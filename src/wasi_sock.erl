-module(wasi_sock).
-moduledoc """
Sockets, as WASI descriptors.

Read this if you are changing how the socket syscalls behave. You grant the
network in `wasi_net` and the descriptor table lives in `wasi_preview1`; what is
left is here: opening, binding, connecting, moving bytes, and turning a POSIX
reason into the errno the module expects.

Sockets are passive (`{active, false}`) and owned by the process that opened
them, which is the instance process, so they close when it exits. Nothing here
spawns anything or holds state of its own.

## A socket exists before it is a socket

`sock_open` gets a descriptor, not a file descriptor: nothing is opened until
the module says what the socket is for. `gen_tcp` has no unbound socket to hand
out, and holding an operating system socket for a descriptor that may never be
used would spend a real resource on a maybe. A pending handle records the
family and type; `sock_bind` remembers an address; `sock_connect` and
`sock_listen` are what actually open something.

## Reading hands back what it could not deliver

`gen_tcp:recv(S, 0, T)` returns whatever has arrived, which can be more than the
caller's buffers hold. The excess goes back to the caller to keep against the
next read rather than being dropped, because dropping it loses bytes from the
middle of a stream, silently, and only under load.
""".

-export([open/2, open_listener/1, bind/2, listen/2, accept/2, connect/3]).
-export([recv/3, recv_from/3, send/2, send_to/3, shutdown/2, close/1]).
-export([peer/1, local/1, family/1, type/1, filetype/1, errno/1]).
-export([getopt/2, setopt/3]).

-export_type([handle/0]).

-include("wasi.hrl").

