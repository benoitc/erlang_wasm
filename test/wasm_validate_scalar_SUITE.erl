%% @doc The stack effect of every scalar numeric instruction, and how the
%% validator finds it.
%%
%% Each opcode byte from 0x45 to 0xC4 is decoded, and three one-function
%% modules are built around it from bytes: one that gives it operands of the
%% right types and returns its result as the right type, which must validate,
%% and two with a wrong operand type or a wrong result type, which must fail
%% with a type mismatch. The expected types come from the opcode's name and
%% the specification, in `expected/1' below, not from the validator, so a wrong
%% clause in either is caught.
-module(wasm_validate_scalar_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() -> [every_scalar_opcode, scalar_lookup_skips_the_vector_table].

%% 0x45 `i32.eqz' to 0xC4 `i64.extend32_s'.
every_scalar_opcode(_Config) ->
    Checked = [check(B) || B <- lists:seq(16#45, 16#C4)],
    ?assertEqual(128, length(Checked)).

check(Byte) ->
    {[Op], end_, <<>>} = wasm_decode_code:instrs(<<Byte, 16#0B>>),
    {In, Out} = expected(Op),
    ?assertEqual({Byte, Op, ok}, {Byte, Op, validate(In, Out, Byte)}),
    ?assertMatch({Byte, Op, {error, #{kind := type_mismatch}}},
                 {Byte, Op, validate(wrong_first(In), Out, Byte)}),
    ?assertMatch({Byte, Op, {error, #{kind := type_mismatch}}},
                 {Byte, Op, validate(In, [other(hd(Out))], Byte)}),
    Op.

%% A scalar instruction is found without consulting the vector table: before,
%% every binary and comparison operator missed it and then had its name taken
%% apart as a string.
scalar_lookup_skips_the_vector_table(_Config) ->
    {module, wasm_validate_simd} = code:ensure_loaded(wasm_validate_simd),
    MFA = {wasm_validate_simd, type_of, 1},
    1 = erlang:trace_pattern(MFA, true, [call_count]),
    try
        ok = validate([i32, i32], [i32], 16#6A),
        ok = validate([f64, f64], [i32], 16#63),
        ok = validate([f32], [f32], 16#8C),
        ?assertEqual({call_count, 0}, erlang:trace_info(MFA, call_count))
    after
        erlang:trace_pattern(MFA, false, [call_count])
    end.

%%% ----------------------------------------------------------- expected ---

%% {Operands, Results} from the opcode's name, as the specification gives
%% them: `T.eqz' is [T] -> [i32]; a conversion `R.op_A' takes A and gives R;
%% an integer test or comparison gives i32; everything else keeps its type.
expected(Op) ->
    case string:split(atom_to_list(Op), "_") of
        [T, "eqz"] -> {[t(T)], [i32]};
        [T, Rest] -> by_name(t(T), Rest)
    end.

by_name(R, Rest) ->
    case string:lexemes(Rest, "_") of
        [Conv, A | _] when Conv =:= "wrap"; Conv =:= "extend"; Conv =:= "trunc";
                           Conv =:= "convert"; Conv =:= "demote";
                           Conv =:= "promote"; Conv =:= "reinterpret" ->
            {[t(A)], [R]};
        [Name | _] ->
            case lists:member(Name, ["eq", "ne", "lt", "gt", "le", "ge"]) of
                true -> {[R, R], [i32]};
                false ->
                    case lists:member(Name, unary(R)) of
                        true -> {[R], [R]};
                        false -> {[R, R], [R]}
                    end
            end
    end.

unary(T) when T =:= i32; T =:= i64 ->
    ["clz", "ctz", "popcnt", "extend8", "extend16", "extend32"];
unary(_) -> ["abs", "neg", "ceil", "floor", "trunc", "nearest", "sqrt"].

t("i32") -> i32; t("i64") -> i64; t("f32") -> f32; t("f64") -> f64.

%% A type the instruction cannot take in that position.
other(i32) -> i64; other(i64) -> i32; other(f32) -> f64; other(f64) -> f32.

wrong_first([T | Ts]) -> [other(T) | Ts].

%%% ------------------------------------------------------------- modules ---

%% One function whose body pushes its parameters in order, runs the opcode and
%% returns.
validate(In, Out, Byte) ->
    {ok, M} = wasm_decode:module(module(In, Out, Byte)),
    case wasm_validate:module(M) of
        {ok, _} -> ok;
        {error, _} = E -> E
    end.

module(In, Out, Byte) ->
    Type = [16#60, vec([vt(T) || T <- In]), vec([vt(T) || T <- Out])],
    Body = [0, [[16#20, I] || I <- lists:seq(0, length(In) - 1)], Byte, 16#0B],
    iolist_to_binary([<<0, "asm", 1:32/little>>,
                      1, sized(vec([Type])), 3, sized(vec([0])),
                      10, sized(vec([sized(Body)]))]).

vt(i32) -> 16#7F; vt(i64) -> 16#7E; vt(f32) -> 16#7D; vt(f64) -> 16#7C.

vec(Xs) -> [wasm_leb128:encode_u32(length(Xs)) | Xs].

sized(B) ->
    Bin = iolist_to_binary(B),
    [wasm_leb128:encode_u32(byte_size(Bin)), Bin].
