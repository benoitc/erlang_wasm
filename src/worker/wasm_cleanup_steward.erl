-module(wasm_cleanup_steward).
-moduledoc """
Internal: the per-request cleanup steward.

One steward owns the cleanup interaction with the reaper for a single request,
so the guardian talks to the steward and never to the reaper directly. The full
protocol -- the ledger, the `send_request` transport, the state machine and
adoption -- is described in `test/audit/CLEANUP_STEWARD.md`.

This module is being built in stages. Here it is a **synchronous relay**: each
call forwards to the reaper and replies with what the reaper returned, so
behaviour is byte-for-byte what the guardian saw when it called the reaper
itself. The topology is now in place; the async forward that stops the guardian
blocking, and the ledger and transport, arrive in the stages after it.
""".

-behaviour(gen_server).

-export([start_link/1, reserve/4, register/2, withdraw/2, transfer/3, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(s, {request :: wasm_worker_reaper:request_id()}).

-spec start_link(wasm_worker_reaper:request_id()) -> {ok, pid()}.
start_link(RequestId) ->
    gen_server:start_link(?MODULE, RequestId, []).

-doc "Claim the request's cleanup capacity and directory, via the reaper.".
-spec reserve(pid(), pid(), wasm_worker_adapter:root_id(), binary()) ->
          {ok, file:filename_all()} | {error, wasm_worker_error:worker_error()}.
reserve(Steward, Owner, Root, RelPath) ->
    gen_server:call(Steward, {reserve, Owner, Root, RelPath}, infinity).

-doc "Register a cleanup action, via the reaper.".
-spec register(pid(), wasm_worker_adapter:action()) ->
          {ok, wasm_worker_adapter:token()} |
          {error, wasm_worker_error:worker_error(), released | cleanup_failed}.
register(Steward, Action) ->
    gen_server:call(Steward, {register, Action}, infinity).

-doc "Drop a registered action, via the reaper.".
-spec withdraw(pid(), wasm_worker_adapter:token()) ->
          ok | {error, wasm_worker_error:worker_error()}.
withdraw(Steward, Token) ->
    gen_server:call(Steward, {withdraw, Token}, infinity).

-doc "Hand the adapter's state to the reaper.".
-spec transfer(pid(), module(), term()) ->
          ok | {error, wasm_worker_error:worker_error()}.
transfer(Steward, Mod, AState) ->
    gen_server:call(Steward, {transfer, Mod, AState}, infinity).

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
handle_call({register, Action}, _From, #s{request = Id} = S) ->
    {reply, wasm_worker_reaper:register(Id, Action), S};
handle_call({withdraw, Token}, _From, #s{request = Id} = S) ->
    {reply, wasm_worker_reaper:withdraw(Id, Token), S};
handle_call({transfer, Mod, AState}, _From, #s{request = Id} = S) ->
    {reply, wasm_worker_reaper:transfer(Id, Mod, AState), S};
handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(_Msg, S) ->
    {noreply, S}.
