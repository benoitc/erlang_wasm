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
     two_resources_are_independent,
     dropping_twice_is_graceful,
     a_method_after_drop_is_a_value,
     a_method_on_a_bogus_handle_is_a_value].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture_path()),
    [{component, Bin} | Config].

end_per_suite(_Config) -> ok.

%% The instance and its handle table are scoped to the test case's process. Build the
%% cores inline (`loader => compile`) rather than through the node cache, whose 50/s load
%% limit a full test run trips when many cases instantiate.
init_per_testcase(_Case, Config) ->
    {ok, Inst} = wasm_component:instantiate(?config(component, Config), #{},
                                            #{loader => compile}),
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

%% Resource misuse must be graceful: it returns a value and never destabilises the
%% caller. Detection of misuse as a trap (a double drop, a use-after-drop) is a tracked
%% refinement that belongs with per-component handle tables; today the contract these
%% cases pin is only that the runtime does not crash.

%% Dropping a handle twice does not crash (the second drop is a no-op).
dropping_twice_is_graceful(Config) ->
    Inst = ?config(inst, Config),
    {ok, H} = make(Inst, 1),
    ok = drop(Inst, H),
    ok = drop(Inst, H).

%% Calling a method after the resource was dropped is a value, not a crash.
a_method_after_drop_is_a_value(Config) ->
    Inst = ?config(inst, Config),
    {ok, H} = make(Inst, 1),
    ok = drop(Inst, H),
    assert_value(increment(Inst, H, 1)).

%% A method on a handle that was never minted is a value, not a crash.
a_method_on_a_bogus_handle_is_a_value(Config) ->
    Inst = ?config(inst, Config),
    assert_value(increment(Inst, 16#7FFFFFFF, 1)).

assert_value({ok, _})    -> ok;
assert_value({error, _}) -> ok;
assert_value(Other)      -> ct:fail({not_a_value, Other}).

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
