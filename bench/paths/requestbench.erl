-module(requestbench).
-moduledoc """
One script worker's request latency: the first request of a fresh node, and
steady requests after it.

Use it to hold a change to the worker request path, restore or the compiled
tier against the request p50 gate. One VM per invocation; interleave the trees
and run a first-request sample per VM.

    erlc -o bench/paths -pa _build/default/lib/wasm/ebin \\
         bench/paths/reactorlib.erl bench/paths/requestbench.erl
    erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run requestbench main first py compiled off CACHEDIR raw/first.terms
    erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run requestbench main steady py interp on none raw/steady.terms

Arguments: the mode (`first`, `steady`, `paced`, `split`, `firstwrite`), the guest
(`py`, `py_entry`, `qjs`, `lua`), the tier (`interp`, `compiled`),
`restore_ahead` (`on`, `off`), the code cache directory (`none` for none;
compiled arms need one) and the raw file (`none` for none).

The worker is the stock adapter with `reactorlib:worker_opts/2` (timeout
120000), `compiled => true` and `fuel => infinity` for the compiled tier, and
`restore_ahead` as given. Its image is filed under `_build/requestbench/images`
and read back by every later start, so a start is not a capture. Before any
request the harness waits until the worker is idle: with `restore_ahead` on,
until the ahead runner holds its instance (as `densitybench`).

## `first`

One request, timed from `wasm_script_worker:run/2` to its return. Run with a
code cache populated by an earlier `steady` run, so the compiled tier can find
the code on disk; `wasm_code_slots:resident/0` is recorded before the request
so a sample with code already resident shows it.

## `steady`

Interpreted: 20 requests, then 200 timed. Compiled: requests until one is seen
entering generated code, by a call trace on every `wasm_code_slots:slots/0`
module seeing a `wasm_f_` function during the request (as
`wasm_worker_lang_SUITE:compiled_requests`), within 25 minutes, then 200
timed. The median and the samples go to the raw file.

## `paced`

As `steady`, but every request, warm-up and timed, is sent 20 ms after the
previous reply, so the worker is idle between requests. `steady` is back to
back. Use it for what `restore_ahead` does while the worker waits.

## `split`

The worker's per-request sequence, through the public `wasm` API, with each
phase timed on its own. The worker is started as for `steady` (so its image is
the one a request would restore from) and is read once with
`sys:get_state/1` for the adapter, artifact, limits, runner heap floor, image
and snapshot capability it would use; every request is then served here, not
by the worker. Each request runs in a fresh process spawned with the runner's
own `max_heap_size` and `min_heap_size`, and does, in the runner's order:
`requirements/2`, the declared mounts made as directories, `prepare/3`, then

- `restore`: `wasm:restore/3` with the request's bindings and the worker's
  limits merged with the import set's hooks and key (and `recycle => true`
  plus the last request's kept memory on a build that recycles, as the worker
  does);
- `post`: `wasm:snapshot_info/1` and the capability's `post_restore`;
- `call`: every invocation followed by the adapter's `classify/2`;
- `destroy`: `wasm:destroy/1`;

then the channels read and `decode/2`, and the answer checked. Each phase is
timed with `erlang:monotonic_time(nanosecond)`. Warm-up and sample counts are
as `steady`: interpreted 20 then 200; compiled, requests until one enters
generated code, then 200. `restore_ahead` must be `off`.

What the worker does that this leaves out, none of it inside a timed phase:
the guardian and its message round trips, the mounts' cleanup steward and the
adapter-state transfer, the keeper reservation a recycling worker holds for
kept memory between requests, and the `gen_server` call.

## `firstwrite`

As `split`, on a build instrumented with `arb_inst` (a scratch tree, never a
timed arm), with the first-write counters read before the restore and after
the destroy of every request: count and time of A's `wasm_memory:fault/2`,
of B's `buy/2`, and of B's NIF stores that set a page's first bit.

Every answer is checked against the expected value.
""".

-export([main/1]).

-define(TIMEOUT, 120_000).
-define(IMAGES, "_build/requestbench/images").
-define(ENTRY_DEADLINE_S, 25 * 60).
-define(PAUSE_MS, 20).

%% 200 timed and 20 interpreted warm-up requests. `ARB_SMOKE` set to anything
%% makes them 3 and 2, for a smoke run that proves a harness works and is
%% never a sample.
samples() -> case os:getenv("ARB_SMOKE") of false -> 200; _ -> 3 end.
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

measure(Mode, _Tier, _W, _Request, _Expected, #{ahead := true} = Base)
  when Mode =:= split; Mode =:= firstwrite ->
    Base#{verdict => void, why => {restore_ahead_on, Mode}};
measure(Mode, Tier, W, _Request, Expected, Base)
  when Mode =:= split; Mode =:= firstwrite ->
    case split_ctx(W, Expected, Mode =:= firstwrite) of
        {void, Why} -> Base#{verdict => void, why => Why};
        {ok, Ctx} -> split(Tier, Ctx, Base#{recycles => recycles()})
    end;
measure(first, _Tier, W, Request, Expected, Base) ->
    Resident = length(wasm_code_slots:resident()),
    Counts0 = wasm_jit:counts(),
    Us = timed(W, Request, Expected),
    Base#{verdict => ok, first_us => Us, resident_before => Resident,
          counts_before => Counts0, counts_after => wasm_jit:counts()};
measure(paced, Tier, W, Request, Expected, Base) ->
    put(pause_ms, ?PAUSE_MS),
    measure(steady, Tier, W, Request, Expected, Base#{pause_ms => ?PAUSE_MS});
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
    ok = pause(),
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
    ok = pause(),
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

%% `paced' only: the wait after the previous reply.
pause() ->
    case get(pause_ms) of
        undefined -> ok;
        Ms -> timer:sleep(Ms)
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
    {Pid, Mon} = spawn_opt(fun() -> Self ! {split, self(), runner(Ctx)} end,
                           [monitor,
                            {max_heap_size, #{size => Words, kill => true,
                                              error_logger => true}}
                            | Floor]),
    receive
        {split, Pid, {ok, Sample, Kept}} ->
            receive {'DOWN', Mon, process, Pid, _} -> ok end,
            {Sample, Ctx#{kept => Kept}};
        {split, Pid, Bad} ->
            exit({split_failed, Bad});
        {'DOWN', Mon, process, Pid, Why} ->
            exit({runner_died, Why})
    end.

runner(#{adapter := A, artifact := Art, request := Req, limits := Limits,
         image := Image, cap := #{post_restore := Post}, kept := Kept,
         recycles := Recycles, expected := Expected, inst := Inst}) ->
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
            S = #{restore => T1 - T0, post => T2 - T1, call => T3 - T2,
                  destroy => T4 - T3, total => T4 - T0,
                  recycled_in => Kept =/= undefined},
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
