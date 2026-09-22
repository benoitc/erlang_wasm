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
     the_socket_and_streams_do_not_leak].

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

%%% -------------------------------------------------------------- helpers ---

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
