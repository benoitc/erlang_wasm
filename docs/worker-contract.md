# Writing an adapter

This page shows you how to write an adapter. An adapter is a module that
tells the worker kernel how to run one language. It implements the
`wasm_worker_adapter` behaviour. You need one when you want to run a guest
that no shipped adapter supports. You should not need to change the kernel.

The kernel knows about modules, imports, invocations (calls into the guest),
deadlines and output channels with a size limit. It does not know what WASI
is, what JSON is, or that an entry point might be called `main`. Your adapter
handles all of those.

## What the kernel supports, exactly

The kernel does not support "any language". It supports:

> Any language runtime packaged as a WebAssembly module that an adapter can
> express as a **finite sequence of calls over supported imports**.

The kernel does not promise to support long-lived event loops, threads,
native extensions, browser ABIs or component-model guests.

## Write one

> **Where these modules come from.** The behaviour your adapter implements,
> `wasm_worker_adapter`, the conformance kit `wasm_adapter_conformance` and
> the worker kernel are installed with the application.

An adapter has eight required callbacks and two optional ones. Without
`snapshot_capability/1`, the kernel treats snapshots as `unsupported`.
Without `defaults/1`, the adapter has no defaults.

```erlang
-module(my_adapter).
-behaviour(wasm_worker_adapter).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2]).
```

Load whatever you run, once:

```erlang
artifact(_Opts) ->
    {ok, Module} = wasm:load(Bytes),
    {ok, #{module => Module}}.
```

Say what a request needs, before anything is created. This runs in the
runner (the process that runs one request), under the deadline and the heap
limit, because measuring a tenant's request means reading all of it:

```erlang
requirements(Request, _Artifact) ->
    {ok, #{min_timeout => 100, min_memory_pages => 1,
           request_bytes => byte_size(Request),
           staged_bytes => 0, staged_files => 0,
           mounts => #{ro => #{guest_path => ~"/", mode => read}}}}.
```

Build what the kernel will run. The mounts (the directories the guest can
see) already exist, and the limits are final:

```erlang
prepare(Request, #{module := M}, Env) ->
    ok = (maps:get(stage, Env))(ro, ~"main.src", Request),
    {ok, #{mode => command, module => M,
           imports => #{bindings => wasi(Env)},
           invoke => [{call, ~"_start", []}]},
     #{}}.
```

Decide what the result of each invocation means. The kernel calls this
after **every** invocation, whether it returned or trapped (stopped with a
runtime error):

```erlang
classify({ok, _Values}, _State) -> continue;
classify({error, Err}, _State) ->
    case wasi_preview1:exit_code(Err) of
        {ok, Code} -> {stop, {exited, Code}};
        error      -> {stop, trapped}
    end.
```

Turn the result into an answer, and release what you allocated:

```erlang
decode(#{outcome := exited, exit := 0, channels := #{stdout := Out}}, _S) ->
    {ok, Out};
decode(#{outcome := trapped, error := E}, _S) ->
    {error, wasm_worker_error:runtime(E)}.

cleanup(_State) -> ok.
```

## Notes

**There is no `{start}` invocation.** To translate one, the kernel would
have to know what `_start` means. So you write `{call, ~"_start", []}`
yourself. This is why a reactor and a command use the same code path in the
kernel: both are plain calls, and the adapter chooses which.

