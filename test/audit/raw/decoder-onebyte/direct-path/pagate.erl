-module(pagate).
%% PR A timing gates, written before the run: per guest and ordering, null
%% medians of decode and validate in [0.95, 1.05]; ab validate <= 0.95 and
%% decode <= 1.03; six pairs per ordering; no bimodal side. A pair counts only
%% if the 5-minute load average was below 8 at both ends of both runs.
-export([main/1]).

main(Files) ->
    Rs = lists:append([begin {ok, T} = file:consult(F), T end || F <- Files]),
    Cool = fun(R) -> maps:get(load_start, R) < 8.0
                         andalso maps:get(load_end, R) < 8.0 end,
    %% Later files win, so a rerun replaces the pair it repeats.
    M = lists:foldl(fun(R, A) ->
                            [G, O, Rd, S, P] = string:lexemes(maps:get(tag, R), ":"),
                            maps:update_with({G, O, Rd, S}, fun(X) -> X#{P => R} end,
                                             #{P => R}, A)
                    end, #{}, Rs),
    Valid = maps:filter(fun(_, #{"first" := A, "second" := B}) -> Cool(A) andalso Cool(B);
                           (_, _) -> false end, M),
    [report(G, S, O, [bv(O, S, A, B) || {{G1, O1, _, S1}, #{"first" := A, "second" := B}}
                                            <- maps:to_list(Valid),
                                        G1 =:= G, O1 =:= O, S1 =:= S])
     || G <- ["qjs", "python"], S <- ["null", "ab"], O <- ["F", "R"]],
    halt().

report(G, S, O, Pairs) ->
    R = fun(K) -> [maps:get(K, V) / maps:get(K, B) || {B, V} <- Pairs] end,
    Side = fun(K, W) -> [maps:get(K, element(W, P)) || P <- Pairs] end,
    Bim = [bimodal(Side(K, W)) || K <- [decode_us, validate_us], W <- [1, 2]],
    io:format("~s ~s ~s n=~p decode ~s validate ~s bimodal ~p~n"
              "  decode ~w~n  validate ~w~n  base decode ~s us validate ~s us~n",
              [G, S, O, length(Pairs), med(R(decode_us)), med(R(validate_us)),
               lists:member(true, Bim), r3(R(decode_us)), r3(R(validate_us)),
               med(Side(decode_us, 1)), med(Side(validate_us, 1))]).

bv(_, "null", A, B) -> {A, B};
bv("F", _, A, B) -> {A, B};
bv("R", _, A, B) -> {B, A}.

r3(L) -> [round(X * 1000) / 1000 || X <- L].

med([]) -> "none";
med(L) ->
    S = lists:sort(L), N = length(S),
    V = case N rem 2 of
            1 -> lists:nth(N div 2 + 1, S);
            0 -> (lists:nth(N div 2, S) + lists:nth(N div 2 + 1, S)) / 2
        end,
    io_lib:format("~.3f", [float(V)]).

bimodal(L) when length(L) < 6 -> false;
bimodal(L) ->
    S = lists:sort(L), N = length(S),
    [I || I <- lists:seq(3, N - 3),
          lists:nth(I + 1, S) / max(1, lists:nth(I, S)) > 2.0] =/= [].
