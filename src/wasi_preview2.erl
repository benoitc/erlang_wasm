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

-export([imports/0, random/0, clocks/0, environment/0, environment/2, io/0, io/1,
         filesystem/1, sockets/1, command/1, run_command/2, run_command/3]).

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
%% Where cli_exit records the status for run_command to read (same process).
-define(EXIT_STATUS, {?MODULE, exit_status}).

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
-define(FLAGS_RESULT, {result, ?DESC_FLAGS, ?ERROR_CODE}).
-define(METADATA_HASH, {record, [{<<"lower">>, u64}, {<<"upper">>, u64}]}).
-define(METADATA_HASH_RESULT, {result, ?METADATA_HASH, ?ERROR_CODE}).
-define(NEW_TIMESTAMP,
        {variant, [{<<"no-change">>, none}, {<<"now">>, none},
                   {<<"timestamp">>, ?DATETIME2}]}).
-define(ADVICE,
        {enum, [<<"normal">>, <<"sequential">>, <<"random">>, <<"will-need">>,
                <<"dont-need">>, <<"no-reuse">>]}).

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
      {M, <<"subscribe-duration">>} =>
          wasm_component:import_fun(
            {[u64], handle}, fun([_When]) -> wasm_component:host_new(pollable, ready) end),
      {M, <<"subscribe-instant">>} =>
          wasm_component:import_fun(
            {[u64], handle}, fun([_When]) -> wasm_component:host_new(pollable, ready) end),
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
    environment([], []).

-doc """
`wasi:cli/environment` with a given argv and environment. `get-arguments` returns
`Args` verbatim (the caller includes `argv[0]`; nothing is prepended), and
`get-environment` returns `Env` as name/value pairs.
""".
-spec environment([binary()], [{binary(), binary()}]) ->
          #{{binary(), binary()} => fun()}.
environment(Args, Env) ->
    E = <<"wasi:cli/environment">>,
    Pairs = [{K, V} || {K, V} <- Env],
    #{{E, <<"get-environment">>} =>
          wasm_component:import_fun(
            {[], {list, {tuple, [string, string]}}}, fun([]) -> Pairs end),
      {E, <<"get-arguments">>} =>
          wasm_component:import_fun({[], {list, string}}, fun([]) -> Args end),
      {E, <<"initial-cwd">>} =>
          wasm_component:import_fun({[], {option, string}}, fun([]) -> none end)}.

-doc """
Every import a `wasi:cli/command` component needs, merged into one map: io (with
`stdin` as the input source and `stdout`/`stderr` as sinks), clocks, random, the
environment, `exit`, and the terminal interfaces (which report no tty). Hand it
to a command component and call its `wasi:cli/run.run` export.

Options: `stdin` (a binary, default empty), `stdout` and `stderr`
(`fun((binary()) -> ok)` sinks, default discard).
""".
-spec command(#{stdin => binary(),
                stdout => fun((binary()) -> ok),
                stderr => fun((binary()) -> ok),
                args => [binary()],
                env => [{binary(), binary()}],
                preopen => file:filename_all(),
                writable => boolean()}) ->
          #{{binary(), binary()} => fun()}.
