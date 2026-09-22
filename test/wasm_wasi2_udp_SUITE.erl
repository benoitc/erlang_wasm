-module(wasm_wasi2_udp_SUITE).
-moduledoc """
A component that sends and receives UDP datagrams runs against the
`wasi:sockets` host (`wasi_preview2:sockets/1`), the udp slice.

The guest imports the udp interfaces and exports `ping(addr, port, msg)`: it
creates a udp-socket, binds, opens a connected datagram stream, sends the
message and receives the reply (see `scripts/build-component-fixture.sh`). A
local echo server answers. The point of this suite is `send_needs_a_grant`:
without a connect grant the datagram stream is refused, because stream asks
`wasi_net:allows(connect, ...)`.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [a_datagram_round_trips,
     send_needs_a_grant].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture_path()),
    [{component, Bin} | Config].

end_per_suite(_Config) -> ok.

%% A datagram sent to the echo server comes back over the incoming stream.
a_datagram_round_trips(Config) ->
    Port = start_udp_echo(),
    {ok, I} = instance(Config, #{connect => [{udp, <<"127.0.0.1">>, Port}]}),
    ?assertEqual(<<"udp hello">>, ping(I, Port, <<"udp hello">>)).

%% With no connect grant the datagram stream is refused, so the guest sends
%% nothing and returns empty. This is the capability check.
send_needs_a_grant(Config) ->
    Port = start_udp_echo(),
    {ok, I} = instance(Config, none),
    ?assertEqual(<<>>, ping(I, Port, <<"blocked">>)).

%%% -------------------------------------------------------------- helpers ---

ping(I, Port, Msg) ->
    {ok, V} = wasm_component:call(
                I, <<"ping">>,
                {[u8, u8, u8, u8, u16, {list, u8}], {list, u8}},
                [127, 0, 0, 1, Port, Msg]),
    V.

instance(Config, Grant) ->
    Imports = wasi_preview2:sockets(#{grant => Grant}),
    wasm_component:instantiate(?config(component, Config), Imports).

%% A UDP echo server in its own process (it owns the socket it recvs on).
start_udp_echo() ->
    Parent = self(),
    _ = spawn(fun() ->
                  {ok, S} = gen_udp:open(0, [binary, {active, false},
                                             {ip, {127, 0, 0, 1}}]),
                  {ok, Port} = inet:port(S),
                  Parent ! {udp_port, Port},
                  udp_echo_loop(S)
              end),
    receive {udp_port, Port} -> Port after 2000 -> error(no_udp_port) end.

udp_echo_loop(S) ->
    case gen_udp:recv(S, 0) of
        {ok, {Addr, Port, Data}} -> _ = gen_udp:send(S, Addr, Port, Data),
                                    udp_echo_loop(S);
        {error, _}               -> ok
    end.

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "wasiudp.component.wasm"]).
