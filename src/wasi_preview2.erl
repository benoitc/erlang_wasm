-module(wasi_preview2).
-moduledoc """
The WASI Preview 2 host: the `wasi:*` interfaces a component imports, each
supplied as a host function keyed by `{Interface, Field}` for
`wasm_component:instantiate/2`.

Preview 2 is the component-model side of WASI. A guest imports a world such as
`wasi:random/random` and the host provides every function in it. This module
holds those functions; `imports/0` is the merged map to hand a component. The
functions map onto the same hardened internals as Preview 1 (here
`crypto:strong_rand_bytes/1`).

Worlds land one at a time: `wasi:random`, `wasi:clocks`, `wasi:cli/environment`,
`wasi:io`, and a read-only `wasi:filesystem`. Keys are the bare, unversioned
interface ids (`wasi:random/random`); matching a versioned `@0.2.x` import is a
later step.
""".

-include("wasi.hrl").

-export([imports/0, random/0, clocks/0, environment/0, io/0, io/1,
         filesystem/1, sockets/1]).

%% result<_, stream-error>, the result every output-stream method returns. The
%% error arm names an `error` resource (a handle); we only ever return ok, so no
%% error handle is minted, but the layout must be expressible so the ok result
%% pads its payload area.
-define(STREAM_ERROR,
        {variant, [{<<"last-operation-failed">>, handle}, {<<"closed">>, none}]}).
-define(WRITE_RESULT, {result, none, ?STREAM_ERROR}).
-define(READ_RESULT, {result, {list, u8}, ?STREAM_ERROR}).
-define(COUNT_RESULT, {result, u64, ?STREAM_ERROR}).
%% The write budget check-write reports for the discarding/buffer sinks: always
%% ready for a chunk this size.
-define(WRITE_BUDGET, 65536).

%% wasi:filesystem enums, in WIT order (the enum discriminant is the index).
-define(ERROR_CODE,
        {enum, [<<"access">>, <<"would-block">>, <<"already">>,
                <<"bad-descriptor">>, <<"busy">>, <<"deadlock">>, <<"quota">>,
                <<"exist">>, <<"file-too-large">>, <<"illegal-byte-sequence">>,
                <<"in-progress">>, <<"interrupted">>, <<"invalid">>, <<"io">>,
                <<"is-directory">>, <<"loop">>, <<"too-many-links">>,
                <<"message-size">>, <<"name-too-long">>, <<"no-device">>,
                <<"no-entry">>, <<"no-lock">>, <<"insufficient-memory">>,
                <<"insufficient-space">>, <<"not-directory">>, <<"not-empty">>,
                <<"not-recoverable">>, <<"unsupported">>, <<"no-tty">>,
                <<"no-such-device">>, <<"overflow">>, <<"not-permitted">>,
                <<"pipe">>, <<"read-only">>, <<"invalid-seek">>,
                <<"text-file-busy">>, <<"cross-device">>]}).
-define(DESC_TYPE,
        {enum, [<<"unknown">>, <<"block-device">>, <<"character-device">>,
                <<"directory">>, <<"fifo">>, <<"symbolic-link">>,
                <<"regular-file">>, <<"socket">>]}).
-define(PATH_FLAGS, {flags, [<<"symlink-follow">>]}).
-define(OPEN_FLAGS,
        {flags, [<<"create">>, <<"directory">>, <<"exclusive">>,
                 <<"truncate">>]}).
-define(DESC_FLAGS,
        {flags, [<<"read">>, <<"write">>, <<"file-integrity-sync">>,
                 <<"data-integrity-sync">>, <<"requested-write-sync">>,
                 <<"mutate-directory">>]}).
-define(OPEN_RESULT, {result, handle, ?ERROR_CODE}).
-define(READ_AT_RESULT, {result, {tuple, [{list, u8}, bool]}, ?ERROR_CODE}).
-define(TYPE_RESULT, {result, ?DESC_TYPE, ?ERROR_CODE}).
-define(DATETIME2, {record, [{<<"seconds">>, u64}, {<<"nanoseconds">>, u32}]}).
-define(DESCRIPTOR_STAT,
        {record, [{<<"type">>, ?DESC_TYPE},
                  {<<"link-count">>, u64},
                  {<<"size">>, u64},
                  {<<"data-access-timestamp">>, {option, ?DATETIME2}},
                  {<<"data-modification-timestamp">>, {option, ?DATETIME2}},
                  {<<"status-change-timestamp">>, {option, ?DATETIME2}}]}).
-define(STAT_RESULT, {result, ?DESCRIPTOR_STAT, ?ERROR_CODE}).
-define(DIR_ENTRY, {record, [{<<"type">>, ?DESC_TYPE}, {<<"name">>, string}]}).
-define(DIR_ENTRY_RESULT, {result, {option, ?DIR_ENTRY}, ?ERROR_CODE}).

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
-define(SOCK_TIMEOUT, 5000).
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
-define(INCOMING_DATAGRAM,
        {record, [{<<"data">>, {list, u8}}, {<<"remote-address">>, ?IP_SOCKADDR}]}).
-define(OUTGOING_DATAGRAM,
        {record, [{<<"data">>, {list, u8}},
                  {<<"remote-address">>, {option, ?IP_SOCKADDR}}]}).
