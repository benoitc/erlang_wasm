-module(densitybench).
-moduledoc """
What a live instance costs the node, and how many fit under a page budget.

Use it to hold a change to linear memory against the A, B and density gates.
Each subcommand is one arm in one fresh VM; run them interleaved against the
other tree.

    erlc -o bench/paths -pa _build/default/lib/wasm/ebin \\
         bench/paths/reactorlib.erl bench/paths/barrier_adapter.erl \\
         bench/paths/densitybench.erl
    erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run densitybench main sharing py 50 raw/sharing.terms
    erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run densitybench main workers py 50 off raw/workers.terms
    erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run densitybench main expiry py 50 raw/expiry.terms
    erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run densitybench main density py raw/density.terms
    erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run densitybench main pool py 10 raw/pool.terms
    erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run densitybench main capture qjs 4 raw/capture.terms
    erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run densitybench main copy py 200 raw/copy.terms
    erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run densitybench main churn py_entry 10 lua 200 CACHEDIR raw/churn.terms

Guests are `py`, `py_entry`, `qjs`, `lua` and `plain`; `workers` and
`expiry` take all but `plain`. The last argument is the raw file, `none` for
none. A round that breaks the protocol prints `VOID` with the reason and still
tears down.

## `sharing`: A, runtime sharing

`page_limit` 65536. The image is loaded once and put in `persistent_term`, so
the processes read one term and copy none of it; one warm restore, request and
destroy runs first. Then `erlang:memory(total)` is sampled, K processes each
restore, serve the fixed request through `reactorlib:request/2`, check the
answer, acknowledge and block in `receive`, and once all K have acknowledged
total is sampled again. The result is the difference over K. Charged pages
(`wasm_engine:pages_in_use/0`) and image bytes are reported beside it and
never added. Each process has 60 s or the round is void. A second sample after
each process has collected its own heap is reported as a diagnostic.

## `workers`: B, deployment

`page_limit` 65536, worker `timeout` 120000, N script workers wrapped by
`barrier_adapter`, `restore_ahead` as given (`on` or `off`), every other
worker option at its default. Each worker serves one request, the harness
waits until it is idle, and samples total: that is warm idle. Idle means the
ahead runner holds its instance (`restore_ahead` on), the worker's
`{recycle, _}` keeper rows exist (off, on a build that recycles), or the
request completed (off, on a build that does not). Then each worker takes one
request, and with all N held at the barrier total is sampled again: the
increment over N is the result. All N must then succeed with the expected
value.

On a build that recycles, with `restore_ahead` off, the handoff is checked in
two stages: the rows exist immediately before the busy requests go, within
20 s of the warm ones; at the barrier they are gone, each runner holds its
instance's rows under an `{instance, _}` token and has
`{wasm_script_worker, released} = true` in its dictionary. Whether a build
recycles is read from the code (`wasm_snapshot:take_recycled/1`); a build
without it reports `no recycling` and skips both stages. Every check runs in
a short-lived process.

Image duplication is reported apart, from the snapshot byte budget: what the
workers added to `wasm_snapshot_owner:charged/0`, over one image's bytes.

**A pool where the build has one.** On a build that exports
`wasm_script_worker:prepare/2` the N workers start from one prepared image,
which is how a pool is meant to be run there; on one that does not, the first
worker starts alone so the image is filed and the rest start together, as
before. Every pool mode below makes the same choice, read from the code.

## `pool`: a pool started on a filed image

`snapshot_dir` as `workers`. One worker is started and stopped first, so the
image is filed, and the harness waits until the image's charge is given back.
Then the clock starts: with `prepare/2` the image is prepared and N workers
start together from it; without, N workers start together. The result is the
time from the start to the last `start_link/2` returning, prepare included:
with `restore_ahead` off a started worker is idle. Every worker then serves
one request, checked.

## `capture`: a pool started on a missing image

`snapshot_dir` a new empty directory, named by the OS pid and the system
time so no two VMs share one. As `pool`, without the first worker. Every call
of `wasm_snapshot:capture/3` is counted with `call_count`. Once all are up and
the holder counts are stable for 200 ms, the keeper's image rows made since
the start are the generations, each with its holder count from its owner.

## `copy`: what sending the image costs

One worker started as usual. The image it holds is read from its state, and
`erts_debug:flat_size/1` of it is the words a send or a spawn copies, since
an off-heap binary counts only its reference. Then K processes are spawned
with the image in the closure, one at a time, each timed from before the
`spawn` to the child's first instruction; the median and minimum are
reported, in microseconds.

## `churn`: a serving pool while another pool starts and stops

N workers of the serving guest on the compiled tier, `code_cache_dir` as
given, each warmed until a request enters generated code, then two requests
each. A churner then starts and stops a pool of one worker of the churn guest
every 500 ms, its image filed beforehand (with `prepare/2`, prepared, started
and released each cycle), while every serving worker serves `Per` requests
back to back, each timed. `erlang:memory(total)` is sampled every 100 ms from
just before the burst to its end. Reported: the p50 and p99 of all requests,
requests a second over the burst's wall time, the peak memory and the churn
cycles completed. A churn guest of `none` runs no churner: that is the
saturated pool on its own.

## `expiry`: the idle diagnostic

`restore_ahead` off. Warm idle as above, then the sample again 35 s after the
warm requests, after the 30 s `recycle_idle` timer has fired. Reported, never
the reference for busy.

## `density`

`page_limit` 4096. Restore and serve, holding each instance in its own
process, until the first failure; every answer is checked. `reserve_pages/1`
is traced with `erlang:trace_pattern/3` and `return_trace`, and the failure
counts only if a traced call refused with `{error, limit}` after the last
success, and the error is `exhaustion`/`memory_limit`, or `malformed`/
`internal` carrying `{error, {snapshot_restore_grow_failed, page_limit}}`.
A restored memory takes its pages when it writes them, so the refusal can
also come during the call: an `exhaustion`/`memory_limit` the call's error
carries, at any depth of `{error, _}` and `ctx := #{error := _}`, at any
stage after the restore. The result is the number of live, verified
instances.
""".