%% What a listener gets when the module does not say. `sock_listen' takes a
%% backlog; the host-opened path has nobody to ask.
-define(DEFAULT_BACKLOG, 128).

-doc """
An open socket, tagged with what it is.

The tag is what makes "accept on a connected socket" an errno rather than a
surprise: the operations that need a listener match on it. `pending` and
`bound` hold no operating system resource at all.
""".
-nominal handle() :: {pending, inet | inet6, stream | dgram}
                   | {bound, inet | inet6, stream, {inet:ip_address(), 0..65535}}
                   | {listen, gen_tcp:socket()}
                   | {stream, gen_tcp:socket()}
                   | {dgram, gen_udp:socket()}.

%%% ----------------------------------------------------------------- open ---

-doc "A descriptor with a family and a type, and nothing open behind it yet.".
-spec open(inet | inet6, stream | dgram) -> {ok, handle()}.
open(Family, Type) -> {ok, {pending, Family, Type}}.

-doc """
Bind and listen in one step, for a socket the host opens on the module's
behalf. The endpoint has already been checked against the grant.
""".
-spec open_listener(wasi_net:endpoint()) ->
          {ok, handle()} | {error, non_neg_integer()}.
open_listener({tcp, Addr, Port}) ->
    tcp_listen(Addr, Port, ?DEFAULT_BACKLOG);
open_listener({udp, Addr, Port}) ->
    udp_open(Addr, Port).

tcp_listen(Addr, Port, Backlog) ->
    case gen_tcp:listen(Port, [binary, {active, false}, {reuseaddr, true},
                               {backlog, Backlog}, {ip, Addr}, family_of(Addr)]) of
        {ok, S} -> {ok, {listen, S}};
        {error, Reason} -> {error, errno(Reason)}
    end.

udp_open(Addr, Port) ->
    case gen_udp:open(Port, [binary, {active, false}, {ip, Addr},
                             family_of(Addr)]) of
        {ok, S} -> {ok, {dgram, S}};
        {error, Reason} -> {error, errno(Reason)}
    end.

-doc """
Claim a local address.

A datagram socket is opened here, because a bound datagram socket is already
usable. A stream socket only remembers the address: whether it becomes a
listener or the source address of an outbound connection is not known yet.
""".
-spec bind(handle(), wasi_net:endpoint()) ->
          {ok, handle()} | {error, non_neg_integer()}.
bind({pending, Family, dgram}, {udp, Addr, Port}) ->
    case matching_family(Family, Addr) of
        false -> {error, ?EAFNOSUPPORT};
        true -> udp_open(Addr, Port)
    end;
bind({pending, Family, stream}, {tcp, Addr, Port}) ->
    case matching_family(Family, Addr) of
        false -> {error, ?EAFNOSUPPORT};
        true -> {ok, {bound, Family, stream, {Addr, Port}}}
    end;
bind({pending, _Family, _Type}, _Endpoint) ->
    %% Asking to bind a datagram address on a stream socket, or the reverse.
    {error, ?EINVAL};
bind(_Handle, _Endpoint) ->
    {error, ?EISCONN}.

-doc "Start accepting. The address was checked when it was bound.".
-spec listen(handle(), non_neg_integer()) ->
          {ok, handle()} | {error, non_neg_integer()}.
listen({bound, _Family, stream, {Addr, Port}}, Backlog) ->
    tcp_listen(Addr, Port, backlog(Backlog));
listen({pending, _Family, _Type}, _Backlog) ->
    %% Listening on an address nobody named would mean choosing one here, and
    %% the capability check happens where the address is named.
    {error, ?EDESTADDRREQ};
listen(_Handle, _Backlog) ->
    {error, ?EISCONN}.

backlog(0) -> ?DEFAULT_BACKLOG;
backlog(N) when N > 0, N =< 4096 -> N;
backlog(_) -> ?DEFAULT_BACKLOG.

-doc "Take the next inbound connection.".
-spec accept(handle(), timeout()) ->
          {ok, handle()} | {error, non_neg_integer()}.
accept({listen, S}, Timeout) ->
    case gen_tcp:accept(S, Timeout) of
        {ok, Conn} -> {ok, {stream, Conn}};
        {error, Reason} -> {error, errno(Reason)}
    end;
accept(_Other, _Timeout) ->
    {error, ?ENOTSUP}.

-doc """
Connect to an already-checked address.

The address arrives as a tuple and leaves as a tuple. No name is resolved here,
so there is nothing between the capability check and the syscall that could
move the target.
""".
-spec connect(handle(), wasi_net:endpoint(), timeout()) ->
          {ok, handle()} | {error, non_neg_integer()}.
connect({pending, Family, stream}, {tcp, Addr, Port}, Timeout) ->
    tcp_connect(Family, Addr, Port, [], Timeout);
connect({bound, Family, stream, {Src, SrcPort}}, {tcp, Addr, Port}, Timeout) ->
    tcp_connect(Family, Addr, Port, [{ip, Src}, {port, SrcPort}], Timeout);
connect({pending, Family, dgram}, {udp, Addr, _Port} = Endpoint, _Timeout) ->
    %% A connected datagram socket is a bound one that remembers where to send.
    %% Opening it ephemerally is what an unbound `sendto' would do anyway.
    case matching_family(Family, Addr) of
        false -> {error, ?EAFNOSUPPORT};
        true -> connect_dgram(Family, Endpoint)
    end;
connect({stream, _S}, _Endpoint, _Timeout) ->
    {error, ?EISCONN};
connect(_Handle, _Endpoint, _Timeout) ->
    {error, ?ENOTSUP}.

tcp_connect(Family, Addr, Port, Opts, Timeout) ->
    case matching_family(Family, Addr) of
        false ->
            {error, ?EAFNOSUPPORT};
        true ->
            case gen_tcp:connect(Addr, Port, [binary, {active, false} | Opts],
                                 Timeout) of
                {ok, Conn} -> {ok, {stream, Conn}};
                {error, Reason} -> {error, errno(Reason)}
            end
    end.

connect_dgram(Family, {udp, Addr, Port}) ->
    Any = case Family of inet -> {0, 0, 0, 0}; inet6 -> {0, 0, 0, 0, 0, 0, 0, 0} end,
    case udp_open(Any, 0) of
        {error, _} = E -> E;
        {ok, {dgram, S}} ->
            case gen_udp:connect(S, Addr, Port) of
                ok -> {ok, {dgram, S}};
                {error, Reason} -> _ = gen_udp:close(S), {error, errno(Reason)}
            end
    end.

