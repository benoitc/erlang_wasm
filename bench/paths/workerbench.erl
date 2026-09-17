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

## The `throughput` mode

What a host gets from more workers, and what a heap floor costs it in memory.

    erl ... -run workerbench main throughput qjs_reactor metered 20 200000 1 2 4 8 14

`N` requests per worker, then a floor in words, then the worker counts to
sweep. Each count is run twice, once with the floor and once without, so the
curve prices the floor as well as the scaling. Peak `erlang:memory(processes)`
is sampled during each arm, because the point of the memory column is that a
floor is paid per *concurrent runner* and only a concurrent arm can show it.

**This one is not self-controlling and nothing can make it so.** A latency
sweep can interleave its arms and be read against whatever else the box is
doing; a scaling curve needs idle cores and there is no substitute. Read
`uptime` before and after every arm, and throw the run away if the box was
busy. `bench/paths/README.md` says the same thing at more length.

## The `floors` mode

A second question, and a different shape: what a **heap floor** on the request
runner is worth. A restored request instance holds almost nothing on its own
heap -- the module is a cache handle, the memories are `atomics` pages, the
image's runs are refc binaries -- so the collector sizes the runner a 233-word
heap and collects through it hundreds of times.

    erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples \\
        -pa bench/paths -run workerbench main floors qjs_reactor metered 20 0 100000 200000

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

main(["floors", Adapter, Config, N | Floors]) ->
    floors(Adapter, Config, list_to_integer(N),
           [list_to_integer(F) || F <- Floors]);
main(["throughput", Adapter, Config, N, Floor | Counts]) ->
    throughput(Adapter, Config, list_to_integer(N), list_to_integer(Floor),
               [list_to_integer(C) || C <- Counts]);
main(["tier", Adapter, N, Floor]) ->
    tier(Adapter, list_to_integer(N), list_to_integer(Floor));
main(["coldnode", Adapter, Dir, State, Strategy]) ->
    coldnode(Adapter, Dir, State, Strategy);
main(["coldnode", Adapter, Dir, State, Strategy, Which]) ->
    coldnode(Adapter, Dir, State, Strategy, Which);
main(["workloads", Adapter]) ->
    workloads(Adapter);
main(["steady", Adapter, Arm, N, Floor]) ->
    steady(Adapter, Arm, list_to_integer(N), list_to_integer(Floor));
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
    io:format("# diagnostics:   ~p~n", [wasm_jit:diagnostics()]),
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
%%
%% `interpreted' is the **fuel-matched** control, and it exists because
%% `metered' is not one: `metered' keeps the untrusted preset's fuel ceiling
%% while `compiled' removes it, so comparing those two prices metering and
%% compilation together. This differs from `compiled' in exactly one thing.
limits(Config, Base) ->
    case Config of
        "metered"     -> Base;
        "interpreted" -> Base#{fuel => infinity};
        "compiled"    -> Base#{fuel => infinity, compile => true,
                               profile => script}
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

