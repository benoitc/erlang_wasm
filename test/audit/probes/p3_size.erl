-module(p3_size).
-export([run/0]).

run() ->
    {ok, Bin} = file:read_file("test/fixtures/lang/qjs.wasm"),
    io:format("qjs.wasm on disk: ~p bytes~n", [byte_size(Bin)]),
    {T1, {ok, M}} = timer:tc(fun() -> wasm:compile(Bin) end),
    io:format("compile: ~p ms~n", [T1 div 1000]),
    measure("erts_debug:size_shared/1", fun() -> erts_debug:size_shared(M) end),
    measure("erts_debug:size/1       ", fun() -> erts_debug:size(M) end),
    ok.

%% Run in a killable process with a budget, so an unbounded walk is reported
%% rather than hanging the probe.
measure(Name, F) ->
    Parent = self(),
    {P, Mon} = spawn_monitor(fun() ->
        {T, V} = timer:tc(F),
        Parent ! {self(), T, V}
    end),
    receive
        {P, T, V} ->
            erlang:demonitor(Mon, [flush]),
            io:format("~s = ~p words (~.1f MB) in ~p ms~n",
                      [Name, V, V * 8 / 1048576, T div 1000]);
        {'DOWN', Mon, process, P, Why} ->
            io:format("~s CRASHED: ~p~n", [Name, Why])
    after 30000 ->
        exit(P, kill),
        io:format("~s DID NOT FINISH within 30 s~n", [Name])
    end.
