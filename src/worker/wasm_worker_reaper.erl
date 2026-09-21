-module(wasm_worker_reaper).
-moduledoc """
Who cleans up after a request when the process that owned it is gone.

Internal. The `wasm` application runs one per node, under `wasm_worker_sup`,
which says where it keeps its files; `wasm_script_worker` refuses a request
when none is running. `wasm_script_worker:cleanup_stats/0` and
`wasm_script_worker:cleanup_requests/0` are the supported way to look at it.

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
and an adapter whose `c:wasm_worker_adapter:cleanup/1` hangs would otherwise stop registration and
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

```text
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

-export([start_link/1, start_link/2, start_link/3, stop/0, alive/0, roots/0]).
-export([setting_keys/0, setting/2]).
-export([reserve/4, register/2, withdraw/2, transfer/3, finish/1]).
-export([unreachable_operation/1]).
-export([authorise/2, generation/0, incarnation/0, stats/0, requests/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).
-define(INCARNATION_KEY, {?MODULE, incarnation}).
-define(GENERATION_KEY, {?MODULE, generation}).
-define(JOURNAL_DIR, ".journal").
-define(QUARANTINE_DIR, "quarantine").
-define(RECORD_VERSION, "v2").

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
-define(MAX_CLEANUP_OPERATIONS, 256).
-define(HANDSHAKE_TIMEOUT, 1_000).
-define(HANDSHAKE_RETRIES, 3).

%% Defined in `wasm_worker_adapter`, beside the callbacks that name them.
-type root_id() :: wasm_worker_adapter:root_id().
-type request_id() :: wasm_worker_adapter:request_id().
-type token() :: wasm_worker_adapter:token().
-type recover_op() :: wasm_worker_adapter:recover_op().
-type action() :: wasm_worker_adapter:action().
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
              %% The steward that reserved this request. It is the caller
              %% identity every `{apply, ...}' operation must match, captured
              %% from the reserve call. `undefined' for a v1 record reconstructed
              %% by a restart, which never had one.
              steward        :: undefined | pid(),
              mon            :: undefined | reference(),
              %% The steward's monitor. The reaper watches both owners: while
              %% either is alive it stays passive on the other's death, and it
              %% cleans up only on an explicit finish or when both are gone.
              smon           :: undefined | reference(),
              root           :: root_id(),
              relpath        :: binary(),
              ops     = []   :: [recover_op()],
              actions = []   :: [{token(), action(), owned | transferred}],
              next_token = 1 :: pos_integer(),
              %% Operation-id ledger for the `{apply, ...}' transport: the next
              %% sequence expected in order, and every resolved sequence with the
              %% result it produced, so a resend after adoption is answered from
              %% store rather than re-executed. Bounded by
              %% `max_cleanup_operations_per_request'.
              next_seq = 1   :: pos_integer(),
              ledger = #{}   :: #{pos_integer() => term()},
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
             opts       :: map(),
             %% Roots this reaper made for itself and may remove at a clean
             %% shutdown. Never a root somebody configured.
             generated = [] :: [root_id()]}).

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
start_link(Roots, Opts) -> start_link(Roots, Opts, #{}).

-doc """
Start the reaper with what only its supervisor may say.

`#{generated := Ids}` names the roots this reaper was given a directory of its
own for, which it removes at a clean shutdown when nothing is left in them.
It is a separate argument, not a key in `Opts`, so that no configuration can
mark a directory somebody else owns for deletion. `wasm_worker_sup` is the
only caller.
""".
-spec start_link(#{root_id() => file:filename_all()}, map(),
                 #{generated => [root_id()]}) ->
          {ok, pid()} | {error, term()}.
start_link(Roots, Opts, Internal) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE,
                          {Roots, Opts, maps:get(generated, Internal, [])}, []).

-doc "The root ids this reaper was started with.".
-spec roots() -> [root_id()] | {error, wasm_worker_error:worker_error()}.
roots() -> call(roots).

-spec stop() -> ok.
stop() -> gen_server:stop(?SERVER).

-doc """
Whether a reaper is running.

