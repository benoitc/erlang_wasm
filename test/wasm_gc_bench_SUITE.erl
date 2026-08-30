%% @doc Garbage collection benchmarks.
%%
%% The numbers in `docs/features.md' were produced by hand and could not be
%% reproduced from the repository. This suite is where they come from now, so a
%% claim about the collector is a thing anyone can re-run.
%%
%% Two of these measure something no other benchmark does:
%%
%% <ul>
%%   <li><b>Call round trip against a non-empty heap.</b> `wasm_instance:set_mut/2'
%%       writes the whole `#mut{}' into ETS, and the object store lives inside
%%       it, so a call that allocates or writes a field copies the entire heap.
%%       Every other benchmark here allocates inside one call and writes back
%%       once, which hides it exactly.</li>
%%   <li><b>Process heap growth across a collection.</b> The mark phase builds a
%%       live-set map and a worklist proportional to the graph, on the BEAM heap
%%       of whichever process happened to make the call.</li>
%% </ul>
%%
%% Run with `rebar3 bench'. A plain `rebar3 ct' runs none of it: these are
%% measurements rather than regression tests, and `all/0' is empty so that they
%% are not counted as passing cases. Sizes stop at 10^5; set `WASM_BENCH_FULL=1'
%% for the 10^6 arms.
%%
%% Numbers are logged, not asserted. This box has been seen at load average 33
%% and repeated runs of one arm vary by more than 3x, so every measurement here
%% is a minimum of several rounds and each one that matters has a null arm
%% beside it. A benchmark in this project has already reported a stable,
%% reproducible 2x regression that did not exist.
-module(wasm_gc_bench_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").

-define(I32, 16#7F).
-define(FB, 16#FB).

%% (ref null $s), where $s is type index 0 in each module below.
-define(REF0, [16#63, 0]).

%% Empty on purpose. Every case here logs a number and asserts nothing, so a
%% plain `rebar3 ct' would spend minutes on measurements that cannot fail and
%% would report them as passing tests. They live in a group instead, which is
%% what `rebar3 bench' asks for.
all() -> [].

groups() ->
    [{bench, [],
      [call_round_trip_vs_heap_size,
       collector_pause_vs_live_set,
       minor_pause_vs_live_set,
       collector_pause_vs_garbage,
       allocation_throughput,
       field_access,
       bulk_array_ops,
       field_index_cost,
       collector_process_heap,
       store_primitives]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

init_per_testcase(_Case, Config) ->
    %% High enough that nothing collects behind a measurement's back. The cases
    %% that want a collection call the collector directly.
    application:set_env(wasm, gc_alloc_threshold, 1 bsl 60),
    Config.

end_per_testcase(_Case, _Config) ->
    application:unset_env(wasm, gc_alloc_threshold),
    ok.

%%% -------------------------------------------------------------- headline ---

%% What a call costs as the heap grows underneath it.
%%
%% `nop' is the null arm: same call, same instance, no heap access at all. If
%% the three arms track each other the write-back is free; if `touch' pulls away
%% from `read' as the heap grows, the write-back is proportional to heap size,
%% which is the thing this milestone exists to fix.
%%
%% `touch' takes the value it stores as a parameter, and every iteration passes
%% a different one. That is not decoration. `wasm:invoke_with/5' skips the
%% write-back when the new state is `=:=' the old, and `=:=' is *structural*, so
%% a `touch' storing a constant produces a term equal to the one before it from
%% the second call onwards and the write-back never happens. The first version
%% of this benchmark did exactly that and reported a flat 0.21 us at every heap
%% size, which is the cost of the path it was accidentally measuring.
call_round_trip_vs_heap_size(_Config) ->
    lists:foreach(
      fun(Size) ->
          {ok, Inst} = instantiate(struct_module()),
          grow(Inst, Size),
          Nop   = best_i(fun(_) -> wasm:call(Inst, ~"nop", []) end),
          Read  = best_i(fun(_) -> wasm:call(Inst, ~"read", []) end),
          Touch = best_i(fun(I) -> wasm:call(Inst, ~"touch", [I]) end, 200),
          ct:log("heap ~7w objects: nop ~9.2f us | read ~9.2f us | "
                 "touch (mutating) ~9.2f us",
                 [Size, Nop, Read, Touch]),
          ok = wasm:destroy(Inst)
      end, heap_sizes()),
    ok.

%%% ------------------------------------------------------------- collector ---

%% Mark and sweep over a chain in which everything is live, rooted in a global.
collector_pause_vs_live_set(_Config) ->
    lists:foreach(
      fun(Size) ->
          {ok, Inst} = instantiate(struct_module()),
          grow(Inst, Size),
          Heap = wasm_instance:heap(Inst),
          Size = wasm_heap:size(Heap),
          Roots = roots(Inst),
          %% Once. Collecting sets the watermark, so a second collection over
          %% the same heap has an empty nursery and a satisfied major ratio:
          %% taking the best of several measured an already-clean heap and
          %% reported a collector several times faster than it is.
          Ms = once_ms(fun() -> wasm_heap:collect(Heap, Roots) end),
          ct:log("~7w live: ~9.3f ms (~7.1f ns/object)",
                 [Size, Ms, Ms * 1000000 / Size]),
          ok = wasm:destroy(Inst)
      end, heap_sizes()),
    ok.

%% The number the generation exists for: a collection after a small amount of
%% allocation, against a large live set that is already old.
%%
%% A major collection here is proportional to the live set. A minor one should
%% be proportional to what was just allocated, and so flat as the heap grows.
minor_pause_vs_live_set(_Config) ->
    lists:foreach(
      fun(Size) ->
          {ok, Inst} = instantiate(struct_module()),
          grow(Inst, Size),
          Heap = wasm_instance:heap(Inst),
          Roots = roots(Inst),
          %% One major collection promotes the whole chain to the old
          %% generation; everything after it is a minor.
          application:set_env(wasm, gc_min_major_size, 0),
          application:set_env(wasm, gc_major_ratio, 1),
          ok = wasm_heap:collect(Heap, Roots),
          %% Repeated here on purpose, and it is the only arm where that is
          %% right: the settings above make every collection a major one over
          %% the same live set, so each round does the same work.
          Major = best_ms(fun() -> wasm_heap:collect(Heap, Roots) end),
          application:set_env(wasm, gc_min_major_size, 1 bsl 40),
          application:unset_env(wasm, gc_major_ratio),
          %% A thousand fresh objects, then collect.
          Minor = lists:min(
                    [begin
                         {ok, []} = wasm:call(Inst, ~"garbage", [1000]),
                         T0 = erlang:monotonic_time(nanosecond),
                         ok = wasm_heap:collect(Heap, Roots),
                         (erlang:monotonic_time(nanosecond) - T0) / 1000000
                     end || _ <- lists:seq(1, 5)]),
          application:unset_env(wasm, gc_min_major_size),
          ct:log("~7w old objects: major ~9.3f ms | minor after 1000 "
                 "allocations ~9.3f ms", [Size, Major, Minor]),
          ok = wasm:destroy(Inst)
      end, heap_sizes()),
    ok.

%% The same small live set with more and more garbage around it. Mark and sweep
%% pays for the sweep whether or not anything survives, so this is where the
%% cost of never reusing an object id shows up.
collector_pause_vs_garbage(_Config) ->
    Live = 1000,
    lists:foreach(
      fun(Garbage) ->
          {ok, Inst} = instantiate(struct_module()),
          grow(Inst, Live),
          {ok, []} = wasm:call(Inst, ~"garbage", [Garbage]),
          Heap = wasm_instance:heap(Inst),
          Roots = roots(Inst),
          %% Once, for the same reason: the first collection sweeps the
          %% garbage and the ones after it have nothing left to sweep, which
          %% is the opposite of what this arm is for.
          Ms = once_ms(fun() -> wasm_heap:collect(Heap, Roots) end),
          ct:log("~w live, ~7w garbage: ~9.3f ms (~7.1f ns/dead object)",
                 [Live, Garbage, Ms, Ms * 1000000 / Garbage]),
          ok = wasm:destroy(Inst)
      end, garbage_sizes()),
    ok.

%% Allocation on its own, with the collector out of the way. The interpreter
%% arm includes dispatch and the loop; the direct arm is the store write alone.
allocation_throughput(_Config) ->
    {ok, Inst} = instantiate(struct_module()),
    N = 100000,
    Ms = best_ms(fun() -> {ok, []} = wasm:call(Inst, ~"garbage", [N]) end),
    ct:log("struct.new through the interpreter: ~6.1f ns/object "
           "(~.2f M objects/s)", [Ms * 1000000 / N, N / (Ms * 1000)]),
    ok = wasm:destroy(Inst).

%% Field read and write, net of the call round trip that carries them.
field_access(_Config) ->
    {ok, Inst} = instantiate(struct_module()),
    grow(Inst, 1000),
    Nop   = best_i(fun(_) -> wasm:call(Inst, ~"nop", []) end),
    Read  = best_i(fun(_) -> wasm:call(Inst, ~"read", []) end),
    Touch = best_i(fun(I) -> wasm:call(Inst, ~"touch", [I]) end),
    %% Promote the chain, so storing a reference into its head takes the write
    %% barrier rather than skipping it.
    application:set_env(wasm, gc_min_major_size, 0),
    application:set_env(wasm, gc_major_ratio, 1),
    ok = wasm_heap:collect(wasm_instance:heap(Inst), roots(Inst)),
    application:unset_env(wasm, gc_min_major_size),
    application:unset_env(wasm, gc_major_ratio),
    Barrier = best_i(fun(_) -> wasm:call(Inst, ~"touch_ref", []) end),
    Cast = best_i(fun(_) -> wasm:call(Inst, ~"test_ref", []) end),
    ct:log("struct.get ~7.1f ns net | struct.set ~7.1f ns net | "
           "struct.set of a reference into an old object ~7.1f ns net | "
           "ref.test ~7.1f ns net (call round trip ~7.1f ns)",
           [(Read - Nop) * 1000, (Touch - Nop) * 1000, (Barrier - Nop) * 1000,
            (Cast - Nop) * 1000, Nop * 1000]),
    ok = wasm:destroy(Inst).

%% What a struct's field index costs, measured inside wasm so the number is the
%% instruction and not the call carrying it.
%%
%% A field used to be found with `lists:nth/2' over a list rebuilt from the type
%% table on every access, so reading the sixteenth field cost more than reading
%% the first. Both are two `element/2' calls now.
field_index_cost(_Config) ->
    {ok, Inst} = instantiate(wide_struct_module()),
    {ok, []} = wasm:call(Inst, ~"init", []),
    N = 200000,
    Per = fun(Name) ->
              Ms = best_ms(fun() -> {ok, []} = wasm:call(Inst, Name, [N]) end),
              Ms * 1000000 / N
          end,
    Empty = Per(~"empty"),
    ct:log("struct.get field 0 ~5.1f ns | field 15 ~5.1f ns "
           "(loop overhead ~5.1f ns)",
           [Per(~"first") - Empty, Per(~"last") - Empty, Empty]),
    ok = wasm:destroy(Inst).

%% `array.fill' and `array.copy' at growing lengths, reported per element.
%%
%% Per-element cost that grows with length is the signature of a quadratic, and
%% `array.copy' materialises its source as a list and then indexes it with
%% `lists:nth/2' inside the fold.
bulk_array_ops(_Config) ->
    lists:foreach(
      fun(Len) ->
          {ok, Inst} = instantiate(array_module()),
          {ok, []} = wasm:call(Inst, ~"alloc", [Len]),
          Fill = best_ms(fun() -> wasm:call(Inst, ~"fill", [Len]) end),
          Part = best_ms(fun() -> wasm:call(Inst, ~"fill_part", [Len]) end),
          Copy = best_ms(fun() -> wasm:call(Inst, ~"copy", [Len]) end),
          ct:log("~6w elements: array.fill whole ~8.1f | part ~8.1f | "
                 "array.copy ~8.1f ns/element",
                 [Len, Fill * 1000000 / Len, Part * 1000000 / Len,
                  Copy * 1000000 / Len]),
          ok = wasm:destroy(Inst)
      end, [100, 1000, 10000]),
    ok.

%% How much BEAM heap the collecting process grows by while collecting.
%%
%% The mark phase holds its live set in a map and its worklist in a cons list,
%% both on the process heap, so the process that happened to make the call pays
%% for the shape of the object graph. Collection is meant to free memory.
collector_process_heap(_Config) ->
    lists:foreach(
      fun(Size) ->
          {ok, Inst} = instantiate(struct_module()),
          grow(Inst, Size),
          Pid = spawn_collector(wasm_instance:heap(Inst), roots(Inst)),
          receive
              {Pid, Before, After, Peak} ->
                  ct:log("~7w live: process heap ~w -> ~w words, peak ~w "
                         "(~5.1f words per object)",
                         [Size, Before, After, Peak, (Peak - Before) / Size])
          after 60000 ->
                  ct:fail(collector_timeout)
          end,
          ok = wasm:destroy(Inst)
      end, heap_sizes()),
    ok.

%% Attribution for the roughly 220 ns per object the mark phase costs, against
%% the primitives a faster store would be built from.
%%
%% The null arm is the loop and the `rem' alone. Without it the fun call and the
%% remainder dominate everything below them and every row looks the same.
store_primitives(_Config) ->
    Size = 100000,
    Array = lists:foldl(fun(I, A) -> array:set(I, {gcstruct, 0, {17, null}}, A) end,
                        array:new([{default, undefined}, {fixed, false}]),
                        lists:seq(0, Size - 1)),
    Tab = ets:new(bench, [set, public]),
    [ets:insert(Tab, {I, gcstruct, 0, {17, null}}) || I <- lists:seq(0, Size - 1)],
    %% Unsigned: a mark bitmap sets bit 63, and a signed 64-bit atomic rejects
    %% the value that lands there.
    Bits = atomics:new(Size div 64 + 1, [{signed, false}]),
    Null = per_op(Size, fun(I) -> I end),
    Rows = [{"array:get", fun(I) -> array:get(I, Array) end},
            {"array:set", fun(I) -> array:set(I, x, Array) end},
            {"array:reset", fun(I) -> array:reset(I, Array) end},
            {"ets:lookup_element", fun(I) -> ets:lookup_element(Tab, I, 4) end},
            {"ets:lookup, whole row", fun(I) -> ets:lookup(Tab, I) end},
            {"ets:next", fun(I) -> ets:next(Tab, I) end},
            {"ets:update_element",
             fun(I) -> ets:update_element(Tab, I, {4, {I, null}}) end},
            {"atomics mark bit", fun(I) -> mark_bit(Bits, I) end},
            {"map live-set insert", fun(I) -> live_insert(I) end}],
    ct:log("null arm (loop only): ~7.1f ns/op", [Null]),
    lists:foreach(
      fun({Label, F}) ->
          put(live_set, #{}),
          Gross = per_op(Size, F),
          ct:log("~-22s ~8.1f ns/op gross, ~8.1f ns/op net",
                 [Label, Gross, Gross - Null])
      end, Rows),
    ets:delete(Tab),
    ok.

%%% ---------------------------------------------------------------- timing ---

-define(ROUNDS, 5).

%% Minimum of several rounds. A single sample of anything on this box is
%% worthless: repeated runs of the *same* arm span more than 3x.
%% The iteration counter is handed to the fun, so an arm that must not repeat
%% itself can vary what it writes.
best_i(F) -> best_i(F, 2000).

best_i(F, N) ->
    lists:min([begin
                   T0 = erlang:monotonic_time(microsecond),
                   repeat(N, F),
                   T1 = erlang:monotonic_time(microsecond),
                   (T1 - T0) / N
               end || _ <- lists:seq(1, ?ROUNDS)]).

%% For anything whose cost is spent by running it. A collection is the case:
%% the second one over the same heap has nothing left to do.
once_ms(F) ->
    T0 = erlang:monotonic_time(nanosecond),
    _ = F(),
    (erlang:monotonic_time(nanosecond) - T0) / 1000000.

best_ms(F) ->
    lists:min([begin
                   T0 = erlang:monotonic_time(nanosecond),
                   _ = F(),
                   T1 = erlang:monotonic_time(nanosecond),
                   (T1 - T0) / 1000000
               end || _ <- lists:seq(1, ?ROUNDS)]).

per_op(Size, F) ->
    N = 200000,
    Us = lists:min([begin
                        T0 = erlang:monotonic_time(microsecond),
                        loop(N, Size, F),
                        T1 = erlang:monotonic_time(microsecond),
                        T1 - T0
                    end || _ <- lists:seq(1, ?ROUNDS)]),
    (Us * 1000) / N.

loop(0, _Size, _F) -> ok;
loop(N, Size, F) -> _ = F(N rem Size), loop(N - 1, Size, F).

repeat(0, _F) -> ok;
repeat(N, F) -> _ = F(N), repeat(N - 1, F).

mark_bit(Bits, I) ->
    W = (I bsr 6) + 1,
    atomics:put(Bits, W, atomics:get(Bits, W) bor (1 bsl (I band 63))).

live_insert(I) ->
    M = get(live_set),
    put(live_set, M#{I => true}).

%% Collection runs in a process of its own so the measurement sees only what the
%% collector itself allocated, not whatever the suite has on its heap.
spawn_collector(Heap, Roots) ->
    Parent = self(),
    spawn(fun() ->
              erlang:garbage_collect(),
              {total_heap_size, Before} =
                  erlang:process_info(self(), total_heap_size),
              ok = wasm_heap:collect(Heap, Roots),
              {total_heap_size, Peak} =
                  erlang:process_info(self(), total_heap_size),
              erlang:garbage_collect(),
              {total_heap_size, After} =
                  erlang:process_info(self(), total_heap_size),
              Parent ! {self(), Before, After, Peak}
          end).

%%% ----------------------------------------------------------------- sizes ---

%% 10^6 takes long enough to be unwelcome in a routine `rebar3 ct' run, so it is
%% opt-in rather than skipped silently at a smaller size.
heap_sizes() ->
    case os:getenv("WASM_BENCH_FULL") of
        false -> [1000, 10000, 100000];
        _ -> [1000, 10000, 100000, 1000000]
    end.

garbage_sizes() ->
    case os:getenv("WASM_BENCH_FULL") of
        false -> [10000, 100000];
        _ -> [10000, 100000, 1000000]
    end.

%% ```
%% (type $w (struct (field (mut i32)) x16))
%% (global $w (mut (ref null $w)) (ref.null $w))
%% (func (export "init"))
%% (func (export "first") (result i32))   ;; field 0
%% (func (export "last") (result i32))    ;; field 15
%% ```
%%
%% A struct's field used to be found with `lists:nth/2' over a list rebuilt from
%% the type table, so reading the sixteenth field cost sixteen times reading the
%% first. Both are two `element/2' calls now, and this is where that shows.
wide_struct_module() ->
    WRef = [16#63, 0],
    Fields = lists:duplicate(16, [?I32, 1]),
    Types = wasm_asm:section(
              1, [wasm_asm:uleb(3),
                  [16#5F, wasm_asm:uleb(16), Fields],
                  [16#60, wasm_asm:uleb(0), wasm_asm:uleb(0)],
                  [16#60, wasm_asm:uleb(1), ?I32, wasm_asm:uleb(0)]]),
    Init = <<?FB, 1, 0, 16#24, 0, 16#0B>>,
    Down = countdown(),
    %% Read one field n times inside wasm, so the measurement is the
    %% instruction rather than the call that carries it.
    Loop = fun(Field) ->
               <<16#03, 16#40,
                   16#23, 0, ?FB, 2, 0, Field, 16#1A,
                   Down/binary,
                 16#0B, 16#0B>>
           end,
    Empty = <<16#03, 16#40, Down/binary, 16#0B, 16#0B>>,
    wasm_asm:module(
      [Types,
       wasm_asm:func_section([1, 2, 2, 2]),
       wasm_asm:global_section([{WRef, true, <<16#D0, 0>>}]),
       wasm_asm:export_section([{~"init", 0, 0}, {~"first", 0, 1},
                                {~"last", 0, 2}, {~"empty", 0, 3}]),
       wasm_asm:code_section([Init, Loop(0), Loop(15), Empty])]).

%%% -------------------------------------------------------------- fixtures ---

instantiate(Bin) ->
    {ok, Mod} = wasm:load(Bin),
    wasm:instantiate(Mod, #{}).

%% The collector takes its roots from the caller, so the benchmark supplies the
%% one that matters: the head of the chain, read back through an export.
roots(Inst) ->
    {ok, [Head]} = wasm:call(Inst, ~"head", []),
    [Head].

%% Grown in chunks so one call does not have to hold a million-deep chain in a
%% single interpreter loop.
grow(Inst, N) when N =< 100000 ->
    {ok, []} = wasm:call(Inst, ~"grow", [N]),
    ok;
grow(Inst, N) ->
    {ok, []} = wasm:call(Inst, ~"grow", [100000]),
    grow(Inst, N - 100000).

%% ```
%% (type $s (struct (field (mut i32)) (field (mut (ref null $s)))))
%% (global $head (mut (ref null $s)) (ref.null $s))
%%
%% (func (export "grow") (param i32))      ;; n structs chained onto $head
%% (func (export "touch") (param i32))     ;; one field write: mutates
%% (func (export "read") (result i32))     ;; one field read: does not mutate
%% (func (export "garbage") (param i32))   ;; n structs, all dropped
%% (func (export "nop"))                   ;; the null arm
%% ```
struct_module() ->
    Types = wasm_asm:section(
              1, [wasm_asm:uleb(5),
                  [16#5F, wasm_asm:uleb(2), ?I32, 1, ?REF0, 1],
                  [16#60, wasm_asm:uleb(1), ?I32, wasm_asm:uleb(0)],
                  [16#60, wasm_asm:uleb(0), wasm_asm:uleb(0)],
                  [16#60, wasm_asm:uleb(0), wasm_asm:uleb(1), ?I32],
                  [16#60, wasm_asm:uleb(0), wasm_asm:uleb(1), ?REF0]]),
    %% The parameter doubles as the loop counter, so no local is declared.
    Down = countdown(),
    Grow = <<16#03, 16#40,                     % loop
               16#41, 1,                       %   i32.const 1
               16#23, 0,                       %   global.get $head
               ?FB, 0, 0,                      %   struct.new $s
               16#24, 0,                       %   global.set $head
               Down/binary,
             16#0B,                            % end loop
             16#0B>>,
    Garbage = <<16#03, 16#40,
                  ?FB, 1, 0,                   %   struct.new_default $s
                  16#1A,                       %   drop
                  Down/binary,
                16#0B,
                16#0B>>,
    Touch = <<16#23, 0, 16#20, 0, ?FB, 5, 0, 0, 16#0B>>,
    Read = <<16#23, 0, ?FB, 2, 0, 0, 16#0B>>,
    Nop = <<16#0B>>,
    %% Handing the chain head back is how the benchmark names a root. The global
    %% stays private: exporting it would make it a shared cell and change what
    %% `read' and `touch' are measuring.
    Head = <<16#23, 0, 16#0B>>,
    %% Stores a *reference* into the head struct, so the write barrier fires
    %% once the head is old. `touch' stores a number and never fires it.
    TouchRef = <<16#23, 0, 16#23, 0, ?FB, 5, 0, 1, 16#0B>>,
    %% ref.test against a concrete type: the most frequent GC instruction in
    %% real toolchain output.
    TestRef = <<16#23, 0, ?FB, 20, 0, 16#0B>>,
    wasm_asm:module(
      [Types,
       wasm_asm:func_section([1, 1, 3, 1, 2, 4, 2, 3]),
       wasm_asm:global_section([{?REF0, true, <<16#D0, 0>>}]),
       wasm_asm:export_section([{~"grow", 0, 0}, {~"touch", 0, 1},
                                {~"read", 0, 2}, {~"garbage", 0, 3},
                                {~"nop", 0, 4}, {~"head", 0, 5},
                                {~"touch_ref", 0, 6}, {~"test_ref", 0, 7}]),
       wasm_asm:code_section([Grow, Touch, Read, Garbage, Nop, Head,
                              TouchRef, TestRef])]).

%% local.get 0; i32.const 1; i32.sub; local.tee 0; br_if 0
countdown() -> <<16#20, 0, 16#41, 1, 16#6B, 16#22, 0, 16#0D, 0>>.

%% ```
%% (type $a (array (mut i32)))
%% (global $src (mut (ref null $a))) (global $dst (mut (ref null $a)))
%% (func (export "alloc") (param i32))   ;; both arrays, n elements
%% (func (export "fill") (param i32))
%% (func (export "copy") (param i32))
%% ```
array_module() ->
    Types = wasm_asm:section(
              1, [wasm_asm:uleb(2),
                  [16#5E, ?I32, 1],
                  [16#60, wasm_asm:uleb(1), ?I32, wasm_asm:uleb(0)]]),
    Alloc = <<16#20, 0, ?FB, 7, 0, 16#24, 0,
              16#20, 0, ?FB, 7, 0, 16#24, 1, 16#0B>>,
    Fill = <<16#23, 0, 16#41, 0, 16#41, 7, 16#20, 0, ?FB, 16, 0, 16#0B>>,
    %% From index 1, so it cannot become a new default and has to write every
    %% element. Without this arm the benchmark would only ever measure the
    %% whole-array shortcut.
    Part = <<16#23, 0, 16#41, 1, 16#41, 7,
             16#20, 0, 16#41, 1, 16#6B, ?FB, 16, 0, 16#0B>>,
    Copy = <<16#23, 1, 16#41, 0, 16#23, 0, 16#41, 0, 16#20, 0,
             ?FB, 17, 0, 0, 16#0B>>,
    wasm_asm:module(
      [Types,
       wasm_asm:func_section([1, 1, 1, 1]),
       wasm_asm:global_section([{?REF0, true, <<16#D0, 0>>},
                                {?REF0, true, <<16#D0, 0>>}]),
       wasm_asm:export_section([{~"alloc", 0, 0}, {~"fill", 0, 1},
                                {~"copy", 0, 2}, {~"fill_part", 0, 3}]),
       wasm_asm:code_section([Alloc, Fill, Copy, Part])]).
