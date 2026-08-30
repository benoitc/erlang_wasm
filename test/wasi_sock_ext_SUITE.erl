%% @doc The socket extension: opening, binding and connecting from the module.
%%
%% Preview 1 has no way for a module to open a socket, so this is the WasmEdge
%% extension rather than the specification, and its structure layouts are
%% somebody else's decision. They are read from WasmEdge's own `api.hpp' and
%% the `wasmedge_wasi_socket' crate a guest compiles against.
%%
%% Layouts are the risk here, and the same one the `poll_oneoff' padding bug
%% was: a field read at the wrong offset produces a plausible number rather
%% than an error. So the structures are built here in Erlang, byte by byte, at
%% the offsets the headers fix, and read back the same way.
-module(wasi_sock_ext_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("wasi.hrl").

all() ->
    [opening_a_socket_needs_a_network_at_all,
     connects_to_a_granted_address,
     connecting_outside_the_grant_is_refused,
     a_mapped_address_is_checked_as_the_address_it_reaches,
     binds_listens_and_accepts,
     binding_wider_than_the_grant_is_refused,
     reports_both_ends_of_a_connection,
     socket_options_are_answered_or_refused,
     datagrams_carry_their_address,
     resolution_is_its_own_capability,
     a_resolved_address_gets_no_authority_from_being_resolved,
     a_made_up_service_name_mints_no_atoms,
     a_refused_out_pointer_does_not_leak_the_connection,
     a_failed_datagram_leaves_no_socket_behind,
     a_refused_out_pointer_keeps_the_socket_it_opened,
     the_socket_cap_covers_opening].

%%% ---------------------------------------------------------------- fixture ---

%% Linear memory, at fixed offsets so both sides agree:
%%   0 out-fd, 4 count, 8 iovec, 16 roflags, 20 port, 24 addr-type,
%%   32 __wasi_address_t, 40 opt size, 48 address octets, 64 data,
%%   128 raw address, 160 result array, 200/232/248 addrinfo, sockaddr, data,
%%   288 hint, 320 node, 352 service.
source() -> ~"""
(module
  (import "wasi_snapshot_preview1" "sock_open"
    (func $sock_open (param i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "sock_bind"
    (func $sock_bind (param i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "sock_listen"
    (func $sock_listen (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "sock_connect"
    (func $sock_connect (param i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "sock_accept"
    (func $sock_accept (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "sock_send"
    (func $sock_send (param i32 i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "sock_recv"
    (func $sock_recv (param i32 i32 i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "sock_send_to"
    (func $sock_send_to (param i32 i32 i32 i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "sock_recv_from"
    (func $sock_recv_from (param i32 i32 i32 i32 i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "sock_getlocaladdr"
    (func $sock_getlocaladdr (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "sock_getpeeraddr"
    (func $sock_getpeeraddr (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "sock_getsockopt"
    (func $sock_getsockopt (param i32 i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "sock_setsockopt"
    (func $sock_setsockopt (param i32 i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "sock_getaddrinfo"
    (func $sock_getaddrinfo (param i32 i32 i32 i32 i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_close"
    (func $fd_close (param i32) (result i32)))
  (memory (export "memory") 1)

  (func $iov (param $len i32)
    (i32.store (i32.const 8) (i32.const 64))
    (i32.store (i32.const 12) (local.get $len)))

  (func (export "open") (param $family i32) (param $type i32) (result i32)
    (call $sock_open (local.get $family) (local.get $type) (i32.const 0)))
  ;; The same accept, with the out-pointer past the end of a one-page memory.
  (func (export "bad_accept") (param $fd i32) (result i32)
    (call $sock_accept (local.get $fd) (i32.const 0x7FFF0000)))
  (func (export "bind") (param $fd i32) (param $port i32) (result i32)
    (call $sock_bind (local.get $fd) (i32.const 32) (local.get $port)))
  (func (export "listen") (param $fd i32) (param $backlog i32) (result i32)
    (call $sock_listen (local.get $fd) (local.get $backlog)))
  (func (export "connect") (param $fd i32) (param $port i32) (result i32)
    (call $sock_connect (local.get $fd) (i32.const 32) (local.get $port)))
  (func (export "accept") (param $fd i32) (result i32)
    (call $sock_accept (local.get $fd) (i32.const 0)))
  (func (export "send") (param $fd i32) (param $len i32) (result i32)
    (call $iov (local.get $len))
    (call $sock_send (local.get $fd) (i32.const 8) (i32.const 1)
                     (i32.const 0) (i32.const 4)))
  (func (export "recv") (param $fd i32) (param $len i32) (result i32)
    (call $iov (local.get $len))
    (call $sock_recv (local.get $fd) (i32.const 8) (i32.const 1)
                     (i32.const 0) (i32.const 4) (i32.const 16)))
  (func (export "send_to") (param $fd i32) (param $len i32) (param $port i32)
        (result i32)
    (call $iov (local.get $len))
    (call $sock_send_to (local.get $fd) (i32.const 8) (i32.const 1)
                        (i32.const 128) (local.get $port) (i32.const 0)
                        (i32.const 4)))
  ;; The same send_to, with the out-pointer past the end of a one-page memory.
  (func (export "bad_send_to") (param $fd i32) (param $len i32) (param $port i32)
        (result i32)
    (call $iov (local.get $len))
    (call $sock_send_to (local.get $fd) (i32.const 8) (i32.const 1)
                        (i32.const 128) (local.get $port) (i32.const 0)
                        (i32.const 0x7FFF0000)))
  (func (export "recv_from") (param $fd i32) (param $len i32) (result i32)
    (call $iov (local.get $len))
    (call $sock_recv_from (local.get $fd) (i32.const 8) (i32.const 1)
                          (i32.const 128) (i32.const 0) (i32.const 20)
                          (i32.const 4) (i32.const 16)))
  (func (export "getlocal") (param $fd i32) (result i32)
    (call $sock_getlocaladdr (local.get $fd) (i32.const 32) (i32.const 24)
                             (i32.const 20)))
  (func (export "getpeer") (param $fd i32) (result i32)
    (call $sock_getpeeraddr (local.get $fd) (i32.const 32) (i32.const 24)
                            (i32.const 20)))
  (func (export "getopt") (param $fd i32) (param $name i32) (result i32)
    (call $sock_getsockopt (local.get $fd) (i32.const 0) (local.get $name)
                           (i32.const 4) (i32.const 40)))
  (func (export "setopt") (param $fd i32) (param $name i32) (result i32)
    (call $sock_setsockopt (local.get $fd) (i32.const 0) (local.get $name)
                           (i32.const 4) (i32.const 4)))
  (func (export "getaddrinfo") (param $nlen i32) (param $slen i32)
        (param $max i32) (result i32)
    (call $sock_getaddrinfo (i32.const 320) (local.get $nlen)
                            (i32.const 352) (local.get $slen)
                            (i32.const 288) (i32.const 160)
                            (local.get $max) (i32.const 4)))
  (func (export "close") (param $fd i32) (result i32)
    (call $fd_close (local.get $fd)))

  (func (export "out_fd") (result i32) (i32.load (i32.const 0)))
  (func (export "count") (result i32) (i32.load (i32.const 4)))
  (func (export "roflags") (result i32) (i32.load (i32.const 16)))
  (func (export "port") (result i32) (i32.load (i32.const 20)))
  (func (export "addr_type") (result i32) (i32.load (i32.const 24)))
  (func (export "addr_size") (result i32) (i32.load (i32.const 36))))
""".

init_per_suite(Config) ->
    {ok, Parsed} = wasm_wat:module(source()),
    {ok, Mod} = wasm_validate:module(Parsed),
    [{mod, Mod} | Config].

end_per_suite(_) -> ok.

instance(Config, Net) ->
    {ok, I} = wasm:instantiate(?config(mod, Config),
                               wasi_preview1:imports(#{net => Net})),
    I.

free_port() ->
    {ok, S} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(S),
    ok = gen_tcp:close(S),
    Port.

%% Build `__wasi_address_t' at 32 pointing at the octets at 48. The length is
%% how the family is told: 4 is IPv4, 16 is IPv6.
put_address(I, Octets) ->
    put_buffer(I, byte_size(Octets)),
    ok = wasm:write_memory(I, 48, Octets).

