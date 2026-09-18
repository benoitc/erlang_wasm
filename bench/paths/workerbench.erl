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

-include_lib("kernel/include/file.hrl").

%% `monotonic_timestamp' pairs a start with the end that follows it;
%% without it a collection has no duration.
-define(GC_FLAGS, [garbage_collection, monotonic_timestamp]).

main(["phases" | Rest]) ->
    phases(Rest);
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

%%% ------------------------------------------------------------- phases ----

%% Where a request's milliseconds go, at the five adapter boundaries.
%%
%% `bench/paths/phasing_adapter.erl' wraps the real adapter and returns T1..T10
%% with the reply; this takes T0 and T11 around `submit/2' and `await/3' and
%% joins them by the reference in the vector. The intervals are contiguous, so
%% they sum to the total exactly and a non-zero residual is an assembly bug
%% rather than a discovery: every sample asserts it away.
%%
%% One mode per worker, because the adapter and its artifact are fixed at
%% `start_link/2' and a timed request must carry timestamps and nothing else.
%%
%%     erl ... -run workerbench main phases seed  py_reactor
%%     erl ... -run workerbench main phases pairs py_reactor interpreted compiled
%%
%% Every stage validates every reply with `strict_phase/2' and stops the arm on
%% a mismatch, seed included: a failing seed request would decide a different
%% cached function set and still satisfy a compiled count.
%%
%% An invalid arm writes its raw record and halts the emulator non-zero, so a
%% `set -e' script cannot run `pairs' behind a failed `null'.

-define(PH_SAMPLES, 12).
-define(PH_FLOOR_PROBES, 6).
-define(PH_DISPATCH, 3).
-define(PH_ARM_MS, 900_000).            % fifteen minutes, enforced per request
-define(PH_LOAD_MAX, 20.0).
-define(PH_LOAD_DRIFT, 2.0).
-define(PH_GATE_LO, 0.95).
-define(PH_GATE_HI, 1.05).

