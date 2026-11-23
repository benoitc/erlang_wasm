-module(valdiag).
-export([main/1]).
%% Validation after decode in the same process (as wasm:compile/1 does), and
%% in a fresh process given a copy of the decoded module. Collections and
%% heap size around validation, per round.
main([Guest]) ->
    {ok, Bin} = file:read_file(filename:join(["test", "fixtures", "lang", Guest ++ ".wasm"])),
    Same = [run(fun() ->
                {ok, M} = wasm_decode:module(Bin),
                measure(M)
            end) || _ <- lists:seq(1, 5)],
    {ok, M0} = wasm_decode:module(Bin),
    Fresh = [run(fun() -> measure(M0) end) || _ <- lists:seq(1, 5)],
    io:format("~p.~n", [#{guest => Guest, same_process => best(Same), fresh_process => best(Fresh)}]),
    halt().
measure(M) ->
    {heap_size, H0} = process_info(self(), heap_size),
    {_, GC0, _} = erlang:statistics(garbage_collection),
    {minor_gcs, Mi0} = minor(),
    T0 = erlang:monotonic_time(),
    {ok, _} = wasm_validate:module(M),
    T1 = erlang:monotonic_time(),
    {minor_gcs, Mi1} = minor(),
    _ = GC0,
    #{validate_us => erlang:convert_time_unit(T1 - T0, native, microsecond),
      heap_words_before => H0, minor_gcs => Mi1 - Mi0}.
minor() ->
    {garbage_collection, L} = process_info(self(), garbage_collection),
    {minor_gcs, proplists:get_value(minor_gcs, L)}.
run(F) ->
    Self = self(),
    {P, R} = spawn_monitor(fun() -> Self ! {self(), F()} end),
    receive {P, X} -> demonitor(R, [flush]), X; {'DOWN', R, _, _, W} -> error(W) end.
best(Rs) -> hd(lists:sort(fun(A, B) -> maps:get(validate_us, A) =< maps:get(validate_us, B) end, Rs)).
