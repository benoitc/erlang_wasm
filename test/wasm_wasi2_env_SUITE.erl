-module(wasm_wasi2_env_SUITE).
-moduledoc """
A component that imports the `wasi:cli/environment` world runs against the
Preview 2 host (`wasi_preview2:environment/0`).

The guest imports `wasi:cli/environment` (`get-environment`, `get-arguments`,
`initial-cwd`) and re-exports each. The environment crosses as a
`list<tuple<string, string>>`, so these cases exercise a nested aggregate (a
list of tuples of strings) and an `option<string>` over the Canonical ABI. The
default host is the sandboxed one: it exposes nothing.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(E, <<"wasi:cli/environment">>).

all() ->
    [the_sandboxed_environment_is_empty,
     a_supplied_environment_reaches_the_guest].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture_path()),
    [{component, Bin} | Config].

end_per_suite(_Config) -> ok.

%% The default host exposes nothing: empty list, empty arguments, no cwd. Empty
%% aggregates still cross the ABI (a length written wrong would not read back as
%% []), and `none` is the zero discriminant of the option.
the_sandboxed_environment_is_empty(Config) ->
    {ok, I} = instance(Config, wasi_preview2:environment()),
    ?assertEqual([], env(I)),
    ?assertEqual([], args(I)),
    ?assertEqual(none, cwd(I)).

%% A supplied host proves the nested aggregate deterministically: a list of
%% string pairs, a list of strings, and an option's some case must all reach the
%% guest unchanged.
a_supplied_environment_reaches_the_guest(Config) ->
    Env = [{<<"LANG">>, <<"C">>}, {<<"K">>, <<>>}, {<<"x">>, <<"h", 16#C3, 16#A9>>}],
    Args = [<<"prog">>, <<>>, <<"a longer one">>],
    Fixed = #{{?E, <<"get-environment">>} =>
                  wasm_component:import_fun(
                    {[], {list, {tuple, [string, string]}}}, fun([]) -> Env end),
              {?E, <<"get-arguments">>} =>
                  wasm_component:import_fun(
                    {[], {list, string}}, fun([]) -> Args end),
              {?E, <<"initial-cwd">>} =>
                  wasm_component:import_fun(
                    {[], {option, string}}, fun([]) -> {some, <<"/tmp/work">>} end)},
    {ok, I} = instance(Config, Fixed),
    ?assertEqual(Env, env(I)),
    ?assertEqual(Args, args(I)),
    ?assertEqual({some, <<"/tmp/work">>}, cwd(I)).

%%% -------------------------------------------------------------- helpers ---

env(I) ->
    {ok, V} = wasm_component:call(
                I, <<"env">>, {[], {list, {tuple, [string, string]}}}, []),
    V.

args(I) ->
    {ok, V} = wasm_component:call(I, <<"args">>, {[], {list, string}}, []),
    V.

cwd(I) ->
    {ok, V} = wasm_component:call(I, <<"cwd">>, {[], {option, string}}, []),
    V.

instance(Config, Imports) ->
    wasm_component:instantiate(?config(component, Config), Imports).

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "wasienv.component.wasm"]).
