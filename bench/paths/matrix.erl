-module(matrix).
-moduledoc """
Measurement you can trust, and the instrument for the run-to-run anomaly.

Use this before believing any number taken from a repeated run in one node.
`realbench` reports wall time per run; this reports *why* two runs of the same
work differ, by recording what the emulator was doing during each.

    erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/matrix.erl
    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run matrix main qjs same 3

The three axes:

- **workload** `qjs | memloop | arith | plugin`. `memloop` and `arith` are the
  same loop with and without memory traffic, so a slowdown that appears in one
  and not the other says whether memory access is where the time went. Both are
  built from text here rather than from a fixture, so the tool is self
  contained.
- **mode** `same | fresh | helper`. `same` runs every iteration in the calling
  process, which is what reproduces the anomaly. `fresh` gives each iteration a
  new process. `helper` decodes and instantiates in one process and runs in
  another, separating build cost from execution cost.
- **count**, the number of iterations.

Per iteration it records wall and CPU time, reductions, garbage collections and
words reclaimed, the process heap, node memory by category, and the microstate
accounting delta. `msacc` is the one that matters: it says whether lost time
went to garbage collection, to the emulator, to a NIF or to auxiliary work,
which partitions the hypothesis space in a single run.

A diagnostic, never a timed comparison. Use `realbench` for that.
""".
-include_lib("wasm/include/wasm.hrl").
-include_lib("wasm/include/wasm_exec.hrl").
-export([main/1]).

main([W]) -> main([W, "same", "3"]);
main([W, Mode]) -> main([W, Mode, "3"]);
main([W, Mode, N]) ->
    {ok, _} = application:ensure_all_started(wasm),
    Workload = list_to_atom(W),
    Count = list_to_integer(N),
    io:format("~s / ~s / ~p iterations, load ~s~n",
              [W, Mode, Count, loadavg()]),
    instruments_on(),
    Rows = run(list_to_atom(Mode), Workload, Count),
    report(Rows),
    init:stop().

%%% --------------------------------------------------------------- modes ---

%% Every mode builds the module once and the *instance* per iteration, because
%% an instance is what a workload actually costs and reusing one would measure
%% something no embedder does.
run(same, W, N) ->
    M = build(W),
    [measure(W, M, K) || K <- lists:seq(1, N)];
run(fresh, W, N) ->
    M = build(W),
    [benchlib:in_process(fun() -> measure(W, M, K) end) || K <- lists:seq(1, N)];
run(helper, W, N) ->
    %% The module is decoded and validated somewhere else entirely, so nothing
    %% the build left on this process's heap can be blamed for the execution.
    M = benchlib:in_process(fun() -> build(W) end),
    [benchlib:in_process(fun() -> measure(W, M, K) end) || K <- lists:seq(1, N)].


%%% ---------------------------------------------------------- instruments ---

instruments_on() ->
    _ = erlang:system_flag(scheduler_wall_time, true),
    case msacc:available() of
        true -> _ = msacc:start(), ok;
        false -> io:format("  (microstate accounting unavailable)~n")
    end.

%% One iteration, with everything that could explain a difference recorded
%% around it rather than after it.
measure(W, M, K) ->
    _ = erlang:garbage_collect(),
    have_msacc() andalso msacc:reset(),
    {GC0, Words0, _} = erlang:statistics(garbage_collection),
    {Cpu0, _} = erlang:statistics(runtime),
    Red0 = reductions(),
    {Wall, Result} = timer:tc(fun() -> exercise(W, M) end),
    Red1 = reductions(),
    {Cpu1, _} = erlang:statistics(runtime),
    {GC1, Words1, _} = erlang:statistics(garbage_collection),
    #{n => K, wall_us => Wall, cpu_ms => Cpu1 - Cpu0,
      reductions => Red1 - Red0, gcs => GC1 - GC0, words => Words1 - Words0,
      heap => element(2, process_info(self(), total_heap_size)),
      mem => erlang:memory([total, processes, binary, ets]),
      msacc => msacc_types(),
      result => Result}.

reductions() ->
    {R, _} = erlang:statistics(reductions),
    R.

have_msacc() -> msacc:available().

