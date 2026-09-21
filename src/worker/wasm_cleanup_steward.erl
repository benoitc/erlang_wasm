-module(wasm_cleanup_steward).
-moduledoc """
Internal: the per-request cleanup steward.

One steward owns the cleanup interaction with the reaper for a single request,
so the guardian talks to the steward and never to the reaper directly. The full
protocol -- the ledger, the `send_request` transport, the state machine and
adoption -- is described in `test/audit/CLEANUP_STEWARD.md`.

The steward is the operation authority. It assigns each operation a monotonic
sequence, keeps a ledger of `Sequence => {Operation, pending | {done, Result}}`,
and carries operations to the reaper with `gen_server:send_request/2`, matching
answers with `gen_server:check_response/3` so it never blocks. Each operation's
`OperationId` is `{RequestId, Sequence}`; `reserve` is sequence 0 and stays
synchronous, because it runs at setup before the deadline that matters.

It **pins** the exact reaper pid it reserved against and monitors it. While that
reaper lives, operations go to it. When it dies, the operations it was still
answering stay pending: a replacement reaper's `adopt_request`, sent during its
sweep, re-pins the steward, which hands over the ledger, mirror and next
sequence in `adopt_reply` and then resends the pending operations on the same
ordered path, so none races ahead of the sequence handover and a request
survives a reaper restart with its sequence and volatile state intact. Only when
an operation must be sent with no reaper pinned does the steward ask the cleanup
manager whether one can be reached; a definitive `gone` fails the operation
rather than holding it, so a request whose reaper will not return is not stuck.
""".

-behaviour(gen_server).