command(Opts) ->
    Stdin = maps:get(stdin, Opts, <<>>),
    Stdout = maps:get(stdout, Opts, fun(_) -> ok end),
    Stderr = maps:get(stderr, Opts, fun(_) -> ok end),
    Args = maps:get(args, Opts, []),
    Env = maps:get(env, Opts, []),
    Base = [io(#{source => Stdin, sink => Stdout}),
            clocks(), random(), environment(Args, Env),
            cli_exit(), cli_stderr(Stderr), cli_terminals()],
    %% The filesystem is always present so a component that imports it links even
    %% with no mount; without a preopen it simply offers no directories. That is
    %% what lets a command run with no stubbed imports.
    Fs = case maps:find(preopen, Opts) of
             {ok, Dir} -> [filesystem(#{preopen => Dir, name => <<"/">>,
                                        writable => maps:get(writable, Opts, false)})];
             error     -> [filesystem(#{name => <<"/">>})]
         end,
    lists:foldl(fun maps:merge/2, #{}, Base ++ Fs).

-doc """
Run a `wasi:cli/command` component with `Stdin` on its standard input and return
what it wrote to standard output. Instantiates with `command/1`, calls the
`wasi:cli/run.run` export, and collects the output stream. This is the
byte-in/byte-out entry: a real component reads stdin and writes stdout.
""".
-spec run_command(binary(), binary()) -> {ok, binary()} | {error, term()}.
run_command(Bin, Stdin) ->
    run_command(Bin, Stdin, #{}).

-doc """
As `run_command/2` with extra `command/1` options, such as `preopen => Dir` to
give the command a directory to read (a mount).
""".
-spec run_command(binary(), binary(),
                  #{args => [binary()], env => [{binary(), binary()}],
                    preopen => file:filename_all(), writable => boolean(),
                    compile => boolean(), stub => boolean()}) ->
          {ok, #{stdout := binary(), stderr := binary(),
                 exit_code := integer()}} | {error, term()}.
run_command(Bin, Stdin, Extra) ->
    _ = erase(?EXIT_STATUS),
    OutRef = make_ref(),
    ErrRef = make_ref(),
    Self = self(),
    Opts = (maps:without([compile, stub], Extra))#{
             stdin => Stdin,
             stdout => fun(B) -> Self ! {OutRef, B}, ok end,
             stderr => fun(B) -> Self ! {ErrRef, B}, ok end},
    Loader = case maps:get(compile, Extra, false) of true -> compile; false -> load end,
    InstOpts = #{loader => Loader, stub => maps:get(stub, Extra, false)},
    case wasm_component:instantiate(Bin, command(Opts), InstOpts) of
        {ok, Instance} ->
            case run_export(wasm_component:exports(Instance)) of
                {ok, Export} ->
                    RunResult = wasm_component:call(
                                  Instance, Export, {[], {result, none, none}}, []),
                    Stdout = collect_output(OutRef),
                    Stderr = collect_output(ErrRef),
                    case exit_outcome(RunResult) of
                        {ok, Code} ->
                            {ok, #{stdout => Stdout, stderr => Stderr,
                                   exit_code => Code}};
                        {error, _} = E ->
                            E
                    end;
                error ->
                    {error, no_run_export}
            end;
        {error, _} = E ->
            E
    end.

%% run returns result<_,_> (ok -> 0, err -> 1); a trap that recorded an exit
%% status is that code; any other trap is a real error.
exit_outcome({ok, {ok, _}})    -> {ok, 0};
exit_outcome({ok, {error, _}}) -> {ok, 1};
exit_outcome({ok, _Other})     -> {ok, 0};
exit_outcome({error, E}) ->
    case get(?EXIT_STATUS) of
        undefined -> {error, E};
        Code      -> {ok, Code}
    end.

run_export(Exports) ->
    case [E || E <- Exports, binary:match(E, <<"wasi:cli/run">>) =/= nomatch] of
        [Interface | _] -> {ok, <<Interface/binary, "#run">>};
        []              -> error
    end.

collect_output(Ref) ->
    collect_output(Ref, []).

collect_output(Ref, Acc) ->
    receive {Ref, Bytes} -> collect_output(Ref, [Bytes | Acc])
    after 0 -> iolist_to_binary(lists:reverse(Acc))
    end.

%% exit(status: result<_,_>) records the status and traps: the code cannot ride a
%% component trap value (call_host wraps it and reason_kind collapses it), so
%% run_command reads it from the process dictionary. ok disc 0 -> 0, err disc 1 -> 1.
cli_exit() ->
    #{{<<"wasi:cli/exit">>, <<"exit">>} =>
          fun(_Ctx, [Disc]) ->
              put(?EXIT_STATUS, exit_of(Disc)),
              {trap, wasi_exit}
          end}.

exit_of(0) -> 0;
exit_of(_) -> 1.

cli_stderr(Sink) ->
    #{{<<"wasi:cli/stderr">>, <<"get-stderr">>} =>
          wasm_component:import_fun(
            {[], handle}, fun([]) -> wasm_component:host_new(output_stream, Sink) end)}.

