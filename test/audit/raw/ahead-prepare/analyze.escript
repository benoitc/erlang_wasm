#!/usr/bin/env escript
%%! -noshell
%% The ahead-prepare gates, from the files rounds.sh wrote.
%% Usage: analyze.escript RESULTS_DIR
%%
%% Per cell: each arm's value per round, the median of each arm, and the
%% per-round cand/main ratios with their median. Then gates 1 to 4 as the plan
%% wrote them. Gate 5 is counted apart (waste.escript).
-mode(compile).

-define(ARMS, [main, cand]).

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

%% metric_guest_tier_ahead_arm.terms, the guest possibly holding a `_'.
add(F, Acc) ->
    "r" ++ RS = filename:basename(filename:dirname(F)),
    R = list_to_integer(RS),
    [M | Rest] = string:split(filename:basename(F, ".terms"), "_", all),
    [Arm, Ahead, Tier | GR] = lists:reverse(Rest),
    G = lists:flatten(lists:join("_", lists:reverse(GR))),
    lists:foldl(fun({Sub, V}, A) ->
                        K = {list_to_atom(M), G, Tier, Ahead, Sub},
                        Rows = maps:get(K, A, #{}),
                        Row = maps:get(R, Rows, #{}),
                        A#{K => Rows#{R => Row#{list_to_atom(Arm) => V}}}
                end, Acc, values(list_to_atom(M), F)).

values(M, F) ->
    case file:consult(F) of
        {ok, Terms} -> lists:append([vals(M, T) || T <- Terms]);
        {error, _} -> []
    end.

vals(M, #{verdict := ok, median_us := V}) when M =:= paced; M =:= steady ->
    [{p50, V}];
vals(M, #{verdict := ok, n := N, pages_idle := I, pages_busy := B} = R)
  when M =:= workers; M =:= learned ->
    [{idle_pages_per_worker, I / N},
     {busy_pages_per_worker, maps:get(charged_pages_per_worker, R)},
     {total_pages_per_worker, B / N},
     {busy_increment_bytes, maps:get(busy_increment_per_worker, R)}];
vals(density, #{verdict := ok, count := C}) -> [{count, C}];
vals(_, _) -> [].

report(T) ->
    [begin
         io:format("~n~p ~s ~s ahead=~s ~p~n", [M, G, Tier, Ah, Sub]),
         [io:format("  r~p  ~s~n", [R, row(maps:get(R, Rows))])
          || R <- lists:sort(maps:keys(Rows))],
         io:format("  med ~s~n", [meds(Rows)]),
         io:format("  cand/main per round ~s  median ~s~n",
                   [fmt(rs(Rows)), num(med(rs(Rows)))])
     end || {M, G, Tier, Ah, Sub} = K <- lists:sort(maps:keys(T)),
            Rows <- [maps:get(K, T)]],
    ok.

row(Row) ->
    string:join([io_lib:format("~p=~s", [A, num(maps:get(A, Row, nan))])
                 || A <- ?ARMS], "  ").

meds(Rows) ->
    string:join([io_lib:format("~p=~s", [A, num(med(col(Rows, A)))])
                 || A <- ?ARMS, col(Rows, A) =/= []], "  ").

col(Rows, A) -> [V || #{A := V} <- maps:values(Rows)].

rs(Rows) ->
    [VA / VB || R <- lists:sort(maps:keys(Rows)),
                #{cand := VA, main := VB} <- [maps:get(R, Rows)], VB > 0].

fmt(L) -> "[" ++ string:join([io_lib:format("~.3f", [X]) || X <- L], " ")
              ++ "]".

num(nan) -> "-";
num(V) when is_integer(V) -> integer_to_list(V);
num(V) -> io_lib:format("~.4f", [V]).

med([]) -> nan;
med(L) ->
    S = lists:sort(L), N = length(S),
    case N rem 2 of
        1 -> lists:nth(N div 2 + 1, S);
        0 -> (lists:nth(N div 2, S) + lists:nth(N div 2 + 1, S)) / 2
    end.

ratio(T, K) -> med(rs(maps:get(K, T, #{}))).

gates(T) ->
    io:format("~n== gates (median of per-round cand/main ratios)~n"),
    G1 = ratio(T, {paced, "py_entry", "compiled", "on", p50}),
    io:format("gate 1 paced on py_entry compiled p50: ~s (need =< 0.90) ~s~n",
              [num(G1), pass(G1 =/= nan andalso G1 =< 0.90)]),
    [io:format("  reported: paced on ~s ~s p50: ~s~n",
               [G, Tier, num(ratio(T, {paced, G, Tier, "on", p50}))])
     || G <- ["py_entry", "py", "qjs", "lua"], Tier <- ["compiled", "interp"],
        {G, Tier} =/= {"py_entry", "compiled"}],
    [begin
         V = ratio(T, {steady, G, Tier, Ah, p50}),
         io:format("gate ~s steady ahead=~s ~s ~s p50: ~s ~s~n",
                   [N, Ah, G, Tier, num(V),
                    pass(V =/= nan andalso V =< 1.03)])
     end || {N, Ah} <- [{"2", "on"}, {"3", "off"}],
            G <- ["py_entry", "py", "qjs", "lua"],
            Tier <- ["compiled", "interp"]],
    [begin
         V = ratio(T, {M, G, "-", "on", total_pages_per_worker}),
         io:format("gate 4~s ~s workers on, idle+busy pages per worker: ~s "
                   "~s~n", [Tag, G, num(V), pass(V =/= nan andalso V =< 1.05)])
     end || {M, Tag} <- [{workers, ""}, {learned, " (DENSITY_WARM=9)"}],
            G <- ["py_entry", "py", "qjs", "lua"]],
    [begin
         Rows = maps:get({density, G, "-", "-", count}, T, #{}),
         Same = [maps:get(cand, maps:get(R, Rows), x) =:=
                     maps:get(main, maps:get(R, Rows), y)
                 || R <- maps:keys(Rows)],
         io:format("gate 4 ~s density counts per round cand ~w main ~w ~s~n",
                   [G, col_r(Rows, cand), col_r(Rows, main),
                    pass(Same =/= [] andalso lists:all(fun(X) -> X end,
                                                       Same))])
     end || G <- ["py_entry", "py", "qjs", "lua"]].

col_r(Rows, A) ->
    [maps:get(A, maps:get(R, Rows), nan) || R <- lists:sort(maps:keys(Rows))].

pass(true) -> "PASS";
pass(false) -> "FAIL".
