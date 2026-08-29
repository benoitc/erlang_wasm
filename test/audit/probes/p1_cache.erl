-module(p1_cache).
-export([run/0]).

run() ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Small} = file:read_file("test/fixtures/seeds/fac.wasm"),
    lead1(Small),
    lead2(),
    ok.

%% LEAD 1: a process loads and dies without unloading.
lead1(Bin) ->
    Before = wasm_module_cache:resident(),
    {Pid, Mon} = spawn_monitor(fun() -> {ok, _H} = wasm:load(Bin) end),
    receive {'DOWN', Mon, process, Pid, _} -> ok after 5000 -> exit(no_down) end,
    timer:sleep(200),
    After = wasm_module_cache:resident(),
    Holders = holders(Bin),
    io:format("LEAD1 resident before=~p after=~p holders=~p~n",
              [Before, After, Holders]),
    %% and repeat it: does the count keep climbing for the same module?
    [begin {P, M} = spawn_monitor(fun() -> {ok, _} = wasm:load(Bin) end),
           receive {'DOWN', M, process, P, _} -> ok after 5000 -> exit(no_down) end
     end || _ <- lists:seq(1, 20)],
    timer:sleep(200),
    io:format("LEAD1 after 20 more dead loaders: resident=~p holders=~p~n",
              [wasm_module_cache:resident(), holders(Bin)]).

%% LEAD 2: two processes load the same NEW module concurrently.
lead2() ->
    {ok, Big} = file:read_file("test/fixtures/lang/qjs.wasm"),
    Parent = self(),
    Fs = [spawn(fun() -> Parent ! {self(), wasm:load(Big)} end) || _ <- [1, 2]],
    Rs = [receive {P, R} -> R after 60000 -> timeout end || P <- Fs],
    io:format("LEAD2 both loads: ~p~n", [[element(1, R) || R <- Rs]]),
    io:format("LEAD2 holders after 2 concurrent loads = ~p (expect 2)~n",
              [holders(Big)]),
    [{ok, H1}, {ok, H2}] = Rs,
    ok = wasm:unload(H1),
    io:format("LEAD2 after first unload, holders=~p~n", [holders(Big)]),
    io:format("LEAD2 second holder can still use its handle: ~p~n",
              [case wasm_module_cache:get(H2) of
                   {ok, _} -> ok;
                   E -> E
               end]).

holders(Bin) ->
    Hash = crypto:hash(sha256, Bin),
    St = sys:get_state(wasm_module_cache),
    R = element(2, St),
    case maps:find(Hash, R) of
        {ok, #{holders := N}} -> N;
        error -> absent
    end.