%% The pinned reactor artifacts. `scripts/verify-fixtures.sh' does not cover
%% these: it checksums the command guests and checks the QuickJS and Lua
%% reactors for presence only, because a built reactor has no portable checksum
%% (the same pinned SDK emits different bytes on arm64 macOS and x86-64 Linux).
%% These two were built here, and every number this mode produces is against
%% them. A mismatch is a different artifact, not a different measurement, so it
%% stops the experiment rather than re-baselining.
-define(PH_PINNED,
        #{"py_reactor" =>
              "b4a78ad5046df47d0c8422eca122aa660f83933b70fcf0736519dc0dd0bc5514",
          "qjs_reactor" =>
              "7813fe2025c33b9e72645e696bfc8f14ecbc4a660a5d642b90af542473dbbabb"}).

%% What the seed must compile, exactly. A cardinality and not an identity: the
%% identity control is the warm preparer's `cached = 1', since the eligible
%% function-index set is part of the cache key.
-define(PH_COMPILED, #{"py_reactor" => 971, "qjs_reactor" => 264}).

phases(["preflight"]) ->
    ph_preflight(maps:keys(?PH_PINNED)),
    init:stop();
phases(["smoke"]) ->
    ph_smoke(),
    init:stop();
phases(["calibrate", Cb, Ms, N]) ->
    ph_calibrate(list_to_atom(Cb), list_to_integer(Ms), list_to_integer(N)),
    init:stop();
phases([Stage, Guest | Rest]) ->
    ph_preflight([Guest]),
    ph_stage(Stage, Guest, Rest),
    init:stop().

%%% ----------------------------------------------------------- preflight ---

%% Existence and hash, before anything else runs. A suite or an arm that cannot
%% find its fixture *skips* or measures the wrong thing, and a green run that
%% proved nothing is worse than a red one.
ph_preflight(Guests) ->
    _ = [ph_pinned(G) || G <- Guests],
    Lib = "test/fixtures/lang/py_reactor_lib/python3.14",
    case lists:member("py_reactor", Guests) of
        false -> ok;
        true ->
            filelib:is_dir(Lib) orelse ph_die({missing, Lib}),
            [] =/= filelib:wildcard(filename:join(Lib, "*"))
                orelse ph_die({empty, Lib})
    end,
    io:format("# preflight ok: ~p~n", [Guests]).

ph_pinned(Guest) ->
    Path = ph_path(Guest),
    filelib:is_regular(Path) orelse ph_die({missing, Path}),
    {ok, Bin} = file:read_file(Path),
    Got = ph_hex(crypto:hash(sha256, Bin)),
    Want = maps:get(Guest, ?PH_PINNED),
    Got =:= Want orelse ph_die({guest_hash, Guest, #{want => Want, got => Got}}),
    io:format("# ~-12s ~s ~w bytes~n", [Guest, Got, byte_size(Bin)]).

ph_path(Guest) -> element(2, arm(Guest, "metered")).

ph_hex(Bin) -> binary_to_list(binary:encode_hex(Bin, lowercase)).

%%% ------------------------------------------------------------ manifests ---

%% Two manifests, because the measurement spans a dozen emulators and recording
%% identities in each of them does not make them the same identities. Setup
%% writes both; every later invocation asserts exact equality before it opens a
%% window.
%%
%% The code manifest exists because a git commit is not enough: these runs
%% happen from a worktree that is still being edited, so HEAD names the parent
%% commit and not the code that was loaded, and a recompile between two
%% invocations would otherwise pass unnoticed.
ph_manifest_path(Guest) ->
    filename:join(ph_dir("bench-manifests"), Guest ++ ".manifest").

ph_write_manifest(Guest, M) ->
    Path = ph_manifest_path(Guest),
    ok = file:write_file(Path, io_lib:format("~p.~n", [M])),
    io:format("# manifest written ~ts~n", [Path]),
    M.

ph_read_manifest(Guest) ->
    Path = ph_manifest_path(Guest),
    case file:consult(Path) of
        {ok, [M]} -> M;
        {error, R} -> ph_die({no_manifest, Path, R})
    end.

%% Every later invocation calls this. A mismatch invalidates the invocation
%% rather than being noted, because a phase table assembled from two different
%% images or two different builds is not a phase table.
ph_assert_manifest(Guest) ->
    Want = ph_read_manifest(Guest),
    Got = ph_observe(Guest, maps:get(snapshot, Want), maps:get(cache, Want)),
    _ = [ph_same(K, maps:get(K, Want), maps:get(K, Got))
         || K <- [guest, request, lib, snapshot, cache, code]],
    Want.

ph_same(_K, V, V) -> ok;
ph_same(K, Want, Got) -> ph_die({manifest_drift, K, #{want => Want,
                                                      got => Got}}).

ph_observe(Guest, SnapHint, CacheHint) ->
    #{guest => ph_file_id(ph_path(Guest)),
      request => ph_request_hash(Guest),
      lib => ph_tree_hash(Guest),
      snapshot => ph_pick(ph_dir_ids(ph_images(Guest), "*"), SnapHint),
      cache => ph_pick(ph_dir_ids(ph_cache(Guest), "*.beam"), CacheHint),
      code => ph_code_id()}.

%% Exactly one of each is expected, and the seed purges both directories so
%% that is enforceable rather than hopeful. The hint is what the manifest
%% recorded: an extra file appearing later is drift and is reported as drift.
ph_pick([One], _Hint) -> One;
ph_pick(Many, Hint)   -> {unexpected, length(Many), Hint}.

ph_dir_ids(Dir, Glob) ->
    [ph_file_id(F) || F <- lists:sort(filelib:wildcard(
                                        filename:join(Dir, Glob)))].

ph_file_id(Path) ->
    {ok, Bin} = file:read_file(Path),
    {list_to_binary(filename:basename(Path)), byte_size(Bin),
     list_to_binary(ph_hex(crypto:hash(sha256, Bin)))}.

%% The request, with its encoding stated so another person can reproduce the
%% bytes. `expect' is not in it: the oracle is not part of the workload.
ph_request_hash(Guest) ->
    {W, _B} = pair(Guest),
    Core = maps:with([source, context], W),
    list_to_binary(ph_hex(crypto:hash(
                            sha256, term_to_binary(Core, [deterministic])))).

%% "sha256 of a directory" means nothing, and this tree has an empty
%% `python3.14/lib-dynload', so directories and symlinks are entries in their
%% own right and the whole sorted list is hashed as one deterministic term.
ph_tree_hash("py_reactor") ->
    Root = "test/fixtures/lang/py_reactor_lib",
    Entries = lists:sort(ph_walk(Root, Root)),
    list_to_binary(ph_hex(crypto:hash(
                            sha256, term_to_binary(Entries, [deterministic]))));
ph_tree_hash(_Guest) ->
    none.

ph_walk(Root, Path) ->
    Rel = list_to_binary(ph_rel(Root, Path)),
    case file:read_link_info(Path) of
        {ok, #file_info{type = symlink}} ->
            {ok, T} = file:read_link(Path),
            [{symlink, Rel, list_to_binary(T)}];
        {ok, #file_info{type = directory}} ->
            {ok, Names} = file:list_dir(Path),
            [{dir, Rel} | lists:append(
                            [ph_walk(Root, filename:join(Path, N))
                             || N <- Names])];
        {ok, #file_info{type = regular, size = Size}} ->
            {ok, Bin} = file:read_file(Path),
            [{file, Rel, Size,
              list_to_binary(ph_hex(crypto:hash(sha256, Bin)))}];
        {ok, #file_info{type = T}} ->
            [{T, Rel}]
    end.

ph_rel(Root, Root) -> "";
ph_rel(Root, Path) -> string:prefix(Path, Root ++ "/").

%% The runtime, the kernel, the adapters and this harness, by content. HEAD
%% alone would name the parent commit of a worktree that is still being edited.
ph_code_id() ->
    Beams = lists:sort(
              filelib:wildcard("_build/test/lib/wasm/ebin/*.beam")
              ++ filelib:wildcard("_build/test/lib/wasm/examples/*.beam")
              ++ ["bench/paths/phasing_adapter.beam",
                  "bench/paths/workerbench.beam"]),
    Ids = [ph_file_id(B) || B <- Beams, filelib:is_regular(B)],
    #{head => ph_trim(os:cmd("git rev-parse HEAD")),
      diff => list_to_binary(ph_hex(crypto:hash(
                                      sha256, os:cmd("git diff HEAD")))),
      beams => list_to_binary(ph_hex(crypto:hash(
                                       sha256, term_to_binary(
                                                 Ids, [deterministic]))))}.

ph_trim(S) -> list_to_binary(string:trim(S)).

%%% ------------------------------------------------------------ the arena ---

%% Absolute paths under `_build', whose ancestry passes `wasm_code_cache's
%% ownership and mode rules. `/tmp' does not: it is a symlink to a
%% world-writable directory, which the cache refuses and should.
ph_dir(Kind) ->
    D = filename:absname(filename:join("_build", Kind)),
    ok = filelib:ensure_path(D),
    D.

ph_images(Guest) -> ph_dir(filename:join("bench-images", Guest)).
ph_cache(Guest)  -> ph_dir(filename:join("bench-cache-phases", Guest)).

%% One emulator, one root, one reaper. `snapshot_dir' points at the seeded
%% image directory so a worker start is a load: a CPython capture is 83 to 90
%% seconds and a load is under 20, and `loaded_not_captured/2' is what refuses
%% to confuse them.
ph_boot(Guest, Cache) ->
    {ok, _} = application:ensure_all_started(wasm),
    case Cache of
        none -> application:unset_env(wasm, code_cache_dir);
        Dir  -> application:set_env(wasm, code_cache_dir, Dir)
    end,
    Root = filename:join(ph_dir("bench-root"), Guest),
    _ = os:cmd("rm -rf " ++ Root),
    ok = filelib:ensure_path(Root),
    application:set_env(wasm, snapshot_dir, ph_images(Guest)),
    {ok, _} = worker_reaper:start_link(#{scratch => Root}),
    ok.

%% A wrapper worker in one mode, or the real adapter with no wrapper at all.
%% The mode is fixed here because the adapter and its artifact are, and because
%% a per-request mode would have to be read, stashed and erased on every path
%% through the runner for no gain.
ph_worker(Guest, Config, Mode) -> ph_worker(Guest, Config, Mode, load).

%% `capture' is for the seed alone, which purged the image directory and is the
%% run that fills it: a CPython capture is 83 to 90 seconds where a load is
%% under 20, so the ceiling that tells them apart has to be lifted exactly
%% once. Every later worker is held to `load'.
ph_worker(Guest, Config, Mode, Expect) ->
    {Mod, Path, Limits} = arm(Guest, Config),
    Base = (guest(Guest, Path))#{root => scratch, limits => Limits,
                                 runner_min_heap_words => floor_for(Guest)},
    T0 = erlang:monotonic_time(millisecond),
    {ok, W} =
        case Mode of
            direct ->
                script_worker:start_link(Mod, Base);
            {calibrate, Cb, Sleep} ->
                script_worker:start_link(
                  phasing_adapter,
                  Base#{under => Mod, mode => calibrate,
                        calibrate => {Cb, Sleep}});
            _ ->
                script_worker:start_link(
                  phasing_adapter, Base#{under => Mod, mode => Mode})
        end,
    Ms = erlang:monotonic_time(millisecond) - T0,
    Expect =:= capture orelse ok =:= loaded_not_captured(Guest, Ms)
        orelse ph_die({not_a_load, Ms}),
    io:format("# worker start ~w ms (~w)~n", [Ms, Expect]),
    W.

%% The frozen request, and the oracle that goes with it. `pair/1' already holds
%% a workload with an `expect' per reactor guest; the adapters' own fixtures do
%% not, so they cannot be handed to a strict check at all.
ph_workload(Guest) -> element(1, pair(Guest)).

%%% ---------------------------------------------------------- one request ---

%% T0, submit, a **finite** await against the arm's remaining time, cancel, T11.
%%
%% Not `script_worker:run/2', which is `submit/2' plus `await(infinity)'
%% (`script_worker.erl:494-510'), so a request begun just inside a deadline
%% runs on for the worker's own timeout: ten more minutes on CPython. A loop
%% that only checks the clock before submitting is not a bound.
%%
%% `await/3' calls `consumed/3' before it returns, so that acknowledgement is
%% inside T10-T11 and is named there.
ph_one(W, Workload, Deadline) ->
    Req = maps:with([source, context], Workload),
    T0 = erlang:monotonic_time(microsecond),
    case script_worker:submit(W, Req) of
        {error, E} ->
            {invalid, {submit, E}};
        {ok, Ref} ->
            Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
            case script_worker:await(W, Ref, Left) of
                {ok, Map} ->
                    T11 = erlang:monotonic_time(microsecond),
                    ph_vector(Workload, T0, T11, Map);
                {error, E} ->
                    _ = script_worker:cancel(W, Ref),
                    {invalid, {failed, E}}
            end
    end.

%% Validate, then assemble. Both happen outside the window in a timed arm,
%% which is why this returns the raw reply and the caller decides when to look
%% at it.
ph_vector(Workload, T0, T11, Map) ->
    case maps:take('$phases', Map) of
        error ->
            %% The direct arm of the overhead experiment, which deliberately
            %% runs the real adapter with no wrapper on it. It has a total and
            %% no intervals, and that is what it is for.
            ok = strict_phase(Workload, {ok, Map}),
            {ok, #{ref => none, total => T11 - T0, ivs => none, extra => #{}}};
        {P, Rest} ->
            ok = strict_phase(Workload, {ok, Rest}),
            {ok, ph_intervals(P, T0, T11)}
    end.

%% The eleven contiguous intervals. They sum to T11-T0 identically, so the
%% residual is an assertion and not a finding: a non-zero one is a bug in this
%% arithmetic, never a hidden runtime cost.
ph_intervals(P, T0, T11) ->
    #{t1 := T1, t2 := T2, t3 := T3, t4 := T4, t5 := T5, t6 := T6,
      t7 := T7, t8 := T8, t9 := T9, t10 := T10} = P,
    Marks = [T0, T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11],
    ok = ph_ordered(Marks),
    Names = ph_names(),
    Ivs = maps:from_list(
            lists:zip(Names, [B - A || {A, B} <- lists:zip(
                                                  lists:droplast(Marks),
                                                  tl(Marks))])),
    Total = T11 - T0,
    Total = lists:sum(maps:values(Ivs)),          % the residual, asserted away
    #{ref => maps:get(ref, P), total => Total, ivs => Ivs,
      extra => maps:without([ref, t1, t2, t3, t4, t5, t6, t7, t8, t9, t10], P)}.

%% Named for what is inside them, not for the callback that bounds them. T6-T7
%% especially: it is the **invocation envelope**, holding the returns through
%% `post_restore/3' and `start_instance/2', the dispatch, all of `wasm:call/5'
%% and the dispatch into `classify/2'. Calling it `handle' would claim a
%% boundary no adapter can reach.
ph_names() ->
    [submit, requirements, mounts, prepare, deliver_restore, post_restore,
     envelope, classify, destroy_channels, decode, reply].

ph_ordered([_]) -> ok;
ph_ordered([A, B | R]) when A =< B -> ph_ordered([B | R]);
ph_ordered(Bad) -> ph_die({timestamps_out_of_order, Bad}).

%% What `strict/2' is not, twice over. It checks the decoded result and nothing
%% else, and these workloads should also produce nothing on the other two
%% channels: unexpected output is changed behaviour *and* channel-read cost
%% inside a phase this measures. `strict/2' is left alone for the older modes.
strict_phase(#{expect := Expect}, {ok, #{result := Expect,
                                         stdout := <<>>, stderr := <<>>}}) ->
    ok;
%% The smoke fixture has no channels and answers guest values, so it gets its
%% own clause rather than a looser first one: a check that accepted both shapes
%% would accept a reactor reply with output on stderr.
strict_phase(#{expect_values := Vs}, {ok, #{values := Vs}}) ->
    ok;
strict_phase(W, Other) ->
    ph_die({wrong_result, #{expected => maps:with([expect, expect_values], W),
                            got => Other}}).

%%% ---------------------------------------------------------- statistics ---

%% The median decides, because the question is what a typical request costs.
%% Minimums are reported beside it, as `bench/paths/README.md' asks, and decide
%% nothing here.
ph_median(L) ->
    S = lists:sort(L),
    N = length(S),
    case N rem 2 of
        1 -> lists:nth((N + 1) div 2, S);
        0 -> (lists:nth(N div 2, S) + lists:nth(N div 2 + 1, S)) / 2
    end.

%% Medians of paired ratios, never ratios of medians: the i-th round of one arm
%% pairs with the i-th round of the other in the same emulator.
ph_paired(As, Bs) -> [A / B || {A, B} <- lists:zip(As, Bs), B > 0].

%% One outlier must not make an arm bimodal, so a split needs a 2x gap with at
%% least three samples on each side of it. Fixed now, not revisited after the
%% numbers are in.
ph_bimodal(L) ->
    S = lists:sort(L),
    N = length(S),
    Splits = [{I, lists:nth(I + 1, S) / max(1, lists:nth(I, S))}
              || I <- lists:seq(3, N - 3)],
    case [I || {I, R} <- Splits, R > 2.0] of
        []      -> false;
        [I | _] -> {true, lists:sublist(S, I), lists:nthtail(I, S)}
    end.

%% The one-minute average, at the start and end of the paired experiment and
%% not per arm, since the arms interleave. Drift in either direction
%% contaminates both arms, so the gate is symmetric.
ph_load() ->
    S = os:cmd("uptime"),
    case re:run(S, "load averages?:\\s*([0-9.]+)", [{capture, [1], list}]) of
        {match, [V]} -> list_to_float(ph_dot(V));
        nomatch      -> unparseable
    end.

ph_dot(V) -> case lists:member($., V) of true -> V; false -> V ++ ".0" end.

ph_load_gate(Start, End) ->
    (is_float(Start) andalso is_float(End))
        orelse ph_die({uptime_unparseable, {Start, End}}),
    Hi = max(Start, End),
    Lo = max(0.01, min(Start, End)),
    case Start =< ?PH_LOAD_MAX andalso End =< ?PH_LOAD_MAX
        andalso Hi / Lo =< ?PH_LOAD_DRIFT of
        true  -> ok;
        false -> {load, #{start => Start, 'end' => End, drift => Hi / Lo}}
    end.

%%% ------------------------------------------------------------- the seed ---

%% A fresh emulator does not make the filesystem fresh, so the cache directory
%% is purged rather than assumed empty, and the application is started first
%% because `wasm_code_cache:purge/0' is guarded.
%%
%% The snapshot gets an origin and not just an identity: the image directory is
%% emptied and one capture is taken, so every later worker loads *that* image.
%% Without it `loaded_not_captured/2' is satisfied by any older compatible
%% image already sitting there, which is the one failure it cannot see.
ph_stage("seed", Guest, _) ->
    Cache = ph_cache(Guest),
    _ = os:cmd("rm -rf " ++ ph_images(Guest) ++ "/*"),
    ok = ph_boot(Guest, Cache),
    ok = wasm_code_cache:purge(),
    [] = ph_beams(Cache),
    [] = filelib:wildcard(filename:join(Cache, "*.tmp")),
    #{cached := 0} = wasm_jit:counts(),
    Workload = ph_workload(Guest),
    W = ph_worker(Guest, "compiled", timing, capture),
    Hash = ph_hash(Guest),
    Deadline = ph_deadline(),
    ok = ph_until_resident(W, Workload, Hash, Deadline),
    ok = until_quiet(Hash, Deadline),
    Want = maps:get(Guest, ?PH_COMPILED),
    Counts = wasm_jit:counts(),
    io:format("# seed counts ~p~n", [Counts]),
    #{compiled := Want, refused := 0, failed := 0, crashed := 0} = Counts,
    [] = wasm_jit:diagnostics(),
    1 = length(wasm_code_slots:resident()),
    ok = script_worker:stop(W),
    [_] = ph_beams(Cache),
    M = ph_write_manifest(Guest, ph_observe(Guest, hint, hint)),
    io:format("# seeded ~s: ~p~n", [Guest, maps:with([guest, request], M)]);

%%% ------------------------------------------------------- the floor probe ---

%% Its own worker, with the limits of the one it stands for, because the
%% direct-adapter side of the overhead experiment has no wrapper to ask. Six
%% discarded requests, never a sample: `process_info/2' allocates and enlarges
%% the reply, which is exactly why it is not in one.
ph_stage("floor", Guest, [Config]) ->
    ok = ph_boot(Guest, ph_cache(Guest)),
    _ = ph_assert_manifest(Guest),
    Workload = ph_workload(Guest),
    %% Warmed like every other compiled arm. Without it the probe's own
    %% `entered' assertion cannot hold, and a floor probe that silently ran
    %% interpreted would be proving the floor of the wrong configuration.
    ok = ph_maybe_warm(Config =:= "compiled", Guest, Workload),
    W = ph_worker(Guest, Config, floor),
    _ = ph_one(W, Workload, ph_deadline()),
    ok = ph_quiesce(),
    ok = wasm_jit:reset_counts(),
    D = ph_deadline(),
    Gs = [begin
              {ok, V} = ph_one(W, Workload, D),
              maps:get(gc, maps:get(extra, V))
          end || _ <- lists:seq(1, ?PH_FLOOR_PROBES)],
    Want = floor_for(Guest),
    Mins = lists:usort([maps:get(min_heap_size, G) || G <- Gs]),
    Ceiling = maps:get(max_heap_words, element(3, arm(Guest, Config)),
                       8 * 1024 * 1024),
    io:format("# floor asked ~w got ~p ceiling ~w~n", [Want, Mins, Ceiling]),
    io:format("# minor_gcs ~p~n", [[maps:get(minor_gcs, G) || G <- Gs]]),
    io:format("# fullsweep_after ~p~n",
              [lists:usort([maps:get(fullsweep_after, G) || G <- Gs])]),
    %% At least, not equal: the emulator rounds a requested floor up to a
    %% heap-size class, by as much as 1.598x.
    [Got] = Mins,
    Got >= Want orelse ph_die({floor_below_request, Got, Want}),
    Got =< Ceiling orelse ph_die({floor_over_ceiling, Got, Ceiling}),
    ok = ph_counts(Config, ?PH_FLOOR_PROBES),
    ok = script_worker:stop(W);

%%% ---------------------------------------------------- the paired windows ---

%% Null: one configuration against itself, and it runs before the overhead arm
%% as well as before the primary one, because a failed null invalidates every
%% timing run after it on this guest.
ph_stage("null", Guest, [Config]) ->
    ph_pairs(Guest, {Config, timing}, {Config, timing}, "null");

%% Overhead: the real adapter against the timing wrapper. The null arm compares
%% the instrumented build against itself and so cannot see the instrument.
ph_stage("overhead", Guest, [Config]) ->
    ph_pairs(Guest, {Config, direct}, {Config, timing}, "overhead");

%% The primary window.
ph_stage("pairs", Guest, [A, B]) ->
    ph_pairs(Guest, {A, timing}, {B, timing}, "pairs");

%%% ------------------------------------------------------------ the rest ----

ph_stage("cleanup", Guest, [Config]) -> ph_cleanup(Guest, Config);
ph_stage("gc", Guest, [Config])      -> ph_gc(Guest, Config);
ph_stage("dispatch", Guest, _)       -> ph_dispatch(Guest);
ph_stage("msacc", Guest, _)          -> ph_msacc(Guest);
ph_stage("census", Guest, _)         -> ph_census(Guest).

ph_beams(Dir) -> filelib:wildcard(filename:join(Dir, "*.beam")).

ph_hash(Guest) -> artifact_hash(#{path => ph_path(Guest)}).

ph_deadline() -> erlang:monotonic_time(millisecond) + ?PH_ARM_MS.

ph_until_resident(W, Workload, Hash, Deadline) ->
    ok = ph_drive(W, Workload, Deadline),
    case target(Hash) of
        {ok, _} -> ok;
        error ->
            erlang:monotonic_time(millisecond) < Deadline
                orelse ph_die({never_resident, wasm_jit:counts()}),
            ph_until_resident(W, Workload, Hash, Deadline)
    end.

%% Drive one request and validate it, without asking for a measurement. The
%% seed and the warm preparer both run here, and the preparer is a *direct*
%% worker -- `compile_after' is not in the cache key but the wrapper is not in
%% the cache at all, so warming through it would seed a set no timed worker
%% asks for. A reply with no `$phases' is therefore the ordinary case here and
%% an error only in a timed arm.
ph_drive(W, Workload, Deadline) ->
    Req = maps:with([source, context], Workload),
    {ok, Ref} = script_worker:submit(W, Req),
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    case script_worker:await(W, Ref, Left) of
        {ok, Map} ->
            strict_phase(Workload, {ok, maps:remove('$phases', Map)});
        {error, E} ->
            _ = script_worker:cancel(W, Ref),
            ph_die({drive_failed, E})
    end.

%%% ------------------------------------------------- warm preparation ------

%% `?DEFAULT_AFTER' is 32, so a fresh warm-cache emulator does not look the
%% artifact up on its first ordinary request. A preparer worker with
%% `compile_after => 1' does, and `compile_after' is not in the cache key, so
%% the timed workers keep the ordinary configuration.
%%
%% `cached = 1' here is the identity control: the eligible function-index set
%% is part of the cache key, so a hit says the same set was asked for. The cold
%% seed has no hit and asserts `cached = 0'.
ph_warm(Guest, Workload) ->
    {Mod, Path, Limits} = arm(Guest, "compiled"),
    Base = (guest(Guest, Path))#{root => scratch,
                                 limits => Limits#{compile_after => 1},
                                 runner_min_heap_words => floor_for(Guest)},
    {ok, P} = script_worker:start_link(Mod, Base),
    Hash = ph_hash(Guest),
    D = ph_deadline(),
    ok = ph_until_resident(P, Workload, Hash, D),
    ok = until_quiet(Hash, D),
    Counts = wasm_jit:counts(),
    io:format("# warm counts ~p~n", [Counts]),
    Want = maps:get(Guest, ?PH_COMPILED),
    #{cached := 1, compiled := Want, refused := 0, failed := 0,
      crashed := 0} = Counts,
    [] = wasm_jit:diagnostics(),
    1 = length(wasm_code_slots:resident()),
    ok = script_worker:stop(P),
    ok.