%% Not a terminal: get-terminal-* report none, so a guest writes plainly.
cli_terminals() ->
    #{{<<"wasi:cli/terminal-stdin">>, <<"get-terminal-stdin">>} =>
          wasm_component:import_fun({[], {option, handle}}, fun([]) -> none end),
      {<<"wasi:cli/terminal-stdout">>, <<"get-terminal-stdout">>} =>
          wasm_component:import_fun({[], {option, handle}}, fun([]) -> none end),
      {<<"wasi:cli/terminal-stderr">>, <<"get-terminal-stderr">>} =>
          wasm_component:import_fun({[], {option, handle}}, fun([]) -> none end)}.

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
        {ok, {output_stream, {file, Fh, Off}}} ->
            %% A file-backed stream (from write/append-via-stream): pwrite and
            %% advance the offset so the next write continues where this ended.
            case wasi_fs:pwrite(Fh, Off, Bytes) of
                {ok, N}    -> _ = wasm_component:host_update(Handle, {file, Fh, Off + N}), ok;
                {error, _} -> ok
            end;
        {ok, {output_stream, Sink}} when is_function(Sink) ->
            _ = Sink(Bytes), ok;
        _ ->
            ok
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
-spec filesystem(#{preopen => file:filename_all(), name => binary(),
                   writable => boolean()}) ->
          #{{binary(), binary()} => fun()}.
