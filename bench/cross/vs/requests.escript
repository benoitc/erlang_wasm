#!/usr/bin/env escript
%% The CPython request gate's figure, or a refusal.
%%
%% Usage: requests.escript OUTDIR [ROUNDS]
%%
%% Each VM's p50 (requestbench's `median_us`) over its timed requests; the
%% figure is the median over the rounds of those p50s, per tree, and the gate
%% compares candidate to baseline on it. p99 is reported, not gated. It exits
%% with status 1 when a run is missing, failed, overloaded, or never entered
%% compiled code.

main([Dir]) -> main([Dir, "5"]);
main([Dir, RoundsS]) ->
    Rounds = list_to_integer(RoundsS),
    Req = filename:join(Dir, "requests"),
    try
        [] =:= filelib:wildcard(filename:join(Req, "*.overloaded"))
            orelse refuse("overloaded results left in place", []),
        Get = fun(T) -> [load(Req, T, R) || R <- lists:seq(1, Rounds)] end,
        B = Get(baseline), C = Get(candidate),
        P50 = fun(L) -> [maps:get(median_us, X) / 1000 || X <- L] end,
        P99 = fun(L) -> [p99(maps:get(samples, X)) / 1000 || X <- L] end,
        Med = fun(L) -> S = lists:sort(L), lists:nth((length(S) + 1) div 2, S) end,
        MB = Med(P50(B)), MC = Med(P50(C)),
        io:format("CPython compiled request, median over ~p VMs of each VM's p50~n"
                  "  baseline  ~.3f ms   p99 ~.3f ms~n"
                  "  candidate ~.3f ms   p99 ~.3f ms~n"
                  "  candidate / baseline ~.3fx~n",
                  [Rounds, MB, Med(P99(B)), MC, Med(P99(C)), MC / MB])
    catch throw:{refuse, Why} ->
        io:format(standard_error, "refused: ~s~n", [Why]), halt(1)
    end.

refuse(Fmt, Args) -> throw({refuse, io_lib:format(Fmt, Args)}).

load(Req, T, R) ->
    F = filename:join(Req, lists:flatten(io_lib:format("~s-r~p.terms", [T, R]))),
    case file:consult(F) of
        {ok, [X | _]} when is_map(X) ->
            maps:get(verdict, X, undefined) =:= ok
                orelse refuse("~s did not answer ok", [F]),
            Entered = maps:get(entered, maps:get(counts, X, #{}), 0),
            Entered > 0 orelse refuse("~s never entered compiled code", [F]),
            X;
        _ -> refuse("missing or unreadable: ~s", [F])
    end.

p99(L) ->
    S = lists:sort(L),
    lists:nth(max(1, round(length(S) * 0.99)), S).
