#!/usr/bin/env escript
main([Dir]) ->
    Load = fun(F) -> case file:consult(filename:join(Dir, F)) of {ok, L} -> L; _ -> [] end end,
    First = [{base, T} || T <- Load("first_base.terms")] ++ [{cand, T} || T <- Load("first_cand.terms")],
    Steady = [{base, T} || T <- Load("steady_base.terms")] ++ [{cand, T} || T <- Load("steady_cand.terms")],
    Med = fun(L) -> lists:nth((length(L)+1) div 2, lists:sort(L)) end,
    io:format("FIRST (median of per-round medians, rounds reconstructed by order of 5)~n"),
    [begin
         Vals = fun(Tr) -> [maps:get(first_us, T) || {Tr2, #{guest := G2, tier := Ti2, ahead := A2, verdict := ok} = T} <- First, Tr2 =:= Tr, G2 =:= G, Ti2 =:= Ti, A2 =:= A] end,
         Res = fun(Tr) -> lists:usort([maps:get(resident_before, T) || {Tr2, #{guest := G2, tier := Ti2, ahead := A2} = T} <- First, Tr2 =:= Tr, G2 =:= G, Ti2 =:= Ti, A2 =:= A]) end,
         B = Vals(base), C = Vals(cand),
         MB = Med([Med(X) || X <- chunks(B, 5)]), MC = Med([Med(X) || X <- chunks(C, 5)]),
         io:format("~p ~p ahead=~p n=~p/~p base ~.1f ms cand ~.1f ms ratio ~.3f resident ~p/~p~n",
                   [G, Ti, A, length(B), length(C), MB/1000, MC/1000, MC/MB, Res(base), Res(cand)])
     end || G <- [py, qjs, lua], Ti <- [interp, compiled], A <- [false, true]],
    io:format("STEADY (median of per-round medians)~n"),
    [begin
         Vals = fun(Tr) -> [maps:get(median_us, T) || {Tr2, #{guest := G2, tier := Ti2, ahead := A2, verdict := ok} = T} <- Steady, Tr2 =:= Tr, G2 =:= G, Ti2 =:= Ti, A2 =:= A] end,
         Void = fun(Tr) -> length([x || {Tr2, #{guest := G2, tier := Ti2, ahead := A2, verdict := void}} <- Steady, Tr2 =:= Tr, G2 =:= G, Ti2 =:= Ti, A2 =:= A]) end,
         B = Vals(base), C = Vals(cand),
         MB = Med(B), MC = Med(C),
         io:format("~p ~p ahead=~p n=~p/~p void=~p/~p base ~.2f ms cand ~.2f ms ratio ~.3f~n",
                   [G, Ti, A, length(B), length(C), Void(base), Void(cand), MB/1000, MC/1000, MC/MB])
     end || G <- [py, qjs, lua], Ti <- [interp, compiled], A <- [false, true]],
    ok.
chunks([], _) -> [];
chunks(L, N) when length(L) =< N -> [L];
chunks(L, N) -> {A, B} = lists:split(N, L), [A | chunks(B, N)].
