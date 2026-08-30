-module(wasm_resource_SUITE).
-moduledoc """
Who owns a memory, and when its pages go back.

The rules under test are the ones a count could not express: two instances
sharing one memory, the same instance releasing twice, a handle that may look
at a memory but not free it, and a process killed with no chance to clean up.
Every case here corresponds to a way the node's page counter was taken below
zero, where it wrapped to 2^64-1 and refused every allocation for the rest of
the node's life.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([destroying_the_exporter_leaves_the_memory_to_the_importer/1,
         releasing_the_same_memory_twice_is_a_no_op/1,
         an_exported_memory_cannot_be_freed_through_its_handle/1,
         killing_an_instance_owner_releases_what_it_held/1,
         importing_one_memory_through_two_slots_counts_once/1,
         concurrent_growers_agree_on_the_size_and_the_charge/1,
         a_grower_that_dies_gives_its_reservation_back/1,
         a_table_and_a_global_outlive_the_process_that_made_them/1,
         a_table_goes_when_the_last_holder_lets_go/1,
         a_failed_build_gives_back_what_it_took/1,
         a_builder_killed_before_it_finishes_releases_what_it_took/1,
         instantiating_and_destroying_does_not_grow_the_store/1,
         touching_a_table_and_destroying_leaves_no_cache/1,
         a_caller_that_never_destroys_keeps_a_bounded_cache/1,
         a_trapping_start_hands_back_what_it_left_behind/1,
         two_instances_of_one_module_share_no_mutable_state/1,
         two_modules_in_one_process_do_not_borrow_each_others_functions/1,
         a_keeper_restart_keeps_the_registry/1,
         a_keeper_restart_mid_growth_leaves_the_size_it_promised/1,
         a_keeper_restart_keeps_the_ceiling_it_promised/1,
         an_aborted_growth_does_not_block_the_next_one/1,
         an_engine_restart_keeps_the_store_and_the_waiters/1,
         restarts_under_traffic_leave_nothing_behind/1]).

all() ->
    [destroying_the_exporter_leaves_the_memory_to_the_importer,
     releasing_the_same_memory_twice_is_a_no_op,
     an_exported_memory_cannot_be_freed_through_its_handle,
     killing_an_instance_owner_releases_what_it_held,
     importing_one_memory_through_two_slots_counts_once,
     concurrent_growers_agree_on_the_size_and_the_charge,
     a_grower_that_dies_gives_its_reservation_back,
     a_table_and_a_global_outlive_the_process_that_made_them,
     a_table_goes_when_the_last_holder_lets_go,
     a_failed_build_gives_back_what_it_took,
     a_builder_killed_before_it_finishes_releases_what_it_took,
     instantiating_and_destroying_does_not_grow_the_store,
     touching_a_table_and_destroying_leaves_no_cache,
     a_caller_that_never_destroys_keeps_a_bounded_cache,
     a_trapping_start_hands_back_what_it_left_behind,
     two_instances_of_one_module_share_no_mutable_state,
     two_modules_in_one_process_do_not_borrow_each_others_functions,
     a_keeper_restart_keeps_the_registry,
     a_keeper_restart_mid_growth_leaves_the_size_it_promised,
     a_keeper_restart_keeps_the_ceiling_it_promised,
     an_aborted_growth_does_not_block_the_next_one,
     an_engine_restart_keeps_the_store_and_the_waiters,
     restarts_under_traffic_leave_nothing_behind].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

%%% ------------------------------------------------------------- ownership ---

%% The exporter is not privileged. It made the memory, but an importer holds it
%% just as firmly, and destroying the maker while the importer is still running
%% must not take the pages away: the arrays stay alive because the importer
%% holds a reference to them, so the accounting silently disagreed with what
%% was actually allocated.
destroying_the_exporter_leaves_the_memory_to_the_importer(_Config) ->
    Base = wasm_engine:pages_in_use(),
    {ok, Exporter} = wasm:instantiate(exports_memory(), #{}),
    {ok, Mem} = wasm:extern(Exporter, ~"m"),
    ?assertEqual(Base + 1, wasm_engine:pages_in_use()),
    {ok, Importer} = wasm:instantiate(imports_memory(),
                                      #{{~"e", ~"m"} => Mem}),

    ok = wasm:destroy(Exporter),
    ?assertEqual(Base + 1, wasm_engine:pages_in_use()),
    %% Still the importer's to read, to write and to grow.
    ok = wasm:write_memory(Importer, 0, <<7, 0, 0, 0>>),
    ?assertEqual({ok, [7]}, wasm:call(Importer, ~"read", [])),

    ok = wasm:destroy(Importer),
    ?assertEqual(Base, wasm_engine:pages_in_use()).

%% A double release is the whole reason holders are a set and not a count.
releasing_the_same_memory_twice_is_a_no_op(_Config) ->
    Base = wasm_engine:pages_in_use(),
    {ok, Mem} = wasm_memory:new(2, 4),
    ?assertEqual(Base + 2, wasm_engine:pages_in_use()),
    ok = wasm_memory:free(Mem),
    ?assertEqual(Base, wasm_engine:pages_in_use()),
    ok = wasm_memory:free(Mem),
    ok = wasm_memory:free(Mem),
    ?assertEqual(Base, wasm_engine:pages_in_use()),
    %% And the node still allocates, which a wrapped counter would refuse.
    {ok, Again} = wasm_memory:new(1, 1),
    ?assertEqual(Base + 1, wasm_engine:pages_in_use()),
    ok = wasm_memory:free(Again).

%% `wasm:extern/2' hands out a handle so another module can import the memory.
%% It is not a transfer of ownership, and `free/1' on it must not pull the
%% memory out from under the instance that is still running on it.
an_exported_memory_cannot_be_freed_through_its_handle(_Config) ->
    Base = wasm_engine:pages_in_use(),
    {ok, Inst} = wasm:instantiate(exports_memory(), #{}),
    {ok, Mem} = wasm:extern(Inst, ~"m"),
    ok = wasm_memory:free(Mem),
    ok = wasm_memory:free(Mem),
    ?assertEqual(Base + 1, wasm_engine:pages_in_use()),
    ok = wasm:write_memory(Inst, 0, <<9, 0, 0, 0>>),
    ?assertEqual({ok, [9]}, wasm:call(Inst, ~"read", [])),
    ok = wasm:destroy(Inst),
    ?assertEqual(Base, wasm_engine:pages_in_use()).

%% A killed process runs no cleanup, and killing one is the documented
%% behaviour of a worker timeout. Nothing but a monitor can release what it
%% held.
killing_an_instance_owner_releases_what_it_held(_Config) ->
    Base = wasm_engine:pages_in_use(),
    Self = self(),
    Owner = spawn(fun() ->
                      {ok, _} = wasm:instantiate(exports_memory(), #{}),
                      {ok, _} = wasm:instantiate(exports_memory(), #{}),
                      Self ! ready,
                      receive never -> ok end
                  end),
    receive ready -> ok after 5000 -> ct:fail(no_instances) end,
    ?assertEqual(Base + 2, wasm_engine:pages_in_use()),
    Ref = monitor(process, Owner),
    exit(Owner, kill),
    receive {'DOWN', Ref, _, _, _} -> ok after 5000 -> ct:fail(alive) end,
    wait_until(fun() -> wasm_engine:pages_in_use() =:= Base end, 2000).

%% One instance, one holder, however many import slots name the same memory.
%% Counting slots would release the memory on the first destroy and charge it
%% twice on the way in.
importing_one_memory_through_two_slots_counts_once(_Config) ->
    Base = wasm_engine:pages_in_use(),
    {ok, Mem} = wasm_memory:new(1, 4),
    Wat = ~"(module (import \"e\" \"a\" (memory 1 4))
                    (import \"e\" \"b\" (memory 1 4)))",
    {ok, P} = wasm_wat:module(Wat),
    {ok, Mod} = wasm_validate:module(P),
    {ok, Inst} = wasm:instantiate(Mod, #{{~"e", ~"a"} => Mem,
                                         {~"e", ~"b"} => Mem}),
    ?assertEqual(Base + 1, wasm_engine:pages_in_use()),
    ok = wasm:destroy(Inst),
    ?assertEqual(Base + 1, wasm_engine:pages_in_use()),
    ?assertEqual(0, wasm_memory:atomic_load(Mem, 0, 4)),
    ok = wasm_memory:free(Mem),
    ?assertEqual(Base, wasm_engine:pages_in_use()).

%%% ---------------------------------------------------------------- growth ---

%% Growing a shared memory publishes two cells: the chunk tuple and the size.
%% Each grower used to build its tuple from its own view and publish both
%% independently, so two of them agreed on neither. The counter ran ahead of
%% the memory, which is a leak, and a published size could name a chunk the
%% published tuple did not have, which is a crash.
concurrent_growers_agree_on_the_size_and_the_charge(_Config) ->
    N = 16,
    Base = wasm_engine:pages_in_use(),
    {ok, Mem} = wasm_memory:new(shared_limits()),
    Self = self(),
    Pids = [spawn(fun() ->
                      {ok, _, _} = wasm_memory:grow(Mem, 1),
                      Self ! {grown, self()}
                  end) || _ <- lists:seq(1, N)],
    [receive {grown, P} -> ok after 30000 -> ct:fail({stuck, P}) end
     || P <- Pids],

    ?assertEqual(1 + N, wasm_memory:size_pages(Mem)),
    ?assertEqual(Base + 1 + N, wasm_engine:pages_in_use()),
    %% Every page the published size claims has to be backed by a chunk. A
    %% short tuple shows up here and nowhere else.
    Last = (1 + N) * 65536 - 8,
    ok = wasm_memory:store(Mem, Last, 8, 16#DEAD),
    ?assertEqual(16#DEAD, wasm_memory:load(Mem, Last, 8)),
    ok = wasm_memory:free(Mem),
    ?assertEqual(Base, wasm_engine:pages_in_use()).

%% The expensive half of a growth runs outside the serialised callback, so the
%% process doing it can die there. Its reservation has to come back, and
%% whoever is queued behind it has to be let through.
a_grower_that_dies_gives_its_reservation_back(_Config) ->
    Base = wasm_engine:pages_in_use(),
    {ok, Mem} = wasm_memory:new(shared_limits()),
    Res = wasm_memory:resource(Mem),
    Self = self(),
    Grower = spawn(fun() ->
                       {ok, _GrowRef, _Old} = wasm_keeper:grow_begin(Res, 4, 64),
                       Self ! claimed,
                       receive never -> ok end
                   end),
    receive claimed -> ok after 5000 -> ct:fail(no_claim) end,
    ?assertEqual(Base + 5, wasm_engine:pages_in_use()),

    Ref = monitor(process, Grower),
    exit(Grower, kill),
    receive {'DOWN', Ref, _, _, _} -> ok after 5000 -> ct:fail(alive) end,
    wait_until(fun() -> wasm_engine:pages_in_use() =:= Base + 1 end, 2000),

    %% And the memory is still growable, which a growth slot left claimed
    %% forever would prevent.
    {ok, 1, Grown} = wasm_memory:grow(Mem, 1),
    ?assertEqual(2, wasm_memory:size_pages(Grown)),
    ok = wasm_memory:free(Grown),
    ?assertEqual(Base, wasm_engine:pages_in_use()).

%%% ---------------------------------------------------- tables and globals ---

%% A table and a mutable global are shareable in exactly the way a memory is:
%% one module exports, another imports, and both must see the same thing. Their
%% rows were tied to the creating process alone, so the exporter's process
%% exiting deleted them out from under an importer that was still running, and
%% the next `call_indirect' or `global.get' through them found nothing.
a_table_and_a_global_outlive_the_process_that_made_them(_Config) ->
    Self = self(),
    Creator = spawn(fun() ->
                        {ok, E} = wasm:instantiate(exports_table_and_global(),
                                                   #{}),
                        {ok, T} = wasm:extern(E, ~"t"),
                        {ok, G} = wasm:extern(E, ~"g"),
                        Self ! {externs, T, G},
                        receive go -> ok end
                    end),
    {T, G} = receive {externs, A, B} -> {A, B}
             after 5000 -> ct:fail(no_externs) end,
    {ok, Imp} = wasm:instantiate(imports_table_and_global(),
                                 #{{~"e", ~"t"} => T, {~"e", ~"g"} => G}),
    {ok, []} = wasm:call(Imp, ~"set_global", [42]),

    Ref = monitor(process, Creator),
    Creator ! go,
    receive {'DOWN', Ref, _, _, _} -> ok after 5000 -> ct:fail(alive) end,
    timer:sleep(100),

    %% The importer put its own function into the imported table, so this
    %% needs the row and not the dead instance behind it.
    ?assertEqual({ok, [7]}, wasm:call(Imp, ~"indirect", [])),
    ?assertEqual({ok, [42]}, wasm:call(Imp, ~"get_global", [])),
    ok = wasm:destroy(Imp).

%% The other half of the rule: outliving one holder is not outliving all of
%% them, or every table ever made would stay in the store for the life of the
%% node, which is what happened before any of them were released at all.
a_table_goes_when_the_last_holder_lets_go(_Config) ->
    Table = wasm_table:new(table_limits(), null),
    Res = wasm_table:resource(Table),
    {ok, Inst} = wasm:instantiate(imports_table_and_global(),
                                  #{{~"e", ~"t"} => Table,
                                    {~"e", ~"g"} => standalone_global()}),
    ?assertEqual(2, length(wasm_keeper:holders_of(Res))),
    ok = wasm:destroy(Inst),
    ?assertEqual([{process, self()}], wasm_keeper:holders_of(Res)),
    ok = wasm_table:release(Table, {process, self()}),
    ?assertEqual([], wasm_keeper:holders_of(Res)),
    ?assertEqual([], ets:lookup(wasm_tables, Res)).

%%% ------------------------------------------------------ build transaction ---

%% Instantiation acquires as it goes and can fail at any point in the middle.
%% A ledger threaded through the build is lost the moment it throws, because
%% the exception carries the error and not the newest value from the abandoned
%% stack, so everything acquired before the failure stayed acquired until the
%% building process itself exited. The keeper holds the ledger instead.
%%
%% Three places, because they fail differently: inside the comprehension that
%% creates the module's own memories, after the memories are built and while
%% the tables are being linked, and after everything is built while the
%% segments are being copied in.
a_failed_build_gives_back_what_it_took(_Config) ->
    Base = wasm_engine:pages_in_use(),
    Rows = wasm_keeper:resources(),

    Limit = wasm_engine:page_limit(),
    wasm_engine:set_page_limit(Base + 3),
    ?assertMatch({error, #{class := exhaustion}},
                 wasm:instantiate(two_memories(), #{})),
    wasm_engine:set_page_limit(Limit),
    baseline(Base, Rows),

    ?assertMatch({error, #{class := link}},
                 wasm:instantiate(memory_then_missing_table(), #{})),
    baseline(Base, Rows),

    ?assertMatch({error, #{class := trap}},
                 wasm:instantiate(memory_with_a_bad_segment(), #{})),
    baseline(Base, Rows).

%% The other way a build ends without finishing. Killing the builder runs no
%% rollback at all, so only the monitor on the build token releases what it had
%% taken. Driven through the same call instantiation makes, because there is no
%% way to stop a real build at a chosen point from outside it.
a_builder_killed_before_it_finishes_releases_what_it_took(_Config) ->
    Base = wasm_engine:pages_in_use(),
    Self = self(),
    Builder = spawn(fun() ->
                        Build = {build, make_ref()},
                        Holder = {Build, self()},
                        {ok, _} = wasm_memory:create(mem_limits(2),
                                                     #{holder => Holder}),
                        {ok, _} = wasm_memory:create(mem_limits(3),
                                                     #{holder => Holder}),
                        Self ! taken,
                        receive never -> ok end
                    end),
    receive taken -> ok after 5000 -> ct:fail(nothing_taken) end,
    ?assertEqual(Base + 5, wasm_engine:pages_in_use()),
    Ref = monitor(process, Builder),
    exit(Builder, kill),
    receive {'DOWN', Ref, _, _, _} -> ok after 5000 -> ct:fail(alive) end,
    wait_until(fun() -> wasm_engine:pages_in_use() =:= Base end, 2000).

%% Pages *and* rows: a table or a global acquired before the failure would show
%% up in neither the page count nor anything else.
baseline(Pages, Rows) ->
    ?assertEqual(Pages, wasm_engine:pages_in_use()),
    ?assertEqual(Rows, wasm_keeper:resources()).

%%% ------------------------------------------------------------ steady state ---

%% The page counter said nothing was in use while the store still held every
%% chunk tuple, table array and global cell ever created. Ten thousand
%% instantiate-and-destroy cycles of a 17-page Rust plugin left 20,015 rows and
%% 20 GB of live memory with `pages_in_use' reading 0, and instantiation slowed
%% from 496 to 638 us as it went. A pool instantiating per request, which is
%% what `isolation => fresh' does, would take a machine down in minutes.
%%
%% So the invariant is not that the counter returns to zero. It is that nothing
%% accumulates at all.
instantiating_and_destroying_does_not_grow_the_store(_Config) ->
    Mod = exports_all_three(),
    {ok, Warm} = wasm:instantiate(Mod, #{}),
    ok = wasm:destroy(Warm),
    Pages = wasm_engine:pages_in_use(),
    Rows = ets:info(wasm_tables, size),
    Held = wasm_keeper:resources(),
    _ = [begin
             {ok, I} = wasm:instantiate(Mod, #{}),
             ok = wasm:destroy(I)
         end || _ <- lists:seq(1, 200)],
    ?assertEqual(Pages, wasm_engine:pages_in_use()),
    ?assertEqual(Rows, ets:info(wasm_tables, size)),
    ?assertEqual(Held, wasm_keeper:resources()).

%% The store rows are only half of it. `wasm_table:array_of/1` caches a table's
%% whole array in the *calling process's* dictionary, and nothing erased it: an
%% instance per request, which is what `docs/worker.md` recommends, left one
%% array per request in the worker for as long as the worker lived.
touching_a_table_and_destroying_leaves_no_cache(_Config) ->
    Mod = compile(~"(module (table (export \"t\") 2 4 funcref)
                            (func (export \"n\") (result i32) table.size 0))"),
    _ = [begin
             {ok, I} = wasm:instantiate(Mod, #{}),
             %% Reading the table is what fills the cache. Without this the
             %% case passes against the defect as well as against the fix.
             {ok, [2]} = wasm:call(I, ~"n", []),
             ok = wasm:destroy(I)
         end || _ <- lists:seq(1, 200)],
    ?assertEqual([], [K || {{wasm_table_cache, _} = K, _} <- get()]).

%% Erasing on release only reaches the process that destroys the instance, and
%% that is often not the one that called it: a worker pool calls into instances
%% a request handler creates and destroys. Two hundred instances served left two
%% hundred arrays in the worker, one per table it had ever read.
%%
%% So the cache is bounded as well as erased. The number is not the point; that
%% it stops growing is.
a_caller_that_never_destroys_keeps_a_bounded_cache(_Config) ->
    Mod = compile(~"(module (table (export \"t\") 2 4 funcref)
                            (func (export \"n\") (result i32) table.size 0))"),
    Self = self(),
    Caller = spawn(fun() -> serve(Self) end),
    _ = [begin
             {ok, I} = wasm:instantiate(Mod, #{}),
             Caller ! {touch, I, Self},
             receive touched -> ok after 5000 -> ct:fail(no_touch) end,
             %% Destroyed here, which is the point: `wasm_table:release/2`
             %% runs in this process and never in the caller.
             ok = wasm:destroy(I)
         end || _ <- lists:seq(1, 200)],
    Caller ! {report, Self},
    Cached = receive {cached, N} -> N after 5000 -> ct:fail(no_report) end,
    ?assert(Cached =< 64).

serve(Parent) ->
    receive
        {touch, I, From} ->
            {ok, [2]} = wasm:call(I, ~"n", []),
            From ! touched,
            serve(Parent);
        {report, To} ->
            Keys = [K || {{wasm_table_cache, _} = K, _} <- get()],
            To ! {cached, length(Keys)}
    end.

%% A start function that traps keeps its instance on purpose: the specification
%% says the store keeps what instantiation wrote, and `linking.wast` requires a
%% call through a reference such a module left in an imported table to work
%% afterwards. What was wrong was that nobody was handed the instance, so its
%% memories were held until the *building process* exited, and a long-lived
%% builder that instantiates many trapping modules never gets them back.
a_trapping_start_hands_back_what_it_left_behind(_Config) ->
    Base = wasm_engine:pages_in_use(),
    Mod = compile(~"(module (memory 4 4)
                            (func $s (unreachable))
                            (start $s))"),
    {error, Err} = wasm:instantiate(Mod, #{}),
    ?assertMatch(#{class := trap}, Err),
    %% Still charged, which is the half that is deliberate.
    ?assertEqual(Base + 4, wasm_engine:pages_in_use()),
    %% And reachable, which is the half that was missing.
    Inst = maps:get(instance, maps:get(ctx, Err)),
    ok = wasm:destroy(Inst),
    ?assertEqual(Base, wasm_engine:pages_in_use()).

%%% -------------------------------------------------------------- restarts ---

%% The registry says who holds what, and it is what decides whether pages ever
%% come back. A keeper that came up with an empty one would believe the node
%% held nothing while every memory on it was still charged, and nothing would
%% ever release them.
%%
%% The supervisor owns the table for that reason, so this is mostly asserting a
%% property the ownership already gives. The monitors are the half that has to
%% be rebuilt, and they are what the second part checks.
a_keeper_restart_keeps_the_registry(_Config) ->
    Base = wasm_engine:pages_in_use(),
    {ok, Mem} = wasm_memory:new(3, 8),
    Res = wasm_memory:resource(Mem),
    Self = self(),
    Owner = spawn(fun() ->
                      {ok, M} = wasm_memory:new(2, 4),
                      Self ! {mine, wasm_memory:resource(M)},
                      receive never -> ok end
                  end),
    Owned = receive {mine, R} -> R after 5000 -> ct:fail(no_memory) end,
    ?assertEqual(Base + 5, wasm_engine:pages_in_use()),

    Pid = whereis(wasm_keeper),
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, _, _, _} -> ok after 5000 -> ct:fail(alive) end,
    wait_until(fun() -> is_pid(whereis(wasm_keeper)) andalso
                            whereis(wasm_keeper) =/= Pid end, 2000),

    %% Still known, still charged, still releasable.
    ?assertEqual([{process, self()}], wasm_keeper:holders_of(Res)),
    ?assertEqual(Base + 5, wasm_engine:pages_in_use()),

    %% And the monitors came back with it: killing the other owner still
    %% returns its pages, which is the half a restart could silently lose.
    OwnerRef = monitor(process, Owner),
    exit(Owner, kill),
    receive {'DOWN', OwnerRef, _, _, _} -> ok after 5000 -> ct:fail(alive) end,
    wait_until(fun() -> wasm_engine:pages_in_use() =:= Base + 3 end, 2000),
    ?assertEqual([], wasm_keeper:holders_of(Owned)),

    ok = wasm_memory:free(Mem),
    ?assertEqual(Base, wasm_engine:pages_in_use()).

%% `max_memory_pages` is a promise `wasm:instantiate/3` makes for the life of
%% the instance, and a keeper restart used to withdraw it. Everything else came
%% back from the registry -- the holders, the charges, the growths in flight --
%% and the ceilings did not: they lived only in the keeper's state map. An
%% instance capped at two pages refused the third before a restart and took it
%% afterwards, up to the node budget.
%%
%% So a ceiling lives in the registry beside the pages it bounds.
a_keeper_restart_keeps_the_ceiling_it_promised(_Config) ->
    %% On a fresh tree, for the reason `restarts_under_traffic_leave_nothing_
    %% behind/1` gives: the restart budget is `intensity => 5, period => 10`
    %% and it is shared with every other case here that kills something. This
    %% one spends a unit of it, and without the reset the *next* case's kill is
    %% the one the supervisor refuses.
    ok = application:stop(wasm),
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Inst} = wasm:instantiate(exports_memory(), #{},
                                  #{max_memory_pages => 2}),
    ?assertEqual({ok, [1]}, wasm:call(Inst, ~"grow", [1])),
    %% At the ceiling: the third page is refused, which is -1 to the guest.
    ?assertEqual({ok, [-1]}, wasm:call(Inst, ~"grow", [1])),

    Pid = whereis(wasm_keeper),
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, _, _, _} -> ok after 5000 -> ct:fail(alive) end,
    wait_until(fun() -> is_pid(whereis(wasm_keeper)) andalso
                            whereis(wasm_keeper) =/= Pid end, 2000),

    %% Still refused, and still two pages.
    ?assertEqual({ok, [-1]}, wasm:call(Inst, ~"grow", [1])),
    ?assertEqual({ok, [2]}, wasm:call(Inst, ~"size", [])),
    ok = wasm:destroy(Inst).

%% A growth ends three ways: committed, aborted, or the grower died. The commit
%% path and the `DOWN` handler both took the resource out of `growing`; the
%% abort path did not, and `grow_begin/3` queues behind that mark on a call with
%% no timeout. So one abort made every later growth of that memory block for
%% ever, with no error to see and nothing to time out.
%%
%% `wasm_memory:grow/3` only aborts when extending raises, which is why this
%% survived: it is on the path nothing ordinarily takes.
an_aborted_growth_does_not_block_the_next_one(_Config) ->
    Base = wasm_engine:pages_in_use(),
    {ok, Mem} = wasm_memory:new(1, 8),
    Res = wasm_memory:resource(Mem),
    {ok, GrowRef, 1} = wasm_keeper:grow_begin(Res, 4, 8),
    ok = wasm_keeper:grow_abort(Res, GrowRef),
    ?assertEqual(1, wasm_keeper:charge_of(Res)),
    %% From another process and with a deadline, because the defect is a block
    %% and asserting it from here would hang the suite instead of failing it.
    Self = self(),
    Tag = make_ref(),
    P = spawn(fun() -> Self ! {Tag, wasm_keeper:grow_begin(Res, 2, 8)} end),
    Second = receive {Tag, R} -> ?assertMatch({ok, _, 1}, R), R
             after 5000 -> exit(P, kill), ct:fail(a_second_growth_never_started)
             end,
    %% Ended explicitly rather than left to the grower's death, so the next case
    %% does not start while this memory is still mid-transaction.
    {ok, Second_Ref, _} = Second,
    ok = wasm_keeper:grow_abort(Res, Second_Ref),
    wait_until(fun() -> wasm_keeper:charge_of(Res) =:= 1 end, 2000),
    ok = wasm_memory:free(Mem),
    wait_until(fun() -> wasm_engine:pages_in_use() =:= Base end, 2000),
    ?assertEqual(Base, wasm_engine:pages_in_use()).

%% The charge moves at `grow_begin/3` and the size is published at
%% `grow_commit/4`, so a keeper that restarts between them has to account for
%% the half that already happened. It did not: `growing` started empty, the
%% memory stayed charged for pages the guest could not see, and the commit was
%% answered `ok` without publishing anything. The next grow then reported the
%% inflated charge as the size before it, which is the one thing `memory.grow`
%% promises the guest.
a_keeper_restart_mid_growth_leaves_the_size_it_promised(_Config) ->
    Base = wasm_engine:pages_in_use(),
    {ok, Mem} = wasm_memory:new(1, 8),
    Res = wasm_memory:resource(Mem),
    ?assertEqual(1, wasm_keeper:charge_of(Res)),

    %% Begun and not committed, which is where the grower sits while it
    %% allocates its chunks.
    {ok, GrowRef, 1} = wasm_keeper:grow_begin(Res, 4, 8),
    ?assertEqual(5, wasm_keeper:charge_of(Res)),

    Pid = whereis(wasm_keeper),
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, _, _, _} -> ok after 5000 -> ct:fail(alive) end,
    wait_until(fun() -> is_pid(whereis(wasm_keeper)) andalso
                            whereis(wasm_keeper) =/= Pid end, 2000),

    %% This process is alive, so the growth it started is still its own to
    %% finish: the new keeper rebuilt the transaction rather than forgetting it.
    ?assertEqual(5, wasm_keeper:charge_of(Res)),
    ?assertEqual(ok, wasm_keeper:grow_abort(Res, GrowRef)),
    ?assertEqual(1, wasm_keeper:charge_of(Res)),

    %% One kill, not two. The supervisor allows five restarts in ten seconds and
    %% this suite spends them: a second kill here took the tree down and the
    %% *next* case failed instead of this one. The other half of `adopt_growths/1`,
    %% rolling back a growth whose grower died across the restart, is left to the
    %% `DOWN` handler it shares an outcome with.
    ok = wasm_memory:free(Mem),
    wait_until(fun() -> wasm_engine:pages_in_use() =:= Base end, 2000),
    ?assertEqual(Base, wasm_engine:pages_in_use()).

%% The store holds every table's contents, every shared global and every
%% published chunk tuple, and the registry names rows in it. The waiter table
%% is where a parked agent is found. An engine that owned either would take it
%% down on restart: the registry would point at nothing, and every agent parked
%% in `memory.atomic.wait` would be unreachable for ever.
an_engine_restart_keeps_the_store_and_the_waiters(_Config) ->
    Table = wasm_table:new(table_limits(), null),
    ok = wasm_table:set(Table, 0, 42),
    MemId = make_ref(),
    Self = self(),
    Waiter = spawn(fun() ->
                       R = wasm_wait:wait(MemId, 0,
                                          fun() -> Self ! parked, equal end,
                                          10000000000),
                       Self ! {woke, R}
                   end),
    receive parked -> ok after 5000 -> ct:fail(never_parked) end,

    Pid = whereis(wasm_engine),
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, _, _, _} -> ok after 5000 -> ct:fail(alive) end,
    wait_until(fun() -> is_pid(whereis(wasm_engine)) andalso
                            whereis(wasm_engine) =/= Pid end, 2000),

    ?assertEqual(42, wasm_table:get(Table, 0)),
    ?assertEqual(1, wasm_wait:notify(MemId, 0, 1)),
    receive {woke, 0} -> ok after 5000 -> ct:fail({stranded, Waiter}) end,
    ok = wasm_table:release(Table, {process, self()}).

%% The restart cases above each stop the world first. This one does not: it
%% kills the keeper, the engine and the module cache repeatedly while
%% instances are being made, called and destroyed, which is the shape a
%% supervision tree is actually for.
%%
%% What it asserts is the invariant the whole resource model rests on: when the
%% traffic stops, nothing is left charged and nothing is left in the store.
%%
%% Within what the tree promises, which is `intensity => 5, period => 10'.
%% Killing harder than that is not a stronger test, it is a different one: the
%% first version killed three children six times in a quarter of a second, the
%% supervisor gave up as it is designed to, and the application went down
%% taking the tables with it. That is the tree working.
restarts_under_traffic_leave_nothing_behind(Config) ->
    %% On a fresh tree, because a supervisor's restart budget is shared with
    %% every other case that kills something and this one spends four of it.
    %% Run after the other restart cases without this, the tree gives up part
    %% way through, the tables go, and the failure says nothing about the
    %% resource model.
    ok = application:stop(wasm),
    {ok, _} = application:ensure_all_started(wasm),
    Mod = exports_all_three(),
    Pages = wasm_engine:pages_in_use(),
    Rows = ets:info(wasm_tables, size),
    Self = self(),
    Workers = [spawn(fun() -> traffic(Mod, 60), Self ! {done, self()} end)
               || _ <- lists:seq(1, 4)],
    _ = [begin timer:sleep(300), kill(N) end
         || N <- [wasm_keeper, wasm_module_cache, wasm_engine, wasm_keeper]],
    [receive {done, P} -> ok after 60000 -> ct:fail({stuck, P}) end
     || P <- Workers],
    %% Everything the traffic held is gone, whatever the restarts did to the
    %% bookkeeping in between.
    settled(fun() -> wasm_engine:pages_in_use() end, Pages, pages),
    settled(fun() -> ets:info(wasm_tables, size) end, Rows, rows),
    _ = Config,
    ok.

%% Fails with the numbers rather than with `timeout', because "something is
%% still held" is only useful if it says how much.
settled(F, Want, What) ->
    try wait_until(fun() -> F() =< Want end, 5000)
    catch _:_ -> ct:fail({What, expected_at_most, Want, got, F()})
    end.

kill(Name) ->
    case whereis(Name) of
        undefined -> ok;
        Pid -> exit(Pid, kill), ok
    end.

%% A failure here is a value, not a crash: a call landing while the keeper is
%% being restarted is refused, and that is the behaviour rather than a defect.
traffic(_Mod, 0) -> ok;
traffic(Mod, N) ->
    case wasm:instantiate(Mod, #{}) of
        {ok, I} ->
            _ = wasm:call(I, ~"m", []),
            try wasm:destroy(I) catch _:_ -> ok end;
        {error, _} ->
            ok
    end,
    traffic(Mod, N - 1).

%%% --------------------------------------------------------------- fixtures ---

exports_memory() ->
    compile(~"(module (memory (export \"m\") 1 8)
                (func (export \"read\") (result i32) (i32.const 0) (i32.load))
                (func (export \"grow\") (param i32) (result i32)
                  (memory.grow (local.get 0)))
                (func (export \"size\") (result i32) (memory.size)))").

imports_memory() ->
    compile(~"(module (import \"e\" \"m\" (memory 1 8))
                (func (export \"read\") (result i32) (i32.const 0) (i32.load)))").

exports_table_and_global() ->
    compile(~"(module (table (export \"t\") 2 4 funcref)
                      (global (export \"g\") (mut i32) (i32.const 0)))").

imports_table_and_global() ->
    compile(~"(module
                (import \"e\" \"t\" (table 2 4 funcref))
                (import \"e\" \"g\" (global $g (mut i32)))
                (type $r (func (result i32)))
                (func $mine (result i32) (i32.const 7))
                (elem (i32.const 1) $mine)
                (func (export \"set_global\") (param i32)
                  (local.get 0) (global.set $g))
                (func (export \"get_global\") (result i32) (global.get $g))
                (func (export \"indirect\") (result i32)
                  (i32.const 1) (call_indirect (type $r))))").

%% One of each kind of row: a chunk tuple for the exported memory, an array for
%% the table, a cell for the mutable global.
exports_all_three() ->
    compile(~"(module (memory (export \"m\") 1 8)
                      (table (export \"t\") 2 4 funcref)
                      (global (export \"g\") (mut i32) (i32.const 0)))").

two_memories() ->
    compile(~"(module (memory 2 2) (memory 2 2))").

memory_then_missing_table() ->
    compile(~"(module (import \"e\" \"t\" (table 1 4 funcref))
                      (memory 1 2)
                      (global (mut i32) (i32.const 0)))").

memory_with_a_bad_segment() ->
    compile(~"(module (memory 1 1) (data (i32.const 100000) \"x\"))").

standalone_global() ->
    {ok, E} = wasm:instantiate(exports_table_and_global(), #{}),
    {ok, G} = wasm:extern(E, ~"g"),
    G.

%% The functions a module owns are built once per module and shared by every
%% instance of it, because nothing in a `#fn{}' can differ between two: the
%% lowered body, the raw body and the type all belong to the module. That is
%% what makes instantiation cheap, and it is only safe while the *mutable*
%% halves stay apart.
%%
%% Two instances in one process, so they share the cache, each writing to its
%% own memory and its own global and reading back what it wrote.
two_instances_of_one_module_share_no_mutable_state(_Config) ->
    Mod = compile(~"""
    (module
      (memory (export "memory") 1)
      (global $g (mut i32) (i32.const 0))
      (func (export "put") (param i32)
        (i32.store (i32.const 0) (local.get 0))
        (global.set $g (local.get 0)))
      (func (export "mem") (result i32) (i32.load (i32.const 0)))
      (func (export "glob") (result i32) (global.get $g)))
    """),
    {ok, A} = wasm:instantiate(Mod, #{}),
    {ok, B} = wasm:instantiate(Mod, #{}),
    {ok, []} = wasm:call(A, ~"put", [111]),
    {ok, []} = wasm:call(B, ~"put", [222]),
    ?assertEqual({ok, [111]}, wasm:call(A, ~"mem", [])),
    ?assertEqual({ok, [222]}, wasm:call(B, ~"mem", [])),
    ?assertEqual({ok, [111]}, wasm:call(A, ~"glob", [])),
    ?assertEqual({ok, [222]}, wasm:call(B, ~"glob", [])),
    %% And a third built after both, in case the cache is filled by the last
    %% instantiation rather than the first.
    {ok, C} = wasm:instantiate(Mod, #{}),
    ?assertEqual({ok, [0]}, wasm:call(C, ~"mem", [])),
    ?assertEqual({ok, [0]}, wasm:call(C, ~"glob", [])),
    [ok = wasm:destroy(I) || I <- [A, B, C]],
    ok.

%% The other half of the same invariant: the cache holds one module, so a
%% process alternating between two must not be handed the wrong one's code.
%%
%% Without this the cache key can be dropped entirely and every other test in
%% the tree still passes, because nothing else instantiates two *different*
%% modules in one process and calls both.
two_modules_in_one_process_do_not_borrow_each_others_functions(_Config) ->
    One = compile(~"(module (func (export \"f\") (result i32) (i32.const 1)))"),
    Two = compile(~"(module (func (export \"f\") (result i32) (i32.const 2)))"),
    {ok, A} = wasm:instantiate(One, #{}),
    {ok, B} = wasm:instantiate(Two, #{}),
    ?assertEqual({ok, [1]}, wasm:call(A, ~"f", [])),
    ?assertEqual({ok, [2]}, wasm:call(B, ~"f", [])),
    %% Alternating, so a one-entry cache is evicted and refilled each time.
    [begin
         {ok, X} = wasm:instantiate(One, #{}),
         ?assertEqual({ok, [1]}, wasm:call(X, ~"f", [])),
         ok = wasm:destroy(X),
         {ok, Y} = wasm:instantiate(Two, #{}),
         ?assertEqual({ok, [2]}, wasm:call(Y, ~"f", [])),
         ok = wasm:destroy(Y)
     end || _ <- lists:seq(1, 20)],
    ok = wasm:destroy(A),
    ok = wasm:destroy(B).

compile(Wat) ->
    {ok, P} = wasm_wat:module(Wat),
    {ok, Mod} = wasm_validate:module(P),
    Mod.

shared_limits() ->
    {limits, 1, 64, true, i32}.

mem_limits(Pages) ->
    {limits, Pages, Pages, false, i32}.

%% The importer declares `(table 2 4)', and a provided table with no maximum is
%% not as permissive as one bounded at 4.
table_limits() ->
    {limits, 2, 4, false, i32}.

wait_until(Pred, 0) -> Pred() orelse ct:fail(timeout_waiting);
wait_until(Pred, Ms) ->
    case Pred() of
        true -> ok;
        false -> timer:sleep(20), wait_until(Pred, erlang:max(Ms - 20, 0))
    end.
