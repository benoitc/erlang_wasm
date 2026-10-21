# Garbage collection

This page explains how the runtime implements the WebAssembly garbage
collection proposal: where structs and arrays are stored, how they are
collected, what that costs, and which roots are easy to miss. Read it before
you change `wasm_heap`, the GC instructions in `wasm_exec`, or any code that
keeps a reference across a call. Each section describes a way to free an
object that is still in use, or to make every call slower because of the heap.

## The words on this page

| word | what it means here |
| --- | --- |
| **object** | a struct or an array created by a guest with the GC instructions. |
| **store** | where the objects of one instance, or of linked instances, are kept. |
| **root** | a place the collector starts from: a global, a table, a segment, or a reference the embedder holds. Anything it cannot reach from a root is freed. |
| **live** | reachable from a root, so it must not be freed. |
| **minor**, **major** | a collection that looks only at new objects, and one that looks at all of them. |
| **nursery** | the objects created since the last collection. |
| **watermark** | the first id of the nursery. Older ids belong to the old generation. |
| **write barrier** | a check on each write that records when an old object starts to point to a new one. |
| **remembered set** | the old objects that the write barrier recorded. |
| **pin** | a mark that keeps an object alive while the embedder holds a reference to it. |
| **null arm** | a benchmark that does the same work without the operation measured, to subtract its cost. |

## Why the runtime collects its own objects

The BEAM garbage collector cannot manage these objects, for three reasons.

- A struct can change, and two references to it must both see a write. So it
  cannot be a value copied into each holder.
- Objects can refer to each other in cycles. So an object cannot be an
  immutable term rebuilt on each write.
- The only changeable container that the BEAM collector *traces* is
  `atomics`, and it holds only integers. ETS and `persistent_term` can change,
  but Erlang's collector does not see inside them.

So the objects live in a store that this runtime owns, and this runtime
collects them.

This is possible because **the interpreter keeps all execution state itself.**
Between calls the operand stack is empty, so the runtime can list every root:
the globals, the tables and the passive element segments of every instance
that shares the store, plus the references the embedder holds. Tracing from
there needs no stack maps, no safe points and no help from the compiler that
produced the module. A runtime that keeps execution state on the C stack could
not do this.

`i31` is not an object. It is a value stored directly in the reference and it
allocates nothing. That is the purpose of the type.

## Where objects live

The store is a handle, `{wasm_heap, Objects, Elements, Counters}`, kept in
`#inst{}`, the part of an instance that never changes. The tables it names are
changed in place, so writing a field does not change the instance state.

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
- An array of a million default values takes one row. The ordering lets the
  collector visit one array's elements without scanning the whole table.
- Every heap gets both tables, because the remembered set must be stored
  somewhere and a third table would cost more.
- A module that declares no struct or array type gets no heap and costs
  nothing extra.
- Ids come from an `atomics` counter and are never reused, so `ref.eq` is an
  integer comparison. The sweep visits rows, not every possible id, so its
  cost depends on what is in the store. The mark bitmap still has one bit for
  each id up to the highest.

The store uses ETS, not `array`, although `array` is faster per operation
(13.4 ns against 33.9 ns for a read, 50.6 ns against 93.0 ns for a write). To
be shared, an `array` must be written back somewhere, and writing it back
copies it. So its cost comes on every call and grows with the heap. ETS rows
are changed in place.

## Two generations

A collection is **minor**, unless the store has grown to more than
`gc_major_ratio` times its size after the last major collection. Size is
counted in objects *or* in pages.

| setting | default | what it does |
| --- | ---: | --- |
| `gc_alloc_threshold` | 100,000 | allocations between collections |
| `gc_major_ratio` | 2 | growth since the last major that makes one due |
| `gc_min_major_size` | 4,096 | no major below this many objects |
| `gc_min_major_pages` | 16 | no major below this many pages |

