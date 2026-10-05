#!/usr/bin/env escript
%% Exp 1: per variant and arm, min and median of the per-round request
%% medians (requestbench), and of the profreq phase medians.
main([Dir | VL]) ->
    Vs = case VL of [] -> [v0, v1, v2, v3]; _ -> [list_to_atom(X) || X <- VL] end,
    Load = fun(F) -> case file:consult(filename:join(Dir, F)) of
                         {ok, L} -> L; _ -> [] end end,
    Steady = maps:from_list([{V, Load("steady_" ++ atom_to_list(V) ++ ".terms")}
                             || V <- Vs]),
    Prof = maps:from_list([{V, Load("prof_" ++ atom_to_list(V) ++ ".terms")}
                           || V <- Vs]),
    io:format("requestbench steady p50, ms: min / median of per-round medians "
              "(n rounds); delta vs V0 on the median~n"),
    [begin
         Row = [{V, vals(maps:get(V, Steady), G, T, median_us)} || V <- Vs],
         {_, B} = lists:keyfind(v0, 1, Row),
         io:format("~-4s ~-9s", [G, T]),
         [io:format("  ~s ~s", [V, cell(X, B)]) || {V, X} <- Row],
         io:format("~n")
     end || G <- [py, qjs, lua], T <- [interp, compiled]],
    io:format("~nprofreq phases, ms: median of per-round medians "
              "(total / restore / call / destroy / other)~n"),
    [begin
         io:format("~-4s ~-9s~n", [G, T]),
         [begin
              Rs = [R || #{guest := G2, tier := T2} = R <- maps:get(V, Prof),
                         G2 =:= G, T2 =:= T],
              Tot = med([maps:get(median_us, R) || R <- Rs]),
              Ph = fun(K) -> med([maps:get(median_us,
                                           maps:get(K, maps:get(phases, R)))
                                  || R <- Rs]) end,
              Re = Ph(restore), Ca = Ph(call), De = Ph(destroy),
              io:format("    ~s n=~p  ~7.2f / ~6.3f / ~7.2f / ~6.3f / ~6.3f~n",
                        [V, length(Rs), ms(Tot), ms(Re), ms(Ca), ms(De),
                         ms(Tot - Re - Ca - De)])
          end || V <- Vs, maps:get(V, Prof) =/= []]
     end || G <- [py, qjs, lua], T <- [interp, compiled]],
    ok.

vals(L, G, T, K) ->
    [maps:get(K, R) || #{guest := G2, tier := T2, verdict := ok} = R <- L,
                       G2 =:= G, T2 =:= T].

cell([], _) -> "-";
cell(X, B) ->
    M = med(X),
    D = case B of [] -> ""; _ -> P = 100 * (M / med(B) - 1),
                                io_lib:format(" (~s~.1f%)", [case P < 0 of true -> "-"; false -> "+" end, abs(P)]) end,
    io_lib:format("~.2f/~.2f(~p)~s", [ms(lists:min(X)), ms(M), length(X), D]).

med(L) -> S = lists:sort(L), N = length(S),
          case N rem 2 of 1 -> lists:nth((N + 1) div 2, S);
                          0 -> (lists:nth(N div 2, S) + lists:nth(N div 2 + 1, S)) / 2 end.
ms(X) -> X / 1000.
