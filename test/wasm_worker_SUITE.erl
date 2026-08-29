-module(wasm_worker_SUITE).
-moduledoc """
Sandboxing, tested through the worker pattern the documentation recommends.

These decide whether the runtime can be pointed at code you do not control.
Each takes a claim from `wasm_limits` or `docs/worker.md` and tries to break it:
an infinite loop, unbounded recursion, unbounded memory growth, a host function
that crashes, state surviving a request.

They run against `examples/wasm_worker`, which is the code the documentation
tells people to copy. Testing the example rather than a library-internal
wrapper means the documented pattern cannot rot: if the advice stops working,
this suite goes red.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [state_does_not_leak_between_requests,
     reuse_policy_keeps_state,
     infinite_loop_is_bounded_by_fuel,
     infinite_loop_is_bounded_by_timeout,
     runaway_recursion_is_bounded,
     memory_growth_is_bounded_per_instance,
     memory_growth_is_bounded_node_wide,
     pages_are_released_when_worker_stops,
     discarded_instances_release_their_pages,
     memory_allocation_tracks_declared_size,
     killing_a_worker_does_not_disturb_others,
     crashing_host_function_becomes_a_trap,
     trap_leaves_instance_usable,
     worker_is_labelled_for_observability,
     state_stays_coherent_across_processes,
     limits_are_validated,
     shared_table_is_shared_by_reference].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_) -> application:stop(wasm).

init_per_testcase(_Case, Config) ->
    wasm_engine:set_page_limit(16384),
    put(workers, []),
    Config.

end_per_testcase(_Case, _Config) ->
    lists:foreach(fun(P) -> catch_stop(P) end, get(workers)),
    ok.

catch_stop(P) -> try wasm_worker:stop(P) catch _:_ -> ok end.

%%% -------------------------------------------------------------- fixtures ---

%% Workers are ordinary processes, not children of a library supervisor, so
%% the suite tracks the ones it starts.
worker(Wasm, Opts) ->
    {ok, Mod} = wasm:compile(Wasm),
    {ok, Pid} = wasm_worker:start_link(Mod, Opts),
    put(workers, [Pid | get(workers)]),
    Pid.

%%% ------------------------------------------------------------- isolation ---

%% The property a Workers-style host depends on: nothing survives a request.
%% Under `fresh` the instance is destroyed and rebuilt, so a global written by
%% one request is invisible to the next.
state_does_not_leak_between_requests(_Config) ->
    W = worker(counter_module(), #{isolation => fresh}),
    ?assertEqual({ok, [1]}, wasm_worker:call(W, ~"inc", [])),
    ?assertEqual({ok, [1]}, wasm_worker:call(W, ~"inc", [])),
    ?assertEqual({ok, [1]}, wasm_worker:call(W, ~"inc", [])),
    ?assertEqual({ok, [0]}, wasm_worker:call(W, ~"get", [])).

%% The opposite policy, which exists and is documented as the risky one.
reuse_policy_keeps_state(_Config) ->
    W = worker(counter_module(), #{isolation => reuse}),
    ?assertEqual({ok, [1]}, wasm_worker:call(W, ~"inc", [])),
    ?assertEqual({ok, [2]}, wasm_worker:call(W, ~"inc", [])),
    ?assertEqual({ok, [2]}, wasm_worker:call(W, ~"get", [])).

%%% ------------------------------------------------------------ termination ---

infinite_loop_is_bounded_by_fuel(_Config) ->
    W = worker(spin_module(), #{isolation => reuse,
                                limits => #{fuel => 100000}}),
    ?assertMatch({error, #{class := exhaustion, kind := out_of_fuel}},
                 wasm_worker:call(W, ~"spin", [], 30000)),
    %% Fuel exhaustion is a bounded failure of one request, not of the worker.
    ?assert(is_process_alive(W)).

%% Fuel bounds work, not time. A timeout is the other half, and it must kill
%% the worker: giving up without killing would leave the module burning a
%% scheduler with nobody waiting for it.
infinite_loop_is_bounded_by_timeout(_Config) ->
    W = worker(spin_module(), #{isolation => reuse,
                                limits => #{fuel => infinity}}),
    unlink(W),
    Ref = monitor(process, W),
    T0 = erlang:monotonic_time(millisecond),
    ?assertMatch({error, #{class := exhaustion, kind := timeout}},
                 wasm_worker:call(W, ~"spin", [], 300)),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 3000),
    receive {'DOWN', Ref, process, W, _} -> ok
    after 2000 -> ct:fail(worker_survived_timeout)
    end.

runaway_recursion_is_bounded(_Config) ->
    W = worker(recurse_module(), #{isolation => reuse,
                                   limits => #{max_depth => 64,
                                               fuel => infinity}}),
    ?assertMatch({error, #{class := exhaustion, kind := call_stack_exhausted}},
                 wasm_worker:call(W, ~"go", [], 5000)).

%%% ----------------------------------------------------------------- memory ---

memory_growth_is_bounded_per_instance(_Config) ->
    {ok, Mem} = wasm_memory:new(1, 4),
    {ok, 1, Mem1} = wasm_memory:grow(Mem, 3),
    ?assertEqual(4, wasm_memory:size_pages(Mem1)),
    %% Beyond the declared maximum, growth is refused as a value rather than a
    %% trap, which is what the specification requires.
    ?assertEqual({error, exceeds_max}, wasm_memory:grow(Mem1, 1)),
    wasm_memory:free(Mem1).

memory_growth_is_bounded_node_wide(_Config) ->
    Before = wasm_engine:pages_in_use(),
    wasm_engine:set_page_limit(Before + 8),
    {ok, Mem} = wasm_memory:new(4, undefined),
    %% The node-wide budget is what stops a thousand small instances doing what
    %% one large one cannot. `atomics` pages are off-heap, so `max_heap_size`
    %% cannot see them and this has to be accounted explicitly.
    ?assertEqual({error, page_limit}, wasm_memory:grow(Mem, 8)),
    wasm_memory:free(Mem),
    wasm_engine:set_page_limit(16384).

pages_are_released_when_worker_stops(_Config) ->
    Before = wasm_engine:pages_in_use(),
    W = worker(memory_module(), #{isolation => reuse}),
    %% The worker instantiates in a `handle_continue', so `start_link'
    %% returning says nothing about whether the memory exists yet. Reading the
    %% counter straight away was a race that only ever passed because
    %% instantiation was faster than the reply reached this process.
    wait_until(fun() -> wasm_engine:pages_in_use() > Before end, 2000),
    unlink(W),
    Ref = monitor(process, W),
    ok = wasm_worker:stop(W),
    receive {'DOWN', Ref, process, W, _} -> ok after 2000 -> ct:fail(no_down) end,
    wait_until(fun() -> wasm_engine:pages_in_use() =:= Before end, 2000).

%% Even an instance nobody cleaned up must give its pages back.
%%
%% This leaked: `wasm_memory:free/1` was only reachable from a cleanup callback,
%% so a process that created instances inline and exited left the counter
%% permanently high. `wasm_keeper` now monitors the creating process.
discarded_instances_release_their_pages(_Config) ->
    {ok, Mod} = wasm:compile(memory_module()),
    Before = wasm_engine:pages_in_use(),
    Self = self(),
    Owner = spawn(fun() ->
                      [{ok, _} = wasm:instantiate(Mod, #{}) || _ <- lists:seq(1, 20)],
                      Self ! made,
                      receive done -> ok end
                  end),
    receive made -> ok after 2000 -> ct:fail(no_instances) end,
    ?assert(wasm_engine:pages_in_use() > Before),
    Ref = monitor(process, Owner),
    Owner ! done,
    receive {'DOWN', Ref, process, Owner, _} -> ok after 2000 -> ct:fail(no_down) end,
    wait_until(fun() -> wasm_engine:pages_in_use() =:= Before end, 2000).

%% A memory must not cost dramatically more than it declares. A fixed 1 MiB
%% chunk made a single 64 KiB page allocate 1 MiB, so an instance cost 1080 KB
%% against 11 KB of process.
memory_allocation_tracks_declared_size(_Config) ->
    [begin
         erlang:garbage_collect(),
         Before = erlang:memory(total),
         Mems = [element(2, wasm_memory:new(Pages, undefined))
                 || _ <- lists:seq(1, 20)],
         erlang:garbage_collect(),
         Each = (erlang:memory(total) - Before) / 20,
         [wasm_memory:free(M) || M <- Mems],
         Declared = Pages * 65536,
         ?assert(Each < Declared * 1.5,
                 {Pages, declared, Declared, allocated, round(Each)})
     end || Pages <- [1, 2, 4, 16]].

%%% ------------------------------------------------------------- isolation ---

killing_a_worker_does_not_disturb_others(_Config) ->
    Ws = [worker(add_module(), #{isolation => reuse}) || _ <- lists:seq(1, 5)],
    [Victim | Survivors] = Ws,
    unlink(Victim),
    exit(Victim, kill),
    timer:sleep(50),
    ?assertNot(is_process_alive(Victim)),
    [?assertEqual({ok, [7]}, wasm_worker:call(P, ~"add", [3, 4])) || P <- Survivors],
    ?assertEqual(4, length([P || P <- Survivors, is_process_alive(P)])).

crashing_host_function_becomes_a_trap(_Config) ->
    Imports = #{{~"env", ~"f"} => fun(_Ctx, _Args) -> error(boom) end},
    W = worker(import_module(), #{isolation => reuse, imports => Imports}),
    %% An Erlang exception inside an import must not escape as an exception: the
    %% embedder supplied that code, but the caller still gets a value.
    ?assertMatch({error, #{class := trap, kind := host_error}},
                 wasm_worker:call(W, ~"run", [])),
    ?assert(is_process_alive(W)).

trap_leaves_instance_usable(_Config) ->
    W = worker(trap_module(), #{isolation => reuse}),
    ?assertMatch({error, #{class := trap, kind := unreachable}},
                 wasm_worker:call(W, ~"boom", [])),
    %% A trap aborts the invocation, not the instance. The specification is
    %% explicit that the instance remains valid afterwards.
    ?assertEqual({ok, [7]}, wasm_worker:call(W, ~"add", [3, 4])).

worker_is_labelled_for_observability(_Config) ->
    W = worker(add_module(), #{isolation => reuse, name => my_plugin}),
    ?assertEqual({wasm_worker, my_plugin}, proc_lib:get_label(W)).

%%% ---------------------------------------------------------------- limits ---

limits_are_validated(_Config) ->
    ?assertEqual(ok, wasm_limits:validate(wasm_limits:untrusted())),
    ?assertEqual(ok, wasm_limits:validate(wasm_limits:trusted())),
    ?assertMatch({error, {invalid_limits, [fuel]}},
                 wasm_limits:validate(#{fuel => -1})).

%% The per-process state cache must never serve a stale answer.
%%
%% Reading instance state out of ETS copies it, 398 ns on a real module, so each
%% process caches what it last saw and checks a shared version counter. That is
%% only sound if a write by any process invalidates every other cache.
state_stays_coherent_across_processes(_Config) ->
    {ok, Mod} = wasm:compile(counter_module()),
    {ok, Inst} = wasm:instantiate(Mod, #{}),
    Self = self(),
    ?assertEqual({ok, [1]}, wasm:call(Inst, ~"inc", [])),
    spawn(fun() -> Self ! {seen, wasm:call(Inst, ~"get", [])} end),
    receive {seen, R1} -> ?assertEqual({ok, [1]}, R1)
    after 2000 -> ct:fail(no_reply)
    end,
    spawn(fun() ->
              _ = wasm:call(Inst, ~"inc", []),
              _ = wasm:call(Inst, ~"inc", []),
              Self ! done
          end),
    receive done -> ok after 2000 -> ct:fail(no_done) end,
    ?assertEqual({ok, [3]}, wasm:call(Inst, ~"get", [])).

wait_until(Pred, 0) -> Pred() orelse ct:fail(timeout_waiting);
wait_until(Pred, Ms) ->
    case Pred() of
        true -> ok;
        false -> timer:sleep(20), wait_until(Pred, erlang:max(Ms - 20, 0))
    end.

%%% ---------------------------------------------------------- test modules ---
%%
%% Hand-assembled so the suite needs no toolchain.

%% (func (export "spin") loop br 0 end)
spin_module() ->
    module_of([{<<16#60, 0, 0>>, <<0, 16#03, 16#40, 16#0C, 0, 16#0B, 16#0B>>,
                <<"spin">>}]).

%% (func $go (export "go") (call $go))
recurse_module() ->
    module_of([{<<16#60, 0, 0>>, <<0, 16#10, 0, 16#0B>>, <<"go">>}]).

%% (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add)
add_module() ->
    module_of([{<<16#60, 2, 16#7F, 16#7F, 1, 16#7F>>,
                <<0, 16#20, 0, 16#20, 1, 16#6A, 16#0B>>, <<"add">>}]).

%% Two functions: one traps, one adds.
trap_module() ->
    module_of([{<<16#60, 0, 0>>, <<0, 16#00, 16#0B>>, <<"boom">>},
               {<<16#60, 2, 16#7F, 16#7F, 1, 16#7F>>,
                <<0, 16#20, 0, 16#20, 1, 16#6A, 16#0B>>, <<"add">>}]).

memory_module() ->
    Type = <<16#60, 0, 0>>,
    Code = <<0, 16#0B>>,
    Sections =
        [section(1, <<1, Type/binary>>),
         section(3, <<1, 0>>),
         section(5, <<1, 16#01, 4, 8>>),            % memory, min 4 max 8
         section(7, <<1, 4, "noop", 16#00, 0>>),
         section(10, <<1, (byte_size(Code)), Code/binary>>)],
    iolist_to_binary([<<0, "asm", 1:32/little>> | Sections]).

%% (import "env" "f" (func)) (func (export "run") (call 0))
import_module() ->
    Type = <<16#60, 0, 0>>,
    Code = <<0, 16#10, 0, 16#0B>>,
    Sections =
        [section(1, <<1, Type/binary>>),
         section(2, <<1, 3, "env", 1, "f", 16#00, 0>>),
         section(3, <<1, 0>>),
         section(7, <<1, 3, "run", 16#00, 1>>),
         section(10, <<1, (byte_size(Code)), Code/binary>>)],
    iolist_to_binary([<<0, "asm", 1:32/little>> | Sections]).

module_of(Funcs) ->
    Types = [T || {T, _, _} <- Funcs],
    Codes = [C || {_, C, _} <- Funcs],
    N = length(Funcs),
    TypeSec = section(1, [<<N>> | Types]),
    FuncSec = section(3, [<<N>> | [<<I>> || I <- lists:seq(0, N - 1)]]),
    ExportSec = section(7, [<<N>> |
                            [<<(byte_size(Nm)), Nm/binary, 16#00, I>>
                             || {I, {_, _, Nm}} <- lists:enumerate(0, Funcs)]]),
    CodeSec = section(10, [<<N>> | [<<(byte_size(C)), C/binary>> || C <- Codes]]),
    iolist_to_binary([<<0, "asm", 1:32/little>>,
                      TypeSec, FuncSec, ExportSec, CodeSec]).

section(Id, Payload) ->
    Bin = iolist_to_binary(Payload),
    <<Id:8, (byte_size(Bin)):8, Bin/binary>>.

%% (global $g (mut i32)) with inc/get: the smallest thing that can leak state
%% between requests, which is what the isolation policy is judged on.
counter_module() ->
    Bodies = [{<<16#60, 0, 1, 16#7F>>,
               <<0, 16#23, 0, 16#41, 1, 16#6A, 16#24, 0, 16#23, 0, 16#0B>>,
               ~"inc"},
              {<<16#60, 0, 1, 16#7F>>, <<0, 16#23, 0, 16#0B>>, ~"get"}],
    Types = [T || {T, _, _} <- Bodies],
    Codes = [C || {_, C, _} <- Bodies],
    N = length(Bodies),
    TypeSec = section(1, [<<N>> | Types]),
    FuncSec = section(3, [<<N>> | [<<I>> || I <- lists:seq(0, N - 1)]]),
    GlobalSec = section(6, <<1, 16#7F, 16#01, 16#41, 0, 16#0B>>),
    ExportSec = section(7, [<<N>> |
                            [<<(byte_size(Nm)), Nm/binary, 16#00, I>>
                             || {I, {_, _, Nm}} <- lists:enumerate(0, Bodies)]]),
    CodeSec = section(10, [<<N>> | [<<(byte_size(C)), C/binary>> || C <- Codes]]),
    iolist_to_binary([<<0, "asm", 1:32/little>>, TypeSec, FuncSec, GlobalSec,
                      ExportSec, CodeSec]).

%% Two modules sharing a table must see each other's writes, and a reference
%% written by one must call *its* function, not the same index in the other.
%%
%% This did not work before 0.2.0 on two counts: tables were immutable arrays
%% copied into each instance, and a `funcref' was a bare index, so module B's
%% reference was reinterpreted against module A's function space and silently
%% called the wrong function.
shared_table_is_shared_by_reference(_Config) ->
    {ok, ModA} = wasm:compile(table_owner_module()),
    {ok, A} = wasm:instantiate(ModA, #{}),
    %% A's own element segment put its function at index 0.
    ?assertEqual({ok, [11]}, wasm:call(A, ~"call0", [])),
    {ok, Table} = wasm:extern(A, ~"t"),
    {ok, ModB} = wasm:compile(table_writer_module()),
    {ok, _B} = wasm:instantiate(ModB, #{{~"m1", ~"t"} => Table}),
    %% B's element segment overwrote index 0, and A sees it.
    ?assertEqual({ok, [22]}, wasm:call(A, ~"call0", [])).

%% (table (export "t") 4 funcref) (func $a -> 11) (elem (i32.const 0) $a)
%% (func (export "call0") -> call_indirect 0)
table_owner_module() ->
    Types = [<<16#60, 0, 1, 16#7F>>],
    Codes = [<<0, 16#41, 11, 16#0B>>,                       % $a: i32.const 11
             <<0, 16#41, 0, 16#11, 0, 0, 16#0B>>],          % call0
    iolist_to_binary(
      [<<0, "asm", 1:32/little>>,
       section(1, [<<1>> | Types]),
       section(3, <<2, 0, 0>>),
       section(4, <<1, 16#70, 16#00, 4>>),                  % table 4 funcref
       section(7, <<2, 5, "call0", 16#00, 1, 1, "t", 16#01, 0>>),
       section(9, <<1, 16#00, 16#41, 0, 16#0B, 1, 0>>),     % elem (i32.const 0) 0
       section(10, [<<2>> | [<<(byte_size(C)), C/binary>> || C <- Codes]])]).

%% (import "m1" "t" (table 4 funcref)) (func $b -> 22) (elem (i32.const 0) $b)
table_writer_module() ->
    Codes = [<<0, 16#41, 22, 16#0B>>],
    iolist_to_binary(
      [<<0, "asm", 1:32/little>>,
       section(1, <<1, 16#60, 0, 1, 16#7F>>),
       section(2, <<1, 2, "m1", 1, "t", 16#01, 16#70, 16#00, 4>>),
       section(3, <<1, 0>>),
       section(9, <<1, 16#00, 16#41, 0, 16#0B, 1, 0>>),
       section(10, [<<1>> | [<<(byte_size(C)), C/binary>> || C <- Codes]])]).
