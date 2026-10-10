-module(attrbench).
%% Scratch copy of bench/paths/requestbench.erl for the A4 attribution
%% (2026-10-09), with modes added: paced, sat, prof, tprof, bigword, count,
%% regions. split/steady/first are requestbench's, unchanged.

-export([main/1]).

-define(TIMEOUT, 120_000).
-define(IMAGES, "_build/requestbench/images").
-define(ENTRY_DEADLINE_S, 25 * 60).

%% 200 timed and 20 interpreted warm-up requests. `ARB_SMOKE` set to anything
%% makes them 3 and 2, for a smoke run that proves a harness works and is
%% never a sample.
samples() -> case os:getenv("ARB_SMOKE") of
                 false -> case os:getenv("ATTR_N") of
                              false -> 200;
                              N -> list_to_integer(N)
                          end;
                 _ -> 3
             end.
warm() -> case os:getenv("ARB_SMOKE") of false -> 20; _ -> 2 end.

main([Mode, Guest, Tier, Ahead, Cache, Raw]) ->
    try
        R = run(list_to_atom(Mode), list_to_atom(Guest), list_to_atom(Tier),
                Ahead =:= "on", Cache, Raw),
        io:format("~p~n", [maps:without([samples, meta], R)])
    catch C:E:S -> io:format("failed: ~p~n~p~n", [{C, E}, S])
    end,
    erlang:halt(0).

run(Mode, Name, Tier, Ahead, Cache, Raw) ->
    _ = application:load(wasm),
    case Cache of
        "none" -> ok;
        _ -> ok = application:set_env(wasm, code_cache_dir, Cache)
    end,
    ok = filelib:ensure_path(?IMAGES),
    ok = application:set_env(wasm, snapshot_dir, filename:absname(?IMAGES)),
    {ok, _} = application:ensure_all_started(wasm),
    Meta = reactorlib:meta(),
    {ok, G} = reactorlib:guest(Name),
    Request = maps:get(request, G),
    Expected = reactorlib:expected(G),
    {Adapter, Opts} = opts(Name, Tier, Ahead),
    T0 = erlang:monotonic_time(millisecond),
    {ok, W} = wasm_script_worker:start_link(Adapter, Opts),
    Started = erlang:monotonic_time(millisecond) - T0,
    Ahead andalso (ahead_ready(W, 6000) orelse exit(ahead_not_ready)),
    Base = #{mode => Mode, guest => Name, tier => Tier, ahead => Ahead,
             cache => Cache, start_ms => Started, meta => Meta},
    R = measure(Mode, Tier, W, Request, Expected, Base),
    unlink(W),
    ok = wasm_script_worker:stop(W),
    ok = reactorlib:write_raw(case Raw of "none" -> none; P -> P end, R),
    R.

opts(Name, Tier, Ahead) ->
    {Adapter, Opts0} = reactorlib:worker_opts(Name, ?TIMEOUT),
    Opts = Opts0#{restore_ahead => Ahead},
    case Tier of
        interp ->
            {Adapter, Opts};
        compiled ->
            Limits = maps:get(limits, Opts),
            {Adapter, Opts#{compiled => true,
                            limits => Limits#{fuel => infinity}}}
    end.

measure(paced, compiled, W, Request, Expected, Base) ->
    Deadline = erlang:monotonic_time(second) + ?ENTRY_DEADLINE_S,
    case until_generated(W, Request, Expected, Deadline, 0) of
        {entered, N} ->
            Ts = [begin timer:sleep(20), timed(W, Request, Expected) end
                  || _ <- lists:seq(1, samples())],
            Base#{verdict => ok, warm_requests => N, idle_ms => 20,
                  median_us => reactorlib:med(Ts), min_us => lists:min(Ts),
                  samples => Ts, counts => wasm_jit:counts()};
        {never, N} -> Base#{verdict => void, why => {never_entered, N}}
    end;