%% The struct alone, for the calls that write an address back into it.
put_buffer(I, Size) ->
    ok = wasm:write_memory(I, 32, <<48:32/little, Size:32/little>>).

octets({A, B, C, D}) -> <<A, B, C, D>>.

taken(I, N) ->
    {ok, Bin} = wasm:read_memory(I, 64, N),
    Bin.

%% A TCP peer that echoes one message, on its own process, so the module can
%% connect and talk to it while this process drives the module.
echo_server() ->
    Self = self(),
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(L),
    spawn_link(fun() ->
                   {ok, S} = gen_tcp:accept(L, 5000),
                   {ok, Data} = gen_tcp:recv(S, 0, 5000),
                   ok = gen_tcp:send(S, Data),
                   Self ! {echoed, Data},
                   receive stop -> ok after 5000 -> ok end,
                   gen_tcp:close(S)
               end),
    {L, Port}.

%%% ------------------------------------------------------------------ opens ---

%% Opening is not itself reaching the network, but a descriptor an instance can
%% do nothing with is a slower way of saying it was not granted anything.
opening_a_socket_needs_a_network_at_all(Config) ->
    I = instance(Config, none),
    ?assertEqual({ok, [?ENOTCAPABLE]},
                 wasm:call(I, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_STREAM])),
    G = instance(Config, #{connect => [{tcp, ~"127.0.0.1", 80}]}),
    ?assertEqual({ok, [?ESUCCESS]},
                 wasm:call(G, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_STREAM])),
    ?assertEqual({ok, [3]}, wasm:call(G, ~"out_fd", [])),
    %% A family or type the extension does not define is refused rather than
    %% guessed at.
    ?assertEqual({ok, [?EAFNOSUPPORT]}, wasm:call(G, ~"open", [7, ?SOCK_TYPE_STREAM])),
    ?assertEqual({ok, [?EPROTONOSUPPORT]},
                 wasm:call(G, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_ANY])).