-define(UDP_STREAM_RESULT, {result, {tuple, [handle, handle]}, ?SOCK_ERROR}).
-define(RECEIVE_RESULT, {result, {list, ?INCOMING_DATAGRAM}, ?SOCK_ERROR}).
-define(SEND_RESULT, {result, u64, ?SOCK_ERROR}).

-doc "Every implemented `wasi:*` interface, merged into one imports map.".
-spec imports() -> #{{binary(), binary()} => fun()}.
imports() ->
    lists:foldl(fun maps:merge/2, #{},
                [random(), clocks(), environment(), io()]).

-doc """
`wasi:random/random`: `get-random-u64` and `get-random-bytes`, backed by the
system CSPRNG. The returned byte length is the guest's request, bounded by the
guest's own linear-memory limit when the result is lowered.
""".
-spec random() -> #{{binary(), binary()} => fun()}.
random() ->
    I = <<"wasi:random/random">>,
    #{{I, <<"get-random-u64">>} =>
          wasm_component:import_fun({[], u64}, fun([]) -> random_u64() end),
      {I, <<"get-random-bytes">>} =>
          wasm_component:import_fun({[u64], {list, u8}},
                                    fun([Len]) -> random_bytes(Len) end)}.

random_u64() ->
    <<X:64/unsigned>> = crypto:strong_rand_bytes(8),
    X.

random_bytes(0) -> <<>>;
random_bytes(Len) when is_integer(Len), Len > 0 ->
    crypto:strong_rand_bytes(Len).

-doc """
`wasi:clocks`: `monotonic-clock` (`now`, `resolution` in nanoseconds) and
`wall-clock` (`now`, `resolution` as a `datetime` record of seconds and
nanoseconds). The `subscribe-*` functions return a pollable and wait for
`wasi:io`. Monotonic `now` counts from the node's first reading, so it is
non-negative and non-decreasing; wall `now` is the system clock.
""".
-spec clocks() -> #{{binary(), binary()} => fun()}.
clocks() ->
    M = <<"wasi:clocks/monotonic-clock">>,
    W = <<"wasi:clocks/wall-clock">>,
    Datetime = {record, [{<<"seconds">>, u64}, {<<"nanoseconds">>, u32}]},
    #{{M, <<"now">>} =>
          wasm_component:import_fun({[], u64}, fun([]) -> monotonic_now() end),
      {M, <<"resolution">>} =>
          wasm_component:import_fun({[], u64}, fun([]) -> 1 end),
      {W, <<"now">>} =>
          wasm_component:import_fun({[], Datetime}, fun([]) -> wall_now() end),
      {W, <<"resolution">>} =>
          wasm_component:import_fun({[], Datetime},
                                    fun([]) -> datetime(0, 1000) end)}.

monotonic_now() ->
    %% Read the base first: it is then the earliest reading, so now/0 is never
    %% negative and never decreases.
    Base = monotonic_base(),
    erlang:monotonic_time(nanosecond) - Base.

%% The node's first monotonic reading, so now/0 starts near zero. A race between
%% two first readers just picks one; both are valid origins.
monotonic_base() ->
    Key = {?MODULE, monotonic_base},
    case persistent_term:get(Key, undefined) of
        undefined ->
            Base = erlang:monotonic_time(nanosecond),
            persistent_term:put(Key, Base),
            Base;
        Base ->
            Base
    end.

wall_now() ->
    Ns = erlang:system_time(nanosecond),
    datetime(Ns div 1000000000, Ns rem 1000000000).

datetime(Seconds, Nanoseconds) ->
    #{<<"seconds">> => Seconds, <<"nanoseconds">> => Nanoseconds}.

-doc """
`wasi:cli/environment`: `get-environment`, `get-arguments`, `initial-cwd`. The
default exposes nothing, the sandboxed posture: an empty environment, no
arguments, no working directory. It never reads the node's real environment.
""".
-spec environment() -> #{{binary(), binary()} => fun()}.
environment() ->
    E = <<"wasi:cli/environment">>,
    #{{E, <<"get-environment">>} =>
          wasm_component:import_fun(
            {[], {list, {tuple, [string, string]}}}, fun([]) -> [] end),
      {E, <<"get-arguments">>} =>
          wasm_component:import_fun({[], {list, string}}, fun([]) -> [] end),
      {E, <<"initial-cwd">>} =>
          wasm_component:import_fun({[], {option, string}}, fun([]) -> none end)}.

