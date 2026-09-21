-module(wasm_script_worker).
-moduledoc """
A worker kernel: processes, deadlines, bounded streams, and an adapter.

It runs many small untrusted guest modules, one tenant's code per request. What
it knows about is modules, imports, invocations, deadlines and bounded
channels. **It does not know about WASI**, or JSON, or an entry point called
`main`. Those belong to an adapter, which is what makes a language the kernel
has never heard of expressible without changing anything here.

<!-- check: modules my_adapter -->
```erlang
{ok, W} = wasm_script_worker:start_link(my_adapter, #{}),
{ok, R} = wasm_script_worker:run(W, MyRequest).
```

## What it supports, stated exactly

Not "any language":

> Any language runtime packaged as a WebAssembly module that an adapter can
> express as a **finite sequence of calls over supported imports**.

Long-lived event loops, threads, native extensions, browser ABIs and
component-model guests are outside the guarantee.

## What is supported API

These are covered by compatibility and the release notes:

| module | what it is |
| --- | --- |
| `wasm_script_worker` | this module: start, run, submit, await, cancel, stop, and the operator view (`cleanup_stats/0`, `cleanup_requests/0`) |
| `wasm_worker_adapter` | the behaviour an adapter implements, and every type its callbacks name |
| `wasm_worker_error` | the errors a worker answers with, and the constructors an adapter builds its own with |
| `wasm_javascript`, `wasm_javascript_command`, `wasm_python`, `wasm_python_command`, `wasm_lua` | the shipped adapters |
| `wasm_adapter_conformance` | the kit that checks an adapter keeps the contract |
| `wasm_instance_worker` | the simple worker: one instance, one process, a deadline |

So are the option keys this module takes (`root`, `timeout`, `trusted`,
`limits`, `capture_timeout`, `runner_min_heap_words`,
`capture_min_heap_words`, and the `limits` keys `docs/worker.md` lists), the
`wasm` application settings `scratch_roots` and `reaper_options`, and the
error shapes: a running worker answers `{error, wasm_worker_error:worker_error()}`,
and `start_link/2,3` fails with a `gen_server` start reason, one of
`{missing_option, Key}`, `{unknown_root, Root, Known}`,
`{unknown_reaper_option, Keys}` or the adapter's own `wasm_worker_error()`.

`wasm_worker_reaper`, `wasm_worker_sup` and `wasm_script_v1` are internal:
they may change in any release.

## The execution model is the one every other runtime has

Stripped of processes and bounds, the whole job is three lines:

```erlang
{ok, Inst} = wasm:instantiate(Module, Imports, Limits),
Result     = wasm:call(Inst, Export, Args, Limits),
ok         = wasm:destroy(Inst).
```

Assemble an import set, instantiate, call an export, release. That is
Wasmtime's `Linker` and `Store`, Wasmer's `Imports` and
`exports.get_function`, wasm3's `lookup_function` and `call`. **WASI is
something an adapter puts into the imports**, exactly as those runtimes make it
a library you attach rather than a mode the engine is in.

**There is no `{start}` invocation**, because there could not be one without
this module knowing what `_start` means, and a `{start}` it translated would be
WASI knowledge smuggled into a type. An adapter that wants a command writes
`{call, ~"_start", []}` itself. That is the only reason a reactor and a command
are the same code path: they are the same call, chosen by different adapters.

## One instance per request

Three constraints point at it and a persistent interpreter fails all three.
`docs/worker.md` is unambiguous that untrusted code gets `fresh`, and replacing
a language's globals resets neither imported modules nor native interpreter
state. Fuel and `max_host_calls` open once at the outermost invocation, so a
guest blocked in a read never leaves it and its budgets accumulate over the
worker's life instead of resetting. And the compiled tier asks *after* a call
returns, so a `_start` guest that never returns never asks.

## The process shape

```text
worker (gen_server)     never blocks; holds at most one request
  |  spawn_monitor           worker learns of guardian death  (DOWN)
  |  <- guardian monitors    guardian learns of worker death  (DOWN)
guardian                traps exits; owns the mounts and the deadline;
  |  spawn_opt [link,monitor]   runs no guest code, always responsive
runner                  instantiate -> invoke -> decode -> destroy
```

**Monitors are one-way, so both directions are set up explicitly.** The worker
monitors the guardian, which tells the worker when the guardian dies and tells
the guardian nothing, so the guardian monitors the worker back.

The runner is spawned `[link, monitor]` deliberately: the **monitor** delivers
the `DOWN` carrying the exit reason the guardian reads, and the **link** kills
the runner if the guardian dies abnormally. The guardian traps exits, so the
link arrives as an `EXIT` it ignores, and it acts on the `DOWN`.

## Nothing raises

`gen_server:call` on a dead process exits, so every entry point catches it and
answers with a value, which is the runtime's rule applied to this layer's own
edges. The kinds these four can produce are in `wasm_worker_error`.
""".

-behaviour(gen_server).

