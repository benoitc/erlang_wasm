# Changelog

## Unreleased

**The workers ship with the application.** Running JavaScript, Python or Lua
now needs the dependency and a runtime artifact, and nothing copied from
`examples/`. Nothing breaks: the new modules take names no 0.3 example used,
so code you copied keeps working. [Upgrading from 0.3](docs/upgrading.md)
maps each copied module to its installed one.

- `wasm_script_worker` is the worker kernel; `run/3` takes a source and a
  context. `wasm_worker_adapter` is the behaviour an adapter implements.
- The adapters are `wasm_javascript`, `wasm_javascript_command`,
  `wasm_python`, `wasm_python_command` and `wasm_lua`.
- `wasm_instance_worker` is the 0.3 `examples/wasm_worker.erl`, with the same
  calls.
- The application starts the reaper. Set `scratch_roots` so a restarted node
  cleans up what a crashed one left, and `reaper_options` for the cleanup
  limits. `wasm_script_worker:cleanup_stats/0` and `cleanup_requests/0` show
  what it holds.

## 0.3.0

This release is about running other people's code: safely, and fast enough to
be worth doing.

Three parts, meant to be used together.

- A **worker** runs one untrusted request at a time, in its own process, with
  its own deadline and its own limits.
- **Snapshots** let a language like Python start once, when the worker starts,
  instead of starting again on every request.
- The **compiled tier** now works for a worker like that. It did not before.

Together they take a CPython request from about a minute to 35 ms.

### Run untrusted code, one request at a time

`script_worker` is the worker. It knows about modules, imports, deadlines and
output limits. It knows nothing about WASI, or JSON, or what your guest calls
its entry point. That part is an **adapter**: one module per language.

```erlang
{ok, _} = worker_reaper:start_link(#{scratch => "/var/tmp/w"}),
{ok, W} = script_worker:start_link(my_adapter, #{root => scratch}),
{ok, R} = script_worker:run(W, Request).
```

Three languages come with adapters already. `js_worker` and `python_worker`
take a function written by whoever is sending the request. Lua is
`lua_reactor_adapter`.

Every language needs its own limits, and an adapter will never raise one for
you. Python will not even start until you raise several of them. The Python
guide lists them.

Read next: [workers](docs/worker.md) to run one,
[the adapter contract](docs/worker-contract.md) to write one, and
[JavaScript](docs/javascript.md), [Python](docs/python.md) or
[Lua](docs/lua.md) for a language.

Smaller things: `max_output_bytes` now accepts separate bounds for stdout and
stderr. `t:wasm:extern/0` names the type `extern/2` returns.

### Start an interpreter once, not once per request

Starting CPython takes about a minute and a half. Doing that per request is not
an option, and keeping one interpreter alive across requests leaks one caller's
state into the next.

So capture it once, and give every request a fresh copy:

```erlang
{ok, Image} = wasm:snapshot(Init),
{ok, Fresh} = wasm:restore(Image, FreshImports, #{}).
```

The copy is genuinely fresh. Globals, memory and tables come from the image,
but the imports are the ones you pass in now, so one request cannot reach
another's files or sockets.

The instance you capture has to be created with `snapshotable => true`, and a
restore refuses an image that does not match the module it is handed.
`wasm:save_snapshot/2` and `load_snapshot/2` put an image on disk.
`max_snapshot_bytes` caps what one node keeps in memory.

Read next: [snapshots](docs/snapshots.md).

### Compiling hot code, and why it helps now

Turn it on with `compile => true` and `fuel => infinity`. Those two go
together: leaving a fuel limit in place quietly keeps you on the interpreter.
Point `code_cache_dir` at a directory you own, and a restart reuses what was
compiled last time. That is minutes of work turned into seconds.

What changed:

- **A fresh instance uses compiled code immediately.** It used to wait for a
  function to be called 32 times. A worker that builds a new instance per
  request almost never got there, so 31 requests in 32 ran interpreted next to
  compiled code that was sitting right there.
- **Restoring a snapshot is three times faster.** It used to write out the
  module's initial data and then blank it again, even though the image was
  about to overwrite all of it. A CPython request went from 64 ms to 35 ms.
- **A compile can be given a memory cap, and can be interrupted.**
  `compile_max_heap_words` caps a single compile. `compile_budget_heap_words`
  caps the whole machine: divide it by the cap and that is how many compiles
  run at once. A guest that does not get a slot keeps interpreting and tries
  again later. Both are off unless you turn them on.