-doc """
The stream side of `wasi:io` with default endpoints: `get-stdout` over a sink
that discards, `get-stdin` over an empty source.
""".
-spec io() -> #{{binary(), binary()} => fun()}.
io() ->
    io(#{}).

-doc """
The stream side of `wasi:io`. `wasi:cli/stdout.get-stdout` mints a host-owned
`output-stream` whose `blocking-write-and-flush` writes to `sink`, and
`wasi:cli/stdin.get-stdin` mints an `input-stream` that hands out `source`
through `read`/`blocking-read` until it is drained, then `closed`. The
`[resource-drop]` intrinsics free the host handle.

`sink` defaults to discarding (so a guest never writes to the node's own
stdout); `source` defaults to empty.
""".
-spec io(#{sink => fun((binary()) -> ok), source => binary()}) ->
          #{{binary(), binary()} => fun()}.
io(Opts) ->
    Sink = maps:get(sink, Opts, fun(_Bytes) -> ok end),
    Source = maps:get(source, Opts, <<>>),
    Streams = <<"wasi:io/streams">>,
    Error = <<"wasi:io/error">>,
    Stdout = <<"wasi:cli/stdout">>,
    Stdin = <<"wasi:cli/stdin">>,
    Poll = <<"wasi:io/poll">>,
    Write = fun([Handle, Bytes]) -> write_stream(Handle, Bytes), {ok, undefined} end,
    Read = fun([H, Len]) -> read_stream(H, Len) end,
    Subscribe = fun([_Stream]) -> wasm_component:host_new(pollable, ready) end,
    #{{Stdout, <<"get-stdout">>} =>
          wasm_component:import_fun(
            {[], handle}, fun([]) -> wasm_component:host_new(output_stream, Sink) end),
      {Streams, <<"[method]output-stream.check-write">>} =>
          wasm_component:import_fun(
            {[handle], ?COUNT_RESULT}, fun([_H]) -> {ok, ?WRITE_BUDGET} end),
      {Streams, <<"[method]output-stream.write">>} =>
          wasm_component:import_fun({[handle, {list, u8}], ?WRITE_RESULT}, Write),
      {Streams, <<"[method]output-stream.blocking-write-and-flush">>} =>
          wasm_component:import_fun({[handle, {list, u8}], ?WRITE_RESULT}, Write),
      {Streams, <<"[method]output-stream.flush">>} =>
          wasm_component:import_fun(
            {[handle], ?WRITE_RESULT}, fun([_H]) -> {ok, undefined} end),
      {Streams, <<"[method]output-stream.blocking-flush">>} =>
          wasm_component:import_fun(
            {[handle], ?WRITE_RESULT}, fun([_H]) -> {ok, undefined} end),
      {Streams, <<"[method]output-stream.write-zeroes">>} =>
          wasm_component:import_fun(
            {[handle, u64], ?WRITE_RESULT},
            fun([H, Len]) -> write_stream(H, binary:copy(<<0>>, Len)), {ok, undefined} end),
      {Streams, <<"[method]output-stream.subscribe">>} =>
          wasm_component:import_fun({[handle], handle}, Subscribe),
      {Streams, <<"[resource-drop]output-stream">>} => drop_fun(),
      {Stdin, <<"get-stdin">>} =>
          wasm_component:import_fun(
            {[], handle}, fun([]) -> wasm_component:host_new(input_stream, Source) end),
      {Streams, <<"[method]input-stream.read">>} =>
          wasm_component:import_fun({[handle, u64], ?READ_RESULT}, Read),
      {Streams, <<"[method]input-stream.blocking-read">>} =>
          wasm_component:import_fun({[handle, u64], ?READ_RESULT}, Read),
      {Streams, <<"[method]input-stream.skip">>} =>
          wasm_component:import_fun(
            {[handle, u64], ?COUNT_RESULT}, fun([H, Len]) -> skip_stream(H, Len) end),
      {Streams, <<"[method]input-stream.subscribe">>} =>
          wasm_component:import_fun({[handle], handle}, Subscribe),
      {Streams, <<"[resource-drop]input-stream">>} => drop_fun(),
      %% A pollable over a synchronous stream is always ready; block returns at
      %% once and poll reports every input index ready.
      {Poll, <<"[method]pollable.ready">>} =>
          wasm_component:import_fun({[handle], bool}, fun([_P]) -> true end),
      {Poll, <<"[method]pollable.block">>} =>
          wasm_component:import_fun({[handle], none}, fun([_P]) -> undefined end),
      {Poll, <<"poll">>} =>
          wasm_component:import_fun(
            {[{list, handle}], {list, u32}},
            fun([Handles]) -> lists:seq(0, length(Handles) - 1) end),
      {Poll, <<"[resource-drop]pollable">>} => drop_fun(),
      {Error, <<"[method]error.to-debug-string">>} =>
          wasm_component:import_fun({[handle], string}, fun([_E]) -> <<"stream error">> end),
      {Error, <<"[resource-drop]error">>} => drop_fun()}.

drop_fun() ->
    fun(_Ctx, [Handle]) -> _ = wasm_component:host_drop(Handle), {ok, []} end.

%% Write to the stream's sink. A write to a handle that is gone is dropped; a
%% real closed-stream error waits for the error resource.
write_stream(Handle, Bytes) ->
    case wasm_component:host_get(Handle) of
        {ok, {output_stream, Sink}} -> _ = Sink(Bytes), ok;
        error -> ok
    end.

%% Read up to Len bytes from the source, advancing it. An empty source (drained
%% or unknown handle) reads `closed`, the end-of-stream signal blocking-read
%% waits for. `closed` carries no payload, so no error resource is minted.
read_stream(Handle, Len) ->
    case wasm_component:host_get(Handle) of
        {ok, {input_stream, {socket, Sock, Buf}}} ->
            %% A socket-backed stream (from tcp finish-connect/accept). Return up
            %% to Len bytes, blocking for at least one; buffer any it read past
            %% Len so the next read hands them over.
            socket_read(Handle, Sock, Buf, Len);
        {ok, {input_stream, <<>>}} ->
            {error, {<<"closed">>, undefined}};
        {ok, {input_stream, Remaining}} when is_binary(Remaining) ->
            N = min(Len, byte_size(Remaining)),
            <<Chunk:N/binary, Rest/binary>> = Remaining,
            _ = wasm_component:host_update(Handle, Rest),
            {ok, Chunk};
        error ->
            {error, {<<"closed">>, undefined}}
    end.

socket_read(Handle, Sock, <<>>, Len) ->
    case wasi_sock:recv(Sock, 0, ?SOCK_TIMEOUT) of
        {ok, Data}  -> socket_deliver(Handle, Sock, Data, Len);
        eof         -> {error, {<<"closed">>, undefined}};
        {error, _}  -> {error, {<<"closed">>, undefined}}
    end;
socket_read(Handle, Sock, Buf, Len) ->
    socket_deliver(Handle, Sock, Buf, Len).

socket_deliver(Handle, Sock, Data, Len) ->
    N = min(Len, byte_size(Data)),
    <<Chunk:N/binary, Rest/binary>> = Data,
    _ = wasm_component:host_update(Handle, {socket, Sock, Rest}),
    {ok, Chunk}.

%% Advance the source by up to Len bytes without returning them, reporting how
%% many were skipped; a drained or unknown stream is `closed`.
skip_stream(Handle, Len) ->
    case wasm_component:host_get(Handle) of
        {ok, {input_stream, <<>>}} ->
            {error, {<<"closed">>, undefined}};
        {ok, {input_stream, Remaining}} ->
            N = min(Len, byte_size(Remaining)),
            <<_Skipped:N/binary, Rest/binary>> = Remaining,
            _ = wasm_component:host_update(Handle, Rest),
            {ok, N};
        error ->
            {error, {<<"closed">>, undefined}}
    end.

-doc """
A read-only `wasi:filesystem` over one preopened directory. `get-directories`
hands the guest a descriptor for `preopen` (named `name`, default `/`);
`open-at` resolves a path under it and opens it read-only; `read` is a pread and
`get-type` says file or directory. Path resolution and the sandbox are not
reimplemented here: `open-at` passes the guest path straight to `wasi_fs:open/3`,
the same call Preview 1 makes, so the same escapes are refused. Write intent is
refused with `read-only`.
""".
-spec filesystem(#{preopen := file:filename_all(), name => binary()}) ->
          #{{binary(), binary()} => fun()}.
filesystem(Opts) ->
    HostDir = maps:get(preopen, Opts),
    Name = maps:get(name, Opts, <<"/">>),
    Types = <<"wasi:filesystem/types">>,
    Preopens = <<"wasi:filesystem/preopens">>,
    #{{Preopens, <<"get-directories">>} =>
          wasm_component:import_fun(
            {[], {list, {tuple, [handle, string]}}},
            fun([]) -> get_directories(HostDir, Name) end),
      {Types, <<"[method]descriptor.open-at">>} =>
          wasm_component:import_fun(
            {[handle, ?PATH_FLAGS, string, ?OPEN_FLAGS, ?DESC_FLAGS], ?OPEN_RESULT},
            fun([Dir, _PF, Path, OpenFlags, DescFlags]) ->
                open_at(Dir, Path, OpenFlags, DescFlags)
            end),
      {Types, <<"[method]descriptor.read">>} =>
          wasm_component:import_fun(
            {[handle, u64, u64], ?READ_AT_RESULT},
            fun([File, Len, Off]) -> read_at(File, Len, Off) end),
      {Types, <<"[method]descriptor.get-type">>} =>
          wasm_component:import_fun(
            {[handle], ?TYPE_RESULT}, fun([H]) -> type_of(H) end),
      {Types, <<"[method]descriptor.stat">>} =>
          wasm_component:import_fun(
            {[handle], ?STAT_RESULT}, fun([H]) -> stat(H) end),
      {Types, <<"[method]descriptor.stat-at">>} =>
          wasm_component:import_fun(
            {[handle, ?PATH_FLAGS, string], ?STAT_RESULT},
            fun([Dir, PathFlags, Path]) -> stat_at(Dir, PathFlags, Path) end),
      {Types, <<"[method]descriptor.read-via-stream">>} =>
          wasm_component:import_fun(
            {[handle, u64], ?OPEN_RESULT},
            fun([File, Off]) -> read_via_stream(File, Off) end),
      {Types, <<"[method]descriptor.read-directory">>} =>
          wasm_component:import_fun(
            {[handle], ?OPEN_RESULT}, fun([Dir]) -> read_directory(Dir) end),
      {Types, <<"[method]directory-entry-stream.read-directory-entry">>} =>
          wasm_component:import_fun(
            {[handle], ?DIR_ENTRY_RESULT},
            fun([Stream]) -> read_directory_entry(Stream) end),
      {Types, <<"[resource-drop]directory-entry-stream">>} =>
          fun(_Ctx, [H]) -> _ = wasm_component:host_drop(H), {ok, []} end,
      {Types, <<"[resource-drop]descriptor">>} =>
          fun(_Ctx, [H]) -> _ = fs_drop(H), {ok, []} end}.

get_directories(HostDir, Name) ->
    case wasi_fs:preopen(HostDir) of
        {ok, Root} -> [{wasm_component:host_new(fs_dir, Root), Name}];
        {error, _} -> []
    end.

%% Open a path under a directory descriptor, read-only. Write intent is refused
%% rather than downgraded. The path is not resolved here: wasi_fs:open/3 applies
%% the same sandbox Preview 1 does.
open_at(Dir, Path, OpenFlags, DescFlags) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, Root}} ->
            case write_intent(OpenFlags, DescFlags) of
                true ->
                    {error, <<"read-only">>};
                false ->
                    case wasi_fs:open(Root, Path, [read]) of
                        {ok, Handle} -> {ok, wasm_component:host_new(fs_file, Handle)};
                        {error, Errno} -> {error, errno_name(Errno)}
                    end
            end;
        _ ->
            {error, <<"bad-descriptor">>}
    end.

