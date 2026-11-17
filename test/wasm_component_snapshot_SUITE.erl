-module(wasm_component_snapshot_SUITE).
-moduledoc """
Snapshots of component instances: `wasm_component:snapshot/2` and
`restore/3`.

A component is captured once it is initialised, every core together, and
each restore replays its link with every core laid from its part of the
image. `statecore` keeps a mutable global, so a restore that carried the
state answers the next value; `twocore` links two cores, so a restore that
replayed the link answers 42.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([a_restore_starts_where_the_capture_was/1,
         a_linked_component_is_restored_with_its_link/1,
         an_undeclared_import_refuses_the_capture/1,
         a_host_resource_refuses_the_capture/1,
         an_instance_not_snapshotable_is_refused/1,
         a_busy_core_refuses_the_capture_and_keeps_no_lease/1,
         an_image_outlives_the_process_that_captured_it/1,
         a_released_image_cannot_be_restored/1,
         a_wrong_key_is_refused/1,
         references_to_a_later_core_are_laid_once_it_exists/1,
         a_restore_that_fails_at_a_later_core_leaves_nothing/1,
         an_image_past_the_budget_is_refused_and_charges_nothing/1,
         an_image_no_one_holds_gives_its_charge_back/1,
         pages_stay_charged_while_a_restored_instance_reads_them/1]).

all() ->
    [a_restore_starts_where_the_capture_was,
     a_linked_component_is_restored_with_its_link,
     an_undeclared_import_refuses_the_capture,
     a_host_resource_refuses_the_capture,
     an_instance_not_snapshotable_is_refused,
     a_busy_core_refuses_the_capture_and_keeps_no_lease,
     an_image_outlives_the_process_that_captured_it,
     a_released_image_cannot_be_restored,
     a_wrong_key_is_refused,
     references_to_a_later_core_are_laid_once_it_exists,
     a_restore_that_fails_at_a_later_core_leaves_nothing,
     an_image_past_the_budget_is_refused_and_charges_nothing,
     an_image_no_one_holds_gives_its_charge_back,
     pages_stay_charged_while_a_restored_instance_reads_them].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) ->
    ok.

-define(SNAP, #{snapshotable => true}).

%%% --------------------------------------------------------------- cases ---

%% Fail-first, for every case: `wasm_component:snapshot/2' did not exist.

%% Two bumps before the capture: each restore answers 3, and one restore's
%% bump is not seen by the next.
a_restore_starts_where_the_capture_was(_Config) ->
    {ok, I} = wasm_component:instantiate(fixture("statecore"), #{}, ?SNAP),
    {ok, 1} = bump(I),
    {ok, 2} = bump(I),
    {ok, Image} = wasm_component:snapshot(I, #{}),
    ok = wasm_component:destroy(I),
    [begin
         {ok, R} = wasm_component:restore(Image, #{}, #{}),
         ?assertEqual({ok, 3}, bump(R)),
         ?assertEqual({ok, 4}, bump(R)),
         ok = wasm_component:destroy(R)
     end || _ <- [1, 2]],
    ok.

%% `twocore''s entry core imports a function from its second core: the
%% restore links them again.
a_linked_component_is_restored_with_its_link(_Config) ->
    {ok, I} = wasm_component:instantiate(fixture("twocore"), #{}, ?SNAP),
    {ok, 42} = run(I),
    {ok, Image} = wasm_component:snapshot(I, #{}),
    ok = wasm_component:destroy(I),
    {ok, R} = wasm_component:restore(Image, #{}, #{}),
    ?assertEqual({ok, 42}, run(R)),
    ?assertEqual(2, length(maps:get(cores, R))),
    ok = wasm_component:destroy(R).

%% `asyncping' imports `local:ping/host'; until it is declared, the capture
%% is refused, naming it, and once declared it is taken.
an_undeclared_import_refuses_the_capture(_Config) ->
    Host = #{{~"local:ping/host", ~"ping"} => {async_import, {[u32], none}, fun([_]) -> ok end}},
    {ok, I} = wasm_component:instantiate(fixture("asyncping"), Host, ?SNAP),
    ?assertMatch({error, #{kind := import_not_snapshottable,
                           ctx := #{import := ~"local:ping/host"}}},
                 wasm_component:snapshot(I, #{})),
    ?assertMatch({ok, _},
                 wasm_component:snapshot(I, #{snapshot_hooks =>
                                                  #{~"local:ping/host" => stateless}})),
    ok = wasm_component:destroy(I).

a_host_resource_refuses_the_capture(_Config) ->
    {ok, I} = wasm_component:instantiate(fixture("statecore"), #{}, ?SNAP),
    _ = wasm_component:host_new(socketish, #{}),
    ?assertMatch({error, #{kind := host_resource_not_snapshottable,
                           ctx := #{tag := socketish}}},
                 wasm_component:snapshot(I, #{})),
    ok = wasm_component:destroy(I).

an_instance_not_snapshotable_is_refused(_Config) ->
    {ok, I} = wasm_component:instantiate(fixture("statecore"), #{}, #{}),
    ?assertMatch({error, #{kind := not_snapshotable}}, wasm_component:snapshot(I, #{})),
    ok = wasm_component:destroy(I).

%% The second core is in a capture of its own: the component's capture
%% answers `busy', and the first core's lease is given back.
a_busy_core_refuses_the_capture_and_keeps_no_lease(_Config) ->
    {ok, I} = wasm_component:instantiate(fixture("twocore"), #{}, ?SNAP),
    [First, Second] = maps:get(cores, I),
    ok = wasm_instance:begin_capture(Second),
    ?assertMatch({error, #{kind := busy}}, wasm_component:snapshot(I, #{})),
    ok = wasm_instance:end_capture(Second),
    ok = wasm_instance:begin_capture(First),
    ok = wasm_instance:end_capture(First),
    ?assertMatch({ok, _}, wasm_component:snapshot(I, #{})),
    ok = wasm_component:destroy(I).

%% Captured in a child that then exits: the image, acquired here, still
%% restores, and every core answers.
an_image_outlives_the_process_that_captured_it(_Config) ->
    Self = self(),
    Child = spawn(fun() ->
                          {ok, I} = wasm_component:instantiate(fixture("twocore"), #{}, ?SNAP),
                          {ok, Image} = wasm_component:snapshot(I, #{}),
                          Self ! {image, Image},
                          receive go -> ok end
                  end),
    Image = receive {image, Im} -> Im after 10000 -> ct:fail(no_image) end,
    ok = wasm_component:acquire(Image),
    Mon = monitor(process, Child),
    Child ! go,
    receive {'DOWN', Mon, process, Child, _} -> ok end,
    {ok, R} = wasm_component:restore(Image, #{}, #{}),
    ?assertEqual({ok, 42}, run(R)),
    ok = wasm_component:destroy(R),
    ok = wasm_component:release(Image).

a_released_image_cannot_be_restored(_Config) ->
    Self = self(),
    Child = spawn(fun() ->
                          {ok, I} = wasm_component:instantiate(fixture("statecore"), #{}, ?SNAP),
                          {ok, Image} = wasm_component:snapshot(I, #{}),
                          Self ! {image, Image}
                  end),
    Image = receive {image, Im} -> Im after 10000 -> ct:fail(no_image) end,
    Mon = monitor(process, Child),
    receive {'DOWN', Mon, process, Child, _} -> ok end,
    ?assertMatch({error, #{kind := snapshot_invalidated}},
                 wasm_component:restore(Image, #{}, #{})).

a_wrong_key_is_refused(_Config) ->
    {ok, I} = wasm_component:instantiate(fixture("statecore"), #{}, ?SNAP),
    {ok, Image} = wasm_component:snapshot(I, #{compatibility_key => ~"a"}),
    ?assertMatch({error, #{kind := snapshot_incompatible}},
                 wasm_component:restore(Image, #{}, #{compatibility_key => ~"b"})),
    ?assertMatch({ok, _}, wasm_component:restore(Image, #{}, #{compatibility_key => ~"a"})),
    ok = wasm_component:destroy(I).

%% `forwardref''s first core holds a reference to a function of its second,
%% in a table and in a global, and the second bumps a counter it imports from
%% the first. After a restore the calls through both reach the second core,
%% and the counter they bump is the one the first reads.
references_to_a_later_core_are_laid_once_it_exists(_Config) ->
    {ok, I} = wasm_component:instantiate(fixture("forwardref"), #{}, ?SNAP),
    {ok, _} = wasm_component:call(I, ~"setup", {[], none}, []),
    {ok, 7} = call(I, ~"via-table"),
    {ok, Image} = wasm_component:snapshot(I, #{}),
    ok = wasm_component:destroy(I),
    {ok, R} = wasm_component:restore(Image, #{}, #{}),
    ?assertEqual({ok, 7}, call(R, ~"via-table")),
    ?assertEqual({ok, 7}, call(R, ~"via-global")),
    ?assertEqual({ok, 3}, call(R, ~"count")),
    ok = wasm_component:destroy(R).

%% `twocore''s second core has a memory, which no page may hold here: its
%% restore fails after the first core is built, and neither is left.
a_restore_that_fails_at_a_later_core_leaves_nothing(_Config) ->
    {ok, I} = wasm_component:instantiate(fixture("twocore"), #{}, ?SNAP),
    {ok, Image} = wasm_component:snapshot(I, #{}),
    ok = wasm_component:destroy(I),
    Before = live_instance_tables(),
    ?assertMatch({error, _}, wasm_component:restore(Image, #{}, #{max_memory_pages => 0})),
    ?assertEqual(Before, live_instance_tables()),
    {ok, R} = wasm_component:restore(Image, #{}, #{}),
    ?assertEqual({ok, 42}, run(R)),
    ok = wasm_component:destroy(R).

an_image_past_the_budget_is_refused_and_charges_nothing(_Config) ->
    {ok, I} = wasm_component:instantiate(fixture("twocore"), #{}, ?SNAP),
    Before = wasm_snapshot_owner:charged(),
    ok = application:set_env(wasm, max_snapshot_bytes, Before + 1000),
    try
        ?assertMatch({error, #{kind := snapshot_budget}}, wasm_component:snapshot(I, #{})),
        ?assertEqual(Before, wasm_snapshot_owner:charged())
    after
        application:unset_env(wasm, max_snapshot_bytes)
    end,
    ok = wasm_component:destroy(I).

%% Captured in a child that exits with nobody else holding the image: the
%% owner goes, and the charge with it.
an_image_no_one_holds_gives_its_charge_back(_Config) ->
    Before = wasm_snapshot_owner:charged(),
    Self = self(),
    Child = spawn(fun() ->
                          {ok, I} = wasm_component:instantiate(fixture("twocore"), #{}, ?SNAP),
                          {ok, #{owner := O, bytes := B}} = wasm_component:snapshot(I, #{}),
                          Self ! {owner, O, B, wasm_snapshot_owner:charged()}
                  end),
    {Owner, Bytes, During} = receive {owner, O, B, C} -> {O, B, C} after 10000 -> ct:fail(none) end,
    ?assert(Bytes > 0),
    ?assertEqual(Before + Bytes, During),
    Mon = monitor(process, Child),
    receive {'DOWN', Mon, process, Child, _} -> ok end,
    wait_until(fun() -> wasm_snapshot_owner:holders(Owner) =:= gone end),
    wait_until(fun() -> wasm_snapshot_owner:charged() =:= Before end).

%% The image's last holder lets go while a restored instance still reads its
%% pages: they stay charged, and readable, until that instance is destroyed.
pages_stay_charged_while_a_restored_instance_reads_them(_Config) ->
    Before = wasm_snapshot_owner:charged(),
    {ok, I} = wasm_component:instantiate(fixture("twocore"), #{}, ?SNAP),
    {ok, #{owner := Owner, bytes := Bytes} = Image} = wasm_component:snapshot(I, #{}),
    ok = wasm_component:destroy(I),
    {ok, R} = wasm_component:restore(Image, #{}, #{}),
    ok = wasm_component:release(Image),
    wait_until(fun() -> wasm_snapshot_owner:holders(Owner) =:= gone end),
    ?assertEqual(Before + Bytes, wasm_snapshot_owner:charged()),
    ?assertEqual({ok, 42}, run(R)),
    ok = wasm_component:destroy(R),
    wait_until(fun() -> wasm_snapshot_owner:charged() =:= Before end).

%%% ------------------------------------------------------------- helpers ---

call(I, Name) -> wasm_component:call(I, Name, {[], u32}, []).

live_instance_tables() ->
    length([T || T <- ets:all(), ets:info(T, name) =:= wasm_instance_store]).

wait_until(Fun) -> wait_until(Fun, 100).

wait_until(Fun, 0) -> ?assert(Fun());
wait_until(Fun, N) ->
    case Fun() of
        true -> ok;
        false -> timer:sleep(50), wait_until(Fun, N - 1)
    end.

bump(I) -> wasm_component:call(I, ~"bump", {[], u32}, []).
run(I) -> wasm_component:call(I, ~"run", {[], u32}, []).

fixture(Name) ->
    {ok, Bin} = file:read_file(
                  filename:join([code:lib_dir(wasm), "..", "..", "..", "..", "test",
                                 "fixtures", "component", Name ++ ".component.wasm"])),
    Bin.
