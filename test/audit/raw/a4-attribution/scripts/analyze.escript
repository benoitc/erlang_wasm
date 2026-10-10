#!/usr/bin/env escript
%% Reads results/raw/r*/<mode>_<guest>_<arm>.terms and prints, per mode and
%% guest: per-arm medians over rounds of per-round p50/p95/p99 (ms), per-phase
%% medians for split, ratios main/base and null/main (median over rounds), and
%% the null paired difference (null - main) per round in ms.
main([Dir]) ->
    Files = filelib:wildcard(filename:join(Dir, "r*/*.terms")),
    Rows = lists:append([rows(F) || F <- Files]),
    Keys = lists:usort([{M, G} || {_, M, G, _, _} <- Rows]),
    [report(M, G, [R || {_, M1, G1, _, _} = R <- Rows, M1 =:= M, G1 =:= G])
     || {M, G} <- Keys],
    ok.

rows(F) ->
    Round = list_to_integer(tl(filename:basename(filename:dirname(F)))),
    [Mode, Guest0 | _] = string:split(filename:basename(F, ".terms"), "_"),
    Base = filename:basename(F, ".terms"),
    Arm = lists:last(string:split(Base, "_", all)),
    Guest = lists:sublist(Base, length(Mode) + 2,
                          length(Base) - length(Mode) - length(Arm) - 2),
    _ = Guest0,
    case file:consult(F) of
        {ok, [T | _]} when is_map(T) ->
            case maps:get(verdict, T, void) of
                ok -> [{Round, Mode, Guest, Arm, stats(Mode, T)}];
                _ -> io:format("VOID ~s~n", [F]), []
            end;
        _ -> io:format("UNREADABLE ~s~n", [F]), []
    end.

pct(L, P) ->
    S = lists:sort(L), N = length(S),
    lists:nth(max(1, min(N, round(P * N + 0.5))), S).

stats("split", #{samples := Ss}) ->
    maps:from_list(
      lists:append(
        [[{{K, p50}, pct(V, 0.5)}, {{K, p95}, pct(V, 0.95)},
          {{K, p99}, pct(V, 0.99)}]
         || K <- [total, restore, post, call, destroy],
            V <- [[maps:get(K, S) / 1.0e6 || S <- Ss]]]));
stats(_, #{samples := Ts} = T) ->
    V = [X / 1000 || X <- Ts],
    M = #{{total, p50} => pct(V, 0.5), {total, p95} => pct(V, 0.95),
          {total, p99} => pct(V, 0.99)},
    case T of #{rps := R} -> M#{{rps, p50} => R}; _ -> M end.

med([]) -> nan;
med(L) -> pct(L, 0.5).

report(Mode, G, Rows) ->
    Rounds = lists:usort([R || {R, _, _, _, _} <- Rows]),
    Ks = lists:usort(lists:append([maps:keys(S) || {_, _, _, _, S} <- Rows])),
    io:format("~n## ~s ~s (rounds ~p)~n", [Mode, G, Rounds]),
    io:format("~-16s ~9s ~9s ~9s ~8s ~8s ~10s ~10s~n",
              [key, base, main, null, "m/b", "n/m", "m-b ms", "n-m ms rng"]),
    [begin
         Get = fun(A, R) -> case [S || {R1, _, _, A1, S} <- Rows,
                                       R1 =:= R, A1 =:= A] of
                                [S] -> maps:get(K, S, nan); _ -> nan end end,
         Col = fun(A) -> [X || R <- Rounds, X <- [Get(A, R)], is_number(X)] end,
         Pair = fun(A, B, F) -> [F(X, Y) || R <- Rounds, X <- [Get(A, R)],
                                            Y <- [Get(B, R)], is_number(X),
                                            is_number(Y)] end,
         Rmb = med(Pair("main", "base", fun(X, Y) -> X / Y end)),
         Rnm = med(Pair("null", "main", fun(X, Y) -> X / Y end)),
         Dmb = med(Pair("main", "base", fun(X, Y) -> X - Y end)),
         Dnm = Pair("null", "main", fun(X, Y) -> X - Y end),
         Rng = case Dnm of [] -> "-";
                   _ -> io_lib:format("~.3f/~.3f/~.3f",
                                      [lists:min(Dnm), med(Dnm), lists:max(Dnm)])
               end,
         io:format("~-16s ~9s ~9s ~9s ~8s ~8s ~10s ~s~n",
                   [io_lib:format("~p", [K]), f(med(Col("base"))),
                    f(med(Col("main"))), f(med(Col("null"))), f(Rmb), f(Rnm),
                    f(Dmb), Rng])
     end || K <- Ks],
    ok.

f(X) when is_float(X) -> io_lib:format("~.3f", [X]);
f(X) when is_integer(X) -> integer_to_list(X);
f(X) -> io_lib:format("~p", [X]).
