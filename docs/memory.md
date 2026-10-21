# Memory

This page explains how the runtime stores a guest's linear memory, how a
restored memory shares its snapshot image, and how the runtime counts pages
for the whole node. Read it before you change `wasm_memory`, `wasm_keeper`,
`wasm_engine` or `wasm_snapshot`, or any code that reserves, grows or frees
pages. The storage format was chosen by measurement. The page counting is what
stops one guest from using all the memory of the node.

## The words on this page

| word | what it means here |
| --- | --- |
| **linear memory** | the array of bytes a WebAssembly guest reads and writes. It grows in **pages** of 64 KiB. |
| **chunk** | one `atomics` array holding part of a linear memory. |
| **snapshot** | a saved copy of an instance's state, taken so that new instances can start from it. See [Snapshots](snapshots.md). |
| **image** | the memory part of a snapshot: its pages, read-only, shared by every memory restored from it. |
| **restore** | making a new instance from a snapshot instead of running the guest's start-up code again. |
| **page table** | a small `atomics` array, one entry per 4 KiB page, that says where each page of a restored memory is now: still in the image, or in a private copy. |
| **arena** | the private 4 KiB copies of the image pages that one memory has written to. |
| **slot** | one 4 KiB place in the arena. |
| **keeper** | `wasm_keeper`, the process that records which process holds each memory, table or image. |
| **holder** | something whose existence keeps a resource alive, written as a token such as `{instance, Id}`. |
| **page budget** | the maximum number of pages the whole node may use for memory the Erlang VM cannot see. |

## Memory is chunked atomics arrays

Linear memory is a tuple of `atomics` arrays, not a binary and not a NIF.

- A binary cannot be mutated in place, so every store would copy the page.
- `atomics` is mutable in place and word-addressable,
  and it is an OTP built-in, so memory needs no native code of its own.
- Chunking keeps `memory.grow` from copying the whole memory: growth appends a
  chunk to the tuple.

The cost is that a narrow store is a read-modify-write: about 9.6 to 19
nanoseconds against 4.8 for a plain `atomics:get`. An aligned i64 store is one
`put`; an access spanning two words takes a slower path.

A NIF would be faster and was declined. It puts the sandbox boundary in C,
where a bug is a node crash rather than a trap, and the pure Erlang version is
what makes the safety claims checkable.
`wasm_prop_SUITE:memory_matches_model` runs random sequences of load, store,
fill, copy and grow against a plain binary model; it is what would validate a
native backend if one ever arrives.

## Chunk size

A chunk is sized to the memory, not fixed. `chunk_shift/1` takes the initial
size, clamps it to between one 64 KiB page and 1 MiB, and rounds up to a power
of two, so address decoding stays a shift and a mask against `#mem.shift`.

```text
  initial pages   chunk
  0 or 1          64 KiB
  3               256 KiB
  16 or more      1 MiB
```

With a fixed 1 MiB chunk, a module that declared one page used 1 MiB. That is
16 times too much, and it was most of the memory one instance used (1080 KB,
against 11 KB for its process).

A restored memory takes its chunk size from the image instead. It uses the
largest chunk size, up to 1 MiB, that divides the image size exactly. So the
image region ends on a chunk boundary, and growth adds whole chunks after it.

Generated code reads `#mem{}` by literal field index.
`wasm_core_SUITE:the_memory_field_indices_match_the_record` pins those indices
to `wasm_memory:field_indices/0`. If you add a field to `#mem{}`, that test
fails, instead of memory being corrupted without any error.

## A restored memory shares its image

A memory restored from a snapshot has two regions. An address below
`img_bytes` is found through the page table over the image. An address at or
above it is found in the ordinary chunks that growth adds.

```text
  address 0                     img_bytes                       size
  |-------- image region ---------|-------- growth chunks --------|
     page table over the image       ordinary atomics chunks
```

The `#mem{}` fields involved:

| field | what it holds |
| --- | --- |
| `chunks` | the chunk tuple; chunks under the image are the atom `image` |
| `shift` | log2 of the chunk size |
| `img_bytes` | size of the image region; `0` for a memory with no image |
| `image` | one immutable 64 KiB binary per page, or `zero` |
| `tab` | the page table: one `atomics` entry per 4 KiB page, plus two |
| `arena` | the arena chunks this handle has seen |

