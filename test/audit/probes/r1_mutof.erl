-module(r1_mutof).
-export([run/0]).
run() ->
    {ok, _} = application:ensure_all_started(wasm),
    Src = ~"(module (global $g (mut i32) (i32.const 0)) (memory 1)
             (func (export \"f\") (result i32) (i32.const 7)))",
    {ok, P} = wasm_wat:module(Src),
    {ok, M} = wasm_validate:module(P),
    {ok, I} = wasm:instantiate(M, #{}),
    View = wasm_instance:root_view(I),
    %% A fresh process has no cache for this instance, so the root view has to
    %% fill it. This is the path GC root scanning takes.
    Self = self(),
    spawn(fun() -> Self ! {result, catch wasm_instance:mut_of(View)} end),
    receive
        {result, {'EXIT', {function_clause, [{M2, F, _, _} | _]}}} ->
            io:format("CRASHES: function_clause in ~p:~p~n", [M2, F]);
        {result, {'EXIT', E}} -> io:format("CRASHES: ~p~n", [element(1, E)]);
        {result, _} -> io:format("ok, no crash~n")
    after 5000 -> io:format("timeout~n") end.
