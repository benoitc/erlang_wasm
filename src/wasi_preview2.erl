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
and the output side of `wasi:io`. Keys are the bare, unversioned interface ids
(`wasi:random/random`); matching a versioned `@0.2.x` import is a later step.
""".

-export([imports/0, random/0, clocks/0, environment/0, io/0, io/1]).

%% result<_, stream-error>, the result every output-stream method returns. The
%% error arm names an `error` resource (a handle); we only ever return ok, so no
%% error handle is minted, but the layout must be expressible so the ok result
%% pads its payload area.
-define(STREAM_ERROR,
        {variant, [{<<"last-operation-failed">>, handle}, {<<"closed">>, none}]}).
-define(WRITE_RESULT, {result, none, ?STREAM_ERROR}).

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
The output side of `wasi:io`: `wasi:cli/stdout.get-stdout` mints a host-owned
`output-stream`, `blocking-write-and-flush` writes its bytes to the stream's
sink, and the `[resource-drop]` intrinsics free the host handle. The default
sink discards, so a guest never writes to the node's own stdout.
""".
-spec io() -> #{{binary(), binary()} => fun()}.
io() ->
    io(fun(_Bytes) -> ok end).

-doc "The output side of `wasi:io` with `Sink` receiving every written chunk.".
-spec io(fun((binary()) -> ok)) -> #{{binary(), binary()} => fun()}.
io(Sink) ->
    Streams = <<"wasi:io/streams">>,
    Error = <<"wasi:io/error">>,
    Stdout = <<"wasi:cli/stdout">>,
    #{{Stdout, <<"get-stdout">>} =>
          wasm_component:import_fun(
            {[], handle}, fun([]) -> wasm_component:host_new(output_stream, Sink) end),
      {Streams, <<"[method]output-stream.blocking-write-and-flush">>} =>
          wasm_component:import_fun(
            {[handle, {list, u8}], ?WRITE_RESULT},
            fun([Handle, Bytes]) -> write_stream(Handle, Bytes), {ok, undefined} end),
      {Streams, <<"[resource-drop]output-stream">>} =>
          fun(_Ctx, [Handle]) -> _ = wasm_component:host_drop(Handle), {ok, []} end,
      {Error, <<"[resource-drop]error">>} =>
          fun(_Ctx, [Handle]) -> _ = wasm_component:host_drop(Handle), {ok, []} end}.

%% Write to the stream's sink. A write to a handle that is gone is dropped; a
%% real closed-stream error waits for the error resource.
write_stream(Handle, Bytes) ->
    case wasm_component:host_get(Handle) of
        {ok, {output_stream, Sink}} -> _ = Sink(Bytes), ok;
        error -> ok
    end.
