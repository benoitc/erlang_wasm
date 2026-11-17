# Feature and conformance status

This page lists what the runtime implements and its results on the official
WebAssembly specification test suite. Use it to find out whether your module
will run, and roughly what it costs.

How the garbage collector works is in [Garbage collection](gc.md), how the
WASI sandboxes are enforced is in [WASI](wasi.md), and the reasons behind the
runtime's design are in the [design notes](design-notes.md). How each suite
was brought up, and the defects that turned up on the way, are in the record:
`test/audit/CONFORMANCE.md`.

What the conformance figure means, exactly: every assertion of the official
core test suite passes, 65,481 of them, at the commit
`scripts/fetch-suites.sh` pins. That suite is WebAssembly 3.0's, so this is
conformance to the WebAssembly 3.0 core specification. It is not a claim about
every WebAssembly proposal: the threads proposal is implemented and checked by
its own suite (see [Threads](#threads)), and a proposal not named on this page
is not implemented. The Component Model and WASI are not part of the core
specification. What they cover, and what they do not, is in
[Components](components.md), [WASI](wasi.md) and [WASI 0.3](wasi-0-3.md).

## What works

| Area | Status |
| --- | --- |
| Binary decoding, all 12 sections | complete |
| Validation (full algorithm, polymorphic unreachable stack) | complete |
| Structured control flow: `block`, `loop`, `if`, `br`, `br_if`, `br_table` | complete |
| Integer instructions, i32 and i64 | complete |
| Floating point, f32 and f64, including NaN payloads and signed zero | complete |
| Conversions, trapping and saturating | complete |
| Linear memory: loads, stores, `size`, `grow` | complete |
| Bulk memory: `memory.copy`, `memory.fill`, `memory.init`, `data.drop` | complete |
| Tables, `call_indirect`, element segments | complete |
| Reference types: `ref.null`, `ref.is_null`, `ref.func`, table ops | complete |
| Multi-value blocks and results | complete |
| Multiple memories, including `memory.copy` between two of them | complete |
| memory64: 64-bit memories and tables | complete |
| SIMD: `v128` and all 236 vector instructions | complete |
| Relaxed SIMD: all 20 instructions, deterministic profile | complete |
| Threads: shared memories, all 66 atomic instructions, `wait` and `notify` | complete |
| Garbage collection: structs, arrays, `i31`, casts, and a collector | complete |
| Tail calls: `return_call`, `return_call_indirect` | complete |
| Typed function references: `(ref ht)`, `call_ref`, `br_on_null` | complete |
| Exception handling: tags, `throw`, `throw_ref`, `try_table` | complete |
| Sign extension, non-trapping float-to-int | complete |
| Erlang host functions and imports | complete |
| Fuel and call-depth limits | complete |
| Node-wide memory page budget | complete |
| Link-time import type checking (kind, limits, signatures, mutability) | complete |
| Mutable globals shared by reference between instances | complete |
| Module cache keyed by content hash | complete |
| Optional native path resolution, closing the WASI time-of-check-to-time-of-use race ([WASI](wasi.md)) | complete |
| WASI Preview 1: 45 syscalls, capability-based filesystem | complete |
| Runs unmodified Rust `wasm32-wasip1` and `clang -O2` output | complete |
| Text format: `.wat` modules and `.wast` scripts | complete |
| Compiling the most used functions to Core Erlang, with a cache on disk | complete, off by default |
| Snapshots of a started guest: capture, restore one per request, save to files | complete |
| A worker kernel for untrusted guests, with an adapter per language | complete |
| WASI sockets: a capability model, the four standard calls, the client extension | complete |
| The Component Model: decoding, linking several cores, composition, resources | complete |
| The async Canonical ABI: `async func`, `stream<T>` and `future<T>` of any element type, callback and stackful lifts, cancellation, subtasks, `error-context`, backpressure, `stream.forward` and `future.forward` | complete |
| Cooperative threads in a component instance: `thread.new-indirect`, `thread.index`, suspending, yielding, resuming and switching, cancellable or not | complete |
| WASI 0.2: random, clocks, cli, io, filesystem, sockets | complete |
| `wasi:http`: outbound requests and serving an incoming-handler | complete |
| WASI 0.3: cli, clocks, random, filesystem, sockets and `wasi:http`, beside 0.2 in one component ([WASI 0.3](wasi-0-3.md)) | complete |
| An async task that runs on after its call returns, and host imports that take or give a stream or future | complete |
| Preparing a component once for many instances (`wasm_component:prepare/1`) | complete |
| Snapshots of component instances, composed ones too, with WASI stdio and preopens made again per request ([snapshots](snapshots.md)) | complete, in memory only |

## Not implemented

| Area | Why |
| --- | --- |
| Shared-everything threads: `thread.spawn-ref`, `thread.spawn-indirect`, `thread.available-parallelism` | no engine runs them yet, and the specification and wasm-tools write them differently ([why](#shared-everything-threads)); a component that uses one is refused when it is linked, with `unsupported_canon_builtin` and the built-in's name |

## Caching compiled code

Off by default. See [the compiled tier](compiled-tier.md).


## Specification test suite

The tests are read directly from the [upstream test
suite](https://github.com/WebAssembly/testsuite). `wasm_wast` turns a `.wast`
script into a list of commands, and `wasm_spec_runner` runs them. Nothing is
generated and no other tool is needed. To run the conformance tests, fetch
the suite at the commit this project is tested against:

```sh
scripts/fetch-suites.sh
```

The checkout is not copied into this repository. When it is missing,
`wasm_spec_SUITE` skips with a message, so a fresh clone still runs all other
tests. When it is present, the suite compares each test file with a baseline
of known failures.

The scores below cover the 256 core suites listed in
`wasm_spec_manifest:core/0`, which is every suite in the checkout. Every suite
is classified, so the number covers the whole checkout, not a part of it.

| Phase | Pass | Fail | Skip |
| --- | ---: | ---: | ---: |
| decode + validate + execute | 65481 | 0 | 0 |

**Every core assertion passes**, at every phase, and the baseline in
`wasm_spec_SUITE` is empty. The build fails if a failure comes back, *or* if a
baseline entry is no longer needed. So an empty baseline is the strongest
result the suite can report.

Nothing is skipped either: `wasm_spec_runner` runs every command of the
checkout, `assert_exception` and `module definition` included.

The harness and the baseline have both been wrong before, in ways that made
the score look better than it was. How they were caught, and the five
defects the baseline was hiding, are in `test/audit/CONFORMANCE.md`,
sections "What the harness was not checking" and "What the baseline was
hiding".

### SIMD

All 236 vector instructions, and all 59 specification suites, with no baseline
entries: every `assert_invalid` case passes too. A `v128` is a 16-byte
binary, chosen by measurement over a 128-bit integer; the numbers are in
`test/audit/CONFORMANCE.md`, section "SIMD: why a `v128` is a binary".

#### Relaxed SIMD

All 20 instructions, following the specification's **deterministic profile**:
each behaves exactly as its strict counterpart does.

| instruction | the answer chosen, where the proposal permits several |
| --- | --- |
| `i8x16.relaxed_swizzle` | an index of 16 or more reads as zero |
| `i32x4.relaxed_trunc_*` | NaN becomes zero, out of range saturates |
| `relaxed_madd`, `relaxed_nmadd` | unfused: the product is rounded before the addition |
| `relaxed_laneselect` | a bitwise select, so a partial mask mixes both operands |
| `f32x4`/`f64x2` `relaxed_min`, `relaxed_max` | IEEE, so a NaN operand propagates |
| `i16x8.relaxed_q15mulr_s` | saturating, so -32768 squared gives 32767 |
| `relaxed_dot_i8x16_i7x16_s` | both operands read as signed |

The proposal exists so that an engine can use one machine instruction where
the strict rules would need several. A pure Erlang interpreter does not use
vector hardware, so different answers would bring no speed. They would only
make results differ between machines. Here the same module gives the same
answer on every machine.

`wasm_relaxed_simd_SUITE` asserts each choice on an input where the permitted
answers differ, because the conformance suite writes them as `either` and would
accept any of them. It also covers the four truncation instructions outright:
upstream's `i32x4_relaxed_trunc.wast` is eight lines containing a module and no
assertions at all, so conformance checks nothing about their results.

### Exception handling

Tags, `throw`, `throw_ref`, `try_table` and `exnref`.

**A trap is not catchable.** Traps stay `wasm_error` throws and pass straight
through every handler, so a module cannot hide a division by zero or an
out-of-bounds access with `catch_all`. The two paths are separate on purpose and
`wasm_exception_SUITE` asserts it, because a change merging them would still
pass every other test.

A `throw` crosses instance and host-function boundaries: an exception thrown
in an imported function is caught by its caller's `try_table`.

### Tail calls

`return_call` and `return_call_indirect` do not grow the call depth: the
callee returns straight to the original caller, so a million-deep tail call
does not exhaust `max_depth`.

A tail call into *another instance* can still grow the stack. The callee uses
its own memory and globals, so it cannot reuse this frame. It is called
normally, and its results become the caller's results. The behaviour is the
same, except for the stack space.

### memory64

A memory or table may declare `i64` as its index type.

Index types must match exactly between an import and its export. Minimum and
maximum sizes do not need to match exactly; they only need to allow at least
as much. A 32-bit memory handed to a
module expecting a 64-bit one would truncate every address that module computes.

### Shared tables and instance-carrying references

Imported tables are shared by reference, as imported memories already were.
A `funcref` carries the instance that defined it, so a reference read from a
shared table calls the right function, against its own instance's memory and
globals.

## Compiling to Core Erlang

Off by default. It made a language runtime 8.4 times faster, and did not
change a plugin. See [the compiled tier](compiled-tier.md) for what it
compiles, what turns it off, how to keep the result across restarts, and how
to read the code it generates.

```erlang
{ok, I} = wasm:instantiate(M, Imports, #{compile => true}).
```

## What it costs

On Apple Silicon, OTP 29: decoding and validating a small module takes about
13 us, instantiating it about 3 us, and a call round trip about 0.4 us. The
interpreter dispatches about 5 ns per instruction. It gives up the scheduler
like ordinary Erlang code, so a guest in an infinite loop does not stop other
processes from running. The tables, how they were taken, and what adding
garbage collection support cost code that does not use it, are in
`test/audit/PERF.md`, section "The feature page's benchmarks (from
docs/features.md)". [Tuning a worker host](tuning.md) is about the costs a
worker host sees.

## Real toolchain acceptance

An unmodified `rustc --target wasm32-wasip1 -O` build runs from start to end,
called through `_start` as a WASI command. This runs Rust's whole startup
code, not only the syscalls that a small hand-written test would use. It
needs 13 WASI imports (`args_get`, `args_sizes_get`, `environ_get`,
`environ_sizes_get`, `fd_close`, `fd_fdstat_get`, `fd_filestat_get`,
`fd_prestat_dir_name`, `fd_prestat_get`, `fd_read`, `fd_write`, `path_open`,
`proc_exit`), and all of them are implemented.

```text
hello from rust on wasm
args: ["prog", "--verbose"]
MODE=production
fib(20)=6765
file: contents of note
escape refused: uncategorized error
this goes to stderr
_start -> exit code 7
```

The escape line matters: that is
`std::fs::read_to_string("/data/../secret/key.txt")` being refused, attempted by
Rust's own standard library through the preopen table it built from
`fd_prestat_*`. The module never learns the host path behind `/data`. Rust
reports it as "uncategorized" because its `ErrorKind` has no name for
`ENOTCAPABLE`.

The committed 120 KB stripped build compiles in 4.1 ms and instantiates in
103 us.
`scripts/build-rust-fixture.sh` rebuilds it; the artefact is committed so the
test runs without a Rust toolchain.

## Real usage

Two complete examples, both in `examples/` and both tested by
`wasm_examples_SUITE`. They show two different *kinds* of guest.

| | `plugin_worker` | `qjs_worker` |
| --- | ---: | ---: |
| guest | a Rust plugin, compiled | QuickJS, interpreting a script |
| module | 46 KB | 1.8 MB |
| compile, once | 1.6 ms | 310 ms |
| instantiate, per request | 540 us | 3.2 ms |
| a trivial request | under 1 ms | 238 ms |
| levels of interpretation | one | two |

The second column is the more interesting one. A real 1.8 MB QuickJS build,
which was not written for this runtime, decodes and validates in 310 ms,
instantiates in 3.2 ms and evaluates `print('hello')` in 238 ms end to end. A
hundred thousand iterations of a JavaScript loop take about 7 s, which is the
real cost of running one interpreter inside another, and the reason
`plugin_worker` exists.

That module is also an independent check of the WASI socket extension: it
imports twelve of those calls with the signatures `wasi_sock_ext_SUITE`
asserts, including the two-argument `sock_accept`.

The first run of it crashed the Erlang VM, on a cost that only shows at size.
What it was, and the two changes that followed, are in
`test/audit/CONFORMANCE.md`, section "What running QuickJS first found".

## Testing

[Testing](contributing/testing.md) lists the suites behind the claims on
this page and the properties they hold, and [Where things are](map.md) has
the suites for each area.

## Threads

Shared memories, all 66 instructions of the `0xFE` opcode space, and
`memory.atomic.wait`, which really blocks an Erlang process until another
process notifies it. The `atomic` suite passes in full: 297 assertions, no
skips.

Atomic accesses are sequentially consistent, and `memory.atomic.wait` blocks
in a `receive`, so a notify can never be lost. How the atomic instructions
are built on the `atomics` arrays that hold linear memory is in
[Memory](memory.md#atomic-instructions-and-wait).

### An agent is an Erlang process

The proposal has no instruction that creates a thread. The embedder creates the
agents (threads): instantiate the same module more than once over one shared
memory, each instance in its own process. `memory.atomic.wait` then blocks that
process in a `receive` and `notify` sends it a message, so a waiting agent costs
the same as a waiting Erlang process, and the scheduler can run other processes.

```erlang
{ok, Mem} = wasm_memory:new(#limits{min = 1, max = 4, shared = true}),
Agents = [spawn_link(fun() ->
              {ok, Inst} = wasm:instantiate(Mod, #{{~"env", ~"mem"} => Mem}),
              wasm:call(Inst, ~"run", [])
          end) || _ <- lists:seq(1, 8)].
```

**A shared memory outlives the process that created it**, and this is why the
code above works: the coordinator may exit while its agents continue. No process
holds the memory, so no process exit frees it. `wasm_memory:free/1` is what
releases it.

`wasm_threads_SUITE` checks what the single-agent specification suite cannot:
sixteen processes adding to one address, a contended compare and exchange,
and a waiter that wakes, times out or does not wait. What it found is in
`test/audit/CONFORMANCE.md`, sections "Threads: the shared memory that
outlived its creator" and "Threads: what `wasm_threads_SUITE` adds".

### Two suites left out, and why

The threads proposal includes its own copy of the whole core suite, and that
copy is older than multiple memories and multiple tables. `imports-threads` and
`memory-threads` assert that a module with two memories is invalid, which
contradicts a feature this runtime implements: they fail because that copy is
old, not because anything is missing. The instructions and shared-memory rules
the proposal actually adds are in `atomic` and `exports-threads`, both of which
pass in full.

### Shared-everything threads

Three Component Model built-ins are left out on purpose. `thread.spawn-ref`
starts a thread from a function reference, `thread.spawn-indirect` starts one
from a slot in a table, and `thread.available-parallelism` tells the guest how
many threads can run at once. A component that uses one is refused when it is
linked. The error is `unsupported_canon_builtin`, and its context names the
built-in, for example `builtin => <<"thread.spawn-ref">>`.

They are left out because there is nothing yet to check an implementation
against:

- **No engine runs them.** wasmtime refuses all three, and lists the core
  shared-everything-threads proposal as not implemented.
- **The specification and the toolchain write them differently.** The
  Component Model's binary format puts a `shared` flag before each built-in's
  operands. wasm-tools writes them without it. A decoder cannot accept both,
  because the flag and a type index of 0 or 1 are the same bytes.
- **The parallel form needs a draft proposal.** With the `shared` flag, the
  new thread runs in parallel with the others. It needs shared types, shared
  tables and shared function references from the core proposal, which is
  still a draft. This runtime refuses shared tables.
- **There are no tests.** The Component Model's own reference tests have no
  case for any of the three.

They come back when wasmtime runs them and wasm-tools writes the
specification's format. Without the `shared` flag, a spawned thread is a
cooperative one, so that form can reuse the cooperative threads this runtime
already has: `thread.new-indirect` followed by `thread.resume-later`. The
parallel form also waits for the core proposal to settle enough to implement
shared tables and shared function references.

## Read this next

[Upgrading](upgrading.md) and the [changelog](../CHANGELOG.md).