%% Only a compiled arm needs the cache warmed, and warming one for an
%% interpreted arm would put resident code on a node whose whole point is that
%% it has none.
ph_maybe_warm(false, _Guest, _Workload) -> ok;
ph_maybe_warm(true, Guest, Workload)    -> ph_warm(Guest, Workload).

ph_maybe_wait(false, _Deadline) -> ok;
ph_maybe_wait(true, Deadline)   -> ph_reaper_empty(Deadline).

ph_counts(Config, N) -> ph_entered(ph_enters(Config, N)).

%% Exactly N, never `entered > 0': that passes with eleven of twelve samples
%% interpreting, and the exact count is always available. An arm whose counters
%% do not match is invalid whether or not it produced numbers, because a
%% completed run does not prove the request entered generated code.
ph_entered(N) ->
    C = wasm_jit:counts(),
    #{compiled := 0, cached := 0, refused := 0, failed := 0, crashed := 0} = C,
    case maps:get(entered, C) of
        N -> [] = wasm_jit:diagnostics(), ok;
        Other -> ph_die({entered, #{want => N, got => Other, counts => C}})
    end.

%%% ------------------------------------------------- the paired experiment ---

%% Twelve paired samples, the two arms alternating in one emulator with the
%% order reversed on alternate rounds.
%%
%% **The window is silent.** Nothing runs between requests but the next
%% request: validation, phase assembly, gate arithmetic, counter reads,
%% printing and the result directory all wait until it closes, with the raw
%% replies buffered. Printing per sample would put a gap between requests and
%% change the cleanup overlap this sets out to measure.
ph_pairs(Guest, {ConfA, ModeA}, {ConfB, ModeB}, Kind) ->
    ok = ph_boot(Guest, ph_cache(Guest)),
    _ = ph_assert_manifest(Guest),
    Workload = ph_workload(Guest),
    ok = ph_maybe_warm((ConfA =:= "compiled") orelse (ConfB =:= "compiled"),
                       Guest, Workload),
    Wa = ph_worker(Guest, ConfA, ModeA),
    Wb = ph_worker(Guest, ConfB, ModeB),
    D = ph_deadline(),
    %% One discarded request each: the first carries the module cache and every
    %% lazily loaded host module.
    _ = [ph_one(W, Workload, D) || W <- [Wa, Wb]],
    ok = ph_quiesce(),
    ok = wasm_jit:reset_counts(),
    Load0 = ph_load(),
    Raw = ph_rounds(Wa, Wb, Workload, D, 1, []),
    Counts = wasm_jit:counts(),
    Load1 = ph_load(),
    [ok = script_worker:stop(W) || W <- [Wa, Wb]],
    ph_finish(Guest, Kind, ConfA, ConfB, ModeA, ModeB, Raw, Counts,
              Load0, Load1).

ph_rounds(_Wa, _Wb, _W, _D, I, Acc) when I > ?PH_SAMPLES ->
    lists:reverse(Acc);
ph_rounds(Wa, Wb, Workload, D, I, Acc) ->
    {A, B} = case I rem 2 of
                 1 -> X = ph_one(Wa, Workload, D), {X, ph_one(Wb, Workload, D)};
                 0 -> Y = ph_one(Wb, Workload, D), {ph_one(Wa, Workload, D), Y}
             end,
    ph_rounds(Wa, Wb, Workload, D, I + 1, [{A, B} | Acc]).

%% Everything that was deferred, now that the window is shut.
ph_finish(Guest, Kind, ConfA, ConfB, ModeA, ModeB, Raw, Counts, L0, L1) ->
    As = [A || {A, _} <- Raw],
    Bs = [B || {_, B} <- Raw],
    ok = ph_no_invalid(As ++ Bs),
    Av = [V || {ok, V} <- As],
    Bv = [V || {ok, V} <- Bs],
    Gates = [{load, ph_load_gate(L0, L1)}] ++ ph_gates(Kind, Av, Bv),
    ok = ph_expect_counts(Kind, ConfA, ConfB, Counts),
    ph_report(Kind, ConfA, ConfB, Av, Bv),
    Dir = ph_results(Guest, Kind, ConfA ++ "-" ++ ConfB),
    ok = ph_write(Dir, #{kind => Kind, guest => Guest,
                         arms => {{ConfA, ModeA}, {ConfB, ModeB}},
                         load => {L0, L1}, counts => Counts,
                         gates => Gates, samples => {Av, Bv}}),
    ph_gate_verdict(Gates, Dir).

%% The counters are node-wide, so the window sees both arms: the expected
%% `entered' is the sum over the two configurations, whatever they are and in
%% whichever order they were given.
%%
%% Written as a sum rather than as a clause per shape because the clause
%% version had a silent catch-all: `pairs G compiled interpreted' matched
%% nothing and asserted nothing, which is a check that cannot fail.
ph_expect_counts(_Kind, ConfA, ConfB, _Counts) ->
    ph_entered(ph_enters(ConfA, ?PH_SAMPLES)
               + ph_enters(ConfB, ?PH_SAMPLES)).

ph_enters("compiled", N)    -> N;
ph_enters("interpreted", _) -> 0.

%% A null gate applies to the total and to the envelope separately; an overhead
%% gate is the wrapper against the direct adapter and also reports the absolute
%% difference, because 5% of a 7 ms request is 0.35 ms and that is larger than
%% the phases it would be used to justify.
ph_gates("null", Av, Bv) ->
    [{null_total, ph_ratio_gate(ph_paired(ph_col(total, Av),
                                          ph_col(total, Bv)))},
     {null_envelope, ph_ratio_gate(ph_paired(ph_iv(envelope, Av),
                                             ph_iv(envelope, Bv)))}];
ph_gates("overhead", Av, Bv) ->
    Direct = ph_col(total, Av),
    Wrapped = ph_col(total, Bv),
    %% The median of the paired differences, not the difference of the medians.
    %% Pairing is what cancels the drift both arms share, and taking it the
    %% other way read 3,643 us of "probe overhead" on a box that had simply
    %% moved between the two halves of one arm -- larger than every phase the
    %% floor would then have disqualified.
    Abs = ph_median([W - D || {W, D} <- lists:zip(Wrapped, Direct)]),
    io:format("# probe resolution floor ~.1f us "
              "(phases under it are below probe resolution)~n", [abs(Abs)]),
    [{overhead, ph_ratio_gate(ph_paired(Wrapped, Direct))},
     {resolution_floor_us, abs(Abs)}];
ph_gates(_Kind, _Av, _Bv) ->
    [].

ph_ratio_gate(Rs) ->
    M = ph_median(Rs),
    case M >= ?PH_GATE_LO andalso M =< ?PH_GATE_HI of
        true  -> {ok, M};
        false -> {failed, M}
    end.

ph_col(K, Vs)  -> [maps:get(K, V) || V <- Vs].
ph_iv(K, Vs)   -> [maps:get(K, maps:get(ivs, V)) || V <- Vs].

ph_no_invalid(Rs) ->
    case [R || {invalid, _} = R <- Rs] of
        []  -> ok;
        Bad -> ph_die({invalid_samples, Bad})
    end.

%%% -------------------------------------------------------------- report ----

%% Per-phase medians do not sum to the median total and are labelled as
%% summaries. Beside them an accounting row that does sum: the sixth and
%% seventh by total, averaged phase by phase, which is the even-sample median.
ph_report(Kind, ConfA, ConfB, Av, Bv) ->
    io:format("~n# ~s: ~s vs ~s, ~w paired samples~n",
              [Kind, ConfA, ConfB, length(Av)]),
    ph_arm(ConfA, Av),
    ph_arm(ConfB, Bv),
    ph_compare(Av, Bv).

%% Only where both arms carry intervals. The overhead experiment's direct side
%% has none by construction, so the ratios it could form are the totals its
%% own gate already takes.
ph_compare(Av, Bv) ->
    case ph_timed(Av) andalso ph_timed(Bv) of
        false -> ok;
        true  -> ph_compare_1(Av, Bv)
    end.

ph_timed(Vs) -> maps:get(ivs, hd(Vs)) =/= none.

ph_compare_1(Av, Bv) ->
    Rs = ph_paired(ph_iv(envelope, Av), ph_iv(envelope, Bv)),
    io:format("# envelope paired ratio  median ~.4f  min ~.4f~n",
              [ph_median(Rs), lists:min(Rs)]),
    Sh = [maps:get(deliver_restore, maps:get(ivs, V)) / maps:get(total, V)
          || V <- Bv],
    io:format("# deliver+restore share  median ~.3f  min ~.3f~n",
              [ph_median(Sh), lists:min(Sh)]),
    %% Per arm, never pooled. Two arms that differ by 3x are bimodal when
    %% concatenated **by construction**, so a pooled check reports the effect
    %% being measured as a defect in the samples. It did, the first time this
    %% ran.
    [begin
         ph_bimodality({Nm, total}, ph_col(total, Vs)),
         ph_bimodality({Nm, envelope}, ph_iv(envelope, Vs))
     end || {Nm, Vs} <- [{a, Av}, {b, Bv}]],
    ok.

ph_arm(Conf, Vs) ->
    Totals = ph_col(total, Vs),
    io:format("~n  ~s  total  median ~w us  min ~w us~n",
              [Conf, round(ph_median(Totals)), lists:min(Totals)]),
    ph_timed(Vs) andalso ph_arm_phases(Vs),
    ok.

ph_arm_phases(Vs) ->
    io:format("  ~-18s ~12s ~12s~n", ["phase (summary)", "median us",
                                      "min us"]),
    [begin
         Xs = ph_iv(N, Vs),
         io:format("  ~-18s ~12w ~12w~n", [N, round(ph_median(Xs)),
                                           lists:min(Xs)])
     end || N <- ph_names()],
    ph_accounting(Vs),
    true.

%% The row that adds up. Independent per-phase medians do not, and printing
%% them as though they did is how a phase table stops being an account.
ph_accounting(Vs) ->
    Sorted = lists:sort(fun(A, B) -> maps:get(total, A) =< maps:get(total, B) end,
                        Vs),
    N = length(Sorted),
    [P, Q] = [lists:nth(I, Sorted) || I <- [N div 2, N div 2 + 1]],
    io:format("  ~-18s ~12s~n", ["accounting", "us"]),
    [io:format("  ~-18s ~12.1f~n",
               [Nm, (maps:get(Nm, maps:get(ivs, P)) +
                     maps:get(Nm, maps:get(ivs, Q))) / 2])
     || Nm <- ph_names()],
    io:format("  ~-18s ~12.1f~n",
              [total, (maps:get(total, P) + maps:get(total, Q)) / 2]).

%% A split invalidates only its own series: a bimodal envelope draws no compile
%% conclusion and cannot fire the second cut, a bimodal total makes no
%% end-to-end claim.
ph_bimodality(Which, Xs) ->
    case ph_bimodal(Xs) of
        false -> ok;
        {true, Lo, Hi} ->
            io:format("# ** ~w is BIMODAL: ~w low ~p / ~w high ~p~n"
                      "#    no ratio conclusion from this series~n",
                      [Which, length(Lo), Lo, length(Hi), Hi])
    end.

%%% ---------------------------------------------------- the two controls ----

%% Cleanup overlap. The worker publishes its result before the reaper runs
%% adapter cleanup and removes the request directory
%% (`script_worker.erl:1183'), so a following request can overlap the previous
%% one's cleanup. The primary run stays immediate, because that is the workload
%% whose numbers are being explained.
%%
%% Alternating cannot express this: waiting before every isolated request
%% changes the sequence. So two batches of twelve in one emulator, in both
%% orderings, and the reaper waited empty **before every batch of either kind**
%% -- without that, a continuous batch following an isolated one overlaps the
%% cleanup that batch left.
ph_cleanup(Guest, Config) ->
    ok = ph_boot(Guest, ph_cache(Guest)),
    _ = ph_assert_manifest(Guest),
    Workload = ph_workload(Guest),
    ok = ph_maybe_warm(Config =:= "compiled", Guest, Workload),
    W = ph_worker(Guest, Config, timing),
    D = ph_deadline(),
    _ = ph_one(W, Workload, D),
    L0 = ph_load(),
    Runs = [{Order, Kind, ph_batch(W, Workload, D, Kind, Config)}
            || Order <- [cont_first, iso_first],
               Kind <- ph_order(Order)],
    L1 = ph_load(),
    ok = script_worker:stop(W),
    Get = fun(O, K) -> hd([V || {Oo, Kk, V} <- Runs, Oo =:= O, Kk =:= K]) end,
    io:format("~n# cleanup overlap, ~s~n", [Config]),
    Overlaps = [ph_overlap(N, Get) || N <- [total, submit, envelope, reply]],
    Dir = ph_results(Guest, "cleanup", Config),
    ok = ph_write(Dir, #{kind => cleanup, guest => Guest, load => {L0, L1},
                         overlaps => Overlaps, runs => Runs}),
    %% An overlap result is a **finding**, not an invalid arm: this control
    %% exists to say whether the two regimes differ, so a difference is its
    %% output and halting on one would discard the answer. Only the load gate
    %% can invalidate it.
    ph_gate_verdict([{load, ph_load_gate(L0, L1)}], Dir),
    ph_overlap_verdict(Overlaps).

