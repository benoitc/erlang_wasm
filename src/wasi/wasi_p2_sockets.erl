-module(wasi_p2_sockets).
-moduledoc """
The `wasi:sockets` slice of the WASI 0.2 host: `sockets/1` builds the network,
name lookup, TCP and UDP imports over `wasi_sock2`, gated by a `wasi_net` grant.

Read it when you change a socket method, an option, or an address check. The
streams a connection opens are the stream resources `wasi_preview2` serves, and
that module calls in here for the socket side of them: `udp_pump/4` fills a
datagram stream and `sock2_errno/1` names a send failure. This module never
calls back into `wasi_preview2`. `datagram_allowed/3` and `peer_matches/3` are
the UDP grant and peer checks.
""".

-include("wasi.hrl").

-export([sockets/1, udp_pump/4, sock2_errno/1, datagram_allowed/3,
         peer_matches/3]).

%% wasi:sockets/network error-code, its own enum, in WIT order.
-define(SOCK_ERROR,
        {enum, [<<"unknown">>, <<"access-denied">>, <<"not-supported">>,
                <<"invalid-argument">>, <<"out-of-memory">>, <<"timeout">>,
                <<"concurrency-conflict">>, <<"not-in-progress">>,
                <<"would-block">>, <<"invalid-state">>, <<"new-socket-limit">>,
                <<"address-not-bindable">>, <<"address-in-use">>,
                <<"remote-unreachable">>, <<"connection-refused">>,
                <<"connection-reset">>, <<"connection-aborted">>,
                <<"datagram-too-large">>, <<"name-unresolvable">>,
                <<"temporary-resolver-failure">>,
                <<"permanent-resolver-failure">>]}).
-define(IP_ADDRESS,
        {variant, [{<<"ipv4">>, {tuple, [u8, u8, u8, u8]}},
                   {<<"ipv6">>, {tuple, [u16, u16, u16, u16,
                                         u16, u16, u16, u16]}}]}).
-define(RESOLVE_RESULT, {result, {option, ?IP_ADDRESS}, ?SOCK_ERROR}).
%% The datagrams a single send may carry: check-send reports it, and sending more
%% than the last check-send permitted is a trap (the wasi:sockets contract).
-define(DGRAM_PERMIT, 16).
-define(ADDR_FAMILY, {enum, [<<"ipv4">>, <<"ipv6">>]}).
-define(IPV4_SOCKADDR,
        {record, [{<<"port">>, u16}, {<<"address">>, {tuple, [u8, u8, u8, u8]}}]}).
-define(IPV6_SOCKADDR,
        {record, [{<<"port">>, u16}, {<<"flow-info">>, u32},
                  {<<"address">>, {tuple, [u16, u16, u16, u16,
                                           u16, u16, u16, u16]}},
                  {<<"scope-id">>, u32}]}).
-define(IP_SOCKADDR,
        {variant, [{<<"ipv4">>, ?IPV4_SOCKADDR}, {<<"ipv6">>, ?IPV6_SOCKADDR}]}).
-define(CONNECT_RESULT, {result, {tuple, [handle, handle]}, ?SOCK_ERROR}).
-define(ACCEPT_RESULT, {result, {tuple, [handle, handle, handle]}, ?SOCK_ERROR}).
-define(LOCAL_RESULT, {result, ?IP_SOCKADDR, ?SOCK_ERROR}).
-define(SOCK_BACKLOG, 128).
%% Default answers for the best-effort socket options: a live socket reports
%% these until the exact-clamping sockopts pass wires the real getsockopt/
%% setsockopt values. Durations are nanoseconds (the wasi:clocks unit).
-define(KEEPIDLE_NS, 7200000000000).
-define(KEEPINTVL_NS, 75000000000).
-define(KEEPCNT, 9).
-define(HOP_LIMIT, 64).
-define(SOCK_BUFSIZE, 65536).
-define(INCOMING_DATAGRAM,
        {record, [{<<"data">>, {list, u8}}, {<<"remote-address">>, ?IP_SOCKADDR}]}).
-define(OUTGOING_DATAGRAM,
        {record, [{<<"data">>, {list, u8}},
                  {<<"remote-address">>, {option, ?IP_SOCKADDR}}]}).
