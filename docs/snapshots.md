# Initialized runtime snapshots

An initialized runtime snapshot is an immutable copy of a guest taken after its
initialisation has returned. Restoring one builds a **fresh** instance already
at that point, so you skip interpreter startup without giving up
one-instance-per-request isolation. Reach for it when a guest costs seconds to
start and milliseconds to run: an interpreter that parses its standard library
on every request is the case it exists for.

An image lives in this node for as long as something holds it, and a keeper or
module-cache restart invalidates it. Recapturing costs one `init()`, which for
CPython is 90 seconds, so there is also a **file** form: see keeping images
across restarts, below.

**Do you need this?** Yes, if a guest takes seconds to start and milliseconds
to run, such as an interpreter. No, for a plugin that starts in microseconds.

## Let a worker do it for you, which is the usual way

`wasm_script_worker` captures at `start_link/2` and restores per request, so an
adapter never calls `snapshot/1` itself. Declare the capability and say what
the initialisation instance is built from:

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

A capture that fails **fails the start**, since the alternative is a worker
whose requests call `handle` on an instance that never ran `init`. The
initialisation bindings should be as barren as the guest allows: whatever
`init()` touches is shared by every request that restores it.

`capture_timeout` bounds the whole thing, 60 s by default:

<!-- check: modules my_adapter -->
```erlang
wasm_script_worker:start_link(my_adapter, #{root => scratch,
                                       capture_timeout => 180_000}).
```

It is a worker option rather than a limit because a `timeout` in a limits map
is enforced by whoever owns the instance, and an inline call cannot be
interrupted. The kernel gives the capture a process of its own and kills it at
the deadline, so a guest whose `init()` never returns costs one timeout instead
of a `start_link/2` that never comes back.

Make `validate` ask the runtime whether it came up, rather than asking the
module what it exports: `init`'s own return value never reaches the kernel, so
the alternative is capturing a runtime that failed to start and restoring it
into every request.

## One image, three sizes

"The size of an image" is ambiguous and the three answers differ by 15x, so
this guide always says which. For a started CPython:

| | | what it bounds |
| --- | ---: | --- |
| the address space it covers | 41.9 MB | what a restore writes into, bounded by `max_memory_pages` |
| what it **retains** in memory | its pages that hold data | `max_snapshot_bytes`, and what `wasm:snapshot_info/1` answers as `bytes` |
| the **file** on disk | 2.7 MB | `max_snapshot_dir_bytes` |

They differ because an image keeps only the 64 KiB pages of each memory that
are not all zero -- a started interpreter is mostly zero -- and the file keeps
only their non-zero runs, compressed.

An unqualified "image" below means the thing itself, not any one of its sizes.

## Capture one

The guest must be a **reactor**: something that brings its runtime up in one
call and returns. You cannot capture mid-call, so a WASI command exporting only
`_start` is not a candidate.

```erlang
{ok, Handle} = wasm:load(Bytes),
{ok, Init} = wasm:instantiate(Handle, Imports, #{snapshotable => true}),
{ok, []} = wasm:call(Init, ~"init", []),
{ok, Image} = wasm:snapshot(Init),
ok = wasm:destroy(Init).
```

`snapshotable => true` is what makes the instance capturable: it allocates the
lease counters that prove no call is running. Ask for it only on the
initialisation instance. An instance without it is refused, and an ordinary
request instance pays nothing.

Capture the image from **trusted** initialisation only. Every request restores
the same bytes, so anything tenant code touched before the capture is shared
by every tenant after it.

## Restore per request

```erlang
{ok, Fresh} = wasm:restore(Image, FreshBindings, #{}),
{ok, Result} = wasm:call(Fresh, ~"handle", [Arg]),
ok = wasm:destroy(Fresh).
```

Build the imports fresh each time. Restore reconstructs nothing of the host
side for you: file descriptors, sockets, clocks and random providers are yours
to supply, and the image carries none of them.

`restore/3` takes no module argument. It uses the handle the image retained, so
there is nothing to pass that could lay an image over a different module's
layout. It also does **not** run the module's start function, because the image
already contains what that function did.

**What a restore costs.** Nothing of the image is copied. A restored memory
reads the image's pages in place, shared with every other instance restored
from it, and the first write to a 4 KiB page copies that page into memory of
the instance's own. So a restore costs a page table, one 8-byte entry per
4 KiB of image, and a request costs the pages it writes.

