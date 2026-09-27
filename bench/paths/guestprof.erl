-module(guestprof).
-moduledoc """
Where a real guest's compiled run spends its time, and what memory it touches.

Use it before ranking engine work, so the ranking is by measured time on a
guest rather than by a kernel. Two guests: `qjs`, QuickJS running a loop as a
command, and `py`, one request of `reqbench`'s CPython guest through a
`wasm_script_worker`.

    erlc -o bench/paths -pa _build/test/lib/wasm/ebin \\
        bench/paths/reqbench.erl bench/paths/guestprof.erl
    erl -noshell -pa _build/test/lib/wasm/ebin -pa bench/paths \\
        -run guestprof main qjs plain

Modes:

- `plain`: wall time of a unit, a `_start` or 50 requests. Undisturbed.
- `count`: exact calls per function. Barely disturbed.
- `msacc`: emulator against collection time.
- `bigword`: every word `atomics:get/2` answered, by range. Slow.
- `phases`: inclusive time of each `wasm` API call, for `py`. About 5%.
- `widths`: every memory access by direction, width and alignment, on the
  interpreter, one request for `py`. Slow.
- `sample`: prints the OS pid and loops, for macOS `sample`.

The code cache lives in `_build/guestprof/code`, because the cache refuses
any directory with a group- or world-writable ancestor and `/tmp` is one. The
first VM compiles, which takes minutes; every later VM must report
`cached => 1` or its numbers are not the compiled tier's.

`+JPperf` is refused on macOS, so `sample` sees generated code only as
addresses. Split that bucket with `count` and a `call_time` pass, and say that
the split is an estimate.
""".
-export([main/1]).

-define(REQS, 50).
-define(JS, <<"var a=0; for (var i=0;i<30000;i++) { a=(a+i*3)^(a>>>7); }",
              " print(a);">>).

main([Guest, Mode]) ->
    io:format("load ~s", [os:cmd("uptime")]),
    Dir = filename:absname("_build/guestprof"),
    ok = filelib:ensure_path(filename:join(Dir, "images")),
    _ = application:load(wasm),
    ok = application:set_env(wasm, code_cache_dir, filename:join(Dir, "code")),
    ok = application:set_env(wasm, snapshot_dir, filename:join(Dir, "images")),
    {ok, _} = application:ensure_all_started(wasm),
    Tier = Mode =/= "widths",
    Unit = unit(list_to_atom(Guest), Tier, Dir),
    Warm = warm(Unit, Tier),
    io:format("warm ~p ms, counts ~p~n", [Warm, wasm_jit:counts()]),
    E0 = maps:get(entered, wasm_jit:counts()),
    {T, R} = mode(Mode, Unit),
    Tier andalso (true = maps:get(entered, wasm_jit:counts()) > E0),
    io:format("RESULT ~s ~s ~.1f ms, counts ~p~n",
              [Guest, Mode, T / 1000, wasm_jit:counts()]),
    report(R),
    halt().

%%% ----------------------------------------------------------------- guests ---
%%
%% A fun that runs one unit of guest work: a whole `_start' in a fresh
%% process for QuickJS, `?REQS' requests for CPython.

unit(qjs, Tier, Dir) ->
    Js = filename:join(Dir, "js"),
    ok = filelib:ensure_path(Js),
    ok = file:write_file(filename:join(Js, "bench.js"), ?JS),
    {ok, Bin} = file:read_file("test/fixtures/lang/qjs.wasm"),
    {ok, M} = case Tier of
                  true -> wasm:load(Bin);
                  false -> wasm:compile(Bin)
              end,
    Opts = case Tier of
               true -> #{compile => true, compile_after => 1};
               false -> #{}
           end,
    Im = wasi_preview1:imports(
           #{args => [~"qjs", ~"/s/bench.js"], env => #{},
             dirs => [{~"/s", Js, read}], clocks => [monotonic, realtime],
             random => strong, stdout => fun(_) -> ok end,
             stderr => fun(_) -> ok end}),
    fun() ->
            benchlib:in_process(
              fun() ->
                      {ok, I} = wasm:instantiate(M, Im, Opts),
                      {ok, _} = wasm:call(I, ~"_start", []),
                      ok = wasm:destroy(I)
              end)
    end;