-export([main/1]).

-define(CACHE, "_build/imagecache").
-define(IMAGES, "_build/densitybench/images").
-define(PT, {?MODULE, image}).
-define(ACK_MS, 60_000).
-define(WORKER_TIMEOUT, 120_000).
-define(HANDOFF_MS, 20_000).
-define(EXPIRY_MS, 35_000).

main([Sub | Args]) ->
    try
        Out = run(Sub, Args),
        io:format("~p~n", [printed(Out)])
    catch C:R:S -> io:format("failed: ~p~n~p~n", [{C, R}, S])
    end,
    erlang:halt(0).

run("sharing", [G, K, Raw]) ->
    record(Raw, sharing(list_to_atom(G), list_to_integer(K)));
run("workers", [G, N, Ahead, Raw]) ->
    record(Raw, workers(list_to_atom(G), list_to_integer(N), onoff(Ahead),
                        busy));
run("expiry", [G, N, Raw]) ->
    record(Raw, workers(list_to_atom(G), list_to_integer(N), false, expiry));
run("density", [G, Raw]) ->
    record(Raw, density(list_to_atom(G)));
run("pool", [G, N, Raw]) ->
    record(Raw, pool(list_to_atom(G), list_to_integer(N)));
run("capture", [G, N, Raw]) ->
    record(Raw, capture(list_to_atom(G), list_to_integer(N)));
run("copy", [G, K, Raw]) ->
    record(Raw, copy(list_to_atom(G), list_to_integer(K)));
run("churn", [G, N, C, Per, Cache, Raw]) ->
    record(Raw, churn(list_to_atom(G), list_to_integer(N), list_to_atom(C),
                      list_to_integer(Per), Cache)).

