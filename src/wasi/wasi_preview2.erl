-module(wasi_preview2).
-moduledoc """
The WASI Preview 2 host: the `wasi:*` interfaces a component imports, each
supplied as a host function keyed by `{Interface, Field}` for
`wasm_component:instantiate/2`.

Preview 2 is the component-model side of WASI. A guest imports a world such as
`wasi:random/random` and the host provides every function in it. The functions
map onto the same hardened internals as Preview 1: paths go through `wasi_fs`,
address decisions through `wasi_net`, randomness through
`crypto:strong_rand_bytes/1`.

Keys are the bare interface ids (`wasi:random/random`). A component imports
versioned ids (`wasi:io/streams@0.2.0`), and `wasm_component` strips the
version when it resolves them, so one host serves every `0.2.x`.

| Interface | Built by |
|---|---|
| `wasi:random` | `random/0` |
| `wasi:clocks` | `clocks/0` |
| `wasi:cli/environment` | `environment/0` |
| `wasi:io` streams and `poll` | `io/0`, `poll/1` |
| `wasi:filesystem`, read-only or writable per mount | `wasi_p2_filesystem:filesystem/1` |
| `wasi:sockets`: TCP, UDP, name lookup | `wasi_p2_sockets:sockets/1`, over `wasi_sock2` |
| `wasi:http` | `wasi_http:http/1` |
| a whole `wasi:cli/command` world | `command/1`, run by `run_command/2` |
| one `wasi:http/incoming-handler` request | `run_serve/3` |

`imports/0` is the merged map of the stateless interfaces. `command/1` is the
one to hand a command component: it merges everything above under the grants
in its options. `docs/components.md` shows both from the caller's side.
""".

-include("wasi.hrl").

-export([imports/0, random/0, clocks/0, environment/0, environment/3, io/0, io/1,
         filesystem/1, sockets/1, command/1, run_command/2, run_command/3,
         run_serve/3]).
%% The poll_oneoff readiness logic over host pollable handles, and the monotonic
%% clock its deadlines use, exported so a test can drive poll directly (as
%% host_new/host_get are).
-export([poll/1, monotonic_now/0, next_sleep_ms/1, close_resource/1]).
%% Exported so a test can drive the stream write/read and udp grant paths directly.
-export([write_stream/2, blocking_read_stream/2, datagram_allowed/3,
         peer_matches/3, random_bytes/1]).
%% Exported so a test can mint an output stream and drive the permit contract.
-export([new_output_stream/1, permit_write/2, check_write/1]).

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
            case wasi_p2_sockets:udp_pump(Sock, Peer, Queue, false) of
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
            case wasi_p2_sockets:udp_pump(Sock, Peer, Queue, true) of
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
                network => term(),
                http_transport => module(),
                http_tls => [ssl:tls_client_option()]}) ->
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
    Fs = [wasi_p2_filesystem:filesystem(#{mounts => command_mounts(Opts)})],
    %% Sockets are opt-in: only a caller that passes a network grant gets the
    %% wasi:sockets slice, so the default capability posture is unchanged and a
    %% command that imports no sockets still links.
    Net = case maps:find(network, Opts) of
              {ok, Grant} -> [wasi_p2_sockets:sockets(#{grant => Grant})];
              error       -> []
          end,
    %% wasi:http is always present (like the filesystem) so a reactor that imports
    %% its types links with no mount; outbound requests are gated by the grant, so
    %% without a network grant the types work but a request reaches nowhere.
    Http = [wasi_http:http(#{grant => maps:get(network, Opts, none),
                             transport => maps:get(http_transport, Opts, wasi_http_h1),
                             tls => maps:get(http_tls, Opts, [])})],
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
                    compile => boolean()}) ->
          {ok, #{stdout := binary(), stderr := binary(),
                 exit_code := integer()}} | {error, term()}.
