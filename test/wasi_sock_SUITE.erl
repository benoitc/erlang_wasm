%% @doc Sockets as WASI descriptors, over the four calls Preview 1 standardised.
%%
%% The module under test is written in the text format rather than compiled
%% from C, which is a payoff from the `.wat' work: a socket test can say exactly
%% which syscall it makes, with which arguments, and nothing else.
%%
%% The peer is a real `gen_tcp' socket on an ephemeral port. Connecting before
%% accepting is deliberate rather than incidental: `wasm:call/3' runs the module
%% in this process, so a module blocked in `sock_accept' would block the test
%% that is supposed to connect to it. TCP puts the connection in the backlog,
%% so it is there waiting when accept runs.
-module(wasi_sock_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("wasi.hrl").

all() ->
    [a_granted_listener_arrives_as_a_descriptor,
     accepts_reads_and_writes,
     fd_read_and_fd_write_reach_a_socket,
     a_short_buffer_keeps_the_rest,
     an_accepted_socket_cannot_itself_accept,
     peeking_is_refused_rather_than_faked,
     a_socket_preopen_does_not_end_the_preopen_scan,
     no_net_grant_means_no_descriptor,
     socket_calls_on_a_file_are_refused,
     the_socket_cap_is_enforced,
     shutdown_ends_the_stream,
     poll_reports_a_socket_with_data_waiting,
     poll_waits_and_the_clock_fires,
     poll_reports_a_hangup,
     poll_does_not_consume_what_it_found,
     poll_on_a_file_reports_ready,
     a_non_blocking_read_does_not_wait,
     destroying_an_instance_closes_what_the_guest_left_open].

%%% ------------------------------------------------------------- teardown ---

%% Dropping a handle is not closing a socket. `destroy/1' used to release the
%% pages and the state table and leave the guest's sockets open until the
%% owning process exited, so a worker resetting its instance per request leaked
%% a descriptor per request, and the `max_sockets' cap could not see it because
%% each fresh instance counted from zero.
destroying_an_instance_closes_what_the_guest_left_open(Config) ->
    {I, Port, Fd} = listening(Config),
    Peer = connect(Port),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"accept", [Fd])),
    {ok, [Accepted]} = wasm:call(I, ~"out_fd", []),
    ?assertMatch({ok, [?ESUCCESS]}, send(I, Accepted, ~"still here")),
    ?assertEqual({ok, ~"still here"}, gen_tcp:recv(Peer, 0, 1000)),
    %% No fd_close, no sock_shutdown: the guest simply stops.
    ok = wasm:destroy(I),
    %% The peer sees the connection close, which it cannot if the socket is
    %% merely unreachable.
    ?assertEqual({error, closed}, gen_tcp:recv(Peer, 0, 2000)),
    %% And the listener the host opened is gone too, so nothing is accepting
    %% on the granted port any more.
    ?assertEqual({error, econnrefused},
                 gen_tcp:connect({127, 0, 0, 1}, Port, [{active, false}], 1000)).

%%% ---------------------------------------------------------------- fixture ---

