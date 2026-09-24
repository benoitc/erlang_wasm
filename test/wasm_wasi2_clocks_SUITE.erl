-module(wasm_wasi2_clocks_SUITE).
-moduledoc """
A component that imports the `wasi:clocks` world runs against the Preview 2 host
(`wasi_preview2:clocks/0`).

The guest imports `wasi:clocks/monotonic-clock` and `wasi:clocks/wall-clock` and
re-exports each function (see `scripts/build-component-fixture.sh`). Wall time
comes back as a `datetime` record, so these cases exercise a record result
crossing the Canonical ABI in both directions: the host lowers it into the
guest's memory, the guest lifts it, returns it, and the call lifts it again.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(MONO, <<"wasi:clocks/monotonic-clock">>).
-define(WALL, <<"wasi:clocks/wall-clock">>).
-define(DATETIME, {record, [{<<"seconds">>, u64}, {<<"nanoseconds">>, u32}]}).

all() ->
    [the_wall_clock_is_a_plausible_time,
     the_monotonic_clock_does_not_go_backward,
     a_fixed_clock_reaches_the_guest,
     poll_reports_ready_pollables_and_not_an_unelapsed_clock,
     poll_over_only_a_clock_waits_for_its_deadline].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture_path()),
    [{component, Bin} | Config].

end_per_suite(_Config) -> ok.

%% The record's fields land in the right slots: seconds is a real epoch time
%% (past 2023-11-14) and nanoseconds is a sub-second remainder. A swapped or
%% misaligned field would put a tiny number in seconds or an out-of-range one in
%% nanoseconds, so this can fail.
the_wall_clock_is_a_plausible_time(Config) ->
    {ok, I} = instance(Config, wasi_preview2:clocks()),
    #{<<"seconds">> := S, <<"nanoseconds">> := N} = wall_now(I),
    ?assert(S > 1700000000),
    ?assert(N >= 0 andalso N < 1000000000).

%% Monotonic now/0 is non-decreasing and resolution is a positive duration.
the_monotonic_clock_does_not_go_backward(Config) ->
    {ok, I} = instance(Config, wasi_preview2:clocks()),
    A = mono_now(I),
    B = mono_now(I),
    ?assert(B >= A),
    ?assert(mono_res(I) > 0).

%% poll reports the always-ready pollables and skips a clock whose deadline is
%% still in the future -- the filtering that stops poll_oneoff from reporting a
%% timer that has not fired. A clock already past is reported.
poll_reports_ready_pollables_and_not_an_unelapsed_clock(_Config) ->
    Now = wasi_preview2:monotonic_now(),
    Future = wasm_component:host_new(pollable, {clock, Now + 10 * 1000000000}),
    Stream = wasm_component:host_new(pollable, ready),
    Past = wasm_component:host_new(pollable, {clock, Now - 1000000}),
    ?assertEqual([1, 2], wasi_preview2:poll([Future, Stream, Past])).

%% With nothing ready, poll waits for the earliest deadline rather than returning
%% an empty set, then reports the clock that elapsed.
poll_over_only_a_clock_waits_for_its_deadline(_Config) ->
    Now = wasi_preview2:monotonic_now(),
    Clock = wasm_component:host_new(pollable, {clock, Now + 40 * 1000000}),
    T0 = erlang:monotonic_time(millisecond),
    ?assertEqual([0], wasi_preview2:poll([Clock])),
    ?assert(erlang:monotonic_time(millisecond) - T0 >= 30).

%% A fixed clock proves the record round-trip deterministically: a host that
%% returns a known datetime and a known instant must reach the guest unchanged.
a_fixed_clock_reaches_the_guest(Config) ->
    DT = #{<<"seconds">> => 1234567890, <<"nanoseconds">> => 987654321},
    Instant = 42424242,
    Fixed = #{{?MONO, <<"now">>} =>
                  wasm_component:import_fun({[], u64}, fun([]) -> Instant end),
              {?MONO, <<"resolution">>} =>
                  wasm_component:import_fun({[], u64}, fun([]) -> 7 end),
              {?WALL, <<"now">>} =>
                  wasm_component:import_fun({[], ?DATETIME}, fun([]) -> DT end),
              {?WALL, <<"resolution">>} =>
                  wasm_component:import_fun({[], ?DATETIME}, fun([]) -> DT end)},
    {ok, I} = instance(Config, Fixed),
    ?assertEqual(DT, wall_now(I)),
    ?assertEqual(Instant, mono_now(I)),
    ?assertEqual(7, mono_res(I)).

%%% -------------------------------------------------------------- helpers ---

wall_now(I) ->
    {ok, V} = wasm_component:call(I, <<"wall-now">>, {[], ?DATETIME}, []),
    V.

mono_now(I) ->
    {ok, V} = wasm_component:call(I, <<"mono-now">>, {[], u64}, []),
    V.

mono_res(I) ->
    {ok, V} = wasm_component:call(I, <<"mono-res">>, {[], u64}, []),
    V.

instance(Config, Imports) ->
    wasm_component:instantiate(?config(component, Config), Imports).

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "wasiclocks.component.wasm"]).
