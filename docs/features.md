# Feature and conformance status

This page records what the runtime implements, how it scores against the
official WebAssembly specification test suite, and what it measures. Use it to
find out whether a module you care about will run, and what it will cost.

Status as of **0.3.0**.

The internals that used to sit at the end of this page -- how the garbage
collector works and how the WASI sandboxes are enforced -- are in
[design notes](design-notes.md), which is where the rest of the runtime's
rationale lives. Build and test instructions are in the README.

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
| Compiling hot functions to Core Erlang, with an on-disk artifact cache | complete, off by default |
| Initialized runtime snapshots: capture, restore per request, and files | complete |
| A worker kernel for untrusted guests, with an adapter per language | complete |
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

| | `plugin_worker` | `qjs_worker` |
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
