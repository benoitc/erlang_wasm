-module(wasi_sock2).
-moduledoc """
The TCP backend for `wasi:sockets`, over OTP's low-level `socket` module.

Read this if you are changing how the WASI 0.2 TCP state machine behaves. It exists
because `gen_tcp` (what `wasi_sock` uses, and what preview1 keeps using) cannot
express the WASI TCP socket: there is no `gen_tcp` shape that is *bound but not yet a
client or a listener*, so a socket bound to an ephemeral port cannot report the port
it got, a double bind is never detected, and a client cannot bind before it connects.
The `socket` module has a real `bind` separate from `connect`/`listen`, `sockname`
after bind, and `select`-based non-blocking readiness, which is exactly the state
machine WASI describes.

This module is deliberately isolated: only `wasi_preview2` uses it, so preview1's
`gen_tcp` path (and its 0-fail conformance) is untouched. A handle is
`{tcp, Family, socket:socket()}`: the same OS socket carried from `open` through
`bind` and on to `connect` or `listen`; the WASI phase (unconnected/bound/listening/
connected) is tracked by the caller, not here. Errors are POSIX atoms the caller maps
to WASI `error-code`s.
""".

-export([open/1, open_udp/1, bind/2, connect/3, listen/2, accept/2]).
-export([recv/3, send/2, recvfrom/2, sendto/3, shutdown/2, close/1]).
-export([sockname/1, peername/1, family/1, setopt/3, getopt/2]).

-export_type([handle/0]).

-type handle() :: {tcp | udp, inet | inet6, socket:socket()}.
-type endpoint() :: {inet:ip_address(), inet:port_number()}.
-type reason() :: atom().

%%% ------------------------------------------------------------------ open ---

-doc """
Open a TCP socket of the given family, with SO_REUSEADDR set (the WASI runtime is
expected to, so a rebind after a closed connection is not blocked by TIME_WAIT).
Nothing is bound yet.
""".
-spec open(inet | inet6) -> {ok, handle()} | {error, reason()}.
open(Family) ->
    case socket:open(Family, stream, tcp) of
        {ok, S} ->
            _ = socket:setopt(S, {socket, reuseaddr}, true),
            {ok, {tcp, Family, S}};
        {error, Reason} ->
            {error, flatten(Reason)}
    end.

-doc """
Open a UDP socket. No SO_REUSEADDR: two sockets binding the same address should
conflict (address-in-use), which is what the WASI bind tests assert.
""".
-spec open_udp(inet | inet6) -> {ok, handle()} | {error, reason()}.
open_udp(Family) ->
    case socket:open(Family, dgram, udp) of
        {ok, S}         -> {ok, {udp, Family, S}};
        {error, Reason} -> {error, flatten(Reason)}
    end.

%%% ------------------------------------------------------------------ bind ---

-doc "Bind the socket to a local address. Reports the OS error (e.g. eaddrinuse).".
-spec bind(handle(), endpoint()) -> ok | {error, reason()}.
bind({_Proto, Family, S}, {Addr, Port}) ->
    map(socket:bind(S, sockaddr(Family, Addr, Port))).

%%% --------------------------------------------------------------- connect ---

-doc "Connect to a remote address, from an unconnected or a bound socket.".
-spec connect(handle(), endpoint(), timeout()) -> ok | {error, reason()}.
connect({_Proto, Family, S}, {Addr, Port}, Timeout) ->
    map(socket:connect(S, sockaddr(Family, Addr, Port), Timeout)).

%%% ---------------------------------------------------------------- listen ---

-doc "Start listening with the given backlog (from a bound socket).".
-spec listen(handle(), non_neg_integer()) -> ok | {error, reason()}.
listen({tcp, _Family, S}, Backlog) ->
    map(socket:listen(S, Backlog)).

-doc "Accept a connection, blocking up to `Timeout`. A timeout is `{error, timeout}`.".
-spec accept(handle(), timeout()) -> {ok, handle()} | {error, reason()}.
accept({tcp, Family, S}, Timeout) ->
    case socket:accept(S, Timeout) of
        {ok, Conn}      -> {ok, {tcp, Family, Conn}};
        {error, Reason} -> {error, flatten(Reason)}
    end.

%%% ------------------------------------------------------------ read/write ---

-doc """
Receive up to what has arrived (a stream read). `eof` is an orderly peer close;
`{error, timeout}` is a would-block once `Timeout` is 0.
""".
-spec recv(handle(), non_neg_integer(), timeout()) ->
          {ok, binary()} | eof | {error, reason()}.
