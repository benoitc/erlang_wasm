-module(workerb).
-export([main/1]).
%% Median microseconds per wasm_script_worker:run/2, one worker:
%% 300 requests per sample, five samples, after a warm-up of 50. The module
%% cache's load rate is raised for both arms: the cold path compiles its cores
%% again on every request, and at its default of 50 a second it is refused
%% before it is measured.
main([Fixture, Image]) ->
    ok = application:load(wasm),
    ok = application:set_env(wasm, max_module_loads_per_second, 1000000),
    {ok, _} = application:ensure_all_started(wasm),
    Opts = #{root => scratch, fixture => list_to_atom(Fixture),
             image => list_to_atom(Image)},
    {ok, W} = wasm_script_worker:start_link(snapb_adapter, Opts),
    Run = fun() -> {ok, _} = wasm_script_worker:run(W, #{}) end,
    [Run() || _ <- lists:seq(1, 50)],
    Ts = [begin T0 = erlang:monotonic_time(nanosecond),
                [Run() || _ <- lists:seq(1, 300)],
                (erlang:monotonic_time(nanosecond) - T0) / 300 / 1000
          end || _ <- lists:seq(1, 5)],
    io:format("~.1f~n", [lists:nth(3, lists:sort(Ts))]),
    halt().
