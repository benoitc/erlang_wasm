%% What a restored memory owes, and what happens when anything stops half way.
%%
%% A memory restored from an image reads the image's pages in place and pays
%% for the pages it writes. Every case here is about the keeper's record of
%% that: what is charged for a restore, a growth and an arena extension; how
%% each transaction is finished or undone when its writer or the keeper dies at
%% any point in it; how an image lives exactly as long as a memory or a holder
%% needs it; and what a file may and may not make a node load.
%%
%% Each case runs on a freshly started application, because several kill the
%% keeper and the supervisor allows only a few restarts in a short window.
-module(wasm_shared_pages_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("wasm.hrl").
-include("wasm_exec.hrl").
-include("wasm_memory.hrl").

-define(PAGE, 65536).

suite() -> [{timetrap, {seconds, 60}}].

all() ->
    [a_restore_and_one_write_cost_three_pages,
     growth_charges_whole_chunks_and_only_new_ones,
     growth_inside_capacity_still_meets_every_limit,
     growth_of_a_memory_without_an_image_charges_whole_chunks,
     growth_refused_by_the_node_charges_nothing,
     a_killed_grower_gives_its_growth_back,
     concurrent_growers_each_get_their_own_size,
     a_restart_during_growth_inside_capacity_keeps_one_size,
     a_private_memory_grows_across_a_keeper_restart,
     published_chunks_finish_a_growth_whose_grower_died,
     an_older_retry_gets_its_own_answer,
     holder_totals_survive_a_restart,
     two_writers_wanting_one_chunk_make_one_reservation,
     a_late_claimant_gets_every_missing_chunk,
     a_refused_extension_consumes_no_slot,
     the_keeper_dies_at_every_step_of_a_growth,
     the_keeper_dies_at_every_step_of_an_extension,
     a_lost_begin_reply_is_resumed,
     a_writer_waits_through_a_slow_recovery,
     a_writer_killed_mid_transaction_is_settled,
     a_reclaim_cut_short_is_finished,
     exhaustion_leaves_every_byte_as_it_was,
     exhaustion_in_generated_code_leaves_every_byte_as_it_was,
     the_image_ledger_survives_every_cut,
     an_image_that_fails_to_build_takes_nothing,
     an_image_lives_as_long_as_a_memory_needs_it,
     a_restore_that_cannot_be_afforded_leaves_nothing,
     a_descendant_restores_its_parents_pages,
     a_file_from_the_last_release_loads,
     a_sparse_image_loads_on_a_small_node,
     a_bad_file_is_refused_before_anything_is_built,
     an_expensive_file_is_refused_as_exhaustion].

init_per_testcase(_Case, Config) ->
    _ = application:stop(wasm),
    application:unset_env(wasm, keeper_hook),
    application:unset_env(wasm, build_hook),
    application:unset_env(wasm, page_limit),
    application:unset_env(wasm, max_snapshot_bytes),
    {ok, _} = application:ensure_all_started(wasm),
    %% The node budget lives in `persistent_term' and outlives the
    %% application, so a case that lowered it would lower it for the next.
    ok = wasm_engine:set_page_limit(16384),
    Config.

end_per_testcase(_Case, _Config) ->
    ok = wasm_engine:set_page_limit(16384),
    application:unset_env(wasm, keeper_hook),
    _ = application:stop(wasm),
    application:unset_env(wasm, page_limit),
    application:unset_env(wasm, max_snapshot_bytes),
    ok.

%%% --------------------------------------------------------------- module ---

%% A module whose memory the cases fill and read: `init' writes a word at the
%% start of every page listed, and the rest are one instruction each.
pager(Min, Max, Pages) ->
    I32 = 16#7F, I64 = 16#7E,
    Init = iolist_to_binary(
             [[16#41, wasm_asm:sleb(P * ?PAGE + 8), 16#41, wasm_asm:sleb(P + 1),
               16#36, 2, 0] || P <- Pages] ++ [16#0B]),
    Bodies = [Init,
              <<16#20, 0, 16#20, 1, 16#3A, 0, 0, 16#0B>>,           % st8
              <<16#20, 0, 16#2D, 0, 0, 16#0B>>,                     % ld8
              <<16#20, 0, 16#40, 0, 16#0B>>,                        % grow
              <<16#3F, 0, 16#0B>>,                                  % size
              <<16#20, 0, 16#20, 1, 16#20, 2, 16#FC, 11, 0, 16#0B>>, % fill
              <<16#20, 0, 16#20, 1, 16#20, 2, 16#FC, 10, 0, 0, 16#0B>>, % copy
              <<16#20, 0, 16#20, 1, 16#37, 0, 0, 16#0B>>],          % st64
    Names = [~"init", ~"st", ~"ld", ~"grow", ~"size", ~"fill", ~"copy",
             ~"st64"],
    Flags = case Max of undefined -> 0; _ -> 1 end,
    wasm_asm:module(
      [wasm_asm:type_section([{[], []}, {[I32, I32], []}, {[I32], [I32]},
                              {[], [I32]}, {[I32, I32, I32], []},
                              {[I32, I64], []}]),
       wasm_asm:func_section([0, 1, 2, 2, 3, 4, 4, 5]),
       wasm_asm:memory_section(Flags, Min, Max),
       wasm_asm:export_section(
         [{N, 0, Ix} || {Ix, N} <- lists:enumerate(0, Names)]
         ++ [{~"memory", 2, 0}]),
       wasm_asm:code_section([iolist_to_binary(B) || B <- Bodies])]).

%% An image of a module with `Min' pages, a word written to each of `Pages'.
image(Min, Max, Pages) ->
    {ok, H} = wasm:load(pager(Min, Max, Pages)),
    Run = #{fuel => infinity},
    {ok, I} = wasm:instantiate(H, #{}, Run#{snapshotable => true}),
    {ok, []} = wasm:call(I, ~"init", [], Run),
    {ok, Image} = wasm:snapshot(I),
    ok = wasm:destroy(I),
    Image.

restore(Image) -> restore(Image, #{}).

restore(Image, Opts) ->
    {ok, I} = wasm:restore(Image, #{}, Opts#{fuel => infinity}),
    I.

call(I, F, Args) -> wasm:call(I, F, Args, #{fuel => infinity}).

pages() -> wasm_engine:pages_in_use().

mem(I) ->
    #mut{mems = {M}} = wasm_instance:mut(I),
    M.

row(Res) ->
    [Row] = ets:lookup(wasm_holders, Res),
    Row.

phys(Res) ->
    {_, _, _, _, #{phys := Phys}} = row(Res),
    Phys.

%% A memory over a bare image, without a snapshot, as only a test build makes.
paged(Bin, Max) ->
    {ok, M} = wasm_memory:create(#limits{min = byte_size(Bin) div ?PAGE,
                                         max = Max},
                                 #{image => wasm_memory:image_of(Bin),
                                   observable => true}),
    M.

ones(Pages) -> binary:copy(<<1>>, Pages * ?PAGE).

caught(F) ->
    try F() catch C:R -> {'EXIT', {C, R}} end.

wait_until(F) -> wait_until(F, 500).

wait_until(F, 0) -> ?assert(F());
wait_until(F, N) ->
    case F() of
        true -> ok;
        false -> timer:sleep(10), wait_until(F, N - 1)
    end.

%% The keeper killed, once, the first time it reaches `Point', and the case
%% waits for its replacement. A process holding the keeper's restart sees
%% exactly one kill.
kill_keeper_at(Point) ->
    Once = atomics:new(1, []),
    ok = application:set_env(
           wasm, keeper_hook,
           fun(P) when P =:= Point ->
                   case atomics:compare_exchange(Once, 1, 0, 1) of
                       ok -> exit(self(), kill);
                       _ -> ok
                   end;
              (_) -> ok
           end).

%% Held at `Point' until told to go, once.
hold_keeper_at(Point) ->
    Self = self(),
    Once = atomics:new(1, []),
    ok = application:set_env(
           wasm, keeper_hook,
           fun(P) when P =:= Point ->
                   case atomics:compare_exchange(Once, 1, 0, 1) of
                       ok -> Self ! {held, P}, receive go -> ok end;
                       _ -> ok
                   end;
              (_) -> ok
           end).

restarted(Old) ->
    wait_until(fun() ->
                       case whereis(wasm_keeper) of
                           undefined -> false;
                           Old -> false;
                           _ -> true
                       end
               end),
    %% And through `init/1', so recovery has run.
    _ = sys:get_state(wasm_keeper),
    ok.

%%% -------------------------------------------------------------- charges ---

%% A 40 MiB image: its page table is 80 KiB, two pages, and the first write
%% opens a 64 KiB arena chunk, one page. Three, where a copy cost 640.
a_restore_and_one_write_cost_three_pages(_Config) ->
    Image = image(640, undefined, [0, 100, 639]),
    Base = pages(),
    I = restore(Image),
    ?assertEqual(Base + 2, pages()),
    ?assertEqual({ok, []}, call(I, ~"st", [100 * ?PAGE + 3, 9])),
    ?assertEqual(Base + 3, pages()),
    ?assertEqual({ok, [101]}, call(I, ~"ld", [100 * ?PAGE + 8])),
    ok = wasm:destroy(I),
    ?assertEqual(Base, pages()).

%% A 16-page image sits on 1 MiB chunks. Growing by one allocates a chunk of
%% sixteen pages; the next fifteen fit in it.
growth_charges_whole_chunks_and_only_new_ones(_Config) ->
    Image = image(16, 64, [3]),
    I = restore(Image),
    Res = wasm_memory:resource(mem(I)),
    Base = pages(),
    ?assertEqual({ok, [16]}, call(I, ~"grow", [1])),
    ?assertEqual(Base + 16, pages()),
    ?assertEqual({ok, [17]}, call(I, ~"grow", [15])),
    ?assertEqual(Base + 16, pages()),
    ?assertEqual({ok, [32]}, call(I, ~"size", [])),
    ?assertEqual(32, wasm_keeper:charge_of(Res)),
    [?assertEqual({ok, [0]}, call(I, ~"ld", [P * ?PAGE + 77]))
     || P <- lists:seq(17, 31)],
    ok = wasm:destroy(I).

growth_inside_capacity_still_meets_every_limit(_Config) ->
    Image = image(16, 18, [3]),
    I = restore(Image),
    ?assertEqual({ok, [16]}, call(I, ~"grow", [1])),
    %% Room in the chunk, none under the declared maximum.
    ?assertEqual({ok, [-1]}, call(I, ~"grow", [2])),
    ok = wasm:destroy(I),
    %% And none under the instance's ceiling.
    J = restore(Image, #{max_memory_pages => 17}),
    ?assertEqual({ok, [16]}, call(J, ~"grow", [1])),
    ?assertEqual({ok, [-1]}, call(J, ~"grow", [1])),
    ok = wasm:destroy(J).

growth_of_a_memory_without_an_image_charges_whole_chunks(_Config) ->
    Base = pages(),
    {ok, M} = wasm_memory:new(3, 64),
    %% Three pages in one 256 KiB chunk.
    ?assertEqual(Base + 4, pages()),
    {ok, 3, M1} = wasm_memory:grow(M, 1),
    ?assertEqual(Base + 4, pages()),
    {ok, 4, _M2} = wasm_memory:grow(M1, 1),
    ?assertEqual(Base + 8, pages()),
    ok = wasm_memory:free(M),
    ?assertEqual(Base, pages()).

growth_refused_by_the_node_charges_nothing(_Config) ->
    Image = image(16, 64, [3]),
    I = restore(Image),
    ok = wasm_engine:set_page_limit(pages() + 8),
    Before = pages(),
    ?assertEqual({ok, [-1]}, call(I, ~"grow", [1])),
    ?assertEqual(Before, pages()),
    ?assertEqual({ok, [16]}, call(I, ~"size", [])),
    ok = wasm:destroy(I).

a_killed_grower_gives_its_growth_back(_Config) ->
    M = paged(ones(16), 64),
    Res = wasm_memory:resource(M),
    Base = pages(),
    Self = self(),
    Op = make_ref(),
    P = spawn(fun() ->
                      {ok, 16} = wasm_keeper:grow_begin(Res, Op, 1, 64),
                      Self ! begun,
                      receive never -> ok end
              end),
    receive begun -> ok end,
    ?assertEqual(Base + 16, pages()),
    exit(P, kill),
    wait_until(fun() -> pages() =:= Base end),
    ?assertEqual(16, wasm_keeper:charge_of(Res)),
    ?assertMatch(#{growth := 0}, phys(Res)),
    ok = wasm_memory:free(M).

concurrent_growers_each_get_their_own_size(_Config) ->
    {ok, M} = wasm_memory:new(#limits{min = 1, max = 64, shared = true}),
    Self = self(),
    N = 12,
    [spawn(fun() -> Self ! {grown, wasm_memory:grow(M, 1)} end)
     || _ <- lists:seq(1, N)],
    Olds = [receive {grown, {ok, Old, _}} -> Old end || _ <- lists:seq(1, N)],
    ?assertEqual(lists:seq(1, N), lists:sort(Olds)),
    ?assertEqual(N + 1, wasm_memory:size_pages(M)),
    ok = wasm_memory:store(M, (N + 1) * ?PAGE - 8, 8, 16#AB),
    ok = wasm_memory:free(M).

%% Inside existing capacity the size is the only thing a growth publishes, so
%% it is what decides, after a restart, whether the growth happened.
a_restart_during_growth_inside_capacity_keeps_one_size(_Config) ->
    {ok, M} = wasm_memory:new(#limits{min = 4, max = 8}),
    Res = wasm_memory:resource(M),
    Op = make_ref(),
    {ok, 4} = wasm_keeper:grow_begin(Res, Op, 1, 8),
    Old = whereis(wasm_keeper),
    exit(Old, kill),
    restarted(Old),
    %% The begin is answered again, not applied again.
    ?assertEqual({ok, 4}, wasm_keeper:grow_begin(Res, Op, 1, 8)),
    ?assertEqual(5, wasm_keeper:charge_of(Res)),
    Chunks = element(?MEM_CHUNKS, M),
    ?assertEqual({ok, 4}, wasm_keeper:grow_commit(Res, Op, Chunks)),
    ?assertEqual({ok, 4}, wasm_keeper:grow_commit(Res, Op, Chunks)),
    ok = wasm_keeper:ack(Res, Op),
    ?assertEqual(5, wasm_memory:size_pages(M)),
    ?assertEqual(5, wasm_keeper:charge_of(Res)),
    ok = wasm_memory:free(M).

a_private_memory_grows_across_a_keeper_restart(_Config) ->
    [private_growth(Tier, Image)
     || Tier <- [#{}, #{compile => true, compile_after => 1,
                        compile_force => true}],
        Image <- [image(2, 8, [0, 1]), image(0, 8, [])]],
    ok.

private_growth(Tier, Image) ->
    kill_keeper_at(grow_begun),
    Old = whereis(wasm_keeper),
    I = restore(Image, Tier),
    {ok, [Size]} = wasm:call(I, ~"size", [], Tier#{fuel => infinity}),
    ?assertEqual({ok, [Size]}, wasm:call(I, ~"grow", [1],
                                         Tier#{fuel => infinity})),
    restarted(Old),
    application:unset_env(wasm, keeper_hook),
    ?assertEqual({ok, [Size + 1]}, wasm:call(I, ~"size", [],
                                             Tier#{fuel => infinity})),
    ?assertEqual({ok, []}, wasm:call(I, ~"st", [Size * ?PAGE + 5, 3],
                                     Tier#{fuel => infinity})),
    ?assertEqual({ok, [3]}, wasm:call(I, ~"ld", [Size * ?PAGE + 5],
                                      Tier#{fuel => infinity})),
    ?assertEqual({ok, [0]}, wasm:call(I, ~"ld", [Size * ?PAGE + 6],
                                      Tier#{fuel => infinity})),
    Size > 1 andalso
        ?assertEqual({ok, [2]}, wasm:call(I, ~"ld", [?PAGE + 8],
                                          Tier#{fuel => infinity})),
    Res = wasm_memory:resource(mem(I)),
    ?assertEqual(Size + 1, wasm_keeper:charge_of(Res)),
    {_, _, _, _, #{txn := none}} = row(Res),
    Base = pages() - lists:sum(maps:values(phys(Res))),
    ok = wasm:destroy(I),
    ?assertEqual(Base, pages()).

%% The chunk tuple is published before the size. A keeper killed between the
%% two, and a grower that dies before recovery, leave a growth whose arrays are
%% reachable: recovery finishes it rather than refunding what exists.
published_chunks_finish_a_growth_whose_grower_died(_Config) ->
    M = paged(ones(16), 64),
    Res = wasm_memory:resource(M),
    Base = pages(),
    kill_keeper_at(grow_commit_chunks),
    Old = whereis(wasm_keeper),
    Self = self(),
    P = spawn(fun() ->
                      _ = wasm_memory:grow(M, 1),
                      Self ! never_reached
              end),
    wait_until(fun() -> whereis(wasm_keeper) =/= Old end),
    exit(P, kill),
    application:unset_env(wasm, keeper_hook),
    restarted(Old),
    {_, {memory, CRef, PagesRef, _, _, _}, L, _, #{txn := Txn}} = row(Res),
    Published = wasm_engine:cell_get(CRef),
    ?assertEqual({17, 17, none}, {L, atomics:get(PagesRef, 1), Txn}),
    ?assertEqual(2, tuple_size(Published)),
    ?assertMatch(#{growth := 16}, phys(Res)),
    ?assertEqual(Base + 16, pages()),
    ok = wasm_memory:free(M).

%% An outcome survives a later operation by another writer: an older retry is
%% answered from it and publishes nothing over what came after.
an_older_retry_gets_its_own_answer(_Config) ->
    [older_retry(Min) || Min <- [1, 16]],
    ok.

older_retry(Min) ->
    {ok, M} = wasm_memory:new(#limits{min = Min, max = 64, shared = true}),
    Res = wasm_memory:resource(M),
    {memory, CRef, PagesRef, _, _, _} = element(2, row(Res)),
    Self = self(),
    OpA = make_ref(),
    A = spawn(fun() ->
                      {ok, Min} = wasm_keeper:grow_begin(Res, OpA, 1, 64),
                      Chunks = new_chunks(CRef, Min + 1),
                      kill_keeper_at(txn_finished),
                      Old = whereis(wasm_keeper),
                      {error, keeper_unavailable} =
                          wasm_keeper:grow_commit(Res, OpA, Chunks),
                      Self ! {committed_but_lost, Old},
                      receive retry -> ok end,
                      Self ! {retried, wasm_keeper:grow_commit(Res, OpA, Chunks)},
                      receive never -> ok end
              end),
    Old = receive {committed_but_lost, O} -> O end,
    application:unset_env(wasm, keeper_hook),
    restarted(Old),
    {ok, Min1, _} = wasm_memory:grow(M, 2),
    ?assertEqual(Min + 1, Min1),
    After = {wasm_engine:cell_get(CRef), atomics:get(PagesRef, 1)},
    A ! retry,
    ?assertEqual({retried, {ok, Min}}, receive {retried, _} = R -> R end),
    ?assertEqual(After, {wasm_engine:cell_get(CRef), atomics:get(PagesRef, 1)}),
    ?assertEqual(Min + 3, wasm_keeper:charge_of(Res)),
    #{done := Done} = element(5, row(Res)),
    ?assert(maps:is_key(A, Done)),
    exit(A, kill),
    wait_until(fun() ->
                       not maps:is_key(A, maps:get(done, element(5, row(Res))))
               end),
    ok = wasm_memory:free(M).

new_chunks(CRef, Pages) ->
    Have = wasm_engine:cell_get(CRef),
    Need = Pages - tuple_size(Have),
    list_to_tuple(tuple_to_list(Have)
                  ++ [atomics:new(?PAGE div 8, [{signed, false}])
                      || _ <- lists:seq(1, max(0, Need))]).

%% A holder's ceiling is checked against what it holds; a restart that
%% forgot its heap would let through what was refused before.
holder_totals_survive_a_restart(_Config) ->
    Token = {instance, make_ref()},
    ok = wasm_keeper:set_limit(Token, 6),
    {ok, M} = wasm_memory:create(#limits{min = 2, max = 8},
                                 #{holder => {Token, self()}}),
    {ok, Heap} = wasm_keeper:reserve(3, cell, Token, self()),
    Total = wasm_keeper:total_of(Token),
    ?assertEqual(5, Total),
    ?assertMatch({error, instance_limit},
                 wasm_keeper:reserve(2, cell, Token, self())),
    Old = whereis(wasm_keeper),
    exit(Old, kill),
    restarted(Old),
    ?assertEqual(Total, wasm_keeper:total_of(Token)),
    ?assertMatch({error, instance_limit},
                 wasm_keeper:reserve(2, cell, Token, self())),
    ok = wasm_keeper:release(Heap, Token),
    ok = wasm_keeper:release(wasm_memory:resource(M), Token).

%%% ---------------------------------------------------------------- arena ---

two_writers_wanting_one_chunk_make_one_reservation(_Config) ->
    M = paged(ones(1), 4),
    Res = wasm_memory:resource(M),
    hold_keeper_at(arena_reserved),
    Self = self(),
    Ws = [spawn(fun() ->
                        ok = wasm_memory:store(M, P * 4096, 1, 5),
                        Self ! {wrote, self()}
                end) || P <- [0, 1]],
    receive {held, arena_reserved} -> ok end,
    whereis(wasm_keeper) ! go,
    %% `go' reaches the hook through the keeper's own mailbox only when the
    %% hook is waiting in it, which it is.
    [receive {wrote, W} -> ok end || W <- Ws],
    ?assertMatch(#{arena := 1}, phys(Res)),
    ?assertEqual({2, 2}, wasm_memory:faults(M)),
    ok = wasm_memory:free(M).

%% Slots are claimed in order but the chunk for a late slot can be asked for
%% first: it brings the chunks before it.
a_late_claimant_gets_every_missing_chunk(_Config) ->
    M = paged(ones(4), 8),
    Res = wasm_memory:resource(M),
    {memory, _, _, ARef, _, _} = element(2, row(Res)),
    Op = make_ref(),
    %% Chunks one to three: 16 + 32 + 64 slots, 1 + 2 + 4 pages.
    {ok, 0} = wasm_keeper:arena_begin(Res, Op, 3, {0, 7}),
    New = list_to_tuple([atomics:new(S * 512, [{signed, false}])
                         || S <- [16, 32, 64]]),
    ok = wasm_keeper:arena_commit(Res, Op, New),
    ok = wasm_keeper:ack(Res, Op),
    ?assertEqual(3, tuple_size(wasm_engine:cell_get(ARef))),
    ?assertMatch(#{arena := 7}, phys(Res)),
    ok = wasm_memory:free(M).

a_refused_extension_consumes_no_slot(_Config) ->
    M = paged(ones(4), 8),
    [ok = wasm_memory:store(M, P * 4096, 1, 2) || P <- lists:seq(0, 15)],
    ?assertEqual({16, 16}, wasm_memory:faults(M)),
    ok = wasm_engine:set_page_limit(pages()),
    [?assertMatch({'EXIT', _}, caught(fun() -> wasm_memory:store(M, 16 * 4096, 1, 2) end))
     || _ <- lists:seq(1, 100)],
    ?assertEqual({16, 16}, wasm_memory:faults(M)),
    ok = wasm_memory:free(M).

%%% --------------------------------------------------------- crash points ---

%% A keeper killed at every boundary of a growth, the writer alive throughout.
%% Whatever the point, the growth completes once, the published size and
%% chunks agree with the row, and the charge is counted once.
the_keeper_dies_at_every_step_of_a_growth(_Config) ->
    [keeper_dies_growing(Point, Shared)
     || Point <- [grow_reserved, grow_begun, grow_commit_start,
                  grow_commit_chunks, grow_commit_size, txn_finished],
        Shared <- [false, true]],
    ok.

keeper_dies_growing(Point, Shared) ->
    {ok, M} = wasm_memory:new(#limits{min = 1, max = 8, shared = Shared}),
    Res = wasm_memory:resource(M),
    kill_keeper_at(Point),
    Old = whereis(wasm_keeper),
    {ok, 1, M1} = wasm_memory:grow(M, 1),
    application:unset_env(wasm, keeper_hook),
    restarted(Old),
    {_, {memory, CRef, PagesRef, _, _, _}, L, _, #{txn := Txn} = Ledger} =
        row(Res),
    ?assertEqual({Point, 2, none}, {Point, L, Txn}),
    ?assertMatch(#{growth := 2}, maps:get(phys, Ledger)),
    CRef =:= undefined orelse
        ?assertEqual({Point, 2}, {Point, atomics:get(PagesRef, 1)}),
    ok = wasm_memory:store(M1, 2 * ?PAGE - 8, 8, 7),
    ?assertEqual(7, wasm_memory:load(M1, 2 * ?PAGE - 8, 8)),
    ?assertEqual(lists:sum(maps:values(maps:get(phys, Ledger))), node_charge()),
    ok = wasm_memory:free(M1),
    ?assertEqual(0, node_charge()).

%% The rows' charge, which the node counter must equal.
node_charge() ->
    wait_until(fun() -> pages() =:= rows_charge() end),
    pages().

rows_charge() ->
    ets:foldl(fun({_, {memory, _, _, _, _, _}, _, H, #{phys := P}}, A)
                    when is_map(H) -> A + lists:sum(maps:values(P));
                 ({_, {image, _}, _, H, _}, A) when is_map(H) -> A;
                 ({_, _, Pages, H, _}, A) when is_map(H) -> A + Pages;
                 (_, A) -> A
              end, 0, wasm_holders).

the_keeper_dies_at_every_step_of_an_extension(_Config) ->
    [keeper_dies_extending(Point)
     || Point <- [arena_reserved, arena_begun, arena_commit_start,
                  arena_commit_published, txn_finished]],
    ok.

keeper_dies_extending(Point) ->
    M = paged(ones(4), 8),
    Res = wasm_memory:resource(M),
    {memory, _, _, ARef, _, _} = element(2, row(Res)),
    kill_keeper_at(Point),
    Old = whereis(wasm_keeper),
    ok = wasm_memory:store(M, 5, 1, 9),
    First = wasm_engine:cell_get(ARef),
    application:unset_env(wasm, keeper_hook),
    restarted(Old),
    ?assertEqual({Point, 1}, {Point, tuple_size(First)}),
    %% The array a slot lives in is the one published, not a replacement.
    ?assertEqual(First, wasm_engine:cell_get(ARef)),
    ?assertMatch({Point, #{arena := 1}}, {Point, phys(Res)}),
    ?assertEqual(9, wasm_memory:load(M, 5, 1)),
    ?assertEqual(1, wasm_memory:load(M, 6, 1)),
    ?assertEqual(rows_charge(), node_charge()),
    ok = wasm_memory:free(M),
    ?assertEqual(0, node_charge()).

%% The keeper writes the growth's row and dies before it replies. The writer
%% asks again with the same operation and gets the growth it started.
a_lost_begin_reply_is_resumed(_Config) ->
    {ok, M} = wasm_memory:new(#limits{min = 1, max = 8, shared = true}),
    Res = wasm_memory:resource(M),
    kill_keeper_at(grow_begun),
    Old = whereis(wasm_keeper),
    {ok, 1, _} = wasm_memory:grow(M, 1),
    application:unset_env(wasm, keeper_hook),
    restarted(Old),
    ?assertEqual(2, wasm_keeper:charge_of(Res)),
    ?assertMatch(#{growth := 2}, phys(Res)),
    {_, _, _, _, #{txn := none}} = row(Res),
    ok = wasm_memory:free(M).

%% Recovery held back for ten seconds while the writer waits: it does not give
%% up, and its answer is what was decided.
a_writer_waits_through_a_slow_recovery(_Config) ->
    {ok, M} = wasm_memory:new(#limits{min = 1, max = 8, shared = true}),
    Res = wasm_memory:resource(M),
    Self = self(),
    kill_keeper_at(grow_commit_size),
    Old = whereis(wasm_keeper),
    _ = spawn_link(fun() -> Self ! {grown, wasm_memory:grow(M, 1)} end),
    restarted(Old),
    sys:suspend(wasm_keeper),
    timer:sleep(10_000),
    sys:resume(wasm_keeper),
    application:unset_env(wasm, keeper_hook),
    ?assertMatch({grown, {ok, 1, _}}, receive {grown, _} = G -> G end),
    ?assertEqual(2, wasm_memory:size_pages(M)),
    {ok, 2, _} = wasm_memory:grow(M, 1),
    ?assertEqual(3, wasm_keeper:charge_of(Res)),
    ok = wasm_memory:free(M).

%% A writer killed between claiming a growth and committing it, before and
%% after it allocated, and a page writer killed between its claim and its
%% publish: what was not published is given back.
a_writer_killed_mid_transaction_is_settled(_Config) ->
    {ok, M} = wasm_memory:new(#limits{min = 1, max = 8, shared = true}),
    Res = wasm_memory:resource(M),
    Base = rows_charge(),
    Op = make_ref(),
    P = spawn(fun() -> {ok, 1} = wasm_keeper:grow_begin(Res, Op, 1, 8),
                       receive never -> ok end end),
    wait_until(fun() -> wasm_keeper:charge_of(Res) =:= 2 end),
    exit(P, kill),
    wait_until(fun() -> wasm_keeper:charge_of(Res) =:= 1 end),
    ?assertEqual(Base, rows_charge()),
    ok = wasm_memory:free(M),
    %% A page writer held between filling its slot and publishing it.
    Paged = paged(ones(1), 4),
    Self = self(),
    W = spawn(fun() ->
                      put({wasm_memory, fault_hook},
                          fun(fault) -> Self ! held, receive never -> ok end end),
                      ok = wasm_memory:store(Paged, 0, 1, 3)
              end),
    receive held -> ok end,
    exit(W, kill),
    ?assertEqual({1, 0}, wasm_memory:faults(Paged)),
    ?assertEqual(1, wasm_memory:load(Paged, 0, 1)),
    ok = wasm_memory:store(Paged, 0, 1, 4),
    ?assertEqual({2, 1}, wasm_memory:faults(Paged)),
    ?assertEqual(rows_charge(), node_charge()),
    ok = wasm_memory:free(Paged),
    ?assertEqual(0, node_charge()).

%% A reclaim cut short anywhere is finished by the next keeper, whether the
%% process that released stays or goes, and both cells really go.
a_reclaim_cut_short_is_finished(_Config) ->
    [reclaim_cut(Point, Stay)
     || Point <- [retiring, forgotten, deleted], Stay <- [true, false]],
    ok.

reclaim_cut(Point, Stay) ->
    M = paged(ones(1), 4),
    ok = wasm_memory:store(M, 0, 1, 2),
    Res = wasm_memory:resource(M),
    {memory, CRef, _, ARef, _, _} = element(2, row(Res)),
    kill_keeper_at(Point),
    Old = whereis(wasm_keeper),
    Self = self(),
    P = spawn(fun() -> ok = wasm_memory:free(M), Self ! freed,
                       Stay andalso receive never -> ok end end),
    restarted(Old),
    application:unset_env(wasm, keeper_hook),
    ?assertEqual({Point, []}, {Point, ets:lookup(wasm_holders, Res)}),
    ?assertMatch({Point, {'EXIT', _}},
                 {Point, caught(fun() -> wasm_engine:cell_get(ARef) end)}),
    ?assertMatch({Point, {'EXIT', _}},
                 {Point, caught(fun() -> wasm_engine:cell_get(CRef) end)}),
    ?assertEqual(0, node_charge()),
    exit(P, kill).

%%% ----------------------------------------------------------- exhaustion ---

%% Fifteen slots taken elsewhere, so the sixteenth is the last of the first
%% arena chunk and the second chunk is refused. Each write below needs both,
%% and must leave every byte it would have written as it was.
exhaustion_leaves_every_byte_as_it_was(_Config) ->
    exhaustion(#{}).

exhaustion_in_generated_code_leaves_every_byte_as_it_was(_Config) ->
    exhaustion(#{compile => true, compile_after => 1, compile_force => true}).

exhaustion(Tier) ->
    Bin = << <<(P band 16#FF)>> || P <- lists:seq(0, 32 * ?PAGE - 1) >>,
    Run = Tier#{fuel => infinity},
    {ok, H} = wasm:load(pager(32, 32, [])),
    Cases = [{~"st64", [12 * 4096 - 3, -1], {12 * 4096 - 3, 8}},
             {~"fill", [13 * 4096, 7, 8 * 4096], {13 * 4096, 8 * 4096}},
             host,
             {~"copy", [21 * 4096, 21 * 4096 + 100, 8 * 4096],
              {21 * 4096, 8 * 4096}},
             {~"copy", [29 * 4096 + 100, 29 * 4096, 8 * 4096],
              {29 * 4096 + 100, 8 * 4096}}],
    [begin
         {ok, I} = wasm:instantiate(
                     H, #{}, Run#{memory_opts =>
                                      #{0 => #{image => wasm_memory:image_of(Bin)}}}),
         [{ok, []} = wasm:call(I, ~"st", [P * 4096 + 1, 0], Run)
          || P <- lists:seq(60, 74)],
         Mem = mem(I),
         ?assertEqual({15, 15}, wasm_memory:faults(Mem)),
         ok = wasm_engine:set_page_limit(pages()),
         {ok, Before} = wasm:read_memory(I, 0, 32 * ?PAGE),
         Got = case Case of
                   host -> wasm:write_memory(I, 40 * 4096, binary:copy(<<9>>,
                                                                       8 * 4096));
                   {F, Args, _} -> wasm:call(I, F, Args, Run)
               end,
         ?assertMatch({Case, {error, #{class := exhaustion, kind := memory_limit}}},
                      {Case, Got}),
         {ok, After} = wasm:read_memory(I, 0, 32 * ?PAGE),
         ?assertEqual({Case, Before}, {Case, After}),
         %% Three more refusals take no slot.
         Faults = wasm_memory:faults(Mem),
         [_ = wasm:write_memory(I, 40 * 4096, binary:copy(<<9>>, 8 * 4096))
          || _ <- lists:seq(1, 3)],
         ?assertEqual(element(1, Faults), element(1, wasm_memory:faults(Mem))),
         %% Pages already private stay writable.
         ?assertEqual({ok, []}, wasm:call(I, ~"st", [60 * 4096 + 1, 5], Run)),
         ?assertEqual({ok, [5]}, wasm:call(I, ~"ld", [60 * 4096 + 1], Run)),
         ok = wasm_engine:set_page_limit(16384),
         ok = wasm:destroy(I)
     end || Case <- Cases],
    ok.

%%% --------------------------------------------------------------- images ---

the_image_ledger_survives_every_cut(_Config) ->
    %% Charged and then cut before the row: the rebuilt counter has no charge.
    kill_keeper_at(image_charged),
    Old = whereis(wasm_keeper),
    {ok, H} = wasm:load(pager(1, 1, [0])),
    {ok, I} = wasm:instantiate(H, #{}, #{fuel => infinity,
                                          snapshotable => true}),
    {ok, []} = call(I, ~"init", []),
    ?assertMatch({error, _}, wasm:snapshot(I)),
    application:unset_env(wasm, keeper_hook),
    restarted(Old),
    ?assertEqual(0, wasm_snapshot_owner:charged()),
    %% An image whose owner dies: reclaimed, once.
    {ok, Image} = wasm:snapshot(I),
    Bytes = wasm_snapshot_owner:charged(),
    ?assert(Bytes > 0),
    R = restore(Image),
    exit(wasm_snapshot:owner(Image), kill),
    timer:sleep(100),
    ?assertEqual(Bytes, wasm_snapshot_owner:charged()),
    %% A memory retired and cut before its image follows: finished at restart.
    kill_keeper_at(deleted),
    Old2 = whereis(wasm_keeper),
    ok = wasm:destroy(R),
    restarted(Old2),
    application:unset_env(wasm, keeper_hook),
    wait_until(fun() -> wasm_snapshot_owner:charged() =:= 0 end),
    ok = wasm:destroy(I).

%% A file's image is charged before its pages are built, by its owner. A build
%% that throws half way, with the caller alive throughout, gives everything back
%% by the owner exiting; the budget it held then admits the next load.
an_image_that_fails_to_build_takes_nothing(Config) ->
    {ok, H} = wasm:load(two_memories()),
    {ok, I} = wasm:instantiate(H, #{}, #{fuel => infinity, snapshotable => true}),
    {ok, []} = call(I, ~"init", []),
    {ok, Image} = wasm:snapshot(I),
    ok = wasm:destroy(I),
    Path = filename:join(?config(priv_dir, Config), "build-fail.img"),
    ok = wasm:save_snapshot(Image, Path),
    ok = wasm:release(Image),
    wait_until(fun() -> wasm_snapshot_owner:charged() =:= 0 end),
    Once = atomics:new(1, []),
    ok = application:set_env(wasm, build_hook,
                             fun(page) ->
                                     case atomics:add_get(Once, 1, 1) of
                                         2 -> error(injected);
                                         _ -> ok
                                     end
                             end),
    ?assertMatch({error, _}, wasm:load_snapshot(Path, H)),
    application:unset_env(wasm, build_hook),
    wait_until(fun() -> wasm_snapshot_owner:charged() =:= 0 end),
    ?assertEqual([], image_rows()),
    {ok, Size} = file:read_file_info(Path),
    _ = Size,
    application:set_env(wasm, max_snapshot_bytes, 2 * ?PAGE + 32),
    {ok, Again} = wasm:load_snapshot(Path, H),
    ok = wasm:release(Again).

%% Two memories, one page each, each holding data: the build is cut after the
%% first is built.
two_memories() ->
    Init = <<16#41, 8, 16#41, 1, 16#36, 2, 0,
             16#41, 8, 16#41, 2, 16#36, 16#42, 1, 0, 16#0B>>,
    wasm_asm:module(
      [wasm_asm:type_section([{[], []}]),
       wasm_asm:func_section([0]),
       wasm_asm:section(5, [wasm_asm:uleb(2), wasm_asm:limits(1, 1, 1),
                            wasm_asm:limits(1, 1, 1)]),
       wasm_asm:export_section([{~"init", 0, 0}]),
       wasm_asm:code_section([Init])]).

image_rows() ->
    [R || R <- ets:tab2list(wasm_holders), tuple_size(R) =:= 5,
          is_tuple(element(2, R)), element(1, element(2, R)) =:= image].

an_image_lives_as_long_as_a_memory_needs_it(_Config) ->
    Image = image(1, 1, [0]),
    Bytes = wasm_snapshot_owner:charged(),
    %% Two restores in one process, one destroyed.
    A = restore(Image), B = restore(Image),
    ok = wasm:destroy(A),
    ok = wasm:release(Image),
    ?assertEqual(Bytes, wasm_snapshot_owner:charged()),
    ok = wasm:destroy(B),
    wait_until(fun() -> wasm_snapshot_owner:charged() =:= 0 end),
    %% Exported into another instance, the exporter destroyed.
    Image2 = image(1, 1, [0]),
    Bytes2 = wasm_snapshot_owner:charged(),
    X = restore(Image2),
    {ok, Mem} = wasm:extern(X, ~"memory"),
    {ok, ImpH} = wasm:load(importer()),
    {ok, Imp} = wasm:instantiate(ImpH, #{{~"e", ~"m"} => Mem}),
    ok = wasm:destroy(X),
    exit(wasm_snapshot:owner(Image2), kill),
    timer:sleep(100),
    ?assertEqual(Bytes2, wasm_snapshot_owner:charged()),
    ?assertEqual({ok, [1]}, wasm:call(Imp, ~"ld", [8])),
    ok = wasm:destroy(Imp),
    wait_until(fun() -> wasm_snapshot_owner:charged() =:= 0 end),
    %% No memory at all: the owner's death refunds once.
    Image3 = image(1, 1, [0]),
    exit(wasm_snapshot:owner(Image3), kill),
    wait_until(fun() -> wasm_snapshot_owner:charged() =:= 0 end).

importer() ->
    I32 = 16#7F,
    wasm_asm:module(
      [wasm_asm:type_section([{[I32], [I32]}]),
       wasm_asm:import_section([{~"e", ~"m", 0, 1}]),
       wasm_asm:func_section([0]),
       wasm_asm:export_section([{~"ld", 0, 0}]),
       wasm_asm:code_section([<<16#20, 0, 16#2D, 0, 0, 16#0B>>])]).

a_restore_that_cannot_be_afforded_leaves_nothing(_Config) ->
    Image = image(640, undefined, [0]),
    Rows = length(ets:tab2list(wasm_holders)),
    Base = pages(),
    ok = wasm_engine:set_page_limit(Base + 1),
    ?assertMatch({error, #{class := exhaustion, kind := memory_limit}},
                 wasm:restore(Image, #{}, #{fuel => infinity})),
    ok = wasm_engine:set_page_limit(16384),
    ?assertMatch({error, #{class := exhaustion, kind := memory_limit}},
                 wasm:restore(Image, #{}, #{fuel => infinity,
                                            max_memory_pages => 100})),
    ?assertEqual({Base, Rows}, {pages(), length(ets:tab2list(wasm_holders))}).

a_descendant_restores_its_parents_pages(_Config) ->
    Parent = image(4, 4, [0, 1, 2, 3]),
    I = restore(Parent),
    {ok, []} = call(I, ~"st", [2 * ?PAGE + 100, 77]),
    {ok, Child} = wasm:snapshot(restore_snapshotable(Parent)),
    ok = wasm:destroy(I),
    ok = wasm:release(Parent),
    C = restore(Child),
    ?assertEqual({ok, [3]}, call(C, ~"ld", [2 * ?PAGE + 8])),
    ok = wasm:destroy(C).

restore_snapshotable(Image) ->
    {ok, I} = wasm:restore(Image, #{}, #{fuel => infinity, snapshotable => true}),
    {ok, []} = call(I, ~"st", [2 * ?PAGE + 100, 77]),
    I.

%%% ---------------------------------------------------------------- files ---

a_file_from_the_last_release_loads(_Config) ->
    Path = filename:join([wasm_spec_runner:fixtures_dir(), "snapshot",
                          "pager-0.8.0.img"]),
    case filelib:is_file(Path) of
        false ->
            {skip, "no 0.8.0 image fixture"};
        true ->
            {ok, H} = wasm:load(pager(3, 3, [0, 2])),
            {ok, Image} = wasm:load_snapshot(Path, H),
            I = restore(Image),
            ?assertEqual({ok, [1]}, call(I, ~"ld", [8])),
            ?assertEqual({ok, [0]}, call(I, ~"ld", [?PAGE + 8])),
            ?assertEqual({ok, [3]}, call(I, ~"ld", [2 * ?PAGE + 8])),
            ok = wasm:destroy(I)
    end.

a_sparse_image_loads_on_a_small_node(_Config) ->
    Image = image(640, undefined, [0, 639]),
    Path = filename:join(code:priv_dir(wasm), "../sparse.img"),
    ok = wasm:save_snapshot(Image, Path),
    ok = wasm:release(Image),
    ok = wasm_engine:set_page_limit(pages() + 128),
    {ok, H} = wasm:load(pager(640, undefined, [0, 639])),
    {ok, Loaded} = wasm:load_snapshot(Path, H),
    I = restore(Loaded),
    %% 640 stored as a word, read back as its low byte.
    ?assertEqual({ok, [640 band 16#FF]}, call(I, ~"ld", [639 * ?PAGE + 8])),
    ok = wasm:destroy(I),
    file:delete(Path).

a_bad_file_is_refused_before_anything_is_built(_Config) ->
    {ok, H} = wasm:load(pager(2, 4, [])),
    {ok, M} = wasm_module_cache:get(H),
    Good = #{pages => 2, runs => [{0, <<1>>}, {?PAGE, <<2>>}]},
    Bad = [#{pages => 5, runs => []},
           #{pages => 2, runs => [{?PAGE, <<2>>}, {0, <<1>>}]},
           #{pages => 2, runs => [{0, <<1, 2, 3>>}, {1, <<9>>}]},
           #{pages => 2, runs => [{2 * ?PAGE - 1, <<1, 2>>}]}],
    [?assertMatch({error, #{class := invalid}}, from_parts(H, M, [B]))
     || B <- Bad],
    ?assertMatch({error, #{class := invalid}}, from_parts(H, M, [Good, Good])),
    ?assertEqual(0, wasm_snapshot_owner:charged()).

%% Over the node's snapshot budget, or past the fixed ceiling on how many
%% pages one image may map: refused as exhaustion, with nothing registered.
an_expensive_file_is_refused_as_exhaustion(Config) ->
    Image = image(4, 4, [0, 1, 2, 3]),
    Path = filename:join(?config(priv_dir, Config), "expensive.img"),
    ok = wasm:save_snapshot(Image, Path),
    ok = wasm:release(Image),
    wait_until(fun() -> wasm_snapshot_owner:charged() =:= 0 end),
    application:set_env(wasm, max_snapshot_bytes, ?PAGE),
    {ok, H} = wasm:load(pager(4, 4, [0, 1, 2, 3])),
    ?assertMatch({error, #{class := exhaustion, kind := snapshot_budget}},
                 wasm:load_snapshot(Path, H)),
    ?assertEqual({0, []}, {wasm_snapshot_owner:charged(), image_rows()}),
    application:unset_env(wasm, max_snapshot_bytes),
    %% A 64-bit memory with no maximum, mapped past 2^20 pages.
    {ok, H64} = wasm:load(wasm_asm:module([wasm_asm:memory_section(4, 1,
                                                                   undefined)])),
    {ok, M64} = wasm_module_cache:get(H64),
    ?assertMatch({error, #{class := exhaustion, kind := snapshot_budget}},
                 from_parts(H64, M64, [#{pages => (1 bsl 20) + 1, runs => []}])),
    ?assertEqual({0, []}, {wasm_snapshot_owner:charged(), image_rows()}).

from_parts(H, M, Mems) ->
    {wasm_module, Hash} = H,
    P = #{hash => Hash, version => ~"1", key => undefined, shape => x,
          globals => [], tables => [], mems => Mems, dropped => {#{}, #{}},
          hooks => #{}},
    wasm_snapshot:from_parts(P, H, M).
