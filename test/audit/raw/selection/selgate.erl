-module(selgate).
%% Applies experiment S's gates, written before the run, to sel/time.terms.
-export([main/1]).

main([File]) -> main([File, none]);
main([File, Rerun]) ->
    Orig = tagged(File),
    Valid = fun(Rs) -> lists:all(fun(R) -> cool(R) end, Rs) end,
    Groups = group(Orig),
    Kept = maps:filter(fun(_, Rs) -> Valid(Rs) end, Groups),
    Redo = maps:keys(maps:without(maps:keys(Kept), Groups)),
    Fresh = case Rerun of none -> #{}; _ -> group(tagged(Rerun)) end,
    Replaced = maps:with(Redo, maps:filter(fun(_, Rs) -> Valid(Rs) end, Fresh)),
    Missing = Redo -- maps:keys(Replaced),
    io:format("pairs kept ~p, replaced ~p, missing ~p ~p~n",
              [map_size(Kept), map_size(Replaced), length(Missing), Missing]),
    Use = maps:merge(Kept, Replaced),
    Pairs = [{O, S, pair(O, S, Rs)} || {{S, O, _Rd}, Rs} <- maps:to_list(Use)],
    Null = gate("null", Pairs),
    io:format("null ~p~n", [Null]),
    case Null of
        #{pass := true} ->
            [io:format("~s ~p~n", [S, gate(S, Pairs)]) || S <- ["s1", "s2"]];
        _ -> io:format("INCONCLUSIVE: null failed~n")
    end,
    halt().

%% A run counts only if it started and ended below load 8.
cool(R) -> maps:get(load_start, R) < 8.0 andalso maps:get(load_end, R) < 8.0.

tagged(File) ->
    {ok, Runs} = file:consult(File),
    [{lists:sublist(string:lexemes(maps:get(tag, R), ":"), 4), R}
     || R <- Runs].

%% {Set, Ordering, Round} => [First, Second]; a rerun file holds only
%% complete pairs, and the last one for a key wins.
group(Tagged) ->
    M = lists:foldl(fun({[O, Rd, S, Pos], R}, A) ->
                            maps:update_with({S, O, Rd},
                                             fun(P) -> P#{Pos => R} end,
                                             #{Pos => R}, A)
                    end, #{}, Tagged),
    maps:map(fun(_, #{"first" := F, "second" := Sd}) -> [F, Sd] end, M).

pair(O, S, [First, Second]) -> base_variant(O, S, First, Second).

base_variant(_, "null", First, Second) -> {First, Second};
base_variant("F", _, First, Second) -> {First, Second};
base_variant("R", _, First, Second) -> {Second, First}.

warm(R) -> median(maps:get(warm_us, R)).
cold(R) -> maps:get(cold_us, R).

gate(Set, Pairs) ->
    Per = fun(O) -> [BV || {O1, S, BV} <- Pairs, O1 =:= O, S =:= Set] end,
    Ord = fun(O) ->
              Ps = Per(O),
              #{n => length(Ps),
                cold => median([cold(V) / cold(B) || {B, V} <- Ps]),
                warm => median([warm(V) / warm(B) || {B, V} <- Ps]),
                cold_pairs => [round3(cold(V) / cold(B)) || {B, V} <- Ps],
                warm_pairs => [round3(warm(V) / warm(B)) || {B, V} <- Ps]}
          end,
    F = Ord("F"), R = Ord("R"),
    All = Per("F") ++ Per("R"),
    Sides = [[cold(B) || {B, _} <- All], [cold(V) || {_, V} <- All],
             [warm(B) || {B, _} <- All], [warm(V) || {_, V} <- All]],
    Bimodal = [S || S <- Sides, bimodal(S) =:= true],
    Untestable = [x || S <- Sides, bimodal(S) =:= too_few_to_test],
    Pass = case Set of
               "null" ->
                   lists:all(fun(#{cold := C, warm := W}) ->
                                     in(C) andalso in(W)
                             end, [F, R]) andalso Bimodal =:= [];
               _ ->
                   Limit = case Set of "s1" -> 0.85; "s2" -> 0.90 end,
                   lists:all(fun(#{cold := C, warm := W}) ->
                                     C =< Limit andalso W =< 1.03
                             end, [F, R]) andalso Bimodal =:= []
           end,
    #{pass => Pass, f => F, r => R, bimodal_sides => length(Bimodal),
      sides_too_few_for_bimodality => length(Untestable),
      base_cold_s => median([cold(B) || {B, _} <- All]) / 1.0e6,
      variant_cold_s => median([cold(V) || {_, V} <- All]) / 1.0e6,
      base_warm_ms => median([warm(B) || {B, _} <- All]) / 1000,
      variant_warm_ms => median([warm(V) || {_, V} <- All]) / 1000}.

in(X) -> X >= 0.95 andalso X =< 1.05.

round3(X) -> round(X * 1000) / 1000.

median(L) ->
    S = lists:sort(L), N = length(S),
    case N rem 2 of
        1 -> lists:nth(N div 2 + 1, S);
        0 -> (lists:nth(N div 2, S) + lists:nth(N div 2 + 1, S)) / 2
    end.

%% As workerbench's ph_bimodal/1: a gap of more than 2x between neighbours,
%% with at least three values on each side of it.
bimodal(L) when length(L) < 6 -> too_few_to_test;
bimodal(L) ->
    S = lists:sort(L), N = length(S),
    [I || I <- lists:seq(3, N - 3),
          lists:nth(I + 1, S) / max(1, lists:nth(I, S)) > 2.0] =/= [].