filesystem(Opts) ->
    HostDir = maps:get(preopen, Opts, none),
    Name = maps:get(name, Opts, <<"/">>),
    Writable = maps:get(writable, Opts, false),
    Types = <<"wasi:filesystem/types">>,
    Preopens = <<"wasi:filesystem/preopens">>,
    #{{Preopens, <<"get-directories">>} =>
          wasm_component:import_fun(
            {[], {list, {tuple, [handle, string]}}},
            fun([]) -> get_directories(HostDir, Name) end),
      %% Map a stream error back to a filesystem error-code. Our stream errors do
      %% not carry one (a filesystem operation reports its code directly), so this
      %% is `none`: the io error was not a filesystem error.
      {Types, <<"filesystem-error-code">>} =>
          wasm_component:import_fun({[handle], {option, ?ERROR_CODE}},
                                    fun([_Err]) -> none end),
      {Types, <<"[method]descriptor.open-at">>} =>
          wasm_component:import_fun(
            {[handle, ?PATH_FLAGS, string, ?OPEN_FLAGS, ?DESC_FLAGS], ?OPEN_RESULT},
            fun([Dir, PF, Path, OpenFlags, DescFlags]) ->
                open_at(Dir, PF, Path, OpenFlags, DescFlags, Writable)
            end),
      {Types, <<"[method]descriptor.write">>} =>
          wasm_component:import_fun(
            {[handle, {list, u8}, u64], {result, u64, ?ERROR_CODE}},
            fun([File, Data, Off]) -> write_at(File, Data, Off) end),
      {Types, <<"[method]descriptor.create-directory-at">>} =>
          wasm_component:import_fun(
            {[handle, string], {result, none, ?ERROR_CODE}},
            fun([Dir, Path]) -> create_directory_at(Dir, Path, Writable) end),
      {Types, <<"[method]descriptor.unlink-file-at">>} =>
          wasm_component:import_fun(
            {[handle, string], {result, none, ?ERROR_CODE}},
            fun([Dir, Path]) -> unlink_file_at(Dir, Path, Writable) end),
      {Types, <<"[method]descriptor.remove-directory-at">>} =>
          wasm_component:import_fun(
            {[handle, string], {result, none, ?ERROR_CODE}},
            fun([Dir, Path]) -> remove_directory_at(Dir, Path, Writable) end),
      {Types, <<"[method]descriptor.rename-at">>} =>
          wasm_component:import_fun(
            {[handle, string, handle, string], {result, none, ?ERROR_CODE}},
            fun([Dir, Path, NewDir, NewPath]) ->
                rename_at(Dir, Path, NewDir, NewPath, Writable)
            end),
      {Types, <<"[method]descriptor.symlink-at">>} =>
          wasm_component:import_fun(
            {[handle, string, string], {result, none, ?ERROR_CODE}},
            fun([Dir, OldPath, NewPath]) ->
                symlink_at(Dir, OldPath, NewPath, Writable)
            end),
      {Types, <<"[method]descriptor.link-at">>} =>
          wasm_component:import_fun(
            {[handle, ?PATH_FLAGS, string, handle, string],
             {result, none, ?ERROR_CODE}},
            fun([Dir, PathFlags, Path, NewDir, NewPath]) ->
                link_at(Dir, PathFlags, Path, NewDir, NewPath, Writable)
            end),
      {Types, <<"[method]descriptor.readlink-at">>} =>
          wasm_component:import_fun(
            {[handle, string], {result, string, ?ERROR_CODE}},
            fun([Dir, Path]) -> readlink_at(Dir, Path) end),
      {Types, <<"[method]descriptor.set-size">>} =>
          wasm_component:import_fun(
            {[handle, u64], {result, none, ?ERROR_CODE}},
            fun([File, Size]) -> set_size(File, Size, Writable) end),
      {Types, <<"[method]descriptor.set-times">>} =>
          wasm_component:import_fun(
            {[handle, ?NEW_TIMESTAMP, ?NEW_TIMESTAMP], {result, none, ?ERROR_CODE}},
            fun([H, Atime, Mtime]) -> set_times(H, Atime, Mtime, Writable) end),
      {Types, <<"[method]descriptor.set-times-at">>} =>
          wasm_component:import_fun(
            {[handle, ?PATH_FLAGS, string, ?NEW_TIMESTAMP, ?NEW_TIMESTAMP],
             {result, none, ?ERROR_CODE}},
            fun([Dir, PathFlags, Path, Atime, Mtime]) ->
                set_times_at(Dir, PathFlags, Path, Atime, Mtime, Writable)
            end),
      {Types, <<"[method]descriptor.advise">>} =>
          wasm_component:import_fun(
            {[handle, u64, u64, ?ADVICE], {result, none, ?ERROR_CODE}},
            fun([_H, _Off, _Len, _Advice]) -> {ok, undefined} end),
      {Types, <<"[method]descriptor.sync">>} =>
          wasm_component:import_fun(
            {[handle], {result, none, ?ERROR_CODE}}, fun([H]) -> sync_fd(H) end),
      {Types, <<"[method]descriptor.sync-data">>} =>
          wasm_component:import_fun(
            {[handle], {result, none, ?ERROR_CODE}}, fun([H]) -> sync_fd(H) end),
      {Types, <<"[method]descriptor.is-same-object">>} =>
          wasm_component:import_fun(
            {[handle, handle], bool}, fun([A, B]) -> is_same_object(A, B) end),
      {Types, <<"[method]descriptor.metadata-hash-at">>} =>
          wasm_component:import_fun(
            {[handle, ?PATH_FLAGS, string], ?METADATA_HASH_RESULT},
            fun([Dir, PathFlags, Path]) -> metadata_hash_at(Dir, PathFlags, Path) end),
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
      {Types, <<"[method]descriptor.get-flags">>} =>
          wasm_component:import_fun(
            {[handle], ?FLAGS_RESULT}, fun([H]) -> get_flags(H, Writable) end),
      {Types, <<"[method]descriptor.metadata-hash">>} =>
          wasm_component:import_fun(
            {[handle], ?METADATA_HASH_RESULT}, fun([H]) -> metadata_hash(H) end),
      {Types, <<"[method]descriptor.write-via-stream">>} =>
          wasm_component:import_fun(
            {[handle, u64], ?OPEN_RESULT},
            fun([H, Off]) -> write_via_stream(H, Off, Writable) end),
      {Types, <<"[method]descriptor.append-via-stream">>} =>
          wasm_component:import_fun(
            {[handle], ?OPEN_RESULT}, fun([H]) -> append_via_stream(H, Writable) end),
      {Types, <<"[method]directory-entry-stream.read-directory-entry">>} =>
          wasm_component:import_fun(
            {[handle], ?DIR_ENTRY_RESULT},
            fun([Stream]) -> read_directory_entry(Stream) end),
      {Types, <<"[resource-drop]directory-entry-stream">>} =>
          fun(_Ctx, [H]) -> _ = wasm_component:host_drop(H), {ok, []} end,
      {Types, <<"[resource-drop]descriptor">>} =>
          fun(_Ctx, [H]) -> _ = fs_drop(H), {ok, []} end}.

