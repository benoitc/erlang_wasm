-module(workerbench).
-moduledoc """
What a *host* sees per request, and when the tier changes it.

Everything already in `bench/paths` prices one path inside the runtime.
Nothing measured the thing a worker host actually experiences: a request
arriving, an instance being made for it, and the latency changing under them
when generated code lands. This does.

    erlc -o bench/paths -pa _build/test/lib/wasm/ebin \\
         -pa _build/test/lib/wasm/examples bench/paths/workerbench.erl
    erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples \\
        -pa bench/paths -run workerbench main qjs metered adoption 400 ""

## The three cache arms, and why they are three

| arm | `code_cache_dir` | what it answers |
| --- | --- | --- |
| `adoption` | unset | one node, no disk: does request *n* adopt what *n-1* compiled? |
| `cold` | an **empty** directory | what a first-ever start costs |
| `warm` | that directory, **after** a cold run | what a restart costs |

The disk cache must not be credited for same-node adoption, which is why
`adoption` sets no directory at all rather than an empty one. `warm` is the arm
that turns minutes into seconds, and `wasm_jit:counts/0` saying `cached => 1`
is what distinguishes it: a wall time alone would not.

Output is written as it happens, one line per sample. Do not pipe it through
`tail`, which buffers until exit and hides the progress this exists to show.
""".

-export([main/1]).

main([Adapter, Config, Arm, N, Cache]) ->
    io:format("# load average at start: ~s", [os:cmd("uptime")]),
    {ok, _} = application:ensure_all_started(wasm),
    case Cache of
        "" -> application:unset_env(wasm, code_cache_dir);
        _  -> ok = filelib:ensure_path(Cache),
              application:set_env(wasm, code_cache_dir, Cache)
    end,
    Root = "/tmp/workerbench_root",
    _ = os:cmd("rm -rf " ++ Root),
    ok = filelib:ensure_path(Root),
    {ok, _} = worker_reaper:start_link(#{scratch => Root}),
    {Mod, Path, Limits} = arm(Adapter, Config),
    {ok, W} = script_worker:start_link(Mod, #{root => scratch, path => Path,
                                              limits => Limits}),
    {ok, Artifact} = Mod:artifact(#{path => Path}),
    #{base := #{echo := Echo}} = Mod:conformance_fixtures(Artifact),
    io:format("# ~s ~s arm=~s n=~s cache=~ts~n",
              [Adapter, Config, Arm, N, case Cache of "" -> "(none)"; _ -> Cache end]),
    Samples = run(W, Echo, list_to_integer(N), 1, []),
    report(Samples),
    io:format("# counts at end: ~p~n", [wasm_jit:counts()]),
    io:format("# load average at end: ~s", [os:cmd("uptime")]),
    %% `-run' returns to an idle node, which for a harness meant every arm
    %% appeared to hang after printing its last line.
    init:stop().

%% The two named configurations, and the ceilings each interpreter needs. None
%% of these is a round number chosen for looking safe: `QUICKJS.md` and
%% `PYTHON.md` say what each was measured at.
arm("qjs", Config) ->
    {qjs_adapter, "test/fixtures/lang/qjs.wasm",
     limits(Config, #{timeout => 300_000, max_memory_pages => 2048,
                      max_host_calls => 100_000})};
arm("python", Config) ->
    {py_adapter, "test/fixtures/lang/python.wasm",
     limits(Config, #{timeout => 600_000, max_memory_pages => 4096,
                      max_host_calls => 1_000_000,
                      max_heap_words => 16 * 1024 * 1024,
                      fuel => 4_000_000_000})}.

%% `wasm_jit:entry/3` enables generated code only when fuel is `infinity`, so
%% the compiled arm has to remove the ceiling rather than add to it.
limits(Config, Base) ->
    case Config of
        "metered"  -> Base;
        "compiled" -> Base#{fuel => infinity, compile => true, profile => script}
    end.

run(_W, _R, N, I, Acc) when I > N ->
    lists:reverse(Acc);
run(W, R, N, I, Acc) ->
    T0 = erlang:monotonic_time(microsecond),
    Result = script_worker:run(W, R),
    Us = erlang:monotonic_time(microsecond) - T0,
    ok = check(Result),
    Entered = maps:get(entered, wasm_jit:counts(), 0),
    %% Every sample, when the tier is moving; every tenth otherwise. The
    %% transition is the interesting part and averaging over it hides it.
    case I rem 10 =:= 1 orelse Entered > 0 of
        true  -> io:format("~w ~w ~p~n", [I, Us, wasm_jit:counts()]);
        false -> ok
    end,
    run(W, R, N, I + 1, [{I, Us, Entered} | Acc]).

check({ok, _}) -> ok;
check({error, E}) -> io:format("# REQUEST FAILED: ~p~n", [E]), ok.

%% Minimum and median, never a mean: one scheduling hiccup moves a mean and
%% neither of these, and `bench/paths/README.md` asks for minimums.
report([]) ->
    io:format("# no samples~n");
report(Samples) ->
    Us = [U || {_, U, _} <- Samples],
    {First, _} = {hd(Us), ok},
    Sorted = lists:sort(Us),
    Entered = [I || {I, _, E} <- Samples, E > 0],
    Before = [U || {I, U, _} <- Samples, Entered =:= [] orelse I < hd(Entered)],
    After = [U || {I, U, _} <- Samples, Entered =/= [], I >= hd(Entered)],
    io:format("# first        ~w us~n", [First]),
    io:format("# min / median ~w / ~w us~n",
              [hd(Sorted), lists:nth(max(1, length(Sorted) div 2), Sorted)]),
    io:format("# peak         ~w us~n", [lists:last(Sorted)]),
    case Entered of
        [] ->
            io:format("# entered      never, in ~w requests~n", [length(Samples)]);
        [At | _] ->
            io:format("# entered      at request ~w~n", [At]),
            io:format("# before       min ~w us over ~w~n",
                      [lists:min(Before), length(Before)]),
            io:format("# after        min ~w us over ~w~n",
                      [lists:min(After), length(After)])
    end.
