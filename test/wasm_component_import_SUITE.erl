-module(wasm_component_import_SUITE).
-moduledoc """
A component runs against host functions the host provides for its imports.

This is the import direction of the component model, the shape a WASI 0.2 world
takes: the guest imports an interface and the host supplies each function. The
fixture imports `example:host/clock` (`now`, `add`) and exports `read-now` and
`read-add`, which call the imports (see `scripts/build-component-fixture.sh`).
These cases prove the host functions are wired by `{interface, field}`, that they
see the guest's arguments and their result reaches the guest, and that a missing
import is refused rather than silently absent.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [the_host_supplies_a_leaf_import,
     a_host_import_sees_its_arguments,
     a_missing_import_is_refused,
     a_typed_import_wraps_flat_values,
     an_aggregate_import_round_trips].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture_path()),
    [{component, Bin} | Config].

end_per_suite(_Config) -> ok.

the_host_supplies_a_leaf_import(Config) ->
    {ok, I} = instance(Config, imports(424242)),
    ?assertEqual({ok, 424242}, wasm_component:call(I, <<"read-now">>, {[], u64}, [])),
    ?assertEqual({ok, 42},
                 wasm_component:call(I, <<"read-add">>, {[u32, u32], u32}, [20, 22])).

a_host_import_sees_its_arguments(Config) ->
    {ok, I} = instance(Config, imports(0)),
    [?assertEqual({ok, A + B},
                  wasm_component:call(I, <<"read-add">>, {[u32, u32], u32}, [A, B]))
     || {A, B} <- [{0, 0}, {1, 2}, {1000000, 2000000}, {4294967294, 1}]].

a_missing_import_is_refused(Config) ->
    %% No host functions provided: the guest's imports are unmet.
    ?assertMatch({error, _},
                 wasm_component:instantiate(?config(component, Config), #{})).

%% import_fun/2 wraps a typed host function; here the flat case (u64, u32).
a_typed_import_wraps_flat_values(Config) ->
    Now = wasm_component:import_fun({[], u64}, fun([]) -> 777 end),
    Add = wasm_component:import_fun({[u32, u32], u32}, fun([A, B]) -> A + B end),
    {ok, I} = instance(Config,
                       #{{<<"example:host/clock">>, <<"now">>} => Now,
                         {<<"example:host/clock">>, <<"add">>} => Add}),
    ?assertEqual({ok, 777}, wasm_component:call(I, <<"read-now">>, {[], u64}, [])),
    ?assertEqual({ok, 30},
                 wasm_component:call(I, <<"read-add">>, {[u32, u32], u32}, [10, 20])).

%% A string crosses both ways: the host lifts the guest's argument and lowers its
%% result into the guest's return area, all through import_fun/2.
an_aggregate_import_round_trips(Config) ->
    Bin = agg_component(Config),
    Shout = wasm_component:import_fun({[string], string},
                                     fun([S]) -> string:uppercase(S) end),
    {ok, I} = wasm_component:instantiate(
                Bin, #{{<<"example:agg/host">>, <<"shout">>} => Shout}),
    [?assertEqual({ok, <<"<<", (string:uppercase(S))/binary, ">>">>},
                  wasm_component:call(I, <<"announce">>, {[string], string}, [S]))
     || S <- [<<>>, <<"hi there">>, <<"h", 16#C3, 16#A9, "llo">>]].

%%% -------------------------------------------------------------- helpers ---

agg_component(_Config) ->
    {ok, Bin} = file:read_file(
                  filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                                 "test", "fixtures", "component",
                                 "hostagg.component.wasm"])),
    Bin.

instance(Config, Imports) ->
    wasm_component:instantiate(?config(component, Config), Imports).

%% `now` returns a fixed value so the test can assert on it; `add` adds.
imports(Now) ->
    #{{<<"example:host/clock">>, <<"now">>} =>
          fun(_Ctx, []) -> {ok, [Now]} end,
      {<<"example:host/clock">>, <<"add">>} =>
          fun(_Ctx, [A, B]) -> {ok, [A + B]} end}.

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "hostcall.component.wasm"]).