-export([start_link/1, reserve/4, forward/4, complete/2, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% What the guardian asks the steward to do to the reaper, and what carries
%% enough for the steward to make the call and to answer if the reaper is gone.
-type operation() :: {register, wasm_worker_adapter:action()}
                   | {withdraw, wasm_worker_adapter:token()}
                   | {transfer, module(), term()}.
-export_type([operation/0]).

%% One ledger entry: how to answer the guardian, the operation itself, and
%% whether the reaper has resolved it. A pending entry is what a reaper restart
%% resends.
-record(op, {corr      :: reference(),
             reply_to  :: pid(),
             operation :: operation(),
             status    :: pending | {done, term()}}).

-record(s, {request :: wasm_worker_reaper:request_id(),
            %% Next operation sequence. Reserve is 0; register, withdraw and
            %% transfer take 1, 2, 3 ... in order.
            seq = 1 :: pos_integer(),
            %% The exact reaper this request is pinned to, and its monitor, so
            %% its death is observed and a replacement can be re-pinned.
            reaper = undefined :: undefined | pid(),
            rmon   = undefined :: undefined | reference(),
            %% Outstanding `send_request' operations, each labelled by its
            %% sequence (an integer) or `{finish, Guardian}'.
            reqids :: gen_server:request_id_collection(),
            %% The operation ledger, keyed by sequence.
            ledger = #{} :: #{pos_integer() => #op{}},
            %% A finish awaiting the reaper, so a replacement resubmits it: the
            %% guardian to answer, or `none' for an orphan finish.
            pending_finish = undefined :: undefined | none | pid(),
            %% The volatile cleanup state the reaper accepted: owned actions
            %% (keyed by token, which is the sequence) and the adapter state, so
            %% a restarted reaper recovers from this steward what it could not
            %% have kept. Best-effort, lost only if this process dies.
            actions = [] :: [{wasm_worker_adapter:token(),
                              wasm_worker_adapter:action()}],
            adapter_state = undefined :: undefined | {module(), term()}}).

-spec start_link(wasm_worker_reaper:request_id()) -> {ok, pid()}.
start_link(RequestId) ->
    gen_server:start_link(?MODULE, RequestId, []).

-doc """
Claim the request's cleanup capacity and directory, via the reaper.

Synchronous, and it stays that way: it runs at setup, before the runner and
before the request deadline is being enforced, so the caller waiting on it is
not the caller that owns a deadline. It also pins the reaper this steward talks
to from here on.
""".
-spec reserve(pid(), pid(), wasm_worker_adapter:root_id(), binary()) ->
          {ok, file:filename_all()} | {error, wasm_worker_error:worker_error()}.
reserve(Steward, Owner, Root, RelPath) ->
    gen_server:call(Steward, {reserve, Owner, Root, RelPath}, infinity).

-doc """
Forward a cleanup operation to the reaper without waiting for it.

Returns at once. The steward sends the operation to the reaper and, when the
answer arrives, sends `{steward_reply, CorrRef, Reply}` to `ReplyTo`, so the
guardian correlates the answer to the runner it is holding and never blocks on
the reaper itself.
""".
-spec forward(pid(), reference(), pid(), operation()) -> ok.
forward(Steward, CorrRef, ReplyTo, Operation) ->
    gen_server:cast(Steward, {forward, CorrRef, ReplyTo, Operation}).

-doc """
Tell the steward the request is done and it should finish it with the reaper.

The steward submits `finish`, which asks the reaper to own cleanup, and answers
`Guardian` with `{cleanup_owned, Steward}` once the reaper accepts it, or
`{cleanup_unavailable, Steward}` if no reaper can be reached, so the guardian
either exits or falls back to its mirror.
""".
-spec complete(pid(), pid()) -> ok.
complete(Steward, Guardian) ->
    gen_server:cast(Steward, {complete, Guardian}).

-doc """
Stop a steward. Non-blocking, so a caller tearing a request down never waits on
a steward that is itself waiting on the reaper.
""".
-spec stop(pid()) -> ok.
stop(Steward) ->
    exit(Steward, shutdown),
    ok.

init(RequestId) ->
    {ok, #s{request = RequestId, reqids = gen_server:reqids_new()}}.

handle_call({reserve, Owner, Root, RelPath}, _From, #s{request = Id} = S) ->
    Reply = wasm_worker_reaper:reserve(Id, Owner, Root, RelPath),
    S1 = case Reply of
             {ok, _} -> pin(whereis(wasm_worker_reaper), S);
             _       -> S
         end,
    {reply, Reply, S1};
handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast({forward, CorrRef, ReplyTo, Operation}, #s{seq = Seq} = S) ->
    Entry = #op{corr = CorrRef, reply_to = ReplyTo,
                operation = Operation, status = pending},
    S1 = S#s{seq = Seq + 1, ledger = maps:put(Seq, Entry, S#s.ledger)},
    {noreply, dispatch(S1, Seq)};
handle_cast({complete, Guardian}, S) ->
    submit_finish(Guardian, S);
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({adopt_request, ReaperPid, _Generation, Id}, #s{request = Id} = S0) ->
    %% A replacement reaper is recovering this request. Re-pin to it, hand it the
    %% ledger, mirror and next sequence, then resend the operations it does not
    %% have. Resend follows adopt_reply on the same ordered path, so no operation
    %% arrives before the sequence is restored.
    S = pin(ReaperPid, S0),
    ReaperPid ! {adopt_reply, Id, done_results(S), resume_seq(S),
                 S#s.actions, S#s.adapter_state},
    {noreply, resend(S)};
handle_info({cleanup_orphaned, _Id}, S) ->
    %% The reaper saw the guardian die and asked the steward to finish. There is
    %% no guardian left to answer.
    submit_finish(none, S);
handle_info({cleanup_complete, _Id}, S) ->
    %% The reaper finished cleanup; the steward's job is done and its tombstone
    %% can be dropped once it goes down.
    {stop, normal, S};
handle_info({cleanup_terminal, _Id}, S) ->
    %% Cleanup was quarantined; the steward exits so the reaper drops the record.
    {stop, normal, S};
handle_info({'DOWN', RMon, process, _Pid, _Reason}, #s{rmon = RMon} = S) ->
    %% The pinned reaper died. Keep the pending operations: a replacement reaper
    %% adopts this request during its sweep and the steward resends them then. A
    %% reaper that answered its operations before dying left nothing pending.
    {noreply, S#s{reaper = undefined, rmon = undefined}};
handle_info(Msg, S) ->
    case gen_server:check_response(Msg, S#s.reqids, true) of
        {{reply, _Reply}, {finish, Guardian}, Reqids} ->
            %% The reaper accepted the finish and owns cleanup. The steward stays
            %% alive as a passive mirror until `cleanup_complete', so a reaper
            %% restart during cleanup can re-adopt it and recover volatile state.
            notify(Guardian, cleanup_owned),
            {noreply, S#s{reqids = Reqids, pending_finish = undefined}};
        {{error, {_Reason, _}}, {finish, Guardian}, Reqids} ->
            %% The reaper died before answering the finish. Keep it pending for a
            %% replacement to resubmit on adoption; a definitively gone reaper is
            %% caught by the manager query in `submit_finish'.
            {noreply, S#s{reqids = Reqids, pending_finish = Guardian}};
        {{reply, Reply}, Seq, Reqids} when is_integer(Seq) ->
            #op{corr = CorrRef, reply_to = ReplyTo, operation = Op} =
                maps:get(Seq, S#s.ledger),
            ReplyTo ! {steward_reply, CorrRef, Reply},
            L = mark_done(Seq, Reply, S#s.ledger),
            {noreply, mirror(Op, Reply, S#s{reqids = Reqids, ledger = L})};
        {{error, {_Reason, _}}, Seq, Reqids} when is_integer(Seq) ->
            %% The reaper died before answering this operation; it stays pending
            %% in the ledger and a replacement resends it on adoption.
            {noreply, S#s{reqids = Reqids}};
        no_request ->
            {noreply, S};
        no_reply ->
            {noreply, S}
    end.

%%% ---------------------------------------------------------------- internal ---

%% Send an operation now if a reaper is pinned. With none pinned it was either
%% dispatched after the pinned reaper died -- in which case a replacement will
%% adopt and resend -- or never had one; ask the manager which. A reaper it can
%% reach is pinned and the operation sent; a definitive `gone' answers the
%% operation as absent so the runner is not stuck behind a reaper that is not
%% coming back.
dispatch(#s{reaper = Reaper} = S, Seq) when is_pid(Reaper) ->
    send_op(S, Seq);
dispatch(S, Seq) ->
    case wasm_cleanup_manager:reaper() of
        {ok, Reaper} -> send_op(pin(Reaper, S), Seq);
        gone         -> answer_absent(S, Seq)
    end.

send_op(#s{reaper = Reaper, request = Id, ledger = L} = S, Seq) ->
    #op{operation = Operation} = maps:get(Seq, L),
    Reqids = gen_server:send_request(Reaper, {apply, Id, {Id, Seq}, Operation},
                                     Seq, S#s.reqids),
    S#s{reqids = Reqids}.

%% Answer one pending operation as the reaper would when absent, and record it
%% resolved so a later adoption does not resend it.
answer_absent(#s{ledger = L} = S, Seq) ->
    #op{corr = CorrRef, reply_to = ReplyTo, operation = Op} = maps:get(Seq, L),
    Reply = wasm_worker_reaper:unreachable_operation(Op),
    ReplyTo ! {steward_reply, CorrRef, Reply},
    S#s{ledger = mark_done(Seq, Reply, L)}.

%% Submit the finish barrier. With a reaper pinned, send it there; with none,
%% ask the manager -- a reachable reaper is pinned and finish sent, a definitive
%% `gone' tells the guardian to fall back to its mirror and the steward, having
%% nothing left to own, exits.
submit_finish(Guardian, #s{reaper = Reaper} = S) when is_pid(Reaper) ->
    {noreply, send_finish(Guardian, S)};
submit_finish(Guardian, S) ->
    case wasm_cleanup_manager:reaper() of
        {ok, Reaper} -> {noreply, send_finish(Guardian, pin(Reaper, S))};
        gone         -> notify(Guardian, cleanup_unavailable),
                        {stop, normal, S}
    end.

send_finish(Guardian, #s{reaper = Reaper, request = Id, seq = Seq} = S) ->
    Reqids = gen_server:send_request(Reaper, {apply, Id, {Id, Seq}, finish},
                                     {finish, Guardian}, S#s.reqids),
    S#s{seq = Seq + 1, reqids = Reqids, pending_finish = Guardian}.

%% Pin (or re-pin) the reaper: drop the old monitor, take one on the new pid.
pin(undefined, S) ->
    S;
pin(Reaper, S) when is_pid(Reaper) ->
    ok = drop_monitor(S#s.rmon),
    S#s{reaper = Reaper, rmon = erlang:monitor(process, Reaper)}.

drop_monitor(undefined) -> ok;
drop_monitor(Ref)       -> erlang:demonitor(Ref, [flush]), ok.

notify(none, _What)      -> ok;
notify(Guardian, What)   -> Guardian ! {What, self()}, ok.

%% The resolved results, for the reaper to restore its ledger and answer a
%% resent duplicate from store.
done_results(#s{ledger = L}) ->
    maps:from_list([{Seq, R}
                    || {Seq, #op{status = {done, R}}} <- maps:to_list(L)]).

%% The sequence a replacement reaper resumes from: the lowest still pending, or
%% the next sequence to assign when nothing is pending. Pending operations form a
%% contiguous suffix, so nothing done sits above this.
resume_seq(#s{ledger = L, seq = Seq}) ->
    case [K || {K, #op{status = pending}} <- maps:to_list(L)] of
        []      -> Seq;
        Pending -> lists:min(Pending)
    end.

%% Resend every pending operation to the newly pinned reaper, in order, and
%% resubmit a finish that was awaiting one.
resend(#s{ledger = L} = S) ->
    Pending = lists:sort([K || {K, #op{status = pending}} <- maps:to_list(L)]),
    S1 = lists:foldl(fun(Seq, Acc) -> send_op(Acc, Seq) end, S, Pending),
    case S1#s.pending_finish of
        undefined -> S1;
        Guardian  -> send_finish(Guardian, S1)
    end.

mark_done(Seq, Reply, L) ->
    Op = maps:get(Seq, L),
    maps:put(Seq, Op#op{status = {done, Reply}}, L).

%% Keep the mirror in step with what the reaper accepted: a registered action is
%% owned, a withdrawn one is dropped, and a transfer records the adapter state.
%% Only the reaper's success changes ownership, so nothing speculative is kept.
mirror({register, Action}, {ok, Token}, S) ->
    S#s{actions = [{Token, Action} | S#s.actions]};
mirror({withdraw, Token}, ok, S) ->
    S#s{actions = lists:keydelete(Token, 1, S#s.actions)};
mirror({transfer, Mod, AState}, ok, S) ->
    S#s{adapter_state = {Mod, AState}};
mirror(_Op, _Reply, S) ->
    S.
