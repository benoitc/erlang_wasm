-module(tiered).
-moduledoc """
Whether the compiled tier is actually running the program.

Use this as the gate on any change that adds instructions to the subset. It
counts the interpreter's own dispatch, tier off and tier on, by call-count
tracing `wasm_exec:run/3` rather than by inferring anything.

    erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/tiered.erl
    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run tiered main qjs

**Coverage is not the gate and never was.** `bench/paths/coverage.erl` reports
the share of *functions* that compile, and that number has pointed the wrong way
twice: QuickJS reached 93% compiled while about 1% of its executed instructions
were, because one unsupported instruction anywhere in the hot function keeps
that whole function interpreted, and a bytecode interpreter is one function.

Counting function *entries* is no better, and is how the mistake was made: with
the tier on, QuickJS entered only 204 functions interpreted against 23,069, and
every one of those 204 ran a loop of about 720,000 instructions. A function
entered once and a function entered once that runs for a second look identical
by call count. Dispatches do not lie.

The tier compiles off the calling process, so the arm waits for it. Without
that, it measures the interpreter while a compiler runs beside it.
""".
-export([main/1]).

main([Arm]) ->
    {ok, _} = application:ensure_all_started(wasm),
    {module, wasm_exec} = code:ensure_loaded(wasm_exec),
    W = workload(list_to_atom(Arm)),
    io:format("~-10s ~12s ~18s ~10s~n",
              ["tier", "wall (traced)", "run/3 calls", "compiled"]),
    Off = measure(W, #{}),
    On = measure(W, #{compile => true, compile_after => 1}),
    report(Off, On),
    init:stop().

measure(W, Opts) ->
    M = W(module),
    ok = warm(W, M, Opts),
    %% A fresh process, because repeating a real workload in one process is
    %% bimodal on collection time. See `bench/paths/matrix.erl`.
    benchlib:in_process(fun() ->
        {ok, I} = W({instance, M, Opts}),
        _ = erlang:trace_pattern({wasm_exec, run, 3}, true, [call_count]),
        {T, ok} = timer:tc(fun() -> W({call, I}) end),
        {call_count, N} = erlang:trace_info({wasm_exec, run, 3}, call_count),
        _ = erlang:trace_pattern({wasm_exec, run, 3}, false, [call_count]),
        ok = wasm:destroy(I),
        {T, N, maps:get(compiled, wasm_jit:counts())}
    end).

%% The dispatch counts are the answer. The wall times are not a speedup and are
%% printed only to show the arm did something: call-count tracing charges the
%% arm that dispatches 148 million times and charges nothing to the arm that
%% dispatches none, so the ratio between them is inflated by the instrument.
%% `bench/paths/realbench.erl` is where a speed claim comes from.
report({T0, N0, _}, {T1, N1, C}) ->
    io:format("~-10s ~9.1f ms ~18w ~10s~n", ["off", T0 / 1000, N0, "-"]),
    io:format("~-10s ~9.1f ms ~18w ~10w~n", ["on", T1 / 1000, N1, C]),
    io:format("~n  the interpreter executes ~.2f% of the instructions it did~n"
              "  (wall times include tracing overhead and are not a speedup)~n",
              [case N0 of 0 -> 0.0; _ -> N1 * 100 / N0 end]),
    %% The two failure shapes this exists to name, in the terms that caused them.
    [io:format("  ** the tier is not running the program: coverage is not the gate~n")
     || N1 * 10 > N0],
    [io:format("  ** compiled code was never entered~n") || C =:= 0].

%% Run once to make the module hot, then wait for the compiler. With the tier
%% off there is nothing to wait for.
warm(W, M, #{compile := true} = Opts) ->
    {ok, I} = W({instance, M, Opts}),
    _ = W({call, I}),
    R = wasm_jit:await(I, 600000),
    ok = wasm:destroy(I),
    R;
warm(_W, _M, _Opts) ->
    ok.

%%% ------------------------------------------------------------ workloads ---

workload(qjs) ->
    Dir = filename:join(["/tmp", "wasm-tiered"]),
    ok = filelib:ensure_path(Dir),
    ok = file:write_file(
           filename:join(Dir, "b.js"),
           ~"var a=0; for (var i=0;i<30000;i++) { a=(a+i*3)^(a>>>7); } print(a);"),
    Cfg = #{args => [~"qjs", ~"/s/b.js"], env => #{},
            dirs => [{~"/s", Dir, read}],
            clocks => [monotonic, realtime], random => strong,
            stdout => fun(_) -> ok end, stderr => fun(_) -> ok end},
    fun(module) -> fixture(["lang", "qjs.wasm"]);
       ({instance, M, O}) -> wasm:instantiate(M, wasi_preview1:imports(Cfg), O);
       ({call, I}) -> {ok, _} = wasm:call(I, ~"_start", []), ok
    end;
workload(plugin) ->
    Im = wasi_preview1:imports(#{}),
    fun(module) -> fixture(["plugin", "plugin.wasm"]);
       ({instance, M, O}) -> wasm:instantiate(M, Im, O);
       ({call, I}) ->
            _ = [{ok, _} = wasm:call(I, ~"capacity", [])
                 || _ <- lists:seq(1, 2000)],
            ok
    end.

fixture(Parts) ->
    {ok, B} = file:read_file(filename:join(["test", "fixtures" | Parts])),
    {ok, M} = wasm:compile(B),
    M.

