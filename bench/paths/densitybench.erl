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

Guests are `py`, `qjs`, `lua` and `plain`; `workers` and `expiry` take the
first three. The last argument is the raw file, `none` for none. A round that
breaks the protocol prints `VOID` with the reason and still tears down.

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
The result is the number of live, verified instances.
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
    record(Raw, density(list_to_atom(G))).

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
    Ws = start_workers(Opts, N),
    C1 = charged(),
    Base = #{arm => workers, mode => Mode, guest => Name, n => N,
             restore_ahead => Ahead, meta => Meta, image_bytes => Bytes,
             recycling => Recycles,
             images_charged => C1 - C0,
             distinct_images => (C1 - C0) / Bytes},
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

%% One at a time for the first, so the image is captured once and filed; the
%% rest read it, as `reqbench' does.
start_workers(Opts, N) ->
    {ok, W1} = wasm_script_worker:start_link(barrier_adapter, Opts),
    Self = self(),
    Rest = [spawn_link(fun() ->
                               {ok, W} = wasm_script_worker:start_link(
                                           barrier_adapter, Opts),
                               unlink(W),
                               Self ! {up, self(), W}
                       end) || _ <- lists:seq(2, N)],
    [W1 | [receive {up, P, W} -> link(W), W end || P <- Rest]].

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
budget_shape(_) ->
    false.

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
