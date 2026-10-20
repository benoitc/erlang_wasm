# Garbage collection

How the garbage-collection proposal is implemented: where structs and arrays
live, how they are collected, what that costs, and the roots that are easy to
miss. Read this before you change `wasm_heap`, the GC instructions in
`wasm_exec`, or anything that holds a reference across a call: each section
below is a way to free a live object or to make every call pay for the heap.

## Why the runtime collects its own objects

Objects cannot ride on BEAM garbage collection.

- A struct is mutable and two references must both see a write, so it cannot
  be a value copied into each holder.
- It may reference other objects cyclically, so it cannot be an immutable term
  rebuilt on each write.
- The BEAM's only *traced* mutable container is `atomics`, which holds
  integers. ETS and `persistent_term` are mutable but invisible to Erlang's
  collector.

So the object graph lives in a store this runtime owns, and this runtime
collects it.

That is affordable because **the interpreter owns all execution state
explicitly.** Between calls the operand stack is empty, so the roots are
enumerable: the globals, the tables and the passive element segments of every
instance sharing the store, plus whatever the embedder is holding. Tracing from
there needs no stack maps, no safe points and no cooperation from the compiler
that produced the module. A runtime keeping execution state on the C stack
could not do this.

`i31` is not an object. It is an immediate that allocates nothing, which is the
point of the type.

## Where objects live

The store is a handle, `{wasm_heap, Objects, Elements, Counters}`, carried in
`#inst{}`, the immutable half of an instance. The tables it names are mutated
in place, so a field write leaves the instance state untouched.

```text
  objects   ets set
    struct  {Id, s, TypeIdx, F0, F1, ...}     one element per field
    array   {Id, a, TypeIdx, Len, Default}    the header only
  elements  ets ordered_set, keyed {Id, Index}
    array elements that have been written, and the write barrier's
    remembered set
  counters  atomics: next id, watermark, leases, charge, trigger
```

- Reading a field copies the field, not the object.
- An array of a million defaults costs one row. The ordering lets the
  collector walk one array's elements without scanning the table.
- Every heap gets both tables, because the remembered set has to live
  somewhere and a third table would cost more.
- A module that declares no struct or array type gets no heap and pays
  nothing.
- Ids come from an `atomics` counter and are never reused, so `ref.eq` is an
  integer comparison. The sweep walks rows, not the id space, so it costs
  what is in the store; the mark bitmap is still sized to the highest id.

ETS, not `array`, although `array` is faster per operation (13.4 ns against
33.9 ns for a read, 50.6 ns against 93.0 ns for a write). An `array` has to be
written back somewhere to be shared, and writing it back copies it, so its
cost is per call and proportional to the heap. ETS rows are mutated in place.

## Two generations

A collection is **minor** unless the store has grown past `gc_major_ratio`
times what it was after the last major, measured in objects *or* in pages.

| setting | default | what it does |
| --- | ---: | --- |
| `gc_alloc_threshold` | 100,000 | allocations between collections |
| `gc_major_ratio` | 2 | growth since the last major that makes one due |
| `gc_min_major_size` | 4,096 | no major below this many objects |
| `gc_min_major_pages` | 16 | no major below this many pages |

Both units, because a store can be enormous and hold five objects. A workload
replacing one large array per call never passes the object floor; without the
page rule it never gets a major collection and nothing it drops is reclaimed.
Four rounds of a fifty thousand element array left all four in the store,
sixteen megabytes, with one reachable. The same page rule also triggers a
collection when the store has grown in pages, not only after
`gc_alloc_threshold` allocations.

```text
  ids   0 ........ watermark ........ next_id
        |-- old generation --|-- nursery --|

  minor  mark from roots + remembered set, stop at ids below watermark,
         sweep [watermark, next_id)
  major  mark from roots, sweep every row
  both   then watermark := next_id, clear the remembered set
```

- **The nursery needs no bookkeeping.** Ids are never reused, so the objects
  allocated since the last collection are exactly `[watermark, next_id)`, and
  sweeping it is a loop over integers.
- **The write barrier** in `struct.set` and `array.set` is what makes skipping
  the old generation sound: an old object can reach a young one only through a
  write made since the last collection. It costs nothing unless the value is a
  reference *and* the container is old.
- **The watermark moves before the remembered set is cleared.** A collector
  killed between the two leaves a remembered set larger than needed, which
  costs a longer trace and frees nothing live.
- **A minor collection cannot reclaim old objects.** An old object that becomes
  unreachable waits for a major.
- **Mark and sweep, not copying**, because ids are compared by `ref.eq` and
  must not move. The mark set is an `atomics` bitmap and the worklist holds
  ids.