%%% ----------------------------------------------------------------- bytes ---

-doc """
Read up to `Want` bytes, or whatever has arrived if `Want` is 0.

Returns everything the socket gave up. The caller decides how much of it fits
in the module's buffers and keeps the rest.
""".
-spec recv(handle(), non_neg_integer(), timeout()) ->
          {ok, binary()} | eof | {error, non_neg_integer()}.
recv({stream, S}, Want, Timeout) ->
    case gen_tcp:recv(S, Want, Timeout) of
        {ok, Data} -> {ok, Data};
        {error, closed} -> eof;
        {error, Reason} -> {error, errno(Reason)}
    end;
recv({dgram, S}, Want, Timeout) ->
    case recv_from({dgram, S}, Want, Timeout) of
        {ok, Data, _From} -> {ok, Data};
        Other -> Other
    end;
recv(_Handle, _Want, _Timeout) ->
    {error, ?ENOTCONN}.

-doc """
Read one datagram, and say where it came from.

A datagram that does not fit is truncated, which is what the protocol does: the
rest of it is gone, and `ROFLAGS_RECV_DATA_TRUNCATED` is how the caller is told.
""".
-spec recv_from(handle(), non_neg_integer(), timeout()) ->
          {ok, binary(), {inet:ip_address(), 0..65535}} |
          {error, non_neg_integer()}.
recv_from({dgram, S}, _Want, Timeout) ->
    case gen_udp:recv(S, 0, Timeout) of
        {ok, {Addr, Port, Data}} ->
            {ok, Data, {wasi_net:normalise(Addr), Port}};
        {error, Reason} ->
            {error, errno(Reason)}
    end;
recv_from(_Handle, _Want, _Timeout) ->
    {error, ?ENOTSUP}.

-doc "Send all of `Data`, or fail.".
-spec send(handle(), binary()) -> ok | {error, non_neg_integer()}.
send({stream, S}, Data) ->
    case gen_tcp:send(S, Data) of
        ok -> ok;
        {error, Reason} -> {error, errno(Reason)}
    end;
send({dgram, S}, Data) ->
    case gen_udp:send(S, Data) of
        ok -> ok;
        {error, Reason} -> {error, errno(Reason)}
    end;
send(_Handle, _Data) ->
    {error, ?ENOTCONN}.

-doc "Send one datagram to an already-checked address.".
-spec send_to(handle(), binary(), wasi_net:endpoint()) ->
          {ok, handle()} | {error, non_neg_integer()}.
send_to({dgram, S}, Data, {udp, Addr, Port}) ->
    case gen_udp:send(S, Addr, Port, Data) of
        ok -> {ok, {dgram, S}};
        {error, Reason} -> {error, errno(Reason)}
    end;
