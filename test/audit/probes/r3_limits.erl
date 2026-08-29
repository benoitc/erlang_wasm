-module(r3_limits).
-export([run/0]).
run() ->
    {ok, _} = application:ensure_all_started(wasm),
    io:format("node page budget: ~p, in use: ~p~n",
              [wasm_engine:page_limit(), wasm_engine:pages_in_use()]),
    Big = ~"(module (memory 300))",
    {ok, P} = wasm_wat:module(Big), {ok, M} = wasm_validate:module(P),
    L = wasm_limits:untrusted(),
    io:format("limit says max_memory_pages = ~p~n", [maps:get(max_memory_pages, L)]),
    case wasm:instantiate(M, #{}, L) of
        {ok, I} ->
            {ok, Pages} = wasm:memory_size(I),
            io:format("RESULT: instantiated with ~p pages, limit not enforced~n", [Pages]),
            wasm:destroy(I);
        E -> io:format("RESULT: refused, ~p~n", [E])
    end,
    io:format("max_host_calls validated? ~p~n",
              [wasm_limits:validate(#{max_host_calls => -1})]).