## When a collection runs

- Only at the outermost invocation, counted per process, because two instances
  calling each other share one Erlang stack. A host import may call another
  instance, and below a live frame the locals and operand stack hold
  references nothing can see.
- A call that allocates nothing pays a few `atomics` reads in
  `wasm_heap:should_collect/1`.
- Across processes, an execution takes a read lease on the store
  (`wasm_heap:lease/1`) and a collector needs it exclusively. A request never
  blocks: if others are inside, it is recorded and the last one out performs
  it. A running collection is exclusive, so a call arriving then waits a
  bounded time. If execution never stops, collection never runs, and the
  memory limits are the backstop.
- The pause is ordinary Erlang walking ordinary terms, so it is preemptible and
  does not block a scheduler.

## What it costs

Run these yourself with `rebar3 bench`, which runs `wasm_gc_bench_SUITE`. Every
number is a minimum of five rounds, and the arms that need one have a null arm
beside them. Set `WASM_BENCH_FULL=1` for the 10^6 sizes.

**A field write does not depend on heap size.** With the store inside the
instance state, `wasm_instance:set_mut/2` copied every object on each mutating
call, because ETS copies on insert. As a handle:

| heap | `touch` (one `struct.set`), store in `#mut{}` | store as a handle |
| ---: | ---: | ---: |
| 1,000 | 20.7 us | **0.23 us** |
| 10,000 | 199.0 us | **0.22 us** |
| 100,000 | 1993.6 us | **0.21 us** |

That is 19.7 ns of write-back per object in the heap, per mutating call, gone.

Watch for this when you write a benchmark against it. The write-back skip is
*structural* equality, so a call that stores the same value it stored last time
produces a term equal to its predecessor and skips the write-back anyway. The
first version of the benchmark above did that and reported a flat 0.21 us at
every heap size: the right answer for the wrong reason.

**A minor pause is flat as the live set grows:**

| old objects | major collection | **minor after 1000 allocations** |
| ---: | ---: | ---: |
| 1,000 | 0.123 ms | 0.075 ms |
| 10,000 | 1.262 ms | 0.077 ms |
| 100,000 | 14.928 ms | **0.083 ms** |

At a hundred thousand live objects a minor is 180 times shorter than a major.

**The write barrier**, net of the call:

| store | cost |
| --- | ---: |
| `struct.get` | 44.8 ns |
| `struct.set` of a number | 52.5 ns |
| `struct.set` of a reference into an old object | 170.5 ns |

118 ns when it fires, one pattern match when it does not.

**Collection**, mark and sweep from a chain of live objects, before and after
the store moved to ETS:

| case | before | now |
| --- | ---: | ---: |
| 1,000 live | 108 us | 123 us |
| 10,000 live | 1.72 ms | 1.25 ms |
| 100,000 live | 21.8 ms | **14.7 ms** |
| 1,000 live, 10,000 garbage | 625 us | **124 us** |
| 1,000 live, 100,000 garbage | 6.35 ms | **175 us** |

The gain is in the sweep: 63.5 ns per dead object down to 1.8 ns, because a
dead object is one `ets:delete` rather than a path copy through a functional
array. Marking is around 140 ns per live object.

**A collection does not allocate on the caller's BEAM heap.** A map live set
and a worklist built with `++` grew it; an `atomics` bitmap and a worklist of
ids do not:

| live objects | peak process heap, map live set | bitmap |
| ---: | ---: | ---: |
| 1,000 | 53,194 words (35.5 per object) | 609 words |
| 10,000 | 225,340 words (10.4 per object) | 3,286 words |
| 100,000 | 2,045,548 words (8.5 per object) | **3,246 words** |

Six and a half megabytes to collect a hundred thousand objects, down to
constant. A collection is supposed to release memory.

Where the mark time goes, against a 2.9 ns null arm:

| primitive | cost |
| --- | ---: |
| `array:get` | 13.4 ns |
| `array:set` | 50.6 ns |
| `array:reset` | 42.6 ns |
| `ets:lookup_element` | 33.9 ns |
| `ets:update_element` | 93.0 ns |
| `atomics` mark bit, get and put | 23.7 ns |
| map live-set insert | 76.1 ns |

**Bulk array operations**, per element written. Reductions first, because this
box has been seen between load 4 and 84 and the nanosecond column moves by more
than the change it is meant to show; the times were taken at load average 3.5.

