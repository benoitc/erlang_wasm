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

-export([imports/0, random/0, clocks/0, environment/0, environment/3, io/0, io/1,
         filesystem/1, sockets/1, command/1, run_command/2, run_command/3,
         run_serve/3]).
%% The poll_oneoff readiness logic over host pollable handles, and the monotonic
%% clock its deadlines use, exported so a test can drive poll directly (as
%% host_new/host_get are).
-export([poll/1, monotonic_now/0, next_sleep_ms/1, close_resource/1]).
%% Exported so a test can drive the stream write and udp grant paths directly.
-export([write_stream/2, datagram_allowed/3, peer_matches/3, random_bytes/1]).

%% result<_, stream-error>, the result every output-stream method returns. The
%% error arm names an `error` resource (a handle), minted when a file-backed write
%% fails; a discarding/buffer sink never fails, so it returns ok.
-define(STREAM_ERROR,
        {variant, [{<<"last-operation-failed">>, handle}, {<<"closed">>, none}]}).
-define(WRITE_RESULT, {result, none, ?STREAM_ERROR}).
-define(READ_RESULT, {result, {list, u8}, ?STREAM_ERROR}).
-define(COUNT_RESULT, {result, u64, ?STREAM_ERROR}).

%% Longest single timer:sleep a clock wait uses. A guest deadline can be months
%% out, past `receive after`'s ceiling; `sleep_until/1` chunks the wait by this.
-define(SLEEP_CHUNK_MS, 60000).

%% Most random bytes the host will materialise for one get-random-bytes call. A
%% guest u64 length beyond this is refused rather than allocated up front.
-define(MAX_RANDOM_BYTES, 16 * 1024 * 1024).

%% How long a blocking poll waits between readiness re-checks: short enough that a
%% socket's data wakes the poll promptly, long enough not to busy-spin.
-define(POLL_SLICE_MS, 50).
%% The write budget check-write reports for the discarding/buffer sinks: always
%% ready for a chunk this size.
-define(WRITE_BUDGET, 65536).
%% Where cli_exit records the status for run_command to read (same process).
-define(EXIT_STATUS, {?MODULE, exit_status}).
-define(INSECURE_SEED, {?MODULE, insecure_seed}).
-define(SOCKOPT, {?MODULE, sockopt}).

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
%% The datagrams a single send may carry: check-send reports it, and sending more
%% than the last check-send permitted is a trap (the wasi:sockets contract).
-define(DGRAM_PERMIT, 16).
%% Process-dict key marking a connection whose receive side the guest shut down.
-define(SHUT_RECV, {?MODULE, shut_recv}).
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
    Insecure = <<"wasi:random/insecure">>,
    Seed = <<"wasi:random/insecure-seed">>,
    %% The insecure interfaces do not need cryptographic strength, only speed and
    %% independence; backing them by the same CSPRNG is stronger than required and
    %% keeps one source of randomness.
    #{{I, <<"get-random-u64">>} =>
          wasm_component:import_fun({[], u64}, fun([]) -> random_u64() end),
      {I, <<"get-random-bytes">>} =>
          wasm_component:import_fun({[u64], {list, u8}},
                                    fun([Len]) -> random_bytes(Len) end),
      {Insecure, <<"get-insecure-random-u64">>} =>
          wasm_component:import_fun({[], u64}, fun([]) -> random_u64() end),
      {Insecure, <<"get-insecure-random-bytes">>} =>
          wasm_component:import_fun({[u64], {list, u8}},
                                    fun([Len]) -> random_bytes(Len) end),
      {Seed, <<"insecure-seed">>} =>
          wasm_component:import_fun({[], {tuple, [u64, u64]}},
                                    fun([]) -> insecure_seed() end)}.

%% The insecure seed is a fixed 128-bit value for the life of the instance: a
%% guest seeds a pseudo-random generator with it and every call must return the
%% same seed. The instance runs in one process, so it is cached there.
insecure_seed() ->
    case get(?INSECURE_SEED) of
        undefined -> V = {random_u64(), random_u64()}, put(?INSECURE_SEED, V), V;
        V         -> V
    end.

random_u64() ->
    <<X:64/unsigned>> = crypto:strong_rand_bytes(8),
    X.

random_bytes(0) -> <<>>;
random_bytes(Len) when is_integer(Len), Len > ?MAX_RANDOM_BYTES ->
    %% A guest u64 length would otherwise drive an unbounded host allocation before
    %% the result is lowered into (bounded) guest memory. Refuse an absurd request
    %% rather than allocate it.
    error(random_bytes_too_large);
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
            {[u64], handle},
            fun([When]) ->
                wasm_component:host_new(pollable, {clock, monotonic_now() + When})
            end),
      {M, <<"subscribe-instant">>} =>
          wasm_component:import_fun(
            {[u64], handle},
            fun([When]) -> wasm_component:host_new(pollable, {clock, When}) end),
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

%%% --------------------------------------------------------------------- poll ---

%% A pollable's state: `{clock, Deadline}` for a timer, `{stream, Handle}` for a
%% stream whose readiness is asked of the stream itself, or the bare atom `ready`
%% for something always ready. A handle that is gone reads as ready, so a stale
%% entry never wedges a poll.
state_of(Handle) ->
    case wasm_component:host_get(Handle) of
        {ok, {pollable, State}} -> State;
        _                       -> ready
    end.

pollable_ready(ready)             -> true;
pollable_ready({clock, Deadline}) -> monotonic_now() >= Deadline;
pollable_ready({stream, Handle})  -> stream_ready(Handle).

%% A stream is ready when a read (or write) would not block. Our sinks and the
%% in-memory, file and drained input streams are always ready; a socket input
%% stream is ready only when data is buffered or waiting, which a non-blocking peek
%% answers without consuming (any bytes it reads are buffered for the next read).
stream_ready(Handle) ->
    case wasm_component:host_get(Handle) of
        {ok, {input_stream, {socket, Sock, <<>>}}} ->
            case wasi_sock2:recv(Sock, 0, 0) of
                {ok, Data} -> _ = wasm_component:host_update(Handle, {socket, Sock, Data}),
                              Data =/= <<>>;
                eof        -> true;
                {error, _} -> false
            end;
        {ok, {udp_in, {Sock, Peer, Queue}}} ->
            case udp_pump(Sock, Peer, Queue, false) of
                {ok, Q}    -> _ = wasm_component:host_update(Handle, {Sock, Peer, Q}),
                              Q =/= [];
                {error, _} -> true  %% a pending socket error is deliverable now
            end;
        error -> true;
        _     -> true
    end.

%% Wait for a pollable: a clock sleeps to its deadline, a socket stream blocks for
%% data, anything already ready returns now.
block_pollable(ready)             -> undefined;
block_pollable({clock, Deadline}) -> sleep_until(Deadline), undefined;
block_pollable({stream, Handle})  -> block_stream(Handle), undefined.

block_stream(Handle) ->
    case wasm_component:host_get(Handle) of
        {ok, {input_stream, {socket, Sock, <<>>}}} ->
            case wasi_sock2:recv(Sock, 0, ?SOCK_TIMEOUT) of
                {ok, Data} -> wasm_component:host_update(Handle, {socket, Sock, Data});
                _          -> ok
            end;
        {ok, {udp_in, {Sock, Peer, Queue}}} ->
            case udp_pump(Sock, Peer, Queue, true) of
                {ok, Q}    -> wasm_component:host_update(Handle, {Sock, Peer, Q});
                {error, _} -> ok  %% wake so the receive can return the error
            end;
        _ ->
            ok
    end.

