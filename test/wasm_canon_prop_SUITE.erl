-module(wasm_canon_prop_SUITE).
-moduledoc """
Generated values round-trip through the Canonical ABI.

`wasm_component_vectors_SUITE` echoes a handful of hand-picked values per WIT type
through the `vectors` guest and asserts each comes back equal. This does the same
with generated values: for every type the guest echoes, a value the type admits is
lowered into the guest's memory, lifted by the guest, returned, and lifted again by
the call. If lower and lift are inverses the value returns unchanged, so a mismatch
in field order, alignment, sign extension, string encoding or the list/variant/flag
layout fails a case that hand-picked inputs would miss.

Values are generated so they are exactly representable: floats are small multiples
of a negative power of two, chars are Unicode scalar values, and flags keep their
declared order, so a faithful round-trip is bit-exact and the property is `=:=`.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("proper/include/proper.hrl").

-define(NUMTESTS, 100).

all() ->
    [integers, floats_bool_char, strings_and_lists, compound_types].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture_path()),
    [{component, Bin} | Config].

end_per_suite(_Config) -> ok.

%% A bare instance is scoped to the process that created it, and the property runs
%% in this process, so instantiate per case rather than in init_per_suite.
init_per_testcase(_Case, Config) ->
    {ok, Inst} = wasm_component:instantiate(?config(component, Config)),
    [{inst, Inst} | Config].

end_per_testcase(_Case, _Config) -> ok.

%%% --------------------------------------------------------------- cases ---

integers(Config) ->
    Inst = ?config(inst, Config),
    run(?FORALL({E, D, V}, integer_case(), echoes(Inst, E, D, V))).

floats_bool_char(Config) ->
    Inst = ?config(inst, Config),
    run(?FORALL({E, D, V}, oneof(
                  [{<<"echo-f32">>, f32, f32()},
                   {<<"echo-f64">>, f64, f64()},
                   {<<"echo-bool">>, bool, boolean()},
                   {<<"echo-char">>, char, unicode_scalar()}]),
                echoes(Inst, E, D, V))).

strings_and_lists(Config) ->
    Inst = ?config(inst, Config),
    run(?FORALL({E, D, V}, oneof(
                  [{<<"echo-string">>, string, utf8_bin()},
                   {<<"echo-list-u32">>, {list, u32}, list(uint(32))},
                   {<<"echo-list-string">>, {list, string}, list(utf8_bin())}]),
                echoes(Inst, E, D, V))).

compound_types(Config) ->
    Inst = ?config(inst, Config),
    run(?FORALL({E, D, V}, compound_case(), echoes(Inst, E, D, V))).

%%% ------------------------------------------------------------ property ---

%% The value survives the round-trip through the guest unchanged.
echoes(Inst, Export, Desc, Value) ->
    {ok, Value} =:= wasm_component:call(Inst, Export, {[Desc], Desc}, [Value]).

run(P) ->
    ?assert(proper:quickcheck(P, [{numtests, ?NUMTESTS}, {to_file, user}])).

%%% ---------------------------------------------------------- generators ---

integer_case() ->
    oneof(
      [{<<"echo-u8">>, u8, uint(8)},
       {<<"echo-u16">>, u16, uint(16)},
       {<<"echo-u32">>, u32, uint(32)},
       {<<"echo-u64">>, u64, uint(64)},
       {<<"echo-s8">>, s8, sint(8)},
       {<<"echo-s16">>, s16, sint(16)},
       {<<"echo-s32">>, s32, sint(32)},
       {<<"echo-s64">>, s64, sint(64)}]).

compound_case() ->
    oneof(
      [{<<"echo-point">>, point(), point_val()},
       {<<"echo-tuple">>, {tuple, [u8, string, bool]},
        {uint(8), utf8_bin(), boolean()}},
       {<<"echo-shape">>, shape(), shape_val()},
       {<<"echo-color">>, color(), oneof([<<"red">>, <<"green">>, <<"blue">>])},
       {<<"echo-option">>, {option, u32},
        oneof([none, {some, uint(32)}])},
       {<<"echo-result">>, {result, u32, string},
        oneof([{ok, uint(32)}, {error, utf8_bin()}])},
       {<<"echo-perms">>, perms(), perms_val()}]).

uint(Bits) -> integer(0, (1 bsl Bits) - 1).
sint(Bits) -> integer(-(1 bsl (Bits - 1)), (1 bsl (Bits - 1)) - 1).

%% Exactly representable in binary32 and binary64: a small integer over a power of
%% two, so lowering to f32 and lifting loses nothing and `=:=` holds.
f32() -> ?LET(N, integer(-100000, 100000), N / 8).
f64() -> ?LET(N, integer(-1000000, 1000000), N / 16).

%% A Unicode scalar value: any codepoint except the surrogate range.
unicode_scalar() ->
    oneof([integer(0, 16#D7FF), integer(16#E000, 16#10FFFF)]).

utf8_bin() ->
    ?LET(Cs, list(unicode_scalar()), unicode:characters_to_binary(Cs)).

point() -> {record, [{<<"x">>, s32}, {<<"y">>, s32}]}.
point_val() ->
    ?LET({X, Y}, {sint(32), sint(32)}, #{<<"x">> => X, <<"y">> => Y}).

shape() ->
    {variant, [{<<"circle">>, f64}, {<<"rect">>, point()}, {<<"unit">>, none}]}.
shape_val() ->
    oneof([{<<"circle">>, f64()},
           {<<"rect">>, point_val()},
           {<<"unit">>, undefined}]).

color() -> {enum, [<<"red">>, <<"green">>, <<"blue">>]}.

perms() -> {flags, [<<"read">>, <<"write">>, <<"exec">>]}.
%% A subset in declared order, which is how a lifted flags set comes back.
perms_val() ->
    ?LET({R, W, X}, {boolean(), boolean(), boolean()},
         [N || {true, N} <- [{R, <<"read">>}, {W, <<"write">>}, {X, <<"exec">>}]]).

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "vectors.component.wasm"]).
