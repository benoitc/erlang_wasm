-module(bench).
-export([run/0]).
%% Per fixture: cold wasm_component:prepare/1, and instantiating from a
%% prepared component (with one call for echo), minimum of 5 batches.
run() ->
    {ok, _} = application:ensure_all_started(wasm),
    [begin
         {ok, Bin} = file:read_file("test/fixtures/component/" ++ N ++ ".component.wasm"),
         _ = [wasm_component:prepare(Bin) || _ <- lists:seq(1, 50)],
         Prep = [batch(fun() -> wasm_component:prepare(Bin) end, 200) || _ <- lists:seq(1, 5)],
         {ok, P} = wasm_component:prepare(Bin),
         Imports = imports(N),
         Use = fun() -> {ok, I} = wasm_component:instantiate(P, Imports), call(N, I), ok = wasm_component:destroy(I) end,
         _ = [Use() || _ <- lists:seq(1, 20)],
         Inst = [batch(Use, 50) || _ <- lists:seq(1, 5)],
         io:format("~s prepare ~.2f instantiate ~.2f~n", [N, lists:min(Prep), lists:min(Inst)])
     end || N <- ["echo", "asynclifts", "ifaceexports", "realupper"]],
    ok.

batch(F, K) -> {T, _} = timer:tc(fun() -> [F() || _ <- lists:seq(1, K)] end), T / K.

imports("realupper") -> wasi_preview2:command(#{stdin => <<>>, stdout => fun(_) -> ok end});
imports(_) -> #{}.

call("echo", I) -> {ok, _} = wasm_component:call(I, ~"run", {[{list, u8}], {result, {list, u8}, string}}, [~"hello"]);
call(_, _) -> ok.
