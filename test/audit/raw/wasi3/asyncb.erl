-module(asyncb).
-export([main/1]).
%% Median microseconds per wasm_component:call_async/4 on asyncval, one
%% instance reused: read-future(42) and sum-stream(100 bytes), 5000 calls per
%% sample, five samples each, after a warm-up.
main([Fixture]) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(Fixture),
    {ok, I} = wasm_component:instantiate(Bin, #{}, #{loader => compile}),
    Bytes = binary:copy(<<1>>, 100),
    F = fun() -> {ok, 42} = wasm_component:call_async(
                              I, <<"run#read-future">>, {[{future, u32}], u32}, [42]) end,
    S = fun() -> {ok, 100} = wasm_component:call_async(
                               I, <<"run#sum-stream">>, {[{stream, u8}], u32}, [Bytes]) end,
    io:format("~.3f ~.3f~n", [median(F), median(S)]),
    halt().

median(Fun) ->
    [Fun() || _ <- lists:seq(1, 1000)],
    Ts = [begin T0 = erlang:monotonic_time(nanosecond),
                [Fun() || _ <- lists:seq(1, 5000)],
                (erlang:monotonic_time(nanosecond) - T0) / 5000 / 1000
          end || _ <- lists:seq(1, 5)],
    lists:nth(3, lists:sort(Ts)).
