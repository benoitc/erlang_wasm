-module(wasi_p3_sockets).
-moduledoc """
`wasi:sockets` at 0.3: the same TCP and UDP sockets as `wasi_p2_sockets`,
under the same grant, through the 0.3 interface.

The operations are `wasi_p2_sockets`', so the address checks and the grant are
one implementation. What changes: there is no network resource, `bind`,
`connect` and `listen` are one call each, a TCP connection's data goes through
a `send` stream and a `receive` stream, `listen` is a stream of accepted
sockets, and UDP `send` and `receive` are async.
""".

-export([sockets/1]).

-define(TYPES, ~"wasi:sockets/types@0.3").
-define(LOOKUP, ~"wasi:sockets/ip-name-lookup@0.3").
-define(ERRORS,
        [~"access-denied", ~"not-supported", ~"invalid-argument", ~"out-of-memory",
         ~"timeout", ~"invalid-state", ~"address-not-bindable", ~"address-in-use",
         ~"remote-unreachable", ~"connection-refused", ~"connection-broken",
         ~"connection-reset", ~"connection-aborted", ~"datagram-too-large"]).
-define(ERROR, {variant, [{E, none} || E <- ?ERRORS] ++ [{~"other", {option, string}}]}).
-define(LOOKUP_ERRORS,
        [~"access-denied", ~"invalid-argument", ~"name-unresolvable",
         ~"temporary-resolver-failure", ~"permanent-resolver-failure"]).
-define(LOOKUP_ERROR,
        {variant, [{E, none} || E <- ?LOOKUP_ERRORS] ++ [{~"other", {option, string}}]}).
-define(FAMILY, {enum, [~"ipv4", ~"ipv6"]}).
-define(IPV4, {tuple, [u8, u8, u8, u8]}).
-define(IPV6, {tuple, [u16, u16, u16, u16, u16, u16, u16, u16]}).
-define(IP, {variant, [{~"ipv4", ?IPV4}, {~"ipv6", ?IPV6}]}).
-define(SOCKADDR,
        {variant,
         [{~"ipv4", {record, [{~"port", u16}, {~"address", ?IPV4}]}},
          {~"ipv6", {record, [{~"port", u16}, {~"flow-info", u32}, {~"address", ?IPV6},
                              {~"scope-id", u32}]}}]}).
-define(UNIT, {result, none, ?ERROR}).
-define(R(T), {result, T, ?ERROR}).
-define(STATUS, {future, ?UNIT}).
%% How long one receive or accept waits before looking again; the producer
%% loops, so this only bounds how late it notices it was stopped.
-define(POLL_MS, 1000).
-define(CHUNK, 65536).