send_to({pending, Family, dgram} = H, Data, {udp, _, _} = Endpoint) ->
    %% Sending from a socket that was never bound binds it ephemerally, which
    %% is what an unbound `sendto' does. The destination was checked; the
    %% source is whatever the host picks.
    Any = case Family of inet -> {0, 0, 0, 0}; inet6 -> {0, 0, 0, 0, 0, 0, 0, 0} end,
    case udp_open(Any, 0) of
        {error, _} = E ->
            _ = H,
            E;
        {ok, Opened} ->
            %% The socket belongs to the caller only if the send works: a
            %% failure answers an errno and no handle, so nothing would ever
            %% close this one. An unreachable destination on an unbound socket
            %% leaked one file descriptor per call.
            case send_to(Opened, Data, Endpoint) of
                {ok, _} = Ok -> Ok;
                {error, _} = E -> ok = close(Opened), E
            end
    end;
send_to(_Handle, _Data, _Endpoint) ->
    {error, ?ENOTSUP}.

-doc "Half-close. `How` is the WASI `sdflags` bitmask: 1 read, 2 write.".
-spec shutdown(handle(), non_neg_integer()) -> ok | {error, non_neg_integer()}.
shutdown({stream, S}, How) ->
    case direction(How) of
        error -> {error, ?EINVAL};
        Dir ->
            case gen_tcp:shutdown(S, Dir) of
                ok -> ok;
                {error, Reason} -> {error, errno(Reason)}
            end
    end;
shutdown(_Handle, _How) ->
    {error, ?ENOTCONN}.

direction(?SDFLAGS_RD) -> read;
direction(?SDFLAGS_WR) -> write;
direction(How) when How =:= (?SDFLAGS_RD bor ?SDFLAGS_WR) -> read_write;
direction(_) -> error.

-spec close(handle()) -> ok.
close({dgram, S}) -> gen_udp:close(S);
close({listen, S}) -> gen_tcp:close(S);
close({stream, S}) -> gen_tcp:close(S);
close(_Unopened) -> ok.

%%% --------------------------------------------------------------- options ---

%% The set that can be answered truthfully. Anything else is `ENOPROTOOPT':
%% accepting an option and ignoring it makes a module believe it configured
%% something, and it will find out at the worst moment that it did not.
-spec getopt(handle(), non_neg_integer()) ->
          {ok, integer()} | {error, non_neg_integer()}.
getopt(Handle, ?SO_TYPE) ->
    case type(Handle) of
        stream -> {ok, ?SOCK_TYPE_STREAM};
        dgram -> {ok, ?SOCK_TYPE_DGRAM}
    end;
getopt(Handle, ?SO_ACCEPTCONN) ->
    case Handle of
        {listen, _} -> {ok, 1};
        _ -> {ok, 0}
    end;
getopt(Handle, Name) when Name =:= ?SO_RCVBUF; Name =:= ?SO_SNDBUF;
                          Name =:= ?SO_KEEPALIVE; Name =:= ?SO_REUSEADDR ->
    inet_getopt(Handle, opt_name(Name));
getopt(_Handle, ?SO_ERROR) ->
    %% Errors are reported by the call that produced them, not held for later.
    {ok, 0};
getopt(_Handle, _Name) ->
    {error, ?ENOPROTOOPT}.

-spec setopt(handle(), non_neg_integer(), integer()) ->
          ok | {error, non_neg_integer()}.
setopt(Handle, Name, Value) when Name =:= ?SO_RCVBUF; Name =:= ?SO_SNDBUF ->
    inet_setopt(Handle, {opt_name(Name), Value});
setopt(Handle, Name, Value) when Name =:= ?SO_KEEPALIVE; Name =:= ?SO_REUSEADDR ->
    inet_setopt(Handle, {opt_name(Name), Value =/= 0});
setopt(_Handle, _Name, _Value) ->
    {error, ?ENOPROTOOPT}.

opt_name(?SO_RCVBUF) -> recbuf;
opt_name(?SO_SNDBUF) -> sndbuf;
opt_name(?SO_KEEPALIVE) -> keepalive;
opt_name(?SO_REUSEADDR) -> reuseaddr.

inet_getopt({Tag, S}, Name) when Tag =:= stream; Tag =:= listen; Tag =:= dgram ->
    case inet:getopts(S, [Name]) of
        {ok, [{_, V}]} when is_boolean(V) -> {ok, case V of true -> 1; false -> 0 end};
        {ok, [{_, V}]} -> {ok, V};
        _ -> {error, ?ENOPROTOOPT}
    end;
inet_getopt(_Unopened, _Name) ->
    %% Nothing is open yet, so there is no honest answer to give.
    {error, ?ENOTCONN}.

inet_setopt({Tag, S}, Opt) when Tag =:= stream; Tag =:= listen; Tag =:= dgram ->
    case inet:setopts(S, [Opt]) of
        ok -> ok;
        {error, Reason} -> {error, errno(Reason)}
    end;
inet_setopt(_Unopened, _Opt) ->
    {error, ?ENOTCONN}.

