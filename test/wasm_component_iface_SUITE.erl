-module(wasm_component_iface_SUITE).
-moduledoc """
Synchronous interface functions called as their `canon lift` declares.

A function an interface exports (`local:t/api#greet`) used to be found by a
core export of that very name, in the entry core first, with no post-return,
the default string encoding and `cabi_realloc`: the per-export tables were
built from top-level function exports only. Each case here is reachable only
through the lift's own declaration.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([a_renamed_core_function_is_found/1,
         the_post_return_runs/1,
         the_declared_string_encoding_is_used/1,
         the_declared_core_is_called/1,
         a_wrapped_interface_function_is_found/1]).

all() ->
    [a_renamed_core_function_is_found, the_post_return_runs,
     the_declared_string_encoding_is_used, the_declared_core_is_called,
     a_wrapped_interface_function_is_found].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture()),
    [{component, Bin} | Config].

end_per_suite(_) -> ok.

init_per_testcase(_, Config) ->
    {ok, I} = wasm_component:instantiate(?config(component, Config), #{},
                                         #{loader => compile}),
    [{inst, I} | Config].

end_per_testcase(_, Config) ->
    ok = wasm_component:destroy(?config(inst, Config)).

%% The lift names core function `impl-a'; no core export is called
%% `local:t/api#renamed'.
a_renamed_core_function_is_found(Config) ->
    ?assertEqual({ok, 1}, call(Config, ~"local:t/api#renamed", u32)).

%% `greet' returns a string and names a post-return, which a component uses
%% to free what it returned. It never ran for an interface function.
the_post_return_runs(Config) ->
    ?assertEqual({ok, ~"hi there"}, call(Config, ~"local:t/api#greet", string)),
    ?assertEqual({ok, 1}, call(Config, ~"local:t/api#post-returns", u32)).

the_declared_string_encoding_is_used(Config) ->
    ?assertEqual({ok, ~"héllo"}, call(Config, ~"local:t/api#utf16", string)).

%% Both cores export `local:t/api#twin'; the lift names the second, which
%% answers 2. By name, the entry core's answered 1.
the_declared_core_is_called(Config) ->
    ?assertEqual({ok, 2}, call(Config, ~"local:t/api#twin", u32)).

%% `local:t/wrapped' is a wrapper component instantiated with `renamed', as
%% wit-component exports an interface.
a_wrapped_interface_function_is_found(Config) ->
    ?assertEqual({ok, 1}, call(Config, ~"local:t/wrapped#renamed", u32)).

call(Config, Export, Result) ->
    wasm_component:call(?config(inst, Config), Export, {[], Result}, []).

fixture() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..", "test", "fixtures",
                   "component", "ifaceexports.component.wasm"]).
