# JavaScript

Run JavaScript that arrives at request time, in a sandbox that gets one
directory and nothing else. You need this page when you are deciding whether
the thing you want to run can run here: it is mostly a list of what is *not*
promised, because that is the half you cannot discover from a working example.

## Run one

```erlang
{ok, _} = worker_reaper:start_link(#{scratch => "/var/tmp/js"}),
{ok, W} = js_worker:start_link("test/fixtures/lang/qjs.wasm", #{root => scratch}),
{ok, #{result := #{~"answer" := 42}}} =
    js_worker:run(W, ~"export function main(c) { return {answer: c.value + 1}; }",
                  #{~"value" => 41}).
```

The tenant writes an ES module exporting `main`:

```javascript
export function main(context) {
    return { answer: context.value + 1 };
}
```

`context` is whatever you passed, decoded from JSON, so its keys are binaries
on the way in and strings in JavaScript. What `main` returns is encoded the
same way and comes back under `result`.

## What you get

The language, and the engine's own library. `test/fixtures/lang/QUICKJS.md`
records which build, and every answer in it was taken by running that build
rather than from its documentation.

Capability-controlled file access: the worker stages your source and context
into one read-only mount and grants nothing else. A guest that tries to create
a file there gets `ENOTCAPABLE`, and a guest that tries to climb out of the
preopen gets the same, both asserted from inside the sandbox in
`wasm_adapter_conformance`.

## What you do not get

**A runtime module resolver.** `import` resolves the absolute path the host
staged. npm works the way it works on Cloudflare Workers: bundle before
submitting. What is absent is the resolver, not the packages.

**Node built-ins.** None. `std` is QuickJS's own and the bootstrap uses it;
nothing re-exports `fs` or `path`.

**A network.** Denied here by choice rather than missing, and the difference
matters. An absent `net` key is no network at all however much the engine
imports, so granting it is a `wasi_net` rule naming addresses and ports. Note
what those knobs bound, because neither is what a Workers user expects:
`max_sockets` caps the descriptors an instance holds **at once**, and `timeout`
bounds **one blocking call** ([WASI guide](wasi.md)). Neither is a total
subrequest cap, and neither is an end-to-end deadline for one subrequest. A
host that wants those counts them itself.

**Threads, `Worker`, or an event loop that outlives the call.** The profile is
a finite sequence of calls and the bound is wall clock, which is also why there
is no `ctx.waitUntil`.

**The WasmEdge extensions** the interim artifact carries. A script that relies
on them is relying on that artifact rather than on the profile.

## The bound is wall clock, or work, and not both

`wasm_limits:untrusted/0` sets a fuel ceiling, and `wasm_jit:entry/3` enables
generated code only when fuel is `infinity`. So the two named configurations
are exclusive, and **a host that sets `compile => true` and keeps the fuel
ceiling gets neither an error nor a tier**: it gets the interpreter, quietly.
`wasm_worker_lang_SUITE` asserts exactly that over 500 requests.

Under `compiled` the only thing between the node and a runaway script is the
guardian's wall-clock deadline. That is a security statement rather than a
tuning note.

## Errors

Everything arrives as a value. A tenant exception comes back as

```erlang
{error, #{class := adapter, kind := adapter_failure,
          msg := ~"boom",
          ctx := #{code := ~"exception", stdout := _, stderr := _}}}
```

`code` is a **binary** and always will be: the atom table is node-wide and
never reclaimed, so nothing a guest names can reach it.
