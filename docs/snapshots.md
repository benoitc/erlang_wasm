# Initialized runtime snapshots

A snapshot is a copy of a guest, taken after its initialisation has finished.
The copy never changes. Restoring it builds a **new** instance that is already
initialized, so you skip the guest's startup and still give each request its
own instance. Use it when a guest takes seconds to start and milliseconds to
run. The main case is an interpreter that parses its standard library on every
request.

An image lives in this node while something holds it. A restart of the keeper
or of the module cache makes it invalid. Capturing it again costs one
`init()`, which for CPython is 90 seconds, so you can also keep an image in a
**file**: see "Keep images across restarts" below.

**Do you need this?** Yes, if a guest takes seconds to start and milliseconds
to run, such as an interpreter. No, for a plugin that starts in microseconds.

## The words on this page

| word | what it means here |
| --- | --- |
| **image** | the snapshot itself: the guest's memories, globals and tables after initialisation. On this page "snapshot" and "image" mean the same thing. |
| **capture** | making an image from a running instance, with `wasm:snapshot/1`. |
| **restore** | making a new instance from an image, with `wasm:restore/3`. |
| **reactor** | a guest that starts its runtime in one call and then returns, so you can call it again later. |
| **holder** | a process that keeps an image alive. When the last holder is gone and no restored memory uses it, the image is freed. |
| **owner** | the `wasm_snapshot_owner` process that keeps an image's data while it has holders. |
| **keeper** | `wasm_keeper`, the node-wide process that records who holds which memory pages, and charges them to the budgets. |
| **page** | a block of memory. Guest memory grows in 64 KiB WebAssembly pages; a restore shares and copies in 4 KiB pages. |
| **page table** | the list a restored memory keeps of where each of its 4 KiB pages is: in the image, or in its own arena. |
| **arena** | the memory that belongs to one restored instance, where it copies the pages it writes. |
| **page budget** | the node-wide limit on guest memory pages. See [Memory](memory.md). |

## Let a worker do it for you (the usual way)

`wasm_script_worker` captures at `start_link/2` and restores for each
request, so an adapter never calls `snapshot/1` itself. Declare the capability,
and say what the initialisation instance is built from:

```erlang
capabilities(Artifact) ->
    %% your other capabilities, with these two set
    (base_capabilities(Artifact))#{execution => reactor,
                                   snapshots => #{version => ~"my-1"}}.

snapshot_capability(#{module := M}) ->
    #{version => ~"my-1",
      module => M,
      imports => #{bindings => TrustedBindings,
                   snapshot_hooks => Hooks,
                   compatibility_key => ~"my-1"},
      init => [{call, ~"_initialize", []}, {call, ~"init", []}],
      validate => fun(Inst) -> ok end,
      post_restore => fun(Inst, _Ctx) -> ok end}.
```

Then `prepare/3` returns only the request's own work, because the rest is in
the image:

```erlang
invoke => [{call, ~"handle", []}]
```

If the capture fails, **the start fails**. Otherwise you would get a worker
whose requests call `handle` on an instance that never ran `init`. Give the
initialisation as few bindings as the guest allows: everything that `init()`
touches is shared by every request that restores the image.

`capture_timeout` limits the whole capture. The default is 60 s:

<!-- check: modules my_adapter -->
```erlang
wasm_script_worker:start_link(my_adapter, #{root => scratch,
                                       capture_timeout => 180_000}).
```

It is a worker option, not a limit, for this reason: a `timeout` in a limits
map is enforced by the process that owns the instance, and an inline call
cannot be interrupted. The kernel runs the capture in its own process and kills
it at the deadline. So a guest whose `init()` never returns costs one timeout,
instead of a `start_link/2` that never returns. It limits the capture and
nothing before it: loading the artifact and looking for the image in
`snapshot_dir` have no time limit.

If you start several workers with the same options, prepare the image once
with `wasm_script_worker:prepare/2` and start each worker from it. Then the
pool holds one image, charged once, and captures at most once. "Run a pool
from one image" in [Using workers](worker.md) shows how.

In `validate`, ask the runtime whether it started correctly. Do not only check
what the module exports. The return value of `init` never reaches the kernel,
so without this check you could capture a runtime that failed to start, and
restore it into every request.

## One image, three sizes

"The size of an image" can mean three things, and they differ by up to 15x.
This guide always says which one it means. For a started CPython:

