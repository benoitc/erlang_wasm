#!/usr/bin/env escript
%% Medians over the rounds of what vs.erl recorded, per runtime, and the ratio.
main([Dir]) ->
    Get = fun(Arm) ->
              [T || R <- lists:seq(1, 5),
                    {ok, [T]} <- [file:consult(filename:join(Dir,
                                   Arm ++ "-r" ++ integer_to_list(R) ++ ".terms"))]]
          end,
    E = Get("erlang_wasm"), W = Get("wasmtime"),
    Med = fun(L) -> S = lists:sort(L), lists:nth((length(S) + 1) div 2, S) end,
    Path = fun(T, Ks) -> lists:foldl(fun(K, M) -> maps:get(K, M) end, T, Ks) end,
    Row = fun(Name, Ks) ->
              A = Med([Path(T, Ks) || T <- E]), B = Med([Path(T, Ks) || T <- W]),
              io:format("~-34s ~14.3f ~14.3f ~9.1fx~n", [Name, float(A), float(B), A / B])
          end,
    io:format("~-34s ~14s ~14s ~10s~n", ["", "erlang_wasm", "wasmtime", "ratio"]),
    Row("arithmetic, ns per iteration", [loop, ns_per_iter]),
    Row("store and load, ns per iteration", [mem, ns_per_iter]),
    Row("4 KiB memory.copy, ns", [bulk, ns_per_iter]),
    Row("fib(30), ms", [fib30, ms]),
    Row("call from Erlang, ns", [call, ns_per_call]),
    Row("plugin compile+instantiate, us", [plugin, us]),
    Row("QuickJS compile, ms", [qjs, compile_ms]),
    Row("QuickJS instantiate, ms", [qjs, instantiate_ms]),
    Row("QuickJS _start, compiled, ms", [qjs, start_ms]),
    io:format("~nerlang_wasm QuickJS interpreted _start, ms: ~.1f~n",
              [float(Med([Path(T, [qjs, first, interpreted_ms]) || T <- E]))]),
    io:format("erlang_wasm QuickJS first compiled run (compile whole + run), ms: ~.1f~n",
              [float(Med([Path(T, [qjs, first, first_compiled_ms]) || T <- E]))]),
    Checks = [{K, lists:usort([Path(T, [K, checksum]) || T <- E ++ W])}
              || K <- [loop, mem, bulk, fib30]]
             ++ [{qjs, lists:usort(lists:append([Path(T, [qjs, checksum]) || T <- E ++ W]))}],
    io:format("checksums (one value each means both runtimes agree): ~p~n", [Checks]).
