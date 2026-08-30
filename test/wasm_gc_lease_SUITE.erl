-module(wasm_gc_lease_SUITE).
-moduledoc """
Collecting an object store two processes are using.

Collection traces from roots, and a root is something the runtime can see: a
global, a table, a passive element segment, a pin. A reference held in a local
or on an operand stack halfway through a call is none of those. Within one
process that is handled by only ever collecting at depth zero. Across processes
it was not handled at all, and linked instances share a store precisely so that
two processes can use one.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([a_foreign_process_mid_call_keeps_what_it_holds/1,
         a_pending_request_blocks_nobody/1,
         a_collector_killed_mid_sweep_does_not_wedge_the_store/1,
         a_killed_reader_does_not_stop_collection_for_ever/1,
         a_reader_killed_before_it_counts_leaves_nothing_stranded/1,
         a_reader_killed_after_it_uncounts_leaves_nothing_stranded/1,
         a_collector_killed_before_it_unmarks_does_not_wedge_the_store/1,
         a_release_never_unmarks_the_next_collector/1,
         a_corpse_never_takes_the_count_below_the_living/1,
         the_collector_row_matches_who_holds_the_store/1,
         re_entrant_calls_take_one_lease/1,
         overlapping_traffic_still_gets_collected/1]).

all() ->
    [a_foreign_process_mid_call_keeps_what_it_holds,
     a_pending_request_blocks_nobody,
     a_collector_killed_mid_sweep_does_not_wedge_the_store,
     a_killed_reader_does_not_stop_collection_for_ever,
     a_reader_killed_before_it_counts_leaves_nothing_stranded,
     a_reader_killed_after_it_uncounts_leaves_nothing_stranded,
     a_collector_killed_before_it_unmarks_does_not_wedge_the_store,
     a_release_never_unmarks_the_next_collector,
     a_corpse_never_takes_the_count_below_the_living,
     the_collector_row_matches_who_holds_the_store,
     re_entrant_calls_take_one_lease,
     overlapping_traffic_still_gets_collected].

%% Low enough that one `churn` call crosses it, so a collection is attempted
%% where the test says it is rather than whenever the default happens to fall.
init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Parsed} = wasm_wat:module(source()),
    {ok, Mod} = wasm_validate:module(Parsed),
    [{mod, Mod} | Config].

end_per_suite(_) -> ok.

init_per_testcase(_Case, Config) ->
    Old = application:get_env(wasm, gc_alloc_threshold),
    ok = application:set_env(wasm, gc_alloc_threshold, 2000),
    [{old_threshold, Old} | Config].

end_per_testcase(_Case, Config) ->
    case ?config(old_threshold, Config) of
        {ok, V} -> application:set_env(wasm, gc_alloc_threshold, V);
        undefined -> application:unset_env(wasm, gc_alloc_threshold)
    end.

source() -> ~"""
(module
  (import "e" "block" (func $block))
  (import "e" "reenter" (func $reenter (param i32) (result i32)))
  (type $s (struct (field $v (mut i32))))
  ;; Allocates, keeps the only reference in a local, and parks inside a host
  ;; call. Nothing the collector can see points at that object.
  (func (export "hold") (param i32) (result i32)
    (local $r (ref null $s))
    (local.set $r (struct.new $s (local.get 0)))
    (call $block)
    (struct.get $s $v (local.get $r)))
  (func (export "churn") (param i32) (result i32)
    (local $i i32) (local $acc i32)
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get 0)))
        (local.set $acc
          (struct.get $s $v (struct.new $s (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (local.get $acc))
  (func (export "nested") (param i32) (result i32)
    (local $r (ref null $s))
    (local.set $r (struct.new $s (local.get 0)))
    (drop (call $reenter (local.get 0)))
    (struct.get $s $v (local.get $r)))
  (func (export "one") (param i32) (result i32)
    (struct.get $s $v (struct.new $s (local.get 0)))))
""".

%%% ------------------------------------------------------------- the case ---

%% The one this whole mechanism exists for. A foreign process is parked inside
%% a host call with the only reference to an object in a local; the owner
%% allocates enough to want a collection. Collecting there would free an object
%% that is about to be read.
a_foreign_process_mid_call_keeps_what_it_holds(Config) ->
    Self = self(),
    Gate = make_ref(),
    {A, B} = linked_pair(Config, Self, Gate),

    Foreign = spawn(fun() -> Self ! {result, wasm:call(B, ~"hold", [12345])} end),
    receive {blocked, Gate} -> ok after 5000 -> ct:fail(never_blocked) end,

    %% Enough allocation to want a collection, several times over.
    [{ok, _} = wasm:call(A, ~"churn", [5000]) || _ <- lists:seq(1, 5)],

    Foreign ! {go, Gate},
    receive
        {result, R} -> ?assertEqual({ok, [12345]}, R)
    after 5000 -> ct:fail(no_result)
    end,
    destroy([A, B]).

%% A collection that is merely wanted must not stop anybody. There is no
%% writer-pending state, on purpose: the alternative is a reader queue behind a
%% collection that cannot start, which is a deadlock whenever the thing holding
%% it up is a guest that never returns.
a_pending_request_blocks_nobody(Config) ->
    Self = self(),
    Gate = make_ref(),
    {A, B} = linked_pair(Config, Self, Gate),

    Foreign = spawn(fun() -> Self ! {result, wasm:call(B, ~"hold", [7])} end),
    receive {blocked, Gate} -> ok after 5000 -> ct:fail(never_blocked) end,

    %% The first of these leaves a request pending. Every one after it has to
    %% go straight through while the foreign process is still parked.
    {Micros, _} = timer:tc(fun() ->
                      [{ok, _} = wasm:call(A, ~"churn", [3000])
                       || _ <- lists:seq(1, 20)]
                  end),
    ?assert(Micros < 5000000),
    ?assert(wasm_heap:readers(wasm_instance:heap(A)) >= 1),

    Foreign ! {go, Gate},
    receive {result, {ok, [7]}} -> ok after 5000 -> ct:fail(no_result) end,
    %% And once the last reader is out, the collection actually happens.
    {ok, _} = wasm:call(A, ~"one", [1]),
    ?assertEqual(0, wasm_heap:readers(wasm_instance:heap(A))),
    destroy([A, B]).

%% A collection is pure computation with no receive in it, so the only way to
%% stop halfway is `exit(Pid, kill)`, which is exactly what a worker timeout
%% does. Left alone that holds the store exclusively for ever and every reader
%% spins against it.
a_collector_killed_mid_sweep_does_not_wedge_the_store(_Config) ->
    Heap = wasm_heap:new(),
    Self = self(),
    Collector = spawn(fun() ->
                          true = wasm_heap:lease(Heap),
                          true = wasm_heap:try_exclusive(Heap),
                          Self ! holding,
                          receive never -> ok end
                      end),
    receive holding -> ok after 5000 -> ct:fail(never_held) end,
    %% Nobody gets in while it is alive and holding.
    ?assertEqual(timeout, try_lease(Heap, 300)),

    Ref = monitor(process, Collector),
    exit(Collector, kill),
    receive {'DOWN', Ref, _, _, _} -> ok after 5000 -> ct:fail(alive) end,

    ?assertEqual(true, try_lease(Heap, 5000)),
    ?assertEqual(0, wasm_heap:readers(Heap)).

%% The other half of the killed-holder problem, and the one that was open. A
%% *reader* killed outright never runs the `after` that gives its count back,
%% so the lease cell stays above zero for ever: `last_out/2` never sees the
%% store empty, `try_exclusive/1` never matches, and nothing on this store is
%% ever collected again. Unreachable objects then accumulate without bound,
%% which is a leak rather than the slowdown a stranded code slot costs.
a_killed_reader_does_not_stop_collection_for_ever(_Config) ->
    Heap = wasm_heap:new(),
    Self = self(),
    Reader = spawn(fun() ->
                       true = wasm_heap:lease(Heap),
                       Self ! holding,
                       receive never -> ok end
                   end),
    receive holding -> ok after 5000 -> ct:fail(never_held) end,
    ?assertEqual(1, wasm_heap:readers(Heap)),
    Ref = monitor(process, Reader),
    exit(Reader, kill),
    receive {'DOWN', Ref, _, _, _} -> ok after 5000 -> ct:fail(alive) end,
    %% Still counted, because nothing gave it back. That is the defect, and it
    %% is only a defect once somebody wants to collect.
    ?assertEqual(1, wasm_heap:readers(Heap)),
    ok = wasm_heap:request_collect(Heap),
    %% A live reader arrives, does its work and leaves. On the way out it is the
    %% only one left alive, so it must be handed the collection rather than
    %% concluding that somebody else is still inside.
    true = wasm_heap:lease(Heap),
    ?assertEqual(collect_now, wasm_heap:unlease(Heap, true)),
    ?assertEqual(0, wasm_heap:readers(Heap) rem (1 bsl 32)),
    ok = wasm_heap:release_exclusive(Heap),
    %% And the store is usable afterwards.
    ?assertEqual(true, try_lease(Heap, 5000)),
    ?assertEqual(0, wasm_heap:readers(Heap)).

%% The count and the row are two writes and a kill can land between them, so
%% which one goes first decides what a corpse leaves behind. The rule is that
%% **the rows are a superset of the counts**: a row without a count is a delay,
%% a count without a row is unrecoverable.
%%
%% Here the reader dies having recorded its row and not yet counted. Recording
%% second left the mirror state, a count nothing could account for, and the
%% store never collected again.
a_reader_killed_before_it_counts_leaves_nothing_stranded(_Config) ->
    Heap = wasm_heap:new(),
    with_hook(fun() ->
        Reader = held_at(row_before_count,
                         fun() -> true = wasm_heap:lease(Heap) end),
        kill(Reader),
        ?assertEqual(collect_now, next_one_out_collects(Heap)),
        ok = wasm_heap:release_exclusive(Heap),
        ?assertEqual(0, wasm_heap:readers(Heap))
    end).

%% And the same window read the other way round: the reader has given the count
%% back and dies before deleting its row. That leaves a row leading its count,
%% which is the direction the store survives.
a_reader_killed_after_it_uncounts_leaves_nothing_stranded(_Config) ->
    Heap = wasm_heap:new(),
    with_hook(fun() ->
        Reader = held_at(count_before_row,
                         fun() ->
                             true = wasm_heap:lease(Heap),
                             ok = wasm_heap:unlease(Heap, true)
                         end),
        kill(Reader),
        ?assertEqual(collect_now, next_one_out_collects(Heap)),
        ok = wasm_heap:release_exclusive(Heap),
        ?assertEqual(0, wasm_heap:readers(Heap))
    end).

%% The collector has the same two writes and the same rule, pointing the other
%% way: exclusivity may never be visible without a row naming who holds it. So
%% the count is given back first. Unmarking first left a collector killed in
%% between holding `?EXCL` with nobody to find, `reclaim/2` answered `none`, and
%% every reader spun without bound.
a_collector_killed_before_it_unmarks_does_not_wedge_the_store(_Config) ->
    Heap = wasm_heap:new(),
    with_hook(fun() ->
        Collector = held_at(released_before_unmark,
                            fun() ->
                                true = wasm_heap:lease(Heap),
                                true = wasm_heap:try_exclusive(Heap),
                                ok = wasm_heap:release_exclusive(Heap)
                            end),
        kill(Collector),
        %% The store is free the instant the count goes back, whatever the row
        %% says, so a reader gets in rather than spinning against a corpse.
        ?assertEqual(true, try_lease(Heap, 5000))
    end).

%% Giving the count back first makes the store claimable while the releasing
%% process still has its unmark to run, so that unmark has to be conditional.
%% A plain delete would take the *next* collector's row away while it holds the
%% store, which is exactly the state the order above exists to prevent.
a_release_never_unmarks_the_next_collector(_Config) ->
    Heap = wasm_heap:new(),
    Self = self(),
    with_hook(fun() ->
        %% Claimed the way the last reader out claims it, so this collector
        %% holds no read lease of its own and the store is empty behind it.
        Collector = held_at(released_before_unmark,
                            fun() ->
                                collect_now = next_one_out_collects(Heap),
                                ok = wasm_heap:release_exclusive(Heap),
                                Self ! released
                            end),
        %% The store is already free, so somebody else can become the collector
        %% while the first one still has its unmark to run. Bounded, and off
        %% this process: a store that is *not* free leaves the claim spinning
        %% in `read_lease/3`, and a hung case says less than a failed one.
        Next = collects_within(Heap, 5000),
        try
            Next =/= timeout orelse ct:fail(store_never_became_free),
            Collector ! proceed,
            receive released -> ok after 5000 -> ct:fail(never_released) end,
            ?assertMatch([{_, Next, 1}], collector_rows(Heap))
        after
            %% Both are parked waiting to be let go, and a failure above would
            %% otherwise leave them there for the life of the node.
            is_pid(Next) andalso kill(Next),
            kill(Collector)
        end
    end).

%% What the corpse's row is worth. It says what that reader *would* have held,
%% which for one killed before it counted is more than it ever did, so giving
%% the counter back what the row says can take it below the readers actually
%% inside -- and then a collection runs with somebody in the store. The count is
%% recomputed from the survivors instead, which can only err upwards.
a_corpse_never_takes_the_count_below_the_living(_Config) ->
    Heap = wasm_heap:new(),
    Self = self(),
    with_hook(fun() ->
        Dead = held_at(row_before_count,
                       fun() -> true = wasm_heap:lease(Heap) end),
        kill(Dead),
        Live = spawn(fun() ->
                         true = wasm_heap:lease(Heap),
                         Self ! inside,
                         receive leave -> ok end,
                         R = wasm_heap:unlease(Heap, true),
                         %% Released here, from the process that was handed it,
                         %% so the store afterwards is empty rather than held
                         %% exclusively by a collection nobody ran. `readers/1`
                         %% reports zero for both, which is how the first
                         %% version of this case ended up asserting nothing.
                         R =:= collect_now andalso
                             wasm_heap:release_exclusive(Heap),
                         Self ! {left, R}
                     end),
        receive inside -> ok after 5000 -> ct:fail(never_inside) end,
        ok = wasm_heap:request_collect(Heap),
        %% One reader is inside, so nobody else may be handed the collection.
        true = wasm_heap:lease(Heap),
        ?assertEqual(ok, wasm_heap:unlease(Heap, true)),
        ?assertEqual(1, wasm_heap:readers(Heap)),
        %% And when the living one leaves, it is handed the collection itself.
        Live ! leave,
        receive {left, R} -> ?assertEqual(collect_now, R)
        after 5000 -> ct:fail(never_left)
        end,
        ?assertEqual(0, wasm_heap:readers(Heap))
    end).

%% The collector row, at every endpoint an upgrade can reach: held, released,
%% and refused. A held store names its collector so `reclaim/2` has somebody to
%% test, and the other two leave nothing behind, or the next reader would think
%% a collection was in progress.
%%
%% These are the endpoints and not the *ordering* between the two writes:
%% swapping them would still satisfy everything below. The ordering is what
%% `a_collector_killed_before_it_unmarks_does_not_wedge_the_store` holds, by
%% killing a process inside the window rather than by inspecting either end.
the_collector_row_matches_who_holds_the_store(_Config) ->
    Heap = wasm_heap:new(),
    true = wasm_heap:lease(Heap),
    true = wasm_heap:try_exclusive(Heap),
    %% Held, and findable: nobody else gets in, and the row says who has it.
    ?assertEqual(timeout, try_lease(Heap, 300)),
    ?assertMatch([{_, _, _}], collector_rows(Heap)),
    ok = wasm_heap:release_exclusive(Heap),
    ?assertEqual([], collector_rows(Heap)),
    %% A failed upgrade leaves no mark behind either, or the next reader would
    %% think a collection was in progress.
    Self = self(),
    Other = spawn(fun() -> true = wasm_heap:lease(Heap), Self ! in,
                           receive go -> ok end,
                           ok = wasm_heap:unlease(Heap, true) end),
    receive in -> ok after 5000 -> ct:fail(never_in) end,
    ?assertEqual(false, wasm_heap:try_exclusive(Heap)),
    ?assertEqual([], collector_rows(Heap)),
    Other ! go,
    ok = wasm_heap:unlease(Heap, true).

%% A host import calling back into the instance is one execution, not two. Two
%% leases would be harmless; what would not be is releasing on the way out of
%% the inner one and leaving the outer running unprotected.
re_entrant_calls_take_one_lease(Config) ->
    Self = self(),
    Gate = make_ref(),
    {A, _B} = linked_pair(Config, Self, Gate),
    Heap = wasm_instance:heap(A),
    ?assertEqual(1, get_reenter_readers(A, Heap)),
    ?assertEqual(0, wasm_heap:readers(Heap)),
    destroy([A]).

%% Not one overlap but continuous overlap. Collection has to happen anyway, and
%% no call may be stuck behind it.
overlapping_traffic_still_gets_collected(Config) ->
    Self = self(),
    Gate = make_ref(),
    {A, B} = linked_pair(Config, Self, Gate),
    Heap = wasm_instance:heap(A),
    Workers = [spawn(fun() ->
                         [{ok, _} = wasm:call(I, ~"churn", [2000])
                          || _ <- lists:seq(1, 60)],
                         Self ! {done, self()}
                     end) || I <- [A, B, A, B]],
    [receive {done, P} -> ok after 60000 -> ct:fail({stuck, P}) end
     || P <- Workers],
    %% A store that never collected would hold a quarter of a million objects.
    ?assert(wasm_heap:size(Heap) < 100000),
    ?assertEqual(0, wasm_heap:readers(Heap)),
    destroy([A, B]).

%%% --------------------------------------------------------------- helpers ---

%% Two instances over one object store, which is the shape the lease exists
%% for: two processes, one store, references passing between them.
linked_pair(Config, Parent, Gate) ->
    Mod = ?config(mod, Config),
    Imports = fun(Inst) ->
                  #{{~"e", ~"block"} =>
                        fun(_C, []) ->
                            Parent ! {blocked, Gate},
                            receive {go, Gate} -> ok end,
                            {ok, []}
                        end,
                    {~"e", ~"reenter"} =>
                        fun(_C, [X]) ->
                            Parent ! {readers, wasm_heap:readers(Inst())},
                            {ok, [X]}
                        end}
              end,
    Ref = make_ref(),
    put(Ref, undefined),
    {ok, A} = wasm:instantiate(Mod, Imports(fun() -> get(Ref) end)),
    put(Ref, wasm_instance:heap(A)),
    {ok, B} = wasm:instantiate(Mod, Imports(fun() -> get(Ref) end),
                               #{link => A}),
    {A, B}.

get_reenter_readers(Inst, _Heap) ->
    {ok, [_]} = wasm:call(Inst, ~"nested", [3]),
    receive {readers, N} -> N after 5000 -> ct:fail(no_reenter) end.

%% The hook is application-wide, so a process opts itself in by naming the
%% window it means to stop in. Nothing else in the node is held.
with_hook(F) ->
    Parent = self(),
    Hook = fun(Where) ->
               case get('$hold_at') of
                   Where -> Parent ! {at, Where, self()},
                            receive proceed -> ok end;
                   _ -> ok
               end
           end,
    ok = application:set_env(wasm, heap_hook, Hook),
    try F() after application:unset_env(wasm, heap_hook) end.

%% Spawn a process that runs `F' and stops inside `Where', and answer once it
%% is actually there. It stays stopped until it is killed or sent `proceed'.
held_at(Where, F) ->
    P = spawn(fun() -> put('$hold_at', Where), F() end),
    receive {at, Where, P} -> P
    after 5000 -> ct:fail({never_reached, Where})
    end.

%% Somebody takes the store exclusively within `Ms`, on a process of its own so
%% that a store which never becomes claimable fails the case rather than
%% wedging it. Answers that process, parked holding the store until it is
%% killed, or `timeout`.
collects_within(Heap, Ms) ->
    Self = self(),
    Tag = make_ref(),
    P = spawn(fun() ->
                  true = wasm_heap:lease(Heap),
                  true = wasm_heap:try_exclusive(Heap),
                  Self ! {Tag, self()},
                  receive never -> ok end
              end),
    receive {Tag, P} -> P
    after Ms -> exit(P, kill), timeout
    end.

kill(Pid) ->
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, _, _, _} -> ok
    after 5000 -> ct:fail({still_alive, Pid})
    end.

%% Ask for a collection and go in and out once. Whoever is last out of a store
%% with a request standing performs it, and a corpse must not stop that being
%% this caller.
next_one_out_collects(Heap) ->
    ok = wasm_heap:request_collect(Heap),
    true = wasm_heap:lease(Heap),
    wasm_heap:unlease(Heap, true).

%% Whether a reader can get into the store within `Ms`, off a process of its
%% own so that a store nobody can get into fails the case rather than wedging
%% it.
%%
%% It gives the lease back before answering, and from the process that took it.
%% Reader rows are keyed by pid, so leasing here and unleasing in the caller
%% would leave the bookkeeping deliberately inconsistent, which is a poor thing
%% for a suite about that bookkeeping to do.
try_lease(Heap, Ms) ->
    Self = self(),
    Tag = make_ref(),
    P = spawn(fun() -> Self ! {Tag, lease_and_leave(Heap)} end),
    receive {Tag, R} -> R
    after Ms -> exit(P, kill), timeout
    end.

lease_and_leave(Heap) ->
    case wasm_heap:lease(Heap) of
        false ->
            false;
        true ->
            case wasm_heap:unlease(Heap, true) of
                collect_now -> ok = wasm_heap:release_exclusive(Heap);
                ok -> ok
            end,
            true
    end.

%% The collector row, read straight out of the heap's own objects table. There
%% is no api for it and there should not be: it exists so a reader can tell a
%% collection in progress from one whose collector is gone, and this asserts
%% that distinction is always available.
collector_rows({wasm_heap, Objs, _, _}) ->
    ets:lookup(Objs, '$wasm_collector').

destroy(Insts) -> [ok = wasm:destroy(I) || I <- Insts], ok.
