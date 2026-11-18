# Design principles

This page states the few rules that explain how the API behaves: why a call
returns a value instead of raising, why a deadline needs a process, why you
load a module once. Read it when you decide whether to rely on erlang_wasm,
and before you contribute a change, because a change that breaks one of
these rules is not accepted. Each section says what the rule is, why it
holds, and where you see it in the API. The reasons behind the internals are
in [Design notes](design-notes.md).

## Pure Erlang, not a binding

**What it is.** The runtime decodes, validates and runs WebAssembly in
Erlang. It does not call Wasmtime, Wasmer, WAMR or wasm3. Linear memory,
WASI and the Component Model are Erlang code too.

**Why.**

- A bug in native code can crash the whole node, with every process in it.
  A bug in Erlang code raises an exception in one process. At the API
  boundary the runtime turns that exception into an error value of kind
  `internal`, so even a defect of the runtime reaches you as a value.
- The safety claims stay checkable. For example, every memory access is
  checked with Erlang's unlimited-size integers, so an address cannot wrap
  around. You can read that code, and the property tests run it on random
  input.
- You build and ship nothing native.

**The one exception.** An optional file NIF closes one race in WASI path
resolution: between checking a path and opening it, someone could replace a
directory with a symlink. Erlang cannot open a file relative to a directory
it holds, so pure Erlang can make this window smaller but cannot close it.
Without a C compiler the runtime uses the pure Erlang path, and works.

**Where you see it.**

