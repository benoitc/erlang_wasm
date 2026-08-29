-module(v1_cache).
-export([run/0]).

run() ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Small} = file:read_file("test/fixtures/seeds/fac.wasm"),
    {ok, Big} = file:read_file("test/fixtures/lang/qjs.wasm"),

    %% F6: a loader that dies gives its claim back.
    [begin {P, M} = spawn_monitor(fun() -> {ok, _} = wasm:load(Small) end),
           receive {'DOWN', M, process, P, _} -> ok end
     end || _ <- lists:seq(1, 21)],
    timer:sleep(300),
    io:format("F6 after 21 dead loaders: resident=~p holders=~p (want 0 / absent)~n",
              [wasm_module_cache:resident(), holders(Small)]),

    %% F7: two live callers of the same new module both keep a claim.
    Parent = self(),
    Ps = [element(1, spawn_monitor(fun() ->
            R = try wasm:load(Big) of X -> tag(X) catch C:E -> {raised, C, E} end,
            Parent ! {self(), R},
            receive done -> ok end          % stay alive, holding the claim
          end)) || _ <- [1, 2]],
    Rs = [receive {P, R} -> R after 120000 -> timeout end || P <- Ps],
    io:format("F7/F1 two concurrent loads -> ~p, holders=~p (want [ok,ok] / 2)~n",
              [Rs, holders(Big)]),

    %% F2: the server is not blocked while a large module is loading.
    Loader = spawn(fun() -> {ok, _} = wasm:load(Big), Parent ! loaded, receive done -> ok end end),
    Worst = poll(200, 0),
    receive loaded -> ok after 120000 -> exit(slow) end,
    io:format("F2 worst resident/0 latency during a 1.8 MB load: ~p ms (want < 1000)~n",
              [Worst div 1000]),
    [P ! done || P <- [Loader | Ps]],
    ok.

poll(0, Worst) -> Worst;
poll(N, Worst) ->
    {T, _} = timer:tc(fun() -> wasm_module_cache:resident() end),
    timer:sleep(1),
    poll(N - 1, max(T, Worst)).

tag({ok, _}) -> ok;
tag(X) -> X.

holders(Bin) ->
    Hash = crypto:hash(sha256, Bin),
    case maps:find(Hash, element(2, sys:get_state(wasm_module_cache))) of
        {ok, #{holders := N}} -> N;
        error -> absent
    end.
