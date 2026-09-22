-module(wasm_component_vectors_SUITE).
-moduledoc """
The Canonical ABI lift/lower, checked against a real guest over a full set of
vectors.

The fixture is a `wit-bindgen` guest that echoes one value of every WIT type back
(see `scripts/build-component-fixture.sh`). Each case lowers an Erlang term into
the guest, calls the echo, lifts the result, and asserts it round-trips -- so both
directions of the ABI are exercised for every value type, at edge values
(zero, unsigned max, signed min and max, empty and non-empty collections, a
non-ASCII string, an astral character, every flag on and none), and for both
cases of each variant, option and result.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [unsigned_integers, signed_integers, floats_bool_char,
     strings_and_byte_lists, typed_lists, records_and_tuples,
     variants, enums, options, results, flags].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture_path()),
    [{component, Bin} | Config].

end_per_suite(_Config) -> ok.

%% A bare instance is scoped to the process that created it, and the test case
%% runs in this process, so instantiate here rather than in init_per_suite.
init_per_testcase(_Case, Config) ->
    {ok, Inst} = wasm_component:instantiate(?config(component, Config)),
    [{inst, Inst} | Config].

end_per_testcase(_Case, _Config) -> ok.

%%% --------------------------------------------------------------- cases ---

unsigned_integers(Config) ->
    rt(Config, <<"echo-u8">>, u8, [0, 1, 255]),
    rt(Config, <<"echo-u16">>, u16, [0, 60000, 65535]),
    rt(Config, <<"echo-u32">>, u32, [0, 4000000000, 4294967295]),
    rt(Config, <<"echo-u64">>, u64, [0, 18446744073709551615]).

signed_integers(Config) ->
    rt(Config, <<"echo-s8">>, s8, [-128, -1, 0, 127]),
    rt(Config, <<"echo-s16">>, s16, [-32768, -1, 32767]),
    rt(Config, <<"echo-s32">>, s32, [-2147483648, -1, 2147483647]),
    rt(Config, <<"echo-s64">>, s64,
       [-9223372036854775808, -1, 9223372036854775807]).

floats_bool_char(Config) ->
    rt(Config, <<"echo-f32">>, f32, [0.0, 1.5, -2.25]),
    rt(Config, <<"echo-f64">>, f64, [0.0, 3.141592653589793, -1.0e300]),
    rt(Config, <<"echo-bool">>, bool, [true, false]),
    %% ASCII, a BMP codepoint, and an astral one.
    rt(Config, <<"echo-char">>, char, [$A, 16#20AC, 16#1F600]).

strings_and_byte_lists(Config) ->
    rt(Config, <<"echo-string">>, string,
       [<<>>, <<"ascii">>, <<"h", 16#C3, 16#A9, "llo, w", 16#C3, 16#B6, "rld">>]).

typed_lists(Config) ->
    rt(Config, <<"echo-list-u32">>, {list, u32}, [[], [0], [1, 2, 4294967295]]),
    rt(Config, <<"echo-list-string">>, {list, string},
       [[], [<<"a">>, <<"">>, <<"ccc">>]]).

records_and_tuples(Config) ->
    rt(Config, <<"echo-point">>, point(),
       [#{<<"x">> => -1, <<"y">> => 2}, #{<<"x">> => 0, <<"y">> => 0}]),
    rt(Config, <<"echo-tuple">>, {tuple, [u8, string, bool]},
       [{0, <<>>, false}, {200, <<"hi">>, true}]).

variants(Config) ->
    rt(Config, <<"echo-shape">>, shape(),
       [{<<"circle">>, 2.5},
        {<<"rect">>, #{<<"x">> => 1, <<"y">> => -2}},
        {<<"unit">>, undefined}]).

enums(Config) ->
    rt(Config, <<"echo-color">>, color(),
       [<<"red">>, <<"green">>, <<"blue">>]).

options(Config) ->
    rt(Config, <<"echo-option">>, {option, u32}, [none, {some, 0}, {some, 42}]).

results(Config) ->
    rt(Config, <<"echo-result">>, {result, u32, string},
       [{ok, 0}, {ok, 7}, {error, <<>>}, {error, <<"bad">>}]).

flags(Config) ->
    rt(Config, <<"echo-perms">>, perms(),
       [[], [<<"read">>], [<<"read">>, <<"exec">>],
        [<<"read">>, <<"write">>, <<"exec">>]]).

%%% -------------------------------------------------------------- helpers ---

%% Round-trip each value through the guest echo and assert it comes back equal.
rt(Config, Export, Desc, Values) ->
    Inst = ?config(inst, Config),
    lists:foreach(
      fun(V) ->
          ?assertEqual({ok, V},
                       wasm_component:call(Inst, Export, {[Desc], Desc}, [V]))
      end, Values).

point() -> {record, [{<<"x">>, s32}, {<<"y">>, s32}]}.
shape() -> {variant, [{<<"circle">>, f64}, {<<"rect">>, point()},
                      {<<"unit">>, none}]}.
color() -> {enum, [<<"red">>, <<"green">>, <<"blue">>]}.
perms() -> {flags, [<<"read">>, <<"write">>, <<"exec">>]}.

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "vectors.component.wasm"]).
