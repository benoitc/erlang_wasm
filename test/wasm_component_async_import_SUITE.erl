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

all() -> [awaits_an_async_import, awaits_with_a_bigger_value,
          awaits_a_suspending_import].

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

%% The import SUSPENDS: it reports STARTED and completes only after the owner is
%% provably waiting (the wait_hook handshake), delivered as a SUBTASK event that
%% resumes the guest. Runs call_async in its own process (a bare instance is
%% process-scoped, and the test process coordinates the completion).
awaits_a_suspending_import(Config) ->
    Bin = ?config(component, Config),
    Self = self(),
    PFun = fun(#{owner := O, task_ref := R, handle := H}) ->
               Self ! {producer_up, self()},
               receive go -> O ! {async_ready, R, H, subtask_complete} end
           end,
    Imports = #{{<<"local:asyncimp/host">>, <<"compute">>} =>
                    {async_import, {[u32], u32}, fun([X]) -> X * 2 end, {producer, PFun}}},
    spawn(fun() ->
              {ok, Inst} = wasm_component:instantiate(Bin, Imports),
              Res = wasm_component:call_async(Inst, <<"run#call-compute">>,
                                              {[u32], u32}, [21], #{wait_hook => Self}),
              Waits = wasm_async:waits(),
              ok = wasm_component:destroy(Inst),
              Self ! {result, Res, Waits}
          end),
    Prod = receive {producer_up, P} -> P after 5000 -> timeout end,
    receive {async_wait, _, _} -> Prod ! go after 5000 -> Self ! no_wait end,
    ?assertEqual({result, {ok, 43}, 1}, receive R -> R after 8000 -> timeout end).

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
