-module(vs).
-moduledoc """
erlang_wasm against erlang-wasmtime, one runtime per VM.

Use it to compare this runtime with Wasmtime called from Erlang through its
binding, on the same bytes. Each run measures one runtime and writes its
results as terms; `run.sh` interleaves the two, one fresh VM per runtime per
round, and `summary.escript` reads the results. `run.sh` builds each `.wat` with
`wasm-tools` first, so neither VM loads the other runtime to parse text.

    erl -noshell -pa _build/default/lib/*/ebin \\
        -pa ~/Projects/erlang-wasmtime/_build/default/lib/erlang_wasmtime/ebin \\
        -pa bench/cross/vs -run vs main erlang_wasm QJS_WASM OUT.terms

What it measures, with the same module bytes and the same checksum on both
sides:

- `loop`, `mem`, `bulk`: nanoseconds per iteration, the slope between two
  sizes so the call's fixed cost cancels out. erlang_wasm compiles every
  function on the first call (`compiled/0`), as Wasmtime compiles before it
  runs.
- `fib30`: one call of `fib(30)`.
- `call`: one call from Erlang into the cheapest export, from 10,000 calls.
- `plugin`: compile, instantiate and destroy a 46 KB WASI module.
- `qjs`: a QuickJS build running a 30,000-iteration script: module compile,
  then instantiate and `_start`. erlang_wasm also reports its first,
  interpreted run, which includes compiling the whole module.
""".
-export([main/1]).

-define(SAMPLES, 5).
-define(TARGET_US, 150000).