**`artifact/1` runs in a short-lived process.** The kernel calls it in a
separate process. So the file you read is freed when that process exits; an
idle worker does not keep it. Module claims taken through `wasm:load/1` (the
process's hold on a cached module) pass to the worker before the process
exits. Anything else tied to the calling process, such as an ETS table or a
link, ends with it. So return values, not resources.

**Only the adapter knows what a trap means.** WASI's `proc_exit` becomes a
trap that carries the exit status. To tell it apart from other traps, the
kernel would have to call `wasi_preview1:exit_code/1`. A kernel that calls
`wasi_preview1` is no longer independent of the language. So you decide, in
`classify/2`.

**Two rules protect you if your adapter misses a case.** `continue` on the
last invocation finishes with the real result, so a runtime error is never
lost. And when your adapter does not understand a result, it should answer
`{stop, trapped}` instead of guessing.

**Limits are final, not suggestions.** You said what you needed in
`requirements/2`. Before `prepare/3` runs, the kernel has applied its policy
and set the deadline from it. Read the limits; never return new ones.

**Permissions belong to mounts, not to files.** A staged file (a file your
adapter writes for the guest) cannot have its own mode. WASI gives rights to
a preopened directory and to everything opened below it. So declare one
named mount for each mode. The kernel creates and preopens each one before
`prepare/3` runs, and so it owns them.

**`mode => write` needs a trusted worker.** `max_staged_bytes` limits what
the *adapter* stages. It does not limit what the *guest* writes once the
directory is open. So an untrusted worker refuses a write mount with
`insufficient_limit`. A real limit needs quotas on the bytes and files a
guest writes, inside `wasi_fs`. These do not exist yet.

**Stage files through `env.stage`, not `file:write_file/2`.** `env.stage`
checks the path before it opens anything. It counts the bytes and the files
across all mounts, and refuses a file that goes past either limit. An adapter
that writes files directly has no limit. And **writing an adapter is writing
host code**: the runtime trusts adapters, and it does not trust tenants.

**Register cleanup when you allocate, not at the end.** The runner can be
killed in the middle of `prepare`. So returning a state and letting the
kernel clean it up cannot work. `env.cleanup` has `register` and `withdraw`.
It has no `transfer`: the kernel transfers once, after the guardian (the
process that owns the request's deadline and files) holds your complete
state. So "transferred" and "the state was delivered" are the same event.

`register` has three answers. With only one kind of error, an error that
neither recorded nor ran the action would leak what you allocated one line
earlier:

| | meaning |
| --- | --- |
| `{ok, Token}` | recorded |
| `{error, E, released}` | not recorded, but the action ran to completion |
| `{error, E, cleanup_failed}` | not recorded, and nobody owns that resource now |

**Actions must be safe to run twice, and safe to run at the same time.**
Two paths can run one action: the guardian's own copy, and a job whose reaper
died after allowing it. An action that is safe to run twice but not at the
same time passes every sequential test, and breaks data in exactly that
race.

**A `fun` is lost when the reaper (the node's cleanup process) crashes; a
`recover_op()` is not.** If a resource must not leak even when the reaper
crashes, describe its cleanup as `{remove_tree, RootId, RelPath}` or
`{delete_file, RootId, RelPath}`. Any other cleanup is best effort.

**Nothing a guest supplies becomes an atom.** The atom table is shared by
the whole node and never freed. Put your language's own words in `ctx` as
binaries:

```erlang
#{class => adapter, kind => adapter_failure, msg => ~"main is not defined",
  ctx => #{code => ~"no_entry_point"}}
```

## Skip the startup, if your guest is a reactor

Export `snapshot_capability/1`. The worker then captures your runtime once,
at `start_link/2`, and restores a copy of it for every request. Your guest
must be a **reactor**: a module that starts the runtime in one call and
returns. Then there is a moment with no call running, and the worker
captures the state at that moment. A WASI command that exports only `_start`
cannot be a reactor: when `_start` returns, the runtime has already shut
itself down.

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

`prepare/3` then returns only the request's own work. The start-up is
already in the image (the captured state):

```erlang
invoke => [{call, ~"handle", []}]
```

Notes:

- **If you declare it, the capture must work.** A failed capture makes
  `start_link/2` fail. Otherwise the worker would call `handle` on an
  instance that never ran `init`.
- **`capture_timeout` limits the capture**, 60 s by default. It is a worker
  option, not a limit: a `timeout` in a limits map is applied by the process
  that owns the instance. So the kernel runs the capture in a separate
  process and kills it at the deadline. Raise it for a runtime that needs
  longer: CPython takes about ninety seconds.
- **`validate` should ask the runtime, not the module.** The kernel does not
  read guest values, so it never sees what `init` returned. A `validate` that
  only checks that an export exists cannot tell a started runtime from one
  that failed to start. Export a function that answers.
- **Every import module needs a `snapshot_hooks` entry**, or the capture is
  refused. A missing entry means no. A module that holds no state says
  `stateless`.
- **`post_restore` runs in the runner**, within the time left before the
  request's deadline, because it runs for each request.
- **A restore is a fresh instance.** Nothing a request did is kept after it.
  This is how the worker keeps requests isolated from each other.
- [Snapshots](snapshots.md) has the rest, including what a capture refuses
  and what an image keeps fixed.

## Give your guest a heap floor by default

A **heap floor** is the heap size, in words, that a process starts with,
so the garbage collector does not run again and again on a heap that is too
small. See [How a heap floor works](tuning.md#how-a-heap-floor-works).

Export `defaults/1` when you have measured the heap floor your guest needs.
Then a caller who has never read the tuning guide still gets it. The worker
reads `runner_min_heap_words` and `capture_min_heap_words` from it, and
ignores any other key.

The argument is the worker's final limits map, so you can answer
differently for each tier. The compiled tier runs when `compile` is `true`
and `fuel` is `infinity`. This is the test `wasm_jit` uses:

```erlang
defaults(#{compile := true, fuel := infinity}) ->
    #{runner_min_heap_words => 1_500_000};
defaults(_Limits) ->
    #{runner_min_heap_words => 1_000_000}.
```

That is `wasm_python`'s rule. `wasm_lua` and `wasm_javascript` ignore the
argument and answer 200,000 words for both tiers.

Notes:

- **The caller's value is used first**, and `0` turns your default off.
- **A default goes through the same checks** as a value from the caller. If
  it does not fit under the worker's `max_heap_words`, the worker logs it as
  the adapter's default and does not apply it.
- **Only set a number you measured.** [Tuning a worker host](tuning.md)
  shows how to find the knee: the point after which a larger floor stops
  helping. A floor above it costs time. A capture floor can also kill a
  capture that fits without it, under the same maximum heap: CPython's
  2,000,000 words, under its own maximum of 16 M words, killed three captures
  in four. This is why `wasm_python` sets no capture default.

## Prove it

Write `conformance_fixtures/1` and run the conformance kit,
`wasm_adapter_conformance`. The kit never looks inside a request, so it works
for any language:

```erlang
all() -> wasm_adapter_conformance:base_cases().

echo_returns_a_result(Config) ->
    wasm_adapter_conformance:echo_returns_a_result(ctx(Config)).
```

`capabilities/1` decides which other cases must pass. If you declare a
capability, its cases are required. If you do not, they are reported as
unsupported, and counted neither as passed nor as failed. A skipped case that
looks like a pass would be a test that cannot fail.

**A new language is accepted when it passes without kernel changes.** If
yours needs a kernel change, that change must add a new generic capability.
The WAT adapters in `wasm_worker_kernel_SUITE` must test it before your
adapter uses it.

## How this compares

The design follows Wasmtime and Wasmer, not `workerd`. You build a set of
imports, instantiate, call an export and release. WASI is a library you add,
not a mode of the engine. Only the lifecycle follows Wasmer: you configure
files, arguments, environment and limits yourself; a run that finishes is
different from a long-lived process; you release the sandbox yourself. This
runtime does not claim to be compatible with Wasmer.

Against Cloudflare Workers, which is V8 isolates under `workerd`:

| | Cloudflare Workers | here |
| --- | --- | --- |
| entry point | `fetch(request, env, ctx)` | adapter-defined |
| isolation | isolate reused per script; globals persist | fresh instance per request |
| outbound network | `fetch()` subrequests, capped per request | denied in the examples; `wasi_net` could grant it |
| npm | bundled at deploy time; no runtime resolver | same mechanism, bundle before submitting |
| the limit | CPU time; waiting on I/O does not count | fuel, or a wall-clock deadline |
| timers | clamped, advancing only after I/O | nanosecond `monotonic` granted by default |

Three of those rows are choices, not limits:

- The network is **not granted**, but it is available. A `wasi_net` rule
  that names addresses and ports turns it on. Note that `max_sockets` limits
  how many sockets are open at once, and `timeout` limits one blocking call.
  Neither one limits the number of subrequests.
- Workers limits CPU time; fuel limits work. Fuel turns the compiled tier
  off.
- The clock is the risky one. `clock_res_get` answers 1 us, but
  `clock_time_get` returns nanoseconds. So the untrusted preset passes
  `clocks => [monotonic]` explicitly. This does not stop a guest from
  measuring time to learn secrets (a timing side channel), and the runtime
  does not claim it does.

## Read this next

[Worker internals](worker-internals.md), and the adapter recipe in
[Recipes](contributing/recipes.md).
