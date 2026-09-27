-module(wasm_component_compose_SUITE).
-moduledoc """
Component composition: a component that defines and instantiates nested components
and wires their exports together, the shape `wac`/`wasm-compose` produce.

The `composed` fixture defines an inner component (a nested-component section), instantiates
it (a component-instance section), aliases the instance's `run` export and re-exports it.
It has no core module of its own, so running it means the runtime instantiates the nested
component and dispatches the outer export to that sub-instance.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() -> [a_nested_component_is_instantiated_and_its_export_reached].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

%% Calling the outer `run` reaches the inner component's core function (returns 42) only
%% if the runtime decoded the nested-component and component-instance sections,
%% instantiated the nested component, and dispatched the aliased export to it.
%% Fail-first: before composition support, decode returned `{error, no_core_module}`
%% because the composed component has no top-level core module.
a_nested_component_is_instantiated_and_its_export_reached(_Config) ->
    {ok, Bin} = file:read_file(fixture_path("composed")),
    {ok, Inst} = wasm_component:instantiate(Bin),
    ?assertEqual([<<"run">>], wasm_component:exports(Inst)),
    ?assertEqual({ok, 42}, wasm_component:call(Inst, <<"run">>, {[], u32}, [])),
    ok = wasm_component:destroy(Inst).

fixture_path(Name) ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..", "test",
                   "fixtures", "component", Name ++ ".component.wasm"]).
