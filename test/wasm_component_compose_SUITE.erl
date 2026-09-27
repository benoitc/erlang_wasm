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

all() -> [a_nested_component_is_instantiated_and_its_export_reached,
          a_cross_component_call_bridges_to_the_provider,
          an_interface_import_signature_is_decoded,
          an_aggregate_interface_signature_is_decoded].

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

%% Cross-component data flow: the consumer imports interface `host:math/ops` and its `run`
%% calls add(20, 22); composed, that import is wired to the provider's export. Calling the
%% outer `run` returns 42 only if a cross-component call bridged the consumer's core import
%% to the provider's lifted export, deriving the func signature from the type section.
%% Fail-first: before composition, instantiate failed on the instance-sort alias, and
%% before the bridge the consumer's import was unresolved.
a_cross_component_call_bridges_to_the_provider(_Config) ->
    {ok, Bin} = file:read_file(fixture_path("composedcall")),
    {ok, Inst} = wasm_component:instantiate(Bin),
    ?assertEqual({ok, 42}, wasm_component:call(Inst, <<"run">>, {[], u32}, [])),
    ok = wasm_component:destroy(Inst).

%% The bridge needs each interface function's signature, decoded from the component type
%% section. The consumer imports `host:math/ops` with `add: func(u32, u32) -> u32`.
an_interface_import_signature_is_decoded(_Config) ->
    {ok, Bin} = file:read_file(fixture_path("composedcall")),
    <<_:8/binary, Sec/binary>> = Bin,
    %% The consumer is the second nested component; decode its import signatures.
    Consumer = lists:nth(2, nested_components(Sec)),
    <<_:8/binary, CSec/binary>> = Consumer,
    ?assertEqual({ok, #{<<"host:math/ops">> => #{<<"add">> => {[u32, u32], u32}}}},
                 wasm_component_types:import_interfaces(CSec)).

%% Rich value types decode too: an interface with aggregate parameters/results resolves
%% to nested descriptors, including type references into the type space. `wasi:cli/
%% environment`'s `get-environment` returns `list<tuple<string, string>>`. Fail-first:
%% only the primitives were decoded, so an aggregate was `{error, unsupported_valtype}`.
an_aggregate_interface_signature_is_decoded(_Config) ->
    {ok, <<_:8/binary, Sec/binary>>} = file:read_file(fixture_path("wasienv")),
    {ok, Ifaces} = wasm_component_types:import_interfaces(Sec),
    Env = maps:get(<<"wasi:cli/environment">>, Ifaces),
    ?assertEqual({[], {list, {tuple, [string, string]}}},
                 maps:get(<<"get-environment">>, Env)),
    ?assertEqual({[], {option, string}}, maps:get(<<"initial-cwd">>, Env)).

%% The raw bytes of each nested component (section id 4) in a component's section stream.
nested_components(<<Id, Rest0/binary>>) ->
    {Size, Rest1} = wasm_leb128:u32(Rest0),
    <<Content:Size/binary, Rest2/binary>> = Rest1,
    case Id of
        4 -> [Content | nested_components(Rest2)];
        _ -> nested_components(Rest2)
    end;
nested_components(<<>>) ->
    [].

fixture_path(Name) ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..", "test",
                   "fixtures", "component", Name ++ ".component.wasm"]).
