#!/usr/bin/env escript
%% Gate tables from results/raw/rN/*.terms. A VM's figure is its own value
%% (p50 for latency); an arm's figure the median over rounds; a ratio the
%% median of per-round cand/main ratios; the uncertainty |null - main| per
%% round, median and max.
main([Dir]) ->
    Rounds = lists:sort(filelib:wildcard(filename:join(Dir, "r*"))),
    io:format("rounds: ~p~n", [length(Rounds)]),
    Cells = [{workers, G, "-"} || G <- guests()] ++
            [{poolstart, G, "-"} || G <- guests()] ++
            [{capture, G, "-"} || G <- guests()] ++
            [{steady, G, T} || T <- ["compiled", "interp"], G <- guests()] ++
            [{restore, "all", "-"}] ++
            [{sat, G, "compiled"} || G <- guests()] ++
            [{churn, "py_entry", "compiled"}],
    [cell(Rounds, C) || C <- Cells],
    ok.

guests() -> ["py_entry", "qjs", "lua", "py"].

file(R, {M, G, T}, Arm) ->
    filename:join(R, lists:flatten(io_lib:format("~s.~s.~s.~s.terms", [M, G, T, Arm]))).

terms(F) ->
    case file:consult(F) of {ok, Ts} -> Ts; _ -> [] end.

metrics({workers, _, _}, [M | _]) when is_map(M) ->
    [{distinct_images, maps:get(distinct_images, M, x)}, {images_charged, maps:get(images_charged, M, x)},
     {busy_increment_per_worker, maps:get(busy_increment_per_worker, M, x)}];
metrics({poolstart, _, _}, [M | _]) when is_map(M) -> [{wall_ms, maps:get(wall_ms, M)}];
metrics({capture, _, _}, [M | _]) when is_map(M) ->
    [{captures, maps:get(captures, M)}, {generations, maps:get(generations, M)}, {holders, maps:get(holders, M)}];
metrics({steady, _, _}, [M | _]) when is_map(M) -> [{p50_us, maps:get(median_us, M, x)}];
metrics({sat, _, _}, [M | _]) when is_map(M) -> [{rps, maps:get(rps, M, x)}, {p50_us, maps:get(median_us, M, x)}];
metrics({churn, _, _}, [M | _]) when is_map(M) ->
    [{p50_us, maps:get(p50_us, M, x)}, {p99_us, maps:get(p99_us, M, x)}, {rps, maps:get(rps, M, x)},
     {peak_memory, maps:get(peak_memory, M, x)}, {churn_cycles, maps:get(churn_cycles, M, x)}];
metrics({restore, _, _}, Ts) ->
    [{list_to_atom("restore_" ++ atom_to_list(G)), med(Rs)} || {restore, G, Rs} <- Ts];
metrics(_, _) -> [].

med(L) when is_list(L), L =/= [] ->
    S = lists:sort([X || X <- L, is_number(X)]), lists:nth((length(S) + 1) div 2, S);
med(_) -> x.

cell(Rounds, C) ->
    Per = [{R, [{A, metrics(C, terms(file(R, C, A)))} || A <- [main, null, cand]]} || R <- Rounds],
    Keys = lists:usort([K || {_, As} <- Per, {_, Ms} <- As, {K, _} <- Ms]),
    [begin
         Vals = fun(A) -> [V || {_, As} <- Per, {A2, Ms} <- As, A2 =:= A, {K2, V} <- Ms, K2 =:= K] end,
         Main = Vals(main), Null = Vals(null), Cand = Vals(cand),
         case lists:all(fun is_number/1, Main ++ Cand) andalso Main =/= [] andalso length(Main) =:= length(Cand) of
             true ->
                 Ratios = [Cv / Mv || {Mv, Cv} <- lists:zip(Main, Cand), Mv /= 0],
                 Ds = [abs(Nv - Mv) || {Mv, Nv} <- lists:zip(Main, Null), is_number(Nv)],
                 io:format("~p ~s ~s ~p: main ~s cand ~s ratio ~s null|d| ~s/~s n=~p~n",
                           [element(1, C), element(2, C), element(3, C), K, f(med(Main)), f(med(Cand)),
                            f(med(Ratios)), f(med(Ds)), f(case Ds of [] -> x; _ -> lists:max(Ds) end), length(Main)]);
             false ->
                 io:format("~p ~s ~s ~p: main ~p null ~p cand ~p~n", [element(1, C), element(2, C), element(3, C), K, Main, Null, Cand])
         end
     end || K <- Keys],
    ok.

f(X) when is_float(X) -> io_lib:format("~.4g", [X]);
f(X) -> io_lib:format("~p", [X]).
