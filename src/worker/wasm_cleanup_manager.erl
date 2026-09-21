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
-export([phase/0, reaper_generation/0, stats/0, requests/0, reaper/0]).
-export([start_local_cleanup/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% `admitted` is request id -> a marker; capacity is the ceiling computed once
%% from the reaper settings, so the manager and the reaper never disagree on it.
%% `reaper` is the exact `{Pid, Generation}` the manager tracks; `rmon` monitors
%% it so its death reopens recovery.
-record(s, {cap :: non_neg_integer(),
            admitted = #{} :: #{term() => true},
            phase = recovering :: recovering | ready,
            reaper = undefined :: undefined | {pid(), pos_integer()},
            rmon = undefined :: undefined | reference(),
            %% The operator view the current reaper last pushed. Served to
            %% `cleanup_stats/0'/`cleanup_requests/0' so a reaper wedged in
            %% journal I/O never stalls diagnostics.
            view = undefined :: undefined | map(),
            %% Local cleanup jobs the manager leased and monitors: monitor ref
            %% to the request id it runs. Bounded by `job_cap' (max_cleanup_jobs),
            %% with the overflow held in `lqueue' and started as slots free, so a
            %% reaper outage cannot make local cleanup an unbounded burst.
            job_cap :: non_neg_integer(),
            jobs = #{} :: #{reference() => term()},
            lqueue = [] :: [{term(), map()}]}).

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

-doc """
The operator view's per-state counts, served from the reaper's last push so it
answers even while the reaper is wedged in journal I/O.
""".
-spec stats() -> map().
stats() ->
    gen_server:call(?MODULE, stats).

-doc "The operator view's live requests, served from the reaper's last push.".
-spec requests() -> [map()].
requests() ->
    gen_server:call(?MODULE, requests).

-doc """
The hold-vs-fail decision a steward needs when its pinned reaper dies: whether a
reaper can be reached now. `{ok, Pid}` when one is registered (a supervised
restart is established first through `wasm_worker_sup:ensure_reaper/0`); `gone`
when none can be reached, so the steward stops holding and fails the operation.
""".
-spec reaper() -> {ok, pid()} | gone.
reaper() ->
    gen_server:call(?MODULE, reaper).

-doc """
Run a request's local cleanup fallback under a job lease, off the guardian.

The guardian hands over the request's complete mirror when no reaper can own the
cleanup. The manager starts a terminal replacement steward to run it and holds a
lease, so local fallback jobs share the node's `max_cleanup_jobs` bound with the
reaper's own jobs and a reaper outage cannot create an unbounded burst. Returns
once the job is leased or queued; the manager owns it from there.
""".
-spec start_local_cleanup(term(), map()) -> ok.
start_local_cleanup(RequestId, Mirror) ->
    gen_server:call(?MODULE, {start_local_cleanup, RequestId, Mirror}).

init([]) ->
    Opts = application:get_env(wasm, reaper_options, #{}),
    Jobs = wasm_worker_reaper:setting(Opts, max_cleanup_jobs),
    Cap = Jobs + wasm_worker_reaper:setting(Opts, cleanup_queue_len),
    {ok, #s{cap = Cap, job_cap = Jobs}}.

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
handle_call({start_local_cleanup, Id, Mirror}, _From, S) ->
    {reply, ok, start_or_queue_job(Id, Mirror, S)};
handle_call(phase, _From, #s{phase = P} = S) ->
    {reply, P, S};
handle_call(reaper_generation, _From, #s{reaper = {_, Gen}} = S) ->
    {reply, Gen, S};
handle_call(reaper_generation, _From, #s{reaper = undefined} = S) ->
    {reply, 0, S};
handle_call(stats, _From, #s{view = #{stats := Stats}} = S) ->
    {reply, Stats, S};
handle_call(stats, _From, #s{view = undefined} = S) ->
    {reply, #{quarantined => 0, capacity => 0, generation => 0}, S};
handle_call(requests, _From, #s{view = #{requests := Requests}} = S) ->
    {reply, Requests, S};
handle_call(requests, _From, #s{view = undefined} = S) ->
    {reply, [], S};
handle_call(reaper, _From, #s{reaper = {Pid, _}} = S) ->
    {reply, {ok, Pid}, S};
handle_call(reaper, _From, #s{reaper = undefined} = S) ->
    %% Not tracking one: a supervised reaper can be established now; otherwise
    %% (suspended, unconfigured, or the start errored) none is coming.
    Reply = case wasm_worker_sup:ensure_reaper() of
                ok ->
                    case whereis(wasm_worker_reaper) of
                        undefined -> gone;
                        Pid       -> {ok, Pid}
                    end;
                {error, _} ->
                    gone
            end,
    {reply, Reply, S};
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
handle_info({reaper_view, Pid, Gen, View}, #s{reaper = {Pid, Gen}} = S)
  when is_map(View) ->
    %% Only the tracked reaper's own generation updates the view; a straggler
    %% from an older reaper cannot overwrite the current one.
    {noreply, S#s{view = View}};
handle_info({'DOWN', Ref, process, _Pid, _Why}, #s{rmon = Ref} = S) ->
    %% The tracked reaper died; recovery is closed and its view is stale until
    %% the replacement announces and pushes again.
    {noreply, S#s{phase = recovering, reaper = undefined, rmon = undefined,
                  view = undefined}};
handle_info({'DOWN', Ref, process, _Pid, _Why}, #s{jobs = Jobs} = S)
  when is_map_key(Ref, Jobs) ->
    %% A local cleanup job finished (or died): free its lease and start the next
    %% queued one, if any.
    {noreply, job_done(Ref, S)};
handle_info(_Msg, S) ->
    {noreply, S}.

%% Start a local cleanup job now if a lease is free, otherwise queue it. The
%% guardian never waits on a slot: the manager owns the job once this returns.
start_or_queue_job(Id, Mirror, #s{jobs = Jobs, job_cap = Cap} = S)
  when map_size(Jobs) >= Cap ->
    S#s{lqueue = S#s.lqueue ++ [{Id, Mirror}]};
start_or_queue_job(Id, Mirror, S) ->
    start_job(Id, Mirror, S).

start_job(Id, Mirror, #s{jobs = Jobs} = S) ->
    {ok, Pid} = wasm_cleanup_steward_sup:start_steward(
                  {local_cleanup, Id, Mirror}),
    Ref = monitor(process, Pid),
    S#s{jobs = maps:put(Ref, Id, Jobs)}.

%% Release the finished job's lease, then start the oldest queued job if a slot
%% is now free.
job_done(Ref, #s{jobs = Jobs} = S) ->
    S1 = S#s{jobs = maps:remove(Ref, Jobs)},
    case S1#s.lqueue of
        []                    -> S1;
        [{Id, Mirror} | Rest] -> start_job(Id, Mirror, S1#s{lqueue = Rest})
    end.

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
    %% A new reaper's view has not arrived yet; drop the old one so nothing
    %% stale is served under the new generation.
    S#s{phase = ready, reaper = {Pid, Gen}, rmon = Ref, view = undefined}.

drop_monitor(undefined) -> ok;
drop_monitor(Ref)       -> demonitor(Ref, [flush]), ok.
