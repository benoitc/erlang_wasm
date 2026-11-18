#!/usr/bin/env escript
%% Per workload: the b/a ratio of each round's pair, and their median.
main([Log]) ->
    {ok, Bin} = file:read_file(Log),
    Lines = [string:split(L, " ", all) || L <- string:split(Bin, "\n", all), L =/= <<>>],
    Rounds = rounds(Lines, []),
    Names = [N || {a, N, _} <- hd(Rounds)],
    [begin
         Rs = [val(b, N, R) / val(a, N, R) || R <- Rounds],
         S = lists:sort(Rs),
         io:format("~-18s median ~.3f  range ~.3f-~.3f  pairs ~s~n",
                   [N, lists:nth(3, S), hd(S), lists:last(S),
                    lists:join(" ", [io_lib:format("~.3f", [X]) || X <- Rs])])
     end || N <- Names].

val(Arm, N, R) -> hd([T || {A, M, T} <- R, A =:= Arm, M =:= N]).

rounds([], Acc) -> lists:reverse(Acc);
rounds([[<<"round">> | _] | Rest], Acc) -> rounds(Rest, [[] | Acc]);
rounds([[Arm, Name, T] | Rest], [Cur | Acc]) ->
    rounds(Rest, [[{binary_to_atom(Arm), binary_to_list(Name), binary_to_float(T)} | Cur] | Acc]).
