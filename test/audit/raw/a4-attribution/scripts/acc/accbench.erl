-module(accbench).
%% Scratch (A4 attribution): ns per compiled memory-0 access by class, on a
%% restored memory. One fresh process; 7 timed calls, minimum.
%%   erl ... -run accbench main ACCWASM
-export([main/1]).
-include("wasm_exec.hrl").
-define(C, #{compile => true, compile_after => 1, compile_force => true,
             compile_sync => true, fuel => infinity}).
-define(N, 3_000_000).

main([Wasm]) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bytes} = file:read_file(Wasm),
    R = benchlib:in_process(fun() -> run(Bytes) end),
    io:format("~p~n", [R]),
    halt().

run(Bytes) ->
    {ok, M} = wasm:load(Bytes),
    {ok, I0} = wasm:instantiate(M, #{}, #{snapshotable => true, fuel => infinity}),
    {ok, _} = wasm:call(I0, ~"init", [0]),
    {ok, S} = wasm:snapshot(I0, #{}),
    ok = wasm:destroy(I0),
    {ok, I} = wasm:restore(S, #{}, ?C),
    {ok, _} = wasm:call(I, ~"touch", [0, 3], ?C),
    Cases = [{ld_hit, ~"ld", [?N, 0, 0]},
             {ld_miss_private, ~"ld", [?N, 4096, 0]},
             {ld_untouched, ~"ld", [?N, 0, 32768]},
             {ld_untouched3, ~"ld", [?N, 4096, 32768]},
             {st_hit, ~"st", [?N, 0, 0]},
             {st_miss_private, ~"st", [?N, 4096, 0]}],
    [spin(I, F, [1000, St, B], 200) || {_, F, [_, St, B]} <- Cases],
    [{K, ns(I, F, A)} || {K, F, A} <- Cases] ++
        [{img_bytes, img(I)}, {counts, wasm_jit:counts()}].

ns(I, F, A) ->
    T = lists:min([element(1, timer:tc(fun() ->
                                               {ok, _} = wasm:call(I, F, A, ?C)
                                       end)) || _ <- lists:seq(1, 7)]),
    T * 1000 / ?N.

spin(_I, _F, _A, 0) -> erlang:error(never_entered);
spin(I, F, A, K) ->
    E0 = maps:get(entered, wasm_jit:counts()),
    {ok, _} = wasm:call(I, F, A, ?C),
    case maps:get(entered, wasm_jit:counts()) > E0 of
        true -> ok;
        false -> timer:sleep(20), spin(I, F, A, K - 1)
    end.

img(I) ->
    case maps:get(img_bytes, wasm_memory:field_indices(), undefined) of
        undefined -> no_image;
        Ix -> {Mem} = (wasm_instance:mut(I))#mut.mems, element(Ix, Mem)
    end.
