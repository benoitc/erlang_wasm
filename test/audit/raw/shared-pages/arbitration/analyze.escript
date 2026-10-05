#!/usr/bin/env escript
%%! -noshell
%% The arbitration's numbers and its decision, from the files rounds.sh and
%% fw.sh wrote. Usage: analyze.escript RESULTS_DIR [ct_b=pass|fail]
%%
%% Per metric and guest: every arm's value per round, the per-round ratios for
%% b/a3, b/a4, a4/a3, a3/base, a4/base, b/base, and their medians. Then the
%% plan's decision rule, clause by clause, B against the best A arm, and the
%% A4 against A3 ranking that picks that arm.
-mode(compile).

-define(PAIRS, [{b, a3}, {b, a4}, {a4, a3}, {a3, base}, {a4, base},
                {b, base}]).
-define(ARMS, [base, a3, a4, b]).
-define(GUESTS, [py, qjs, lua]).

main([Out | Opts]) ->
    Ct = proplists:get_value("ct_b", [list_to_tuple(string:split(O, "="))
                                       || O <- Opts], "unverified"),
    T = table(Out),
    report(T),
    loads(Out),
    A = a4_vs_a3(T),
    Best = case A of true -> a4; false -> a3 end,
    decide(T, Best, Ct),
    firstwrite(Out);
main(_) ->
    io:format("usage: analyze.escript RESULTS_DIR [ct_b=pass|fail]~n"),
    halt(1).

%%% ------------------------------------------------------------- reading ---

