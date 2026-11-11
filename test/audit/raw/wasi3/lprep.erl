-module(lprep).
-export([main/1]).
%% Per request as the listener does it: a fresh process serving one request,
%% from the bytes or from the prepared component. Interleaved rounds.
main([Fixture]) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(Fixture),
    {ok, Prep} = wasm_component:prepare(Bin),
    ok = wasm_component:hold(Bin),
    Req = #{method => <<"GET">>, path => <<"/">>, scheme => <<"http">>,
            authority => <<"localhost">>, headers => [], body => <<>>},
    Imports = wasi_preview3:serve_imports(Bin, #{}),
    Serve = fun(C) -> fun() -> {ok, 200, _, _} = wasi_preview3:run_serve(C, Req, #{}, Imports) end end,
    Run = fun(F, N) -> T0 = erlang:monotonic_time(microsecond),
                       [begin {P, M} = spawn_monitor(fun() -> F(), exit(normal) end),
                              receive {'DOWN', M, process, P, normal} -> ok end end || _ <- lists:seq(1, N)],
                       (erlang:monotonic_time(microsecond) - T0) / N end,
    _ = Run(Serve(Bin), 50), _ = Run(Serve(Prep), 50),
    Rounds = [{Run(Serve(Bin), 200), Run(Serve(Prep), 200)} || _ <- lists:seq(1, 7)],
    Med = fun(L) -> lists:nth(4, lists:sort(L)) end,
    B = Med([X || {X, _} <- Rounds]), P = Med([Y || {_, Y} <- Rounds]),
    io:format("bytes ~.1f us, prepared ~.1f us, ratio ~.3f~n~p~n", [B, P, P / B, Rounds]),
    halt().
