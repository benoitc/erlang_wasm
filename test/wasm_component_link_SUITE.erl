-module(wasm_component_link_SUITE).
-moduledoc """
A component whose cores feed each other links core to core.

`twocore` is a hand-authored component with two cores: a small provider core that
exports `foo`, and a larger entry core that imports `foo` from it and exports
`run`. Its import is not a WASI name, so binding by host name (the single-core
path) cannot satisfy it (`unknown import {a, foo}`); only wiring one core's import
to another core's export runs it. This suite pins that: the entry returns the
value it got across the core boundary, every core is freed on destroy, a link that
fails partway frees the cores it had already built, and destroy closes the host
resources an instance still holds.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [links_a_cross_core_import,
     frees_every_core_on_destroy,
     an_unbound_host_import_is_named,
     a_failed_link_frees_the_cores_it_built,
     a_malformed_component_link_leaks_no_cores,
     destroy_closes_host_resources_and_clears_the_tables].

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

%% When a later core fails to instantiate, the cores the linker already built must
%% be freed, not leaked. `twocore_trap` builds its provider core, then traps in the
%% entry core's start function. A failed instantiate leaves its own instance table
%% behind (a property of wasm:instantiate, measured by `trapcore` alone), so the
%% test asserts the two-core link leaks no more than that single unavoidable table:
%% the provider core is freed. Before the fix the provider leaked too, so the
%% two-core link left one extra table and this fails.
a_failed_link_frees_the_cores_it_built(_Config) ->
    {ok, Core} = wasm:load(read(trapcore_path())),
    SelfLeak = leaked(fun() -> wasm:instantiate(Core, #{}) end),
    Comp = read(trap_path()),
    LinkLeak = leaked(fun() -> wasm_component:instantiate(Comp, #{}) end),
    ?assertEqual(SelfLeak, LinkLeak).

%% destroy/2 must be a complete teardown: close every OS handle a host resource
%% owns and clear the per-process tables. A gen_tcp socket is port-owned and is not
%% reclaimed by GC, so a leaked one stays open until the process dies. The test
%% mints a host resource holding a live socket, destroys with the WASI closer, and
%% asserts the port is gone and the tables are empty.
destroy_closes_host_resources_and_clears_the_tables(_Config) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}]),
    {ok, Port} = inet:port(Listen),
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
    _ = wasm_component:host_new(tcp_socket, {connected, {stream, Sock}}),
    _ = wasm_component:host_new(pollable, {clock, 0}),
    ?assertNotEqual([], wasm_component:host_live()),
    ok = wasm_component:destroy(#{cores => []},
                                fun wasi_preview2:close_resource/1),
    ?assertEqual([], wasm_component:host_live()),
    ?assertEqual(undefined, erlang:port_info(Sock)),
    gen_tcp:close(Listen).

%% A graph item that makes the linker raise after it has built a core must still
%% free that core. The two-core graph is parsed and a component-function alias to a
%% component instance that does not exist is appended; linking builds both cores and
%% then raises on the alias (a bad map key). Fail-first: without freeing on the
%% exception path, the two built cores leak.
a_malformed_component_link_leaks_no_cores(_Config) ->
    {ok, Decoded} = wasm_component:decode(component()),
    #{sec := Sec, entry_idx := EntryIdx} = Decoded,
    {ok, Graph} = wasm_component_link:parse(Sec),
    BadGraph = Graph ++ [{comp_func_alias, 99, <<"nope">>}],
    Before = live_instance_tables(),
    Result = wasm_component_link:link(BadGraph, EntryIdx, fun(_) -> #{} end, #{}),
    ?assertMatch({error, _}, Result),
    ?assertEqual(Before, live_instance_tables()).

leaked(F) ->
    Before = live_instance_tables(),
    ?assertMatch({error, _}, F()),
    live_instance_tables() - Before.

live_instance_tables() ->
    length([T || T <- ets:all(), ets:info(T, name) =:= wasm_instance_store]).

read(P) ->
    {ok, Bin} = file:read_file(P),
    Bin.

component() ->
    read(path()).

real_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "realupper.component.wasm"]).

path() -> fixture("twocore.component.wasm").
trap_path() -> fixture("twocore_trap.component.wasm").
trapcore_path() -> fixture("trapcore.wasm").

fixture(Name) ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", Name]).
