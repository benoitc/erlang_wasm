-module(callk).
-export([main/1]).
%% The worst case for a per-call cost: a top-level `wasm:call/3' of a function
%% that returns a constant. Nanoseconds a call, the minimum of five runs of
%% 200,000 calls, in a VM of its own with the application started.
main(_) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, M} = wasm:compile({wat, ~"(module (func (export \"k\") (result i32) (i32.const 7)))"}),
    {ok, I} = wasm:instantiate(M, #{}),
    N = 200000,
    _ = [wasm:call(I, ~"k", []) || _ <- lists:seq(1, 20000)],
    Ts = [begin {T, _} = timer:tc(fun() -> loop(N, I) end), T * 1000 / N end
          || _ <- lists:seq(1, 5)],
    io:format("callk_ns ~.1f~n", [lists:min(Ts)]),
    halt().

loop(0, _I) -> ok;
loop(N, I) -> {ok, [7]} = wasm:call(I, ~"k", []), loop(N - 1, I).
