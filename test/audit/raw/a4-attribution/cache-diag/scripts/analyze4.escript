#!/usr/bin/env escript
%% analyze.escript RESULTS: call-phase p50 per VM (ms), median over rounds per
%% arm, paired arm - v0 per round (median), null |null - v0| (median, max).
main([Dir]) ->
    Fs = filelib:wildcard(filename:join(Dir, "raw/r*/split_*.terms")),
    Rows = lists:filtermap(fun row/1, Fs),
    Gs = lists:usort([G || {_, G, _, _} <- Rows]),
    Arms = ["base", "v0", "null", "v4", "v5", "v6"],
    [begin
         io:format("~n## ~s~n~-6s ~8s ~8s ~10s ~6s~n", [G, arm, "p50 ms", "total", "d v0 med", "n"]),
         Rs = lists:usort([R || {R, G1, _, _} <- Rows, G1 =:= G]),
         V = fun(A, R) -> [X || {R1, G1, A1, X} <- Rows, R1 =:= R, G1 =:= G, A1 =:= A] end,
         [begin
              Xs = [C || R <- Rs, [{C, _}] <- [V(A, R)]],
              Ts = [T || R <- Rs, [{_, T}] <- [V(A, R)]],
              Ds = [C - C0 || R <- Rs, [{C, _}] <- [V(A, R)], [{C0, _}] <- [V("v0", R)]],
              io:format("~-6s ~8.3f ~8.3f ~10.3f ~6p  ~w~n",
                        [A, med(Xs), med(Ts), med(Ds), length(Xs),
                         [round(X * 100) / 100 || X <- Xs]])
          end || A <- Arms],
         Nd = [abs(N - M) || R <- Rs, [{N, _}] <- [V("null", R)], [{M, _}] <- [V("v0", R)]],
         io:format("null |null - v0| median ~.3f max ~.3f~n", [med(Nd), lists:max([0 | Nd])])
     end || G <- Gs],
    ok.

row(F) ->
    R = list_to_integer(tl(filename:basename(filename:dirname(F)))),
    B = filename:basename(F, ".terms"),
    A = lists:last(string:split(B, "_", all)),
    G = lists:sublist(B, 7, length(B) - 6 - length(A) - 1),
    case file:consult(F) of
        {ok, [#{verdict := ok, samples := Ss}]} ->
            {true, {R, G, A, {p50([maps:get(call, S) / 1.0e6 || S <- Ss]),
                              p50([maps:get(total, S) / 1.0e6 || S <- Ss])}}};
        _ -> io:format("VOID ~s~n", [F]), false
    end.

p50(L) -> S = lists:sort(L), lists:nth((length(S) + 1) div 2, S).
med([]) -> 0.0;
med(L) -> p50(L).
