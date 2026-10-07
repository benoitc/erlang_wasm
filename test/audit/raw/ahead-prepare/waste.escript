#!/usr/bin/env escript
%%! -noshell
%% Gate 5: prepared pages the request never wrote, over those prepared.
%% Usage: waste.escript DIR
%% DIR holds <guest>_<tier>_main.log and <guest>_<tier>_cand.log from inst.py
%% builds. Requests are aligned from the end (both runs end with the 200
%% timed ones). `vs main' is the plan's count: a prepared page counts as
%% written when main's run made it private in the same request.
%% `vs content' is the candidate's own: the page's bytes changed.
-mode(compile).

main([Dir]) ->
    Cells = lists:usort([C || F <- filelib:wildcard(filename:join(Dir, "*_cand.log")),
                              C <- [filename:basename(F, "_cand.log")]]),
    [cell(Dir, C) || C <- Cells],
    ok.

cell(Dir, C) ->
    {ok, Ct} = file:consult(filename:join(Dir, C ++ "_cand.log")),
    {ok, Mt} = file:consult(filename:join(Dir, C ++ "_main.log")),
    P = [Ps || {prepared, Ps} <- Ct],
    S = [Ss || {sample, Ss} <- Ct],
    Wm = [Ws || {written, Ws} <- Mt],
    N = min(length(P), length(Wm)),
    Pa = lists:nthtail(length(P) - N, P),
    Wa = lists:nthtail(length(Wm) - N, Wm),
    Prepared = lists:sum([length(X) || X <- Pa]),
    Unwritten = lists:sum([length(X -- W) || {X, W} <- lists:zip(Pa, Wa)]),
    Content = case length(S) =:= length(P) of
                  true ->
                      lists:sum([length(X -- Sm) || {X, Sm} <- lists:zip(P, S),
                                                     is_list(Sm)]);
                  false -> na
              end,
    AllP = lists:sum([length(X) || X <- P]),
    io:format("~s: requests ~p, prepared ~p (mean ~.1f), unwritten vs main ~p "
              "= ~s, unwritten vs content ~p of ~p = ~s, main writes mean "
              "~.1f; ~s~n",
              [C, N, Prepared, Prepared / max(1, N), Unwritten,
               pct(Unwritten, Prepared), Content, AllP, pct(Content, AllP),
               lists:sum([length(X) || X <- Wa]) / max(1, N),
               case Prepared > 0 andalso Unwritten / Prepared =< 0.05 of
                   true -> "PASS"; false -> "FAIL" end]).

pct(na, _) -> "na";
pct(_, 0) -> "-";
pct(A, B) -> io_lib:format("~.2f%", [100 * A / B]).
