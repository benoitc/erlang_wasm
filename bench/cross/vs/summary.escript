#!/usr/bin/env escript
%% Read what run.sh recorded and print the comparison, or refuse.
%%
%% Usage: summary.escript OUTDIR [ROUNDS]
%%
%% It exits with status 1, printing why, when the evidence cannot be trusted:
%% an overloaded result left in OUTDIR, a missing or failed run, a row missing
%% from an arm that should have it, manifests that differ within one tree,
%% checksums that differ between any two runs, a compiled run that never
%% entered generated code, or a cold compile whose hot set differs between the
%% two trees. Figures are medians over the rounds; `paired` is the median of
%% the per-round candidate/baseline ratios.

main([Dir]) -> main([Dir, "5"]);
main([Dir, RoundsS]) ->
    Rounds = list_to_integer(RoundsS),
    try
        check_no_overloaded(Dir),
        Runs = load_all(Dir, Rounds),
        check_manifests(Runs),
        check_rows(Runs),
        check_entered(Runs),
        check_checksums(Runs),
        check_hot_set(Runs),
        print(Runs, Rounds)
    catch throw:{refuse, Why} ->
        io:format(standard_error, "refused: ~s~n", [Why]),
        halt(1)
    end.

refuse(Fmt, Args) -> throw({refuse, io_lib:format(Fmt, Args)}).

-define(ARMS, [baseline, candidate, erlang, wasmtime]).
-define(COLD, [baseline, candidate]).
-define(WASM_ROWS, [loop, mem, bulk, fib30, fibi30, f64, blocks, call, plugin,
                    qjs]).
-define(ERLANG_ROWS, [loop, fib30, fib30_idiomatic, fibi30, f64]).

%%% ------------------------------------------------------------ the checks ---

check_no_overloaded(Dir) ->
    case filelib:wildcard(filename:join(Dir, "*.overloaded")) of
        [] -> ok;
        Fs -> refuse("overloaded results left in place: ~p", [Fs])
    end.

