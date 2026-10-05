#!/usr/bin/env escript
main([Dir]) ->
    [begin
         {ok, Rs} = file:consult(filename:join(Dir, "load_" ++ V ++ ".terms")),
         io:format("~s rounds=~p~n", [V, length(Rs)]),
         [begin
              As = [A || #{arms := Arms} <- Rs, #{guest := G2} = A <- Arms, G2 =:= G],
              Keys = lists:sort(maps:keys(maps:get(stats, hd(As)))),
              io:format("  ~-6s", [G]),
              [io:format(" ~s=~s", [K, cell([maps:get(median, maps:get(K, maps:get(stats, A))) || A <- As])]) || K <- Keys],
              io:format("~n         digests ~p~n", [lists:usort([maps:get(digest, A) || A <- As])])
          end || G <- [py, qjs, lua, plain]]
     end || V <- ["v0", "v1", "v4"]].
cell(L) -> io_lib:format("~w/~w", [round(lists:min(L)), round(med(L))]).
med(L) -> lists:nth((length(L)+1) div 2, lists:sort(L)).
