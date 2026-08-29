-module(wasm_decode_code).
-moduledoc """
Instruction and expression decoding.

Read this before you add an opcode. Block bodies nest directly rather than being flattened with `end` markers.
WebAssembly control flow is structured, so nesting is lossless, and it lets
`wasm_ir` build continuation lists without a separate label-resolution pass.
A flat stream would have to be re-scanned to pair every `block` with its
`end` anyway.

The opcode dispatch is a dense integer match, which the BEAM compiler turns
into a jump table. Writing one clause per opcode is verbose but it is the
shape the compiler optimises best, and it keeps each opcode's immediate
operands visible at the point of decoding.
""".

-include("wasm.hrl").

-export([expr/1, instrs/1, blocktype/1]).
-export([mem_arg/2]).

%%% ---------------------------------------------------------- expressions ---

-doc "Decode an expression: instructions up to and including the `end` byte.".
-spec expr(binary()) -> {[instr()], binary()}.
expr(Bin) ->
    case instrs(Bin, []) of
        {Is, end_, Rest} -> {Is, Rest};
        {_, else_, _} ->
            wasm_error:malformed(unexpected_else, <<"unexpected else">>)
    end.

-spec instrs(binary()) -> {[instr()], end_ | else_, binary()}.
instrs(Bin) -> instrs(Bin, []).