| | | what it is limited by, or used for |
| --- | ---: | --- |
| the address space it covers | 41.9 MB | what a restore writes into, limited by `max_memory_pages` |
| what it **retains** in memory | its pages that hold data | `max_snapshot_bytes`, and the `bytes` value of `wasm:snapshot_info/1` |
| the **file** on disk | 2.7 MB | `max_snapshot_dir_bytes` |

They differ because an image keeps only the 64 KiB pages of each memory that
are not all zeros, and a started interpreter is mostly zeros. The file keeps
only the non-zero runs of those pages, compressed.

Below, "image" alone means the image itself, not one of its sizes.

## How an image moves

```text
  initialisation instance, snapshotable => true
        |
        | wasm:snapshot/1
        v
  image: memories, globals, tables         wasm:save_snapshot/2
    a wasm_snapshot_owner process  ----------------------------> file
    holds the module claim and              wasm:load_snapshot/2
    the keeper record of its pages <---------------------------- file
        |
        | wasm:restore/3, once per request, start function not run
        v
  fresh instance; its memory is a page table over the image
    untouched page   read from the image, shared by every restore
    written page     copied once into the instance's own arena
        |
        | wasm:destroy/1
        v
  the private pages are freed; the image stays while anything holds it
```

The owner process lives as long as some process holds the image. The keeper
keeps the image's pages charged until the last memory restored from it is
freed. When `snapshot_dir` is set, a worker does the file part for you,
through `wasm_snapshot_store`.

## Capture one

The guest must be a **reactor**. You cannot capture in the middle of a call,
so a WASI command that exports only `_start` cannot be captured.

```erlang
{ok, Handle} = wasm:load(Bytes),
{ok, Init} = wasm:instantiate(Handle, Imports, #{snapshotable => true}),
{ok, []} = wasm:call(Init, ~"init", []),
{ok, Image} = wasm:snapshot(Init),
ok = wasm:destroy(Init).
```

`snapshotable => true` makes the instance capturable. It creates the lease
counters that prove no call is running. Ask for it only on the initialisation
instance. An instance without it is refused, and an ordinary request instance
pays nothing for it.

Capture the image only from **trusted** initialisation. Every request restores
the same bytes, so anything that tenant code changed before the capture is
shared with every tenant after it.

## Restore per request

```erlang
{ok, Fresh} = wasm:restore(Image, FreshBindings, #{}),
{ok, Result} = wasm:call(Fresh, ~"handle", [Arg]),
ok = wasm:destroy(Fresh).
```

Build the imports again for each request. A restore rebuilds nothing on the
host side: you supply file descriptors, sockets, clocks and random providers,
and the image contains none of them.

`restore/3` takes no module argument. It uses the module handle the image
kept, so you cannot restore an image onto a different module by mistake. It
also does **not** run the module's start function, because the image already
contains what that function did.

**What a restore costs.** Nothing of the image is copied. A restored memory
reads the image's pages where they are, shared with every other instance
restored from the same image. The first write to a 4 KiB page copies that page
into the instance's own memory. So a restore costs a page table (one 8-byte
entry per 4 KiB of image), and a request costs the pages it writes.

**Sending an image to another process copies almost nothing.** Its pages are
binaries, and a send shares binaries by reference. A function table that holds
only `null` and the module's own functions is packed into one binary, one
32-bit word per slot, at capture and at load. So it is shared in the same way,
and a restore builds the new table directly from those words. A table that
holds anything else stays a list. Packing changes nothing on disk: the file
holds the same lists as before, and files written earlier still load.

Compared with the 0.8 releases, which copied the image into every restore
(medians from `test/audit/PERF.md`, "Shared pages"):

| guest | `wasm:restore/3`, 0.8 | now | first writes per request | instances under `page_limit` 4096, 0.8 | now |
| --- | ---: | ---: | ---: | ---: | ---: |
| CPython | 12.0 ms | 0.79 ms | 256 pages, 1.3 ms | 6 | 124 |
| QuickJS | 0.42 ms | 0.12 ms | 41 pages, 0.21 ms | 682 | 1024 |
| Lua | 0.17 ms | 0.06 ms | 12 pages, 0.06 ms | 1365 | 2048 |

