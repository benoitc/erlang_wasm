-module(wasm_resources_SUITE).
-moduledoc """
The per-component-instance resource handle table.

These drive `wasm_resources` directly (the module behind `wasm_component`'s
resource intrinsics and the composition bridge), pinning the properties the
cross-component ownership transfer relies on: liveness is per instance, dropping
or reading a handle that is not live fails, a handle moves from one instance's
table to another's without the first keeping it, and the current-instance pointer
saves and restores across a nested call.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [tracking_is_per_instance,
     dropping_a_live_handle_succeeds_once,
     reading_a_dead_handle_fails,
     a_transfer_moves_a_handle_between_instances,
     the_current_instance_nests,
     ops_are_lenient_with_no_current].

%% A handle tracked in one instance is not live in another.
tracking_is_per_instance(_Config) ->
    A = wasm_resources:new_instance(),
    B = wasm_resources:new_instance(),
    wasm_resources:with_instance(A, fun() -> wasm_resources:track(7, 0) end),
    ?assert(wasm_resources:has(A, 7)),
    ?assertNot(wasm_resources:has(B, 7)),
    wasm_resources:with_instance(B, fun() -> ?assertEqual(error, wasm_resources:lookup(7)) end),
    wasm_resources:destroy_instance(A),
    wasm_resources:destroy_instance(B).

%% A live handle drops once; dropping it again is a miss.
dropping_a_live_handle_succeeds_once(_Config) ->
    A = wasm_resources:new_instance(),
    wasm_resources:with_instance(
      A,
      fun() ->
          wasm_resources:track(9, 1),
          ?assertEqual({ok, own}, wasm_resources:drop(9)),
          ?assertEqual(error, wasm_resources:drop(9))
      end),
    wasm_resources:destroy_instance(A).

%% Reading a handle that was never tracked, or was dropped, is a miss.
reading_a_dead_handle_fails(_Config) ->
    A = wasm_resources:new_instance(),
    wasm_resources:with_instance(
      A,
      fun() ->
          ?assertEqual(error, wasm_resources:lookup(123)),
          wasm_resources:track(123, 2),
          ?assertEqual({ok, 2}, wasm_resources:lookup(123)),
          {ok, own} = wasm_resources:drop(123),
          ?assertEqual(error, wasm_resources:lookup(123))
      end),
    wasm_resources:destroy_instance(A).

%% Moving a handle out of one instance and into another leaves it live only in the
%% second: an own transferred across a component boundary is invalidated at the
%% sender. `destroy_instance` of one does not disturb the other.
a_transfer_moves_a_handle_between_instances(_Config) ->
    A = wasm_resources:new_instance(),
    B = wasm_resources:new_instance(),
    wasm_resources:with_instance(A, fun() -> wasm_resources:track(5, 3) end),
    ?assertEqual({ok, 3}, wasm_resources:take(A, 5)),
    ?assertNot(wasm_resources:has(A, 5)),
    ?assertEqual(error, wasm_resources:take(A, 5)),
    wasm_resources:add(B, 5, 3, own),
    ?assert(wasm_resources:has(B, 5)),
    wasm_resources:destroy_instance(A),
    ?assert(wasm_resources:has(B, 5)),
    wasm_resources:destroy_instance(B).

%% A nested call sets its own current and restores the caller's afterwards.
the_current_instance_nests(_Config) ->
    A = wasm_resources:new_instance(),
    B = wasm_resources:new_instance(),
    wasm_resources:with_instance(
      A,
      fun() ->
          ?assertEqual(A, wasm_resources:current()),
          wasm_resources:with_instance(B, fun() -> ?assertEqual(B, wasm_resources:current()) end),
          ?assertEqual(A, wasm_resources:current())
      end),
    ?assertEqual(undefined, wasm_resources:current()),
    wasm_resources:destroy_instance(A),
    wasm_resources:destroy_instance(B).

%% With no instance current the operations are lenient pass-throughs, so a path
%% that never set one behaves as before.
ops_are_lenient_with_no_current(_Config) ->
    ?assertEqual(undefined, wasm_resources:current()),
    ?assertEqual(ok, wasm_resources:track(1, 0)),
    ?assertEqual({ok, undefined}, wasm_resources:lookup(1)),
    ?assertEqual({ok, own}, wasm_resources:drop(1)).