- **The compiled-code cache is checked, not trusted.** It verifies the
  directory and every file it reads, and quietly recompiles if anything looks
  wrong. It will not read through a symlink or out of a world-writable
  directory.

Read next: [the compiled tier](docs/compiled-tier.md).

### If requests are slower than you expect, set a heap floor

A restored instance holds almost nothing on the Erlang heap, so the runtime
gives its process a tiny one and then collects garbage hundreds of times during
a single call.

`runner_min_heap_words` fixes it. The right value depends on the guest:
200,000 for QuickJS and Lua, 1,000,000 for CPython. Going higher than that
makes things worse, not better. `capture_min_heap_words` does the same for the
snapshot.

Read next: [tuning](docs/tuning.md).

### Breaking

`script_worker` used to be the QuickJS worker. It is called `qjs_worker` now
and behaves exactly as it did. The old name now belongs to the
language-neutral worker described above.

## 0.2.2

Documentation only. No code changed.

### Documentation

A guide for talking to a guest while it runs, [Streams](docs/streams.md). You
need it when the module you are running is a server rather than a function: a
script with its own read loop, a language runtime answering one request at a
time, or a program whose output you want as it is produced.

There is no new API for this, which is the point of the page. A `stdin`
capability may be a fun and a fun is allowed to block, so `fd_read` waits until
you answer; a `stdout` capability may be a pid, which receives
`{wasi_output, RunnerPid, Bytes}` per write. Both were one table cell each in
the WASI guide, so the recipe was not findable. The WASI and Workers guides now
point at it, and it states the two things that bite: the fun blocks the process
running the call, so the process feeding the guest has to be a different one,
and it needs an `after` or a guest parked on a read holds a worker for ever.

The README says that the project is developed with strong AI assistance, and
what that process is: humans lead the architecture, semantics, testing and
benchmarking, generated code is a proposal rather than evidence, and changes
are validated against the specification suite, real toolchain output and
repeatable benchmarks.

## 0.2.1

### Changed

`array.copy` and `array.fill` do less work per element. Over ten thousand
elements, a copied element costs 7.0 reductions where it cost 19.9, and a
filled one 6.0 where it cost 7.8.

`array.copy` built three lists per copy and read the array's length from the
object table once per element, re-answering what the range check had already
answered. The loop lives in `wasm_heap` now, beside the accounting it has to go
through: it reads the source array's default once rather than per element, and
decides an overlapping copy by direction instead of taking a snapshot of the
source. A partial `array.fill` counts down rather than walking a list of the
indices it is about to use.

Behaviour does not change, including the rule that an overlapping `array.copy`
behaves as though an intermediate copy were taken.

## 0.2.0

### Changed

The supervision tree is one supervisor per subsystem. Five servers under one
`intensity => 5, period => 10` shared a budget, so losing the module cache
repeatedly could take the engine, the keeper and the code slots with it, and
the tables went too. Each subsystem now has its own supervisor and its own
`10 in 60`, and `wasm_store` owns the long-lived tables.

A wrong-typed call argument answers `{link, argument_type}` where it used to
answer `{malformed, internal}`. `malformed` is the decode class and an argument
is not a decode concern; the kind is new, the class has changed, and anything
matching on the old pair needs updating.

- **`max_memory_pages` now covers garbage-collected objects as well as linear
  memory.** A workload under a tight ceiling that allocates structs or arrays
  can be refused where it was not. The node page budget widens the same way, so
  `memory.grow` can return -1 because a guest filled the object store. Both were
  unbounded before: a guest filling a twenty-million element array took 1.8 GB
  with `max_heap_words` set, `process_flag(max_heap_size, ...)` set on the
  process running it, and `pages_in_use` reading zero throughout, because a
  struct or an array is a row in ETS and ETS is not process heap.

  `max_heap_words` is documented as what it always was: a ceiling on terms on
  the *caller's own heap*, applied by the caller. It never covered guest memory
  of either kind, and no longer reads as though it might.

### Fixed

- **A store of few large objects was never collected.** Every rule in
  `wasm_heap` counted objects: `major_due/1` compared a row count against a
  floor of 4096, so a workload replacing one large array per call never got a
  major collection, and a minor one leaves the old generation alone by design.
  Four rounds of a fifty thousand element array left all four, sixteen
  megabytes, with one reachable. Both `major_due/1` and `should_collect/1` now
  read bytes as well as rows, with a `gc_min_major_pages` floor. A workload that
  allocates heavily and keeps nothing does about 14% more work and stops
  leaking; one with a stable live set is unaffected.

