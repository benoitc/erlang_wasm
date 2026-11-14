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
          an_aggregate_interface_signature_is_decoded,
          a_wac_composed_component_passes_a_string,
          a_wac_composed_component_passes_a_resource,
          an_async_interface_signature_is_decoded,
          an_async_call_passes_a_stream_and_a_future,
          a_component_cannot_copy_a_tuple_to_itself].

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

%% A real composed component from the toolchain (cargo component + wac plug), not a
%% hand-authored one: `greeter` exports greet(string) -> string, `greetuser` imports it
%% and its `run` calls greet("wasm"). Composed, calling `run` returns "hello, wasm" only
%% if the cross-component call passes a string across the bridge (each side lifting and
%% lowering on its own memory). It imports WASI, supplied by the command bundle.
a_wac_composed_component_passes_a_string(_Config) ->
    {ok, Bin} = file:read_file(fixture_path("composed_greet")),
    %% `loader => compile` builds the many cores inline rather than through the node
    %% cache, whose 50/s load limit a heavy WASI-importing component trips under load.
    {ok, Inst} = wasm_component:instantiate(Bin, wasi_preview2:command(#{}),
                                            #{loader => compile}),
    try
        ?assertEqual({ok, <<"hello, wasm">>},
                     wasm_component:call(Inst, <<"run">>, {[], string}, []))
    after
        wasm_component:destroy(Inst, fun(_) -> ok end)
    end.

%% A resource crosses the component boundary: `counter` exports a counter resource
%% (constructor + increment), `countuser` imports it and its `run` creates a counter(41)
%% and increments it. Composed, `run` returns 42 only if the constructor call bridged to
%% the provider (minting a handle), the handle crossed back to the consumer, and the
%% consumer's increment call bridged that handle back to the provider. The interface
%% function signatures (constructor `(u32) -> own<counter>`, increment
%% `(borrow<counter>) -> u32`) are decoded from the resource type in the type section.
a_wac_composed_component_passes_a_resource(_Config) ->
    {ok, Bin} = file:read_file(fixture_path("composed_counter")),
    %% `loader => compile` (see the string case) keeps this off the rate-limited cache.
    {ok, Inst} = wasm_component:instantiate(Bin, wasi_preview2:command(#{}),
                                            #{loader => compile}),
    try
        ?assertEqual({ok, 42}, wasm_component:call(Inst, <<"run">>, {[], u32}, []))
    after
        wasm_component:destroy(Inst, fun(_) -> ok end)
    end.

%% An async function type (`func async', tag 0x43) decodes as any function
%% type, and a type an instance type takes from the enclosing component
%% (`alias outer') is that component's. Before, the async type was misread as
%% a value type and the outer one was opaque, so a composed handler's `handle'
%% import had no signature and was never bridged.
an_async_interface_signature_is_decoded(_Config) ->
    {ok, <<_:8/binary, Sec/binary>>} = file:read_file(fixture_path("composedasync")),
    Consumer = lists:nth(2, nested_components(Sec)),
    <<_:8/binary, CSec/binary>> = Consumer,
    ?assertEqual({ok, #{<<"local:pipe/svc">> =>
                            #{<<"sum">> => {[{stream, u8}, {future, u32}], u32}}}},
                 wasm_component_types:import_interfaces(CSec)).

%% A call into another component's async export: the consumer writes "abc" to
%% a stream and 7 to a future and passes their readers; the provider reads both
%% and answers 301 only if it reads the very ends the consumer wrote. The
%% provider's task runs in the consumer's frame, where those ends are.
an_async_call_passes_a_stream_and_a_future(_Config) ->
    {ok, Bin} = file:read_file(fixture_path("composedasync")),
    {ok, Inst} = wasm_component:instantiate(Bin, #{}, #{loader => compile}),
    try
        ?assertEqual({ok, 301},
                     wasm_component:call_async(Inst, <<"run">>, {[], u32}, []))
    after
        wasm_component:destroy(Inst)
    end.

%% A component may not read and write one future or stream when what it
%% carries is not a number: the specification's same-instance restriction.
%% `self' writes a tuple to a future it reads itself.
a_component_cannot_copy_a_tuple_to_itself(_Config) ->
    {ok, Bin} = file:read_file(fixture_path("composedasync")),
    {ok, Inst} = wasm_component:instantiate(Bin, #{}, #{loader => compile}),
    try
        ?assertMatch({error, #{class := trap, kind := intra_component_copy}},
                     wasm_component:call_async(Inst, <<"self">>, {[], u32}, []))
    after
        wasm_component:destroy(Inst)
    end.

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