get_directories(none, _Name) ->
    [];
get_directories(HostDir, Name) ->
    case wasi_fs:preopen(HostDir) of
        {ok, Root} -> [{wasm_component:host_new(fs_dir, Root), Name}];
        {error, _} -> []
    end.

%% Open a path under a directory descriptor. Write intent is refused on a
%% read-only filesystem and otherwise turned into open modes. The path is not
%% resolved here: wasi_fs:open/3 applies the same sandbox Preview 1 does.
open_at(Dir, PathFlags, Path, OpenFlags, DescFlags, Writable) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, Root}} ->
            case write_intent(OpenFlags, DescFlags) of
                true when not Writable ->
                    {error, <<"read-only">>};
                WantsWrite ->
                    open_target(Root, PathFlags, Path, OpenFlags, DescFlags, WantsWrite)
            end;
        _ ->
            {error, <<"bad-descriptor">>}
    end.

%% Open a path that may be a directory or a file. A directory becomes a directory
%% descriptor (its own root, for path operations beneath it); a file is opened
%% through wasi_fs and remembers the flags it was opened with, which `get-flags`
%% reports. This mirrors Preview 1's path_open: a directory has a root and no file
%% handle. A directory asked for with write intent is is-directory, and the
%% `directory` open flag on a non-directory is not-directory.
open_target(Root, PathFlags, Path, OpenFlags, DescFlags, WantsWrite) ->
    WantDir = lists:member(<<"directory">>, OpenFlags),
    case wasi_fs:stat(Root, Path, follow_of(PathFlags)) of
        {ok, #{type := directory}} when WantsWrite ->
            {error, <<"is-directory">>};
        {ok, #{type := directory}} ->
            open_dir(Root, Path);
        {ok, _} when WantDir ->
            {error, <<"not-directory">>};
        {ok, _} ->
            open_file(Root, Path, OpenFlags, DescFlags, WantsWrite);
        {error, Errno} when WantDir ->
            {error, errno_name(Errno)};
        {error, _} ->
            %% Absent (a create) or a symlink stat could not follow: let the open
            %% produce the errno, as Preview 1 hands the name to wasi_fs.
            open_file(Root, Path, OpenFlags, DescFlags, WantsWrite)
    end.

open_dir(Root, Path) ->
    case wasi_fs:open_dir_at(Root, Path) of
        {ok, SubRoot} -> {ok, wasm_component:host_new(fs_dir, SubRoot)};
        {error, Errno} -> {error, errno_name(Errno)}
    end.

open_file(Root, Path, OpenFlags, DescFlags, WantsWrite) ->
    Modes = open_modes(OpenFlags, DescFlags, WantsWrite),
    case wasi_fs:open(Root, Path, Modes) of
        {ok, Handle} ->
            Flags = eff_flags(DescFlags, WantsWrite),
            {ok, wasm_component:host_new(fs_file, {Handle, Flags})};
        {error, Errno} ->
            {error, errno_name(Errno)}
    end.

%% The descriptor-flags a file ends up with: readable and writable as it was
%% opened, plus whichever sync flags the guest asked for. A write-only open reports
%% no read, so a guest can tell it apart.
eff_flags(DescFlags, WantsWrite) ->
    Sync = [F || F <- [<<"file-integrity-sync">>, <<"data-integrity-sync">>,
                       <<"requested-write-sync">>],
                 lists:member(F, DescFlags)],
    [<<"read">> || wants_read(DescFlags, WantsWrite)]
        ++ [<<"write">> || WantsWrite] ++ Sync.

%% Read is implied unless the open is write-only (write wanted, read not named).
wants_read(DescFlags, WantsWrite) ->
    (not WantsWrite) orelse lists:member(<<"read">>, DescFlags).

write_intent(OpenFlags, DescFlags) ->
    Wants = fun(Name, Set) -> lists:member(Name, Set) end,
    Wants(<<"create">>, OpenFlags) orelse Wants(<<"truncate">>, OpenFlags)
        orelse Wants(<<"exclusive">>, OpenFlags)
        orelse Wants(<<"write">>, DescFlags)
        orelse Wants(<<"mutate-directory">>, DescFlags).

open_modes(OpenFlags, DescFlags, WantsWrite) ->
    Base = [read || wants_read(DescFlags, WantsWrite)] ++ [write || WantsWrite],
    Add = fun(Flag, Mode, Acc) ->
              case lists:member(Flag, OpenFlags) of true -> [Mode | Acc]; false -> Acc end
          end,
    Add(<<"create">>, create,
        Add(<<"truncate">>, truncate,
            Add(<<"exclusive">>, exclusive, Base))).

%% Write bytes at an offset, reporting how many. A write to a read-opened file is
%% refused by the OS, so a read-only filesystem needs no extra guard here.
%% A file-backed output stream, from the given offset (write) or the file end
%% (append). Refused on a read-only filesystem. `write_stream` does the pwrite.
write_via_stream(_File, _Off, false) ->
    {error, <<"read-only">>};
write_via_stream(File, Off, true) ->
    case writable_file(File) of
        {ok, Handle} -> {ok, wasm_component:host_new(output_stream, {file, Handle, Off})};
        {error, _} = E -> E
    end.

append_via_stream(_File, false) ->
    {error, <<"read-only">>};
append_via_stream(File, true) ->
    case writable_file(File) of
        {ok, Handle} ->
            End = case wasi_fs:size(Handle) of {ok, S} -> S; _ -> 0 end,
            {ok, wasm_component:host_new(output_stream, {file, Handle, End})};
        {error, _} = E ->
            E
    end.

%% A file that was opened for writing; a read-only descriptor cannot produce a
%% write stream, which is how a write to a read-opened file is refused.
writable_file(File) ->
    case wasm_component:host_get(File) of
        {ok, {fs_file, {Handle, Flags}}} ->
            case lists:member(<<"write">>, Flags) of
                true  -> {ok, Handle};
                false -> {error, <<"bad-descriptor">>}
            end;
        _ ->
            {error, <<"bad-descriptor">>}
    end.

write_at(File, Data, Off) ->
    case wasm_component:host_get(File) of
        {ok, {fs_file, {Handle, _}}} ->
            case wasi_fs:pwrite(Handle, Off, Data) of
                {ok, Count}    -> {ok, Count};
                {error, Errno} -> {error, errno_name(Errno)}
            end;
        _ ->
            {error, <<"bad-descriptor">>}
    end.

create_directory_at(_Dir, _Path, false) ->
    {error, <<"read-only">>};
create_directory_at(Dir, Path, true) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, Root}} -> fs_unit(wasi_fs:mkdir(Root, Path));
        _                    -> {error, <<"bad-descriptor">>}
    end.