%%% --------------------------------------------------------------- addresses ---

-doc "The remote end of a connected socket.".
-spec peer(handle()) -> {ok, {inet:ip_address(), 0..65535}} |
                        {error, non_neg_integer()}.
peer({stream, S}) -> address(inet:peername(S));
peer({dgram, S}) -> address(inet:peername(S));
peer(_Handle) -> {error, ?ENOTCONN}.

-doc "The local end, which is how a module learns the port an ephemeral bind got.".
-spec local(handle()) -> {ok, {inet:ip_address(), 0..65535}} |
                         {error, non_neg_integer()}.
local({bound, _Family, _Type, {Addr, Port}}) -> {ok, {Addr, Port}};
local({pending, _Family, _Type}) -> {error, ?ENOTCONN};
local({_Tag, S}) -> address(inet:sockname(S)).

address({ok, {Addr, Port}}) -> {ok, {wasi_net:normalise(Addr), Port}};
address({error, Reason}) -> {error, errno(Reason)}.

-doc "Which address family this socket speaks.".
-spec family(handle()) -> inet | inet6.
family({pending, Family, _Type}) -> Family;
family({bound, Family, _Type, _Addr}) -> Family;
family({_Tag, S}) ->
    case inet:sockname(S) of
        {ok, {Addr, _}} when tuple_size(Addr) =:= 8 -> inet6;
        _ -> inet
    end.

-doc "Stream or datagram, whether or not anything is open yet.".
-spec type(handle()) -> stream | dgram.
type({pending, _Family, Type}) -> Type;
type({bound, _Family, Type, _Addr}) -> Type;
type({dgram, _S}) -> dgram;
type({_Tag, _S}) -> stream.

-doc "The WASI filetype a descriptor holding this socket reports.".
-spec filetype(handle()) -> non_neg_integer().
filetype(Handle) ->
    case type(Handle) of
        dgram -> ?FILETYPE_SOCKET_DGRAM;
        stream -> ?FILETYPE_SOCKET_STREAM
    end.

family_of(Addr) when tuple_size(Addr) =:= 4 -> inet;
family_of(Addr) when tuple_size(Addr) =:= 8 -> inet6.

matching_family(Family, Addr) -> family_of(Addr) =:= Family.

%%% ---------------------------------------------------------------- errnos ---

-doc """
Map a POSIX reason onto a WASI errno.

`timeout` becomes `EAGAIN` rather than `ETIMEDOUT`: a read that waited its
allowance and found nothing is the same event a non-blocking read reports, and
programs written against sockets already handle `EAGAIN` by retrying.
""".
-spec errno(atom()) -> non_neg_integer().
errno(timeout) -> ?EAGAIN;
errno(eagain) -> ?EAGAIN;
errno(closed) -> ?ENOTCONN;
errno(econnrefused) -> ?ECONNREFUSED;
errno(econnreset) -> ?ECONNRESET;
errno(econnaborted) -> ?ECONNABORTED;
errno(ehostunreach) -> ?EHOSTUNREACH;
errno(enetunreach) -> ?ENETUNREACH;
errno(enetdown) -> ?ENETDOWN;
errno(eaddrinuse) -> ?EADDRINUSE;
errno(eaddrnotavail) -> ?EADDRNOTAVAIL;
errno(eafnosupport) -> ?EAFNOSUPPORT;
errno(eisconn) -> ?EISCONN;
errno(enotconn) -> ?ENOTCONN;
errno(epipe) -> ?EPIPE;
errno(emsgsize) -> ?EMSGSIZE;
errno(enobufs) -> ?ENOBUFS;
errno(emfile) -> ?EMFILE;
errno(etimedout) -> ?ETIMEDOUT;
errno(eacces) -> ?EACCES;
errno(einval) -> ?EINVAL;
%% Anything unmapped is an I/O error rather than a guess. A wrong errno sends a
%% program down a recovery path meant for a different failure.
errno(_Reason) -> ?EIO.
