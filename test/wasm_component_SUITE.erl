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
     a_truncated_component_is_an_error_not_a_crash].

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

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "echo.component.wasm"]).

twocore_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "twocore.component.wasm"]).
