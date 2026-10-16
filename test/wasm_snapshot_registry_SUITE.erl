%% One loaded image per store key on a node, shared by its workers.
%%
%% Every case is about the moments a generation starts and ends: workers that
%% start together share one load or capture, a generation ends however its
%% owner goes, a load is cancelled at its deadline whatever it is blocked in,
%% and a report from a load the registry no longer knows is refused. The
%% kernel's own snapshot cases are in `wasm_worker_kernel_SUITE'; these use
%% the same `fake_reactor_adapter', each with a store key of its own.
%%
%% Each case runs on a freshly started application, because several restart
%% the keeper, the registry or the whole application.
-module(wasm_snapshot_registry_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(ADAPTER, fake_reactor_adapter).
%% How long anything asked to end may take to end. Generous next to what it
%% takes, and far below every deadline a case sets.
-define(BOUND, 2_000).

suite() -> [{timetrap, {seconds, 120}}].

all() ->
    [the_flag_clears_when_the_last_holder_goes,
     a_killed_owner_clears_the_flag_and_the_publication,
     the_keeper_refuses_a_memory_once_the_flag_is_clear,
     the_keeper_publishes_only_a_live_generation,
     the_keeper_erases_a_publication_it_has_no_row_for,
     an_application_stop_leaves_no_publication,
     an_acquire_that_times_out_leaves_no_hold,
     four_workers_on_a_missing_image_capture_once,
     workers_on_a_filed_image_share_one_generation,
     an_owner_killed_outright_ends_its_generation,
     an_owner_killed_after_a_registry_restart_ends_its_generation,
     an_owner_killed_while_the_keeper_is_suspended_ends_its_generation,
     an_owner_retiring_while_acquired_gives_a_new_generation,
     a_whole_application_restart_ends_a_held_generation,
     a_generation_lost_with_an_earlier_keeper_is_never_published,
     a_report_of_an_unpublished_generation_is_refused,
     a_spinning_init_ends_every_task_at_the_deadline,
     the_guard_kills_a_capturer_the_load_left_behind,
     a_successful_capture_ends_without_a_kill,
     a_capture_that_returns_an_error_leaves_no_task,
     a_capturer_over_its_heap_fails_at_once,
     a_load_process_that_dies_fails_at_once,
     a_worker_killed_mid_load_ends_every_task,
     a_worker_killed_with_the_keeper_suspended_ends_every_task,
     time_before_image_acquisition_is_not_counted,
     a_suspended_keeper_fails_a_filed_load_at_its_deadline,
     a_suspended_owner_fails_the_handoff_and_its_waiters_ask_again,
     a_suspended_registry_does_not_hold_a_worker_past_its_deadline,
     waiters_give_up_at_their_own_deadlines,
     a_loader_from_before_a_registry_restart_is_refused,
     a_refused_loader_offers_its_own_image_when_none_is_loaded,
     the_last_worker_stopping_frees_everything,
     a_worker_crash_removes_only_its_own_hold,
     a_file_replaced_while_held_is_read_by_the_next_generation,
     a_worker_with_no_store_key_keeps_its_own_image,
     a_request_after_its_generation_ended_is_invalidated].

init_per_testcase(_Case, Config) ->
    process_flag(trap_exit, true),
    reset_env(),
    _ = application:stop(wasm),
    {ok, _} = application:ensure_all_started(wasm),
    Dir = filename:join(?config(priv_dir, Config),
                        "images-" ++ integer_to_list(
                                       erlang:unique_integer([positive]))),
    ok = filelib:ensure_path(Dir),
    [{dir, Dir}, {charged, wasm_snapshot_owner:charged()},
     {rows, image_rows()} | Config].

end_per_testcase(_Case, _Config) ->
    _ = [try sys:resume(S) catch _:_ -> ok end
         || S <- [wasm_keeper, wasm_snapshot_registry]],
    reset_env(),
    _ = application:stop(wasm),
    ok.

reset_env() ->
    application:unset_env(wasm, worker_hook),
    application:unset_env(wasm, keeper_hook),
    application:unset_env(wasm, snapshot_dir).

%%% ------------------------------------------- the live flag, the keeper ---
%%
%% An image's flag and its publication, without a worker: what the owner and
%% the keeper do with them however a generation ends.

%% By the owner, first, before it gives anything back: with the keeper held,
%% the owner is still alive in its release and the flag is already clear.
the_flag_clears_when_the_last_holder_goes(_Config) ->
    {Image, _G} = image(),
    Live = wasm_snapshot:live(Image),
    ?assertEqual(1, atomics:get(Live, 1)),
    ok = sys:suspend(wasm_keeper),
    ok = wasm:release(Image),
    wait_until(fun() -> atomics:get(Live, 1) =:= 0 end),
    ?assert(is_process_alive(wasm_snapshot:owner(Image))),
    ?assertMatch({error, #{kind := snapshot_invalidated}},
                 wasm:restore(Image, #{}, #{})),
    ok = sys:resume(wasm_keeper).

%% Killed outright, the owner runs no cleanup of its own: the keeper clears
%% the flag and erases the publication when it sees the owner go. An instance
%% restored before keeps running.
a_killed_owner_clears_the_flag_and_the_publication(_Config) ->
    {Image, G} = published(),
    Live = wasm_snapshot:live(Image),
    {ok, Inst} = wasm:restore(Image, #{}, #{}),
    ok = sys:suspend(wasm_keeper),
    exit(wasm_snapshot:owner(Image), kill),
    %% Refused before the keeper has done anything: the owner is not alive.
    ?assertMatch({error, #{kind := snapshot_invalidated}},
                 wasm:restore(Image, #{}, #{})),
    ok = sys:resume(wasm_keeper),
    wait_until(fun() -> atomics:get(Live, 1) =:= 0 end),
    wait_until(fun() -> persistent_term:get({wasm_snapshot, G}, gone)
                            =:= gone end),
    ?assertMatch({ok, [_]}, wasm:call(Inst, ~"handle", [])),
    ok = wasm:destroy(Inst).

%% Between restore's check and the memory's reservation, the flag cleared by
%% a hook in the keeper: the keeper refuses the memory.
the_keeper_refuses_a_memory_once_the_flag_is_clear(_Config) ->
    {Image, _G} = image(),
    Live = wasm_snapshot:live(Image),
    application:set_env(wasm, keeper_hook,
                        fun(image_ok) -> atomics:put(Live, 1, 0);
                           (_) -> ok
                        end),
    ?assertMatch({error, #{kind := snapshot_invalidated}},
                 wasm:restore(Image, #{}, #{})),
    application:unset_env(wasm, keeper_hook),
    ok = wasm:release(Image).

%% Put only for a generation the keeper holds a live row for: never for one
%% whose owner has gone, nor for one it has never seen.
the_keeper_publishes_only_a_live_generation(_Config) ->
    {Image, G} = image(),
    ?assertEqual(stale, wasm_keeper:publish(make_ref(), Image)),
    ok = wasm:release(Image),
    wait_until(fun() -> atomics:get(wasm_snapshot:live(Image), 1) =:= 0 end),
    ?assertEqual(stale, wasm_keeper:publish(G, Image)),
    ?assertEqual([], publications()).

%% What a restart of the `wasm' supervisor leaves: publications in
%% `persistent_term' and no rows. The keeper's start is what clears them.
the_keeper_erases_a_publication_it_has_no_row_for(_Config) ->
    {Image, G} = published(),
    Live = wasm_snapshot:live(Image),
    ok = supervisor:terminate_child(wasm_keeper_sup, wasm_keeper),
    true = ets:delete(wasm_holders, G),
    {ok, _} = supervisor:restart_child(wasm_keeper_sup, wasm_keeper),
    ?assertEqual(gone, persistent_term:get({wasm_snapshot, G}, gone)),
    ?assertEqual(0, atomics:get(Live, 1)).

%% A stop has no restart behind it to sweep, so the stop does.
an_application_stop_leaves_no_publication(_Config) ->
    {_Image, _G} = published(),
    ?assertNotEqual([], publications()),
    ok = application:stop(wasm),
    ?assertEqual([], publications()).

%% An owner that does not answer in time: `gone', no reply left in the
%% mailbox, and the hold it granted late given back.
an_acquire_that_times_out_leaves_no_hold(_Config) ->
    {Image, _G} = image(),
    Owner = wasm_snapshot:owner(Image),
    Holder = spawn(fun() -> receive stop -> ok end end),
    true = erlang:suspend_process(Owner),
    T = now_ms(),
    ?assertEqual(gone, wasm_snapshot_owner:acquire(Owner, Holder, 100)),
    ?assert(now_ms() - T < 100 + ?BOUND),
    true = erlang:resume_process(Owner),
    ?assertEqual(1, wasm_snapshot_owner:holders(Owner)),
    ?assertEqual({messages, []}, process_info(self(), messages)),
    ?assertEqual(ok, wasm_snapshot_owner:acquire(Owner, Holder, 5_000)),
    ?assertEqual(2, wasm_snapshot_owner:holders(Owner)),
    Holder ! stop,
    ok = wasm:release(Image).