-doc """
`wasi:sockets` at 0.3 under the grant `network` in `Opts` (none: every socket
is refused at create).
""".
-spec sockets(map()) -> #{{binary(), binary()} => term()}.
sockets(Opts) ->
    Grant = wasi_net:grant(maps:get(network, Opts, none)),
    P2 = wasi_p2_sockets,
    Tcp = fun(N) -> <<"[method]tcp-socket.", N/binary>> end,
    Udp = fun(N) -> <<"[method]udp-socket.", N/binary>> end,
    Fun = fun(Name, Sig, F) -> {{?TYPES, Name}, wasm_component:import_fun(Sig, F)} end,
    Async = fun(Name, Sig, F) -> {{?TYPES, Name}, {async_import, Sig, F}} end,
    Opt = fun(Kind, Name, Which, T) ->
                  [Fun(Kind(<<"get-", Name/binary>>), {[handle], ?R(T)},
                       fun([S]) -> err(P2:opt_get(S, Which)) end),
                   Fun(Kind(<<"set-", Name/binary>>), {[handle, T], ?UNIT},
                       fun([S, V]) -> unit(set(S, Which, V)) end)]
          end,
    maps:from_list(
      [{{?LOOKUP, ~"resolve-addresses"},
        {async_import, {[string], {result, {list, ?IP}, ?LOOKUP_ERROR}},
         fun([Name]) -> {returned, resolve(Grant, Name)} end}},
       Fun(~"[static]tcp-socket.create", {[?FAMILY], ?R(handle)},
           fun([F]) -> err(P2:create_tcp_socket(F, Grant)) end),
       Fun(Tcp(~"bind"), {[handle, ?SOCKADDR], ?UNIT},
           fun([S, A]) -> unit(tcp_bind(S, A, Grant)) end),
       Async(Tcp(~"connect"), {[handle, ?SOCKADDR], ?UNIT},
             fun([S, A]) -> {returned, unit(tcp_connect(S, A, Grant))} end),
       Fun(Tcp(~"listen"), {[handle], ?R({stream, handle})},
           fun([S]) -> err(listen(S, Grant)) end),
       Fun(Tcp(~"send"), {[handle, {stream, u8}], ?STATUS},
           fun([S, Data]) -> send(S, Data) end),
       Fun(Tcp(~"receive"), {[handle], {tuple, [{stream, u8}, ?STATUS]}},
           fun([S]) -> receive_stream(S) end),
       Fun(Tcp(~"get-local-address"), {[handle], ?R(?SOCKADDR)},
           fun([S]) -> err(P2:tcp_local(S)) end),
       Fun(Tcp(~"get-remote-address"), {[handle], ?R(?SOCKADDR)},
           fun([S]) -> err(P2:tcp_remote(S)) end),
       Fun(Tcp(~"get-is-listening"), {[handle], bool},
           fun([S]) -> P2:tcp_is_listening(S) end),
       Fun(Tcp(~"get-address-family"), {[handle], ?FAMILY},
           fun([S]) -> P2:tcp_family(S) end),
       Fun(Tcp(~"set-listen-backlog-size"), {[handle, u64], ?UNIT},
           fun([S, N]) -> unit(P2:tcp_set_nonzero(S, N)) end)]
      ++ Opt(Tcp, ~"keep-alive-enabled", keep_alive_enabled, bool)
      ++ Opt(Tcp, ~"keep-alive-idle-time", keep_alive_idle_time, u64)
      ++ Opt(Tcp, ~"keep-alive-interval", keep_alive_interval, u64)
      ++ Opt(Tcp, ~"keep-alive-count", keep_alive_count, u32)
      ++ Opt(Tcp, ~"hop-limit", hop_limit, u8)
      ++ Opt(Tcp, ~"receive-buffer-size", recv_buffer, u64)
      ++ Opt(Tcp, ~"send-buffer-size", send_buffer, u64)
      ++ [{{?TYPES, ~"[resource-drop]tcp-socket"},
           fun(_Ctx, [H]) -> _ = P2:tcp_drop(H), {ok, []} end},
          Fun(~"[static]udp-socket.create", {[?FAMILY], ?R(handle)},
              fun([F]) -> err(P2:create_udp_socket(F, Grant)) end),
          Fun(Udp(~"bind"), {[handle, ?SOCKADDR], ?UNIT},
              fun([S, A]) -> unit(udp_bind(S, A, Grant)) end),
          Fun(Udp(~"connect"), {[handle, ?SOCKADDR], ?UNIT},
              fun([S, A]) -> unit(udp_connect(S, {some, A}, Grant)) end),
          Fun(Udp(~"disconnect"), {[handle], ?UNIT},
              fun([S]) -> unit(udp_disconnect(S)) end),
          Async(Udp(~"send"), {[handle, {list, u8}, {option, ?SOCKADDR}], ?UNIT},
                fun([S, Data, To]) -> {returned, unit(udp_send(S, Data, To, Grant))} end),
          {{?TYPES, Udp(~"receive")},
           {async_import, {[handle], ?R({tuple, [{list, u8}, ?SOCKADDR]})},
            fun([S]) -> udp_receiving(S) end, {producer, fun udp_receive/1}}},
          Fun(Udp(~"get-local-address"), {[handle], ?R(?SOCKADDR)},
              fun([S]) -> err(P2:udp_local(S)) end),
          Fun(Udp(~"get-remote-address"), {[handle], ?R(?SOCKADDR)},
              fun([S]) -> err(P2:udp_remote_addr(S)) end),
          Fun(Udp(~"get-address-family"), {[handle], ?FAMILY},
              fun([S]) -> P2:udp_family(S) end)]
      ++ Opt(Udp, ~"unicast-hop-limit", hop_limit, u8)
      ++ Opt(Udp, ~"receive-buffer-size", recv_buffer, u64)
      ++ Opt(Udp, ~"send-buffer-size", send_buffer, u64)
      ++ [{{?TYPES, ~"[resource-drop]udp-socket"},
           fun(_Ctx, [H]) -> _ = P2:udp_drop(H), {ok, []} end}]).

