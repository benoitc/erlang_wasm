-module(zmicro).
-export([main/0]).
t(F, N) -> erlang:garbage_collect(), T0 = erlang:monotonic_time(nanosecond),
           loop(F, N), (erlang:monotonic_time(nanosecond) - T0) / N / 1000.
loop(_F, 0) -> ok;
loop(F, N) -> _ = F(), loop(F, N - 1).
z64(B) -> case B of <<0:(65536 * 8)>> -> z; _ -> nz end.
z4(B) -> case B of <<0:(4096 * 8)>> -> z; _ -> nz end.
sr(_C, _I, <<>>) -> ok;
sr(C, I, <<W:64/little, R/binary>>) -> atomics:put(C, I, W), sr(C, I + 1, R).
page(Pieces) ->
    {End, Parts} = lists:foldl(fun({Off, Bin}, {At, Acc}) ->
                                       {Off + byte_size(Bin),
                                        [Bin, <<0:((Off - At) * 8)>> | Acc]}
                               end, {0, []}, lists:reverse(Pieces)),
    binary:copy(iolist_to_binary(lists:reverse([<<0:((65536 - End) * 8)>> | Parts]))).
main() ->
    P4 = crypto:strong_rand_bytes(4096), B = crypto:strong_rand_bytes(65536),
    Z = binary:copy(<<0:524288>>),
    Run = crypto:strong_rand_bytes(30000),
    C = atomics:new(512, [{signed, false}]),
    io:format("z64 pattern, nonzero page ~.2f us~n", [t(fun() -> z64(B) end, 5000)]),
    io:format("z64 pattern, zero page ~.2f us~n", [t(fun() -> z64(Z) end, 5000)]),
    io:format("z4 pattern, nonzero 4K ~.3f us~n", [t(fun() -> z4(P4) end, 50000)]),
    io:format("scatter 512 words ~.2f us~n", [t(fun() -> sr(C, 1, P4) end, 50000)]),
    io:format("page/1 build, one 30000-byte piece at 1000 ~.2f us~n",
              [t(fun() -> page([{1000, Run}]) end, 5000)]),
    io:format("<<0:(34536*8)>> pad ~.2f us~n", [t(fun() -> pad(34536) end, 5000)]),
    halt().
pad(N) -> <<0:(N * 8)>>.