run_command(Bin, Stdin, Extra) ->
    _ = erase(?EXIT_STATUS),
    _ = erase(?INSECURE_SEED),
    OutRef = make_ref(),
    ErrRef = make_ref(),
    Self = self(),
    %% An optional stdout byte limit models a reader that closes the pipe: once the
    %% limit is passed the sink reports closed, which a guest reads as EPIPE.
    Written = counters:new(1, []),
    Limit = maps:get(stdout_limit, Extra, infinity),
    Stdout = fun(B) ->
                 Self ! {OutRef, B},
                 case Limit =/= infinity andalso counters:get(Written, 1) >= Limit of
                     true  -> closed;
                     false -> counters:add(Written, 1, byte_size(B)), ok
                 end
             end,
    %% Stdin redirected from a directory reads as an operation failure, not bytes.
    Source = case maps:get(stdin_dir, Extra, false) of true -> eisdir; false -> Stdin end,
    Opts = (maps:without([compile, stdout_limit, stdin_dir], Extra))#{
             stdin => Source,
             stdout => Stdout,
             stderr => fun(B) -> Self ! {ErrRef, B}, ok end},
    Loader = case maps:get(compile, Extra, false) of true -> compile; false -> load end,
    InstOpts = #{loader => Loader,
                 resource_closer => fun close_resource/1,
                 resource_predrop => fun stream_predrop/1,
                 resource_limit => maps:get(resource_limit, Extra, infinity)},
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
            {[], handle}, fun([]) -> new_output_stream(Sink) end)}.

%% Not a terminal: get-terminal-* report none, so a guest writes plainly. No
%% terminal handle is ever minted, so the resource-drops are unreachable, but a
%% command component imports the terminal-input/terminal-output resources and needs
%% their drop intrinsic to resolve at link time (there are no stubs).
cli_terminals() ->
    #{{<<"wasi:cli/terminal-stdin">>, <<"get-terminal-stdin">>} =>
          wasm_component:import_fun({[], {option, handle}}, fun([]) -> none end),
      {<<"wasi:cli/terminal-stdout">>, <<"get-terminal-stdout">>} =>
          wasm_component:import_fun({[], {option, handle}}, fun([]) -> none end),
      {<<"wasi:cli/terminal-stderr">>, <<"get-terminal-stderr">>} =>
          wasm_component:import_fun({[], {option, handle}}, fun([]) -> none end),
      {<<"wasi:cli/terminal-input">>, <<"[resource-drop]terminal-input">>} => drop_fun(),
      {<<"wasi:cli/terminal-output">>, <<"[resource-drop]terminal-output">>} => drop_fun()}.

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
    %% A plain `write` requires the guest's prior `check-write` permit; the
    %% blocking helper acquires its permit internally, so it just writes and flushes.
    Write = fun([Handle, Bytes]) -> write_result(permit_write(Handle, Bytes)) end,
    BlockingWrite = fun([Handle, Bytes]) ->
                        write_result(and_flush(Handle, write_stream(Handle, Bytes)))
                    end,
    Read = fun([H, Len]) -> read_stream(H, Len) end,
    BlockingRead = fun([H, Len]) -> blocking_read_stream(H, Len) end,
    Subscribe = fun([Stream]) -> wasm_component:host_new(pollable, {stream, Stream}) end,
    #{{Stdout, <<"get-stdout">>} =>
          wasm_component:import_fun(
            {[], handle}, fun([]) -> new_output_stream(Sink) end),
      {Streams, <<"[method]output-stream.check-write">>} =>
          wasm_component:import_fun(
            {[handle], ?COUNT_RESULT}, fun([H]) -> check_write(H) end),
      {Streams, <<"[method]output-stream.write">>} =>
          wasm_component:import_fun({[handle, {list, u8}], ?WRITE_RESULT}, Write),
      {Streams, <<"[method]output-stream.blocking-write-and-flush">>} =>
          wasm_component:import_fun({[handle, {list, u8}], ?WRITE_RESULT}, BlockingWrite),
      {Streams, <<"[method]output-stream.flush">>} =>
          wasm_component:import_fun(
            {[handle], ?WRITE_RESULT}, fun([H]) -> write_result(flush_stream(H)) end),
      {Streams, <<"[method]output-stream.blocking-flush">>} =>
          wasm_component:import_fun(
            {[handle], ?WRITE_RESULT}, fun([H]) -> write_result(flush_stream(H)) end),
      {Streams, <<"[method]output-stream.write-zeroes">>} =>
          wasm_component:import_fun(
            {[handle, u64], ?WRITE_RESULT},
            fun([H, Len]) -> write_result(permit_write_zeroes(H, Len)) end),
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
        {ok, {output_stream, {ostream, _P, _C, {file, own, Fh, _}}}}     -> _ = wasi_fs:close(Fh);
        {ok, {output_stream, {ostream, _P, _C, {file_append, own, Fh}}}} -> _ = wasi_fs:close(Fh);
        _                                                                -> ok
    end,
    wasm_component:host_drop(Handle).

