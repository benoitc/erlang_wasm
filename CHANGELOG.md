# Changelog

## Unreleased

### A restore stops writing what it is about to overwrite

A restored instance was built by applying the module's active data segments and
then zeroing everything the image did not cover, which on CPython was 25 ms of
writing zeros over memory that `atomics:new/2` had already zeroed. A restore
now asks for an instance without those segments applied and writes only the
image's non-zero runs.

**A warm CPython reactor request goes from 64 ms to 35 ms**, and the restore
inside it from 46 ms to 13 ms. QuickJS gains 10%, which is all a guest whose
image is half non-zero has to gain. The bounds an active segment carries are
still checked, so a module that could not be instantiated is refused as before.

Nothing to set: this is how a restore works now.

### Two thirds of a CPython request is restoring its image

A warm, tiered CPython reactor request is 64 ms, and 42 ms of that is
delivering the adapter state and restoring the image. The same bucket is 0.9 ms
of a 6.8 ms QuickJS request. Measured per phase against the real worker, not
reconstructed.

This settles what looked like a CPython-specific weakness in the compiled tier.
On the interval the tier can act on, it is worth **4.3x on QuickJS and 4.0x on
CPython**: the same, to within 8%. The whole-request difference is Amdahl on a
bucket the tier never touches.

Two costs nobody had measured: accepting a request -- the guardian reservation,
the request directory, the channels and the runner spawn -- is 1.7 to 2.3 ms,
which is 24% of a tiered QuickJS request; and the reply path is 0.87 ms on
CPython against 0.025 ms on QuickJS for the same kernel, which is not
explained.

Nothing in `src/` changed. `bench/paths/phasing_adapter.erl` and
`workerbench`'s `phases` mode are how it was measured, and
[the benchmark protocol](bench/paths/README.md) says how to run it.

### What a reactor host must do at startup

Measured, for the first time on the reactor path: a cold node reaches the
compiled tier in 47 s and 3,835 requests on Lua, 147 s and 6,412 on QuickJS,
319 s and 1,908 on CPython. A warm `code_cache_dir` takes that to 0.5 s and 44
requests, 1.5 s and 34, and 7.7 s and 33.

Also fixed, because it made CPython unmeasurable: an image whose tables hold a
`funcref` could only be read by a node that had already interned that atom,
which a freshly started one has not. The decoder now lists the atoms an image's
own values can contain, so they exist before it can decode anything. A CPython
worker start goes from 104 s to 1.1 s.

Two things a host needs to know. **A different script gets nothing from a warm
cache** -- the key includes the set of functions a request executed, so a
second script pays the full cold cost and writes its own entry. And **there is
no supported way to wait until the tier is ready**: `wasm_jit:await/2` needs an
instance, and a worker destroys its instance every request. Waiting rather than
serving through is worth 32 interpreted requests instead of 3,835, so the gap
is recorded rather than papered over.

[The compiled tier guide](docs/compiled-tier.md) has the startup procedure.

### The artifact cache is checked, not just trusted

Reading a cache entry is `code:load_binary/3` on bytes from a file, and nothing
checked those bytes or where they came from. `code_cache_dir` is still opt-in
and still as trusted as your release, but the runtime now refuses a directory
that plainly is not: the path must be absolute with no dot component, the
directory owned by the node's user, every directory above it owned by root or
that user, none of them writable by group or other, and nothing on the path a
symlink. Entries must be regular files, and each carries a digest checked
before it is loaded.

Every failure is a cache miss and one line in the log. Nothing raises, and a
refused directory does not stop the node compiling.

Two behaviour changes worth knowing. A **missing parent** is now a refusal: the
runtime creates the last component of the path at `0700` and nothing above it,
where it used to create the whole chain. And a **relative** `code_cache_dir` is
refused, because it means something different after `file:set_cwd/1`.

The digest detects corruption, not a hostile writer. See
[Security](docs/security.md) for what that does and does not cover.

