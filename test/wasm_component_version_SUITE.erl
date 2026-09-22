-module(wasm_component_version_SUITE).
-moduledoc """
A component that imports a versioned interface id runs against the host's bare
handlers.

Real components import versioned ids (`wasi:random/random@0.2.0`); the host is
keyed bare (`wasi:random/random`). `wasm_component` resolves each core import by
its bare id, so a versioned guest links against the same handlers a bare one
does. The fixture imports `wasi:random/random@0.2.0` and exports `roll`.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [a_versioned_import_resolves_to_a_bare_handler].

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

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "wasiver.component.wasm"]).