write_intent(OpenFlags, DescFlags) ->
    Wants = fun(Name, Set) -> lists:member(Name, Set) end,
    Wants(<<"create">>, OpenFlags) orelse Wants(<<"truncate">>, OpenFlags)
        orelse Wants(<<"exclusive">>, OpenFlags)
        orelse Wants(<<"write">>, DescFlags)
        orelse Wants(<<"mutate-directory">>, DescFlags).

read_at(File, Len, Off) ->
    case wasm_component:host_get(File) of
        {ok, {fs_file, Handle}} ->
            case wasi_fs:pread(Handle, Off, Len) of
                {ok, Bin} -> {ok, {Bin, at_eof(Handle, Off, byte_size(Bin), Len)}};
                eof -> {ok, {<<>>, true}};
                {error, Errno} -> {error, errno_name(Errno)}
            end;
        _ ->
            {error, <<"bad-descriptor">>}
    end.

at_eof(Handle, Off, Got, Len) ->
    case wasi_fs:size(Handle) of
        {ok, Size} -> (Off + Got) >= Size;
        {error, _} -> Got < Len
    end.

type_of(H) ->
    case wasm_component:host_get(H) of
        {ok, {fs_dir, _Root}} ->
            {ok, <<"directory">>};
        {ok, {fs_file, Handle}} ->
            case wasi_fs:stat_fd(Handle) of
                {ok, #{type := Type}} -> {ok, fs_type_name(Type)};
                {error, Errno} -> {error, errno_name(Errno)}
            end;
        error ->
            {error, <<"bad-descriptor">>}
    end.

fs_type_name(directory) -> <<"directory">>;
fs_type_name(regular)   -> <<"regular-file">>;
fs_type_name(symlink)   -> <<"symbolic-link">>;
fs_type_name(_Other)    -> <<"unknown">>.

stat(H) ->
    case wasm_component:host_get(H) of
        {ok, {fs_file, Handle}} -> from_stat(wasi_fs:stat_fd(Handle));
        {ok, {fs_dir, Root}}    -> from_stat(wasi_fs:stat(Root, <<".">>));
        error                   -> {error, <<"bad-descriptor">>}
    end.

stat_at(Dir, PathFlags, Path) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, Root}} ->
            Follow = case lists:member(<<"symlink-follow">>, PathFlags) of
                         true -> follow;
                         false -> nofollow
                     end,
            from_stat(wasi_fs:stat(Root, Path, Follow));
        _ ->
            {error, <<"bad-descriptor">>}
    end.

