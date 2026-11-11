-module(waitp).
-export([main/0]).
%% Median microseconds per wasm_wait:wait/4 that registers, parks with a zero
%% timeout and times out: the parking path, 100,000 calls per sample.
%% the path that gained a cast; parking is dominated by the wake-up.
main() ->
    {ok, _} = application:ensure_all_started(wasm),
    M = make_ref(),
    R = fun() -> equal end,
    W = fun() -> 2 = wasm_wait:wait(M, 0, R, 0) end,
    [W() || _ <- lists:seq(1, 20000)],
    Ts = [begin T0 = erlang:monotonic_time(nanosecond),
                [W() || _ <- lists:seq(1, 100000)],
                (erlang:monotonic_time(nanosecond) - T0) / 100000 / 1000
          end || _ <- lists:seq(1, 5)],
    io:format("~.3f~n", [lists:nth(3, lists:sort(Ts))]),
    halt().