connects_to_a_granted_address(Config) ->
    {L, Port} = echo_server(),
    I = instance(Config, #{connect => [{tcp, ~"127.0.0.1", Port}]}),
    ?assertEqual({ok, [?ESUCCESS]},
                 wasm:call(I, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_STREAM])),
    {ok, [Fd]} = wasm:call(I, ~"out_fd", []),
    put_address(I, octets({127, 0, 0, 1})),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"connect", [Fd, Port])),
    ok = wasm:write_memory(I, 64, ~"hello"),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"send", [Fd, 5])),
    receive {echoed, Data} -> ?assertEqual(~"hello", Data)
    after 5000 -> ct:fail(no_echo)
    end,
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"recv", [Fd, 16])),
    ?assertEqual({ok, [5]}, wasm:call(I, ~"count", [])),
    ?assertEqual(~"hello", taken(I, 5)),
    ok = gen_tcp:close(L).

%% The address is checked before it reaches a socket, so nothing was attempted:
%% the errno says "not granted", not "refused" or "no route".
connecting_outside_the_grant_is_refused(Config) ->
    %% No peer is needed: the check happens before anything is attempted, which
    %% is the property under test.
    Port = free_port(),
    I = instance(Config, #{connect => [{tcp, ~"127.0.0.1", Port}]}),
    ?assertEqual({ok, [?ESUCCESS]},
                 wasm:call(I, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_STREAM])),
    {ok, [Fd]} = wasm:call(I, ~"out_fd", []),
    %% The granted address, a port that was not granted.
    put_address(I, octets({127, 0, 0, 1})),
    ?assertEqual({ok, [?ENOTCAPABLE]}, wasm:call(I, ~"connect", [Fd, Port + 1])),
    %% The granted port, an address that was not granted.
    put_address(I, octets({127, 0, 0, 2})),
    ?assertEqual({ok, [?ENOTCAPABLE]}, wasm:call(I, ~"connect", [Fd, Port])).