- **`atomic.fence` was rejected as invalid.** The decoder and the interpreter
  both knew it and the validator had no clause, so every module carrying a
  fence failed to load. The specification suite does not exercise it.
- **A tree death leaked the node page budget permanently.** The counter lives
  in `persistent_term` and outlives the supervision tree; the registry that
  says who holds those pages does not. Pages charged when the tree died could
  never be released, and it accumulated across application restarts.
  `wasm_keeper` now reconciles the two when it starts.
- **A limits map that could not mean what it said was ignored.**
  `#{max_depth => lots}` failed open, because every integer sorts before every
  atom, so a guest could recurse a million frames under a ceiling the embedder
  believed it had set. `wasm_limits:validate/1` existed and nothing called it.
- **The compiled tier computed on ill-typed arguments.** `wasm_exec` checks
  arity and the tier never reaches it, so the same call answered differently
  depending on whether the function was hot; and a float passed for an `i32`
  was rejected by the interpreter and had `i32.add` run on it by the tier.
  Both are checked once now, before either engine is chosen.

## 0.1.1

`wasm:compile/1` takes the text format:

```erlang
{ok, M} = wasm:compile({wat, ~"(module (func (export \"f\") (result i32) i32.const 7))"}).
```

`load/1` still takes the binary format only: the cache is keyed on a content
hash, and a module built from text takes a fresh identity every time.

### Fixed

Seven lifecycle defects found by an audit of the previous release.

- A reader killed inside `wasm_heap:lease/1` or `unlease/2` stranded a count
  nothing could give back, and the object store never collected again.
- A keeper restart dropped every per-instance memory ceiling, so an instance
  created with `max_memory_pages` grew past it.
- A process calling instances it does not destroy kept one table array and one
  compiled entry per instance, without bound.
- `sock_send_to` leaked a socket when the send failed, and another when the
  guest's output pointer was out of bounds.
- `atomic.wait` reported a wakeup that never happened when the notifier died
  between claiming a waiter and sending to it.
- `wasm_engine`'s per-instance limits table had no callers and is gone.

## 0.1.0

First public release. The versions before it were developed in a private
repository and are not published; this is the whole runtime as one release.

The Hex package is `erlang_wasm`; the OTP application inside it is `wasm`.

```erlang
{deps, [{wasm, {pkg, erlang_wasm}}]}.
```

### What it does

A WebAssembly runtime written in Erlang/OTP. Decoding, validation,
instantiation, execution, linear memory and WASI preview 1 are implemented in
Erlang. The only native code is an optional file NIF that closes a
time-of-check-to-time-of-use window in WASI path resolution, and the runtime
falls back to a pure Erlang resolver when it is absent.

### Proposals

WebAssembly 1.0 core, bulk memory, reference types, multi-value, multiple
memories, memory64, SIMD, relaxed SIMD, tail calls, typed function references,
exception handling, garbage collection, threads and shared memories, sign
extension, and saturating float-to-int conversion.

Both formats are read: the binary format, and the text format as `.wat` modules
and `.wast` scripts.

### WASI

Forty-four preview 1 syscalls. Directories and sockets are granted by naming
what may be reached, with nothing reachable by default. See `docs/wasi.md` and
`docs/security.md`.

### The compiled tier

Hot functions are lowered to Core Erlang, compiled and loaded into a fixed pool
of sixteen pre-interned module names, so no atom is ever derived from a guest's
bytes. Off by default; see `docs/compiled-tier.md` for when it pays and when it
does not.

### Errors and limits

Nothing raises. A malformed binary, an ill-typed module, a trap and a resource
limit all come back as `{error, Error}` carrying a class, a machine-readable
kind, the specification's message text and context. Memory pages, tables and
globals are held by holder tokens whose owning process's death releases them,
so a killed worker cannot leak a page.

### Conformance

64,774 core specification assertions across 215 suites, with an empty skip
baseline, and 65,481 of them replayed through generated code. Seventy-two of
the 72 wasi-testsuite cases pass with the NIF, 68 without it. Neither suite is
vendored; `docs/features.md` says how to clone them.