unlink_file_at(_Dir, _Path, false) ->
    {error, <<"read-only">>};
unlink_file_at(Dir, Path, true) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, Root}} ->
            %% A trailing slash on a name that is not a directory is not-directory;
            %% on a directory, unlink itself reports is-directory / not-permitted.
            case trailing_slash(Path) andalso not is_dir(Root, Path) of
                true  -> {error, <<"not-directory">>};
                false -> fs_unit(wasi_fs:unlink(Root, Path))
            end;
        _ ->
            {error, <<"bad-descriptor">>}
    end.

is_dir(Root, Path) ->
    case wasi_fs:stat(Root, Path, nofollow) of
        {ok, #{type := directory}} -> true;
        _                          -> false
    end.

trailing_slash(<<>>)   -> false;
trailing_slash(Path)   -> binary:last(Path) =:= $/.

fs_unit(ok)             -> {ok, undefined};
fs_unit({error, Errno}) -> {error, errno_name(Errno)}.

%% Remove an empty directory. A mutation, so refused on a read-only mount.
remove_directory_at(_Dir, _Path, false) ->
    {error, <<"read-only">>};
remove_directory_at(Dir, Path, true) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, Root}} -> fs_unit(wasi_fs:rmdir(Root, Path));
        _                    -> {error, <<"bad-descriptor">>}
    end.

%% Rename within the sandbox. Both descriptors are directories; a mutation.
rename_at(_Dir, _Path, _NewDir, _NewPath, false) ->
    {error, <<"read-only">>};