Against the 0.8 releases, which copied the image into every restore, medians
from `test/audit/PERF.md`, "Shared pages":

| guest | `wasm:restore/3`, 0.8 | now | first writes per request | instances under `page_limit` 4096, 0.8 | now |
| --- | ---: | ---: | ---: | ---: | ---: |
| CPython | 12.0 ms | 0.79 ms | 256 pages, 1.3 ms | 6 | 124 |
| QuickJS | 0.42 ms | 0.12 ms | 41 pages, 0.21 ms | 682 | 1024 |
| Lua | 0.17 ms | 0.06 ms | 12 pages, 0.06 ms | 1365 | 2048 |

The price is on access. Compiled code reaches a page through a lookup, so a
compiled request's guest time is 12% to 49% higher than before, and the whole
request moves between 8% faster and 19% slower depending on how much of it
was the restore. A CPython worker with an `entry`, where the restore was most
of the request, went from 5.4 ms to 3.0 ms.

The instance underneath is built without the module's active data segments
applied, because the image already holds what they wrote. Their bounds are
still checked against the module's declared minimum, so a module that could not
be instantiated is still refused.

A write that needs a page the node budget cannot give fails with `exhaustion`
/ `memory_limit` before it changes a byte, and the instance stays usable.

## Hold an image past its creator

A holder is a process. `wasm:snapshot/1` gives the capturing process the first
one, and a holder is dropped when its process dies.

```erlang
ok = wasm:acquire(Image),     %% from the process that should keep it
ok = wasm:release(Image).     %% drops this process's holder; always ok
```

Acquire **before** the capturing process exits. The reverse order is a race.
`wasm:snapshot_info/1` answers `#{bytes, module, version}`.

`wasm:restore/3` takes a holder for you if the calling process has none, and
drops it when the restore returns, so N restores leave no holders behind.
Each restored memory holds the image itself until it is freed, which is what
keeps its pages readable after you release the image.

## Keep images across restarts

An image lives in memory and dies with the node, which for a guest that takes
90 seconds to start is the wrong trade. Point the runtime at a directory and a
worker reads its image instead of capturing:

```erlang
application:set_env(wasm, snapshot_dir, "/var/cache/wasm/images").
```

Off unless you set it. A CPython worker starts in **under a second** from a
file against a hundred seconds capturing, and the file is 2.7 MB. The rest of the numbers are in
`test/audit/PERF.md`.

The directory is bounded, oldest first:

```erlang
application:set_env(wasm, max_snapshot_dir_bytes, 2 * 1024 * 1024 * 1024).
```

512 MiB unless you set it, which is about 197 CPython images at 2.7 MB of file
each. "Oldest" is least recently
**used**, because reading one touches it.

**It is trimmed when an image is filed and at no other time.** There is no
sweeper: a directory only grows when something writes to it, so that is the
only moment it can need shrinking. Two consequences worth knowing before you
meet them -- a node that starts no new worker never trims, and lowering the
setting does nothing until the next capture. `wasm_snapshot_store:purge/0`
empties a directory now.

An adapter must supply a `compatibility_key` for any of this to happen. There
is no default and no fallback: an image is a runtime after `init()` ran against
a **particular** environment, and the key is where a preopened directory, an
argument list or an environment belongs. Two deployments differing only in what
they preopened would otherwise share a file.

**The directory is as trusted as your release.** A snapshot is not code, it is
guest state laid into a live runtime, so anyone who can write the file can
choose what a restored instance believes. Every field is validated on the way
in, a table slot may name only a function the module has, and the decompressed
size is bounded by the module rather than by the file, but that is containment
and not authentication.

Reading one by hand, if you want to ship a file rather than let a worker make
it:

```erlang
ok = wasm:save_snapshot(Image, Path),
{ok, Handle} = wasm:load(Bytes),
{ok, Image2} = wasm:load_snapshot(Path, Handle).
```

The module is an argument rather than something the file names, which is the
same protection `restore/3` gets from the other direction. Every failure is a
refusal by name: `snapshot_corrupt`, `snapshot_truncated`,
`snapshot_wrong_module`, `snapshot_wrong_shape`, `snapshot_too_large`,
`snapshot_unknown_atom`, `snapshot_abi_mismatch`. A worker treats all of them as
a miss and captures.