ph_overlap_verdict(Overlaps) ->
    case [N || {{overlap, N}, {failed, _}} <- Overlaps] of
        [] ->
            io:format("# the two regimes agree; cleanup does not overlap "
                      "measurably~n");
        Ns ->
            io:format("# the two regimes DIFFER on ~p. A ratio below 1 is the "
                      "continuous~n#   arm being faster, which is not cleanup "
                      "contamination: waiting for~n#   the reaper has a cost of "
                      "its own. Read the direction before~n#   the magnitude.~n",
                      [Ns])
    end.

ph_order(cont_first) -> [continuous, isolated];
ph_order(iso_first)  -> [isolated, continuous].

%% Quiescence and a counter reset before each batch, and the counters asserted
%% after it, so a batch that never entered generated code cannot pass as one
%% that did.
ph_batch(W, Workload, D, Kind, Config) ->
    ok = ph_reaper_empty(D),
    ok = ph_quiesce(),
    ok = wasm_jit:reset_counts(),
    Vs = [begin
              ok = ph_maybe_wait(Kind =:= isolated, D),
              {ok, V} = ph_one(W, Workload, D),
              V
          end || _ <- lists:seq(1, ?PH_SAMPLES)],
    ok = ph_counts(Config, ?PH_SAMPLES),
    Vs.

