-module(wasm_component_async_import_SUITE).
-moduledoc """
An async guest that awaits an async host import (caller-side async Canonical ABI).

The fixture (`scripts/build-component-fixture.sh`, `asyncimp`) imports
`compute: async func(u32) -> u32` and exports `call-compute: async func(u32) -> u32`
implemented as `compute(x).await + 1`. The host supplies `compute` as an async import
(registered `{async_import, Sig, Fun}`); the guest lowers the call through `canon lower`
with the async option, which returns a subtask. This host completes the import
synchronously (the subtask reports RETURNED at once), so the guest reads the result and
runs to `task.return` without suspending; a host import that suspends and completes
later is a further milestone.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() -> [awaits_an_async_import, awaits_with_a_bigger_value].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture_path()),
    [{component, Bin} | Config].

end_per_suite(_Config) -> ok.

init_per_testcase(_Case, Config) ->
    {ok, Inst} = wasm_component:instantiate(?config(component, Config), imports()),
    [{inst, Inst} | Config].

end_per_testcase(_Case, Config) ->
    ok = wasm_component:destroy(?config(inst, Config)).

%%% --------------------------------------------------------------- cases ---

%% The guest awaits `compute(x)` (which doubles) and adds one.
awaits_an_async_import(Config) ->
    ?assertEqual({ok, 43}, call_compute(Config, 21)),
    ?assertEqual({ok, 1}, call_compute(Config, 0)).

%% A value whose double exceeds the signed-32 range round-trips as unsigned.
awaits_with_a_bigger_value(Config) ->
    ?assertEqual({ok, 4000000001}, call_compute(Config, 2000000000)).

%%% --------------------------------------------------------------- helpers ---

call_compute(Config, X) ->
    wasm_component:call_async(?config(inst, Config), <<"run#call-compute">>,
                              {[u32], u32}, [X]).

%% The host implementation of the imported async `compute`: it doubles its argument.
imports() ->
    #{{<<"local:asyncimp/host">>, <<"compute">>} =>
          {async_import, {[u32], u32}, fun([X]) -> (X * 2) rem 4294967296 end}}.

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "asyncimp.component.wasm"]).
