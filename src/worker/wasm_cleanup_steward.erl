-module(wasm_cleanup_steward).
-moduledoc """
Internal: the per-request cleanup steward.

One steward owns the cleanup interaction with the reaper for a single request,
so the guardian talks to the steward and never to the reaper directly. The full
protocol -- the ledger, the `send_request` transport, the state machine and
adoption -- is described in `test/audit/CLEANUP_STEWARD.md`.

This module is being built in stages. Here `register`, `withdraw` and
`transfer` are **asynchronous forwards**: the guardian hands the operation over
with a correlation reference and returns to its deadline `receive`, and the
steward is the process that blocks on the reaper and mails the reply back. So a
slow or wedged reaper stalls the steward, never the guardian, which is the whole
point of the split. `reserve` stays synchronous, because it runs once at setup
before any guest code and before the deadline clock that matters is running. The
ledger and the `send_request` transport arrive in the stages after this.
""".

-behaviour(gen_server).

-export([start_link/1, reserve/4, forward/4, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% What the guardian asks the steward to do to the reaper, and what carries
%% enough for the steward to make the call.
-type operation() :: {register, wasm_worker_adapter:action()}
                    | {withdraw, wasm_worker_adapter:token()}
                    | {transfer, module(), term()}.
-export_type([operation/0]).

-record(s, {request :: wasm_worker_reaper:request_id()}).

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

Returns at once. The steward makes the reaper call and sends
`{steward_reply, CorrRef, Reply}` to `ReplyTo`, so the guardian correlates the
answer to the runner it is holding and never blocks on the reaper itself.
""".
-spec forward(pid(), reference(), pid(), operation()) -> ok.
forward(Steward, CorrRef, ReplyTo, Operation) ->
    gen_server:cast(Steward, {forward, CorrRef, ReplyTo, Operation}).

-doc """
Stop a steward. Non-blocking, so a caller tearing a request down never waits on
a steward that is itself waiting on the reaper.
""".
-spec stop(pid()) -> ok.
stop(Steward) ->
    exit(Steward, shutdown),
    ok.

init(RequestId) ->
    {ok, #s{request = RequestId}}.

handle_call({reserve, Owner, Root, RelPath}, _From, #s{request = Id} = S) ->
    {reply, wasm_worker_reaper:reserve(Id, Owner, Root, RelPath), S};
handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast({forward, CorrRef, ReplyTo, Operation}, #s{request = Id} = S) ->
    %% The reaper call may block here; that is deliberate, and it is why the
    %% guardian handed the work over instead of making the call itself.
    ReplyTo ! {steward_reply, CorrRef, apply_operation(Id, Operation)},
    {noreply, S};
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(_Msg, S) ->
    {noreply, S}.

apply_operation(Id, {register, Action})      -> wasm_worker_reaper:register(Id, Action);
apply_operation(Id, {withdraw, Token})       -> wasm_worker_reaper:withdraw(Id, Token);
apply_operation(Id, {transfer, Mod, AState}) -> wasm_worker_reaper:transfer(Id, Mod, AState).