%% What is printed: the full term goes to the raw file, and here every
%% `erlang:memory/0' list is cut to its total.
printed(Out) ->
    maps:map(fun(_, [{total, T} | _]) -> {total, T};
                (_, V) -> V
             end, maps:without([meta], Out)).

onoff("on") -> true;
onoff("off") -> false.

record(Raw, Result) ->
    ok = reactorlib:write_raw(case Raw of "none" -> none; P -> P end, Result),
    Result.

%%% -------------------------------------------------------------- sharing ---

sharing(Name, K) ->
    ok = reactorlib:page_limit(65536),
    Meta = reactorlib:meta(),
    io:format("# ~s~n", [maps:get(uptime, Meta)]),
    {ok, G} = reactorlib:guest(Name),
    {ok, Image} = reactorlib:image(G, ?CACHE),
    persistent_term:put(?PT, Image),
    {ok, _, W} = reactorlib:request(G, Image),
    ok = reactorlib:finish(W),
    Bytes = maps:get(bytes, wasm:snapshot_info(Image)),
    true = erlang:garbage_collect(),
    P0 = wasm_engine:pages_in_use(),
    M0 = erlang:memory(),
    Self = self(),
    Ps = [spawn_monitor(fun() -> holder(Self, G) end) || _ <- lists:seq(1, K)],
    Acks = acks([P || {P, _} <- Ps], ?ACK_MS),
    M1 = erlang:memory(),
    P1 = wasm_engine:pages_in_use(),
    [P ! collect || {P, _} <- Ps],
    _ = [receive {collected, P} -> ok after ?ACK_MS -> ok end
         || {P, _} <- Ps],
    M2 = erlang:memory(),
    teardown(Ps),
    Total = fun(M) -> proplists:get_value(total, M) end,
    Base = #{arm => sharing, guest => Name, k => K, meta => Meta,
             image_bytes => Bytes, page_limit => wasm_engine:page_limit(),
             pages_before => P0, pages_after => P1,
             charged_pages_per_instance => (P1 - P0) / K,
             memory_before => M0, memory_held => M1, memory_collected => M2},
    case Acks of
        ok ->
            Base#{verdict => ok,
                  delta_per_instance => (Total(M1) - Total(M0)) / K,
                  collected_delta_per_instance =>
                      (Total(M2) - Total(M0)) / K};
        {void, Why} ->
            io:format("VOID: ~p~n", [Why]),
            Base#{verdict => void, why => Why}
    end.

%% Restore, serve, check, acknowledge, hold.
holder(Parent, G) ->
    Image = persistent_term:get(?PT),
    case reactorlib:request(G, Image) of
        {ok, R, Inst} ->
            case R =:= reactorlib:expected(G) of
                true -> Parent ! {held, self(), ok};
                false -> Parent ! {held, self(), {wrong, R}}
            end,
            hold(Parent, Inst);
        Other ->
            Parent ! {held, self(), {failed, Other}}
    end.

hold(Parent, Inst) ->
    receive
        collect ->
            true = erlang:garbage_collect(),
            Parent ! {collected, self()},
            hold(Parent, Inst);
        stop ->
            ok = reactorlib:finish(Inst)
    end.

acks(Ps, Ms) ->
    Until = erlang:monotonic_time(millisecond) + Ms,
    acks(Ps, Until, []).

acks([], _Until, []) -> ok;
acks([], _Until, Bad) -> {void, {bad_results, Bad}};
acks([P | Rest], Until, Bad) ->
    Left = max(0, Until - erlang:monotonic_time(millisecond)),
    receive
        {held, P, ok} -> acks(Rest, Until, Bad);
        {held, P, Why} -> acks(Rest, Until, [Why | Bad])
    after Left -> {void, {timeout, length(Rest) + 1}}
    end.

teardown(Ps) ->
    [P ! stop || {P, _} <- Ps],
    [receive {'DOWN', M, process, P, _} -> ok
     after ?ACK_MS -> exit(P, kill)
     end || {P, M} <- Ps],
    ok.

%%% -------------------------------------------------------------- workers ---

workers(Name, N, Ahead, Mode) ->
    ok = reactorlib:page_limit(65536),
    Meta = reactorlib:meta(),
    io:format("# ~s~n", [maps:get(uptime, Meta)]),
    ok = filelib:ensure_path(?IMAGES),
    ok = application:set_env(wasm, snapshot_dir, filename:absname(?IMAGES)),
    {ok, G} = reactorlib:guest(Name),
    Expected = reactorlib:expected(G),
    Request = maps:get(request, G),
    {ok, Image} = reactorlib:image(G, ?CACHE),
    Bytes = maps:get(bytes, wasm:snapshot_info(Image)),
    C0 = charged(),
    {Adapter, Opts0} = reactorlib:worker_opts(Name, ?WORKER_TIMEOUT),
    Opts = (stock_floor(Adapter, Opts0))#{under => Adapter,
                                          harness => self(),
                                          restore_ahead => Ahead},
    Recycles = recycles(),
    Rows0 = image_rows(),
    Ws = start_workers(Opts, N),
    C1 = charged(),
    Gens = stable_generations(Rows0, 50),
    Base = #{arm => workers, mode => Mode, guest => Name, n => N,
             restore_ahead => Ahead, meta => Meta, image_bytes => Bytes,
             recycling => Recycles, pooled => pooled(),
             images_charged => C1 - C0,
             distinct_images => (C1 - C0) / Bytes,
             image_rows => length(Gens),
             holders => [H || {_, H} <- Gens]},
    R = try workers_1(Ws, Request, Expected, Ahead, Recycles, Mode, Base)
        catch throw:{void, Why} ->
                io:format("VOID: ~p~n", [Why]),
                Base#{verdict => void, why => Why}
        end,
    [begin unlink(W), wasm_script_worker:stop(W) end || W <- Ws],
    R.

workers_1(Ws, Request, Expected, Ahead, Recycles, Mode, Base) ->
    N = length(Ws),
    %% Warm: one request each, released at once.
    Warm = serve(Ws, Request, release),
    ok = all_expected(warm, Warm, Expected),
    %% The first to finish bounds the handoff window, the last the expiry.
    Times = [T || {_, T, _} <- Warm],
    Idle = idle_check(Ws, Ahead, Recycles),
    true = erlang:garbage_collect(),
    MIdle = erlang:memory(),
    PIdle = wasm_engine:pages_in_use(),
    B1 = Base#{idle => Idle, memory_idle => MIdle, pages_idle => PIdle},
    Kept = Idle =:= recycle_rows,
    case Mode of
        expiry -> expiry(Ws, lists:max(Times), Kept, B1);
        busy -> busy(Ws, Request, Expected, Kept, lists:min(Times), N, B1)
    end.

busy(Ws, Request, Expected, Handoff, WarmDone, N, B1) ->
    Pre = case Handoff of
              true ->
                  Since = erlang:monotonic_time(millisecond) - WarmDone,
                  Since < ?HANDOFF_MS orelse
                      throw({void, {handoff_late_ms, Since}}),
                  Missing = [W || W <- Ws, recycle_rows(W) =:= 0],
                  Missing =:= [] orelse
                      throw({void, {recycle_rows_missing, length(Missing)}}),
                  #{since_warm_ms => Since};
              false ->
                  skipped
          end,
    Self = self(),
    Callers = [spawn_link(fun() ->
                                  Self ! {done, W, submit_run(W, Request)}
                          end) || W <- Ws],
    Runners = readies(N, ?WORKER_TIMEOUT),
    At = case Handoff of
             true -> barrier_check(Ws, Runners);
             false -> skipped
         end,
    true = erlang:garbage_collect(),
    MBusy = erlang:memory(),
    PBusy = wasm_engine:pages_in_use(),
    [R ! go || R <- Runners],
    Done = [receive {done, W, Res} -> {W, 0, Res} end || W <- Ws],
    _ = Callers,
    ok = all_expected(busy, Done, Expected),
    Total = fun(M) -> proplists:get_value(total, M) end,
    B1#{verdict => ok, handoff_before => Pre, handoff_at_barrier => At,
        memory_busy => MBusy, pages_busy => PBusy,
        busy_increment_per_worker =>
            (Total(MBusy) - Total(maps:get(memory_idle, B1))) / N,
        charged_pages_per_worker =>
            (PBusy - maps:get(pages_idle, B1)) / N}.

expiry(Ws, WarmDone, Kept, B1) ->
    Wait = WarmDone + ?EXPIRY_MS - erlang:monotonic_time(millisecond),
    Wait > 0 andalso receive after Wait -> ok end,
    true = erlang:garbage_collect(),
    M = erlang:memory(),
    Left = case Kept of
               true -> lists:sum([recycle_rows(W) || W <- Ws]);
               false -> no_recycling
           end,
    Total = fun(X) -> proplists:get_value(total, X) end,
    B1#{verdict => ok, memory_after_35s => M,
        pages_after_35s => wasm_engine:pages_in_use(),
        recycle_rows_left => Left,
        idle_drop_per_worker =>
            (Total(maps:get(memory_idle, B1)) - Total(M)) / length(Ws)}.

%% One request per worker, each from its own caller. `release' answers every
%% barrier at once; the result is `{W, DoneAtMs, Result}'.
serve(Ws, Request, release) ->
    Self = self(),
    _ = [spawn_link(fun() ->
                            Self ! {done, W, submit_run(W, Request)} end)
         || W <- Ws],
    release_loop(length(Ws), []).

release_loop(0, Acc) -> Acc;
release_loop(Left, Acc) ->
    receive
        {ready, R} ->
            R ! go,
            release_loop(Left, Acc);
        {done, W, Res} ->
            release_loop(Left - 1,
                         [{W, erlang:monotonic_time(millisecond), Res} | Acc])
    after ?WORKER_TIMEOUT -> throw({void, {warm_timeout, Left}})
    end.

submit_run(W, Request) -> wasm_script_worker:run(W, Request).

readies(N, Ms) ->
    Until = erlang:monotonic_time(millisecond) + Ms,
    readies(N, Until, []).

readies(0, _Until, Acc) -> Acc;
readies(N, Until, Acc) ->
    Left = max(0, Until - erlang:monotonic_time(millisecond)),
    receive
        {ready, R} -> readies(N - 1, Until, [R | Acc]);
        {done, W, Res} -> throw({void, {finished_before_barrier, W, Res}})
    after Left -> throw({void, {barrier_timeout, N}})
    end.

all_expected(Phase, Rs, Expected) ->
    Bad = [{W, Res} || {W, _, Res} <- Rs,
                       not matches(Res, Expected)],
    Bad =:= [] orelse throw({void, {Phase, wrong_results, length(Bad),
                                    hd(Bad)}}),
    ok.

matches({ok, #{result := R}}, Expected) -> R =:= Expected;
matches(_, _) -> false.

%% The stock adapter's own runner floor, which `barrier_adapter' cannot
%% supply through `defaults/1'. A caller's option wins as it would anyway.
stock_floor(Adapter, Opts) ->
    D = case erlang:function_exported(Adapter, defaults, 1) of
            true -> Adapter:defaults(maps:get(limits, Opts));
            false -> #{}
        end,
    maps:merge(maps:with([runner_min_heap_words], D), Opts).

%% From one prepared image where the build has `prepare/2'. Otherwise one at
%% a time for the first, so the image is captured once and filed; the rest
%% read it, as `reqbench' does.
start_workers(Opts, N) ->
    case pooled() of
        true ->
            {ok, P} = wasm_script_worker:prepare(barrier_adapter, Opts),
            Ws = [W || {W, _} <- start_together(barrier_adapter,
                                                Opts#{prepared => P}, N,
                                                erlang:monotonic_time(
                                                  millisecond))],
            ok = wasm_script_worker:release_prepared(P),
            Ws;
        false ->
            {ok, W1} = wasm_script_worker:start_link(barrier_adapter, Opts),
            [W1 | [W || {W, _} <- start_together(
                                     barrier_adapter, Opts, N - 1,
                                     erlang:monotonic_time(millisecond))]]
    end.

%% Whether this build prepares one image for a pool.
pooled() ->
    {module, _} = code:ensure_loaded(wasm_script_worker),
    erlang:function_exported(wasm_script_worker, prepare, 2).

%% A pool of N, the way this build runs one: prepared once and started from
%% it, or started together. Answers the workers, each with the milliseconds
%% from `T0' to its start returning, and the prepared image or `none'.
start_pool(Adapter, Opts, N, T0) ->
    case pooled() of
        true ->
            {ok, P} = wasm_script_worker:prepare(Adapter, Opts),
            {start_together(Adapter, Opts#{prepared => P}, N, T0), P};
        false ->
            {start_together(Adapter, Opts, N, T0), none}
    end.

release_pool(none) -> ok;
release_pool(P) -> wasm_script_worker:release_prepared(P).

%% N workers, each started from its own process at once; each answer is the
%% worker and the milliseconds from `T0' to its start returning.
start_together(Adapter, Opts, N, T0) ->
    Self = self(),
    Ps = [spawn_link(fun() ->
                             {ok, W} = wasm_script_worker:start_link(Adapter,
                                                                     Opts),
                             unlink(W),
                             Self ! {up, self(), W,
                                     erlang:monotonic_time(millisecond) - T0}
                     end) || _ <- lists:seq(1, N)],
    [receive {up, P, W, T} -> link(W), {W, T} end || P <- Ps].

%%% ------------------------------------------------------- idle and handoff ---

%% Whether this build recycles, read from the code rather than inferred from
%% rows that might simply be missing.
recycles() ->
    {module, wasm_snapshot} = code:ensure_loaded(wasm_snapshot),
    erlang:function_exported(wasm_snapshot, take_recycled, 1).

idle_check(Ws, true, _Recycles) ->
    Missing = [W || W <- Ws, not inspect(fun() -> ahead_ready(W, 6000) end)],
    Missing =:= [] orelse throw({void, {ahead_not_ready, length(Missing)}}),
    ahead_ready;
idle_check(Ws, false, true) ->
    Missing = [W || W <- Ws,
                    not inspect(fun() -> poll(fun() -> recycle_rows(W) > 0 end,
                                              500) end)],
    case length(Missing) of
        0 -> recycle_rows;
        %% A request that wrote every chunk leaves nothing to keep, and the
        %% kernel then reserves nothing (`wasm_script_worker:keep/3'). With
        %% no row on any worker this guest does not recycle on this build.
        N when N =:= length(Ws) -> no_recycling;
        N -> throw({void, {recycle_rows_missing, N}})
    end;
idle_check(_Ws, false, false) ->
    no_recycling.

%% Adapted from `wasm_worker_kernel_SUITE:waiting/2': between requests the
%% worker monitors exactly one process, its runner, and the runner has an
%% instance waiting once `wasm_worker_ahead' is in its dictionary.
ahead_ready(_W, 0) -> false;
ahead_ready(W, N) ->
    Ready = case process_info(W, monitors) of
                {monitors, [{process, Runner}]} ->
                    case process_info(Runner, dictionary) of
                        {dictionary, D} -> lists:keymember(wasm_worker_ahead,
                                                           1, D);
                        undefined -> false
                    end;
                _ ->
                    false
            end,
    Ready orelse begin timer:sleep(10), ahead_ready(W, N - 1) end.

poll(_F, 0) -> false;
poll(F, N) -> F() orelse begin timer:sleep(10), poll(F, N - 1) end.

%% At the barrier, for every held runner: it has released the recycled
%% reservation into its restore, and its instance's rows are held under an
%% instance token it owns; and no worker still has a `{recycle, _}' row.
barrier_check(Ws, Runners) ->
    Left = lists:sum([recycle_rows(W) || W <- Ws]),
    Left =:= 0 orelse throw({void, {recycle_rows_at_barrier, Left}}),
    NotReleased = [R || R <- Runners, not inspect(fun() -> released(R) end)],
    NotReleased =:= [] orelse
        throw({void, {not_released, length(NotReleased)}}),
    NoRows = [R || R <- Runners, instance_rows(R) =:= 0],
    NoRows =:= [] orelse throw({void, {no_instance_rows, length(NoRows)}}),
    #{recycle_rows => 0, released => length(Runners)}.

released(R) ->
    case process_info(R, dictionary) of
        {dictionary, D} ->
            proplists:get_value({wasm_script_worker, released}, D) =:= true;
        undefined ->
            false
    end.

recycle_rows(W) ->
    inspect(fun() -> held_by(fun({recycle, _}) -> true; (_) -> false end,
                             W) end).

instance_rows(R) ->
    inspect(fun() -> held_by(fun({instance, _}) -> true; (_) -> false end,
                             R) end).

%% Rows of `wasm_holders' with a holder whose token matches and whose owner
%% is `Owner'. A row is `{Res, Meta, Pages, Holders}' or has a fifth element;
%% the holders are found as whichever map elements the row has, so either
%% shape is read without assuming which.
held_by(TokenP, Owner) ->
    length([Row || Row <- ets:tab2list(wasm_holders),
                   is_tuple(Row), tuple_size(Row) >= 4,
                   lists:any(fun(Hs) ->
                                     lists:any(fun({T, O}) ->
                                                       O =:= Owner
                                                           andalso TokenP(T);
                                                  (_) -> false
                                               end, maps:to_list(Hs))
                             end,
                             [E || E <- tl(tuple_to_list(Row)),
                                   is_map(E)])]).

%% Every check in a short-lived process, so nothing it copied stays here.
inspect(F) ->
    Self = self(),
    Ref = make_ref(),
    {P, M} = spawn_monitor(fun() -> Self ! {Ref, F()} end),
    receive
        {Ref, R} -> receive {'DOWN', M, process, P, _} -> R end;
        {'DOWN', M, process, P, Why} -> exit({inspect_died, Why})
    end.

charged() ->
    {module, _} = code:ensure_loaded(wasm_snapshot_owner),
    case erlang:function_exported(wasm_snapshot_owner, charged, 0) of
        true -> wasm_snapshot_owner:charged();
        false -> 0
    end.

%%% ----------------------------------------------------------------- pool ---

pool(Name, N) ->
    ok = reactorlib:page_limit(65536),
    Meta = reactorlib:meta(),
    io:format("# ~s~n", [maps:get(uptime, Meta)]),
    ok = filelib:ensure_path(?IMAGES),
    ok = application:set_env(wasm, snapshot_dir, filename:absname(?IMAGES)),
    {ok, G} = reactorlib:guest(Name),
    {Adapter, Opts} = reactorlib:worker_opts(Name, ?WORKER_TIMEOUT),
    C0 = charged(),
    {ok, W0} = wasm_script_worker:start_link(Adapter, Opts),
    unlink(W0),
    ok = wasm_script_worker:stop(W0),
    ok = until_charged(C0, 30_000),
    T0 = erlang:monotonic_time(millisecond),
    {Up, P} = start_pool(Adapter, Opts, N, T0),
    Wall = erlang:monotonic_time(millisecond) - T0,
    Ws = [W || {W, _} <- Up],
    Rs = [{W, 0, wasm_script_worker:run(W, maps:get(request, G))} || W <- Ws],
    Base = #{arm => pool, guest => Name, n => N, meta => Meta,
             pooled => pooled(), wall_ms => Wall,
             start_ms => lists:sort([T || {_, T} <- Up])},
    R = try ok = all_expected(pool, Rs, reactorlib:expected(G)),
            Base#{verdict => ok}
        catch throw:{void, Why} -> Base#{verdict => void, why => Why}
        end,
    ok = release_pool(P),
    [begin unlink(W), wasm_script_worker:stop(W) end || W <- Ws],
    R.

until_charged(_C0, Ms) when Ms =< 0 -> throw({void, still_charged});
until_charged(C0, Ms) ->
    case charged() =< C0 of
        true -> ok;
        false -> timer:sleep(20), until_charged(C0, Ms - 20)
    end.

%%% -------------------------------------------------------------- capture ---

capture(Name, N) ->
    ok = reactorlib:page_limit(65536),
    Meta = reactorlib:meta(),
    io:format("# ~s~n", [maps:get(uptime, Meta)]),
    Dir = filename:absname(
            lists:flatten(io_lib:format("_build/densitybench/capture-~s-~p",
                                        [os:getpid(),
                                         os:system_time(microsecond)]))),
    [] = filelib:wildcard(filename:join(Dir, "*")),
    ok = filelib:ensure_path(Dir),
    ok = application:set_env(wasm, snapshot_dir, Dir),
    {ok, G} = reactorlib:guest(Name),
    {Adapter, Opts} = reactorlib:worker_opts(Name, ?WORKER_TIMEOUT),
    Rows0 = image_rows(),
    {module, wasm_snapshot} = code:ensure_loaded(wasm_snapshot),
    1 = erlang:trace_pattern({wasm_snapshot, capture, 3}, true, [call_count]),
    T0 = erlang:monotonic_time(millisecond),
    {Up, P} = start_pool(Adapter, Opts, N, T0),
    Wall = erlang:monotonic_time(millisecond) - T0,
    {call_count, Captures} =
        erlang:trace_info({wasm_snapshot, capture, 3}, call_count),
    _ = erlang:trace_pattern({wasm_snapshot, capture, 3}, false, [call_count]),
    Gens = stable_generations(Rows0, 50),
    Ws = [W || {W, _} <- Up],
    Rs = [{W, 0, wasm_script_worker:run(W, maps:get(request, G))} || W <- Ws],
    Base = #{arm => capture, guest => Name, n => N, meta => Meta,
             pooled => pooled(), wall_ms => Wall, captures => Captures,
             files => length(filelib:wildcard(filename:join(Dir, "*.img"))),
             generations => length(Gens), holders => [H || {_, H} <- Gens]},
    R = try ok = all_expected(capture, Rs, reactorlib:expected(G)),
            Base#{verdict => ok}
        catch throw:{void, Why} -> Base#{verdict => void, why => Why}
        end,
    ok = release_pool(P),
    [begin unlink(W), wasm_script_worker:stop(W) end || W <- Ws],
    R.

