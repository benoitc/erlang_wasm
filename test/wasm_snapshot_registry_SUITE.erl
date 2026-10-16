%% One loaded image per store key on a node, shared by its workers.
%%
%% Every case is about the moments a generation starts and ends: an image's
%% live flag and its publication, cleared and erased however its owner goes,
%% and put only for a generation the keeper still holds.
%%
%% Each case runs on a freshly started application, because several restart
%% the keeper or the whole application.
-module(wasm_snapshot_registry_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

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
     an_acquire_that_times_out_leaves_no_hold].

init_per_testcase(_Case, Config) ->
    process_flag(trap_exit, true),
    reset_env(),
    _ = application:stop(wasm),
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_testcase(_Case, _Config) ->
    _ = [try sys:resume(S) catch _:_ -> ok end || S <- [wasm_keeper]],
    reset_env(),
    _ = application:stop(wasm),
    ok.

reset_env() ->
    application:unset_env(wasm, keeper_hook).

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

publications() ->
    [K || {{wasm_snapshot, _} = K, _} <- persistent_term:get()].

now_ms() -> erlang:monotonic_time(millisecond).

wait_until(F) -> wait_until(F, 500).

wait_until(F, 0) -> ?assert(F());
wait_until(F, N) ->
    case F() of
        true -> ok;
        false -> timer:sleep(10), wait_until(F, N - 1)
    end.
