# How each suite was brought up

This is the record of how the conformance suites came to pass: what the
harness was not checking, what the baseline was hiding, the defects each
proposal uncovered and the measurements behind the choices made on the way.
Read it when you change the spec harness, the baseline, or the instruction
set a section covers, so that you know what already went wrong once.

`docs/features.md` says what passes today. Every section below was moved
word for word from it on 2026-11-17, when the guides stopped carrying
history; only the headings were changed, so that each names the proposal it
belongs to. The source gave no date or commit for these blocks, and "the
table above" in them is the score table of `docs/features.md`.

## The 22 commands the runner skipped

From "Specification test suite".

Nothing is skipped either. The 22 commands skipped before were 18
`assert_exception` commands and 4 `module_definition` commands. Both belong to
features this runtime implements: exception handling is implemented, and
`instance.wast` uses `module definition` and `module instance` to check that
each instantiation creates a new instance. The test runner did not support
them. `wasm_spec_runner` now runs them.

## What the harness was not checking

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

## What the baseline was hiding

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

## SIMD: why a `v128` is a binary

From "SIMD".

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

## SIMD: float lanes and the two lane rules

From "SIMD", where it followed "Relaxed SIMD".

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

## Typed function references

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

## Exception handling: how a throw unwinds

From "Exception handling".

**Unwinding was easy because frames are explicit.** `run/3` already keeps the
control stack as a list, and each call frame holds the caller's control stack.
So a throw walks outwards through both. It is the same traversal `branch/3`
does, searching for a handler rather than counting to a depth, and it needs no
Erlang exceptions inside a single instance.

Crossing an instance boundary does need one, because a foreign call is a nested
`wasm_exec:call/5`. There the exception travels as an Erlang throw. At the
host-call boundary it goes back into the interpreter's own unwinding, so a
`throw` in an imported function is caught by its caller's `try_table`.

## Tail calls: how they work and what the suites could not show

From "Tail calls".

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

## memory64: what 64-bit operands uncovered

From "memory64".

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

## Shared tables and instance-carrying references

From the section of that name.

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

## What running QuickJS first found

From "Real usage", where it was "What running it first found".

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

## Threads: the shared memory that outlived its creator

From "An agent is an Erlang process".

That was not true at first. The memory was counted for the process that created
it. So when that process exited, the node's page count fell to zero while the
memory was still in use. Also, the shared tuple of chunks was dropped, so
growing the memory afterwards failed. Both are fixed, and `wasm_threads_SUITE`
tests the pattern: a coordinator makes the memory, hands it over, exits, and the
memory stays readable, stays charged and still grows.

## Threads: what `wasm_threads_SUITE` adds

From "An agent is an Erlang process".

`wasm_threads_SUITE` tests what the conformance suite cannot, because the
specification suite runs only one agent. Sixteen processes each add one ten
thousand times to the same address and the total must be exactly 160,000; a
compare and exchange contended by sixteen processes must admit exactly one
winner; a waiter must wake, time out, or answer "not equal" without waiting. It
has its own control test: the same arithmetic written with an ordinary load, add
and store, which is asserted to **lose** updates. Without that, the atomicity
test would pass just as well against an implementation that was not atomic at
all.

## Threads: what the two dropped suites found

From "Two suites left out, and why".

Those suites found two real defects before they were removed: a shared
memory did not link against a shared import (sharing has to match exactly, in
both directions, and was not compared at all), and `wasm_spectest` had no shared
memory to import.