%% `::ffff:127.0.0.1' reaches the same host as `127.0.0.1'. It is folded before
%% the check, so it does not walk past an IPv4 grant, and the folded address is
%% what is then connected to.
a_mapped_address_is_checked_as_the_address_it_reaches(Config) ->
    {L, Port} = echo_server(),
    Mapped = <<0:80, 16#ffff:16, 127, 0, 0, 1>>,
    Denied = instance(Config, #{connect => [{tcp, ~"127.0.0.2", Port}]}),
    ?assertEqual({ok, [?ESUCCESS]},
                 wasm:call(Denied, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_STREAM])),
    {ok, [Fd0]} = wasm:call(Denied, ~"out_fd", []),
    put_address(Denied, Mapped),
    ?assertEqual({ok, [?ENOTCAPABLE]}, wasm:call(Denied, ~"connect", [Fd0, Port])),

    %% And under a grant that does cover it, the connection is made over IPv4.
    I = instance(Config, #{connect => [{tcp, ~"127.0.0.1", Port}]}),
    ?assertEqual({ok, [?ESUCCESS]},
                 wasm:call(I, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_STREAM])),
    {ok, [Fd]} = wasm:call(I, ~"out_fd", []),
    put_address(I, Mapped),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"connect", [Fd, Port])),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"getpeer", [Fd])),
    ?assertEqual({ok, [?ADDRESS_FAMILY_INET4]}, wasm:call(I, ~"addr_type", [])),
    ok = gen_tcp:close(L).

%%% ---------------------------------------------------------------- listens ---

binds_listens_and_accepts(Config) ->
    Port = free_port(),
    I = instance(Config, #{listen => [{tcp, ~"127.0.0.1", Port}]}),
    %% A grant naming one address and one port describes a socket the host can
    %% open, and it did: fd 3 is already listening on it. A range does not, so
    %% a second instance granted a range has to bind for itself, which is what
    %% the extension is for.
    Range = free_port(),
    J = instance(Config, #{listen => [{tcp, ~"127.0.0.1", {Range, Range + 1}}]}),
    ?assertEqual({ok, [?ESUCCESS]},
                 wasm:call(J, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_STREAM])),
    {ok, [Fd]} = wasm:call(J, ~"out_fd", []),
    put_address(J, octets({127, 0, 0, 1})),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(J, ~"bind", [Fd, Range])),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(J, ~"listen", [Fd, 8])),
    {ok, Peer} = gen_tcp:connect({127, 0, 0, 1}, Range,
                                 [binary, {active, false}], 1000),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(J, ~"accept", [Fd])),
    {ok, [Conn]} = wasm:call(J, ~"out_fd", []),
    ok = wasm:write_memory(J, 64, ~"hi"),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(J, ~"send", [Conn, 2])),
    ?assertEqual({ok, ~"hi"}, gen_tcp:recv(Peer, 2, 1000)),
    ok = gen_tcp:close(Peer),
    %% The first instance still has its host-opened listener on fd 3, and it
    %% can ask which port it got.
    put_buffer(I, 16),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"getlocal", [3])),
    ?assertEqual({ok, [Port]}, wasm:call(I, ~"port", [])),
    %% A buffer too small for the family is an error rather than a truncated
    %% address, which would be a different host entirely.
    put_buffer(I, 2),
    ?assertEqual({ok, [?EINVAL]}, wasm:call(I, ~"getlocal", [3])).