%% The image rows made since `Rows0', each with its owner's holder count,
%% once two reads 200 ms apart agree.
stable_generations(Rows0, 0) ->
    generations(Rows0);
stable_generations(Rows0, N) ->
    A = generations(Rows0),
    timer:sleep(200),
    case generations(Rows0) of
        A -> A;
        _ -> stable_generations(Rows0, N - 1)
    end.

generations(Rows0) ->
    lists:sort([{Res, holders_of_owner(H)}
                || {Res, H} <- image_rows(), not lists:keymember(Res, 1, Rows0)]).

image_rows() ->
    [{element(1, R), element(4, R)}
     || R <- ets:tab2list(wasm_holders), is_tuple(R), tuple_size(R) >= 4,
        is_tuple(element(2, R)), element(1, element(2, R)) =:= image,
        is_map(element(4, R))].

holders_of_owner(Holders) ->
    case [O || {{snapshot, _}, O} <- maps:to_list(Holders), is_pid(O)] of
        [Owner] -> wasm_snapshot_owner:holders(Owner);
        _ -> no_owner
    end.

%%% ----------------------------------------------------------------- copy ---

copy(Name, K) ->
    ok = reactorlib:page_limit(65536),
    Meta = reactorlib:meta(),
    io:format("# ~s~n", [maps:get(uptime, Meta)]),
    ok = filelib:ensure_path(?IMAGES),
    ok = application:set_env(wasm, snapshot_dir, filename:absname(?IMAGES)),
    {Adapter, Opts} = reactorlib:worker_opts(Name, ?WORKER_TIMEOUT),
    {ok, W} = wasm_script_worker:start_link(Adapter, Opts),
    [Image] = [E || E <- tuple_to_list(sys:get_state(W)),
                    is_tuple(E), tuple_size(E) > 0,
                    element(1, E) =:= snapshot],
    Words = erts_debug:flat_size(Image),
    _ = [spawn_us(Image) || _ <- lists:seq(1, 10)],
    Us = lists:sort([spawn_us(Image) || _ <- lists:seq(1, K)]),
    unlink(W),
    ok = wasm_script_worker:stop(W),
    #{arm => copy, guest => Name, k => K, meta => Meta, verdict => ok,
      image_words => Words, image_bytes => maps:get(bytes,
                                                    wasm:snapshot_info(Image)),
      spawn_p50_us => pct(Us, 50), spawn_min_us => hd(Us), samples => Us}.

%% From before the `spawn' to the child's first instruction, with the image
%% in the closure so the spawn copies it.
spawn_us(Image) ->
    Self = self(),
    true = erlang:garbage_collect(),
    T0 = erlang:monotonic_time(nanosecond),
    Pid = spawn(fun() ->
                        T1 = erlang:monotonic_time(nanosecond),
                        Self ! {began, self(), T1, element(1, Image)}
                end),
    receive {began, Pid, T1, snapshot} -> (T1 - T0) / 1000 end.

