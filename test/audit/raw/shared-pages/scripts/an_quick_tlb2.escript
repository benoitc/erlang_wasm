#!/usr/bin/env escript
%% Usage: an_quick.escript DIR
main([D]) ->
    io:format("## 1. steady request p50 (median of per-round medians, us)~n"),
    B = steady(D ++ "/steady_base.terms"), C = steady(D ++ "/steady_cand.terms"),
    [begin
         Bm = med(maps:get(K, B, [])), Cm = med(maps:get(K, C, [])),
         io:format("~p ~p base=~.1f cand=~.1f ratio=~.3f ~s~n",
                   [G, T, Bm, Cm, Cm / Bm, pf(Cm =< Bm * 1.05)])
     end || G <- [py, qjs, lua], T <- [interp, compiled], K <- [{G, T}]],
    io:format("## compiled entry check~n"),
    [io:format("~s ~p entered: ~p~n", [N, K, maps:get(K, E, [])])
     || {N, E} <- [{base, entries(D ++ "/steady_base.terms")},
                   {cand, entries(D ++ "/steady_cand.terms")}],
        K <- [py, qjs, lua]],
    io:format("## 2. snapshot load (min us)~n"),
    LB = loads(D ++ "/restore_base.terms"), LC = loads(D ++ "/restore_cand.terms"),
    [begin Bm = lists:min(maps:get(G, LB)), Cm = lists:min(maps:get(G, LC)),
           io:format("~p base=~.1f cand=~.1f ratio=~.3f ~s~n",
                     [G, Bm, Cm, Cm / Bm, pf(Cm =< Bm)]) end
     || G <- [py, qjs, lua, plain]].
pf(true) -> "PASS"; pf(false) -> "FAIL".
terms(F) -> {ok, Ts} = file:consult(F), Ts.
steady(F) ->
    lists:foldl(fun(#{mode := steady, guest := G, tier := T, median_us := M}, A) ->
                        maps:update_with({G, T}, fun(L) -> [M | L] end, [M], A);
                   (_, A) -> A end, #{}, terms(F)).
entries(F) ->
    lists:foldl(fun(#{mode := steady, guest := G, tier := compiled} = M, A) ->
                        V = {maps:get(verdict, M, x),
                             maps:get(entered, maps:get(counts, M, #{}), x)},
                        maps:update_with(G, fun(L) -> L ++ [V] end, [V], A);
                   (_, A) -> A end, #{}, terms(F)).
loads(F) ->
    lists:foldl(fun({load_snapshot, G, Ls}, A) ->
                        maps:update_with(G, fun(L) -> Ls ++ L end, Ls, A);
                   (_, A) -> A end, #{}, terms(F)).
med([]) -> 0.0;
med(L) -> S = lists:sort(L), N = length(S),
          case N rem 2 of 1 -> lists:nth(N div 2 + 1, S);
              0 -> (lists:nth(N div 2, S) + lists:nth(N div 2 + 1, S)) / 2 end.
