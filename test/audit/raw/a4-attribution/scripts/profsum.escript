#!/usr/bin/env escript
%% Summarises results/prof/<step>_<guest>_<arm>.terms, per request.
main([Dir]) ->
    Fs = lists:sort(filelib:wildcard(filename:join(Dir, "*.terms"))),
    [one(F) || F <- Fs], ok.

mean(L) -> lists:sum(L) / max(1, length(L)).
med(L) -> lists:nth((length(L) + 1) div 2, lists:sort(L)).

one(F) ->
    B = filename:basename(F, ".terms"),
    case file:consult(F) of
        {ok, [#{verdict := ok, samples := Ss} = T | _]} ->
            N = length(Ss),
            Call = med([maps:get(call, S) / 1.0e6 || S <- Ss]),
            Tot = med([maps:get(total, S) / 1.0e6 || S <- Ss]),
            Reds = mean([maps:get(reds, S) || S <- Ss]),
            io:format("~n### ~s  n=~p call_p50=~.3f ms total_p50=~.3f ms reds/req=~.1f~n",
                      [B, N, Call, Tot, Reds]),
            step(hd(string:split(B, "_")), T, Ss, N);
        {ok, [T | _]} -> io:format("~n### ~s VOID ~p~n", [B, maps:get(why, T, x)]);
        _ -> io:format("~n### ~s unreadable~n", [B])
    end.

step("prof", T, Ss, N) ->
    G = [maps:get(gc, S) || S <- Ss],
    io:format("gc/req: n=~.2f major=~.2f words=~.1f gc_us=~.1f~n",
              [mean([maps:get(n, X) || X <- G]),
               mean([maps:get(major, X) || X <- G]),
               mean([maps:get(words, X) || X <- G]),
               mean([maps:get(ns, X) || X <- G]) / 1000]),
    M = maps:get(msacc, T), Hz = maps:get(perf_per_s, T),
    _ = Hz, %% msacc:stats/0 counters are microseconds
    Us = fun(K) -> maps:get(K, M, 0) / N end,
    io:format("msacc us/req: sched emu=~.1f gc=~.1f other=~.1f aux=~.1f "
              "| dcpu emu=~.1f gc=~.1f other=~.1f | dio emu=~.1f other=~.1f "
              "| wall/req=~.1f~n",
              [Us({scheduler, emulator}), Us({scheduler, gc}),
               Us({scheduler, other}), Us({scheduler, aux}),
               Us({dirty_cpu_scheduler, emulator}),
               Us({dirty_cpu_scheduler, gc}),
               Us({dirty_cpu_scheduler, other}),
               Us({dirty_io_scheduler, emulator}),
               Us({dirty_io_scheduler, other}),
               maps:get(wall_ns, T) / 1000 / N]);
step("tprof", T, _Ss, N) ->
    Rows = maps:get(call_time, T),
    Bk = fun(M, F) ->
                 S = atom_to_list(M),
                 case S of
                     "wasm_code_" ++ _ -> generated;
                     _ when M =:= wasm_exec, (F =:= load_at orelse F =:= store_at) -> exec_mem_helper;
                     _ when M =:= wasm_memory; M =:= atomics -> M;
                     "wasm_num" ++ _ -> wasm_num;
                     "wasm_exec" ++ _ -> wasm_exec;
                     "wasi" ++ _ -> wasi;
                     "wasm_snapshot" ++ _ -> snapshot;
                     "wasm_instance" ++ _ -> instance;
                     _ when M =:= erlang -> erlang_bif;
                     "wasm" ++ _ -> wasm_other;
                     _ -> other
                 end
         end,
    Acc = lists:foldl(fun({M, F, _A, C, Us}, A) ->
                              K = Bk(M, F),
                              {C0, U0} = maps:get(K, A, {0, 0}),
                              A#{K => {C0 + C, U0 + Us}}
                      end, #{}, Rows),
    Tot = lists:sum([U || {_, U} <- maps:values(Acc)]),
    io:format("call_time us/req by bucket (traced total ~.1f):~n", [Tot / N]),
    [io:format("  ~-16s ~w us ~w calls~n", [K, round(U / N), round(C / N)])
     || {K, {C, U}} <- lists:reverse(lists:keysort(2, [{K, V} || {K, V} <- maps:to_list(Acc)]))],
    Top = lists:sublist(lists:reverse(lists:keysort(5, Rows)), 12),
    [io:format("  top ~p:~p/~p ~.1f us ~.1f calls~n", [M, F, A, U / N, C / N])
     || {M, F, A, C, U} <- Top];
step("bigword", T, _Ss, N) ->
    C = maps:get(bigword, T),
    io:format("atomics:get per req: small=~.1f big=~.1f~n",
              [maps:get(small, C, 0) / N, maps:get(big, C, 0) / N]);
step(S, _T, Ss, _N) when S =:= "count"; S =:= "regions" ->
    Ps = [maps:get(prof, X, #{}) || X <- Ss],
    Ks = lists:usort(lists:append([maps:keys(P) || P <- Ps])),
    io:format("counters mean/req: ~s~n",
              [[io_lib:format("~p=~.1f ", [K, mean([maps:get(K, P, 0) || P <- Ps])])
                || K <- Ks]]),
    case [maps:get(regions, X) || X <- Ss, maps:is_key(regions, X)] of
        [] -> ok;
        Rs -> io:format("regions mean/req: ~s~n",
                        [[io_lib:format("~p=~.1f ", [G, mean([maps:get(G, R) || R <- Rs])])
                          || G <- [512, 1024, 2048, 4096, 8192]]])
    end;
step(_, _, _, _) -> ok.