%% Binding `0.0.0.0' publishes a service on every interface. A loopback grant
%% must not permit it, and this is the case that says so end to end.
binding_wider_than_the_grant_is_refused(Config) ->
    Port = free_port(),
    I = instance(Config, #{listen => [{tcp, ~"127.0.0.1", {Port, Port + 1}}]}),
    ?assertEqual({ok, [?ESUCCESS]},
                 wasm:call(I, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_STREAM])),
    {ok, [Fd]} = wasm:call(I, ~"out_fd", []),
    put_address(I, octets({0, 0, 0, 0})),
    ?assertEqual({ok, [?ENOTCAPABLE]}, wasm:call(I, ~"bind", [Fd, Port])),
    %% Nor may a client bind a source port it was not granted: binding claims a
    %% local address, and that is what `listen' grants.
    put_address(I, octets({127, 0, 0, 1})),
    ?assertEqual({ok, [?ENOTCAPABLE]}, wasm:call(I, ~"bind", [Fd, Port + 2])).

%%% ----------------------------------------------------------------- shapes ---

reports_both_ends_of_a_connection(Config) ->
    {L, Port} = echo_server(),
    I = instance(Config, #{connect => [{tcp, ~"127.0.0.1", Port}]}),
    ?assertEqual({ok, [?ESUCCESS]},
                 wasm:call(I, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_STREAM])),
    {ok, [Fd]} = wasm:call(I, ~"out_fd", []),
    put_address(I, octets({127, 0, 0, 1})),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"connect", [Fd, Port])),

    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"getpeer", [Fd])),
    ?assertEqual({ok, [Port]}, wasm:call(I, ~"port", [])),
    ?assertEqual({ok, [?ADDRESS_FAMILY_INET4]}, wasm:call(I, ~"addr_type", [])),
    ?assertEqual({ok, [4]}, wasm:call(I, ~"addr_size", [])),
    {ok, Octets} = wasm:read_memory(I, 48, 4),
    ?assertEqual(<<127, 0, 0, 1>>, Octets),

    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"getlocal", [Fd])),
    {ok, [Local]} = wasm:call(I, ~"port", []),
    ?assertNotEqual(0, Local),
    ?assertNotEqual(Port, Local),
    ok = gen_tcp:close(L).

%% An option that cannot be honoured is refused. Accepting it and dropping it
%% makes a module believe it configured something, and it finds out otherwise
%% at the worst moment.
socket_options_are_answered_or_refused(Config) ->
    I = instance(Config, #{connect => [{tcp, ~"127.0.0.1", 80}]}),
    ?assertEqual({ok, [?ESUCCESS]},
                 wasm:call(I, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_STREAM])),
    {ok, [Fd]} = wasm:call(I, ~"out_fd", []),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"getopt", [Fd, ?SO_TYPE])),
    ?assertEqual({ok, [?SOCK_TYPE_STREAM]}, wasm:call(I, ~"count", [])),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"getopt", [Fd, ?SO_ACCEPTCONN])),
    ?assertEqual({ok, [0]}, wasm:call(I, ~"count", [])),
    ?assertEqual({ok, [?ENOPROTOOPT]}, wasm:call(I, ~"getopt", [Fd, ?SO_LINGER])),
    ?assertEqual({ok, [?ENOPROTOOPT]}, wasm:call(I, ~"setopt", [Fd, ?SO_RCVTIMEO])).

%%% -------------------------------------------------------------- datagrams ---

