-module(wasm_component_link_SUITE).
-moduledoc """
A component whose cores feed each other links core to core.

`twocore` is a hand-authored component with two cores: a small provider core that
exports `foo`, and a larger entry core that imports `foo` from it and exports
`run`. Its import is not a WASI name, so binding by host name (the single-core
path) cannot satisfy it (`unknown import {a, foo}`); only wiring one core's import
to another core's export runs it. This suite pins that: the entry returns the
value it got across the core boundary, and every core is freed on destroy.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [links_a_cross_core_import,
     frees_every_core_on_destroy,
     an_unbound_host_import_is_named].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

%% The entry core's `run` calls `foo`, which lives in the other core; it returns
%% 42 only if the linker wired the two cores together.
links_a_cross_core_import(_Config) ->
    {ok, Inst} = wasm_component:instantiate(component(), #{}),
    ?assertEqual({ok, 42}, wasm_component:call(Inst, ~"run", {[], u32}, [])),
    ok = wasm_component:destroy(Inst).

%% Both cores are built, so both are freed.
frees_every_core_on_destroy(_Config) ->
    {ok, Inst} = wasm_component:instantiate(component(), #{}),
    ?assertEqual(2, length(maps:get(cores, Inst))),
    ok = wasm_component:destroy(Inst).

%% A real component needs its WASI imports supplied. Instantiated with none, the
%% error names an import that was left unbound (interface and method), rather than
%% a generic link failure, so the caller can see what to provide.
an_unbound_host_import_is_named(_Config) ->
    {ok, Bin} = file:read_file(real_path()),
    {error, {unresolved_import, {Iface, Method}}} =
        wasm_component:instantiate(Bin, #{}),
    ?assert(is_binary(Iface) andalso byte_size(Iface) > 0),
    ?assert(is_binary(Method) andalso byte_size(Method) > 0).

component() ->
    {ok, Bin} = file:read_file(path()),
    Bin.

real_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "realupper.component.wasm"]).

path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "twocore.component.wasm"]).