%% Per interval and not averaged, so an order effect cannot hide inside a mean.
%% All four, because cleanup can take scheduler time during any phase and a
%% rule watching the total and the submit alone could miss contamination of the
%% envelope.
ph_overlap(Name, Get) ->
    Pick = fun(O, K) -> ph_median(ph_series(Name, Get(O, K))) end,
    R1 = Pick(cont_first, continuous) / Pick(cont_first, isolated),
    R2 = Pick(iso_first, continuous) / Pick(iso_first, isolated),
    Ok = lists:all(fun(R) -> R >= ?PH_GATE_LO andalso R =< ?PH_GATE_HI end,
                   [R1, R2]),
    io:format("  ~-18s cont_first ~.4f  iso_first ~.4f  ~s~n",
              [Name, R1, R2, case Ok of true -> "ok"; false -> "OVERLAP" end]),
    {{overlap, Name}, case Ok of true -> {ok, {R1, R2}};
                                 false -> {failed, {R1, R2}} end}.

ph_series(total, Vs) -> ph_col(total, Vs);
ph_series(Name, Vs)  -> ph_iv(Name, Vs).

ph_reaper_empty(Deadline) ->
    case worker_reaper:requests() of
        [] -> ok;
        _  ->
            erlang:monotonic_time(millisecond) < Deadline
                orelse ph_die(reaper_never_empty),
            timer:sleep(20),
            ph_reaper_empty(Deadline)
    end.

