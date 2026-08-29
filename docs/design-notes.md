# Design notes

Why the runtime is built the way it is, indexed by subject. Read a section when
you are about to change the thing it describes, so you find out what was already
tried before you try it again.

This is not the measurement record. `test/audit/PERF.md` is the lab notebook,
ordered by when each thing was discovered, and `test/audit/ATTEMPTS.md` lists
what was tried and reverted. Both are worth keeping in that order and neither is
a reference. This page is the reference, and it links into them.

Two subjects are documented elsewhere because they are features as much as
decisions: [threads](features.md#threads) and [garbage
collection](features.md#garbage-collection) in the feature page, and the whole
compiled tier in [the compiled tier](compiled-tier.md).

## Linear memory is chunked atomics arrays

Not a binary, and not a NIF.

A binary cannot be mutated in place, so every store would copy. `atomics` is the
BEAM's only mutable, traced, word-addressable container, and chunking it keeps
`memory.grow` from copying the whole memory. The cost is that a narrow store is
a read-modify-write, about 9.6 to 19 nanoseconds against 4.8 for a plain
`atomics:get`.

A NIF would be faster and was considered and declined: it puts the sandbox
boundary in C, where a bug is a node crash or worse rather than a trap, and the
pure Erlang version is what makes the safety claims checkable.
`wasm_prop_SUITE:memory_matches_model` is a property over random sequences of
load, store, fill, copy and grow against a plain binary model, which is what
would validate a native backend for free if one ever arrives.

Generated code reads the memory record by literal field index, so
`wasm_core_SUITE:the_memory_field_indices_match_the_record` pins those indices
to `wasm_memory:field_indices/0`. Adding a field to `#mem{}` fails there rather
than corrupting memory quietly.

## The interpreter keeps its own control stack

`#st.frames` and `#st.ctrl` are explicit lists rather than the Erlang call
stack. Erlang has no first-class continuations, so an implicit stack could not
be suspended, inspected from outside, or bounded independently of Erlang's own
stack growth. Those three are what `max_depth`, trap reporting and the worker's
cancellation all rest on.

`#st.stack` is a cons list with the top at the head, which measured faster than
any indexed structure.

## The mutable half of an instance is separate from the immutable half

`#inst{}` is everything derived from the module and never written during
execution; `#mut{}` is what changes. A call reads the mutable half once, threads
it functionally through execution, and writes it back once at the end. A tuple
update is a few nanoseconds and an ETS write is forty.

The garbage-collected object store sits in the *immutable* half, which looks
wrong and is the point: the handle is immutable and only what it names changes.
While the store was a term inside `#mut{}`, committing it copied the whole heap
into ETS, at 1993 microseconds per mutating call at a hundred thousand objects.

## Generated code checks a stamp, and does not hold a lease

A slot holding generated code may be reused once nobody is inside it. The
obvious way to know that is a lease per call, and it was tried: a killed caller
leaks its lease, because a lease is given back in an `after` and an `after` does
not run for an untrappable kill, so one killed process pinned a slot for the
life of the node.

So the check moved into the callee. Generated code is built for a stamp, the
module's content hash where it has one and the slot generation otherwise, and it
refuses a caller that presents a different one. A killed caller now costs
nothing: reuse is safe whatever the lease counter says, and `soft_purge` is the
authority rather than the leases.

`wasm_code_slots_SUITE` caught the first version of this, which was unsound in
the window between taking a lease and entering the code.

## Sixteen fixed module names, and bounded name pools

The atom table is node-wide and never reclaimed, so any name derived from a
module's own bytes is a permanent leak with a remote tap on it. Generated module
names come from a pool of sixteen written out literally in `wasm_code_slots`,
and function and frame names from bounded pools in `wasm_core`. The number of
atoms the compiler can ever create is a literal you can read in the source, and
`wasm_core_SUITE` and `wasm_prop_SUITE` both assert the count does not move.

## Compile what ran, not what exists

QuickJS is 1666 functions and a workload reaches about 223 of them. Compiling
all of them is most of the time and most of the fifteen megabytes of code space.
A function left out is not a correctness question: it is interpreted, and since
the boundary became two-way it can still call back into compiled code.

One shot, and honestly so. A function that becomes hot afterwards is never
compiled, because there is one slot per module and no mapping from a function to
a shard. That is the next change and it has not been made.

## A benchmark that lied, and how it was caught

Interleaving two arms in one VM cancels load drift, so it was used for every
A/B here. On a memory-heavy workload it reported that superinstructions made
things **2x slower**, reproducibly (0.49x across three runs).

The control experiment settled it: with *all fusions disabled*, so both arms
ran byte-identical code, the same harness still reported 0.38x. The harness was
wrong, not the runtime. Alternating between two instances alternates between
two 1 MiB linear memories and thrashes the CPU cache; the same instance
measured twice in a row ran at 1560 us against 2200 us when alternating.

Interleaving is the right tool for load drift and the wrong tool when each arm
carries a large private working set. Those A/Bs are run one arm per VM instead,
several launches, minimum taken. Re-measured that way, fusion is **1.14x
faster** on the same workload, not 2x slower.

The lesson is kept here because a benchmark that produces a confident, stable,
reproducible, wrong number is more dangerous than a noisy one, and the only
thing that caught it was running the null experiment.

## Where a call's time goes

Decomposing `wasm:call/3` on a trivial exported function showed that execution
was the smallest part of it:

| stage | cost |
| --- | ---: |
| export name lookup | 26 ns |
| instance state read (ETS) | 105 ns |
| **interpreter execution** | **~45 ns** |
| instance state write-back (ETS) | 185 ns |

Marshalling the instance's mutable state in and out of ETS dominated a short
call. Two changes followed:

- **Skip the write-back when nothing changed.** A function that only reads
  threads the same `#mut{}` term straight through, so `=:=` is a pointer
  comparison and the ETS write disappears entirely. Most compute functions
  mutate no globals, tables or memory size.
- **Build the locals tuple in one pass.** `lists:split` then `lists:reverse`
  then `++ Defaults` walks the arguments three times and allocates three lists.
  Popping top-first into an accumulator seeded with the defaults produces the
  same tuple in one pass. Interleaved A/B over 7 rounds: **32.7 ns to 17.6 ns,
  1.86x**, consistent in every round.
- **Precompute the `{func, N}` control frame** at instantiation instead of
  allocating one per call.

### Removing the state read

That state read turned out to be term-copy cost, not table overhead: the same
`ets:lookup_element` returning an atom costs 30 ns, a big nested term 175 ns,
and the real Rust module's state 398 ns. Meanwhile a process dictionary read
costs 9 ns regardless of size, because it does not copy.

So each process caches the state it last saw together with a version counter
held in an `atomics` slot. A hit is an `atomics:get` plus a dictionary lookup;
any process's write bumps the counter and invalidates every other cache. That
coherence property is asserted in both directions by
`wasm_worker_SUITE:state_stays_coherent_across_processes/1`.

Interleaved A/B on the real Rust module: **398.5 ns to 18.8 ns, 21x**, stable
across all seven rounds (399-407 against 19-20).

### Superinstructions

Chosen from measured frequencies over ~25,000 instructions of real Rust and
clang output rather than from intuition. `local.get` alone is 28.3% of the
stream and `i32.const` a further 17.6%. The fused sequences are
`local.get,i32.const,i32.add` (address arithmetic), `local.get,i32.load`,
`local.get,local.get`, `local.get,i32.const`, and `i32.eqz,br_if`.

Only straight-line runs are fused. `br_if,local.get` is a frequent adjacency
but must never be merged, because the `local.get` runs only when the branch is
not taken.

Removes 23.9% of static instructions on the clang fixture; worth roughly
1.02x to 1.14x of wall clock depending on workload. Fusion can be disabled with
`wasm:instantiate(M, Imports, #{fuse => false})`, which is how it was measured
and how a suspected fusion bug would be isolated.

### Bulk memory, and where a NIF *is* justified

The float experiment found a NIF losing to pure Erlang. Bulk memory is the
opposite, and measuring it first found two defects worth fixing before any
native code:

| operation, 64 KiB | before | after | ceiling (`binary:copy`) |
| --- | ---: | ---: | ---: |
| `load_bytes` | 1437 us | **122 us** | 5.5 us |
| `memory.copy`, disjoint | 5424 us | **257 us** | 5.5 us |
| `memory.fill` | 145 us | 145 us | 5.5 us |

`memory.copy` was testing only `Dst =< Src` to decide whether it needed a
backward copy, so every high-to-low copy took the byte-at-a-time path even when
the ranges were disjoint. `load_bytes` was building 8192 small binaries and
joining them instead of accumulating into one.

Even after a 21x and an 11.8x fix, bulk memory remains 26x to 47x off the
memcpy ceiling, and that gap is irreducible in Erlang: the bytes have to be
assembled from 64-bit atomic words one at a time. This, unlike float
arithmetic, is where the optional native backend earns its place, and the
memory-model property test will validate it for free when it arrives.

## Table representation

Tables are `array`, not flat tuples. A tuple gives O(1) reads, which looks
right because `call_indirect` reads on every dynamic call, but it makes every
write copy the whole table. Measured on a 10,000-element table:

| operation | tuple + `setelement` | `array` |
| --- | ---: | ---: |
| bulk fill of 10,000 | 33,858 us | 248 us |
| 1,000 scattered writes | 3,779 us | 17 us |
| 1,000,000 reads | 1,916 us | 5,316 us |

Reads get 2.8x slower, but an indirect call also does a type check, a fuel
charge and frame setup, so 3.4 ns is a few percent of the operation. Writes get
222x faster, and the sequential-`setelement` bulk operations were O(n squared),
which for untrusted code is a denial-of-service vector rather than a slow path.
Luerl reaches the same conclusion for Lua's integer-keyed table part.

## Float representation, and why there is no NIF

Erlang floats are native IEEE 754 doubles, but they cannot hold NaN or
Infinity. Every route in is closed: arithmetic and `math:*` raise `badarith`,
and `binary_to_term`, `list_to_float`, `erlang:float/1` and `<<F:64/float>>`
matching all reject those bit patterns. So floats are hybrid: Erlang floats for
finite values, `infinity` / `neg_infinity` / `{nan, Sign, Payload}` for the rest.

The obvious response is to push float arithmetic into C. Measured, f64 add,
1,000,000 operations:

| approach | ns/op | can represent NaN/Inf? |
| --- | ---: | --- |
| hybrid Erlang (used here) | **8.9** | yes |
| C NIF, bit patterns | 13.1 | yes |
| binary re-encode per op | 27.1 | yes |
| C NIF, raw doubles | 9.2 | **no** |

The NIF loses. `enif_make_double` rejects non-finite values too, so a
NaN-capable NIF has to return the raw 64-bit pattern, and every such pattern
exceeds 2^59 and is therefore a heap bignum allocated on every operation. The
raw-double NIF avoids that but cannot implement WebAssembly f64 at all. Pure
Erlang wins here on measurement, not on principle.