%% #{{Kind, Arm, Round} => Term}, every expected file present and not failed.
load_all(Dir, Rounds) ->
    Names = [{arm, A, R, io_lib:format("~s-r~p", [A, R])}
             || R <- lists:seq(1, Rounds), A <- ?ARMS]
         ++ [{cold, T, R, io_lib:format("cold-~s-r~p", [T, R])}
             || R <- lists:seq(1, Rounds), T <- ?COLD],
    maps:from_list(
      [begin
           F = filename:join(Dir, lists:flatten(N) ++ ".terms"),
           case file:consult(F) of
               {ok, [#{failed := Why}]} -> refuse("~s failed: ~p", [F, Why]);
               {ok, [T]} -> {{K, A, R}, T};
               _ -> refuse("missing or unreadable: ~s", [F])
           end
       end || {K, A, R, N} <- Names]).

%% Within one tree every run must come from the same build.
check_manifests(Runs) ->
    [case lists:usort([maps:get(manifest, T) || {{_, A, _}, T} <- maps:to_list(Runs),
                                                 A =:= Arm]) of
         [_] -> ok;
         Ms -> refuse("~p ran from ~p different manifests", [Arm, length(Ms)])
     end || Arm <- ?ARMS],
    ok.

check_rows(Runs) ->
    maps:foreach(
      fun({arm, A, R}, T) ->
              [case maps:is_key(Row, T) of
                   true -> ok;
                   false -> refuse("~p round ~p has no ~p row", [A, R, Row])
               end || Row <- expected_rows(A)];
         ({cold, A, R}, T) ->
              maps:is_key(coldcompile, T)
                  orelse refuse("cold ~p round ~p has no result", [A, R])
      end, Runs).

expected_rows(erlang) -> ?ERLANG_ROWS;
expected_rows(_) -> ?WASM_ROWS.

%% A compiled arm that never entered generated code measured the interpreter.
check_entered(Runs) ->
    maps:foreach(
      fun({arm, A, R}, T) when A =:= baseline; A =:= candidate ->
              C = maps:get(jit_counts, T, #{}),
              maps:get(entered, C, 0) > 0
                  orelse refuse("~p round ~p never entered compiled code", [A, R]);
         (_, _) -> ok
      end, Runs).

%% Every row that carries a checksum must carry the same one everywhere.
check_checksums(Runs) ->
    Rows = [loop, mem, bulk, fib30, fib30_idiomatic, fibi30, f64, blocks, qjs],
    [case lists:usort(lists:append(
                        [sums(maps:get(checksum, maps:get(Row, T)))
                         || {{arm, _, _}, T} <- maps:to_list(Runs),
                            maps:is_key(Row, T)])) of
         [] -> ok;
         [_] -> ok;
         Vs -> refuse("~p checksums disagree: ~p", [Row, Vs])
     end || Row <- Rows],
    Cold = lists:usort([maps:get(checksum, maps:get(coldcompile, T))
                        || {{cold, _, _}, T} <- maps:to_list(Runs)]),
    QjsSums = lists:usort(lists:append(
                            [maps:get(checksum, maps:get(qjs, T))
                             || {{arm, _, _}, T} <- maps:to_list(Runs),
                                maps:is_key(qjs, T)])),
    case Cold of
        [C] when QjsSums =:= [] orelse QjsSums =:= [C] -> ok;
        _ -> refuse("cold compile output disagrees: ~p against ~p", [Cold, QjsSums])
    end.

sums(L) when is_list(L) -> L;
sums(V) -> [V].

%% Both trees must have compiled the same hot set, or their times are not
%% comparable.
check_hot_set(Runs) ->
    case lists:usort([maps:get(hot_set_hash, maps:get(coldcompile, T))
                      || {{cold, _, _}, T} <- maps:to_list(Runs)]) of
        [_] -> ok;
        Hs -> refuse("cold compiles saw ~p different hot sets", [length(Hs)])
    end.

%%% ----------------------------------------------------------- the table ---

print(Runs, Rounds) ->
    Get = fun(K, A, Path) ->
                  [deep(maps:get({K, A, R}, Runs), Path) || R <- lists:seq(1, Rounds)]
          end,
    Med = fun(L) -> S = lists:sort(L), lists:nth((length(S) + 1) div 2, S) end,
    io:format("~-30s ~11s ~11s ~11s ~11s ~8s ~8s ~8s ~8s~n",
              ["", "baseline", "candidate", "erlang", "wasmtime",
               "c/base", "paired", "c/erl", "c/wt"]),
    Row = fun(Name, Path, ErlPath, HasWt) ->
              B = Get(arm, baseline, Path), C = Get(arm, candidate, Path),
              E = case ErlPath of none -> none; _ -> Med(Get(arm, erlang, ErlPath)) end,
              W = case HasWt of true -> Med(Get(arm, wasmtime, Path)); false -> none end,
              Paired = Med([Ci / Bi || {Bi, Ci} <- lists:zip(B, C)]),
              io:format("~-30s ~11s ~11s ~11s ~11s ~8s ~8s ~8s ~8s~n",
                        [Name, f(Med(B)), f(Med(C)), f(E), f(W),
                         r(Med(C), Med(B)), f3(Paired), r(Med(C), E), r(Med(C), W)])
          end,
    Row("loop, ns/iter", [loop, ns_per_iter], [loop, ns_per_iter], true),
    Row("store+load, ns/iter", [mem, ns_per_iter], none, true),
    Row("4 KiB copy, ns", [bulk, ns_per_iter], none, true),
    Row("fib(30), ms", [fib30, ms], [fib30, ms], true),
    Row("fib(30) through a table, ms", [fibi30, ms], [fibi30, ms], true),
    Row("f64 loop, ns/iter", [f64, ns_per_iter], [f64, ns_per_iter], true),
    Row("block result + load, ns/iter", [blocks, ns_per_iter], none, true),
    Row("call from Erlang, ns", [call, ns_per_call], none, true),
    Row("plugin compile+inst, us", [plugin, us], none, true),
    Row("QuickJS compile, ms", [qjs, compile_ms], none, true),
    Row("QuickJS instantiate, ms", [qjs, instantiate_ms], none, true),
    Row("QuickJS _start, ms", [qjs, start_ms], none, true),
    io:format("~nplain Erlang fib(30), idiomatic, ms: ~s~n",
              [f(Med(Get(arm, erlang, [fib30_idiomatic, ms])))]),
    ColdRow = fun(Name, Key) ->
                  B = Get(cold, baseline, [coldcompile, Key]),
                  C = Get(cold, candidate, [coldcompile, Key]),
                  io:format("~-30s ~11s ~11s ~8s paired ~s~n",
                            [Name, f(Med(B)), f(Med(C)), r(Med(C), Med(B)),
                             f3(Med([Ci / Bi || {Bi, Ci} <- lists:zip(B, C)]))])
              end,
    io:format("~ncold compile of QuickJS's hot set (~p functions)~n",
              [hd(Get(cold, baseline, [coldcompile, hot_set_size]))]),
    ColdRow("compile, ms", compile_ms),
    ColdRow("code, bytes", code_bytes),
    io:format("~nall checks passed: ~p rounds, manifests consistent, "
              "checksums agree, compiled code entered, same hot set~n", [Rounds]).

deep(T, []) -> T;
deep(T, [K | Ks]) -> deep(maps:get(K, T), Ks).

f(none) -> "-";
f(V) when is_integer(V) -> integer_to_list(V);
f(V) -> lists:flatten(io_lib:format("~.3f", [V])).
f3(V) -> lists:flatten(io_lib:format("~.3f", [V])).
r(_, none) -> "-";
r(A, B) -> lists:flatten(io_lib:format("~.2fx", [A / B])).
