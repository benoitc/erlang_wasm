-module(sharedbench).
-moduledoc """
What each process that calls one instance lowers, and what it keeps.

A module over the deferral threshold (256 functions) is lowered a function
at a time, on first call, and each lowered body stays in the dictionary of
the process that lowered it. One instance called from several long-lived
processes is therefore lowered once per process, and each process carries
its own copy on its heap. Use this before and after a change to how bodies
are shared between processes.

    erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/sharedbench.erl
    erl -noshell -pa _build/default/lib/*/ebin -pa bench/paths \\
        -run sharedbench main p8

Arms: `p1`, one caller; `p8`, eight callers, one after the other, each kept
alive until the end so its heap is still there. The module is loaded with
`wasm:load/1` and instantiated once. Each caller calls `go` once (its first
call, which lowers what it reaches) and then `?STEADY` more times.

It prints one `RESULT` line: `lowerings`, every call of
`wasm_instance:lower/2` (the one place a body becomes IR) by all callers;
`later_lowerings`, those made by callers 2 and after; `heap_words`, each
caller's `total_heap_size` after a collection, at the end; `first_ms` and
`steady_us`, the medians over callers of the first call and of the steady
calls. `go` returns the same value for every caller, checked.
""".
-export([main/1]).

-define(FUNCS, 300).
-define(OPS, 200).
-define(STEADY, 20).

main([Arm]) ->
    {ok, _} = application:ensure_all_started(wasm),
    P = case Arm of "p1" -> 1; "p8" -> 8 end,
    {ok, Mod} = wasm:load({wat, wat()}),
    {ok, Inst} = wasm:instantiate(Mod, #{}),
    1 = erlang:trace_pattern({wasm_instance, lower, 2}, true, [call_count]),
    Self = self(),
    Callers = [spawn_link(fun() -> caller(Self, Inst) end) || _ <- lists:seq(1, P)],
    Reports = [begin
                   C ! {go, Self},
                   receive {C, R} -> R end
               end || C <- Callers],
    {call_count, Total} = erlang:trace_info({wasm_instance, lower, 2}, call_count),
    [First | _] = Reports,
    Later = lists:sum([maps:get(lowered, R) || R <- tl(Reports)]),
    1 = erlang:trace_pattern({wasm_instance, lower, 2}, false, [call_count]),
    Heaps = [heap(C) || C <- Callers],
    [Want] = lists:usort([maps:get(result, R) || R <- Reports]),
    _ = Want,
    io:format("RESULT arm=~s callers=~b lowerings=~b first_caller_lowerings=~b "
              "later_lowerings=~b heap_words=~w first_ms=~.2f steady_us=~.1f load=~s~n",
              [Arm, P, Total, maps:get(lowered, First), Later, Heaps,
               median([maps:get(first_us, R) || R <- Reports]) / 1000,
               float(median([maps:get(steady_us, R) || R <- Reports])), load()]),
    [exit(C, kill) || C <- Callers],
    ok = wasm:destroy(Inst),
    init:stop().

%% A caller lowers on its first call; lowerings are counted around that call
%% as the change of the global count, which is exact because callers run
%% one at a time.
caller(Main, Inst) ->
    receive {go, Main} -> ok end,
    {call_count, Before} = erlang:trace_info({wasm_instance, lower, 2}, call_count),
    {First, {ok, [R]}} = timer:tc(fun() -> wasm:call(Inst, ~"go", [1]) end),
    {call_count, After} = erlang:trace_info({wasm_instance, lower, 2}, call_count),
    Steady = [element(1, timer:tc(fun() -> {ok, [R]} = wasm:call(Inst, ~"go", [1]) end))
              || _ <- lists:seq(1, ?STEADY)],
    Main ! {self(), #{result => R, lowered => After - Before, first_us => First,
                      steady_us => median(Steady)}},
    receive stop -> ok end.

heap(C) ->
    true = erlang:garbage_collect(C),
    {total_heap_size, W} = process_info(C, total_heap_size),
    W.

%% Function N adds N and then `?OPS' more small steps to its argument, so
%% each body lowers to a few thousand words; `go' calls every function once,
%% in order, threading the value through.
wat() ->
    Body = fun(N) ->
               Steps = [io_lib:format(" i32.const ~b i32.add", [(N * 7 + I) rem 97])
                        || I <- lists:seq(1, ?OPS)],
               io_lib:format("(func $f~b (param i32) (result i32) local.get 0~s)~n",
                             [N, Steps])
           end,
    Calls = [io_lib:format(" call $f~b", [N]) || N <- lists:seq(0, ?FUNCS - 1)],
    iolist_to_binary(
      ["(module\n", [Body(N) || N <- lists:seq(0, ?FUNCS - 1)],
       "(func (export \"go\") (param i32) (result i32) local.get 0", Calls, "))\n"]).

median(L) -> lists:nth((length(L) + 1) div 2, lists:sort(L)).

load() -> lists:nth(2, string:tokens(os:cmd("sysctl -n vm.loadavg"), " {}")).
