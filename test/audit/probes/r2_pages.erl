-module(r2_pages).
-export([run/0]).
run() ->
    {ok, _} = application:ensure_all_started(wasm),
    %% [2] one memory, two importers, each destroyed.
    {ok, Mem} = wasm_memory:new(1, 2),
    Imp = ~"(module (import \"e\" \"m\" (memory 1 2)))",
    {ok, P} = wasm_wat:module(Imp), {ok, M} = wasm_validate:module(P),
    Base = wasm_engine:pages_in_use(),
    {ok, A} = wasm:instantiate(M, #{{~"e", ~"m"} => Mem}),
    {ok, B} = wasm:instantiate(M, #{{~"e", ~"m"} => Mem}),
    io:format("[2] pages after two importers: ~p (base ~p)~n",
              [wasm_engine:pages_in_use(), Base]),
    ok = wasm:destroy(A),
    io:format("[2] after destroying importer A: ~p~n", [wasm_engine:pages_in_use()]),
    ok = wasm:destroy(B),
    io:format("[2] after destroying importer B: ~p~n", [wasm_engine:pages_in_use()]),
    io:format("[2] memory still readable by its owner: ~p~n",
              [catch wasm_memory:atomic_load(Mem, 0, 4)]),

    %% [6] does max_memory_pages stop a module declaring more?
    Big = ~"(module (memory 300))",
    {ok, P2} = wasm_wat:module(Big), {ok, M2} = wasm_validate:module(P2),
    R = wasm:instantiate(M2, #{}, wasm_limits:untrusted()),
    io:format("[6] 300-page module under a 256-page limit: ~p~n",
              [case R of {ok, I} -> wasm:destroy(I), instantiated; E -> E end]),
    io:format("[6] limits presented: ~p~n",
              [maps:keys(maps:with([max_memory_pages, max_host_calls],
                                   wasm_limits:untrusted()))]).