Both units are needed, because a store can be very large and hold only five
objects. A workload that replaces one large array on each call never reaches
the object minimum. Without the page rule, it never gets a major collection,
and nothing it drops is freed. Four rounds of a fifty thousand element array
left all four arrays in the store, sixteen megabytes, with only one reachable.
The page rule also starts a collection when the store has grown in pages, not
only after `gc_alloc_threshold` allocations.

```text
  ids   0 ........ watermark ........ next_id
        |-- old generation --|-- nursery --|

  minor  mark from roots + remembered set, stop at ids below watermark,
         sweep [watermark, next_id)
  major  mark from roots, sweep every row
  both   then watermark := next_id, clear the remembered set
```

- **The nursery needs no extra records.** Ids are never reused, so the
  objects allocated since the last collection are exactly
  `[watermark, next_id)`, and sweeping them is a loop over integers.
- **The write barrier** in `struct.set` and `array.set` makes it correct to
  skip the old generation: an old object can reach a new one only through a
  write made since the last collection. The barrier costs nothing unless the
  value is a reference *and* the container is old.
- **The watermark moves before the remembered set is cleared.** If the
  collector is killed between the two, the remembered set is larger than
  needed. The next trace takes longer, but nothing live is freed.
- **A minor collection cannot free old objects.** An old object that becomes
  unreachable waits for a major collection.
- **Mark and sweep, not copying**, because `ref.eq` compares ids, so objects
  must not move. The mark set is an `atomics` bitmap and the list of objects
  still to visit holds ids.

## When a collection runs

- Only when the outermost call returns, counted per process, because two
  instances that call each other share one Erlang stack. A host import may
  call another instance. Below a running frame, the locals and the operand
  stack hold references that the collector cannot see.
- A call that allocates nothing costs a few `atomics` reads in
  `wasm_heap:should_collect/1`.
- Across processes, a running call takes a shared read lease on the store
  (`wasm_heap:lease/1`), and a collector needs the store for itself alone. A
  request to collect never waits: if calls are running, the request is
  recorded and the last call to leave runs the collection. While a collection
  runs, no call can enter, so a call that arrives then waits for a limited
  time. If calls never stop, the collection never runs, and the memory limits
  are the last protection.
- The pause is normal Erlang code reading normal terms, so the scheduler can
  interrupt it and other processes keep running.

## What it costs

You can run these benchmarks with `rebar3 bench`, which runs
`wasm_gc_bench_SUITE`. Every number is the minimum of five rounds. Where it is
needed, a null arm runs next to the benchmark. Set `WASM_BENCH_FULL=1` for the
10^6 sizes.

**A field write does not depend on heap size.** When the store was inside
the instance state, `wasm_instance:set_mut/2` copied every object on each call
that changed state, because ETS copies on insert. With the store as a
handle:

| heap | `touch` (one `struct.set`), store in `#mut{}` | store as a handle |
| ---: | ---: | ---: |
| 1,000 | 20.7 us | **0.23 us** |
| 10,000 | 199.0 us | **0.22 us** |
| 100,000 | 1993.6 us | **0.21 us** |

This removes 19.7 ns of write-back per object in the heap, on each call that
changes state.

Be careful when you write a benchmark for this. The runtime skips the
write-back when the new state is *structurally* equal to the old one. So a
call that stores the same value as last time produces an equal term and skips
the write-back anyway. The first version of the benchmark above did this and
reported 0.21 us at every heap size: the right result, for the wrong reason.

**A minor pause is flat as the live set grows:**

| old objects | major collection | **minor after 1000 allocations** |
| ---: | ---: | ---: |
| 1,000 | 0.123 ms | 0.075 ms |
| 10,000 | 1.262 ms | 0.077 ms |
| 100,000 | 14.928 ms | **0.083 ms** |

With a hundred thousand live objects, a minor collection is 180 times shorter
than a major one.

**The write barrier**, without the cost of the call:

| store | cost |
| --- | ---: |
| `struct.get` | 44.8 ns |
| `struct.set` of a number | 52.5 ns |
| `struct.set` of a reference into an old object | 170.5 ns |

