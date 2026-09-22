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
         filesystem/1]).

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
        {ok, {input_stream, <<>>}} ->
            {error, {<<"closed">>, undefined}};
        {ok, {input_stream, Remaining}} ->
            N = min(Len, byte_size(Remaining)),
            <<Chunk:N/binary, Rest/binary>> = Remaining,
            _ = wasm_component:host_update(Handle, Rest),
            {ok, Chunk};
        error ->
            {error, {<<"closed">>, undefined}}
    end.

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
