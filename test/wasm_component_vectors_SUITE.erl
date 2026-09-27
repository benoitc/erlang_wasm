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
     variants, enums, options, results, flags,
     wide_parameter_lists_spill_to_memory,
     an_invalid_char_is_rejected,
     a_bad_argument_is_an_error_not_a_crash,
     an_invalid_discriminant_is_rejected,
     an_unknown_case_name_is_rejected,
     nan_and_infinity_floats_round_trip,
     an_oversized_list_traps_on_bounds].

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

%% A parameter list that flattens past 16 values is passed as one pointer to the
%% parameters stored in memory. Lowering then lifting a wide signature round-trips
%% through that spill path. Fail-first: without spilling, lower_params returned 20
%% flats and lift_params read them as registers, which is the wrong ABI.
wide_parameter_lists_spill_to_memory(Config) ->
    #{core := Core} = ?config(inst, Config),
    Descs = lists:duplicate(20, u32),
    Args = lists:seq(1, 20),
    Flats = wasm_canon:lower_params(Core, Descs, Args),
    ?assertEqual(1, length(Flats)),
    {Lifted, _} = wasm_canon:lift_params(Core, Descs, Flats),
    ?assertEqual(Args, Lifted).

%% A char must be a Unicode scalar value; a surrogate or an out-of-range code
%% point is rejected on lift. Fail-first: char used to lift any i32 unchecked.
an_invalid_char_is_rejected(Config) ->
    #{core := Core} = ?config(inst, Config),
    %% A surrogate or out-of-range code point signals a structured trap that the
    %% call boundary captures as an `{error, _}` value; it does not raise. Fail-first:
    %% `valid_char` used to `error({invalid_char, _})`, which `capture` reported as a
    %% generic `internal` error, not `kind => invalid_char`.
    Lift = fun(V) ->
               wasm_error:capture(fun() -> wasm_canon:lift_params(Core, [char], [V]) end)
           end,
    ?assertMatch({error, #{kind := invalid_char}}, Lift(16#D800)),
    ?assertMatch({error, #{kind := invalid_char}}, Lift(16#110000)),
    ?assertEqual({[16#20AC], []}, wasm_canon:lift_params(Core, [char], [16#20AC])).

%% A malformed argument (here a non-number where a `u8` is lowered) is an `{error, _}`
%% value from the call boundary, not a raw crash. Fail-first: `call/4` lowered outside
%% any capture, so the `band` on an atom raised `badarith` straight to the caller.
a_bad_argument_is_an_error_not_a_crash(Config) ->
    Inst = ?config(inst, Config),
    ?assertMatch({error, _},
                 wasm_component:call(Inst, <<"echo-u8">>, {[u8], u8}, [not_a_number])).

%% A variant/enum discriminant the guest wrote past its last case is malformed and
%% traps with a named reason, captured as an `{error, _}` value. Fail-first: the lift
%% used `lists:nth(Disc + 1, Cases)`, so an out-of-range discriminant raised a
%% `function_clause` that `capture` could only report as a generic `internal` error.
an_invalid_discriminant_is_rejected(Config) ->
    #{core := Core} = ?config(inst, Config),
    Lift = fun(Desc, Disc) ->
               wasm_error:capture(
                 fun() -> wasm_canon:lift_params(Core, [Desc], [Disc]) end)
           end,
    ?assertMatch({error, #{kind := invalid_discriminant}},
                 Lift({enum, [<<"a">>, <<"b">>, <<"c">>]}, 7)),
    ?assertMatch({error, #{kind := invalid_discriminant}},
                 Lift({enum, [<<"a">>, <<"b">>, <<"c">>]}, -1)),
    %% A variant carries a payload; an out-of-range tag traps before reading it.
    ?assertMatch({error, #{kind := invalid_discriminant}},
                 wasm_error:capture(
                   fun() -> wasm_canon:lift_params(
                              Core, [{variant, [{<<"x">>, u32}, {<<"y">>, u32}]}],
                              [4, 0]) end)).

%% Lowering a variant/enum/flags name that is not one of the type's cases is
%% malformed input and traps, captured as `{error, _}`. Fail-first: `index_of` ran
%% off the end of the case list into a `function_clause`.
an_unknown_case_name_is_rejected(Config) ->
    #{core := Core} = ?config(inst, Config),
    Lower = fun(Desc, Val) ->
                wasm_error:capture(
                  fun() -> wasm_canon:lower_params(Core, [Desc], [Val]) end)
            end,
    ?assertMatch({error, #{kind := unknown_case}},
                 Lower({enum, [<<"a">>, <<"b">>]}, <<"z">>)),
    ?assertMatch({error, #{kind := unknown_case}},
                 Lower({flags, [<<"read">>, <<"write">>]}, [<<"execute">>])).

%% Infinities and NaN cross the Canonical ABI: the runtime carries a non-finite float
%% as `infinity`/`neg_infinity`/`{nan, _, _}`, not an Erlang float. Fail-first: the
%% float sites packed with `<<V:32/float>>`, which raises `badarg` on those terms.
%% `shape`'s `circle` case carries an `f64`, so `echo-shape` exercises the variant
%% coerce on lower and the by-memory `load` on the lifted result; a direct
%% lower/lift round-trip covers the flat `uncoerce` and a NaN (a guest may canonicalise
%% a NaN, so it is not asserted through the guest).
nan_and_infinity_floats_round_trip(Config) ->
    Inst = ?config(inst, Config),
    #{core := Core} = Inst,
    Shape = shape(),
    lists:foreach(
      fun(F) ->
          ?assertEqual({ok, {<<"circle">>, F}},
                       wasm_component:call(Inst, <<"echo-shape">>,
                                           {[Shape], Shape}, [{<<"circle">>, F}]))
      end, [infinity, neg_infinity]),
    %% Flat coerce/uncoerce, no guest: lower to flats then lift straight back.
    RT = fun(V) ->
             Flats = wasm_canon:lower_params(Core, [Shape], [V]),
             {[Out], []} = wasm_canon:lift_params(Core, [Shape], Flats),
             Out
         end,
    ?assertEqual({<<"circle">>, infinity}, RT({<<"circle">>, infinity})),
    ?assertEqual({<<"circle">>, neg_infinity}, RT({<<"circle">>, neg_infinity})),
    ?assertEqual({<<"circle">>, {nan, 0, 16#8000000000000}},
                 RT({<<"circle">>, {nan, 0, 16#8000000000000}})).

%% A `(ptr, len)` a guest wrote whose element span runs past linear memory traps on
%% bounds before the element list is built, rather than driving an unbounded allocation.
%% Fail-first: lifting used `lists:seq(0, Len - 1)` with no ceiling, so an out-of-range
%% length allocated first and only a later per-element read failed (a generic error).
an_oversized_list_traps_on_bounds(Config) ->
    #{core := Core} = ?config(inst, Config),
    {ok, Pages} = wasm:memory_size(Core),
    %% One u32 element past the end of memory.
    Len = Pages * (65536 div 4) + 1,
    ?assertMatch({error, #{kind := out_of_bounds_memory_access}},
                 wasm_error:capture(
                   fun() -> wasm_canon:lift_params(Core, [{list, u32}], [0, Len]) end)).

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