datagrams_carry_their_address(Config) ->
    {ok, Peer} = gen_udp:open(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, PeerPort} = inet:port(Peer),
    Local = free_port(),
    I = instance(Config, #{listen => [{udp, ~"127.0.0.1", {Local, Local + 1}}],
                           connect => [{udp, ~"127.0.0.1", PeerPort}]}),
    ?assertEqual({ok, [?ESUCCESS]},
                 wasm:call(I, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_DGRAM])),
    {ok, [Fd]} = wasm:call(I, ~"out_fd", []),
    put_address(I, octets({127, 0, 0, 1})),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"bind", [Fd, Local])),

    %% `sock_send_to' passes the octets with no length, so the socket's family
    %% is what says how many are there.
    ok = wasm:write_memory(I, 128, <<127, 0, 0, 1>>),
    ok = wasm:write_memory(I, 64, ~"ping"),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"send_to", [Fd, 4, PeerPort])),
    ?assertEqual({ok, {{127, 0, 0, 1}, Local, ~"ping"}},
                 gen_udp:recv(Peer, 0, 1000)),

    ok = gen_udp:send(Peer, {127, 0, 0, 1}, Local, ~"pong"),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"recv_from", [Fd, 16])),
    ?assertEqual({ok, [4]}, wasm:call(I, ~"count", [])),
    ?assertEqual({ok, [PeerPort]}, wasm:call(I, ~"port", [])),
    ?assertEqual(~"pong", taken(I, 4)),
    {ok, From} = wasm:read_memory(I, 128, 4),
    ?assertEqual(<<127, 0, 0, 1>>, From),

    %% An address the grant does not cover is refused before a packet leaves.
    ok = wasm:write_memory(I, 128, <<127, 0, 0, 2>>),
    ?assertEqual({ok, [?ENOTCAPABLE]}, wasm:call(I, ~"send_to", [Fd, 4, PeerPort])),
    ok = gen_udp:close(Peer).

%%% ------------------------------------------------------------- resolution ---

%% Resolving is a capability of its own, and it is off unless it is granted.
resolution_is_its_own_capability(Config) ->
    Off = instance(Config, #{connect => [{tcp, ~"127.0.0.1", 80}]}),
    ok = put_query(Off, ~"localhost", <<>>, 1),
    ?assertEqual({ok, [?ENOTCAPABLE]}, wasm:call(Off, ~"getaddrinfo", [9, 0, 1])),

    On = instance(Config, #{connect => [{tcp, ~"127.0.0.1", 80}],
                            resolve => allow}),
    ok = put_query(On, ~"localhost", <<>>, 4),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(On, ~"getaddrinfo", [9, 0, 4])),
    {ok, [Count]} = wasm:call(On, ~"count", []),
    ?assert(Count >= 1),
    %% The first answer, read back out of the structures the module supplied,
    %% at the offsets WasmEdge's static asserts fix.
    {ok, <<_Flags:16/little, Family:8, SockType:8, _Proto:8, _:24,
           AddrLen:32/little>>} = wasm:read_memory(On, 512, 12),
    ?assertEqual(?SOCK_TYPE_STREAM, SockType),
    ?assert(Family =:= ?ADDRESS_FAMILY_INET4 orelse Family =:= ?ADDRESS_FAMILY_INET6),
    ?assertEqual(AddrLen, case Family of ?ADDRESS_FAMILY_INET4 -> 4; _ -> 16 end),
    {ok, <<SaFamily:8, _:24, SaLen:32/little, _SaData:32/little>>} =
        wasm:read_memory(On, 512 + 32, 12),
    ?assertEqual(Family, SaFamily),
    ?assertEqual(AddrLen, SaLen),
    %% Port first, then the octets, as `sockaddr_in' has them.
    {ok, <<0:16/big, Octets:AddrLen/binary>>} =
        wasm:read_memory(On, 512 + 48, 2 + AddrLen),
    ?assert(Octets =:= <<127, 0, 0, 1>> orelse
            Octets =:= <<0:120, 1>>).

%% A name that resolves is still only a name. The answer is checked as an
%% address at connect, so resolution can never widen a grant.
a_resolved_address_gets_no_authority_from_being_resolved(Config) ->
    I = instance(Config, #{connect => [{tcp, ~"10.0.0.1", 80}],
                           resolve => allow}),
    ok = put_query(I, ~"localhost", <<>>, 4),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"getaddrinfo", [9, 0, 4])),
    ?assertEqual({ok, [?ESUCCESS]},
                 wasm:call(I, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_STREAM])),
    {ok, [Fd]} = wasm:call(I, ~"out_fd", []),
    put_address(I, octets({127, 0, 0, 1})),
    ?assertEqual({ok, [?ENOTCAPABLE]}, wasm:call(I, ~"connect", [Fd, 80])).