### A reactor can use compiled code from a request's first call

An instance adopted generated code only on a call where the compiled tier's
hotness counter fired, one call in 32. That is invisible to a long-lived
instance, which adopts once and keeps its slot, and severe for a worker that
restores a snapshot per request: 31 requests in 32 interpreted while the
compiled code sat resident beside them.

Whether code already exists and whether to start compiling some are two
questions, and only the second wants a threshold. `wasm_jit:maybe_adopt/3` now
asks about residency first and consults the count of 32 only when nothing is
resident, so what gets compiled is unchanged and when it can be used is not.

A QuickJS reactor request goes from 20.6 ms to 7.4, Lua from 11.3 to 4.4,
CPython from 119 to 65, and throughput at fourteen workers rises about three
quarters. `test/audit/PERF.md`
has the measurements and the bars they had to clear.

### Heap floors for the request runner and the capture

`script_worker:start_link/2` takes `runner_min_heap_words`, off unless set,
which gives the process running a request a `min_heap_size` rather than the
emulator's 233-word default. A request runner keeps almost nothing on its own
heap, so the collector sizes it a small one and collects through the request
dozens of times: on QuickJS that was 61% of a request, and a floor of 200,000
words takes one from 56.0 ms to 21.1 ms.

```erlang
script_worker:start_link(my_adapter, #{root => scratch,
                                       runner_min_heap_words => 200_000}).
```

`capture_min_heap_words` is the same for the process a snapshot capture runs
in, where it is worth more still: a CPython worker start goes from 91 s to
18 s. Separate from the runner's because it is a different process doing
different work, and it costs nothing where no capture happens.

**Raise `max_heap_words` when you add a capture floor.** The ceiling bounds the
peak and a floor raises the baseline it is measured from, so one that was
comfortable without a floor can stop being: CPython at its adapter's own 16 M
words dies about three runs in four with a 2 M capture floor. A capture killed
that way now names `max_heap_words` and the floor in its error rather than only
saying `killed`.

The right value is a property of the guest, so sweep for it. [The tuning
guide](docs/tuning.md) is new and says how; `script_worker:runner_heap_words/2`
and `capture_heap_words/2` answer what a configuration resolves to without
starting a worker. A floor with no room under `max_heap_words` is refused with
a warning rather than applied, because `min_heap_size` above `max_heap_size`
kills the process at spawn.

### A worker kernel for untrusted guests

`examples/script_worker.erl` is now a language-neutral kernel: modules,
imports, invocations, deadlines and bounded channels, and nothing about WASI or
JSON. A language is an **adapter**, the eight-callback behaviour the same
module declares. Start one with a `worker_reaper` and a scratch root:

```erlang
{ok, _} = worker_reaper:start_link(#{scratch => "/var/tmp/w"}),
{ok, W} = script_worker:start_link(my_adapter, #{root => scratch}),
{ok, R} = script_worker:run(W, Request).
```

See [the adapter contract](docs/worker-contract.md) for writing one, and
[the worker guide](docs/worker.md) for the `metered` and `compiled`
configurations, which are mutually exclusive: setting `compile => true` while
keeping a fuel ceiling silently gets you the interpreter.

**Breaking.** The QuickJS example is `qjs_worker`, since the kernel has the
name it used to hold. Its behaviour is unchanged.

`max_output_bytes` now also accepts `#{stdout := N, stderr := M}`, so the two
streams can carry different bounds.

New: `wasm:extern/0` names the value `extern/2` returns. A new `kernel_check`
rebar profile analyses `examples/`, which no other profile reaches.

### JavaScript and Python through `script_v1`

`js_worker` and `python_worker` run a function that arrives at request time:

```erlang
{ok, W} = js_worker:start_link("qjs.wasm", #{root => scratch}),
{ok, #{result := #{~"answer" := 42}}} =
    js_worker:run(W, ~"export function main(c) { return {answer: c.value+1}; }",
                  #{~"value" => 41}).
```

