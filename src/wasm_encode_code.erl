-module(wasm_encode_code).
-moduledoc """
Instruction and expression encoding: `wasm_decode_code` run backwards.

Read this before you add an opcode: an instruction the decoder reads must be
written here too, and `wasm_encode_SUITE` fails for every decoded opcode this
cannot write back to the same bytes.

Each instruction is one clause, the opcode byte first, so the table reads
against the decoder's line for line. Nested bodies are written in place and
closed with `end` (`0x0B`); an `if` writes `else` (`0x05`) only when its else
branch has instructions, because the decoder reads `if ... end` and
`if ... else end` the same. A memory argument names its memory only when it
is not memory 0, for the same reason.
""".

-include("wasm.hrl").

%% A NaN's sign is one bit and its payload is non-zero and fits the mantissa.
-define(IS_NAN(S, P, Mask),
        (S =:= 0 orelse S =:= 1) andalso is_integer(P) andalso P > 0
            andalso P =< Mask).

-export([expr/1, instrs/1, instr/1, blocktype/1, mem_arg/1]).


%%% ---------------------------------------------------------- expressions ---

-doc "An expression: its instructions, then `end`.".
-spec expr([instr()]) -> iodata().
expr(Is) when is_list(Is) -> [instrs(Is), 16#0B];
expr(Is) -> unencodable(expr, Is).

-spec instrs([instr()]) -> iodata().
instrs(Is) -> [instr(I) || I <- Is].

-doc "A block signature: empty, one value type, or a type index.".
-spec blocktype(blocktype()) -> iodata() | byte().
blocktype(empty) -> 16#40;
blocktype({valtype, T}) -> wasm_encode:valtype(T);
blocktype({typeidx, N}) when is_integer(N), N >= 0, N =< 16#FFFFFFFF -> s33(N);
blocktype(BT) -> unencodable(blocktype, BT).

-doc """
A memory argument. Bit 6 of the alignment field says a memory index follows,
so it is set only for a memory other than 0.
""".
-spec mem_arg(memarg()) -> iodata().
mem_arg({Align, Offset, 0}) when is_integer(Align), Align >= 0, Align < 64 ->
    [Align, u64(Offset)];
mem_arg({Align, Offset, Mem}) when is_integer(Align), Align >= 0, Align < 64 ->
    [Align + 64, u32(Mem), u64(Offset)];
mem_arg(MA) ->
    unencodable(memarg, MA).

%%% ----------------------------------------------------------- dispatch ---

-doc "One instruction, as the decoder gives it.".
-spec instr(instr()) -> iodata() | byte().
%% - control ---------------------------------------------------------------
instr(unreachable) -> 16#00;
instr(nop) -> 16#01;
instr({block, BT, Body}) -> [16#02, blocktype(BT), expr(Body)];
instr({loop, BT, Body}) -> [16#03, blocktype(BT), expr(Body)];
instr({if_, BT, Then, []}) -> [16#04, blocktype(BT), expr(Then)];
instr({if_, BT, Then, Else}) when is_list(Then) ->
    [16#04, blocktype(BT), instrs(Then), 16#05, expr(Else)];
instr({br, L}) -> [16#0C, u32(L)];
instr({br_if, L}) -> [16#0D, u32(L)];
instr({br_table, Labels, Default}) ->
    [16#0E, wasm_encode:vec(Labels, fun u32/1), u32(Default)];
instr(return) -> 16#0F;
instr({call, F}) -> [16#10, u32(F)];
instr({call_indirect, T, Table}) -> [16#11, u32(T), u32(Table)];
instr({call_ref, T}) -> [16#14, u32(T)];

%% - reference types -------------------------------------------------------
%% `ref.null' names a heap type, so the reference must be nullable.
instr({ref_null, {ref, null, HT}}) -> [16#D0, wasm_encode:heaptype(HT)];
instr(ref_is_null) -> 16#D1;
instr({ref_func, F}) -> [16#D2, u32(F)];
instr(ref_eq) -> 16#D3;
instr(ref_as_non_null) -> 16#D4;
instr({br_on_null, L}) -> [16#D5, u32(L)];
instr({br_on_non_null, L}) -> [16#D6, u32(L)];

%% - parametric ------------------------------------------------------------
instr(drop) -> 16#1A;
instr({select, undefined}) -> 16#1B;
instr({select, Types}) -> [16#1C, wasm_encode:vec(Types, fun wasm_encode:valtype/1)];

%% - variables -------------------------------------------------------------
instr({local_get, I}) -> [16#20, u32(I)];
instr({local_set, I}) -> [16#21, u32(I)];
instr({local_tee, I}) -> [16#22, u32(I)];
instr({global_get, I}) -> [16#23, u32(I)];
instr({global_set, I}) -> [16#24, u32(I)];

%% - tables ----------------------------------------------------------------
instr({table_get, T}) -> [16#25, u32(T)];
instr({table_set, T}) -> [16#26, u32(T)];

%% - memory loads ----------------------------------------------------------
instr({i32_load, MA}) -> [16#28, mem_arg(MA)];
instr({i64_load, MA}) -> [16#29, mem_arg(MA)];
instr({f32_load, MA}) -> [16#2A, mem_arg(MA)];
instr({f64_load, MA}) -> [16#2B, mem_arg(MA)];
instr({i32_load8_s, MA}) -> [16#2C, mem_arg(MA)];
instr({i32_load8_u, MA}) -> [16#2D, mem_arg(MA)];
instr({i32_load16_s, MA}) -> [16#2E, mem_arg(MA)];
instr({i32_load16_u, MA}) -> [16#2F, mem_arg(MA)];
instr({i64_load8_s, MA}) -> [16#30, mem_arg(MA)];
instr({i64_load8_u, MA}) -> [16#31, mem_arg(MA)];
instr({i64_load16_s, MA}) -> [16#32, mem_arg(MA)];
instr({i64_load16_u, MA}) -> [16#33, mem_arg(MA)];
instr({i64_load32_s, MA}) -> [16#34, mem_arg(MA)];
instr({i64_load32_u, MA}) -> [16#35, mem_arg(MA)];

%% - memory stores ---------------------------------------------------------
instr({i32_store, MA}) -> [16#36, mem_arg(MA)];
instr({i64_store, MA}) -> [16#37, mem_arg(MA)];
instr({f32_store, MA}) -> [16#38, mem_arg(MA)];
instr({f64_store, MA}) -> [16#39, mem_arg(MA)];
instr({i32_store8, MA}) -> [16#3A, mem_arg(MA)];
instr({i32_store16, MA}) -> [16#3B, mem_arg(MA)];
instr({i64_store8, MA}) -> [16#3C, mem_arg(MA)];
instr({i64_store16, MA}) -> [16#3D, mem_arg(MA)];
instr({i64_store32, MA}) -> [16#3E, mem_arg(MA)];

instr({memory_size, M}) -> [16#3F, u32(M)];
instr({memory_grow, M}) -> [16#40, u32(M)];

%% - constants -------------------------------------------------------------
instr({i32_const, V}) -> [16#41, s32(V)];
instr({i64_const, V}) -> [16#42, s64(V)];
instr({f32_const, F}) -> [16#43, <<(float_bits(f32, F)):32/little>>];
instr({f64_const, F}) -> [16#44, <<(float_bits(f64, F)):64/little>>];

%% - i32 comparison --------------------------------------------------------
instr(i32_eqz) -> 16#45;
instr(i32_eq) -> 16#46;
instr(i32_ne) -> 16#47;
instr(i32_lt_s) -> 16#48;
instr(i32_lt_u) -> 16#49;
instr(i32_gt_s) -> 16#4A;
instr(i32_gt_u) -> 16#4B;
instr(i32_le_s) -> 16#4C;
instr(i32_le_u) -> 16#4D;
instr(i32_ge_s) -> 16#4E;
instr(i32_ge_u) -> 16#4F;

%% - i64 comparison --------------------------------------------------------
instr(i64_eqz) -> 16#50;
instr(i64_eq) -> 16#51;
instr(i64_ne) -> 16#52;
instr(i64_lt_s) -> 16#53;
instr(i64_lt_u) -> 16#54;
instr(i64_gt_s) -> 16#55;
instr(i64_gt_u) -> 16#56;
instr(i64_le_s) -> 16#57;
instr(i64_le_u) -> 16#58;
instr(i64_ge_s) -> 16#59;
instr(i64_ge_u) -> 16#5A;

%% - float comparison ------------------------------------------------------
instr(f32_eq) -> 16#5B;
instr(f32_ne) -> 16#5C;
instr(f32_lt) -> 16#5D;
instr(f32_gt) -> 16#5E;
instr(f32_le) -> 16#5F;
instr(f32_ge) -> 16#60;
instr(f64_eq) -> 16#61;
instr(f64_ne) -> 16#62;
instr(f64_lt) -> 16#63;
instr(f64_gt) -> 16#64;
instr(f64_le) -> 16#65;
instr(f64_ge) -> 16#66;

%% - i32 numeric -----------------------------------------------------------
instr(i32_clz) -> 16#67;
instr(i32_ctz) -> 16#68;
instr(i32_popcnt) -> 16#69;
instr(i32_add) -> 16#6A;
instr(i32_sub) -> 16#6B;
instr(i32_mul) -> 16#6C;
instr(i32_div_s) -> 16#6D;
instr(i32_div_u) -> 16#6E;
instr(i32_rem_s) -> 16#6F;
instr(i32_rem_u) -> 16#70;
instr(i32_and) -> 16#71;
instr(i32_or) -> 16#72;
instr(i32_xor) -> 16#73;
instr(i32_shl) -> 16#74;
instr(i32_shr_s) -> 16#75;
instr(i32_shr_u) -> 16#76;
instr(i32_rotl) -> 16#77;
instr(i32_rotr) -> 16#78;

%% - i64 numeric -----------------------------------------------------------
instr(i64_clz) -> 16#79;
instr(i64_ctz) -> 16#7A;
instr(i64_popcnt) -> 16#7B;
instr(i64_add) -> 16#7C;
instr(i64_sub) -> 16#7D;
instr(i64_mul) -> 16#7E;
instr(i64_div_s) -> 16#7F;
instr(i64_div_u) -> 16#80;
instr(i64_rem_s) -> 16#81;
instr(i64_rem_u) -> 16#82;
instr(i64_and) -> 16#83;
instr(i64_or) -> 16#84;
instr(i64_xor) -> 16#85;
instr(i64_shl) -> 16#86;
instr(i64_shr_s) -> 16#87;
instr(i64_shr_u) -> 16#88;
instr(i64_rotl) -> 16#89;
instr(i64_rotr) -> 16#8A;

%% - f32 numeric -----------------------------------------------------------
instr(f32_abs) -> 16#8B;
instr(f32_neg) -> 16#8C;
instr(f32_ceil) -> 16#8D;
instr(f32_floor) -> 16#8E;
instr(f32_trunc) -> 16#8F;
instr(f32_nearest) -> 16#90;
instr(f32_sqrt) -> 16#91;
instr(f32_add) -> 16#92;
instr(f32_sub) -> 16#93;
instr(f32_mul) -> 16#94;
instr(f32_div) -> 16#95;
instr(f32_min) -> 16#96;
instr(f32_max) -> 16#97;
instr(f32_copysign) -> 16#98;

%% - f64 numeric -----------------------------------------------------------
instr(f64_abs) -> 16#99;
instr(f64_neg) -> 16#9A;
instr(f64_ceil) -> 16#9B;
instr(f64_floor) -> 16#9C;
instr(f64_trunc) -> 16#9D;
instr(f64_nearest) -> 16#9E;
instr(f64_sqrt) -> 16#9F;
instr(f64_add) -> 16#A0;
instr(f64_sub) -> 16#A1;
instr(f64_mul) -> 16#A2;
instr(f64_div) -> 16#A3;
instr(f64_min) -> 16#A4;
instr(f64_max) -> 16#A5;
instr(f64_copysign) -> 16#A6;

%% - conversions -----------------------------------------------------------
instr(i32_wrap_i64) -> 16#A7;
instr(i32_trunc_f32_s) -> 16#A8;
instr(i32_trunc_f32_u) -> 16#A9;
instr(i32_trunc_f64_s) -> 16#AA;
instr(i32_trunc_f64_u) -> 16#AB;
instr(i64_extend_i32_s) -> 16#AC;
instr(i64_extend_i32_u) -> 16#AD;
instr(i64_trunc_f32_s) -> 16#AE;
instr(i64_trunc_f32_u) -> 16#AF;
instr(i64_trunc_f64_s) -> 16#B0;
instr(i64_trunc_f64_u) -> 16#B1;
instr(f32_convert_i32_s) -> 16#B2;
instr(f32_convert_i32_u) -> 16#B3;
instr(f32_convert_i64_s) -> 16#B4;
instr(f32_convert_i64_u) -> 16#B5;
instr(f32_demote_f64) -> 16#B6;
instr(f64_convert_i32_s) -> 16#B7;
instr(f64_convert_i32_u) -> 16#B8;
instr(f64_convert_i64_s) -> 16#B9;
instr(f64_convert_i64_u) -> 16#BA;
instr(f64_promote_f32) -> 16#BB;
instr(i32_reinterpret_f32) -> 16#BC;
instr(i64_reinterpret_f64) -> 16#BD;
instr(f32_reinterpret_i32) -> 16#BE;
instr(f64_reinterpret_i64) -> 16#BF;

%% - sign extension --------------------------------------------------------
instr(i32_extend8_s) -> 16#C0;
instr(i32_extend16_s) -> 16#C1;
instr(i64_extend8_s) -> 16#C2;
instr(i64_extend16_s) -> 16#C3;
instr(i64_extend32_s) -> 16#C4;

%% -- 0xFC prefix: saturating truncation, bulk memory, table ops ------------
instr(i32_trunc_sat_f32_s) -> [16#FC, 0];
instr(i32_trunc_sat_f32_u) -> [16#FC, 1];
instr(i32_trunc_sat_f64_s) -> [16#FC, 2];
instr(i32_trunc_sat_f64_u) -> [16#FC, 3];
instr(i64_trunc_sat_f32_s) -> [16#FC, 4];
instr(i64_trunc_sat_f32_u) -> [16#FC, 5];
instr(i64_trunc_sat_f64_s) -> [16#FC, 6];
instr(i64_trunc_sat_f64_u) -> [16#FC, 7];
instr({memory_init, D, M}) -> [16#FC, 8, u32(D), u32(M)];
instr({data_drop, D}) -> [16#FC, 9, u32(D)];
instr({memory_copy, Dst, Src}) -> [16#FC, 10, u32(Dst), u32(Src)];
instr({memory_fill, M}) -> [16#FC, 11, u32(M)];
instr({table_init, E, T}) -> [16#FC, 12, u32(E), u32(T)];
instr({elem_drop, E}) -> [16#FC, 13, u32(E)];
instr({table_copy, Dst, Src}) -> [16#FC, 14, u32(Dst), u32(Src)];
instr({table_grow, T}) -> [16#FC, 15, u32(T)];
instr({table_size, T}) -> [16#FC, 16, u32(T)];
instr({table_fill, T}) -> [16#FC, 17, u32(T)];

%% - unknown ---------------------------------------------------------------
instr(I) -> unencodable(instr, I).

%%% --------------------------------------------------------------- helpers ---

%% A constant goes back as the exact bits it was read from, NaN payload and
%% sign included. A float that 32 bits cannot hold exactly would be rounded,
%% and a payload wider than the mantissa would spill into the exponent, so
%% both are refused rather than written as some other number.
float_bits(f32, F) when is_float(F) ->
    Bits = try wasm_num:f32_to_bits(F) catch error:_ -> unencodable(f32, F) end,
    case wasm_num:f32_from_bits(Bits) =:= F of
        true -> Bits;
        false -> unencodable(f32, F)
    end;
float_bits(f64, F) when is_float(F) ->
    wasm_num:f64_to_bits(F);
float_bits(f32, F) when F =:= infinity; F =:= neg_infinity ->
    wasm_num:f32_to_bits(F);
float_bits(f64, F) when F =:= infinity; F =:= neg_infinity ->
    wasm_num:f64_to_bits(F);
float_bits(f32, {nan, S, P} = F) when ?IS_NAN(S, P, 16#7FFFFF) ->
    wasm_num:f32_to_bits(F);
float_bits(f64, {nan, S, P} = F) when ?IS_NAN(S, P, 16#FFFFFFFFFFFFF) ->
    wasm_num:f64_to_bits(F);
float_bits(W, F) ->
    unencodable(W, F).

u32(V) -> wasm_encode:u32(V).
u64(V) -> wasm_encode:u64(V).
s32(V) -> wasm_encode:s32(V).
s33(V) -> wasm_encode:s33(V).
s64(V) -> wasm_encode:s64(V).
unencodable(What, V) -> wasm_encode:unencodable(What, V).
