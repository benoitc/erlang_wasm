-module(keepcnt).
%% Profiling copy of requestbench `steady': same worker, same warm-up and
%% generated-code entry check, then N timed requests during which
%% wasm:restore/3, wasm:call/4 and wasm:destroy/1 are traced with monotonic
%% timestamps (call + return_trace), giving per-request wall time of each
%% phase. In a tree with wasm_prof_c, the counters are reset after warm-up and
%% read after the timed requests.
%%
%%   erl ... -run profreq main Guest Tier Cache N Raw
-export([main/1]).

-define(TIMEOUT, 120_000).
-define(IMAGES, "_build/requestbench/images").
-define(NCOUNTERS, 32).

main([Guest, Tier, Cache, N, Raw]) ->
    try
        R = run(list_to_atom(Guest), list_to_atom(Tier), Cache,
                list_to_integer(N)),
        io:format("~p~n", [maps:without([samples, phases_raw], R)]),
        case Raw of
            "none" -> ok;
            _ -> ok = file:write_file(Raw, io_lib:format("~p.~n", [R]),
                                      [append])
        end
    catch C:E:S -> io:format("failed: ~p~n~p~n", [{C, E}, S])
    end,
    erlang:halt(0).

run(Name, Tier, Cache, N) ->
    _ = application:load(wasm),
    case Cache of
        "none" -> ok;
        _ -> ok = application:set_env(wasm, code_cache_dir, Cache)
    end,
    ok = filelib:ensure_path(?IMAGES),
    ok = application:set_env(wasm, snapshot_dir, filename:absname(?IMAGES)),
    {ok, _} = application:ensure_all_started(wasm),
    {ok, G} = reactorlib:guest(Name),
    Request = maps:get(request, G),
    Expected = reactorlib:expected(G),
    {Adapter, Opts0} = reactorlib:worker_opts(Name, ?TIMEOUT),
    Opts1 = Opts0#{restore_ahead => false},
    Opts = case Tier of
               interp -> Opts1;
               compiled ->
                   L = maps:get(limits, Opts1),
                   Opts1#{compiled => true, limits => L#{fuel => infinity}}
           end,
    {ok, W} = wasm_script_worker:start_link(Adapter, Opts),
    Warm = case Tier of
               interp ->
                   _ = [timed(W, Request, Expected) || _ <- lists:seq(1, 20)],
                   20;
               compiled ->
                   {entered, K} = until_generated(
                                    W, Request, Expected,
                                    erlang:monotonic_time(second) + 25 * 60,
                                    0),
                   K
           end,
    Inst = code:which(wasm_prof_c) =/= non_existing,
    C = case Inst of
            true ->
                Ctr = counters:new(?NCOUNTERS, [write_concurrency]),
                persistent_term:put(wasm_prof_counters, Ctr),
                Ctr;
            false -> undefined
        end,
    KMFAs = [{wasm_keeper, call, 1}, {wasm_keeper, ack, 2},
             {wasm_keeper, reserve, 4}, {wasm_keeper, release_all, 1},
             {wasm_keeper, release, 2}, {wasm_keeper, arena_begin, 4},
             {wasm_keeper, image_reserve, 3}],
    _ = [code:ensure_loaded(wasm_keeper)],
    KOn = [MFA || {M, F, A} = MFA <- KMFAs,
                  erlang:function_exported(M, F, A)],
    [erlang:trace_pattern(MFA, true, [call_count]) || MFA <- KOn],
    Tr = start_phase_trace(),
    T0 = erlang:monotonic_time(nanosecond),
    Ts = [timed(W, Request, Expected) || _ <- lists:seq(1, N)],
    Wall = erlang:monotonic_time(nanosecond) - T0,
    KC = [{F, case erlang:trace_info(MFA, call_count) of
                  {call_count, C0} when is_integer(C0) -> C0 / N;
                  _ -> undefined
              end} || {_, F, _} = MFA <- KOn],
    [erlang:trace_pattern(MFA, false, [call_count]) || MFA <- KOn],
    Phases = stop_phase_trace(Tr),
    Counts = case C of
                 undefined -> #{};
                 _ -> maps:from_list([{I, counters:get(C, I)}
                                      || I <- lists:seq(1, ?NCOUNTERS),
                                         counters:get(C, I) =/= 0])
             end,
    unlink(W),
    ok = wasm_script_worker:stop(W),
    PerReq = maps:map(fun(_K, V) -> V / N end, Counts),
    #{guest => Name, tier => Tier, n => N, warm => Warm,
      tree => element(2, file:get_cwd()),
      uptime => os:cmd("uptime") -- "\n",
      median_us => med(Ts), min_us => lists:min(Ts), samples => Ts,
      wall_ms => Wall / 1.0e6,
      phases => maps:map(fun(_K, L) -> #{n => length(L), median_us => med(L),
                                         sum_ms => lists:sum(L) / 1000}
                         end, Phases),
      phases_raw => Phases,
      counts_per_req => PerReq, counts => Counts,
      jit => wasm_jit:counts(), keeper_per_req => KC}.

med([]) -> undefined;
med(L) -> lists:nth((length(L) + 1) div 2, lists:sort(L)).

timed(W, Request, Expected) ->
    T0 = erlang:monotonic_time(nanosecond),
    R = wasm_script_worker:run(W, Request),
    T1 = erlang:monotonic_time(nanosecond),
    case R of
        {ok, #{result := Expected}} -> (T1 - T0) / 1000;
        Other -> exit({wrong_result, Other})
    end.

%%% phase trace

-define(PHASES, [{wasm, restore, 3}, {wasm, call, 4}, {wasm, destroy, 1}]).

start_phase_trace() ->
    T = spawn(fun() -> ptracer(#{}, #{}) end),
    %% Only destroy is traced to its return: a restore's return value is an
    %% instance, which the trace message would copy.
    1 = erlang:trace_pattern({wasm, restore, 3}, true, [local]),
    1 = erlang:trace_pattern({wasm, call, 4}, true, [local]),
    1 = erlang:trace_pattern({wasm, destroy, 1},
                             [{'_', [], [{return_trace}]}], [local]),
    _ = erlang:trace(all, true, [call, monotonic_timestamp, {tracer, T}]),
    T.

stop_phase_trace(T) ->
    _ = erlang:trace(all, false, [call]),
    [erlang:trace_pattern(MFA, false, [local]) || MFA <- ?PHASES],
    Ref = erlang:trace_delivered(all),
    receive {trace_delivered, all, Ref} -> ok end,
    T ! {done, self()},
    receive {phases, T, P} -> P end.

%% Per runner: restore = restore call to first wasm:call call; call = first
%% wasm:call call to destroy call; destroy = destroy call to its return.
ptracer(Open, Acc) ->
    receive
        {trace_ts, Pid, call, {wasm, restore, _}, Ts} ->
            ptracer(Open#{Pid => {restore, Ts}}, Acc);
        {trace_ts, Pid, call, {wasm, call, _}, Ts} ->
            case maps:get(Pid, Open, none) of
                {restore, T0} ->
                    ptracer(Open#{Pid => {call, Ts}},
                            add(restore, Ts - T0, Acc));
                _ -> ptracer(Open, Acc)
            end;
        {trace_ts, Pid, call, {wasm, destroy, _}, Ts} ->
            case maps:get(Pid, Open, none) of
                {call, T0} ->
                    ptracer(Open#{Pid => {destroy, Ts}},
                            add(call, Ts - T0, Acc));
                _ -> ptracer(Open, Acc)
            end;
        {trace_ts, Pid, return_from, {wasm, destroy, 1}, _R, Ts} ->
            case maps:take(Pid, Open) of
                {{destroy, T0}, Open1} ->
                    ptracer(Open1, add(destroy, Ts - T0, Acc));
                _ -> ptracer(Open, Acc)
            end;
        {done, From} ->
            From ! {phases, self(), Acc};
        _ ->
            ptracer(Open, Acc)
    end.

add(K, Ns, Acc) -> Acc#{K => [Ns / 1000 | maps:get(K, Acc, [])]}.

%%% generated-code entry, as requestbench

until_generated(W, R, E, Deadline, N) ->
    true = erlang:monotonic_time(second) < Deadline,
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
    {ok, #{result := E}} = Got,
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
