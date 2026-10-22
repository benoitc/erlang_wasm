# Feature and conformance status

This page lists what the runtime implements, its results on the official
WebAssembly specification test suite, and its measured costs. Use it to find
out whether your module will run, and how fast.

How the garbage collector works and how the WASI sandboxes are enforced are
explained in the [design notes](design-notes.md), with the other reasons
behind the runtime's design. Build and test instructions are in the README.

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
| The async Canonical ABI: `async func`, `stream`, `future` | complete |
| WASI 0.2: random, clocks, cli, io, filesystem, sockets | complete |
| `wasi:http`: outbound requests and serving an incoming-handler | complete |

## Not implemented

| Area | Why |
| --- | --- |
| WASI 0.3 interfaces | they use the async ABI, which is implemented; no toolchain needs them yet |
| Snapshots of component instances | `wasm:snapshot/2` captures a core instance; a component's handle tables point to host state that a snapshot image cannot store |

## Caching compiled code

Off by default. See [the compiled tier](compiled-tier.md).


## Specification test suite

The tests are read directly from the [upstream test
suite](https://github.com/WebAssembly/testsuite). `wasm_wast` turns a `.wast`
script into a list of commands, and `wasm_spec_runner` runs them. Nothing is
generated and no other tool is needed. To run the conformance tests, you only
clone the suite:

```sh
git clone --depth 1 https://github.com/WebAssembly/testsuite.git
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

Nothing is skipped either. The 22 commands skipped before were 18
`assert_exception` commands and 4 `module_definition` commands. Both belong to
features this runtime implements: exception handling is implemented, and
`instance.wast` uses `module definition` and `module instance` to check that
each instantiation creates a new instance. The test runner did not support
them. `wasm_spec_runner` now runs them.

### What the harness was not checking

A conformance score is only correct if every assertion counted as passing
really compared something. Two times, some did not.

To add relaxed SIMD, we checked what happens when the matcher does not recognise
an expected value. It skipped that value *and every later value in the same
assertion*, and counted the assertion as a **pass**. Tightening that to report
it as unchecked moved **116 assertions out of the pass column** across seventeen
core suites.

They were not relaxed SIMD's. The harness could compare a *null* external
reference and not a particular one, so every assertion naming `(ref.extern 1)`
in `table_fill`, `table_grow`, `br_table` and a dozen others passed without
comparing anything. After the harness learned the non-null reference forms, 109
of them became real checks again, and one real defect appeared: a host reference
in the internal hierarchy, `(ref.host N)`, had no decoding at all, so
`extern.wast` was exercising `extern.convert_any` against a placeholder.

The totals of that run were unchanged at 63,231 and 1,180. What changed is that
all of them now check something. The gate reads 65,481 over 256 suites today,
after the classification the table above records.

### What the baseline was hiding

A baseline is only correct if each entry fails *because of* the proposal it
names. We traced each entry back to its cause, and found five defects listed
under a proposal's name. All are fixed now, and `wasm_linking_SUITE` tests
them:

- **An import of the wrong kind raised out of the runtime.** Handing a table to
  a module that imports a memory reached `wasm_memory:limits/1` and died with a
  `function_clause`, reported as an internal error. Every failure must be a
  value, and an embedder passes plain Erlang terms, so this broke the rule that
  the whole library depends on.
- **An imported mutable global was copied, not shared.** Two modules linked to
  the same global each got their own, and diverged silently after the first
  write. The same defect imported tables had.
- **Import mutability was never checked**, so a module could import a mutable
  global as immutable or the reverse.
- **Function import signatures were never checked.** An export from another
  instance was adopted with whatever signature the importer declared.
- **A `funcref` global failed to link**, because the shape check still expected
  the bare two-element reference that instance-carrying `funcref`s replaced.

Only mutable globals became shared cells. The module decides which globals
are mutable, and this is fixed in the instruction when the IR (the internal
form of the code) is built. Reading an ETS row took 17.7 ns, against 1.9 ns
for a tuple element. Compiled guest code reads its shadow stack pointer (a
global) at the start of almost every function. So an ordinary `global.get`
still reads a tuple.

Every entry in that baseline names a specific unimplemented proposal or a
stated limitation. A failure without a known cause is a defect to fix, not a
number to record. The suite fails the build if the baseline allows more
failures than really happen.

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

Bit syntax cuts each field to its declared width, so lanes wrap around with
no extra work, while the integer form needs a mask per lane. A binary is built
in one allocation, while a chain of shifts and ors allocates a temporary
bignum per lane. The integer form wins only on `v128.and`, and only by 12%.

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

**Float lanes are not `:32/float` fields.** Erlang cannot represent NaN or
Infinity as a float and those bit patterns do not match a float field at all,
so a lane holding one would raise an error instead of comparing unequal.
Lanes are read as integer bit patterns and converted through `wasm_num`, the
same mixed representation that the scalar instructions use. So NaN
propagation and quieting work with no extra code.

Two rules apply whatever the representation: a lane comparison yields
all-ones rather than 1, which is what makes it a mask for `v128.bitselect`; and
`pmin`/`pmax` are not `min`/`max`, being specified as "return the second
operand if the comparison is true, otherwise the first", which propagates the
first operand's value when either is NaN.

### Typed function references

Value types gained the general reference form `{ref, Null, HeapType}`, with
`funcref` normalised to `{ref, null, func}` at the decoder. Each type has
only one form, on purpose. With two terms for one type, every comparison
would have to know that they are equal. A comparison that forgot would
silently accept or reject the wrong modules.

**Subtyping did not slow down the common case.** It is in `pop_expect/2`, the
only place where two value types are compared, and that function's equality
clause is still first. So numeric and vector types are still compared as
simple values. Only reference types go on to the subtyping clauses. That is why
`wasm.hrl` can still describe value types as compared by equality.

Non-nullable locals get definite-assignment analysis. An assignment made
*inside* a control frame does not survive it: only one arm of an `if` runs, and
a `block` may be branched out of before its assignments happen. The
specification is this strict on purpose, and the tests check it.

Recursive type groups are flattened. Without garbage collection there is no
recursion to resolve and no declared subtyping, so a `rec` group is exactly its
members listed in order. That is exact for everything except telling two
structurally identical types in one group apart, which is the remaining `tag`
failure.

### Exception handling

Tags, `throw`, `throw_ref`, `try_table` and `exnref`.

**Unwinding was easy because frames are explicit.** `run/3` already keeps the
control stack as a list, and each call frame holds the caller's control stack.
So a throw walks outwards through both. It is the same traversal `branch/3`
does, searching for a handler rather than counting to a depth, and it needs no
Erlang exceptions inside a single instance.

Crossing an instance boundary does need one, because a foreign call is a nested
`wasm_exec:call/5`. There the exception travels as an Erlang throw. At the
host-call boundary it goes back into the interpreter's own unwinding, so a
`throw` in an imported function is caught by its caller's `try_table`.

**A trap is not catchable.** Traps stay `wasm_error` throws and pass straight
through every handler, so a module cannot hide a division by zero or an
out-of-bounds access with `catch_all`. The two paths are separate on purpose and
`wasm_exception_SUITE` asserts it, because a change merging them would still
pass every other test.

### Tail calls

`return_call` and `return_call_indirect`. They were also easy because frames
are explicit: `enter/5` pushes a frame, and a tail call runs the callee's body
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

A tail call into *another instance* can still grow the stack. The callee uses
its own memory and globals, so it cannot reuse this frame. It is called
normally, and its results become the caller's results. The behaviour is the
same, except for the stack space.

### memory64

A memory or table may declare `i64` as its index type, which changes far more
than the decoder. The index type reaches the operand types of every memory and
table instruction, the ceilings the validator enforces, how an operand is read
as unsigned at run time, and whether one module may import another's memory.

The interpreter must not do a lookup on every access to find the index type.
So the width is found once, when the IR is built, and stored in the
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

Index types must match exactly between an import and its export. Minimum and
maximum sizes do not need to match exactly; they only need to allow at least
as much. A 32-bit memory handed to a
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
callee's own memory and globals, and not against the state of the
module that made the call.

Nothing is skipped: every command in every suite of the checkout is either
executed or asserted against.

## Compiling to Core Erlang

Off by default. It made a language runtime 8.4 times faster, and did not
change a plugin. See [the compiled tier](compiled-tier.md) for what it
compiles, what turns it off, how to keep the result across restarts, and how
to read the code it generates.

```erlang
{ok, I} = wasm:instantiate(M, Imports, #{compile => true}).
```


## Benchmarks

Measured on Apple Silicon, OTP 29, with `rebar3 bench`. The numbers give an
idea of the costs. They are not exact results for comparing runtimes.

**On measurement conditions.** The machine had a load average of about 30,
and runs of the same code varied by up to 3 times. Read the absolute numbers
as an order of magnitude only. When the page claims that a *change* helped, it
was measured like this: both versions ran in turn in one VM for several
rounds, and the minimum of each version was kept. So changes in load affect
both versions equally. One run before and one run after, on a loaded machine,
proves nothing, and such numbers are not given here.

### Pipeline

| Operation | Cost |
| --- | ---: |
| decode | 6.3 us |
| validate | 5.6 us |
| compile (decode + validate) | 13.2 us |
| instantiate | 2.9 us |
| call round trip | 0.40 us |

Instantiation at 2.9 us is the important number for plugins and for one
instance per request. There, what matters is how cheaply the runtime creates
and discards an instance, more than how fast a long run goes.

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

**How much garbage collection support slowed down code that does not use
it.** Measured before the work and again after, minimum of three runs each:

| Path | Before | After |
| --- | ---: | ---: |
| interpreter dispatch | 4.9 ns/instr | 4.9 ns/instr |
| call round trip | 0.40 us | 0.40 us |
| instantiate | 3.07 us | **2.93 us** |
| memory load i32 | 16.8 ns | 18.2 ns |
| compile | 11.8 us | 13.2 us |

These measurements found three slowdowns. All three were fixed:

- **Dispatch had slowed 18%.** The new instructions were inserted early in the
  interpreter's clause list, so every common instruction was tested against
  forty new patterns first. Moving them after the common ones gave back the old
  speed exactly.
- **Instantiate had slowed 33%**, because the validation context is rebuilt per
  instance and canonicalising interns every recursive type group. Now the result
  for the last module is kept and reused, which is why it is *faster* than
  before. The first attempt used a cache with `phash2` of the module as key, and
  was even slower: hashing a large module costs more than the work it saved.
- **Memory access had slowed 15%**, because the page count moved behind an
  accessor. Inlining it, and keeping a plain record match for a private memory,
  removed most of the slowdown.

Two real costs remain. Memory access is 1.4 ns slower, because a memory can
now be shared. Compile is 1.4 us slower, because of canonicalisation: a
module's recursive type groups are stored once in a node-wide table, so that
the same type is equal in every module.

### Scheduler responsiveness

This result shows the difference from a runtime called through a NIF. An
unrelated Erlang process measures how long its own messages take to come
back, while WebAssembly infinite loops keep every scheduler busy.

The measurement is **compared with a control**: the same number of pure-Erlang
busy loops. A comparison with an idle node would only measure the cost of
fourteen busy schedulers, and wrongly report it as a property of this
runtime.

| Condition | p99 message latency |
| --- | ---: |
| idle | 1 us |
| 14 pure-Erlang busy loops (control) | 6-246 us |
| 14 WebAssembly infinite loops | 2-153 us standalone, 11.4 ms under Common Test |

Measured the same way, the two cases give similar numbers, and that is the
result: the interpreter gives up the scheduler like ordinary Erlang code. Every
dispatch step is an Erlang function call and therefore consumes a reduction, and
an infinite `loop` runs in **constant space** (986 words, flat, at 780M
reductions per second), so the heap does not grow and the garbage collector does
not pause it either. With a runtime called through a NIF, the process would not
answer at all until the call finished.

Two warnings. The results vary a lot: runs of the *same* case went from 2 us
to 1005 us. So one before-and-after pair can show any result, and an earlier
version of this section reported a 40 times slowdown that was one noisy
sample. Also, under Common Test the same measurement always reports 11.4 ms
for the WebAssembly case, while its Erlang control reports 6 us. Nobody knows
why yet, and the gap does not appear outside Common Test.
`scheduler_stays_responsive/1` now takes the minimum of several rounds per arm
and logs both, instead of comparing with an idle node using a limit so large
that it would hide a real 49 ms block.

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

### What running it first found

Before this, the runtime had never run a large module written by someone
else. The first one we tried crashed the Erlang VM:

```text
ets_alloc: Cannot reallocate 18446744060576004240 bytes  (2^64 minus ~3 GB)
```

A function reference carried its whole defining instance, and an instance holds
the module's compiled functions: 19.5 MB flat, per reference, with 1036 of them
in the table. Stored in the engine's ETS table, where `ets:insert` copies each
reference in full, that is 19.8 GB. The cost was `table entries x module size`,
so no fixture here was large enough to show it.

Two changes followed. `wasm_scale_SUITE` now tests both, with modules written
in text, so nothing needs to be downloaded:

- **A reference names its instance rather than carrying it.** The common path
  already compared only ids, so it did not change. A call into another instance
  finds the instance from its id in the calling process's dictionary, which is
  cleaned so that destroyed instances do not pile up.
- **A function is lowered (prepared for the interpreter) the first time it is
  called**, in modules with more than 256 functions. Instantiating QuickJS fell
  from 78 ms, and measures 3.2 ms today; a script went from 752 ms to 238 ms.
  Below the threshold everything is lowered up front as before, because waiting
  made a call round trip 16% slower in a small module and brought no gain.

## Testing

| Suite | What it covers |
| --- | --- |
| `wasm_spec_SUITE` | the official suite, gated per suite against a baseline |
| `wasm_prop_SUITE` | totality, atom safety, memory model equivalence, LEB128 round trip |
| `wasm_bench_SUITE` | the tables above, plus the responsiveness assertion |
| `wasm_worker_SUITE` | limits actually bound, tested through `wasm_instance_worker` |
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

The main properties:

- **Totality.** No binary, however hostile, produces anything but `{ok, _}` or a
  structured `{error, _}`. Verified over random binaries and over valid modules
  mutated at the byte level.
- **No atom creation.** Decoding arbitrary input never moves the atom count. The
  atom table is node-wide and never reclaimed, so one
  `binary_to_atom` on module data would let a remote module crash the node.
- **Memory equivalence.** Random sequences of store, fill, copy and grow against
  the `atomics` backend agree byte for byte with a plain binary model. The same
  property will validate the optional native backend when it arrives.

## Threads

Shared memories, all 66 instructions of the `0xFE` opcode space, and
`memory.atomic.wait`, which really blocks an Erlang process until another
process notifies it. The `atomic` suite passes in full: 297 assertions, no
skips.

**The storage was already atomic.** Linear memory is chunked `atomics` arrays,
so an eight-byte aligned atomic load is the same single `atomics:get` an
ordinary one is. Narrower accesses are a *field* of a 64-bit word, so writing
one means reading the word, replacing the field and writing it back; those go
through `atomics:compare_exchange` and retry. A read-modify-write is that same
loop with the arithmetic inside it, and this makes it one indivisible step,
not a load and a store that usually work.

**`wait` is a `receive`.** Other runtimes use a futex, which has a well-known
risk: a waiter must check a value and then sleep, and a notify that arrives
between those two steps wakes nobody. Here the waiter registers *before* it
re-reads the value, so a notify arriving afterwards lands in its mailbox and
`receive` finds it either way. A mailbox is a queue, not a signal that can be
missed. This is the one part of the proposal that the BEAM makes easier, not
harder.

**Nothing reorders.** `atomics` is sequentially consistent, so `atomic.fence`
has nothing to do and the relaxed memory model the proposal permits is not
exploited. An implementation that reordered would be faster, but ordering bugs
in guest programs could then not be reproduced.

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

That was not true at first. The memory was counted for the process that created
it. So when that process exited, the node's page count fell to zero while the
memory was still in use. Also, the shared tuple of chunks was dropped, so
growing the memory afterwards failed. Both are fixed, and `wasm_threads_SUITE`
tests the pattern: a coordinator makes the memory, hands it over, exits, and the
memory stays readable, stays charged and still grows.

`wasm_threads_SUITE` tests what the conformance suite cannot, because the
specification suite runs only one agent. Sixteen processes each add one ten
thousand times to the same address and the total must be exactly 160,000; a
compare and exchange contended by sixteen processes must admit exactly one
winner; a waiter must wake, time out, or answer "not equal" without waiting. It
has its own control test: the same arithmetic written with an ordinary load, add
and store, which is asserted to **lose** updates. Without that, the atomicity
test would pass just as well against an implementation that was not atomic at
all.

### Two suites left out, and why

The threads proposal includes its own copy of the whole core suite, and that
copy is older than multiple memories and multiple tables. `imports-threads` and
`memory-threads` assert that a module with two memories is invalid, which
contradicts a feature this runtime implements: they fail because that copy is
old, not because anything is missing. The instructions and shared-memory rules
the proposal actually adds are in `atomic` and `exports-threads`, both of which
pass in full.

Those suites found two real defects before they were removed: a shared
memory did not link against a shared import (sharing has to match exactly, in
both directions, and was not compared at all), and `wasm_spectest` had no shared
memory to import.

## Read this next

[Upgrading](upgrading.md) and the [changelog](../CHANGELOG.md).