ph_quiesce() ->
    ph_quiesce(erlang:monotonic_time(millisecond) + 60_000).

ph_quiesce(Deadline) ->
    Children = proplists:get_value(active,
                                   supervisor:count_children(wasm_jit_sup)),
    case {Children, loading(), worker_reaper:requests()} of
        {0, [], []} -> ok;
        State ->
            erlang:monotonic_time(millisecond) < Deadline
                orelse ph_die({never_quiet, State}),
            timer:sleep(50),
            ph_quiesce(Deadline)
    end.

%%% ------------------------------------------------------- the GC control ---

%% Collections, and never in a timed pass. Tracing `new_processes' catches the
%% guardian and the cleanup jobs as well as the runner, and
%% `erlang:trace_delivered(RunnerPid)' is a barrier for the runner only, so
%% late events from the others would arrive during the next sample and sit in
%% the mailbox.
%%
%% So each request gets a **dedicated collector process**. It enables the
%% trace, submits, waits for the runner's barrier, drains the runner's events
%% and exits, and late unrelated events have no next sample to reach.
%% (`compileheap.erl:357-361' shows the other shape, a `trace_delivered(all)'
%% barrier over every traced pid.)
ph_gc(Guest, Config) ->
    ok = ph_boot(Guest, ph_cache(Guest)),
    _ = ph_assert_manifest(Guest),
    Workload = ph_workload(Guest),
    ok = ph_maybe_warm(Config =:= "compiled", Guest, Workload),
    W = ph_worker(Guest, Config, gc),
    D = ph_deadline(),
    _ = ph_one(W, Workload, D),
    ok = ph_quiesce(),
    ok = wasm_jit:reset_counts(),
    L0 = ph_load(),
    Rows = [ph_collect(W, Workload, D) || _ <- lists:seq(1, ?PH_SAMPLES)],
    L1 = ph_load(),
    ok = ph_counts(Config, ?PH_SAMPLES),
    ok = script_worker:stop(W),
    %% An incomplete start/end pair is an incomplete event stream, which the
    %% collector's own failure protocol invalidates the arm for. Twelve or
    %% nothing: never an eleven-sample diagnostic, and never a replacement
    %% sample spliced in.
    Bad = [R || R <- Rows, not is_map(R)],
    io:format("~n# gc, ~s ~s~n", [Guest, Config]),
    [io:format("  minor ~4w  major ~3w  in ~8w us~n",
               [maps:get(minor, R), maps:get(major, R), maps:get(us, R)])
     || R <- Rows, is_map(R)],
    Gates = [{load, ph_load_gate(L0, L1)},
             {complete, case Bad of [] -> {ok, ?PH_SAMPLES};
                                    _  -> {failed, Bad} end}],
    Dir = ph_results(Guest, "gc", Config),
    ok = ph_write(Dir, #{kind => gc, guest => Guest, config => Config,
                         load => {L0, L1}, rows => Rows, gates => Gates}),
    ph_gate_verdict(Gates, Dir).

ph_collect(W, Workload, D) ->
    Parent = self(),
    {Pid, Mon} = spawn_monitor(fun() -> ph_collector(Parent, W, Workload, D) end),
    receive
        {gc_result, Pid, R} ->
            receive {'DOWN', Mon, process, Pid, normal} -> R
            after 5000 -> {invalid, collector_did_not_exit}
            end;
        {'DOWN', Mon, process, Pid, Reason} ->
            {invalid, {collector_died, Reason}}
    after 900_000 ->
            exit(Pid, kill),
            {invalid, collector_timeout}
    end.

