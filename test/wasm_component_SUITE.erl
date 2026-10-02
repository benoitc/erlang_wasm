-module(wasm_component_SUITE).
-moduledoc """
Phase 0 of component-model support: a real component runs end to end.

The fixture is a no-import component built from a `wit-bindgen` guest and
`wasm-tools` (see `scripts/build-component-fixture.sh`), exporting
`run: func(list<u8>) -> result<list<u8>, string>`. These cases prove the whole
Phase 0 pipeline: recognise a component, extract and instantiate its core module,
lower a `list<u8>` argument through the Canonical ABI, call the export, and lift a
`result<list<u8>, string>` back -- both the ok and the error case.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [a_core_module_is_not_a_component,
     the_component_decodes_to_its_core_and_exports,
     a_component_round_trips_bytes_in_and_out,
     a_result_error_lifts_as_the_error_string,
     a_truncated_component_is_an_error_not_a_crash,
     a_renamed_export_is_called_through_its_wiring,
     a_core_less_component_instantiates,
     a_declared_realloc_is_used,
     a_declared_post_return_runs,
     a_post_return_trap_fails_the_call,
     a_lift_selects_its_declared_core,
     an_ill_typed_lift_is_rejected,
     a_double_drop_traps].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture_path()),
    [{component, Bin} | Config].

end_per_suite(_Config) -> ok.

%% A core module shares the magic but a different version/layer, so it must not be
%% mistaken for a component; junk is neither.
a_core_module_is_not_a_component(_Config) ->
    ?assertEqual({error, not_a_component},
                 wasm_component:decode(<<16#00, 16#61, 16#73, 16#6d,
                                         16#01, 16#00, 16#00, 16#00>>)),
    ?assertEqual({error, not_wasm}, wasm_component:decode(<<"not wasm">>)).

the_component_decodes_to_its_core_and_exports(Config) ->
    Bin = ?config(component, Config),
    {ok, C} = wasm_component:decode(Bin),
    ?assertEqual([<<"run">>], maps:get(exports, C)),
    %% The extracted core module is a real, loadable core module.
    ?assertMatch({ok, _}, wasm:load(maps:get(core, C))).

a_component_round_trips_bytes_in_and_out(Config) ->
    {ok, I} = wasm_component:instantiate(?config(component, Config)),
    %% ok case: the guest upper-cases the bytes and returns them as the ok list.
    ?assertEqual({ok, {ok, <<"HELLO, WASM">>}},
                 wasm_component:call(I, <<"run">>, sig(), [<<"hello, wasm">>])).

a_result_error_lifts_as_the_error_string(Config) ->
    {ok, I} = wasm_component:instantiate(?config(component, Config)),
    %% error case: empty input returns the error string.
    ?assertEqual({ok, {error, <<"empty input">>}},
                 wasm_component:call(I, <<"run">>, sig(), [<<>>])).

%% run: func(input: list<u8>) -> result<list<u8>, string>
sig() -> {[{list, u8}], {result, {list, u8}, string}}.

%% A component cut off at any length is malformed input, which the runtime turns
%% into a value, never a raise. The multi-core `twocore` bytes exercise the graph
%% linker's strict binary parsers; a prefix that stops mid-section would badmatch
%% or function_clause without the guard. Fail-first: remove the try/catch in
%% wasm_component:link_in/3 and some prefix crashes this case.
a_truncated_component_is_an_error_not_a_crash(_Config) ->
    {ok, Good} = file:read_file(twocore_path()),
    lists:foreach(
      fun(Len) ->
          Bad = binary:part(Good, 0, Len),
          try wasm_component:instantiate(Bad, #{}) of
              {ok, Inst}     -> wasm_component:destroy(Inst);
              {error, _}     -> ok
          catch
              Class:Reason -> ct:fail({raised, Len, Class, Reason})
          end
      end, lists:seq(8, byte_size(Good))).

%% The component export "step" is implemented by the core function "bump"; calling
%% by the component name reaches it through the export wiring. Fail-first: without
%% the export map, call/4 used the component name as a core export name and got
%% unknown_export.
a_renamed_export_is_called_through_its_wiring(_Config) ->
    {ok, Bin} = file:read_file(component_fixture("renamedexport.component.wasm")),
    {ok, I} = wasm_component:instantiate(Bin),
    ?assertEqual({ok, 1}, wasm_component:call(I, <<"step">>, {[], u32}, [])),
    ?assertEqual({ok, 2}, wasm_component:call(I, <<"step">>, {[], u32}, [])),
    wasm_component:destroy(I).

fixture_path() ->
    component_fixture("echo.component.wasm").

%% A component need not embed a core module: `(component)` is valid and instantiates
%% with no exports. Was rejected as `no_core_module`.
a_core_less_component_instantiates(_Config) ->
    {ok, Bin} = file:read_file(component_fixture("audit/empty.wasm")),
    {ok, I} = wasm_component:instantiate(Bin),
    ?assertEqual([], wasm_component:exports(I)),
    ok = wasm_component:destroy(I).

%% The lift declares the allocator `allocate`, not `cabi_realloc`; lowering the string
%% argument must go through it. `run("abc")` returns 3. Was an unknown_export error.
a_declared_realloc_is_used(_Config) ->
    {ok, Bin} = file:read_file(component_fixture("audit/realloc_name.wasm")),
    {ok, I} = wasm_component:instantiate(Bin),
    ?assertEqual({ok, 3}, wasm_component:call(I, <<"run">>, {[string], u32}, [<<"abc">>])).

%% The lift declares the post-return `cleanup`, which sets a global; the second call sees
%% it. Was 0 then 0 (the declared cleanup was skipped in favour of `cabi_post_run`).
a_declared_post_return_runs(_Config) ->
    {ok, Bin} = file:read_file(component_fixture("audit/post_return.wasm")),
    {ok, I} = wasm_component:instantiate(Bin),
    ?assertEqual({ok, 0}, wasm_component:call(I, <<"run">>, {[], u32}, [])),
    ?assertEqual({ok, 1}, wasm_component:call(I, <<"run">>, {[], u32}, [])).

%% A trap during post-return fails the call rather than being swallowed. Was returning 42.
a_post_return_trap_fails_the_call(_Config) ->
    {ok, Bin} = file:read_file(component_fixture("audit/post_trap.wasm")),
    {ok, I} = wasm_component:instantiate(Bin),
    ?assertMatch({error, _}, wasm_component:call(I, <<"run">>, {[], u32}, [])).

%% Two cores each export "run": the larger returns 99, the smaller 42, and the
%% component lifts the smaller. The export must reach the core its declared lift
%% names, not the largest core by size. Was 99 (largest-core + same-name heuristic,
%% and the second core was never even built on the single-core path).
a_lift_selects_its_declared_core(_Config) ->
    {ok, Bin} = file:read_file(component_fixture("audit/wrong_core.wasm")),
    {ok, I} = wasm_component:instantiate(Bin),
    ?assertEqual({ok, 42}, wasm_component:call(I, <<"run">>, {[], u32}, [])),
    ok = wasm_component:destroy(I).

%% A lift declares its result is u32 but its core function returns f64: the core
%% signature the Canonical ABI derives from the declared type (a single i32) does
%% not match the core function, so the component is rejected at instantiate, before
%% any core runs. Was accepted and later crashed with a badarith on the call.
an_ill_typed_lift_is_rejected(_Config) ->
    {ok, Bin} = file:read_file(component_fixture("audit/invalid_lift.wasm")),
    ?assertMatch({error, {invalid_lift_type, _}},
                 wasm_component:instantiate(Bin)).

%% The guest mints a resource handle, drops it, then drops the same handle again.
%% The second drop is a use of a handle no longer live in the instance, so it
%% traps rather than returning. Was returning 42 (the drop was a silent no-op).
a_double_drop_traps(_Config) ->
    {ok, Bin} = file:read_file(component_fixture("audit/double_drop.wasm")),
    {ok, I} = wasm_component:instantiate(Bin),
    ?assertMatch({error, #{class := trap, msg := <<"resource_not_live">>}},
                 wasm_component:call(I, <<"run">>, {[], u32}, [])),
    ok = wasm_component:destroy(I).

component_fixture(Name) ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", Name]).

twocore_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "twocore.component.wasm"]).