**CPython needs ceilings raised knowingly**, and an adapter never raises one
for you: `timeout`, `max_memory_pages`, `fuel` (a thousand times the untrusted
preset) and `max_heap_words` (16M words; the default kills the runner, and a
*larger* bound is slower). [The Python guide](docs/python.md) has the numbers.

[docs/javascript.md](docs/javascript.md) and
[docs/python.md](docs/python.md) say what each language does not promise. The
network is **ungranted** rather than unavailable in both.

`scripts/fetch-python-fixture.sh` and `scripts/verify-fixtures.sh` fetch and
check the artifacts; `test/fixtures/lang/QUICKJS.md` and `PYTHON.md` record
what they are.

### Initialized runtime snapshots

`wasm:snapshot/1`, `wasm:restore/3` and `wasm:snapshot_info/1`. An image of an
already-started guest, restored into a **fresh** instance, so startup is
skipped and per-request isolation is unchanged.

```erlang
{ok, Init} = wasm:instantiate(Handle, Imports, #{snapshotable => true}),
{ok, _} = wasm:call(Init, ~"init", []),
{ok, Image} = wasm:snapshot(Init),
{ok, Fresh} = wasm:restore(Image, FreshImports, #{}).
```

`snapshotable => true` is required and costs an ordinary instance nothing.
Restore does **not** run the module's start function, and takes the module from
the image rather than from the caller. On a snapshotable instance `extern/2` is
refused and `write_memory/3` takes a lease, so a capture cannot read a torn
image.

Every import module in the bindings needs an entry in `snapshot_hooks`, or the
capture is refused: say `stateless`, or supply `eligible`, `capture` and
`restore` funs. `wasi_preview1:snapshot_hook/0` is WASI's, and it refuses a
descriptor opened during initialisation.

Refused: an instance not built through `wasm:load/1`, an imported memory, table
or global, a shared memory, a non-empty object store, and a reference to
another instance.

`script_worker` uses them: an adapter that exports `snapshot_capability/1`
gets its runtime captured once at `start_link/2` and restored into every
request, with `prepare/3` returning only the request's own work. A capture that
fails fails the start. Two adapters use it, over reactors built by
`scripts/build-quickjs-reactor.sh` and `scripts/build-python-reactor.sh`:

| | per request, command | per request, restored |
| --- | ---: | ---: |
| `qjs_reactor_adapter` | 173 to 190 ms | 28 to 46 ms |
| `py_reactor_adapter` | 66 to 87 s | 0.35 s |
| `lua_reactor_adapter` | n/a | 25 ms |

Lua is the third language and the first added after all of this was written:
it passed the conformance kit unmodified, with no kernel, profile or snapshot
change. Building it needs `-mllvm -wasm-use-legacy-eh=false`, because LLVM
emits the superseded exception-handling encoding by default and this runtime
implements the standardised one. [The Lua guide](docs/lua.md) has the rest.

`test/audit/PERF.md` has the protocol and the null experiments.
`start_link/2` pays one interpreter start, which for CPython is about 90
seconds, so start your workers before you take traffic, and raise
`capture_timeout` (a worker option, 60 s by default) past it.

**Three fixes since.** A mutable global a module *exports* is a cell, and
capturing it raw shared one global between every restore from an image and died
with the instance that captured it. A restore that grew a memory wrote through
the pre-grow handle, which only worked because reactors export their memory. A
table the guest grew during `init()` could be captured and never restored.

Capture also refuses by allowlist now rather than by a list of refusals, so a
global holding a host term is refused instead of entering an image.

A restored table is written once rather than once per element, which is
**2.5x on a CPython request**. An image keeps only the non-zero runs of each
memory, which holds 5.7x less: `wasm:snapshot_info/1`'s `bytes` and the
`max_snapshot_bytes` budget both mean what is retained, so a ceiling set before
this admits proportionally more images.

