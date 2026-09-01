%% @doc The collector: what it reclaims, and what it must not.
%%
%% No specification test checks any of this. The suite asserts that unreachable
%% objects are freed, which is the entire reason the store exists rather than
%% growing forever, and that everything still reachable survives. A collector
%% that freed nothing would pass every conformance test in the repository.
-module(wasm_gc_collect_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(I32, 16#7F).
-define(FB, 16#FB).

all() ->
    [garbage_is_reclaimed,
     an_unreachable_cycle_is_reclaimed,
     a_global_keeps_its_object_alive,
     a_reference_handed_to_the_embedder_survives,
     collection_does_not_run_below_the_threshold,
     a_field_written_before_a_trap_stays_written,
     a_minor_collection_leaves_old_garbage,
     a_major_collection_takes_it,
     the_write_barrier_keeps_a_young_object_alive,
     a_released_reference_is_collected,
     release_all_drops_every_pin,
     a_global_read_by_the_embedder_is_pinned,
     a_store_of_few_large_objects_is_collected,
     a_major_is_due_on_bytes_not_only_rows].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) ->
    application:unset_env(wasm, gc_alloc_threshold),
    ok.

init_per_testcase(_Case, Config) ->
    %% Low enough that a handful of allocations triggers a collection, so the
    %% tests do not have to allocate a hundred thousand objects to observe one.
    application:set_env(wasm, gc_alloc_threshold, 8),
    Config.

end_per_testcase(_Case, _Config) ->
    application:unset_env(wasm, gc_alloc_threshold),
    application:unset_env(wasm, gc_min_major_size),
    application:unset_env(wasm, gc_min_major_pages),
    application:unset_env(wasm, gc_major_ratio),
    ok.

%%% ------------------------------------------------------------------ rule ---

%% Objects nothing refers to are freed. Without this the store grows for the
%% life of the instance and a long-running program built by a garbage-collected
%% language would exhaust the node.
garbage_is_reclaimed(_Config) ->
    {ok, Inst} = instantiate(module_with_gc()),
    %% Each call allocates and drops a struct, so nothing survives it.
    [{ok, []} = wasm:call(Inst, ~"alloc_garbage", []) || _ <- lists:seq(1, 50)],
    ?assert(store_size(Inst) < 20,
            {store_grew_without_bound, store_size(Inst)}),
    ok = wasm:destroy(Inst).

%% A cycle is unreachable even though each of its objects is referenced. This
%% is the case reference counting cannot handle and the reason the collector
%% traces from roots instead.
an_unreachable_cycle_is_reclaimed(_Config) ->
    {ok, Inst} = instantiate(module_with_gc()),
    [{ok, []} = wasm:call(Inst, ~"alloc_cycle", []) || _ <- lists:seq(1, 50)],
    ?assert(store_size(Inst) < 20,
            {cycles_not_reclaimed, store_size(Inst)}),
    ok = wasm:destroy(Inst).

%% Anything reachable from a global survives, however much garbage is created
%% around it.
a_global_keeps_its_object_alive(_Config) ->
    {ok, Inst} = instantiate(module_with_gc()),
    {ok, []} = wasm:call(Inst, ~"keep", []),
    {ok, [Before]} = wasm:call(Inst, ~"kept_value", []),
    ?assertEqual(7, Before),
    [{ok, []} = wasm:call(Inst, ~"alloc_garbage", []) || _ <- lists:seq(1, 50)],
    %% Still readable, and still the same object rather than a fresh one.
    ?assertMatch({ok, [7]}, wasm:call(Inst, ~"kept_value", [])),
    ok = wasm:destroy(Inst).

%% A reference returned to the embedder is not reachable from any root the
%% runtime can see, so it is pinned. Collecting it would leave the embedder
%% holding an index into a slot that has been reused.
a_reference_handed_to_the_embedder_survives(_Config) ->
    {ok, Inst} = instantiate(module_with_gc()),
    {ok, [Ref]} = wasm:call(Inst, ~"alloc_and_return", []),
    ?assertMatch({objref, _}, Ref),
    [{ok, []} = wasm:call(Inst, ~"alloc_garbage", []) || _ <- lists:seq(1, 50)],
    %% The embedder's reference still names a live object.
    ?assertMatch({ok, [7]}, wasm:call(Inst, ~"read", [Ref])),
    ok = wasm:destroy(Inst).

%% Below the threshold nothing is traced, so a call that allocates little pays
%% only the comparison. Asserted by observing that the store is *allowed* to
%% grow when the threshold is high.
collection_does_not_run_below_the_threshold(_Config) ->
    application:set_env(wasm, gc_alloc_threshold, 1000000),
    {ok, Inst} = instantiate(module_with_gc()),
    [{ok, []} = wasm:call(Inst, ~"alloc_garbage", []) || _ <- lists:seq(1, 50)],
    ?assert(store_size(Inst) >= 50,
            {collected_below_threshold, store_size(Inst)}),
    ok = wasm:destroy(Inst).

%% Object writes take effect immediately, so a trap does not roll them back.
%%
%% This changed when the store left `#mut{}'. Globals and tables are still
%% committed only on success, because they are part of the state term and a
%% trapping call never writes it back. Linear memory has always behaved this
%% way, the specification describes no rollback at all, and a store that is
%% shared cannot be un-shared when one caller fails.
a_field_written_before_a_trap_stays_written(_Config) ->
    application:set_env(wasm, gc_alloc_threshold, 1000000),
    {ok, Inst} = instantiate(module_with_gc()),
    {ok, []} = wasm:call(Inst, ~"keep", []),
    ?assertMatch({ok, [7]}, wasm:call(Inst, ~"kept_value", [])),
    %% Writes 42 into the kept struct, then traps.
    ?assertMatch({error, #{class := trap, kind := unreachable}},
                 wasm:call(Inst, ~"write_then_trap", [])),
    ?assertMatch({ok, [42]}, wasm:call(Inst, ~"kept_value", [])),
    ok = wasm:destroy(Inst).

%% A minor collection never frees an old object, however unreachable.
%%
%% That is the trade the generation makes: it will not look at the old
%% generation, so it cannot pay for it, and it cannot reclaim from it either.
a_minor_collection_leaves_old_garbage(_Config) ->
    never_major(),
    collect_every_call(),
    {ok, Inst} = instantiate(module_with_gc()),
    %% Allocating and collecting in one call leaves the kept struct live, so it
    %% is promoted: the nursery starts again above it.
    {ok, []} = wasm:call(Inst, ~"keep", []),
    ?assertEqual(1, store_size(Inst)),
    %% Now nothing refers to it, but it is old.
    {ok, []} = wasm:call(Inst, ~"forget", []),
    {ok, []} = wasm:call(Inst, ~"alloc_garbage", []),
    ?assertEqual(1, store_size(Inst)),
    ok = wasm:destroy(Inst).

%% A major collection does take it. This is what stops the old generation
%% growing without bound, and it is the long pause.
a_major_collection_takes_it(_Config) ->
    never_major(),
    collect_every_call(),
    {ok, Inst} = instantiate(module_with_gc()),
    {ok, []} = wasm:call(Inst, ~"keep", []),
    {ok, []} = wasm:call(Inst, ~"forget", []),
    {ok, []} = wasm:call(Inst, ~"alloc_garbage", []),
    ?assertEqual(1, store_size(Inst)),
    always_major(),
    {ok, []} = wasm:call(Inst, ~"alloc_garbage", []),
    ?assertEqual(0, store_size(Inst)),
    ok = wasm:destroy(Inst).

%% An old object pointing at a young one keeps it alive.
%%
%% This is the case the write barrier exists for, and the one that breaks
%% silently without it. A minor collection does not trace old objects, so
%% nothing would reach the young struct through its old holder, and it would be
%% freed while still referenced. `attached_value' would then trap rather than
%% answer 3.
the_write_barrier_keeps_a_young_object_alive(_Config) ->
    never_major(),
    collect_every_call(),
    {ok, Inst} = instantiate(module_with_gc()),
    {ok, []} = wasm:call(Inst, ~"keep", []),     % kept, and now old
    {ok, []} = wasm:call(Inst, ~"attach", []),   % a young struct inside it
    ?assertEqual(2, store_size(Inst)),
    %% A minor collection that did not know about the write would free it.
    {ok, []} = wasm:call(Inst, ~"alloc_garbage", []),
    ?assertEqual(2, store_size(Inst)),
    ?assertMatch({ok, [3]}, wasm:call(Inst, ~"attached_value", [])),
    ok = wasm:destroy(Inst).

%% A reference the embedder releases stops being a root.
%%
%% Without this the pin set grew for the life of the instance: every reference
%% ever returned stayed a root, so an embedder calling a function that returns a
%% struct a million times kept a million objects alive. It was a list rebuilt
%% with `lists:usort/1' on every call, so it cost time as well as memory.
a_released_reference_is_collected(_Config) ->
    always_major(),
    collect_every_call(),
    {ok, Inst} = instantiate(module_with_gc()),
    {ok, [Ref]} = wasm:call(Inst, ~"alloc_and_return", []),
    %% Pinned on the way out, so allocation cannot free it.
    {ok, []} = wasm:call(Inst, ~"alloc_garbage", []),
    ?assertMatch({ok, [7]}, wasm:call(Inst, ~"read", [Ref])),
    ok = wasm:release(Inst, Ref),
    {ok, []} = wasm:call(Inst, ~"alloc_garbage", []),
    ?assertEqual(0, store_size(Inst)),
    ok = wasm:destroy(Inst).

%% Releasing everything is one call, for an embedder that scopes references to a
%% request rather than tracking each one.
release_all_drops_every_pin(_Config) ->
    always_major(),
    collect_every_call(),
    {ok, Inst} = instantiate(module_with_gc()),
    [{ok, [_]} = wasm:call(Inst, ~"alloc_and_return", [])
     || _ <- lists:seq(1, 10)],
    ?assertEqual(10, store_size(Inst)),
    ok = wasm:release_all(Inst),
    {ok, []} = wasm:call(Inst, ~"alloc_garbage", []),
    ?assertEqual(0, store_size(Inst)),
    ok = wasm:destroy(Inst).

%% A reference read out of a global is leaving the runtime just as a call result
%% is, and was not pinned. The embedder held an id the next collection freed.
a_global_read_by_the_embedder_is_pinned(_Config) ->
    always_major(),
    collect_every_call(),
    {ok, Inst} = instantiate(module_with_gc()),
    {ok, []} = wasm:call(Inst, ~"keep", []),
    {ok, [Ref]} = wasm:get_global(Inst, ~"g"),
    ?assertMatch({objref, _}, Ref),
    {ok, []} = wasm:call(Inst, ~"forget", []),
    {ok, []} = wasm:call(Inst, ~"alloc_garbage", []),
    ?assertMatch({ok, [7]}, wasm:call(Inst, ~"read", [Ref])),
    ok = wasm:destroy(Inst).

%%% ---------------------------------------------------------------- helpers ---

%% One allocation is enough to collect, so the store size after any allocating
%% call is exactly what survived it. Anything less deterministic leaves young
%% garbage lying around and the counts stop meaning what they say.
collect_every_call() -> application:set_env(wasm, gc_alloc_threshold, 1).

%% Both floors. A major is due on rows *or* on bytes since `major_due/1` learned
%% to see a store that is large without holding many rows, so a control that
%% raises only the row floor stops controlling anything the moment a test's
%% store passes a megabyte.
never_major() ->
    application:set_env(wasm, gc_min_major_size, 1 bsl 40),
    application:set_env(wasm, gc_min_major_pages, 1 bsl 40).
%% Both settings, not just the floor: with the default ratio a major only runs
%% once the store has doubled since the last one, so a test that wants every
%% collection to trace everything has to say so.
always_major() ->
    application:set_env(wasm, gc_min_major_size, 0),
    application:set_env(wasm, gc_min_major_pages, 0),
    application:set_env(wasm, gc_major_ratio, 1).

instantiate(Bin) ->
    {ok, Mod} = wasm:load(Bin),
    wasm:instantiate(Mod, #{}).

store_size(Inst) -> wasm_heap:size(wasm_instance:heap(Inst)).

%% ```
%% (type $s (struct (field (mut i32)) (field (mut (ref null $s)))))
%% (global $g (mut (ref null $s)) (ref.null $s))
%%
%% (func (export "alloc_garbage")      ;; allocates, keeps nothing
%%   (drop (struct.new_default $s)))
%% (func (export "alloc_cycle")        ;; two objects pointing at each other
%%   (local $a (ref null $s)) (local $b (ref null $s))
%%   ...)
%% (func (export "keep")               ;; stores one in the global
%%   (global.set $g (struct.new $s (i32.const 7) (ref.null $s))))
%% (func (export "kept_value") (result i32) ...)
%% (func (export "alloc_and_return") (result (ref null $s)) ...)
%% (func (export "read") (param (ref null $s)) (result i32) ...)
%% ```
module_with_gc() ->
    SRef = <<16#63, 0>>,                        % (ref null $s), type index 0
    Struct = [16#5F, wasm_asm:uleb(2),          % struct, 2 fields
              ?I32, 1,                          %   (field (mut i32))
              SRef, 1],                         %   (field (mut (ref null $s)))
    Types = wasm_asm:section(
              1, [wasm_asm:uleb(5),
                  Struct,
                  [16#60, wasm_asm:uleb(0), wasm_asm:uleb(0)],          % ()->()
                  [16#60, wasm_asm:uleb(0), wasm_asm:uleb(1), ?I32],    % ()->i32
                  [16#60, wasm_asm:uleb(1), SRef, wasm_asm:uleb(1), ?I32],
                  [16#60, wasm_asm:uleb(0), wasm_asm:uleb(1), SRef]]),  % ()->ref
    %% struct.new_default $s ; drop
    Garbage = <<?FB, 1, 0, 16#1A, 16#0B>>,
    %% Two structs, each stored into the other's reference field.
    Cycle = <<?FB, 1, 0,                        % a = struct.new_default
              16#21, 0,                         % local.set 0
              ?FB, 1, 0,                        % b = struct.new_default
              16#21, 1,                         % local.set 1
              16#20, 0, 16#20, 1, ?FB, 5, 0, 1, % a.field1 = b
              16#20, 1, 16#20, 0, ?FB, 5, 0, 1, % b.field1 = a
              16#0B>>,
    CycleLocals = <<1, 2, 16#63, 0>>,           % 2 locals of (ref null $s)
    %% global.set 0 (struct.new $s (i32.const 7) (ref.null $s))
    Keep = <<16#41, 7, 16#D0, 0, ?FB, 0, 0, 16#24, 0, 16#0B>>,
    %% (struct.get $s 0 (global.get 0))
    KeptValue = <<16#23, 0, ?FB, 2, 0, 0, 16#0B>>,
    AllocReturn = <<16#41, 7, 16#D0, 0, ?FB, 0, 0, 16#0B>>,
    Read = <<16#20, 0, ?FB, 2, 0, 0, 16#0B>>,
    %% (struct.set $s 1 (global.get $g) (struct.new $s (i32.const 3) null))
    Attach = <<16#23, 0, 16#41, 3, 16#D0, 0, ?FB, 0, 0, ?FB, 5, 0, 1, 16#0B>>,
    %% (struct.get $s 0 (struct.get $s 1 (global.get $g)))
    AttachedValue = <<16#23, 0, ?FB, 2, 0, 1, ?FB, 2, 0, 0, 16#0B>>,
    Forget = <<16#D0, 0, 16#24, 0, 16#0B>>,
    %% (struct.set $s 0 (global.get 0) (i32.const 42)) then unreachable
    WriteThenTrap = <<16#23, 0, 16#41, 42, ?FB, 5, 0, 0, 16#00, 16#0B>>,
    wasm_asm:module(
      [Types,
       wasm_asm:func_section([1, 1, 1, 2, 4, 3, 1, 1, 2, 1]),
       %% (global (mut (ref null $s)) (ref.null $s))
       wasm_asm:section(6, [wasm_asm:uleb(1), SRef, 1, 16#D0, 0, 16#0B]),
       wasm_asm:export_section([{~"alloc_garbage", 0, 0},
                                {~"alloc_cycle", 0, 1},
                                {~"keep", 0, 2},
                                {~"kept_value", 0, 3},
                                {~"alloc_and_return", 0, 4},
                                {~"read", 0, 5},
                                {~"write_then_trap", 0, 6},
                                {~"attach", 0, 7},
                                {~"attached_value", 0, 8},
                                {~"forget", 0, 9},
                                {~"g", 3, 0}]),
       wasm_asm:section(10, [wasm_asm:uleb(10),
                             body(<<0>>, Garbage),
                             body(CycleLocals, Cycle),
                             body(<<0>>, Keep),
                             body(<<0>>, KeptValue),
                             body(<<0>>, AllocReturn),
                             body(<<0>>, Read),
                             body(<<0>>, WriteThenTrap),
                             body(<<0>>, Attach),
                             body(<<0>>, AttachedValue),
                             body(<<0>>, Forget)])]).

body(Locals, Code) ->
    Bin = <<Locals/binary, Code/binary>>,
    [wasm_asm:uleb(byte_size(Bin)), Bin].

%%% ------------------------------------------------------- large and few ---

%% A store can be enormous and hold five rows, and until this it was then never
%% collected at all.
%%
%% Every heuristic here counted objects. `major_due/1` compares `size/1`, a row
%% count, against a floor of four thousand, so a workload replacing one large
%% array per call never reached it and never got a major collection; a minor one
%% leaves the old generation alone by design, which is what
%% `a_minor_collection_leaves_old_garbage` above asserts. So the arrays piled up
%% while exactly one was reachable: four rounds of a fifty thousand element
%% array left all four, sixteen megabytes.
%%
%% Invisible until the store was charged against the node page budget, because
%% nothing measured bytes. Then it stopped being a leak and became a refusal.
a_store_of_few_large_objects_is_collected(_Config) ->
    {ok, Inst} = wasm:instantiate(big_array_module(), #{}),
    Heap = wasm_instance:heap(Inst),
    Rounds = [begin
                  {ok, [_]} = wasm:call(Inst, ~"replace", [20000]),
                  wasm_heap:size(Heap)
              end || _ <- lists:seq(1, 8)],
    ct:log("store size per round: ~p", [Rounds]),
    %% Bounded, not monotonic. One array is reachable at a time, so the store
    %% holds one or two of them and never eight.
    ?assert(lists:max(Rounds) =< 4,
            {store_grew_without_bound, Rounds}),
    ok = wasm:destroy(Inst).

%% The rule itself, without a workload around it: under the row floor and over
%% the page floor answers true.
a_major_is_due_on_bytes_not_only_rows(_Config) ->
    never_major(),                       % raises both floors out of the way
    {ok, Inst} = wasm:instantiate(big_array_module(), #{}),
    Heap = wasm_instance:heap(Inst),
    {ok, [_]} = wasm:call(Inst, ~"replace", [20000]),
    ?assert(wasm_heap:size(Heap) < 4096,
            {not_the_case_this_is_about, wasm_heap:size(Heap)}),
    ?assertNot(wasm_heap:major_due(Heap)),
    %% Now let the page floor apply. The store is megabytes, so it is due.
    application:set_env(wasm, gc_min_major_pages, 1),
    ?assert(wasm_heap:major_due(Heap)),
    ok = wasm:destroy(Inst).

%% One array per call, each replacing the last, so only one is ever reachable
%% and the store grows only if nothing collects it.
big_array_module() ->
    {ok, M} = wasm:compile({wat, ~"""
    (module
      (type $a (array (mut i64)))
      (global $k (mut (ref null $a)) (ref.null $a))
      (func (export "replace") (param i32) (result i32) (local $i i32)
        (global.set $k (array.new_default $a (local.get 0)))
        (block $o (loop $l
          (br_if $o (i32.ge_u (local.get $i) (local.get 0)))
          (array.set $a (global.get $k) (local.get $i) (i64.const 7))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $l)))
        (local.get $i)))
    """}),
    M.