A file's memories are checked against the module before any page is built: as
many as the module defines, each within its declared limits, and its runs in
order, apart and inside it. An image over `max_snapshot_bytes`, or one memory
mapping more than 2^20 pages, is refused as `exhaustion` / `snapshot_budget`.
The node page budget plays no part in loading: a sparse image loads on a node
too small to hold its whole address space, and its restores pay only for what
they write.

Loading costs what it did: the file's runs are laid into 64 KiB pages once, about
25 ms for a started CPython and 1.3 ms for QuickJS (`test/audit/PERF.md`,
"Shared pages"). Every restore after that shares them.

## Declare what your imports hold

Every import module named in the bindings must have an entry in
`snapshot_hooks`, or the capture is refused. Silence means unknown and unknown
means no.

```erlang
Opts = #{snapshotable => true,
         snapshot_hooks =>
             #{~"env" => stateless,
               ~"wasi_snapshot_preview1" => wasi_preview1:snapshot_hook()}}.
```

Say `stateless` for a module that keeps nothing. A module that keeps something
supplies a map of three funs, of this type:

```erlang
-type hooks() ::
        #{eligible := fun((wasm:instance()) -> ok | {error, wasm_error:error()}),
          capture  := fun((wasm:instance()) ->
                              {ok, Kept :: term()} | {error, wasm_error:error()}),
          restore  := fun((wasm:instance(), Kept :: term()) ->
                              ok | {error, wasm_error:error()})}.
```

`Kept` must be portable: binaries, numbers, atoms, lists, tuples and maps of
those. A pid, port, reference or fun fails the capture by type, because it
would mean something only in this node at this moment.

## Match an image to a configuration

An image is only valid against the imports and capabilities it was captured
under. Say what that is with a key, and a restore whose key differs is refused
before anything is copied.

```erlang
{ok, Image} = wasm:snapshot(Init, #{version => ~"2",
                                    compatibility_key => Key}),
{ok, Fresh} = wasm:restore(Image, FreshBindings,
                           #{compatibility_key => Key}).
```

Build the key from things that are the same across two runs of an identical
configuration: module identity, ABI, the name and type of every import, the
capability configuration in its declared form. Not a closure, a freshly spawned
pid or a request-specific path, which differ every time and would stop the key
matching itself.

## What is refused

| refused | why |
| --- | --- |
| an instance without `snapshotable => true` | nothing can prove it is quiescent |
| an instance built from `wasm:compile/1` | provenance is the cache handle, and there is none |
| a call running on the instance, in any process | an image cannot hold a call stack |
| an imported memory, table or global | the aliasing has no representation |
| a shared memory | same |
| a non-empty object store | GC state is not captured |
| a reference to another instance | it would restore into something already gone |
| an import module with no hook | silence means no |
| a WASI descriptor opened during `init()` | a live file is not reconstructible |

The WASI hook allows exactly the baseline: stdio and the preopens the
configuration built. It sees open descriptors, not integers a guest copied into
its own memory, so the guarantee is "nothing outside the baseline is open"
rather than "the guest is holding no descriptor number".

On a snapshotable instance `wasm:extern/2` is refused outright and
`wasm:write_memory/3` takes a lease, so neither can tear an image a capture is
reading. `wasm:destroy/1` during a capture still returns `ok` and takes effect
when the capture finishes.

## Bound them

```erlang
application:set_env(wasm, max_snapshot_bytes, 512 * 1024 * 1024).
```

Node-wide, in bytes, charged once at capture or load. The default is
`infinity`, which means unbounded rather than off.

It charges the **retained** size, the middle row of the three above: 64 KiB for
every page that holds data, and 8 bytes for every page of address space. The
charge is held while the image is held **or** while any memory restored from it
remains, including one another instance imported, because those memories read
its pages.

A restore does not charge it again. What a restored memory allocates, its page
table and the pages it writes, is charged to the node page budget, and
`max_memory_pages` bounds its size as for any memory.

## What an image freezes

Whatever the guest drew before the capture is in the image and is shared by
every request that restores it. For CPython that is the hash seed, read from
`random_get` during startup. Re-seeding afterwards is not available: string
hashes are already cached against the old secret.

So rotation means recapturing. Anything a guest reads from the clock before the
capture is frozen the same way.
