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
         re_entrant_calls_take_one_lease/1,
         overlapping_traffic_still_gets_collected/1]).

all() ->
    [a_foreign_process_mid_call_keeps_what_it_holds,
     a_pending_request_blocks_nobody,
     a_collector_killed_mid_sweep_does_not_wedge_the_store,
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
    ok = wasm_heap:unlease(Heap, true),
    ?assertEqual(0, wasm_heap:readers(Heap)).

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

try_lease(Heap, Ms) ->
    Self = self(),
    Tag = make_ref(),
    P = spawn(fun() -> Self ! {Tag, wasm_heap:lease(Heap)} end),
    receive {Tag, R} -> R
    after Ms -> exit(P, kill), timeout
    end.

destroy(Insts) -> [ok = wasm:destroy(I) || I <- Insts], ok.