%% poll_oneoff: the indices ready now. When none are ready the set is all clocks,
%% so wait for the earliest deadline and return whichever have then elapsed.
-spec poll([non_neg_integer()]) -> [non_neg_integer()].
poll(Handles) ->
    States = [state_of(H) || H <- Handles],
    case ready_indices(States) of
        []      -> wait_ready(States);
        Indices -> Indices
    end.

ready_indices(States) ->
    [I || {I, S} <- lists:enumerate(0, States), pollable_ready(S)].

%% Block until at least one pollable is ready, never returning an empty set for a
%% non-empty poll. Readiness is re-checked in short slices, so a socket that
%% receives data wakes the poll within a slice rather than only at a clock
%% deadline; a slice is shortened so a clock still fires close to its deadline. The
%% slices sleep (no busy-spin) and the worker reaper bounds a poll that never
%% becomes ready.
wait_ready(States) ->
    case ready_indices(States) of
        []      -> timer:sleep(poll_slice(States)), wait_ready(States);
        Indices -> Indices
    end.

poll_slice(States) ->
    case earliest_deadline(States) of
        none     -> ?POLL_SLICE_MS;
        Deadline -> max(1, min(?POLL_SLICE_MS,
                               (Deadline - monotonic_now() + 999999) div 1000000))
    end.

earliest_deadline(States) ->
    case [D || {clock, D} <- States] of
        []        -> none;
        Deadlines -> lists:min(Deadlines)
    end.

%% Sleep to the deadline in bounded chunks. A guest chooses the deadline, so the
%% remaining time can exceed `receive after`'s ~49.7 day ceiling; passing that to
%% timer:sleep raises. Chunking keeps the true deadline (honest), never hands
%% timer:sleep an out-of-range value, and lets the worker reaper interrupt between
%% chunks.
sleep_until(Deadline) ->
    case next_sleep_ms(Deadline) of
        0  -> ok;
        Ms -> timer:sleep(Ms), sleep_until(Deadline)
    end.

%% Milliseconds to sleep now: the time left to the deadline, rounded up, capped to
%% one chunk and floored at 0. Never exceeds `?SLEEP_CHUNK_MS`, so it is always a
%% valid `timer:sleep` value.
next_sleep_ms(Deadline) ->
    Remaining = (Deadline - monotonic_now() + 999999) div 1000000,
    min(max(0, Remaining), ?SLEEP_CHUNK_MS).

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
    environment([], [], none).

-doc """
`wasi:cli/environment` with a given argv, environment and initial working
directory. `get-arguments` returns `Args` verbatim (the caller includes `argv[0]`;
nothing is prepended), `get-environment` returns `Env` as name/value pairs, and
`initial-cwd` returns `Cwd` (`none` or `{some, Path}`).
""".
-spec environment([binary()], [{binary(), binary()}],
                  none | {some, binary()}) ->
          #{{binary(), binary()} => fun()}.
environment(Args, Env, Cwd) ->
    E = <<"wasi:cli/environment">>,
    Pairs = [{K, V} || {K, V} <- Env],
    #{{E, <<"get-environment">>} =>
          wasm_component:import_fun(
            {[], {list, {tuple, [string, string]}}}, fun([]) -> Pairs end),
      {E, <<"get-arguments">>} =>
          wasm_component:import_fun({[], {list, string}}, fun([]) -> Args end),
      {E, <<"initial-cwd">>} =>
          wasm_component:import_fun({[], {option, string}}, fun([]) -> Cwd end)}.

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
                writable => boolean(),
                preopens => [{binary(), file:filename_all(), boolean()}],
                initial_cwd => binary(),
                network => term()}) ->
          #{{binary(), binary()} => fun()}.