**Images can be kept on disk.** `application:set_env(wasm, snapshot_dir, Dir)`
and a worker reads its image instead of running `init()` again: a CPython
worker starts in **under a second** against a hundred capturing, from a
2.7 MB file. Off unless you
set it, and the directory is as trusted as your release.
`wasm:save_snapshot/2` and `wasm:load_snapshot/2` are the same thing by hand.

`application:set_env(wasm, max_snapshot_dir_bytes, N)` bounds that directory,
512 MiB by default, oldest first. It is trimmed when an image is filed and at
no other time, so lowering it shrinks nothing until the next capture;
`wasm_snapshot_store:purge/0` empties one now. Note it is not
`max_snapshot_bytes`, which bounds what images retain in memory.

An adapter must supply a `compatibility_key` to be filed at all: an image is a
runtime after `init()` ran against a particular environment, and nothing else
in the contract accounts for it.

[The snapshot guide](docs/snapshots.md) has the lifecycle and the hooks.

`wasm:acquire/1` and `wasm:release/1` add and drop a holder. An image keeps its
own claim on its module, so it survives the process that captured it **if
something acquired first**. `application:set_env(wasm, max_snapshot_bytes, N)`
bounds images node-wide; the default is `infinity`, meaning unbounded rather
than off.

### The compiled tier runs the OTP compiler in a process it owns

`compile:forms/2` runs its passes in a process of its own and gives a caller no
way to configure it, so anything set on the process `wasm_jit` spawns bound a
process that only waits: 141 MB watched against 2,055 MB spent. The tier now
declines that spawn with `no_spawn_compiler_process` and makes the same
short-lived process itself, measured at 0.9% over five interleaved samples.

Two things follow. A heap ceiling can be set, with
`application:set_env(wasm, compile_max_heap_words, Words)`; a compile over it is
refused, which means the guest interprets and answers as before, and
`wasm_jit:diagnostics/0` says `{limit, {compile_memory, Words}}`. It is **off by
default**: see [the compiled tier guide](docs/compiled-tier.md) for what it does
and does not bound.

And a compile can now be stopped. `compile:forms/2` spawns its worker with
`spawn_monitor/1`, which does not link, so until now a compiler killed by
`application:stop(wasm)` or by its supervisor left the OTP compiler running to
completion holding its copy of the forms, with nothing able to see or stop it.

### A budget for what the node has in flight

`compile_max_heap_words` bounds one compiler, and the slot pool allows sixteen
of them, so it is not a bound on the node. `compile_budget_heap_words` is, in
the same unit: a compile reserves the ceiling it will be held to, so the
aggregate is a sum of quantities the VM enforces at every collection rather
than a prediction. `Budget div Ceiling` compilers are admitted and the rest are
refused, which means the guest interprets and asks again later.

It needs the ceiling to mean anything, and says so once through `logger` if set
without one. Nothing is queued: a caller that waited would hold the unit IR it
was admitted to compile for the whole wait. A request larger than the whole
budget still compiles when nothing else is running, and a killed compiler gives
its words back through a monitor rather than an `after`. Off by default.

`wasm_jit:compile_limits/0` reports `max_heap_words`, `budget_heap_words` and
the `max_concurrent_compilers` the two imply.

### A shard is no longer cached, and a cache hit is never refused

Two defects in the compiled tier's cache, both found while measuring the above.

The *last* shard of a sharded compile was written to the on-disk cache and read
back, under a key carrying the identity, ABI, slot, quality, function set and
stamp, while the artifact also embeds the module a crossing re-enters the chain
through and a map of where every other function lives. Neither is in the key,
and the first is whichever slot shard one happened to claim. Only a whole unit
is cached now.

And a request that was about to adopt an artifact from disk was admitted against
the compile budget as if it were about to compile one, so a busy node turned the
cache path into interpreting. The lookup now happens before admission, and a
cache hit reserves nothing.

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