instrs(<<16#0B, Rest/binary>>, Acc) -> {lists:reverse(Acc), end_, Rest};
instrs(<<16#05, Rest/binary>>, Acc) -> {lists:reverse(Acc), else_, Rest};
instrs(<<Op:8, Rest/binary>>, Acc) ->
    {I, Rest1} = instr(Op, Rest),
    instrs(Rest1, [I | Acc]);
instrs(<<>>, _Acc) ->
    wasm_error:malformed(unexpected_end,
                         <<"unexpected end of section or function">>).

%% Body of a block or loop: must terminate with `end', never `else'.
block_body(Bin) ->
    case instrs(Bin, []) of
        {Is, end_, Rest} -> {Is, Rest};
        {_, else_, _} ->
            wasm_error:malformed(unexpected_else, <<"unexpected else">>)
    end.

-doc """
Block signature. Value types are encoded as negative s33 values, type
indices as non-negative ones, so a single signed read distinguishes them.
""".
-spec blocktype(binary()) -> {blocktype(), binary()}.
blocktype(Bin) ->
    {X, Rest} = wasm_leb128:s33(Bin),
    case X of
        -64 -> {empty, Rest};
        -1  -> {{valtype, i32}, Rest};
        -2  -> {{valtype, i64}, Rest};
        -3  -> {{valtype, f32}, Rest};
        -4  -> {{valtype, f64}, Rest};
        -5  -> {{valtype, v128}, Rest};
        -16 -> {{valtype, ?FUNCREF}, Rest};
        -17 -> {{valtype, ?EXTERNREF}, Rest};
        -13 -> {{valtype, {ref, null, nofunc}}, Rest};
        -14 -> {{valtype, {ref, null, noextern}}, Rest};
        -18 -> {{valtype, {ref, null, any}}, Rest};
        -19 -> {{valtype, {ref, null, eq}}, Rest};
        -20 -> {{valtype, {ref, null, i31}}, Rest};
        -21 -> {{valtype, {ref, null, struct}}, Rest};
        -22 -> {{valtype, {ref, null, array}}, Rest};
        -15 -> {{valtype, {ref, null, none}}, Rest};
        -23 -> {{valtype, ?EXNREF}, Rest};
        -12 -> {{valtype, {ref, null, noexn}}, Rest};
        %% A block may result in any value type, including the general
        %% reference forms, whose heap type follows the prefix.
        -29 -> ref_blocktype(null, Rest);
        -28 -> ref_blocktype(nonull, Rest);
        N when N >= 0 -> {{typeidx, N}, Rest};
        _ -> wasm_error:malformed(malformed_block_type,
                                  <<"malformed block type">>, #{code => X})
    end.

ref_blocktype(Null, Bin) ->
    {HT, Rest} = wasm_decode:heaptype(Bin),
    {{valtype, {ref, Null, HT}}, Rest}.

%%% ----------------------------------------------------------- dispatch ---

%% - control ---------------------------------------------------------------
instr(16#00, R) -> {unreachable, R};
instr(16#01, R) -> {nop, R};
instr(16#02, R0) ->
    {BT, R1} = blocktype(R0),
    {Body, R2} = block_body(R1),
    {{block, BT, Body}, R2};
instr(16#03, R0) ->
    {BT, R1} = blocktype(R0),
    {Body, R2} = block_body(R1),
    {{loop, BT, Body}, R2};
instr(16#04, R0) ->
    {BT, R1} = blocktype(R0),
    case instrs(R1, []) of
        {Then, end_, R2} ->
            {{if_, BT, Then, []}, R2};
        {Then, else_, R2} ->
            {Else, R3} = block_body(R2),
            {{if_, BT, Then, Else}, R3}
    end;
%% - exceptions ------------------------------------------------------------
instr(16#08, R0) -> u32_arg(R0, fun(T) -> {throw, T} end);
instr(16#0A, R) -> {throw_ref, R};
%% `try_table' is a block that additionally carries a list of handlers. Each
%% names a label to branch to, and whether it matches one tag or everything,
%% and whether the branch carries the exception itself as an `exnref'.
instr(16#1F, R0) ->
    {BT, R1} = blocktype(R0),
    {Catches, R2} = vec_catch(R1),
    {Body, R3} = block_body(R2),
    {{try_table, BT, Catches, Body}, R3};

instr(16#0C, R0) -> u32_arg(R0, fun(L) -> {br, L} end);
instr(16#0D, R0) -> u32_arg(R0, fun(L) -> {br_if, L} end);
instr(16#0E, R0) ->
    {Labels, R1} = vec_u32(R0),
    {Default, R2} = wasm_leb128:u32(R1),
    {{br_table, Labels, Default}, R2};
instr(16#0F, R) -> {return, R};
instr(16#10, R0) -> u32_arg(R0, fun(F) -> {call, F} end);
instr(16#11, R0) ->
    {TypeIdx, R1} = wasm_leb128:u32(R0),
    {TableIdx, R2} = wasm_leb128:u32(R1),
    {{call_indirect, TypeIdx, TableIdx}, R2};
%% Tail calls.
instr(16#12, R0) -> u32_arg(R0, fun(F) -> {return_call, F} end);
instr(16#13, R0) ->
    {TypeIdx, R1} = wasm_leb128:u32(R0),
    {TableIdx, R2} = wasm_leb128:u32(R1),
    {{return_call_indirect, TypeIdx, TableIdx}, R2};
%% Calls through a typed function reference. The callee is on the stack rather
%% than named by an index, so the type immediate is what gives the call its
%% signature.
instr(16#14, R0) -> u32_arg(R0, fun(T) -> {call_ref, T} end);
instr(16#15, R0) -> u32_arg(R0, fun(T) -> {return_call_ref, T} end);

%% - reference types -------------------------------------------------------
%% `ref.null' names a *heap* type: `ref.null func' is `0xD0 0x70' and
%% `ref.null 0' is `0xD0 0x00', a type index with no reference-type prefix.
instr(16#D0, R0) ->
    {HT, R1} = wasm_decode:heaptype(R0),
    {{ref_null, {ref, null, HT}}, R1};
instr(16#D1, R) -> {ref_is_null, R};
instr(16#D2, R0) -> u32_arg(R0, fun(F) -> {ref_func, F} end);
instr(16#D3, R) -> {ref_eq, R};
instr(16#D4, R) -> {ref_as_non_null, R};
instr(16#D5, R0) -> u32_arg(R0, fun(L) -> {br_on_null, L} end);
instr(16#D6, R0) -> u32_arg(R0, fun(L) -> {br_on_non_null, L} end);

%% - parametric ------------------------------------------------------------
instr(16#1A, R) -> {drop, R};
instr(16#1B, R) -> {{select, undefined}, R};
instr(16#1C, R0) ->
    {Types, R1} = vec_valtype(R0),
    {{select, Types}, R1};

%% - variables -------------------------------------------------------------
instr(16#20, R) -> u32_arg(R, fun(I) -> {local_get, I} end);
instr(16#21, R) -> u32_arg(R, fun(I) -> {local_set, I} end);
instr(16#22, R) -> u32_arg(R, fun(I) -> {local_tee, I} end);
instr(16#23, R) -> u32_arg(R, fun(I) -> {global_get, I} end);
instr(16#24, R) -> u32_arg(R, fun(I) -> {global_set, I} end);

%% - tables ----------------------------------------------------------------
instr(16#25, R) -> u32_arg(R, fun(I) -> {table_get, I} end);
instr(16#26, R) -> u32_arg(R, fun(I) -> {table_set, I} end);

%% - memory loads ----------------------------------------------------------
instr(16#28, R) -> mem_arg(R, i32_load);
instr(16#29, R) -> mem_arg(R, i64_load);
instr(16#2A, R) -> mem_arg(R, f32_load);
instr(16#2B, R) -> mem_arg(R, f64_load);
instr(16#2C, R) -> mem_arg(R, i32_load8_s);
instr(16#2D, R) -> mem_arg(R, i32_load8_u);
instr(16#2E, R) -> mem_arg(R, i32_load16_s);
instr(16#2F, R) -> mem_arg(R, i32_load16_u);
instr(16#30, R) -> mem_arg(R, i64_load8_s);
instr(16#31, R) -> mem_arg(R, i64_load8_u);
instr(16#32, R) -> mem_arg(R, i64_load16_s);
instr(16#33, R) -> mem_arg(R, i64_load16_u);
instr(16#34, R) -> mem_arg(R, i64_load32_s);
instr(16#35, R) -> mem_arg(R, i64_load32_u);

%% - memory stores ---------------------------------------------------------
instr(16#36, R) -> mem_arg(R, i32_store);
instr(16#37, R) -> mem_arg(R, i64_store);
instr(16#38, R) -> mem_arg(R, f32_store);
instr(16#39, R) -> mem_arg(R, f64_store);
instr(16#3A, R) -> mem_arg(R, i32_store8);
instr(16#3B, R) -> mem_arg(R, i32_store16);
instr(16#3C, R) -> mem_arg(R, i64_store8);
instr(16#3D, R) -> mem_arg(R, i64_store16);
instr(16#3E, R) -> mem_arg(R, i64_store32);

%% The trailing byte is a memory index, reserved as 0 until the multiple
%% memories proposal. Decoded rather than assumed so the field already exists.
instr(16#3F, R0) ->
    {M, R1} = wasm_leb128:u32(R0),
    {{memory_size, M}, R1};
instr(16#40, R0) ->
    {M, R1} = wasm_leb128:u32(R0),
    {{memory_grow, M}, R1};

%% - constants -------------------------------------------------------------
instr(16#41, R0) ->
    {V, R1} = wasm_leb128:s32(R0),
    {{i32_const, V}, R1};
instr(16#42, R0) ->
    {V, R1} = wasm_leb128:s64(R0),
    {{i64_const, V}, R1};
instr(16#43, <<Bits:32/little, R/binary>>) ->
    {{f32_const, wasm_num:f32_from_bits(Bits)}, R};
instr(16#43, _) ->
    wasm_error:malformed(unexpected_end, <<"unexpected end">>, #{reading => f32});
instr(16#44, <<Bits:64/little, R/binary>>) ->
    {{f64_const, wasm_num:f64_from_bits(Bits)}, R};
instr(16#44, _) ->
    wasm_error:malformed(unexpected_end, <<"unexpected end">>, #{reading => f64});

%% - i32 comparison --------------------------------------------------------
instr(16#45, R) -> {i32_eqz, R};
instr(16#46, R) -> {i32_eq, R};
instr(16#47, R) -> {i32_ne, R};
instr(16#48, R) -> {i32_lt_s, R};
instr(16#49, R) -> {i32_lt_u, R};
instr(16#4A, R) -> {i32_gt_s, R};
instr(16#4B, R) -> {i32_gt_u, R};
instr(16#4C, R) -> {i32_le_s, R};
instr(16#4D, R) -> {i32_le_u, R};
instr(16#4E, R) -> {i32_ge_s, R};
instr(16#4F, R) -> {i32_ge_u, R};

%% - i64 comparison --------------------------------------------------------
instr(16#50, R) -> {i64_eqz, R};
instr(16#51, R) -> {i64_eq, R};
instr(16#52, R) -> {i64_ne, R};
instr(16#53, R) -> {i64_lt_s, R};
instr(16#54, R) -> {i64_lt_u, R};
instr(16#55, R) -> {i64_gt_s, R};
instr(16#56, R) -> {i64_gt_u, R};
instr(16#57, R) -> {i64_le_s, R};
instr(16#58, R) -> {i64_le_u, R};
instr(16#59, R) -> {i64_ge_s, R};
instr(16#5A, R) -> {i64_ge_u, R};

%% - float comparison ------------------------------------------------------
instr(16#5B, R) -> {f32_eq, R};
instr(16#5C, R) -> {f32_ne, R};
instr(16#5D, R) -> {f32_lt, R};
instr(16#5E, R) -> {f32_gt, R};
instr(16#5F, R) -> {f32_le, R};
instr(16#60, R) -> {f32_ge, R};
instr(16#61, R) -> {f64_eq, R};
instr(16#62, R) -> {f64_ne, R};
instr(16#63, R) -> {f64_lt, R};
instr(16#64, R) -> {f64_gt, R};
instr(16#65, R) -> {f64_le, R};
instr(16#66, R) -> {f64_ge, R};

%% - i32 numeric -----------------------------------------------------------
instr(16#67, R) -> {i32_clz, R};
instr(16#68, R) -> {i32_ctz, R};
instr(16#69, R) -> {i32_popcnt, R};
instr(16#6A, R) -> {i32_add, R};
instr(16#6B, R) -> {i32_sub, R};
instr(16#6C, R) -> {i32_mul, R};
instr(16#6D, R) -> {i32_div_s, R};
instr(16#6E, R) -> {i32_div_u, R};
instr(16#6F, R) -> {i32_rem_s, R};
instr(16#70, R) -> {i32_rem_u, R};
instr(16#71, R) -> {i32_and, R};
instr(16#72, R) -> {i32_or, R};
instr(16#73, R) -> {i32_xor, R};
instr(16#74, R) -> {i32_shl, R};
instr(16#75, R) -> {i32_shr_s, R};
instr(16#76, R) -> {i32_shr_u, R};
instr(16#77, R) -> {i32_rotl, R};
instr(16#78, R) -> {i32_rotr, R};

%% - i64 numeric -----------------------------------------------------------
instr(16#79, R) -> {i64_clz, R};
instr(16#7A, R) -> {i64_ctz, R};
instr(16#7B, R) -> {i64_popcnt, R};
instr(16#7C, R) -> {i64_add, R};
instr(16#7D, R) -> {i64_sub, R};
instr(16#7E, R) -> {i64_mul, R};
instr(16#7F, R) -> {i64_div_s, R};
instr(16#80, R) -> {i64_div_u, R};
instr(16#81, R) -> {i64_rem_s, R};
instr(16#82, R) -> {i64_rem_u, R};
instr(16#83, R) -> {i64_and, R};
instr(16#84, R) -> {i64_or, R};
instr(16#85, R) -> {i64_xor, R};
instr(16#86, R) -> {i64_shl, R};
instr(16#87, R) -> {i64_shr_s, R};
instr(16#88, R) -> {i64_shr_u, R};
instr(16#89, R) -> {i64_rotl, R};
instr(16#8A, R) -> {i64_rotr, R};

%% - f32 numeric -----------------------------------------------------------
instr(16#8B, R) -> {f32_abs, R};
instr(16#8C, R) -> {f32_neg, R};
instr(16#8D, R) -> {f32_ceil, R};
instr(16#8E, R) -> {f32_floor, R};
instr(16#8F, R) -> {f32_trunc, R};
instr(16#90, R) -> {f32_nearest, R};
instr(16#91, R) -> {f32_sqrt, R};
instr(16#92, R) -> {f32_add, R};
instr(16#93, R) -> {f32_sub, R};
instr(16#94, R) -> {f32_mul, R};
instr(16#95, R) -> {f32_div, R};
instr(16#96, R) -> {f32_min, R};
instr(16#97, R) -> {f32_max, R};
instr(16#98, R) -> {f32_copysign, R};

%% - f64 numeric -----------------------------------------------------------
instr(16#99, R) -> {f64_abs, R};
instr(16#9A, R) -> {f64_neg, R};
instr(16#9B, R) -> {f64_ceil, R};
instr(16#9C, R) -> {f64_floor, R};
instr(16#9D, R) -> {f64_trunc, R};
instr(16#9E, R) -> {f64_nearest, R};
instr(16#9F, R) -> {f64_sqrt, R};
instr(16#A0, R) -> {f64_add, R};
instr(16#A1, R) -> {f64_sub, R};
instr(16#A2, R) -> {f64_mul, R};
instr(16#A3, R) -> {f64_div, R};
instr(16#A4, R) -> {f64_min, R};
instr(16#A5, R) -> {f64_max, R};
instr(16#A6, R) -> {f64_copysign, R};

%% - conversions -----------------------------------------------------------
instr(16#A7, R) -> {i32_wrap_i64, R};
instr(16#A8, R) -> {i32_trunc_f32_s, R};
instr(16#A9, R) -> {i32_trunc_f32_u, R};
instr(16#AA, R) -> {i32_trunc_f64_s, R};
instr(16#AB, R) -> {i32_trunc_f64_u, R};
instr(16#AC, R) -> {i64_extend_i32_s, R};
instr(16#AD, R) -> {i64_extend_i32_u, R};
instr(16#AE, R) -> {i64_trunc_f32_s, R};
instr(16#AF, R) -> {i64_trunc_f32_u, R};
instr(16#B0, R) -> {i64_trunc_f64_s, R};
instr(16#B1, R) -> {i64_trunc_f64_u, R};
instr(16#B2, R) -> {f32_convert_i32_s, R};
instr(16#B3, R) -> {f32_convert_i32_u, R};
instr(16#B4, R) -> {f32_convert_i64_s, R};
instr(16#B5, R) -> {f32_convert_i64_u, R};
instr(16#B6, R) -> {f32_demote_f64, R};
instr(16#B7, R) -> {f64_convert_i32_s, R};
instr(16#B8, R) -> {f64_convert_i32_u, R};
instr(16#B9, R) -> {f64_convert_i64_s, R};
instr(16#BA, R) -> {f64_convert_i64_u, R};
instr(16#BB, R) -> {f64_promote_f32, R};
instr(16#BC, R) -> {i32_reinterpret_f32, R};
instr(16#BD, R) -> {i64_reinterpret_f64, R};
instr(16#BE, R) -> {f32_reinterpret_i32, R};
instr(16#BF, R) -> {f64_reinterpret_i64, R};

%% - sign extension --------------------------------------------------------
instr(16#C0, R) -> {i32_extend8_s, R};
instr(16#C1, R) -> {i32_extend16_s, R};
instr(16#C2, R) -> {i64_extend8_s, R};
instr(16#C3, R) -> {i64_extend16_s, R};
instr(16#C4, R) -> {i64_extend32_s, R};

%% -- 0xFC prefix: saturating truncation, bulk memory, table ops ------------
instr(16#FC, R0) ->
    {Sub, R1} = wasm_leb128:u32(R0),
    instr_fc(Sub, R1);

%% -- 0xFB prefix: garbage collection ---------------------------------------
instr(16#FB, R0) ->
    wasm_decode_gc:instr(R0);

%% -- 0xFD prefix: fixed-width SIMD -----------------------------------------
%% Its own module: the vector opcode space is larger than every other prefix
%% put together.
instr(16#FD, R0) ->
    wasm_decode_simd:instr(R0);

%% -- 0xFE prefix: threads --------------------------------------------------
instr(16#FE, R0) ->
    wasm_decode_atomic:instr(R0);

%% - unknown ---------------------------------------------------------------
instr(Op, _) ->
    wasm_error:malformed(illegal_opcode, <<"illegal opcode">>, #{opcode => Op}).

%%% -------------------------------------------------------- 0xFC subopcodes ---

instr_fc(0, R) -> {i32_trunc_sat_f32_s, R};
instr_fc(1, R) -> {i32_trunc_sat_f32_u, R};
instr_fc(2, R) -> {i32_trunc_sat_f64_s, R};
instr_fc(3, R) -> {i32_trunc_sat_f64_u, R};
instr_fc(4, R) -> {i64_trunc_sat_f32_s, R};
instr_fc(5, R) -> {i64_trunc_sat_f32_u, R};
instr_fc(6, R) -> {i64_trunc_sat_f64_s, R};
instr_fc(7, R) -> {i64_trunc_sat_f64_u, R};
instr_fc(8, R0) ->
    {DataIdx, R1} = wasm_leb128:u32(R0),
    {MemIdx, R2} = wasm_leb128:u32(R1),
    {{memory_init, DataIdx, MemIdx}, R2};
instr_fc(9, R0) -> u32_arg(R0, fun(D) -> {data_drop, D} end);
instr_fc(10, R0) ->
    {Dst, R1} = wasm_leb128:u32(R0),
    {Src, R2} = wasm_leb128:u32(R1),
    {{memory_copy, Dst, Src}, R2};
instr_fc(11, R0) -> u32_arg(R0, fun(M) -> {memory_fill, M} end);
instr_fc(12, R0) ->
    {ElemIdx, R1} = wasm_leb128:u32(R0),
    {TableIdx, R2} = wasm_leb128:u32(R1),
    {{table_init, ElemIdx, TableIdx}, R2};
instr_fc(13, R0) -> u32_arg(R0, fun(E) -> {elem_drop, E} end);
instr_fc(14, R0) ->
    {Dst, R1} = wasm_leb128:u32(R0),
    {Src, R2} = wasm_leb128:u32(R1),
    {{table_copy, Dst, Src}, R2};
instr_fc(15, R0) -> u32_arg(R0, fun(T) -> {table_grow, T} end);
instr_fc(16, R0) -> u32_arg(R0, fun(T) -> {table_size, T} end);
instr_fc(17, R0) -> u32_arg(R0, fun(T) -> {table_fill, T} end);
instr_fc(Sub, _) ->
    wasm_error:malformed(illegal_opcode, <<"illegal opcode">>,
                         #{opcode => 16#FC, sub => Sub}).

%% A handler is `{Kind, TagIdx | undefined, LabelIdx}'.
vec_catch(Bin) ->
    {N, Rest} = wasm_leb128:u32(Bin),
    guard_count(N, Rest),
    vec_catch(N, Rest, []).

vec_catch(0, Rest, Acc) -> {lists:reverse(Acc), Rest};
vec_catch(N, Bin, Acc) ->
    {C, Rest} = catch_clause(Bin),
    vec_catch(N - 1, Rest, [C | Acc]).

catch_clause(<<16#00, R0/binary>>) -> tagged_catch(catch_, R0);
catch_clause(<<16#01, R0/binary>>) -> tagged_catch(catch_ref, R0);
catch_clause(<<16#02, R0/binary>>) ->
    {L, R1} = wasm_leb128:u32(R0),
    {{catch_all, undefined, L}, R1};
catch_clause(<<16#03, R0/binary>>) ->
    {L, R1} = wasm_leb128:u32(R0),
    {{catch_all_ref, undefined, L}, R1};
catch_clause(<<B:8, _/binary>>) ->
    wasm_error:malformed(malformed_catch_clause,
                         <<"malformed catch clause">>, #{byte => B});
catch_clause(<<>>) ->
    wasm_error:malformed(unexpected_end, <<"unexpected end">>,
                         #{reading => catch_clause}).

tagged_catch(Kind, R0) ->
    {Tag, R1} = wasm_leb128:u32(R0),
    {L, R2} = wasm_leb128:u32(R1),
    {{Kind, Tag, L}, R2}.

%%% --------------------------------------------------------------- helpers ---

u32_arg(Bin, Wrap) ->
    {V, Rest} = wasm_leb128:u32(Bin),
    {Wrap(V), Rest}.

%% Memory arguments carry a log2 alignment hint and a static offset. The hint
%% is kept rather than discarded: validation checks it against the access
%% width, and `wasm_ir' uses it to select aligned fast paths, which measured
%% 6 ns versus 22 ns for the read-modify-write case.
%%
%% Bit 6 of the alignment field is a flag, not part of the alignment: when set
%% it means an explicit memory index follows (the multiple memories proposal).
%% Anything above that is not a valid encoding at all. Treating the field as a
%% plain log2 value would silently accept `align=128', which the specification
%% requires be rejected as malformed.
mem_arg(Bin, Op) ->
    {Flags, R1} = wasm_leb128:u32(Bin),
    case Flags of
        _ when Flags >= 128 ->
            wasm_error:malformed(malformed_memop_flags,
                                 <<"malformed memop flags">>, #{flags => Flags});
        _ when Flags >= 64 ->
            {Mem, R2} = wasm_leb128:u32(R1),
            {Offset, R3} = wasm_leb128:u64(R2),
            {{Op, {Flags - 64, Offset, Mem}}, R3};
        _ ->
            %% The offset is read as u64 for the same reason limits are: an
            %% offset beyond the 32-bit address space is invalid ("offset out
            %% of range"), not malformed, and memory64 will use the full width.
            {Offset, R2} = wasm_leb128:u64(R1),
            {{Op, {Flags, Offset, 0}}, R2}
    end.

vec_u32(Bin) ->
    {N, Rest} = wasm_leb128:u32(Bin),
    guard_count(N, Rest),
    vec_u32(N, Rest, []).

vec_u32(0, Rest, Acc) -> {lists:reverse(Acc), Rest};
vec_u32(N, Bin, Acc) ->
    {V, Rest} = wasm_leb128:u32(Bin),
    vec_u32(N - 1, Rest, [V | Acc]).

vec_valtype(Bin) ->
    {N, Rest} = wasm_leb128:u32(Bin),
    guard_count(N, Rest),
    vec_valtype(N, Rest, []).

vec_valtype(0, Rest, Acc) -> {lists:reverse(Acc), Rest};
vec_valtype(N, Bin, Acc) ->
    {V, Rest} = wasm_decode:valtype(Bin),
    vec_valtype(N - 1, Rest, [V | Acc]).

%% Bounds before allocation. Every vector element occupies at least one byte,
%% so a declared count larger than the remaining input cannot be satisfied.
%% Checking here means a module claiming four billion elements fails in
%% constant time instead of exhausting the node.
guard_count(N, Rest) when N > byte_size(Rest) ->
    wasm_error:malformed(length_out_of_bounds, <<"length out of bounds">>,
                         #{declared => N, remaining => byte_size(Rest)});
guard_count(_, _) ->
    ok.
