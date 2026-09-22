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
     a_missing_import_is_refused].

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

%%% -------------------------------------------------------------- helpers ---

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