| elements | `array.copy` | `array.fill` whole | `array.fill` sparse | `array.fill` dense |
| ---: | ---: | ---: | ---: | ---: |
| 100 | 9.2 reds, 281 ns | 2.0 reds, 66 ns | 8.1 reds, 215 ns | 7.7 reds, 123 ns |
| 1,000 | 7.2 reds, 259 ns | 0.2 reds, 9 ns | 6.2 reds, 175 ns | 6.3 reds, 152 ns |
| 10,000 | **7.0 reds, 279 ns** | 0.0 reds, 0.6 ns | 6.0 reds, 174 ns | 6.0 reds, 146 ns |

- A fill covering the whole array is one row update: every element becoming
  the same value is what an array's default means here.
- A partial fill writes every element. A sparse fill creates a row per index;
  a dense one replaces a row that exists.
- `array.copy` was 19.9 reductions an element before it moved into
  `wasm_heap`: it built three lists per copy and read the array's length once
  per element. It reads the source's default once and decides an overlapping
  copy by direction, so nothing is materialised. What is left per element is
  two table operations and one `atomics:add_get`, about 6% of it.

**An array whose elements cannot be references is never walked.** The
collector marks it and stops. Collecting one live array with fifty thousand
written elements:

| array | collection |
| --- | ---: |
| `(array (mut i32))` | below 1 us |
| `(array (mut (ref null $t)))` | 4307 us |

That is most of what a language like Java or Kotlin allocates.

## What this cost

The price of the above, measured one arm per VM:

| path | before | after |
| --- | ---: | ---: |
| call round trip, no objects | 0.478 us | 0.433 us |
| instantiate, no GC types | 1.669 us | 1.587 us |
| **instantiate, GC types** | **2.672 us** | **5.053 us** |
| `struct.get` net of the call | 34.0 ns | 51.5 ns |
| `struct.new` | 164 ns | 215 ns |

What a module with GC types pays: two ETS tables and an `atomics` array per
instance that can allocate, the row recording which instances share the store,
and a field read at ETS prices instead of `array` prices.

Two microseconds were found by measuring rather than by reasoning. Keeping the
instance registry in the engine's shared, named, write-concurrent table cost
2.2 us of a 6.0 us instantiation; it is a row in the heap's own objects table.
Registering the whole `#inst{}` cost another 1.9 us, because ETS copies on
insert; only the four fields a root scan reads are registered.

**A major collection costs about 124 ns per live object**, so a hundred
thousand live objects stop that instance for 12.4 ms. That is close to the
floor for this storage:

| per object | cost |
| --- | ---: |
| `ets:lookup` of the row, to reach its fields | 35.8 ns |
| `atomics` mark bit, get and put | 22.3 ns |
| `ets:next` per row in the sweep | 24.2 ns |
| the collector's own Erlang | the rest |

Rejected, with the numbers:

- Sweeping with a chunked `ets:select` instead of `ets:first`/`ets:next`:
  **worse**, 36.6 ns per key against 24.2.
- Inlining the field scan and hoisting `tuple_size/1` out of the loop: 1.7%,
  12.585 to 12.375 ms, within run-to-run spread. Kept because it is not
  worse, not because it helped.
- Encoding "holds no references" in the object id to skip the row lookup: ids
  would stop being dense and every minor sweep would probe absent ids. The
  common case is the one to protect.

The lever that works is not marking, which is what the generation is: a
program with a stable live set never has a major.

## What the heap costs the node

Objects are ETS rows, which neither `max_heap_size` nor the `atomics` page
count can see. So a heap is a `wasm_keeper` resource, charged in pages against
the node budget like a memory (see [Memory](memory.md)).

- The charge is reconciled every 64K words written, counted by what each row
  costs, not by operations: one `struct.new_default` of a wide type can be
  800 KB.
- Only a guest allocating is refused, with a `heap_limit` exhaustion error.
  A collection charges too and is never refused, since it is what makes the
  charge fall.
- The tables are inherited by the keeper, so killing the creating process does
  not destroy a store a linked instance is still running on.

## What a trap does not undo

A trap ends the computation; it does not undo it.

- Object writes take effect immediately. A `struct.set` before a trap stays
  written. The store is shared and mutated in place, so there is nothing to
  roll back, and the specification describes no rollback.
  `wasm_gc_collect_SUITE` pins it.
- Memories and tables are shared structures and keep their writes too.
- A global that is not a cell, the size a private memory grew to, and the
  dropped-segment sets are threaded through the interpreter's own state. Each
  is recorded as it happens and committed by the invocation's catch, so the
  trap does not take them with the stack it unwinds.
  `wasm_trap_effects_SUITE` pins all five cases.

## Roots that were not roots

