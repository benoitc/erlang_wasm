-module(floor).
-export([main/1]).

%% The same loop the .wasm benchmark runs, written in Erlang. This is the floor:
%% no interpreter can be faster than the BEAM doing the arithmetic directly.
native(I, N, Acc) when I >= N -> Acc;
native(I, N, Acc0) ->
    Acc1 = wrap(Acc0 + I * 3),
    Acc2 = Acc1 bxor (Acc1 bsr 7),
    native(I + 1, N, Acc2).

wrap(V) ->
    case V band 16#FFFFFFFF of
        U when U >= 16#80000000 -> U - 16#100000000;
        U -> U
    end.

main([NS]) ->
    {ok, _} = application:ensure_all_started(wasm),
    N = list_to_integer(NS),
    io:format("native BEAM   ~.1f ns/iter~n", [min_of(5, fun() -> native(0, N, 0) end) / N]),
    {ok, Bin} = file:read_file("bench/loop.wasm"),
    {ok, M} = wasm:compile(Bin),
    {ok, I} = wasm:instantiate(M, #{}),
    io:format("interpreted   ~.1f ns/iter~n",
              [min_of(5, fun() -> wasm:call(I, ~"bench", [N]) end) / N]),
    %% What the interpretation costs in memory, which is what a cons-list stack
    %% and a record update per instruction show up as.
    allocation(I, N),
    init:stop().

min_of(R, F) ->
    lists:min([element(1, timer:tc(F)) * 1000 || _ <- lists:seq(1, R)]).

allocation(Inst, N) ->
    Self = self(),
    P = spawn(fun() ->
                  receive go -> ok end,
                  {ok, _} = wasm:call(Inst, ~"bench", [N]),
                  {garbage_collection_info, G} = process_info(self(), garbage_collection_info),
                  {reductions, R} = process_info(self(), reductions),
                  Self ! {done, proplists:get_value(minor_gcs, G), R}
              end),
    P ! go,
    receive
        {done, Gcs, Reds} ->
            io:format("              ~.1f reductions/iter, ~p minor GCs for ~p iters~n",
                      [Reds / N, Gcs, N])
    after 600000 -> io:format("timeout~n")
    end.
