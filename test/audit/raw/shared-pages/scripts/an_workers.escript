#!/usr/bin/env escript
main([Dir]) ->
    L = fun(T) -> {ok, Ts} = file:consult(filename:join(Dir, T ++ ".terms")), Ts end,
    Med = fun([]) -> undefined; (X) -> lists:nth((length(X)+1) div 2, lists:sort(X)) end,
    [begin
         Row = fun(Tr) -> [T || #{guest := G2, restore_ahead := A2} = T <- L(Tr), G2 =:= G, A2 =:= A] end,
         Inc = fun(Tr) -> [round(maps:get(busy_increment_per_worker, T)) || #{verdict := ok} = T <- Row(Tr)] end,
         Void = fun(Tr) -> [maps:get(why, T) || #{verdict := void} = T <- Row(Tr)] end,
         Idle = fun(Tr) -> [round(element(2, hd(maps:get(memory_idle, T))) / 50) || #{verdict := ok} = T <- Row(Tr)] end,
         Dup = fun(Tr) -> lists:usort([maps:get(distinct_images, T) || T <- Row(Tr)]) end,
         Hand = fun(Tr) -> lists:usort([{maps:get(idle, T), maps:get(handoff_at_barrier, T, x)} || #{verdict := ok} = T <- Row(Tr)]) end,
         io:format("~p ahead=~p~n  base inc ~p med ~p idle/worker med ~p void ~p distinct ~p ~p~n  cand inc ~p med ~p idle/worker med ~p void ~p distinct ~p ~p~n",
                   [G, A, Inc("base"), Med(Inc("base")), Med(Idle("base")), Void("base"), Dup("base"), Hand("base"),
                    Inc("cand"), Med(Inc("cand")), Med(Idle("cand")), Void("cand"), Dup("cand"), Hand("cand")])
     end || G <- [py, qjs, lua], A <- [false, true]].
