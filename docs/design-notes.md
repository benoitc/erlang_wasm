# Design notes

Why the runtime is built the way it is, indexed by subject. Read a section when
you are about to change the thing it describes, so you find out what was already
tried before you try it again.

This is not the measurement record. `test/audit/PERF.md` is the lab notebook,
ordered by when each thing was discovered, and `test/audit/ATTEMPTS.md` lists
what was tried and reverted. Both are worth keeping in that order and neither is
a reference. This page is the reference, and it links into them.

[Threads](features.md#threads) are documented as a feature rather than here,
because what matters about them is what is implemented. So is the compiled
tier, in [its own guide](compiled-tier.md). The garbage collector and the WASI
sandboxes are at the end of this page: they were in the feature page until they
outgrew it.

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

## A request is three processes, not one

The worker kernel gives each request a **worker**, a **guardian** and a
**runner**, and the split is about who can be trusted to survive what.

The runner is the only process that touches tenant data: it instantiates,
invokes, decodes and dies. It is spawned `[link, monitor]` so that the monitor
delivers a `DOWN` carrying the exit reason, and the link kills it if the
guardian goes. The guardian traps exits, owns the mounts and the deadline, and
is the process a `cancel` acts on. The worker is the API and holds the single
in-flight slot.

Everything a request can leak -- a directory, a staged file, a registered
cleanup action -- is owned by the guardian and handed to a node-wide **reaper**
when the request ends. That reaper is a process and not an ETS table with the
worker as `heir`, for two reasons `worker_reaper` states: `heir` fires when the
*owner* dies, so a worker-owned table survives exactly the failure it is not
needed for; and deferring the sweep to the worker's next request leaks for as
long as that worker is idle, which for a lightly used tenant has no bound.

The cost of that shape is measurable and small. Accepting a request -- the
reservation, the request directory, the channels and the runner spawn -- is
1.7 to 2.3 ms, which on a 6 ms QuickJS request is a quarter of it. It has not
been attacked because nothing yet needs it to be smaller.

## A snapshot is a copy of state, not of an instance

`wasm:snapshot/1` does not freeze an instance. It copies the guest-visible
state -- the non-zero runs of each memory, the table contents, the globals --
and `restore/3` lays that over a **fresh** instance built from the same module
with **fresh imports**. Nothing of the host side travels: file descriptors,
sockets, clocks and random providers are the embedder's to supply again.

That is what makes a restored instance safe to hand a different tenant. It is
also why capture refuses an image holding a `funcref` into another instance or
any `externref`: those name something on this node that a restore has no way to
recreate, so the refusal is at capture, where it can still be explained.

Two consequences worth knowing before changing the restore path. A restore
writes only the runs, onto memory that is zero because the instance was built
without its active data segments applied -- they would be overwritten anyway,
and applying them made a restore pay twice. And the module is taken from the
handle the image retained rather than passed in, so there is no argument that
could lay one module's bytes over another's layout.

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
what it was after the last major (default 2), measured in objects *or* in bytes.

Both units, because a store can be enormous and hold five objects. A workload
replacing one large array per call never passes the object floor, and without
the byte rule it never gets a major collection at all, so nothing it drops is
ever reclaimed. The byte floor is `gc_min_major_pages`, default 16 pages.

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

**Bulk array operations**, per element written. Reductions first, because this
box has been seen between load 4 and 84 and the nanosecond column moves by more
than the change it is meant to show; the times beside them were taken at load
average 3.5.

| elements | `array.copy` | `array.fill` whole | `array.fill` sparse | `array.fill` dense |
| ---: | ---: | ---: | ---: | ---: |
| 100 | 9.2 reds, 281 ns | 2.0 reds, 66 ns | 8.1 reds, 215 ns | 7.7 reds, 123 ns |
| 1,000 | 7.2 reds, 259 ns | 0.2 reds, 9 ns | 6.2 reds, 175 ns | 6.3 reds, 152 ns |
| 10,000 | **7.0 reds, 279 ns** | 0.0 reds, 0.6 ns | 6.0 reds, 174 ns | 6.0 reds, 146 ns |

A fill covering the whole array is one row update, because every element
becoming the same value is what an array's default means here. A *partial* fill
writes every element, and the two partial columns are separate because they are
different operations: a sparse fill creates a row per index and a dense one
replaces a row that exists.

`array.copy` was 19.9 reductions an element before it moved into `wasm_heap`.
It built three lists per copy, and read the array's length from the object
table once per element to re-answer what the range check had already answered.
It reads the source's default once now, and decides an overlapping copy by
direction rather than by taking a snapshot, which is why nothing is
materialised. What is left in an element is two table operations and one
`atomics:add_get`, and the atomic is about 6% of it.

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
