-module(vs).
-moduledoc """
One arm of the cross-runtime comparison, in one fresh VM.

Use it through `run.sh`, which builds a fixed baseline and the candidate tree,
runs every arm in turn, and lets `summary.escript` read the results. One run
measures one arm and writes its results, with the manifest of the tree it ran
from, as one term:

    erl -noshell -pa TREE/_build/default/lib/*/ebin -pa HARNESS \\
        -run vs main KIND LABEL QJS_WASM OUT.terms MANIFEST

`KIND` is the arm:

- `erlang_wasm`: this runtime, from the tree on the code path; `LABEL` says
  which (`baseline` or `candidate`). Every function is compiled on the first
  call, and every timed call must enter generated code or the run fails.
- `wasmtime`: erlang-wasmtime, on the same module bytes.
- `erlang`: plain Erlang with the same semantics (`gapref`), the floor.
- `coldcompile`: the compile gate. QuickJS's hot set compiled from an empty
  code cache, generation included in the timing.

Rows, with the same checksum on every arm that has them:

- `loop`, `mem`, `bulk`: nanoseconds per iteration, the slope between two
  sizes so the call's fixed cost cancels out.
- `fib30`: one call of `fib(30)`; the `erlang` arm also reports
  `fib30_idiomatic`, plain Erlang without 32-bit wrapping.
- `call`: one call from Erlang into the cheapest export, from 10,000 calls.
- `plugin`: compile, instantiate and destroy a 46 KB WASI module.
- `qjs`: a QuickJS build running a 30,000-iteration script.

Nothing is silently skipped: any failure writes `#{failed => ...}` and exits
with status 1, which stops `run.sh`. `VS_INTERPRET=1` turns compilation off,
only to show that a run which measured the interpreter fails.
""".
-export([main/1]).

-define(SAMPLES, 5).
-define(TARGET_US, 150000).

main([Kind, Label, Qjs, Out, Manifest]) ->
    Dir = filename:dirname(code:which(?MODULE)),
    {ok, Man} = file:read_file(Manifest),
    {Status, R} =
        try {0, run(list_to_atom(Kind), Dir, Qjs, Out)}
        catch C:E:S -> {1, #{failed => {C, E, S}}}
        end,
    {ok, F} = file:open(Out, [write]),
    io:format(F, "~p.~n", [R#{kind => Kind, label => Label,
                              manifest => Man, load => load()}]),
    ok = file:close(F),
    io:format("~p~n", [R]),
    erlang:halt(Status).

run(coldcompile, Dir, Qjs, Out) ->
    coldcompile(Dir, Qjs, Out);
run(Kind, Dir, Qjs, _Out) ->
    ok = start(Kind),
    Bytes = fun(Name) ->
                {ok, B} = file:read_file(filename:join(Dir, Name ++ ".wasm")),
                B
            end,
    {ok, Loop} = file:read_file(filename:join([Dir, "..", "loop.wasm"])),
    Rows = rows(Kind, Dir, Qjs, Loop, Bytes),
    R = maps:from_list(Rows),
    case Kind of
        erlang_wasm -> R#{jit_counts => wasm_jit:counts()};
        _ -> R
    end.

rows(erlang, _Dir, _Qjs, _Loop, _Bytes) ->
    [{loop, per_iter(fun(N) -> [gapref:loop(N)] end)},
     {fib30, fib30(fun(N) -> [gapref:fib32(N)] end)},
     {fib30_idiomatic, fib30(fun(N) -> [gapref:fib(N)] end)}];
rows(Kind, Dir, Qjs, Loop, Bytes) ->
    [{loop, per_iter(Kind, Loop, ~"bench")},
     {mem, per_iter(Kind, Bytes("mem"), ~"bench")},
     {bulk, per_iter(Kind, Bytes("bulk"), ~"bench")},
     {fib30, fib30(Kind, Bytes("fib"))},
     {call, call(Kind, Bytes("nop"))},
     {plugin, plugin(Kind, Dir)},
     {qjs, qjs(Kind, Dir, Qjs)}].

start(erlang_wasm) -> {ok, _} = application:ensure_all_started(wasm), ok;
start(wasmtime) -> {ok, _} = application:ensure_all_started(erlang_wasmtime), ok;
start(erlang) -> ok.

%%% ------------------------------------------------------------ the arms ---

