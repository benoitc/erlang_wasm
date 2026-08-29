-module(p4_race2).
-export([run/0]).

run() ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Big} = file:read_file("test/fixtures/lang/qjs.wasm"),
    Parent = self(),
    Ps = [element(1, spawn_monitor(
            fun() -> Parent ! {self(), try wasm:load(Big) of R -> {returned, tag(R)}
                                       catch C:E -> {raised, C, short(E)} end} end))
          || _ <- [1, 2]],
    Rs = [receive {P, R} -> R after 180000 -> timeout end || P <- Ps],
    io:format("LEAD2 two concurrent loads -> ~p~n", [Rs]),
    io:format("LEAD2 holders now = ~p (two callers asked for it)~n", [holders(Big)]).

tag({ok, _}) -> ok;
tag(X) -> X.
short({timeout, {gen_server, call, [Srv, Req | _]}}) ->
    {timeout, gen_server_call, Srv, element(1, Req)};
short(E) -> E.

holders(Bin) ->
    Hash = crypto:hash(sha256, Bin),
    case maps:find(Hash, element(2, sys:get_state(wasm_module_cache, 120000))) of
        {ok, #{holders := N}} -> N;
        error -> absent
    end.
