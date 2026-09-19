# The adapter contract

This page is for writing an adapter: the module that teaches the worker kernel
how to run one language. You need it when you want to run a guest the kernel
has never heard of, and you should not need to change the kernel to do it. The
kernel knows about modules, imports, invocations, deadlines and bounded
channels. It does not know what WASI is, what JSON is, or that an entry point
might be called `main`. Everything in that second list is yours.

## What the kernel supports, stated exactly

Not "any language":

> Any language runtime packaged as a WebAssembly module that an adapter can
> express as a **finite sequence of calls over supported imports**.

Long-lived event loops, threads, native extensions, browser ABIs and
component-model guests are outside the guarantee.

## Write one

> **Where these modules come from.** The behaviour your adapter implements (it
> is defined in `wasm_script_worker`), the conformance kit
> `wasm_adapter_conformance` and the worker kernel are installed with the
> application.

Eight callbacks. `snapshot_capability/1` is optional and an absent one reads as
`unsupported`.

```erlang
-module(my_adapter).
-behaviour(wasm_script_worker).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2]).
```

Load whatever you run, once:

```erlang
artifact(_Opts) ->
    {ok, Module} = wasm:load(Bytes),
    {ok, #{module => Module}}.
```

Say what a request needs, before anything exists. This runs in the runner, on
the deadline and under the heap bound, because sizing a tenant's request means
traversing it:

```erlang
requirements(Request, _Artifact) ->
    {ok, #{min_timeout => 100, min_memory_pages => 1,
           request_bytes => byte_size(Request),
           staged_bytes => 0, staged_files => 0,
           mounts => #{ro => #{guest_path => ~"/", mode => read}}}}.
```

Build the thing to run. The mounts already exist and the limits are already
final:

```erlang
prepare(Request, #{module := M}, Env) ->
    ok = (maps:get(stage, Env))(ro, ~"main.src", Request),
    {ok, #{mode => command, module => M,
           imports => #{bindings => wasi(Env)},
           invoke => [{call, ~"_start", []}]},
     #{}}.
```

Decide what each invocation meant. This is called after **every** one, whether
it returned or trapped:

```erlang
classify({ok, _Values}, _State) -> continue;
classify({error, Err}, _State) ->
    case wasi_preview1:exit_code(Err) of
        {ok, Code} -> {stop, {exited, Code}};
        error      -> {stop, trapped}
    end.
```

Turn what happened into an answer, and release what you took:

```erlang
decode(#{outcome := exited, exit := 0, channels := #{stdout := Out}}, _S) ->
    {ok, Out};
decode(#{outcome := trapped, error := E}, _S) ->
    {error, wasm_worker_error:runtime(E)}.

cleanup(_State) -> ok.
```

## Notes

**There is no `{start}` invocation.** The kernel would have to know what
`_start` means to translate one, so you write `{call, ~"_start", []}` yourself.
That is the only reason a reactor and a command are the same code path: they
are the same call, chosen by different adapters.

**Only the adapter knows what a trap meant.** `proc_exit` becomes a trap
carrying the status, so a kernel that told it from any other trap would be
calling `wasi_preview1:exit_code/1`, and a kernel that calls `wasi_preview1`
anything is not language-neutral. `classify/2` is where you say.

**Two defaults keep a forgetful adapter honest.** `continue` on the last
invocation finishes with what actually happened, so a runtime error is never
silently discarded, and an adapter that does not understand a result should
answer `{stop, trapped}` rather than guess.

**Limits are effective, not proposed.** You said what you needed in
`requirements/2`; by `prepare/3` the policy has been applied and the deadline
built from it. Read them, never return replacements.

**Mounts, not per-file permissions.** A mode cannot belong to a staged file,
because WASI grants rights to a preopened directory and everything opened
beneath it. Declare a named mount per mode and the kernel creates and preopens
each one before `prepare/3` runs, which is what lets it own them.

**`mode => write` needs a trusted worker.** `max_staged_bytes` bounds what the
*adapter* stages and says nothing about what the *guest* writes once the
preopen exists, so an untrusted worker refuses one with `insufficient_limit`.
Bounding it properly needs guest-write byte and inode quotas inside `wasi_fs`,
which do not exist yet.

**Stage through `env.stage`, not `file:write_file/2`.** It validates the path
before anything is opened, debits both bounds across all mounts together, and
refuses past either. An adapter that writes directly is not bounded, and
**writing an adapter is writing host code**: adapters are inside the trust
boundary and tenants are not.

**Register cleanup as you allocate it, not at the end.** The runner can be
killed mid-`prepare`, so a contract where you return a state and the kernel
cleans it up cannot work. `env.cleanup` has `register` and `withdraw`. It has
no `transfer`: the kernel does that once, after the guardian holds your
complete state, so "transferred" and "a state was delivered" are the same event.

`register` answers three ways, because one that returns an error having neither
recorded nor performed the action leaks exactly what you allocated one line
earlier:

| | meaning |
| --- | --- |
| `{ok, Token}` | recorded |
| `{error, E, released}` | not recorded, but the action ran to completion |
| `{error, E, cleanup_failed}` | not recorded, and nobody owns that resource now |

**Actions must be idempotent *and* concurrent-safe.** Two paths can run one:
the guardian's mirror and a job whose reaper died after authorising it.
Idempotent-but-not-concurrent-safe passes every sequential test and corrupts
under exactly that race.