%% Write to the stream's sink. A write to a handle that is gone is dropped. A
%% file-backed write that fails is reported: the caller mints an error resource.
%% Returns `ok` or `{error, Reason}`.
write_stream(Handle, Bytes) ->
    case wasm_component:host_get(Handle) of
        {ok, {output_stream, {ostream, _P, true, _B}}} ->
            %% A stream that has already reported closed stays closed.
            {error, closed};
        {ok, {output_stream, {ostream, P, false, B}}} ->
            case write_backing(Handle, P, B, Bytes) of
                {error, closed} = E ->
                    %% Remember the close so a later check-write reports it too.
                    _ = wasm_component:host_update(Handle, {ostream, 0, true, B}),
                    E;
                Other ->
                    Other
            end;
        _ ->
            ok
    end.

%% Write to a stream's backing, preserving the permit envelope. A file offset
%% advances so the next write continues where this ended. A send to a closed or
%% shut-down peer, or a sink whose reader is gone, is the `closed` stream-error;
%% any other failure is reported as itself.
write_backing(Handle, P, {file, Own, Fh, Off}, Bytes) ->
    case wasi_fs:pwrite(Fh, Off, Bytes) of
        {ok, N} ->
            wasm_component:host_update(Handle, {ostream, P, false, {file, Own, Fh, Off + N}});
        {error, _} = Err ->
            Err
    end;
write_backing(_Handle, _P, {file_append, _Own, Fh}, Bytes) ->
    End = case wasi_fs:size(Fh) of {ok, S} -> S; _ -> 0 end,
    case wasi_fs:pwrite(Fh, End, Bytes) of
        {ok, _}          -> ok;
        {error, _} = Err -> Err
    end;
write_backing(_Handle, _P, {socket, Conn}, Bytes) ->
    case wasi_sock2:send(Conn, Bytes) of
        ok                              -> ok;
        {error, E} when E =:= epipe; E =:= closed; E =:= econnreset;
                        E =:= enotconn; E =:= eshutdown -> {error, closed};
        {error, Errno}                  ->
            {error, wasi_p2_sockets:sock2_errno(Errno)}
    end;
write_backing(_Handle, _P, {http_body, Req}, Bytes) ->
    wasi_http:append_body(Req, Bytes);
write_backing(_Handle, _P, Sink, Bytes) when is_function(Sink) ->
    case Sink(Bytes) of
        closed -> {error, closed};
        _      -> ok
    end.

%% Mint a host output-stream over Backing. wasi-io's `write` requires a permit
%% from a prior `check-write`, so a fresh stream starts with none and is open.
-spec new_output_stream(term()) -> pos_integer().
new_output_stream(Backing) ->
    wasm_component:host_new(output_stream, {ostream, 0, false, Backing}).

