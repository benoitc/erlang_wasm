-module(wasm_prof_c).
%% Scratch counters for the A4 attribution, compiled only into the
%% instrumented tree erlang_wasm-attr-inst. Never a timed arm.
-export([init/0, reset/0, read/0, hit/1, add/2, st/3, st_range/3,
         rec_on/1, regions/0]).
-define(N, 64).
-define(T, attr_w).

init() ->
    persistent_term:put(?MODULE, counters:new(?N, [write_concurrency])),
    case ets:info(?T) of
        undefined -> ets:new(?T, [named_table, public, set,
                                  {write_concurrency, true}]);
        _ -> ok
    end,
    ok.

rec_on(B) -> persistent_term:put({?MODULE, rec}, B).

reset() ->
    C = persistent_term:get(?MODULE),
    [counters:put(C, I, 0) || I <- lists:seq(1, ?N)],
    try ets:delete_all_objects(?T) catch _:_ -> ok end,
    ok.

read() ->
    C = persistent_term:get(?MODULE),
    maps:from_list([{I, V} || I <- lists:seq(1, ?N),
                              V <- [counters:get(C, I)], V =/= 0]).

hit(I) ->
    case persistent_term:get(?MODULE, undefined) of
        undefined -> ok;
        C -> counters:add(C, I, 1)
    end.

add(I, V) ->
    case persistent_term:get(?MODULE, undefined) of
        undefined -> ok;
        C -> counters:add(C, I, V)
    end.

%% A store of N bytes at A; only the image region (below IB) is recorded, as
%% 512-byte blocks.
st(A, N, IB) when A < IB ->
    case persistent_term:get({?MODULE, rec}, false) of
        true -> blocks(A bsr 9, (min(A + N, IB) - 1) bsr 9);
        false -> ok
    end;
st(_, _, _) -> ok.

st_range(A, Len, IB) when A < IB, Len > 0 -> st(A, Len, IB);
st_range(_, _, _) -> ok.

blocks(B, L) when B > L -> ok;
blocks(B, L) -> ets:insert(?T, {B}), blocks(B + 1, L).

%% Distinct written regions at each granularity, from the 512 B blocks.
regions() ->
    Bs = [B || {B} <- ets:tab2list(?T)],
    maps:from_list([{G, length(lists:usort([B bsr S || B <- Bs]))}
                    || {G, S} <- [{512, 0}, {1024, 1}, {2048, 2}, {4096, 3},
                                  {8192, 4}]]).
