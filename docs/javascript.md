# JavaScript

This page shows you how to run JavaScript code that you receive at request
time. The code runs in a sandbox that can see one directory and nothing else.
Read it to decide whether your JavaScript can run here. Most of the page lists
what is *not* provided, because a working example cannot show you that.

A few words used on this page:

- a **worker** is a process that runs one request at a time with a deadline;
- an **adapter** is the module that teaches a worker one language, here
  `wasm_javascript_command` or `wasm_javascript`;
- the **tenant** is the person who writes the JavaScript you run;
- a **runner** is the process that runs the guest for one request.

The [glossary](concepts.md#glossary) defines the others.

## Run one

> **Where these modules come from.** `wasm_javascript_command`,
> `wasm_javascript` and the worker kernel they run on (`wasm_script_worker`)
> are installed with the application. You supply the QuickJS artifact, the
> `.wasm` file.

<!-- check: run -->
<!-- check: needs qjs -->
```erlang
{ok, W} = wasm_script_worker:start_link(
            wasm_javascript_command, #{path => "test/fixtures/lang/qjs.wasm"}),
{ok, #{result := #{~"answer" := 42}}} =
    wasm_script_worker:run(W, <<"export function main(c)"
                                " { return {answer: c.value + 1}; }">>,
                           #{~"value" => 41}).
```

The tenant writes an ES module exporting `main`:

```javascript
export function main(context) {
    return { answer: context.value + 1 };
}
```

`context` is the map you passed, sent as JSON. Its keys are binaries in
Erlang and strings in JavaScript. The value `main` returns is sent back as
JSON the same way, and you find it under `result`.

## What you get

You get the language and the engine's own library.
`test/fixtures/lang/QUICKJS.md` records which build. Every answer in it comes
from running that build, not from its documentation.

You get file access controlled by capabilities. The worker writes your source
and context into one read-only directory, called a preopen, and grants nothing
else. A guest that tries to create a file there gets `ENOTCAPABLE`. A guest
that tries to leave the preopen gets the same error. `wasm_adapter_conformance`
checks both from inside the sandbox.

## What you do not get

**A module resolver at run time.** `import` only finds the absolute path
where the host wrote the source. npm works as on Cloudflare Workers: bundle
your code before you submit it. The resolver is missing, not the packages.

**Node built-ins.** There are none. `std` is QuickJS's own module, and the
bootstrap uses it. Nothing provides `fs` or `path`.

**A network.** The worker denies network access on purpose; it is not
missing. Without a `net` key there is no network at all, whatever the engine
imports. To grant it, write a `wasi_net` rule that names addresses and ports.
These limits do not do what a Cloudflare Workers user expects:
`max_sockets` limits the sockets an instance holds **at the same time**, and
`timeout` limits **one blocking call** ([WASI guide](wasi.md)). Neither one
limits the total number of outgoing requests, and neither one is a deadline
for a whole outgoing request. A host that needs those must count them itself.

**Threads, `Worker`, or an event loop that keeps running after the call.** A
request is a fixed sequence of calls, limited by a wall-clock deadline. This
is also why there is no `ctx.waitUntil`.

**The WasmEdge extensions** that the current temporary artifact contains. A
script that uses them depends on that artifact, and may break with another
build.

## Skip the engine start, with the reactor build

Starting QuickJS takes most of the time of a small request: 173 ms, against
28.5 ms for the same work once the engine has started, both measured in the
same run. The reactor artifact and `wasm_javascript` give you the second
number. A **reactor** is a guest that exports functions and stays ready, where
a **command** runs `_start` once and exits. Build it, then give its path to a
worker:

```sh
scripts/build-quickjs-reactor.sh
```

<!-- check: run -->
<!-- check: fresh -->
<!-- check: needs qjs_reactor -->
```erlang
{ok, W} = wasm_script_worker:start_link(
            wasm_javascript,
            #{path => "test/fixtures/lang/qjs_reactor.wasm",
              limits => #{timeout => 30_000, fuel => infinity,
                          max_memory_pages => 4096,
                          max_heap_words => 16 * 1024 * 1024}}),
{ok, #{result := #{~"answer" := 42}}} =
    wasm_script_worker:run(W, #{source => <<"export function main(c)"
                                       " { return {answer: c.value + 1}; }">>,
                           context => #{~"value" => 41}}).
```

For the tenant nothing changes: the same `main(context)`, the same JSON in
and out, the same capabilities. What changes is this: the engine starts once,
when the worker starts. The worker saves an **image** of the guest at that
point, and each request **restores** a fresh instance from that image.

Notes:

- **Isolation does not change.** A restore builds a *fresh* instance, so the
  globals of one request never reach the next. No interpreter is reused.
- **`fuel => infinity` is required**, as for the command artifact. **Fuel** is
  a work budget, and the untrusted preset's budget is used up before the
  engine runs its first line. The deadline is what stops a script that runs
  too long.
- **The build needs a WASI SDK.** The downloaded command artifact does not.
  `test/fixtures/lang/QUICKJS.md` has the pinned versions.
- The numbers, the control measurement and where the time goes are in
  `test/audit/PERF.md`.

## The runner's heap floor

A **heap floor** is a minimum heap size given to a process when it starts,
so the Erlang garbage collector runs less often. `wasm_javascript` gives every
request runner a heap floor of 200,000 words by default. No other single
setting speeds up a QuickJS request as much, and you get it without setting
anything. Set the option yourself to change it, or pass `0` to turn it off:

<!-- check: run -->
<!-- check: fresh -->
<!-- check: needs qjs_reactor -->
```erlang
{ok, W} = wasm_script_worker:start_link(
            wasm_javascript,
            #{path => "test/fixtures/lang/qjs_reactor.wasm",
              runner_min_heap_words => 400_000,
              limits => #{timeout => 30_000, fuel => infinity,
                          max_memory_pages => 4096,
                          max_heap_words => 16 * 1024 * 1024}}).
```

With the floor, **a request takes 21.1 ms instead of 56.0 ms**. Without it,
61% of a request was garbage collection. A restored instance keeps almost
nothing on the runner's own heap, so the collector gives the runner a 233-word
heap, and then collects 98 times during a call that allocates hundreds of
millions of words.

At 200,000 words QuickJS stops getting faster: a larger floor gains nothing.
This value depends on the guest. [The tuning guide](tuning.md) shows how to
find it for a different build. `capture_min_heap_words` helps little here,
because QuickJS captures its image in well under a second. [How a heap floor
works](tuning.md#how-a-heap-floor-works) explains where the options go and how
a floor is rounded.

## The limit is wall-clock time or work, not both

`wasm_limits:untrusted/0` sets a fuel limit. `wasm_jit:entry/3` runs compiled
code only when fuel is `infinity`. So you cannot have both a fuel limit and
the [compiled tier](compiled-tier.md). **A host that sets `compile => true` and
keeps the fuel limit gets no error and no compiled code**: it silently gets
the interpreter. `wasm_worker_lang_SUITE` checks exactly this over 500
requests.

With compiled code, only the guardian's wall-clock deadline stops a script
that runs forever. The guardian is the process that owns one request and
enforces its deadline. This is a security point, not a tuning note.

## Errors

Every error comes back as a value. An exception in the tenant's code comes
back as

```erlang
{error, #{class := adapter, kind := adapter_failure,
          msg := ~"boom",
          ctx := #{code := ~"exception", stdout := _, stderr := _}}}
```

`code` is a **binary** and will stay one. The atom table is shared by the
whole node and atoms are never freed, so nothing a guest names becomes an
atom.

## Read this next

[Tuning](tuning.md), then [Snapshots](snapshots.md).
