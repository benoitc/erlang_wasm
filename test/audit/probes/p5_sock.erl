-module(p5_sock).
-export([run/0]).
-include_lib("wasm/include/wasi.hrl").

%% Does wasm:destroy/1 close a socket the guest left open?
run() ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127,0,0,1}}]),
    {ok, Port} = inet:port(L),
    {ok, Parsed} = wasm_wat:module(wasi_sock_ext_SUITE:source()),
    {ok, Mod} = wasm_validate:module(Parsed),
    Net = #{connect => [{tcp, ~"127.0.0.1", Port}]},
    Before = length(erlang:ports()),
    Peers = [connect_one(Mod, Net, L, Port) || _ <- lists:seq(1, 5)],
    io:format("guest sockets connected: ~p~n", [length([ok || ok <- Peers])]),
    io:format("ports before=~p after 5 destroyed instances=~p~n",
              [Before, length(erlang:ports())]),
    %% Are the accepted peers still connected, i.e. did the guest socket die?
    io:format("peer still open after destroy (no FIN seen): ~p of 5~n",
              [length([x || {S, _} <- get(peers), still_open(S)])]),
    ok.

connect_one(Mod, Net, L, Port) ->
    {ok, I} = wasm:instantiate(Mod, wasi_preview1:imports(#{net => Net})),
    {ok, [0]} = wasm:call(I, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_STREAM]),
    {ok, [Fd]} = wasm:call(I, ~"out_fd", []),
    ok = wasm:write_memory(I, 32, <<48:32/little, 4:32/little>>),
    ok = wasm:write_memory(I, 48, <<127, 0, 0, 1>>),
    {ok, [0]} = wasm:call(I, ~"connect", [Fd, Port]),
    {ok, Peer} = gen_tcp:accept(L, 5000),
    put(peers, [{Peer, I} | case get(peers) of undefined -> []; Ps -> Ps end]),
    %% Destroy WITHOUT the guest calling sock_close.
    ok = wasm:destroy(I),
    ok.

%% If the guest socket had been closed, the peer would see a FIN and recv
%% would answer {error, closed}.
still_open(S) ->
    case gen_tcp:recv(S, 0, 300) of
        {error, timeout} -> true;
        {error, closed} -> false;
        _ -> true
    end.