%% A setter with a zero for a size or a time is invalid; the rest pass through.
set(S, Which, V) when Which =:= keep_alive_enabled -> wasi_p2_sockets:opt_set(S, Which, V);
set(S, Which, V) -> wasi_p2_sockets:opt_set_nonzero(S, Which, V).

%%% ---------------------------------------------------------------- tcp ---

%% 0.2's start and finish, one after the other. A 0.3 bind reuses an address
%% still in TIME_WAIT from a socket just closed, as wasmtime's does.
tcp_bind(S, Addr, Grant) ->
    case wasm_component:host_get(S) of
        {ok, {tcp_socket, {unconnected, {tcp, _, Raw}}}} ->
            _ = socket:setopt(Raw, {socket, reuseaddr}, true);
        _ -> ok
    end,
    case wasi_p2_sockets:tcp_start_bind(S, net(Grant), Addr) of
        {ok, _} -> wasi_p2_sockets:finish(S, tcp_socket, binding, bound);
        E -> E
    end.

tcp_connect(S, Addr, Grant) ->
    case wasi_p2_sockets:tcp_start_connect(S, net(Grant), Addr) of
        {ok, _} ->
            {ok, {tcp_socket, {connecting, Conn}}} = wasm_component:host_get(S),
            _ = wasm_component:host_update(S, {connected, Conn}),
            {ok, undefined};
        E -> E
    end.

%% A listening socket's connections, as a stream a producer fills by accepting.
%% The producer hands each accepted socket to the owner, whose table the
%% guest's handle must be in.
listen(S, Grant) ->
    case auto_bind(S, Grant) of
        ok ->
            case wasi_p2_sockets:tcp_start_listen(S) of
                {ok, _} ->
                    {ok, _} = wasi_p2_sockets:finish(S, tcp_socket, listen_pending,
                                                     listening),
                    {ok, {tcp_socket, {listening, Listen}}} = wasm_component:host_get(S),
                    Owner = self(),
                    Accepted = fun(Conns) ->
                                       [accepted(S, C, Grant) || C <- Conns]
                               end,
                    R = wasm_async:new_stream_channel(handle, Accepted),
                    ok = wasm_async:register_producer(
                           R, fun(Ctx) -> accept_loop(Listen, Owner, Ctx) end),
                    {ok, R};
                E -> E
            end;
        E -> E
    end.

%% 0.3 listens on an unbound socket by binding it to any port first.
auto_bind(S, Grant) ->
    case wasm_component:host_get(S) of
        {ok, {tcp_socket, {unconnected, H}}} ->
            Any = any(wasi_sock2:family(H)),
            case tcp_bind(S, Any, Grant) of
                {ok, _} -> ok;
                E -> E
            end;
        _ -> ok
    end.