%% What `check/1' is not. That one matches any `{ok, _}' and, worse, *prints* on
%% an error and still answers `ok', so a request that failed is logged and its
%% timing kept. A timing arm cannot do that: a failed request is faster than a
%% working one and would flatter whatever produced it.
%%
%% This compares the decoded result against what the workload says it should be
%% and stops the arm otherwise.
strict(#{expect := Expect}, {ok, #{result := Got}}) when Got =:= Expect ->
    ok;
strict(#{expect := Expect}, Other) ->
    exit({wrong_result, #{expected => Expect, got => Other}}).

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
floors(Adapter, Config, N, Floors) ->
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
    {Mod, Path, Limits} = arm(Adapter, Config),
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

%%% --------------------------------------------------------- throughput ---

%% Requests per second against worker count, with and without a heap floor.
%%
%% Shaped on `pathbench:run(concurrency)', which sweeps the same counts and
%% reports the same rate. The difference is what is being driven: that one
%% spawns instances, this one spawns `script_worker's, so what it prices is a
%% host's own scaling and not the interpreter's.
throughput(Adapter, Config, N, Floor, Counts) ->
    io:format("# at start: ~s#           ~s", [os:cmd("uptime"), idle()]),
    {ok, _} = application:ensure_all_started(wasm),
    application:unset_env(wasm, code_cache_dir),
    Root = "/tmp/workerbench_root",
    _ = os:cmd("rm -rf " ++ Root),
    ok = filelib:ensure_path(Root),
    Images = Root ++ "/images",
    ok = filelib:ensure_path(Images),
    application:set_env(wasm, snapshot_dir, Images),
    {ok, _} = worker_reaper:start_link(#{scratch => Root}),
    {Mod, Path, Limits} = arm(Adapter, Config),
    Guest = guest(Adapter, Path),
    {ok, Artifact} = Mod:artifact(maps:without([capture_timeout], Guest)),
    #{base := #{echo := Echo}} = Mod:conformance_fixtures(Artifact),
    io:format("# ~s n=~w floor=~w counts=~w schedulers=~w~n",
              [Adapter, N, Floor, Counts, erlang:system_info(schedulers_online)]),
    %% One worker built and thrown away, so the image is captured and filed
    %% before any arm is timed. Otherwise the first arm pays a capture that no
    %% other arm pays and the curve starts with a number that is not a rate.
    ok = script_worker:stop(start_floor(Mod, Guest, Limits, 0)),
    [arm_pair(Mod, Guest, Limits, Echo, N, Floor, C) || C <- Counts],
    io:format("# at end:   ~s#           ~s", [os:cmd("uptime"), idle()]),
    init:stop().

%% How much of the machine was actually free. A one-minute load average decays
%% for fifteen minutes after a previous arm and says nothing about now; this
%% says what a scaling curve needs to know before it is believed.
idle() ->
    os:cmd("top -l 2 -n 0 -s 1 | grep 'CPU usage' | tail -1").

%% Both orderings across the sweep rather than within it: an arm here is a
%% whole population of workers and cannot be interleaved with another.
arm_pair(Mod, Guest, Limits, Echo, N, Floor, C) when C rem 2 =:= 0 ->
    one_arm(Mod, Guest, Limits, Echo, N, 0, C),
    one_arm(Mod, Guest, Limits, Echo, N, Floor, C);
arm_pair(Mod, Guest, Limits, Echo, N, Floor, C) ->
    one_arm(Mod, Guest, Limits, Echo, N, Floor, C),
    one_arm(Mod, Guest, Limits, Echo, N, 0, C).

one_arm(Mod, Guest, Limits, Echo, N, Floor, Count) ->
    Ws = [start_floor(Mod, Guest, Limits, Floor) || _ <- lists:seq(1, Count)],
    Sampler = spawn_link(fun() -> sample(self(), 0) end),
    T0 = erlang:monotonic_time(microsecond),
    ok = drive(Ws, Echo, N),
    Us = erlang:monotonic_time(microsecond) - T0,
    Peak = stop_sampler(Sampler),
    [ok = script_worker:stop(W) || W <- Ws],
    io:format("workers=~2w floor=~8w  ~7.1f req/s  ~w requests in ~w ms  "
              "peak process memory ~w MB~n",
              [Count, Floor, Count * N / (Us / 1000000), Count * N,
               Us div 1000, Peak div (1024 * 1024)]).

%% One client per worker, all of them started before any of them runs, so the
%% arm measures the workers competing rather than a ramp.
drive(Ws, Req, N) ->
    Parent = self(),
    Pids = [spawn_link(fun() -> client(Parent, W, Req, N) end) || W <- Ws],
    [receive {done, P} -> ok end || P <- Pids],
    ok.

client(Parent, W, Req, N) ->
    lists:foreach(fun(_) -> ok = check(script_worker:run(W, Req)) end,
                  lists:seq(1, N)),
    Parent ! {done, self()}.

%% Sampled rather than read at the end: a runner is created and destroyed per
%% request, so the memory a floor costs is only visible while requests are in
%% flight.
%%
%% **The peak is biased low for a fast arm**, and the bias runs the wrong way
%% for the comparison this column exists for: a floored arm finishes sooner, so
%% fewer samples are taken and the maximum over them is a worse estimate of the
%% real maximum. 5 ms keeps it small against the shortest request measured
%% (12.7 ms on Lua) but does not remove it. Read the column as a bound, not a
%% measurement, and never read a *lower* floored number as the floor saving
%% memory.
sample(_Parent, Peak) ->
    receive
        {stop, From} -> From ! {peak, Peak}
    after 5 ->
        sample(_Parent, max(Peak, erlang:memory(processes)))
    end.

stop_sampler(Pid) ->
    Pid ! {stop, self()},
    receive {peak, P} -> P after 5000 -> 0 end.

%%% --------------------------------------------------------------- tier ---

%% Whether a **restored** instance ever reaches generated code, and what it is
%% worth if it does.
%%
%% Two workers over the same reactor artifact, one `metered' and one
%% `compiled', driven alternately in one emulator with the heap floor on in
%% both. The floor is not optional here: the tier's published 8.4x was measured
%% against an unfloored interpreter, and against a floored one it has far less
%% to win. Measuring it the other way would credit the tier with what the floor
%% already does.
%%
%% `wasm_jit:counts/0' is the evidence, not the wall time, which is
%% `bench/paths/adopt.erl's rule for the same question one layer down: a
%% slow arm and an arm where the tier never engaged look identical in
%% milliseconds, and only `entered' tells them apart.
tier(Adapter, N, Floor) ->
    io:format("# at start: ~s#           ~s", [os:cmd("uptime"), idle()]),
    {ok, _} = application:ensure_all_started(wasm),
    application:unset_env(wasm, code_cache_dir),
    Root = "/tmp/workerbench_root",
    _ = os:cmd("rm -rf " ++ Root),
    ok = filelib:ensure_path(Root),
    Images = Root ++ "/images",
    ok = filelib:ensure_path(Images),
    application:set_env(wasm, snapshot_dir, Images),
    {ok, _} = worker_reaper:start_link(#{scratch => Root}),
    {Mod, Path, Metered} = arm(Adapter, "metered"),
    {Mod, Path, Compiled} = arm(Adapter, "compiled"),
    Guest = guest(Adapter, Path),
    {ok, Artifact} = Mod:artifact(maps:without([capture_timeout], Guest)),
    #{base := #{echo := Echo}} = Mod:conformance_fixtures(Artifact),
    io:format("# ~s tier n=~w floor=~w~n# compiled limits ~p~n",
              [Adapter, N, Floor, Compiled]),
    Wm = start_floor(Mod, Guest, Metered, Floor),
    Wc = start_floor(Mod, Guest, Compiled, Floor),
    %% One discarded request each, as everywhere else here: the first carries
    %% the module cache and every lazily loaded host module.
    _ = [one(W, Echo) || W <- [Wm, Wc]],
    io:format("# counts after warm-up: ~p~n", [wasm_jit:counts()]),
    {Ms, Cs, At0} = tier_rounds(Wm, Wc, Echo, N, 1, [], [], undefined),
    %% A reactor request is 21 ms against the command path's ~200, so N
    %% requests buy a tenth of the wall time and the background compile is very
    %% likely still running. Wait for it, then keep driving: a run that stopped
    %% here would report "never entered" for a compile that was merely
    %% unfinished, which is the first wrong answer this mode gave.
    At = wait_and_drive(Wc, Echo, At0,
                        erlang:monotonic_time(millisecond) + 300_000),
    [ok = script_worker:stop(W) || W <- [Wm, Wc]],
    tier_report(Ms, Cs, At, N),
    io:format("# counts at end: ~p~n", [wasm_jit:counts()]),
    io:format("# slots: ~p~n",
              [[{Nm, St} || {Nm, _G, St, _M} <- ets:tab2list(wasm_code_slots),
                            St =/= free]]),
    io:format("# jit children: ~p~n",
              [supervisor:count_children(wasm_jit_sup)]),

    io:format("# diagnostics:   ~p~n", [wasm_jit:diagnostics()]),
    io:format("# at end:   ~s#           ~s", [os:cmd("uptime"), idle()]),
    init:stop().

%% Poll by **calling**, not by sleeping: the tier advances when calls happen,
%% so a run that waited without calling would wait forever for an adoption only
%% a call can perform.
%%
%% Bounded by wall time rather than by a request count, because that is the
%% quantity the compiler needs and a reactor request buys a tenth as much of it
%% as a command one. 600 requests sounded generous and was twelve seconds.
wait_and_drive(_Wc, _Req, At, _Deadline) when At =/= undefined -> At;
wait_and_drive(Wc, Req, undefined, Deadline) ->
    _ = req_us(Wc, Req),
    Now = erlang:monotonic_time(millisecond),
    case {maps:get(entered, wasm_jit:counts(), 0) > 0, Now >= Deadline} of
        {true, _} ->
            io:format("# entered while waiting, ~p~n", [wasm_jit:counts()]),
            waited;
        {false, true} ->
            io:format("# gave up after the wait; compilers still running: ~p~n",
                      [supervisor:count_children(wasm_jit_sup)]),
            undefined;
        {false, false} ->
            (Deadline - Now) rem 10000 < 30 andalso
                io:format("# waiting, ~w s left, ~p~n",
                          [(Deadline - Now) div 1000, wasm_jit:counts()]),
            wait_and_drive(Wc, Req, undefined, Deadline)
    end.

tier_rounds(_Wm, _Wc, _Req, N, I, Ms, Cs, At) when I > N ->
    {lists:reverse(Ms), lists:reverse(Cs), At};
tier_rounds(Wm, Wc, Req, N, I, Ms, Cs, At) ->
    %% Both orderings, so neither arm is always the one that meets a cold
    %% scheduler.
    {M, C} = case I rem 2 of
                 1 -> {req_us(Wm, Req), req_us(Wc, Req)};
                 0 -> R = req_us(Wc, Req), {req_us(Wm, Req), R}
             end,
    Entered = maps:get(entered, wasm_jit:counts(), 0),
    At1 = case {At, Entered > 0} of
              {undefined, true} ->
                  io:format("~w ENTERED  counts ~p~n", [I, wasm_jit:counts()]),
                  I;
              _ ->
                  At
          end,
    case I rem 25 =:= 1 of
        true  -> io:format("~w metered=~w us compiled=~w us  ~p~n",
                           [I, M, C, wasm_jit:counts()]);
        false -> ok
    end,
    tier_rounds(Wm, Wc, Req, N, I + 1, [M | Ms], [C | Cs], At1).

req_us(W, Req) ->
    T0 = erlang:monotonic_time(microsecond),
    R = script_worker:run(W, Req),
    Us = erlang:monotonic_time(microsecond) - T0,
    ok = check(R),
    Us.

%% Split at the request the tier engaged on, because an average across that
%% boundary is a number describing neither side of it.
tier_report(_Ms, _Cs, waited, _N) ->
    io:format("# the tier engaged only after the measured rounds; rerun with a "
              "larger N for a before/after split~n");
tier_report(Ms, Cs, undefined, N) ->
    io:format("# NEVER ENTERED in ~w requests~n", [N]),
    io:format("# metered  min/median ~w / ~w us~n", [lists:min(Ms), med2(Ms)]),
    io:format("# compiled min/median ~w / ~w us~n", [lists:min(Cs), med2(Cs)]);
tier_report(Ms, Cs, At, N) ->
    io:format("# entered at request ~w of ~w~n", [At, N]),
    {MB, MA} = lists:split(At, Ms),
    {CB, CA} = lists:split(At, Cs),
    io:format("# before  metered ~w / ~w   compiled ~w / ~w us (min/median)~n",
              [lists:min(MB), med2(MB), lists:min(CB), med2(CB)]),
    after_report(MA, CA).

after_report([], _CA) ->
    io:format("# after   nothing ran after the tier engaged~n");
after_report(MA, CA) ->
    io:format("# after   metered ~w / ~w   compiled ~w / ~w us (min/median)~n",
              [lists:min(MA), med2(MA), lists:min(CA), med2(CA)]).

med2(L) -> S = lists:sort(L), lists:nth(max(1, length(S) div 2), S).

%%% ----------------------------------------------------------- workloads ---

%% The two scripts the cold-node arms use, per guest, with what each must
%% answer. They are literals rather than fixtures because the cache keys on the
%% **set of functions a request executed**, so what these scripts touch is the
%% independent variable: `W' is arithmetic, `B' sorts, serialises and rewrites,
%% which reaches into parts of an engine `W' never does.
%%
%% `expect' is not decoration. A timing arm that accepts any answer will happily
%% time a request that failed, and a failure is faster than the work.
workload(Adapter, w) -> element(1, pair(Adapter));
workload(Adapter, b) -> element(2, pair(Adapter)).

pair("qjs_reactor") ->
    {#{source => ~"export function main(c) { return {answer: c.value + 1}; }",
       context => #{~"value" => 41},
       expect => #{~"answer" => 42}},
     #{source => <<"export function main(c) {"
                   " const xs = c.words.slice().sort();"
                   " return {out: xs.join('-') + ':' + JSON.stringify(xs).length};"
                   "}">>,
       context => #{~"words" => [~"pear", ~"fig", ~"date"]},
       expect => #{~"out" => ~"date-fig-pear:21"}}};
pair("lua_reactor") ->
    {#{source => ~"function main(c) return {answer = c.value + 1} end",
       context => #{~"value" => 41},
       expect => #{~"answer" => 42}},
     #{source => <<"function main(c)\n"
                   "  local xs = {}\n"
                   "  for i, w in ipairs(c.words) do xs[i] = w end\n"
                   "  table.sort(xs)\n"
                   "  local s = table.concat(xs, '-')\n"
                   "  s = string.gsub(s, 'fig', 'FIG')\n"
                   "  return {out = string.format('%s:%d', s, #s)}\n"
                   "end">>,
       context => #{~"words" => [~"pear", ~"fig", ~"date"]},
       expect => #{~"out" => ~"date-FIG-pear:13"}}};
pair("py_reactor") ->
    {#{source => ~"def main(c):\n    return {'answer': c['value'] + 1}\n",
       context => #{~"value" => 41},
       expect => #{~"answer" => 42}},
     #{source => <<"import json, re\n"
                   "def main(c):\n"
                   "    xs = sorted(c['words'])\n"
                   "    s = re.sub('fig', 'FIG', '-'.join(xs))\n"
                   "    return {'out': '%s:%d' % (s, len(json.dumps(xs)))}\n">>,
       context => #{~"words" => [~"pear", ~"fig", ~"date"]},
       expect => #{~"out" => ~"date-FIG-pear:23"}}}.

%% Run W and B once each and print what came back, so a workload can be checked
%% without waiting for a compile. Nothing here is timed.
workloads(Adapter) ->
    io:format("# ~s workloads~n", [Adapter]),
    {ok, _} = application:ensure_all_started(wasm),
    Root = "/tmp/workerbench_root",
    _ = os:cmd("rm -rf " ++ Root),
    ok = filelib:ensure_path(Root),
    {ok, _} = worker_reaper:start_link(#{scratch => Root}),
    {Mod, Path, Limits} = arm(Adapter, "metered"),
    Guest = guest(Adapter, Path),
    W = start_floor(Mod, Guest, Limits, 0),
    [begin
         Wl = workload(Adapter, Which),
         R = script_worker:run(W, maps:with([source, context], Wl)),
         io:format("~p: ~p~n  expect ~p~n", [Which, R, maps:get(expect, Wl)])
     end || Which <- [w, b]],
    ok = script_worker:stop(W),
    init:stop().

%%% -------------------------------------------------------------- steady ---

%% What adoption is worth once the code is already there.
%%
%% Every other mode here measures a node on its way somewhere. This one
%% measures a node that has arrived: the module compiled, the compiler gone,
%% the counters zeroed. That is the only state in which "does a fresh instance
%% use the compiled code" is a question about adoption rather than about how
%% long a compile takes.
%%
%%     erl ... -run workerbench main steady qjs_reactor latency 200 200000
%%     erl ... -run workerbench main steady qjs_reactor throughput 40 200000
%%     erl ... -run workerbench main steady qjs_reactor control 200 200000
%%
%% The three arms answer different gates and have different end states; see
%% `bench/paths/README.md'. Run the same binary against both revisions, copying
%% this file into the older tree, because the older tree does not contain it.
steady(Adapter, Arm, N, Floor) ->
    io:format("# at start: ~s#           ~s", [os:cmd("uptime"), idle()]),
    {ok, _} = application:ensure_all_started(wasm),
    application:unset_env(wasm, code_cache_dir),
    Root = "/tmp/workerbench_root",
    _ = os:cmd("rm -rf " ++ Root),
    ok = filelib:ensure_path(Root),
    Images = Root ++ "/images",
    ok = filelib:ensure_path(Images),
    application:set_env(wasm, snapshot_dir, Images),
    {ok, _} = worker_reaper:start_link(#{scratch => Root}),
    {Mod, Path, _} = arm(Adapter, "metered"),
    Guest = guest(Adapter, Path),
    {ok, Artifact} = Mod:artifact(maps:without([capture_timeout], Guest)),
    #{base := #{echo := Echo}} = Mod:conformance_fixtures(Artifact),
    Hash = artifact_hash(Guest),
    io:format("# ~s steady arm=~s n=~w floor=~w~n", [Adapter, Arm, N, Floor]),
    steady_arm(Arm, Adapter, Mod, Guest, Echo, Hash, N, Floor),
    io:format("# at end:   ~s#           ~s", [os:cmd("uptime"), idle()]),
    init:stop().

%% The module's own content hash, which is what the JIT's slot key is built
%% from. Read from the artifact rather than spelled here: `wasm_jit:key/1' is
%% `{identity, ?ABI}' and `?ABI' is private to that module, so a benchmark that
%% wrote the key out would go stale the next time the ABI moved.
artifact_hash(Guest) ->
    {ok, Bin} = file:read_file(maps:get(path, Guest)),
    crypto:hash(sha256, Bin).

%% The slot row holding this guest, matched by hash *inside* the key.
%% `resident/0' answers `{Name, Key, LeaseCount}', which is both halves of what
%% the quiescence check below needs.
target(Hash) ->
    case [R || {_, {{sha256, H}, _}, _} = R <- wasm_code_slots:resident(),
               H =:= Hash] of
        [R | _] -> {ok, R};
        []      -> error
    end.

%%% The latency arm: one compiled worker and one metered one, alternating.
steady_arm("latency", Adapter, Mod, Guest, Echo, Hash, N, Floor) ->
    {_, _, Metered} = arm(Adapter, "metered"),
    {_, _, Compiled} = arm(Adapter, "compiled"),
    Wm = start_floor(Mod, Guest, Metered, Floor),
    Wc = start_floor(Mod, Guest, Compiled, Floor),
    Compiled0 = prepare(Wc, Echo, Hash),
    {Ms, Cs} = alternate(Wm, Wc, Echo, N, 1, [], []),
    Entered = maps:get(entered, wasm_jit:counts(), 0),
    io:format("# compiled functions ~w~n", [Compiled0]),
    io:format("# adoption rate ~.1f% (~w of ~w)~n",
              [100.0 * Entered / N, Entered, N]),
    io:format("# metered  min/median ~w / ~w us~n", [lists:min(Ms), med2(Ms)]),
    io:format("# compiled min/median ~w / ~w us~n", [lists:min(Cs), med2(Cs)]),
    io:format("# ratio compiled/metered median ~.3f~n", [med2(Cs) / med2(Ms)]),
    [ok = script_worker:stop(W) || W <- [Wm, Wc]],
    end_state(Hash, resident);

%%% The throughput arm: N concurrent compiled workers, and a metered control at
%%% the same count so the rate can be normalised before revisions are compared.
steady_arm("throughput", Adapter, Mod, Guest, Echo, Hash, N, Floor) ->
    [steady_rate(Adapter, Mod, Guest, Echo, Hash, N, Floor, C)
     || C <- [1, 2, 4, 8, 14]],
    end_state(Hash, resident);

%%% The control arm: the tier on, so every call pays the residency lookup, and
%%% a threshold nothing can reach, so no compile ever starts. It prices the
%%% lookup and nothing else.
steady_arm("control", Adapter, Mod, Guest, Echo, Hash, N, Floor) ->
    {_, _, Base} = arm(Adapter, "compiled"),
    %% Above every tier-enabled call this arm makes, discarded and measured
    %% together, with room to spare. One threshold hit and the arm would be
    %% measuring a compile.
    Never = (N * 10) + 10_000,
    W = start_floor(Mod, Guest, Base#{compile_after => Never}, Floor),
    %% Nothing may be resident before a control arm runs, or it is not a
    %% control: it would adopt and price adoption instead of the lookup.
    error = target(Hash),
    _ = one(W, Echo),
    ok = wasm_jit:reset_counts(),
    Us = [req_us(W, Echo) || _ <- lists:seq(1, N)],
    io:format("# control min/median ~w / ~w us over ~w~n",
              [lists:min(Us), med2(Us), N]),
    io:format("# counts (all must be zero): ~p~n", [wasm_jit:counts()]),
    ok = script_worker:stop(W),
    end_state(Hash, absent).

steady_rate(Adapter, Mod, Guest, Echo, Hash, N, Floor, Count) ->
    {_, _, Metered} = arm(Adapter, "metered"),
    {_, _, Compiled} = arm(Adapter, "compiled"),
    Cs = [start_floor(Mod, Guest, Compiled, Floor) || _ <- lists:seq(1, Count)],
    _ = prepare(hd(Cs), Echo, Hash),
    CRate = rate(Cs, Echo, N),
    Entered = maps:get(entered, wasm_jit:counts(), 0),
    [ok = script_worker:stop(W) || W <- Cs],
    Ms = [start_floor(Mod, Guest, Metered, Floor) || _ <- lists:seq(1, Count)],
    MRate = rate(Ms, Echo, N),
    [ok = script_worker:stop(W) || W <- Ms],
    io:format("workers=~2w compiled ~7.1f req/s  metered ~7.1f req/s  "
              "normalised ~.3f  entered ~w of ~w~n",
              [Count, CRate, MRate, CRate / MRate, Entered, Count * N]).

rate(Ws, Req, N) ->
    ok = wasm_jit:reset_counts(),
    T0 = erlang:monotonic_time(microsecond),
    ok = drive(Ws, Req, N),
    Us = erlang:monotonic_time(microsecond) - T0,
    length(Ws) * N / (Us / 1000000).

%% Reach the state the arm is about to measure, and prove it.
%%
%% `publish/1' makes a slot resident **before** the compiler bumps `compiled'
%% and takes its own lease, so residency on its own is not quiescence: waiting
%% for the lease count to fall to zero and for the compiler children to go is
%% what makes the counters safe to reset. Reading `compiled' before the reset
%% and asserting it non-zero is what stops the whole comparison passing
%% vacuously with nothing compiled on either side.
prepare(W, Req, Hash) ->
    %% Already resident, which is the second and later arms of a sweep: the
    %% counters were zeroed by the first, so `compiled' is legitimately 0 and
    %% asserting on it here would fail an arm that is correctly set up. What
    %% still has to hold is quiescence.
    Already = target(Hash) =/= error,
    Deadline = erlang:monotonic_time(millisecond) + 900_000,
    ok = until_resident(W, Req, Hash, Deadline),
    ok = until_quiet(Hash, Deadline),
    Compiled = maps:get(compiled, wasm_jit:counts(), 0),
    Already orelse Compiled > 0
        orelse exit({nothing_compiled, wasm_jit:counts()}),
    ok = wasm_jit:reset_counts(),
    Compiled.

until_resident(W, Req, Hash, Deadline) ->
    _ = req_us(W, Req),
    case target(Hash) of
        {ok, _} -> ok;
        error ->
            erlang:monotonic_time(millisecond) < Deadline
                orelse exit({never_resident, wasm_jit:counts()}),
            until_resident(W, Req, Hash, Deadline)
    end.

%% Polled without calling, deliberately: the compiler is off the request path,
%% so more requests would only add leases of their own to wait for.
until_quiet(Hash, Deadline) ->
    {ok, {_, _, Leases}} = target(Hash),
    Children = proplists:get_value(active,
                                   supervisor:count_children(wasm_jit_sup)),
    case {Leases, Children} of
        {0, 0} -> ok;
        _ ->
            erlang:monotonic_time(millisecond) < Deadline
                orelse exit({never_quiet, {Leases, Children}}),
            timer:sleep(200),
            until_quiet(Hash, Deadline)
    end.

alternate(_Wm, _Wc, _Req, N, I, Ms, Cs) when I > N ->
    {lists:reverse(Ms), lists:reverse(Cs)};
alternate(Wm, Wc, Req, N, I, Ms, Cs) ->
    {M, C} = case I rem 2 of
                 1 -> {req_us(Wm, Req), req_us(Wc, Req)};
                 0 -> R = req_us(Wc, Req), {req_us(Wm, Req), R}
             end,
    alternate(Wm, Wc, Req, N, I + 1, [M | Ms], [C | Cs]).

%% Not "every slot free". Releasing the last lease deliberately leaves the key
%% on the slot so a later instance adopts rather than reloads, so the expected
%% end state is resident-with-no-leases. The control arm is the opposite and
%% says so.
end_state(Hash, resident) ->
    {ok, {Name, _, Leases}} = target(Hash),
    io:format("# end state: ~p resident, ~w leases, ~w loading, ~p children~n",
              [Name, Leases, length(loading()),
               supervisor:count_children(wasm_jit_sup)]),
    Leases =:= 0 orelse exit({leases_left, Leases}),
    [] =:= loading() orelse exit({still_loading, loading()}),
    ok;
end_state(Hash, absent) ->
    error = target(Hash),
    #{compiled := 0, entered := 0, cached := 0} = wasm_jit:counts(),
    [] =:= loading() orelse exit({still_loading, loading()}),
    io:format("# end state: nothing resident, counts zero, ~p children~n",
              [supervisor:count_children(wasm_jit_sup)]),
    ok.

loading() ->
    [N || {N, _, St, _} <- ets:tab2list(wasm_code_slots),
          element(1, St) =:= loading].

%%% ------------------------------------------------------------ cold node ---

%% What a node pays before the tier is running, and whether a cache spares it.
%%
%%     erl ... -run workerbench main coldnode lua_reactor <dir> cold serve
%%
%% `<dir>' is an **absolute** path the cache will accept: not `/tmp', which is a
%% symlink to a world-writable directory and is refused. `cold' starts from an
%% empty one and populates it; `warm' expects a seeded one.
%%
%% `serve' keeps requests coming while the compile runs, which is what a host
%% can actually do. `wait' stops once the compile has been asked for and polls
%% while idle -- **not** a host strategy, because the polling is an internal
%% API, but the lower bound a readiness barrier would buy.
coldnode(Adapter, Dir, State, Strategy) ->
    coldnode(Adapter, Dir, State, Strategy, "w").

coldnode(Adapter, Dir, State, Strategy, Which) ->
    say_box("at start"),
    {ok, _} = application:ensure_all_started(wasm),
    Root = "/tmp/workerbench_root",
    _ = os:cmd("rm -rf " ++ Root),
    ok = filelib:ensure_path(Root),
    true = filename:pathtype(Dir) =:= absolute,
    ok = filelib:ensure_path(Dir),
    application:set_env(wasm, code_cache_dir, Dir),
    %% Prepared outside every timed arm. A worker that finds no image captures
    %% instead, silently, and the arm would then carry ninety seconds of
    %% somebody else's work.
    Images = image_dir(Adapter),
    application:set_env(wasm, snapshot_dir, Images),
    {ok, _} = worker_reaper:start_link(#{scratch => Root}),
    {Mod, Path, _} = arm(Adapter, "metered"),
    Guest = guest(Adapter, Path),
    {_, _, Compiled} = arm(Adapter, "compiled"),
    Wl = workload(Adapter, list_to_atom(Which)),
    io:format("# ~s coldnode dir=~ts state=~s strategy=~s workload=~s~n",
              [Adapter, Dir, State, Strategy, Which]),
    io:format("# entries before: ~w~n", [length(entries(Dir))]),
    State =:= "warm" andalso entries(Dir) =:= [] andalso
        exit(warm_arm_with_empty_cache),
    T0 = erlang:monotonic_time(millisecond),
    Wk = start_floor(Mod, Guest, Compiled, floor_for(Adapter)),
    Start = erlang:monotonic_time(millisecond) - T0,
    ok = loaded_not_captured(Adapter, Start),
    ok = wasm_jit:reset_counts(),
    %% The clock for residency starts here: the snapshot is already paid for.
    T1 = erlang:monotonic_time(millisecond),
    {Reqs, Ms} = to_residency(Wk, Wl, Strategy, T1),
    Counts = wasm_jit:counts(),
    io:format("# worker start   ~w ms (snapshot, reported apart)~n", [Start]),
    io:format("# to residency   ~w ms over ~w requests~n", [Ms, Reqs]),
    io:format("# counts         ~p~n", [Counts]),
    io:format("# shards         ~w~n", [shards_of(Adapter, Dir)]),
    %% The slot is in the cache key, so a miss cannot be blamed on the function
    %% set unless both arms took the same one.
    io:format("# slot           ~p~n",
              [[N || {N, _, _} <- wasm_code_slots:resident()]]),
    io:format("# entries after: ~w~n", [length(entries(Dir))]),
    ok = script_worker:stop(Wk),
    say_box("at end"),
    init:stop().

%% Drive until the module is resident, one of two ways.
to_residency(Wk, Wl, Strategy, T0) ->
    Deadline = T0 + 1_800_000,
    Hash = artifact_hash_of(Wl),
    to_residency(Wk, Wl, Strategy, T0, Deadline, 0, Hash).

to_residency(Wk, Wl, Strategy, T0, Deadline, N, Hash) ->
    case resident_any() of
        true ->
            {N, erlang:monotonic_time(millisecond) - T0};
        false ->
            erlang:monotonic_time(millisecond) < Deadline
                orelse exit({never_resident, N, wasm_jit:counts()}),
            case {Strategy, asked(N)} of
                %% Asked for already: stop driving and let it finish. This is
                %% the idealised arm; a host cannot see `asked' either.
                {"wait", true} ->
                    timer:sleep(200),
                    to_residency(Wk, Wl, Strategy, T0, Deadline, N, Hash);
                _ ->
                    ok = strict(Wl, script_worker:run(
                                      Wk, maps:with([source, context], Wl))),
                    to_residency(Wk, Wl, Strategy, T0, Deadline, N + 1, Hash)
            end
    end.

%% A compile has been asked for once anything is loading or a compiler is up.
asked(_N) ->
    proplists:get_value(active, supervisor:count_children(wasm_jit_sup)) > 0
        orelse [] =/= [x || {_, _, St, _} <- ets:tab2list(wasm_code_slots),
                            element(1, St) =:= loading].

resident_any() -> wasm_code_slots:resident() =/= [].

%% A sharded compile never looks in the cache at all, so a `cached' of 0 from
%% one means nothing about the function set. Recorded for every arm.
shards_of(_Adapter, _Dir) -> length(wasm_code_slots:resident()).

entries(Dir) -> filelib:wildcard(filename:join(Dir, "*.beam")).

%% Only a load can be this quick; a capture is the guest's whole startup.
loaded_not_captured(Adapter, Ms) ->
    Ceiling = case Adapter of
                  "py_reactor"  -> 20_000;
                  "qjs_reactor" -> 5_000;
                  "lua_reactor" -> 5_000
              end,
    case Ms =< Ceiling of
        true -> ok;
        false -> exit({worker_captured_rather_than_loaded, Ms, Ceiling})
    end.

image_dir(Adapter) ->
    D = filename:absname(filename:join(["_build", "bench-images", Adapter])),
    ok = filelib:ensure_path(D),
    D.

artifact_hash_of(_Wl) -> undefined.

floor_for("py_reactor") -> 1_000_000;
floor_for(_)            -> 200_000.

say_box(When) ->
    io:format("# ~s: ~s#           ~s", [When, os:cmd("uptime"), idle()]).