%% #{{Metric, Guest, Tier, Sub} => #{Round => #{Arm => Value}}}
table(Out) ->
    Files = filelib:wildcard(filename:join(Out, "raw/r*/*.terms")),
    lists:foldl(fun(F, Acc) -> add(F, Acc) end, #{}, Files).

add(F, Acc) ->
    "r" ++ RS = filename:basename(filename:dirname(F)),
    R = list_to_integer(RS),
    %% metric_guest_tier_arm; a guest name may itself contain "_".
    [M | Rest] = string:split(filename:basename(F, ".terms"), "_", all),
    [Arm, Tier | GR] = lists:reverse(Rest),
    G = lists:flatten(lists:join("_", lists:reverse(GR))),
    Vs = values(list_to_atom(M), G, F),
    lists:foldl(fun({{G1, Sub}, V}, A) ->
                        K = {list_to_atom(M), G1, Tier, Sub},
                        Rows = maps:get(K, A, #{}),
                        Row = maps:get(R, Rows, #{}),
                        A#{K => Rows#{R => Row#{list_to_atom(Arm) => V}}}
                end, Acc, Vs).

%% [{{Guest, Sub}, Value}]; nothing for a void or failed run.
values(real, G, F) ->
    {ok, B} = file:read_file(F),
    Ms = case re:run(B, "run [0-9]+\t([0-9.]+) ms",
                     [global, {capture, all_but_first, binary}]) of
             {match, L} -> [binary_to_float(X) || [X] <- L];
             nomatch -> []
         end,
    case Ms of [] -> []; _ -> [{{G, ms}, med(Ms)}] end;
values(M, G, F) ->
    case file:consult(F) of
        {ok, Terms} -> lists:append([vals(M, G, T) || T <- Terms]);
        {error, _} -> []
    end.

vals(split, G, #{verdict := ok, median_us := Med}) ->
    [{{G, K}, V} || K <- [call, restore, post, destroy, total],
                    V <- [maps:get(K, Med)]];
vals(steady, G, #{verdict := ok, median_us := V}) -> [{{G, p50}, V}];
vals(density, G, #{verdict := ok, count := C}) -> [{{G, count}, C}];
vals(sharing, G, #{verdict := ok} = S) ->
    [{{G, footprint_kb}, maps:get(footprint_delta_kb, S)},
     {{G, rss_kb}, maps:get(rss_delta_kb, S)},
     {{G, erlang_kb}, maps:get(erlang_total_delta_kb, S)}];
vals(restore, _G, {restore, G, Rs}) ->
    [{{atom_to_list(G), restore_us}, med(Rs)}];
vals(restore, _G, {load_snapshot, G, Ls}) ->
    [{{atom_to_list(G), load_us}, med(Ls)}];
vals(_, _, _) -> [].

%%% ------------------------------------------------------------ reporting ---

report(T) ->
    [cell(K, maps:get(K, T)) || K <- lists:sort(maps:keys(T))],
    ok.

cell({M, G, Tier, Sub} = K, Rows) ->
    io:format("~n== ~s ~s ~s ~s~n", [M, G, Tier, Sub]),
    Rs = lists:sort(maps:keys(Rows)),
    io:format("  round ~s~n", [string:join([pad(atom_to_list(A))
                                             || A <- ?ARMS], " ")]),
    [io:format("  r~-4w ~s~n",
               [R, string:join([pad(num(maps:get(A, maps:get(R, Rows),
                                                 undefined)))
                                || A <- ?ARMS], " ")]) || R <- Rs],
    [begin
         {Med, Per} = ratio(K, Rows, X, Y),
         io:format("  ~s/~s median ~s  per round ~s~n",
                   [X, Y, num(Med), string:join([num(P) || P <- Per], " ")])
     end || {X, Y} <- ?PAIRS],
    ok.

ratio(_K, Rows, X, Y) ->
    Per = [maps:get(X, Row) / maps:get(Y, Row)
           || R <- lists:sort(maps:keys(Rows)),
              Row <- [maps:get(R, Rows)],
              is_number(maps:get(X, Row, undefined)),
              is_number(maps:get(Y, Row, undefined)),
              maps:get(Y, Row) /= 0],
    {med(Per), Per}.

med([]) -> undefined;
med(L) ->
    S = lists:sort(L), N = length(S),
    case N rem 2 of
        1 -> lists:nth((N + 1) div 2, S);
        0 -> (lists:nth(N div 2, S) + lists:nth(N div 2 + 1, S)) / 2
    end.

num(undefined) -> "-";
num(V) when is_integer(V) -> integer_to_list(V);
num(V) -> float_to_list(V, [{decimals, 3}]).

pad(S) -> string:pad(S, 10, leading).

loads(Out) ->
    case file:read_file(filename:join(Out, "loads.tsv")) of
        {ok, B} ->
            [_ | Lines] = [L || L <- string:split(B, "\n", all), L =/= <<>>],
            Ends = [binary_to_number(lists:last(string:split(L, "\t", all)))
                    || L <- Lines],
            Redone = length(filelib:wildcard(
                              filename:join(Out, "redone/*"))),
            io:format("~n== loads: ~w arm runs, max end load ~s, "
                      "~w cells redone, arm runs ending >= 8: ~w~n",
                      [length(Ends), num(lists:max([0 | Ends])), Redone,
                       length([E || E <- Ends, E >= 8])]);
        _ -> ok
    end.

binary_to_number(B) ->
    try binary_to_float(B) catch _:_ -> float(binary_to_integer(B)) end.

%%% ------------------------------------------------------------- decision ---

r(T, K, X, Y) ->
    case maps:find(K, T) of
        {ok, Rows} -> element(1, ratio(K, Rows, X, Y));
        error -> undefined
    end.

%% A clause holds when its test holds for every guest, each on the median of
%% the per-round ratios. No data for a guest is a FAIL.
clause(Name, T, X, Y, KeyFun, Test) ->
    Per = [{G, r(T, KeyFun(atom_to_list(G)), X, Y)} || G <- ?GUESTS],
    Ok = lists:all(fun({_, V}) -> is_number(V) andalso Test(V) end, Per),
    io:format("  ~s ~s  ~s~n",
              [case Ok of true -> "PASS"; false -> "FAIL" end, Name,
               string:join([io_lib:format("~s=~s", [G, num(V)])
                            || {G, V} <- Per], " ")]),
    Ok.

%% The plan's decision rule, X against Y: compiled guest time at least 10%
%% lower, compiled whole-request p50 lower, interpreted whole-request p50 no
%% more than 5% higher, budget density at least, physical per instance no more
%% than 1.25x, for each guest.
clauses(T, X, Y) ->
    [clause(io_lib:format("compiled guest time ~s/~s =< 0.90", [X, Y]),
            T, X, Y, fun(G) -> {split, G, "compiled", call} end,
            fun(V) -> V =< 0.90 end),
     clause(io_lib:format("compiled whole-request p50 ~s/~s < 1", [X, Y]),
            T, X, Y, fun(G) -> {steady, G, "compiled", p50} end,
            fun(V) -> V < 1 end),
     clause(io_lib:format("interpreted whole-request p50 ~s/~s =< 1.05",
                          [X, Y]),
            T, X, Y, fun(G) -> {steady, G, "interp", p50} end,
            fun(V) -> V =< 1.05 end),
     clause(io_lib:format("budget density ~s/~s >= 1", [X, Y]),
            T, X, Y, fun(G) -> {density, G, "-", count} end,
            fun(V) -> V >= 1 end),
     clause(io_lib:format("physical per instance (footprint) ~s/~s =< 1.25",
                          [X, Y]),
            T, X, Y, fun(G) -> {sharing, G, "-", footprint_kb} end,
            fun(V) -> V =< 1.25 end)].

%% The plan's A4 rule (fixed 2026-10-04): A4 is kept if its compiled guest
%% time is lower than A3's for every guest and its compiled whole-request p50
%% is no higher for any guest.
a4_vs_a3(T) ->
    io:format("~n== A4 against A3 (A4 is kept only if both hold)~n"),
    Ok = lists:all(fun(X) -> X end,
                   [clause("compiled guest time a4/a3 < 1", T, a4, a3,
                           fun(G) -> {split, G, "compiled", call} end,
                           fun(V) -> V < 1 end),
                    clause("compiled whole-request p50 a4/a3 =< 1", T, a4,
                           a3, fun(G) -> {steady, G, "compiled", p50} end,
                           fun(V) -> V =< 1 end)]),
    io:format("  => ~s is A~n", [case Ok of true -> "a4"; false -> "a3" end]),
    Ok.

decide(T, Best, Ct) ->
    io:format("~n== Decision rule: B against A = ~s~n", [Best]),
    Cs = clauses(T, b, Best),
    CtOk = Ct =:= "pass",
    io:format("  ~s full ct on mmap-pages (given: ~s)~n",
              [case CtOk of true -> "PASS"; false -> "FAIL" end, Ct]),
    case lists:all(fun(X) -> X end, [CtOk | Cs]) of
        true -> io:format("  => B goes to the production plan~n");
        false -> io:format("  => ~s goes to the production plan~n", [Best])
    end.

%%% ---------------------------------------------------------- first write ---

firstwrite(Out) ->
    Fs = filelib:wildcard(filename:join(Out, "fw/*.terms")),
    Fs =/= [] andalso io:format("~n== first-write cost per request "
                                "(instrumented trees, mean)~n"),
    [case file:consult(F) of
         {ok, [#{verdict := ok, firstwrite_mean := Mean} | _]} ->
             io:format("  ~-28s ~p~n", [filename:basename(F, ".terms"), Mean]);
         _ ->
             io:format("  ~-28s void~n", [filename:basename(F, ".terms")])
     end || F <- Fs],
    ok.