The cost moves to memory access. Compiled code finds each page through a
lookup, so the guest time of a compiled request is 12% to 49% higher than
before. The whole request becomes between 8% faster and 19% slower, depending
on how much of it was the restore. A CPython worker with an `entry`, where the
restore was most of the request, went from 5.4 ms to 3.0 ms.

The restored instance is built without applying the module's active data
segments, because the image already contains what they wrote. Their bounds are
still checked against the module's declared minimum, so a module that could
not be instantiated is still refused.

If a write needs a new page and the node page budget cannot give one, the
write fails with `exhaustion` / `memory_limit` before it changes any byte, and
the instance stays usable.

## Keep an image after its creator exits

A holder is a process. `wasm:snapshot/1` makes the capturing process the first
holder. A holder is removed when its process dies.

```erlang
ok = wasm:acquire(Image),     %% from the process that should keep it
ok = wasm:release(Image).     %% drops this process's holder; always ok
```

Call `acquire` **before** the capturing process exits. In the other order, the
image may be freed first.
`wasm:snapshot_info/1` returns `#{bytes, module, version}`.

If the calling process is not a holder, `wasm:restore/3` makes it one for the
time of the restore and removes it when the restore returns. So N restores
leave no holders behind. Each restored memory keeps the image alive itself
until the memory is freed. That is why its pages stay readable after you
release the image.

## Keep images across restarts

An image lives in memory and is lost when the node stops. For a guest that
takes 90 seconds to start, that is a bad trade. Give the runtime a directory,
and a worker reads its image from there instead of capturing:

```erlang
application:set_env(wasm, snapshot_dir, "/var/cache/wasm/images").
```

It is off unless you set it. A CPython worker starts in **under a second** from
a file, against a hundred seconds when it captures, and the file is 2.7 MB.
The other numbers are in `test/audit/PERF.md`.

The directory has a size limit. When it is full, the oldest files are removed
first:

```erlang
application:set_env(wasm, max_snapshot_dir_bytes, 2 * 1024 * 1024 * 1024).
```

The default is 512 MiB, about 197 CPython images of 2.7 MB each. "Oldest"
means least recently **used**, because reading a file updates its time.

**The directory is trimmed when an image is stored, and at no other time.**
There is no background cleaner. The directory grows only when something writes
to it, so that is the only time it may need trimming. This has two effects: a
node that starts no new worker never trims, and lowering the limit does
nothing until the next capture. `wasm_snapshot_store:purge/0` empties a
directory immediately.

None of this happens unless the adapter supplies a `compatibility_key`. There
is no default and no fallback. An image is a runtime after `init()` ran in a
**particular** environment, and the key is where you put that environment: a
preopened directory, an argument list, environment variables. Without it, two
deployments that differ only in what they preopened would share a file.

**Trust this directory as much as your release.** A snapshot is not code, but
it is guest state loaded into a live runtime. Anyone who can write the file can
choose what a restored instance believes. Every field is checked when it is
read, a table slot can only name a function the module has, and the
decompressed size is limited by the module, not by the file. These checks
contain damage; they do not prove who wrote the file.

To save and load a file yourself, for example to ship a file instead of
letting a worker make it:

```erlang
ok = wasm:save_snapshot(Image, Path),
{ok, Handle} = wasm:load(Bytes),
{ok, Image2} = wasm:load_snapshot(Path, Handle).
```

You pass the module as an argument; the file does not name it. This is the
same protection `restore/3` has, from the other side. Each failure is refused
with a name: `snapshot_corrupt`, `snapshot_truncated`,
`snapshot_wrong_module`, `snapshot_wrong_shape`, `snapshot_too_large`,
`snapshot_unknown_atom`, `snapshot_abi_mismatch`. A worker treats all of them
as "no image" and captures. A table that decodes to neither a list of entries
nor whole 32-bit words is `snapshot_corrupt`. A table that names a function
the module does not have is `snapshot_invalid_value`.

A file's memories are checked against the module before any page is built:
there must be as many as the module defines, each within its declared limits,
with its runs in order, not overlapping, and inside the memory. An image over
`max_snapshot_bytes`, or a memory that maps more than 2^20 pages, is refused
as `exhaustion` / `snapshot_budget`. The node page budget is not used when
loading. A sparse image loads even on a node too small to hold its whole
address space, and its restores pay only for what they write.