from_stat({ok, Map}) -> {ok, stat_record(Map)};
from_stat({error, Errno}) -> {error, errno_name(Errno)}.

stat_record(#{size := Size, type := Type} = M) ->
    #{<<"type">> => fs_type_name(Type),
      <<"link-count">> => maps:get(nlink, M, 1),
      <<"size">> => Size,
      <<"data-access-timestamp">> => opt_datetime(maps:get(atim, M, undefined)),
      <<"data-modification-timestamp">> => opt_datetime(maps:get(mtim, M, undefined)),
      <<"status-change-timestamp">> => opt_datetime(maps:get(ctim, M, undefined))}.

opt_datetime(Nsec) when is_integer(Nsec) ->
    {some, #{<<"seconds">> => Nsec div 1000000000,
             <<"nanoseconds">> => Nsec rem 1000000000}};
opt_datetime(_) ->
    none.

%% read-via-stream snapshots the file from the offset into an input-stream (the
%% wasi:io kind), so a caller must also supply io/1 to read it. pread does the
%% reading, so the sandbox is unchanged.
read_via_stream(File, Off) ->
    case wasm_component:host_get(File) of
        {ok, {fs_file, Handle}} ->
            case read_all(Handle, Off, <<>>) of
                {ok, Bytes}     -> {ok, wasm_component:host_new(input_stream, Bytes)};
                {error, Errno}  -> {error, errno_name(Errno)}
            end;
        _ ->
            {error, <<"bad-descriptor">>}
    end.

read_all(Handle, Off, Acc) ->
    case wasi_fs:pread(Handle, Off, 65536) of
        {ok, <<>>}     -> {ok, Acc};
        {ok, Bin}      -> read_all(Handle, Off + byte_size(Bin), <<Acc/binary, Bin/binary>>);
        eof            -> {ok, Acc};
        {error, Errno} -> {error, Errno}
    end.

read_directory(Dir) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, Root}} ->
            case wasi_fs:list(Root) of
                {ok, Names} ->
                    Entries = [dir_entry(Root, N) || N <- Names],
                    {ok, wasm_component:host_new(dir_entries, Entries)};
                {error, Errno} ->
                    {error, errno_name(Errno)}
            end;
        _ ->
            {error, <<"bad-descriptor">>}
    end.

