#!/usr/bin/env escript
%%! -noshell
%% analyze.escript RESULTS: the gates of the outline-miss plan, from what
%% cold.sh and rounds.sh wrote. Definitions, fixed before the rounds ran:
%%
%% - A VM's figure is the p50 of its samples (split: the call phase; steady:
%%   the request), the median of its restores, the median of its three
%%   realbench runs, its density count.
%% - An arm's figure is the median over rounds of its VMs' figures.
%% - A ratio against main is the median over rounds of the per-round ratio,
%%   arm / main, both from the same cell.
%% - The null uncertainty is |null - main| per round: its median, and its
%%   largest.
%% - Cold compile is the median of three entry_ms.
%% - The one-entry rule: one's call p50 is "no higher beyond the null
%%   uncertainty" when the median over rounds of (one - cand) is at most the
%%   median of |null - main|; its cold compile is "at least 10% lower" when
%%   one / cand is at most 0.90. Both on every guest.
-mode(compile).
-define(GUESTS, ["py_entry", "qjs", "lua", "py"]).
-define(ARMS, ["main", "null", "cand", "one"]).

main([Out]) ->
    T = table(Out),
    Cold = cold(Out),
    io:format("# Gate 1: cold compile, entry_ms, median of three, at most "
              "0.5x main~n"),
    G1 = [begin
              [M, C, O] = [maps:get({G, A}, Cold, undefined)
                           || A <- ["main", "cand", "one"]],
              io:format("~-9s main ~s cand ~s one ~s  cand/main ~s one/main ~s "
                        "one/cand ~s~n",
                        [G, cs(M), cs(C), cs(O), rt(C, M), rt(O, M), rt(O, C)]),
              {G, r(C, M), r(O, M), r(O, C)}
          end || G <- ?GUESTS],
    io:format("~n# Gate 2: compiled call phase (split), p50 ms, at most 0.95x "
              "main~n"),
    G2 = [row(T, {"split", G, "compiled", call}, 1.0e6) || G <- ?GUESTS],
    io:format("~n# Gate 3a: compiled whole request (steady), p50 ms, no higher "
              "than main~n"),
    G3a = [row(T, {"steady", G, "compiled", p50}, 1.0e3) || G <- ?GUESTS],
    io:format("~n# Gate 3b: interpreted whole request (steady), p50 ms, within "
              "1.03x~n"),
    G3b = [row(T, {"steady", G, "interp", p50}, 1.0e3) || G <- ?GUESTS],
    io:format("~n# Gate 4a: density counts, identical~n"),
    G4a = [begin
               Rows = maps:get({"density", G, "-", count}, T, #{}),
               Per = [[maps:get(A, maps:get(R, Rows), void) || A <- ?ARMS]
                      || R <- lists:sort(maps:keys(Rows))],
               io:format("~-9s ~w (main null cand one per round)~n", [G, Per]),
               {G, lists:usort(lists:append(Per))}
           end || G <- ?GUESTS],
    io:format("~n# Gate 4b: restore median, us, within 1.03x~n"),
    G4b = [row(T, {"restore", G, "-", restore_us}, 1.0)
           || G <- ["py", "qjs", "lua", "plain"]],
    io:format("~n# Gate 4c: realbench qjs interpreted, ms, within 1.03x~n"),
    G4c = [row(T, {"real", "qjs", "-", ms}, 1.0)],
    io:format("~n# Reported: p95 and p99, ms, median over rounds of the "
              "per-VM figure~n"),
    [begin
         io:format("~s ~s ~s ~s:", [M, G, Tier, P]),
         [io:format(" ~s ~s", [A, f(armmed(T, {M, G, Tier, P}, A), D)])
          || A <- ["main", "cand", "one"]],
         io:format("~n")
     end || {M, Tier, Ps, D} <- [{"split", "compiled", [call95, call99], 1.0e6},
                                 {"steady", "compiled", [p95, p99], 1.0e3},
                                 {"steady", "interp", [p95, p99], 1.0e3}],
            G <- ?GUESTS, P <- Ps],
    io:format("~n# Reported: saturated throughput, pool of 10, requests/s~n"),
    [row(T, {"sat", G, "compiled", rps}, 1.0) || G <- ?GUESTS],
    io:format("~n# Reported: compile memory peak, erlang:memory(total), MB, "
              "median of three~n"),
    [io:format("~-9s main ~s cand ~s one ~s~n",
               [G | [f(maps:get({G, A, mem}, Cold, undefined), 1.0e6)
                     || A <- ["main", "cand", "one"]]]) || G <- ?GUESTS],
    io:format("~n# Decisions (cand against main)~n"),
    P1 = all([C =< 0.5 || {_, C, _, _} <- G1]),
    P2 = all([C =< 0.95 || {_, C, _, _, _} <- G2]),
    P3a = all([C =< 1.0 || {_, C, _, _, _} <- G3a]),
    P3b = all([C =< 1.03 || {_, C, _, _, _} <- G3b]),
    P4a = all([length(U) =:= 1 andalso U =/= [void] || {_, U} <- G4a]),
    P4b = all([C =< 1.03 || {_, C, _, _, _} <- G4b]),
    P4c = all([C =< 1.03 || {_, C, _, _, _} <- G4c]),
    [io:format("~s: ~s~n", [N, pf(P)])
     || {N, P} <- [{"gate 1 cold compile", P1}, {"gate 2 call phase", P2},
                   {"gate 3 compiled request", P3a},
                   {"gate 3 interpreted request", P3b},
                   {"gate 4 density", P4a}, {"gate 4 restore", P4b},
                   {"gate 4 realbench", P4c}]],
    io:format("~n# One-entry rule (one against cand)~n"),
    Ra = [begin
              Rows = maps:get({"split", G, "compiled", call}, T, #{}),
              D = med([maps:get("one", Row) - maps:get("cand", Row)
                       || Row <- maps:values(Rows),
                          is_map_key("one", Row), is_map_key("cand", Row)]),
              {_, _, _, NullMed, NullMax} = lists:keyfind(G, 1, G2),
              io:format("~-9s one - cand median ~s ms, null median ~s max ~s~n",
                        [G, f(D, 1.0e6), f(NullMed, 1.0e6), f(NullMax, 1.0e6)]),
              is_number(D) andalso D =< NullMed
          end || G <- ?GUESTS],
    Rb = [is_number(OC) andalso OC =< 0.90 || {_, _, _, OC} <- G1],
    io:format("call p50 no higher on any guest: ~s~ncold compile at least 10% "
              "lower on every guest: ~s~none entry ships: ~s~n",
              [pf(all(Ra)), pf(all(Rb)), pf(all(Ra) andalso all(Rb))]),
    loads(Out).

all(L) -> L =/= [] andalso lists:all(fun(X) -> X =:= true end, L).
pf(true) -> "pass"; pf(false) -> "FAIL".

%% One line: per-arm median, ratios against main, per-round values and null.
row(T, {_M, G, _Tier, _Sub} = K, Div) ->
    Rows = maps:get(K, T, #{}),
    Rs = lists:sort(maps:keys(Rows)),
    V = fun(A) -> [maps:get(A, maps:get(R, Rows), undefined) || R <- Rs] end,
    Ratio = fun(A) ->
                    med([X / Y || {X, Y} <- lists:zip(V(A), V("main")),
                                  is_number(X), is_number(Y)])
            end,
    Nd = [abs(X - Y) || {X, Y} <- lists:zip(V("null"), V("main")),
                        is_number(X), is_number(Y)],
    io:format("~-9s", [G]),
    [io:format(" ~s ~s", [A, f(med([X || X <- V(A), is_number(X)]), Div)])
     || A <- ?ARMS],
    io:format("  cand/main ~s one/main ~s null/main ~s  null |d| med ~s max ~s~n",
              [f(Ratio("cand"), 1), f(Ratio("one"), 1), f(Ratio("null"), 1),
               f(med(Nd), Div), f(lists:max([0 | Nd]), Div)]),
    [io:format("          ~-5s per round ~s~n",
               [A, string:join([f(X, Div) || X <- V(A)], " ")]) || A <- ?ARMS],
    {G, Ratio("cand"), Ratio("one"), med(Nd), lists:max([0 | Nd])}.

armmed(T, K, A) ->
    Rows = maps:get(K, T, #{}),
    med([maps:get(A, Row) || Row <- maps:values(Rows), is_map_key(A, Row)]).

%%% ------------------------------------------------------------- reading ---

%% #{{Metric, Guest, Tier, Sub} => #{Round => #{Arm => Value}}}
table(Out) ->
    Files = filelib:wildcard(filename:join(Out, "raw/r*/*.terms")),
    lists:foldl(fun add/2, #{}, Files).

add(F, Acc) ->
    "r" ++ RS = filename:basename(filename:dirname(F)),
    R = list_to_integer(RS),
    [M, G, Tier, Arm] = string:split(filename:basename(F, ".terms"), ".", all),
    lists:foldl(fun({{G1, Sub}, V}, A) ->
                        K = {M, G1, Tier, Sub},
                        Rows = maps:get(K, A, #{}),
                        Row = maps:get(R, Rows, #{}),
                        A#{K => Rows#{R => Row#{Arm => V}}}
                end, Acc, values(M, G, F)).

values("real", G, F) ->
    {ok, B} = file:read_file(F),
    case re:run(B, "run [0-9]+\t([0-9.]+) ms",
                [global, {capture, all_but_first, binary}]) of
        {match, L} -> [{{G, ms}, med([binary_to_float(X) || [X] <- L])}];
        nomatch -> io:format("VOID ~s~n", [F]), []
    end;
values(M, G, F) ->
    case file:consult(F) of
        {ok, Terms} ->
            case lists:append([vals(M, G, T) || T <- Terms]) of
                [] -> io:format("VOID ~s~n", [F]), [];
                Vs -> Vs
            end;
        {error, _} -> io:format("VOID ~s~n", [F]), []
    end.

vals("split", G, #{verdict := ok, samples := Ss}) ->
    Cs = [maps:get(call, S) || S <- Ss],
    [{{G, call}, pct(Cs, 50)}, {{G, call95}, pct(Cs, 95)},
     {{G, call99}, pct(Cs, 99)},
     {{G, total}, pct([maps:get(total, S) || S <- Ss], 50)}];
vals("steady", G, #{verdict := ok, samples := Ss}) ->
    [{{G, p50}, pct(Ss, 50)}, {{G, p95}, pct(Ss, 95)}, {{G, p99}, pct(Ss, 99)}];
vals("sat", G, #{verdict := ok, rps := Rps}) -> [{{G, rps}, Rps}];
vals("density", G, #{verdict := ok, count := C}) -> [{{G, count}, C}];
vals("restore", _G, {restore, G, Rs}) ->
    [{{atom_to_list(G), restore_us}, med(Rs)}];
vals(_, _, _) -> [].

cold(Out) ->
    lists:foldl(
      fun({G, A}, Acc) ->
              Fs = lists:sort(filelib:wildcard(
                                filename:join(Out, "cold/" ++ G ++ "_" ++ A
                                              ++ "_r*.terms"))),
              Ms = [M || F <- Fs, {ok, [M]} <- [file:consult(F)]],
              Es = [maps:get(entry_ms, M) || #{verdict := ok} = M <- Ms],
              Cs = lists:usort([maps:get(compiled, maps:get(counts, M))
                                || #{verdict := ok} = M <- Ms]),
              Mem = [list_to_integer(string:trim(binary_to_list(B)))
                     || F <- Fs,
                        {ok, B} <- [file:read_file(filename:rootname(F)
                                                   ++ ".mem")]],
              io:format("cold ~-9s ~-5s entry_ms ~w compiled ~w~n",
                        [G, A, Es, Cs]),
              case length(Es) of
                  3 -> Acc#{{G, A} => med(Es), {G, A, mem} => med(Mem)};
                  _ -> Acc
              end
      end, #{}, [{G, A} || G <- ?GUESTS, A <- ["main", "cand", "one"]]).

loads(Out) ->
    [case file:read_file(filename:join(Out, F)) of
         {ok, B} ->
             [_ | Lines] = [L || L <- string:split(B, "\n", all), L =/= <<>>],
             Col = fun(L, N) ->
                           num(lists:nth(N, string:split(L, "\t", all)))
                   end,
             Ends = [Col(L, E) || L <- Lines],
             Starts = [Col(L, E - 1) || L <- Lines],
             io:format("~n# loads ~s: ~w arm runs, start load max ~.2f, end "
                       "load median ~.2f max ~.2f, runs ending >= 8: ~w~n",
                       [F, length(Ends), lists:max([0.0 | Starts]),
                        med(Ends), lists:max([0.0 | Ends]),
                        length([X || X <- Ends, X >= 8])]);
         _ -> ok
     end || {F, E} <- [{"cold/loads.tsv", 7}, {"loads.tsv", 9}]],
    io:format("cells redone: ~w, void: ~s~n",
              [length(filelib:wildcard(filename:join(Out, "redone/*"))),
               case file:read_file(filename:join(Out, "void.txt")) of
                   {ok, V} -> V;
                   _ -> "none"
               end]).

num(B) ->
    S = binary_to_list(B),
    try list_to_float(S) catch _:_ -> float(list_to_integer(S)) end.

%%% ------------------------------------------------------------ numbers ---

pct(L, P) ->
    S = lists:sort(L), N = length(S),
    lists:nth(max(1, min(N, ceil(N * P / 100))), S).

med([]) -> undefined;
med(L) ->
    S = lists:sort(L), N = length(S),
    case N rem 2 of
        1 -> lists:nth((N + 1) div 2, S);
        0 -> (lists:nth(N div 2, S) + lists:nth(N div 2 + 1, S)) / 2
    end.

r(X, Y) when is_number(X), is_number(Y) -> X / Y;
r(_, _) -> undefined.
rt(X, Y) -> f(r(X, Y), 1).
cs(undefined) -> "-";
cs(Ms) -> io_lib:format("~.1f s", [Ms / 1000]).
f(undefined, _) -> "-";
f(V, D) -> float_to_list(V / D, [{decimals, 3}]).
