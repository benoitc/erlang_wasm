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

## The `floors` mode

A second question, and a different shape: what a **heap floor** on the request
runner is worth. A restored request instance holds almost nothing on its own
heap -- the module is a cache handle, the memories are `atomics` pages, the
image's runs are refc binaries -- so the collector sizes the runner a 233-word
heap and collects through it hundreds of times.

    erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples \\
        -pa bench/paths -run workerbench main floors qjs_reactor 20 0 100000 200000

Every floor gets a worker of its own and they are driven **round robin in one
emulator**, with the order reversed on alternate rounds, because that is the
only way a sweep is comparable on a box that has never been quiet. Compare the
floors against each other in one run; never a number here against a number from
another run.

Each request is traced for `garbage_collection` on processes created inside
it, so the collections and the collection time reported are the runner's own.
`erlang:statistics(garbage_collection)` is not used and must not be: it counts
the whole node, and `bench/paths/allocwords.erl` records it answering "no
change" while one process's collections fell 51x.

This mode measures the **request** floor only. The capture floor
(`capture_min_heap_words`) cannot be swept here, because what it changes is a
worker *start* and two starts in one emulator would share a module cache. That
one is measured with one emulator per arm, alternating, which is not
self-controlling; `test/audit/PERF.md` says what makes it readable anyway.