%%% -------------------------------------------------------------- sharing ---

%% Four workers started together on a missing image: one capture, one file,
%% one owner holding for all four, one keeper row, the budget charged once.
four_workers_on_a_missing_image_capture_once(Config) ->
    with_store(Config),
    Opts = own_key(),
    ok = ?ADAPTER:reset_captures(),
    %% The first load held until the other three are parked behind it, so
    %% the four really start together.
    Self = self(),
    Gate = once(),
    hook(fun({load, _}) ->
                 case Gate() of
                     true -> Self ! {loading, self()}, receive go -> ok end;
                     false -> ok
                 end;
            (_) -> ok
         end),
    Ps = [start_async(Opts) || _ <- lists:seq(1, 4)],
    Load = receive {loading, L} -> L end,
    wait_until(fun() -> waiters(key(Opts)) =:= 3 end),
    Load ! go,
    Ws = [W || {ok, W, _} <- await_all(Ps)],
    ?assertEqual(4, length(Ws)),
    ?assertEqual(1, ?ADAPTER:captures()),
    ?assertMatch([_], files(Config)),
    {G, Owner} = wasm_snapshot_registry:loaded(key(Opts)),
    ?assertEqual([G], lists:usort([generation(W) || W <- Ws])),
    wait_until(fun() -> wasm_snapshot_owner:holders(Owner) =:= 4 end),
    ?assertEqual([G], new_rows(Config)),
    Bytes = wasm_snapshot:bytes(wasm_snapshot_registry:image(G)),
    ?assertEqual(Bytes, wasm_snapshot_owner:charged() - charged(Config)),
    stop_all(Ws).