command(Opts) ->
    Stdin = maps:get(stdin, Opts, <<>>),
    Stdout = maps:get(stdout, Opts, fun(_) -> ok end),
    Stderr = maps:get(stderr, Opts, fun(_) -> ok end),
    Args = maps:get(args, Opts, []),
    Env = maps:get(env, Opts, []),
    Cwd = case maps:find(initial_cwd, Opts) of
              {ok, C} -> {some, C};
              error   -> none
          end,
    Base = [io(#{source => Stdin, sink => Stdout}),
            clocks(), random(), environment(Args, Env, Cwd),
            cli_exit(), cli_stderr(Stderr), cli_terminals()],
    %% The filesystem is always present so a component that imports it links even
    %% with no mount; without one it simply offers no directories. That is what lets
    %% a command run with no stubbed imports. A caller gives one mount with
    %% `preopen`/`writable`, or several named mounts with `preopens` (a list of
    %% {name, dir, writable}), each carrying its own writability.
    Fs = [filesystem(#{mounts => command_mounts(Opts)})],
    %% Sockets are opt-in: only a caller that passes a network grant gets the
    %% wasi:sockets slice, so the default capability posture is unchanged and a
    %% command that imports no sockets still links.
    Net = case maps:find(network, Opts) of
              {ok, Grant} -> [sockets(#{grant => Grant})];
              error       -> []
          end,
    %% wasi:http is always present (like the filesystem) so a reactor that imports
    %% its types links with no mount; outbound requests are gated by the grant, so
    %% without a network grant the types work but a request reaches nowhere.
    Http = [wasi_http:http(#{grant => maps:get(network, Opts, none),
                             transport => maps:get(http_transport, Opts, wasi_http_h1)})],
    lists:foldl(fun maps:merge/2, #{}, Base ++ Fs ++ Net ++ Http).

%% The mounts a command exposes: an explicit named list, or the single preopen.
command_mounts(Opts) ->
    case maps:find(preopens, Opts) of
        {ok, Mounts} ->
            Mounts;
        error ->
            case maps:find(preopen, Opts) of
                {ok, Dir} -> [{<<"/">>, Dir, maps:get(writable, Opts, false)}];
                error     -> []
            end
    end.

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
give the command a directory to read (a mount), or `network => Grant` to grant the
`wasi:sockets` slice (opt-in; without it a command imports no sockets).
""".
-spec run_command(binary(), binary(),
                  #{args => [binary()], env => [{binary(), binary()}],
                    preopen => file:filename_all(), writable => boolean(),
                    preopens => [{binary(), file:filename_all(), boolean()}],
                    initial_cwd => binary(),
                    network => term(),
                    compile => boolean(), stub => boolean()}) ->
          {ok, #{stdout := binary(), stderr := binary(),
                 exit_code := integer()}} | {error, term()}.
run_command(Bin, Stdin, Extra) ->
    _ = erase(?EXIT_STATUS),
    _ = erase(?INSECURE_SEED),
    OutRef = make_ref(),
    ErrRef = make_ref(),
    Self = self(),
    Opts = (maps:without([compile, stub], Extra))#{
             stdin => Stdin,
             stdout => fun(B) -> Self ! {OutRef, B}, ok end,
             stderr => fun(B) -> Self ! {ErrRef, B}, ok end},
    Loader = case maps:get(compile, Extra, false) of true -> compile; false -> load end,
    InstOpts = #{loader => Loader, stub => maps:get(stub, Extra, false),
                 resource_closer => fun close_resource/1,
                 resource_predrop => fun stream_predrop/1},
    case wasm_component:instantiate(Bin, command(Opts), InstOpts) of
        {ok, Instance} ->
            %% Destroy on every path: a run mints stream, pollable and directory
            %% handles that own fds, and a command is one-shot.
            try
                run_collect(Instance, OutRef, ErrRef)
            after
                wasm_component:destroy(Instance, fun close_resource/1)
            end;
        {error, _} = E ->
            E
    end.

run_collect(Instance, OutRef, ErrRef) ->
    case run_export(wasm_component:exports(Instance)) of
        {ok, Export} ->
            RunResult = wasm_component:call(
                          Instance, Export, {[], {result, none, none}}, []),
            Stdout = collect_output(OutRef),
            Stderr = collect_output(ErrRef),
            case exit_outcome(RunResult) of
                {ok, Code} ->
                    {ok, #{stdout => Stdout, stderr => Stderr, exit_code => Code}};
                {error, _} = E ->
                    E
            end;
        error ->
            {error, no_run_export}
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

-doc """
Serve one request to a `wasi:http/incoming-handler` reactor component. `Request`
is `#{method, path, scheme, authority, headers, body}`; the host synthesizes the
incoming-request, calls the guest's `handle`, and returns the response the guest
set on the outparam as `{ok, Status, Headers, Body}`. `Extra` is the `command/1`
options (a `network` grant lets the reactor make its own outbound requests).
""".
-spec run_serve(binary(), map(),
                #{network => term(), compile => boolean()}) ->
          {ok, 0..65535, [{binary(), binary()}], binary()} | {error, term()}.
run_serve(Bin, Request, Extra) ->
    _ = erase(?EXIT_STATUS),
    _ = erase(?INSECURE_SEED),
    Loader = case maps:get(compile, Extra, false) of true -> compile; false -> load end,
    InstOpts = #{loader => Loader, resource_closer => fun close_resource/1,
                 resource_predrop => fun stream_predrop/1},
    Opts = maps:without([compile], Extra),
    case wasm_component:instantiate(Bin, command(Opts), InstOpts) of
        {ok, Instance} ->
            try serve(Instance, Request)
            after wasm_component:destroy(Instance, fun close_resource/1) end;
        {error, _} = E ->
            E
    end.

serve(Instance, Request) ->
    case serve_export(wasm_component:exports(Instance)) of
        {ok, Export} ->
            ReqH = wasi_http:incoming_request(Request),
            OutparamH = wasm_component:host_new(http_outparam, undefined),
            _ = wasm_component:call(Instance, Export, {[handle, handle], none},
                                    [ReqH, OutparamH]),
            wasi_http:read_outparam(OutparamH);
        error ->
            {error, no_incoming_handler}
    end.

serve_export(Exports) ->
    case [E || E <- Exports,
               binary:match(E, <<"wasi:http/incoming-handler">>) =/= nomatch] of
        [Interface | _] -> {ok, <<Interface/binary, "#handle">>};
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
          end,
      {<<"wasi:cli/exit">>, <<"exit-with-code">>} =>
          fun(_Ctx, [Code]) ->
              put(?EXIT_STATUS, Code),
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
    Write = fun([Handle, Bytes]) -> write_result(checked_write(Handle, Bytes)) end,
    Read = fun([H, Len]) -> read_stream(H, Len) end,
    BlockingRead = fun([H, Len]) -> blocking_read_stream(H, Len) end,
    Subscribe = fun([Stream]) -> wasm_component:host_new(pollable, {stream, Stream}) end,
    #{{Stdout, <<"get-stdout">>} =>
          wasm_component:import_fun(
            {[], handle}, fun([]) -> wasm_component:host_new(output_stream, Sink) end),
      {Streams, <<"[method]output-stream.check-write">>} =>
          wasm_component:import_fun(
            {[handle], ?COUNT_RESULT}, fun([H]) -> check_write(H) end),
      {Streams, <<"[method]output-stream.write">>} =>
          wasm_component:import_fun({[handle, {list, u8}], ?WRITE_RESULT}, Write),
      {Streams, <<"[method]output-stream.blocking-write-and-flush">>} =>
          wasm_component:import_fun({[handle, {list, u8}], ?WRITE_RESULT}, Write),
      {Streams, <<"[method]output-stream.flush">>} =>
          wasm_component:import_fun(
            {[handle], ?WRITE_RESULT}, fun([H]) -> write_result(flush_stream(H)) end),
      {Streams, <<"[method]output-stream.blocking-flush">>} =>
          wasm_component:import_fun(
            {[handle], ?WRITE_RESULT}, fun([H]) -> write_result(flush_stream(H)) end),
      {Streams, <<"[method]output-stream.write-zeroes">>} =>
          wasm_component:import_fun(
            {[handle, u64], ?WRITE_RESULT},
            fun([H, Len]) -> write_result(write_zeroes(H, Len)) end),
      {Streams, <<"[method]output-stream.blocking-write-zeroes-and-flush">>} =>
          wasm_component:import_fun(
            {[handle, u64], ?WRITE_RESULT},
            fun([H, Len]) -> write_result(and_flush(H, write_zeroes(H, Len))) end),
      {Streams, <<"[method]output-stream.splice">>} =>
          wasm_component:import_fun(
            {[handle, handle, u64], ?COUNT_RESULT},
            fun([Dst, Src, Len]) -> splice_stream(Dst, Src, Len) end),
      {Streams, <<"[method]output-stream.blocking-splice">>} =>
          wasm_component:import_fun(
            {[handle, handle, u64], ?COUNT_RESULT},
            fun([Dst, Src, Len]) -> blocking_splice_stream(Dst, Src, Len) end),
      {Streams, <<"[method]output-stream.subscribe">>} =>
          wasm_component:import_fun({[handle], handle}, Subscribe),
      {Streams, <<"[resource-drop]output-stream">>} =>
          fun(_Ctx, [H]) -> _ = output_drop(H), {ok, []} end,
      {Stdin, <<"get-stdin">>} =>
          wasm_component:import_fun(
            {[], handle}, fun([]) -> wasm_component:host_new(input_stream, Source) end),
      {Streams, <<"[method]input-stream.read">>} =>
          wasm_component:import_fun({[handle, u64], ?READ_RESULT}, Read),
      {Streams, <<"[method]input-stream.blocking-read">>} =>
          wasm_component:import_fun({[handle, u64], ?READ_RESULT}, BlockingRead),
      {Streams, <<"[method]input-stream.skip">>} =>
          wasm_component:import_fun(
            {[handle, u64], ?COUNT_RESULT}, fun([H, Len]) -> skip_stream(H, Len) end),
      {Streams, <<"[method]input-stream.blocking-skip">>} =>
          wasm_component:import_fun(
            {[handle, u64], ?COUNT_RESULT}, fun([H, Len]) -> skip_stream(H, Len) end),
      {Streams, <<"[method]input-stream.subscribe">>} =>
          wasm_component:import_fun({[handle], handle}, Subscribe),
      {Streams, <<"[resource-drop]input-stream">>} =>
          fun(_Ctx, [H]) -> _ = input_drop(H), {ok, []} end,
      %% A clock pollable is ready once its deadline has passed; a stream pollable
      %% is ready when the stream is, which for a socket means data is waiting, so
      %% poll reports neither an unelapsed timer nor a socket with nothing to read.
      {Poll, <<"[method]pollable.ready">>} =>
          wasm_component:import_fun(
            {[handle], bool}, fun([P]) -> pollable_ready(state_of(P)) end),
      {Poll, <<"[method]pollable.block">>} =>
          wasm_component:import_fun(
            {[handle], none}, fun([P]) -> block_pollable(state_of(P)) end),
      {Poll, <<"poll">>} =>
          wasm_component:import_fun(
            {[{list, handle}], {list, u32}},
            %% poll of an empty list would block forever; the WIT requires a trap.
            fun([[]])      -> error(poll_empty_list);
               ([Handles]) -> poll(Handles)
            end),
      {Poll, <<"[resource-drop]pollable">>} => drop_fun(),
      {Error, <<"[method]error.to-debug-string">>} =>
          wasm_component:import_fun({[handle], string}, fun([_E]) -> <<"stream error">> end),
      {Error, <<"[resource-drop]error">>} => drop_fun()}.

drop_fun() ->
    fun(_Ctx, [Handle]) -> _ = wasm_component:host_drop(Handle), {ok, []} end.

%% Dropping an input stream closes the descriptor it owns (a file stream holds its
%% own duplicated handle). A socket stream only borrows the socket's connection,
%% which the socket resource owns and closes, so it is left alone.
input_drop(Handle) ->
    case wasm_component:host_get(Handle) of
        {ok, {input_stream, {file, Fh, _}}} -> _ = wasi_fs:close(Fh);
        _                                   -> ok
    end,
    wasm_component:host_drop(Handle).

%% Dropping an output stream closes the descriptor it owns (a native file stream
%% holds its own duplicated handle). A borrowed handle and a socket connection are
%% owned by the descriptor or socket resource and left alone.
output_drop(Handle) ->
    case wasm_component:host_get(Handle) of
        {ok, {output_stream, {file, own, Fh, _}}}     -> _ = wasi_fs:close(Fh);
        {ok, {output_stream, {file_append, own, Fh}}} -> _ = wasi_fs:close(Fh);
        _                                             -> ok
    end,
    wasm_component:host_drop(Handle).

%% Write to the stream's sink. A write to a handle that is gone is dropped. A
%% file-backed write that fails is reported: the caller mints an error resource.
%% Returns `ok` or `{error, Reason}`.
write_stream(Handle, Bytes) ->
    case wasm_component:host_get(Handle) of
        {ok, {output_stream, {file, Own, Fh, Off}}} ->
            %% A file-backed write stream: pwrite and advance the offset so the
            %% next write continues where this ended.
            case wasi_fs:pwrite(Fh, Off, Bytes) of
                {ok, N}          -> wasm_component:host_update(Handle, {file, Own, Fh, Off + N});
                {error, _} = Err -> Err
            end;
        {ok, {output_stream, {file_append, _Own, Fh}}} ->
            %% Append: write at the current end each time.
            End = case wasi_fs:size(Fh) of {ok, S} -> S; _ -> 0 end,
            case wasi_fs:pwrite(Fh, End, Bytes) of
                {ok, _}          -> ok;
                {error, _} = Err -> Err
            end;
        {ok, {output_stream, {socket, Conn}}} ->
            %% A socket-backed stream: a send to a closed or shut-down peer is the
            %% `closed` stream-error; any other failure is reported as itself.
            case wasi_sock2:send(Conn, Bytes) of
                ok                              -> ok;
                {error, E} when E =:= epipe; E =:= closed; E =:= econnreset;
                                E =:= enotconn; E =:= eshutdown -> {error, closed};
                {error, Errno}                  -> {error, sock2_errno(Errno)}
            end;
        {ok, {output_stream, {http_body, Req}}} ->
            %% An outgoing HTTP request body: append to the request the body
            %% belongs to, so outgoing-handler sends what the guest wrote.
            wasi_http:append_body(Req, Bytes);
        {ok, {output_stream, Sink}} when is_function(Sink) ->
            _ = Sink(Bytes), ok;
        _ ->
            ok
    end.

%% Enforce the permit check-write reports. A write no larger than the budget goes
%% through; a larger one is refused rather than trusted, which also bounds the host
%% allocation a guest can drive.
checked_write(_Handle, Bytes) when byte_size(Bytes) > ?WRITE_BUDGET ->
    {error, exceeds_write_budget};
checked_write(Handle, Bytes) ->
    write_stream(Handle, Bytes).

%% write-zeroes with the same permit, so the host never materialises more than one
%% budget's worth of zeroes for a guest-chosen length.
write_zeroes(_Handle, Len) when Len > ?WRITE_BUDGET ->
    {error, exceeds_write_budget};
write_zeroes(Handle, Len) ->
    write_stream(Handle, binary:copy(<<0>>, Len)).

%% Sequence a write with a flush for the blocking-*-and-flush methods: flush only
%% if the write succeeded.
and_flush(Handle, ok)              -> flush_stream(Handle);
and_flush(_Handle, {error, _} = E) -> E.

%% Move up to `Len` bytes (capped to the permit) from an input stream to an output
%% stream, returning how many moved. splice reads the source non-blocking;
%% blocking-splice waits for at least one byte.
splice_stream(Dst, Src, Len) ->
    splice_with(fun read_stream/2, Dst, Src, Len).

blocking_splice_stream(Dst, Src, Len) ->
    splice_with(fun blocking_read_stream/2, Dst, Src, Len).

splice_with(Read, Dst, Src, Len) ->
    N = min(Len, ?WRITE_BUDGET),
    case Read(Src, N) of
        {ok, Chunk} ->
            case write_stream(Dst, Chunk) of
                ok               -> {ok, byte_size(Chunk)};
                {error, Reason}  -> write_result({error, Reason})
            end;
        {error, _} = E ->
            E
    end.

%% Turn a write result into the WIT `result<_, stream-error>`. A failure mints an
%% error resource and returns the `last-operation-failed` case, mirroring how
%% read_stream reports `closed`.
write_result(ok) ->
    {ok, undefined};
%% A write to a closed or shut-down connection is the `closed` stream-error, not a
%% recoverable failure.
write_result({error, closed}) ->
    {error, {<<"closed">>, undefined}};
write_result({error, Reason}) ->
    {error, {<<"last-operation-failed">>, wasm_component:host_new(error, Reason)}}.

%% Flush a stream. A file-backed stream fsyncs so blocking-flush is durable; a
%% function sink has nothing to flush. A gone handle is a no-op.
flush_stream(Handle) ->
    case wasm_component:host_get(Handle) of
        {ok, {output_stream, {file, _Own, Fh, _Off}}}  -> wasi_fs:sync(Fh);
        {ok, {output_stream, {file_append, _Own, Fh}}} -> wasi_fs:sync(Fh);
        {ok, {output_stream, {socket, Conn}}}          -> socket_open_or_closed(Conn);
        _                                              -> ok
    end.

%% check-write and flush on a socket report `closed` once the send side is shut: a
%% zero-byte probe send fails on a shut or closed connection.
check_write(Handle) ->
    case wasm_component:host_get(Handle) of
        {ok, {output_stream, {socket, Conn}}} ->
            case socket_open_or_closed(Conn) of
                ok             -> {ok, ?WRITE_BUDGET};
                {error, closed} -> {error, {<<"closed">>, undefined}}
            end;
        _ ->
            {ok, ?WRITE_BUDGET}
    end.

socket_open_or_closed(Conn) ->
    case wasi_sock2:send(Conn, <<>>) of
        ok                              -> ok;
        {error, E} when E =:= epipe; E =:= closed; E =:= econnreset;
                        E =:= enotconn; E =:= eshutdown -> {error, closed};
        {error, _}                      -> ok
    end.

%% Close the OS resource a host handle owns, called from teardown for every live
%% handle. Only file descriptors and sockets hold OS state; a clock pollable, a
%% preopen dir root and an error carry none.
%% Vetoes dropping a stream that a pollable still borrows: a `subscribe` mints a
%% pollable holding `{stream, StreamHandle}`, and the Canonical ABI traps rather than
%% leave that pollable pointing at a freed stream. Any other handle drops normally.
-spec stream_predrop(pos_integer()) -> ok | {trap, term()}.
stream_predrop(Handle) ->
    case wasm_component:host_get(Handle) of
        {ok, {input_stream, _}}  -> no_live_pollable(Handle);
        {ok, {output_stream, _}} -> no_live_pollable(Handle);
        _                        -> ok
    end.

no_live_pollable(Handle) ->
    Borrowed = lists:any(
                 fun(H) ->
                     case wasm_component:host_get(H) of
                         {ok, {pollable, {stream, Handle}}} -> true;
                         _                                  -> false
                     end
                 end, wasm_component:host_live()),
    case Borrowed of
        true  -> {trap, stream_dropped_with_live_pollable};
        false -> ok
    end.

-spec close_resource({atom(), term()}) -> ok.
%% A socket-backed stream only borrows its socket's connection, which the
%% tcp_socket resource owns and closes, so it is not closed here.
close_resource({fs_file, {Handle, _Flags}})             -> _ = wasi_fs:close(Handle), ok;
close_resource({fs_dir, {Root, _}})                          -> _ = wasi_fs:forget(Root), ok;
close_resource({output_stream, {file, own, Fh, _}})     -> _ = wasi_fs:close(Fh), ok;
close_resource({output_stream, {file_append, own, Fh}}) -> _ = wasi_fs:close(Fh), ok;
close_resource({input_stream, {file, Handle, _}})       -> _ = wasi_fs:close(Handle), ok;
close_resource({tcp_socket, {_State, Handle}})          -> _ = wasi_sock2:close(Handle), ok;
close_resource({udp_socket, {udp_bound, Sock, _Conn}})  -> _ = wasi_sock2:close(Sock), ok;
close_resource({udp_socket, {_State, Handle}})          -> _ = wasi_sock2:close(Handle), ok;
close_resource(_)                                       -> ok.

%% Non-blocking read: return whatever is available, up to Len bytes, without
%% waiting. On a socket with nothing buffered or waiting this returns an empty
%% chunk (the guest polls, then reads), never blocking for it.
read_stream(Handle, Len) ->
    read_stream(Handle, Len, 0).

%% Blocking read: wait for at least one byte (or end of stream) before returning.
blocking_read_stream(Handle, Len) ->
    read_stream(Handle, Len, ?SOCK_TIMEOUT).

%% An empty in-memory source (drained or unknown handle) reads `closed`, the
%% end-of-stream signal blocking-read waits for. `closed` carries no payload, so no
%% error resource is minted.
read_stream(Handle, Len, Timeout) ->
    case wasm_component:host_get(Handle) of
        {ok, {input_stream, {socket, Sock, Buf}}} ->
            %% A socket-backed stream (from tcp finish-connect/accept). Return up
            %% to Len bytes; buffer any it read past Len so the next read hands
            %% them over.
            socket_read(Handle, Sock, Buf, Len, Timeout);
        {ok, {input_stream, {file, Fh, Off}}} ->
            file_read(Handle, Fh, Off, Len);
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

socket_read(Handle, Sock, Buf, Len, Timeout) ->
    case get({?SHUT_RECV, Sock}) of
        true ->
            %% A socket shut for receiving reads as closed at once, discarding any
            %% buffered bytes (WASI does not drain first after a local shutdown).
            {error, {<<"closed">>, undefined}};
        _ ->
            %% Probe the socket so a peer close is seen, but deliver buffered bytes
            %% before reporting it: a graceful remote close hands over what already
            %% arrived, then closes on the next read. A probe with a buffer present is
            %% non-blocking (the buffer is what a timeout would have returned).
            Probe = case Buf of <<>> -> Timeout; _ -> 0 end,
            case wasi_sock2:recv(Sock, 0, Probe) of
                {ok, Data} ->
                    socket_deliver(Handle, Sock, <<Buf/binary, Data/binary>>, Len);
                eof when Buf =/= <<>> ->
                    socket_deliver(Handle, Sock, Buf, Len);
                eof ->
                    {error, {<<"closed">>, undefined}};
                {error, _} when Buf =/= <<>> ->
                    socket_deliver(Handle, Sock, Buf, Len);
                %% A non-blocking read with nothing waiting is not an error: zero
                %% bytes, so the guest can poll and read again. A blocking read that
                %% timed out reports the stream drained.
                {error, _} when Timeout =:= 0 -> {ok, <<>>};
                {error, _}  -> {error, {<<"closed">>, undefined}}
            end
    end.

socket_deliver(Handle, Sock, Data, Len) ->
    N = min(Len, byte_size(Data)),
    <<Chunk:N/binary, Rest/binary>> = Data,
    _ = wasm_component:host_update(Handle, {socket, Sock, Rest}),
    {ok, Chunk}.

%% Read one chunk of a file-backed input stream, capped to the permit so a huge
%% requested length never materialises more than one chunk. An empty read is EOF,
%% reported as `closed`.
%% A zero-length read is a no-op that returns no bytes, not end-of-stream: only a
%% read that asked for bytes and got none is closed.
file_read(_Handle, _Fh, _Off, 0) ->
    {ok, <<>>};
file_read(Handle, Fh, Off, Len) ->
    case wasi_fs:pread(Fh, Off, min(Len, ?WRITE_BUDGET)) of
        {ok, <<>>}     -> {error, {<<"closed">>, undefined}};
        eof            -> {error, {<<"closed">>, undefined}};
        {ok, Chunk}    ->
            _ = wasm_component:host_update(Handle, {file, Fh, Off + byte_size(Chunk)}),
            {ok, Chunk};
        {error, Errno} ->
            {error, {<<"last-operation-failed">>, wasm_component:host_new(error, Errno)}}
    end.

%% Advance the source by up to Len bytes without returning them, reporting how
%% many were skipped; a drained or unknown stream is `closed`.
skip_stream(Handle, Len) ->
    case wasm_component:host_get(Handle) of
        {ok, {input_stream, {file, Fh, Off}}} ->
            case file_read(Handle, Fh, Off, Len) of
                {ok, Chunk}    -> {ok, byte_size(Chunk)};
                {error, _} = E -> E
            end;
        {ok, {input_stream, {socket, Sock, Buf}}} ->
            %% Skip consumes bytes from the socket rather than reporting closed:
            %% read up to Len and discard, returning how many were consumed.
            case socket_read(Handle, Sock, Buf, Len, 0) of
                {ok, Chunk}    -> {ok, byte_size(Chunk)};
                {error, _} = E -> E
            end;
        {ok, {input_stream, <<>>}} ->
            {error, {<<"closed">>, undefined}};
        {ok, {input_stream, Remaining}} when is_binary(Remaining) ->
            N = min(Len, byte_size(Remaining)),
            <<_Skipped:N/binary, Rest/binary>> = Remaining,
            _ = wasm_component:host_update(Handle, Rest),
            {ok, N};
        _ ->
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
                   writable => boolean(),
                   mounts => [{binary(), file:filename_all(), boolean()}]}) ->
          #{{binary(), binary()} => fun()}.
filesystem(Opts) ->
    Mounts = mounts_of(Opts),
    Types = <<"wasi:filesystem/types">>,
    Preopens = <<"wasi:filesystem/preopens">>,
    #{{Preopens, <<"get-directories">>} =>
          wasm_component:import_fun(
            {[], {list, {tuple, [handle, string]}}},
            fun([]) -> get_directories(Mounts) end),
      %% Map a stream error back to a filesystem error-code. Our stream errors do
      %% not carry one (a filesystem operation reports its code directly), so this
      %% is `none`: the io error was not a filesystem error.
      {Types, <<"filesystem-error-code">>} =>
          wasm_component:import_fun(
            {[handle], {option, ?ERROR_CODE}},
            fun([Err]) ->
                %% A file stream mints its error resource carrying the raw errno,
                %% which maps to a filesystem error-code; anything else is none.
                case wasm_component:host_get(Err) of
                    {ok, {error, Errno}} when is_integer(Errno) ->
                        {some, errno_name(Errno)};
                    _ ->
                        none
                end
            end),
      {Types, <<"[method]descriptor.open-at">>} =>
          wasm_component:import_fun(
            {[handle, ?PATH_FLAGS, string, ?OPEN_FLAGS, ?DESC_FLAGS], ?OPEN_RESULT},
            fun([Dir, PF, Path, OpenFlags, DescFlags]) ->
                open_at(Dir, PF, Path, OpenFlags, DescFlags)
            end),
      {Types, <<"[method]descriptor.write">>} =>
          wasm_component:import_fun(
            {[handle, {list, u8}, u64], {result, u64, ?ERROR_CODE}},
            fun([File, Data, Off]) -> write_at(File, Data, Off) end),
      {Types, <<"[method]descriptor.create-directory-at">>} =>
          wasm_component:import_fun(
            {[handle, string], {result, none, ?ERROR_CODE}},
            fun([Dir, Path]) -> create_directory_at(Dir, Path) end),
      {Types, <<"[method]descriptor.unlink-file-at">>} =>
          wasm_component:import_fun(
            {[handle, string], {result, none, ?ERROR_CODE}},
            fun([Dir, Path]) -> unlink_file_at(Dir, Path) end),
      {Types, <<"[method]descriptor.remove-directory-at">>} =>
          wasm_component:import_fun(
            {[handle, string], {result, none, ?ERROR_CODE}},
            fun([Dir, Path]) -> remove_directory_at(Dir, Path) end),
      {Types, <<"[method]descriptor.rename-at">>} =>
          wasm_component:import_fun(
            {[handle, string, handle, string], {result, none, ?ERROR_CODE}},
            fun([Dir, Path, NewDir, NewPath]) ->
                rename_at(Dir, Path, NewDir, NewPath)
            end),
      {Types, <<"[method]descriptor.symlink-at">>} =>
          wasm_component:import_fun(
            {[handle, string, string], {result, none, ?ERROR_CODE}},
            fun([Dir, OldPath, NewPath]) ->
                symlink_at(Dir, OldPath, NewPath)
            end),
      {Types, <<"[method]descriptor.link-at">>} =>
          wasm_component:import_fun(
            {[handle, ?PATH_FLAGS, string, handle, string],
             {result, none, ?ERROR_CODE}},
            fun([Dir, PathFlags, Path, NewDir, NewPath]) ->
                link_at(Dir, PathFlags, Path, NewDir, NewPath)
            end),
      {Types, <<"[method]descriptor.readlink-at">>} =>
          wasm_component:import_fun(
            {[handle, string], {result, string, ?ERROR_CODE}},
            fun([Dir, Path]) -> readlink_at(Dir, Path) end),
      {Types, <<"[method]descriptor.set-size">>} =>
          wasm_component:import_fun(
            {[handle, u64], {result, none, ?ERROR_CODE}},
            fun([File, Size]) -> set_size(File, Size) end),
      {Types, <<"[method]descriptor.set-times">>} =>
          wasm_component:import_fun(
            {[handle, ?NEW_TIMESTAMP, ?NEW_TIMESTAMP], {result, none, ?ERROR_CODE}},
            fun([H, Atime, Mtime]) -> set_times(H, Atime, Mtime) end),
      {Types, <<"[method]descriptor.set-times-at">>} =>
          wasm_component:import_fun(
            {[handle, ?PATH_FLAGS, string, ?NEW_TIMESTAMP, ?NEW_TIMESTAMP],
             {result, none, ?ERROR_CODE}},
            fun([Dir, PathFlags, Path, Atime, Mtime]) ->
                set_times_at(Dir, PathFlags, Path, Atime, Mtime)
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
            {[handle], ?FLAGS_RESULT}, fun([H]) -> get_flags(H) end),
      {Types, <<"[method]descriptor.metadata-hash">>} =>
          wasm_component:import_fun(
            {[handle], ?METADATA_HASH_RESULT}, fun([H]) -> metadata_hash(H) end),
      {Types, <<"[method]descriptor.write-via-stream">>} =>
          wasm_component:import_fun(
            {[handle, u64], ?OPEN_RESULT},
            fun([H, Off]) -> write_via_stream(H, Off) end),
      {Types, <<"[method]descriptor.append-via-stream">>} =>
          wasm_component:import_fun(
            {[handle], ?OPEN_RESULT}, fun([H]) -> append_via_stream(H) end),
      {Types, <<"[method]directory-entry-stream.read-directory-entry">>} =>
          wasm_component:import_fun(
            {[handle], ?DIR_ENTRY_RESULT},
            fun([Stream]) -> read_directory_entry(Stream) end),
      {Types, <<"[resource-drop]directory-entry-stream">>} =>
          fun(_Ctx, [H]) -> _ = wasm_component:host_drop(H), {ok, []} end,
      {Types, <<"[resource-drop]descriptor">>} =>
          fun(_Ctx, [H]) -> _ = fs_drop(H), {ok, []} end}.

%% The mounts a filesystem slice offers: an explicit list of {name, dir, writable}
%% for several preopens, or the single legacy preopen/name/writable.
mounts_of(Opts) ->
    case maps:find(mounts, Opts) of
        {ok, Mounts} ->
            Mounts;
        error ->
            case maps:find(preopen, Opts) of
                {ok, Dir} -> [{maps:get(name, Opts, <<"/">>), Dir,
                               maps:get(writable, Opts, false)}];
                error     -> []
            end
    end.

%% Each mount becomes one preopened directory descriptor carrying its own
%% writability, so a command can hold a read-only mount and a writable one at once
%% and the mutation gates read the descriptor, not one mount-wide flag.
get_directories(Mounts) ->
    lists:flatmap(
      fun({Name, HostDir, Writable}) ->
          case wasi_fs:preopen(HostDir) of
              {ok, Root} -> [{wasm_component:host_new(fs_dir, {Root, Writable}), Name}];
              {error, _} -> []
          end
      end, Mounts).

%% Open a path under a directory descriptor. Write intent is refused on a
%% read-only filesystem and otherwise turned into open modes. The path is not
%% resolved here: wasi_fs:open/3 applies the same sandbox Preview 1 does.
open_at(Dir, PathFlags, Path, OpenFlags, DescFlags) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, {Root, Writable}}} ->
            case write_intent(OpenFlags, DescFlags) of
                true when not Writable ->
                    %% A descriptor without write rights (a read-only mount) refuses
                    %% a write-intent open as not-permitted, the descriptor-rights
                    %% error, not the read-only-filesystem one.
                    {error, <<"not-permitted">>};
                WantsWrite ->
                    open_target(Root, Writable, PathFlags, Path,
                                OpenFlags, DescFlags, WantsWrite)
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
open_target(_Root, _W, _PathFlags, Path, _OpenFlags, _DescFlags, _WantsWrite)
  when Path =:= <<>> ->
    {error, <<"invalid">>};
open_target(Root, W, PathFlags, Path, OpenFlags, DescFlags, WantsWrite) ->
    case binary:match(Path, <<0>>) of
        nomatch -> open_named(Root, W, PathFlags, Path, OpenFlags, DescFlags, WantsWrite);
        %% A NUL truncates the name in C, so it must be refused, not silently
        %% opening whatever comes before it.
        _       -> {error, <<"invalid">>}
    end.

open_named(Root, W, PathFlags, Path0, OpenFlags, DescFlags, WantsWrite) ->
    %% A trailing slash names a directory: it forces the directory expectation and
    %% is stripped before the name reaches the backend, so a file named with one is
    %% not-directory rather than the backend's mishandling of the slash.
    Slash = trailing_slash(Path0),
    Path = strip_trailing_slashes(Path0),
    WantDir = Slash orelse lists:member(<<"directory">>, OpenFlags),
    Follow = follow_of(PathFlags),
    case wasi_fs:stat(Root, Path, Follow) of
        {ok, #{type := directory}} when WantsWrite ->
            {error, <<"is-directory">>};
        {ok, #{type := directory}} ->
            open_dir(Root, W, Path);
        {ok, _} when WantDir ->
            {error, <<"not-directory">>};
        {ok, _} ->
            open_file(Root, Path, OpenFlags, DescFlags, WantsWrite, Follow);
        {error, Errno} when WantDir ->
            {error, errno_name(Errno)};
        {error, _} ->
            %% Absent (a create) or a symlink stat could not follow: let the open
            %% produce the errno, as Preview 1 hands the name to wasi_fs.
            open_file(Root, Path, OpenFlags, DescFlags, WantsWrite, Follow)
    end.

strip_trailing_slashes(Path) ->
    case trailing_slash(Path) of
        true  -> strip_trailing_slashes(binary:part(Path, 0, byte_size(Path) - 1));
        false -> Path
    end.

open_dir(Root, W, Path) ->
    case wasi_fs:open_dir_at(Root, Path) of
        {ok, SubRoot} -> {ok, wasm_component:host_new(fs_dir, {SubRoot, W})};
        {error, Errno} -> {error, errno_name(Errno)}
    end.

open_file(Root, Path, OpenFlags, DescFlags, WantsWrite, Follow) ->
    Modes = open_modes(OpenFlags, DescFlags, WantsWrite)
        ++ [follow || Follow =:= follow],
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
%% Writability is the file's own: a file opened without the write flag (which a
%% read-only mount never grants) cannot make a write stream.
write_via_stream(File, Off) ->
    case writable_file(File) of
        {ok, Handle}   -> {ok, wasm_component:host_new(output_stream,
                                                       output_file(Handle, {write, Off}))};
        {error, _} = E -> E
    end.

append_via_stream(File) ->
    case writable_file(File) of
        {ok, Handle}   -> {ok, wasm_component:host_new(output_stream,
                                                       output_file(Handle, append))};
        {error, _} = E -> E
    end.

%% A file-backed output stream owns a duplicated descriptor on the native backend,
%% so it outlives the descriptor it was taken from; the fallback cannot duplicate a
%% handle, so it borrows the descriptor's and is closed with it. An append stream
%% carries no offset: each write goes to the current end, so concurrent appends do
%% not overwrite each other.
output_file(Handle, Mode) ->
    {Own, Fh} = case wasi_fs:dup(Handle) of
                    {ok, Dup}  -> {own, Dup};
                    {error, _} -> {borrow, Handle}
                end,
    case Mode of
        {write, Off} -> {file, Own, Fh, Off};
        append       -> {file_append, Own, Fh}
    end.

%% A file that was opened for writing; a read-only descriptor cannot produce a
%% write stream, which is how a write to a read-opened file is refused.
writable_file(File) ->
    case wasm_component:host_get(File) of
        {ok, {fs_file, {Handle, Flags}}} ->
            case lists:member(<<"write">>, Flags) of
                true  -> {ok, Handle};
                %% Opened without write rights: the preview1 fd_write contract
                %% wants a bad descriptor here (the p1->p2 adapter's
                %% path_open_read_write asserts EBADF/ENOTCAPABLE/EACCES), so a
                %% read-only file's write stream is bad-descriptor, not
                %% not-permitted.
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

%% The directory mutations below are gated on the mount being writable, not on a
%% per-descriptor `mutate-directory` right. Enforcing the per-descriptor right is
%% not possible on the preview1-to-preview2 adapter path, which does not request the
%% `mutate-directory` descriptor flag: a native p2 host could enforce it, but doing
%% so here would refuse every adapted preview1 program that mutates a directory. The
%% mount's writable flag is therefore the boundary.
create_directory_at(Dir, Path) ->
    case writable_dir(Dir) of
        {ok, Root}     -> fs_unit(wasi_fs:mkdir(Root, Path));
        {error, _} = E -> E
    end.

unlink_file_at(Dir, Path) ->
    case writable_dir(Dir) of
        {ok, Root} ->
            %% A trailing slash on a name that is not a directory is not-directory;
            %% on a directory, unlink itself reports is-directory / not-permitted.
            case trailing_slash(Path) andalso not is_dir(Root, Path) of
                true  -> {error, <<"not-directory">>};
                false -> fs_unit(wasi_fs:unlink(Root, Path))
            end;
        {error, _} = E ->
            E
    end.

%% A directory descriptor open for mutation: its own mount's writable flag governs
%% here, so a read-only mount refuses while a writable one proceeds, and each
%% descriptor carries the flag it was preopened or opened-at with.
writable_dir(Dir) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, {Root, true}}}   -> {ok, Root};
        {ok, {fs_dir, {_Root, false}}} -> {error, <<"not-permitted">>};
        _                              -> {error, <<"bad-descriptor">>}
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
remove_directory_at(Dir, Path) ->
    case writable_dir(Dir) of
        {ok, Root}     -> fs_unit(wasi_fs:rmdir(Root, Path));
        {error, _} = E -> E
    end.

%% Rename within the sandbox. Both descriptors are directories; a mutation, so both
%% must be writable.
rename_at(Dir, Path, NewDir, NewPath) ->
    with_two_writable_dirs(Dir, NewDir,
                           fun(From, To) ->
                               fs_unit(wasi_fs:rename(From, Path, To, NewPath))
                           end).

%% Create a symlink at NewPath pointing at OldPath. An absolute target is refused
%% at creation, as Preview 1 does, so a symlink can never name outside the sandbox.
symlink_at(_Dir, <<$/, _/binary>>, _NewPath) ->
    {error, <<"access">>};
symlink_at(Dir, OldPath, NewPath) ->
    case trailing_slash(NewPath) of
        %% The link location ending in `/` names a directory that is not there.
        true ->
            {error, <<"no-entry">>};
        false ->
            case writable_dir(Dir) of
                {ok, Root}     -> fs_unit(wasi_fs:symlink(Root, NewPath, OldPath));
                {error, _} = E -> E
            end
    end.

%% Hard-link Path under Dir to NewPath under NewDir. Following the source symlink
%% is rejected as invalid, as Preview 1's path_link does.
link_at(Dir, PathFlags, Path, NewDir, NewPath) ->
    case lists:member(<<"symlink-follow">>, PathFlags) of
        true ->
            {error, <<"invalid">>};
        false ->
            case trailing_slash(NewPath) of
                %% The link location ending in `/` names a directory not there.
                true ->
                    {error, <<"no-entry">>};
                false ->
                    with_two_writable_dirs(
                      Dir, NewDir,
                      fun(From, To) ->
                          fs_unit(wasi_fs:link(From, Path, To, NewPath))
                      end)
            end
    end.

%% Both descriptors must be writable directories for a cross-directory mutation.
with_two_writable_dirs(A, B, Fun) ->
    case {writable_dir(A), writable_dir(B)} of
        {{ok, RA}, {ok, RB}}        -> Fun(RA, RB);
        {{error, _} = E, _}         -> E;
        {_, {error, _} = E}         -> E
    end.

readlink_at(Dir, Path) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, {Root, _}}} ->
            case wasi_fs:readlink(Root, Path) of
                {ok, Target}   -> {ok, Target};
                {error, Errno} -> {error, errno_name(Errno)}
            end;
        _ ->
            {error, <<"bad-descriptor">>}
    end.

set_size(File, Size) ->
    case writable_file(File) of
        {ok, Handle}   -> fs_unit(wasi_fs:truncate(Handle, Size));
        {error, _} = E -> E
    end.

set_times(H, Atime, Mtime) ->
    case wasm_component:host_get(H) of
        {ok, {fs_file, _}} ->
            case writable_file(H) of
                {ok, Handle}   ->
                    fs_unit(wasi_fs:set_times_fd(Handle, new_ts(Atime), new_ts(Mtime)));
                {error, _} = E -> E
            end;
        {ok, {fs_dir, {_, _}}} ->
            case writable_dir(H) of
                {ok, Root}     ->
                    fs_unit(wasi_fs:set_times(Root, <<".">>,
                                              new_ts(Atime), new_ts(Mtime)));
                {error, _} = E -> E
            end;
        _ ->
            {error, <<"bad-descriptor">>}
    end.

set_times_at(Dir, PathFlags, Path, Atime, Mtime) ->
    case writable_dir(Dir) of
        {ok, Root} ->
            fs_unit(wasi_fs:set_times(Root, Path, new_ts(Atime), new_ts(Mtime),
                                      follow_of(PathFlags)));
        {error, _} = E ->
            E
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
        {ok, {fs_dir, {_Root, _}}}   -> {ok, undefined};
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
        {ok, {fs_dir, {Root, _}}}    -> ino_of(wasi_fs:stat(Root, <<".">>));
        error                   -> error
    end.

ino_of({ok, Map})  -> {ok, {maps:get(dev, Map, 0), maps:get(inode, Map, 0)}};
ino_of({error, _}) -> error.

metadata_hash_at(Dir, PathFlags, Path) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, {Root, _}}} ->
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
        {ok, {fs_dir, {_Root, _}}} ->
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
get_flags(H) ->
    case wasm_component:host_get(H) of
        {ok, {fs_file, {_Handle, Flags}}} -> {ok, Flags};
        {ok, {fs_dir, {_Root, W}}}        -> {ok, descriptor_flags(W)};
        _                                 -> {error, <<"bad-descriptor">>}
    end.

%% A stable identity for a descriptor, from its inode; enough for a guest to tell
%% two descriptors apart, which is what metadata-hash is for.
metadata_hash(H) ->
    case wasm_component:host_get(H) of
        {ok, {fs_file, {Handle, _}}} -> from_hash(wasi_fs:stat_fd(Handle));
        {ok, {fs_dir, {Root, _}}}    -> from_hash(wasi_fs:stat(Root, <<".">>));
        error                   -> {error, <<"bad-descriptor">>}
    end.

from_hash({ok, Map}) ->
    {ok, #{<<"lower">> => maps:get(inode, Map, 0), <<"upper">> => 0}};
from_hash({error, Errno}) ->
    {error, errno_name(Errno)}.

stat(H) ->
    case wasm_component:host_get(H) of
        {ok, {fs_file, {Handle, _}}} -> from_stat(wasi_fs:stat_fd(Handle));
        {ok, {fs_dir, {Root, _}}}    -> from_stat(wasi_fs:stat(Root, <<".">>));
        error                   -> {error, <<"bad-descriptor">>}
    end.

stat_at(Dir, PathFlags, Path) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, {Root, _}}} ->
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
%% The stream reads the file lazily, one chunk per read, so a guest reading a
%% small prefix of a large file never makes the host materialise the rest. It
%% duplicates the descriptor's handle (`wasi_fs:dup/1`) and owns the copy, so
%% dropping the descriptor does not close the stream and the stream never touches
%% the descriptor's own fd. The stream closes its handle on drop and teardown.
read_via_stream(File, Off) ->
    %% A directory is not a byte stream: streaming it is is-directory, not a bad
    %% descriptor. Check read permission up front otherwise, before deferring any
    %% I/O: a descriptor with no read right must fail here as a bad descriptor, not
    %% later as a stream error, which is the error code the caller expects and how
    %% the eager read reported it.
    case wasm_component:host_get(File) of
        {ok, {fs_dir, {_, _}}} -> {error, <<"is-directory">>};
        _                 -> read_via_stream_file(File, Off)
    end.

read_via_stream_file(File, Off) ->
    case readable_file(File) of
        {ok, Handle} ->
            case wasi_fs:dup(Handle) of
                {ok, Own} ->
                    %% Native: an owned fd, read lazily one chunk at a time.
                    {ok, wasm_component:host_new(input_stream, {file, Own, Off})};
                {error, _} ->
                    %% Fallback: no safe dup, so read eagerly into a self-contained
                    %% binary rather than hold a re-resolvable pathname.
                    case read_all(Handle, Off, <<>>) of
                        {ok, Bytes}  -> {ok, wasm_component:host_new(input_stream, Bytes)};
                        {error, Errno} -> {error, errno_name(Errno)}
                    end
            end;
        {error, _} = E ->
            E
    end.

%% Read a whole file (from Off) into one binary, for the fallback backend where a
%% lazy stream cannot own an independent descriptor.
read_all(Handle, Off, Acc) ->
    case wasi_fs:pread(Handle, Off, 65536) of
        {ok, <<>>}     -> {ok, Acc};
        eof            -> {ok, Acc};
        {ok, Bin}      -> read_all(Handle, Off + byte_size(Bin), <<Acc/binary, Bin/binary>>);
        {error, Errno} -> {error, Errno}
    end.

readable_file(File) ->
    case wasm_component:host_get(File) of
        {ok, {fs_file, {Handle, Flags}}} ->
            case lists:member(<<"read">>, Flags) of
                true  -> {ok, Handle};
                false -> {error, <<"bad-descriptor">>}
            end;
        _ ->
            {error, <<"bad-descriptor">>}
    end.

read_directory(Dir) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, {Root, _}}} ->
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
    Out = wasm_component:host_new(output_stream, {socket, Conn}),
    {In, Out}.

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

%% Drop a descriptor: close the open file or forget the preopened root, then
%% free the host handle. A double drop or unknown handle is a no-op.
fs_drop(H) ->
    case wasm_component:host_get(H) of
        {ok, {fs_file, {Handle, _}}} -> _ = wasi_fs:close(Handle);
        {ok, {fs_dir, {Root, _}}}    -> _ = wasi_fs:forget(Root);
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