**A `fun` dies with the reaper; a `recover_op()` does not.** If you hold
something you cannot afford to leak across a reaper crash, express it as
`{remove_tree, RootId, RelPath}` or `{delete_file, RootId, RelPath}`. Anything
else is best effort.

**Nothing a guest supplies becomes an atom.** The atom table is node-wide and
never reclaimed. Your language's vocabulary goes in `ctx` as a binary:

```erlang
#{class => adapter, kind => adapter_failure, msg => ~"main is not defined",
  ctx => #{code => ~"no_entry_point"}}
```

## Skip the startup, if your guest is a reactor

Export `snapshot_capability/1` and the worker captures your runtime once at
`start_link/2`, then restores it into every request. Your guest has to be a
**reactor**: something that brings the runtime up in one call and returns, so
there is a point with no call in progress to capture. A WASI command exporting
only `_start` cannot be one, because by the time `_start` returns the runtime
has torn itself down.

```erlang
capabilities(Artifact) ->
    %% your other capabilities, with these two set
    (base_capabilities(Artifact))#{execution => reactor,
                                   snapshots => #{version => ~"my-1"}}.

snapshot_capability(#{module := M}) ->
    #{version => ~"my-1",
      module => M,
      %% Trusted, and used once. Whatever `init()` touches is in the image
      %% every request restores, so keep it barren.
      imports => #{bindings => TrustedBindings,
                   snapshot_hooks => #{~"wasi_snapshot_preview1" =>
                                           wasi_preview1:snapshot_hook()},
                   compatibility_key => ~"my-1"},
      init => [{call, ~"_initialize", []}, {call, ~"init", []}],
      validate => fun(_Inst) -> ok end,
      post_restore => fun(_Inst, _Ctx) -> ok end}.
```

`prepare/3` then returns only the request's own work, since the rest is in the
image:

```erlang
invoke => [{call, ~"handle", []}]
```

Notes:

- **Declaring it is a promise.** A capture that fails fails `start_link/2`,
  because a worker that carried on would call `handle` on an instance that
  never ran `init`.
- **`capture_timeout` bounds it**, 60 s by default, and it is a worker option
  rather than a limit: a `timeout` in a limits map is enforced by whoever owns
  the instance, so the kernel runs the capture in a process of its own and
  kills it at the deadline. Raise it for a runtime that needs longer -- CPython
  takes about ninety seconds.
- **`validate` should ask the runtime, not the module.** `init`'s own return
  value never reaches the kernel, which does not read guest values, so a
  `validate` that only checks an export exists cannot tell a started runtime
  from one that failed to start. Export something that answers.
- **Every import module needs a `snapshot_hooks` entry** or the capture is
  refused. Silence means no. A module holding nothing says `stateless`.
- **`post_restore` runs in the runner**, on the request's remaining deadline,
  because it happens per request.
- **A restore is a fresh instance.** Nothing a request did survives it, which
  is what keeps the isolation the worker promises.
- `docs/snapshots.md` has the rest, including what a capture refuses and what
  an image freezes.

## Prove it

Supply `conformance_fixtures/1` and run the kit. It never looks inside a
request, so it works for a language it has never seen:

```erlang
all() -> wasm_adapter_conformance:base_cases().

echo_returns_a_result(Config) ->
    wasm_adapter_conformance:echo_returns_a_result(ctx(Config)).
```

`capabilities/1` decides what else is demanded. A declared capability makes its
cases mandatory; an undeclared one is reported as unsupported and counted as
neither, because a skip that looks green is how a test that cannot fail
arrives.

**A new language is accepted when it passes without modifying the kernel.** If
adding yours needs a kernel change, that change has to describe a new generic
capability and be exercised by the WAT adapters in
`wasm_worker_kernel_SUITE` before your adapter uses it.

## How this compares

The shape is Wasmtime's and Wasmer's, not `workerd`'s. You assemble an import
set, instantiate, call an export and release; WASI is a library you attach
rather than a mode the engine is in. Wasmer is the lifecycle reference and only
that: files, arguments, environment and limits configured explicitly, a finite
run distinguished from a long-lived spawn, the sandbox released explicitly.
Compatibility is not claimed.

Against Cloudflare Workers, which is V8 isolates under `workerd`:

| | Cloudflare Workers | here |
| --- | --- | --- |
| entry point | `fetch(request, env, ctx)` | adapter-defined |
| isolation | isolate reused per script; globals persist | fresh instance per request |
| outbound network | `fetch()` subrequests, capped per request | denied in the examples; `wasi_net` could grant it |
| npm | bundled at deploy time; no runtime resolver | same mechanism, bundle before submitting |
| the bound | CPU time; wall clock free while waiting on I/O | fuel, or a wall-clock deadline |
| timers | clamped, advancing only after I/O | nanosecond `monotonic` granted by default |

Three of those are choices rather than limits. The network is **ungranted**,
not unavailable: a `wasi_net` rule naming addresses and ports turns it on, and
note that `max_sockets` caps concurrent descriptors and `timeout` bounds one
blocking call, so neither is a subrequest budget. Workers bounds CPU where fuel
bounds work, and fuel turns the compiled tier off. And the clock is the sharp
instrument: `clock_res_get` answers 1 us while `clock_time_get` returns
nanoseconds, so the untrusted preset passes `clocks => [monotonic]` explicitly.
That does not close the timing channel and is not claimed to.