dir_entry(Root, Name) ->
    Type = case wasi_fs:stat(Root, Name, nofollow) of
               {ok, #{type := T}} -> fs_type_name(T);
               _ -> <<"unknown">>
           end,
    #{<<"type">> => Type, <<"name">> => Name}.

read_directory_entry(Stream) ->
    case wasm_component:host_get(Stream) of
        {ok, {dir_entries, []}} ->
            {ok, none};
        {ok, {dir_entries, [Entry | Rest]}} ->
            _ = wasm_component:host_update(Stream, Rest),
            {ok, {some, Entry}};
        _ ->
            {error, <<"bad-descriptor">>}
    end.

-doc """
A slice of `wasi:sockets`: the network foundation and `ip-name-lookup`.
`instance-network` mints a network resource carrying the grant; `resolve-addresses`
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
      {Lookup, <<"[resource-drop]resolve-address-stream">>} => drop_fun(),
      {Network, <<"[resource-drop]network">>} => drop_fun(),
      {<<"wasi:sockets/tcp-create-socket">>, <<"create-tcp-socket">>} =>
          wasm_component:import_fun(
            {[?ADDR_FAMILY], {result, handle, ?SOCK_ERROR}},
            fun([Family]) -> create_tcp_socket(Family) end),
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
            {[handle], {result, none, ?SOCK_ERROR}}, fun([_Self]) -> {ok, undefined} end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.start-listen">>} =>
          wasm_component:import_fun(
            {[handle], {result, none, ?SOCK_ERROR}}, fun([Self]) -> tcp_start_listen(Self) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.finish-listen">>} =>
          wasm_component:import_fun(
            {[handle], {result, none, ?SOCK_ERROR}}, fun([_Self]) -> {ok, undefined} end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.accept">>} =>
          wasm_component:import_fun(
            {[handle], ?ACCEPT_RESULT}, fun([Self]) -> tcp_accept(Self) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.local-address">>} =>
          wasm_component:import_fun(
            {[handle], ?LOCAL_RESULT}, fun([Self]) -> tcp_local(Self) end),
      {<<"wasi:sockets/tcp">>, <<"[method]tcp-socket.subscribe">>} =>
          wasm_component:import_fun(
            {[handle], handle}, fun([_Self]) -> wasm_component:host_new(pollable, ready) end),
      {<<"wasi:sockets/tcp">>, <<"[resource-drop]tcp-socket">>} =>
          fun(_Ctx, [H]) -> _ = tcp_drop(H), {ok, []} end,
      {<<"wasi:sockets/udp-create-socket">>, <<"create-udp-socket">>} =>
          wasm_component:import_fun(
            {[?ADDR_FAMILY], {result, handle, ?SOCK_ERROR}},
            fun([Family]) -> create_udp_socket(Family) end),
      {<<"wasi:sockets/udp">>, <<"[method]udp-socket.start-bind">>} =>
          wasm_component:import_fun(
            {[handle, handle, ?IP_SOCKADDR], {result, none, ?SOCK_ERROR}},
            fun([Self, _Net, Addr]) -> udp_start_bind(Self, Addr) end),
      {<<"wasi:sockets/udp">>, <<"[method]udp-socket.finish-bind">>} =>
          wasm_component:import_fun(
            {[handle], {result, none, ?SOCK_ERROR}}, fun([_Self]) -> {ok, undefined} end),
      {<<"wasi:sockets/udp">>, <<"[method]udp-socket.stream">>} =>
          wasm_component:import_fun(
            {[handle, {option, ?IP_SOCKADDR}], ?UDP_STREAM_RESULT},
            fun([Self, Remote]) -> udp_stream(Self, Remote, Grant) end),
      {<<"wasi:sockets/udp">>, <<"[method]outgoing-datagram-stream.send">>} =>
          wasm_component:import_fun(
            {[handle, {list, ?OUTGOING_DATAGRAM}], ?SEND_RESULT},
            fun([Out, Datagrams]) -> udp_send(Out, Datagrams) end),
      {<<"wasi:sockets/udp">>, <<"[method]outgoing-datagram-stream.check-send">>} =>
          wasm_component:import_fun(
            {[handle], ?SEND_RESULT}, fun([_Out]) -> {ok, ?WRITE_BUDGET} end),
      {<<"wasi:sockets/udp">>, <<"[method]incoming-datagram-stream.receive">>} =>
          wasm_component:import_fun(
            {[handle, u64], ?RECEIVE_RESULT},
            fun([In, Max]) -> udp_receive(In, Max) end),
      {<<"wasi:sockets/udp">>, <<"[resource-drop]incoming-datagram-stream">>} => drop_fun(),
      {<<"wasi:sockets/udp">>, <<"[resource-drop]outgoing-datagram-stream">>} => drop_fun(),
      {<<"wasi:sockets/udp">>, <<"[resource-drop]udp-socket">>} =>
          fun(_Ctx, [H]) -> _ = udp_drop(H), {ok, []} end}.

create_tcp_socket(Family) ->
    {ok, Handle} = wasi_sock:open(family_inet(Family), stream),
    {ok, wasm_component:host_new(tcp_socket, {unconnected, Handle})}.

family_inet(<<"ipv6">>) -> inet6;
family_inet(_Ipv4)      -> inet.

%% The connect state machine, collapsed to a blocking connect: start-connect
%% checks the grant and connects, finish-connect hands back the streams. The
%% address decision is wasi_net, so a socket reaches only a granted endpoint.
tcp_start_connect(Self, Net, Addr) ->
    case {wasm_component:host_get(Self), wasm_component:host_get(Net)} of
        {{ok, {tcp_socket, {unconnected, Pending}}}, {ok, {net_network, Grant}}} ->
            Endpoint = endpoint(Addr),
            case wasi_net:allows(connect, Endpoint, Grant) of
                false ->
                    {error, <<"access-denied">>};
                true ->
                    case wasi_sock:connect(Pending, Endpoint, ?SOCK_TIMEOUT) of
                        {ok, Conn} ->
                            _ = wasm_component:host_update(Self, {connected, Conn}),
                            {ok, undefined};
                        {error, Errno} ->
                            {error, sock_errno(Errno)}
                    end
            end;
        _ ->
            {error, <<"invalid-state">>}
    end.

tcp_finish_connect(Self) ->
    case wasm_component:host_get(Self) of
        {ok, {tcp_socket, {connected, Conn}}} ->
            In = wasm_component:host_new(input_stream, {socket, Conn, <<>>}),
            Out = wasm_component:host_new(
                    output_stream, fun(Bytes) -> _ = wasi_sock:send(Conn, Bytes), ok end),
            {ok, {In, Out}};
        _ ->
            {error, <<"invalid-state">>}
    end.

%% Bind and listen collapse like connect: start-bind checks the grant and binds,
%% start-listen listens, accept blocks for a connection and returns its streams.
tcp_start_bind(Self, Net, Addr) ->
    case {wasm_component:host_get(Self), wasm_component:host_get(Net)} of
        {{ok, {tcp_socket, {unconnected, Pending}}}, {ok, {net_network, Grant}}} ->
            Endpoint = endpoint(Addr),
            case wasi_net:allows(listen, Endpoint, Grant) of
                false ->
                    {error, <<"access-denied">>};
                true ->
                    case wasi_sock:bind(Pending, Endpoint) of
                        {ok, Bound}     -> bind_ok(Self, Bound);
                        {error, Errno}  -> {error, sock_errno(Errno)}
                    end
            end;
        _ ->
            {error, <<"invalid-state">>}
    end.

bind_ok(Self, Bound) ->
    _ = wasm_component:host_update(Self, {bound, Bound}),
    {ok, undefined}.

tcp_start_listen(Self) ->
    case wasm_component:host_get(Self) of
        {ok, {tcp_socket, {bound, Bound}}} ->
            case wasi_sock:listen(Bound, ?SOCK_BACKLOG) of
                {ok, Listen}   -> _ = wasm_component:host_update(Self, {listening, Listen}),
                                  {ok, undefined};
                {error, Errno} -> {error, sock_errno(Errno)}
            end;
        _ ->
            {error, <<"invalid-state">>}
    end.

tcp_accept(Self) ->
    case wasm_component:host_get(Self) of
        {ok, {tcp_socket, {listening, Listen}}} ->
            case wasi_sock:accept(Listen, ?SOCK_TIMEOUT) of
                {ok, Conn} ->
                    Sock = wasm_component:host_new(tcp_socket, {connected, Conn}),
                    In = wasm_component:host_new(input_stream, {socket, Conn, <<>>}),
                    Out = wasm_component:host_new(
                            output_stream, fun(B) -> _ = wasi_sock:send(Conn, B), ok end),
                    {ok, {Sock, In, Out}};
                {error, Errno} ->
                    {error, sock_errno(Errno)}
            end;
        _ ->
            {error, <<"invalid-state">>}
    end.

tcp_local(Self) ->
    case wasm_component:host_get(Self) of
        {ok, {tcp_socket, {State, Handle}}}
          when State =:= listening; State =:= connected ->
            case wasi_sock:local(Handle) of
                {ok, {Addr, Port}} -> {ok, ip_sockaddr(Addr, Port)};
                {error, Errno}     -> {error, sock_errno(Errno)}
            end;
        _ ->
            {error, <<"invalid-state">>}
    end.

ip_sockaddr({A, B, C, D}, Port) ->
    {<<"ipv4">>, #{<<"port">> => Port, <<"address">> => {A, B, C, D}}};
ip_sockaddr({A, B, C, D, E, F, G, H}, Port) ->
    {<<"ipv6">>, #{<<"port">> => Port, <<"flow-info">> => 0,
                   <<"address">> => {A, B, C, D, E, F, G, H}, <<"scope-id">> => 0}}.

tcp_drop(H) ->
    case wasm_component:host_get(H) of
        {ok, {tcp_socket, {connected, Conn}}}  -> _ = wasi_sock:close(Conn);
        {ok, {tcp_socket, {listening, Listen}}} -> _ = wasi_sock:close(Listen);
        _                                      -> ok
    end,
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

create_udp_socket(Family) ->
    {ok, Handle} = wasi_sock:open(family_inet(Family), dgram),
    {ok, wasm_component:host_new(udp_socket, {udp_unbound, Handle})}.

%% Bind to the local address. The source port is the guest's own, so it is not a
%% capability; the peer is checked at stream time.
udp_start_bind(Self, Addr) ->
    case wasm_component:host_get(Self) of
        {ok, {udp_socket, {udp_unbound, Pending}}} ->
            case wasi_sock:bind(Pending, endpoint_udp(Addr)) of
                {ok, Bound}    -> _ = wasm_component:host_update(Self, {udp_bound, Bound}),
                                  {ok, undefined};
                {error, Errno} -> {error, sock_errno(Errno)}
            end;
        _ ->
            {error, <<"invalid-state">>}
    end.

%% stream splits the socket into an incoming and outgoing datagram stream. A
%% connected stream (a remote address) checks the peer against the grant.
udp_stream(Self, Remote, Grant) ->
    case wasm_component:host_get(Self) of
        {ok, {udp_socket, {udp_bound, Sock}}} ->
            case udp_remote(Remote, Grant) of
                {error, _} = E ->
                    E;
                {ok, Peer} ->
                    In = wasm_component:host_new(udp_in, {Sock, Peer}),
                    Out = wasm_component:host_new(udp_out, {Sock, Peer}),
                    {ok, {In, Out}}
            end;
        _ ->
            {error, <<"invalid-state">>}
    end.

udp_remote(none, _Grant) ->
    {ok, none};
udp_remote({some, Addr}, Grant) ->
    Endpoint = endpoint_udp(Addr),
    case wasi_net:allows(connect, Endpoint, Grant) of
        true  -> {ok, Endpoint};
        false -> {error, <<"access-denied">>}
    end.

udp_send(Out, Datagrams) ->
    case wasm_component:host_get(Out) of
        {ok, {udp_out, {Sock, Peer}}} ->
            Sent = lists:foldl(
                     fun(D, Acc) -> Acc + send_datagram(Sock, Peer, D) end, 0, Datagrams),
            {ok, Sent};
        _ ->
            {error, <<"invalid-state">>}
    end.

send_datagram(Sock, Peer, #{<<"data">> := Data, <<"remote-address">> := Remote}) ->
    Dest = case Remote of
               {some, Addr} -> endpoint_udp(Addr);
               none         -> Peer
           end,
    case Dest of
        none -> 0;
        _    -> case wasi_sock:send_to(Sock, Data, Dest) of
                    {ok, _}     -> 1;
                    {error, _}  -> 0
                end
    end.

udp_receive(In, Max) ->
    case wasm_component:host_get(In) of
        {ok, {udp_in, {Sock, _Peer}}} when Max > 0 ->
            case wasi_sock:recv_from(Sock, 0, ?SOCK_TIMEOUT) of
                {ok, Data, {Addr, Port}} ->
                    {ok, [#{<<"data">> => Data,
                            <<"remote-address">> => ip_sockaddr(Addr, Port)}]};
                {error, _} ->
                    {ok, []}
            end;
        {ok, {udp_in, _}} ->
            {ok, []};
        _ ->
            {error, <<"invalid-state">>}
    end.

udp_drop(H) ->
    case wasm_component:host_get(H) of
        {ok, {udp_socket, {udp_bound, Sock}}} -> _ = wasi_sock:close(Sock);
        _                                     -> ok
    end,
    wasm_component:host_drop(H).

%% A Preview 1 errno to a wasi:sockets error-code name.
sock_errno(?ECONNREFUSED) -> <<"connection-refused">>;
sock_errno(?ETIMEDOUT)    -> <<"timeout">>;
sock_errno(?EHOSTUNREACH) -> <<"remote-unreachable">>;
sock_errno(?ENETUNREACH)  -> <<"remote-unreachable">>;
sock_errno(?EACCES)       -> <<"access-denied">>;
sock_errno(_Other)        -> <<"unknown">>.

%% Resolve only if the grant behind the network permits it: no grant, no network.
resolve_addresses(NetH, Name) ->
    case wasm_component:host_get(NetH) of
        {ok, {net_network, Grant}} ->
            case wasi_net:resolves(Grant) of
                false -> {error, <<"access-denied">>};
                true  -> {ok, wasm_component:host_new(net_addrs, resolve_names(Name))}
            end;
        _ ->
            {error, <<"invalid-argument">>}
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

%% Drop a descriptor: close the open file or forget the preopened root, then
%% free the host handle. A double drop or unknown handle is a no-op.
fs_drop(H) ->
    case wasm_component:host_get(H) of
        {ok, {fs_file, Handle}} -> _ = wasi_fs:close(Handle);
        {ok, {fs_dir, Root}}    -> _ = wasi_fs:forget(Root);
        error                   -> ok
    end,
    wasm_component:host_drop(H).

%% A Preview 1 errno to a wasi:filesystem error-code name; anything not mapped is
%% the generic `io`.
errno_name(?EACCES)       -> <<"access">>;
errno_name(?ENOENT)       -> <<"no-entry">>;
errno_name(?ELOOP)        -> <<"loop">>;
errno_name(?ENOTDIR)      -> <<"not-directory">>;
errno_name(?EISDIR)       -> <<"is-directory">>;
errno_name(?ENAMETOOLONG) -> <<"name-too-long">>;
errno_name(?EEXIST)       -> <<"exist">>;
errno_name(?EBADF)        -> <<"bad-descriptor">>;
errno_name(?EINVAL)       -> <<"invalid">>;
errno_name(?ENOSPC)       -> <<"insufficient-space">>;
errno_name(?ENOMEM)       -> <<"insufficient-memory">>;
errno_name(?ENOTEMPTY)    -> <<"not-empty">>;
errno_name(_Other)        -> <<"io">>.
