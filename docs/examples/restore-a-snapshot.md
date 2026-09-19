# Restore a snapshot

This example starts a guest once, captures it, and gives every request a fresh
copy of that started state. A **snapshot** is a frozen copy of a guest after
startup; restoring it skips the startup, which is what makes an interpreter
that takes seconds to start cost milliseconds per request.

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

Every restore is a fresh instance, already initialised:

```erlang
{ok, A} = wasm:restore(Image, #{}, #{}),
{ok, [1235]} = wasm:call(A, ~"handle", []),
{ok, [1236]} = wasm:call(A, ~"handle", []),
{ok, B} = wasm:restore(Image, #{}, #{}),
wasm:call(B, ~"handle", []).
%% => {ok, [1235]}
```

**What happened.** `init` ran once. `A` counted on from where `init` left it;
`B`, restored from the same **image**, started from that point again and saw
nothing `A` did. The image holds the guest's memory, globals and tables, not a
paused process. Only a **reactor**, a guest that exports functions and stays
ready between calls, can be captured: a command that runs `main` and exits has
no moment worth keeping.

**Clean up:**

```erlang
ok = wasm:destroy(A),
ok = wasm:destroy(B).
```

**Next:** [Turn on the compiled tier](turn-on-the-tier.md), or
[Snapshots](../snapshots.md) for images kept on disk and what a worker does
with them.
