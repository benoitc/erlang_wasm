-module(sbench).
-export([main/1]).
%% One request served through wasi_preview3:run_serve/4 with its imports and a
%% prepared component built once, as a server does: microseconds a request,
%% median of seven rounds of 300 after a warm-up.
main([Fixture]) ->
    ok = application:load(wasm),
    ok = application:set_env(wasm, max_module_loads_per_second, 1000000),
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(Fixture),
    {ok, P} = wasm_component:prepare(Bin),
    _ = wasm_component:hold(P),
    Imports = wasi_preview3:serve_imports(Bin, #{}),
    Req = #{method => <<"GET">>, path => <<"/">>, scheme => <<"http">>,
            authority => <<"localhost">>, headers => [], body => <<>>},
    One = fun() -> {ok, 200, _, _} = wasi_preview3:run_serve(P, Req, #{}, Imports) end,
    _ = [One() || _ <- lists:seq(1, 100)],
    Rs = [begin
              T0 = erlang:monotonic_time(nanosecond),
              _ = [One() || _ <- lists:seq(1, 300)],
              (erlang:monotonic_time(nanosecond) - T0) / 300 / 1000
          end || _ <- lists:seq(1, 7)],
    io:format("~.1f~n", [lists:nth(4, lists:sort(Rs))]),
    halt().
