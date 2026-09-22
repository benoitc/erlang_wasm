-module(wasm_component_resource_SUITE).
-moduledoc """
A component that exports a resource runs through the host handle table.

The fixture is a `wit-bindgen` guest exporting a `counter` resource with a
constructor, `increment` and `get` (see `scripts/build-component-fixture.sh`). Its
core module imports the resource intrinsics `[resource-new]`/`[resource-drop]`,
which the host provides -- that is the handle table. These cases prove a resource
is constructed, its methods called on the returned handle, two live resources stay
independent, and the destructor runs on drop.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [a_resource_is_constructed_and_its_methods_called,
     two_resources_are_independent].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture_path()),
    [{component, Bin} | Config].

end_per_suite(_Config) -> ok.

%% The instance and its handle table are scoped to the test case's process.
init_per_testcase(_Case, Config) ->
    {ok, Inst} = wasm_component:instantiate(?config(component, Config)),
    [{inst, Inst} | Config].

end_per_testcase(_Case, _Config) -> ok.

a_resource_is_constructed_and_its_methods_called(Config) ->
    Inst = ?config(inst, Config),
    {ok, H} = make(Inst, 5),
    ?assert(is_integer(H)),
    ?assertEqual({ok, 8}, increment(Inst, H, 3)),
    ?assertEqual({ok, 8}, get(Inst, H)),
    ?assertEqual({ok, 108}, increment(Inst, H, 100)),
    ok = drop(Inst, H).

two_resources_are_independent(Config) ->
    Inst = ?config(inst, Config),
    {ok, A} = make(Inst, 0),
    {ok, B} = make(Inst, 100),
    ?assertNotEqual(A, B),
    ?assertEqual({ok, 1}, increment(Inst, A, 1)),
    ?assertEqual({ok, 105}, increment(Inst, B, 5)),
    %% A's changes did not touch B and vice versa.
    ?assertEqual({ok, 1}, get(Inst, A)),
    ?assertEqual({ok, 105}, get(Inst, B)),
    ok = drop(Inst, A),
    ok = drop(Inst, B).

%%% -------------------------------------------------------------- helpers ---

make(Inst, Init)   -> wasm_component:call(Inst, q(<<"make-counter">>),
                                          {[u32], u32}, [Init]).
increment(Inst, H, By) ->
    wasm_component:call(Inst, q(<<"[method]counter.increment">>),
                        {[u32, u32], u32}, [H, By]).
get(Inst, H)       -> wasm_component:call(Inst, q(<<"[method]counter.get">>),
                                          {[u32], u32}, [H]).
drop(Inst, H)      -> wasm_component:drop_resource(Inst, q(<<"[dtor]counter">>), H).

q(Name) -> <<"example:counter/counters#", Name/binary>>.

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "counter.component.wasm"]).