The barrier costs 118 ns when it records a write, and one pattern match when
it does not.

**Collection**, mark and sweep from a chain of live objects, before and after
the store moved to ETS:

| case | before | now |
| --- | ---: | ---: |
| 1,000 live | 108 us | 123 us |
| 10,000 live | 1.72 ms | 1.25 ms |
| 100,000 live | 21.8 ms | **14.7 ms** |
| 1,000 live, 10,000 garbage | 625 us | **124 us** |
| 1,000 live, 100,000 garbage | 6.35 ms | **175 us** |

The gain is in the sweep: from 63.5 ns to 1.8 ns per dead object, because
freeing a dead object is one `ets:delete`, not a copy of the path through a
functional array. Marking costs about 140 ns per live object.

**A collection does not allocate on the caller's BEAM heap.** A map of live
objects and a work list built with `++` made that heap grow. An `atomics`
bitmap and a work list of ids do not:

| live objects | peak process heap, map live set | bitmap |
| ---: | ---: | ---: |
| 1,000 | 53,194 words (35.5 per object) | 609 words |
| 10,000 | 225,340 words (10.4 per object) | 3,286 words |
| 100,000 | 2,045,548 words (8.5 per object) | **3,246 words** |

Collecting a hundred thousand objects needed six and a half megabytes; now it
needs a constant amount. A collection should free memory, not use it.

Where the mark time goes, with a null arm at 2.9 ns:

| primitive | cost |
| --- | ---: |
| `array:get` | 13.4 ns |
| `array:set` | 50.6 ns |
| `array:reset` | 42.6 ns |
| `ets:lookup_element` | 33.9 ns |
| `ets:update_element` | 93.0 ns |
| `atomics` mark bit, get and put | 23.7 ns |
| map live-set insert | 76.1 ns |

**Bulk array operations**, per element written. Reductions (the BEAM's count
of work done) come first, because this machine's load average has varied
between 4 and 84, and the times in nanoseconds then vary more than the change
they should show. The times were taken at load average 3.5.

| elements | `array.copy` | `array.fill` whole | `array.fill` sparse | `array.fill` dense |
| ---: | ---: | ---: | ---: | ---: |
| 100 | 9.2 reds, 281 ns | 2.0 reds, 66 ns | 8.1 reds, 215 ns | 7.7 reds, 123 ns |
| 1,000 | 7.2 reds, 259 ns | 0.2 reds, 9 ns | 6.2 reds, 175 ns | 6.3 reds, 152 ns |
| 10,000 | **7.0 reds, 279 ns** | 0.0 reds, 0.6 ns | 6.0 reds, 174 ns | 6.0 reds, 146 ns |

- A fill of the whole array updates one row: it changes the array's default
  value, which every element then has.
- A partial fill writes every element. A sparse fill creates one row per
  index; a dense fill replaces a row that already exists.
- `array.copy` cost 19.9 reductions per element before it moved into
  `wasm_heap`: it built three lists per copy and read the array's length once
  per element. Now it reads the source's default once and handles an
  overlapping copy by choosing the copy direction, so it builds no
  intermediate list. What is left per element is two table operations and one
  `atomics:add_get`, about 6% of the cost.

**The collector never visits the elements of an array that cannot hold
references.** It marks the array and stops. Collecting one live array with
fifty thousand written elements:

| array | collection |
| --- | ---: |
| `(array (mut i32))` | below 1 us |
| `(array (mut (ref null $t)))` | 4307 us |

Arrays like the first one are most of what a language like Java or Kotlin
allocates.

## What this cost

What the design above costs, measured with one benchmark per VM:

| path | before | after |
| --- | ---: | ---: |
| call round trip, no objects | 0.478 us | 0.433 us |
| instantiate, no GC types | 1.669 us | 1.587 us |
| **instantiate, GC types** | **2.672 us** | **5.053 us** |
| `struct.get` net of the call | 34.0 ns | 51.5 ns |
| `struct.new` | 164 ns | 215 ns |

