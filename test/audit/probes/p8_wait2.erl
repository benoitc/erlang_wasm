-module(p8_wait2).
-export([run/0]).

%% wasm_wait's ETS table is created by whichever process first waits or
%% notifies. Whose is it, and what happens to everyone else when that
%% process dies?
run() ->
    Eq = fun() -> equal end,
    Parent = self(),
    %% A waits first, so A creates the table.
    A = spawn(fun() -> Parent ! {self(), wasm_wait:wait(mem, 0, Eq, 10000000000)} end),
    timer:sleep(200),
    io:format("table owner is the first waiter: ~p (A = ~p)~n",
              [ets:info(wasm_waiters, owner), A]),
    %% B parks on a different address, in its own process.
    B = spawn(fun() -> Parent ! {self(), wasm_wait:wait(mem, 64, Eq, 10000000000)} end),
    timer:sleep(200),
    io:format("waiters registered: ~p~n", [length(ets:tab2list(wasm_waiters))]),

    %% A is killed. This is exactly what a worker timeout does.
    exit(A, kill),
    timer:sleep(200),
    io:format("after killing A, table exists: ~p~n",
              [ets:whereis(wasm_waiters) =/= undefined]),

    %% Now try to wake B, which never went anywhere.
    Woken = wasm_wait:notify(mem, 64, 1),
    io:format("notify(B's address) woke ~p agent(s)~n", [Woken]),
    receive
        {B, 0} -> io:format("B: woken normally~n");
        {B, 2} -> io:format("B: TIMED OUT despite being notified (lost wakeup)~n")
    after 15000 -> io:format("B: still parked~n")
    end.
