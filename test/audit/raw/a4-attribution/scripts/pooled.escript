#!/usr/bin/env escript
%% Pooled main+null against base: per-VM p50 of a key, median over VMs, and
%% the null comparison |null - main| per round (median and max), in ms.
main([Dir, Mode, Key]) ->
    K = list_to_atom(Key),
    [begin
         V = fun(A, R) ->
                 F = filename:join([Dir, "r" ++ integer_to_list(R),
                                    Mode ++ "_" ++ G ++ "_" ++ A ++ ".terms"]),
                 case file:consult(F) of
                     {ok, [#{verdict := ok, samples := Ss}]} ->
                         L = lists:sort([x(K, S) || S <- Ss]),
                         lists:nth((length(L) + 1) div 2, L);
                     _ -> nan
                 end
             end,
         Rs = lists:seq(1, 6),
         B = [X || R <- Rs, X <- [V("base", R)], is_number(X)],
         M = [X || R <- Rs, X <- [V("main", R)], is_number(X)],
         N = [X || R <- Rs, X <- [V("null", R)], is_number(X)],
         D = [abs(V("null", R) - V("main", R)) || R <- Rs,
              is_number(V("null", R)), is_number(V("main", R))],
         io:format("~-9s base ~.3f [~.3f..~.3f] pooled ~.3f [~.3f..~.3f] gap ~.3f null|d| med ~.3f max ~.3f nvm ~p/~p~n",
                   [G, med(B), lists:min(B), lists:max(B), med(M ++ N),
                    lists:min(M ++ N), lists:max(M ++ N),
                    med(M ++ N) - med(B), med(D), lists:max(D),
                    length(B), length(M ++ N)])
     end || G <- ["py_entry", "py", "qjs", "lua"]].
x(K, S) when is_map(S) -> maps:get(K, S) / 1.0e6;
x(_, S) -> S / 1000.
med(L) -> S = lists:sort(L), N = length(S),
          case N rem 2 of 1 -> lists:nth((N + 1) div 2, S);
                          0 -> (lists:nth(N div 2, S) + lists:nth(N div 2 + 1, S)) / 2 end.