-define(UDP_STREAM_RESULT, {result, {tuple, [handle, handle]}, ?SOCK_ERROR}).
-define(RECEIVE_RESULT, {result, {list, ?INCOMING_DATAGRAM}, ?SOCK_ERROR}).
-define(SEND_RESULT, {result, u64, ?SOCK_ERROR}).
-doc """
`wasi:sockets`: the network foundation, `ip-name-lookup`, TCP and UDP, the
sockets themselves over `wasi_sock2`. `instance-network` mints a network resource carrying the grant; `resolve-addresses`
resolves a name (gated by `wasi_net:resolves/1`, so a component with no grant
resolves nothing) into a stream of addresses; `resolve-next-address` pops each as
an `ipv4`/`ipv6` value. The address decision is `wasi_net`, not a second copy of
it, so a p2 guest reaches only what a p1 grant permits.
""".
-spec sockets(#{grant => term()}) -> #{{binary(), binary()} => fun()}.
sockets(Opts) ->
    Grant = wasi_net:grant(maps:get(grant, Opts, none)),
    Inet = <<"wasi:sockets/instance-network">>,
    Lookup = <<"wasi:sockets/ip-name-lookup">>,
    Network = <<"wasi:sockets/network">>,
    #{{Inet, <<"instance-network">>} =>
          wasm_component:import_fun(
            {[], handle}, fun([]) -> wasm_component:host_new(net_network, Grant) end),
      {Lookup, <<"resolve-addresses">>} =>
          wasm_component:import_fun(
            {[handle, string], {result, handle, ?SOCK_ERROR}},
            fun([NetH, Name]) -> resolve_addresses(NetH, Name) end),
      {Lookup, <<"[method]resolve-address-stream.resolve-next-address">>} =>
          wasm_component:import_fun(
            {[handle], ?RESOLVE_RESULT},
            fun([Stream]) -> resolve_next(Stream) end),
      {Lookup, <<"[method]resolve-address-stream.subscribe">>} =>
          wasm_component:import_fun(
            {[handle], handle},
            fun([_Stream]) -> wasm_component:host_new(pollable, ready) end),
      {Lookup, <<"[resource-drop]resolve-address-stream">>} => drop_fun(),
      {Network, <<"[resource-drop]network">>} => drop_fun(),
      {<<"wasi:sockets/tcp-create-socket">>, <<"create-tcp-socket">>} =>
          wasm_component:import_fun(
            {[?ADDR_FAMILY], {result, handle, ?SOCK_ERROR}},
            fun([Family]) -> create_tcp_socket(Family, Grant) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.start-connect">>} =>
          wasm_component:import_fun(
            {[handle, handle, ?IP_SOCKADDR], {result, none, ?SOCK_ERROR}},
            fun([Self, Net, Addr]) -> tcp_start_connect(Self, Net, Addr) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.finish-connect">>} =>
          wasm_component:import_fun(
            {[handle], ?CONNECT_RESULT}, fun([Self]) -> tcp_finish_connect(Self) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.start-bind">>} =>
          wasm_component:import_fun(
            {[handle, handle, ?IP_SOCKADDR], {result, none, ?SOCK_ERROR}},
            fun([Self, Net, Addr]) -> tcp_start_bind(Self, Net, Addr) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.finish-bind">>} =>
          wasm_component:import_fun(
            {[handle], {result, none, ?SOCK_ERROR}},
            fun([Self]) -> finish(Self, tcp_socket, binding, bound) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.start-listen">>} =>
          wasm_component:import_fun(
            {[handle], {result, none, ?SOCK_ERROR}}, fun([Self]) -> tcp_start_listen(Self) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.finish-listen">>} =>
          wasm_component:import_fun(
            {[handle], {result, none, ?SOCK_ERROR}},
            fun([Self]) -> finish(Self, tcp_socket, listen_pending, listening) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.accept">>} =>
          wasm_component:import_fun(
            {[handle], ?ACCEPT_RESULT}, fun([Self]) -> tcp_accept(Self, Grant) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.local-address">>} =>
          wasm_component:import_fun(
            {[handle], ?LOCAL_RESULT}, fun([Self]) -> tcp_local(Self) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.subscribe">>} =>
          wasm_component:import_fun(
            {[handle], handle}, fun([_Self]) -> wasm_component:host_new(pollable, ready) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.shutdown">>} =>
          wasm_component:import_fun(
            {[handle, {enum, [<<"receive">>, <<"send">>, <<"both">>]}],
             {result, none, ?SOCK_ERROR}},
            fun([Self, How]) -> tcp_shutdown(Self, How) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.remote-address">>} =>
          wasm_component:import_fun(
            {[handle], ?LOCAL_RESULT}, fun([Self]) -> tcp_remote(Self) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.is-listening">>} =>
          wasm_component:import_fun(
            {[handle], bool}, fun([Self]) -> tcp_is_listening(Self) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.address-family">>} =>
          wasm_component:import_fun(
            {[handle], ?ADDR_FAMILY}, fun([Self]) -> tcp_family(Self) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.set-listen-backlog-size">>} =>
          wasm_component:import_fun(
            {[handle, u64], {result, none, ?SOCK_ERROR}},
            fun([Self, N]) -> tcp_set_nonzero(Self, N) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.keep-alive-enabled">>} =>
          wasm_component:import_fun(
            {[handle], {result, bool, ?SOCK_ERROR}},
            fun([Self]) -> opt_get(Self, keep_alive_enabled) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.set-keep-alive-enabled">>} =>
          wasm_component:import_fun(
            {[handle, bool], {result, none, ?SOCK_ERROR}},
            fun([Self, On]) -> opt_set(Self, keep_alive_enabled, On) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.keep-alive-idle-time">>} =>
          wasm_component:import_fun(
            {[handle], {result, u64, ?SOCK_ERROR}},
            fun([Self]) -> opt_get(Self, keep_alive_idle_time) end),
      {<<"wasi:sockets/tcp">>,
       <<"[method]tcp-socket.set-keep-alive-idle-time">>} =>
          wasm_component:import_fun(
            {[handle, u64], {result, none, ?SOCK_ERROR}},
            fun([Self, N]) -> opt_set_nonzero(Self, keep_alive_idle_time, N) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.keep-alive-interval">>} =>
          wasm_component:import_fun(
            {[handle], {result, u64, ?SOCK_ERROR}},
            fun([Self]) -> opt_get(Self, keep_alive_interval) end),
      {<<"wasi:sockets/tcp">>,
       <<"[method]tcp-socket.set-keep-alive-interval">>} =>
          wasm_component:import_fun(
            {[handle, u64], {result, none, ?SOCK_ERROR}},
            fun([Self, N]) -> opt_set_nonzero(Self, keep_alive_interval, N) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.keep-alive-count">>} =>
          wasm_component:import_fun(
            {[handle], {result, u32, ?SOCK_ERROR}},
            fun([Self]) -> opt_get(Self, keep_alive_count) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.set-keep-alive-count">>} =>
          wasm_component:import_fun(
            {[handle, u32], {result, none, ?SOCK_ERROR}},
            fun([Self, N]) -> opt_set_nonzero(Self, keep_alive_count, N) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.hop-limit">>} =>
          wasm_component:import_fun(
            {[handle], {result, u8, ?SOCK_ERROR}},
            fun([Self]) -> opt_get(Self, hop_limit) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.set-hop-limit">>} =>
          wasm_component:import_fun(
            {[handle, u8], {result, none, ?SOCK_ERROR}},
            fun([Self, N]) -> opt_set_nonzero(Self, hop_limit, N) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.receive-buffer-size">>} =>
          wasm_component:import_fun(
            {[handle], {result, u64, ?SOCK_ERROR}},
            fun([Self]) -> opt_get(Self, recv_buffer) end),
      {<<"wasi:sockets/tcp">>,
       <<"[method]tcp-socket.set-receive-buffer-size">>} =>
          wasm_component:import_fun(
            {[handle, u64], {result, none, ?SOCK_ERROR}},
            fun([Self, N]) -> opt_set_nonzero(Self, recv_buffer, N) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.send-buffer-size">>} =>
          wasm_component:import_fun(
            {[handle], {result, u64, ?SOCK_ERROR}},
            fun([Self]) -> opt_get(Self, send_buffer) end),
      {<<"wasi:sockets/tcp">>,
       <<"[method]tcp-socket.set-send-buffer-size">>} =>
          wasm_component:import_fun(
            {[handle, u64], {result, none, ?SOCK_ERROR}},
            fun([Self, N]) -> opt_set_nonzero(Self, send_buffer, N) end),
      {<<"wasi:sockets/tcp">>, <<"[resource-drop]tcp-socket">>} =>
          fun(_Ctx, [H]) -> _ = tcp_drop(H), {ok, []} end,
      {<<"wasi:sockets/udp-create-socket">>, <<"create-udp-socket">>} =>
          wasm_component:import_fun(
            {[?ADDR_FAMILY], {result, handle, ?SOCK_ERROR}},
            fun([Family]) -> create_udp_socket(Family, Grant) end),
      {<<"wasi:sockets/udp">>, <<"[method]udp-socket.start-bind">>} =>
          wasm_component:import_fun(
            {[handle, handle, ?IP_SOCKADDR], {result, none, ?SOCK_ERROR}},
            fun([Self, Net, Addr]) -> udp_start_bind(Self, Net, Addr) end),
      {<<"wasi:sockets/udp">>, <<"[method]udp-socket.finish-bind">>} =>
          wasm_component:import_fun(
            {[handle], {result, none, ?SOCK_ERROR}},
            fun([Self]) -> udp_finish_bind(Self) end),
      {<<"wasi:sockets/udp">>, <<"[method]udp-socket.local-address">>} =>
          wasm_component:import_fun(
            {[handle], ?LOCAL_RESULT}, fun([Self]) -> udp_local(Self) end),
      {<<"wasi:sockets/udp">>, <<"[method]udp-socket.remote-address">>} =>
          wasm_component:import_fun(
            {[handle], ?LOCAL_RESULT}, fun([Self]) -> udp_remote_addr(Self) end),
      {<<"wasi:sockets/udp">>, <<"[method]udp-socket.address-family">>} =>
          wasm_component:import_fun(
            {[handle], ?ADDR_FAMILY}, fun([Self]) -> udp_family(Self) end),
      {<<"wasi:sockets/udp">>, <<"[method]udp-socket.subscribe">>} =>
          wasm_component:import_fun(
            {[handle], handle},
            fun([_Self]) -> wasm_component:host_new(pollable, ready) end),
      {<<"wasi:sockets/udp">>, <<"[method]udp-socket.unicast-hop-limit">>} =>
          wasm_component:import_fun(
            {[handle], {result, u8, ?SOCK_ERROR}},
            fun([Self]) -> opt_get(Self, hop_limit) end),
      {<<"wasi:sockets/udp">>, <<"[method]udp-socket.set-unicast-hop-limit">>} =>
          wasm_component:import_fun(
            {[handle, u8], {result, none, ?SOCK_ERROR}},
            fun([Self, N]) -> opt_set_nonzero(Self, hop_limit, N) end),
      {<<"wasi:sockets/udp">>, <<"[method]udp-socket.receive-buffer-size">>} =>
          wasm_component:import_fun(
            {[handle], {result, u64, ?SOCK_ERROR}},
            fun([Self]) -> opt_get(Self, recv_buffer) end),
      {<<"wasi:sockets/udp">>,
       <<"[method]udp-socket.set-receive-buffer-size">>} =>
          wasm_component:import_fun(
            {[handle, u64], {result, none, ?SOCK_ERROR}},
            fun([Self, N]) -> opt_set_nonzero(Self, recv_buffer, N) end),
      {<<"wasi:sockets/udp">>, <<"[method]udp-socket.send-buffer-size">>} =>
          wasm_component:import_fun(
            {[handle], {result, u64, ?SOCK_ERROR}},
            fun([Self]) -> opt_get(Self, send_buffer) end),
      {<<"wasi:sockets/udp">>, <<"[method]udp-socket.set-send-buffer-size">>} =>
          wasm_component:import_fun(
            {[handle, u64], {result, none, ?SOCK_ERROR}},
            fun([Self, N]) -> opt_set_nonzero(Self, send_buffer, N) end),
      {<<"wasi:sockets/udp">>, <<"[method]udp-socket.stream">>} =>
          wasm_component:import_fun(
            {[handle, {option, ?IP_SOCKADDR}], ?UDP_STREAM_RESULT},
            fun([Self, Remote]) -> udp_stream(Self, Remote, Grant) end),
      {<<"wasi:sockets/udp">>, <<"[method]outgoing-datagram-stream.send">>} =>
          udp_send_import(),
      {<<"wasi:sockets/udp">>, <<"[method]outgoing-datagram-stream.check-send">>} =>
          wasm_component:import_fun(
            {[handle], ?SEND_RESULT}, fun([_Out]) -> {ok, ?DGRAM_PERMIT} end),
      {<<"wasi:sockets/udp">>, <<"[method]incoming-datagram-stream.receive">>} =>
          wasm_component:import_fun(
            {[handle, u64], ?RECEIVE_RESULT},
            fun([In, Max]) -> udp_receive(In, Max) end),
      {<<"wasi:sockets/udp">>,
       <<"[method]incoming-datagram-stream.subscribe">>} =>
          wasm_component:import_fun(
            {[handle], handle},
            fun([In]) -> wasm_component:host_new(pollable, {stream, In}) end),
      {<<"wasi:sockets/udp">>,
       <<"[method]outgoing-datagram-stream.subscribe">>} =>
          wasm_component:import_fun(
            {[handle], handle},
            fun([_Out]) -> wasm_component:host_new(pollable, ready) end),
      {<<"wasi:sockets/udp">>, <<"[resource-drop]incoming-datagram-stream">>} => drop_fun(),
      {<<"wasi:sockets/udp">>, <<"[resource-drop]outgoing-datagram-stream">>} => drop_fun(),
      {<<"wasi:sockets/udp">>, <<"[resource-drop]udp-socket">>} =>
          fun(_Ctx, [H]) -> _ = udp_drop(H), {ok, []} end}.

%% A grant-less socket (`none`) is still created but reaches nowhere (every connect,
%% bind and listen is checked against the grant), which the connect/listen-needs-a-
%% grant tests rely on. A grant that explicitly withholds the TCP transport is
%% different: creation itself is access-denied, which is what p2_cli_no_tcp asserts.
%% TCP sockets use wasi_sock2 (the OTP `socket` module) so the WASI state machine
%% works: a real bind-only that reports its ephemeral port and detects a double bind,
%% and a client that binds before it connects.
create_tcp_socket(Family, Grant) ->
    case wasi_net:tcp_allowed(Grant) of
        false -> {error, <<"access-denied">>};
        true  ->
            case socket_room(Grant) of
                false -> {error, <<"new-socket-limit">>};
                true  ->
                    case wasi_sock2:open(family_inet(Family)) of
                        {ok, Handle}   -> {ok, wasm_component:host_new(
                                                 tcp_socket, {unconnected, Handle})};
                        {error, Errno} -> {error, sock2_errno(Errno)}
                    end
            end
    end.

%% Cap the sockets an instance holds at once at the grant's `max_sockets`. A
%% component with no grant reaches nowhere, so its sockets are harmless and left
%% uncapped; a granted one is bounded so a guest cannot exhaust descriptors.
socket_room(Grant) ->
    case wasi_net:max_sockets(Grant) of
        0   -> true;
        Max -> live_sockets() < Max
    end.

live_sockets() ->
    length([H || H <- wasm_component:host_live(),
                 case wasm_component:host_get(H) of
                     {ok, {tcp_socket, _}} -> true;
                     {ok, {udp_socket, _}} -> true;
                     _                     -> false
                 end]).

family_inet(<<"ipv6">>) -> inet6;
family_inet(_Ipv4)      -> inet.

%% The connect state machine, collapsed to a blocking connect: start-connect
%% checks the grant and connects, finish-connect hands back the streams. The
%% address decision is wasi_net, so a socket reaches only a granted endpoint.
tcp_start_connect(Self, Net, Addr) ->
    case {tcp_connectable(Self), wasm_component:host_get(Net)} of
        {{ok, Handle}, {ok, {net_network, Grant}}} ->
            {tcp, Ip, Port} = Endpoint = endpoint(Addr),
            case connect_addr_ok(wasi_sock2:family(Handle), Ip, Port) of
                false ->
                    {error, <<"invalid-argument">>};
                true ->
                    case wasi_net:allows(connect, Endpoint, Grant) of
                        false ->
                            {error, <<"access-denied">>};
                        true ->
                            case wasi_sock2:connect(Handle, {Ip, Port}, ?SOCK_TIMEOUT) of
                                ok             -> _ = wasm_component:host_update(
                                                        Self, {connecting, Handle}),
                                                  {ok, undefined};
                                {error, Errno} -> {error, sock2_errno(Errno)}
                            end
                    end
            end;
        {{error, State}, _} ->
            {error, State};
        _ ->
            {error, <<"invalid-state">>}
    end.

%% A client may connect from an unconnected or an already-bound socket (an explicit
%% local bind before connect); every other state is invalid.
tcp_connectable(Self) ->
    case wasm_component:host_get(Self) of
        {ok, {tcp_socket, {unconnected, Handle}}} -> {ok, Handle};
        {ok, {tcp_socket, {bound, Handle}}}        -> {ok, Handle};
        _                                          -> {error, <<"invalid-state">>}
    end.

%% finish-connect completes a start-connect exactly once: the socket must be in the
%% `connecting` state a start-connect left it in. A finish with no connect pending
%% (never started, or already finished) is `not-in-progress`, as the contract says.
tcp_finish_connect(Self) ->
    case wasm_component:host_get(Self) of
        {ok, {tcp_socket, {connecting, Conn}}} ->
            _ = wasm_component:host_update(Self, {connected, Conn}),
            {ok, tcp_streams(Conn)};
        _ ->
            %% No connect in progress is not-in-progress, not invalid-state,
            %% the same contract finish/4 gives bind and listen.
            {error, <<"not-in-progress">>}
    end.

%% Bind and listen collapse like connect: start-bind checks the grant and binds,
%% start-listen listens, accept blocks for a connection and returns its streams.
tcp_start_bind(Self, Net, Addr) ->
    case {wasm_component:host_get(Self), wasm_component:host_get(Net)} of
        {{ok, {tcp_socket, {unconnected, Handle}}}, {ok, {net_network, Grant}}} ->
            {tcp, Ip, Port} = Endpoint = endpoint(Addr),
            case bind_addr_ok(wasi_sock2:family(Handle), Ip) of
                false ->
                    {error, <<"invalid-argument">>};
                true ->
                    case wasi_net:allows(listen, Endpoint, Grant) of
                        false ->
                            {error, <<"access-denied">>};
                        true ->
                            case wasi_sock2:bind(Handle, {Ip, Port}) of
                                ok             -> bind_ok(Self, Handle);
                                {error, Errno} -> {error, sock2_errno(Errno)}
                            end
                    end
            end;
        _ ->
            {error, <<"invalid-state">>}
    end.

bind_ok(Self, Handle) ->
    _ = wasm_component:host_update(Self, {binding, Handle}),
    {ok, undefined}.

%% Complete a start operation exactly once. The socket must be in the intermediate
%% state the matching start left it in; a finish with nothing pending is
%% `not-in-progress`, which is what the wasi:sockets contract requires.
finish(Self, Tag, From, To) ->
    case wasm_component:host_get(Self) of
        {ok, {Tag, {From, Handle}}} ->
            _ = wasm_component:host_update(Self, {To, Handle}),
            {ok, undefined};
        _ ->
            {error, <<"not-in-progress">>}
    end.

tcp_start_listen(Self) ->
    case wasm_component:host_get(Self) of
        {ok, {tcp_socket, {bound, Handle}}} ->
            case wasi_sock2:listen(Handle, listen_backlog(Self)) of
                ok             -> _ = wasm_component:host_update(
                                        Self, {listen_pending, Handle}),
                                  {ok, undefined};
                {error, Errno} -> {error, sock2_errno(Errno)}
            end;
        _ ->
            {error, <<"invalid-state">>}
    end.

%% The backlog the guest set via set-listen-backlog-size, or the default.
listen_backlog(Self) ->
    case get({?SOCKOPT, Self}) of
        #{listen_backlog := N} -> N;
        _                      -> ?SOCK_BACKLOG
    end.

tcp_accept(Self, Grant) ->
    case wasm_component:host_get(Self) of
        {ok, {tcp_socket, {listening, Listen}}} ->
            case socket_room(Grant) of
                false ->
                    {error, <<"new-socket-limit">>};
                true ->
                    accept_connection(Self, Listen)
            end;
        _ ->
            {error, <<"invalid-state">>}
    end.

accept_connection(Listener, Listen) ->
    case wasi_sock2:accept(Listen, ?SOCK_TIMEOUT) of
        {ok, Conn} ->
            Sock = wasm_component:host_new(tcp_socket, {connected, Conn}),
            %% An accepted connection inherits the listener's socket options.
            _ = inherit_sockopts(Listener, Sock),
            {In, Out} = tcp_streams(Conn),
            {ok, {Sock, In, Out}};
        {error, Errno} ->
            {error, sock2_errno(Errno)}
    end.

%% The input/output stream pair over a connected TCP socket (a wasi_sock2 handle).
%% The `socket` stream tag is TCP-only, so its read/write path uses wasi_sock2.
tcp_streams(Conn) ->
    In = wasm_component:host_new(input_stream, {socket, Conn, <<>>}),
    Out = new_output_stream({socket, Conn}),
    {In, Out}.

%% Mint a host output-stream over Backing: the `{ostream, Permit, Closed,
%% Backing}` envelope wasi_preview2's stream methods read, with no permit and
%% open. Inlined (not a call) to keep the module graph acyclic, since
%% wasi_preview2 already depends on this module.
new_output_stream(Backing) ->
    wasm_component:host_new(output_stream, {ostream, 0, false, Backing}).

%% A local copy of wasi_preview2's drop, for the same reason.
drop_fun() ->
    fun(_Ctx, [Handle]) -> _ = wasm_component:host_drop(Handle), {ok, []} end.

inherit_sockopts(From, To) ->
    case get({?SOCKOPT, From}) of
        undefined -> ok;
        Opts      -> put({?SOCKOPT, To}, Opts)
    end.

tcp_local(Self) ->
    case wasm_component:host_get(Self) of
        {ok, {tcp_socket, {State, Handle}}}
          when State =:= bound; State =:= listening; State =:= connected ->
            case wasi_sock2:sockname(Handle) of
                {ok, {Addr, Port}} -> {ok, ip_sockaddr(Addr, Port)};
                {error, Errno}     -> {error, sock2_errno(Errno)}
            end;
        _ ->
            {error, <<"invalid-state">>}
    end.

%% Remote address is only defined once connected; every other state is
%% invalid-state, as the tcp state machine requires.
tcp_remote(Self) ->
    case wasm_component:host_get(Self) of
        {ok, {tcp_socket, {connected, Conn}}} ->
            case wasi_sock2:peername(Conn) of
                {ok, {Addr, Port}} -> {ok, ip_sockaddr(Addr, Port)};
                {error, Errno}     -> {error, sock2_errno(Errno)}
            end;
        _ ->
            {error, <<"invalid-state">>}
    end.

tcp_is_listening(Self) ->
    case wasm_component:host_get(Self) of
        {ok, {tcp_socket, {listening, _}}} -> true;
        _                                  -> false
    end.

%% The family is fixed at create and readable from the live handle in any state.
tcp_family(Self) ->
    case tcp_handle(Self) of
        {ok, Handle} -> family_enum(wasi_sock2:family(Handle));
        error        -> <<"ipv4">>
    end.

tcp_handle(Self) ->
    case wasm_component:host_get(Self) of
        {ok, {tcp_socket, {_State, Handle}}} -> {ok, Handle};
        _                                    -> error
    end.

family_enum(inet6) -> <<"ipv6">>;
family_enum(_)     -> <<"ipv4">>.

%% Socket options persist per socket so a set reads back: a live socket reports a
%% stored value or its default, and stores what a set gives (the OS is not
%% consulted, so no silent clamping is needed for these to round-trip). A value the
%% ABI forbids to be zero (durations, counts, hop limit, buffer sizes, listen
%% backlog) is invalid-argument, and any call on a dropped socket is invalid-state.
%% The store lives in the instance process, keyed by the resource, freed on drop.
opt_get(Self, Which) ->
    case live_socket(Self) of
        true  -> {ok, maps:get(Which, socket_opts(Self), sockopt_default(Which))};
        false -> {error, <<"invalid-state">>}
    end.

opt_set(Self, Which, Value) ->
    case live_socket(Self) of
        true  -> put_socket_opt(Self, Which, Value), {ok, undefined};
        false -> {error, <<"invalid-state">>}
    end.

opt_set_nonzero(Self, Which, Value) ->
    case live_socket(Self) of
        false                 -> {error, <<"invalid-state">>};
        true when Value =:= 0 -> {error, <<"invalid-argument">>};
        true                  -> put_socket_opt(Self, Which, Value), {ok, undefined}
    end.

%% set-listen-backlog-size stores the hint so a later listen uses it.
tcp_set_nonzero(Self, Value) ->
    case live_socket(Self) of
        false                 -> {error, <<"invalid-state">>};
        true when Value =:= 0 -> {error, <<"invalid-argument">>};
        true                  -> put_socket_opt(Self, listen_backlog, Value),
                                 {ok, undefined}
    end.

live_socket(Self) ->
    case wasm_component:host_get(Self) of
        {ok, {tcp_socket, _}} -> true;
        {ok, {udp_socket, _}} -> true;
        _                     -> false
    end.

socket_opts(Self) ->
    case get({?SOCKOPT, Self}) of
        undefined -> #{};
        Map       -> Map
    end.

put_socket_opt(Self, Which, Value) ->
    put({?SOCKOPT, Self}, (socket_opts(Self))#{Which => Value}).

sockopt_default(keep_alive_enabled)   -> false;
sockopt_default(keep_alive_idle_time) -> ?KEEPIDLE_NS;
sockopt_default(keep_alive_interval)  -> ?KEEPINTVL_NS;
sockopt_default(keep_alive_count)     -> ?KEEPCNT;
sockopt_default(hop_limit)            -> ?HOP_LIMIT;
sockopt_default(recv_buffer)          -> ?SOCK_BUFSIZE;
sockopt_default(send_buffer)          -> ?SOCK_BUFSIZE.

ip_sockaddr({A, B, C, D}, Port) ->
    {<<"ipv4">>, #{<<"port">> => Port, <<"address">> => {A, B, C, D}}};
ip_sockaddr({A, B, C, D, E, F, G, H}, Port) ->
    {<<"ipv6">>, #{<<"port">> => Port, <<"flow-info">> => 0,
                   <<"address">> => {A, B, C, D, E, F, G, H}, <<"scope-id">> => 0}}.

tcp_shutdown(Self, How) ->
    case wasm_component:host_get(Self) of
        {ok, {tcp_socket, {connected, Conn}}} ->
            case wasi_sock2:shutdown(Conn, shutdown_dir(How)) of
                ok ->
                    %% Remember a local receive shutdown so a later read reports
                    %% closed rather than draining buffered bytes.
                    case How of
                        <<"send">> -> ok;
                        _          -> put({?SHUT_RECV, Conn}, true)
                    end,
                    {ok, undefined};
                {error, Errno} ->
                    {error, sock2_errno(Errno)}
            end;
        _ ->
            {error, <<"invalid-state">>}
    end.

shutdown_dir(<<"receive">>) -> read;
shutdown_dir(<<"send">>)    -> write;
shutdown_dir(<<"both">>)    -> both.

tcp_drop(H) ->
    case wasm_component:host_get(H) of
        {ok, {tcp_socket, {_State, Handle}}} -> _ = wasi_sock2:close(Handle);
        _                                    -> ok
    end,
    _ = erase({?SOCKOPT, H}),
    wasm_component:host_drop(H).

endpoint(Addr) ->
    {Ip, Port} = sockaddr(Addr),
    {tcp, Ip, Port}.

endpoint_udp(Addr) ->
    {Ip, Port} = sockaddr(Addr),
    {udp, Ip, Port}.

sockaddr({<<"ipv4">>, #{<<"port">> := Port, <<"address">> := {A, B, C, D}}}) ->
    {{A, B, C, D}, Port};
sockaddr({<<"ipv6">>, #{<<"port">> := Port, <<"address">> := V6}}) ->
    {V6, Port}.

%%% ----------------------------------------------------------------- udp ---

create_udp_socket(Family, Grant) ->
    case wasi_net:udp_allowed(Grant) of
        false ->
            {error, <<"access-denied">>};
        true ->
            case socket_room(Grant) of
                false ->
                    {error, <<"new-socket-limit">>};
                true ->
                    case wasi_sock2:open_udp(family_inet(Family)) of
                        {ok, Handle}   -> {ok, wasm_component:host_new(
                                                 udp_socket, {udp_unbound, Handle})};
                        {error, Errno} -> {error, sock2_errno(Errno)}
                    end
            end
    end.

%% Sending more datagrams than the last check-send permitted traps, which the plain
%% import_fun wrapper cannot express; the datagram list's length is the third flat
%% argument, checked before the value is lifted.
udp_send_import() ->
    Inner = wasm_component:import_fun(
              {[handle, {list, ?OUTGOING_DATAGRAM}], ?SEND_RESULT},
              fun([Out, Datagrams]) -> udp_send(Out, Datagrams) end),
    fun(Ctx, Flats) ->
        case lists:nth(3, Flats) > ?DGRAM_PERMIT of
            true  -> {trap, udp_send_over_permit};
            false -> Inner(Ctx, Flats)
        end
    end.

%% Bind to the local address. Binding the guest's own source address is not a
%% reach capability, so the local address is not checked against the grant; the
%% peer is checked at stream time and every send destination at send time. The
%% network handle must be a real network resource, as the contract requires.
udp_start_bind(Self, Net, Addr) ->
    case {wasm_component:host_get(Self), wasm_component:host_get(Net)} of
        {{ok, {udp_socket, {udp_unbound, Handle}}}, {ok, {net_network, _Grant}}} ->
            {udp, Ip, Port} = endpoint_udp(Addr),
            case bind_addr_ok(wasi_sock2:family(Handle), Ip) of
                false ->
                    {error, <<"invalid-argument">>};
                true ->
                    case wasi_sock2:bind(Handle, {Ip, Port}) of
                        ok ->
                            _ = wasm_component:host_update(Self, {udp_binding, Handle}),
                            {ok, undefined};
                        {error, Errno} ->
                            {error, sock2_errno(Errno)}
                    end
            end;
        _ ->
            {error, <<"invalid-state">>}
    end.

%% Finishing a bind moves the socket to bound with no connected remote yet; the
%% third field records the address a later stream(some(_)) connects to, which is
%% what remote-address reports.
udp_finish_bind(Self) ->
    case wasm_component:host_get(Self) of
        {ok, {udp_socket, {udp_binding, Bound}}} ->
            _ = wasm_component:host_update(Self, {udp_bound, Bound, none}),
            {ok, undefined};
        _ ->
            {error, <<"not-in-progress">>}
    end.

%% stream splits the socket into an incoming and outgoing datagram stream. A
%% connected stream (a remote address) checks the peer against the grant and is
%% remembered on the socket so remote-address can report it.
%% stream splits the socket into an incoming and outgoing datagram stream. Only a
%% bound socket may stream (else invalid-state). `stream(some(addr))` connects the
%% socket to that peer (so a peer that is gone surfaces on receive as an ICMP error)
%% and remembers it for remote-address; `stream(none)` leaves it unconnected.
udp_stream(Self, Remote, Grant) ->
    case wasm_component:host_get(Self) of
        {ok, {udp_socket, {udp_bound, Sock, _Was}}} ->
            case udp_connect(Sock, Remote, Grant) of
                {ok, Peer} ->
                    _ = wasm_component:host_update(Self, {udp_bound, Sock, Peer}),
                    In = wasm_component:host_new(udp_in, {Sock, Peer, []}),
                    Out = wasm_component:host_new(udp_out, {Sock, Peer, Grant}),
                    {ok, {In, Out}};
                {error, _} = E ->
                    E
            end;
        _ ->
            {error, <<"invalid-state">>}
    end.

%% Validate and, for a real peer, OS-connect the socket; the peer is `none` (an
%% unconnected stream) or `{udp, Ip, Port}` (the connected remote).
udp_connect(_Sock, none, _Grant) ->
    {ok, none};
udp_connect(Sock, {some, Addr}, Grant) ->
    {udp, Ip, Port} = Endpoint = endpoint_udp(Addr),
    case connect_addr_ok(wasi_sock2:family(Sock), Ip, Port) of
        false ->
            {error, <<"invalid-argument">>};
        true ->
            case wasi_net:allows(connect, Endpoint, Grant) of
                false ->
                    {error, <<"access-denied">>};
                true ->
                    case wasi_sock2:connect(Sock, {Ip, Port}, ?SOCK_TIMEOUT) of
                        ok             -> {ok, {udp, Ip, Port}};
                        {error, Errno} -> {error, sock2_errno(Errno)}
                    end
            end
    end.

udp_local(Self) ->
    case wasm_component:host_get(Self) of
        {ok, {udp_socket, {udp_bound, Sock, _Conn}}} ->
            case wasi_sock2:sockname(Sock) of
                {ok, {Addr, Port}} -> {ok, ip_sockaddr(Addr, Port)};
                {error, Errno}     -> {error, sock2_errno(Errno)}
            end;
        _ ->
            {error, <<"invalid-state">>}
    end.

%% Remote address is defined only once a stream connected the socket to a peer.
udp_remote_addr(Self) ->
    case wasm_component:host_get(Self) of
        {ok, {udp_socket, {udp_bound, _Sock, {udp, Ip, Port}}}} ->
            {ok, ip_sockaddr(Ip, Port)};
        _ ->
            {error, <<"invalid-state">>}
    end.

udp_family(Self) ->
    case udp_handle(Self) of
        {ok, Handle} -> family_enum(wasi_sock2:family(Handle));
        error        -> <<"ipv4">>
    end.

udp_handle(Self) ->
    case wasm_component:host_get(Self) of
        {ok, {udp_socket, {udp_bound, Sock, _Conn}}} -> {ok, Sock};
        {ok, {udp_socket, {_State, Handle}}}         -> {ok, Handle};
        _                                            -> error
    end.

udp_send(Out, Datagrams) ->
    case wasm_component:host_get(Out) of
        {ok, {udp_out, {Sock, Peer, Grant}}} ->
            %% Every explicit destination must be granted before anything is sent,
            %% so a datagram never reaches an address outside the grant. A datagram
            %% with no remote uses the connected peer, checked when the stream was
            %% opened.
            case lists:all(fun(D) -> datagram_allowed(D, Peer, Grant) end, Datagrams) of
                false ->
                    {error, <<"access-denied">>};
                true ->
                    Sent = lists:foldl(
                             fun(D, Acc) -> Acc + send_datagram(Sock, Peer, D) end,
                             0, Datagrams),
                    {ok, Sent}
            end;
        _ ->
            {error, <<"invalid-state">>}
    end.

datagram_allowed(#{<<"remote-address">> := {some, Addr}}, _Peer, Grant) ->
    wasi_net:allows(connect, endpoint_udp(Addr), Grant);
datagram_allowed(#{<<"remote-address">> := none}, Peer, _Grant) ->
    Peer =/= none.

%% A connected stream sends to its peer (the OS refuses a different destination, so
%% the datagram's own remote is not consulted); an unconnected stream sends to the
%% datagram's explicit remote. A datagram with neither is dropped.
send_datagram(Sock, {udp, _, _}, #{<<"data">> := Data}) ->
    case wasi_sock2:send(Sock, Data) of ok -> 1; {error, _} -> 0 end;
send_datagram(Sock, none, #{<<"data">> := Data, <<"remote-address">> := {some, Addr}}) ->
    {udp, Ip, Port} = endpoint_udp(Addr),
    case wasi_sock2:sendto(Sock, Data, {Ip, Port}) of ok -> 1; {error, _} -> 0 end;
send_datagram(_Sock, none, _Datagram) ->
    0.

%% Drain the datagrams waiting on the stream, up to Max, and return them at once.
%% A guest that first waits on the stream's pollable (subscribe) finds them already
%% queued; one that receives directly waits here for the first (see udp_pump). The
%% queue lets a single receive return several datagrams, which the poll path fills.
udp_receive(In, Max) ->
    case wasm_component:host_get(In) of
        {ok, {udp_in, {Sock, Peer, Queue0}}} when Max > 0 ->
            case udp_pump(Sock, Peer, Queue0, true) of
                {ok, Queue} ->
                    {Take, Rest} = take_up_to(Max, Queue),
                    _ = wasm_component:host_update(In, {Sock, Peer, Rest}),
                    {ok, [#{<<"data">> => D, <<"remote-address">> => A} || {D, A} <- Take]};
                {error, Errno} ->
                    {error, sock2_errno(Errno)}
            end;
        {ok, {udp_in, _}} ->
            {ok, []};
        _ ->
            {error, <<"invalid-state">>}
    end.

%% Pull the datagrams currently waiting into the stream's queue, peer-filtered, and
%% report a socket error (an ICMP port-unreachable on a connected socket becomes
%% connection-refused). A blocking pump waits up to the socket timeout for the first
%% datagram when the queue is empty; both then drain what is immediately available.
udp_pump(Sock, Peer, Queue, Blocking) ->
    Timeout = case {Queue, Blocking} of {[], true} -> ?SOCK_TIMEOUT; _ -> 0 end,
    case wasi_sock2:recvfrom(Sock, Timeout) of
        {ok, {Addr, Port}, Data} ->
            %% A connected stream (a chosen peer) hears only that peer; a datagram
            %% from anyone else is dropped, not handed over.
            Q1 = case peer_matches(Peer, Addr, Port) of
                     true  -> Queue ++ [{Data, ip_sockaddr(Addr, Port)}];
                     false -> Queue
                 end,
            udp_pump(Sock, Peer, Q1, false);
        {error, Reason} when Reason =:= timeout; Reason =:= etimedout;
                             Reason =:= eagain; Reason =:= ewouldblock ->
            {ok, Queue};
        {error, Reason} when Queue =/= [] ->
            %% Hand over what already arrived; the error surfaces on the next receive.
            _ = Reason, {ok, Queue};
        {error, Reason} ->
            {error, Reason}
    end.

take_up_to(Max, List) when length(List) =< Max -> {List, []};
take_up_to(Max, List)                          -> lists:split(Max, List).

peer_matches(none, _Addr, _Port)                 -> true;
peer_matches({udp, Addr, Port}, Addr, Port)      -> true;
peer_matches({udp, _, _}, _Addr, _Port)          -> false.

udp_drop(H) ->
    case wasm_component:host_get(H) of
        {ok, {udp_socket, {udp_bound, Sock, _Conn}}} -> _ = wasi_sock2:close(Sock);
        {ok, {udp_socket, {_State, Handle}}}         -> _ = wasi_sock2:close(Handle);
        _                                            -> ok
    end,
    _ = erase({?SOCKOPT, H}),
    wasm_component:host_drop(H).

%% A POSIX reason atom (from wasi_sock2 / the `socket` module) to an error-code name.
sock2_errno(eaddrinuse)    -> <<"address-in-use">>;
sock2_errno(eaddrnotavail) -> <<"address-not-bindable">>;
sock2_errno(econnrefused)  -> <<"connection-refused">>;
sock2_errno(econnreset)    -> <<"connection-reset">>;
sock2_errno(econnaborted)  -> <<"connection-aborted">>;
sock2_errno(etimedout)     -> <<"timeout">>;
sock2_errno(timeout)       -> <<"timeout">>;
sock2_errno(ehostunreach)  -> <<"remote-unreachable">>;
sock2_errno(enetunreach)   -> <<"remote-unreachable">>;
sock2_errno(eafnosupport)  -> <<"invalid-argument">>;
sock2_errno(eacces)        -> <<"access-denied">>;
sock2_errno(eperm)         -> <<"access-denied">>;
sock2_errno(emsgsize)      -> <<"datagram-too-large">>;
sock2_errno(eagain)        -> <<"would-block">>;
sock2_errno(ewouldblock)   -> <<"would-block">>;
sock2_errno(einval)        -> <<"invalid-argument">>;
sock2_errno(_Other)        -> <<"unknown">>.

%%% ------------------------------------------------------- address checks ---

%% An address is bindable for a socket's family when its family matches, it is not
%% an IPv4-mapped IPv6 address (these sockets are not dual-stack), and it is a
%% unicast address. The unspecified address (bind-to-any) and port 0 (ephemeral) are
%% both allowed for a bind.
bind_addr_ok(Family, Ip) ->
    ip_family(Ip) =:= Family andalso not mapped_v4(Ip) andalso unicast(Ip).

%% A connect/stream target additionally may not be the unspecified address or port 0.
connect_addr_ok(Family, Ip, Port) ->
    bind_addr_ok(Family, Ip) andalso not unspecified(Ip) andalso Port =/= 0.

ip_family({_, _, _, _})             -> inet;
ip_family({_, _, _, _, _, _, _, _}) -> inet6;
ip_family(_)                        -> undefined.

unspecified({0, 0, 0, 0})             -> true;
unspecified({0, 0, 0, 0, 0, 0, 0, 0}) -> true;
unspecified(_)                        -> false.

%% ::ffff:a.b.c.d
mapped_v4({0, 0, 0, 0, 0, 16#ffff, _, _}) -> true;
mapped_v4(_)                              -> false.

%% Reject broadcast and multicast: IPv4 255.255.255.255, IPv4 224.0.0.0/4, and IPv6
%% ff00::/8.
unicast({255, 255, 255, 255})       -> false;
unicast({A, _, _, _}) when A >= 224, A =< 239 -> false;
unicast({G, _, _, _, _, _, _, _}) when (G band 16#ff00) =:= 16#ff00 -> false;
unicast(_)                          -> true.

%% Resolve only if the grant behind the network permits it: no grant, no network.
resolve_addresses(NetH, Name) ->
    case wasm_component:host_get(NetH) of
        {ok, {net_network, Grant}} ->
            case classify_name(Name) of
                invalid ->
                    {error, <<"invalid-argument">>};
                {literal, Addr} ->
                    %% An IP literal is not a DNS lookup, so it needs no resolve
                    %% capability; the literal is its own single result.
                    {ok, wasm_component:host_new(net_addrs, [Addr])};
                hostname ->
                    case wasi_net:resolves(Grant) of
                        %% No resolve capability is a permanent resolver failure, the
                        %% code a resolver-less host reports (a grant-less guest maps
                        %% any error to no addresses either way).
                        false -> {error, <<"permanent-resolver-failure">>};
                        true  -> {ok, wasm_component:host_new(
                                        net_addrs, resolve_names(Name))}
                    end
            end;
        _ ->
            {error, <<"invalid-argument">>}
    end.

%% A name is an IP literal, a resolvable hostname, or invalid. Reject up front what
%% is neither an address nor a bare host: whitespace, a scheme, a port (`host:port`
%% or `[v6]:port`), or an illegal character. A bracketed IPv6 (`[::]`) is a literal;
%% `[::]:80` carries a port and is invalid.
classify_name(<<>>) ->
    invalid;
classify_name(Name) ->
    S = binary_to_list(Name),
    case bad_name(S) of
        true ->
            invalid;
        false ->
            case strip_brackets(S) of
                invalid ->
                    invalid;
                {bracketed, Inner} ->
                    case inet:parse_ipv6_address(Inner) of
                        {ok, Addr} -> {literal, wasi_net:normalise(Addr)};
                        _          -> invalid
                    end;
                {plain, Plain} ->
                    case inet:parse_address(Plain) of
                        {ok, Addr}  -> {literal, wasi_net:normalise(Addr)};
                        {error, _}  -> hostname
                    end
            end
    end.

%% Whitespace, a URL scheme, or a character no hostname or address carries.
bad_name(S) ->
    lists:any(fun(C) -> C =< $\s orelse lists:member(C, "<>&#?/\\@%") end, S)
        orelse string:find(S, "://") =/= nomatch.

strip_brackets([$[ | Rest]) ->
    case lists:splitwith(fun(C) -> C =/= $] end, Rest) of
        {Inner, "]"} -> {bracketed, Inner};
        _            -> invalid
    end;
strip_brackets(S) ->
    %% A colon in an unbracketed name that is not an IPv6 literal is a port.
    case {lists:member($:, S), inet:parse_address(S)} of
        {true, {error, _}} -> invalid;
        _                  -> {plain, S}
    end.

resolve_names(Name) ->
    Host = binary_to_list(Name),
    lists:usort(
      lists:flatmap(
        fun(Family) ->
            case inet:getaddrs(Host, Family) of
                {ok, Addrs} -> [wasi_net:normalise(A) || A <- Addrs];
                {error, _}  -> []
            end
        end, [inet, inet6])).

resolve_next(Stream) ->
    case wasm_component:host_get(Stream) of
        {ok, {net_addrs, []}} ->
            {ok, none};
        {ok, {net_addrs, [Addr | Rest]}} ->
            _ = wasm_component:host_update(Stream, Rest),
            {ok, {some, ip_address(Addr)}};
        _ ->
            {error, <<"invalid-argument">>}
    end.

ip_address({A, B, C, D}) ->
    {<<"ipv4">>, {A, B, C, D}};
ip_address({A, B, C, D, E, F, G, H}) ->
    {<<"ipv6">>, {A, B, C, D, E, F, G, H}}.

