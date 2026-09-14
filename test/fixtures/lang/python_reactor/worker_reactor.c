/*
 * An init()/handle() reactor over CPython, for the worker kernel.
 *
 * Upstream builds `python.wasm` as a WASI **command**: one `_start`, and by the
 * time it returns `Py_Finalize` has run and the process has exited. An image of
 * that is an image of a torn-down interpreter, which is why a snapshot needs
 * this shape instead.
 *
 * `init()` brings the interpreter up and imports what a request will need, so
 * all of that is in the image. It touches nothing a request supplies, because
 * whatever it touches is shared by every request that restores the image.
 * `handle()` reads the staged source and context, runs `main`, and writes the
 * framed result through the `worker.result` import.
 */
#include <Python.h>

/* `script_v1.channel`: a channel of its own, so the result carries its own
 * bound and nothing has to be parsed back out of stdout. The combined
 * transport is not available here for a reason that is not preference -- it
 * learns its per-request marker from argv, and argv read during `init()` would
 * be frozen into the image. */
__attribute__((import_module("worker"), import_name("result")))
void worker_result(const char *ptr, int len);

static PyObject *result_fn(PyObject *self, PyObject *args)
{
    const char *s;
    Py_ssize_t n;

    (void)self;
    if (!PyArg_ParseTuple(args, "s#", &s, &n))
        return NULL;
    worker_result(s, (int)n);
    Py_RETURN_NONE;
}

static PyMethodDef worker_methods[] = {
    {"result", result_fn, METH_VARARGS, "Write this request's framed result."},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef worker_module = {
    PyModuleDef_HEAD_INIT, "worker", NULL, -1, worker_methods,
    NULL, NULL, NULL, NULL
};

static PyObject *init_worker(void)
{
    return PyModule_Create(&worker_module);
}

/* Imported here rather than inside `handle()` so that the cost is paid once,
 * into the image, instead of once per request. That is most of what a snapshot
 * is worth for this guest: importing `json` alone reads and compiles a
 * meaningful part of the standard library. */
static const char PRELOAD[] =
    "import sys, json, importlib.util, worker\n";

__attribute__((export_name("init")))
int init(void)
{
    PyStatus status;
    PyConfig config;

    if (PyImport_AppendInittab("worker", init_worker) == -1)
        return 1;

    /* Isolated: no environment variables, no user site directory, and the
     * work directory is not on `sys.path`, so nothing a tenant stages can
     * shadow a standard library module. */
    PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode = 0;
    config.buffered_stdio = 0;
    config.install_signal_handlers = 0;

    /* Stated rather than computed. Left to itself, path configuration walks
     * the filesystem looking for a prefix and a landmark, which inside a
     * preopened sandbox means a pile of failed `path_open` calls and a warning
     * at the end of them. There is exactly one answer here and it is the mount
     * the adapter promised, so it is given directly. */
    config.module_search_paths_set = 1;
    status = PyWideStringList_Append(&config.module_search_paths,
                                     L"/lib/python3.14");
    if (PyStatus_Exception(status))
        goto fail;
    status = PyConfig_SetBytesString(&config, &config.program_name, "python");
    if (PyStatus_Exception(status))
        goto fail;
    status = PyConfig_SetBytesString(&config, &config.prefix, "/");
    if (PyStatus_Exception(status))
        goto fail;
    status = PyConfig_SetBytesString(&config, &config.exec_prefix, "/");
    if (PyStatus_Exception(status))
        goto fail;

    status = Py_InitializeFromConfig(&config);
    if (PyStatus_Exception(status))
        goto fail;
    PyConfig_Clear(&config);

    return PyRun_SimpleString(PRELOAD) == 0 ? 0 : 2;

fail:
    PyConfig_Clear(&config);
    return 3;
}

/* Whether the interpreter is actually up. `init()`'s own return value is not
 * enough on its own: the kernel does not read guest values, because a kernel
 * that interpreted one would be interpreting a language. So the adapter's
 * `validate` asks this, and a capture of a half-started interpreter is refused
 * instead of being taken and restored into every request. */
__attribute__((export_name("ready")))
int ready(void)
{
    return Py_IsInitialized() ? 1 : 0;
}

/* The bootstrap. It writes a result on both the success and the exception
 * path: a request that ends without one is `no_result`, which is a different
 * answer from an error. The tenant module is loaded by **absolute path**
 * through `importlib`, never by a search path, so nothing it writes can reach
 * a module the host did not put there.
 *
 * Importing a module runs its top-level statements, so `main` is checked
 * after the import rather than before: a tenant's import-time exception is a
 * real outcome and has to be framed as one. */
static const char BOOT[] =
    "def _worker_run():\n"
    "    try:\n"
    "        with open('/context.json', 'rb') as f:\n"
    "            context = json.loads(f.read() or b'null')\n"
    "        spec = importlib.util.spec_from_file_location('tenant', '/main.py')\n"
    "        mod = importlib.util.module_from_spec(spec)\n"
    "        spec.loader.exec_module(mod)\n"
    "        fn = getattr(mod, 'main', None)\n"
    "        if not callable(fn):\n"
    "            worker.result(json.dumps(\n"
    "                {'error': {'code': 'no_entry_point',\n"
    "                           'message': 'main is not defined'}}))\n"
    "            return\n"
    "        worker.result(json.dumps({'ok': fn(context)}))\n"
    "    except Exception as e:\n"
    "        worker.result(json.dumps(\n"
    "            {'error': {'code': 'exception', 'message': str(e)}}))\n"
    "_worker_run()\n";

__attribute__((export_name("handle")))
int handle(void)
{
    return PyRun_SimpleString(BOOT) == 0 ? 0 : 1;
}
