-module(worker_reaper).
-moduledoc """
Who cleans up after a request when the process that owned it is gone.

Start one per node from your own supervision tree, naming the roots the workers
scratch under, and `script_worker` refuses to accept a request without it:

```erlang
{ok, _} = worker_reaper:start_link(#{scratch => "/var/tmp/workers"}),
{ok, W} = script_worker:start_link(my_adapter, #{root => scratch}).
```

## Why a process and not a table

A worker's guardian owns the request's directories and its registered cleanup
actions, and the guardian can die. An ETS table with the worker as `heir` is
the wrong shape twice over: `heir` fires when the *owner* dies, so a
worker-owned table survives exactly the failure it is not needed for and does
nothing about the guardian's. And deferring the sweep to the worker's next
request leaks for as long as that worker is idle, which for a lightly used
tenant has no bound.

So the reaper outlives both. It holds the registry, it monitors every guardian,
and on a `DOWN` with work outstanding it **spawns a job** and goes straight
back to its loop. It never runs a cleanup callback itself: it is a singleton,
and an adapter whose `cleanup/1` hangs would otherwise stop registration and
recovery for every worker on the node.

## Surviving its own death

The registry is memory, so it also writes a journal, one directory per root,
one record per live request. Three properties of that journal are load-bearing
and each is the smallest honest option rather than the strongest-sounding one:

| | what it is | what it is not |
| --- | --- | --- |
| durability | BEAM-crash: the record is written and renamed **before** the reservation is acknowledged | host-crash durability, which would need the journal directory synced after every change |
| what is durable | ownership and recovery intent | the cleanup lifecycle, which would put a filesystem write on every state transition |
| identity | a minted binary request id | an Erlang `reference()` written down |

The record is a header plus operations:

```
v1 <incarnation-hex> <generation> <guardian-pid> <request-id-hex>
remove_tree <root-id> <escaped-relative-path>
```

**It holds allowlisted operations, never code.** A manifest of `{M, F, A}` is a
file naming host functions to call, sitting one directory-permission mistake
away from a guest. And it is deliberately not `binary_to_term/1`: that
materialises atoms *before* any structural check can reject the record, which
is a node-wide unreclaimable leak, and the file sits exactly where an attacker
who got that far would plant one. Every field here is a number, a hex string, a
pid literal or a verb from a fixed table, so decoding yields an atom that
already existed or fails.

## Recovery asks before it acts

A replacement reaper that simply replayed what it found would delete the
directories out from under a request that is still running. So each record
names its owner, and a restart sorts what it finds:

| | meaning | action |
| --- | --- | --- |
| incarnation differs | the node restarted, no pid means anything | orphan, replay |
| matches, pid dead | the guardian died with the reaper | orphan, replay |
| matches, pid alive, handshake confirms | still running | adopt, replay nothing |
| matches, pid alive, handshake denies | a reused pid | orphan, replay |
| matches, pid alive, no answer | unknown | **pending**: monitor, retry, never replay |

**A timeout is not a denial.** A guardian that is descheduled, mid-GC or behind
a full mailbox is a live guardian that happens to be slow. Only an explicit
denial or a `DOWN` proves orphaning; silence stays unknown, and an entry that
is still alive and silent when the retries run out goes to `held` rather than
being replayed. Leaking a directory is recoverable and deleting a running
request's mounts is not, so ambiguity always resolves towards doing nothing.

## What survives what

| | guardian dies, reaper lives | reaper dies, guardian lives | both die |
| --- | --- | --- | --- |
| `remove_tree` | reaper's registry | guardian's mirror | **journal** |
| a `fun` action | reaper's registry | guardian's mirror | lost |
| `Adapter:cleanup/1` | reaper's registry | guardian's mirror | lost |

An adapter holding something it cannot afford to leak across a reaper crash
expresses it as a `recover_op()`. Anything else is a best-effort release that a
supervised reaper will almost always perform.
""".

-behaviour(gen_server).