%% wasi-io `output-stream.write`: the guest must hold a `check-write` permit at
%% least the size of the write, which the write consumes. Writing with no permit,
%% or beyond it, violates the ABI and traps. A closed stream reports closed.
permit_write(Handle, Bytes) ->
    with_permit(Handle, byte_size(Bytes), fun() -> write_stream(Handle, Bytes) end).

%% write-zeroes carries the same permit. The permit never exceeds the budget, so
%% the materialised run is bounded; `write_zeroes` keeps the ceiling for the gone
%% and blocking (internal-permit) paths.
permit_write_zeroes(Handle, Len) ->
    with_permit(Handle, Len, fun() -> write_zeroes(Handle, Len) end).

write_zeroes(_Handle, Len) when Len > ?WRITE_BUDGET ->
    {error, exceeds_write_budget};
write_zeroes(Handle, Len) ->
    write_stream(Handle, binary:copy(<<0>>, Len)).

%% Consume the write permit for an N-byte write and run it, or trap when the guest
%% has no permit (or asks for more than it holds). A closed stream reports closed
%% without writing; an unknown handle is a no-op, so the write is dropped.
with_permit(Handle, N, Do) ->
    case wasm_component:host_get(Handle) of
        {ok, {output_stream, {ostream, _P, true, _B}}} ->
            {error, closed};
        {ok, {output_stream, {ostream, P, false, B}}} when N =< P ->
            _ = wasm_component:host_update(Handle, {ostream, 0, false, B}),
            Do();
        {ok, {output_stream, {ostream, _P, false, _B}}} ->
            wasm_error:trap(write_without_permit, #{requested => N});
        _ ->
            Do()
    end.

%% Sequence a write with a flush for the blocking-*-and-flush methods: flush only
%% if the write succeeded.
and_flush(Handle, ok)              -> flush_stream(Handle);
and_flush(_Handle, {error, _} = E) -> E.

%% Move up to `Len` bytes (capped to the permit) from an input stream to an output
%% stream, returning how many moved. splice reads the source non-blocking;
%% blocking-splice waits for at least one byte.
%% Plain splice writes to the output like `write`, so it consumes a check-write
%% permit and traps without one; a closed destination reports closed in the
%% result<u64, stream-error> shape. blocking-splice acquires its permit internally.
splice_stream(Dst, Src, Len) ->
    permit_count(
      with_permit(Dst, min(Len, ?WRITE_BUDGET),
                  fun() -> splice_with(fun read_stream/2, Dst, Src, Len) end)).

blocking_splice_stream(Dst, Src, Len) ->
    splice_with(fun blocking_read_stream/2, Dst, Src, Len).

%% with_permit signals a closed stream as the bare `{error, closed}`; splice
%% reports it in the same result<u64, stream-error> shape write_result uses.
permit_count({error, closed}) -> {error, {<<"closed">>, undefined}};
permit_count(Other)           -> Other.

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
        {ok, {output_stream, {ostream, _P, _C, {file, _Own, Fh, _Off}}}}  -> wasi_fs:sync(Fh);
        {ok, {output_stream, {ostream, _P, _C, {file_append, _Own, Fh}}}} -> wasi_fs:sync(Fh);
        {ok, {output_stream, {ostream, _P, _C, {socket, Conn}}}}          -> socket_open_or_closed(Conn);
        _                                                                 -> ok
    end.

%% check-write and flush on a socket report `closed` once the send side is shut: a
%% zero-byte probe send fails on a shut or closed connection.
check_write(Handle) ->
    case wasm_component:host_get(Handle) of
        {ok, {output_stream, {ostream, _P, true, _B}}} ->
            %% A stream that reported closed stays closed.
            {error, {<<"closed">>, undefined}};
        {ok, {output_stream, {ostream, _P, false, B}}} ->
            case backing_open(B) of
                closed ->
                    _ = wasm_component:host_update(Handle, {ostream, 0, true, B}),
                    {error, {<<"closed">>, undefined}};
                open ->
                    %% Grant a budget's worth of permit for the next write.
                    _ = wasm_component:host_update(Handle, {ostream, ?WRITE_BUDGET, false, B}),
                    {ok, ?WRITE_BUDGET}
            end;
        _ ->
            {ok, ?WRITE_BUDGET}
    end.

%% Only a socket-backed stream can be closed before a write is attempted: a shut
%% or dead send side. Every other backing is ready to accept a permit.
backing_open({socket, Conn}) ->
    case socket_open_or_closed(Conn) of
        ok              -> open;
        {error, closed} -> closed
    end;
backing_open(_) -> open.

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
close_resource({fs_file, {Handle, _Flags, _}})             -> _ = wasi_fs:close(Handle), ok;
close_resource({fs_dir, {Root, _}})                          -> _ = wasi_fs:forget(Root), ok;
close_resource({output_stream, {ostream, _P, _C, {file, own, Fh, _}}})     -> _ = wasi_fs:close(Fh), ok;
close_resource({output_stream, {ostream, _P, _C, {file_append, own, Fh}}}) -> _ = wasi_fs:close(Fh), ok;
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
        {ok, {input_stream, eisdir}} ->
            %% Stdin redirected from a directory: a read is a recoverable operation
            %% failure carrying the errno, which filesystem-error-code reads back as
            %% is-directory (not a plain closed stream).
            {error, {<<"last-operation-failed">>, wasm_component:host_new(error, ?EISDIR)}};
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
                {error, Reason} ->
                    socket_read_wait(Handle, Sock, Len, Timeout, Reason)
            end
    end.

%% Nothing was buffered and the recv returned an error. A would-block is not a
%% closed stream: a non-blocking read hands back zero bytes so the guest can poll
%% and read again, and a blocking read keeps waiting for data rather than inventing
%% end-of-stream on its internal timeout (the worker reaper bounds a wedge). Any
%% other errno is a genuine failure and closes the stream.
socket_read_wait(_Handle, _Sock, _Len, 0, Reason) ->
    case would_block(Reason) of
        true  -> {ok, <<>>};
        false -> {error, {<<"closed">>, undefined}}
    end;
socket_read_wait(Handle, Sock, Len, Timeout, Reason) ->
    case would_block(Reason) of
        true  -> socket_read(Handle, Sock, <<>>, Len, Timeout);
        false -> {error, {<<"closed">>, undefined}}
    end.

%% A would-block/timeout means the deadline elapsed with nothing arrived, not that
%% the peer closed. `wasi_sock2:recv` reports a real orderly close as `eof`.
would_block(timeout)     -> true;
would_block(etimedout)   -> true;
would_block(eagain)      -> true;
would_block(ewouldblock) -> true;
would_block(_)           -> false.

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

%%% ------------------------------------------------- filesystem and sockets ---

-doc "`wasi:filesystem`, built by `wasi_p2_filesystem:filesystem/1`.".
-spec filesystem(#{preopen => file:filename_all(), name => binary(),
                   writable => boolean(),
                   mounts => [{binary(), file:filename_all(), boolean()}]}) ->
          #{{binary(), binary()} => fun()}.
filesystem(Opts) ->
    wasi_p2_filesystem:filesystem(Opts).

-doc "`wasi:sockets`, built by `wasi_p2_sockets:sockets/1`.".
-spec sockets(#{grant => term()}) -> #{{binary(), binary()} => fun()}.
sockets(Opts) ->
    wasi_p2_sockets:sockets(Opts).

datagram_allowed(Datagram, Peer, Grant) ->
    wasi_p2_sockets:datagram_allowed(Datagram, Peer, Grant).

peer_matches(Peer, Addr, Port) ->
    wasi_p2_sockets:peer_matches(Peer, Addr, Port).
