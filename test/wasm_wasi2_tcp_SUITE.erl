-module(wasm_wasi2_tcp_SUITE).
-moduledoc """
A component that opens a TCP connection runs against the `wasi:sockets` host
(`wasi_preview2:sockets/1`), the tcp-client slice.

The guest imports the socket and stream interfaces and exports
`echo-to(addr, port, msg)`: it creates a tcp-socket, connects, writes the
message on the output stream and reads it back on the input stream (see
`scripts/build-component-fixture.sh`). A local echo server answers. The point of
this suite is `connect_needs_a_grant`: without a connect grant the socket never
opens, because start-connect asks `wasi_net:allows(connect, ...)`.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [an_echo_round_trips,
     connect_needs_a_grant,
     the_socket_and_streams_do_not_leak,
     an_accepted_connection_echoes,
     listen_needs_a_grant,
     poll_blocks_then_wakes_on_socket_data].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture_path()),
    [{component, Bin} | Config].

end_per_suite(_Config) -> ok.

init_per_testcase(_Case, Config) ->
    {Listen, Port} = start_echo_server(),
    [{listen, Listen}, {port, Port} | Config].

end_per_testcase(_Case, Config) ->
    _ = gen_tcp:close(?config(listen, Config)),
    ok.

%% A message written on the socket comes back over the input stream, across a
%% vector of sizes.
an_echo_round_trips(Config) ->
    Port = ?config(port, Config),
    {ok, I} = instance(Config, granted(Port)),
    [?assertEqual(Msg, echo_to(I, Port, Msg))
     || Msg <- [<<"hi">>, <<"hello world">>, binary:copy(<<$x>>, 500)]].

%% With no connect grant the socket never opens: start-connect is access-denied,
%% so the guest returns nothing. This is the capability check.
connect_needs_a_grant(Config) ->
    Port = ?config(port, Config),
    {ok, I} = instance(Config, none),
    ?assertEqual(<<>>, echo_to(I, Port, <<"blocked">>)).

%% The socket and its two streams are freed once the guest is done.
the_socket_and_streams_do_not_leak(Config) ->
    Port = ?config(port, Config),
    ?assertEqual([], wasm_component:host_live()),
    {ok, I} = instance(Config, granted(Port)),
    _ = echo_to(I, Port, <<"data">>),
    ?assertEqual([], wasm_component:host_live()).

%% The guest binds, listens and accepts; a client connects and its message comes
%% back. The guest runs in its own process (accept blocks and the instance is
%% owned by the calling process), while the test connects as the client.
an_accepted_connection_echoes(Config) ->
    Bin = ?config(component, Config),
    Port = free_port(),
    Test = self(),
    _ = spawn(fun() -> Test ! {served, serve(Bin, Port, listen_grant(Port))} end),
    {ok, Sock} = connect_retry({127, 0, 0, 1}, Port, 100),
    ok = gen_tcp:send(Sock, <<"ping">>),
    {ok, Echo} = gen_tcp:recv(Sock, 4, 5000),
    _ = gen_tcp:close(Sock),
    ?assertEqual(<<"ping">>, Echo),
    receive {served, R} -> ?assertEqual(<<"ping">>, R)
    after 6000 -> ct:fail(server_did_not_return) end.

%% With no listen grant the guest never binds: start-bind is access-denied.
listen_needs_a_grant(Config) ->
    Bin = ?config(component, Config),
    Port = free_port(),
    Test = self(),
    _ = spawn(fun() -> Test ! {served, serve(Bin, Port, none)} end),
    receive {served, R} -> ?assertEqual(<<>>, R)
    after 6000 -> ct:fail(server_did_not_return) end.

%% Polling an input stream backed by a socket with no data yet blocks (it does not
%% return an empty set) and wakes once data arrives. Fail-first: poll returned [] at
%% once for a non-empty set of not-ready sockets and never woke on data.
poll_blocks_then_wakes_on_socket_data(_Config) ->
    %% A socket-backed input stream carries a wasi_sock2 handle (the TCP backend),
    %% so the connection is set up through it.
    {ok, Listen} = wasi_sock2:open(inet),
    ok = wasi_sock2:bind(Listen, {{127, 0, 0, 1}, 0}),
    {ok, {_, Port}} = wasi_sock2:sockname(Listen),
    ok = wasi_sock2:listen(Listen, 32),
    {ok, Client} = wasi_sock2:open(inet),
    ok = wasi_sock2:connect(Client, {{127, 0, 0, 1}, Port}, 2000),
    {ok, Server} = wasi_sock2:accept(Listen, 2000),
    In = wasm_component:host_new(input_stream, {socket, Server, <<>>}),
    P = wasm_component:host_new(pollable, {stream, In}),
    _ = spawn(fun() -> timer:sleep(150), wasi_sock2:send(Client, <<"hi">>) end),
    T0 = erlang:monotonic_time(millisecond),
    ?assertEqual([0], wasi_preview2:poll([P])),
    ?assert(erlang:monotonic_time(millisecond) - T0 >= 100),
    wasm_component:host_drop(P), wasm_component:host_drop(In),
    wasi_sock2:close(Server), wasi_sock2:close(Client), wasi_sock2:close(Listen).

%%% -------------------------------------------------------------- helpers ---

%% Instantiate and run the guest server in this (fresh) process.
serve(Bin, Port, Grant) ->
    {ok, I} = wasm_component:instantiate(
                Bin, maps:merge(wasi_preview2:sockets(#{grant => Grant}),
                                wasi_preview2:io())),
    {ok, V} = wasm_component:call(I, <<"serve-on">>, {[u16], {list, u8}}, [Port]),
    V.

connect_retry(_Addr, _Port, 0) -> {error, timeout};
connect_retry(Addr, Port, N) ->
    case gen_tcp:connect(Addr, Port, [binary, {active, false}], 100) of
        {ok, Sock}      -> {ok, Sock};
        {error, _}      -> timer:sleep(20), connect_retry(Addr, Port, N - 1)
    end.

free_port() ->
    {ok, L} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, P} = inet:port(L),
    _ = gen_tcp:close(L),
    P.

listen_grant(Port) ->
    #{listen => [{tcp, <<"127.0.0.1">>, Port}]}.

echo_to(I, Port, Msg) ->
    <<A, B, C, D>> = <<127, 0, 0, 1>>,
    {ok, V} = wasm_component:call(
                I, <<"echo-to">>,
                {[u8, u8, u8, u8, u16, {list, u8}], {list, u8}},
                [A, B, C, D, Port, Msg]),
    V.

granted(Port) ->
    #{connect => [{tcp, <<"127.0.0.1">>, Port}]}.

instance(Config, Grant) ->
    Imports = maps:merge(wasi_preview2:sockets(#{grant => Grant}),
                         wasi_preview2:io()),
    wasm_component:instantiate(?config(component, Config), Imports).

start_echo_server() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false},
                                      {ip, {127, 0, 0, 1}}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    _ = spawn(fun() -> accept_loop(Listen) end),
    {Listen, Port}.

accept_loop(Listen) ->
    case gen_tcp:accept(Listen) of
        {ok, Sock}      -> _ = spawn(fun() -> echo_conn(Sock) end), accept_loop(Listen);
        {error, closed} -> ok
    end.

echo_conn(Sock) ->
    case gen_tcp:recv(Sock, 0) of
        {ok, Data}      -> _ = gen_tcp:send(Sock, Data), echo_conn(Sock);
        {error, _}      -> ok
    end.

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "wasitcp.component.wasm"]).
