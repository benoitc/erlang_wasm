#!/usr/bin/env escript
%%! -noshell
%% The fault-copy gates, from the files rounds.sh wrote.
%% Usage: analyze.escript RESULTS_DIR
%%
%% Per metric, guest and tier: every arm's value per round, then the median of
%% the per-round values and the median of the per-round ratios c1/main,
%% c2/main and c2/c1. Then the four gates as the plan wrote them.
-mode(compile).

-define(ARMS, [main, c1, c2]).

main([Out]) ->
    T = table(Out),
    report(T),
    gates(T);
main(_) ->
    io:format("usage: analyze.escript RESULTS_DIR~n"),
    halt(1).

table(Out) ->
    Files = filelib:wildcard(filename:join(Out, "raw/r*/*.terms")),
    lists:foldl(fun add/2, #{}, Files).

add(F, Acc) ->
    "r" ++ RS = filename:basename(filename:dirname(F)),
    R = list_to_integer(RS),
    [M | Rest] = string:split(filename:basename(F, ".terms"), "_", all),
    [Arm, Tier | GR] = lists:reverse(Rest),
    G = lists:flatten(lists:join("_", lists:reverse(GR))),
    lists:foldl(fun({Sub, V}, A) ->
                        K = {list_to_atom(M), G, Tier, Sub},
                        Rows = maps:get(K, A, #{}),
                        Row = maps:get(R, Rows, #{}),
                        A#{K => Rows#{R => Row#{list_to_atom(Arm) => V}}}
                end, Acc, values(list_to_atom(M), F)).

values(real, F) ->
    {ok, B} = file:read_file(F),
    case re:run(B, "run [0-9]+\t([0-9.]+) ms",
                [global, {capture, all_but_first, binary}]) of
        {match, L} -> [{ms, med([binary_to_float(X) || [X] <- L])}];
        nomatch -> []
    end;
values(M, F) ->
    case file:consult(F) of
        {ok, Terms} -> lists:append([vals(M, T) || T <- Terms]);
        {error, _} -> []
    end.

vals(split, #{verdict := ok, median_us := Med}) ->
    [{K, maps:get(K, Med)} || K <- [call, restore, post, destroy, total]];
vals(steady, #{verdict := ok, median_us := V}) -> [{p50, V}];
vals(density, #{verdict := ok, count := C}) -> [{count, C}];
vals(_, _) -> [].

report(T) ->
    [begin
         io:format("~n~p ~s ~s ~p~n", [M, G, Tier, Sub]),
         [io:format("  r~p  ~s~n", [R, row(maps:get(R, Rows))])
          || R <- lists:sort(maps:keys(Rows))],
         io:format("  med ~s~n", [meds(Rows)]),
         [io:format("  ~p/~p per round ~s  median ~.4f~n",
                    [A, B, fmt(rs(Rows, A, B)), med(rs(Rows, A, B))])
          || {A, B} <- [{c1, main}, {c2, main}, {c2, c1}], rs(Rows, A, B) =/= []]
     end || {M, G, Tier, Sub} = K <- lists:sort(maps:keys(T)),
            Rows <- [maps:get(K, T)]],
    ok.

row(Row) ->
    string:join([io_lib:format("~p=~s", [A, num(maps:get(A, Row, nan))])
                 || A <- ?ARMS], "  ").

meds(Rows) ->
    string:join([io_lib:format("~p=~s", [A, num(med(col(Rows, A)))])
                 || A <- ?ARMS, col(Rows, A) =/= []], "  ").

col(Rows, A) -> [V || #{A := V} <- maps:values(Rows)].

rs(Rows, A, B) ->
    [VA / VB || R <- lists:sort(maps:keys(Rows)),
                #{A := VA, B := VB} <- [maps:get(R, Rows)], VB > 0].

diffs(Rows, A, B) ->
    [VA - VB || R <- lists:sort(maps:keys(Rows)),
                #{A := VA, B := VB} <- [maps:get(R, Rows)]].

fmt(L) -> "[" ++ string:join([io_lib:format("~.3f", [X]) || X <- L], " ")
              ++ "]".

num(nan) -> "-";
num(V) when is_integer(V) -> integer_to_list(V);
num(V) -> io_lib:format("~.1f", [V]).

med([]) -> nan;
med(L) ->
    S = lists:sort(L), N = length(S),
    case N rem 2 of
        1 -> lists:nth(N div 2 + 1, S);
        0 -> (lists:nth(N div 2, S) + lists:nth(N div 2 + 1, S)) / 2
    end.

gates(T) ->
    io:format("~n== gates (median of per-round ratios)~n"),
    Call = maps:get({split, "py_entry", "compiled", call}, T, #{}),
    [io:format("gate 1 ~p/main py_entry compiled call: ~.4f (need =< 0.95) ~s~n",
               [A, med(rs(Call, A, main)),
                pass(med(rs(Call, A, main)) =< 0.95)]) || A <- [c1, c2]],
    [begin
         Rows = maps:get({steady, G, Tier, p50}, T, #{}),
         [io:format("gate 2 ~p/main ~s ~s p50: ~.4f ~s~n",
                    [A, G, Tier, med(rs(Rows, A, main)),
                     pass(med(rs(Rows, A, main)) =< 1.03)]) || A <- [c1, c2]]
     end || G <- ["py", "py_entry", "qjs", "lua"],
            Tier <- ["compiled", "interp"]],
    Real = maps:get({real, "qjs", "-", ms}, T, #{}),
    [io:format("gate 2 ~p/main realbench qjs: ~.4f ~s~n",
               [A, med(rs(Real, A, main)),
                pass(med(rs(Real, A, main)) =< 1.03)]) || A <- [c1, c2]],
    [begin
         Rows = maps:get({density, G, "-", count}, T, #{}),
         [io:format("gate 3 ~p ~s density per round ~w vs main ~w ~s~n",
                    [A, G, col_r(Rows, A), col_r(Rows, main),
                     pass(lists:all(fun(X) -> X >= 0 end,
                                    diffs(Rows, A, main)))])
          || A <- [c1, c2]]
     end || G <- ["py", "py_entry", "qjs", "lua"]],
    D = diffs(Call, c1, c2),
    io:format("gate 4 c1 - c2 py_entry compiled call, us, per round ~s "
              "median ~.1f (need >= 20) ~s~n",
              [fmt(D), med(D), pass(med(D) >= 20)]).

col_r(Rows, A) ->
    [maps:get(A, maps:get(R, Rows), nan) || R <- lists:sort(maps:keys(Rows))].

pass(true) -> "PASS";
pass(false) -> "FAIL".
