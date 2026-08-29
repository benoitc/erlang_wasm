-module(sockbench).
-export([main/1]).
-include_lib("wasm/include/wasi.hrl").

main(_) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127,0,0,1}}]),
    {ok, Port} = inet:port(L),
    {ok, P} = wasm_wat:module(wasi_sock_ext_SUITE:source()),
    {ok, Mod} = wasm_validate:module(P),
    Net = #{connect => [{tcp, ~"127.0.0.1", Port}]},
    {ok, I} = wasm:instantiate(Mod, wasi_preview1:imports(#{net => Net})),
    {ok, [0]} = wasm:call(I, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_STREAM]),
    {ok, [Fd]} = wasm:call(I, ~"out_fd", []),
    ok = wasm:write_memory(I, 32, <<48:32/little, 4:32/little>>),
    ok = wasm:write_memory(I, 48, <<127,0,0,1>>),
    {ok, [0]} = wasm:call(I, ~"connect", [Fd, Port]),
    {ok, Peer} = gen_tcp:accept(L, 5000),
    ok = inet:setopts(Peer, [{active, false}]),
    ok = wasm:write_memory(I, 32, <<48:32/little, 64:32/little>>),
    ok = wasm:write_memory(I, 48, binary:copy(<<7>>, 64)),
    Echo = spawn_link(fun() -> echo(Peer) end),
    _ = Echo,
    N = 2000,
    Ts = [begin {T,_} = timer:tc(fun() -> roundtrip(I, Fd, N) end), T*1000/N end
          || _ <- lists:seq(1,5)],
    io:format("sock_send+sock_recv round trip\t~.1f ns\n", [lists:min(Ts)]),
    init:stop().

roundtrip(_I, _Fd, 0) -> ok;
roundtrip(I, Fd, N) ->
    {ok, [0]} = wasm:call(I, ~"send", [Fd, 1]),
    {ok, [0]} = wasm:call(I, ~"recv", [Fd, 1]),
    roundtrip(I, Fd, N - 1).

echo(S) ->
    case gen_tcp:recv(S, 0, 30000) of
        {ok, D} -> ok = gen_tcp:send(S, D), echo(S);
        _ -> ok
    end.