%%% ---------------------------------------------------------------- churn ---

-define(CHURN_MS, 500).
-define(SAMPLE_MS, 100).
-define(ENTRY_DEADLINE_S, 25 * 60).

churn(Name, N, ChurnName, Per, Cache) ->
    _ = application:load(wasm),
    ok = application:set_env(wasm, code_cache_dir, filename:absname(Cache)),
    ok = reactorlib:page_limit(65536),
    Meta = reactorlib:meta(),
    io:format("# ~s~n", [maps:get(uptime, Meta)]),
    ok = filelib:ensure_path(?IMAGES),
    ok = application:set_env(wasm, snapshot_dir, filename:absname(?IMAGES)),
    {ok, G} = reactorlib:guest(Name),
    Request = maps:get(request, G),
    Expected = reactorlib:expected(G),
    {Adapter, Opts0} = reactorlib:worker_opts(Name, ?WORKER_TIMEOUT),
    Limits = maps:get(limits, Opts0),
    Opts = Opts0#{compiled => true, limits => Limits#{fuel => infinity}},
    %% The image filed first, so the pool starts as it would in production.
    {ok, W0} = wasm_script_worker:start_link(Adapter, Opts),
    unlink(W0),
    ok = wasm_script_worker:stop(W0),
    {Up, P} = start_pool(Adapter, Opts, N, erlang:monotonic_time(millisecond)),
    Ws = [W || {W, _} <- Up],
    Deadline = erlang:monotonic_time(second) + ?ENTRY_DEADLINE_S,
    Entered = [until_generated(W, Request, Expected, Deadline, 0) || W <- Ws],
    Base = #{arm => churn, guest => Name, n => N, churn_guest => ChurnName,
             per_worker => Per, meta => Meta, pooled => pooled(),
             entered => Entered},
    R = case [E || {never, _} = E <- Entered] of
            [] -> churn_1(Ws, Request, Expected, ChurnName, Per, Base);
            Never -> Base#{verdict => void, why => {never_entered, Never}}
        end,
    ok = release_pool(P),
    [begin unlink(W), wasm_script_worker:stop(W) end || W <- Ws],
    R.

