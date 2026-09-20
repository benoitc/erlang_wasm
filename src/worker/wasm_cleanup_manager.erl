-module(wasm_cleanup_manager).
-moduledoc """
Internal: the node-wide cleanup manager.

It performs no filesystem I/O and runs no cleanup callback. Its job is to bound
how many requests may hold cleanup state at once, and later to grant cleanup-job
leases and hold the operator view, so that the reaper being slow or absent can
never let cleanup grow without a bound. See `test/audit/CLEANUP_STEWARD.md`.

Admission is keyed by request id and independent of any one steward pid, so a
steward dying does not release capacity on its own. The lease, generation and
recovery machinery in the design note arrive with the stages that route the
guardian through the manager and add the v2 journal; the capacity accounting
here is the foundation they build on.
""".

-behaviour(gen_server).

-export([start_link/0, capacity/0, admitted/0, admit/1, release/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% `admitted` is request id -> a marker; capacity is the ceiling computed once
%% from the reaper settings, so the manager and the reaper never disagree on it.
-record(s, {cap :: non_neg_integer(),
            admitted = #{} :: #{term() => true}}).

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "How many requests may hold cleanup state at once.".
-spec capacity() -> non_neg_integer().
capacity() ->
    gen_server:call(?MODULE, capacity).

-doc "How many requests currently hold admission.".
-spec admitted() -> non_neg_integer().
admitted() ->
    gen_server:call(?MODULE, admitted).

-doc """
Reserve admission for a request. `cleanup_saturated` when the node is already at
capacity. Admission is idempotent per request id.
""".
-spec admit(term()) -> ok | {error, cleanup_saturated}.
admit(RequestId) ->
    gen_server:call(?MODULE, {admit, RequestId}).

-doc "Release a request's admission. A no-op if it held none.".
-spec release(term()) -> ok.
release(RequestId) ->
    gen_server:call(?MODULE, {release, RequestId}).

init([]) ->
    Opts = application:get_env(wasm, reaper_options, #{}),
    Cap = wasm_worker_reaper:setting(Opts, max_cleanup_jobs) +
          wasm_worker_reaper:setting(Opts, cleanup_queue_len),
    {ok, #s{cap = Cap}}.

handle_call(capacity, _From, #s{cap = Cap} = S) ->
    {reply, Cap, S};
handle_call(admitted, _From, #s{admitted = A} = S) ->
    {reply, map_size(A), S};
handle_call({admit, Id}, _From, #s{admitted = A, cap = Cap} = S) ->
    case maps:is_key(Id, A) of
        true ->
            {reply, ok, S};                      %% idempotent
        false when map_size(A) >= Cap ->
            {reply, {error, cleanup_saturated}, S};
        false ->
            {reply, ok, S#s{admitted = A#{Id => true}}}
    end;
handle_call({release, Id}, _From, #s{admitted = A} = S) ->
    {reply, ok, S#s{admitted = maps:remove(Id, A)}};
handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(_Msg, S) ->
    {noreply, S}.