rename_at(Dir, Path, NewDir, NewPath, true) ->
    with_two_dirs(Dir, NewDir,
                  fun(From, To) ->
                      fs_unit(wasi_fs:rename(From, Path, To, NewPath))
                  end).

%% Create a symlink at NewPath pointing at OldPath. An absolute target is refused
%% at creation, as Preview 1 does, so a symlink can never name outside the sandbox.
symlink_at(_Dir, _OldPath, _NewPath, false) ->
    {error, <<"read-only">>};
symlink_at(_Dir, <<$/, _/binary>>, _NewPath, true) ->
    {error, <<"access">>};
symlink_at(Dir, OldPath, NewPath, true) ->
    case trailing_slash(NewPath) of
        %% The link location ending in `/` names a directory that is not there.
        true ->
            {error, <<"no-entry">>};
        false ->
            case wasm_component:host_get(Dir) of
                {ok, {fs_dir, Root}} -> fs_unit(wasi_fs:symlink(Root, NewPath, OldPath));
                _                    -> {error, <<"bad-descriptor">>}
            end
    end.

%% Hard-link Path under Dir to NewPath under NewDir. Following the source symlink
%% is rejected as invalid, as Preview 1's path_link does.
link_at(_Dir, _PathFlags, _Path, _NewDir, _NewPath, false) ->
    {error, <<"read-only">>};
link_at(Dir, PathFlags, Path, NewDir, NewPath, true) ->
    case lists:member(<<"symlink-follow">>, PathFlags) of
        true ->
            {error, <<"invalid">>};
        false ->
            with_two_dirs(Dir, NewDir,
                          fun(From, To) ->
                              fs_unit(wasi_fs:link(From, Path, To, NewPath))
                          end)
    end.

with_two_dirs(A, B, Fun) ->
    case {wasm_component:host_get(A), wasm_component:host_get(B)} of
        {{ok, {fs_dir, RA}}, {ok, {fs_dir, RB}}} -> Fun(RA, RB);
        _                                        -> {error, <<"bad-descriptor">>}
    end.

readlink_at(Dir, Path) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, Root}} ->
            case wasi_fs:readlink(Root, Path) of
                {ok, Target}   -> {ok, Target};
                {error, Errno} -> {error, errno_name(Errno)}
            end;
        _ ->
            {error, <<"bad-descriptor">>}
    end.

set_size(_File, _Size, false) ->
    {error, <<"read-only">>};
set_size(File, Size, true) ->
    case wasm_component:host_get(File) of
        {ok, {fs_file, {Handle, _}}} -> fs_unit(wasi_fs:truncate(Handle, Size));
        _                       -> {error, <<"bad-descriptor">>}
    end.

set_times(_H, _Atime, _Mtime, false) ->
    {error, <<"read-only">>};
set_times(H, Atime, Mtime, true) ->
    case wasm_component:host_get(H) of
        {ok, {fs_file, {Handle, _}}} ->
            fs_unit(wasi_fs:set_times_fd(Handle, new_ts(Atime), new_ts(Mtime)));
        {ok, {fs_dir, Root}} ->
            fs_unit(wasi_fs:set_times(Root, <<".">>, new_ts(Atime), new_ts(Mtime)));
        error ->
            {error, <<"bad-descriptor">>}
    end.

set_times_at(_Dir, _PathFlags, _Path, _Atime, _Mtime, false) ->
    {error, <<"read-only">>};
set_times_at(Dir, PathFlags, Path, Atime, Mtime, true) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, Root}} ->
            fs_unit(wasi_fs:set_times(Root, Path, new_ts(Atime), new_ts(Mtime),
                                      follow_of(PathFlags)));
        _ ->
            {error, <<"bad-descriptor">>}
    end.

%% The new-timestamp variant: leave unchanged, set to now, or a given datetime.
%% `wasi_fs` takes nanoseconds since the epoch, or `omit` to leave a stamp alone.
new_ts({<<"no-change">>, _}) ->
    omit;
new_ts({<<"now">>, _}) ->
    os:system_time(nanosecond);
