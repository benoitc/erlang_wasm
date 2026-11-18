-module(bench).
-export([run/0]).
%% Cold wasm_component:prepare/1, minimum of 5 batches of 200, per fixture.
run() ->
    {ok, _} = application:ensure_all_started(wasm),
    [begin
         {ok, Bin} = file:read_file("test/fixtures/component/" ++ N ++ ".component.wasm"),
         _ = [wasm_component:prepare(Bin) || _ <- lists:seq(1, 50)],
         Ts = [begin {T, _} = timer:tc(fun() -> [wasm_component:prepare(Bin) || _ <- lists:seq(1, 200)] end), T / 200 end || _ <- lists:seq(1, 5)],
         io:format("~s ~.2f~n", [N, lists:min(Ts)])
     end || N <- ["echo", "asynclifts", "ifaceexports", "realupper"]],
    ok.