%% A compiled instance with no imports, and how to call it. On our side every
%% call must enter generated code.
inst(erlang_wasm, Bin) ->
    {ok, M} = wasm:compile(Bin),
    {ok, I} = wasm:instantiate(M, #{}, compiled()),
    Call = fun(Name, Args) ->
                   gapref:assert_entered(
                     fun() -> {ok, Vs} = wasm:call(I, Name, Args), Vs end)
           end,
    {I, Call, fun() -> wasm:destroy(I) end};
inst(wasmtime, Bin) ->
    {ok, M} = wasmtime:compile(Bin),
    {ok, I} = wasmtime:instantiate(M, #{}),
    {I, fun(Name, Args) -> {ok, Vs} = wasmtime:call(I, Name, Args), Vs end,
     fun() -> wasmtime:destroy(I) end}.

%% The first call compiles on our side, and is not timed.
per_iter(Kind, Bin, Export) ->
    {_, Call, Stop} = inst(Kind, Bin),
    _ = first(Kind, fun() -> Call(Export, [1000]) end),
    R = per_iter(fun(N) -> Call(Export, [N]) end),
    Stop(),
    R.

per_iter(Run) ->
    _ = Run(1000),
    N = calibrate(Run, 1000),
    T1 = median([us(fun() -> Run(N) end) || _ <- seq()]),
    T2 = median([us(fun() -> Run(2 * N) end) || _ <- seq()]),
    [Check] = Run(1000000),
    #{ns_per_iter => (T2 - T1) * 1000 / N, n => N, checksum => Check}.

fib30(Kind, Bin) ->
    {_, Call, Stop} = inst(Kind, Bin),
    _ = first(Kind, fun() -> Call(~"fib", [20]) end),
    R = fib30(fun(N) -> Call(~"fib", [N]) end),
    Stop(),
    R.

fib30(Run) ->
    _ = Run(20),
    Ts = [us(fun() -> Run(30) end) || _ <- seq()],
    [Check] = Run(30),
    #{ms => median(Ts) / 1000, checksum => Check}.

%% The compiling call: on our side it may interpret while it compiles, so it
%% is exempt from the entered check that every later call must pass.
first(erlang_wasm, Fun) ->
    try Fun() catch error:not_entered -> ok end;
first(_, Fun) ->
    Fun().

call(Kind, Bin) ->
    {_, Call, Stop} = inst(Kind, Bin),
    _ = first(Kind, fun() -> Call(~"nop", [1]) end),
    _ = [Call(~"nop", [1]) || _ <- lists:seq(1, 1000)],
    Batch = fun() -> us(fun() -> [Call(~"nop", [K]) || K <- lists:seq(1, 10000)] end) end,
    Ts = [Batch() || _ <- seq()],
    Stop(),
    #{ns_per_call => median(Ts) * 1000 / 10000}.

plugin(Kind, Dir) ->
    {ok, Bin} = file:read_file(filename:join([Dir, "..", "..", "..", "test",
                                              "fixtures", "plugin", "plugin.wasm"])),
    One = fun() -> us(fun() -> plugin_once(Kind, Bin) end) end,
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

qjs(Kind, Dir, Path) ->
    {ok, Bin} = file:read_file(Path),
    Compile = median([us(fun() -> qjs_compile(Kind, Bin) end) || _ <- [1, 2, 3]]),
    Mod = qjs_compile(Kind, Bin),
    First = qjs_first(Kind, Mod, Dir),
    Runs = [qjs_run(Kind, Mod, Dir) || _ <- seq()],
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

%% Every timed QuickJS run on our side must enter the compiled code.
qjs_run(erlang_wasm, Mod, Dir) ->
    gapref:assert_entered(
      fun() -> qjs_run(erlang_wasm, Mod, Dir, #{compile => true}) end);
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
    T0 = now_us(),
    {I, Ref} = qjs_instance(Mod, Dir, Opts),
    T1 = now_us(),
    _ = wasm:call(I, ~"_start", []),
    T2 = now_us(),
    ok = wasm:destroy(I),
    {T1 - T0, T2 - T1, string:trim(drain(Ref, <<>>))}.

qjs_instance(Mod, Dir, Opts) ->
    Self = self(),
    Ref = make_ref(),
    Imports = wasi_preview1:imports(#{
        args => [~"qjs", ~"/app/bench.js"],
        dirs => [{~"/app", Dir, read}],
        stdout => fun(B) -> Self ! {Ref, B}, ok end}),
    {ok, I} = wasm:instantiate(Mod, Imports, Opts),
    {I, Ref}.

drain(Ref, Acc) ->
    receive {Ref, B} -> drain(Ref, <<Acc/binary, (iolist_to_binary(B))/binary>>)
    after 0 -> Acc
    end.

%%% -------------------------------------------------------- cold compile ---

%% QuickJS's hot set compiled from an empty code cache, the instrument for the
%% compile gate. The hot set is what `_start` actually runs, read back with
%% `wasm_instance:executed/1`, and its hash is recorded so a summary can refuse
%% two trees that compiled different sets. The compile runs inside the timed
%% call (`compile_sync`), so the time includes selecting the IR, analysing
%% calls, generating Core and `compile:forms/2`.
coldcompile(Dir, Qjs, Out) ->
    Cache = filename:absname(filename:rootname(Out) ++ ".cache"),
    ok = filelib:ensure_path(Cache),
    [] = filelib:wildcard(filename:join(Cache, "*")),
    ok = file:change_mode(Cache, 8#700),
    ok = application:load(wasm),
    ok = application:set_env(wasm, code_cache_dir, Cache),
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(Qjs),
    %% `load/1', not `compile/1': only a module with a content hash is cached,
    %% and the artifact's size is part of what this measures.
    {ok, Mod} = wasm:load(Bin),
    Interp = [interp_run(Mod, Dir) || _ <- [1, 2, 3]],
    [Hot] = lists:usort([H || {_, H, _} <- Interp]),
    [Out1] = lists:usort([O || {_, _, O} <- Interp]),
    C0 = wasm_jit:counts(),
    {I, Ref} = qjs_instance(Mod, Dir, #{compile => true, compile_sync => true,
                                       compile_after => 1}),
    T0 = now_us(),
    _ = wasm:call(I, ~"_start", []),
    T1 = now_us(),
    Hot = lists:sort(wasm_instance:executed(I)),
    ok = wasm:destroy(I),
    Out1 = string:trim(drain(Ref, <<>>)),
    C1 = wasm_jit:counts(),
    %% The compile must have happened and nothing refused, failed or crashed.
    %% `compiled` counts functions, so it says how many the hot set held.
    Delta = fun(K) -> maps:get(K, C1, 0) - maps:get(K, C0, 0) end,
    Funs = Delta(compiled),
    true = Funs > 0,
    [0, 0, 0] = [Delta(K) || K <- [refused, failed, crashed]],
    Files = filelib:wildcard(filename:join(Cache, "*")),
    true = Files =/= [],
    Bytes = lists:sum([filelib:file_size(F) || F <- Files]),
    Interpreted = median([T || {T, _, _} <- Interp]),
    #{coldcompile => #{compile_ms => (T1 - T0 - Interpreted) / 1000,
                       compiled_call_ms => (T1 - T0) / 1000,
                       interpreted_ms => Interpreted / 1000,
                       code_bytes => Bytes,
                       hot_set_size => length(Hot),
                       functions_compiled => Funs,
                       hot_set_hash => erlang:phash2(Hot, 1 bsl 32),
                       checksum => Out1}}.

interp_run(Mod, Dir) ->
    {I, Ref} = qjs_instance(Mod, Dir, #{}),
    T0 = now_us(),
    _ = wasm:call(I, ~"_start", []),
    T1 = now_us(),
    Hot = lists:sort(wasm_instance:executed(I)),
    ok = wasm:destroy(I),
    {T1 - T0, Hot, string:trim(drain(Ref, <<>>))}.

%%% ------------------------------------------------------------- helpers ---

%% Compile every function on the first call, before running it, as Wasmtime
%% compiles before it runs. `compile_after => 1' matters: without it the
%% module waits for 32 calls before it compiles anything, and a benchmark of
%% a few long calls measures the interpreter.
%%
%% `VS_INTERPRET=1' asks for no compile at all. It exists to show that the
%% entered check fails a run that measured the interpreter, and nothing else.
compiled() ->
    case os:getenv("VS_INTERPRET") of
        "1" -> #{};
        _ -> #{compile => true, compile_whole => true, compile_sync => true,
               compile_after => 1}
    end.

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