Each image field is set once, when the memory is made, and never changes in
any handle. Only the contents of the arrays change. For a memory with no
image, all of this costs one extra comparison per access.

```text
  image (shared)        page table (per memory)       arena (per memory)
  +--------------+      +---+---+---+---+---+         +-------------------+
  | 0: <<64 KiB>>|<-----| 0 | 0 | E | 0 |...|         | chunk 1, 16 slots |
  | 1: zero      |      +---+---+-|-+---+---+         | chunk 2, 32 slots |
  | 2: <<64 KiB>>|                |                   | ...               |
  +--------------+                +------------------>| slot: 4 KiB copy  |
                                                      +-------------------+
  entry 0  page is still the image's: read its binary, or 0 for `zero`
  entry E  arena chunk E bsr 16, slot E band 16#FFFF
```

What happens on an access:

```text
  read in the image region
    entry = tab[page]
    0  -> bytes out of the image binary
    E  -> the slot in the arena

  first write to page P
    1. claim a slot; if the arena is full, extend it through the keeper
    2. copy the image's 4 KiB of P into the slot (skipped for zeros)
    3. compare_exchange(tab[P], 0, E)
         ok          P is private from now on
         another E'  another writer won; use E', this slot is abandoned
```

- **The image** is built once at capture or load and shared by every memory
  restored from it.
- **An entry goes from 0 to a slot once**, by `compare_exchange`, and never
  changes again.
- **The arena** grows in chunks of 64, 128, 256 and 512 KiB, then 1 MiB each.
  So a memory that writes little uses little memory, and a memory that writes
  a lot does not become thousands of small arrays. A CPython request writes
  256 pages: that needs five arena chunks, so five keeper transactions.
- **Three ordering rules make it safe.** They work because `atomics`
  operations are ordered with each other. An arena chunk is published before
  any slot in it is claimed. A slot is filled before it is published in the
  table. A reader only uses a slot that it found published.
- **A write is prepared first.** Every image page that a write touches is made
  private before any byte changes. So if the budget refuses the write part
  way, nothing that anyone can read has changed.
- **Nothing is invalidated.** A slot and a growth chunk never move.

Some writes can publish arena chunks: a host write, a bulk or vector
instruction, `wasm:write_memory/3`. They return an updated handle through
`wasm_memory:store_r/4` or `wasm_memory:refresh/1`. You may ignore it and keep
the old handle. The old handle still reads the new chunks through the
published cell, only more slowly.

The constants are fixed, not options. `test/audit/ATTEMPTS.md`, "Shared image
pages: what was left out, and the constants", has why each is what it is.

The page table replaced an older design, restore recycling. Recycling kept the
chunks of a destroyed instance in each process, and marked every store to know
which chunks to rewrite. The page table shares one image between all restores
in the node, copies only what a request writes, and adds no mark to stores.

A native version was also built and measured: it maps the image into memory
and lets the operating system copy a page when it is first written. It was
not adopted for now: `test/audit/ATTEMPTS.md`, "Restored memory in an
mmap region: B, deferred", has the numbers and what would reopen it.

## The translation cache

Generated code reaches memory 0 through a two-entry cache of page translations,
so that low addresses of a restored memory do not read the page table on
every access. It only caches translations to an array (a private slot or a
growth chunk). Neither of these ever moves, so no entry ever becomes wrong.
If you change the code generated for a memory access, read "The translation
cache" in [Design notes](design-notes.md#the-translation-cache) and
[Compiled tier](compiled-tier.md).

## The keeper: who holds what

`atomics` arrays live outside the process heap, so `max_heap_size` cannot see
them. Every page is reserved before it is allocated, and `wasm_keeper` records
who holds it.

Each resource has a stable id and a **set of holder tokens**, not a count.
Removing a token that is not in the set does nothing, so releasing twice is
harmless. The resource is freed when the set is empty.

