-module(v2_wait).
-export([run/0]).
run() ->
    {ok, _} = application:ensure_all_started(wasm),
    Eq = fun() -> equal end,
    Parent = self(),
    A = spawn(fun() -> Parent ! {self(), wasm_wait:wait(mem, 0, Eq, 10000000000)} end),
    timer:sleep(200),
    io:format("table owner: ~p (engine is ~p)~n",
              [ets:info(wasm_waiters, owner), whereis(wasm_engine)]),
    B = spawn(fun() -> Parent ! {self(), wasm_wait:wait(mem, 64, Eq, 10000000000)} end),
    timer:sleep(200),
    exit(A, kill),
    timer:sleep(200),
    io:format("after killing A, table exists: ~p~n", [ets:whereis(wasm_waiters) =/= undefined]),
    io:format("notify(B) woke ~p~n", [wasm_wait:notify(mem, 64, 1)]),
    receive
        {B, 0} -> io:format("B: WOKEN~n");
        {B, 2} -> io:format("B: timed out (lost wakeup)~n")
    after 15000 -> io:format("B: still parked~n") end,
    %% A killed waiter's stale row must not consume the count.
    C = spawn(fun() -> Parent ! {self(), wasm_wait:wait(mem, 128, Eq, 10000000000)} end),
    timer:sleep(200),
    exit(C, kill),
    D = spawn(fun() -> Parent ! {self(), wasm_wait:wait(mem, 128, Eq, 3000000000)} end),
    timer:sleep(300),
    io:format("rows on the shared address: ~p~n", [length(ets:lookup(wasm_waiters, {mem, 128}))]),
    io:format("notify(count=1) woke ~p~n", [wasm_wait:notify(mem, 128, 1)]),
    receive
        {D, 0} -> io:format("D: WOKEN, the dead row did not take it~n");
        {D, 2} -> io:format("D: timed out, dead row took the wakeup~n")
    after 15000 -> io:format("D: still parked~n") end.