ph_collector(Parent, W, Workload, D) ->
    _ = erlang:trace(new_processes, true, ?GC_FLAGS),
    R = ph_one(W, Workload, D),
    _ = erlang:trace(new_processes, false, ?GC_FLAGS),
    Out = case R of
              {ok, V} ->
                  Runner = maps:get(runner, maps:get(extra, V)),
                  %% Waiting for the message is the barrier, not calling the
                  %% function: `workerbench:one/2' drains with `after 0' and
                  %% `allocwords.erl:91' records why that loses events in
                  %% flight.
                  Ref = erlang:trace_delivered(Runner),
                  receive {trace_delivered, Runner, Ref} -> ok
                  after 30_000 -> ok
                  end,
                  ph_pairs_of(Runner, V);
              Invalid ->
                  Invalid
          end,
    Parent ! {gc_result, self(), Out}.

%% Minor and major start/end events paired per pid, native converted to
%% microseconds. An unpaired event invalidates the sample rather than being
%% counted, and the arm with it.
ph_pairs_of(Runner, V) ->
    {Minor, Major, Native, Open} = ph_drain(Runner, 0, 0, 0, #{}),
    case maps:size(Open) of
        0 -> #{ref => maps:get(ref, V), total => maps:get(total, V),
               minor => Minor, major => Major,
               us => erlang:convert_time_unit(Native, native, microsecond)};
        _ -> {invalid, {unpaired_gc_events, maps:size(Open)}}
    end.

ph_drain(Runner, Minor, Major, Native, Open) ->
    receive
        {trace_ts, P, Kind, _Info, Ts} when P =:= Runner,
                                            Kind =:= gc_minor_start;
                                            P =:= Runner,
                                            Kind =:= gc_major_start ->
            ph_drain(Runner, Minor, Major, Native, Open#{P => Ts});
        {trace_ts, P, gc_minor_end, _Info, Ts} when P =:= Runner ->
            {T0, Rest} = maps:take(P, Open),
            ph_drain(Runner, Minor + 1, Major, Native + (Ts - T0), Rest);
        {trace_ts, P, gc_major_end, _Info, Ts} when P =:= Runner ->
            {T0, Rest} = maps:take(P, Open),
            ph_drain(Runner, Minor, Major + 1, Native + (Ts - T0), Rest);
        _Other ->
            ph_drain(Runner, Minor, Major, Native, Open)
    after 0 ->
            {Minor, Major, Native, Open}
    end.

%%% --------------------------------------------------------- second cut -----

%% Dispatch. The one number that says how much of the executed program the tier
%% took. No timing pass carries a trace: `pyarms.erl:219-221' records that
%% call-count tracing charges the arm that dispatches and nothing to the arm
%% that does not, so the wall times here are not a speedup and are not printed
%% as one.
ph_dispatch(Guest) ->
    ok = ph_boot(Guest, ph_cache(Guest)),
    _ = ph_assert_manifest(Guest),
    Workload = ph_workload(Guest),
    Rows = [{C, ph_dispatch_arm(Guest, C, Workload)}
            || C <- ["interpreted", "compiled"]],
    io:format("~n# dispatch, ~s~n", [Guest]),
    [io:format("  ~-12s ~15w run/3 calls over ~w requests~n",
               [C, N, ?PH_DISPATCH]) || {C, N} <- Rows],
    [{_, I}, {_, Cc}] = Rows,
    io:format("  the interpreter executes ~.2f% of what it did~n",
              [case I of 0 -> 0.0; _ -> Cc * 100 / I end]),
    Dir = ph_results(Guest, "dispatch", "both"),
    ph_write(Dir, #{kind => dispatch, guest => Guest, rows => Rows}).

ph_dispatch_arm(Guest, Config, Workload) ->
    ok = ph_maybe_warm(Config =:= "compiled", Guest, Workload),
    W = ph_worker(Guest, Config, timing),
    D = ph_deadline(),
    _ = ph_one(W, Workload, D),
    ok = ph_quiesce(),
    ok = wasm_jit:reset_counts(),
    %% `trace_pattern/3' on a module the emulator has not loaded matches
    %% nothing and answers 0, which reads as a missing count and not a failure.
    {module, wasm_exec} = code:ensure_loaded(wasm_exec),
    1 = erlang:trace_pattern({wasm_exec, run, 3}, true, [call_count]),
    try
        _ = [ph_one(W, Workload, D) || _ <- lists:seq(1, ?PH_DISPATCH)],
        {call_count, N} = erlang:trace_info({wasm_exec, run, 3}, call_count),
        ok = ph_counts(Config, ?PH_DISPATCH),
        N
    after
        %% Afresh per arm, so the interpreted arm's hundreds of millions cannot
        %% leak into the adopted count.
        _ = erlang:trace_pattern({wasm_exec, run, 3}, false, [call_count]),
        ok = script_worker:stop(W)
    end.

%%% ---------------------------------------------------------------- msacc ---

%% Node-global, so one request would vanish in it: four batches in the order
%% I, C, C, I, reported separately, which keeps order from being confounded
%% with configuration. Started once and stopped once in an outer `after'; per
%% batch there is a reset, never another start.
%%
%% What it describes is the whole host request workload and not one request's
%% work, because reaper cleanup may overlap inside a batch.
ph_msacc(Guest) ->
    ok = ph_boot(Guest, ph_cache(Guest)),
    _ = ph_assert_manifest(Guest),
    case msacc:available() of
        false ->
            io:format("# msacc unavailable on this emulator; no conclusion~n");
        true ->
            Workload = ph_workload(Guest),
            ok = ph_warm(Guest, Workload),
            Ws = #{"interpreted" => ph_worker(Guest, "interpreted", timing),
                   "compiled" => ph_worker(Guest, "compiled", timing)},
            _ = msacc:start(),
            try
                Size = ph_batch_size(Guest),
                Rows = [ph_msacc_batch(maps:get(C, Ws), Workload, C, Size)
                        || C <- ["interpreted", "compiled",
                                 "compiled", "interpreted"]],
                Dir = ph_results(Guest, "msacc", "both"),
                ph_write(Dir, #{kind => msacc, guest => Guest, rows => Rows})
            after
                _ = msacc:stop(),
                [ok = script_worker:stop(W) || W <- maps:values(Ws)]
            end
    end.

ph_batch_size("py_reactor") -> 50;
ph_batch_size(_)            -> 200.

%% Validation is after the collection, for the reason the timing window is
%% silent: a `strict_phase/2' per request would be charged to the accounting
%% this batch exists to read. The next batch's reset is what clears what
%% validation did.
ph_msacc_batch(W, Workload, Config, Size) ->
    ok = ph_quiesce(),
    ok = ph_reaper_empty(ph_deadline()),
    ok = wasm_jit:reset_counts(),
    ok = msacc:reset(),
    D = ph_deadline(),
    Raw = ph_msacc_run(W, Workload, D, Size, []),
    Stats = msacc:stats(),
    Counts = wasm_jit:counts(),
    ok = ph_no_invalid(Raw),
    ok = ph_counts(Config, Size),
    Types = ph_msacc_types(Stats),
    io:format("~n# msacc ~s, ~w requests~n", [Config, Size]),
    [io:format("  ~-12w ~12w us~n", [T, V]) || {T, V} <- Types],
    #{config => Config, size => Size, counts => Counts, types => Types}.

%% Only the consing the driver needs happens inside the batch.
ph_msacc_run(_W, _Wl, _D, 0, Acc) -> Acc;
ph_msacc_run(W, Wl, D, N, Acc) ->
    ph_msacc_run(W, Wl, D, N - 1, [ph_one(W, Wl, D) | Acc]).

%% `sleep' excluded, as `matrix.erl' does it: a scheduler waiting for work is
%% not time this spent.
ph_msacc_types(Stats) ->
    lists:sort(
      maps:to_list(
        lists:foldl(
          fun(#{counters := C}, Acc) ->
              maps:fold(fun(sleep, _V, A) -> A;
                           (K, V, A) -> maps:update_with(K, fun(X) -> X + V end,
                                                         V, A)
                        end, Acc, C)
          end, #{}, Stats))).

%%% --------------------------------------------------------------- census ---

%% Which of the functions this request ran the tier could take. Its own untimed
%% request, with the tier off and nothing resident: an adopted instance would
%% record the interpreter fallback set rather than the set that drove the
%% compile.
%%
%% The `ok' tally must equal the cardinality the seed asserted, or a census
%% that matched nothing would read as a clean answer.
ph_census(Guest) ->
    ok = ph_boot(Guest, none),
    _ = ph_assert_manifest(Guest),
    [] = wasm_code_slots:resident(),
    [] = loading(),
    0 = proplists:get_value(active, supervisor:count_children(wasm_jit_sup)),
    #{compiled := 0, entered := 0, cached := 0} = wasm_jit:counts(),
    Workload = ph_workload(Guest),
    W = ph_worker(Guest, "interpreted", census),
    {ok, V} = ph_one(W, Workload, ph_deadline()),
    ok = script_worker:stop(W),
    Extra = maps:get(extra, V),
    1 = maps:get(classify_calls, Extra),
    C = maps:get(census, Extra),
    #{reached := Reached, ok := Ok, unsupported := U, limit := L} = C,
    Reached = Ok + U + L,
    Want = maps:get(Guest, ?PH_COMPILED),
    io:format("~n# census, ~s~n", [Guest]),
    io:format("  reached     ~6w~n  eligible    ~6w~n"
              "  unsupported ~6w~n  limit       ~6w~n", [Reached, Ok, U, L]),
    Ok =:= Want orelse ph_die({census_disagrees, #{want => Want, got => Ok}}),
    io:format("~n  ~-34s ~8s  ~s~n", ["first refusal", "count", "some indices"]),
    [io:format("  ~-34p ~8w  ~p~n", [K, N, Some])
     || {K, {N, Some}} <- lists:sort(
                            fun({_, {A, _}}, {_, {B, _}}) -> A >= B end,
                            maps:to_list(maps:get(why, C)))],
    Dir = ph_results(Guest, "census", "interpreted"),
    ph_write(Dir, #{kind => census, guest => Guest, census => C}).

%%% ------------------------------------------------- smoke and calibration ---

%% Over `fake_reactor_adapter', so it runs where no QuickJS or CPython build
%% does and costs seconds rather than minutes. It is the gate on the instrument
%% itself: a vector that is out of order, does not sum, or carries a payload
%% its mode promised not to carry is a broken instrument, and every number
%% after it would be assembled from it.
ph_smoke() ->
    {ok, _} = application:ensure_all_started(wasm),
    application:unset_env(wasm, code_cache_dir),
    Root = filename:join(ph_dir("bench-root"), "smoke"),
    _ = os:cmd("rm -rf " ++ Root),
    ok = filelib:ensure_path(Root),
    application:set_env(wasm, snapshot_dir, Root),
    {ok, _} = worker_reaper:start_link(#{scratch => Root}),
    Wl = ph_fake_workload(),
    T = ph_fake_worker(timing),
    D = ph_deadline(),
    {ok, A} = ph_one(T, Wl, D),
    {ok, B} = ph_one(T, Wl, D),
    %% Ordering and the residual are asserted inside `ph_intervals/3'; getting
    %% here at all is those two passing.
    maps:get(ref, A) =/= maps:get(ref, B)
        orelse ph_die(sample_ids_repeat),
    Bare = maps:get(extra, A),
    [] = maps:keys(Bare) -- [mode, classify_calls],
    timing = maps:get(mode, Bare),
    ok = script_worker:stop(T),
    G = ph_fake_worker(gc),
    {ok, Gv} = ph_one(G, Wl, D),
    Runner = maps:get(runner, maps:get(extra, Gv)),
    is_pid(Runner) orelse ph_die(no_runner_pid),
    Runner =/= self() orelse ph_die(runner_is_caller),
    ok = script_worker:stop(G),
    io:format("# smoke ok: ordered, sums, distinct ids, timing mode bare, "
              "gc mode names a runner ~p~n", [Runner]).

%% A known sleep in one callback has to show up in that interval and nowhere
%% else. "Nowhere else" is too strong against scheduling noise on its own, so
%% it is a paired comparison against a no-delay baseline with the tolerances
%% fixed in advance. Without this, a boundary wired to the wrong phase is
%% invisible: every interval would still be positive and still sum.
ph_calibrate(Callback, Ms, N) ->
    {ok, _} = application:ensure_all_started(wasm),
    application:unset_env(wasm, code_cache_dir),
    Root = filename:join(ph_dir("bench-root"), "calibrate"),
    _ = os:cmd("rm -rf " ++ Root),
    ok = filelib:ensure_path(Root),
    application:set_env(wasm, snapshot_dir, Root),
    {ok, _} = worker_reaper:start_link(#{scratch => Root}),
    Wl = ph_fake_workload(),
    Base = ph_fake_worker(timing),
    Slow = ph_fake_worker({calibrate, Callback, Ms}),
    D = ph_deadline(),
    _ = [ph_one(W, Wl, D) || W <- [Base, Slow]],
    {Bs, Ss} = ph_cal_rounds(Base, Slow, Wl, D, N, [], []),
    [ok = script_worker:stop(W) || W <- [Base, Slow]],
    Owner = ph_owner(Callback),
    Us = Ms * 1000,
    io:format("~n# calibrate ~w, ~w ms into ~w, owner interval ~w~n",
              [Callback, Ms, N, Owner]),
    Deltas = [{Nm, ph_median(ph_iv(Nm, Ss)) - ph_median(ph_iv(Nm, Bs))}
              || Nm <- ph_names()],
    [io:format("  ~-18s ~12.1f us~n", [Nm, Dl]) || {Nm, Dl} <- Deltas],
    Got = proplists:get_value(Owner, Deltas),
    Others = [{Nm, Dl} || {Nm, Dl} <- Deltas, Nm =/= Owner],
    TotalDelta = ph_median(ph_col(total, Ss)) - ph_median(ph_col(total, Bs)),
    io:format("  ~-18s ~12.1f us~n", [total, TotalDelta]),
    Got >= Us * 0.8 orelse ph_die({owner_did_not_move, Owner, Got}),
    Leaked = [X || {_, Dl} = X <- Others, abs(Dl) >= Us * 0.2],
    Leaked =:= [] orelse ph_die({delay_leaked_into, Leaked}),
    abs(TotalDelta - Got) < Us * 0.2
        orelse ph_die({total_disagrees, TotalDelta, Got}),
    io:format("# calibration ok for ~w~n", [Callback]).

%% Which interval each wrapped callback owns. This mapping is the claim the
%% whole phase table rests on, which is why it is tested rather than asserted.
ph_owner(requirements) -> requirements;
ph_owner(prepare)      -> prepare;
ph_owner(post_restore) -> post_restore;
ph_owner(classify)     -> classify;
ph_owner(decode)       -> decode.

ph_cal_rounds(_B, _S, _Wl, _D, 0, Bs, Ss) ->
    {lists:reverse(Bs), lists:reverse(Ss)};
ph_cal_rounds(B, S, Wl, D, N, Bs, Ss) ->
    {X, Y} = case N rem 2 of
                 1 -> P = ph_one(B, Wl, D), {P, ph_one(S, Wl, D)};
                 0 -> Q = ph_one(S, Wl, D), {ph_one(B, Wl, D), Q}
             end,
    {ok, Bv} = X,
    {ok, Sv} = Y,
    ph_cal_rounds(B, S, Wl, D, N - 1, [Bv | Bs], [Sv | Ss]).

ph_fake_worker(Mode) ->
    Base = #{root => scratch, runner_min_heap_words => 200_000,
             under => fake_reactor_adapter},
    Opts = case Mode of
               {calibrate, Cb, Ms} ->
                   Base#{mode => calibrate, calibrate => {Cb, Ms}};
               _ ->
                   Base#{mode => Mode}
           end,
    {ok, W} = script_worker:start_link(phasing_adapter, Opts),
    W.

%% The fixture's own base request, with the answer it must give. The kernel
%% suite pins the same one.
ph_fake_workload() ->
    {ok, A} = fake_reactor_adapter:artifact(#{}),
    #{base := #{echo := Echo}} = fake_reactor_adapter:conformance_fixtures(A),
    Echo#{expect_values => ph_fake_expect(Echo)}.

%% Asked once, before any timing, rather than written here: the fixture's
%% counter is the adapter's business and a literal would go stale with it.
ph_fake_expect(Echo) ->
    {ok, W} = script_worker:start_link(
                fake_reactor_adapter, #{root => scratch}),
    {ok, #{values := R}} = script_worker:run(W, Echo),
    ok = script_worker:stop(W),
    R.

%%% ---------------------------------------------------------- the record ----

%% `_build/' is neither tracked nor durable, so this is the working copy and
%% `test/audit/PERF.md' is the record. Guest, mode and configuration are in the
%% name because several invocations run in the same second, and the suffix
%% because two of them can still collide on all of that.
%%
%% Written after the window closes, never inside it.
ph_results(Guest, Kind, Config) ->
    Stamp = calendar:system_time_to_rfc3339(erlang:system_time(second),
                                            [{unit, second}]),
    Name = lists:flatten(
             io_lib:format("~s-~s-~s-~s-~s-~6.16.0b",
                           [Stamp, string:slice(ph_head(), 0, 12), Guest, Kind,
                            Config, rand:uniform(16#ffffff)])),
    D = filename:join(ph_dir("bench-results-phases"), Name),
    ok = filelib:ensure_path(D),
    D.

ph_head() -> binary_to_list(ph_trim(os:cmd("git rev-parse --short=12 HEAD"))).

ph_write(Dir, Map) ->
    Full = Map#{at => calendar:system_time_to_rfc3339(
                        erlang:system_time(second), [{unit, second}]),
                schedulers => erlang:system_info(schedulers),
                otp => erlang:system_info(otp_release),
                erts => erlang:system_info(version),
                system => erlang:system_info(system_architecture),
                cpu => string:trim(os:cmd("sysctl -n machdep.cpu.brand_string "
                                          "2>/dev/null || uname -p")),
                os => string:trim(os:cmd("uname -sr"))},
    ok = file:write_file(filename:join(Dir, "record.eterm"),
                         io_lib:format("~p.~n", [Full])),
    io:format("# record ~ts~n", [Dir]),
    ok.

%% A failed gate is not a footnote. The record is written first, then the
%% emulator halts non-zero, so a `set -e' script cannot run the next arm behind
%% it and the raw output of the invalid run survives for the repeat to be
%% published beside.
ph_gate_verdict(Gates, Dir) ->
    case [G || {_, {failed, _}} = G <- Gates] ++
         [G || {_, {load, _}} = G <- Gates] of
        [] ->
            io:format("# gates ok~n");
        Bad ->
            io:format("# ** GATE FAILED: ~p~n# ** record ~ts~n", [Bad, Dir]),
            init:stop(2),
            timer:sleep(infinity)
    end.

%% Everything that invalidates an arm comes through here: the record is already
%% written where there is one, and what is left is to say so and leave non-zero.
ph_die(Reason) ->
    io:format("# ** INVALID: ~p~n", [Reason]),
    init:stop(2),
    timer:sleep(infinity).
