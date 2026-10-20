-module(tabmb).
-export([main/0]).
-define(NW, 16#FFFFFFFF).
main() ->
    [run(N) || N <- [196, 580, 5960]], halt().
run(N) ->
    Packed = << <<(case I rem 7 of 0 -> ?NW; _ -> I end):32>> || I <- lists:seq(0, N-1) >>,
    Id = make_ref(),
    Fresh = array:new([{size, N}, {default, null}, {fixed, false}]),
    Fresh1 = array:set(1, {funcref, Id, 3}, Fresh),
    Ms = [{a_list_foldl, fun() -> a(Packed, Id, Fresh1) end},
          {b_from_list, fun() -> b(Packed, Id, Fresh1) end},
          {c_bin_set, fun() -> c(Packed, Id, Fresh1, 0) end},
          {d_map, fun() -> d(Packed, Id, Fresh1) end}],
    true = array:to_list(a(Packed, Id, Fresh1)) =:= array:to_list(b(Packed, Id, Fresh1)),
    true = array:to_list(a(Packed, Id, Fresh1)) =:= array:to_list(c(Packed, Id, Fresh1, 0)),
    true = array:to_list(a(Packed, Id, Fresh1)) =:= array:to_list(d(Packed, Id, Fresh1)),
    [io:format("~6w ~-14w p50 ~8.2f us  min ~8.2f~n", [N, Name | stats([sample(F) || _ <- lists:seq(1, 301)])]) || {Name, F} <- Ms],
    ok.
stats(L) -> S = lists:sort(L), [lists:nth(151, S), hd(S)].
sample(F) ->
    Self = self(),
    P = spawn_opt(fun() -> T0 = erlang:monotonic_time(nanosecond), A = F(), T1 = erlang:monotonic_time(nanosecond), Self ! {t, self(), (T1 - T0)/1000, array:size(A)} end, heap()),
    receive {t, P, T, _} -> T end.
unpack(P, Id) -> [case W of ?NW -> null; F -> {funcref, Id, F} end || <<W:32>> <= P].
a(P, Id, Arr) -> lists:foldl(fun({I, V}, Acc) -> array:set(I, V, Acc) end, Arr, lists:enumerate(0, unpack(P, Id))).
b(P, Id, Arr) ->
    N = byte_size(P) div 4,
    New = array:from_list(unpack(P, Id), array:default(Arr)),
    case array:size(Arr) of N -> New; M when M > N -> lists:foldl(fun(I, Acc) -> array:set(I, array:get(I, Arr), Acc) end, array:resize(M, New), lists:seq(N, M-1)) end.
c(<<>>, _Id, Arr, _I) -> Arr;
c(<<?NW:32, R/binary>>, Id, Arr, I) -> c(R, Id, array:set(I, null, Arr), I + 1);
c(<<F:32, R/binary>>, Id, Arr, I) -> c(R, Id, array:set(I, {funcref, Id, F}, Arr), I + 1).
heap() -> case os:getenv("FLOOR") of false -> []; W -> [{min_heap_size, list_to_integer(W)}] end.

d(P, Id, Arr) ->
    N = byte_size(P) div 4,
    array:map(fun(I, _) when I < N ->
                      case P of
                          <<_:I/binary-unit:32, ?NW:32, _/binary>> -> null;
                          <<_:I/binary-unit:32, F:32, _/binary>> -> {funcref, Id, F}
                      end;
                 (_, V) -> V
              end, Arr).