measure(sat, compiled, W0, Request, Expected, #{guest := Name} = Base) ->
    Deadline = erlang:monotonic_time(second) + ?ENTRY_DEADLINE_S,
    {entered, _} = until_generated(W0, Request, Expected, Deadline, 0),
    {Adapter, Opts} = opts(Name, compiled, false),
    Ws = [W0 | [begin {ok, W} = wasm_script_worker:start_link(Adapter, Opts),
                      {entered, _} = until_generated(W, Request, Expected,
                                                     Deadline, 0),
                      W end || _ <- lists:seq(2, pool())]],
    %% two warm requests on each, concurrently, then the timed burst
    burst(Ws, Request, Expected, 2),
    Per = samples(),
    T0 = erlang:monotonic_time(nanosecond),
    Ts = burst(Ws, Request, Expected, Per),
    Wall = (erlang:monotonic_time(nanosecond) - T0) / 1.0e6,
    [begin unlink(W), ok = wasm_script_worker:stop(W) end || W <- tl(Ws)],
    Base#{verdict => ok, pool => pool(), per_worker => Per, wall_ms => Wall,
          rps => length(Ts) / (Wall / 1000),
          median_us => reactorlib:med(Ts), min_us => lists:min(Ts),
          samples => Ts};
measure(Mode, _Tier, _W, _Request, _Expected, #{ahead := true} = Base)
  when Mode =:= split; Mode =:= firstwrite ->
    Base#{verdict => void, why => {restore_ahead_on, Mode}};
measure(Mode, Tier, W, _Request, Expected, Base)
  when Mode =:= split; Mode =:= firstwrite ->
    case split_ctx(W, Expected, Mode =:= firstwrite) of
        {void, Why} -> Base#{verdict => void, why => Why};
        {ok, Ctx} -> split(Tier, Ctx, Base#{recycles => recycles()})
    end;
measure(Mode, Tier, W, _Request, Expected, Base)
  when Mode =:= prof; Mode =:= tprof; Mode =:= bigword; Mode =:= count;
       Mode =:= regions ->
    case split_ctx(W, Expected, false) of
        {void, Why} -> Base#{verdict => void, why => Why};
        {ok, Ctx} -> xsplit(Mode, Tier, Ctx#{xmode => Mode},
                            Base#{recycles => recycles()})
    end;
measure(first, _Tier, W, Request, Expected, Base) ->
    Resident = length(wasm_code_slots:resident()),
    Counts0 = wasm_jit:counts(),
    Us = timed(W, Request, Expected),
    Base#{verdict => ok, first_us => Us, resident_before => Resident,
          counts_before => Counts0, counts_after => wasm_jit:counts()};
measure(steady, interp, W, Request, Expected, Base) ->
    _ = [timed(W, Request, Expected) || _ <- lists:seq(1, warm())],
    steady(W, Request, Expected, Base#{warm_requests => warm()});
measure(steady, compiled, W, Request, Expected, Base) ->
    Deadline = erlang:monotonic_time(second) + ?ENTRY_DEADLINE_S,
    T0 = erlang:monotonic_time(millisecond),
    case until_generated(W, Request, Expected, Deadline, 0) of
        {entered, N} ->
            steady(W, Request, Expected,
                   Base#{warm_requests => N,
                         entry_ms => erlang:monotonic_time(millisecond) - T0});
        {never, N} ->
            Base#{verdict => void, why => {never_entered, N}}
    end.

steady(W, Request, Expected, Base) ->
    Ts = [timed(W, Request, Expected) || _ <- lists:seq(1, samples())],
    Base#{verdict => ok, median_us => reactorlib:med(Ts),
          min_us => lists:min(Ts), samples => Ts,
          counts => wasm_jit:counts()}.

timed(W, Request, Expected) ->
    T0 = erlang:monotonic_time(nanosecond),
    R = wasm_script_worker:run(W, Request),
    T1 = erlang:monotonic_time(nanosecond),
    case R of
        {ok, #{result := Expected}} -> (T1 - T0) / 1000;
        Other -> exit({wrong_result, Other})
    end.

%% A request is traced; the loop ends at the first one during which a
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
    case Got of
        {ok, #{result := E}} -> ok;
        Other -> exit({wrong_result, Other})
    end,
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

%% As `densitybench': between requests the worker monitors exactly its
%% runner, which has an instance waiting once `wasm_worker_ahead' is in its
%% dictionary.
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

%%% ---------------------------------------------------------------- split ---

-define(PHASES, [restore, post, call, destroy]).

%% What the worker would use, read from its state. The record's first ten
%% fields are the same on every tree this runs on; each is checked by shape so
%% a tree where they moved is void rather than wrong.
split_ctx(W, Expected, Inst) ->
    St = sys:get_state(W),
    case is_tuple(St) andalso tuple_size(St) >= 11
        andalso element(1, St) =:= w of
        true -> split_ctx(St, Expected, Inst, ok);
        false -> {void, worker_state_shape}
    end.

split_ctx(St, Expected, Inst, ok) ->
    [Adapter, Artifact, _Opts, Limits, Heap, _Root, _Timeout, _Trusted,
     Image, Cap] = [element(I, St) || I <- lists:seq(2, 11)],
    Shape = is_atom(Adapter) andalso is_map(Limits) andalso is_integer(Heap)
        andalso is_map(Cap)
        andalso maps:is_key(max_staged_files, Limits)
        andalso is_function(maps:get(post_restore, Cap, none), 2)
        andalso is_image(Image),
    Counters = not Inst orelse
        (code:ensure_loaded(arb_inst) =:= {module, arb_inst}
         andalso arb_inst:init() =:= ok),
    if
        not Shape -> {void, worker_state_shape};
        not Counters -> {void, not_instrumented};
        true ->
            {ok, #{adapter => Adapter, artifact => Artifact,
                   limits => Limits, heap => Heap, image => Image,
                   cap => Cap, expected => Expected, inst => Inst,
                   recycles => recycles(), kept => undefined}}
    end.

is_image(Image) ->
    try is_map(wasm:snapshot_info(Image)) catch _:_ -> false end.

recycles() ->
    {module, wasm_snapshot} = code:ensure_loaded(wasm_snapshot),
    erlang:function_exported(wasm_snapshot, take_recycled, 1).

split(Tier, Ctx0, Base) ->
    Request = request_of(Base),
    Ctx = Ctx0#{request => Request},
    case split_warm(Tier, Ctx) of
        {void, Why, _} ->
            Base#{verdict => void, why => Why};
        {ok, Warm, Ctx1, Extra} ->
            {Ss, _} = lists:mapfoldl(fun(_, C) -> split_one(C) end, Ctx1,
                                     lists:seq(1, samples())),
            Col = fun(K) -> [maps:get(K, S) / 1000 || S <- Ss] end,
            Med = maps:from_list([{K, reactorlib:med(Col(K))}
                                  || K <- [total | ?PHASES]]),
            Min = maps:from_list([{K, lists:min(Col(K))}
                                  || K <- [total | ?PHASES]]),
            Recycled = length([x || #{recycled_in := true} <- Ss]),
            FW = case [F || #{firstwrite := F} <- Ss] of
                     [] -> #{};
                     [F1 | _] = Fs ->
                         #{firstwrite_median =>
                               maps:from_list(
                                 [{K, reactorlib:med([maps:get(K, F)
                                                      || F <- Fs])}
                                  || K <- maps:keys(F1)]),
                           firstwrite_mean =>
                               maps:from_list(
                                 [{K, lists:sum([maps:get(K, F)
                                                 || F <- Fs]) / length(Fs)}
                                  || K <- maps:keys(F1)])}
                 end,
            maps:merge(Base#{verdict => ok, warm_requests => Warm,
                             recycled_in => Recycled,
                             median_us => Med, min_us => Min, samples => Ss,
                             counts => wasm_jit:counts()},
                       maps:merge(FW, Extra))
    end.

request_of(#{guest := Name}) ->
    {ok, G} = reactorlib:guest(Name),
    maps:get(request, G).

split_warm(interp, Ctx) ->
    {_, Ctx1} = lists:mapfoldl(fun(_, C) -> split_one(C) end, Ctx,
                               lists:seq(1, warm())),
    {ok, warm(), Ctx1, #{}};
split_warm(compiled, Ctx) ->
    Deadline = erlang:monotonic_time(second) + ?ENTRY_DEADLINE_S,
    T0 = erlang:monotonic_time(millisecond),
    case split_until(Ctx, Deadline, 0) of
        {entered, N, Ctx1} ->
            {ok, N, Ctx1,
             #{entry_ms => erlang:monotonic_time(millisecond) - T0}};
        {never, N, Ctx1} ->
            {void, {never_entered, N}, Ctx1}
    end.

%% As `until_generated/5', around a split request.
split_until(Ctx, Deadline, N) ->
    case erlang:monotonic_time(second) >= Deadline of
        true -> {never, N, Ctx};
        false ->
            Self = self(),
            Tracer = spawn_link(fun() -> generated_calls(Self, false) end),
            Mods = wasm_code_slots:slots(),
            [erlang:trace_pattern({Mod, '_', '_'}, true, [local])
             || Mod <- Mods],
            _ = erlang:trace(all, true, [call, {tracer, Tracer}]),
            {_, Ctx1} = split_one(Ctx),
            _ = erlang:trace(all, false, [call]),
            [erlang:trace_pattern({Mod, '_', '_'}, false, [local])
             || Mod <- Mods],
            Tracer ! {done, Self},
            Seen = receive {seen, Tracer, S} -> S end,
            case Seen of
                true -> {entered, N + 1, Ctx1};
                false -> split_until(Ctx1, Deadline, N + 1)
            end
    end.

%% One request in a fresh runner. The memory a recycling build keeps comes
%% back here and goes to the next runner, as the worker carries it.
split_one(#{limits := Limits, heap := Heap} = Ctx) ->
    Self = self(),
    Words = maps:get(max_heap_words, Limits, 8 * 1024 * 1024),
    Floor = case Heap of 0 -> []; _ -> [{min_heap_size, Heap}] end,
    Gc = maps:get(gctracer, Ctx, none),
    {Pid, Mon} = spawn_opt(fun() ->
                                   Gc =:= none orelse
                                       receive go -> ok end,
                                   Self ! {split, self(), runner(Ctx)}
                           end,
                           [monitor,
                            {max_heap_size, #{size => Words, kill => true,
                                              error_logger => true}}
                            | Floor]),
    Gc =:= none orelse begin
                           1 = erlang:trace(Pid, true,
                                            [garbage_collection,
                                             monotonic_timestamp,
                                             {tracer, Gc}]),
                           Pid ! go
                       end,
    receive
        {split, Pid, {ok, Sample, Kept}} ->
            receive {'DOWN', Mon, process, Pid, _} -> ok end,
            Sample1 = case Gc of
                          none -> Sample;
                          _ -> Sample#{gc => gc_of(Gc, Pid)}
                      end,
            {Sample1, Ctx#{kept => Kept}};
        {split, Pid, Bad} ->
            exit({split_failed, Bad});
        {'DOWN', Mon, process, Pid, Why} ->
            exit({runner_died, Why})
    end.

runner(#{adapter := A, artifact := Art, request := Req, limits := Limits,
         image := Image, cap := #{post_restore := Post}, kept := Kept,
         recycles := Recycles, expected := Expected, inst := Inst} = Ctx0) ->
    {ok, Reqs} = A:requirements(Req, Art),
    Dir = private_dir(),
    Mounts = maps:map(fun(Name, #{guest_path := GP, mode := Mode}) ->
                              D = filename:join(Dir, atom_to_list(Name)),
                              ok = filelib:ensure_path(D),
                              #{guest_path => GP, host_dir => D, mode => Mode}
                      end, maps:get(mounts, Reqs, #{})),
    Chans = channels(Limits),
    Env = #{mounts => Mounts, channels => Chans, deadline => infinity,
            limits => Limits,
            cleanup => #{register => fun(_) -> {ok, make_ref()} end,
                         withdraw => fun(_) -> ok end},
            stage => fun(M, Path, Data) ->
                             #{host_dir := HD} = maps:get(M, Mounts),
                             file:write_file(filename:join(HD, Path), Data)
                     end},
    {ok, #{imports := IS, invoke := Invoke}, AState} = A:prepare(Req, Art, Env),
    Opts0 = maps:merge(Limits, restore_opts(IS)),
    Bindings = maps:get(bindings, IS),
    Opts = case Recycles of
               true ->
                   ok = wasm_snapshot:give_recycled(Image, Kept),
                   Opts0#{recycle => true};
               false ->
                   Opts0
           end,
    C0 = inst_read(Inst),
    XM = maps:get(xmode, Ctx0, none),
    ok = xreset(XM),
    {reductions, R0} = process_info(self(), reductions),
    T0 = erlang:monotonic_time(nanosecond),
    {ok, I} = wasm:restore(Image, Bindings, Opts),
    T1 = erlang:monotonic_time(nanosecond),
    #{module := M, version := V} = wasm:snapshot_info(Image),
    ok = Post(I, #{module => M, version => V}),
    T2 = erlang:monotonic_time(nanosecond),
    Exec = invoke(Invoke, I, Limits, A, AState),
    T3 = erlang:monotonic_time(nanosecond),
    ok = wasm:destroy(I),
    T4 = erlang:monotonic_time(nanosecond),
    {reductions, R1} = process_info(self(), reductions),
    X = xread(XM),
    C1 = inst_read(Inst),
    Kept1 = case Recycles of
                true -> wasm_snapshot:take_recycled(Image);
                false -> undefined
            end,
    Out = A:decode(executed(Exec, Chans), AState),
    [ets:delete(T) || {channel, _, T, _, _} <- maps:values(Chans)],
    _ = file:del_dir_r(Dir),
    case Out of
        {ok, #{result := Expected}} ->
            S = maps:merge(#{restore => T1 - T0, post => T2 - T1,
                             call => T3 - T2,
                             destroy => T4 - T3, total => T4 - T0,
                             reds => R1 - R0,
                             recycled_in => Kept =/= undefined}, X),
            {ok, inst_delta(Inst, C0, C1, S), Kept1};
        Other ->
            {wrong_result, Other}
    end.

inst_read(false) -> none;
inst_read(true) -> arb_inst:read().

inst_delta(false, _, _, S) -> S;
inst_delta(true, C0, C1, S) ->
    S#{firstwrite => maps:map(fun(K, V) -> V - maps:get(K, C0) end, C1)}.

%% As `wasm_script_worker:restore_opts/1'.
restore_opts(IS) ->
    Base = case maps:get(snapshot_hooks, IS, #{}) of
               Empty when map_size(Empty) =:= 0 -> #{};
               Hooks -> #{snapshot_hooks => Hooks}
           end,
    case maps:get(compatibility_key, IS, undefined) of
        undefined -> Base;
        Key       -> Base#{compatibility_key => Key}
    end.

%% As the runner's `invoke_loop/5', `stopped/2' and `last/1'.
invoke([{call, Name, Args} | Rest], Inst, Limits, A, AState) ->
    IR = wasm:call(Inst, Name, Args, Limits),
    case {A:classify(IR, AState), Rest, IR} of
        {continue, [], {ok, Vs}} -> {returned, Vs, undefined, undefined};
        {continue, [], {error, E}} -> {trapped, [], undefined, E};
        {continue, _, _} -> invoke(Rest, Inst, Limits, A, AState);
        {{stop, returned}, _, {ok, Vs}} -> {returned, Vs, undefined, undefined};
        {{stop, returned}, _, {error, E}} -> {returned, [], undefined, E};
        {{stop, {exited, C}}, _, {ok, Vs}} -> {exited, Vs, C, undefined};
        {{stop, {exited, C}}, _, {error, E}} -> {exited, [], C, E};
        {_, _, {ok, Vs}} -> {trapped, Vs, undefined, undefined};
        {_, _, {error, E}} -> {trapped, [], undefined, E}
    end.

executed({Outcome, Values, Exit, Err}, Chans) ->
    Read = fun(K) -> channel_read(maps:get(K, Chans)) end,
    {Out, TO} = Read(stdout),
    {Er, TE} = Read(stderr),
    {Res, TR} = Read(result),
    #{outcome => Outcome, values => Values, exit => Exit, error => Err,
      channels => #{stdout => Out, stderr => Er, result => Res},
      truncated => #{stdout => TO, stderr => TE, result => TR}}.

%% As the worker's `channels/1', with its bounds.
channels(Limits) ->
    Out = maps:get(max_output_bytes, Limits),
    Res = maps:get(max_result_bytes, Limits),
    Bound = fun(N, _) when is_integer(N) -> N;
               (Map, W) when is_map(Map) -> maps:get(W, Map)
            end,
    #{stdout => channel(stdout, Bound(Out, stdout)),
      stderr => channel(stderr, Bound(Out, stderr)),
      result => channel(result, Res)}.

channel(Which, Limit) ->
    {channel, Which, ets:new(worker_channel, [ordered_set, public]),
     atomics:new(1, []), Limit}.

channel_read({channel, _, Tab, Counter, Limit}) ->
    {iolist_to_binary([D || {_, D} <- ets:tab2list(Tab)]),
     atomics:get(Counter, 1) > Limit}.

private_dir() ->
    Dir = filename:join([filename:basedir(user_cache, "erlang_wasm_bench"),
                         "split-" ++ integer_to_list(
                                       erlang:unique_integer([positive]))]),
    ok = filelib:ensure_path(Dir),
    Dir.

%%% ---------------------------------------------------------------- attr ---

pool() -> case os:getenv("ATTR_POOL") of false -> 10; P -> list_to_integer(P) end.

%% Each worker served by its own client, Per requests back to back.
burst(Ws, Request, Expected, Per) ->
    Self = self(),
    Ps = [spawn_link(fun() ->
                             Ts = [timed(W, Request, Expected)
                                   || _ <- lists:seq(1, Per)],
                             Self ! {burst, self(), Ts}
                     end) || W <- Ws],
    lists:append([receive {burst, P, Ts} -> Ts end || P <- Ps]).

xreset(count) -> wasm_prof_c:reset();
xreset(regions) -> wasm_prof_c:reset();
xreset(_) -> ok.

xread(count) -> #{prof => wasm_prof_c:read()};
xread(regions) -> #{prof => wasm_prof_c:read(), regions => wasm_prof_c:regions()};
xread(_) -> #{}.

xsplit(Mode, Tier, Ctx0, Base) ->
    Request = request_of(Base),
    Ctx = Ctx0#{request => Request},
    case Mode of
        count -> ok = wasm_prof_c:init(), wasm_prof_c:rec_on(false);
        regions -> ok = wasm_prof_c:init(), wasm_prof_c:rec_on(true);
        _ -> ok
    end,
    case split_warm(Tier, Ctx) of
        {void, Why, _} ->
            Base#{verdict => void, why => Why};
        {ok, Warm, Ctx1, Extra} ->
            N = samples(),
            {Ss, Out} = xloop(Mode, Ctx1, N),
            Col = fun(K) -> [maps:get(K, S) / 1000 || S <- Ss] end,
            Med = maps:from_list([{K, reactorlib:med(Col(K))}
                                  || K <- [total | ?PHASES]]),
            maps:merge(Base#{verdict => ok, warm_requests => Warm, n => N,
                             median_us => Med, samples => Ss,
                             counts => wasm_jit:counts()},
                       maps:merge(Extra, Out))
    end.

loop(Ctx, N) ->
    {Ss, _} = lists:mapfoldl(fun(_, C) -> split_one(C) end, Ctx,
                             lists:seq(1, N)),
    Ss.

xloop(prof, Ctx, N) ->
    Gc = spawn(fun() -> gc_tracer(#{}) end),
    msacc:start(),
    W0 = erlang:monotonic_time(nanosecond),
    Ss = loop(Ctx#{gctracer => Gc}, N),
    Wall = erlang:monotonic_time(nanosecond) - W0,
    msacc:stop(),
    Stats = msacc:stats(),
    {Ss, #{msacc => msacc_sum(Stats), wall_ns => Wall,
           perf_per_s => erlang:convert_time_unit(1, second, perf_counter),
           msacc_raw => Stats}};
xloop(tprof, Ctx, N) ->
    _ = erlang:trace_pattern({'_', '_', '_'}, true, [call_time]),
    _ = erlang:trace(all, true, [call]),
    Ss = loop(Ctx, N),
    _ = erlang:trace(all, false, [call]),
    _ = erlang:trace_pattern({'_', '_', '_'}, pause, [call_time]),
    Rows = lists:append([ct_rows(M) || {M, _} <- code:all_loaded()]),
    _ = erlang:trace_pattern({'_', '_', '_'}, false, [call_time]),
    {Ss, #{call_time => Rows}};
xloop(bigword, Ctx, N) ->
    Tr = spawn(fun() -> tally(#{}) end),
    _ = erlang:trace_pattern({atomics, get, 2},
                             [{'_', [], [{return_trace}]}], [global]),
    _ = erlang:trace(all, true, [call, {tracer, Tr}]),
    Ss = loop(Ctx, N),
    _ = erlang:trace(all, false, [call]),
    _ = erlang:trace_pattern({atomics, get, 2}, false, [global]),
    Ref = erlang:trace_delivered(all),
    receive {trace_delivered, all, Ref} -> ok end,
    Tr ! {done, self()},
    C = receive {result, R} -> R end,
    {Ss, #{bigword => C}};
xloop(_, Ctx, N) ->
    {loop(Ctx, N), #{}}.

ct_rows(M) ->
    Fs = try erlang:get_module_info(M, functions) catch _:_ -> [] end,
    [{M, F, A, Calls, S * 1000000 + Us}
     || {F, A} <- Fs,
        {call_time, L} <- [erlang:trace_info({M, F, A}, call_time)],
        is_list(L),
        {Calls, S, Us} <- [lists:foldl(fun({_, C, S0, U0}, {C1, S1, U1}) ->
                                                {C + C1, S0 + S1, U0 + U1}
                                        end, {0, 0, 0}, L)],
        Calls > 0].

tally(C) ->
    receive
        {done, P} -> P ! {result, C};
        {trace, _, return_from, {atomics, get, 2}, V} ->
            K = if V < 1 bsl 59 -> small; true -> big end,
            tally(maps:update_with(K, fun(X) -> X + 1 end, 1, C));
        _ -> tally(C)
    end.

msacc_sum(Stats) ->
    lists:foldl(
      fun(#{type := T, counters := Cs}, Acc) ->
              maps:fold(fun(St, V, A) ->
                                maps:update_with({T, St}, fun(X) -> X + V end,
                                                 V, A)
                        end, Acc, Cs)
      end, #{}, Stats).

%% Per traced pid: collections, reclaimed words (end wordsize minus nothing:
%% as allocwords, the end event's `wordsize' is what the collection
%% reclaimed) and collection time.
gc_tracer(Acc) ->
    receive
        {trace_ts, P, Ev, Info, Ts} when Ev =:= gc_minor_start;
                                         Ev =:= gc_major_start ->
            Before = lists:sum([proplists:get_value(K, Info, 0)
                                || K <- [heap_size, old_heap_size,
                                         mbuf_size]]),
            gc_tracer(Acc#{{start, P} => {Ts, Before}});
        {trace_ts, P, Ev, Info, Ts} when Ev =:= gc_minor_end;
                                         Ev =:= gc_major_end ->
            {D, Rec} = case maps:get({start, P}, Acc, undefined) of
                    undefined -> {0, 0};
                    {T0, B0} ->
                        After = lists:sum([proplists:get_value(K, Info, 0)
                                           || K <- [heap_size,
                                                    old_heap_size]]),
                        {erlang:convert_time_unit(Ts - T0, native,
                                                  nanosecond), B0 - After}
                end,
            Kind = case Ev of gc_minor_end -> minor; _ -> major end,
            {N, Mj, W, Ns} = maps:get(P, Acc, {0, 0, 0, 0}),
            Mj1 = case Kind of major -> Mj + 1; minor -> Mj end,
            gc_tracer(Acc#{P => {N + 1, Mj1,
                                 W + Rec,
                                 Ns + D}});
        {get, P, From} ->
            From ! {gc, P, maps:get(P, Acc, {0, 0, 0, 0})},
            gc_tracer(maps:remove(P, Acc));
        _ -> gc_tracer(Acc)
    end.

gc_of(Gc, Pid) ->
    Ref = erlang:trace_delivered(Pid),
    receive {trace_delivered, Pid, Ref} -> ok end,
    Gc ! {get, Pid, self()},
    receive {gc, Pid, {N, Mj, W, Ns}} ->
            #{n => N, major => Mj, words => W, ns => Ns}
    end.