What a module with GC types costs: two ETS tables and an `atomics` array for
each instance that can allocate, the row that records which instances share
the store, and field reads at the speed of ETS instead of `array`.

Measurement, not reasoning, found two microseconds. Keeping the instance
registry in the engine's shared, named, write-concurrent table cost 2.2 us of
a 6.0 us instantiation; it is now a row in the heap's own objects table.
Registering the whole `#inst{}` cost another 1.9 us, because ETS copies on
insert; now only the four fields that a root scan reads are registered.

**A major collection costs about 124 ns per live object**, so a hundred
thousand live objects stop that instance for 12.4 ms. With this storage, it
cannot be much faster:

| per object | cost |
| --- | ---: |
| `ets:lookup` of the row, to reach its fields | 35.8 ns |
| `atomics` mark bit, get and put | 22.3 ns |
| `ets:next` per row in the sweep | 24.2 ns |
| the collector's own Erlang | the rest |

Tried and rejected, with the numbers:

- Sweeping with a chunked `ets:select` instead of `ets:first`/`ets:next`:
  **slower**, 36.6 ns per key against 24.2.
- Inlining the field scan and moving `tuple_size/1` out of the loop: 1.7%,
  12.585 to 12.375 ms, within the normal variation between runs. Kept because
  it is not slower, not because it helped.
- Storing "holds no references" in the object id to skip the row lookup: ids
  would no longer follow each other, and every minor sweep would look up ids
  that do not exist. The common case matters more.

What works is to mark less, and that is what the generations do: a program
whose live objects do not change never needs a major collection.

## What the heap costs the node

Objects are ETS rows. Neither `max_heap_size` nor the count of `atomics`
pages can see them. So a heap is a resource of `wasm_keeper`, the process that
tracks who holds shared resources. Its size is counted in pages against the
node's page budget, like a memory (see [Memory](memory.md)).

- The count is updated after every 64K words written. It counts what each row
  costs, not the number of operations: one `struct.new_default` of a wide type
  can take 800 KB.
- Only a guest's allocation can be refused, with a `heap_limit` exhaustion
  error. A collection updates the count too and is never refused, because it
  is what makes the count go down.
- The keeper takes over the tables, so killing the process that created them
  does not destroy a store that a linked instance still uses.

## What a trap does not undo

A trap stops the computation; it does not undo it.

- Object writes take effect at once. A `struct.set` before a trap stays
  written. The store is shared and changed in place, so there is nothing to
  undo, and the specification describes no undo. `wasm_gc_collect_SUITE`
  checks this.
- Memories and tables are shared structures, and they keep their writes too.
- A global that is not a cell, the size a private memory grew to, and the sets
  of dropped segments are kept in the interpreter's own state. Each change is
  recorded when it happens and saved by the `catch` of the call, so the trap
  does not lose them when it unwinds the stack. `wasm_trap_effects_SUITE`
  checks all five cases.

## Roots that were not roots

These are ways to lose a live object. None of these roots can be reached
from `#mut{}`, where the collector reads its roots. Each one was a bug that
passed every other test. `wasm_gc_roots_SUITE` covers them.

**Passive element segments.** A segment's elements come from constant
expressions, and `struct.new` is one of them. So a segment can be the only
thing that refers to an object. Segments are kept in the part of the instance
that never changes, so they must be added as roots explicitly. Otherwise
`array.new_elem` gives out references to slots that were freed. A dropped
segment is not a root, because it can never be read again.

**Collection below a running frame.** A host import may call another
instance, and that call returns into a frame whose locals and operand stack
hold references that the collector cannot see. So collection runs only when
the outermost call returns.

**A failed instantiation.** Constant expressions keep their allocation store
in the process dictionary while they run. An instantiation that fails after
allocating must erase it. Otherwise the next instantiation *in that process*
takes over a heap it did not allocate.