unit(py, Tier, _Dir) ->
    {Adapter, Opts0, Req} = reqbench:guest(py),
    Opts = case Tier of
               true -> Opts0;
               false ->
                   Limits = maps:get(limits, Opts0),
                   Opts0#{limits => Limits#{compile => false}}
           end,
    {ok, W} = wasm_script_worker:start_link(Adapter, Opts),
    %% Interpreted, a request takes seconds, so `widths' counts one.
    N = case Tier of true -> ?REQS; false -> 1 end,
    fun() ->
            [{ok, #{result := _}} = wasm_script_worker:run(W, Req)
             || _ <- lists:seq(1, N)],
            ok
    end.

%% Until a unit enters generated code and the compiled set stops growing.
warm(Unit, false) ->
    element(1, timer:tc(Unit)) div 1000;
warm(Unit, true) ->
    T0 = erlang:monotonic_time(millisecond),
    ok = warm(Unit, -1, 0, T0 + 1_800_000),
    erlang:monotonic_time(millisecond) - T0.

warm(Unit, Last, Stable, Deadline) ->
    E0 = maps:get(entered, wasm_jit:counts()),
    _ = Unit(),
    #{entered := E1, compiled := C} = wasm_jit:counts(),
    if
        E1 > E0, C =:= Last, Stable >= 2 -> ok;
        true ->
            erlang:monotonic_time(millisecond) < Deadline
                orelse erlang:error({never_warm, wasm_jit:counts()}),
            E1 > E0 orelse timer:sleep(500),
            Next = case E1 > E0 andalso C =:= Last of
                       true -> Stable + 1;
                       false -> 0
                   end,
            warm(Unit, C, Next, Deadline)
    end.

%%% ------------------------------------------------------------------ modes ---

mode("plain", Unit) ->
    timer:tc(Unit);
mode("sample", Unit) ->
    io:format("OSPID ~s~n", [os:getpid()]),
    timer:sleep(3000),
    {T, _} = timer:tc(fun() -> [Unit() || _ <- lists:seq(1, 20)] end),
    {T, sampled};
mode("msacc", Unit) ->
    msacc:start(),
    {T, _} = timer:tc(Unit),
    msacc:stop(),
    {T, {msacc, msacc:stats()}};
mode("count", Unit) ->
    %% By hand rather than through `tprof': generated modules export no
    %% `module_info/1', which its collector calls.
    _ = erlang:trace_pattern({'_', '_', '_'}, true, [call_count]),
    _ = erlang:trace_pattern(on_load, true, [call_count]),
    {T, _} = timer:tc(Unit),
    _ = erlang:trace_pattern({'_', '_', '_'}, pause, [call_count]),
    {T, {rows, lists:append([rows(M) || {M, _} <- code:all_loaded()])}};
mode("bigword", Unit) ->
    traced(Unit, [{{atomics, get, 2}, [{'_', [], [{return_trace}]}]}],
           fun bigword/2);
mode("phases", Unit) ->
    Tr = spawn(fun() -> phases(#{}, #{}) end),
    erlang:trace_pattern({wasm, '_', '_'}, [{'_', [], [{exception_trace}]}],
                         [global]),
    erlang:trace(all, true, [call, arity, monotonic_timestamp, {tracer, Tr}]),
    {T, _} = timer:tc(Unit),
    erlang:trace(all, false, [call]),
    erlang:trace_pattern({wasm, '_', '_'}, false, [global]),
    Tr ! {done, self()},
    receive {result, C} -> {T, {phases, C}} end;
mode("widths", Unit) ->
    %% The interpreter reaches memory only through `wasm_memory', so its entry
    %% points carry every access with its address and width.
    Fs = [{load, 3}, {store, 4}, {load_bytes, 3}, {store_bytes, 3},
          {atomic_load, 3}, {atomic_store, 4}, {atomic_rmw, 5},
          {atomic_cmpxchg, 5}, {fill, 4}, {copy, 4}, {copy, 5}, {init, 5}],
    traced(Unit, [{{wasm_memory, F, A}, true} || {F, A} <- Fs], fun widths/2).

