# JavaScript

Run JavaScript that arrives at request time, in a sandbox that gets one
directory and nothing else. You need this page when you are deciding whether
the thing you want to run can run here: it is mostly a list of what is *not*
promised, because that is the half you cannot discover from a working example.

## Run one

> **Where these modules come from.** `js_worker`, `qjs_adapter`,
> `qjs_reactor_adapter` and the worker kernel they run on (`script_worker`,
> `worker_reaper`, `script_v1` and `worker_error`) are in `examples/` in this
> release, not installed with the application. From a checkout of this
> repository, `rebar3 as test shell` compiles them and puts them on the path.
> In your own project, copy those files from `deps/wasm/examples/` into your
> `src/`.

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

## Skip the engine start, with the reactor build

Starting QuickJS is most of a small request: measured between 173 and 190 ms
against 21 ms for the same work once the engine is already up. The reactor
artifact and `qjs_reactor_adapter` are how you get the second number. Build it, then point a
worker at it:

```
scripts/build-quickjs-reactor.sh
```

```erlang
{ok, _} = worker_reaper:start_link(#{scratch => "/var/tmp/js"}),
{ok, W} = script_worker:start_link(
            qjs_reactor_adapter,
            #{path => "test/fixtures/lang/qjs_reactor.wasm", root => scratch,
              limits => #{timeout => 30_000, fuel => infinity,
                          max_memory_pages => 4096,
                          max_heap_words => 16 * 1024 * 1024}}),
{ok, #{result := #{~"answer" := 42}}} =
    script_worker:run(W, #{source => <<"export function main(c)"
                                       " { return {answer: c.value + 1}; }">>,
                           context => #{~"value" => 41}}).
```

The tenant contract is unchanged: the same `main(context)`, the same JSON in
and out, the same capabilities. What changes is that the engine is started once
when the worker starts and each request restores an image of that point.

Notes:

- **Isolation is unchanged.** A restore builds a *fresh* instance, so one
  request's globals never reach the next. That is not a claim about a reused
  interpreter, because there is no reused interpreter.
- **`fuel => infinity` is required**, as it is for the command artifact: the
  untrusted preset's ceiling does not reach the engine's first line. The
  deadline is what bounds a runaway.
- **It needs a WASI SDK to build**, which the fetched command artifact does
  not. `test/fixtures/lang/QUICKJS.md` has the pins.
- The numbers, their null experiment and where the time goes are in
  `test/audit/PERF.md`.

## Give the runner a heap floor

Do this. It is the largest single thing you can do to a QuickJS request and it
is one option:

```erlang
{ok, W} = script_worker:start_link(
            qjs_reactor_adapter,
            #{path => "test/fixtures/lang/qjs_reactor.wasm", root => scratch,
              runner_min_heap_words => 200_000,
              limits => #{timeout => 30_000, fuel => infinity,
                          max_memory_pages => 4096,
                          max_heap_words => 16 * 1024 * 1024}}).
```

**56.0 ms a request becomes 21.1 ms**, because 61% of an unfloored request was
garbage collection: a restored instance keeps almost nothing on the runner's
own heap, so the collector gives it 233 words and collects 98 times through a
call that allocates hundreds of millions.

Note the option sits beside `root` and **not** inside `limits`. A floor is not
a bound, and one written into the limits map is ignored silently.

200,000 words is QuickJS's knee and it plateaus there; the knee is a property
of the guest, and [the tuning guide](tuning.md) is how to find one for a
different build. There is a matching `capture_min_heap_words` for the worker
start, which is worth little here because QuickJS captures in well under a
second.

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