%% A guest that passes an out-pointer outside its memory gets `EFAULT`, which
%% is right. What was wrong is what became of the connection behind the
%% descriptor it never received: the errno came back without the new state, so
%% the entry was dropped and with it the only reference to the accepted socket.
%% The guest never learned the number so it could never close it, and
%% destroying the instance could not find it either, because it was never in
%% the descriptor table. One connected socket per bad pointer, held for the
%% life of the node.
%%
%% The peer is what makes it visible: an accepted connection nobody holds must
%% be closed, so the other end sees the close rather than waiting for ever.
a_refused_out_pointer_does_not_leak_the_connection(Config) ->
    Port = free_port(),
    I = instance(Config, #{listen => [{tcp, ~"127.0.0.1", {Port, Port + 1}}]}),
    ?assertEqual({ok, [?ESUCCESS]},
                 wasm:call(I, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_STREAM])),
    {ok, [Fd]} = wasm:call(I, ~"out_fd", []),
    put_address(I, octets({127, 0, 0, 1})),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"bind", [Fd, Port])),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"listen", [Fd, 8])),
    {ok, Peer} = gen_tcp:connect({127, 0, 0, 1}, Port,
                                 [binary, {active, false}], 1000),
    ?assertEqual({ok, [?EFAULT]}, wasm:call(I, ~"bad_accept", [Fd])),
    ?assertEqual({error, closed}, gen_tcp:recv(Peer, 0, 2000)),
    ok = wasm:destroy(I).


%% Sending from a socket that was never bound binds it ephemerally, which means
%% `sock_send_to' opens one. If the send then fails, the caller is answered an
%% errno and no handle, so nothing would ever close what was opened: one
%% descriptor per call, for as long as the process lived.
a_failed_datagram_leaves_no_socket_behind(Config) ->
    %% Port zero is a legal destination to ask for and not one that can be
    %% reached, so the send fails after the socket is already open.
    I = instance(Config, #{connect => [{udp, ~"127.0.0.1", {0, 1}}]}),
    ?assertEqual({ok, [?ESUCCESS]},
                 wasm:call(I, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_DGRAM])),
    {ok, [Fd]} = wasm:call(I, ~"out_fd", []),
    ok = wasm:write_memory(I, 128, <<127, 0, 0, 1>>),
    ok = wasm:write_memory(I, 64, ~"ping"),
    Before = length(erlang:ports()),
    _ = [?assertMatch({ok, [E]} when E =/= ?ESUCCESS,
                      wasm:call(I, ~"send_to", [Fd, 4, 0]))
         || _ <- lists:seq(1, 20)],
    ?assertEqual(Before, length(erlang:ports())),
    ok = wasm:destroy(I).

%% And the other end of the same operation. The send works, the guest's out
%% pointer does not, and the socket `send_to/3' opened is in the descriptor
%% table it built: answering an errno without that table dropped the entry that
%% owns the socket, so destroying the instance closed nothing.
a_refused_out_pointer_keeps_the_socket_it_opened(Config) ->
    {ok, Peer} = gen_udp:open(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, PeerPort} = inet:port(Peer),
    I = instance(Config, #{connect => [{udp, ~"127.0.0.1", PeerPort}]}),
    ?assertEqual({ok, [?ESUCCESS]},
                 wasm:call(I, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_DGRAM])),
    {ok, [Fd]} = wasm:call(I, ~"out_fd", []),
    ok = wasm:write_memory(I, 128, <<127, 0, 0, 1>>),
    ok = wasm:write_memory(I, 64, ~"ping"),
    Before = length(erlang:ports()),
    ?assertEqual({ok, [?EFAULT]}, wasm:call(I, ~"bad_send_to", [Fd, 4, PeerPort])),
    %% It really was sent, so the socket really was opened.
    ?assertMatch({ok, {_, _, ~"ping"}}, gen_udp:recv(Peer, 0, 2000)),
    ?assertEqual(Before + 1, length(erlang:ports())),
    %% And destroying the instance closes it, which is what the dropped state
    %% made impossible.
    ok = wasm:destroy(I),
    ?assertEqual(Before, length(erlang:ports())),
    ok = gen_udp:close(Peer).