%% Layout in linear memory: 0 out-fd, 4 count, 8 iovec, 16 roflags, 32 fdstat,
%% 64 onward the data buffer.
source() -> ~"""
(module
  (import "wasi_snapshot_preview1" "sock_accept"
    (func $sock_accept (param i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "sock_recv"
    (func $sock_recv (param i32 i32 i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "sock_send"
    (func $sock_send (param i32 i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "sock_shutdown"
    (func $sock_shutdown (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_close"
    (func $fd_close (param i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_read"
    (func $fd_read (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_fdstat_get"
    (func $fd_fdstat_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_prestat_get"
    (func $fd_prestat_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_fdstat_set_flags"
    (func $fd_fdstat_set_flags (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "poll_oneoff"
    (func $poll_oneoff (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)

  (func $iov (param $len i32)
    (i32.store (i32.const 8) (i32.const 64))
    (i32.store (i32.const 12) (local.get $len)))

  (func (export "accept") (param $fd i32) (result i32)
    (call $sock_accept (local.get $fd) (i32.const 0) (i32.const 0)))
  (func (export "recv") (param $fd i32) (param $len i32) (param $flags i32)
        (result i32)
    (call $iov (local.get $len))
    (call $sock_recv (local.get $fd) (i32.const 8) (i32.const 1)
                     (local.get $flags) (i32.const 4) (i32.const 16)))
  (func (export "send") (param $fd i32) (param $len i32) (result i32)
    (call $iov (local.get $len))
    (call $sock_send (local.get $fd) (i32.const 8) (i32.const 1)
                     (i32.const 0) (i32.const 4)))
  (func (export "read") (param $fd i32) (param $len i32) (result i32)
    (call $iov (local.get $len))
    (call $fd_read (local.get $fd) (i32.const 8) (i32.const 1) (i32.const 4)))
  (func (export "write") (param $fd i32) (param $len i32) (result i32)
    (call $iov (local.get $len))
    (call $fd_write (local.get $fd) (i32.const 8) (i32.const 1) (i32.const 4)))
  (func (export "shutdown") (param $fd i32) (param $how i32) (result i32)
    (call $sock_shutdown (local.get $fd) (local.get $how)))
  (func (export "close") (param $fd i32) (result i32)
    (call $fd_close (local.get $fd)))
  (func (export "fdstat") (param $fd i32) (result i32)
    (call $fd_fdstat_get (local.get $fd) (i32.const 32)))
  (func (export "prestat") (param $fd i32) (result i32)
    (call $fd_prestat_get (local.get $fd) (i32.const 32)))

  (func (export "set_flags") (param $fd i32) (param $flags i32) (result i32)
    (call $fd_fdstat_set_flags (local.get $fd) (local.get $flags)))
  (func (export "poll") (param $n i32) (result i32)
    (call $poll_oneoff (i32.const 1024) (i32.const 2048) (local.get $n)
                       (i32.const 4)))

  (func (export "out_fd") (result i32) (i32.load (i32.const 0)))
  (func (export "count") (result i32) (i32.load (i32.const 4)))
  (func (export "roflags") (result i32) (i32.load (i32.const 16)))
  (func (export "filetype") (result i32) (i32.load8_u (i32.const 32)))
  (func (export "rights") (result i64) (i64.load (i32.const 40))))
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

%% A listening instance, its granted port, and the descriptor the listener
%% arrived on. The first call forces the descriptor table to be built, which is
%% what opens the socket, so the port is listening before anything connects.
listening(Config) -> listening(Config, #{}).

listening(Config, Extra) ->
    Port = free_port(),
    Net = maps:merge(#{listen => [{tcp, ~"127.0.0.1", Port}]}, Extra),
    I = instance(Config, Net),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"fdstat", [3])),
    {I, Port, 3}.

%% Picked by binding and releasing. A port that was free a moment ago is very
%% likely still free, and the alternative is a hardcoded port that fails on
%% whichever machine happens to be using it.
free_port() ->
    {ok, S} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(S),
    ok = gen_tcp:close(S),
    Port.

connect(Port) ->
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port,
                              [binary, {active, false}], 1000),
    S.

send(I, Fd, Data) ->
    ok = wasm:write_memory(I, 64, Data),
    wasm:call(I, ~"send", [Fd, byte_size(Data)]).

taken(I, N) ->
    {ok, Bin} = wasm:read_memory(I, 64, N),
    Bin.

%%% ----------------------------------------------------------------- basics ---

%% The host opens the socket the grant names and hands it in. The module learns
%% it has a stream socket, and never learns an address.
a_granted_listener_arrives_as_a_descriptor(Config) ->
    {I, _Port, Fd} = listening(Config),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"fdstat", [Fd])),
    ?assertEqual({ok, [?FILETYPE_SOCKET_STREAM]}, wasm:call(I, ~"filetype", [])),
    {ok, [Rights]} = wasm:call(I, ~"rights", []),
    ?assertNotEqual(0, Rights band ?RIGHT_SOCK_ACCEPT),
    ?assertNotEqual(0, Rights band ?RIGHT_FD_READ).

accepts_reads_and_writes(Config) ->
    {I, Port, Fd} = listening(Config),
    Peer = connect(Port),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"accept", [Fd])),
    {ok, [Conn]} = wasm:call(I, ~"out_fd", []),
    ?assertEqual(4, Conn),

    ok = gen_tcp:send(Peer, ~"ping"),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"recv", [Conn, 64, 0])),
    ?assertEqual({ok, [4]}, wasm:call(I, ~"count", [])),
    ?assertEqual({ok, [0]}, wasm:call(I, ~"roflags", [])),
    ?assertEqual(~"ping", taken(I, 4)),

    ?assertEqual({ok, [?ESUCCESS]}, send(I, Conn, ~"pong")),
    ?assertEqual({ok, [4]}, wasm:call(I, ~"count", [])),
    ?assertEqual({ok, ~"pong"}, gen_tcp:recv(Peer, 4, 1000)),
    ok = gen_tcp:close(Peer).

%% Rust's `TcpStream` implements `Read` and `Write`, so this is the path a real
%% program takes rather than `sock_recv' directly.
fd_read_and_fd_write_reach_a_socket(Config) ->
    {I, Port, Fd} = listening(Config),
    Peer = connect(Port),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"accept", [Fd])),
    {ok, [Conn]} = wasm:call(I, ~"out_fd", []),
    ok = gen_tcp:send(Peer, ~"abc"),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"read", [Conn, 64])),
    ?assertEqual({ok, [3]}, wasm:call(I, ~"count", [])),
    ?assertEqual(~"abc", taken(I, 3)),
    ok = wasm:write_memory(I, 64, ~"xyz"),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"write", [Conn, 3])),
    ?assertEqual({ok, ~"xyz"}, gen_tcp:recv(Peer, 3, 1000)),
    ok = gen_tcp:close(Peer).

%% A stream read returns whatever has arrived, which can be more than the
%% caller asked for. The excess has to survive to the next read: dropping it
%% loses bytes out of the middle of a stream, and only under load, which is the
%% worst way to find out.
a_short_buffer_keeps_the_rest(Config) ->
    {I, Port, Fd} = listening(Config),
    Peer = connect(Port),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"accept", [Fd])),
    {ok, [Conn]} = wasm:call(I, ~"out_fd", []),
    ok = gen_tcp:send(Peer, ~"abcdefgh"),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"recv", [Conn, 3, 0])),
    ?assertEqual({ok, [3]}, wasm:call(I, ~"count", [])),
    ?assertEqual(~"abc", taken(I, 3)),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"recv", [Conn, 3, 0])),
    ?assertEqual(~"def", taken(I, 3)),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"recv", [Conn, 8, 0])),
    ?assertEqual({ok, [2]}, wasm:call(I, ~"count", [])),
    ?assertEqual(~"gh", taken(I, 2)),
    ok = gen_tcp:close(Peer).

shutdown_ends_the_stream(Config) ->
    {I, Port, Fd} = listening(Config),
    Peer = connect(Port),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"accept", [Fd])),
    {ok, [Conn]} = wasm:call(I, ~"out_fd", []),
    ?assertEqual({ok, [?ESUCCESS]},
                 wasm:call(I, ~"shutdown", [Conn, ?SDFLAGS_WR])),
    ?assertEqual({error, closed}, gen_tcp:recv(Peer, 0, 1000)),
    ?assertEqual({ok, [?EINVAL]}, wasm:call(I, ~"shutdown", [Conn, 0])),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"close", [Conn])),
    ?assertEqual({ok, [?EBADF]}, wasm:call(I, ~"recv", [Conn, 8, 0])),
    ok = gen_tcp:close(Peer).

%%% ---------------------------------------------------------------- refusals ---

%% The accept right does not travel to what was accepted. A connected socket is
%% not a listener, and saying so with an errno beats finding out inside
%% `gen_tcp'.
an_accepted_socket_cannot_itself_accept(Config) ->
    {I, Port, Fd} = listening(Config),
    Peer = connect(Port),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"accept", [Fd])),
    {ok, [Conn]} = wasm:call(I, ~"out_fd", []),
    ?assertEqual({ok, [?ENOTCAPABLE]}, wasm:call(I, ~"accept", [Conn])),
    ok = gen_tcp:close(Peer).

%% Peeking needs a socket that can un-read. Consuming what the module asked to
%% leave would be silent data loss, so it is refused instead.
peeking_is_refused_rather_than_faked(Config) ->
    {I, Port, Fd} = listening(Config),
    Peer = connect(Port),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"accept", [Fd])),
    {ok, [Conn]} = wasm:call(I, ~"out_fd", []),
    ok = gen_tcp:send(Peer, ~"ping"),
    ?assertEqual({ok, [?ENOTSUP]},
                 wasm:call(I, ~"recv", [Conn, 4, ?RIFLAGS_RECV_PEEK])),
    %% And the data is still there afterwards, which is the point of refusing.
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"recv", [Conn, 4, 0])),
    ?assertEqual(~"ping", taken(I, 4)),
    ok = gen_tcp:close(Peer).

%% wasi-libc discovers preopens by walking descriptors upward until one answers
%% EBADF. A listener answering EBADF would end that walk and hide every
%% directory behind it, so it answers ENOTDIR and the walk continues.
a_socket_preopen_does_not_end_the_preopen_scan(Config) ->
    {I, _Port, Fd} = listening(Config),
    ?assertEqual({ok, [?ENOTDIR]}, wasm:call(I, ~"prestat", [Fd])),
    ?assertEqual({ok, [?EBADF]}, wasm:call(I, ~"prestat", [Fd + 1])).

no_net_grant_means_no_descriptor(Config) ->
    I = instance(Config, none),
    ?assertEqual({ok, [?EBADF]}, wasm:call(I, ~"accept", [3])),
    ?assertEqual({ok, [?EBADF]}, wasm:call(I, ~"recv", [3, 8, 0])),
    %% A grant that names nothing opens nothing, which is the same thing.
    Empty = instance(Config, #{}),
    ?assertEqual({ok, [?EBADF]}, wasm:call(Empty, ~"accept", [3])).

%% A descriptor that is not a socket says so, rather than reporting a right it
%% does not have. The distinction matters to a program deciding what to retry.
socket_calls_on_a_file_are_refused(Config) ->
    {I, _Port, _Fd} = listening(Config),
    ?assertEqual({ok, [?ENOTSOCK]}, wasm:call(I, ~"accept", [1])),
    ?assertEqual({ok, [?ENOTSOCK]}, wasm:call(I, ~"shutdown", [1, ?SDFLAGS_WR])).

%% Without a cap a module opens sockets until the node runs out of them, which
%% is the argument the node page budget already makes. The listener the host
%% opened counts: it is a socket this instance is holding.
the_socket_cap_is_enforced(Config) ->
    {I, Port, Fd} = listening(Config, #{max_sockets => 1}),
    Peer = connect(Port),
    ?assertEqual({ok, [?EMFILE]}, wasm:call(I, ~"accept", [Fd])),
    ok = gen_tcp:close(Peer).

%%% -------------------------------------------------------------- readiness ---

%% A subscription is 48 bytes: userdata, a tag, and a union holding either a
%% descriptor or a clock. Built here rather than in the module, so the offsets
%% are stated once and visibly.
fd_sub(UserData, Tag, Fd) ->
    <<UserData:64/little, Tag:8, 0:56, Fd:32/little, 0:224>>.

clock_sub(UserData, Nanos) ->
    <<UserData:64/little, ?EVENTTYPE_CLOCK:8, 0:56, ?CLOCK_MONOTONIC:32/little,
      0:32, Nanos:64/little, 0:64, 0:16, 0:48>>.

put_subs(I, Subs) ->
    ok = wasm:write_memory(I, 1024, iolist_to_binary(Subs)),
    length(Subs).

events(I, N) ->
    {ok, Bin} = wasm:read_memory(I, 2048, N * 32),
    [{UserData, Errno, Type, NBytes, Flags}
     || <<UserData:64/little, Errno:16/little, Type:8, _:40, NBytes:64/little,
          Flags:16/little, _:48>> <= Bin].

accepted(Config) ->
    {I, Port, Fd} = listening(Config),
    Peer = connect(Port),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"accept", [Fd])),
    {ok, [Conn]} = wasm:call(I, ~"out_fd", []),
    {I, Peer, Conn}.

poll_reports_a_socket_with_data_waiting(Config) ->
    {I, Peer, Conn} = accepted(Config),
    ok = gen_tcp:send(Peer, ~"four"),
    N = put_subs(I, [fd_sub(11, ?EVENTTYPE_FD_READ, Conn),
                     clock_sub(22, 2000000000)]),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"poll", [N])),
    ?assertEqual({ok, [1]}, wasm:call(I, ~"count", [])),
    ?assertEqual([{11, ?ESUCCESS, ?EVENTTYPE_FD_READ, 4, 0}], events(I, 1)),
    ok = gen_tcp:close(Peer).

%% Nothing arrives, so the wait ends where the clock said it would, and the
%% clock is what fired.
poll_waits_and_the_clock_fires(Config) ->
    {I, Peer, Conn} = accepted(Config),
    N = put_subs(I, [fd_sub(11, ?EVENTTYPE_FD_READ, Conn),
                     clock_sub(22, 50000000)]),
    Before = erlang:monotonic_time(millisecond),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"poll", [N])),
    Waited = erlang:monotonic_time(millisecond) - Before,
    ?assertEqual([{22, ?ESUCCESS, ?EVENTTYPE_CLOCK, 0, 0}], events(I, 1)),
    ?assert(Waited >= 45),
    ok = gen_tcp:close(Peer).

%% A closed peer is ready, not quiet. Without the hangup flag a module cannot
%% tell "nothing yet" from "nothing ever again", and spins on the difference.
poll_reports_a_hangup(Config) ->
    {I, Peer, Conn} = accepted(Config),
    ok = gen_tcp:close(Peer),
    N = put_subs(I, [fd_sub(11, ?EVENTTYPE_FD_READ, Conn),
                     clock_sub(22, 2000000000)]),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"poll", [N])),
    ?assertEqual([{11, ?ESUCCESS, ?EVENTTYPE_FD_READ, 0,
                   ?EVENTRWFLAGS_FD_READWRITE_HANGUP}], events(I, 1)).

%% Finding out that bytes are there means taking them off the socket, so they
%% are kept against the next read. A poll that consumed what it reported would
%% be the worst possible bug here: it would work in every test that only polls.
poll_does_not_consume_what_it_found(Config) ->
    {I, Peer, Conn} = accepted(Config),
    ok = gen_tcp:send(Peer, ~"kept"),
    N = put_subs(I, [fd_sub(11, ?EVENTTYPE_FD_READ, Conn)]),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"poll", [N])),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"recv", [Conn, 16, 0])),
    ?assertEqual({ok, [4]}, wasm:call(I, ~"count", [])),
    ?assertEqual(~"kept", taken(I, 4)),
    %% And polling twice does not report it twice over.
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"poll", [N])),
    ?assertEqual({ok, [0]}, wasm:call(I, ~"count", [])),
    ok = gen_tcp:close(Peer).

%% File readiness stays refused. Claiming a file is ready when that cannot be
%% known produces misbehaviour a long way from here, and sockets do not change
%% that argument.
%% Renamed from `poll_on_a_file_is_still_refused'.
%%
%% It was refused, on the grounds that claiming a file is ready when that cannot
%% be known misbehaves far from here. For a regular file or a stdio stream it
%% can be known: POSIX says both are always ready, and a guest that polls stdin
%% before reading it -- which Rust's standard library does -- got `ENOSYS' and
%% gave up. Upstream's `poll_oneoff_stdio' is the case.
poll_on_a_file_reports_ready(Config) ->
    {I, _Port, _Fd} = listening(Config),
    N = put_subs(I, [fd_sub(11, ?EVENTTYPE_FD_READ, 1)]),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"poll", [N])),
    ?assertEqual([{11, ?ESUCCESS, ?EVENTTYPE_FD_READ, 0, 0}], events(I, 1)),
    %% A descriptor that does not exist is one subscription being wrong rather
    %% than the call being wrong, so it comes back as an event.
    M = put_subs(I, [fd_sub(11, ?EVENTTYPE_FD_READ, 99)]),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"poll", [M])),
    ?assertEqual([{11, ?EBADF, ?EVENTTYPE_FD_READ, 0, 0}], events(I, 1)).

a_non_blocking_read_does_not_wait(Config) ->
    {I, Peer, Conn} = accepted(Config),
    ?assertEqual({ok, [?ESUCCESS]},
                 wasm:call(I, ~"set_flags", [Conn, ?FDFLAGS_NONBLOCK])),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"fdstat", [Conn])),
    Before = erlang:monotonic_time(millisecond),
    ?assertEqual({ok, [?EAGAIN]}, wasm:call(I, ~"recv", [Conn, 16, 0])),
    ?assert(erlang:monotonic_time(millisecond) - Before < 500),
    ok = gen_tcp:send(Peer, ~"now"),
    %% Once something is there, a non-blocking read gets it.
    ok = wait_until(fun() ->
                        wasm:call(I, ~"recv", [Conn, 16, 0]) =:= {ok, [?ESUCCESS]}
                    end),
    ?assertEqual(~"now", taken(I, 3)),
    ok = gen_tcp:close(Peer).

wait_until(F) -> wait_until(F, 100).

wait_until(_F, 0) -> {error, timeout};
wait_until(F, N) ->
    case F() of
        true -> ok;
        false -> timer:sleep(10), wait_until(F, N - 1)
    end.
