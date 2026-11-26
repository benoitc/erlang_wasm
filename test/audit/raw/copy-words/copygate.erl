-module(copygate).
-export([main/1]).
main([F]) ->
    {ok, Rs} = file:consult(F),
    M = maps:from_list([{list_to_tuple(string:lexemes(maps:get(tag, R), ":")), R} || R <- Rs]),
    Shapes = lists:usort([{D, S} || {D, S, _, _, _, _} <- maps:keys(M)]),
    Med = fun(L) -> Sd = lists:sort(L), N = length(Sd), (lists:nth((N + 1) div 2, Sd) + lists:nth(N div 2 + 1, Sd)) / 2 end,
    [begin
         [io:format("~s:~s ~s ~s n=~p time ~.3f reductions ~.3f base ~p us ~p reds new ~p us ~p reds~n",
                    [D, S, Set, O, length(P), Med([U(V) / U(B) || {B, V} <- P]), Med([Rd(V) / Rd(B) || {B, V} <- P]),
                     round(Med([U(B) || {B, _} <- P])), round(Med([Rd(B) || {B, _} <- P])),
                     round(Med([U(V) || {_, V} <- P])), round(Med([Rd(V) || {_, V} <- P]))])
          || Set <- ["null", "ab"], O <- ["F", "R"],
             P <- [[bv(O, Set, maps:get({D, S, O, Rn, Set, "first"}, M), maps:get({D, S, O, Rn, Set, "second"}, M))
                    || {D1, S1, O1, Rn, Set1, "first"} <- maps:keys(M), D1 =:= D, S1 =:= S, O1 =:= O, Set1 =:= Set]],
             U <- [fun(R) -> maps:get(copy_us, R) end], Rd <- [fun(R) -> maps:get(reductions, R) end]]
     end || {D, S} <- Shapes],
    halt().
bv(_, "null", A, B) -> {A, B};
bv("F", _, A, B) -> {A, B};
bv("R", _, A, B) -> {B, A}.