churn_1(Ws, Request, Expected, ChurnName, Per, Base) ->
    _ = burst(Ws, Request, Expected, 2),
    Self = self(),
    Churner = start_churner(Self, ChurnName),
    Sampler = spawn_link(fun() -> sample(Self, 0, []) end),
    T0 = erlang:monotonic_time(nanosecond),
    Ts = burst(Ws, Request, Expected, Per),
    Wall = (erlang:monotonic_time(nanosecond) - T0) / 1.0e6,
    Cycles = stop_churner(Self, Churner),
    Sampler ! {stop, Self},
    {Peak, Samples} = receive {peak, Sampler, Pk, S} -> {Pk, S} end,
    Sorted = lists:sort(Ts),
    Base#{verdict => ok, wall_ms => Wall, rps => length(Ts) / (Wall / 1000),
          p50_us => pct(Sorted, 50), p99_us => pct(Sorted, 99),
          peak_memory => Peak, memory_samples => Samples,
          churn_cycles => Cycles, samples => Ts}.

start_churner(_Self, none) ->
    none;
start_churner(Self, ChurnName) ->
    {CA, COpts} = reactorlib:worker_opts(ChurnName, ?WORKER_TIMEOUT),
    {ok, C0} = wasm_script_worker:start_link(CA, COpts),
    unlink(C0),
    ok = wasm_script_worker:stop(C0),
    timer:sleep(1_000),
    spawn_link(fun() -> churner(Self, CA, COpts, 0) end).