Ways to lose a live object, none of them reachable from `#mut{}`, which is
where the collector reads its roots. Each passed every other test while being
wrong. `wasm_gc_roots_SUITE` covers them.

**Passive element segments.** A segment's elements come from constant
expressions and `struct.new` is one, so a segment can be the only thing
referring to an object. Segments live in the immutable half of the instance,
so they have to be added as roots explicitly; otherwise `array.new_elem` hands
out references into reset slots. A dropped segment is not a root, since it can
never be read again.

**Collection below a live frame.** A host import may call another instance,
and that call returns into a frame whose locals and operand stack hold
references nothing can see. Collection runs only at the outermost invocation.

**A failed instantiation.** Constant-expression evaluation threads its
allocation store through the process dictionary. An instantiation that fails
after allocating must erase it, or the next instantiation *in that process*
adopts a heap it did not allocate.

**Another instance's globals.** A reference is an id into a store, so two
modules that pass structs or arrays between them must share one. Link them at
instantiation:

```erlang
{ok, A} = wasm:instantiate(ModA, #{}),
{ok, T} = wasm:extern(A, ~"table"),
{ok, B} = wasm:instantiate(ModB, #{{~"env", ~"t"} => T}, #{link => A}).
```

- A collection triggered by either one traces both, because an object B can
  no longer reach may still be held by a global or a table of A's.
- The store goes when the last instance sharing it goes.
- Without `link` the two have separate stores, and reading a reference from
  the other traps with `foreign_reference` instead of reading whatever object
  holds that id.
- Linking is explicit rather than inferred from the import map: `extern/2`
  hands out a table, a memory or a cell, none of which names the instance
  that produced it.

**Re-entering a running instance.** The specification requires re-entrancy,
and `linking.wast` calls back into a module that is still running. A nested
call that read the state as of the last write-back could not see the outer
call's writes, and the outer call's write-back then discarded the inner one's:
a host import calling back into its own instance allocated four objects and
the outer return dropped the store to one. A call publishes its state before
handing control to a host function and adopts whatever comes back.

## Type answers resolved once

Three answers cannot change once a module is validated, so they are resolved
in the cached validation context, which every instance of a module shares:

| | recomputed | resolved once |
| --- | ---: | ---: |
| `struct.get`, field 0 | 37.0 ns | 36.0 ns |
| `struct.get`, field 15 | 44.7 ns | **33.6 ns** |
| `ref.test` against a concrete type | 96.1 ns | **84.5 ns** |

- A field was found with `lists:nth/2` over a list rebuilt from the type table,
  so its cost grew with its index. It is two `element/2` calls.
- A cast recomputed its target's canonical supertype closure and searched it
  on every execution. Casts are the most frequent instructions in real
  toolchain output: `ref.test` appears 121 times across the specification's
  garbage collection suites, against 46 for `struct.new_default`.

Measured inside wasm rather than per call, because the difference is tens of
nanoseconds and a call round trip is four hundred.

## What destroying an instance releases

`wasm:destroy/1` releases:

- the instance's memory pages;
- its object store, when it is the last instance sharing it;
- the ETS table holding its state;
- this process's cached copy of that state, which `wasm_instance:mut/1` keeps
  in the process dictionary keyed by instance id.

Calling `destroy/1` twice decrements the node's page count once.

Table arrays, global cells and shared-memory chunk tuples cannot be dropped
when their creator exits, because an exported table outlives the instance that
made it. Each is held by a set of keeper tokens: the instance that created it,
every instance that imported it, and the process that made it if it was made
standalone. It goes when the last of them lets go, and releasing a token twice
removes nothing the second time.

## References the embedder holds

A reference that leaves the runtime is not reachable from any root the runtime
can see, so it is **pinned**: call results, `wasm:get_global/2` results, and
the values carried by an uncaught exception.

Pins are reference counted and released explicitly:

```erlang
{ok, [Ref]} = wasm:call(Inst, ~"make", []),
%% ... use it ...
ok = wasm:release(Inst, Ref).
ok = wasm:release_all(Inst).        % or drop the lot, per request
```

- The pins live beside the objects, so pinning costs no state write-back.
- Without release, an embedder calling a function that returns a struct a
  million times keeps a million objects alive.
- Pin explicitly with `wasm:pin/2` in one case: a **host function that keeps a
  reference it was passed**. Its arguments are safe for the duration of the
  call, because collection does not run below a live frame, and not after.
- Ids are not reused because an unpinned reference must trap rather than name
  a different live object.

## Read this next

[Architecture](architecture.md) for where the heap sits among the other
modules, or [Design notes](design-notes.md) for the rest of the runtime's
decisions.
