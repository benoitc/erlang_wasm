-module(wasm_cleanup_steward).
-moduledoc """
Internal: the per-request cleanup steward.

One steward owns the complete cleanup mirror and operation ledger for a single
request, and is the only process that sends state-changing operations to the
reaper, so the guardian never blocks on it. The full protocol -- the ledger, the
`send_request` transport, the state machine and adoption -- is described in
`test/audit/CLEANUP_STEWARD.md`.

This module is being built in stages. The scaffolding here starts a steward and
holds its request id; the routing, ledger and reaper transport arrive with the
stage that moves the guardian's cleanup calls onto it.
""".

-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(s, {request :: term()}).

-spec start_link(term()) -> {ok, pid()}.
start_link(Request) ->
    gen_server:start_link(?MODULE, Request, []).

init(Request) ->
    {ok, #s{request = Request}}.

handle_call(_Msg, _From, S) ->
    {reply, {error, not_implemented}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(_Msg, S) ->
    {noreply, S}.