-export([start_link/1, start_link/2, stop/0, alive/0]).
-export([setting_keys/0]).
-export([reserve/4, register/2, withdraw/2, transfer/3, finish/1]).
-export([authorise/2, generation/0, incarnation/0, stats/0, requests/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).
-define(INCARNATION_KEY, {?MODULE, incarnation}).
-define(GENERATION_KEY, {?MODULE, generation}).
-define(JOURNAL_DIR, ".journal").
-define(QUARANTINE_DIR, "quarantine").
-define(RECORD_VERSION, "v1").

%% Defaults. Every one is a **named setting with a default**, overridable in
%% the options map, because "a small fixed count" is not something a case can
%% assert against and an unbounded one is the node-wide exhaustion a singleton
%% was supposed to avoid. A conformance case that had to create 264 live
%% requests to see admission refuse one would not be written.
-define(MAX_CLEANUP_JOBS, 8).
-define(CLEANUP_QUEUE_LEN, 256).
-define(CLEANUP_RETRIES, 3).
-define(CLEANUP_BACKOFF, [1_000, 4_000, 16_000]).
-define(CLEANUP_TIMEOUT, 30_000).
-define(CLEANUP_JOB_DEADLINE, 120_000).
-define(MAX_CLEANUP_ACTIONS, 64).
-define(HANDSHAKE_TIMEOUT, 1_000).
-define(HANDSHAKE_RETRIES, 3).

-doc "Names a configured scratch root. A closed set, supplied at start.".
-type root_id() :: atom().
-doc "The kernel's own id for a request. Minted at `submit`, never a term.".
-type request_id() :: binary().
-doc "What a registered cleanup action is identified by.".
-type token() :: pos_integer().

-doc """
An operation a replacement reaper can replay from disk.

Deliberately a closed set: this is what the journal is allowed to contain, and
the reaper is the only thing that understands it.
""".
-type recover_op() :: {remove_tree, root_id(), binary()}
                    | {delete_file, root_id(), binary()}.

-doc """
What `register/2` accepts.

A fun is in memory and dies with the reaper. A `recover_op()` is written down
and survives it. They are different promises and the caller chooses which.
""".
-type action() :: fun(() -> ok) | recover_op().

-export_type([root_id/0, request_id/0, token/0, recover_op/0, action/0]).

%% A reservation's monitor is cleared the moment its `DOWN' is processed, so
%% anything dropping one afterwards has to cope with its being gone.
%% `erlang:demonitor(undefined, ...)' is a `badarg', and since the reaper is a
%% singleton that meant one late `finish/1' took cleanup down for every worker
%% on the node.
drop_monitor(undefined) -> ok;
drop_monitor(Mon) when is_reference(Mon) -> _ = erlang:demonitor(Mon, [flush]), ok.

%% Per request. `state' is the whole lifecycle and it lives only here: putting
%% it in the journal would mean an atomic rewrite plus a sync at every
%% transition, so a restart *reconstructs* it from what it can observe instead.
-record(req, {id             :: request_id(),
              state          :: live | pending | held | queued | running,
              guardian       :: pid(),
              mon            :: undefined | reference(),
              root           :: root_id(),
              relpath        :: binary(),
              ops     = []   :: [recover_op()],
              actions = []   :: [{token(), action(), owned | transferred}],
              next_token = 1 :: pos_integer(),
              cleanup        :: undefined | {module(), term()},
              attempts   = 0 :: non_neg_integer(),
              tries      = 0 :: non_neg_integer(),
              gen            :: pos_integer()}).

-record(st, {roots      :: #{root_id() => file:filename_all()},
             reqs  = #{} :: #{request_id() => #req{}},
             queue = []  :: [request_id()],
             jobs  = #{} :: #{pid() => {request_id(), reference()}},
             quarantined = 0 :: non_neg_integer(),
             gen        :: pos_integer(),
             incarnation :: binary(),
             opts       :: map()}).

%%% ----------------------------------------------------------------- api ---

-doc """
Start the reaper, sweeping and reconstructing from whatever it finds.

`Roots` maps a root id to a directory. A worker names one of those ids, and
every path in the journal is relative to it, so a restarted reaper knows where
to sweep without having to discover it. A record naming a root this reaper does
not have configured is left alone and logged, never guessed at.
""".
-spec start_link(#{root_id() => file:filename_all()}) ->
          {ok, pid()} | {error, term()}.
start_link(Roots) -> start_link(Roots, #{}).

-spec start_link(#{root_id() => file:filename_all()}, map()) ->
          {ok, pid()} | {error, term()}.
start_link(Roots, Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, {Roots, Opts}, []).

-spec stop() -> ok.
stop() -> gen_server:stop(?SERVER).

-doc """
Whether a reaper is running.

`script_worker` checks this at every `submit`, not only when it starts: the
reaper can die at any point afterwards, and a request whose cleanup would have
no owner should not begin.
""".
-spec alive() -> boolean().
alive() -> whereis(?SERVER) =/= undefined.

-doc """
Claim capacity and durably record the intent to clean up, before anything exists.

Called by the guardian **before** it creates any directory. The record naming
`RelPath` is written and renamed before this returns, so a crash immediately
afterwards leaves a directory a replacement reaper can find. A `remove_tree`
naming a path that was never created is a no-op, which is what idempotence
already required, so the ordering costs nothing and closes the window
completely.

Answers with the **absolute directory** the request owns, so the guardian does
not have to be told separately where its root is and cannot disagree with the
reaper about it.

Returns `{error, cleanup_saturated}` when `live + pending + held + queued +
running` is at capacity. A host under load gets a refusal it can retry rather
than a leak it cannot see.
""".
-spec reserve(request_id(), pid(), root_id(), binary()) ->
          {ok, file:filename_all()} | {error, worker_error:worker_error()}.
reserve(Id, Guardian, Root, RelPath) ->
    call({reserve, Id, Guardian, Root, RelPath}).

-doc """
Register a cleanup action, LIFO, and say what happened if it could not be.

Three outcomes, and the caller can tell them apart:

| | meaning |
| --- | --- |
| `{ok, Token}` | recorded; the registry owns it |
| `{error, E, released}` | not recorded, but the action **ran to completion** |
| `{error, E, cleanup_failed}` | not recorded, and the action hung or raised |

The middle one exists because a `register` that returns an error having done
neither leaks exactly the resource the caller allocated one line earlier. The
last one is the honest case: nobody owns that resource now. It cannot be
journaled either, because the reaper is the journal's only writer and this
state is reached precisely when the reaper is unreachable, so it is logged and
counted and that is all.
""".
-spec register(request_id(), action()) ->
          {ok, token()} | {error, worker_error:worker_error(),
                           released | cleanup_failed}.
register(Id, Action) ->
    try gen_server:call(?SERVER, {register, Id, Action}, infinity)
    catch exit:_ -> unreachable(Action)
    end.

-doc "Drop a registered action, for a caller that released the thing itself.".
-spec withdraw(request_id(), token()) -> ok | {error, worker_error:worker_error()}.
withdraw(Id, Token) -> call({withdraw, Id, Token}).

-doc """
Hand the adapter's state to the registry. Kernel-only.

Not exposed to adapters, and that is an ownership fix rather than a
simplification. If an adapter could transfer and its runner then died before
delivering an `adapter_state()`, the transferred actions would run only "if a
state was delivered" and none ever was, so nothing would own them. The kernel
transfers once, after the guardian holds the complete state, which makes
"transferred" and "a state was delivered" the same event.
""".
-spec transfer(request_id(), module(), term()) ->
          ok | {error, worker_error:worker_error()}.
transfer(Id, Mod, AdapterState) -> call({transfer, Id, Mod, AdapterState}).

-doc "Drop a request whose guardian completed cleanly and cleaned up itself.".
-spec finish(request_id()) -> ok.
finish(Id) -> cast({finish, Id}).

-doc """
Ask whether a job spawned under `Gen` may still act on `Id`.

Links are not ordering: a supervisor can see the reaper's `DOWN` and start a
replacement before the old jobs have processed their parent's exit signal. So
acting on a record requires authorisation from the *currently registered*
reaper, which checks a generation it holds in memory and answers serially. A
stale job reaches the replacement, whose generation no longer matches, and is
refused.

This narrows the window and does not close it: a job authorised just before its
reaper died can still be descheduled and do its filesystem work afterwards.
That is why every action is required to be concurrent-safe as well as
idempotent.
""".
-spec authorise(request_id(), pos_integer()) -> ok | {error, stale}.
authorise(Id, Gen) ->
    try gen_server:call(?SERVER, {authorise, Id, Gen}, ?CLEANUP_TIMEOUT)
    catch exit:_ -> {error, stale}
    end.

-doc "This reaper's generation. Incremented by every start.".
-spec generation() -> pos_integer().
generation() -> persistent_term:get(?GENERATION_KEY, 0).

-doc """
The node's incarnation, which outlives a reaper restart and not a node restart.

It has to be exactly that lifetime, because it is what decides whether a pid in
a record means anything. Generated per reaper start, a supervisor restart would
make every live request look orphaned and get its directories deleted. So it is
node-owned state in `persistent_term`, created by whichever reaper finds it
absent and never rewritten.
""".
-spec incarnation() -> binary().
incarnation() -> persistent_term:get(?INCARNATION_KEY, <<>>).

-doc "Counts per state, for the conformance kit and for an operator.".
-spec stats() -> map() | {error, worker_error:worker_error()}.
stats() -> call(stats).

-doc """
Every reservation this reaper holds, with the process that owns it.

Operator-facing rather than test-only: a reservation that ends in `held` stays
there until a late answer or a `DOWN`, deliberately, and the way to resolve one
is to look at what is holding it and kill that guardian if it really is stuck.
`delivered` says whether the adapter's state has reached the registry yet, and
so whether `cleanup/1` has an owner.
""".
-spec requests() -> [#{id := request_id(), state := atom(), guardian := pid(),
                       delivered := boolean()}]
                  | {error, worker_error:worker_error()}.
requests() -> call(requests).

call(Msg) ->
    try gen_server:call(?SERVER, Msg, infinity)
    catch exit:{noproc, _} -> {error, no_reaper()};
          exit:_           -> {error, no_reaper()}
    end.

cast(Msg) ->
    try gen_server:cast(?SERVER, Msg) catch _:_ -> ok end,
    ok.

no_reaper() ->
    worker_error:worker(no_reaper, ~"no cleanup owner is running", #{}).

%% The registry is unreachable, so perform what could not be recorded. In a
%% bounded child, never inline: a hanging action inline would wedge the caller
%% past its own deadline and defeat cancellation. Killing that child does not
%% prove the resource was released, so the two outcomes are told apart.
unreachable(F) when is_function(F, 0) ->
    case run_bounded(fun() -> _ = F(), ok end, ?CLEANUP_TIMEOUT) of
        ok ->
            {error, no_reaper(), released};
        {error, Why} ->
            ?LOG_ERROR("worker_reaper: unowned resource, action failed: ~p",
                       [Why]),
            {error, no_reaper(), cleanup_failed}
    end;
unreachable(Op) ->
    %% A durable op is a promise the journal keeps, and the journal has exactly
    %% one writer: the reaper that is not there. There is no honest way to
    %% record this and no second writer to invent, so it is the unowned case.
    ?LOG_ERROR("worker_reaper: unowned durable op, not recorded: ~p", [Op]),
    {error, no_reaper(), cleanup_failed}.

%% `cleanup_timeout' bounds **one callback** and `cleanup_job_deadline' bounds
%% **the whole job**. They are different bounds, and a job with eight actions
%% and a `cleanup/1' could otherwise spend nine callback timeouts.
setting(#st{opts = O}, K) -> maps:get(K, O, default(K));
setting(O, K) when is_map(O) -> maps:get(K, O, default(K)).

default(max_cleanup_jobs)     -> ?MAX_CLEANUP_JOBS;
default(cleanup_queue_len)    -> ?CLEANUP_QUEUE_LEN;
default(cleanup_retries)      -> ?CLEANUP_RETRIES;
default(cleanup_backoff)      -> ?CLEANUP_BACKOFF;
default(cleanup_timeout)      -> ?CLEANUP_TIMEOUT;
default(cleanup_job_deadline) -> ?CLEANUP_JOB_DEADLINE;
default(max_cleanup_actions)  -> ?MAX_CLEANUP_ACTIONS.

setting_keys() ->
    [max_cleanup_jobs, cleanup_queue_len, cleanup_retries, cleanup_backoff,
     cleanup_timeout, cleanup_job_deadline, max_cleanup_actions].

%%% -------------------------------------------------------------- server ---

init({Roots, Opts}) ->
    process_flag(trap_exit, true),
    Incarnation = incarnation_of_node(),
    Gen = next_generation(),
    ok = ensure_journals(Roots),
    %% Normalised once, so every read is a `map_get' on a complete map rather
    %% than a default lookup in a guard, which cannot call a function.
    Settings = maps:from_list([{K, setting(Opts, K)} || K <- setting_keys()]),
    St = #st{roots = Roots, gen = Gen, incarnation = Incarnation,
             opts = Settings},
    {ok, sweep(St)}.

handle_call({reserve, Id, Guardian, Root, RelPath}, _From, St) ->
    case maps:is_key(Root, St#st.roots) of
        false ->
            {reply, {error, worker_error:worker(
                              insufficient_limit, ~"unknown root",
                              #{root => Root})}, St};
        true ->
            case has_capacity(St) of
                false ->
                    {reply, {error, worker_error:worker(
                                      cleanup_saturated,
                                      ~"no cleanup capacity", #{})}, St};
                true ->
                    Req = #req{id = Id, state = live, guardian = Guardian,
                               mon = erlang:monitor(process, Guardian),
                               root = Root, relpath = RelPath,
                               ops = [{remove_tree, Root, RelPath}],
                               gen = St#st.gen},
                    case write_record(St, Req) of
                        ok ->
                            Dir = filename:join(maps:get(Root, St#st.roots),
                                                RelPath),
                            {reply, {ok, Dir}, put_req(Req, St)};
                        {error, E} ->
                            erlang:demonitor(Req#req.mon, [flush]),
                            {reply, {error, E}, St}
                    end
            end
    end;

handle_call({register, Id, Action}, _From, St) ->
    case maps:find(Id, St#st.reqs) of
        error ->
            {reply, unreachable(Action), St};
        {ok, #req{actions = As}}
          when length(As) >= map_get(max_cleanup_actions, St#st.opts) ->
            %% The list is adapter-controlled: without a ceiling an adapter in
            %% a loop registers until the reaper's memory is the bound.
            E = worker_error:worker(cleanup_saturated,
                                    ~"too many cleanup actions",
                                    #{max => setting(St, max_cleanup_actions)}),
            {reply, {error, E, cleanup_failed}, St};
        {ok, Req} ->
            do_register(Req, Action, St)
    end;

handle_call({withdraw, Id, Token}, _From, St) ->
    case maps:find(Id, St#st.reqs) of
        error ->
            {reply, ok, St};
        {ok, #req{actions = As} = Req} ->
            Kept = [A || {T, _, _} = A <- As, T =/= Token],
            Req1 = Req#req{actions = Kept},
            %% Only a durable op changes what is on disk. Withdrawing a fun
            %% costs nothing, which is why the common case writes nothing.
            case durable(As, Token) of
                false -> {reply, ok, put_req(Req1, St)};
                true ->
                    Req2 = Req1#req{ops = ops_of(Req1)},
                    case write_record(St, Req2) of
                        ok         -> {reply, ok, put_req(Req2, St)};
                        {error, E} -> {reply, {error, E}, St}
                    end
            end
    end;

handle_call({transfer, Id, Mod, AdapterState}, _From, St) ->
    case maps:find(Id, St#st.reqs) of
        error ->
            {reply, {error, no_reaper()}, St};
        {ok, #req{actions = As} = Req} ->
            %% Marks, never withdraws. A `cleanup/1' that raises would
            %% otherwise leak precisely the resources whose actions were just
            %% removed, so success is what drops them.
            Marked = [{T, A, transferred} || {T, A, _} <- As],
            {reply, ok, put_req(Req#req{actions = Marked,
                                        cleanup = {Mod, AdapterState}}, St)}
    end;

handle_call({authorise, Id, Gen}, _From, #st{gen = Gen} = St) ->
    {reply, case maps:is_key(Id, St#st.reqs) of
                true  -> ok;
                false -> {error, stale}
            end, St};
handle_call({authorise, _Id, _Gen}, _From, St) ->
    {reply, {error, stale}, St};

handle_call(requests, _From, St) ->
    %% `delivered' says whether an `adapter_state()' has reached the registry,
    %% which is the same thing as saying whether `cleanup/1' has an owner.
    {reply, [#{id => R#req.id, state => R#req.state, guardian => R#req.guardian,
               delivered => R#req.cleanup =/= undefined}
             || R <- maps:values(St#st.reqs)], St};

handle_call(stats, _From, St) ->
    Counts = lists:foldl(fun(#req{state = S}, Acc) ->
                             maps:update_with(S, fun(N) -> N + 1 end, 1, Acc)
                         end, #{}, maps:values(St#st.reqs)),
    {reply, Counts#{quarantined => St#st.quarantined,
                    capacity => capacity(St),
                    generation => St#st.gen}, St};

handle_call(_Msg, _From, St) ->
    {reply, {error, worker_error:worker(crashed, ~"bad call", #{})}, St}.

handle_cast({finish, Id}, St) ->
    %% The guardian cleaned up itself and says so. Drop the record last, after
    %% everything it named is gone.
    case maps:find(Id, St#st.reqs) of
        error -> {noreply, St};
        {ok, Req} ->
            ok = drop_monitor(Req#req.mon),
            ok = remove_record(St, Req),
            {noreply, St#st{reqs = maps:remove(Id, St#st.reqs)}}
    end;
handle_cast(_, St) ->
    {noreply, St}.

handle_info({'DOWN', Mon, process, _Pid, _Why}, St) ->
    case lists:keyfind(Mon, #req.mon, maps:values(St#st.reqs)) of
        false -> {noreply, job_down(Mon, St)};
        Req   -> {noreply, schedule(Req#req{mon = undefined, state = queued}, St)}
    end;

handle_info({handshake_reply, Id, Answer}, St) ->
    {noreply, handshake_reply(Id, Answer, St)};

handle_info({retry_handshake, Id}, St) ->
    {noreply, retry_handshake(Id, St)};

handle_info({retry_cleanup, Id}, St) ->
    case maps:find(Id, St#st.reqs) of
        {ok, Req} -> {noreply, schedule(Req#req{state = queued}, St)};
        error     -> {noreply, St}
    end;

handle_info({'EXIT', _Pid, _Reason}, St) ->
    %% Jobs are linked as well as monitored, so a job dying arrives twice. The
    %% `DOWN' carries the reason and is what this acts on; the `EXIT' is what
    %% would have killed an untrapping parent, and is ignored here.
    {noreply, St};

handle_info(_, St) ->
    {noreply, St}.

terminate(_Why, _St) -> ok.

%%% ---------------------------------------------------------- registering ---

do_register(#req{next_token = T, actions = As} = Req, Action, St) ->
    Req1 = Req#req{actions = [{T, Action, owned} | As], next_token = T + 1},
    case is_durable(Action) of
        false ->
            {reply, {ok, T}, put_req(Req1, St)};
        true ->
            %% Synchronous with respect to the write and the rename:
            %% acknowledging before the rename completes is exactly the window
            %% in which an acknowledged op is lost.
            Req2 = Req1#req{ops = ops_of(Req1)},
            case write_record(St, Req2) of
                ok ->
                    {reply, {ok, T}, put_req(Req2, St)};
                {error, E} ->
                    {reply, {error, E, cleanup_failed}, St}
            end
    end.

is_durable({remove_tree, _, _}) -> true;
is_durable({delete_file, _, _}) -> true;
is_durable(F) when is_function(F, 0) -> false.

durable(Actions, Token) ->
    case lists:keyfind(Token, 1, Actions) of
        {_, A, _} -> is_durable(A);
        false     -> false
    end.

%% The reservation's own op comes first and is never dropped: it covers the
%% request directory whether or not anything was staged into it.
ops_of(#req{root = Root, relpath = Rel, actions = As}) ->
    [{remove_tree, Root, Rel} |
     [A || {_, A, _} <- lists:reverse(As), is_durable(A)]].

put_req(#req{id = Id} = Req, St) ->
    St#st{reqs = maps:put(Id, Req, St#st.reqs)}.

%%% ------------------------------------------------------------- capacity ---

%% Five states hold capacity, not three. A reservation is a claim on *future*
%% cleanup, so a hundred long-running requests would otherwise overbook it and
%% discover the shortfall only as they finished.
capacity(St) -> maps:size(St#st.reqs).

has_capacity(St) ->
    capacity(St) < setting(St, max_cleanup_jobs) + setting(St, cleanup_queue_len).

%%% ------------------------------------------------------------ scheduling ---

schedule(#req{id = Id} = Req, St) ->
    St1 = put_req(Req, St),
    pump(St1#st{queue = St1#st.queue ++ [Id]}).

%% Queued work is never discarded: having been admitted it has capacity by
%% construction, since the queue length is what admission counted against.
pump(#st{queue = []} = St) -> St;
pump(#st{jobs = Jobs} = St)
  when map_size(Jobs) >= map_get(max_cleanup_jobs, St#st.opts) -> St;
pump(#st{queue = [Id | Rest]} = St) ->
    case maps:find(Id, St#st.reqs) of
        error ->
            %% Finished and dropped while it sat in the queue. A request only
            %% reaches the queue when its guardian is dead or has denied
            %% ownership, so there is no path back to `live' from here and no
            %% state to re-check: the entry is either still due or gone.
            pump(St#st{queue = Rest});
        {ok, Req} ->
            {Pid, Mon} = start_job(Req, St),
            pump(St#st{queue = Rest,
                       jobs = maps:put(Pid, {Id, Mon}, St#st.jobs),
                       reqs = maps:put(Id, Req#req{state = running},
                                       St#st.reqs)})
    end.

start_job(Req, St) ->
    Roots = St#st.roots,
    Gen = St#st.gen,
    Opts = St#st.opts,
    spawn_opt(fun() -> job(Req, Roots, Gen, Opts) end, [link, monitor]).

job_down(Mon, St) ->
    case [P || {P, {_, M}} <- maps:to_list(St#st.jobs), M =:= Mon] of
        [] -> St;
        [Pid] ->
            {Id, _} = maps:get(Pid, St#st.jobs),
            St1 = St#st{jobs = maps:remove(Pid, St#st.jobs)},
            pump(job_finished(Id, St1))
    end.

%% A job reports by exiting. It has already done what it could; what is left is
%% deciding whether to retry, quarantine, or drop the record.
job_finished(Id, St) ->
    case maps:find(Id, St#st.reqs) of
        error -> St;
        {ok, #req{attempts = N} = Req}
          when N >= map_get(cleanup_retries, St#st.opts) ->
            quarantine(Req, St);
        {ok, #req{attempts = N} = Req} ->
            case job_succeeded(Req, St) of
                true ->
                    ok = remove_record(St, Req),
                    St#st{reqs = maps:remove(Id, St#st.reqs)};
                false ->
                    Offs = setting(St, cleanup_backoff),
                    Backoff = lists:nth(min(N + 1, length(Offs)), Offs),
                    _ = erlang:send_after(Backoff, self(), {retry_cleanup, Id}),
                    put_req(Req#req{attempts = N + 1, state = queued}, St)
            end
    end.

%% What a job leaves behind is the evidence. Every op is idempotent, so
%% "succeeded" is "nothing it named is still there" rather than a message the
%% job had to survive long enough to send.
job_succeeded(#req{ops = Ops}, St) ->
    lists:all(fun(Op) -> not exists(Op, St#st.roots) end, Ops).

%% Quarantine has exactly one cause: the retries are spent against a callback
%% that will not finish. An unresolved handshake is `held', not this.
quarantine(#req{id = Id} = Req, St) ->
    ?LOG_ERROR("worker_reaper: quarantining ~ts after ~p attempts",
               [Id, Req#req.attempts]),
    _ = quarantine_record(St, Req),
    St#st{reqs = maps:remove(Id, St#st.reqs),
          quarantined = St#st.quarantined + 1}.

%%% ------------------------------------------------------------------ job ---

%% The job orchestrates and runs nothing itself, which the ordering makes
%% mandatory rather than tidy: if `cleanup/1' ran here and hung, killing the
%% job at its deadline would kill it before the fallback actions it exists to
%% fall back to. So each callback gets its own monitored child and its own
%% deadline, and the job carries on to the next step after killing one.
job(#req{id = Id} = Req, Roots, Gen, Opts) ->
    process_flag(trap_exit, true),
    case worker_reaper:authorise(Id, Gen) of
        {error, stale} ->
            ok;
        ok ->
            Deadline = erlang:monotonic_time(millisecond)
                + setting(Opts, cleanup_job_deadline),
            Failed = run_cleanup(Req, Deadline, Opts),
            run_actions(Req, Failed, Deadline, Opts),
            remove_dirs(Req, Roots),
            ok
    end.

%% `cleanup/1' first, then actions, then directories. That is the reverse of
%% the obvious order and the only one consistent with why transferred actions
%% are retained: a transferred action covers a resource `cleanup/1' now owns,
%% so running actions first would release it behind its back.
run_cleanup(#req{cleanup = undefined}, _Deadline, _Opts) ->
    failed;
run_cleanup(#req{cleanup = {Mod, State}}, Deadline, Opts) ->
    case run_bounded(fun() -> Mod:cleanup(State) end,
                     callback_budget(Deadline, Opts)) of
        ok -> ok;
        {error, Why} ->
            ?LOG_WARNING("worker_reaper: ~p:cleanup/1 failed: ~p", [Mod, Why]),
            failed
    end.

%% Untransferred actions always run. Transferred ones run only when `cleanup/1'
%% failed or timed out, since those are the ones it took ownership of. That
%% split is the whole reason both exist.
run_actions(#req{actions = As}, CleanupResult, Deadline, Opts) ->
    Run = [A || {_T, A, Own} <- As,
                is_function(A, 0),
                Own =:= owned orelse CleanupResult =:= failed],
    lists:foreach(fun(A) -> run_action(A, Deadline, Opts) end, Run).

%% An action that raises stops nothing. Cleanup that can be aborted by one bad
%% release is not cleanup.
run_action(Action, Deadline, Opts) ->
    case run_bounded(fun() -> _ = Action(), ok end,
                     callback_budget(Deadline, Opts)) of
        ok -> ok;
        {error, Why} ->
            ?LOG_WARNING("worker_reaper: action ~p failed: ~p", [Action, Why]),
            ok
    end.

remove_dirs(#req{ops = Ops}, Roots) ->
    lists:foreach(fun(Op) -> apply_op(Op, Roots) end, Ops).

%%% ------------------------------------------------------------- bounding ---

%% Each callback in its own monitored child with its own deadline. The parent
%% kills a child that overruns, records it, and carries on: one hanging action
%% must not block the rest of the LIFO chain.
run_bounded(_F, Timeout) when Timeout =< 0 ->
    {error, deadline_spent};
run_bounded(F, Timeout) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, Mon} = spawn_opt(fun() -> Parent ! {Ref, guard(F)} end, [monitor]),
    receive
        {Ref, ok} ->
            erlang:demonitor(Mon, [flush]),
            ok;
        {Ref, {C, R}} ->
            erlang:demonitor(Mon, [flush]),
            {error, {C, R}};
        {'DOWN', Mon, process, Pid, Reason} ->
            {error, Reason}
    after Timeout ->
        %% Killing the child does not prove the resource was released, which is
        %% why the caller is told `timeout' rather than a failure it could
        %% mistake for one.
        exit(Pid, kill),
        receive {'DOWN', Mon, process, Pid, _} -> ok after 1_000 -> ok end,
        {error, timeout}
    end.

guard(F) ->
    try F(), ok
    catch C:R -> {C, R}
    end.

left(Deadline) -> Deadline - erlang:monotonic_time(millisecond).

%% One callback gets `cleanup_timeout', or whatever is left of the job's own
%% budget if that is less. Neither bound can be spent by the other.
callback_budget(Deadline, Opts) ->
    min(setting(Opts, cleanup_timeout), left(Deadline)).

%%% ------------------------------------------------------------- handshake ---

%% Pids are reused within one incarnation, so liveness alone is not enough: a
%% record naming a dead guardian whose pid now belongs to something else would
%% be adopted and never cleaned.
ask(#req{id = Id, guardian = Pid}) ->
    Self = self(),
    Pid ! {worker_reaper_handshake, Self, Id},
    _ = erlang:send_after(?HANDSHAKE_TIMEOUT, Self, {retry_handshake, Id}),
    ok.

handshake_reply(Id, Answer, St) ->
    case maps:find(Id, St#st.reqs) of
        error -> St;
        {ok, Req} when Answer =:= yes ->
            %% Both recovery states return to `live' directly: the question
            %% `held' was waiting on has now been answered.
            put_req(Req#req{state = live}, St);
        {ok, Req} ->
            schedule(Req#req{state = queued}, St)
    end.

retry_handshake(Id, St) ->
    case maps:find(Id, St#st.reqs) of
        {ok, #req{state = pending, tries = N} = Req} when N < ?HANDSHAKE_RETRIES ->
            Req1 = Req#req{tries = N + 1},
            ok = ask(Req1),
            put_req(Req1, St);
        {ok, #req{state = pending} = Req} ->
            %% Alive and silent through every retry. `held', never quarantined:
            %% it keeps its capacity because the request may still be running,
            %% and it is never replayed. Only a late answer or a `DOWN' moves
            %% it, and neither a timer nor an operator call exists to do so,
            %% because time passing does not prove a guardian is dead.
            ?LOG_WARNING("worker_reaper: ~ts unresolved, holding", [Id]),
            put_req(Req#req{state = held}, St);
        _ ->
            St
    end.

%%% --------------------------------------------------------------- journal ---

incarnation_of_node() ->
    case persistent_term:get(?INCARNATION_KEY, undefined) of
        undefined ->
            V = binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
            persistent_term:put(?INCARNATION_KEY, V),
            V;
        V ->
            V
    end.

next_generation() ->
    Gen = persistent_term:get(?GENERATION_KEY, 0) + 1,
    persistent_term:put(?GENERATION_KEY, Gen),
    Gen.

ensure_journals(Roots) ->
    maps:foreach(fun(_Id, Dir) ->
                     ok = filelib:ensure_path(journal_dir(Dir)),
                     ok = filelib:ensure_path(
                            filename:join(journal_dir(Dir), ?QUARANTINE_DIR))
                 end, Roots),
    ok.

journal_dir(Root) -> filename:join(Root, ?JOURNAL_DIR).

record_path(St, #req{root = Root, id = Id}) ->
    filename:join(journal_dir(maps:get(Root, St#st.roots)),
                  binary_to_list(Id) ++ ".rec").

%% Write to a temp name, sync, rename over the real one. A half-written record
%% is never observable: a rename within a directory is atomic and a partial
%% temp file is simply not the record.
%%
%% This buys BEAM-crash durability and not host-crash durability. For a reaper
%% crash, a supervisor restart or a node restart the page cache is still alive,
%% so what makes the record visible to a replacement is completing the write
%% and the rename *before* acknowledging. Ordering is the whole mechanism; the
%% sync is conservative flushing on top.
write_record(St, Req) ->
    Path = record_path(St, Req),
    Tmp = Path ++ ".part",
    Data = encode_record(St, Req),
    case file:open(Tmp, [write, raw, binary]) of
        {error, E} ->
            {error, io_error(E, Tmp)};
        {ok, Fd} ->
            R = file:write(Fd, Data),
            _ = file:sync(Fd),
            ok = file:close(Fd),
            case R of
                ok ->
                    case file:rename(Tmp, Path) of
                        ok -> ok;
                        {error, E} -> {error, io_error(E, Path)}
                    end;
                {error, E} ->
                    _ = file:delete(Tmp),
                    {error, io_error(E, Tmp)}
            end
    end.

remove_record(St, Req) ->
    _ = file:delete(record_path(St, Req)),
    ok.

quarantine_record(St, #req{root = Root, id = Id} = Req) ->
    Dir = filename:join(journal_dir(maps:get(Root, St#st.roots)),
                        ?QUARANTINE_DIR),
    _ = file:rename(record_path(St, Req),
                    filename:join(Dir, binary_to_list(Id) ++ ".rec")),
    ok.

io_error(E, Path) ->
    worker_error:worker(crashed, ~"journal write failed",
                        #{reason => E, path => iolist_to_binary(Path)}).

%% The identity header never changes and the operation list grows only by
%% atomic whole-record replacement. Never an in-place append: that would
%% reintroduce the half-written record the temp-and-rename protocol exists to
%% make impossible.
encode_record(St, #req{guardian = Pid, id = Id, gen = Gen, ops = Ops}) ->
    Header = [?RECORD_VERSION, " ", St#st.incarnation, " ",
              integer_to_list(Gen), " ", pid_to_list(Pid), " ", Id, "\n"],
    [Header | [encode_op(Op) || Op <- Ops]].

encode_op({Verb, Root, Rel}) ->
    [atom_to_list(Verb), " ", atom_to_list(Root), " ", escape(Rel), "\n"].

%% Every field is a number, a hex string, a pid literal or a verb from a fixed
%% table, so decoding yields an atom that already exists or fails. Nothing here
%% can mint one.
verb(<<"remove_tree">>) -> {ok, remove_tree};
verb(<<"delete_file">>) -> {ok, delete_file};
verb(_)                 -> error.

escape(Bin) -> << <<(esc(C))/binary>> || <<C>> <= Bin >>.

esc(C) when C >= $a, C =< $z -> <<C>>;
esc(C) when C >= $A, C =< $Z -> <<C>>;
esc(C) when C >= $0, C =< $9 -> <<C>>;
esc(C) when C =:= $-; C =:= $_; C =:= $.; C =:= $/ -> <<C>>;
esc(C) -> <<$%, (hex(C bsr 4)), (hex(C band 15))>>.

hex(N) when N < 10 -> $0 + N;
hex(N) -> $a + N - 10.

unescape(Bin) -> unescape(Bin, <<>>).

unescape(<<>>, Acc) -> {ok, Acc};
unescape(<<$%, A, B, Rest/binary>>, Acc) ->
    case {unhex(A), unhex(B)} of
        {{ok, X}, {ok, Y}} -> unescape(Rest, <<Acc/binary, (X * 16 + Y)>>);
        _                  -> error
    end;
unescape(<<$%, _/binary>>, _) -> error;
unescape(<<C, Rest/binary>>, Acc) -> unescape(Rest, <<Acc/binary, C>>).

unhex(C) when C >= $0, C =< $9 -> {ok, C - $0};
unhex(C) when C >= $a, C =< $f -> {ok, C - $a + 10};
unhex(C) when C >= $A, C =< $F -> {ok, C - $A + 10};
unhex(_) -> error.

%%% ---------------------------------------------------------------- sweep ---

%% On restart, sort every record by what can be observed. Nothing here replays
%% on silence.
sweep(St) ->
    maps:fold(fun(RootId, Dir, Acc) -> sweep_root(RootId, Dir, Acc) end,
              St, St#st.roots).

sweep_root(RootId, Dir, St) ->
    Journal = journal_dir(Dir),
    case file:list_dir(Journal) of
        {error, _} -> St;
        {ok, Names} ->
            lists:foldl(fun(N, Acc) -> sweep_one(RootId, Journal, N, Acc) end,
                        St, [N || N <- Names, lists:suffix(".rec", N)])
    end.

sweep_one(RootId, Journal, Name, St) ->
    Path = filename:join(Journal, Name),
    case file:read_file(Path) of
        {error, _} -> St;
        {ok, Bin} ->
            case decode_record(Bin, RootId, St) of
                {error, Why} ->
                    %% A record that does not parse, names a verb outside the
                    %% set, or carries a path escaping its root is quarantined
                    %% and logged, never acted on. This directory is precisely
                    %% where an adversarial file would have to be planted.
                    ?LOG_ERROR("worker_reaper: quarantining ~ts: ~p",
                               [Name, Why]),
                    _ = file:rename(Path, filename:join(
                                            [Journal, ?QUARANTINE_DIR, Name])),
                    St#st{quarantined = St#st.quarantined + 1};
                {ok, Req, Kind} ->
                    adopt_or_orphan(Req, Kind, St)
            end
    end.

%% Ambiguity always resolves towards doing nothing. Only a dead pid or an
%% explicit denial replays; silence goes pending and is asked again.
adopt_or_orphan(Req, orphan, St) ->
    schedule(Req#req{state = queued, mon = undefined, gen = St#st.gen}, St);
adopt_or_orphan(Req, live, St) ->
    case is_process_alive(Req#req.guardian) of
        false ->
            schedule(Req#req{state = queued, mon = undefined,
                             gen = St#st.gen}, St);
        true ->
            Mon = erlang:monitor(process, Req#req.guardian),
            Req1 = Req#req{state = pending, mon = Mon, gen = St#st.gen},
            ok = ask(Req1),
            put_req(Req1, St)
    end.

decode_record(Bin, RootId, St) ->
    case binary:split(Bin, <<"\n">>, [global, trim]) of
        [] -> {error, empty};
        [Header | Ops] -> decode_header(Header, Ops, RootId, St)
    end.

%% The incarnation is what decides whether the pid means anything. It outlives
%% a reaper restart and not a node restart, which is exactly the lifetime a pid
%% is meaningful for, so a record from another incarnation is an orphan without
%% anything having to look at its pid at all.
decode_header(Header, Ops, RootId, St) ->
    case binary:split(Header, <<" ">>, [global]) of
        [<<?RECORD_VERSION>>, Inc, GenB, PidB, Id] ->
            case decode_ops(Ops, [], St) of
                {error, _} = E -> E;
                {ok, DecodedOps} ->
                    decode_owner(Inc, GenB, PidB, Id, RootId, DecodedOps, St)
            end;
        _ ->
            {error, bad_header}
    end.

decode_owner(Inc, GenB, PidB, Id, RootId, Ops, St) ->
    Base = #req{id = Id, root = RootId, ops = Ops,
                relpath = relpath_of(Ops, RootId),
                state = queued, guardian = self(), gen = St#st.gen},
    case Inc =:= St#st.incarnation of
        false ->
            {ok, Base, orphan};
        true ->
            case {to_integer(GenB), to_pid(PidB)} of
                {{ok, Gen}, {ok, Pid}} ->
                    {ok, Base#req{guardian = Pid, gen = Gen}, live};
                _ ->
                    {error, bad_header}
            end
    end.

%% The reservation's op names the request directory, and it is written first,
%% so recovering the relative path is reading it back rather than storing it
%% twice.
relpath_of([{remove_tree, Root, Rel} | _], Root) -> Rel;
relpath_of(_, _) -> <<>>.

decode_ops([], Acc, _St) -> {ok, lists:reverse(Acc)};
decode_ops([Line | Rest], Acc, St) ->
    case binary:split(Line, <<" ">>, [global]) of
        [V, R, P] ->
            case {verb(V), root(R, St), unescape(P)} of
                {{ok, Verb}, {ok, Root}, {ok, Path}} ->
                    case safe_relative(Path) of
                        true  -> decode_ops(Rest, [{Verb, Root, Path} | Acc], St);
                        false -> {error, {escapes_root, Path}}
                    end;
                _ ->
                    {error, {bad_op, V}}
            end;
        _ ->
            {error, bad_op_line}
    end.

%% Root ids come from a closed set the same way verbs do: the configured map.
%% A record naming a root this reaper does not have is left alone and logged
%% rather than guessed at.
root(Bin, St) ->
    case [Id || Id <- maps:keys(St#st.roots), atom_to_binary(Id) =:= Bin] of
        [Id] -> {ok, Id};
        _    -> error
    end.

safe_relative(<<"/", _/binary>>) -> false;
safe_relative(Path) ->
    Parts = filename:split(Path),
    Parts =/= [] andalso not lists:member(<<"..">>, Parts).

to_integer(B) ->
    try {ok, binary_to_integer(B)} catch _:_ -> error end.

to_pid(B) ->
    try {ok, list_to_pid(binary_to_list(B))} catch _:_ -> error end.

%%% -------------------------------------------------------------- removal ---

exists({_Verb, Root, Rel}, Roots) ->
    case maps:find(Root, Roots) of
        error -> false;
        {ok, Dir} -> filelib:is_file(filename:join(Dir, Rel))
    end.

apply_op({remove_tree, Root, Rel}, Roots) ->
    case maps:find(Root, Roots) of
        error -> ok;
        {ok, Dir} -> _ = file:del_dir_r(filename:join(Dir, Rel)), ok
    end;
apply_op({delete_file, Root, Rel}, Roots) ->
    case maps:find(Root, Roots) of
        error -> ok;
        {ok, Dir} -> _ = file:delete(filename:join(Dir, Rel)), ok
    end.
