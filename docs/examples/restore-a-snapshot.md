# Restore a snapshot

This example starts a guest once, saves it, and gives every request a new
copy of that started state. A **snapshot** is a saved copy of a guest after
it has started. Restoring it skips the startup. This is how an interpreter
that takes seconds to start costs only milliseconds per request.

**You need:** a checkout of this repository, which has a small guest built for
this in `test/fixtures/snapshot/`. It exports `init`, which sets its state up,
and `handle`, which counts calls.

```erlang
{ok, _} = application:ensure_all_started(wasm),
{ok, Mod} = wasm:load_file("test/fixtures/snapshot/reactor.wasm").
```

Start it once, and capture it:

```erlang
{ok, Init} = wasm:instantiate(Mod, #{}, #{snapshotable => true}),
{ok, []} = wasm:call(Init, ~"init", []),
{ok, Image} = wasm:snapshot(Init),
ok = wasm:destroy(Init).
```

Every restore gives a new instance that is already initialised:

```erlang
{ok, A} = wasm:restore(Image, #{}, #{}),
{ok, [1235]} = wasm:call(A, ~"handle", []),
{ok, [1236]} = wasm:call(A, ~"handle", []),
{ok, B} = wasm:restore(Image, #{}, #{}),
wasm:call(B, ~"handle", []).
%% => {ok, [1235]}
```

**What happened.** `init` ran once. `A` continued counting from where `init`
left it. `B` was restored from the same **image** (the stored snapshot), so
it started again from that point and saw nothing that `A` did. The image
holds the guest's memory, globals and tables. It is not a paused process.
Only a **reactor**, a guest that exports functions and stays ready between
calls, can be saved. A command runs `main` and exits, so it has no state
worth keeping.

**Clean up:**

```erlang
ok = wasm:destroy(A),
ok = wasm:destroy(B).
```

**Next:** [Turn on the compiled tier](turn-on-the-tier.md), or
[Snapshots](../snapshots.md) for images kept on disk and what a worker does
with them.

## Read this next

The guide behind this example: [Snapshots](../snapshots.md).
