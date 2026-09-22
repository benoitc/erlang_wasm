-module(wasm_wasi2_sockets_SUITE).
-moduledoc """
A component that resolves names runs against the `wasi:sockets` host
(`wasi_preview2:sockets/1`), the ip-name-lookup slice.

The guest imports `wasi:sockets/instance-network` and `.../ip-name-lookup` and
exports `lookup(name) -> list<string>` (resolve and format each address). See
`scripts/build-component-fixture.sh`. The point of this suite is
`no_grant_no_network`: with no grant the lookup is refused, because
resolve-addresses asks `wasi_net:resolves/1` rather than resolving on its own.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [localhost_resolves,
     no_grant_no_network,
     an_unknown_name_resolves_to_nothing].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture_path()),
    [{component, Bin} | Config].

end_per_suite(_Config) -> ok.

%% With a resolve grant, localhost resolves to the loopback (a local answer, so
%% no network or resolver contents are involved).
localhost_resolves(Config) ->
    {ok, I} = instance(Config, #{resolve => allow}),
    ?assert(lists:member(<<"127.0.0.1">>, lookup(I, <<"localhost">>))).

%% With no grant, the lookup is refused: resolve-addresses returns access-denied,
%% so the guest gets no stream and an empty list. This is the capability check.
no_grant_no_network(Config) ->
    {ok, I} = instance(Config, none),
    ?assertEqual([], lookup(I, <<"localhost">>)).

%% A name that does not resolve is an empty list, not a crash.
an_unknown_name_resolves_to_nothing(Config) ->
    {ok, I} = instance(Config, #{resolve => allow}),
    ?assertEqual([], lookup(I, <<"nonexistent.invalid">>)).

%%% -------------------------------------------------------------- helpers ---

lookup(I, Name) ->
    {ok, V} = wasm_component:call(I, <<"lookup">>, {[string], {list, string}}, [Name]),
    V.

instance(Config, Grant) ->
    wasm_component:instantiate(?config(component, Config),
                               wasi_preview2:sockets(#{grant => Grant})).

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "wasisock.component.wasm"]).
