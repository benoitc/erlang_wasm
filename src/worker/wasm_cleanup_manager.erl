-module(wasm_cleanup_manager).
-moduledoc """
Internal: the node-wide cleanup manager.

It performs no filesystem I/O and runs no cleanup callback. Its job is to bound
how many requests may hold cleanup state at once, and later to grant cleanup-job
leases and hold the operator view, so that the reaper being slow or absent can
never let cleanup grow without a bound. See `test/audit/CLEANUP_STEWARD.md`.

Admission is keyed by request id and independent of any one steward pid, so a
steward dying does not release capacity on its own. The lease, per-request
operator view and the v2 journal arrive with the stages that route the guardian
through the manager; the capacity accounting here is the foundation they build on.

The manager is `recovering` until it has learned the current reaper's generation.
The reaper announces its generation and recovered record count by sending the
manager a message addressed to its pid, so nothing here calls into the reaper and
no module cycle is formed. A reaper-only crash restarts the reaper beneath the
manager (the supervisor is `rest_for_one`); the manager sees the monitored reaper
go down, returns to `recovering`, and reaches `ready` again on the replacement's
announcement. An announcement from an older generation is ignored.
""".

-behaviour(gen_server).

-export([start_link/0, capacity/0, admitted/0, admit/1, release/1]).
-export([phase/0, reaper_generation/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% `admitted` is request id -> a marker; capacity is the ceiling computed once
%% from the reaper settings, so the manager and the reaper never disagree on it.
%% `reaper` is the exact `{Pid, Generation}` the manager tracks; `rmon` monitors
%% it so its death reopens recovery.
-record(s, {cap :: non_neg_integer(),
            admitted = #{} :: #{term() => true},
            phase = recovering :: recovering | ready,
            reaper = undefined :: undefined | {pid(), pos_integer()},
            rmon = undefined :: undefined | reference()}).

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

-doc """
Whether the manager has learned the current reaper's generation. `recovering`
until it has, `ready` after.
""".
-spec phase() -> recovering | ready.
phase() ->
    gen_server:call(?MODULE, phase).

-doc "The generation of the reaper the manager tracks, or 0 if it tracks none.".
-spec reaper_generation() -> non_neg_integer().
reaper_generation() ->
    gen_server:call(?MODULE, reaper_generation).

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
handle_call(phase, _From, #s{phase = P} = S) ->
    {reply, P, S};
handle_call(reaper_generation, _From, #s{reaper = {_, Gen}} = S) ->
    {reply, Gen, S};
handle_call(reaper_generation, _From, #s{reaper = undefined} = S) ->
    {reply, 0, S};
handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

%% The reaper announces its generation and recovered record count once its sweep
%% is done. It reaches `ready` on a current-or-newer generation and ignores an
%% older one.
handle_info({reaper_ready, Pid, Gen, _Recovered}, S)
  when is_pid(Pid), is_integer(Gen), Gen > 0 ->
    {noreply, track_reaper(Pid, Gen, S)};
handle_info({'DOWN', Ref, process, _Pid, _Why}, #s{rmon = Ref} = S) ->
    %% The tracked reaper died; recovery is closed until its replacement announces.
    {noreply, S#s{phase = recovering, reaper = undefined, rmon = undefined}};
handle_info(_Msg, S) ->
    {noreply, S}.

%% Track the reaper that announced. An older generation is ignored; the same
%% reaper re-announcing keeps its monitor; a new pid or generation replaces the
%% monitor and the tracked inventory.
track_reaper(_Pid, Gen, #s{reaper = {_, G}} = S) when G > Gen ->
    S;
track_reaper(Pid, Gen, #s{reaper = {Pid, Gen}, rmon = R} = S) when R =/= undefined ->
    S#s{phase = ready};
track_reaper(Pid, Gen, S) ->
    ok = drop_monitor(S#s.rmon),
    Ref = monitor(process, Pid),
    S#s{phase = ready, reaper = {Pid, Gen}, rmon = Ref}.

drop_monitor(undefined) -> ok;
drop_monitor(Ref)       -> demonitor(Ref, [flush]), ok.
