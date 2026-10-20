# Memory

How linear memory is stored, how a restored memory shares its snapshot image,
and how the node page budget is kept. Read this before you change
`wasm_memory`, `wasm_keeper`, `wasm_engine` or `wasm_snapshot`, or anything
that reserves, grows or frees pages: the representation was chosen by
measurement, and the accounting is what keeps a guest from exhausting the node.

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

A fixed 1 MiB chunk made a module declaring one page cost 1 MiB, a 16x
over-allocation that dominated the per-instance footprint (1080 KB against
11 KB of process).

A restored memory sizes its chunk from the image instead: the largest chunk,
up to 1 MiB, that the image's size is a multiple of, so the image region ends
on a chunk boundary and growth appends whole chunks after it.

Generated code reads `#mem{}` by literal field index.
`wasm_core_SUITE:the_memory_field_indices_match_the_record` pins those indices
to `wasm_memory:field_indices/0`, so adding a field to `#mem{}` fails there
rather than corrupting memory quietly.

## A restored memory shares its image

A memory restored from a snapshot is two regions. Below `img_bytes` every
address resolves through a page table over the image; at or above it, through
the ordinary chunks a growth appends.

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

Every image field is set once, when the memory is made, and never changes in
any handle; only what the arrays hold changes. A memory with no image pays one
comparison per access for all of this.

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
- **The arena** grows in chunks of 64, 128, 256 and 512 KiB, then 1 MiB each,
  so a memory that writes little pays little and one that writes a lot is not
  thousands of small arrays. A CPython request's 256 written pages need five
  arena chunks, so five keeper transactions.
- **Three orders make it safe**, each resting on `atomics` operations being
  mutually ordered: an arena chunk is published before any slot in it is
  claimed, a slot is filled before it is published in the table, and a reader
  acts only on a slot it found published.
- **A write is prepared first.** Every image page a write touches is made
  private before a byte changes, so a write the budget refuses part way has
  changed nothing anyone can read.
- **Nothing is invalidated.** A slot and a growth chunk never move.

A write that can publish arena chunks (a host write, a bulk or vector
instruction, `wasm:write_memory/3`) answers a refreshed handle through
`wasm_memory:store_r/4` or `wasm_memory:refresh/1`. Ignoring it is correct; a
stale handle reads new chunks through the published cell, only slower.

The constants are fixed, not options. `test/audit/ATTEMPTS.md`, "Shared image
pages: what was left out, and the constants", has why each is what it is.

A page table replaced restore recycling, which kept a destroyed instance's
chunks per process and marked every store to know which to rewrite. The page
table shares one image across every restore in the node, copies only what a
request writes, and puts no mark on the store path.

A native backend that maps the image and lets the kernel copy on write was
built, measured and deferred: `test/audit/ATTEMPTS.md`, "Restored memory in an
mmap region: B, deferred", has the numbers and what would reopen it.

## The translation cache

Generated code reaches memory 0 through a two-entry cache of page translations,
so a restored memory's low addresses do not walk the page table on every
access. It caches only translations to an array (a private slot or a growth
chunk), and since neither ever moves, no entry is ever invalidated. If you
change how an access is lowered, read "The translation cache" in
[Design notes](design-notes.md#the-translation-cache) and
[Compiled tier](compiled-tier.md).

## The keeper: who holds what

`atomics` arrays live outside the process heap, so `max_heap_size` cannot see
them. Every page is reserved before it is allocated, and `wasm_keeper` records
who holds it.

A resource is keyed by a stable id and holds a **set of holder tokens**, not a
count. Removing a token that is not there is a no-op, so a double release is
harmless, and the resource is reclaimed when the set empties.

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

- **Death releases.** A process killed with `exit(Pid, kill)` runs no cleanup,
  which is what a worker timeout does, so every token names the process whose
  death removes it and the keeper monitors that process.
- **One row, one write.** Every change to what a memory owes is a single
  `ets:insert` of its row, carrying the transaction in flight: a growth or an
  arena extension, named by an operation id the caller made. A keeper killed
  between two steps leaves the old row or the new one, and the restart
  finishes or undoes the transaction from the row.
- **Growth is two stages.** The keeper validates and reserves
  (`wasm_keeper:grow_begin/4`), the grower allocates chunks outside the
  keeper, and the keeper commits the chunk tuple and the size together.
  Concurrent growers queue rather than fail, because `memory.grow` answering
  -1 must mean the budget really was exhausted.
- **The registry is the authority on size.** `wasm_memory:free/1` gives back
  the size the memory is now, not the size its handle was made at.

The node page counter and the snapshot byte counter are caches, rebuilt from
the rows every time the keeper starts.

## The node page budget

`wasm_engine` holds the node-wide counter and the cap:

```erlang
wasm_engine:set_page_limit(16384),          % 1 GiB, the default
#{pages_in_use := N} = wasm_engine:stats().
```

- It covers every kind of memory the BEAM cannot see: linear memory, the
  object store of the garbage collector (see [GC](gc.md)), and table cells.
- It is node-wide, not per instance, because a thousand small instances are as
  much of a threat as one large one.
- Reading it is a lock-free `atomics:get`. Moving it happens only inside a
  keeper transaction, together with the row that says whose pages they are.
- It can read above the limit. The object store is measured after the rows
  exist, so `wasm_engine:charge_pages/1` records pages already spent, and
  every `wasm_engine:reserve_pages/1` refuses while the node is over. A limit
  bounds what a guest may take next, not what it has taken.

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

An image is a keeper row of its own, charged its bytes against the
application setting `max_snapshot_bytes` (default `infinity`) when it is
captured or loaded. Over the limit, the capture fails with a `snapshot_budget`
exhaustion error.

```erlang
application:set_env(wasm, max_snapshot_bytes, 512 * 1024 * 1024).
```

The bytes stay charged until the snapshot's holder is gone and no memory
restored from it remains, because those memories still read its pages.

## Read this next

[Snapshots](snapshots.md) for the user's side of images and restores, and the
`wasm_memory` and `wasm_keeper` module docs for the code.
