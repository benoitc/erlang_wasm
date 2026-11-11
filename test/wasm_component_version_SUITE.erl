-module(wasm_component_version_SUITE).
-moduledoc """
A component that imports a versioned interface id runs against the host's bare
handlers.

Real components import versioned ids (`wasi:random/random@0.2.0`); the host is
keyed bare (`wasi:random/random`). `wasm_component` resolves each core import by
its bare id, so a versioned guest links against the same handlers a bare one
does. The fixture imports `wasi:random/random@0.2.0` and exports `roll`.

WASI 0.3 is the exception. Its interfaces have the names of 0.2's and other
functions, and one component imports both, as a 0.3 program built through the
wasip1 adapter does. A `0.3.x' import resolves to the host key `Interface@0.3'
and never to the bare 0.2 one: before, `wasi:cli/stdout@0.3.0' bound the 0.2
`stdout' functions. The last case is an async host import on a component that
never reaches the linker, which was refused at instantiation.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [a_versioned_import_resolves_to_a_bare_handler,
     a_0_3_import_reaches_the_0_3_host,
     a_0_3_import_never_binds_a_0_2_function,
     a_single_core_component_calls_an_async_import].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture_path()),
    [{component, Bin} | Config].

end_per_suite(_Config) -> ok.

%% The guest imports wasi:random/random@0.2.0; wasi_preview2:random/0 is keyed
%% wasi:random/random. It links and runs only because resolution strips the
%% version. Without that the import is unmet and instantiation fails.
a_versioned_import_resolves_to_a_bare_handler(Config) ->
    {ok, I} = wasm_component:instantiate(?config(component, Config),
                                         wasi_preview2:random()),
    {ok, V} = wasm_component:call(I, <<"roll">>, {[], u64}, []),
    ?assert(is_integer(V) andalso V >= 0 andalso V < (1 bsl 64)).

%% One host function per version, each answering its own number.
a_0_3_import_reaches_the_0_3_host(_Config) ->
    Host = #{{~"wasi:random/random", ~"get-random-u64"} => constant(2),
             {~"wasi:random/random@0.3", ~"get-random-u64"} => constant(3)},
    {ok, I} = wasm_component:instantiate(fixture(~"wasi3keys"), Host),
    ?assertEqual({ok, 2}, wasm_component:call(I, ~"roll2", {[], u64}, [])),
    ?assertEqual({ok, 3}, wasm_component:call(I, ~"roll3", {[], u64}, [])).

%% With only the 0.2 host, the 0.3 import has no provider.
a_0_3_import_never_binds_a_0_2_function(_Config) ->
    Host = #{{~"wasi:random/random", ~"get-random-u64"} => constant(2)},
    ?assertMatch({error, _},
                 wasm_component:instantiate(fixture(~"wasi3keys"), Host)).

%% `ping' completes at once: the call answers RETURNED (2) and the host saw x.
a_single_core_component_calls_an_async_import(_Config) ->
    Test = self(),
    Host = #{{~"local:ping/host", ~"ping"} =>
                 {async_import, {[u32], none}, fun([X]) -> Test ! {pinged, X} end}},
    {ok, I} = wasm_component:instantiate(fixture(~"asyncping"), Host),
    ?assertEqual({ok, 2}, wasm_component:call(I, ~"run", {[u32], u32}, [5])),
    receive {pinged, 5} -> ok after 1000 -> ct:fail(not_pinged) end.

constant(N) -> wasm_component:import_fun({[], u64}, fun([]) -> N end).

fixture(Name) ->
    {ok, Bin} = file:read_file(
                  filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                                 "test", "fixtures", "component",
                                 <<Name/binary, ".component.wasm">>])),
    Bin.

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "wasiver.component.wasm"]).