-export([start_link/2, start_link/3, stop/1]).
-export([submit/2, await/3, cancel/2, run/2]).
-export([run/3, submit/3]).
-export([withdraw_waiter/3, consumed/3, channel_write/2]).
-export([default_limits/0, runner_heap_words/2, capture_heap_words/2]).
-export([cleanup_stats/0, cleanup_requests/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include_lib("kernel/include/logger.hrl").
-include_lib("kernel/include/file.hrl").

%%% ------------------------------------------------------------ behaviour ---

%% The adapter behaviour and its types live in `wasm_worker_adapter`. These
%% aliases keep `wasm_script_worker:outcome()` and the rest meaning what they
%% always did.
-type artifact() :: wasm_worker_adapter:artifact().
-type request() :: wasm_worker_adapter:request().
-type adapter_state() :: wasm_worker_adapter:adapter_state().
-type result() :: wasm_worker_adapter:result().
-type outcome() :: wasm_worker_adapter:outcome().
-type mount_name() :: wasm_worker_adapter:mount_name().
-type mount() :: wasm_worker_adapter:mount().
-type channel() :: wasm_worker_adapter:channel().
-type cleanup_cap() :: wasm_worker_adapter:cleanup_cap().
-type env() :: wasm_worker_adapter:env().
-type import_value() :: wasm_worker_adapter:import_value().
-type import_set() :: wasm_worker_adapter:import_set().
-type hook() :: wasm_worker_adapter:hook().
-type portable() :: wasm_worker_adapter:portable().
-type capture() :: wasm_worker_adapter:capture().
-type compatibility_key() :: wasm_worker_adapter:compatibility_key().
-type execution_spec() :: wasm_worker_adapter:execution_spec().
-type execution_result() :: wasm_worker_adapter:execution_result().
-type invocation_result() :: wasm_worker_adapter:invocation_result().
-type stop_class() :: wasm_worker_adapter:stop_class().
-type requirements() :: wasm_worker_adapter:requirements().
-type capabilities() :: wasm_worker_adapter:capabilities().
-type fixtures() :: wasm_worker_adapter:fixtures().
-type snapshot_cap() :: wasm_worker_adapter:snapshot_cap().
-type restore_ctx() :: wasm_worker_adapter:restore_ctx().

-export_type([artifact/0, request/0, adapter_state/0, result/0, outcome/0,
              mount_name/0, mount/0, channel/0, cleanup_cap/0, env/0,
              import_value/0, import_set/0, hook/0, portable/0, capture/0,
              compatibility_key/0, execution_spec/0, execution_result/0, invocation_result/0, stop_class/0,
              requirements/0, capabilities/0, fixtures/0, snapshot_cap/0, restore_ctx/0]).

%%% ------------------------------------------------------------------ api ---

-define(DEFAULT_TIMEOUT, 5_000).
-define(GUARDIAN_READY_TIMEOUT, 30_000).
%% One `init()` and its hooks, at `start_link/2`. Generous next to a request's
%% deadline because it is a whole language runtime coming up once, and finite
%% because the alternative is a start that never returns. A guest that needs
%% longer says so: CPython's takes about ninety seconds.
-define(CAPTURE_TIMEOUT, 60_000).
%% How long a capturer holds the image open waiting for the worker to take its
%% own holder. The worker acquires immediately, so this only bounds a worker
%% that died in between.
-define(CAPTURE_HANDOFF, 30_000).

%% The largest `max_heap_size' `size' a 64-bit emulator accepts, and the
%% default ceiling a runner is spawned under. Both are `wasm_jit's numbers and
%% the reasoning for the first is at `src/wasm_jit.erl:110'.
-define(MAX_HEAP_WORDS, ((1 bsl 59) - 1)).
-define(DEFAULT_MAX_HEAP_WORDS, (8 * 1024 * 1024)).

%% How much of the ceiling a floor is allowed to ask for.
%%
%% Not 1, because the emulator rounds a requested floor **up** to a heap-size
%% class and the jump is large: 200,000 words becomes 318,187 and 1,000 becomes
%% 1,598, which is 1.598x, the worst of the sizes measured. A floor merely
%% smaller than the ceiling is therefore not safe -- the rounded heap can land
%% above it, and a heap above `max_heap_size' is a kill at spawn, before the
%% runner has run a line. 2 covers the measured 1.598 with margin.
-define(FLOOR_HEADROOM, 2).

%% What became of a requested floor. Neither of the two changed answers is an
%% error: a worker with no floor is the worker every release had until now.
-type heap_note() :: ok | {bad, term()} | {no_room, pos_integer()}.

%% The base is `wasm_limits:untrusted/0', not a fresh map: fuel, max_depth,
%% max_heap_words, max_memory_pages and max_host_calls come from there and keep
%% their meanings. The worker adds only what the runtime has no concept of.
-define(WORKER_LIMITS,
        #{timeout            => ?DEFAULT_TIMEOUT,
          max_output_bytes   => 1_048_576,      % per stream
          max_result_bytes   => 1_048_576,
          max_combined_bytes => 1_048_576,      % script_v1.combined only
          max_request_bytes  => 1_048_576,      % source plus encoded context
          max_staged_bytes   => 8_388_608,
          max_staged_files   => 64}).

-record(w, {adapter        :: module(),
            artifact       :: artifact(),
            opts           :: map(),
            limits         :: map(),
            %% Resolved once, here, rather than per request: the answer cannot
            %% change over a worker's life and a bad value should be said once.
            runner_heap = 0 :: non_neg_integer(),
            root           :: wasm_worker_adapter:root_id(),
            timeout        :: timeout(),
            trusted        :: boolean(),
            %% Captured once at `init/1' and held for the worker's life, so a
            %% request restores rather than starting an interpreter. The worker
            %% process is the holder, which is the lifetime that matches.
            image          :: undefined | wasm:snapshot(),
            snapshot_cap   :: undefined | snapshot_cap(),
            %% in flight, at most one
            ref            :: undefined | reference(),
            id             :: undefined | binary(),
            guardian       :: undefined | pid(),
            gmon           :: undefined | reference(),
            smon           :: undefined | reference(),
            %% completed, retained until acknowledged
            done_ref       :: undefined | reference(),
            done_outcome   :: undefined | outcome(),
            %% at most one waiter
            waiter_from    :: undefined | gen_server:from(),
            waiter_token   :: undefined | reference(),
            waiter_ref     :: undefined | reference(),
            discarded  = 0 :: non_neg_integer()}).

-doc """
Start a worker for one adapter.

`Opts` takes `root` (a root id the reaper was started with, required),
`timeout`, `trusted` and a `limits` map merged over the defaults. Everything in
it is also handed to `Adapter:artifact/1`.
""".
-spec start_link(module(), map()) -> {ok, pid()} | {error, term()}.
start_link(Adapter, Opts) ->
    case prepare_start(Opts) of
        {ok, Opts1}    -> gen_server:start_link(?MODULE, {Adapter, Opts1}, []);
        {error, _} = E -> E
    end.

-spec start_link(gen_server:server_name(), module(), map()) ->
          {ok, pid()} | {error, term()}.
start_link(Name, Adapter, Opts) ->
    case prepare_start(Opts) of
        {ok, Opts1}    -> gen_server:start_link(Name, ?MODULE, {Adapter, Opts1},
                                                []);
        {error, _} = E -> E
    end.

-doc """
Counts per state of the cleanup that follows requests, node-wide. `capacity`
is how many reservations are held now; when it reaches `max_cleanup_jobs +
cleanup_queue_len` from `reaper_options`, `submit` answers
`cleanup_saturated`.

Served from the cleanup manager, which holds the view the reaper pushes it, so
it answers even while the reaper is busy in journal I/O.
""".
-spec cleanup_stats() -> map().
cleanup_stats() -> wasm_cleanup_manager:stats().

-doc """
Every request whose cleanup is still owned, with the guardian holding it.

A reservation that ends in `held` stays there until a late answer or a `DOWN`,
on purpose, since deleting a running request's mounts cannot be undone. This
is how an operator finds which guardian holds it, to kill that guardian if it
really is stuck.
""".
-spec cleanup_requests() ->
          [#{id := binary(), state := atom(), guardian := pid(),
             delivered := boolean(), actions := non_neg_integer()}].
cleanup_requests() -> wasm_cleanup_manager:requests().

%% Before the worker exists: make sure a reaper runs, and refuse a root it
%% does not have now rather than at the first request. With no reaper at all
%% (suspended, or one started by hand and stopped) the worker starts as it
%% always did and `submit' answers `no_reaper'.
prepare_start(Opts) ->
    Root = maps:get(root, Opts, scratch),
    case wasm_worker_sup:ensure_reaper() of
        {error, _} = E ->
            E;
        ok ->
            case wasm_worker_reaper:roots() of
                {error, _} ->
                    {ok, Opts#{root => Root}};
                Known ->
                    case lists:member(Root, Known) of
                        true  -> {ok, Opts#{root => Root}};
                        false -> {error, {unknown_root, Root, Known}}
                    end
            end
    end.

-spec stop(gen_server:server_ref()) -> ok.
stop(W) -> gen_server:stop(W).

-doc """
Accept a request, and reply once the guardian is ready.

Ready means the durable record is written **and** the request directory exists,
in that order: creating the directory first leaves a window where a worker and
guardian death together leaves a directory no record names and no reaper will
ever find. Intent before action, and it costs nothing extra because the record
had to be written anyway.
""".
-spec submit(gen_server:server_ref(), request()) ->
          {ok, reference()} | {error, wasm_worker_error:worker_error()}.
submit(W, Request) -> guard(W, {submit, Request, self()}, infinity).

-doc """
Wait for an outcome.

`AwaitTimeout` bounds **your wait and nothing else**. The request keeps running
under its own deadline and `{error, still_running}` says so, because a caller
who stopped waiting has not decided the tenant's code should die. `cancel/2` is
what decides that.
""".
-spec await(gen_server:server_ref(), reference(), timeout()) ->
          outcome() | {error, wasm_worker_error:worker_error()}.
await(W, Ref, AwaitTimeout) ->
    Token = make_ref(),
    try gen_server:call(W, {await, Ref, Token}, AwaitTimeout) of
        {outcome, Outcome} ->
            _ = consumed(W, Ref, Token),
            Outcome;
        {error, _} = E ->
            E
    catch
        exit:{timeout, _} ->
            %% A server cannot reply at exactly the moment its caller gives up,
            %% so catching the timeout is not enough on its own: the server
            %% still believes this caller holds the single waiter slot. The
            %% race is resolved in `withdraw_waiter/3'.
            case withdraw_waiter(W, Ref, Token) of
                {ok, Outcome} ->
                    _ = consumed(W, Ref, Token),
                    Outcome;
                _ ->
                    {error, wasm_worker_error:worker(
                              still_running, ~"gave up waiting",
                              #{waited => AwaitTimeout})}
            end;
        exit:{noproc, _} -> {error, no_worker()};
        exit:{Reason, _} -> {error, worker_died(Reason)}
    end.

-doc "Stop a request. This is what ends a tenant's code; `await/3` is not.".
-spec cancel(gen_server:server_ref(), reference()) ->
          ok | {error, wasm_worker_error:worker_error()}.
cancel(W, Ref) -> guard(W, {cancel, Ref}, infinity).

-doc """
Submit and wait for ever.

**No timeout argument**, which removes a race rather than hiding one: the
guardian already owns the execution deadline, so a second timer on the caller's
side only creates the case where both expire together and the caller sees
`still_running` an instant before the guardian publishes the real `timeout`.

With `timeout => infinity` this waits for ever, and that is what was asked for.
Leave `timeout` finite unless something outside the worker is doing the
bounding, or use `await/3` and `cancel/2`.
""".
-spec run(gen_server:server_ref(), request()) ->
          outcome() | {error, wasm_worker_error:worker_error()}.
run(W, Request) ->
    case submit(W, Request) of
        {ok, Ref}  -> await(W, Ref, infinity);
        {error, _} = E -> E
    end.

-doc """
Run `Source` with `Context` and wait for the answer: `run/2` with the request
every shipped adapter takes, `#{source => Source, context => Context}`.

```erlang
{ok, W} = wasm_script_worker:start_link(
            wasm_javascript_command, #{path => "test/fixtures/lang/qjs.wasm"}),
{ok, #{result := #{~"answer" := 42}}} =
    wasm_script_worker:run(W, <<"export function main(c)"
                                " { return {answer: c.value + 1}; }">>,
                           #{~"value" => 41}).
```
""".
-spec run(gen_server:server_ref(), binary(), term()) ->
          outcome() | {error, wasm_worker_error:worker_error()}.
run(W, Source, Context) ->
    run(W, script_request(Source, Context)).

-doc "`submit/2` with `#{source => Source, context => Context}`, as `run/3`.".
-spec submit(gen_server:server_ref(), binary(), term()) ->
          {ok, reference()} | {error, wasm_worker_error:worker_error()}.
submit(W, Source, Context) ->
    submit(W, script_request(Source, Context)).

script_request(Source, Context) -> #{source => Source, context => Context}.

-doc """
Release the waiter slot after a finite `await/3` gave up, and settle the race.

If the outcome was already sent to the abandoning caller this answers
`{ok, Outcome}` and the caller takes it; otherwise the slot is simply free. A
withdraw naming a token that is not the current waiter is `ok` and changes
nothing.
""".
-spec withdraw_waiter(gen_server:server_ref(), reference(), reference()) ->
          ok | {ok, outcome()} | {error, wasm_worker_error:worker_error()}.
withdraw_waiter(W, Ref, Token) -> guard(W, {withdraw_waiter, Ref, Token}, 5_000).

-doc """
Acknowledge an outcome, which is what releases it.

**Sending is not consuming.** A reply the worker put on the wire may never be
received, which is the whole reason the abandoning caller has to ask, so the
outcome is retained until acknowledged rather than until sent.
""".
-spec consumed(gen_server:server_ref(), reference(), reference()) ->
          ok | {error, wasm_worker_error:worker_error()}.
consumed(W, Ref, Token) -> guard(W, {consumed, Ref, Token}, 5_000).

%% Nothing raises. `gen_server:call' on a dead process exits, so every entry
%% point turns that into the value the caller was promised.
guard(W, Msg, Timeout) ->
    try gen_server:call(W, Msg, Timeout)
    catch
        exit:{noproc, _}   -> {error, no_worker()};
        exit:{normal, _}   -> {error, no_worker()};
        exit:{timeout, _}  -> {error, wasm_worker_error:worker(
                                        still_running, ~"worker did not answer",
                                        #{})};
        exit:{Reason, _}   -> {error, worker_died(Reason)}
    end.

no_worker() -> wasm_worker_error:worker(no_worker, ~"worker is gone", #{}).

worker_died(Reason) ->
    wasm_worker_error:worker(worker_died, ~"worker died", #{reason => Reason}).

%%% --------------------------------------------------------------- server ---

init({Adapter, Opts}) ->
    case maps:find(root, Opts) of
        error ->
            {stop, {missing_option, root}};
        {ok, Root} ->
            case Adapter:artifact(Opts) of
                {error, E} ->
                    {stop, E};
                {ok, Artifact} ->
                    Limits = maps:merge(
                               maps:merge(wasm_limits:untrusted(), ?WORKER_LIMITS),
                               maps:get(limits, Opts, #{})),
                    started(Adapter, Artifact, Opts, Limits, Root)
            end
    end.

started(Adapter, Artifact, Opts, Limits, Root) ->
    {Heap, Note} = runner_heap_words(Opts, Limits),
    ok = say_heap(Adapter, runner_min_heap_words, Note),
    W = #w{adapter = Adapter, artifact = Artifact, opts = Opts,
           limits = Limits, root = Root, runner_heap = Heap,
           timeout = maps:get(timeout, Limits, ?DEFAULT_TIMEOUT),
           trusted = maps:get(trusted, Opts, false)},
    {CapHeap, CapNote} = capture_heap_words(Opts, Limits),
    ok = say_heap(Adapter, capture_min_heap_words, CapNote),
    case capture_image(Adapter, Artifact,
                       #{timeout => maps:get(capture_timeout, Opts,
                                             ?CAPTURE_TIMEOUT),
                         words => maps:get(max_heap_words, Limits),
                         floor => CapHeap}) of
        {error, E}          -> {stop, E};
        {ok, undefined, _}  -> {ok, W};
        {ok, Image, Cap}    -> {ok, W#w{image = Image, snapshot_cap = Cap}}
    end.

%% The image is taken once, here, from a **trusted** initialisation context and
%% before any tenant code has run. That is the whole security argument for
%% restoring the same bytes into every request: nothing a tenant did can be in
%% them.
capture_image(Adapter, Artifact, Budget) ->
    case snapshot_cap(Adapter, Artifact) of
        unsupported -> {ok, undefined, undefined};
        Cap         -> from_store_or_capture(Cap, Budget)
    end.

%% **Look before capturing.** For CPython that is the difference between
%% reading a file and ninety seconds of interpreter start. A miss for any
%% reason -- no directory configured, no file, a corrupt one, one written by
%% another build -- costs exactly the capture that would have happened anyway,
%% which is why `wasm_snapshot_store:lookup/2` answers `miss` rather than
%% raising.
from_store_or_capture(#{module := M, imports := ImportSet} = Cap, Budget) ->
    Key = image_key(M, Cap, ImportSet),
    case wasm_snapshot_store:lookup(Key, M) of
        {ok, Image} -> {ok, Image, Cap};
        miss        -> capture_and_file(Key, Cap, Budget)
    end.

capture_and_file(Key, Cap, Budget) ->
    case capture_elsewhere(Cap, Budget) of
        {ok, Image, C} ->
            ok = wasm_snapshot_store:store(Key, Image, C),
            {ok, Image, C};
        Other ->
            Other
    end.

%% An inline module has no content hash and cannot be filed, which is the rule
%% `wasm_code_cache` already applies for the same reason: there would be
%% nothing to key on that meant the same thing twice.
image_key({wasm_module, Hash}, #{version := Version}, ImportSet) ->
    wasm_snapshot_store:key(Hash, Version,
                            maps:get(compatibility_key, ImportSet, undefined),
                            wasm_snapshot_file:image_abi());
image_key(_Other, _Cap, _ImportSet) ->
    undefined.

%% **In a process of its own, killed at the deadline.** A `timeout` in a limits
%% map bounds nothing by itself -- `wasm_limits` is explicit that it is enforced
%% by whoever owns the instance, and an inline call runs in the caller and
%% cannot be interrupted. So the owner here is a child, and a guest whose
%% `init()` never returns costs one `capture_timeout` rather than a
%% `start_link/2` that never comes back.
capture_elsewhere(Cap, #{timeout := Timeout, words := Words, floor := Floor}) ->
    Parent = self(),
    {Pid, Mon} = spawn_opt(fun() -> capture_proc(Parent, Cap) end,
                           [monitor, {max_heap_size, #{size => Words, kill => true,
                                                       error_logger => true}}
                            | heap_floor(Floor)]),
    receive
        {captured, Pid, {ok, Image, C}} ->
            %% **Before** the capturer exits, not after, which is why the child
            %% waits below rather than returning. A holder is dropped when its
            %% process dies, and the image's first holder is the process that
            %% captured it: letting that one go first invalidates the image
            %% between the send and the acquire.
            ok = wasm:acquire(Image),
            reap(Pid, Mon),
            {ok, Image, C};
        {captured, Pid, {error, _} = E} ->
            reap(Pid, Mon),
            E;
        {'DOWN', Mon, process, Pid, Reason} ->
            {error, wasm_worker_error:worker(crashed, ~"the capture died",
                                        died_why(Reason, Words, Floor))}
    after Timeout ->
        exit(Pid, kill),
        reap(Pid, Mon),
        {error, wasm_worker_error:worker(timeout, ~"the capture did not finish",
                                    #{capture_timeout => Timeout})}
    end.

%% A capture that died of `killed' is nearly always the `max_heap_size' kill,
%% and on its own that reason names nothing an operator can act on.
%%
%% It is worth spelling out because a floor makes it **more** likely rather than
%% less: `max_heap_words' bounds the peak and `capture_min_heap_words' raises
%% the baseline the peak is measured from, so a ceiling that was comfortable
%% without a floor can stop being comfortable with one. That is not the
%% `no_room' case, which `heap_words/3' refuses up front: this one passes every
%% check and then dies under load, intermittently, which is the worst way for a
%% configuration error to present. CPython at the 16 M words its own adapter
%% asks for does exactly this.
died_why(killed, Words, Floor) when Floor > 0 ->
    #{reason => ~"killed",
      hint => <<"the capture probably exceeded max_heap_words; a floor raises "
                "the baseline, so raise max_heap_words with it or drop "
                "capture_min_heap_words">>,
      max_heap_words => Words,
      capture_min_heap_words => Floor};
died_why(killed, Words, _Floor) ->
    #{reason => ~"killed",
      hint => ~"the capture probably exceeded max_heap_words",
      max_heap_words => Words};
died_why(Reason, _Words, _Floor) ->
    #{reason => reason_of(Reason)}.

%% Sends, then holds its own holder open until the parent has one of its own.
%% `reap/2` is what releases it, and a parent that died instead is covered by
%% the timeout: this process is not linked, so it would otherwise wait for
%% ever.
capture_proc(Parent, Cap) ->
    Parent ! {captured, self(), run_capture(Cap)},
    receive {'EXIT', Parent, _} -> ok
    after ?CAPTURE_HANDOFF -> ok
    end.

reap(Pid, Mon) ->
    exit(Pid, shutdown),
    receive {'DOWN', Mon, process, Pid, _} -> ok
    after 5_000 -> erlang:demonitor(Mon, [flush]) end.

reason_of(R) -> iolist_to_binary(io_lib:format(~"~p", [R])).

run_capture(#{module := M, imports := ImportSet, init := Invoke} = Cap) ->
    %% No fuel and no inner deadline: the wall clock is the parent's kill, and
    %% a work budget would be charging host code the host chose to run.
    Limits = #{fuel => infinity, timeout => infinity},
    Opts = maps:merge(Limits#{snapshotable => true}, restore_opts(ImportSet)),
    initialise(M, maps:get(bindings, ImportSet), Opts, Limits, Invoke, Cap).

snapshot_cap(Adapter, Artifact) ->
    case erlang:function_exported(Adapter, snapshot_capability, 1) of
        false -> unsupported;
        true  -> Adapter:snapshot_capability(Artifact)
    end.

%% `snapshot_hooks' and `compatibility_key' travel together with the bindings,
%% so capture and restore are matched against one declaration rather than two
%% that can drift apart.
restore_opts(ImportSet) ->
    Base = case maps:get(snapshot_hooks, ImportSet, #{}) of
               Empty when map_size(Empty) =:= 0 -> #{};
               Hooks -> #{snapshot_hooks => Hooks}
           end,
    case maps:get(compatibility_key, ImportSet, undefined) of
        undefined -> Base;
        Key       -> Base#{compatibility_key => Key}
    end.

initialise(M, Bindings, Opts, Limits, Invoke, Cap) ->
    case wasm:instantiate(M, Bindings, Opts) of
        {error, E} -> {error, wasm_worker_error:runtime(E)};
        {ok, Inst} -> initialised(Inst, Opts, Limits, Invoke, Cap)
    end.

%% The initialisation instance exists to be captured once and destroyed, so it
%% goes whether the capture worked or not.
initialised(Inst, Opts, Limits, Invoke, Cap) ->
    Result = run_init(Invoke, Inst, Opts, Limits, Cap),
    ok = wasm:destroy(Inst),
    Result.

run_init([], Inst, Opts, _Limits, #{validate := Validate} = Cap) ->
    case Validate(Inst) of
        {error, _} = E -> E;
        ok             -> captured(Inst, Opts, Cap)
    end;
run_init([{call, Name, Args} | Rest], Inst, Opts, Limits, Cap) ->
    case wasm:call(Inst, Name, Args, Limits) of
        {error, E} -> {error, wasm_worker_error:runtime(E)};
        {ok, _}    -> run_init(Rest, Inst, Opts, Limits, Cap)
    end.

captured(Inst, Opts, #{version := Version} = Cap) ->
    Keys = maps:with([compatibility_key], Opts),
    case wasm:snapshot(Inst, Keys#{version => Version}) of
        {error, E}  -> {error, wasm_worker_error:runtime(E)};
        {ok, Image} -> {ok, Image, Cap}
    end.

handle_call({submit, _Request, _From}, _F, #w{ref = Ref} = W) when Ref =/= undefined ->
    {reply, {error, wasm_worker_error:worker(busy, ~"a request is in flight", #{})}, W};
handle_call({submit, Request, Caller}, _F, W) ->
    %% Checked at every `submit', not only at `start_link': the reaper can die
    %% at any point afterwards, and a request whose cleanup would have no owner
    %% should not begin.
    case wasm_worker_reaper:alive() of
        false ->
            {reply, {error, wasm_worker_error:worker(
                              no_reaper, ~"no cleanup owner is running", #{})}, W};
        true ->
            do_submit(Request, Caller, discard_unacknowledged(W))
    end;

handle_call({await, Ref, _Token}, _F, #w{done_ref = Ref} = W) ->
    {reply, {outcome, W#w.done_outcome}, W};
handle_call({await, Ref, _Token}, _F, #w{ref = Ref, waiter_token = T} = W)
  when T =/= undefined ->
    {reply, {error, wasm_worker_error:worker(
                      already_awaited, ~"another caller is waiting", #{})}, W};
handle_call({await, Ref, Token}, From, #w{ref = Ref} = W) ->
    {noreply, W#w{waiter_from = From, waiter_token = Token, waiter_ref = Ref}};
handle_call({await, _Ref, _Token}, _F, W) ->
    {reply, {error, wasm_worker_error:worker(
                      unknown_ref, ~"no such request", #{})}, W};

handle_call({withdraw_waiter, Ref, _Token}, _F, #w{done_ref = Ref} = W) ->
    %% The outcome was published while the caller was giving up. It is retained
    %% until acknowledged, so handing it over here loses nothing.
    {reply, {ok, W#w.done_outcome}, W};
handle_call({withdraw_waiter, _Ref, Token}, _F, #w{waiter_token = Token} = W) ->
    {reply, ok, clear_waiter(W)};
handle_call({withdraw_waiter, _Ref, _Token}, _F, W) ->
    {reply, ok, W};

handle_call({consumed, Ref, _Token}, _F, #w{done_ref = Ref} = W) ->
    {reply, ok, W#w{done_ref = undefined, done_outcome = undefined}};
handle_call({consumed, _Ref, _Token}, _F, W) ->
    {reply, ok, W};

handle_call({cancel, Ref}, _F, #w{ref = Ref, guardian = G} = W) ->
    G ! {cancel, Ref},
    {reply, ok, W};
handle_call({cancel, _Ref}, _F, W) ->
    {reply, {error, wasm_worker_error:worker(unknown_ref, ~"no such request", #{})}, W};

handle_call(_Msg, _F, W) ->
    {reply, {error, wasm_worker_error:worker(unknown_ref, ~"bad call", #{})}, W}.

handle_cast(_, W) -> {noreply, W}.

handle_info({guardian_done, Ref, Outcome}, #w{ref = Ref} = W) ->
    {noreply, publish(Outcome, W)};

handle_info({'DOWN', Mon, process, _Pid, Reason}, #w{gmon = Mon, ref = Ref} = W)
  when Ref =/= undefined ->
    %% The guardian died without publishing. Whatever it was doing, the request
    %% did not reach a conclusion of its own.
    {noreply, publish({error, wasm_worker_error:worker(
                                crashed, ~"the request died",
                                #{reason => Reason})}, W)};

handle_info({'DOWN', Mon, process, _Pid, _Reason}, #w{smon = Mon} = W) ->
    %% The submitting process is gone, so nobody is coming back for this. A
    %% caller that dies does cancel.
    case W#w.guardian of
        undefined -> ok;
        G -> G ! {cancel, W#w.ref}
    end,
    {noreply, W};

handle_info(_, W) -> {noreply, W}.

terminate(Why, #w{image = Image} = W) ->
    %% Belt as well as braces: a holder goes when its process dies, and this
    %% process is the holder, so the image would be released anyway. Saying so
    %% is what makes the lifetime readable.
    _ = Image =:= undefined orelse wasm:release(Image),
    stop_guardian(Why, W).

stop_guardian(_Why, #w{guardian = undefined}) -> ok;
stop_guardian(_Why, #w{guardian = G}) ->
    %% The guardian monitors the worker and reacts to this itself; killing it
    %% here would skip the cleanup it is holding.
    G ! {cancel, undefined},
    ok.

-doc """
The ceilings a worker starts with, over `wasm_limits:untrusted/0`.

Exported so that `docs/worker.md` can be held to listing every one of them: a
default nobody can find is a default nobody can change.
""".
-spec default_limits() -> map().
default_limits() -> ?WORKER_LIMITS.

-doc """
How much heap a request runner starts with, and what happened to the number.

`runner_min_heap_words` is a **floor**, not a bound: it says how much room to
give a request, where every key in a limits map says what a guest may not
exceed. Off unless set, because the right value is a property of the guest and
there is no number that suits all of them. `docs/tuning.md` is how to find your
own; `test/audit/PERF.md` has the one measured for QuickJS.

Resolved once at `start_link/2` and reported rather than applied silently,
which is `wasm_jit`'s `resolve_max_heap_words` arrangement and is here for the
same reason: a setting nobody can read back is a setting nobody can tell is
being used. Exported so the policy can be asserted without starting a worker.

Two ways a number comes back changed, and neither is an error:

- `{bad, Term}` -- not a whole number of words between the emulator's own
  minimum and its undocumented maximum. Answers off.
- `{no_room, Ceiling}` -- the floor does not fit under this worker's
  `max_heap_words` with the headroom the emulator's rounding needs. Answers
  off, because the alternative is a runner killed at spawn and a worker whose
  every request fails for a reason nothing names.
""".
-spec runner_heap_words(map(), map()) -> {non_neg_integer(), heap_note()}.
runner_heap_words(Opts, Limits) ->
    heap_words(runner_min_heap_words, Opts, Limits).

-doc """
The same, for the process a capture runs in.

A separate setting because it is a different process doing different work: the
capturer runs the guest's `init()` once and the runner answers a request, and
the two want numbers that are nothing like each other. CPython's capture takes
2,000,000 words to a request's 1,000,000, and a guest with no capture at all
wants only the first.

The effect is larger here than anywhere else in this module.
`test/audit/PERF.md` has it at 5x on a CPython worker start.
""".
-spec capture_heap_words(map(), map()) -> {non_neg_integer(), heap_note()}.
capture_heap_words(Opts, Limits) ->
    heap_words(capture_min_heap_words, Opts, Limits).

heap_words(Key, Opts, Limits) ->
    Ceiling = maps:get(max_heap_words, Limits, ?DEFAULT_MAX_HEAP_WORDS),
    {min_heap_size, Min} = erlang:system_info(min_heap_size),
    case maps:get(Key, Opts, 0) of
        %% An explicit zero is a clean disabled state, spelled the way
        %% `max_heap_size' spells it.
        0 ->
            {0, ok};
        W when is_integer(W), W >= Min, W =< ?MAX_HEAP_WORDS,
               W * ?FLOOR_HEADROOM =< Ceiling ->
            {W, ok};
        W when is_integer(W), W >= Min, W =< ?MAX_HEAP_WORDS ->
            {0, {no_room, Ceiling}};
        Bad ->
            {0, {bad, Bad}}
    end.

%% Once per worker, at its start, because that is where the value is resolved.
%% A worker per tenant would otherwise log the same line per tenant.
say_heap(_Adapter, _Key, ok) ->
    ok;
say_heap(Adapter, Key, {bad, Bad}) ->
    logger:warning("wasm_script_worker: ~p: ~s is ~p, which is not a heap size; "
                   "no floor is applied", [Adapter, Key, Bad]);
say_heap(Adapter, Key, {no_room, Ceiling}) ->
    logger:warning("wasm_script_worker: ~p: ~s does not fit under max_heap_words "
                   "of ~p with room for the emulator's rounding; no floor is "
                   "applied", [Adapter, Key, Ceiling]).

%%% ------------------------------------------------------------- submitting ---

do_submit(Request, Caller, W) ->
    Ref = make_ref(),
    Id = binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
    %% Fixed here, before anything tenant-controlled has been touched, and
    %% never reset afterwards. Every phase spends out of this one clock.
    Deadline = case W#w.timeout of
                   infinity -> infinity;
                   Ms       -> erlang:monotonic_time(millisecond) + Ms
               end,
    Self = self(),
    Args = #{worker => Self, ref => Ref, id => Id, deadline => Deadline,
             adapter => W#w.adapter, artifact => W#w.artifact,
             request => Request, limits => W#w.limits, root => W#w.root,
             trusted => W#w.trusted, image => W#w.image,
             snapshot_cap => W#w.snapshot_cap,
             runner_heap => W#w.runner_heap},
    {G, GMon} = spawn_monitor(fun() -> guardian(Args) end),
    receive
        {guardian_ready, Ref, ok} ->
            SMon = erlang:monitor(process, Caller),
            {reply, {ok, Ref},
             W#w{ref = Ref, id = Id, guardian = G, gmon = GMon, smon = SMon}};
        {guardian_ready, Ref, {error, E}} ->
            erlang:demonitor(GMon, [flush]),
            {reply, {error, E}, W};
        {'DOWN', GMon, process, G, Reason} ->
            {reply, {error, wasm_worker_error:worker(
                              crashed, ~"the request could not start",
                              #{reason => Reason})}, W}
    after ?GUARDIAN_READY_TIMEOUT ->
        exit(G, kill),
        erlang:demonitor(GMon, [flush]),
        {reply, {error, wasm_worker_error:worker(
                          crashed, ~"the request did not start", #{})}, W}
    end.

%% The worker holds one slot and a caller that never came back must not wedge
%% it. This is the one window in which a completed result is lost, and it is
%% logged and counted rather than engineered away: the alternative is a worker
%% a dead caller can stop for ever.
discard_unacknowledged(#w{done_ref = undefined} = W) -> W;
discard_unacknowledged(#w{done_ref = Ref} = W) ->
    ?LOG_WARNING("wasm_script_worker: discarding unacknowledged outcome for ~p", [Ref]),
    W#w{done_ref = undefined, done_outcome = undefined,
        discarded = W#w.discarded + 1}.

publish(Outcome, W) ->
    case W#w.waiter_from of
        undefined -> ok;
        From      -> gen_server:reply(From, {outcome, Outcome})
    end,
    _ = case W#w.gmon of
            undefined -> ok;
            GMon      -> erlang:demonitor(GMon, [flush])
        end,
    _ = case W#w.smon of
            undefined -> ok;
            SMon      -> erlang:demonitor(SMon, [flush])
        end,
    %% Retained until acknowledged, and the slot frees now: a new `submit' is
    %% accepted while the previous request's cleanup is still running, because
    %% blocking on cleanup would make one slow release stall a tenant.
    W1 = clear_waiter(W),
    W1#w{ref = undefined, id = undefined, guardian = undefined,
         gmon = undefined, smon = undefined,
         done_ref = W#w.ref, done_outcome = Outcome}.

clear_waiter(W) ->
    W#w{waiter_from = undefined, waiter_token = undefined, waiter_ref = undefined}.

%%% -------------------------------------------------------------- guardian ---

-record(g, {worker      :: pid(),
            ref         :: reference(),
            id          :: binary(),
            deadline    :: integer() | infinity,
            adapter     :: module(),
            artifact    :: artifact(),
            request     :: request(),
            image       :: undefined | wasm:snapshot(),
            snapshot_cap :: undefined | snapshot_cap(),
            limits      :: map(),
            runner_heap :: non_neg_integer(),
            root        :: wasm_worker_adapter:root_id(),
            trusted     :: boolean(),
            wmon        :: reference(),
            dir         :: file:filename_all(),
            runner      :: undefined | pid(),
            rmon        :: undefined | reference(),
            %% The per-request steward. Every reaper interaction goes through
            %% it, so the reaper is never called from this process directly.
            steward     :: undefined | pid(),
            %% The steward's monitor, so the terminal handoff can fall back to
            %% the mirror if the steward dies before confirming cleanup.
            smon        :: undefined | reference(),
            %% Cleanup operations forwarded to the steward and not yet answered,
            %% keyed by a correlation reference. Holds what the reply needs: the
            %% runner to answer and, for register/transfer, what to record on
            %% success. The guardian stays in its deadline `receive' while these
            %% are outstanding, which is how a wedged reaper stops blocking it.
            pending = #{} :: #{reference() => tuple()},
            channels    :: map(),
            mounts = #{} :: #{mount_name() => mount()},
            %% The guardian made every `register' call, so it keeps the list as
            %% it goes. That mirror is what survives the reaper.
            actions = [] :: [{wasm_worker_adapter:token(), wasm_worker_adapter:action()}],
            delivered = false :: boolean(),
            adapter_state      :: undefined | {module(), adapter_state()},
            staged = #{}  :: #{binary() => non_neg_integer()},
            staged_bytes = 0 :: non_neg_integer()}).

guardian(#{worker := Worker, ref := Ref, id := Id} = Args) ->
    process_flag(trap_exit, true),
    %% Monitors are one-way. The worker monitors this process; this is the
    %% other direction, and it is one of the five terminal events.
    WMon = erlang:monitor(process, Worker),
    Root = maps:get(root, Args),
    %% One steward per request, started before the reservation, because the
    %% reservation itself is the first reaper interaction and it goes through
    %% the steward like every other.
    {ok, Steward} = wasm_cleanup_steward_sup:start_steward(Id),
    case wasm_cleanup_steward:reserve(Steward, self(), Root, <<"req-", Id/binary>>) of
        {error, E} ->
            wasm_cleanup_steward:stop(Steward),
            Worker ! {guardian_ready, Ref, {error, E}},
            ok;
        {ok, Dir} ->
            case filelib:ensure_path(Dir) of
                {error, Why} ->
                    wasm_cleanup_steward:stop(Steward),
                    Worker ! {guardian_ready, Ref,
                              {error, wasm_worker_error:worker(
                                        crashed, ~"could not create the request",
                                        #{reason => Why})}},
                    ok;
                ok ->
                    Worker ! {guardian_ready, Ref, ok},
                    start_runner(Args, WMon, Dir, Steward)
            end
    end.

start_runner(Args, WMon, Dir, Steward) ->
    Limits = maps:get(limits, Args),
    G0 = #g{worker = maps:get(worker, Args), ref = maps:get(ref, Args),
            id = maps:get(id, Args), deadline = maps:get(deadline, Args),
            adapter = maps:get(adapter, Args), artifact = maps:get(artifact, Args),
            request = maps:get(request, Args), limits = Limits,
            image = maps:get(image, Args),
            snapshot_cap = maps:get(snapshot_cap, Args),
            runner_heap = maps:get(runner_heap, Args),
            root = maps:get(root, Args), trusted = maps:get(trusted, Args),
            wmon = WMon, dir = Dir, steward = Steward,
            smon = erlang:monitor(process, Steward),
            channels = channels(Limits)},
    Self = self(),
    Words = maps:get(max_heap_words, Limits, 8 * 1024 * 1024),
    %% `spawn_opt', not `process_flag' as the first line of the runner: the
    %% closure and the request are copied onto the new heap *before* that line
    %% would run, so the bound would not cover the copy it most needs to.
    %%
    %% `[link, monitor]' deliberately: the monitor delivers the reason, and the
    %% link kills the runner if this process dies abnormally.
    {Pid, Mon} = spawn_opt(
                   fun() -> runner(Self, G0) end,
                   [link, monitor,
                    {max_heap_size, #{size => Words, kill => true,
                                      error_logger => true}}
                    | heap_floor(G0#g.runner_heap)]),
    loop(G0#g{runner = Pid, rmon = Mon}).

%% A floor and not a bound, and it has to be given here rather than set from
%% the runner's first line for the same reason `max_heap_size' does:
%% `min_heap_size' takes effect at the *next* collection, so by the time an
%% in-process call ran, the thrashing it exists to prevent has already
%% happened. Setting it in place recovered a third of what setting it at spawn
%% recovered; `test/audit/PERF.md` has both.
heap_floor(0)     -> [];
heap_floor(Words) -> [{min_heap_size, Words}].

loop(G) ->
    receive
        {stage, From, Mount, Path, Data} ->
            {Reply, G1} = do_stage(G, Mount, Path, Data),
            From ! {stage_reply, Reply},
            loop(G1);

        {mounts, From, Declared} ->
            {Reply, G1} = make_mounts(G, Declared),
            From ! {mounts_reply, Reply},
            loop(G1);

        {register, From, Action} ->
            loop(forward(G, {register, Action}, {register, From, Action}));

        {withdraw, From, Token} ->
            %% Not dropped speculatively: the action stays in the mirror until the
            %% reaper confirms the withdraw, so a withdraw that is refused or lost
            %% leaves the action owned (the mirror is what survives the reaper).
            loop(forward(G, {withdraw, Token}, {withdraw, From, Token}));

        {deliver_state, From, Mod, AState} ->
            %% Transfer is the kernel's, and it happens here: once, after this
            %% process holds the complete state. "Transferred" and "a state was
            %% delivered" are then the same event rather than two that can come
            %% apart, so the flag is set when the steward answers.
            loop(forward(G, {transfer, Mod, AState},
                         {deliver_state, From, Mod, AState}));

        {steward_reply, CorrRef, Reply} ->
            loop(steward_reply(G, CorrRef, Reply));

        {result, Runner, Outcome} when Runner =:= G#g.runner ->
            finish(G, Outcome, false);

        {'DOWN', Mon, process, _P, Reason} when Mon =:= G#g.rmon ->
            %% The runner's own `DOWN': it is already gone, so `finish' must not
            %% wait for a `DOWN' it has just consumed.
            finish(G, runner_died(G, Reason), true);

        {'DOWN', Mon, process, _P, _Reason} when Mon =:= G#g.wmon ->
            finish(G, {error, wasm_worker_error:worker(
                                cancelled, ~"the worker is gone", #{})}, false);

        {cancel, _Ref} ->
            finish(G, {error, wasm_worker_error:worker(
                                cancelled, ~"cancelled", #{})}, false);

        {worker_reaper_handshake, Reaper, Id} ->
            %% A timeout is not a denial, so answering promptly is what keeps a
            %% live request out of the orphan path. This process runs no guest
            %% code, which is what makes that promise keepable.
            Reaper ! {handshake_reply, Id, case Id =:= G#g.id of
                                              true  -> yes;
                                              false -> no
                                          end},
            loop(G);

        {'EXIT', _Pid, _Reason} ->
            %% The runner is linked as well as monitored, so its death arrives
            %% twice. The `DOWN' carries the reason and is what is acted on.
            loop(G)
    after remaining(G#g.deadline) ->
        finish(G, {error, wasm_worker_error:worker(
                            timeout, ~"deadline reached",
                            #{limit => maps:get(timeout, G#g.limits, undefined)})},
               false)
    end.

%% A runner that exits abnormally either passed a channel bound, in which case
%% the reason says so, or died some other way.
runner_died(G, {channel_limit, result}) ->
    {error, wasm_worker_error:worker(result_limit, ~"result channel bound passed",
                                #{limit => maps:get(max_result_bytes, G#g.limits)})};
runner_died(G, {channel_limit, Which}) ->
    Bound = stream_bound(maps:get(max_output_bytes, G#g.limits), Which),
    {error, wasm_worker_error:worker(output_limit, ~"stream bound passed",
                                #{stream => Which, limit => Bound})};
runner_died(_G, killed) ->
    {error, wasm_worker_error:worker(crashed, ~"the runner was killed", #{})};
runner_died(_G, Reason) ->
    {error, wasm_worker_error:worker(crashed, ~"the runner died",
                                #{reason => Reason})}.

remaining(infinity) -> infinity;
remaining(Deadline) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

%% In every path: kill the runner, wait for its `DOWN', relay the outcome, then
%% hand the cleanup on. The outcome is relayed *before* cleanup, so a
%% `cleanup/1' that fails or hangs can never become an error in a result the
%% caller already has.
finish(G0, Outcome, RunnerDown) ->
    kill_runner(G0, RunnerDown),
    %% Cleanup messages the runner sent before its DOWN may still be in the
    %% mailbox; forward them so a last-moment action reaches the mirror and the
    %% steward before the request is handed off.
    G = drain(G0),
    G#g.worker ! {guardian_done, G#g.ref, with_partial_output(G, Outcome)},
    maps:foreach(fun(_K, C) -> channel_delete(C) end, G#g.channels),
    %% The result is published, so a later worker DOWN is no longer a
    %% cancellation and must not publish a second outcome.
    _ = demonitor(G#g.wmon, [flush]),
    hand_off(G),
    ok.

drain(G) ->
    receive
        {register, From, Action} ->
            drain(forward(G, {register, Action}, {register, From, Action}));
        {withdraw, From, Token} ->
            drain(forward(G, {withdraw, Token}, {withdraw, From, Token}));
        {deliver_state, From, Mod, AState} ->
            drain(forward(G, {transfer, Mod, AState},
                          {deliver_state, From, Mod, AState}))
    after 0 ->
        G
    end.

%% Cleanup is the steward's to complete with the reaper, and the guardian waits
%% for it -- but only after publishing, so the result is never held up. It exits
%% once the steward confirms the reaper owns cleanup. If the steward cannot reach
%% the reaper, dies first, or is silent past the grace, the guardian runs its
%% mirror as the last-resort fallback: the actions it kept as it registered them.
hand_off(G) ->
    wasm_cleanup_steward:complete(G#g.steward, self()),
    %% No timeout: a reaper that is merely slow to own cleanup must never be
    %% mistaken for one that is gone. The steward always resolves the finish --
    %% owned when a reaper accepts it, unavailable when none can be reached -- or
    %% dies, and the guardian falls back to local cleanup only on those.
    receive
        {cleanup_owned, _Steward} ->
            ok;
        {cleanup_unavailable, _Steward} ->
            local_cleanup(G);
        {'DOWN', SMon, process, _P, _R} when SMon =:= G#g.smon ->
            local_cleanup(G)
    end.

%% No reaper can own the cleanup, so hand the request's complete mirror to the
%% manager, which runs it under a job lease off this process. The guardian has
%% already published its result and freed the worker slot, so it does not wait
%% for the cleanup to finish; the manager owns the job from here.
local_cleanup(G) ->
    Mirror = #{id => G#g.id, dir => G#g.dir,
               adapter_state => mirror_adapter_state(G),
               actions => mirror_actions(G)},
    ok = wasm_cleanup_manager:start_local_cleanup(G#g.id, Mirror).

%% The tables are this process's, so they survive a killed runner. A `timeout'
%% or `cancelled' outcome therefore carries what the guest had already written,
%% which is most of what makes one debuggable.
with_partial_output(_G, {ok, _} = Ok) ->
    Ok;
with_partial_output(G, {error, #{ctx := Ctx} = E}) ->
    Read = fun(K) -> {B, _} = channel_read(maps:get(K, G#g.channels)), B end,
    {error, E#{ctx => Ctx#{channels => #{stdout => Read(stdout),
                                         stderr => Read(stderr),
                                         result => Read(result)}}}}.

%% The guardian only enters its loop with a runner spawned, so there is no
%% "no runner yet" case to guard against here.
%%
%% `RunnerDown' is `true' only when we got here from the runner's own `DOWN':
%% the process is already gone and its `DOWN' already consumed, so waiting for
%% one would burn the whole timeout. Every other path kills a live runner and
%% waits, bounded, for it to go. Liveness is passed in rather than inferred with
%% `is_process_alive/1', which would be its own race.
kill_runner(#g{rmon = Mon}, true) ->
    _ = demonitor(Mon, [flush]),
    ok;
kill_runner(#g{runner = Pid, rmon = Mon}, false) ->
    exit(Pid, kill),
    receive {'DOWN', Mon, process, Pid, _} -> ok after 5_000 -> ok end,
    ok.

%% The complete mirror (invariant 5): the guardian holds unacknowledged actions
%% and adapter state in its pending map, so a steward that dies or a reaper that
%% never answered does not lose them. Confirmed adapter state wins; otherwise an
%% unacknowledged transfer's.
mirror_adapter_state(#g{adapter_state = {_, _} = S}) ->
    S;
mirror_adapter_state(#g{pending = P}) ->
    case [{M, A} || {deliver_state, _From, M, A} <- maps:values(P)] of
        [S | _] -> S;
        []      -> undefined
    end.

%% Confirmed owned funs plus unacknowledged register funs. Durable operations are
%% covered by removing the request directory, so only closures need running here.
mirror_actions(#g{actions = As, pending = P}) ->
    Confirmed = [A || {_T, A} <- As, is_function(A, 0)],
    Pending   = [A || {register, _From, A} <- maps:values(P), is_function(A, 0)],
    Confirmed ++ Pending.

%%% ---------------------------------------------------------------- mounts ---

%% Each declared mount is its own host directory with its own mode, because a
%% mode cannot belong to a file: a preopen grants rights to a directory and
%% everything opened beneath it. They are created here, before `prepare/3'
%% runs, which is what lets this process own them.
make_mounts(G, Declared) ->
    Names = maps:keys(Declared),
    case [N || N <- Names, maps:get(mode, maps:get(N, Declared)) =:= write,
               not G#g.trusted] of
        [_ | _] = Bad ->
            {{error, wasm_worker_error:worker(
                       insufficient_limit,
                       ~"a writable mount needs a trusted worker",
                       #{mounts => Bad})}, G};
        [] ->
            create_mounts(G, Declared, Names, #{})
    end.

create_mounts(G, _Declared, [], Acc) ->
    {{ok, Acc}, G#g{mounts = Acc}};
create_mounts(G, Declared, [Name | Rest], Acc) ->
    #{guest_path := GuestPath, mode := Mode} = maps:get(Name, Declared),
    Dir = filename:join(G#g.dir, atom_to_list(Name)),
    case filelib:ensure_path(Dir) of
        ok ->
            M = #{guest_path => GuestPath, host_dir => Dir, mode => Mode},
            create_mounts(G, Declared, Rest, Acc#{Name => M});
        {error, Why} ->
            {{error, wasm_worker_error:worker(crashed, ~"could not create a mount",
                                         #{mount => Name, reason => Why})}, G}
    end.

%%% ---------------------------------------------------------------- staging ---

%% The only bounded way to put a file in a mount, which is why it is handed
%% down in `env' rather than left to `file:write_file/2'. Every call debits the
%% byte and file budgets across all mounts together and refuses past either,
%% which is the enforcement a post-write audit cannot provide.
do_stage(G, Mount, Path, Data) ->
    case maps:find(Mount, G#g.mounts) of
        error ->
            {{error, bad_stage(~"undeclared mount", #{mount => Mount})}, G};
        {ok, #{host_dir := Dir}} ->
            case safe_target(Dir, Path) of
                {error, _} = E -> {E, G};
                {ok, Target}   -> stage_write(G, Mount, Path, Target, Data)
            end
    end.

stage_write(G, Mount, Path, Target, Data) ->
    Bin = iolist_to_binary(Data),
    Size = byte_size(Bin),
    Key = <<(atom_to_binary(Mount))/binary, $/, Path/binary>>,
    Prev = maps:get(Key, G#g.staged, undefined),
    %% Re-staging a path replaces it and re-debits only the delta, so an
    %% adapter rewriting a file does not pay twice and the file count does not
    %% change.
    Bytes = G#g.staged_bytes - zero(Prev) + Size,
    Files = maps:size(G#g.staged) + case Prev of undefined -> 1; _ -> 0 end,
    MaxBytes = maps:get(max_staged_bytes, G#g.limits),
    MaxFiles = maps:get(max_staged_files, G#g.limits),
    if
        Bytes > MaxBytes ->
            {{error, wasm_worker_error:worker(
                       insufficient_limit, ~"staged bytes exceeded",
                       #{limit => MaxBytes, would_be => Bytes})}, G};
        Files > MaxFiles ->
            {{error, wasm_worker_error:worker(
                       insufficient_limit, ~"staged files exceeded",
                       #{limit => MaxFiles, would_be => Files})}, G};
        true ->
            %% Written to a temp name and renamed on success, so a re-stage
            %% that fails leaves the previous file and its previous charge
            %% intact and never turns an existing file into a missing one.
            Tmp = iolist_to_binary([Target, ".part"]),
            case write_then_rename(Tmp, Target, Bin) of
                ok ->
                    {ok, G#g{staged = maps:put(Key, Size, G#g.staged),
                             staged_bytes = Bytes}};
                {error, Why} ->
                    %% A partial write is removed and its bytes refunded before
                    %% the error returns: the accounting matches what is on
                    %% disk either way.
                    _ = file:delete(Tmp),
                    {{error, wasm_worker_error:worker(
                               crashed, ~"staging failed",
                               #{path => Path, reason => Why})}, G}
            end
    end.

write_then_rename(Tmp, Target, Bin) ->
    case filelib:ensure_dir(Target) of
        {error, Why} -> {error, Why};
        ok ->
            case file:write_file(Tmp, Bin) of
                {error, Why} -> {error, Why};
                ok           -> file:rename(Tmp, Target)
            end
    end.

zero(undefined) -> 0;
zero(N) -> N.

%% The check is on the normalised path, not the string, and it is made before
%% anything is opened. An absolute path, any `..' element, or a symlink
%% component is refused as a full worker error, all four keys, like every other
%% error here.
safe_target(Dir, Path) when is_binary(Path) ->
    case filename:split(Path) of
        [] ->
            {error, bad_stage(~"empty path", #{path => Path})};
        [<<"/">> | _] ->
            {error, bad_stage(~"absolute path", #{path => Path})};
        Parts ->
            case lists:any(fun(P) -> P =:= <<"..">> orelse P =:= <<".">> end,
                           Parts) of
                true ->
                    {error, bad_stage(~"path escapes the mount", #{path => Path})};
                false ->
                    no_symlinks(Dir, Parts, Path)
            end
    end;
safe_target(_Dir, Path) ->
    {error, bad_stage(~"path is not a binary", #{path => Path})}.

no_symlinks(Dir, Parts, Path) ->
    Target = filename:join([Dir | Parts]),
    case walk(Dir, Parts) of
        ok    -> {ok, Target};
        error -> {error, bad_stage(~"symlink component", #{path => Path})}
    end.

walk(_Dir, []) -> ok;
walk(Dir, [P | Rest]) ->
    Next = filename:join(Dir, P),
    case file:read_link_info(Next, [raw]) of
        {ok, #file_info{type = symlink}} -> error;
        _                                -> walk(Next, Rest)
    end.

bad_stage(Msg, Ctx) -> wasm_worker_error:worker(bad_stage_path, Msg, Ctx).

%%% -------------------------------------------------------------- cleanup ---

%% Hand a cleanup operation to the steward with a fresh correlation reference,
%% and remember what the reply will need. The guardian returns to its `receive'
%% at once; the answer arrives later as `{steward_reply, CorrRef, Reply}'.
forward(G, Operation, Waiting) ->
    CorrRef = make_ref(),
    wasm_cleanup_steward:forward(G#g.steward, CorrRef, self(), Operation),
    G#g{pending = maps:put(CorrRef, Waiting, G#g.pending)}.

%% Relay a steward's answer to the runner that is waiting for it, and record
%% what the operation established. A reference not in the map is a reply for an
%% operation whose request already finished, and is dropped.
%%
%% The ceiling on the action list is the reaper's, and only the reaper's: the
%% mirror stays bounded for free, because it only grows on `{ok, Token}'.
steward_reply(G, CorrRef, Reply) ->
    case maps:take(CorrRef, G#g.pending) of
        error ->
            G;
        {{register, From, Action}, Pending} ->
            From ! {register_reply, Reply},
            G1 = G#g{pending = Pending},
            case Reply of
                {ok, Token} -> G1#g{actions = [{Token, Action} | G1#g.actions]};
                _           -> G1
            end;
        {{withdraw, From, Token}, Pending} ->
            From ! {withdraw_reply, Reply},
            G1 = G#g{pending = Pending},
            case Reply of
                ok -> G1#g{actions = lists:keydelete(Token, 1, G1#g.actions)};
                _  -> G1
            end;
        {{deliver_state, From, Mod, AState}, Pending} ->
            From ! {deliver_state_reply, Reply},
            G#g{pending = Pending, delivered = true, adapter_state = {Mod, AState}}
    end.

%%% -------------------------------------------------------------- channels ---

%% A counter in `atomics', incremented by the writing process itself, and an
%% `ordered_set' holding the chunks keyed by the byte offset the counter
%% returned. The limit decision is a compare in the writer, synchronously,
%% before anything else happens.
%%
%% The obvious implementation does not work and the runtime says why:
%% `write_stdio/2' discards a sink fun's return value and reports the write as
%% accepted, so a sink cannot refuse a write; and for a pid it sends a message,
%% so the guest races on while the bound goes unchecked.
%% `max_output_bytes' is per stream, and it may say so: an integer bounds both
%% the same, and `#{stdout := N, stderr := M}' bounds them apart. That exists
%% because a profile can put its result on stdout, which makes that descriptor
%% carry two things and the other descriptor carry one. The kernel still knows
%% nothing about transports; it knows that two streams can need two numbers.
channels(Limits) ->
    Out = maps:get(max_output_bytes, Limits),
    Res = maps:get(max_result_bytes, Limits),
    #{stdout => new_channel(stdout, stream_bound(Out, stdout)),
      stderr => new_channel(stderr, stream_bound(Out, stderr)),
      result => new_channel(result, Res)}.

stream_bound(N, _Which) when is_integer(N) -> N;
stream_bound(Map, Which) when is_map(Map) -> maps:get(Which, Map).

new_channel(Which, Limit) ->
    %% `ordered_set' is load-bearing: a plain `set' gives no key order at all,
    %% so the table type *is* the ordering guarantee.
    {channel, Which, ets:new(worker_channel, [ordered_set, public]),
     atomics:new(1, []), Limit}.

-doc """
Write to a channel, and stop the guest if that passed the bound.

`atomics:add_get/3` hands back the new total, so the offset before the write is
the key: ordering is decided by the same atomic operation that decided the
bound, with no sequence number to keep in step.

**`exit/2`, never `exit/1`, and the runner must not trap exits.** The sink runs
inside `wasm:call`, which wraps execution in `wasm_error:capture/2`, and that
ends in a catch-all `Class:Reason:Stack` clause. `exit/1` raises a catchable
exception, so capture swallows it and reports `#{kind => internal}` while the
runner sails on into `decode/2`. `exit/2` sends a **signal**, which no `try`
can intercept.
""".
-spec channel_write(channel(), iodata()) -> ok.
channel_write({channel, Which, Tab, Counter, Limit}, Data) ->
    Bin = iolist_to_binary(Data),
    Size = byte_size(Bin),
    New = atomics:add_get(Counter, 1, Size),
    %% Inserted before the decision, so the chunk that passed the bound is part
    %% of what a `timeout' or `output_limit' outcome carries back.
    true = ets:insert(Tab, {New - Size, Bin}),
    case New > Limit of
        true  -> exit(self(), {channel_limit, Which});
        false -> ok
    end.

%% Assembled exactly once, after execution ends, by folding the table in key
%% order. During the request nothing is concatenated and nothing is copied.
channel_read({channel, _Which, Tab, Counter, Limit}) ->
    Bin = iolist_to_binary([D || {_Off, D} <- ets:tab2list(Tab)]),
    {Bin, atomics:get(Counter, 1) > Limit}.

channel_delete({channel, _Which, Tab, _C, _L}) -> ets:delete(Tab), ok.

%%% ---------------------------------------------------------------- runner ---

%% Every adapter callback that touches tenant data runs here, bounded by the
%% deadline and the heap flag `spawn_opt' installed at creation. None of them
%% runs in the guardian, which has to stay responsive.
runner(Guardian, G) ->
    Adapter = G#g.adapter,
    Result =
        case call_back(Adapter, requirements, [G#g.request, G#g.artifact]) of
            {error, _} = E        -> E;
            {ok, {ok, Reqs}}      -> with_requirements(Guardian, G, Reqs);
            {ok, {error, WErr}}   -> {error, WErr};
            {ok, Other}           -> bad_shape(requirements, Other)
        end,
    Guardian ! {result, self(), Result},
    ok.

with_requirements(Guardian, G, Reqs) ->
    case policy(Reqs, G) of
        {error, _} = E ->
            E;
        ok ->
            case ask(Guardian, {mounts, self(), maps:get(mounts, Reqs)},
                     mounts_reply) of
                {error, _} = E -> E;
                {ok, Mounts}   -> with_mounts(Guardian, G, Mounts)
            end
    end.

with_mounts(Guardian, G, Mounts) ->
    Adapter = G#g.adapter,
    Env = env(Guardian, G, Mounts),
    case call_back(Adapter, prepare, [G#g.request, G#g.artifact, Env]) of
        {error, _} = E ->
            E;
        {ok, {error, WErr, AState}} ->
            %% A `prepare' failing on its own terms still passes back what it
            %% built, so the cleanup has an owner.
            _ = deliver(Guardian, Adapter, AState),
            {error, WErr};
        {ok, {ok, Spec, AState}} ->
            case deliver(Guardian, Adapter, AState) of
                {error, _} = E ->
                    %% A failed transfer aborts before the guest runs. What
                    %% cleans up afterwards is the guardian's mirror.
                    E;
                ok ->
                    execute_and_decode(G, Spec, AState)
            end;
        {ok, Other} ->
            bad_shape(prepare, Other)
    end.

execute_and_decode(G, Spec, AState) ->
    case check_spec(Spec) of
        {error, _} = E ->
            E;
        ok ->
            executed(G, AState, execute(G, Spec, AState))
    end.

executed(_G, _AState, {error, _} = WErr) ->
    WErr;
executed(G, AState, {Outcome, Values, Exit, Err}) ->
    Chans = G#g.channels,
    {Out, TOut} = channel_read(maps:get(stdout, Chans)),
    {Err2, TErr} = channel_read(maps:get(stderr, Chans)),
    {Res, TRes} = channel_read(maps:get(result, Chans)),
    ExecResult = #{outcome => Outcome, values => Values, exit => Exit,
                   error => Err,
                   channels => #{stdout => Out, stderr => Err2, result => Res},
                   truncated => #{stdout => TOut, stderr => TErr,
                                  result => TRes}},
    case call_back(G#g.adapter, decode, [ExecResult, AState]) of
        {error, _} = E          -> E;
        {ok, {ok, _} = Ok}      -> Ok;
        {ok, {error, _} = Bad}  -> Bad;
        {ok, Other}             -> bad_shape(decode, Other)
    end.

%% An empty `invoke' is an adapter bug rather than a legitimate shape, so it is
%% an error rather than a no-op.
check_spec(#{invoke := [_ | _]}) -> ok;
check_spec(#{invoke := []}) ->
    {error, wasm_worker_error:adapter(adapter_failure, ~"prepare/3 returned no work",
                                 #{callback => prepare})};
check_spec(_) ->
    {error, wasm_worker_error:adapter(adapter_failure, ~"prepare/3 returned no invoke",
                                 #{callback => prepare})}.

execute(G, Spec, AState) ->
    #{invoke := Invoke} = Spec,
    Limits = G#g.limits,
    case start_instance(G, Spec) of
        {error, #{class := _} = WErr} ->
            %% An adapter's own refusal, already in the worker's shape.
            {error, WErr};
        {error, E} ->
            {trapped, [], undefined, E};
        {ok, Inst} ->
            R = invoke_loop(Invoke, Inst, Limits, G#g.adapter, AState),
            ok = wasm:destroy(Inst),
            R
    end.

%% One instance per request either way. The image only changes where the
%% instance starts: a restore lands at the captured point, so the adapter's
%% `invoke' is the request's work and nothing else.
start_instance(#g{image = undefined, limits = Limits}, Spec) ->
    #{module := M, imports := ImportSet} = Spec,
    wasm:instantiate(M, maps:get(bindings, ImportSet), Limits);
start_instance(#g{image = Image} = G, #{imports := ImportSet}) ->
    %% The module is not passed: `restore/3' takes it from the image, so there
    %% is no argument left to lay one module's bytes over another's layout.
    %% The bindings **are** fresh, and the compatibility key is checked against
    %% them before anything is copied.
    Opts = maps:merge(G#g.limits, restore_opts(ImportSet)),
    case wasm:restore(Image, maps:get(bindings, ImportSet), Opts) of
        {error, E} -> {error, E};
        {ok, Inst} -> post_restore(Inst, Image, G)
    end.


%% The adapter's own check, run **in the runner on the request's remaining
%% deadline**, because it happens per request. Governing it by a capture budget
%% would bound request work with an initialisation one.
post_restore(Inst, Image, #g{snapshot_cap = #{post_restore := F}}) ->
    #{module := M, version := V} = wasm:snapshot_info(Image),
    case call_fun(F, [Inst, #{module => M, version => V}]) of
        {ok, ok} ->
            {ok, Inst};
        {ok, {error, WErr}} ->
            refused(Inst, WErr);
        {error, WErr} ->
            refused(Inst, WErr)
    end.

%% The instance goes and the adapter's own error is what comes back, rather
%% than a `trapped' with nothing in it that `decode/2' would have to guess at.
refused(Inst, WErr) ->
    ok = wasm:destroy(Inst),
    {error, WErr}.

%% An exception from an adapter fun normalises like every other callback: named
%% in the context, never a crash the runner carries somewhere else.
call_fun(F, Args) ->
    try {ok, apply(F, Args)}
    catch C:R -> {error, wasm_worker_error:adapter(
                           adapter_failure, ~"post_restore raised",
                           #{callback => post_restore, class => C,
                             reason => iolist_to_binary(
                                         io_lib:format(~"~p", [R]))})}
    end.


%% `classify/2' is called after **every** invocation, whether it returned or
%% trapped, and the kernel interprets none of them. A WASI exit arrives as a
%% trap carrying the status, so "stop on every trap" and "let one adapter
%% continue past that trap" cannot both hold: the adapter answers.
invoke_loop([{call, Name, Args} | Rest], Inst, Limits, Adapter, AState) ->
    IR = wasm:call(Inst, Name, Args, Limits),
    case call_back(Adapter, classify, [IR, AState]) of
        {error, E} ->
            {trapped, [], undefined, error_of(E)};
        {ok, {stop, Class}} ->
            stopped(Class, IR);
        {ok, continue} when Rest =:= [] ->
            %% Two defaults keep a naive adapter honest: `continue' on the last
            %% invocation finishes with what actually happened, so a forgetful
            %% adapter cannot silently discard a runtime error.
            last(IR);
        {ok, continue} ->
            invoke_loop(Rest, Inst, Limits, Adapter, AState);
        {ok, _Other} ->
            %% An adapter that does not understand a result gets the safe
            %% answer rather than the ignorant one.
            stopped(trapped, IR)
    end.

stopped(returned, {ok, Vs})        -> {returned, Vs, undefined, undefined};
stopped(returned, {error, E})      -> {returned, [], undefined, E};
stopped(trapped, {ok, Vs})         -> {trapped, Vs, undefined, undefined};
stopped(trapped, {error, E})       -> {trapped, [], undefined, E};
stopped({exited, C}, {ok, Vs})     -> {exited, Vs, C, undefined};
stopped({exited, C}, {error, E})   -> {exited, [], C, E}.

last({ok, Vs})    -> {returned, Vs, undefined, undefined};
last({error, E})  -> {trapped, [], undefined, E}.

error_of(#{ctx := #{error := E}}) -> E;
error_of(_) -> undefined.

%%% ----------------------------------------------------------------- policy ---

%% The clock is not restarted here. Re-deriving the deadline would make
%% requirements processing free, which is exactly the work an adversarial
%% request would inflate.
policy(Reqs, G) ->
    Limits = G#g.limits,
    Left = remaining(G#g.deadline),
    Checks =
        [{min_timeout, maps:get(min_timeout, Reqs, 0), Left,
          ~"not enough time left for this request"},
         {min_memory_pages, maps:get(min_memory_pages, Reqs, 0),
          maps:get(max_memory_pages, Limits, infinity),
          ~"more memory than this worker allows"},
         {request_bytes, maps:get(request_bytes, Reqs, 0),
          maps:get(max_request_bytes, Limits), ~"request is too large"},
         {staged_bytes, maps:get(staged_bytes, Reqs, 0),
          maps:get(max_staged_bytes, Limits), ~"staging is too large"},
         {staged_files, maps:get(staged_files, Reqs, 0),
          maps:get(max_staged_files, Limits), ~"too many staged files"}],
    case [{K, Need, Have, Msg} || {K, Need, Have, Msg} <- Checks,
                                  over(Need, Have)] of
        [{K, Need, Have, Msg} | _] ->
            {error, wasm_worker_error:worker(insufficient_limit, Msg,
                                        #{need => K, wanted => Need,
                                          available => Have})};
        [] ->
            write_mounts_allowed(Reqs, G)
    end.

over(_Need, infinity) -> false;
over(Need, Have) -> Need > Have.

%% A writable mount is outside the untrusted contract and is refused. Bounding
%% what a *guest* writes once the preopen exists needs byte and inode quotas
%% inside `wasi_fs', which do not exist, and `max_staged_bytes' bounds the
%% adapter rather than the tenant. Saying "not yet" is better than a quota that
%% sounds like a bound and is not.
write_mounts_allowed(_Reqs, #g{trusted = true}) -> ok;
write_mounts_allowed(Reqs, _G) ->
    Mounts = maps:get(mounts, Reqs, #{}),
    case [N || N := #{mode := write} <- Mounts] of
        []  -> ok;
        Bad -> {error, wasm_worker_error:worker(
                         insufficient_limit,
                         ~"a writable mount needs a trusted worker",
                         #{mounts => Bad})}
    end.

%%% -------------------------------------------------------------------- env ---

env(Guardian, G, Mounts) ->
    Self = self(),
    #{mounts => Mounts,
      channels => G#g.channels,
      deadline => G#g.deadline,
      limits => G#g.limits,
      cleanup =>
          #{register =>
                fun(Action) ->
                    ask_raw(Guardian, {register, Self, Action}, register_reply)
                end,
            withdraw =>
                fun(Token) ->
                    ask_raw(Guardian, {withdraw, Self, Token}, withdraw_reply)
                end},
      stage =>
          fun(Mount, Path, Data) ->
              ask_raw(Guardian, {stage, Self, Mount, Path, Data}, stage_reply)
          end}.

deliver(Guardian, Mod, AState) ->
    ask_raw(Guardian, {deliver_state, self(), Mod, AState}, deliver_state_reply).

ask(Guardian, Msg, Tag) -> ask_raw(Guardian, Msg, Tag).

%% The guardian is linked to this process, so it cannot silently vanish: if it
%% dies this process dies with it. No timeout is needed and adding one would
%% only invent a second deadline beside the one the guardian already owns.
ask_raw(Guardian, Msg, Tag) ->
    Guardian ! Msg,
    receive {Tag, Reply} -> Reply end.

%%% ------------------------------------------------------------- callbacks ---

%% An exception from any callback normalises to `adapter_failure' with the
%% callback named in the context, so an adapter that raises is a value like
%% everything else.
call_back(Mod, Fun, Args) ->
    try {ok, apply(Mod, Fun, Args)}
    catch
        Class:Reason:Stack ->
            {error, wasm_worker_error:adapter(
                      adapter_failure, ~"adapter callback raised",
                      #{callback => Fun, class => Class, reason => Reason,
                        stack => Stack})}
    end.

bad_shape(Callback, Got) ->
    {error, wasm_worker_error:adapter(
              adapter_failure, ~"adapter callback answered with a bad shape",
              #{callback => Callback, got => shape_of(Got)})}.

shape_of(T) when is_tuple(T) -> {tuple, tuple_size(T)};
shape_of(T) when is_atom(T) -> T;
shape_of(_) -> other.
