/*
 * An init()/handle() reactor over quickjs-ng, for the worker kernel.
 *
 * The kernel fixes every argument before execution and keeps only the last
 * invocation's values, so a `JSContext *` returned by one call can never be an
 * argument to the next. Driving quickjs-ng's exported C API therefore needs
 * result-to-argument dataflow the kernel does not have, and this shim exists
 * so that it does not need it: the context, the guest pointers, evaluation and
 * result framing all stay on this side.
 *
 * `init()` brings the interpreter up and touches nothing a request supplies,
 * because whatever it does ends up in the image every request restores.
 * `handle()` reads the staged source and context, runs `main`, and writes the
 * framed result through the `worker.result` import.
 */
#include <string.h>
#include "quickjs.h"
#include "quickjs-libc.h"

/* `script_v1.channel`: a channel of its own, so the result carries its own
 * bound and nothing has to be parsed back out of stdout. */
__attribute__((import_module("worker"), import_name("result")))
void worker_result(const char *ptr, int len);

static JSRuntime *rt;
static JSContext *ctx;

static JSValue js_worker_result(JSContext *c, JSValueConst this_val,
                                int argc, JSValueConst *argv)
{
    size_t len;
    const char *s;
    if (argc < 1)
        return JS_ThrowTypeError(c, "result takes one string");
    s = JS_ToCStringLen(c, &len, argv[0]);
    if (!s)
        return JS_EXCEPTION;
    worker_result(s, (int)len);
    JS_FreeCString(c, s);
    return JS_UNDEFINED;
}

__attribute__((export_name("init")))
int init(void)
{
    JSValue global;

    rt = JS_NewRuntime();
    if (!rt)
        return 1;
    js_std_init_handlers(rt);
    ctx = JS_NewContext(rt);
    if (!ctx)
        return 1;
    JS_SetModuleLoaderFunc2(rt, NULL, js_module_loader,
                            js_module_check_attributes, NULL);
    js_init_module_std(ctx, "std");
    js_init_module_os(ctx, "os");

    global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "__worker_result",
                      JS_NewCFunction(ctx, js_worker_result,
                                      "__worker_result", 1));
    JS_FreeValue(ctx, global);
    return 0;
}

/* Whether the engine is actually up. `init()`'s own return value is not enough
 * on its own: the kernel does not read guest values, because a kernel that
 * interpreted one would be interpreting a language. So the adapter's
 * `validate` asks this, and a capture of a half-started engine is refused
 * instead of being taken and restored into every request. */
__attribute__((export_name("ready")))
int ready(void)
{
    return ctx != NULL;
}

/* The bootstrap. It is a module so that top-level `await` works, and it writes
 * its result on both the success and the exception path: a request that ends
 * without one is `no_result`, which is a different answer from an error. */
static const char BOOT[] =
    "import * as std from 'std';\n"
    "const fail = (code, message) =>\n"
    "    __worker_result(JSON.stringify({error: {code, message}}));\n"
    "try {\n"
    "    const text = std.loadFile('/context.json');\n"
    "    const context = text === null ? null : JSON.parse(text);\n"
    "    const mod = await import('/main.js');\n"
    "    if (typeof mod.main !== 'function') {\n"
    "        fail('no_entry_point', 'main is not exported');\n"
    "    } else {\n"
    "        const value = await mod.main(context);\n"
    "        __worker_result(JSON.stringify({ok: value === undefined ?"
    " null : value}));\n"
    "    }\n"
    "} catch (e) {\n"
    "    fail('exception', e instanceof Error ? e.message : String(e));\n"
    "}\n";

__attribute__((export_name("handle")))
int handle(void)
{
    JSValue v;
    int rc = 0;

    if (!ctx)
        return 1;
    v = JS_Eval(ctx, BOOT, sizeof(BOOT) - 1, "<boot>", JS_EVAL_TYPE_MODULE);
    if (JS_IsException(v)) {
        js_std_dump_error(ctx);
        rc = 1;
    }
    JS_FreeValue(ctx, v);
    /* A module evaluates to a promise, and the tenant's `main` may itself be
     * async, so the pending jobs are the rest of the request. */
    if (js_std_loop(ctx) != 0)
        rc = 1;
    return rc;
}