traced(Unit, Patterns, Count) ->
    Tr = spawn(fun() -> tally(Count, #{}) end),
    [erlang:trace_pattern(MFA, Ms, [global]) || {MFA, Ms} <- Patterns],
    erlang:trace(all, true, [call, {tracer, Tr}]),
    {T, _} = timer:tc(Unit),
    erlang:trace(all, false, [call]),
    [erlang:trace_pattern(MFA, false, [global]) || {MFA, _} <- Patterns],
    Tr ! {done, self()},
    receive {result, C} -> {T, {tally, C}} end.

tally(Count, C) ->
    receive
        {done, P} -> P ! {result, C};
        Event -> tally(Count, Count(Event, C))
    end.

%% A word below 2^59 is an immediate; at or above it, a heap bignum. The last
%% two buckets say what the same 64 bits would be if the array were signed.
bigword({trace, _, return_from, {atomics, get, 2}, V}, C) ->
    K = if
            V < 1 bsl 59 -> small;
            V < 1 bsl 63 -> big;
            V >= (1 bsl 64) - (1 bsl 59) -> big_but_small_signed;
            true -> big_signed_too
        end,
    bump(K, 1, C);
bigword(_, C) -> C.

widths({trace, _, call, {wasm_memory, F, Args}}, C) ->
    case {F, Args} of
        {load, [_, A, N]} -> bump({load, N, A band 7}, 1, C);
        {store, [_, A, N, _]} -> bump({store, N, A band 7}, 1, C);
        {atomic_load, [_, A, N]} -> bump({atomic_load, N, A band 7}, 1, C);
        {atomic_store, [_, A, N, _]} -> bump({atomic_store, N, A band 7}, 1, C);
        {store_bytes, [_, _, B]} -> bump({bytes, store_bytes}, byte_size(B), C);
        {load_bytes, [_, _, N]} -> bump({bytes, load_bytes}, N, C);
        {_, _} -> bump({bytes, F}, lists:last(Args), C)
    end;
widths(_, C) -> C.

bump(K, N, C) -> maps:update_with(K, fun(X) -> X + N end, N, C).

%% Inclusive microseconds per `wasm' API function, per process call stack.
phases(Open, Acc) ->
    receive
        {trace_ts, P, call, MFA, Ts} ->
            phases(Open#{P => [{MFA, Ts} | maps:get(P, Open, [])]}, Acc);
        {trace_ts, P, R, MFA, _, Ts} when R =:= return_from;
                                          R =:= exception_from ->
            case maps:get(P, Open, []) of
                [{MFA, T0} | St] ->
                    D = erlang:convert_time_unit(Ts - T0, native, microsecond),
                    {N, S} = maps:get(MFA, Acc, {0, 0}),
                    phases(Open#{P => St}, Acc#{MFA => {N + 1, S + D}});
                _ -> phases(Open, Acc)
            end;
        {done, P} -> P ! {result, Acc};
        _ -> phases(Open, Acc)
    end.

rows(M) ->
    Fs = try erlang:get_module_info(M, functions) catch _:_ -> [] end,
    [{M, F, A, N}
     || {F, A} <- Fs,
        {call_count, N} <- [erlang:trace_info({M, F, A}, call_count)],
        is_integer(N), N > 0].

report({rows, Rows}) ->
    [io:format("ROW\t~p:~p/~p\t~p~n", [M, F, A, N])
     || {M, F, A, N} <- lists:reverse(lists:keysort(4, Rows))];
report({phases, C}) ->
    [io:format("PHASE\t~p\tcalls=~p\tinclusive_us=~p~n", [K, N, S])
     || {K, {N, S}} <- lists:reverse(lists:keysort(2, maps:to_list(C)))];
report({tally, C}) ->
    [io:format("K\t~p\t~p~n", [K, V]) || {K, V} <- lists:sort(maps:to_list(C))];
report({msacc, S}) ->
    msacc:print(S, #{system => true});
report(X) ->
    io:format("~p~n", [X]).