accept_loop(Listen, Owner, #{task_ref := Ref, handle := H} = Ctx) ->
    case wasi_sock2:accept(Listen, ?POLL_MS) of
        {ok, {_, _, Raw} = Conn} ->
            %% The owner's socket from now on: it outlives this producer.
            ok = socket:setopt(Raw, {otp, controlling_process}, Owner),
            Owner ! {async_ready, Ref, H, {data, [Conn]}},
            accept_loop(Listen, Owner, Ctx);
        {error, timeout} -> accept_loop(Listen, Owner, Ctx);
        {error, _} -> Owner ! {async_ready, Ref, H, close}
    end.

accepted(Listener, Conn, _Grant) ->
    Sock = wasm_component:host_new(tcp_socket, {connected, Conn}),
    _ = wasi_p2_sockets:inherit_sockopts(Listener, Sock),
    Sock.

%% What the guest writes to `Data' is sent as it is written; ending the stream
%% shuts the connection for writing, and the future reports how it went.
send(S, Data) ->
    {R, W} = wasm_async:host_future(?UNIT),
    case connected(S) of
        {ok, Conn} ->
            Sink = fun(eof) ->
                           _ = wasi_sock2:shutdown(Conn, write),
                           _ = wasm_async:host_future_resolve(W, {ok, undefined}),
                           ok;
                      (Bytes) ->
                           case wasi_sock2:send(Conn, Bytes) of
                               ok -> ok;
                               {error, E} ->
                                   _ = wasm_async:host_future_resolve(
                                         W, {error, code(wasi_p2_sockets:sock2_errno(E))}),
                                   closed
                           end
                   end,
            ok = wasm_async:host_sink(Data, Sink, ?CHUNK);
        {error, E} ->
            ok = wasm_async:host_sink(Data, fun(_) -> closed end),
            ok = wasm_async:host_future_resolve(W, {error, code(E)})
    end,
    R.

%% The connection's incoming bytes, as a stream a producer fills until the
%% peer closes.
receive_stream(S) ->
    case connected(S) of
        {ok, Conn} ->
            R = wasm_async:new_stream_channel(u8),
            ok = wasm_async:register_producer(R, fun(Ctx) -> recv_loop(Conn, Ctx) end),
            {R, resolved({ok, undefined})};
        {error, E} ->
            R = wasm_async:new_stream_channel(u8),
            ok = wasm_async:register_producer(
                   R, fun(#{owner := O, task_ref := Ref, handle := H}) ->
                              O ! {async_ready, Ref, H, close}
                      end),
            {R, resolved({error, code(E)})}
    end.

recv_loop(Conn, #{owner := O, task_ref := Ref, handle := H} = Ctx) ->
    case wasi_sock2:recv(Conn, ?CHUNK, ?POLL_MS) of
        {ok, Bin} -> O ! {async_ready, Ref, H, {data, Bin}}, recv_loop(Conn, Ctx);
        {error, timeout} -> recv_loop(Conn, Ctx);
        _ -> O ! {async_ready, Ref, H, close}
    end.

connected(S) ->
    case wasm_component:host_get(S) of
        {ok, {tcp_socket, {connected, Conn}}} -> {ok, Conn};
        _ -> {error, ~"invalid-state"}
    end.

%%% ---------------------------------------------------------------- udp ---

udp_bind(S, Addr, Grant) ->
    case wasi_p2_sockets:udp_start_bind(S, net(Grant), Addr) of
        {ok, _} -> wasi_p2_sockets:udp_finish_bind(S);
        E -> E
    end.

udp_connect(S, Remote, Grant) ->
    case wasm_component:host_get(S) of
        {ok, {udp_socket, {udp_unbound, _}}} ->
            case bind_any(S, Grant) of
                {ok, _} -> udp_connect(S, Remote, Grant);
                E -> E
            end;
        {ok, {udp_socket, {udp_bound, Sock, _}}} ->
            case wasi_p2_sockets:udp_connect(Sock, Remote, Grant) of
                {ok, Peer} ->
                    _ = wasm_component:host_update(S, {udp_bound, Sock, Peer}),
                    {ok, undefined};
                E -> E
            end;
        _ -> {error, ~"invalid-state"}
    end.

udp_disconnect(S) ->
    case wasm_component:host_get(S) of
        {ok, {udp_socket, {udp_bound, Sock, {udp, _, _}}}} ->
            _ = wasm_component:host_update(S, {udp_bound, Sock, none}),
            {ok, undefined};
        _ -> {error, ~"invalid-state"}
    end.

%% A send needs somewhere to go: the connected peer, or the address given. An
%% unbound socket is bound to any address first.
udp_send(S, Data, To, Grant) ->
    case wasm_component:host_get(S) of
        {ok, {udp_socket, {udp_unbound, _}}} when To =:= none ->
            {error, ~"invalid-argument"};
        {ok, {udp_socket, {udp_unbound, _}}} ->
            case bind_any(S, Grant) of
                {ok, _} -> udp_send(S, Data, To, Grant);
                E -> E
            end;
        {ok, {udp_socket, {udp_bound, Sock, Peer}}} ->
            send_bound(Sock, Peer, Data, To, Grant);
        _ -> {error, ~"invalid-state"}
    end.

%% A connected socket sends to its peer only; an unconnected one to the
%% address given, which must be a real destination the grant allows.
send_bound(Sock, {udp, _, _}, Data, none, _Grant) ->
    sent(wasi_sock2:send(Sock, Data));
send_bound(Sock, {udp, _, _} = Peer, Data, {some, Addr}, _Grant) ->
    case wasi_p2_sockets:endpoint_udp(Addr) of
        Peer -> sent(wasi_sock2:send(Sock, Data));
        _ -> {error, ~"invalid-argument"}
    end;
send_bound(_Sock, none, _Data, none, _Grant) ->
    {error, ~"invalid-argument"};
send_bound(Sock, none, Data, {some, Addr}, Grant) ->
    {udp, Ip, Port} = Endpoint = wasi_p2_sockets:endpoint_udp(Addr),
    case Port =:= 0 orelse unspecified(Ip) orelse family(Ip) =/= wasi_sock2:family(Sock) of
        true -> {error, ~"invalid-argument"};
        false ->
            case wasi_net:allows(connect, Endpoint, Grant) of
                true -> sent(wasi_sock2:sendto(Sock, Data, {Ip, Port}));
                false -> {error, ~"access-denied"}
            end
    end.

unspecified(Ip) -> lists:all(fun(X) -> X =:= 0 end, tuple_to_list(Ip)).

family(Ip) when tuple_size(Ip) =:= 4 -> inet;
family(_) -> inet6.

bind_any(S, Grant) ->
    {ok, {udp_socket, {udp_unbound, H}}} = wasm_component:host_get(S),
    udp_bind(S, any(wasi_sock2:family(H)), Grant).

any(inet) -> {~"ipv4", #{~"port" => 0, ~"address" => {0, 0, 0, 0}}};
any(inet6) -> {~"ipv6", #{~"port" => 0, ~"flow-info" => 0,
                          ~"address" => {0, 0, 0, 0, 0, 0, 0, 0}, ~"scope-id" => 0}}.

sent(ok) -> {ok, undefined};
sent({error, E}) -> {error, wasi_p2_sockets:sock2_errno(E)}.

%% A bound socket waits in a producer for its next datagram, which completes
%% the call; anything else answers at once.
udp_receiving(S) ->
    case wasm_component:host_get(S) of
        {ok, {udp_socket, {udp_bound, Sock, _}}} -> Sock;
        _ -> {returned, {error, code(~"invalid-state")}}
    end.

udp_receive(#{owner := O, task_ref := Ref, handle := H, value := Sock} = Ctx) ->
    case wasi_sock2:recvfrom(Sock, ?POLL_MS) of
        {ok, {Ip, Port}, Data} ->
            O ! {async_ready, Ref, H,
                 {subtask_complete, {ok, {Data, wasi_p2_sockets:ip_sockaddr(Ip, Port)}}}};
        {error, timeout} -> udp_receive(Ctx);
        {error, E} ->
            O ! {async_ready, Ref, H,
                 {subtask_complete, {error, code(wasi_p2_sockets:sock2_errno(E))}}}
    end.

%%% ------------------------------------------------------------- lookup ---

resolve(Grant, Name) ->
    case wasi_p2_sockets:resolve_addresses(net(Grant), Name) of
        {ok, Stream} ->
            {ok, {net_addrs, Addrs}} = wasm_component:host_get(Stream),
            _ = wasm_component:host_drop(Stream),
            {ok, [wasi_p2_sockets:ip_address(A) || A <- Addrs]};
        {error, E} -> {error, lookup_code(E)}
    end.

lookup_code(Name) ->
    case lists:member(Name, ?LOOKUP_ERRORS) of
        true -> {Name, undefined};
        false -> {~"other", {some, Name}}
    end.

%%% -------------------------------------------------------------- shapes ---

%% The 0.2 operations take a network resource; 0.3 has none, so one is made
%% once per instance and kept.
net(Grant) ->
    case get({?MODULE, net}) of
        H when is_integer(H) ->
            case wasm_component:host_get(H) of
                {ok, {net_network, _}} -> H;
                _ -> new_net(Grant)
            end;
        _ -> new_net(Grant)
    end.

new_net(Grant) ->
    H = wasm_component:host_new(net_network, Grant),
    put({?MODULE, net}, H),
    H.

resolved(Value) ->
    {R, W} = wasm_async:host_future(?UNIT),
    ok = wasm_async:host_future_resolve(W, Value),
    R.

code(Name) ->
    case lists:member(Name, ?ERRORS) of
        true -> {Name, undefined};
        false -> {~"other", {some, Name}}
    end.

err({ok, V}) -> {ok, V};
err({error, E}) -> {error, code(E)}.

unit({ok, _}) -> {ok, undefined};
unit({error, E}) -> {error, code(E)}.
