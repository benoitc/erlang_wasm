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
drops it when the copy finishes, so N restores leave no holders behind.

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
`snapshot_wrong_module`, `snapshot_too_large`, `snapshot_unknown_atom`,
`snapshot_abi_mismatch`. A worker treats all of them as a miss and captures.

## Let a worker do it for you

`script_worker` captures at `start_link/2` and restores per request, so an
adapter never calls `snapshot/1` itself. Declare the capability and say what
the initialisation instance is built from:

```erlang
capabilities(_Artifact) ->
    #{execution => reactor, snapshots => #{version => ~"my-1"}, ...}.

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

```erlang
script_worker:start_link(my_adapter, #{root => scratch,
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
supplies three funs:

```erlang
#{eligible => fun(Inst) -> ok | {error, wasm_error:error()} end,
  capture  => fun(Inst) -> {ok, Kept} | {error, wasm_error:error()} end,
  restore  => fun(Inst, Kept) -> ok | {error, wasm_error:error()} end}
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

Node-wide, in bytes, charged once at capture. The default is `infinity`, which
means unbounded rather than off.

It charges what an image **retains**, and an image keeps only the non-zero runs
of each memory. A started CPython covers 41.9 MB of address space and holds
7.4 MB of it, so a ceiling admits far more images than its size suggests. A restore does not charge it again: the
memories a restore builds are an instance's, and `max_memory_pages` bounds
those.

## What an image freezes

Whatever the guest drew before the capture is in the image and is shared by
every request that restores it. For CPython that is the hash seed, read from
`random_get` during startup. Re-seeding afterwards is not available: string
hashes are already cached against the old secret.

So rotation means recapturing. Anything a guest reads from the clock before the
capture is frozen the same way.
