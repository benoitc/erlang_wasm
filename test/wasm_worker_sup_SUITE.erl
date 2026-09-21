%% @doc The reaper as part of the application.
%%
%% Every case runs in peer nodes of its own. They set application environment
%% before `wasm' starts, and they create, kill and remove supervised children,
%% none of which may leak into the Common Test node, where
%% `wasm_worker_kernel_SUITE' and the conformance kit run their own reaper by
%% hand.
-module(wasm_worker_sup_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

suite() -> [{timetrap, {minutes, 5}}].

all() ->
    [a_worker_serves_a_request_with_nobody_starting_a_reaper,
     the_first_worker_starts_a_supervised_reaper,
     a_named_worker_starts_it_too,
     configured_roots_start_the_reaper_at_boot,
     a_default_root_that_is_not_configured_is_refused_at_start,
     suspend_and_resume_keep_configured_roots,
     a_killed_reaper_comes_back_on_the_same_root,
     reaper_options_reach_the_reaper,
     an_unknown_reaper_option_refuses_the_start,
     generated_cannot_be_set_through_reaper_options,
     cleanup_requests_names_the_guardian,
     a_supervised_reaper_kill_is_survived,
     a_manager_restart_is_survived,
     the_operator_view_answers_while_the_reaper_is_wedged,
     an_idle_fallback_root_is_removed_at_shutdown,
     a_configured_root_is_never_removed,
     a_root_with_work_left_survives_shutdown,
     two_nodes_never_share_a_fallback_root].

%%% --------------------------------------------------------------- cases ---

%% The whole point of shipping the kernel: an application that depends on
%% `wasm' starts a worker and gets an answer. Before the reaper was supervised
%% this answered `{error, #{kind := no_reaper}}'.
a_worker_serves_a_request_with_nobody_starting_a_reaper(_Config) ->
    with_peer(#{}, fun(H) -> ok = on(H, fun serves_a_request/0) end).

the_first_worker_starts_a_supervised_reaper(_Config) ->
    with_peer(#{}, fun(H) ->
        false = on(H, fun wasm_worker_reaper:alive/0),
        ok = on(H, fun serves_a_request/0),
        {ok, Pid} = on(H, fun reaper_child/0),
        Pid = on(H, fun() -> whereis(wasm_worker_reaper) end)
    end).

a_named_worker_starts_it_too(_Config) ->
    with_peer(#{}, fun(H) ->
        ok = on(H, fun() ->
            {ok, W} = wasm_script_worker:start_link({local, docs_named},
                                                    fake_reactor_adapter, #{}),
            {ok, _} = wasm_script_worker:run(W, echo()),
            wasm_script_worker:stop(W)
        end),
        {ok, _} = on(H, fun reaper_child/0)
    end).

configured_roots_start_the_reaper_at_boot(Config) ->
    Dir = dir(Config, "configured"),
    with_peer(#{scratch_roots => #{scratch => Dir}}, fun(H) ->
        {ok, _} = on(H, fun reaper_child/0),
        [scratch] = on(H, fun wasm_worker_reaper:roots/0),
        ok = on(H, fun serves_a_request/0)
    end).

a_default_root_that_is_not_configured_is_refused_at_start(Config) ->
    Dir = dir(Config, "production"),
    with_peer(#{scratch_roots => #{production => Dir}}, fun(H) ->
        {error, {unknown_root, scratch, [production]}} =
            on(H, fun() ->
                wasm_script_worker:start_link(fake_reactor_adapter, #{})
            end),
        ok = on(H, fun() -> serves_a_request(#{root => production}) end)
    end).

%% Suspending leaves no reaper and starting a worker does not bring one up;
%% resuming starts the configured one at once, on the configured roots, and
%% it recovers what was left in them while it was away.
suspend_and_resume_keep_configured_roots(Config) ->
    Dir = dir(Config, "resume"),
    Orphan = orphaned_request(Config),
    with_peer(#{scratch_roots => #{scratch => Dir}}, fun(H) ->
        ok = on(H, fun wasm_worker_sup:suspend_reaper/0),
        false = on(H, fun wasm_worker_reaper:alive/0),
        {error, #{kind := no_reaper}} =
            on(H, fun() -> serves_a_request(#{}, fun(R) -> R end) end),
        false = on(H, fun wasm_worker_reaper:alive/0),
        ok = plant(Orphan, Dir),
        ok = on(H, fun wasm_worker_sup:resume_reaper/0),
        [scratch] = on(H, fun wasm_worker_reaper:roots/0),
        ok = until(fun() -> not filelib:is_dir(request_dir(Orphan, Dir)) end),
        %% The record is dropped last, after everything it names is gone
        %% (`wasm_worker_reaper:handle_cast({finish, _}, _)'), so the
        %% directory disappearing does not mean the journal is clear yet.
        ok = until(fun() -> records(Dir) =:= [] end)
    end).

a_killed_reaper_comes_back_on_the_same_root(_Config) ->
    with_peer(#{}, fun(H) ->
        ok = on(H, fun serves_a_request/0),
        Root = on(H, fun fallback_root/0),
        ok = file:write_file(filename:join(Root, "marker"), <<>>),
        Old = on(H, fun() -> whereis(wasm_worker_reaper) end),
        on(H, fun() -> exit(Old, kill) end),
        ok = until(fun() ->
            case on(H, fun() -> whereis(wasm_worker_reaper) end) of
                P when is_pid(P), P =/= Old -> true;
                _                           -> false
            end
        end),
        Root = on(H, fun fallback_root/0),
        true = filelib:is_regular(filename:join(Root, "marker")),
        ok = on(H, fun serves_a_request/0)
    end).

%% One cleanup slot and no queue: a request in flight holds the slot, and a
%% second worker's request is refused rather than queued.
reaper_options_reach_the_reaper(_Config) ->
    Opts = #{max_cleanup_jobs => 1, cleanup_queue_len => 0},
    with_peer(#{reaper_options => Opts}, fun(H) ->
        ok = on(H, fun() ->
            {ok, W} = wasm_script_worker:start_link(fake_reactor_adapter, #{}),
            put(worker, W),
            {ok, _} = wasm_script_worker:submit(W, runaway()),
            ok
        end),
        {error, #{kind := cleanup_saturated}} =
            on(H, fun() -> serves_a_request(#{}, fun(R) -> R end) end)
    end).

an_unknown_reaper_option_refuses_the_start(Config) ->
    with_peer(#{reaper_options => #{bogus => 1}}, fun(H) ->
        {error, {unknown_reaper_option, [bogus]}} =
            on(H, fun() ->
                wasm_script_worker:start_link(fake_reactor_adapter, #{})
            end)
    end),
    Dir = dir(Config, "boot"),
    {error, _} = boot(#{scratch_roots => #{scratch => Dir},
                        reaper_options => #{bogus => 1}}).

%% Which roots the reaper may delete is not configuration: a `generated' key
%% in `reaper_options' is refused like any other unknown one, so no setting can
%% mark a configured directory for removal.
generated_cannot_be_set_through_reaper_options(Config) ->
    Dir = dir(Config, "generated"),
    {error, _} = boot(#{scratch_roots => #{scratch => Dir},
                        reaper_options => #{generated => [scratch]}}).

cleanup_requests_names_the_guardian(_Config) ->
    with_peer(#{}, fun(H) ->
        ok = on(H, fun() ->
            {ok, W} = wasm_script_worker:start_link(
                       fake_reactor_adapter, #{limits => #{timeout => 60_000}}),
            put(worker, W),
            {ok, _Ref} = wasm_script_worker:submit(W, runaway()),
            ok
        end),
        [#{guardian := G}] = on(H, fun() -> some_requests(50) end),
        true = is_pid(G)
    end).

%% A supervised reaper killed while a request is in flight is survived, in a peer
%% node so a broken interleaving cannot wedge CT: the replacement comes up on the
%% same root, the manager returns to `ready', and the node serves a fresh request.
%% Live-request adoption across a restart is asserted deterministically by the
%% conformance kit (`a_stale_job_is_refused_by_the_replacement`,
%% `a_restarted_reaper_adopts_a_live_request`); this proves the whole subsystem
%% recovers under a supervised kill.
a_supervised_reaper_kill_is_survived(_Config) ->
    with_peer(#{}, fun(H) ->
        ok = on(H, fun() ->
            {ok, W} = wasm_script_worker:start_link(fake_reactor_adapter, #{}),
            put(worker, W),
            {ok, _Ref} = wasm_script_worker:submit(W, runaway()),
            ok
        end),
        [#{id := _}] = on(H, fun() -> some_requests(50) end),
        Old = on(H, fun() -> whereis(wasm_worker_reaper) end),
        on(H, fun() -> exit(whereis(wasm_worker_reaper), kill) end),
        ok = until(fun() ->
            case on(H, fun() -> whereis(wasm_worker_reaper) end) of
                P when is_pid(P), P =/= Old -> true;
                _                           -> false
            end
        end),
        ok = until(fun() ->
            on(H, fun() -> wasm_cleanup_manager:phase() end) =:= ready
        end),
        ok = on(H, fun serves_a_request/0)
    end).

%% Killing the manager restarts it and, under `rest_for_one', the reaper beneath
%% it. The subsystem recovers -- the manager returns to `ready' and the node
%% serves a fresh request -- so a manager crash does not strand the node.
a_manager_restart_is_survived(_Config) ->
    with_peer(#{}, fun(H) ->
        ok = on(H, fun serves_a_request/0),
        Old = on(H, fun() -> whereis(wasm_cleanup_manager) end),
        on(H, fun() -> exit(whereis(wasm_cleanup_manager), kill) end),
        ok = until(fun() ->
            case on(H, fun() -> whereis(wasm_cleanup_manager) end) of
                P when is_pid(P), P =/= Old -> true;
                _                           -> false
            end
        end),
        ok = until(fun() ->
            on(H, fun() -> wasm_cleanup_manager:phase() end) =:= ready
        end),
        ok = on(H, fun serves_a_request/0)
    end).

%% The operator view is served from the manager, which holds what the reaper
%% pushed it, so a reaper stuck in journal I/O never stalls diagnostics. Here the
%% reaper is suspended outright: a call to it would block, but the manager still
%% answers.
the_operator_view_answers_while_the_reaper_is_wedged(_Config) ->
    with_peer(#{}, fun(H) ->
        ok = on(H, fun() ->
            {ok, W} = wasm_script_worker:start_link(
                       fake_reactor_adapter, #{limits => #{timeout => 60_000}}),
            put(worker, W),
            {ok, _Ref} = wasm_script_worker:submit(W, runaway()),
            ok
        end),
        [#{guardian := _}] = on(H, fun() -> some_requests(50) end),
        ok = on(H, fun() -> sys:suspend(wasm_worker_reaper), ok end),
        try
            [#{guardian := _}] =
                on(H, fun wasm_script_worker:cleanup_requests/0),
            #{generation := _} =
                on(H, fun wasm_script_worker:cleanup_stats/0)
        after
            on(H, fun() -> sys:resume(wasm_worker_reaper), ok end)
        end
    end).

an_idle_fallback_root_is_removed_at_shutdown(_Config) ->
    with_peer(#{}, fun(H) ->
        ok = on(H, fun serves_a_request/0),
        Root = on(H, fun fallback_root/0),
        true = filelib:is_dir(Root),
        ok = on(H, fun() -> application:stop(wasm) end),
        false = filelib:is_dir(Root)
    end).

a_configured_root_is_never_removed(Config) ->
    Dir = dir(Config, "kept"),
    with_peer(#{scratch_roots => #{scratch => Dir}}, fun(H) ->
        ok = on(H, fun serves_a_request/0),
        ok = on(H, fun() -> application:stop(wasm) end),
        true = filelib:is_dir(Dir)
    end).

a_root_with_work_left_survives_shutdown(_Config) ->
    with_peer(#{}, fun(H) ->
        ok = on(H, fun() ->
            {ok, W} = wasm_script_worker:start_link(
                       fake_reactor_adapter, #{limits => #{timeout => 60_000}}),
            put(worker, W),
            {ok, _Ref} = wasm_script_worker:submit(W, runaway()),
            ok
        end),
        Root = on(H, fun fallback_root/0),
        [_] = on(H, fun() -> some_requests(50) end),
        ok = on(H, fun() -> application:stop(wasm) end),
        true = filelib:is_dir(Root),
        [_ | _] = records(Root)
    end).

%% Two live nodes on the same host, both on fallback roots, each with a
%% request in flight. One is killed and another started in its place: the
%% replacement gets a root of its own, and the survivor's request ends on its
%% own deadline, in a root nobody else touched.
two_nodes_never_share_a_fallback_root(_Config) ->
    {PeerA, HA} = start_peer(#{}),
    {PeerB, HB} = start_peer(#{}),
    try
        [ok = on(H, fun() ->
                    {ok, W} = wasm_script_worker:start_link(
                                fake_reactor_adapter,
                                #{limits => #{timeout => 15000,
                                              fuel => infinity}}),
                    put(worker, W),
                    {ok, Ref} = wasm_script_worker:submit(W, runaway()),
                    put(ref, Ref),
                    ok
                 end) || H <- [HA, HB]],
        RootA = on(HA, fun fallback_root/0),
        RootB = on(HB, fun fallback_root/0),
        true = RootA =/= RootB,
        [#{id := IdB}] = on(HB, fun() -> some_requests(50) end),
        true = has_record(RootB, IdB),
        quiet(fun() -> peer:call(PeerA, erlang, halt, [0], 2000) end),
        {PeerA2, HA2} = start_peer(#{}),
        try
            ok = on(HA2, fun serves_a_request/0),
            true = RootB =/= on(HA2, fun fallback_root/0),
            {error, #{kind := timeout}} =
                on(HB, fun() ->
                    wasm_script_worker:await(get(worker), get(ref), 30000)
                end),
            true = filelib:is_dir(RootB)
        after
            quiet(fun() -> peer:stop(PeerA2) end)
        end
    after
        quiet(fun() -> peer:stop(PeerA) end),
        quiet(fun() -> peer:stop(PeerB) end)
    end.

%%% --------------------------------------------------------- in the peer ---

serves_a_request() -> serves_a_request(#{}).

serves_a_request(Opts) ->
    serves_a_request(Opts, fun({ok, _}) -> ok; (Other) -> Other end).

serves_a_request(Opts, Check) ->
    case wasm_script_worker:start_link(fake_reactor_adapter, Opts) of
        {ok, W} ->
            R = wasm_script_worker:run(W, echo()),
            ok = wasm_script_worker:stop(W),
            Check(R);
        Error ->
            Error
    end.

echo()    -> fixture(echo).
runaway() -> fixture(runaway).

fixture(Name) ->
    {ok, A} = fake_reactor_adapter:artifact(#{}),
    #{base := Base} = fake_reactor_adapter:conformance_fixtures(A),
    maps:get(Name, Base).

reaper_child() ->
    case [P || {wasm_worker_reaper, P, _, _}
                   <- supervisor:which_children(wasm_worker_sup)] of
        [P] when is_pid(P) -> {ok, P};
        Other              -> {error, Other}
    end.

%% The directory the supervised reaper was given, read from its child spec,
%% which is what a restart reuses.
fallback_root() ->
    {ok, #{start := {_, _, [Roots | _]}}} =
        supervisor:get_childspec(wasm_worker_sup, wasm_worker_reaper),
    maps:get(scratch, Roots).

%%% ------------------------------------------------------------- helpers ---

%% A request left behind by a node that died with it in flight: its request
%% directory and its journal record, in a root of its own.
orphaned_request(Config) ->
    Dir = dir(Config, "orphan"),
    {Peer, H} = start_peer(#{scratch_roots => #{scratch => Dir}}),
    ok = on(H, fun() ->
        {ok, W} = wasm_script_worker:start_link(fake_reactor_adapter, #{}),
        put(worker, W),
        {ok, _} = wasm_script_worker:submit(W, runaway()),
        ok
    end),
    [#{id := Id}] = on(H, fun() -> some_requests(50) end),
    quiet(fun() -> peer:call(Peer, erlang, halt, [0], 2000) end),
    quiet(fun() -> peer:stop(Peer) end),
    #{dir => Dir, id => Id}.

%% Moves an orphaned request into another root. The record names the root by
%% id and the path relative to it, so it is valid there as it was.
plant(#{dir := From, id := Id}, To) ->
    ok = filelib:ensure_path(filename:join(To, ".journal")),
    Rec = binary_to_list(Id) ++ ".rec",
    ok = file:rename(filename:join([From, ".journal", Rec]),
                     filename:join([To, ".journal", Rec])),
    ReqDir = "req-" ++ binary_to_list(Id),
    ok = file:rename(filename:join(From, ReqDir), filename:join(To, ReqDir)).

request_dir(#{id := Id}, Root) ->
    filename:join(Root, "req-" ++ binary_to_list(Id)).

records(Root) ->
    filelib:wildcard("*.rec", filename:join(Root, ".journal")).

has_record(Root, Id) ->
    lists:member(binary_to_list(Id) ++ ".rec", records(Root)).

dir(Config, Name) ->
    D = filename:join(?config(priv_dir, Config), Name),
    ok = filelib:ensure_path(D),
    D.

until(F) -> until(F, 100).

until(_F, 0) -> {error, timeout};
until(F, N) ->
    case F() of
        true  -> ok;
        false -> timer:sleep(100), until(F, N - 1)
    end.

%% The operator view is served from the cleanup manager, which the reaper feeds
%% with an asynchronous push, so a read right after a request appears may need a
%% moment to reflect it.
some_requests(N) ->
    case wasm_script_worker:cleanup_requests() of
        []       when N > 0 -> timer:sleep(20), some_requests(N - 1);
        Requests            -> Requests
    end.

%%% ------------------------------------------------------------ the peer ---

with_peer(Env, Fun) ->
    {Peer, H} = start_peer(Env),
    try Fun(H)
    after quiet(fun() -> peer:stop(Peer) end)
    end.

%% A peer node with `Env' set for `wasm' before it starts and the repository
%% root as its working directory, since the fixtures are named relative to it.
start_peer(Env) ->
    Paths = lists:append([["-pa", D] || D <- code:get_path()]),
    {ok, Peer, _} = peer:start_link(#{connection => standard_io,
                                      args => Paths}),
    ok = peer:call(Peer, file, set_cwd, [root()]),
    _ = [ok = peer:call(Peer, application, set_env, [wasm, K, V])
         || K := V <- Env],
    {ok, _} = peer:call(Peer, application, ensure_all_started, [wasm]),
    H = peer:call(Peer, ?MODULE, holder, []),
    {Peer, {Peer, H}}.

%% Starts `wasm' in a throwaway peer with `Env', and answers what the start
%% answered.
boot(Env) ->
    Paths = lists:append([["-pa", D] || D <- code:get_path()]),
    {ok, Peer, _} = peer:start_link(#{connection => standard_io,
                                      args => Paths}),
    try
        ok = peer:call(Peer, file, set_cwd, [root()]),
        _ = [ok = peer:call(Peer, application, set_env, [wasm, K, V])
             || K := V <- Env],
        peer:call(Peer, application, ensure_all_started, [wasm])
    after
        quiet(fun() -> peer:stop(Peer) end)
    end.

%% A process in the peer that runs what it is sent and lives between calls,
%% so a worker linked to it outlives the call that started it. It traps exits
%% so a worker that dies does not take it along; the caller sees that through
%% the worker's own answers.
holder() ->
    Self = self(),
    Pid = spawn(fun() -> process_flag(trap_exit, true), hold(Self) end),
    receive {Pid, ready} -> Pid end.

hold(Parent) ->
    Parent ! {self(), ready},
    hold_loop().

hold_loop() ->
    receive
        {run, From, Ref, Fun} ->
            From ! {Ref, try {value, Fun()} catch C:R:St -> {C, R, St} end},
            hold_loop();
        {'EXIT', _, _} ->
            hold_loop()
    end.

%% Runs Fun in the holder and returns its value; an exception there fails the
%% case here, with the peer's reason.
on({Peer, H}, Fun) ->
    case peer:call(Peer, ?MODULE, relay, [H, Fun], 120000) of
        {value, V}  -> V;
        {C, R, St}  -> erlang:raise(C, {in_peer, R}, St)
    end.

relay(H, Fun) ->
    Ref = monitor(process, H),
    H ! {run, self(), Ref, Fun},
    receive
        {Ref, Result}            -> demonitor(Ref, [flush]), Result;
        {'DOWN', Ref, _, _, Why} -> {error, {holder_died, Why}, []}
    end.

quiet(Fun) ->
    try Fun() catch _:_ -> ok end.

root() ->
    filename:absname(filename:join([code:lib_dir(wasm), "..", "..", "..",
                                    ".."])).