recv({_Proto, _Family, S}, _Want, Timeout) ->
    %% Length 0 asks for whatever is available, the up-to-N stream semantics the
    %% caller wants (it buffers any excess itself).
    case socket:recv(S, 0, [], Timeout) of
        {ok, Data}          -> {ok, Data};
        {error, closed}     -> eof;
        {error, {closed, D}} when byte_size(D) > 0 -> {ok, D};
        {error, {timeout, D}} when byte_size(D) > 0 -> {ok, D};
        {error, Reason}     -> {error, flatten(Reason)}
    end.

-doc "Send a whole buffer (on a connected socket).".
-spec send(handle(), binary()) -> ok | {error, reason()}.
send({_Proto, _Family, S}, Data) ->
    case socket:send(S, Data) of
        ok               -> ok;
        {ok, _Rest}      -> ok;
        {error, Reason}  -> {error, flatten(Reason)}
    end.

-doc """
Receive one datagram with its source address. On a connected UDP socket a peer that
is gone surfaces as an error (an ICMP port-unreachable becomes econnrefused).
""".
-spec recvfrom(handle(), timeout()) ->
          {ok, endpoint(), binary()} | {error, reason()}.
recvfrom({_Proto, _Family, S}, Timeout) ->
    case socket:recvfrom(S, 0, [], Timeout) of
        {ok, {#{addr := Addr, port := Port}, Data}} -> {ok, {Addr, Port}, Data};
        {error, Reason}                             -> {error, flatten(Reason)}
    end.

-doc "Send one datagram to an explicit destination.".
-spec sendto(handle(), binary(), endpoint()) -> ok | {error, reason()}.
sendto({_Proto, Family, S}, Data, {Addr, Port}) ->
    case socket:sendto(S, Data, sockaddr(Family, Addr, Port)) of
        ok              -> ok;
        {ok, _Rest}     -> ok;
        {error, Reason} -> {error, flatten(Reason)}
    end.

-doc "Shut down one or both directions.".
-spec shutdown(handle(), read | write | both) -> ok | {error, reason()}.
shutdown({tcp, _Family, S}, both)  -> map(socket:shutdown(S, read_write));
shutdown({tcp, _Family, S}, read)  -> map(socket:shutdown(S, read));
shutdown({tcp, _Family, S}, write) -> map(socket:shutdown(S, write)).

-doc "Close the socket.".
-spec close(handle()) -> ok.
close({_Proto, _Family, S}) ->
    _ = socket:close(S),
    ok.

%%% ------------------------------------------------------------- addresses ---

-doc "The local address (real getsockname; works once bound).".
-spec sockname(handle()) -> {ok, endpoint()} | {error, reason()}.
sockname({_Proto, _Family, S}) ->
    address(socket:sockname(S)).

-doc "The peer address (real getpeername; only once connected).".
-spec peername(handle()) -> {ok, endpoint()} | {error, reason()}.
peername({_Proto, _Family, S}) ->
    address(socket:peername(S)).

-doc "The socket's address family.".
-spec family(handle()) -> inet | inet6.
family({_Proto, Family, _S}) -> Family.

%%% --------------------------------------------------------------- sockopts ---

-doc "Set a socket option that the WASI keep-alive / buffer-size methods expose.".
-spec setopt(handle(), atom(), term()) -> ok | {error, reason()}.
setopt({_Proto, _F, S}, Name, Value) ->
    case optname(Name) of
        undefined -> {error, enoprotoopt};
        Opt       -> map(socket:setopt(S, Opt, Value))
    end.

-doc "Read a socket option.".
-spec getopt(handle(), atom()) -> {ok, term()} | {error, reason()}.
getopt({_Proto, _F, S}, Name) ->
    case optname(Name) of
        undefined -> {error, enoprotoopt};
        Opt       -> map_get(socket:getopt(S, Opt))
    end.

optname(recv_buffer)         -> {socket, rcvbuf};
optname(send_buffer)         -> {socket, sndbuf};
optname(keep_alive_enabled)  -> {socket, keepalive};
optname(_Other)              -> undefined.

%%% ---------------------------------------------------------------- helpers ---

sockaddr(Family, Addr, Port) ->
    #{family => Family, addr => Addr, port => Port}.

address({ok, #{addr := Addr, port := Port}}) -> {ok, {Addr, Port}};
address({error, Reason})                     -> {error, flatten(Reason)}.

map(ok)              -> ok;
map({error, Reason}) -> {error, flatten(Reason)}.

map_get({ok, _} = Ok)   -> Ok;
map_get({error, Reason}) -> {error, flatten(Reason)}.

%% The socket module reports some errors as `{Reason, Extra}`; the caller only wants
%% the POSIX atom.
flatten({Reason, _Extra}) when is_atom(Reason) -> Reason;
flatten(Reason) when is_atom(Reason)           -> Reason;
flatten(_Other)                                -> unknown.