new_ts({<<"timestamp">>, #{<<"seconds">> := S, <<"nanoseconds">> := N}}) ->
    S * 1000000000 + N.

follow_of(PathFlags) ->
    case lists:member(<<"symlink-follow">>, PathFlags) of
        true  -> follow;
        false -> nofollow
    end.

sync_fd(H) ->
    case wasm_component:host_get(H) of
        {ok, {fs_file, {Handle, _}}} -> fs_unit(wasi_fs:sync(Handle));
        {ok, {fs_dir, _Root}}   -> {ok, undefined};
        error                   -> {error, <<"bad-descriptor">>}
    end.

%% Two descriptors name the same object when their device and inode agree.
is_same_object(A, B) ->
    case {ino(A), ino(B)} of
        {{ok, Key}, {ok, Key}} -> true;
        _                      -> false
    end.

ino(H) ->
    case wasm_component:host_get(H) of
        {ok, {fs_file, {Handle, _}}} -> ino_of(wasi_fs:stat_fd(Handle));
        {ok, {fs_dir, Root}}    -> ino_of(wasi_fs:stat(Root, <<".">>));
        error                   -> error
    end.

ino_of({ok, Map})  -> {ok, {maps:get(dev, Map, 0), maps:get(inode, Map, 0)}};
ino_of({error, _}) -> error.

metadata_hash_at(Dir, PathFlags, Path) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, Root}} ->
            from_hash(wasi_fs:stat(Root, Path, follow_of(PathFlags)));
        _ ->
            {error, <<"bad-descriptor">>}
    end.

read_at(File, Len, Off) ->
    case wasm_component:host_get(File) of
        {ok, {fs_file, {Handle, _}}} ->
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
        {ok, {fs_file, {Handle, _}}} ->
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

descriptor_flags(true)  -> [<<"read">>, <<"write">>];
descriptor_flags(false) -> [<<"read">>].

%% A file reports the flags it was opened with; a directory reports the mount's.
get_flags(H, Writable) ->
    case wasm_component:host_get(H) of
        {ok, {fs_file, {_Handle, Flags}}} -> {ok, Flags};
        {ok, {fs_dir, _Root}}             -> {ok, descriptor_flags(Writable)};
        error                             -> {error, <<"bad-descriptor">>}
    end.

%% A stable identity for a descriptor, from its inode; enough for a guest to tell
%% two descriptors apart, which is what metadata-hash is for.
metadata_hash(H) ->
    case wasm_component:host_get(H) of
        {ok, {fs_file, {Handle, _}}} -> from_hash(wasi_fs:stat_fd(Handle));
        {ok, {fs_dir, Root}}    -> from_hash(wasi_fs:stat(Root, <<".">>));
        error                   -> {error, <<"bad-descriptor">>}
    end.

from_hash({ok, Map}) ->
    {ok, #{<<"lower">> => maps:get(inode, Map, 0), <<"upper">> => 0}};
from_hash({error, Errno}) ->
    {error, errno_name(Errno)}.

stat(H) ->
    case wasm_component:host_get(H) of
        {ok, {fs_file, {Handle, _}}} -> from_stat(wasi_fs:stat_fd(Handle));
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
        {ok, {fs_file, {Handle, _}}} ->
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
        {ok, {fs_file, {Handle, _}}} -> _ = wasi_fs:close(Handle);
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
errno_name(?ENOTCAPABLE)  -> <<"not-permitted">>;
errno_name(?EPERM)        -> <<"not-permitted">>;
errno_name(?EROFS)        -> <<"read-only">>;
errno_name(?EBUSY)        -> <<"busy">>;
errno_name(?EAGAIN)       -> <<"would-block">>;
errno_name(?EXDEV)        -> <<"cross-device">>;
errno_name(?EFBIG)        -> <<"file-too-large">>;
errno_name(?ESPIPE)       -> <<"invalid-seek">>;
errno_name(?ENXIO)        -> <<"no-such-device">>;
errno_name(?ENOSYS)       -> <<"unsupported">>;
errno_name(?ENOTSUP)      -> <<"unsupported">>;
errno_name(?EPIPE)        -> <<"pipe">>;
errno_name(_Other)        -> <<"io">>.