workers_on_a_filed_image_share_one_generation(Config) ->
    with_store(Config),
    Opts = own_key(),
    ok = file_an_image(Opts),
    ok = ?ADAPTER:reset_captures(),
    %% One loads it, and two more find it loaded.
    {ok, W1} = start(Opts),
    Ws = [W1 | [W || {ok, W, _} <- await_all([start_async(Opts)
                                               || _ <- lists:seq(1, 2)])]],
    ?assertEqual(3, length(Ws)),
    ?assertEqual(0, ?ADAPTER:captures()),
    ?assertMatch([_], lists:usort([generation(W) || W <- Ws])),
    stop_all(Ws).

%%% -------------------------------------------- invalidation and crashes ---

an_owner_killed_outright_ends_its_generation(_Config) ->
    owner_killed(fun() -> ok end, fun() -> ok end).

an_owner_killed_after_a_registry_restart_ends_its_generation(_Config) ->
    owner_killed(fun restart_registry/0, fun() -> ok end).

%% The restore is refused while the keeper cannot act: the owner is not
%% alive, and that is read without asking anybody.
an_owner_killed_while_the_keeper_is_suspended_ends_its_generation(_Config) ->
    owner_killed(fun() -> sys:suspend(wasm_keeper) end,
                 fun() -> sys:resume(wasm_keeper) end).