%% A service name is guest data, and resolving it needed `binary_to_atom/2` on
%% that data. The atom table is node-wide and never reclaimed, so a module
%% calling this in a loop with names it invented minted a permanent atom each
%% time and took the node out at the default limit of about a million. A guest
%% able to allocate an unreclaimable node-wide resource is out of its sandbox,
%% whatever else the sandbox holds.
a_made_up_service_name_mints_no_atoms(Config) ->
    I = instance(Config, #{connect => [{tcp, ~"127.0.0.1", 80}],
                           resolve => allow}),
    %% One first, so nothing about the first call through this path is counted
    %% as the loop's doing.
    ok = put_query(I, ~"localhost", ~"http", 1),
    {ok, [_]} = wasm:call(I, ~"getaddrinfo", [9, 4, 1]),

    Before = erlang:system_info(atom_count),
    lists:foreach(
      fun(N) ->
          Service = <<"nonesuch", (integer_to_binary(N))/binary>>,
          ok = put_query(I, ~"localhost", Service, 1),
          ?assertEqual({ok, [?EINVAL]},
                       wasm:call(I, ~"getaddrinfo",
                                 [9, byte_size(Service), 1]))
      end, lists:seq(1, 20)),
    ?assertEqual(Before, erlang:system_info(atom_count)),

    %% A name from the table still resolves, and a numeric port always does.
    ok = put_query(I, ~"localhost", ~"443", 1),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"getaddrinfo", [9, 3, 1])).

%% Lay out what a guest would allocate: the node and service strings, a hint,
%% and `Max' pointers each with an addrinfo, a sockaddr and a data buffer.
put_query(I, Node, Service, Max) ->
    ok = wasm:write_memory(I, 320, Node),
    ok = wasm:write_memory(I, 352, Service),
    %% An unspecified hint family, so both are asked for.
    ok = wasm:write_memory(I, 288, <<0:(28 * 8)>>),
    %% Well clear of the strings and the hint: a slot is 64 bytes and holds an
    %% addrinfo, a sockaddr and a data buffer, so overlapping anything else
    %% quietly rewrites it.
    Slots = [512 + (K * 64) || K <- lists:seq(0, Max - 1)],
    ok = wasm:write_memory(I, 160,
                           iolist_to_binary([<<S:32/little>> || S <- Slots])),
    lists:foreach(
      fun(Slot) ->
          SockAddr = Slot + 32,
          Data = Slot + 48,
          ok = wasm:write_memory(I, Slot, <<0:(28 * 8)>>),
          %% ai_addr points at the sockaddr the guest allocated.
          ok = wasm:write_memory(I, Slot + 12, <<SockAddr:32/little>>),
          %% sa_data_len and sa_data, which bound what the host may write.
          ok = wasm:write_memory(I, SockAddr,
                                 <<0:8, 0:24, 18:32/little, Data:32/little>>)
      end, Slots),
    ok.

the_socket_cap_covers_opening(Config) ->
    I = instance(Config, #{connect => [{tcp, ~"127.0.0.1", 80}], max_sockets => 2}),
    ?assertEqual({ok, [?ESUCCESS]},
                 wasm:call(I, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_STREAM])),
    ?assertEqual({ok, [?ESUCCESS]},
                 wasm:call(I, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_STREAM])),
    ?assertEqual({ok, [?EMFILE]},
                 wasm:call(I, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_STREAM])),
    %% Closing one gives the budget back.
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"close", [3])),
    ?assertEqual({ok, [?ESUCCESS]},
                 wasm:call(I, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_STREAM])).
