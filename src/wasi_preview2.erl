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

Worlds land one at a time: `wasi:random`, then `wasi:clocks`. Keys are the
bare, unversioned interface ids (`wasi:random/random`); matching a versioned
`@0.2.x` import is a later step.
""".

-export([imports/0, random/0, clocks/0]).

-doc "Every implemented `wasi:*` interface, merged into one imports map.".
-spec imports() -> #{{binary(), binary()} => fun()}.
imports() ->
    maps:merge(random(), clocks()).

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
