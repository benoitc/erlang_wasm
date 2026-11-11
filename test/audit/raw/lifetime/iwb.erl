-module(iwb).
-export([main/0]).
%% Median microseconds per wasm_instance_worker:call/4 round trip, 10,000
%% calls of an empty export with a finite timeout, after a warm-up.
main() ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, P} = wasm_wat:module(<<"(module (func (export \"nop\")))">>),
    {ok, M} = wasm_validate:module(P),
    {ok, W} = wasm_instance_worker:start_link(M),
    Call = fun() -> {ok, []} = wasm_instance_worker:call(W, <<"nop">>, [], 5000) end,
    [Call() || _ <- lists:seq(1, 2000)],
    Ts = [begin T0 = erlang:monotonic_time(nanosecond),
                [Call() || _ <- lists:seq(1, 10000)],
                (erlang:monotonic_time(nanosecond) - T0) / 10000 / 1000
          end || _ <- lists:seq(1, 5)],
    io:format("~.2f~n", [lists:nth(3, lists:sort(Ts))]),
    halt().
