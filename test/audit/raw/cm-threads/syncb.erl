-module(syncb).
-export([main/1]).
%% Median microseconds per wasm_component:call/4 on composed's `run', a
%% synchronous call into a nested component, one instance reused: 20000
%% calls per sample, five samples, after a warm-up.
main([Fixture]) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(Fixture),
    {ok, I} = wasm_component:instantiate(Bin, #{}, #{loader => compile}),
    F = fun() -> {ok, 42} = wasm_component:call(I, <<"run">>, {[], u32}, []) end,
    io:format("~.3f~n", [median(F)]),
    halt().

median(Fun) ->
    [Fun() || _ <- lists:seq(1, 2000)],
    Ts = [begin T0 = erlang:monotonic_time(nanosecond),
                [Fun() || _ <- lists:seq(1, 20000)],
                (erlang:monotonic_time(nanosecond) - T0) / 20000 / 1000
          end || _ <- lists:seq(1, 5)],
    lists:nth(3, lists:sort(Ts)).
