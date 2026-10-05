-module(wasm_resources_SUITE).
-moduledoc """
The per-component-instance resource handle table.

These drive `wasm_resources` directly (the module behind `wasm_component`'s
resource built-ins, its host boundary and the composition bridge), pinning the
properties those rely on: a handle is a small index the table mints, liveness is
per instance, using a handle that is not live or not held by the side using it
traps, a handle of another type traps, a handle passes between the guest and the
host, and the current-instance pointer saves and restores across a nested call.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(NOT_LIVE(Op),
        {wasm_error, #{class := trap, kind := resource_not_live,
                       ctx := #{operation := Op}}}).

all() ->
    [handles_are_small_and_never_reused,
     tracking_is_per_instance,
     dropping_a_live_handle_succeeds_once,
     reading_a_dead_handle_fails,
     a_handle_of_another_type_is_refused,
     a_handle_passes_between_guest_and_host,
     a_lent_handle_cannot_be_dropped,
     a_remote_handle_is_released_on_drop,
     destroying_one_instance_leaves_another,
     the_current_instance_nests,
     ops_are_lenient_with_no_current].

%% The table mints 1, 2, ... and does not hand a dropped index out again.
handles_are_small_and_never_reused(_Config) ->
    A = wasm_resources:new_instance(),
    wasm_resources:with_instance(
      A,
      fun() ->
          ?assertEqual(1, wasm_resources:new(0, 1114120)),
          ?assertEqual(2, wasm_resources:new(0, 1114136)),
          ?assertEqual(1114120, wasm_resources:drop(0, 1)),
          ?assertEqual(3, wasm_resources:new(0, 1114120))
      end),
    wasm_resources:destroy_instance(A).

%% A handle minted in one instance is not live in another.
tracking_is_per_instance(_Config) ->
    A = wasm_resources:new_instance(),
    B = wasm_resources:new_instance(),
    H = wasm_resources:with_instance(A, fun() -> wasm_resources:new(0, 7) end),
    ?assertEqual([{H, 0, guest}], wasm_resources:live(A)),
    ?assertEqual([], wasm_resources:live(B)),
    wasm_resources:with_instance(
      B,
      fun() ->
          ?assertEqual(error, wasm_resources:lookup(H)),
          ?assertThrow(?NOT_LIVE(rep), wasm_resources:rep(0, H))
      end),
    wasm_resources:with_instance(
      A, fun() -> ?assertEqual({ok, {0, 7}}, wasm_resources:lookup(H)) end),
    wasm_resources:destroy_instance(A),
    wasm_resources:destroy_instance(B).

%% A live handle drops once, answering its representation for the destructor;
%% dropping it again traps.
dropping_a_live_handle_succeeds_once(_Config) ->
    A = wasm_resources:new_instance(),
    wasm_resources:with_instance(
      A,
      fun() ->
          H = wasm_resources:new(1, 9),
          ?assertEqual(9, wasm_resources:drop(1, H)),
          ?assertThrow({wasm_error,
                        #{ctx := #{handle := H, operation := drop}}},
                       wasm_resources:drop(1, H))
      end),
    wasm_resources:destroy_instance(A).

%% Reading a handle that was never minted, or was dropped, traps.
reading_a_dead_handle_fails(_Config) ->
    A = wasm_resources:new_instance(),
    wasm_resources:with_instance(
      A,
      fun() ->
          ?assertThrow(?NOT_LIVE(rep), wasm_resources:rep(2, 1)),
          H = wasm_resources:new(2, 123),
          ?assertEqual(123, wasm_resources:rep(2, H)),
          123 = wasm_resources:drop(2, H),
          ?assertThrow(?NOT_LIVE(rep), wasm_resources:rep(2, H))
      end),
    wasm_resources:destroy_instance(A).

%% A handle of one type where another is expected traps, naming both; liveness
%% alone (`undefined`) accepts it; an imported handle never matches a local
%% type.
a_handle_of_another_type_is_refused(_Config) ->
    A = wasm_resources:new_instance(),
    wasm_resources:with_instance(
      A,
      fun() ->
          H = wasm_resources:new(0, 5),
          ?assertThrow({wasm_error, #{kind := resource_wrong_type,
                                      ctx := #{expected := 1, actual := 0}}},
                       wasm_resources:rep(1, H)),
          ?assertEqual(5, wasm_resources:rep(undefined, H)),
          R = wasm_resources:new(imported, {remote, A, 1, fun() -> ok end}),
          ?assertThrow({wasm_error, #{kind := resource_wrong_type,
                                      ctx := #{actual := imported}}},
                       wasm_resources:rep(0, R))
      end),
    ?assertThrow({wasm_error, #{kind := resource_wrong_type}},
                 wasm_resources:host_receive(A, 1, 1)),
    wasm_resources:destroy_instance(A).

%% An own the guest returns passes to the host: the guest can no longer use it,
%% the host can. Given back, it is the guest's again and the host's checks fail.
a_handle_passes_between_guest_and_host(_Config) ->
    A = wasm_resources:new_instance(),
    H = wasm_resources:with_instance(A, fun() -> wasm_resources:new(0, 50) end),
    ?assertEqual(H, wasm_resources:host_receive(A, 0, H)),
    ?assertEqual([{H, 0, host}], wasm_resources:live(A)),
    wasm_resources:with_instance(
      A, fun() -> ?assertThrow(?NOT_LIVE(drop), wasm_resources:drop(0, H)) end),
    ?assertThrow(?NOT_LIVE(return), wasm_resources:host_receive(A, 0, H)),
    ?assertEqual({ok, {0, 50}}, wasm_resources:host_lookup(A, H)),
    ?assertEqual(H, wasm_resources:host_give(A, 0, H)),
    ?assertEqual(error, wasm_resources:host_lookup(A, H)),
    ?assertThrow(?NOT_LIVE(borrow), wasm_resources:host_lend(A, 0, H)),
    ?assertThrow(?NOT_LIVE(drop), wasm_resources:host_drop(A, 0, H)),
    wasm_resources:with_instance(
      A, fun() -> ?assertEqual(50, wasm_resources:rep(0, H)) end),
    wasm_resources:destroy_instance(A).

%% A borrow lends the representation for a call; the host cannot drop a handle
%% while it is lent, and can once every loan has ended.
a_lent_handle_cannot_be_dropped(_Config) ->
    A = wasm_resources:new_instance(),
    H = wasm_resources:with_instance(A, fun() -> wasm_resources:new(0, 60) end),
    H = wasm_resources:host_receive(A, 0, H),
    ?assertEqual(60, wasm_resources:host_lend(A, 0, H)),
    ?assertEqual(60, wasm_resources:host_lend(A, 0, H)),
    ?assertEqual([{H, 0, {lent, 2}}], wasm_resources:live(A)),
    ?assertThrow({wasm_error, #{kind := resource_borrowed}},
                 wasm_resources:host_drop(A, 0, H)),
    ok = wasm_resources:host_unlend(A, H),
    ok = wasm_resources:host_unlend(A, H),
    ?assertEqual(60, wasm_resources:host_drop(A, 0, H)),
    ?assertEqual([], wasm_resources:live(A)),
    wasm_resources:destroy_instance(A).

%% A handle that stands for another instance's resource is released there when
%% the guest drops it, and the drop answers `remote` (no local destructor). A
%% `take` moves it on without releasing.
a_remote_handle_is_released_on_drop(_Config) ->
    A = wasm_resources:new_instance(),
    Self = self(),
    Release = fun() -> Self ! released, ok end,
    wasm_resources:with_instance(
      A,
      fun() ->
          R = wasm_resources:new(imported, {remote, 99, 4, Release}),
          ?assertEqual(remote, wasm_resources:drop(undefined, R)),
          receive released -> ok after 0 -> ct:fail(not_released) end,
          M = wasm_resources:new(imported, {remote, 99, 5, Release}),
          ok = wasm_resources:take(M),
          ?assertEqual(error, wasm_resources:lookup(M)),
          receive released -> ct:fail(released_on_take) after 0 -> ok end
      end),
    wasm_resources:destroy_instance(A).

%% Destroying one instance discards its table and leaves another's untouched;
%% a late write to the destroyed one does not bring it back.
destroying_one_instance_leaves_another(_Config) ->
    A = wasm_resources:new_instance(),
    B = wasm_resources:new_instance(),
    wasm_resources:with_instance(A, fun() -> wasm_resources:new(3, 1) end),
    HB = wasm_resources:with_instance(B, fun() -> wasm_resources:new(3, 2) end),
    wasm_resources:destroy_instance(A),
    ?assertNot(wasm_resources:exists(A)),
    ok = wasm_resources:host_unlend(A, 1),
    ?assertNot(wasm_resources:exists(A)),
    ?assertEqual([{HB, 3, guest}], wasm_resources:live(B)),
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

%% With no instance current the guest-side operations are pass-throughs (the
%% handle is the representation), so a path that never set one behaves as
%% before.
ops_are_lenient_with_no_current(_Config) ->
    ?assertEqual(undefined, wasm_resources:current()),
    ?assertEqual(7, wasm_resources:new(0, 7)),
    ?assertEqual(7, wasm_resources:rep(0, 7)),
    ?assertEqual(7, wasm_resources:drop(0, 7)),
    ?assertEqual(error, wasm_resources:lookup(7)).