```text
  token            held by                      removed by
  {instance, Id}   an instance that created     wasm:destroy/1, or its
                   or imported it               builder exiting
  {process, Pid}   a standalone resource        wasm_memory:free/1, or Pid
                                                exiting
  manual           a standalone thread-shared   wasm_memory:free/1 only
                   memory
  {build, Ref}     an instantiation in          transfer/3 on success,
                   progress                     discard/1 on failure, or
                                                its builder exiting
  {snapshot, Id}   a snapshot image, through    the snapshot's last holder
                   its owner process            releasing it or exiting
```

```text
  keeper row: memory M
    logical 20 pages   charged {table, growth, arena}
    holders {instance, I1}  {instance, I2}

    destroy(I1)            drop {instance, I1}; set not empty, keep
    I2's builder killed    monitor fires; drop {instance, I2}
                           set empty: free M, give its charged pages back

  keeper row: image Img
    bytes N            holders {snapshot, Id}
    memories restored from Img, counted by the keeper

    reclaimed when {snapshot, Id} is gone AND no restored memory remains
```

- **When a process dies, its tokens are removed.** A process killed with
  `exit(Pid, kill)` runs no cleanup code, and a worker timeout kills this way.
  So every token names the process whose death removes it, and the keeper
  monitors that process.
- **One row, one write.** Every change to the pages a memory is charged is one
  `ets:insert` of its row. The row also records the change that is not
  finished yet: a growth or an arena extension, named by an operation id that
  the caller made. If the keeper is killed between two steps, the table holds
  either the old row or the new one. When the keeper restarts, it reads the
  row and finishes or undoes the change.
- **Growth has two stages.** First the keeper checks and reserves the pages
  (`wasm_keeper:grow_begin/4`). Then the growing process allocates the chunks,
  outside the keeper. Last, the keeper saves the chunk tuple and the size
  together. Two processes growing at the same time wait in turn instead of
  failing, because `memory.grow` must return -1 only when the budget is really
  used up.
- **The keeper's table decides the size.** `wasm_memory:free/1` gives back the
  size the memory has now, not the size it had when its handle was made.

The node page counter and the snapshot byte counter are only caches. The
keeper rebuilds them from the rows every time it starts.

## The node page budget

`wasm_engine` holds the node-wide counter and the cap:

```erlang
wasm_engine:set_page_limit(16384),          % 1 GiB, the default
#{pages_in_use := N} = wasm_engine:stats().
```

- It counts every kind of memory the BEAM cannot see: linear memory, the
  object store of the garbage collector (see [GC](gc.md)), and table cells.
- It is for the whole node, not for each instance, because a thousand small
  instances are as dangerous as one large one.
- Reading it is a lock-free `atomics:get`. It changes only inside a keeper
  transaction, together with the row that says whose pages they are.
- It can show more than the limit. The object store is measured after its
  pages are already used, so `wasm_engine:charge_pages/1` records pages
  already spent. While the node is over the limit, every
  `wasm_engine:reserve_pages/1` is refused. The limit controls what a guest may
  take next, not what it has already taken.

## Charged pages and logical pages

A memory's keeper row keeps two numbers apart:

| | what it is | what bounds it |
| --- | --- | --- |
| logical pages | what the guest sees | `max_memory_pages`, declared max |
| charged pages | page table, growth chunks, arena | the node page budget |

For a memory restored from an image of `I` pages, the charge is:

```text
  table   ((I * 16 + 2) * 8) bytes, rounded up to whole 64 KiB pages
  growth  chunks allocated past the image, in pages
  arena   the arena chunks, reserved or published, in pages
```

The image's own pages are not charged to the node budget. They are counted
in bytes against `max_snapshot_bytes` instead.

## The snapshot byte budget

An image has its own keeper row. When it is captured or loaded, its size in
bytes is counted against the application setting `max_snapshot_bytes`
(default `infinity`). If that goes over the limit, the capture fails with a
`snapshot_budget` exhaustion error.

```erlang
application:set_env(wasm, max_snapshot_bytes, 512 * 1024 * 1024).
```

The bytes stay counted until the snapshot's holder is gone and no memory
restored from it remains, because those memories still read its pages.

## Read this next

[Snapshots](snapshots.md) for how you use images and restores, and the
`wasm_memory` and `wasm_keeper` module docs for the code.