Loading puts the file's runs into 64 KiB pages once, and packs its tables
while it decodes them. This takes about 21 ms for a started CPython and 1.0 ms
for QuickJS (`test/audit/PERF.md`, "One image for a pool"). Every restore
after that shares them.

## Declare what your imports hold

Every import module named in the bindings must have an entry in
`snapshot_hooks`, or the capture is refused. A module with no entry is
treated as unknown, and an unknown module is refused.

```erlang
Opts = #{snapshotable => true,
         snapshot_hooks =>
             #{~"env" => stateless,
               ~"wasi_snapshot_preview1" => wasi_preview1:snapshot_hook()}}.
```

Use `stateless` for a module that keeps no state. A module that keeps state
supplies a map of three funs, of this type:

```erlang
-type hooks() ::
        #{eligible := fun((wasm:instance()) -> ok | {error, wasm_error:error()}),
          capture  := fun((wasm:instance()) ->
                              {ok, Kept :: term()} | {error, wasm_error:error()}),
          restore  := fun((wasm:instance(), Kept :: term()) ->
                              ok | {error, wasm_error:error()})}.
```

`Kept` must be portable: binaries, numbers, atoms, lists, tuples, and maps of
those. A pid, port, reference or fun makes the capture fail, because it has a
meaning only in this node at this moment.

## Match an image to a configuration

An image is valid only with the imports and capabilities it was captured with.
Describe them with a key. A restore with a different key is refused before
anything is copied.

```erlang
{ok, Image} = wasm:snapshot(Init, #{version => ~"2",
                                    compatibility_key => Key}),
{ok, Fresh} = wasm:restore(Image, FreshBindings,
                           #{compatibility_key => Key}).
```

Build the key from values that are the same in two runs of the same
configuration: the module identity, the ABI, the name and type of every
import, and the capability configuration as declared. Do not use a closure, a
newly spawned pid or a path made for one request. These change every time, so
the key would never match itself.

## What is refused

| refused | why |
| --- | --- |
| an instance without `snapshotable => true` | nothing can prove that no call is running on it |
| an instance built from `wasm:compile/1` | the image needs the cache handle to know its module, and there is none |
| a call running on the instance, in any process | an image cannot hold a call stack |
| an imported memory, table or global | an image cannot record that it is shared with another instance |
| a shared memory | same |
| a non-empty object store | GC state is not captured |
| a reference to another instance | it would restore into something already gone |
| an import module with no hook | unknown means no |
| a WASI descriptor opened during `init()` | a live file cannot be rebuilt |

The WASI hook allows exactly the starting set: stdio and the preopens the
configuration built. It sees open descriptors, not numbers a guest copied into
its own memory. So it guarantees that "nothing outside the starting set is
open", not that "the guest keeps no descriptor number".

On a snapshotable instance, `wasm:extern/2` is always refused, and
`wasm:write_memory/3` takes a lease, so neither can change an image while a
capture reads it. `wasm:destroy/1` during a capture still returns `ok`, and
takes effect when the capture finishes.

## Limit their size

```erlang
application:set_env(wasm, max_snapshot_bytes, 512 * 1024 * 1024).
```

This limit is for the whole node, in bytes, charged once at capture or load.
The default is `infinity`, which means no limit (not that snapshots are off).

It charges the **retained** size, the middle row of the three sizes above:
64 KiB for every page that holds data, and 8 bytes for every page of address
space. The charge stays while the image is held, **or** while any memory
restored from it still exists, including one that another instance imported,
because those memories read its pages.

It counts images, not workers. Each worker started without `prepared` loads
its own copy and is charged for it, so fifty workers on one file are charged
fifty times. Workers started from one `wasm_script_worker:prepare/2` share one
image, charged once.

A restore is not charged again. What a restored memory allocates (its page
table and the pages it writes) is charged to the node page budget, and
`max_memory_pages` limits its size, as for any memory.

## What an image freezes

Any random value or clock time the guest read before the capture is in the
image, and is shared by every request that restores it. For CPython this
includes the hash seed, which it reads from `random_get` during startup. You
cannot change the seed after the capture: string hashes are already stored
with the old value.

So to get a new seed, capture again. Anything a guest reads from the clock
before the capture is frozen in the same way.

## Read this next

[The compiled tier](compiled-tier.md), which makes a guest run faster, where
snapshots make it start faster.
