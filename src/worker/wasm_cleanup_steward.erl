-module(wasm_cleanup_steward).
-moduledoc """
Internal: the per-request cleanup steward.

One steward owns the cleanup interaction with the reaper for a single request,
so the guardian talks to the steward and never to the reaper directly. The full
protocol -- the ledger, the `send_request` transport, the state machine and
adoption -- is described in `test/audit/CLEANUP_STEWARD.md`.

This module is being built in stages. The guardian hands a cleanup operation
over with a correlation reference and returns to its deadline `receive`; the
steward carries it to the reaper with `gen_server:send_request/2` and, without
blocking, keeps its own loop and matches the response with
`gen_server:check_response/3` before mailing the answer to the guardian. So a
reaper that is slow or wedged stalls the steward, not the guardian. Each
operation carries a monotonic `OperationId = {RequestId, Sequence}`; `reserve`
is sequence 0 and stays synchronous, because it runs at setup before the
deadline that matters.

The reaper is addressed by its registered name, resolved at send time, so a
reaper that was restarted mid-request receives the operation and answers from
the request it reconstructed. Pinning the exact reserve-time pid, which lets an
old reaper's death trigger replacement adoption, arrives with the adoption
stage; until then a re-resolved name is what keeps a request that outlives a
reaper restart working. The reaper-side ledger, ordering and bound that the
operation id enables arrive in the stages after this one too.
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

-record(s, {request :: wasm_worker_reaper:request_id(),
            %% Next operation sequence. Reserve is 0; register, withdraw and
            %% transfer take 1, 2, 3 ... in order.
            seq = 1 :: non_neg_integer(),
            %% Outstanding `send_request' operations, each labelled with the
            %% guardian correlation, the runner to answer and the operation, so
            %% a response can be routed and, on error, answered locally.
            reqids :: gen_server:request_id_collection()}).

-spec start_link(wasm_worker_reaper:request_id()) -> {ok, pid()}.
start_link(RequestId) ->
    gen_server:start_link(?MODULE, RequestId, []).

-doc """
Claim the request's cleanup capacity and directory, via the reaper.

Synchronous, and it stays that way: it runs at setup, before the runner and
before the request deadline is being enforced, so the caller waiting on it is
not the caller that owns a deadline.
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
`{cleanup_unavailable, Steward}` if the reaper is gone, so the guardian either
exits or falls back to its mirror.
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
    {reply, wasm_worker_reaper:reserve(Id, Owner, Root, RelPath), S};
handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast({forward, CorrRef, ReplyTo, Operation}, S) ->
    {noreply, send_operation(S, CorrRef, ReplyTo, Operation)};
handle_cast({complete, Guardian}, S) ->
    submit_finish(Guardian, S);
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({cleanup_orphaned, _Id}, S) ->
    %% The reaper saw the guardian die and asked the steward to finish. There is
    %% no guardian left to answer.
    submit_finish(none, S);
handle_info(Msg, S) ->
    case gen_server:check_response(Msg, S#s.reqids, true) of
        {{reply, _Reply}, {finish, Guardian}, Reqids} ->
            %% The reaper accepted the finish and owns cleanup now. The steward's
            %% work is done.
            notify(Guardian, cleanup_owned),
            {stop, normal, S#s{reqids = Reqids}};
        {{error, {_Reason, _}}, {finish, Guardian}, Reqids} ->
            %% The reaper is gone, so the guardian must clean up from its mirror.
            notify(Guardian, cleanup_unavailable),
            {stop, normal, S#s{reqids = Reqids}};
        {{reply, Reply}, {CorrRef, ReplyTo, _Op}, Reqids} ->
            ReplyTo ! {steward_reply, CorrRef, Reply},
            {noreply, S#s{reqids = Reqids}};
        {{error, {_Reason, _}}, {CorrRef, ReplyTo, Op}, Reqids} ->
            %% The reaper did not answer this operation: it was not registered,
            %% or it died before replying. Answer as the reaper would have when
            %% absent, so the guardian sees the same result the synchronous path
            %% produced.
            ReplyTo ! {steward_reply, CorrRef,
                       wasm_worker_reaper:unreachable_operation(Op)},
            {noreply, S#s{reqids = Reqids}};
        no_request ->
            {noreply, S};
        no_reply ->
            {noreply, S}
    end.

%% Submit the finish barrier to the reaper. Resolved by name at send time, and if
%% no reaper is there the guardian is told at once to fall back to its mirror.
submit_finish(Guardian, #s{request = Id, seq = Seq} = S) ->
    case whereis(wasm_worker_reaper) of
        undefined ->
            notify(Guardian, cleanup_unavailable),
            {stop, normal, S};
        Reaper ->
            Reqids = gen_server:send_request(Reaper, {apply, Id, {Id, Seq}, finish},
                                             {finish, Guardian}, S#s.reqids),
            {noreply, S#s{seq = Seq + 1, reqids = Reqids}}
    end.

notify(none, _What)      -> ok;
notify(Guardian, What)   -> Guardian ! {What, self()}, ok.

%%% ---------------------------------------------------------------- internal ---

send_operation(#s{request = Id, seq = Seq} = S, CorrRef, ReplyTo, Operation) ->
    %% Resolve the reaper by name at send time, so an operation reaches the
    %% reaper that is registered now, including a replacement that reconstructed
    %% this request after a restart. No reaper at all answers as one that is
    %% gone would.
    case whereis(wasm_worker_reaper) of
        undefined ->
            ReplyTo ! {steward_reply, CorrRef,
                       wasm_worker_reaper:unreachable_operation(Operation)},
            S;
        Reaper ->
            OperationId = {Id, Seq},
            Reqids = gen_server:send_request(
                       Reaper, {apply, Id, OperationId, Operation},
                       {CorrRef, ReplyTo, Operation}, S#s.reqids),
            S#s{seq = Seq + 1, reqids = Reqids}
    end.
