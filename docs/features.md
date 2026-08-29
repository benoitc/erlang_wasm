# Feature and conformance status

This page records what the runtime implements, how it scores against the
official WebAssembly specification test suite, and what it measures. Use it to
find out whether a module you care about will run, and what it will cost.

Status as of **0.1.0**.

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
| Optional native path resolution closing the WASI TOCTOU window | complete |
| WASI Preview 1: 44 syscalls, capability-based filesystem | complete |
| Runs unmodified Rust `wasm32-wasip1` and `clang -O2` output | complete |
| Text format: `.wat` modules and `.wast` scripts | complete |
| WASI sockets: a capability model, the four standard calls, the client extension | complete |

## Not implemented

| Area | Why |
| --- | --- |
| The component model and WASI Preview 2 | Preview 1 is what toolchains ship today; Preview 2 is a different interface, not a bigger one |

## Caching compiled code

Off by default. See [the compiled tier](compiled-tier.md).


## Specification test suite

Suites are read straight from the [upstream test suite](https://github.com/WebAssembly/testsuite):
`wasm_wast` turns a `.wast` script into a command list and `wasm_spec_runner`
replays it. Nothing is generated and no tool is needed, so running conformance
is one clone away:

```sh
git clone --depth 1 https://github.com/WebAssembly/testsuite.git
```

The checkout is not vendored. `wasm_spec_SUITE` skips with that message when it
is absent, so a fresh clone still runs everything else, and gates on a per-suite
baseline when it is present.

Scores below are over the 256 core suites listed in `wasm_spec_manifest:core/0`,
which is every suite in the checkout. Nothing is left unclassified, so the
number covers what is there rather than a subset of it.

| Phase | Pass | Fail | Skip |
| --- | ---: | ---: | ---: |
| decode + validate + execute | 65481 | 0 | 0 |

**Every core assertion passes**, at every phase, and the baseline in
`wasm_spec_SUITE` is empty. The stale-baseline guard fails the build if a
failure reappears *or* if an entry becomes unnecessary, so an empty map is the
strongest statement the suite can make.

Nothing is skipped either. The 22 that used to be were 18 `assert_exception`
commands and 4 `module_definition` commands, and neither belonged to a proposal
outside this runtime's scope: exception handling is implemented, and
`module definition` and `module instance` are how `instance.wast` checks that
instantiation is generative. Both were harness gaps, and `wasm_spec_runner` now
runs them.

### What the harness was not checking

A conformance number is only worth its arithmetic if every assertion counted as
passing actually compared something. Twice now it has not.

Bringing relaxed SIMD into scope meant looking at how an expected value the
matcher does not recognise was handled. It answered "skip" for the assertion
*and every value after it in the same assertion*, and the assertion was tallied
as a **pass**. Tightening that to report it as unchecked moved **116 assertions
out of the pass column** across seventeen core suites.

They were not relaxed SIMD's. The harness could compare a *null* external
reference and not a particular one, so every assertion naming `(ref.extern 1)`
in `table_fill`, `table_grow`, `br_table` and a dozen others was passing without
looking. Teaching it the non-null reference forms brought 109 of them back as
genuine checks and surfaced one real defect: a host reference in the internal
hierarchy, `(ref.host N)`, had no decoding at all, so `extern.wast` was
exercising `extern.convert_any` against a placeholder.

The totals are unchanged at 63,231 and 1,180. What changed is that all of them
now check something.

### What the baseline was hiding

A baseline is only honest if each entry fails *because of* the proposal it
names. Reading this one back to its causes found five defects wearing a
proposal's name, all now fixed and pinned by `wasm_linking_SUITE`:

- **An import of the wrong kind raised out of the runtime.** Handing a table to
  a module that imports a memory reached `wasm_memory:limits/1` and died with a
  `function_clause`, reported as an internal error. Every failure is supposed to
  be a value, and an embedder passes bare Erlang terms, so this was a hole in
  the property the whole library rests on.
- **An imported mutable global was copied, not shared.** Two modules linked to
  the same global each got their own, and diverged silently after the first
  write. The same defect imported tables had.
- **Import mutability was never checked**, so a module could import a mutable
  global as immutable or the reverse.
- **Function import signatures were never checked.** An export from another
  instance was adopted with whatever signature the importer declared.
- **A `funcref` global failed to link**, because the shape check still expected
  the bare two-element reference that instance-carrying `funcref`s replaced.

Only mutable globals became reference cells, decided from the module and
resolved into the instruction when the IR is built. Reading an ETS row measured
17.7 ns against 1.9 ns for a tuple element, and compiler output reads its shadow
stack pointer on nearly every function entry, so an ordinary `global.get` still
reads a tuple.

Every entry in that baseline names a specific unimplemented proposal or a
stated limitation. An unattributable failure is treated as a defect to fix, not
a number to record, and the suite fails the build if the baseline becomes too
generous.

### SIMD

All 236 vector instructions, and all 59 specification suites, with no baseline
entries: every `assert_invalid` case passes too.

**A `v128` is a 16-byte binary.** The alternative was a 128-bit integer, and
the choice was measured. Per operation, 200,000 iterations, minimum of five:

| operation | binary | 128-bit integer |
| --- | ---: | ---: |
| `i32x4.add` | **11.8 ns** | 126.0 ns |
| `i8x16.add` | **14.6 ns** | 610.6 ns |
| `f32x4.mul` | **76.9 ns** | 296.7 ns |
| `i32x4.extract_lane` | **5.0 ns** | 17.4 ns |
| `i8x16.shuffle` | **154 ns** | 497 ns |
| `v128.and` | 11.9 ns | **10.6 ns** |

Bit syntax truncates each field to its declared width, so lane wrapping is
free where the integer form needs a mask per lane, and a binary is built in one
allocation where a shift-and-or chain allocates an intermediate bignum per
lane. The integer form wins only on `v128.and`, and only by 12%.

**Lanes are matched, not iterated.** The obvious `binary_to_list`,
`lists:zip`, comprehension route costs 182 ns for `i8x16.add` against 14.6 ns
for a single 16-field pattern; a binary comprehension with a zip generator is
worse still at 253 ns. Writing all 236 instructions out at full width would be
some thousands of lines, so the lane split is done once per shape and the
operations are ordinary funs, which costs 1.4x to 1.8x against inlining
(`i8x16.add` at 30.3 ns) and is still six times better than iterating.

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

The proposal exists so an engine can emit one machine instruction where the
strict semantics would need several. There is no vector hardware underneath a
pure Erlang interpreter, so varying buys nothing and costs reproducibility: the
same module gives the same answer on every machine.

`wasm_relaxed_simd_SUITE` asserts each choice on an input where the permitted
answers differ, because the conformance suite writes them as `either` and would
accept any of them. It also covers the four truncation instructions outright:
upstream's `i32x4_relaxed_trunc.wast` is eight lines containing a module and no
assertions at all, so conformance checks nothing about their results.

**Float lanes are not `:32/float` fields.** Erlang cannot represent NaN or
Infinity as a float and those bit patterns do not match a float field at all,
so a lane holding one would raise rather than compare unequal. Lanes are
extracted as integer patterns and converted through `wasm_num`, which is the
same hybrid representation the scalar instructions use, and so gets NaN
propagation and quieting for free.

The two rules that bite regardless of representation: a lane comparison yields
all-ones rather than 1, which is what makes it a mask for `v128.bitselect`; and
`pmin`/`pmax` are not `min`/`max`, being specified as "return the second
operand if the comparison is true, otherwise the first", which propagates the
first operand's value when either is NaN.

### Typed function references

Value types gained the general reference form `{ref, Null, HeapType}`, with
`funcref` normalised to `{ref, null, func}` at the decoder. There is
deliberately one spelling per type: two terms for one type is how a subtyping
bug gets in, since every comparison would have to remember they are equal and
the one that forgot would silently accept or reject the wrong modules.

**Subtyping did not cost the fast path.** It lives in `pop_expect/2`, the
single place two value types are compared, and that function's existing
equality clause stays first. Numeric and vector types therefore keep the
immediate-word comparison; only reference types fall past it. That is why
`wasm.hrl` can still describe value types as compared by equality.

Non-nullable locals get definite-assignment analysis. An assignment made
*inside* a control frame does not survive it: only one arm of an `if` runs, and
a `block` may be branched out of before its assignments happen. The
specification is deliberately this conservative, and the tests pin it.

Recursive type groups are flattened. Without garbage collection there is no
recursion to resolve and no declared subtyping, so a `rec` group is exactly its
members listed in order. That is exact for everything except telling two
structurally identical types in one group apart, which is the remaining `tag`
failure.

### Exception handling

Tags, `throw`, `throw_ref`, `try_table` and `exnref`.

**Unwinding fell out of frames being explicit.** `run/3` already carries the
control stack as a list and each call frame holds the caller's control stack, so
a throw walks outwards through both. It is the same traversal `branch/3` does,
searching for a handler rather than counting to a depth, and it needs no Erlang
exceptions inside a single instance.

Crossing an instance boundary does need one, because a foreign call is a nested
`wasm_exec:call/5`. There the exception travels as an Erlang throw and is put
back into the interpreter's own unwinding at the host-call boundary, so a
`throw` in an imported function is caught by its caller's `try_table`.

**A trap is not catchable.** Traps stay `wasm_error` throws and pass straight
through every handler, so a module cannot swallow a division by zero or an
out-of-bounds access with `catch_all`. The two paths are separate on purpose and
`wasm_exception_SUITE` asserts it, because a change merging them would still
pass every other test.

### Tail calls

`return_call` and `return_call_indirect`, which fall out of frames being
explicit: `enter/5` pushes a frame, and a tail call runs the callee's body
against the frame list unchanged, so the callee returns straight to the
original caller and depth does not grow.

Both specification suites have exactly one executable module, and both use
typed function references, so all 95 of their execution assertions are skipped
until that proposal lands; their `assert_invalid` cases do run and pass. What
the fixtures cannot show, `wasm_tailcall_SUITE` does: a million-deep self tail
call, a million-deep mutual one, the same through
`return_call_indirect`, and the same program with a plain `call` to show it
does exhaust `max_depth`. Without that last case the others would prove
nothing.

A tail call into *another instance* is not space safe. The callee runs against
its own memory and globals, so it cannot reuse this frame; it is called
normally and its results become the caller's, which is observably the same
apart from the space bound.

### memory64

A memory or table may declare `i64` as its index type, which changes far more
than the decoder. The index type reaches the operand types of every memory and
table instruction, the ceilings the validator enforces, how an operand is read
as unsigned at run time, and whether one module may import another's memory.

The interpreter must not pay a lookup per access to find out which it is dealing
with, so the width is resolved once when the IR is built and tagged onto the
instruction. A 32-bit memory keeps exactly the shape it had, so nothing on the
common path changes.

Three things were only reachable once 64-bit operands existed:

- **The limits flags byte is a bit set**, not an enumeration. Bit 2 is the index
  type, so a 64-bit memory with a maximum encodes as `0x05`. Matching whole
  bytes worked while only `0x00` and `0x01` existed.
- **`memory.init` and `memory.copy` took their operands in the wrong order.**
  The validator's `pop_expects/2` takes types in push order, and the lists were
  written in pop order. Invisible while every operand was `i32`.
- **A `table.grow` had no ceiling but the node's.** A table declared
  `(table 0 2 externref)` grew to any size, because the declared maximum was
  never carried anywhere the instruction could see it. It now travels inside the
  table handle, which is also what lets a module that *imported* the table be
  bound by the defining module's declaration.

Index types must match exactly across an import boundary, unlike minima and
maxima where "at least as permissive" is the rule. A 32-bit memory handed to a
module expecting a 64-bit one would truncate every address that module computes.

### Shared tables and instance-carrying references

Imported tables are shared by reference, as imported memories already were.
Two things were needed, and only the first is obvious:

`wasm_table` holds contents in a store shared between instances, behind the
same version-checked cache `#mut{}` uses, so reads stay cheap and a write by
any holder is visible to all of them.

More subtly, a `funcref` now carries the instance that defined it. As a bare
index it was meaningless outside its own module: a reference written into a
shared table by module B, read back by module A, resolved against *A's*
function space and silently called the wrong function. Because a reference
carries its instance, a cross-module indirect call also runs against the
callee's own memory and globals, rather than smuggling one module's code into
another's state.

Nothing is skipped: every command in every suite of the checkout is either
executed or asserted against.

## Compiling to Core Erlang

Off by default, and worth 8.4x on a language runtime and flat on a plugin. See
[the compiled tier](compiled-tier.md) for what it covers, what turns it off, how
to cache the result across restarts, and how to read the code it generates.

```erlang
{ok, I} = wasm:instantiate(M, Imports, #{compile => true}).
```


## Benchmarks

Measured on Apple Silicon, OTP 29, via `rebar3 bench`. Numbers are indicative,
not a leaderboard entry.

**On measurement conditions.** The machine these were taken on carried a load
average around 30, and repeated runs of the same code varied by up to 3x.
Absolute figures here should be read as an order of magnitude. Where a *change*
is claimed, it was measured by interleaving both versions in a single VM across
several rounds and taking the minimum of each arm, so that load drift affects
both equally; single before-and-after runs on a loaded box are not evidence and
are not quoted.

### Pipeline

| Operation | Cost |
| --- | ---: |
| decode | 6.3 us |
| validate | 5.6 us |
| compile (decode + validate) | 13.2 us |
| instantiate | 2.9 us |
| call round trip | 0.40 us |

Instantiation at 1.5 us is the number that matters for plugin and
request-per-instance workloads, where a runtime is judged on how cheaply it can
create and discard an instance rather than on steady-state throughput.

### Execution

| Operation | Cost |
| --- | ---: |
| interpreter dispatch | 4.9 ns/instruction (206 M instr/s) |
| memory load i32, aligned | 18.2 ns |
| memory store i32, aligned | 48.2 ns |
| memory store i64, aligned | 32.7 ns |
| memory load i8, unaligned | 18.1 ns |
| `memory.fill` | 0.43 GB/s |

An i32 store costs more than an i64 store because `atomics` granularity is 64
bits, so a 32-bit write is a read-modify-write while an aligned 64-bit write is
a single operation.

**What garbage collection cost the paths that do not use it.** Measured before
the work and again after, minimum of three runs each:

| Path | Before | After |
| --- | ---: | ---: |
| interpreter dispatch | 4.9 ns/instr | 4.9 ns/instr |
| call round trip | 0.40 us | 0.40 us |
| instantiate | 3.07 us | **2.93 us** |
| memory load i32 | 16.8 ns | 18.2 ns |
| compile | 11.8 us | 13.2 us |

Three regressions were found this way and fixed rather than accepted:

- **Dispatch had slowed 18%.** The new instructions were inserted early in the
  interpreter's clause list, so every common instruction was tested against
  forty new patterns first. Moving them after the hot ones restored it exactly.
- **Instantiate had slowed 33%**, because the validation context is rebuilt per
  instance and canonicalising interns every recursive type group. It is now
  memoised against the last module seen, which is why it ends up *faster* than
  before. The first attempt keyed a cache on `phash2` of the module and made it
  worse still: hashing a large module costs more than the work it saved.
- **Memory access had slowed 15%**, because the page count moved behind an
  accessor. Inlining it and keeping the private memory's clause a plain record
  match recovered most of it.

Two costs remain and are real. Memory access is 1.4 ns slower, the price of a
memory being able to be shared at all. Compile is 1.4 us slower, which is
canonicalisation: a module's recursive type groups are interned once so that
type identity holds across modules.

### Scheduler responsiveness

The result that distinguishes this from a runtime behind a NIF. An unrelated
Erlang process measures its own message round-trip latency while WebAssembly
infinite loops saturate every scheduler.

The measurement is **against a control**: the same number of pure-Erlang busy
loops. Comparing against idle instead would measure what saturating fourteen
schedulers costs and call the answer a property of this runtime.

| Condition | p99 message latency |
| --- | ---: |
| idle | 1 us |
| 14 pure-Erlang busy loops (control) | 6-246 us |
| 14 WebAssembly infinite loops | 2-153 us standalone, 11.4 ms under Common Test |

The two arms overlap when measured the same way, which is the point: the
interpreter yields like ordinary Erlang code. Every dispatch step is an Erlang
function call and therefore consumes a reduction, and an infinite `loop` runs in
**constant space** (986 words, flat, at 780M reductions per second), so there
is no heap growth to pause on either. A runtime called through a NIF would not
answer the ping at all until the invocation finished.

Two honest caveats. The spread is wide: repeated runs of the *same* arm ranged
from 2 us to 1005 us, so any single before-and-after pair here can show whatever
you want it to, and an earlier draft of this section reported a 40x regression
that was one noisy sample. And the same measurement under Common Test
reproducibly reports 11.4 ms for the WebAssembly arm while its Erlang control
reports 6 us; that gap is unexplained and is not reproduced standalone.
`scheduler_stays_responsive/1` now takes the minimum of several rounds per arm
and logs both, rather than asserting against idle with a bound loose enough to
hide a real 49 ms block.

## Real toolchain acceptance

An unmodified `rustc --target wasm32-wasip1 -O` build runs end to end, entered
through `_start` under the WASI command model. That path exercises Rust's whole
startup sequence, not just the syscalls a hand-written probe would touch: it
needs 13 WASI imports (`args_get`, `args_sizes_get`, `environ_get`,
`environ_sizes_get`, `fd_close`, `fd_fdstat_get`, `fd_filestat_get`,
`fd_prestat_dir_name`, `fd_prestat_get`, `fd_read`, `fd_write`, `path_open`,
`proc_exit`), and all of them are implemented.

```
hello from rust on wasm
args: ["prog", "--verbose"]
MODE=production
fib(20)=6765
file: contents of note
escape refused: uncategorized error
this goes to stderr
_start -> exit code 7
```

The escape line matters: that is `std::fs::read_to_string("/data/../secret/key.txt")`
being refused, attempted by Rust's own standard library through the preopen
table it built from `fd_prestat_*`. The module never learns the host path
behind `/data`. Rust reports it as "uncategorized" because its `ErrorKind` has
no name for `ENOTCAPABLE`.

A 98 KB stripped build compiles in about 20 ms and instantiates in about 11 ms.
`scripts/build-rust-fixture.sh` rebuilds it; the artefact is committed so the
test runs without a Rust toolchain.

## Real usage

Two worked embeddings, both in `examples/` and both exercised by
`wasm_examples_SUITE`, chosen to be the two *shapes* rather than two of one.

| | `plugin_worker` | `script_worker` |
| --- | ---: | ---: |
| guest | a Rust plugin, compiled | QuickJS, interpreting a script |
| module | 46 KB | 1.8 MB |
| compile, once | 14 ms | 300 ms |
| instantiate, per request | 4 us | 12 ms |
| a trivial request | under 1 ms | 238 ms |
| levels of interpretation | one | two |

The second is the more interesting number. A real 1.8 MB QuickJS build, which
has never heard of this runtime, decodes and validates in 300 ms, instantiates
in 12 ms and evaluates `print('hello')` in 238 ms end to end. A hundred
thousand iterations of a JavaScript loop take about 7 s, which is the honest
cost of stacking two interpreters and the reason `plugin_worker` exists.

That module is also an independent check of the WASI socket extension: it
imports twelve of those calls with the signatures `wasi_sock_ext_SUITE`
asserts, including the two-argument `sock_accept`.

### What running it first found

Nothing here had ever run a large module written by somebody else, and the
first one that was tried aborted the emulator:

```
ets_alloc: Cannot reallocate 18446744060576004240 bytes  (2^64 minus ~3 GB)
```

A function reference carried its whole defining instance, and an instance holds
the module's compiled functions: 19.5 MB flat, per reference, with 1036 of them
in the table. Published to the engine store, where `ets:insert` copies without
preserving sharing, that is 19.8 GB. The cost was `table entries x module size`,
so no fixture here was large enough to show it.

Two changes followed, and `wasm_scale_SUITE` now pins both from text, with
nothing to download:

- **A reference names its instance rather than carrying it.** The hot path
  already compared only ids, so it is unchanged; a foreign call resolves the id
  through the calling process's own dictionary, swept so that destroyed
  instances do not accumulate.
- **A function is lowered the first time it is called**, above 256 functions per
  module. Instantiating QuickJS went from 78 ms to 12 ms and a script from
  752 ms to 238 ms. Below the threshold everything is lowered up front as
  before, because deferring cost a small module 16% of a call round trip and
  buys it nothing.

## Testing

| Suite | What it covers |
| --- | --- |
| `wasm_spec_SUITE` | the official suite, gated per suite against a baseline |
| `wasm_prop_SUITE` | totality, atom safety, memory model equivalence, LEB128 round trip |
| `wasm_bench_SUITE` | the tables above, plus the responsiveness assertion |
| `wasm_worker_SUITE` | limits actually bound, tested through `examples/wasm_worker` |
| `wasi_SUITE` | WASI syscalls, and one case per filesystem escape technique |
| `wasi_nif_SUITE` | the native backend, including the symlink-swap race |
| `wasi_net_SUITE` | the network grant on its own, with no sockets in it |
| `wasi_sock_SUITE` | the four standard socket calls, and readiness |
| `wasi_sock_ext_SUITE` | the client extension, layouts built byte by byte |
| `wasi_net_escape_SUITE` | one case per network escape route |
| `wasm_num_SUITE` | numeric edge cases, each naming the rule it enforces |
| `wasm_native_SUITE` | a `clang -O2` module: recursion, memory, indirect calls |
| `wasm_rust_SUITE` | a real Rust `std` binary through `_start`, sandbox included |
| `wasm_lang_SUITE` | a real 1.8 MB QuickJS build, evaluating JavaScript |
| `wasm_scale_SUITE` | what only breaks at size: big tables, deferred lowering |
| `wasm_examples_SUITE` | both worked examples, run as their documentation says |

The properties worth naming:

- **Totality.** No binary, however hostile, produces anything but `{ok, _}` or a
  structured `{error, _}`. Verified over random binaries and over valid modules
  mutated at the byte level.
- **No atom creation.** Decoding arbitrary input never moves the atom count. The
  atom table is node-wide and never reclaimed, so one reachable
  `binary_to_atom` on module data would be a remote node kill.
- **Memory equivalence.** Random sequences of store, fill, copy and grow against
  the `atomics` backend agree byte for byte with a plain binary model. The same
  property will validate the optional native backend when it arrives.

## Threads

Shared memories, all 66 instructions of the `0xFE` opcode space, and
`memory.atomic.wait` that genuinely blocks an Erlang process until another
notifies it. The `atomic` suite passes in full: 297 assertions, no skips.

**The storage was already atomic.** Linear memory is chunked `atomics` arrays,
so an eight-byte aligned atomic load is the same single `atomics:get` an
ordinary one is. Narrower accesses are a *field* of a 64-bit word, so writing
one means reading the word, replacing the field and writing it back; those go
through `atomics:compare_exchange` and retry. A read-modify-write is that same
loop with the arithmetic inside it, which is what makes it one indivisible step
rather than a load and a store that usually work.

**`wait` is a `receive`.** On other runtimes this is a futex, with the famous
hazard that a waiter must check a value and then sleep, and a notifier landing
between those two steps signals nobody. Here the waiter registers *before* it
re-reads the value, so a notify arriving afterwards lands in its mailbox and
`receive` finds it either way. A mailbox is a queue rather than a signal that
can be missed, which is the one part of this proposal the BEAM makes easier
rather than harder.

**Nothing reorders.** `atomics` is sequentially consistent, so `atomic.fence`
has nothing to do and the relaxed memory model the proposal permits is not
exploited. An implementation that reordered would be faster and would also make
the ordering bugs in guest programs unreproducible.

### An agent is an Erlang process

The proposal has no instruction that creates a thread. Agents are the
embedder's to make: instantiate the same module more than once over one shared
memory, each instance in its own process. `memory.atomic.wait` then blocks that
process in a `receive` and `notify` sends it a message, so a parked agent costs
what a parked Erlang process costs and the scheduler is free to run others.

```erlang
{ok, Mem} = wasm_memory:new(#limits{min = 1, max = 4, shared = true}),
Agents = [spawn_link(fun() ->
              {ok, Inst} = wasm:instantiate(Mod, #{{~"env", ~"mem"} => Mem}),
              wasm:call(Inst, ~"run", [])
          end) || _ <- lists:seq(1, 8)].
```

**A shared memory outlives the process that created it**, which is what makes
that shape work: the coordinator above may exit while its agents carry on. It
is held manually rather than by any process, so nothing about a process exiting
releases it. `wasm_memory:free/1` is what releases it.

That was not true at first. The memory was charged to whichever process created
it, so the node's page accounting fell to zero while the memory was still in
use, and the published chunk tuple was dropped, so growing it afterwards failed.
Both are fixed and `wasm_threads_SUITE` pins the pattern: a coordinator makes
the memory, hands it over, exits, and the memory stays readable, stays charged
and still grows.

`wasm_threads_SUITE` is the part conformance cannot reach, because the
specification suite runs one agent. Sixteen processes each add one ten thousand
times to the same address and the total must be exactly 160,000; a compare and
exchange contended by sixteen processes must admit exactly one winner; a waiter
must wake, time out, or answer "not equal" without parking. It carries its own
control: the same arithmetic written with an ordinary load, add and store, which
is asserted to **lose** updates. Without that, the atomicity test would pass
just as well against an implementation that was not atomic at all.

### Two suites left out, and why

The threads proposal ships its own copy of the whole core suite, and that copy
predates multiple memories and multiple tables. `imports-threads` and
`memory-threads` assert that a module with two memories is invalid, which
contradicts a feature this runtime implements: they fail because the snapshot is
old, not because anything is missing. The instructions and shared-memory rules
the proposal actually adds are in `atomic` and `exports-threads`, both of which
pass in full.

Two real defects surfaced from those suites before they were set aside: a shared
memory did not link against a shared import (sharing has to match exactly, in
both directions, and was not compared at all), and `wasm_spectest` had no shared
memory to import.

## Garbage collection

Objects cannot ride on BEAM garbage collection. A struct is mutable and two
references must both see a write, so it cannot be a value copied into each
holder; it may reference other objects cyclically, so it cannot be an immutable
term rebuilt on each write either. The BEAM's only *traced* mutable container is
`atomics`, which holds integers; ETS and `persistent_term` are mutable but
invisible to Erlang's collector. So the object graph lives in a store this
runtime owns, and this runtime collects it.

That is affordable here for a reason specific to this design: **the interpreter
owns all execution state explicitly.** Between calls the operand stack is empty,
so the roots are enumerable: the globals, the tables and the passive element
segments of every instance sharing the store, plus whatever the embedder is
holding. Tracing from there needs no stack maps, no safe points and no
cooperation from the compiler that produced the module. A runtime keeping
execution state on the C stack could not do this.

Finding all of those took several goes, and each one that was missing is a way
to free a live object. They are listed under *Roots that were not roots* below,
with the test that pins each.

`i31` is not an object. It is an immediate that allocates nothing, which is the
point of the type.

### What it costs

Run these yourself with `rebar3 bench`, which runs `wasm_gc_bench_SUITE`. Every
number below is a minimum of five rounds, and the arms that need one have a null
arm beside them. Set `WASM_BENCH_FULL=1` for the 10^6 sizes.

**A mutating call used to cost the whole heap.** `wasm_instance:set_mut/2`
writes the `#mut{}` into ETS, ETS copies on insert, and the object store sat
inside it, so one `struct.set` copied every object in the heap. The store is now
a handle in the *immutable* half of the instance and the tables it names are
mutated in place, so a field write leaves the state term untouched:

| heap | `touch` (one `struct.set`), store in `#mut{}` | store as a handle |
| ---: | ---: | ---: |
| 1,000 | 20.7 us | **0.23 us** |
| 10,000 | 199.0 us | **0.22 us** |
| 100,000 | 1993.6 us | **0.21 us** |

19.7 ns of write-back per object in the heap, per mutating call, gone. The cost
no longer depends on heap size at all.

Watch for this when writing a benchmark against it. The write-back skip is
*structural* equality, so a call that stores the same value it stored last time
produces a term equal to its predecessor and skips the write-back anyway. The
first version of the benchmark above did that and reported a flat 0.21 us at
every heap size, which was the right answer for the wrong reason.

### Two generations

A collection is **minor** unless the store has grown past `gc_major_ratio` times
its size after the last major (default 2).

A minor collection never traces an old object. That is what makes the pause
proportional to what was just allocated rather than to everything alive:

| old objects | major collection | **minor after 1000 allocations** |
| ---: | ---: | ---: |
| 1,000 | 0.123 ms | 0.075 ms |
| 10,000 | 1.262 ms | 0.077 ms |
| 100,000 | 14.928 ms | **0.083 ms** |

The minor pause is flat as the live set grows. At a hundred thousand live
objects it is 180 times shorter than a major.

Two things make it cheap. Ids come from a counter and are never reused, so the
objects allocated since the last collection are exactly the id range
`[watermark, next_id)`: the nursery needs no bookkeeping, and sweeping it is a
loop over integers rather than a walk of the store. And not tracing the old
generation is sound only because an old object can reach a young one only
through a write made since the last collection, which is what the **write
barrier** records.

The barrier is in `struct.set` and `array.set`. It costs nothing unless the
value being stored is a reference *and* the container is old:

| store | cost, net of the call |
| --- | ---: |
| `struct.get` | 44.8 ns |
| `struct.set` of a number | 52.5 ns |
| `struct.set` of a reference into an old object | 170.5 ns |

118 ns when it fires, one pattern match when it does not. A minor collection
cannot reclaim from the old generation, which is the other half of the trade: an
old object that becomes unreachable waits for a major.

**Collection**, mark and sweep from a chain of live objects:

| case | before | now |
| --- | ---: | ---: |
| 1,000 live | 108 us | 123 us |
| 10,000 live | 1.72 ms | 1.25 ms |
| 100,000 live | 21.8 ms | **14.7 ms** |
| 1,000 live, 10,000 garbage | 625 us | **124 us** |
| 1,000 live, 100,000 garbage | 6.35 ms | **175 us** |

The sweep is where the gain is: 63.5 ns per dead object down to 1.8 ns, because
a dead object is one `ets:delete` rather than a path copy through a functional
array. Marking is still around 140 ns per live object.

**A collection no longer allocates on the BEAM heap of the process that made
the call.** The live set was a map and the worklist was built with `++`; the
marks are an `atomics` bitmap now and the worklist holds ids:

| live objects | peak process heap, before | now |
| ---: | ---: | ---: |
| 1,000 | 53,194 words (35.5 per object) | 609 words |
| 10,000 | 225,340 words (10.4 per object) | 3,286 words |
| 100,000 | 2,045,548 words (8.5 per object) | **3,246 words** |

Six and a half megabytes to collect a hundred thousand objects, down to
constant. A collection is supposed to release memory.

Where the mark time goes, measured against a 2.9 ns null arm:

| primitive | cost |
| --- | ---: |
| `array:get` | 13.4 ns |
| `array:set` | 50.6 ns |
| `array:reset` | 42.6 ns |
| `ets:lookup_element` | 33.9 ns |
| `ets:update_element` | 93.0 ns |
| `atomics` mark bit, get and put | 23.7 ns |
| map live-set insert | 76.1 ns |

`array` is faster than ETS per operation: 2.5x on reads, 1.8x on writes. It
lost anyway, because an `array` has to be written back somewhere to be shared
and writing it back copies it. The number that matters is per call, not per
operation.

**Bulk array operations**, per element:

| elements | `array.copy` before | now | `array.fill` before | whole array | partial |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 127.1 ns | 205.0 ns | 61.7 ns | 2.9 ns | 85.0 ns |
| 1,000 | 416.2 ns | 257.5 ns | 54.2 ns | 0.3 ns | 106.0 ns |
| 10,000 | 4603.7 ns | **296.4 ns** | 42.2 ns | 0.0 ns | 128.1 ns |

`array.copy` was quadratic: it materialised the source as a list and then
indexed it with `lists:nth/2` inside the fold. A fill covering the whole array
is now one row update, because every element becoming the same value is what an
array's default means here. A *partial* fill still writes every element and is
3x slower than before, which is the honest cost of an element write that is
O(1) in the array's length instead of a path copy.

**An array whose elements cannot be references is never walked.** The collector
marks it and stops, because an `i32` or `i8` element cannot point at anything.
Collecting one live array with fifty thousand written elements:

| array | collection |
| --- | ---: |
| `(array (mut i32))` | below 1 us |
| `(array (mut (ref null $t)))` | 4307 us |

That is most of what a language like Java or Kotlin allocates, and walking a
million-element byte array to find no references in it is work worth not doing.

### What this cost

Recorded because it is the price of the above, measured one arm per VM:

| path | before | after |
| --- | ---: | ---: |
| call round trip, no objects | 0.478 us | 0.433 us |
| instantiate, no GC types | 1.669 us | 1.587 us |
| **instantiate, GC types** | **2.672 us** | **5.053 us** |
| `struct.get` net of the call | 34.0 ns | 51.5 ns |
| `struct.new` | 164 ns | 215 ns |

A module that declares no struct or array type gets no heap and pays nothing.
What is left is two ETS tables and an `atomics` array per instance that can
allocate, the row recording which instances share the store, and a field read
that pays ETS prices instead of `array` prices. The second table holds array
elements and the write barrier's remembered set; a struct-only module briefly
got away without one, and the generation is worth the microsecond it costs
back.

Two of those microseconds were avoidable and were found by measuring rather than
by reasoning. Keeping the instance registry in the engine's shared, named,
write-concurrent table cost 2.2 us of a 6.0 us instantiation; it lives in the
heap's own table now. Registering the whole `#inst{}` cost another 1.9 us,
because ETS copies on insert and an instance carries its type table, its
compiled functions and its exports; what is registered now is the four fields a
root scan reads.

**A major collection costs about 124 ns per live object**, and a hundred
thousand live objects stop that instance for 12.4 ms. That is close to the
floor for this storage, and the generation is what keeps it rare rather than
what makes it fast.

Where the 124 ns goes, and why it does not go much lower:

| per object | cost |
| --- | ---: |
| `ets:lookup` of the row, to reach its fields | 35.8 ns |
| `atomics` mark bit, get and put | 22.3 ns |
| `ets:next` per row in the sweep | 24.2 ns |
| the collector's own Erlang | the rest |

Two alternatives were measured and rejected. Sweeping with a chunked
`ets:select` instead of `ets:first`/`ets:next` is **worse**, 36.6 ns per key
against 24.2. Inlining the field scan and hoisting `tuple_size/1` out of the
loop gained 1.7%, from 12.585 to 12.375 ms, which is within the run-to-run
spread; it was kept because it is not worse, not because it helped.

Encoding "this object holds no references" in the object id, so the mark could
skip the row lookup entirely, would pay for the major out of the minor: ids
would stop being dense and every minor sweep would probe absent ids. The common
case is the one to protect.

The lever that works is not marking, which is what the generation is. A major
runs only when the store has doubled since the last one, so a program with a
stable live set never has one.

Two things follow. Collection is triggered by allocations since the last one
(`gc_alloc_threshold`, default 100,000), so a call that allocates nothing pays
two `atomics` reads and the pause is amortised. And the pause is preemptible
like everything else here: it is ordinary Erlang walking ordinary terms, so it
does not block a scheduler for its duration.

### What a trap does not undo

Object writes take effect immediately. A `struct.set` before a trap stays
written, where globals and tables are still committed only on success. The
store is shared and mutated in place, so there is nothing to roll back; linear
memory has always behaved this way and the specification describes no rollback
at all. `wasm_gc_collect_SUITE` pins it.

### Roots that were not roots

Four ways to lose a live object, none of them reachable from `#mut{}`, which is
where the collector reads its roots. Each passed every other test here while
being wrong. `wasm_gc_roots_SUITE` covers them.

**Passive element segments.** A segment's elements come from constant
expressions and `struct.new` is a constant expression, so a segment can be the
only thing referring to an object. Segments live in the immutable half of the
instance, so the collector never saw them and `array.new_elem` handed out
references into slots that had been reset. A segment that has been dropped is
not a root, since it can never be read again.

**Collection below a live frame.** A host import may call another instance, and
that call returns into an interpreter frame whose locals and operand stack hold
references nothing can see. Collection now runs only at the outermost
invocation, counted per process because two instances calling each other share
one Erlang stack.

**A failed instantiation.** Constant-expression evaluation threads its
allocation store through the process dictionary and erased it only on the way to
a finished instance. An instantiation that failed after allocating left the
store behind, and the next instantiation *in that process* adopted a heap it had
not allocated.

**Another instance's globals.** A reference is an id into a store, so two
modules that pass structs or arrays between them have to share one. Link them
at instantiation:

```erlang
{ok, A} = wasm:instantiate(ModA, #{}),
{ok, T} = wasm:extern(A, ~"table"),
{ok, B} = wasm:instantiate(ModB, #{{~"env", ~"t"} => T}, #{link => A}).
```

A collection triggered by either one then traces both, because an object B can
no longer reach may still be held by a global or a table of A's. The store goes
when the last instance sharing it goes. Without `link` the two have separate
stores and reading a reference from the other traps with `foreign_reference`,
which names the mistake instead of reading whatever object happens to hold that
id.

Linking is explicit rather than inferred from the import map, because an import
is a bare handle that does not say which instance produced it: `extern/2` hands
out a table, a memory or a cell, none of which names its origin. Inferring it
would work for some import kinds and not others.

**Re-entering a running instance keeps its writes.** It did not always. A
nested call read the state as of the last write-back, so it could not see what
the outer call had done, and the outer call's write-back then discarded
whatever the inner one did: a host import calling back into its own instance
allocated four objects and the outer call's return dropped the store to one.
Refusing re-entrancy was never the answer, because the specification requires
it and `linking.wast` calls back into a module that is still running.

A call now publishes its state before handing control to a host function and
adopts whatever came back, so a nested call sees the outer call's writes and
the outer call sees the nested one's.

**A trap keeps them too.** A trap ends the computation; it does not undo it,
and the store keeps every write made before it. Memories and tables are shared
structures and always did. A global that is not a cell, the size a private
memory grew to, and the dropped-segment sets are threaded through the
interpreter's own state, and used to go with the stack the trap unwound. Each
of those is recorded as it happens and committed by the invocation's catch;
`wasm_trap_effects_SUITE` pins all five cases.

### Type answers resolved once

Three things the interpreter recomputed on every instruction that asked. They
cannot change once a module is validated, so they are resolved in the cached
validation context, which a hundred instances of one module share:

| | before | after |
| --- | ---: | ---: |
| `struct.get`, field 0 | 37.0 ns | 36.0 ns |
| `struct.get`, field 15 | 44.7 ns | **33.6 ns** |
| `ref.test` against a concrete type | 96.1 ns | **84.5 ns** |

A struct's field was found with `lists:nth/2` over a list rebuilt from the type
table, so a field's cost grew with its index; it is two `element/2` calls now
and the index no longer matters. A cast recomputed its target's canonical
supertype closure and then searched it, on every execution. Casts are the most
frequent instructions in real toolchain output: `ref.test` appears 121 times
across the specification's garbage collection suites, against 46 for
`struct.new_default`.

Measured inside wasm rather than per call, because the difference is tens of
nanoseconds and a call round trip is four hundred.

### What destroying an instance releases

`wasm:destroy/1` releases the instance's memory pages, its object store when it
is the last instance sharing it, the ETS table holding its state, and this
process's cached copy of that state. The last two used to survive it: the table
was reclaimed only when the creating process exited, so a process making and
discarding many instances accumulated one each, and `wasm_instance:mut/1`
caches the whole state in the process dictionary keyed by instance id and never
erased it. Calling `destroy/1` twice no longer decrements the node's page count
twice.

Table arrays, global cells and shared-memory chunk tuples are reclaimed too.
They could not simply be dropped when their creator exited, because an exported
table outlives the instance that made it, so each one is held by a set of
tokens: the instance that created it, every instance that imported it, and the
process that made it if it was made standalone. It goes when the last of them
lets go, and releasing a token twice removes nothing the second time.

### References the embedder holds

A reference that leaves the runtime is not reachable from any root the runtime
can see, so it is **pinned**: call results, `wasm:get_global/2` results, and the
values carried by an uncaught exception.

Pins are reference counted and released explicitly:

```erlang
{ok, [Ref]} = wasm:call(Inst, ~"make", []),
%% ... use it ...
ok = wasm:release(Inst, Ref).
ok = wasm:release_all(Inst).        % or drop the lot, per request
```

They used to be released by nothing at all. Every reference ever returned stayed
a root for the life of the instance, in a list rebuilt with `lists:usort/1` on
every call, so an embedder calling a function that returns a struct a million
times kept a million objects alive and paid to re-sort the list each time. The
pins now live beside the objects, so pinning costs no state write-back.

Pin explicitly in one case: a **host function that keeps a reference it was
passed**. Its arguments are safe for the duration of the call, because
collection does not run below a live frame, and not afterwards.

## WASI

WASI is an Erlang host interface, not an embedded runtime: each syscall is an
ordinary host function, so it can be traced, replaced or refused.

```erlang
Wasi = #{ stdout => self(),
          dirs   => [{<<"/data">>, "/srv/app/data", read}],
          env    => #{<<"MODE">> => <<"production">>},
          args   => [<<"prog">>],
          clocks => [monotonic],
          random => strong,
          net    => #{connect => [{tcp, <<"10.0.0.0/8">>, 443}]} },
{ok, Inst} = wasm:instantiate(Mod, wasi_preview1:imports(Wasi)).
```

An absent key is an absent capability and the syscall returns `ENOTCAPABLE`.
No `dirs` means no filesystem at all, not one rooted at the working directory.
No `net` means no network at all, not one restricted to somewhere sensible.
No `env` means zero variables rather than the host's. `ENOTCAPABLE` is kept
distinct from `EACCES` so a module can tell "not granted" from "the OS
refused".

Implemented, 44 of them: `args_*`, `environ_*`, `clock_res_get`,
`clock_time_get`, `random_get`, `fd_write`, `fd_read`, `fd_close`, `fd_seek`,
`fd_tell`, `fd_fdstat_get`, `fd_fdstat_set_flags`, `fd_prestat_get`,
`fd_prestat_dir_name`, `fd_filestat_get`, `fd_filestat_set_size`,
`fd_filestat_set_times`, `fd_sync`, `fd_datasync`, `fd_pread`, `fd_pwrite`,
`fd_readdir`, `fd_advise`, `fd_allocate`, `fd_renumber`, `path_open`,
`path_filestat_get`, `path_filestat_set_times`, `path_create_directory`,
`path_unlink_file`, `path_remove_directory`, `path_rename`, `path_symlink`,
`path_readlink`, `path_link`, `proc_exit`, `sched_yield`, `poll_oneoff`
(clocks and socket readiness; a file still returns `ENOSYS` rather than a
guess), `sock_accept`, `sock_recv`, `sock_send`, `sock_shutdown`.

Plus eleven socket extension calls, which are WasmEdge's rather than the
specification's: `sock_open`, `sock_bind`, `sock_listen`, `sock_connect`,
`sock_send_to`, `sock_recv_from`, `sock_getlocaladdr`, `sock_getpeeraddr`,
`sock_getsockopt`, `sock_setsockopt`, `sock_getaddrinfo`.

### Path sandboxing

Every escape technique gets its own test case, and all must fail with
`ENOTCAPABLE` rather than `ENOENT`, so the error code cannot be used to probe
the host's directory layout:

| attempt | result |
| --- | --- |
| `note.txt`, `./note.txt` | opened |
| `../secret/key.txt` | `ENOTCAPABLE` |
| `/etc/passwd` | `ENOTCAPABLE` |
| `escape.txt` (symlink out of the sandbox) | `ENOTCAPABLE` |
| `sub/../../secret/key.txt` | `ENOTCAPABLE` |
| `missing.txt` | `ENOENT` |

Resolution uses `filelib:safe_relative_path/2`, which already handles lexical
traversal *and* symlink escapes, rather than a hand-rolled sanitiser. Requested
rights are masked against what the preopen passes down, so a `read` grant
cannot yield a writable descriptor whatever flags the module passes.

**The time-of-check to time-of-use window.** Resolving a path and then opening
it leaves a gap in which a component can be swapped for a symlink. Erlang's
`file` module exposes neither `openat` nor `O_NOFOLLOW`, so closing it needed
the project's one NIF: a six-function capability-safe file API that walks each
path component `openat(..., O_NOFOLLOW)` relative to the previous directory
descriptor, so no name is resolved twice and no symlink is followed.

It is optional. Without a C compiler the build falls back to the pure-Erlang
resolver and the window is narrowed by re-verification rather than closed; in
that configuration, do not point a preopen at a directory a hostile party can
write to concurrently. `wasi_nif_SUITE` swaps a component for a symlink between
resolve and open and asserts the native path refuses it.

### Network sandboxing

A `net` grant names what may be reached. `connect` and `listen` are separate
capabilities, `resolve` is a third, and none implies another.

```erlang
net => #{connect     => [{tcp, <<"10.0.0.0/8">>, {8000, 8099}}],
         listen      => [{tcp, <<"127.0.0.1">>, 8080}],
         resolve     => allow,
         max_sockets => 32,
         timeout     => 30000}
```

**Grants name addresses, never names.** There is no rule that says
`example.com`. A name has to be resolved to be checked and resolved again to be
used, and the two answers can differ; `sock_connect` hands the operating system
the same tuple it checked, so nothing in between can move the target. That is
the difference between removing the window and narrowing it.

Every route out gets a case in `wasi_net_escape_SUITE`:

| attempt | result |
| --- | --- |
| a granted address and port | connected |
| the granted address, another port | `ENOTCAPABLE` |
| `::ffff:127.0.0.1` under a `127.0.0.0/8` grant | connected, over IPv4 |
| `::ffff:10.0.0.1` under a `127.0.0.0/8` grant | `ENOTCAPABLE` |
| `::127.0.0.1` under a `127.0.0.0/8` grant | `ENOTCAPABLE`, it is IPv6 |
| binding `0.0.0.0` under a loopback `listen` grant | `ENOTCAPABLE` |
| connecting to an address `sock_getaddrinfo` returned | checked as an address |
| a socket descriptor from another instance | `EBADF` |
| any socket call with no `net` key | `ENOTCAPABLE` or `EBADF` |

The refusal is the same whether or not something is listening on the port, for
the reason path escapes answer `ENOTCAPABLE` rather than `ENOENT`: an errno that
varied with the host would be a port scanner.

`::ffff:127.0.0.1` reaching the same host as `127.0.0.1` is the case a tuple
comparison misses, so mapped addresses are folded before the check and the
folded form is what gets connected to. The deprecated `::a.b.c.d` block is
deliberately not folded, because `::0.0.0.1` and `::1` are one address and
folding it would make loopback ambiguous.

Preview 1 standardised four socket calls and all four assume the socket already
exists, so a `listen` rule naming one address and one port is opened by the host
and handed in as a preopened descriptor: a module using only standardised calls
never names an address at all. What socket support does **not** cover is
enumerated in [docs/security.md](security.md), and two of those statements are
asserted by tests so the document fails with them.

## Building the documentation

The hand-written pages are in `docs/`. The generated site is built with
[ex_doc](https://github.com/elixir-lang/ex_doc), which reads the EEP-59
`-moduledoc` and `-doc` attributes rather than edoc comments, and lands in
`doc/`:

```sh
rebar3 ex_doc
open doc/index.html
```

The two directories are deliberately different. ex_doc writes into `doc/`, so
keeping the sources there meant the generated site overwrote them.

## Running the tests

```sh
rebar3 ct                                        # everything
rebar3 ct --suite=test/wasm_spec_SUITE           # core conformance only
rebar3 ct --suite=test/wasi_conformance_SUITE    # WASI conformance only
rebar3 bench                                     # benchmarks

# both conformance suites read upstream sources directly, and skip without them
git clone --depth 1 https://github.com/WebAssembly/testsuite.git
git clone --depth 1 --branch prod/testsuite-base \
    https://github.com/WebAssembly/wasi-testsuite.git
```

`wasm_spec_SUITE` runs the core suites four times: decode only, decode and
validate, all three phases, and all three phases again **through the compiled
tier**, since generated code is a second set of semantics that can drift from
the interpreter's.

### Path resolution

Every WASI path a guest names goes through `wasi_fs`. On the native backend
that means one component walk with `openat(..., O_NOFOLLOW)` and then a single
`*at` call, so a name is resolved once, by the kernel, and no symlink is
followed. That covers `path_open`, `fd_readdir`, the file operations, and all
eight remaining `path_*` calls.

None of it applied to a guest until recently. `wasi_fs` had no callers at all:
`path_open` resolved with `wasi_path` and opened with `file:open/2`, and the
`path_*` calls resolved and then acted, two steps with a window between them.
Every deployment had the fallback's race whether or not the NIF had built.

The fallback still resolves by name, which is what it is. It refuses every
escape it can detect lexically and through `filelib:safe_relative_path/2`, and
what it cannot close is a component swapped between the check and the act.
`wasi_fs:backend()` says which you have.