Images are filed into the scratch root, so every floor after the first reads
one rather than capturing. Without that CPython would spend ninety seconds a
floor on work this mode is not about.
""".

-export([main/1]).

%% `monotonic_timestamp' pairs a start with the end that follows it;
%% without it a collection has no duration.
-define(GC_FLAGS, [garbage_collection, monotonic_timestamp]).

main(["floors", Adapter, N | Floors]) ->
    floors(Adapter, list_to_integer(N), [list_to_integer(F) || F <- Floors]);
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
                      fuel => 4_000_000_000})};
%% The reactor arms, which are what the `floors' mode is about: these restore
%% an image per request instead of starting an interpreter, so the request is
%% the guest's own work and the runner's collections are most of what is left.
arm("qjs_reactor", Config) ->
    {qjs_reactor_adapter, "test/fixtures/lang/qjs_reactor.wasm",
     limits(Config, #{timeout => 300_000, max_memory_pages => 2048,
                      max_host_calls => 100_000})};
arm("py_reactor", Config) ->
    {py_reactor_adapter, "test/fixtures/lang/py_reactor.wasm",
     limits(Config, #{timeout => 600_000, max_memory_pages => 4096,
                      max_host_calls => 1_000_000,
                      max_heap_words => 16 * 1024 * 1024,
                      fuel => 4_000_000_000})};
arm("lua_reactor", Config) ->
    {lua_reactor_adapter, "test/fixtures/lang/lua_reactor.wasm",
     limits(Config, #{timeout => 300_000, max_memory_pages => 2048,
                      max_host_calls => 100_000})}.

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

%%% ------------------------------------------------------------- floors ---

%% One worker per floor, driven round robin in one emulator with the order
%% reversed on alternate rounds. Interleaving is the whole point: the floors
%% are compared against each other under whatever load the box has, and never
%% against a number from another run.
floors(Adapter, N, Floors) ->
    io:format("# load average at start: ~s", [os:cmd("uptime")]),
    {ok, _} = application:ensure_all_started(wasm),
    application:unset_env(wasm, code_cache_dir),
    Root = "/tmp/workerbench_root",
    _ = os:cmd("rm -rf " ++ Root),
    ok = filelib:ensure_path(Root),
    %% Images are filed, because the floors differ only in what a *request*
    %% costs and every worker here captures the same one. Without it CPython
    %% would pay ninety seconds per floor to measure something else.
    Images = Root ++ "/images",
    ok = filelib:ensure_path(Images),
    application:set_env(wasm, snapshot_dir, Images),
    {ok, _} = worker_reaper:start_link(#{scratch => Root}),
    {Mod, Path, Limits} = arm(Adapter, "metered"),
    io:format("# ~s floors=~w n=~w~n", [Adapter, Floors, N]),
    Guest = guest(Adapter, Path),
    Ws = [{F, start_floor(Mod, Guest, Limits, F)} || F <- Floors],
    %% What the runner's flags actually became, not what was asked for. A floor
    %% clamped away or rounded up is the difference between a sweep and a row
    %% of identical numbers, and only the process can say which happened.
    [io:format("# floor ~w -> resolved ~p~n", [F, resolved(Limits, F)])
     || F <- Floors],
    {ok, Artifact} = Mod:artifact(maps:without([capture_timeout], Guest)),
    #{base := #{echo := Echo}} = Mod:conformance_fixtures(Artifact),
    %% One discarded request each: the first is the module cache, the lowered
    %% IR and every lazily loaded host module, and it belongs to none of them.
    _ = [one(W, Echo) || {_, W} <- Ws],
    Samples = rounds(Ws, Echo, N, 1, #{}),
    [report_floor(F, maps:get(F, Samples, [])) || F <- Floors],
    io:format("# load average at end: ~s", [os:cmd("uptime")]),
    init:stop().

start_floor(Mod, Guest, Limits, Floor) ->
    Base = Guest#{root => scratch, limits => Limits},
    Opts = case Floor of
               0 -> Base;
               _ -> Base#{runner_min_heap_words => Floor}
           end,
    {ok, W} = script_worker:start_link(Mod, Opts),
    W.

%% What an adapter needs to find its guest, beyond the module itself. CPython
%% preopens its standard library as `/lib' and refuses to build an artifact
%% without one, so a harness that passed only a path measured nothing.
guest("py_reactor", Path) ->
    %% Ninety seconds to bring CPython up, so the kernel's sixty-second
    %% default fails the start before `init()' has returned.
    #{path => Path, lib => "test/fixtures/lang/py_reactor_lib",
      capture_timeout => 300_000};
guest(_Adapter, Path) ->
    #{path => Path}.

rounds(_Ws, _Req, N, I, Acc) when I > N ->
    Acc;
rounds(Ws, Req, N, I, Acc) ->
    %% Both orderings, alternating, so a floor is never always first.
    Order = case I rem 2 of 0 -> lists:reverse(Ws); 1 -> Ws end,
    Acc1 = lists:foldl(
             fun({F, W}, A) ->
                 {Us, Gcs, GcUs} = one(W, Req),
                 io:format("~w floor=~w ~w us  gc ~w in ~w us~n",
                           [I, F, Us, Gcs, GcUs]),
                 maps:update_with(F, fun(L) -> [{Us, Gcs, GcUs} | L] end,
                                  [{Us, Gcs, GcUs}], A)
             end, Acc, Order),
    rounds(Ws, Req, N, I + 1, Acc1).

%% One request, with the collections of every process created inside it.
%%
%% `new_processes' and not a pid: the runner is spawned by the worker for this
%% request and dies with it, so there is nothing to name beforehand and nothing
%% left to untrace afterwards.
one(W, Req) ->
    _ = erlang:trace(new_processes, true, ?GC_FLAGS),
    T0 = erlang:monotonic_time(microsecond),
    Result = script_worker:run(W, Req),
    Us = erlang:monotonic_time(microsecond) - T0,
    _ = erlang:trace(new_processes, false, ?GC_FLAGS),
    ok = check(Result),
    {Gcs, Native} = drain(#{}, 0, 0),
    {Us, Gcs, erlang:convert_time_unit(Native, native, microsecond)}.

%% Paired per pid, because several processes are traced at once and their
%% events interleave. A start with no end is a collection still running when
%% tracing stopped and is dropped rather than guessed at.
drain(Open, Gcs, Acc) ->
    receive
        {trace_ts, P, S, _, T} when S =:= gc_minor_start; S =:= gc_major_start ->
            drain(Open#{P => T}, Gcs, Acc);
        {trace_ts, P, E, _, T1} when E =:= gc_minor_end; E =:= gc_major_end ->
            case maps:take(P, Open) of
                {T0, Rest} -> drain(Rest, Gcs + 1, Acc + (T1 - T0));
                error      -> drain(Open, Gcs, Acc)
            end;
        {trace_ts, _, _, _, _} ->
            drain(Open, Gcs, Acc)
    after 0 ->
        {Gcs, Acc}
    end.

%% What the option *resolved* to, which is not always what was asked for: a
%% floor below the emulator's minimum, above its maximum, or above this
%% worker's own `max_heap_words' ceiling comes back changed. A sweep printing
%% the request rather than the resolution would report a row of identical
%% numbers and look like a finding.
%%
%% That the resolved number reaches the process is a different claim and is
%% `wasm_worker_kernel_SUITE's, not a benchmark's: the suite reads
%% `process_info(self(), garbage_collection)' from inside a runner.
resolved(Limits, Floor) ->
    script_worker:runner_heap_words(#{runner_min_heap_words => Floor}, Limits).

report_floor(F, []) ->
    io:format("# floor ~w: no samples~n", [F]);
report_floor(F, Samples) ->
    Us = lists:sort([U || {U, _, _} <- Samples]),
    Gcs = lists:sort([G || {_, G, _} <- Samples]),
    GcUs = lists:sort([T || {_, _, T} <- Samples]),
    io:format("# floor ~w  request min/median ~w / ~w us  "
              "gc median ~w in ~w us  over ~w~n",
              [F, hd(Us), med(Us), med(Gcs), med(GcUs), length(Samples)]).

med(L) -> lists:nth(max(1, length(L) div 2), L).