**Another instance's globals.** A reference is an id in a store, so two modules
that pass structs or arrays to each other must share one store. Link them when
you instantiate:

```erlang
{ok, A} = wasm:instantiate(ModA, #{}),
{ok, T} = wasm:extern(A, ~"table"),
{ok, B} = wasm:instantiate(ModB, #{{~"env", ~"t"} => T}, #{link => A}).
```

- A collection started by either instance traces both, because an object
  that B can no longer reach may still be held by a global or a table of A.
- The store is freed when the last instance that shares it is destroyed.
- Without `link`, the two have separate stores. Reading a reference that comes
  from the other one traps with `foreign_reference`; it does not read the
  object that happens to have that id.
- You must link explicitly; the runtime does not guess it from the import map.
  `extern/2` gives out a table, a memory or a cell, and none of them names the
  instance that created it.

**Calling back into a running instance.** The specification allows a call to
enter an instance that is already running, and `linking.wast` does this. A
nested call that read the state from the last write-back could not see the
writes of the outer call. Then the outer call's write-back threw away the
inner call's writes: a host import that called back into its own instance
allocated four objects, and when the outer call returned the store had one.
Now a call saves its state before it calls a host function, and uses the state
that comes back.

## Type answers resolved once

Three answers about types cannot change once a module is validated. So they
are computed once, in the cached validation context, which every instance of a
module shares:

| | recomputed | resolved once |
| --- | ---: | ---: |
| `struct.get`, field 0 | 37.0 ns | 36.0 ns |
| `struct.get`, field 15 | 44.7 ns | **33.6 ns** |
| `ref.test` against a concrete type | 96.1 ns | **84.5 ns** |

- A field was found with `lists:nth/2` over a list rebuilt from the type
  table, so its cost grew with its index. Now it is two `element/2` calls.
- A cast computed the full list of its target's supertypes again, and searched
  it, every time it ran. Casts are the most frequent instructions in code that
  real compilers produce: `ref.test` appears 121 times in the specification's
  garbage collection tests, against 46 for `struct.new_default`.

These were measured inside wasm, not per call, because the difference is tens
of nanoseconds and a call round trip takes four hundred.

## What destroying an instance releases

`wasm:destroy/1` releases:

- the instance's memory pages;
- its object store, when it is the last instance sharing it;
- the ETS table holding its state;
- this process's cached copy of that state, which `wasm_instance:mut/1` keeps
  in the process dictionary keyed by instance id.

Calling `destroy/1` twice lowers the node's page count only once.

Table arrays, global cells and shared-memory chunk tuples cannot be freed when
their creator exits, because an exported table can live longer than the
instance that made it. The keeper records who holds each one: the instance
that created it, every instance that imported it, and the process that made
it, if it was made on its own. It is freed when the last holder lets go.
Releasing the same hold twice frees nothing the second time.

## References the embedder holds

A reference that leaves the runtime cannot be reached from any root that the
runtime can see. So it is **pinned**: this applies to call results,
`wasm:get_global/2` results, and the values carried by an uncaught exception.

Each pin has a count, and you release it explicitly:

```erlang
{ok, [Ref]} = wasm:call(Inst, ~"make", []),
%% ... use it ...
ok = wasm:release(Inst, Ref).
ok = wasm:release_all(Inst).        % or drop the lot, per request
```

- The pins are stored next to the objects, so pinning needs no state
  write-back.
- If you never release, an embedder that calls a function returning a struct
  a million times keeps a million objects alive.
- Call `wasm:pin/2` yourself in one case: a **host function that keeps a
  reference it received**. Its arguments are safe during the call, because no
  collection runs below a running frame. After the call they are not.
- Ids are never reused, so that a reference that is no longer pinned traps; it
  never points to a different live object.

## Read this next

[Architecture](architecture.md) for where the heap sits among the other
modules, or [Design notes](design-notes.md) for the rest of the runtime's
decisions.