- `wasi_fs:backend/0` answers `native` or `fallback`. See
  [Check which backend you have](wasi.md#check-which-backend-you-have).
- The `require_native_fs` setting refuses every directory grant when the NIF
  is missing. See [Configuration](configuration.md).
- Speed: a native engine runs guests faster. [Start here](start-here.md)
  says when that matters more to you.
- A NIF is used only where it wins on measurement. Floats are an example
  where it lost: see
  [Design notes](design-notes.md#float-representation-and-why-there-is-no-nif).
  [Changing the NIF](contributing/nif.md) is for contributors.

## A process for each untrusted instance

**What it is.** An instance belongs to the process that created it. To run
code you do not trust, put the instance in a process of its own, a
**worker**, and call it through messages.

**Why.**

- A call made in your own process cannot be interrupted. Only a separate
  process can be killed when its deadline passes, and killing it really
  stops the work.
- When a process exits, the BEAM frees its heap at once, and the runtime
  frees the memory, tables and images it held.
- The owning process can cap its own heap. `max_heap_words` in the limits is
  applied this way.

A process is a boundary for faults and lifetimes, not for everything.
Linear memory is outside any process heap, so the runtime counts pages
itself, for the whole node. See
[What the process does not protect](worker.md#what-the-process-does-not-protect).

**Where you see it.**

- `wasm_instance_worker` and `wasm_script_worker`, with `timeout` in their
  limits. See [Using workers](worker.md) and
  [Hosting scripting languages](scripting.md).
- `isolation => fresh`, a new instance for every request.
- An instance handle stops working when the process that created it exits.
  See [Know who owns the instance](embedding.md#know-who-owns-the-instance).

## Failures are values at the guest boundary

**What it is.** Nothing a guest supplies makes a call raise an exception:
not the module bytes, not what the guest does while it runs, not the strings
it passes to WASI. A malformed module, a module that fails validation, a
link failure, a trap, an uncaught WebAssembly exception and an exhausted
limit all come back as `{error, Error}`. `Error` is a map with a `class`, a
`kind`, a `msg` and a `ctx`. When your host function raises, the runtime
turns that into a trap too.

**Why.** Guest code is input. A runtime that raises on bad input lets a
hostile module crash the process that called it. With values, you decide
what a failure means, with an ordinary `case`.

**Where you see it.**

- Every call returns `{ok, _}` or `{error, Error}`. Match on `class` and
  `kind`. See
  [Guest errors are returned as values](concepts.md#guest-errors-are-returned-as-values).
- `wasm:format_error/1` turns an error into one line for your logs.
- `wasm_script_worker` adds classes of its own (`worker`, `adapter`,
  `runtime`), listed in `wasm_worker_error`.

**What raises on the host side.** The promise covers what the guest
supplies. These come from your own code or configuration, and they are the
known exceptions:

| what you do | what you get |
| --- | --- |
| a network grant the runtime cannot read (`net` in preview 1, `network` in 0.2 and 0.3), such as a rule that is not a `{Protocol, Address, Port}` tuple | the exception `{bad_net_grant, Term}`, raised in your process where the imports are built |
| an argument of the wrong Erlang type, such as an atom for the module bytes of `wasm:load/1` or `wasm:compile/1`, or call arguments that are not a list | the usual `badarg` or `function_clause`, as from any Erlang function |
| `wasm_instance_worker:stop/1` or `info/1`, or `wasm_script_worker:stop/1`, on a worker that has already exited | the usual exit of `gen_server` (`noproc`) |

A few values are not maps. They are still values, but they have no class
and no kind, so match on them as they are:

| from | value |
| --- | --- |
| `wasm:load/1,2`, `wasm:load_file/1`: too many new modules in one second | `{error, {load_rate_exceeded, Rate}}` |
| the same: the cache holds its most modules | `{error, {too_many_modules, Max}}` |
| the same: the cache holds its most bytes | `{error, {module_cache_full, MaxBytes}}` |
| `wasm_script_worker:start_link/2,3`: a `root` the reaper does not have | `{error, {unknown_root, Root, Known}}` |
| the same: `compiled => true` with a finite `fuel` | `{error, {bad_option, compiled, #{fuel => N}}}` |

## Options say what you know, never how to do it

**What it is.** An option states something only you know: a limit, a
deadline, an isolation policy, whether to compile, where to keep files. No
option picks how the runtime does its work, such as a cache shape, a memory
layout, a chunk size, a garbage collection strategy or the shape of
generated code.

**Why.** You can judge your limits; you cannot judge a tactic without
measuring the runtime's internals. An option for a tactic also freezes an
internal detail into the API. When a tactic wins only for some workloads,
the runtime chooses it from what it can observe, or ships the one default
that measures well enough.

**Where you see it.**

- The presets `wasm_limits:untrusted/0` and `wasm_limits:trusted/0`.
- `profile => plugin` or `profile => script` names a kind of workload, not a
  compile tactic. See [The compiled tier](compiled-tier.md).
- The compiled tier compiles only the functions that ran, and splits a large
  module into units by itself.

**A few tactic options exist today.** `compile_shards`, read from the
instance options by `wasm_jit:shard_count/2`, sets how many units a compile
is split into. `compile_sync`, `compile_whole` and `compile_force` exist for
the conformance suites; see
[Compiled tier internals](compiled-tier-internals.md#three-options-that-exist-only-for-conformance).
The collector's thresholds (`gc_alloc_threshold` and the other `gc_*`
settings) are described on the internals page
[Garbage collection](gc.md). None of these is part of the supported API,
and they may change in any release. [Configuration](configuration.md) marks
them as internal.

## Guest data never becomes an atom

**What it is.** No byte a guest supplies is turned into an atom: not the
module bytes, not an export name, not a host name or a path it passes to
WASI.

**Why.** The atom table is shared by the whole node, has a fixed maximum,
and an atom is never freed. A guest that could create one atom per call
would leak memory forever and finally stop the node, and no limit could
prevent it.

**Where you see it.**

- Names are binaries: you call `wasm:call(Inst, ~"run", Args)`, not
  `run`.
- An error's `kind` is always an atom the runtime itself defines. A
  language's own error codes travel as binaries in `ctx`.
- `wasm_prop_SUITE` checks that the number of atoms does not grow with the
  number of different strings a guest sends. See
  [Security](security.md#what-holds-the-boundary).

## Modules are loaded once

**What it is.** `wasm:load/1` decodes and validates a module once per node,
and keeps it in the **module cache**, found by its content hash. Every
instance reads it from there without copying it.

**Why.** The cache keeps modules in `persistent_term`, which is fast to read
but expensive to change: adding or removing an entry makes the BEAM scan
every process. So the cache has three limits, for the whole node:

| limit | default | answer past it |
| --- | ---: | --- |
| `max_module_loads_per_second`, new modules decoded in one second | 50 | `{error, {load_rate_exceeded, 50}}` |
| `max_resident_modules`, modules held at once | 256 | `{error, {too_many_modules, 256}}` |
| `max_resident_module_bytes`, memory they hold together | 2 GiB | `{error, {module_cache_full, Bytes}}` |

Loading bytes that are already in the cache is cheap and is not counted
against the rate. But a request path that loads a module and unloads it
after each request decodes it every time (about 20 ms for a 100 KB Rust
binary), changes the cache twice, and past 50 requests a second it starts to
fail with `load_rate_exceeded`.

**Where you see it.**

- Load at startup and keep the handle. See
  [Load modules once, at startup](embedding.md#load-modules-once-at-startup).
- A server that runs a component per request calls
  `wasm_component:hold/1` once, as [HTTP](http.md) does.
- The three settings are in [Configuration](configuration.md).

## Snapshots are deterministic

**What it is.** A snapshot saves a guest's state after it has started. Every
restore starts from exactly the same bytes.

**Why.** That is what makes a restore cheap, and what makes each request
start from a known state.

**What it means for you.** Any random value or clock time that the guest
read before the capture is in the image. So every request that restores the
image sees the same values, whichever tenant sent it. For CPython this
includes the hash seed. To get new values, capture a new image. Capture only
from trusted initialisation, because whatever happened before the capture is
shared with every request after it.

**Where you see it.**

- `wasm:snapshot/1` and `wasm:restore/3`, and the shared image of a worker
  pool. See [What an image freezes](snapshots.md#what-an-image-freezes).
- [Security](security.md#snapshot-images-are-trusted-the-same-way) says
  who may write the directory where images are kept.

## Read this next

[Concepts](concepts.md) for the words, [Configuration](configuration.md) for
every setting, or [Architecture](architecture.md) to see how the modules fit
together.