`wasm_script_worker` checks this at every `submit`, not only when it starts: the
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
          {ok, file:filename_all()} | {error, wasm_worker_error:worker_error()}.
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
          {ok, token()} | {error, wasm_worker_error:worker_error(),
                           released | cleanup_failed}.
register(Id, Action) ->
    try gen_server:call(?SERVER, {register, Id, Action}, infinity)
    catch exit:_ -> unreachable(Action)
    end.

-doc "Drop a registered action, for a caller that released the thing itself.".
-spec withdraw(request_id(), token()) -> ok | {error, wasm_worker_error:worker_error()}.
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
          ok | {error, wasm_worker_error:worker_error()}.
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
-spec stats() -> map() | {error, wasm_worker_error:worker_error()}.
stats() -> call(stats).

-doc """
Every reservation this reaper holds, with the process that owns it.

Operator-facing rather than test-only: a reservation that ends in `held` stays
there until a late answer or a `DOWN`, deliberately, and the way to resolve one
is to look at what is holding it and kill that guardian if it really is stuck.
`delivered` says whether the adapter's state has reached the registry yet, and
so whether `c:wasm_worker_adapter:cleanup/1` has an owner.
""".
-spec requests() -> [#{id := request_id(), state := atom(), guardian := pid(),
                       delivered := boolean(), actions := non_neg_integer()}]
                  | {error, wasm_worker_error:worker_error()}.
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
    wasm_worker_error:worker(no_reaper, ~"no cleanup owner is running", #{}).

-doc """
What an operation answers when its reaper is gone, run in the caller.

The steward calls this when a forwarded operation's reaper pid has died, so the
answer is what the guardian would have got had it called the reaper directly and
found it absent: a `register` runs the action bounded and reports `released` or
`cleanup_failed`, and a `withdraw` or `transfer` names the missing owner.
""".
-spec unreachable_operation(wasm_cleanup_steward:operation()) ->
          {error, wasm_worker_error:worker_error()} |
          {error, wasm_worker_error:worker_error(), released | cleanup_failed}.
unreachable_operation({register, Action})   -> unreachable(Action);
unreachable_operation({withdraw, _Token})   -> {error, no_reaper()};
unreachable_operation({transfer, _M, _A})   -> {error, no_reaper()}.

%% The registry is unreachable, so perform what could not be recorded. In a
%% bounded child, never inline: a hanging action inline would wedge the caller
%% past its own deadline and defeat cancellation. Killing that child does not
%% prove the resource was released, so the two outcomes are told apart.
unreachable(F) when is_function(F, 0) ->
    case run_bounded(fun() -> _ = F(), ok end, ?CLEANUP_TIMEOUT) of
        ok ->
            {error, no_reaper(), released};
        {error, Why} ->
            ?LOG_ERROR("wasm_worker_reaper: unowned resource, action failed: ~p",
                       [Why]),
            {error, no_reaper(), cleanup_failed}
    end;
unreachable(Op) ->
    %% A durable op is a promise the journal keeps, and the journal has exactly
    %% one writer: the reaper that is not there. There is no honest way to
    %% record this and no second writer to invent, so it is the unowned case.
    ?LOG_ERROR("wasm_worker_reaper: unowned durable op, not recorded: ~p", [Op]),
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
default(max_cleanup_actions)  -> ?MAX_CLEANUP_ACTIONS;
default(max_cleanup_operations_per_request) -> ?MAX_CLEANUP_OPERATIONS.

setting_keys() ->
    [max_cleanup_jobs, cleanup_queue_len, cleanup_retries, cleanup_backoff,
     cleanup_timeout, cleanup_job_deadline, max_cleanup_actions,
     max_cleanup_operations_per_request].

%%% -------------------------------------------------------------- server ---

init({Roots, Opts, Generated}) ->
    process_flag(trap_exit, true),
    Incarnation = incarnation_of_node(),
    Gen = next_generation(),
    ok = ensure_journals(Roots),
    %% Normalised once, so every read is a `map_get' on a complete map rather
    %% than a default lookup in a guard, which cannot call a function.
    Settings = maps:from_list([{K, setting(Opts, K)} || K <- setting_keys()]),
    St = #st{roots = Roots, gen = Gen, incarnation = Incarnation,
             opts = Settings,
             generated = [G || G <- Generated, maps:is_key(G, Roots)]},
    {ok, sweep(St)}.

handle_call({reserve, Id, Guardian, Root, RelPath}, From, St) ->
    case maps:is_key(Root, St#st.roots) of
        false ->
            {reply, {error, wasm_worker_error:worker(
                              insufficient_limit, ~"unknown root",
                              #{root => Root})}, St};
        true ->
            case has_capacity(St) of
                false ->
                    {reply, {error, wasm_worker_error:worker(
                                      cleanup_saturated,
                                      ~"no cleanup capacity", #{})}, St};
                true ->
                    %% The reserve caller is the steward, and it is the identity
                    %% every later `{apply, ...}' for this request must match.
                    Steward = element(1, From),
                    Req = #req{id = Id, state = live, guardian = Guardian,
                               steward = Steward,
                               mon = erlang:monitor(process, Guardian),
                               smon = erlang:monitor(process, Steward),
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
                            erlang:demonitor(Req#req.smon, [flush]),
                            {reply, {error, E}, St}
                    end
            end
    end;

handle_call({register, Id, Action}, _From, St) ->
    {Reply, St1} = op_register(Id, Action, St),
    {reply, Reply, St1};

handle_call({withdraw, Id, Token}, _From, St) ->
    {Reply, St1} = op_withdraw(Id, Token, St),
    {reply, Reply, St1};

handle_call({transfer, Id, Mod, AdapterState}, _From, St) ->
    {Reply, St1} = op_transfer(Id, Mod, AdapterState, St),
    {reply, Reply, St1};

%% The steward's transport. A cleanup operation carried by
%% `gen_server:send_request/2', so the caller is authenticated by OTP as `From'
%% rather than by a field it could forge: only the steward that reserved the
%% request may drive its cleanup. This stage dispatches to the same logic the
%% legacy calls use; the operation-id ledger, ordering and bound that
%% `OperationId' carries arrive with adoption, which is what resends them.
handle_call({apply, Id, OperationId, Operation}, From, St) ->
    case authorised_caller(Id, element(1, From), St) of
        true ->
            {Reply, St1} = apply_transported(Id, OperationId, Operation, St),
            {reply, Reply, St1};
        false ->
            {reply, {error, unauthorised()}, St}
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
               delivered => R#req.cleanup =/= undefined,
               actions => length(R#req.actions)}
             || R <- maps:values(St#st.reqs)], St};

handle_call(roots, _From, St) ->
    {reply, maps:keys(St#st.roots), St};
handle_call(stats, _From, St) ->
    Counts = lists:foldl(fun(#req{state = S}, Acc) ->
                             maps:update_with(S, fun(N) -> N + 1 end, 1, Acc)
                         end, #{}, maps:values(St#st.reqs)),
    {reply, Counts#{quarantined => St#st.quarantined,
                    capacity => capacity(St),
                    generation => St#st.gen}, St};

handle_call(_Msg, _From, St) ->
    {reply, {error, wasm_worker_error:worker(crashed, ~"bad call", #{})}, St}.

handle_cast({finish, Id}, St) ->
    %% The guardian cleaned up itself and says so. Drop the record last, after
    %% everything it named is gone.
    case maps:find(Id, St#st.reqs) of
        error -> {noreply, St};
        {ok, Req} ->
            ok = drop_monitor(Req#req.mon),
            ok = drop_monitor(Req#req.smon),
            ok = remove_record(St, Req),
            {noreply, St#st{reqs = maps:remove(Id, St#st.reqs)}}
    end;
handle_cast(_, St) ->
    {noreply, St}.

handle_info({'DOWN', Mon, process, _Pid, _Why}, St) ->
    {noreply, owner_down(Mon, St)};

handle_info({adopt_reply, Id, Actions, AdapterState}, St) ->
    {noreply, adopt_reply(Id, Actions, AdapterState, St)};

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

%% A clean shutdown removes the roots this reaper generated, and only when
%% nothing in them is left to recover: no reservation in any state, and a
%% journal with no record and nothing quarantined. Otherwise the directory and
%% its journal stay, for whoever looks next. A crash removes nothing.
terminate(shutdown, #st{generated = [_ | _] = Gen} = St) ->
    _ = [remove_if_idle(Id, St) || Id <- Gen],
    ok;
terminate(_Why, _St) ->
    ok.

remove_if_idle(Id, #st{roots = Roots} = St) ->
    Dir = maps:get(Id, Roots),
    case idle(St) andalso journal_empty(Dir) of
        true ->
            _ = file:del_dir_r(Dir),
            ok;
        false ->
            ?LOG_WARNING("wasm_worker_reaper: keeping ~ts at shutdown: "
                         "requests or journal records remain", [Dir])
    end.

idle(#st{reqs = Reqs, queue = Queue, jobs = Jobs}) ->
    map_size(Reqs) =:= 0 andalso Queue =:= [] andalso map_size(Jobs) =:= 0.

journal_empty(Dir) ->
    Journal = journal_dir(Dir),
    case {file:list_dir(Journal),
          file:list_dir(filename:join(Journal, ?QUARANTINE_DIR))} of
        {{ok, Names}, {ok, []}} -> Names -- [?QUARANTINE_DIR] =:= [];
        {{ok, Names}, {error, enoent}} -> Names =:= [];
        _ -> false
    end.

%%% ---------------------------------------------------------- registering ---

%% One place each cleanup operation is carried out, whichever transport asked
%% for it: the legacy `{register, ...}' call and the steward's `{apply, ...}'
%% both land here, so the two can never diverge. Each returns `{Reply, St1}'.
apply_operation(Id, {register, Action}, St)  -> op_register(Id, Action, St);
apply_operation(Id, {withdraw, Token}, St)   -> op_withdraw(Id, Token, St);
apply_operation(Id, {transfer, Mod, A}, St)  -> op_transfer(Id, Mod, A, St);
apply_operation(Id, finish, St)              -> op_finish(Id, St).

%% The finish barrier. The steward is done and asks the reaper to own cleanup:
%% both owners are released and the request is queued, so the cleanup runs once
%% and neither owner's later `DOWN' schedules it again. An unknown request is
%% already gone, which is the same answer.
op_finish(Id, St) ->
    case maps:find(Id, St#st.reqs) of
        error ->
            {ok, St};
        {ok, Req} ->
            ok = drop_monitor(Req#req.mon),
            ok = drop_monitor(Req#req.smon),
            {ok, schedule(Req#req{mon = undefined, smon = undefined,
                                  state = queued}, St)}
    end.

%% A monitored process died. The reaper watches both the guardian and the
%% steward, and cleans up only when neither can: while one owner is alive the
%% other's death leaves the request passive.
owner_down(Mon, St) ->
    Reqs = maps:values(St#st.reqs),
    case lists:keyfind(Mon, #req.mon, Reqs) of
        #req{} = Req -> guardian_down(Req, St);
        false ->
            case lists:keyfind(Mon, #req.smon, Reqs) of
                #req{} = Req -> steward_down(Req, St);
                false        -> job_down(Mon, St)
            end
    end.

%% Guardian gone. With the steward alive the reaper stays passive and tells the
%% steward, which reconciles and submits finish; with no steward left it cleans.
guardian_down(#req{smon = undefined} = Req, St) ->
    schedule(Req#req{mon = undefined, state = queued}, St);
guardian_down(#req{steward = Steward} = Req, St) ->
    Steward ! {cleanup_orphaned, Req#req.id},
    put_req(Req#req{mon = undefined}, St).

%% Steward gone. With the guardian alive it owns the fallback, so the reaper
%% stays passive; with the guardian also gone the reaper cleans from its replica.
steward_down(#req{mon = undefined} = Req, St) ->
    schedule(Req#req{smon = undefined, state = queued}, St);
steward_down(Req, St) ->
    put_req(Req#req{smon = undefined}, St).

%% A transported operation carries `OperationId = {RequestId, Sequence}'. For a
%% known request the sequence orders and de-duplicates it against the ledger; an
%% unknown request has nothing to order against and is answered as absent.
apply_transported(Id, {Id, Seq}, Operation, St)
  when is_integer(Seq), Seq >= 1 ->
    case maps:find(Id, St#st.reqs) of
        error     -> apply_operation(Id, Operation, St);
        {ok, Req} -> apply_sequenced(Seq, Operation, Req, St)
    end;
apply_transported(Id, _OperationId, Operation, St) ->
    apply_operation(Id, Operation, St).

apply_sequenced(Seq, Op, #req{next_seq = Next, ledger = L}, St)
  when Seq < Next ->
    %% Already resolved: a recorded operation answers from the ledger,
    %% re-executing nothing, which is what makes a resend after adoption safe. An
    %% over-limit operation recorded nothing, so it is answered over-limit again.
    case maps:find(Seq, L) of
        {ok, Stored} -> {Stored, St};
        error        -> {over_limit(Op, St), St}
    end;
apply_sequenced(Seq, _Op, #req{next_seq = Next}, St)
  when Seq > Next ->
    %% A gap. The reaper acts on operations in order, so it asks for the missing
    %% one instead of applying this out of order.
    {{resend, Next}, St};
apply_sequenced(Seq, Op, #req{id = Id} = Req, St) ->        %% Seq =:= next_seq
    %% `finish' is never over the ceiling: it is always accepted, so terminal
    %% cleanup can never be blocked, and it has no over-limit answer.
    case Op =/= finish
         andalso Seq > setting(St, max_cleanup_operations_per_request) of
        true ->
            %% Over the ceiling: consume the sequence so the next operation is
            %% not a gap, record nothing so the ledger stays bounded, and answer
            %% over-limit.
            {over_limit(Op, St), put_req(Req#req{next_seq = Seq + 1}, St)};
        false ->
            {Reply, St1} = apply_operation(Id, Op, St),
            {Reply, advance_ledger(Id, Seq, Reply, St1)}
    end.

advance_ledger(Id, Seq, Reply, St) ->
    case maps:find(Id, St#st.reqs) of
        {ok, R} ->
            put_req(R#req{next_seq = Seq + 1,
                          ledger = maps:put(Seq, Reply, R#req.ledger)}, St);
        error ->
            St
    end.

%% Over the per-request operation ceiling. Not recorded, so the register
%% contract's `cleanup_failed' (nobody owns it) is the honest answer, and a
%% withdraw or transfer keeps what it had.
over_limit(Op, St) ->
    E = wasm_worker_error:worker(cleanup_saturated,
                                 ~"too many cleanup operations",
                                 #{max => setting(
                                            St, max_cleanup_operations_per_request)}),
    case Op of
        {register, _}    -> {error, E, cleanup_failed};
        {withdraw, _}    -> {error, E};
        {transfer, _, _} -> {error, E}
    end.

%% Only the steward that reserved a request may drive its cleanup operations. A
%% request with no recorded steward -- a v1 record a restart reconstructed --
%% has no identity to check, and an unknown request is answered as absent by the
%% operation itself, so both pass here and the operation decides.
authorised_caller(Id, Caller, St) ->
    case maps:find(Id, St#st.reqs) of
        {ok, #req{steward = Steward}} when is_pid(Steward) -> Caller =:= Steward;
        _ -> true
    end.

unauthorised() ->
    wasm_worker_error:worker(unauthorised,
                             ~"cleanup operation from a foreign caller", #{}).

op_register(Id, Action, St) ->
    case maps:find(Id, St#st.reqs) of
        error ->
            {unreachable(Action), St};
        {ok, #req{actions = As}}
          when length(As) >= map_get(max_cleanup_actions, St#st.opts) ->
            %% The list is adapter-controlled: without a ceiling an adapter in
            %% a loop registers until the reaper's memory is the bound.
            E = wasm_worker_error:worker(cleanup_saturated,
                                    ~"too many cleanup actions",
                                    #{max => setting(St, max_cleanup_actions)}),
            {{error, E, cleanup_failed}, St};
        {ok, Req} ->
            do_register(Req, Action, St)
    end.

op_withdraw(Id, Token, St) ->
    case maps:find(Id, St#st.reqs) of
        error ->
            {ok, St};
        {ok, #req{actions = As} = Req} ->
            Kept = [A || {T, _, _} = A <- As, T =/= Token],
            Req1 = Req#req{actions = Kept},
            %% Only a durable op changes what is on disk. Withdrawing a fun
            %% costs nothing, which is why the common case writes nothing.
            case durable(As, Token) of
                false -> {ok, put_req(Req1, St)};
                true ->
                    Req2 = Req1#req{ops = ops_of(Req1)},
                    case write_record(St, Req2) of
                        ok         -> {ok, put_req(Req2, St)};
                        {error, E} -> {{error, E}, St}
                    end
            end
    end.

op_transfer(Id, Mod, AdapterState, St) ->
    case maps:find(Id, St#st.reqs) of
        error ->
            {{error, no_reaper()}, St};
        {ok, #req{actions = As} = Req} ->
            %% Marks, never withdraws. A `cleanup/1' that raises would
            %% otherwise leak precisely the resources whose actions were just
            %% removed, so success is what drops them.
            Marked = [{T, A, transferred} || {T, A, _} <- As],
            {ok, put_req(Req#req{actions = Marked,
                                 cleanup = {Mod, AdapterState}}, St)}
    end.

do_register(#req{next_token = T, actions = As} = Req, Action, St) ->
    Req1 = Req#req{actions = [{T, Action, owned} | As], next_token = T + 1},
    case is_durable(Action) of
        false ->
            {{ok, T}, put_req(Req1, St)};
        true ->
            %% Synchronous with respect to the write and the rename:
            %% acknowledging before the rename completes is exactly the window
            %% in which an acknowledged op is lost.
            Req2 = Req1#req{ops = ops_of(Req1)},
            case write_record(St, Req2) of
                ok ->
                    {{ok, T}, put_req(Req2, St)};
                {error, E} ->
                    {{error, E, cleanup_failed}, St}
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
    ?LOG_ERROR("wasm_worker_reaper: quarantining ~ts after ~p attempts",
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
    case wasm_worker_reaper:authorise(Id, Gen) of
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
            ?LOG_WARNING("wasm_worker_reaper: ~p:cleanup/1 failed: ~p", [Mod, Why]),
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
            ?LOG_WARNING("wasm_worker_reaper: action ~p failed: ~p", [Action, Why]),
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
            ?LOG_WARNING("wasm_worker_reaper: ~ts unresolved, holding", [Id]),
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
    wasm_worker_error:worker(crashed, ~"journal write failed",
                        #{reason => E, path => iolist_to_binary(Path)}).

%% The identity header never changes and the operation list grows only by
%% atomic whole-record replacement. Never an in-place append: that would
%% reintroduce the half-written record the temp-and-rename protocol exists to
%% make impossible.
encode_record(St, #req{guardian = Pid, steward = SPid, id = Id,
                       gen = Gen, ops = Ops}) ->
    Header = [?RECORD_VERSION, " ", St#st.incarnation, " ",
              integer_to_list(Gen), " ", pid_to_list(Pid), " ",
              steward_field(SPid), " ", Id, "\n"],
    [Header | [encode_op(Op) || Op <- Ops]].

steward_field(undefined)            -> "-";
steward_field(Pid) when is_pid(Pid) -> pid_to_list(Pid).

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
                    ?LOG_ERROR("wasm_worker_reaper: quarantining ~ts: ~p",
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
            adopt_steward(Req1, St)
    end.

%% A v2 record names the steward. If it is still alive, monitor it -- so the
%% two-owner logic holds after adoption -- and ask it for the volatile funs and
%% adapter state the dead reaper could not have kept. The journal already carries
%% the durable ops, so this recovers only what was lost.
adopt_steward(#req{steward = SPid, id = Id, gen = Gen} = Req, St)
  when is_pid(SPid) ->
    case is_process_alive(SPid) of
        true ->
            SMon = erlang:monitor(process, SPid),
            SPid ! {adopt_request, self(), Gen, Id},
            put_req(Req#req{smon = SMon}, St);
        false ->
            put_req(Req, St)
    end;
adopt_steward(Req, St) ->
    put_req(Req, St).

%% The steward answered a restart with the volatile state. Restore the funs and
%% adapter state; durable ops already came from the journal, so nothing here
%% touches them, and `run_actions' takes only the funs from `actions' while
%% `remove_dirs' takes the durable ops -- neither runs the other's, so no action
%% executes twice. A transfer having happened marks the actions transferred.
adopt_reply(Id, Actions, AdapterState, St) ->
    case maps:find(Id, St#st.reqs) of
        error ->
            St;
        {ok, Req} ->
            Own = case AdapterState of undefined -> owned; _ -> transferred end,
            Restored = [{T, A, Own} || {T, A} <- Actions],
            put_req(Req#req{actions = Restored, cleanup = AdapterState}, St)
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
%% v2 adds the steward field; a v1 record (from a node upgraded in flight, or a
%% test that plants one) has no steward and decodes with none.
decode_header(Header, Ops, RootId, St) ->
    case binary:split(Header, <<" ">>, [global]) of
        [<<"v2">>, Inc, GenB, PidB, SPidB, Id] ->
            decode_body(Inc, GenB, PidB, SPidB, Id, Ops, RootId, St);
        [<<"v1">>, Inc, GenB, PidB, Id] ->
            decode_body(Inc, GenB, PidB, <<"-">>, Id, Ops, RootId, St);
        _ ->
            {error, bad_header}
    end.

decode_body(Inc, GenB, PidB, SPidB, Id, Ops, RootId, St) ->
    case decode_ops(Ops, [], St) of
        {error, _} = E -> E;
        {ok, DecodedOps} ->
            decode_owner(Inc, GenB, PidB, SPidB, Id, RootId, DecodedOps, St)
    end.

decode_owner(Inc, GenB, PidB, SPidB, Id, RootId, Ops, St) ->
    Base = #req{id = Id, root = RootId, ops = Ops,
                relpath = relpath_of(Ops, RootId),
                state = queued, guardian = self(), gen = St#st.gen},
    case Inc =:= St#st.incarnation of
        false ->
            {ok, Base, orphan};
        true ->
            case {to_integer(GenB), to_pid(PidB)} of
                {{ok, Gen}, {ok, Pid}} ->
                    {ok, Base#req{guardian = Pid, steward = decode_steward(SPidB),
                                  gen = Gen}, live};
                _ ->
                    {error, bad_header}
            end
    end.

decode_steward(<<"-">>) -> undefined;
decode_steward(SPidB) ->
    case to_pid(SPidB) of
        {ok, Pid} -> Pid;
        _         -> undefined
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