main([Arm, Qjs, Out]) ->
    Dir = filename:dirname(code:which(?MODULE)),
    R = try run(list_to_atom(Arm), Dir, Qjs)
        catch C:E:S -> #{failed => {C, E, S}}
        end,
    {ok, F} = file:open(Out, [write]),
    io:format(F, "~p.~n", [R#{arm => Arm, load => load()}]),
    ok = file:close(F),
    io:format("~p~n", [R]),
    erlang:halt(0).

run(Arm, Dir, Qjs) ->
    ok = start(Arm),
    Bytes = fun(Name) ->
                {ok, B} = file:read_file(filename:join(Dir, Name ++ ".wasm")),
                B
            end,
    {ok, Loop} = file:read_file(filename:join([Dir, "..", "loop.wasm"])),
    Rows = [{loop, per_iter(Arm, Loop, ~"bench")},
            {mem, per_iter(Arm, Bytes("mem"), ~"bench")},
            {bulk, per_iter(Arm, Bytes("bulk"), ~"bench")},
            {fib30, fib30(Arm, Bytes("fib"))},
            {call, call(Arm, Bytes("nop"))},
            {plugin, plugin(Arm, Dir)},
            {qjs, qjs(Arm, Dir, Qjs)}],
    maps:from_list(Rows).

start(erlang_wasm) -> {ok, _} = application:ensure_all_started(wasm), ok;
start(wasmtime)    -> {ok, _} = application:ensure_all_started(erlang_wasmtime), ok.

%%% ------------------------------------------------------------ the arms ---

%% A compiled instance with no imports, and how to call it.
inst(erlang_wasm, Bin) ->
    {ok, M} = wasm:compile(Bin),
    {ok, I} = wasm:instantiate(M, #{}, compiled()),
    {I, fun(Name, Args) -> {ok, Vs} = wasm:call(I, Name, Args), Vs end,
     fun() -> wasm:destroy(I) end};
inst(wasmtime, Bin) ->
    {ok, M} = wasmtime:compile(Bin),
    {ok, I} = wasmtime:instantiate(M, #{}),
    {I, fun(Name, Args) -> {ok, Vs} = wasmtime:call(I, Name, Args), Vs end,
     fun() -> wasmtime:destroy(I) end}.

per_iter(Arm, Bin, Export) ->
    {_, Call, Stop} = inst(Arm, Bin),
    _ = Call(Export, [1000]),                       % compiles, on our side
    _ = Call(Export, [1000]),
    N = calibrate(fun(K) -> Call(Export, [K]) end, 1000),
    T1 = median([us(fun() -> Call(Export, [N]) end) || _ <- seq()]),
    T2 = median([us(fun() -> Call(Export, [2 * N]) end) || _ <- seq()]),
    [Check] = Call(Export, [1000000]),
    Stop(),
    #{ns_per_iter => (T2 - T1) * 1000 / N, n => N, checksum => Check}.

fib30(Arm, Bin) ->
    {_, Call, Stop} = inst(Arm, Bin),
    _ = Call(~"fib", [20]),
    _ = Call(~"fib", [20]),
    Ts = [us(fun() -> Call(~"fib", [30]) end) || _ <- seq()],
    [Check] = Call(~"fib", [30]),
    Stop(),
    #{ms => median(Ts) / 1000, checksum => Check}.

call(Arm, Bin) ->
    {_, Call, Stop} = inst(Arm, Bin),
    _ = [Call(~"nop", [1]) || _ <- lists:seq(1, 1000)],
    Batch = fun() -> us(fun() -> [Call(~"nop", [K]) || K <- lists:seq(1, 10000)] end) end,
    Ts = [Batch() || _ <- seq()],
    Stop(),
    #{ns_per_call => median(Ts) * 1000 / 10000}.

plugin(Arm, Dir) ->
    {ok, Bin} = file:read_file(filename:join([Dir, "..", "..", "..", "test",
                                              "fixtures", "plugin", "plugin.wasm"])),
    One = fun() -> us(fun() -> plugin_once(Arm, Bin) end) end,
    _ = One(),
    #{us => median([One() || _ <- seq()])}.

plugin_once(erlang_wasm, Bin) ->
    {ok, M} = wasm:compile(Bin),
    {ok, I} = wasm:instantiate(M, wasi_preview1:imports(#{})),
    wasm:destroy(I);
plugin_once(wasmtime, Bin) ->
    {ok, M} = wasmtime:compile(Bin),
    {ok, I} = wasmtime:instantiate(M, #{wasi => #{}}),
    wasmtime:destroy(I).

%%% ------------------------------------------------------------- QuickJS ---

qjs(Arm, Dir, Path) ->
    {ok, Bin} = file:read_file(Path),
    Compile = median([us(fun() -> qjs_compile(Arm, Bin) end) || _ <- [1, 2, 3]]),
    Mod = qjs_compile(Arm, Bin),
    First = qjs_first(Arm, Mod, Dir),
    Runs = [qjs_run(Arm, Mod, Dir) || _ <- seq()],
    #{compile_ms => Compile / 1000,
      first => First,
      instantiate_ms => median([I || {I, _, _} <- Runs]) / 1000,
      start_ms => median([S || {_, S, _} <- Runs]) / 1000,
      checksum => lists:usort([C || {_, _, C} <- Runs])}.

qjs_compile(erlang_wasm, Bin) -> {ok, M} = wasm:compile(Bin), M;
qjs_compile(wasmtime, Bin)    -> {ok, M} = wasmtime:compile(Bin), M.

%% erlang_wasm's first instance compiles every function before it runs, and
%% the instances after it reuse that code. Wasmtime compiled at
%% `qjs_compile/2`, so its first run is an ordinary one.
qjs_first(erlang_wasm, Mod, Dir) ->
    Interp = qjs_run(erlang_wasm, Mod, Dir, #{}),
    Compiled = qjs_run(erlang_wasm, Mod, Dir, compiled()),
    #{interpreted_ms => element(2, Interp) / 1000,
      first_compiled_ms => (element(1, Compiled) + element(2, Compiled)) / 1000};
qjs_first(wasmtime, _Mod, _Dir) ->
    #{}.

qjs_run(erlang_wasm, Mod, Dir) ->
    qjs_run(erlang_wasm, Mod, Dir, #{compile => true});
qjs_run(wasmtime, Mod, Dir) ->
    T0 = now_us(),
    {ok, I} = wasmtime:instantiate(Mod, #{wasi => #{
        args => [~"qjs", ~"/app/bench.js"],
        dirs => [{~"/app", Dir, read}],
        stdout => capture}}),
    T1 = now_us(),
    _ = wasmtime:call(I, ~"_start", []),
    T2 = now_us(),
    {ok, {Out, _, _}} = wasmtime:read_output(I),
    ok = wasmtime:destroy(I),
    {T1 - T0, T2 - T1, string:trim(Out)}.

qjs_run(erlang_wasm, Mod, Dir, Opts) ->
    Self = self(),
    Ref = make_ref(),
    Imports = wasi_preview1:imports(#{
        args => [~"qjs", ~"/app/bench.js"],
        dirs => [{~"/app", Dir, read}],
        stdout => fun(B) -> Self ! {Ref, B}, ok end}),
    T0 = now_us(),
    {ok, I} = wasm:instantiate(Mod, Imports, Opts),
    T1 = now_us(),
    _ = wasm:call(I, ~"_start", []),
    T2 = now_us(),
    ok = wasm:destroy(I),
    {T1 - T0, T2 - T1, string:trim(drain(Ref, <<>>))}.

drain(Ref, Acc) ->
    receive {Ref, B} -> drain(Ref, <<Acc/binary, (iolist_to_binary(B))/binary>>)
    after 0 -> Acc
    end.

%%% ------------------------------------------------------------- helpers ---

%% Compile every function on the first call, before running it, as Wasmtime
%% compiles before it runs. `compile_after => 1' matters: without it the
%% module waits for 32 calls before it compiles anything, and a benchmark of
%% a few long calls measures the interpreter.
compiled() ->
    #{compile => true, compile_whole => true, compile_sync => true,
      compile_after => 1}.

%% The smallest doubling of `N` whose call takes at least `?TARGET_US`.
calibrate(Run, N) ->
    case us(fun() -> Run(N) end) >= ?TARGET_US orelse N >= 1 bsl 29 of
        true  -> N;
        false -> calibrate(Run, N * 2)
    end.

us(Fun) ->
    T0 = now_us(),
    _ = Fun(),
    now_us() - T0.

now_us() -> erlang:monotonic_time(microsecond).

seq() -> lists:seq(1, ?SAMPLES).

median(L) ->
    S = lists:sort(L),
    lists:nth((length(S) + 1) div 2, S).

load() ->
    string:trim(os:cmd("sysctl -n vm.loadavg")).
