-module(cgate).
%% PR C gates (written before measuring): ab warm _start median paired ratio
%% <= 0.97, cold (trigger to publication) <= 1.03, generated module size
%% <= 1.03; null in [0.95, 1.05]; six pairs per ordering; no bimodal side; a
%% pair counts only if the 5-minute load average was below 8 at both ends of
%% both runs; every output checked by the harness.
-export([main/1]).
main([F]) ->
    {ok, Rs} = file:consult(F),
    M = maps:from_list([{list_to_tuple(string:lexemes(maps:get(tag, R), ":")), R} || R <- Rs]),
    Pairs = fun(O, S) -> [bv(O, S, maps:get({O, Rd, S, "first"}, M), maps:get({O, Rd, S, "second"}, M))
                          || {O1, Rd, S1, "first"} <- maps:keys(M), O1 =:= O, S1 =:= S] end,
    Warm = fun(R) -> med(maps:get(warm_us, R)) end,
    Cold = fun(R) -> maps:get(cold_us, R) end,
    Size = fun(R) -> maps:get(beam_bytes, R) end,
    [begin
         P = Pairs(O, S),
         Rat = fun(K) -> [K(V) / K(B) || {B, V} <- P] end,
         Sides = [[K(element(W, X)) || X <- P] || K <- [Warm, Cold], W <- [1, 2]],
         io:format("~s ~s n=~p warm ~.3f cold ~.3f size ~.4f bimodal ~p~n  warm ~w~n  cold ~w~n",
                   [S, O, length(P), med(Rat(Warm)), med(Rat(Cold)), med(Rat(Size)),
                    lists:any(fun bimodal/1, Sides), r3(Rat(Warm)), r3(Rat(Cold))])
     end || S <- ["null", "ab"], O <- ["F", "R"]],
    Base = [R || R <- Rs, maps:get(side, R) =:= base], New = [R || R <- Rs, maps:get(side, R) =:= new],
    io:format("base: warm ~p ms cold ~p s bytes ~p~nnew:  warm ~p ms cold ~p s bytes ~p~n",
              [round(med([Warm(R) || R <- Base]) / 1000), round(med([Cold(R) || R <- Base]) / 1.0e6),
               lists:usort([Size(R) || R <- Base]),
               round(med([Warm(R) || R <- New]) / 1000), round(med([Cold(R) || R <- New]) / 1.0e6),
               lists:usort([Size(R) || R <- New])]),
    halt().
bv(_, "null", A, B) -> {A, B};
bv("F", _, A, B) -> {A, B};
bv("R", _, A, B) -> {B, A}.
r3(L) -> [round(X * 1000) / 1000 || X <- L].
med(L) -> S = lists:sort(L), N = length(S),
    case N rem 2 of 1 -> lists:nth(N div 2 + 1, S); 0 -> (lists:nth(N div 2, S) + lists:nth(N div 2 + 1, S)) / 2 end.
bimodal(L) when length(L) < 6 -> false;
bimodal(L) -> S = lists:sort(L), N = length(S),
    [I || I <- lists:seq(3, N - 3), lists:nth(I + 1, S) / max(1, lists:nth(I, S)) > 2.0] =/= [].