owner_killed(Before, AfterKill) ->
    Opts = own_key(),
    {ok, W} = start(Opts),
    {G, Owner} = wasm_snapshot_registry:loaded(key(Opts)),
    Image = wasm_snapshot_registry:image(G),
    Live = wasm_snapshot:live(Image),
    RO = restore_opts(Opts),
    {ok, Inst} = wasm:restore(Image, #{}, RO),
    ok = Before(),
    exit(Owner, kill),
    ?assertMatch({error, #{kind := snapshot_invalidated}},
                 wasm:restore(Image, #{}, RO)),
    ok = AfterKill(),
    wait_until(fun() -> atomics:get(Live, 1) =:= 0 end),
    wait_until(fun() -> wasm_snapshot_registry:image(G) =:= undefined end),
    %% Restored before the kill, and still running.
    ?assertMatch({ok, [_]}, wasm:call(Inst, ~"handle", [])),
    wait_until(fun() -> wasm_snapshot_registry:loaded(key(Opts))
                            =/= {G, Owner} end),
    {ok, W2} = start(Opts),
    ?assertNotEqual(G, generation(W2)),
    ok = wasm:destroy(Inst),
    stop_all([W, W2]).

%% The owner held at its last release, so an acquire lands behind it: the
%% worker asking finds the generation gone, asks again, and loads a new one.
an_owner_retiring_while_acquired_gives_a_new_generation(_Config) ->
    Opts = own_key(),
    {ok, W1} = start(Opts),
    {G, Owner} = wasm_snapshot_registry:loaded(key(Opts)),
    true = erlang:suspend_process(Owner),
    ok = wasm_script_worker:stop(W1),
    P = start_async(Opts),
    wait_until(fun() -> asked_to_acquire(Owner) end),
    true = erlang:resume_process(Owner),
    {ok, W2, _} = await_start(P),
    ?assertNotEqual(G, generation(W2)),
    ?assertMatch({ok, _}, wasm_script_worker:run(W2, #{})),
    stop_all([W2]).

asked_to_acquire(Owner) ->
    {messages, Ms} = process_info(Owner, messages),
    lists:any(fun({{acquire, _}, _, _}) -> true; (_) -> false end, Ms).

a_whole_application_restart_ends_a_held_generation(_Config) ->
    Opts = own_key(),
    {ok, W} = start(Opts),
    {G, _Owner} = wasm_snapshot_registry:loaded(key(Opts)),
    Image = wasm_snapshot_registry:image(G),
    Live = wasm_snapshot:live(Image),
    ok = application:stop(wasm),
    {ok, _} = application:ensure_all_started(wasm),
    ?assertEqual(undefined, wasm_snapshot_registry:image(G)),
    ?assertEqual(0, atomics:get(Live, 1)),
    ?assertMatch({error, #{kind := snapshot_invalidated}},
                 wasm:restore(Image, #{}, restore_opts(Opts))),
    ?assertEqual(row_bytes(), wasm_snapshot_owner:charged()),
    {ok, W2} = start(Opts),
    ?assertNotEqual(G, generation(W2)),
    ?assertEqual(row_bytes(), wasm_snapshot_owner:charged()),
    stop_all([W, W2]).

%% A load held just before it publishes while the whole application
%% restarts: the new keeper has no row for it and answers `stale', nothing is
%% put, and the worker loads a fresh generation within its deadline.
a_generation_lost_with_an_earlier_keeper_is_never_published(_Config) ->
    Opts = own_key(),
    Self = self(),
    Once = once(),
    hook(fun({publish, G, _Owner}) ->
                 case Once() of
                     true -> Self ! {publishing, self(), G},
                             receive go -> ok end;
                     false -> ok
                 end;
            (_) -> ok
         end),
    P = start_async(Opts#{capture_timeout => 30_000}),
    {Load, Lost} = receive {publishing, L, G0} -> {L, G0} end,
    ok = application:stop(wasm),
    {ok, _} = application:ensure_all_started(wasm),
    Load ! go,
    %% The worker's module went with the application, so its next load fails;
    %% what matters is that it fails within its deadline and never with the
    %% lost generation recorded or published.
    Got = await_start(P),
    ?assertEqual(undefined, wasm_snapshot_registry:image(Lost)),
    ?assertEqual([], publications()),
    ?assertNotMatch({Lost, _}, wasm_snapshot_registry:loaded(key(Opts))),
    case Got of
        {ok, W, _} -> ?assertNotEqual(Lost, generation(W)), stop_all([W]);
        {error, _, Took} -> ?assert(Took < 30_000)
    end.

%% `loaded/5' is refused for a generation nobody published, which is what a
%% loader from before a restart offers.
a_report_of_an_unpublished_generation_is_refused(_Config) ->
    K = make_ref(),
    {load, T} = wasm_snapshot_registry:acquire(K, deadline(5_000)),
    ?assertEqual(refused,
                 wasm_snapshot_registry:loaded(K, T, make_ref(), self(),
                                               deadline(5_000))),
    ?assertEqual(none, wasm_snapshot_registry:loaded(K)).

%%% ------------------------------------------- deadlines and cancellation ---

%% `init()' never returns: the worker fails at its deadline, and every task
%% the guard started, the guard itself, and anything the load made are gone.
a_spinning_init_ends_every_task_at_the_deadline(Config) ->
    record_tasks(),
    Opts = (own_key())#{init_call => ~"spin", capture_timeout => 300},
    T = now_ms(),
    ?assertMatch({error, #{class := worker, kind := timeout}}, start(Opts)),
    ?assert(now_ms() - T < 300 + ?BOUND),
    {Guard, Tasks} = tasks(2),
    all_dead([Guard | Tasks]),
    nothing_left(Config, key(Opts)).

%% The load's own capture timeout fires, and the load is killed before it
%% kills the capturer: the guard kills the capturer. The guard is held while
%% the load dies, so nothing else can have done it.
the_guard_kills_a_capturer_the_load_left_behind(Config) ->
    Self = self(),
    hook(fun({task, Kind, Pid}) -> Self ! {task, Kind, Pid, self()};
            (capture_timed_out) -> receive never -> ok end;
            (_) -> ok
         end),
    Opts = (own_key())#{init_call => ~"spin", capture_timeout => 300},
    P = start_async(Opts),
    {Guard, [{load, Load}, {capturer, Capturer}]} = tasks(2),
    true = erlang:suspend_process(Guard),
    ?assertMatch({error, #{kind := timeout}, _}, await_start(P)),
    all_dead([Load]),
    ?assert(is_process_alive(Capturer)),
    true = erlang:resume_process(Guard),
    all_dead([Guard, Capturer]),
    nothing_left(Config, key(Opts)).

%% The capturer exits `normal' on `done', the save and the publication come
%% after it, and the guard ends having killed nothing.
a_successful_capture_ends_without_a_kill(Config) ->
    with_store(Config),
    Self = self(),
    Tab = ets:new(capturers, [public, bag]),
    hook(fun({task, capturer, Pid} = E) ->
                 true = ets:insert(Tab, {c, Pid}),
                 Self ! {event, E, self()};
            ({publish, _, _}) ->
                 Self ! {event, {publish,
                                 [is_process_alive(C)
                                  || {c, C} <- ets:lookup(Tab, c)]}, self()};
            (E) ->
                 Self ! {event, E, self()}
         end),
    Opts = (own_key())#{capture_timeout => 5_000},
    {ok, W} = start(Opts),
    Events = drain_events(),
    [Guard] = lists:usort([G || {{task, load, _}, G} <- Events]),
    Tasks = [P || {{task, _, P}, _} <- Events],
    ?assertEqual(2, length(Tasks)),
    ?assertEqual([{publish, [false]}],
                 [E || {{publish, _} = E, _} <- Events]),
    all_dead([Guard | Tasks]),
    ?assertEqual([], [K || {{kill, _} = K, _} <- drain_events() ++ Events]),
    ?assertMatch([_], files(Config)),
    {G, Owner} = wasm_snapshot_registry:loaded(key(Opts)),
    ?assertEqual(G, generation(W)),
    wait_until(fun() -> wasm_snapshot_owner:holders(Owner) =:= 1 end),
    stop_all([W]).

a_capture_that_returns_an_error_leaves_no_task(Config) ->
    record_tasks(),
    Opts = (own_key())#{validate => refuse},
    ?assertMatch({error, #{class := adapter, kind := adapter_failure}},
                 start(Opts)),
    {Guard, Tasks} = tasks(2),
    all_dead([Guard | Tasks]),
    nothing_left(Config, key(Opts)).

%% Killed by its own `max_heap_size': `crashed' with today's diagnostics, at
%% once and not at the deadline.
a_capturer_over_its_heap_fails_at_once(Config) ->
    Opts = (own_key())#{capture_timeout => 30_000,
                        limits => #{max_heap_words => 500}},
    T = now_ms(),
    Got = start(Opts),
    ?assert(now_ms() - T < 10_000),
    ?assertMatch({error, #{class := worker, kind := crashed,
                           ctx := #{reason := ~"killed", hint := _,
                                    max_heap_words := 500}}}, Got),
    nothing_left(Config, key(Opts)).

a_load_process_that_dies_fails_at_once(Config) ->
    record_tasks(),
    Opts = (own_key())#{init_call => ~"spin", capture_timeout => 30_000},
    T = now_ms(),
    P = start_async(Opts),
    {Guard, Tasks} = tasks(2),
    [Load] = [L || {load, L} <- Tasks],
    exit(Load, boom),
    {error, Error, _} = await_start(P),
    ?assert(now_ms() - T < 10_000),
    ?assertMatch(#{class := worker, kind := crashed,
                   ctx := #{reason := ~"boom"}}, Error),
    all_dead([Guard | [Pid || {_, Pid} <- Tasks]]),
    nothing_left(Config, key(Opts)).

a_worker_killed_mid_load_ends_every_task(Config) ->
    record_tasks(),
    Opts = (own_key())#{init_call => ~"spin", capture_timeout => 30_000},
    _P = start_async(Opts),
    {Guard, Tasks} = tasks(2),
    exit(loader(key(Opts)), kill),
    all_dead([Guard | [Pid || {_, Pid} <- Tasks]]),
    nothing_left(Config, key(Opts)).

%% The load process and the owner blocked in keeper calls when the worker is
%% killed: the tasks end while the keeper is still suspended, and the owner
%% once it is resumed.
a_worker_killed_with_the_keeper_suspended_ends_every_task(Config) ->
    with_store(Config),
    Opts = (own_key())#{capture_timeout => 30_000},
    ok = file_an_image(Opts),
    Self = self(),
    hook(fun({task, Kind, Pid}) -> Self ! {task, Kind, Pid, self()};
            ({load, _}) -> ok = sys:suspend(wasm_keeper);
            (_) -> ok
         end),
    _P = start_async(Opts),
    {Guard, [{load, Load}]} = tasks(1),
    wait_until(fun() -> owners() =/= [] end),
    [Owner] = owners(),
    exit(loader(key(Opts)), kill),
    all_dead([Guard, Load]),
    ?assert(is_process_alive(Owner)),
    ok = sys:resume(wasm_keeper),
    all_dead([Owner]),
    nothing_left(Config, key(Opts)).

%% `capture_timeout' starts at image acquisition: the same delay before it
%% does not count, and inside the load it does.
time_before_image_acquisition_is_not_counted(_Config) ->
    Opts = (own_key())#{capture_timeout => 400},
    {ok, W} = start(Opts#{artifact_delay => 600}),
    stop_all([W]),
    wait_until(fun() -> wasm_snapshot_registry:loaded(key(Opts)) =:= none end),
    hook(fun({load, _}) -> timer:sleep(600); (_) -> ok end),
    ?assertMatch({error, #{kind := timeout}}, start(Opts)).

a_suspended_keeper_fails_a_filed_load_at_its_deadline(Config) ->
    with_store(Config),
    Opts = (own_key())#{capture_timeout => 500},
    ok = file_an_image(Opts),
    hook(fun({load, _}) -> ok = sys:suspend(wasm_keeper); (_) -> ok end),
    T = now_ms(),
    ?assertMatch({error, #{kind := timeout}}, start(Opts)),
    ?assert(now_ms() - T < 500 + ?BOUND),
    ok = sys:resume(wasm_keeper),
    wait_until(fun() -> owners() =:= [] end),
    nothing_left(Config, key(Opts)).

%% The owner stops answering during the loader's handoff: the loader fails by
%% its deadline, and the worker parked behind it asks again and loads.
a_suspended_owner_fails_the_handoff_and_its_waiters_ask_again(_Config) ->
    Opts = own_key(),
    K = key(Opts),
    Self = self(),
    Gate = once(),
    Suspend = once(),
    hook(fun({load, _}) ->
                 case Gate() of
                     true -> Self ! {loading, self()}, receive go -> ok end;
                     false -> ok
                 end;
            ({handoff, _G, Owner}) ->
                 case Suspend() of
                     true -> true = erlang:suspend_process(Owner),
                             Self ! {suspended, Owner};
                     false -> ok
                 end;
            (_) -> ok
         end),
    T = now_ms(),
    P1 = start_async(Opts#{capture_timeout => 1_000}),
    Load = receive {loading, L} -> L end,
    P2 = start_async(Opts#{capture_timeout => 20_000}),
    wait_until(fun() -> waiters(K) =:= 1 end),
    Load ! go,
    Owner = receive {suspended, O} -> O end,
    ?assertMatch({error, #{kind := timeout}, _}, await_start(P1)),
    ?assert(now_ms() - T < 1_000 + ?BOUND),
    {ok, W2, _} = await_start(P2),
    {G2, Owner2} = wasm_snapshot_registry:loaded(K),
    ?assertEqual(G2, generation(W2)),
    ?assertNotEqual(Owner, Owner2),
    %% A suspension ends with the process that made it, and the worker that
    %% suspended the owner has gone.
    ?assertError(badarg, erlang:resume_process(Owner)),
    stop_all([W2]).

%% `failed/2' is a cast, so a registry that is not answering cannot hold a
%% worker past its deadline.
a_suspended_registry_does_not_hold_a_worker_past_its_deadline(_Config) ->
    hook(fun({load, _}) -> ok = sys:suspend(wasm_snapshot_registry);
            (_) -> ok
         end),
    Opts = (own_key())#{init_call => ~"spin", capture_timeout => 300},
    T = now_ms(),
    ?assertMatch({error, #{kind := timeout}}, start(Opts)),
    ?assert(now_ms() - T < 300 + ?BOUND),
    ok = sys:resume(wasm_snapshot_registry).

%% Three waiters with deadlines of 300, 900 and 5,000 ms behind a loader
%% that fails twice: each of the first two gives up at its own deadline, and
%% the third, still waiting, gets the generation a third loader reports.
waiters_give_up_at_their_own_deadlines(_Config) ->
    K = make_ref(),
    T = now_ms(),
    {load, T1} = wasm_snapshot_registry:acquire(K, deadline(10_000)),
    [W300, W900, W5000] = [waiter(K, T + D) || D <- [300, 900, 5_000]],
    wait_until(fun() -> waiters(K) =:= 3 end),
    sleep_until(T + 100),
    {H2, T2} = hand_over(K, T1),
    sleep_until(T + 600),
    {H3, T3} = hand_over(K, T2),
    {timeout, At300} = result(W300),
    {timeout, At900} = result(W900),
    ct:log("gave up at ~p and ~p ms", [At300 - T, At900 - T]),
    %% Each at its own deadline: after it, and before the next thing that
    %% could have answered it.
    ?assert(At300 >= T + 300 andalso At300 < T + 900),
    ?assert(At900 >= T + 900 andalso At900 < T + 2_000),
    sleep_until(T + 2_000),
    G = make_ref(),
    persistent_term:put({wasm_snapshot, G}, published),
    try
        ok = wasm_snapshot_registry:loaded(K, T3, G, H3, deadline(5_000)),
        ?assertMatch({{ok, G, H3}, _}, result(W5000))
    after
        persistent_term:erase({wasm_snapshot, G})
    end,
    _ = [H ! stop || H <- [H2, H3]],
    ok.

%% Fail the load under `Token' and make a new process the next loader, ahead
%% of the waiters the failure sends back: the registry is held while both
%% requests are queued.
hand_over(K, Token) ->
    ok = sys:suspend(wasm_snapshot_registry),
    Self = self(),
    H = spawn(fun() ->
                      ok = wasm_snapshot_registry:failed(K, Token),
                      R = wasm_snapshot_registry:acquire(K, deadline(10_000)),
                      Self ! {handed, self(), R},
                      receive stop -> ok end
              end),
    wait_until(fun() ->
                       {message_queue_len, N} =
                           process_info(whereis(wasm_snapshot_registry),
                                        message_queue_len),
                       N >= 2
               end),
    ok = sys:resume(wasm_snapshot_registry),
    receive {handed, H, {load, T}} -> {H, T}
    after 5_000 -> ct:fail(no_hand_over)
    end.

result(W) ->
    receive {result, W, R} -> R
    after 10_000 -> ct:fail({no_result, W})
    end.

sleep_until(At) -> timer:sleep(max(0, At - now_ms())).

%%% ------------------------------------------------------------- restarts ---

%% The registry restarts while a loader captures, and a new worker becomes
%% the new registry's loader with a waiter behind it. The old loader's report
%% is refused; it waits behind the new loader and takes its generation. The
%% waiter is answered by the new loader, undisturbed.
a_loader_from_before_a_registry_restart_is_refused(Config) ->
    Opts = own_key(),
    K = key(Opts),
    Self = self(),
    hook(fun({load, _}) -> Self ! {loading, self()}, receive go -> ok end;
            ({publish, G, _}) -> Self ! {publishing, self(), G};
            (_) -> ok
         end),
    P1 = start_async(Opts),
    Load1 = receive {loading, L1} -> L1 end,
    restart_registry(),
    P2 = start_async(Opts),
    Load2 = receive {loading, L2} -> L2 end,
    P3 = start_async(Opts),
    wait_until(fun() -> waiters(K) =:= 1 end),
    Load1 ! go,
    wait_until(fun() -> waiters(K) =:= 2 end),
    Load2 ! go,
    {ok, W2, _} = await_start(P2),
    {ok, W3, _} = await_start(P3),
    {ok, W1, _} = await_start(P1),
    G1 = receive {publishing, Load1, P1G} -> P1G end,
    G2 = receive {publishing, Load2, P2G} -> P2G end,
    {G, Owner} = wasm_snapshot_registry:loaded(K),
    %% The new loader's generation, not the refused one's.
    ?assertEqual(G2, G),
    ?assertNotEqual(G1, G),
    ?assertEqual([G], lists:usort([generation(W) || W <- [W1, W2, W3]])),
    wait_until(fun() -> wasm_snapshot_owner:holders(Owner) =:= 3 end),
    %% The old loader's own generation ended when it let it go.
    wait_until(fun() -> length(new_rows(Config)) =:= 1 end),
    stop_all([W1, W2, W3]).

a_refused_loader_offers_its_own_image_when_none_is_loaded(_Config) ->
    Opts = own_key(),
    K = key(Opts),
    Self = self(),
    Gate = once(),
    hook(fun({load, _}) ->
                 case Gate() of
                     true -> Self ! {loading, self()}, receive go -> ok end;
                     false -> ok
                 end;
            ({publish, G, _}) -> Self ! {publishing, self(), G};
            (_) -> ok
         end),
    P1 = start_async(Opts),
    Load1 = receive {loading, L1} -> L1 end,
    restart_registry(),
    Load1 ! go,
    {ok, W1, _} = await_start(P1),
    G1 = receive {publishing, Load1, P1G} -> P1G end,
    {G, _Owner} = wasm_snapshot_registry:loaded(K),
    %% Its own image, offered again, not a second load.
    ?assertEqual(G1, G),
    ?assertEqual(G, generation(W1)),
    receive {publishing, _, Other} -> ct:fail({loaded_again, Other})
    after 0 -> ok
    end,
    stop_all([W1]).

%%% ------------------------------------------------------------ lifecycle ---

the_last_worker_stopping_frees_everything(Config) ->
    Opts = own_key(),
    Ws = [W || {ok, W, _} <- await_all([start_async(Opts)
                                        || _ <- lists:seq(1, 3)])],
    {G, _} = wasm_snapshot_registry:loaded(key(Opts)),
    ?assertNotEqual(undefined, wasm_snapshot_registry:image(G)),
    stop_all(Ws),
    nothing_left(Config, key(Opts)).

a_worker_crash_removes_only_its_own_hold(_Config) ->
    Opts = own_key(),
    [W1, W2] = [W || {ok, W, _} <- await_all([start_async(Opts),
                                               start_async(Opts)])],
    {_G, Owner} = wasm_snapshot_registry:loaded(key(Opts)),
    wait_until(fun() -> wasm_snapshot_owner:holders(Owner) =:= 2 end),
    exit(W1, kill),
    wait_until(fun() -> wasm_snapshot_owner:holders(Owner) =:= 1 end),
    ?assertMatch({ok, #{values := [1235]}}, wasm_script_worker:run(W2, #{})),
    stop_all([W2]).

%% While a generation is held, new workers share it whatever the file says.
%% After every worker stops, the next generation reads the file as it is
%% now: unreadable here, so it captures.
a_file_replaced_while_held_is_read_by_the_next_generation(Config) ->
    with_store(Config),
    Opts = own_key(),
    ok = file_an_image(Opts),
    {ok, W1} = start(Opts),
    G1 = generation(W1),
    [File] = files(Config),
    {ok, <<H:40/binary, B, R/binary>>} = file:read_file(File),
    ok = file:write_file(File, <<H/binary, (B bxor 255), R/binary>>),
    ok = ?ADAPTER:reset_captures(),
    {ok, W2} = start(Opts),
    ?assertEqual(G1, generation(W2)),
    ?assertEqual(0, ?ADAPTER:captures()),
    stop_all([W1, W2]),
    wait_until(fun() -> wasm_snapshot_registry:loaded(key(Opts)) =:= none end),
    {ok, W3} = start(Opts),
    ?assertNotEqual(G1, generation(W3)),
    ?assertEqual(1, ?ADAPTER:captures()),
    stop_all([W3]).

a_worker_with_no_store_key_keeps_its_own_image(_Config) ->
    Opts = #{no_key => true},
    [W1, W2] = [W || {ok, W, _} <- await_all([start_async(Opts),
                                               start_async(Opts)])],
    G1 = generation(W1),
    G2 = generation(W2),
    ?assertNotEqual(G1, G2),
    ?assertEqual([], publications()),
    ?assertMatch({ok, #{values := [1235]}}, wasm_script_worker:run(W1, #{})),
    stop_all([W1, W2]).

%%% --------------------------------------------------------- request path ---

a_request_after_its_generation_ended_is_invalidated(_Config) ->
    Opts = own_key(),
    {ok, W} = start(Opts),
    {G, Owner} = wasm_snapshot_registry:loaded(key(Opts)),
    ?assertMatch({ok, _}, wasm_script_worker:run(W, #{})),
    exit(Owner, kill),
    wait_until(fun() -> wasm_snapshot_registry:image(G) =:= undefined end),
    ?assertMatch({error, #{class := invalid, kind := snapshot_invalidated}},
                 wasm_script_worker:run(W, #{})),
    stop_all([W]).

%%% -------------------------------------------------------------- helpers ---

%% An image captured by this process, which is its only holder.
image() ->
    Path = filename:join([wasm_spec_runner:fixtures_dir(), "snapshot",
                          "reactor.wasm"]),
    {ok, Bytes} = file:read_file(Path),
    {ok, Handle} = wasm:load(Bytes),
    {ok, Init} = wasm:instantiate(Handle, #{}, #{snapshotable => true}),
    {ok, []} = wasm:call(Init, ~"init", []),
    {ok, Image} = wasm:snapshot(Init),
    ok = wasm:destroy(Init),
    {Image, wasm_snapshot:generation(Image)}.

%% The same, published as a worker's load publishes it.
published() ->
    {Image, G} = image(),
    ok = wasm_keeper:publish(G, Image),
    {Image, G}.

own_key() -> #{key => make_ref()}.

start(Opts) ->
    wasm_script_worker:start_link(?ADAPTER, Opts).

%% A worker started by another process, so a case can act while it starts.
start_async(Opts) ->
    Self = self(),
    spawn(fun() ->
                  process_flag(trap_exit, true),
                  T = now_ms(),
                  R = start(Opts),
                  case R of
                      {ok, W} -> unlink(W);
                      _ -> ok
                  end,
                  Self ! {started, self(), R, now_ms() - T}
          end).

await_start(P) ->
    receive
        {started, P, {ok, W}, Took} -> {ok, W, Took};
        {started, P, {error, E}, Took} -> {error, E, Took}
    after 60_000 -> ct:fail({no_start, P})
    end.

await_all(Ps) -> [await_start(P) || P <- Ps].

stop_all(Ws) ->
    _ = [try wasm_script_worker:stop(W) catch _:_ -> ok end || W <- Ws],
    ok.

restore_opts(Opts) ->
    {ok, A} = ?ADAPTER:artifact(Opts),
    #{imports := #{compatibility_key := CK}} = ?ADAPTER:snapshot_capability(A),
    #{compatibility_key => CK}.

key(Opts) ->
    {ok, #{module := {wasm_module, Hash}} = A} = ?ADAPTER:artifact(Opts),
    #{version := V, imports := #{compatibility_key := CK}} =
        ?ADAPTER:snapshot_capability(A),
    wasm_snapshot_store:key(Hash, V, CK, wasm_snapshot_file:image_abi()).

%% The generation a worker holds, read from its state.
generation(W) ->
    State = sys:get_state(W),
    w = element(1, State),
    wasm_snapshot:generation(element(10, State)).

%% Capture an image into the store, and let it go, so the next worker on the
%% key reads the file.
file_an_image(Opts) ->
    {ok, W} = start(Opts),
    ok = wasm_script_worker:stop(W),
    wait_until(fun() -> wasm_snapshot_registry:loaded(key(Opts)) =:= none end).

with_store(Config) ->
    application:set_env(wasm, snapshot_dir, ?config(dir, Config)).

files(Config) ->
    filelib:wildcard(filename:join(?config(dir, Config), "*.img")).

hook(F) -> application:set_env(wasm, worker_hook, F).

record_tasks() ->
    Self = self(),
    hook(fun({task, Kind, Pid}) -> Self ! {task, Kind, Pid, self()};
            (_) -> ok
         end).

%% The guard and the first `N' tasks it started.
tasks(N) -> tasks(N, undefined, []).

tasks(0, Guard, Acc) -> {Guard, lists:reverse(Acc)};
tasks(N, _Guard, Acc) ->
    receive
        {task, Kind, Pid, Guard} -> tasks(N - 1, Guard, [{Kind, Pid} | Acc])
    after 10_000 -> ct:fail({tasks_missing, N, Acc})
    end.

drain_events() ->
    receive {event, E, From} -> [{E, From} | drain_events()]
    after 200 -> []
    end.

all_dead(Pids) ->
    Ps = [P || P <- Pids, is_pid(P)] ++ [P || {_, P} <- Pids, is_pid(P)],
    Mons = [erlang:monitor(process, P) || P <- Ps],
    [receive {'DOWN', M, process, _, _} -> ok
     after ?BOUND -> ct:fail({still_alive, Ps})
     end || M <- Mons],
    ok.

%% No charge, row, holder, publication or registry entry left by a load.
nothing_left(Config, Key) ->
    wait_until(fun() -> wasm_snapshot_registry:loaded(Key) =:= none end),
    wait_until(fun() -> wasm_snapshot_owner:charged() =:= charged(Config) end),
    wait_until(fun() -> new_rows(Config) =:= [] end),
    ?assertEqual([], publications()),
    wait_until(fun() -> owners() =:= [] end).

charged(Config) -> ?config(charged, Config).

image_rows() ->
    [element(1, R) || R <- ets:tab2list(wasm_holders), tuple_size(R) =:= 5,
                      is_tuple(element(2, R)),
                      element(1, element(2, R)) =:= image].

new_rows(Config) -> new_rows_since(?config(rows, Config)).

new_rows_since(Before) -> image_rows() -- Before.

row_bytes() ->
    lists:sum([B || R <- ets:tab2list(wasm_holders), tuple_size(R) =:= 5,
                    {image, B} <- [element(2, R)]]).

publications() ->
    [K || {{wasm_snapshot, _} = K, _} <- persistent_term:get()].

%% Live owner processes, found by what they are running.
owners() ->
    [P || P <- processes(),
          {current_stacktrace, St} <- [process_info(P, current_stacktrace)],
          lists:any(fun({wasm_snapshot_owner, F, _, _}) ->
                            F =:= init orelse F =:= loop orelse F =:= drop;
                       (_) -> false
                    end, St)].

loader(Key) ->
    {loading, L, _, _, _} = maps:get(Key, maps:get(keys, registry_state())),
    L.

waiters(Key) ->
    case maps:find(Key, maps:get(keys, registry_state())) of
        {ok, {loading, _, _, _, Ws}} -> length(Ws);
        _ -> 0
    end.

registry_state() -> sys:get_state(wasm_snapshot_registry).

restart_registry() ->
    ok = supervisor:terminate_child(wasm_registry_sup, wasm_snapshot_registry),
    {ok, _} = supervisor:restart_child(wasm_registry_sup,
                                       wasm_snapshot_registry),
    ok.

%% A fun answering `true' the first time it is called, from any process.
once() ->
    Ref = atomics:new(1, []),
    fun() -> atomics:compare_exchange(Ref, 1, 0, 1) =:= ok end.

deadline(Ms) -> now_ms() + Ms.

now_ms() -> erlang:monotonic_time(millisecond).

wait_until(F) -> wait_until(F, 500).

wait_until(F, 0) ->
    ct:log("still waiting; owners: ~p",
           [[{P, process_info(P, [current_stacktrace, messages])}
             || P <- owners()]]),
    ?assert(F());
wait_until(F, N) ->
    case F() of
        true -> ok;
        false -> timer:sleep(10), wait_until(F, N - 1)
    end.

%% A registry client that reports the answer it ends with. A `retry' sends
%% it back to wait with the same deadline.
waiter(K, Deadline) ->
    Self = self(),
    spawn(fun() -> waiter_loop(Self, K, Deadline) end).

waiter_loop(Test, K, Deadline) ->
    case wasm_snapshot_registry:acquire(K, Deadline) of
        retry -> waiter_loop(Test, K, Deadline);
        Other -> Test ! {result, self(), {Other, now_ms()}}
    end.