stop_churner(_Self, none) ->
    0;
stop_churner(Self, Churner) ->
    Churner ! {stop, Self},
    receive {cycles, Churner, C} -> C end.

pct(Sorted, P) ->
    lists:nth(max(1, (length(Sorted) * P + 99) div 100), Sorted).

%% Every worker serves `Per' requests back to back, all at once; the answer
%% is every request's time in microseconds.
burst(Ws, Request, Expected, Per) ->
    Self = self(),
    _ = [spawn_link(fun() ->
                            Self ! {burst, self(),
                                    [timed(W, Request, Expected)
                                     || _ <- lists:seq(1, Per)]}
                    end) || W <- Ws],
    lists:append([receive {burst, _, T} -> T end || _ <- Ws]).

timed(W, Request, Expected) ->
    T0 = erlang:monotonic_time(nanosecond),
    R = wasm_script_worker:run(W, Request),
    T1 = erlang:monotonic_time(nanosecond),
    case matches(R, Expected) of
        true -> (T1 - T0) / 1000;
        false -> exit({wrong_result, R})
    end.

sample(Owner, Peak, Acc) ->
    M = erlang:memory(total),
    receive
        {stop, Owner} ->
            Owner ! {peak, self(), max(Peak, M), lists:reverse([M | Acc])}
    after ?SAMPLE_MS ->
        sample(Owner, max(Peak, M), [M | Acc])
    end.

%% One pool of one worker of the churn guest started and stopped every
%% 500 ms, the way this build runs a pool.
churner(Owner, Adapter, Opts, N) ->
    Next = erlang:monotonic_time(millisecond) + ?CHURN_MS,
    {[{W, _}], P} = start_pool(Adapter, Opts, 1,
                                erlang:monotonic_time(millisecond)),
    unlink(W),
    ok = wasm_script_worker:stop(W),
    ok = release_pool(P),
    Wait = max(0, Next - erlang:monotonic_time(millisecond)),
    receive
        {stop, Owner} -> Owner ! {cycles, self(), N + 1}
    after Wait ->
        churner(Owner, Adapter, Opts, N + 1)
    end.

%% As `requestbench': the loop ends at the first request during which a
%% generated `wasm_f_' function of a slot module was called.
until_generated(W, R, E, Deadline, N) ->
    case erlang:monotonic_time(second) >= Deadline of
        true -> {never, N};
        false -> traced(W, R, E, Deadline, N)
    end.

traced(W, R, E, Deadline, N) ->
    Self = self(),
    Tracer = spawn_link(fun() -> generated_calls(Self, false) end),
    Mods = wasm_code_slots:slots(),
    [erlang:trace_pattern({Mod, '_', '_'}, true, [local]) || Mod <- Mods],
    _ = erlang:trace(all, true, [call, {tracer, Tracer}]),
    Got = wasm_script_worker:run(W, R),
    _ = erlang:trace(all, false, [call]),
    [erlang:trace_pattern({Mod, '_', '_'}, false, [local]) || Mod <- Mods],
    Tracer ! {done, Self},
    Seen = receive {seen, Tracer, S} -> S end,
    matches(Got, E) orelse exit({wrong_result, Got}),
    case Seen of
        true -> {entered, N + 1};
        false -> until_generated(W, R, E, Deadline, N + 1)
    end.

generated_calls(Owner, Seen) ->
    receive
        {trace, _, call, {Mod, F, _}} ->
            Generated = lists:prefix("wasm_code_", atom_to_list(Mod))
                andalso lists:prefix("wasm_f_", atom_to_list(F)),
            generated_calls(Owner, Seen orelse Generated);
        {done, Owner} ->
            Owner ! {seen, self(), Seen}
    end.

%%% -------------------------------------------------------------- density ---

density(Name) ->
    ok = reactorlib:page_limit(4096),
    Meta = reactorlib:meta(),
    io:format("# ~s~n", [maps:get(uptime, Meta)]),
    {ok, G} = reactorlib:guest(Name),
    {ok, Image} = reactorlib:image(G, ?CACHE),
    persistent_term:put(?PT, Image),
    T = start_tracer(),
    Self = self(),
    Result = fill(G, Self, T, 0, []),
    erlang:trace_pattern({wasm_engine, reserve_pages, 1}, false, [local]),
    _ = erlang:trace(all, false, [call]),
    Base = #{arm => density, guest => Name, meta => Meta,
             page_limit => wasm_engine:page_limit(),
             image_bytes => maps:get(bytes, wasm:snapshot_info(Image))},
    R = maps:merge(Base, Result),
    Holders = maps:get(holders, Result),
    teardown(Holders),
    maps:remove(holders, R).

-define(DENSITY_CAP, 50_000).

fill(_G, _Self, _T, Count, Hs) when Count >= ?DENSITY_CAP ->
    #{verdict => void, why => {cap_reached, Count}, count => Count,
      holders => Hs};
fill(G, Self, T, Count, Hs) ->
    Mark = trace_count(T),
    {P, M} = spawn_monitor(fun() -> holder(Self, G) end),
    receive
        {held, P, ok} ->
            fill(G, Self, T, Count + 1, [{P, M} | Hs]);
        {held, P, {wrong, R}} ->
            #{verdict => void, why => {wrong_value, R}, count => Count,
              holders => [{P, M} | Hs]};
        {held, P, {failed, Failure}} ->
            receive {'DOWN', M, process, P, _} -> ok end,
            _ = trace_count(T),
            Log = trace_since(T, Mark),
            Refusals = [E || #{result := {error, limit}} = E <- Log],
            judge(Failure, Refusals, Count, Hs);
        {'DOWN', M, process, P, Why} ->
            #{verdict => void, why => {holder_died, Why}, count => Count,
              holders => Hs}
    after ?ACK_MS ->
            #{verdict => void, why => holder_timeout, count => Count,
              holders => [{P, M} | Hs]}
    end.

judge(Failure, Refusals, Count, Hs) ->
    Shape = budget_shape(Failure),
    Base = #{count => Count, failure => summary(Failure),
             refusals => Refusals, pages_in_use => wasm_engine:pages_in_use(),
             holders => Hs},
    case {Shape, Refusals} of
        {false, _} -> Base#{verdict => void, why => not_a_budget_refusal};
        {_, []} -> Base#{verdict => void, why => no_traced_refusal};
        {S, _} -> Base#{verdict => ok, shape => S}
    end.

budget_shape({error, restore, #{class := exhaustion, kind := memory_limit}}) ->
    memory_limit;
budget_shape({error, restore,
              #{class := malformed, kind := internal,
                ctx := #{exception :=
                             {error, {snapshot_restore_grow_failed,
                                      page_limit}}}}}) ->
    snapshot_restore_grow_failed;
%% A page fault refused by the budget during the call: the guest's write fails
%% with `exhaustion'/`memory_limit', which the call wraps (as a
%% `runtime_failure' whose `ctx' carries it) and the adapter's `decode'
%% reports. The traced `reserve_pages' refusal is still required by `judge/4'.
budget_shape({error, Stage, E}) when Stage =/= restore ->
    case carries_memory_limit(E, 8) of
        true -> memory_limit_in_call;
        false -> false
    end;
budget_shape(_) ->
    false.

carries_memory_limit(_E, 0) -> false;
carries_memory_limit(#{class := exhaustion, kind := memory_limit}, _D) -> true;
carries_memory_limit({error, E}, D) -> carries_memory_limit(E, D - 1);
carries_memory_limit(#{ctx := #{error := E}}, D) ->
    carries_memory_limit(E, D - 1);
carries_memory_limit(_E, _D) -> false.

summary({error, Stage, #{class := C, kind := K} = E}) ->
    {Stage, C, K, maps:get(exception, maps:get(ctx, E, #{}), none)};
summary(Other) ->
    Other.

%% The keeper boundary. Every call of `wasm_engine:reserve_pages/1', from any
%% process, with its argument and its answer, and the counter and the limit as
%% the tracer saw them on the return.
start_tracer() ->
    T = spawn_link(fun() -> tracer(#{}, 0, []) end),
    1 = erlang:trace_pattern({wasm_engine, reserve_pages, 1},
                             [{'_', [], [{return_trace}]}], [local]),
    _ = erlang:trace(all, true, [call, {tracer, T}]),
    T.

tracer(Pending, N, Log) ->
    receive
        {trace, Pid, call, {wasm_engine, reserve_pages, [Pages]}} ->
            tracer(Pending#{Pid => Pages}, N, Log);
        {trace, Pid, return_from, {wasm_engine, reserve_pages, 1}, R} ->
            E = #{n => maps:get(Pid, Pending, unknown), result => R,
                  pages_in_use => wasm_engine:pages_in_use(),
                  limit => wasm_engine:page_limit(), seq => N + 1},
            tracer(maps:remove(Pid, Pending), N + 1, [E | Log]);
        {count, From} ->
            From ! {count, self(), N},
            tracer(Pending, N, Log);
        {since, From, Mark} ->
            From ! {since, self(), [E || #{seq := S} = E <- lists:reverse(Log),
                                         S > Mark]},
            tracer(Pending, N, Log);
        _ ->
            tracer(Pending, N, Log)
    end.

%% After `erlang:trace_delivered/1' every trace message so far is in the
%% tracer's queue, so a request sent after it is answered after them.
trace_count(T) ->
    Ref = erlang:trace_delivered(all),
    receive {trace_delivered, all, Ref} -> ok end,
    T ! {count, self()},
    receive {count, T, N} -> N end.

trace_since(T, Mark) ->
    T ! {since, self(), Mark},
    receive {since, T, L} -> L end.