%% Runtime per microstate, summed over every thread. The shape of this list is
%% what says where a lost second went: to garbage collection, to the emulator,
%% to a port or NIF, or to auxiliary work.
%%
%% The raw counters are aggregated here rather than through `msacc:stats/2',
%% whose argument order is not stable across releases. They are performance
%% counter units, so they compare between runs but are not absolute times.
%% `sleep' is dropped: it is every idle scheduler and it drowns everything.
msacc_types() ->
    case have_msacc() of
        false -> [];
        true ->
            Sum = lists:foldl(
                    fun(#{counters := C}, Acc) ->
                            maps:fold(fun(K, V, A) ->
                                              maps:update_with(
                                                K, fun(X) -> X + V end, V, A)
                                      end, Acc, C)
                    end, #{}, msacc:stats()),
            [{K, V} || {K, V} <- lists:sort(maps:to_list(Sum)),
                       V > 0, K =/= sleep]
    end.

%%% ------------------------------------------------------------ workloads ---

build(qjs) ->
    {ok, B} = file:read_file(filename:join(["test", "fixtures", "lang", "qjs.wasm"])),
    {ok, M} = wasm:compile(B),
    M;
build(plugin) ->
    {ok, B} = file:read_file(filename:join(["test", "fixtures", "plugin", "plugin.wasm"])),
    {ok, M} = wasm:compile(B),
    M;
build(W) ->
    {ok, P} = wasm_wat:module(source(W)),
    {ok, M} = wasm_validate:module(P),
    M.

%% The same counted loop with and without memory traffic. `memloop' adds one
%% store and one load per iteration and nothing else, so the difference between
%% the two arms is the cost of touching linear memory and only that.
source(arith) ->
    ~"(module
        (func (export \"run\") (param i32) (result i32) (local i32)
          block loop
            local.get 0 i32.eqz br_if 1
            local.get 1 local.get 0 i32.add local.set 1
            local.get 0 i32.const 1 i32.sub local.set 0
            br 0
          end end
          local.get 1))";
source(memloop) ->
    ~"(module
        (memory 1)
        (func (export \"run\") (param i32) (result i32) (local i32) (local i32)
          block loop
            local.get 0 i32.eqz br_if 1
            local.get 0 i32.const 65532 i32.and local.set 2
            local.get 2 local.get 0 i32.store
            local.get 1 local.get 2 i32.load i32.add local.set 1
            local.get 0 i32.const 1 i32.sub local.set 0
            br 0
          end end
          local.get 1))".

-define(LOOP_N, 2000000).

exercise(qjs, M) ->
    Dir = script_dir(),
    Cfg = #{args => [~"qjs", ~"/s/bench.js"], env => #{},
            dirs => [{~"/s", Dir, read}],
            clocks => [monotonic, realtime], random => strong,
            stdout => fun(_) -> ok end, stderr => fun(_) -> ok end},
    {ok, I} = wasm:instantiate(M, wasi_preview1:imports(Cfg), #{}),
    %% Asserted, so a run that did not happen cannot be reported as one that did.
    {ok, _} = wasm:call(I, ~"_start", []),
    ok = wasm:destroy(I),
    ok;
exercise(plugin, M) ->
    {ok, I} = wasm:instantiate(M, wasi_preview1:imports(#{}), #{}),
    _ = [{ok, _} = wasm:call(I, ~"capacity", []) || _ <- lists:seq(1, 200)],
    ok = wasm:destroy(I),
    ok;
exercise(_, M) ->
    {ok, I} = wasm:instantiate(M, #{}, #{}),
    {ok, [R]} = wasm:call(I, ~"run", [?LOOP_N]),
    ok = wasm:destroy(I),
    R.

script_dir() ->
    Dir = filename:join(["/tmp", "wasm-matrix"]),
    ok = filelib:ensure_path(Dir),
    ok = file:write_file(
           filename:join(Dir, "bench.js"),
           ~"var a=0; for (var i=0;i<30000;i++) { a=(a+i*3)^(a>>>7); } print(a);"),
    Dir.

%%% --------------------------------------------------------------- report ---

report(Rows) ->
    io:format("~n~4s ~10s ~8s ~14s ~6s ~12s ~10s~n",
              ["run", "wall ms", "cpu ms", "reductions", "gcs", "words", "heap"]),
    [io:format("~4w ~10.1f ~8w ~14w ~6w ~12w ~10w~n",
               [N, W / 1000, C, R, G, Wo, H])
     || #{n := N, wall_us := W, cpu_ms := C, reductions := R,
          gcs := G, words := Wo, heap := H} <- Rows],

    io:format("~nnode memory, MB~n~4s ~10s ~10s ~10s ~10s~n",
              ["run", "total", "processes", "binary", "ets"]),
    [io:format("~4w ~10.1f ~10.1f ~10.1f ~10.1f~n",
               [N, mb(T), mb(P), mb(B), mb(E)])
     || #{n := N, mem := [{total, T}, {processes, P}, {binary, B}, {ets, E}]} <- Rows],

    %% The partition. A run that is slower with the same reductions has lost the
    %% time somewhere the reduction counter does not see, and this says where.
    io:format("~nmicrostate runtime per run, us~n"),
    [begin
         io:format("~4w  ~s~n",
                   [N, [io_lib:format("~s=~w ", [T, V]) || {T, V} <- S]])
     end || #{n := N, msacc := S} <- Rows, S =/= []],

    Walls = [W || #{wall_us := W} <- Rows],
    case Walls of
        [_, _ | _] ->
            Lo = lists:min(Walls), Hi = lists:max(Walls),
            io:format("~nspread ~.1fx (~.1f ms to ~.1f ms)~n",
                      [Hi / Lo, Lo / 1000, Hi / 1000]);
        _ -> ok
    end.

mb(B) -> B / (1024 * 1024).

loadavg() ->
    case os:type() of
        {unix, _} -> string:trim(os:cmd("uptime | sed 's/.*averages*: //'"));
        _ -> "?"
    end.
