-module(cmdbench).
-export([main/1]).
%% Median milliseconds per wasi_preview2:run_command/3 of wasmtime's
%% p2_cli_hello_stdout, 30 runs per sample, five samples, after a warm-up.
main([Fixture]) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(Fixture),
    Run = fun() -> {ok, #{exit_code := 0}} = wasi_preview2:run_command(Bin, <<>>, #{}) end,
    [Run() || _ <- lists:seq(1, 5)],
    Ts = [begin T0 = erlang:monotonic_time(microsecond),
                [Run() || _ <- lists:seq(1, 30)],
                (erlang:monotonic_time(microsecond) - T0) / 30 / 1000
          end || _ <- lists:seq(1, 5)],
    io:format("~.3f~n", [lists:nth(3, lists:sort(Ts))]),
    halt().
