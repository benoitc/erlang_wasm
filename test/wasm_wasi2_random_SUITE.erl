-module(wasm_wasi2_random_SUITE).
-moduledoc """
A component that imports the `wasi:random/random` world runs against the
Preview 2 host (`wasi_preview2:random/0`).

This is the first real WASI 0.2 world: the guest imports `wasi:random/random`
(`get-random-u64`, `get-random-bytes`) and exports `roll` and `bytes`, which
call the imports (see `scripts/build-component-fixture.sh`). The cases prove the
host is wired by the interface id `wasi:random/random`, that a byte request
crosses back at exactly the requested length, that a fixed source reaches the
guest unchanged, and that the default source varies.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(I, <<"wasi:random/random">>).

all() ->
    [random_bytes_have_the_requested_length,
     a_fixed_source_reaches_the_guest,
     the_default_source_varies,
     an_absurd_random_length_is_refused,
     the_insecure_interfaces_are_offered].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture_path()),
    [{component, Bin} | Config].

end_per_suite(_Config) -> ok.

%% The real host returns exactly the requested number of bytes, across a vector
%% of sizes: empty, one, a page, an odd length. A wrong length would be a lift
%% or lower fault, not a random value, so this assertion can fail.
random_bytes_have_the_requested_length(Config) ->
    {ok, I} = instance(Config, wasi_preview2:random()),
    [?assertEqual(N, byte_size(bytes(I, N)))
     || N <- [0, 1, 8, 15, 256, 4096, 65537]].

%% A fixed source proves the plumbing deterministically: a host that always
%% returns the same u64 and the same byte pattern must reach the guest unchanged.
a_fixed_source_reaches_the_guest(Config) ->
    U = 16#0123456789ABCDEF,
    Fixed = #{{?I, <<"get-random-u64">>} =>
                  wasm_component:import_fun({[], u64}, fun([]) -> U end),
              {?I, <<"get-random-bytes">>} =>
                  wasm_component:import_fun(
                    {[u64], {list, u8}},
                    fun([Len]) -> binary:copy(<<16#5A>>, Len) end)},
    {ok, I} = instance(Config, Fixed),
    ?assertEqual(U, roll(I)),
    [?assertEqual(binary:copy(<<16#5A>>, N), bytes(I, N))
     || N <- [0, 1, 32, 1000]].

%% The default CSPRNG does not hand back a constant: two rolls differ and a
%% non-empty request is not all zero. (Both hold with overwhelming probability;
%% a stuck source, e.g. a host that returns a constant, fails here.)
the_default_source_varies(Config) ->
    {ok, I} = instance(Config, wasi_preview2:random()),
    ?assertNotEqual(roll(I), roll(I)),
    ?assertNotEqual(binary:copy(<<0>>, 64), bytes(I, 64)).

%% get-random-bytes of an absurd count is refused rather than allocating the whole
%% buffer in the host. Fail-first: the host materialised the guest-requested length
%% before any bound applied.
an_absurd_random_length_is_refused(_Config) ->
    ?assertEqual(8, byte_size(wasi_preview2:random_bytes(8))),
    ?assertError(random_bytes_too_large,
                 wasi_preview2:random_bytes(16 * 1024 * 1024 + 1)).

%% The insecure random interfaces of the wasi:random world are wired, so a guest
%% that imports them links.
the_insecure_interfaces_are_offered(_Config) ->
    M = wasi_preview2:random(),
    ?assert(maps:is_key({<<"wasi:random/insecure">>, <<"get-insecure-random-u64">>}, M)),
    ?assert(maps:is_key({<<"wasi:random/insecure">>, <<"get-insecure-random-bytes">>}, M)),
    ?assert(maps:is_key({<<"wasi:random/insecure-seed">>, <<"insecure-seed">>}, M)).

%%% -------------------------------------------------------------- helpers ---

roll(I) ->
    {ok, V} = wasm_component:call(I, <<"roll">>, {[], u64}, []),
    V.

bytes(I, N) ->
    {ok, B} = wasm_component:call(I, <<"bytes">>, {[u32], {list, u8}}, [N]),
    B.

instance(Config, Imports) ->
    wasm_component:instantiate(?config(component, Config), Imports).

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "wasirandom.component.wasm"]).
