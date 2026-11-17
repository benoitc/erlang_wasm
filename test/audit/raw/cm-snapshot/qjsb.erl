-module(qjsb).
-export([main/1]).
%% Median milliseconds per request of a QuickJS reactor worker, which restores
%% a core snapshot for each: the conformance kit's `echo', 100 requests per
%% sample, five samples, after a warm-up of 20.
main([Path]) ->
    {ok, _} = application:ensure_all_started(wasm),
    Opts = #{path => list_to_binary(Path)},
    {ok, W} = wasm_script_worker:start_link(wasm_javascript, Opts#{root => scratch}),
    Req = wasm_adapter_conformance:fixture(wasm_javascript, echo, Opts),
    Run = fun() -> {ok, _} = wasm_script_worker:run(W, Req) end,
    [Run() || _ <- lists:seq(1, 20)],
    Ts = [begin T0 = erlang:monotonic_time(nanosecond),
                [Run() || _ <- lists:seq(1, 100)],
                (erlang:monotonic_time(nanosecond) - T0) / 100 / 1000000
          end || _ <- lists:seq(1, 5)],
    io:format("~.3f~n", [lists:nth(3, lists:sort(Ts))]),
    halt().
