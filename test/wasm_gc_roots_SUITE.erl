%% @doc Roots the collector could not see, and the moments it must not run.
%%
%% Every case here is a way to lose a live object. None of them was among the
%% roots the collector traced from, so each one passed every other test in the
%% repository while being wrong.
-module(wasm_gc_roots_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(I32, 16#7F).
-define(FB, 16#FB).

all() ->
    [a_passive_element_segment_is_a_root,
     a_dropped_element_segment_is_not_a_root,
     a_nested_call_does_not_collect,
     a_failed_instantiation_leaves_no_heap,
     a_linked_instance_shares_one_store,
     another_instances_global_is_a_root,
     an_unlinked_reference_traps,
     a_shared_store_outlives_one_instance,
     destroy_releases_the_state_and_repeats_safely,
     an_array_of_numbers_is_never_walked,
     a_reentrant_call_keeps_its_writes,
     a_root_view_works_from_a_process_with_a_cold_cache,
     a_root_view_of_a_destroyed_instance_is_not_a_crash,
     a_guest_cannot_outgrow_the_node_budget,
     a_heap_gives_its_pages_back_when_collected,
     a_shared_heap_is_charged_once,
     a_linked_instance_over_its_ceiling_is_refused,
     a_refused_write_leaves_no_row,
     a_whole_array_fill_gives_its_pages_back,
     concurrent_reconciles_never_lower_a_live_charge].

%% The collector reads its roots through `wasm_instance:mut_of/1', which is
%% handed a root view rather than an instance: four fields, no `#inst{}'. A
%% change that made the cache path require an instance therefore crashed every
%% collection running where the cache was cold, which is any process that has
%% not called that instance, and dialyzer could not see it because `mut_of/1'
%% takes a `term()'. Both shapes are pinned here.
a_root_view_works_from_a_process_with_a_cold_cache(_Config) ->
    {ok, Inst} = one_global_instance(),
    View = wasm_instance:root_view(Inst),
    Self = self(),
    spawn(fun() -> Self ! {mut, try wasm_instance:mut_of(View)
                                catch C:E -> {'EXIT', {C, E}} end} end),
    receive
        {mut, {'EXIT', Why}} -> ct:fail({crashed, Why});
        {mut, Mut} -> ?assert(is_tuple(Mut))
    after 5000 -> ct:fail(no_answer)
    end,
    ok = wasm:destroy(Inst).

a_root_view_of_a_destroyed_instance_is_not_a_crash(_Config) ->
    {ok, Inst} = one_global_instance(),
    View = wasm_instance:root_view(Inst),
    ok = wasm:destroy(Inst),
    Self = self(),
    spawn(fun() -> Self ! {mut, try wasm_instance:mut_of(View)
                                catch C:E -> {'EXIT', {C, E}} end} end),
    receive
        %% A dead instance is reported, not crashed into: the state table is
        %% gone and `load_mut/1' turns that into a structured error.
        {mut, {'EXIT', {{wasm_error, _}, _}}} -> ok;
        {mut, {'EXIT', {wasm_error, _}}} -> ok;
        {mut, Other} -> ?assert(is_tuple(Other))
    after 5000 -> ct:fail(no_answer)
    end.

%% A module with one global, which is enough to have mutable state worth
%% reading through a root view.
one_global_instance() ->
    Src = ~"(module (global (mut i32) (i32.const 7)) (memory 1)
            (func (export \"f\") (result i32) (i32.const 1)))",
    {ok, P} = wasm_wat:module(Src),
    {ok, M} = wasm_validate:module(P),
    wasm:instantiate(M, #{}).

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) ->
    application:unset_env(wasm, gc_alloc_threshold),
    ok.

init_per_testcase(_Case, Config) ->
    %% Low enough that a handful of allocations collects.
    application:set_env(wasm, gc_alloc_threshold, 8),
    Config.

end_per_testcase(_Case, _Config) ->
    application:unset_env(wasm, gc_alloc_threshold),
    application:unset_env(wasm, gc_major_ratio),
    application:unset_env(wasm, gc_min_major_size),
    ok.

%%% ------------------------------------------------------------------ rule ---

%% A passive element segment holds constant expressions, and `struct.new' is a
%% constant expression, so a segment can be the only thing referring to an
%% object.
%%
%% Segments live in the *immutable* half of the instance. The collector reads
%% its roots from the mutable half, so it never saw them: the object was freed
%% at the first collection and `array.new_elem' then handed out a reference into
%% a slot that had been reset.
a_passive_element_segment_is_a_root(_Config) ->
    {ok, Inst} = instantiate(segment_module()),
    %% One object, allocated by the segment's initialiser at instantiation.
    ?assertEqual(1, store_size(Inst)),
    churn(Inst),
    ?assertEqual(1, store_size(Inst)),
    %% And it is still the object the segment names, not a slot reused since.
    ?assertMatch({ok, [7]}, wasm:call(Inst, ~"take", [])),
    ok = wasm:destroy(Inst).

%% A dropped segment can never be read again, so holding it as a root would
%% retain garbage the module has explicitly finished with.
a_dropped_element_segment_is_not_a_root(_Config) ->
    {ok, Inst} = instantiate(segment_module()),
    ?assertEqual(1, store_size(Inst)),
    {ok, []} = wasm:call(Inst, ~"drop_segment", []),
    churn(Inst),
    ?assertEqual(0, store_size(Inst)),
    ok = wasm:destroy(Inst).

%% A host import may call another instance, and that inner call must not
%% collect. It returns into a live interpreter frame whose locals and operand
%% stack hold references no root can see.
%%
%% The other instance is deliberate. Re-entering the *same* instance is
%% legitimate too (`linking.wast` requires it), but a nested call there reads
%% the state as of the last write-back and the outer call's write-back then
%% discards whatever it did, so the hazard cannot be observed through it yet.
%% That is a separate defect, and it is what makes this guard load bearing the
%% moment the object store moves out of `#mut{}'.
a_nested_call_does_not_collect(_Config) ->
    Self = self(),
    {ok, OtherMod} = wasm:load(segment_module()),
    {ok, Other} = wasm:instantiate(OtherMod, #{}),
    Imports = #{{~"host", ~"reenter"} =>
                    fun(_Ctx, []) ->
                        {ok, []} = wasm:call(Other, ~"garbage", [64]),
                        Self ! reentered,
                        {ok, []}
                    end},
    {ok, Mod} = wasm:load(reentrant_module()),
    {ok, Inst} = wasm:instantiate(Mod, Imports),
    %% `keep_across_host' holds a struct in a local, calls the host import in
    %% the middle, and reads its field afterwards.
    ?assertMatch({ok, [7]}, wasm:call(Inst, ~"keep_across_host", [])),
    receive reentered -> ok after 1000 -> ct:fail(host_never_ran) end,
    %% The nested call ran below a live frame, so it collected nothing: the
    %% segment's object is still there alongside the garbage it made.
    ?assert(store_size(Other) > 1, {collected_below_a_live_frame,
                                    store_size(Other)}),
    ok = wasm:destroy(Inst),
    ok = wasm:destroy(Other).

%% An instantiation that fails after a constant expression has allocated must
%% not leave its heap behind.
%%
%% It used to. Constant-expression evaluation threaded its allocation store
%% through the process dictionary and erased it only on the way to a finished
%% instance, so the next instantiation in the same process adopted a heap it had
%% not allocated. The store is a handle now and there is nothing to thread, but
%% the tables it names still have to be released, which is why the heap is
%% created before `build/4' rather than inside it.
a_failed_instantiation_leaves_no_heap(_Config) ->
    {ok, Bad} = wasm:load(allocating_module_with_missing_import()),
    ?assertMatch({error, #{class := link}}, wasm:instantiate(Bad, #{})),
    {ok, Good} = wasm:load(empty_module()),
    {ok, Inst} = wasm:instantiate(Good, #{}),
    ?assertEqual(0, store_size(Inst)),
    ok = wasm:destroy(Inst).

%% Two modules sharing a table exchange object references through it, so they
%% have to share one store: a reference is an id, and an id means nothing in
%% another store. The object must also survive a collection triggered by the
%% instance that did not allocate it.
a_linked_instance_shares_one_store(_Config) ->
    {Producer, Consumer, Table} = linked_pair(),
    %% The producer allocates a struct and parks it in the shared table.
    {ok, []} = wasm:call(Producer, ~"put", []),
    %% The consumer reads it back out of the table and through the reference.
    ?assertMatch({ok, [7]}, wasm:call(Consumer, ~"get", [])),
    %% Collections triggered from the consumer must not free it: it is reachable
    %% only from a table, and only the producer allocated into this store.
    churn(Consumer),
    ?assertMatch({ok, [7]}, wasm:call(Consumer, ~"get", [])),
    ok = wasm:destroy(Consumer),
    ok = wasm:destroy(Producer),
    _ = Table,
    ok.

%% A collection triggered by one instance has to trace every instance sharing
%% the store, not just the one being called.
%%
%% Here the object is reachable only from the *producer's* private global, and
%% the collection runs at the end of a call into the consumer. Tracing only the
%% collecting instance's roots would free it, and the producer would then read
%% through a reference to a deleted row.
another_instances_global_is_a_root(_Config) ->
    {Producer, Consumer, _Table} = linked_pair(),
    {ok, []} = wasm:call(Producer, ~"keep", []),
    ?assertMatch({ok, [5]}, wasm:call(Producer, ~"kept", [])),
    churn(Consumer),
    ?assertMatch({ok, [5]}, wasm:call(Producer, ~"kept", [])),
    ok = wasm:destroy(Consumer),
    ok = wasm:destroy(Producer).

%% Without `link` the two instances have separate stores, so the consumer holds
%% an id that names nothing it can reach. That is a trap naming the problem, not
%% a crash and not a silent read of whatever object happens to have that id.
an_unlinked_reference_traps(_Config) ->
    {ok, PMod} = wasm:load(producer_module()),
    {ok, Producer} = wasm:instantiate(PMod, #{}),
    {ok, Table} = wasm:extern(Producer, ~"table"),
    {ok, CMod} = wasm:load(consumer_module()),
    {ok, Consumer} = wasm:instantiate(CMod, #{{~"env", ~"t"} => Table}),
    {ok, []} = wasm:call(Producer, ~"put", []),
    ?assertMatch({error, #{class := trap, kind := foreign_reference}},
                 wasm:call(Consumer, ~"get", [])),
    ok = wasm:destroy(Consumer),
    ok = wasm:destroy(Producer).

%% Destroying one of two linked instances must not take the store with it.
a_shared_store_outlives_one_instance(_Config) ->
    {Producer, Consumer, _Table} = linked_pair(),
    {ok, []} = wasm:call(Producer, ~"put", []),
    ok = wasm:destroy(Producer),
    %% The producer is gone; the object it allocated is still readable.
    ?assertMatch({ok, [7]}, wasm:call(Consumer, ~"get", [])),
    ok = wasm:destroy(Consumer).

%% `destroy/1' releases the state table and this process's cache of it, and
%% survives being called twice.
%%
%% Both used to outlive the instance. The table is owned by the creating
%% process, so a process making and discarding many instances accumulated one
%% each; and `wasm_instance:mut/1' caches the whole state in the process
%% dictionary, keyed by instance id, and never erased it. A second `destroy/1'
%% also decremented the node's page count a second time.
destroy_releases_the_state_and_repeats_safely(_Config) ->
    Before = wasm_engine:pages_in_use(),
    {ok, Inst} = instantiate(memory_module()),
    ?assert(wasm_engine:pages_in_use() > Before),
    Tables = length(ets:all()),
    ok = wasm:destroy(Inst),
    ?assertEqual(Before, wasm_engine:pages_in_use()),
    ?assert(length(ets:all()) < Tables,
            {state_table_not_released, Tables, length(ets:all())}),
    ?assertEqual(undefined, get({wasm_mut_cache, element(2, Inst)})),
    %% Twice is not twice the release.
    ok = wasm:destroy(Inst),
    ?assertEqual(Before, wasm_engine:pages_in_use()),
    ok.

%% An array whose elements cannot be references is a leaf: the collector marks
%% it and never walks it. Asserted by observing that a live array of a hundred
%% thousand written i32 elements does not slow collection down the way an array
%% of references does.
an_array_of_numbers_is_never_walked(_Config) ->
    application:set_env(wasm, gc_alloc_threshold, 1000000),
    %% Force every collection to be major, so both arrays are actually traced.
    %% A minor collection would trace neither: they are old by then, and not
    %% tracing old objects is the point of the generation.
    application:set_env(wasm, gc_major_ratio, 1),
    application:set_env(wasm, gc_min_major_size, 0),
    {ok, Inst} = instantiate(array_module()),
    {ok, []} = wasm:call(Inst, ~"fill_numbers", [50000]),
    Heap = wasm_instance:heap(Inst),
    {ok, [Root]} = wasm:call(Inst, ~"head", []),
    Numbers = time_collect(Heap, [Root]),
    {ok, []} = wasm:call(Inst, ~"fill_refs", [50000]),
    {ok, [Root2]} = wasm:call(Inst, ~"head_refs", []),
    Refs = time_collect(Heap, [Root, Root2]),
    ct:log("collect: numeric array ~p us, reference array ~p us",
           [Numbers, Refs]),
    ?assert(Refs > Numbers * 2,
            {numeric_array_was_walked, Numbers, Refs}),
    ok = wasm:destroy(Inst).

time_collect(Heap, Roots) ->
    lists:min([begin
                   T0 = erlang:monotonic_time(microsecond),
                   ok = wasm_heap:collect(Heap, Roots),
                   erlang:monotonic_time(microsecond) - T0
               end || _ <- lists:seq(1, 5)]).

%% A host import calling back into its own instance keeps what it did.
%%
%% It did not. The nested call read the state as of the last write-back, so it
%% could not see what the outer call had done, and the outer call's own
%% write-back then discarded whatever the nested one did: a host import that
%% called back and allocated four objects left a store of four, and the outer
%% call's return dropped it to one.
%%
%% Refusing re-entrancy is not the answer. The specification requires it, and
%% `linking.wast` calls back into a module that is still running.
a_reentrant_call_keeps_its_writes(_Config) ->
    Self = self(),
    Imports = #{{~"host", ~"reenter"} =>
                    fun(#{instance := Inst}, []) ->
                        {ok, []} = wasm:call(Inst, ~"bump", []),
                        {ok, [N]} = wasm:call(Inst, ~"count", []),
                        Self ! {inner, N},
                        {ok, []}
                    end},
    {ok, Mod} = wasm:load(reentrant_module()),
    {ok, Inst} = wasm:instantiate(Mod, Imports),
    %% The outer call bumps the counter once itself before calling the host, so
    %% the nested call has something of the outer call's to see.
    ?assertMatch({ok, [7]}, wasm:call(Inst, ~"keep_across_host", [])),
    Inner = receive {inner, N} -> N after 1000 -> ct:fail(host_never_ran) end,
    ?assertEqual(2, Inner, {nested_call_saw_stale_state, Inner}),
    %% And the nested call's write survived the outer call's write-back.
    ?assertMatch({ok, [2]}, wasm:call(Inst, ~"count", [])),
    ok = wasm:destroy(Inst).

%%% --------------------------------------------------------------- helpers ---

%% A producer exporting a table, and a consumer importing it and sharing the
%% producer's store.
linked_pair() ->
    {ok, PMod} = wasm:load(producer_module()),
    {ok, Producer} = wasm:instantiate(PMod, #{}),
    {ok, Table} = wasm:extern(Producer, ~"table"),
    {ok, CMod} = wasm:load(consumer_module()),
    {ok, Consumer} = wasm:instantiate(CMod, #{{~"env", ~"t"} => Table},
                                      #{link => Producer}),
    {Producer, Consumer, Table}.

instantiate(Bin) ->
    {ok, Mod} = wasm:load(Bin),
    wasm:instantiate(Mod, #{}).

store_size(Inst) -> wasm_heap:size(wasm_instance:heap(Inst)).

%% Allocates and drops enough to take the collector past its threshold.
churn(Inst) ->
    {ok, []} = wasm:call(Inst, ~"garbage", [64]),
    ok.

%%% -------------------------------------------------------- module builders ---

%% ```
%% (type $s (struct (field (mut i32))))
%% (type $a (array (mut (ref null $s))))
%% (elem $e (ref null $s) (item (struct.new $s (i32.const 7))))   ;; passive
%%
%% (func (export "take") (result i32)
%%   (struct.get $s 0 (array.get $a (array.new_elem $a $e (i32.const 0)
%%                                                        (i32.const 1))
%%                                  (i32.const 0))))
%% (func (export "drop_segment") (elem.drop $e))
%% (func (export "garbage") (param i32))
%% ```
segment_module() ->
    SRef = [16#63, 0],
    Types = wasm_asm:section(
              1, [wasm_asm:uleb(5),
                  [16#5F, wasm_asm:uleb(1), ?I32, 1],            % 0: struct
                  [16#5E, SRef, 1],                              % 1: array
                  [16#60, wasm_asm:uleb(0), wasm_asm:uleb(1), ?I32],   % 2
                  [16#60, wasm_asm:uleb(0), wasm_asm:uleb(0)],         % 3
                  [16#60, wasm_asm:uleb(1), ?I32, wasm_asm:uleb(0)]]), % 4
    %% Segment form 5: passive, with a reference type and constant expressions.
    Elem = wasm_asm:section(
             9, [wasm_asm:uleb(1),
                 16#05, SRef, wasm_asm:uleb(1),
                 [16#41, 7, ?FB, 0, 0, 16#0B]]),
    Take = <<?FB, 10, 1, 0,                    % array.new_elem $a $e
             16#41, 0,                         % i32.const 0
             ?FB, 11, 1,                       % array.get $a
             ?FB, 2, 0, 0,                     % struct.get $s 0
             16#0B>>,
    %% array.new_elem takes (offset, len); both are pushed before it.
    TakeFull = <<16#41, 0, 16#41, 1, Take/binary>>,
    DropSeg = <<16#FC, 13, 0, 16#0B>>,         % elem.drop 0
    Garbage = garbage_body(),
    wasm_asm:module(
      [Types,
       wasm_asm:func_section([2, 3, 4]),
       wasm_asm:export_section([{~"take", 0, 0}, {~"drop_segment", 0, 1},
                                {~"garbage", 0, 2}]),
       Elem,
       wasm_asm:code_section([TakeFull, DropSeg, Garbage])]).

%% ```
%% (import "host" "reenter" (func $reenter))
%% (type $s (struct (field (mut i32))))
%%
%% (func (export "keep_across_host") (result i32)
%%   (local $k (ref null $s))
%%   (local.set $k (struct.new $s (i32.const 7)))
%%   (call $reenter)
%%   (struct.get $s 0 (local.get $k)))
%% (func (export "garbage") (param i32))
%% ```
reentrant_module() ->
    Types = wasm_asm:section(
              1, [wasm_asm:uleb(4),
                  [16#5F, wasm_asm:uleb(1), ?I32, 1],                  % 0
                  [16#60, wasm_asm:uleb(0), wasm_asm:uleb(0)],         % 1
                  [16#60, wasm_asm:uleb(0), wasm_asm:uleb(1), ?I32],   % 2
                  [16#60, wasm_asm:uleb(1), ?I32, wasm_asm:uleb(0)]]), % 3
    Import = wasm_asm:section(
               2, [wasm_asm:uleb(1),
                   wasm_asm:name(~"host"), wasm_asm:name(~"reenter"),
                   16#00, wasm_asm:uleb(1)]),
    Body = <<16#41, 7, ?FB, 0, 0,              % struct.new $s (i32.const 7)
             16#21, 0,                         % local.set $k
             16#23, 0, 16#41, 1, 16#6A, 16#24, 0,   % $n = $n + 1
             16#10, 0,                         % call $reenter
             16#20, 0,                         % local.get $k
             ?FB, 2, 0, 0,                     % struct.get $s 0
             16#0B>>,
    Keep = <<1, 1, 16#63, 0, Body/binary>>,    % (local (ref null $s))
    Garbage = <<0, (garbage_body())/binary>>,
    Bump = <<0, 16#23, 0, 16#41, 1, 16#6A, 16#24, 0, 16#0B>>,
    Count = <<0, 16#23, 0, 16#0B>>,
    wasm_asm:module(
      [Types,
       Import,
       wasm_asm:func_section([2, 3, 1, 2]),
       %% A plain mutable global. Globals are still part of the state a call
       %% threads and writes back, which is what a nested call could not see.
       wasm_asm:global_section([{?I32, true, <<16#41, 0>>}]),
       wasm_asm:export_section([{~"keep_across_host", 0, 1},
                                {~"garbage", 0, 2},
                                {~"bump", 0, 3},
                                {~"count", 0, 4}]),
       wasm_asm:section(10, [wasm_asm:uleb(4),
                             wasm_asm:uleb(byte_size(Keep)), Keep,
                             wasm_asm:uleb(byte_size(Garbage)), Garbage,
                             wasm_asm:uleb(byte_size(Bump)), Bump,
                             wasm_asm:uleb(byte_size(Count)), Count])]).

%% A global initialiser that allocates, followed by a memory import nothing
%% supplies. Globals are built before memories, so the struct is allocated and
%% then instantiation fails.
allocating_module_with_missing_import() ->
    SRef = [16#63, 0],
    Types = wasm_asm:section(
              1, [wasm_asm:uleb(1), [16#5F, wasm_asm:uleb(1), ?I32, 1]]),
    Import = wasm_asm:section(
               2, [wasm_asm:uleb(1),
                   wasm_asm:name(~"missing"), wasm_asm:name(~"mem"),
                   16#02, wasm_asm:limits(16#00, 1, undefined)]),
    Global = wasm_asm:section(
               6, [wasm_asm:uleb(1), SRef, 1, 16#41, 7, ?FB, 0, 0, 16#0B]),
    wasm_asm:module([Types, Import, Global]).

empty_module() -> wasm_asm:module([]).

%% One page of memory, so `destroy/1' has pages to release.
memory_module() ->
    wasm_asm:module([wasm_asm:memory_section(16#00, 1, undefined)]).

%% ```
%% (type $ints (array (mut i32)))            ;; a leaf: never walked
%% (type $refs (array (mut (ref null $ints))))
%% (global $a (mut (ref null $ints))) (global $b (mut (ref null $refs)))
%% (func (export "fill_numbers") (param i32))  ;; n written i32 elements
%% (func (export "fill_refs") (param i32))     ;; n written reference elements
%% (func (export "head") (result (ref null $ints)))
%% (func (export "head_refs") (result (ref null $refs)))
%% ```
array_module() ->
    IntsRef = [16#63, 0],
    RefsRef = [16#63, 1],
    Types = wasm_asm:section(
              1, [wasm_asm:uleb(5),
                  [16#5E, ?I32, 1],                                    % 0
                  [16#5E, IntsRef, 1],                                 % 1
                  [16#60, wasm_asm:uleb(1), ?I32, wasm_asm:uleb(0)],   % 2
                  [16#60, wasm_asm:uleb(0), wasm_asm:uleb(1), IntsRef],% 3
                  [16#60, wasm_asm:uleb(0), wasm_asm:uleb(1), RefsRef]]),
    %% Allocate, park in the global, then write every element so the elements
    %% table actually has rows to walk.
    Fill = fun(Type, Global, Value) ->
               <<16#20, 0, ?FB, 7, Type,          % array.new_default
                 16#24, Global,                   % global.set
                 16#03, 16#40,                    % loop
                   16#23, Global,                 %   global.get
                   16#20, 0, 16#41, 1, 16#6B,     %   n - 1
                   Value/binary,                  %   the element value
                   ?FB, 14, Type,                 %   array.set
                   16#20, 0, 16#41, 1, 16#6B,
                   16#22, 0, 16#0D, 0,            %   local.tee 0 ; br_if 0
                 16#0B,
                 16#0B>>
           end,
    FillNumbers = Fill(0, 0, <<16#41, 7>>),
    FillRefs = Fill(1, 1, <<16#23, 0>>),           % every element the same array
    Head = <<16#23, 0, 16#0B>>,
    HeadRefs = <<16#23, 1, 16#0B>>,
    wasm_asm:module(
      [Types,
       wasm_asm:func_section([2, 2, 3, 4]),
       wasm_asm:global_section([{IntsRef, true, <<16#D0, 0>>},
                                {RefsRef, true, <<16#D0, 1>>}]),
       wasm_asm:export_section([{~"fill_numbers", 0, 0}, {~"fill_refs", 0, 1},
                                {~"head", 0, 2}, {~"head_refs", 0, 3}]),
       wasm_asm:code_section([FillNumbers, FillRefs, Head, HeadRefs])]).

%% ```
%% (type $s (struct (field (mut i32))))
%% (table (export "table") 1 1 (ref null $s))
%% (global $g (mut (ref null $s)) (ref.null $s))
%% (func (export "put")  (table.set 0 (i32.const 0) (struct.new $s (i32.const 7))))
%% (func (export "keep") (global.set $g (struct.new $s (i32.const 5))))
%% (func (export "kept") (result i32) (struct.get $s 0 (global.get $g)))
%% ```
producer_module() ->
    SRef = [16#63, 0],
    Types = wasm_asm:section(
              1, [wasm_asm:uleb(3),
                  [16#5F, wasm_asm:uleb(1), ?I32, 1],
                  [16#60, wasm_asm:uleb(0), wasm_asm:uleb(0)],
                  [16#60, wasm_asm:uleb(0), wasm_asm:uleb(1), ?I32]]),
    Put = <<16#41, 0, 16#41, 7, ?FB, 0, 0, 16#26, 0, 16#0B>>,
    Keep = <<16#41, 5, ?FB, 0, 0, 16#24, 0, 16#0B>>,
    Kept = <<16#23, 0, ?FB, 2, 0, 0, 16#0B>>,
    wasm_asm:module(
      [Types,
       wasm_asm:func_section([1, 1, 2]),
       wasm_asm:table_section([{SRef, 1, 1}]),
       wasm_asm:global_section([{SRef, true, <<16#D0, 0>>}]),
       wasm_asm:export_section([{~"table", 1, 0}, {~"put", 0, 0},
                                {~"keep", 0, 1}, {~"kept", 0, 2}]),
       wasm_asm:code_section([Put, Keep, Kept])]).

%% ```
%% (import "env" "t" (table 1 1 (ref null $s)))
%% (func (export "get") (result i32)
%%   (struct.get $s 0 (table.get 0 (i32.const 0))))
%% (func (export "garbage") (param i32))
%% ```
consumer_module() ->
    SRef = [16#63, 0],
    Types = wasm_asm:section(
              1, [wasm_asm:uleb(3),
                  [16#5F, wasm_asm:uleb(1), ?I32, 1],
                  [16#60, wasm_asm:uleb(0), wasm_asm:uleb(1), ?I32],
                  [16#60, wasm_asm:uleb(1), ?I32, wasm_asm:uleb(0)]]),
    Import = wasm_asm:section(
               2, [wasm_asm:uleb(1),
                   wasm_asm:name(~"env"), wasm_asm:name(~"t"),
                   16#01, SRef, wasm_asm:limits(16#01, 1, 1)]),
    Get = <<16#41, 0, 16#25, 0, ?FB, 2, 0, 0, 16#0B>>,
    wasm_asm:module(
      [Types,
       Import,
       wasm_asm:func_section([1, 2]),
       wasm_asm:export_section([{~"get", 0, 0}, {~"garbage", 0, 1}]),
       wasm_asm:code_section([Get, garbage_body()])]).

%% loop { struct.new_default $s; drop; countdown } -- allocates and keeps none.
garbage_body() ->
    <<16#03, 16#40,
        ?FB, 1, 0, 16#1A,
        16#20, 0, 16#41, 1, 16#6B, 16#22, 0, 16#0D, 0,
      16#0B,
      16#0B>>.

%%% -------------------------------------------------------------- charging ---

%% A guest's objects are node memory, and until they were charged nothing
%% bounded them.
%%
%% They live in ETS (`wasm_heap:new/2'), and ETS is not process heap, so
%% `max_heap_size` cannot see them and neither could the page budget, which
%% counts `atomics`. Filling a twenty-million element array took 1.8 GB with
%% `max_heap_words` set, `process_flag(max_heap_size, ...)` set on the process
%% running it, and `pages_in_use` reading zero throughout. A differential oracle
%% found it: V8 refused the same call with an array-size cap of its own.
a_guest_cannot_outgrow_the_node_budget(_Config) ->
    Mod = filler(),
    Old = wasm_engine:page_limit(),
    Base = wasm_engine:pages_in_use(),
    try
        wasm_engine:set_page_limit(Base + 512),          % 32 MiB of headroom
        {ok, I} = wasm:instantiate(Mod, #{}),
        Ets = erlang:memory(ets),
        ?assertMatch({error, #{class := exhaustion, kind := heap_limit}},
                     wasm:call(I, ~"fill", [20000000])),
        %% Refused near the ceiling rather than somewhere past it. The bound is
        %% the budget plus one reconcile interval's overshoot, and 1.8 GB was
        %% what this took before.
        ?assert((erlang:memory(ets) - Ets) < 64 * 1024 * 1024),
        ok = wasm:destroy(I)
    after
        wasm_engine:set_page_limit(Old)
    end,
    wait_until(fun() -> wasm_engine:pages_in_use() =:= Base end, 5000).

%% What a collection frees is pages the node gets back, rather than a charge
%% that only ever ratchets up.
a_heap_gives_its_pages_back_when_collected(_Config) ->
    Mod = filler(),
    Base = wasm_engine:pages_in_use(),
    {ok, I} = wasm:instantiate(Mod, #{}),
    {ok, [_]} = wasm:call(I, ~"fill", [200000]),
    Charged = wasm_engine:pages_in_use(),
    ?assert(Charged > Base, {nothing_charged, Base, Charged}),
    %% The array the fill made is unreachable the moment the call returns: it
    %% lived in a local and nothing else names it. What it is not is
    %% *collected*, because a collection is due every hundred thousand
    %% allocations and the fill made one. Lowering the threshold is what makes
    %% this a test of the charge coming back rather than of the collector's
    %% schedule.
    %% Every collection, and every one of them major.
    %%
    %% The threshold alone is not enough. Garbage that appears without the store
    %% growing does not make a major due -- the byte-side rule in `major_due/1`
    %% is a doubling, like the row-side one -- and a minor collection leaves the
    %% old generation alone by design. Dropping the only reference to an array
    %% is exactly that shape, so this says which collection it wants rather than
    %% relying on the schedule.
    ok = application:set_env(wasm, gc_alloc_threshold, 1),
    ok = application:set_env(wasm, gc_min_major_size, 0),
    ok = application:set_env(wasm, gc_min_major_pages, 0),
    ok = application:set_env(wasm, gc_major_ratio, 1),
    try
        {ok, [0]} = wasm:call(I, ~"drop", []),
        wait_until(fun() -> wasm_engine:pages_in_use() < Charged end, 5000)
    after
        ok = application:unset_env(wasm, gc_alloc_threshold),
        ok = application:unset_env(wasm, gc_min_major_size),
        ok = application:unset_env(wasm, gc_min_major_pages),
        ok = application:unset_env(wasm, gc_major_ratio)
    end,
    ok = wasm:destroy(I),
    wait_until(fun() -> wasm_engine:pages_in_use() =:= Base end, 5000).

%% Two instances sharing one store are two holders of one resource, exactly as
%% two instances importing one memory are. Charging per instance would count the
%% same rows twice and refuse at half the real ceiling.
a_shared_heap_is_charged_once(_Config) ->
    Mod = filler(),
    Base = wasm_engine:pages_in_use(),
    {ok, A} = wasm:instantiate(Mod, #{}),
    {ok, [_]} = wasm:call(A, ~"fill", [200000]),
    One = wasm_engine:pages_in_use(),
    %% Before comparing, establish there is something to compare. Without this
    %% the case passes against a runtime that charges nothing at all, because
    %% every reading is then equal at zero, and it did.
    ?assert(One > Base, {nothing_charged, Base, One}),
    {ok, B} = wasm:instantiate(Mod, #{}, #{link => A}),
    ?assertEqual(One, wasm_engine:pages_in_use()),
    %% And it survives the instance that made it.
    ok = wasm:destroy(A),
    ?assertEqual(One, wasm_engine:pages_in_use()),
    ok = wasm:destroy(B),
    wait_until(fun() -> wasm_engine:pages_in_use() =:= Base end, 5000).

%% Writes elements, so the cost lands in `wasm_heap_elements' rather than in one
%% array header: `array.new_default' of a hundred million is a single row.
filler() ->
    build(~"""
    (module
      (type $a (array (mut i64)))
      (global $keep (mut (ref null $a)) (ref.null $a))
      ;; Into the global, not a local. A local is unreachable the moment the
      ;; call returns, and the byte-side collection trigger now fires at that
      ;; boundary, so the array was already gone before the charge was read and
      ;; there was nothing left for `drop` to release.
      (func (export "fill") (param i32) (result i32)
        (local $r (ref $a)) (local $i i32)
        (local.set $r (array.new_default $a (local.get 0)))
        (global.set $keep (local.get $r))
        (block $o (loop $l
          (br_if $o (i32.ge_u (local.get $i) (local.get 0)))
          (array.set $a (local.get $r) (local.get $i)
                        (i64.extend_i32_u (local.get $i)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $l)))
        (array.len (local.get $r)))
      ;; One element, for asking whether a refused write left a row behind.
      (func (export "poke") (param i32) (result i32)
        (array.set $a (global.get $keep) (local.get 0) (i64.const 9))
        (i32.const 0))
      ;; Replaces the whole array, which deletes every element row.
      (func (export "fillall") (result i32)
        (array.fill $a (global.get $keep) (i32.const 0) (i64.const 0)
                    (array.len (global.get $keep)))
        (i32.const 0))
      (func (export "drop") (result i32)
        ;; Allocates, so a collection is due when the threshold is low, and
        ;; keeps nothing, so what the fill made is unreachable.
        (global.set $keep (array.new_default $a (i32.const 1)))
        (global.set $keep (ref.null $a))
        (i32.const 0)))
    """).

build(Src) ->
    {ok, P} = wasm_wat:module(Src),
    {ok, M} = wasm_validate:module(P),
    M.

wait_until(Pred, 0) -> Pred() orelse ct:fail({timeout_waiting, Pred()});
wait_until(Pred, Ms) ->
    case Pred() of
        true -> ok;
        false -> timer:sleep(20), wait_until(Pred, erlang:max(Ms - 20, 0))
    end.

%%% -------------------------------------------- what a refusal must not do ---

%% Linking to a store bigger than this instance may reach is a link failure.
%%
%% `wasm_heap:acquire/3` used to discard the keeper's answer, so a one-page
%% instance linked to a 269-page store instantiated cleanly, never became a
%% holder of it, and destroying the instance that *made* the store released the
%% whole charge while the linked one was still running on it.
a_linked_instance_over_its_ceiling_is_refused(_Config) ->
    Mod = filler(),
    {ok, A} = wasm:instantiate(Mod, #{}),
    {ok, [_]} = wasm:call(A, ~"fill", [200000]),
    Charged = wasm_engine:pages_in_use(),
    ?assert(Charged > 8, {nothing_charged, Charged}),
    ?assertMatch({error, #{class := link, kind := shared_heap_refused}},
                 wasm:instantiate(Mod, #{}, #{link => A,
                                              max_memory_pages => 1})),
    %% And the refusal left nothing behind: still one holder, still charged.
    ?assertEqual(Charged, wasm_engine:pages_in_use()),
    ok = wasm:destroy(A).

%% A write the charge refuses must not have happened.
%%
%% The insert used to come first and the charge second, so a refused write left
%% its row and, because the charge was refused, the row was never recorded
%% either: twenty writes grew the store by megabytes while the page count did
%% not move. A refusal also has to make the *next* write check, or it stops one
%% write and lets the rest of the reconcile interval through.
a_refused_write_leaves_no_row(_Config) ->
    Mod = filler(),
    {ok, I} = wasm:instantiate(Mod, #{}, #{max_memory_pages => 8}),
    %% Fills until the ceiling refuses it; the refusal is a value.
    _ = wasm:call(I, ~"fill", [200000]),
    {wasm_heap, _, Elems, _} = wasm_instance:heap(I),
    Rows = ets:info(Elems, size),
    Pages = wasm_engine:pages_in_use(),
    Answers = [wasm:call(I, ~"poke", [N * 907]) || N <- lists:seq(1, 20)],
    ?assertEqual(20, length([x || {error, #{kind := heap_limit}} <- Answers]),
                 {not_all_refused, Answers}),
    ?assertEqual(Rows, ets:info(Elems, size)),
    ?assertEqual(Pages, wasm_engine:pages_in_use()),
    ok = wasm:destroy(I).

%% A fill that replaces the whole array deletes every element row, and the
%% charge has to follow it down. Nothing else on that path counts a write, so
%% the store stayed charged for rows that no longer existed.
a_whole_array_fill_gives_its_pages_back(_Config) ->
    Mod = filler(),
    Base = wasm_engine:pages_in_use(),
    {ok, I} = wasm:instantiate(Mod, #{}),
    {ok, [_]} = wasm:call(I, ~"fill", [200000]),
    Charged = wasm_engine:pages_in_use(),
    ?assert(Charged > Base + 100, {nothing_charged, Base, Charged}),
    {ok, [0]} = wasm:call(I, ~"fillall", []),
    After = wasm_engine:pages_in_use(),
    ?assert(After < Base + 10, {still_charged_for_deleted_rows, Base, After}),
    ok = wasm:destroy(I).

%% Two processes on one shared store must never leave it charged for less than
%% it holds.
%%
%% `charge/1` used to measure the tables and then call the keeper, so an older,
%% smaller sample could land after a newer, larger one and release the pages of
%% rows that still existed. The keeper measures inside the callback that applies
%% the result now, which makes the interleaving unrepresentable rather than
%% unlikely; this hammers it and checks the invariant, which is the most a test
%% can do against a race that no longer has a window.
concurrent_reconciles_never_lower_a_live_charge(_Config) ->
    Mod = filler(),
    {ok, A} = wasm:instantiate(Mod, #{}),
    {ok, B} = wasm:instantiate(Mod, #{}, #{link => A}),
    Self = self(),
    Ps = [spawn_link(fun() ->
                         [{ok, [_]} = wasm:call(Inst, ~"fill", [20000])
                          || _ <- lists:seq(1, 8)],
                         Self ! {done, self()}
                     end) || Inst <- [A, B]],
    [receive {done, P} -> ok after 60000 -> ct:fail({stuck, P}) end || P <- Ps],
    {wasm_heap, Objs, Elems, _} = wasm_instance:heap(A),
    Words = ets:info(Objs, memory) + ets:info(Elems, memory),
    Held = (Words * erlang:system_info(wordsize) + 65535) div 65536,
    Charged = wasm_engine:pages_in_use(),
    ?assert(Charged >= Held,
            {charged_for_less_than_it_holds, Charged, Held}),
    ok = wasm:destroy(B),
    ok = wasm:destroy(A).

%% Writes elements so the cost lands in `wasm_heap_elements`, keeps the array in
%% a global so it stays live, and offers a single write and a whole-array fill.
