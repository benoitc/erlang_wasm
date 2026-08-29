-module(wasm_validate_simd).
-moduledoc """
Operand types for the `0xFD` vector opcode space. Add a vector instruction's
types here, alongside its decoding.

Four tables, one per immediate shape, matching `wasm_decode_simd`:

  * `type_of/1` for the plain lane-wise instructions, which is nearly all of
    them and where the type is a function of the opcode alone;
  * `lane_op/1` for `extract_lane` and `replace_lane`, which also need the lane
    count so the immediate can be bounds-checked;
  * `mem_op/1` for the vector loads and stores, whose natural alignment is the
    width of the *access* rather than 16: `v128.load32_splat` reads four bytes;
  * `lane_mem_op/1` for the lane-indexed loads and stores, which need both.

Kept apart from `wasm_validate_code` for the same reason the decoder is: this
opcode space is larger than every other prefix combined, and inlining it would
bury the rules that are actually interesting.
""".

-export([type_of/1, lane_op/1, mem_op/1, lane_mem_op/1]).

-doc "Operand and result types, or `false` if this is not a plain vector op.".
-spec type_of(atom()) -> {[atom()], [atom()]} | false.
type_of(i8x16_eq) -> {[v128, v128], [v128]};
type_of(i8x16_ne) -> {[v128, v128], [v128]};
type_of(i8x16_lt_s) -> {[v128, v128], [v128]};
type_of(i8x16_gt_s) -> {[v128, v128], [v128]};
type_of(i8x16_le_s) -> {[v128, v128], [v128]};
type_of(i8x16_ge_s) -> {[v128, v128], [v128]};
type_of(i8x16_lt_u) -> {[v128, v128], [v128]};
type_of(i8x16_gt_u) -> {[v128, v128], [v128]};
type_of(i8x16_le_u) -> {[v128, v128], [v128]};
type_of(i8x16_ge_u) -> {[v128, v128], [v128]};
type_of(i16x8_eq) -> {[v128, v128], [v128]};
type_of(i16x8_ne) -> {[v128, v128], [v128]};
type_of(i16x8_lt_s) -> {[v128, v128], [v128]};
type_of(i16x8_gt_s) -> {[v128, v128], [v128]};
type_of(i16x8_le_s) -> {[v128, v128], [v128]};
type_of(i16x8_ge_s) -> {[v128, v128], [v128]};
type_of(i16x8_lt_u) -> {[v128, v128], [v128]};
type_of(i16x8_gt_u) -> {[v128, v128], [v128]};
type_of(i16x8_le_u) -> {[v128, v128], [v128]};
type_of(i16x8_ge_u) -> {[v128, v128], [v128]};
type_of(i32x4_eq) -> {[v128, v128], [v128]};
type_of(i32x4_ne) -> {[v128, v128], [v128]};
type_of(i32x4_lt_s) -> {[v128, v128], [v128]};
type_of(i32x4_gt_s) -> {[v128, v128], [v128]};
type_of(i32x4_le_s) -> {[v128, v128], [v128]};
type_of(i32x4_ge_s) -> {[v128, v128], [v128]};
type_of(i32x4_lt_u) -> {[v128, v128], [v128]};
type_of(i32x4_gt_u) -> {[v128, v128], [v128]};
type_of(i32x4_le_u) -> {[v128, v128], [v128]};
type_of(i32x4_ge_u) -> {[v128, v128], [v128]};
type_of(i64x2_eq) -> {[v128, v128], [v128]};
type_of(i64x2_ne) -> {[v128, v128], [v128]};
type_of(i64x2_lt_s) -> {[v128, v128], [v128]};
type_of(i64x2_gt_s) -> {[v128, v128], [v128]};
type_of(i64x2_le_s) -> {[v128, v128], [v128]};
type_of(i64x2_ge_s) -> {[v128, v128], [v128]};
type_of(f32x4_eq) -> {[v128, v128], [v128]};
type_of(f32x4_ne) -> {[v128, v128], [v128]};
type_of(f32x4_lt) -> {[v128, v128], [v128]};
type_of(f32x4_gt) -> {[v128, v128], [v128]};
type_of(f32x4_le) -> {[v128, v128], [v128]};
type_of(f32x4_ge) -> {[v128, v128], [v128]};
type_of(f64x2_eq) -> {[v128, v128], [v128]};
type_of(f64x2_ne) -> {[v128, v128], [v128]};
type_of(f64x2_lt) -> {[v128, v128], [v128]};
type_of(f64x2_gt) -> {[v128, v128], [v128]};
type_of(f64x2_le) -> {[v128, v128], [v128]};
type_of(f64x2_ge) -> {[v128, v128], [v128]};
type_of(v128_and) -> {[v128, v128], [v128]};
type_of(v128_andnot) -> {[v128, v128], [v128]};
type_of(v128_or) -> {[v128, v128], [v128]};
type_of(v128_xor) -> {[v128, v128], [v128]};
type_of(i8x16_swizzle) -> {[v128, v128], [v128]};
type_of(i8x16_add) -> {[v128, v128], [v128]};
type_of(i8x16_sub) -> {[v128, v128], [v128]};
type_of(i8x16_add_sat_s) -> {[v128, v128], [v128]};
type_of(i8x16_add_sat_u) -> {[v128, v128], [v128]};
type_of(i8x16_sub_sat_s) -> {[v128, v128], [v128]};
type_of(i8x16_sub_sat_u) -> {[v128, v128], [v128]};
type_of(i8x16_avgr_u) -> {[v128, v128], [v128]};
type_of(i8x16_min_s) -> {[v128, v128], [v128]};
type_of(i8x16_min_u) -> {[v128, v128], [v128]};
type_of(i8x16_max_s) -> {[v128, v128], [v128]};
type_of(i8x16_max_u) -> {[v128, v128], [v128]};
type_of(i16x8_add) -> {[v128, v128], [v128]};
type_of(i16x8_sub) -> {[v128, v128], [v128]};
type_of(i16x8_mul) -> {[v128, v128], [v128]};
type_of(i16x8_add_sat_s) -> {[v128, v128], [v128]};
type_of(i16x8_add_sat_u) -> {[v128, v128], [v128]};
type_of(i16x8_sub_sat_s) -> {[v128, v128], [v128]};
type_of(i16x8_sub_sat_u) -> {[v128, v128], [v128]};
type_of(i16x8_avgr_u) -> {[v128, v128], [v128]};
type_of(i16x8_min_s) -> {[v128, v128], [v128]};
type_of(i16x8_min_u) -> {[v128, v128], [v128]};
type_of(i16x8_max_s) -> {[v128, v128], [v128]};
type_of(i16x8_max_u) -> {[v128, v128], [v128]};
type_of(i32x4_add) -> {[v128, v128], [v128]};
type_of(i32x4_sub) -> {[v128, v128], [v128]};
type_of(i32x4_mul) -> {[v128, v128], [v128]};
type_of(i32x4_min_s) -> {[v128, v128], [v128]};
type_of(i32x4_min_u) -> {[v128, v128], [v128]};
type_of(i32x4_max_s) -> {[v128, v128], [v128]};
type_of(i32x4_max_u) -> {[v128, v128], [v128]};
type_of(i64x2_add) -> {[v128, v128], [v128]};
type_of(i64x2_sub) -> {[v128, v128], [v128]};
type_of(i64x2_mul) -> {[v128, v128], [v128]};
type_of(i8x16_narrow_i16x8_s) -> {[v128, v128], [v128]};
type_of(i8x16_narrow_i16x8_u) -> {[v128, v128], [v128]};
type_of(i16x8_narrow_i32x4_s) -> {[v128, v128], [v128]};
type_of(i16x8_narrow_i32x4_u) -> {[v128, v128], [v128]};
type_of(i16x8_q15mulr_sat_s) -> {[v128, v128], [v128]};
type_of(i32x4_dot_i16x8_s) -> {[v128, v128], [v128]};
type_of(i16x8_extmul_low_i8x16_s) -> {[v128, v128], [v128]};
type_of(i16x8_extmul_low_i8x16_u) -> {[v128, v128], [v128]};
type_of(i16x8_extmul_high_i8x16_s) -> {[v128, v128], [v128]};
type_of(i16x8_extmul_high_i8x16_u) -> {[v128, v128], [v128]};
type_of(i32x4_extmul_low_i16x8_s) -> {[v128, v128], [v128]};
type_of(i32x4_extmul_low_i16x8_u) -> {[v128, v128], [v128]};
type_of(i32x4_extmul_high_i16x8_s) -> {[v128, v128], [v128]};
type_of(i32x4_extmul_high_i16x8_u) -> {[v128, v128], [v128]};
type_of(i64x2_extmul_low_i32x4_s) -> {[v128, v128], [v128]};
type_of(i64x2_extmul_low_i32x4_u) -> {[v128, v128], [v128]};
type_of(i64x2_extmul_high_i32x4_s) -> {[v128, v128], [v128]};
type_of(i64x2_extmul_high_i32x4_u) -> {[v128, v128], [v128]};
type_of(f32x4_add) -> {[v128, v128], [v128]};
type_of(f32x4_sub) -> {[v128, v128], [v128]};
type_of(f32x4_mul) -> {[v128, v128], [v128]};
type_of(f32x4_div) -> {[v128, v128], [v128]};
type_of(f32x4_min) -> {[v128, v128], [v128]};
type_of(f32x4_max) -> {[v128, v128], [v128]};
type_of(f32x4_pmin) -> {[v128, v128], [v128]};
type_of(f32x4_pmax) -> {[v128, v128], [v128]};
type_of(f64x2_add) -> {[v128, v128], [v128]};
type_of(f64x2_sub) -> {[v128, v128], [v128]};
type_of(f64x2_mul) -> {[v128, v128], [v128]};
type_of(f64x2_div) -> {[v128, v128], [v128]};
type_of(f64x2_min) -> {[v128, v128], [v128]};
type_of(f64x2_max) -> {[v128, v128], [v128]};
type_of(f64x2_pmin) -> {[v128, v128], [v128]};
type_of(f64x2_pmax) -> {[v128, v128], [v128]};
type_of(v128_not) -> {[v128], [v128]};
type_of(i8x16_abs) -> {[v128], [v128]};
type_of(i8x16_neg) -> {[v128], [v128]};
type_of(i16x8_abs) -> {[v128], [v128]};
type_of(i16x8_neg) -> {[v128], [v128]};
type_of(i32x4_abs) -> {[v128], [v128]};
type_of(i32x4_neg) -> {[v128], [v128]};
type_of(i64x2_abs) -> {[v128], [v128]};
type_of(i64x2_neg) -> {[v128], [v128]};
type_of(i8x16_popcnt) -> {[v128], [v128]};
type_of(f32x4_abs) -> {[v128], [v128]};
type_of(f32x4_neg) -> {[v128], [v128]};
type_of(f32x4_sqrt) -> {[v128], [v128]};
type_of(f32x4_ceil) -> {[v128], [v128]};
type_of(f32x4_floor) -> {[v128], [v128]};
type_of(f32x4_trunc) -> {[v128], [v128]};
type_of(f32x4_nearest) -> {[v128], [v128]};
type_of(f64x2_abs) -> {[v128], [v128]};
type_of(f64x2_neg) -> {[v128], [v128]};
type_of(f64x2_sqrt) -> {[v128], [v128]};
type_of(f64x2_ceil) -> {[v128], [v128]};
type_of(f64x2_floor) -> {[v128], [v128]};
type_of(f64x2_trunc) -> {[v128], [v128]};
type_of(f64x2_nearest) -> {[v128], [v128]};
type_of(i16x8_extend_low_i8x16_s) -> {[v128], [v128]};
type_of(i16x8_extend_low_i8x16_u) -> {[v128], [v128]};
type_of(i16x8_extend_high_i8x16_s) -> {[v128], [v128]};
type_of(i16x8_extend_high_i8x16_u) -> {[v128], [v128]};
type_of(i32x4_extend_low_i16x8_s) -> {[v128], [v128]};
type_of(i32x4_extend_low_i16x8_u) -> {[v128], [v128]};
type_of(i32x4_extend_high_i16x8_s) -> {[v128], [v128]};
type_of(i32x4_extend_high_i16x8_u) -> {[v128], [v128]};
type_of(i64x2_extend_low_i32x4_s) -> {[v128], [v128]};
type_of(i64x2_extend_low_i32x4_u) -> {[v128], [v128]};
type_of(i64x2_extend_high_i32x4_s) -> {[v128], [v128]};
type_of(i64x2_extend_high_i32x4_u) -> {[v128], [v128]};
type_of(i16x8_extadd_pairwise_i8x16_s) -> {[v128], [v128]};
type_of(i16x8_extadd_pairwise_i8x16_u) -> {[v128], [v128]};
type_of(i32x4_extadd_pairwise_i16x8_s) -> {[v128], [v128]};
type_of(i32x4_extadd_pairwise_i16x8_u) -> {[v128], [v128]};
type_of(f32x4_demote_f64x2_zero) -> {[v128], [v128]};
type_of(f64x2_promote_low_f32x4) -> {[v128], [v128]};
type_of(i32x4_trunc_sat_f32x4_s) -> {[v128], [v128]};
type_of(i32x4_trunc_sat_f32x4_u) -> {[v128], [v128]};
type_of(f32x4_convert_i32x4_s) -> {[v128], [v128]};
type_of(f32x4_convert_i32x4_u) -> {[v128], [v128]};
type_of(i32x4_trunc_sat_f64x2_s_zero) -> {[v128], [v128]};
type_of(i32x4_trunc_sat_f64x2_u_zero) -> {[v128], [v128]};
type_of(f64x2_convert_low_i32x4_s) -> {[v128], [v128]};
type_of(f64x2_convert_low_i32x4_u) -> {[v128], [v128]};
type_of(v128_any_true) -> {[v128], [i32]};
type_of(i8x16_all_true) -> {[v128], [i32]};
type_of(i16x8_all_true) -> {[v128], [i32]};
type_of(i32x4_all_true) -> {[v128], [i32]};
type_of(i64x2_all_true) -> {[v128], [i32]};
type_of(i8x16_bitmask) -> {[v128], [i32]};
type_of(i16x8_bitmask) -> {[v128], [i32]};
type_of(i32x4_bitmask) -> {[v128], [i32]};
type_of(i64x2_bitmask) -> {[v128], [i32]};
type_of(i8x16_shl) -> {[v128, i32], [v128]};
type_of(i8x16_shr_s) -> {[v128, i32], [v128]};
type_of(i8x16_shr_u) -> {[v128, i32], [v128]};
type_of(i16x8_shl) -> {[v128, i32], [v128]};
type_of(i16x8_shr_s) -> {[v128, i32], [v128]};
type_of(i16x8_shr_u) -> {[v128, i32], [v128]};
type_of(i32x4_shl) -> {[v128, i32], [v128]};
type_of(i32x4_shr_s) -> {[v128, i32], [v128]};
type_of(i32x4_shr_u) -> {[v128, i32], [v128]};
type_of(i64x2_shl) -> {[v128, i32], [v128]};
type_of(i64x2_shr_s) -> {[v128, i32], [v128]};
type_of(i64x2_shr_u) -> {[v128, i32], [v128]};
type_of(i8x16_splat) -> {[i32], [v128]};
type_of(i16x8_splat) -> {[i32], [v128]};
type_of(i32x4_splat) -> {[i32], [v128]};
type_of(i64x2_splat) -> {[i64], [v128]};
type_of(f32x4_splat) -> {[f32], [v128]};
type_of(f64x2_splat) -> {[f64], [v128]};
type_of(v128_bitselect) -> {[v128, v128, v128], [v128]};

%% Relaxed SIMD. Every one takes and returns vectors, so the shapes here are
%% the same three the strict instructions already use and `wasm_instance`
%% routes them without knowing they are relaxed. Kept at the end of the table
%% deliberately: these are the least frequently executed vector instructions
%% and the clauses above them are matched on every lookup.
type_of(i8x16_relaxed_swizzle) -> {[v128, v128], [v128]};
type_of(f32x4_relaxed_min) -> {[v128, v128], [v128]};
type_of(f32x4_relaxed_max) -> {[v128, v128], [v128]};
type_of(f64x2_relaxed_min) -> {[v128, v128], [v128]};
type_of(f64x2_relaxed_max) -> {[v128, v128], [v128]};
type_of(i16x8_relaxed_q15mulr_s) -> {[v128, v128], [v128]};
type_of(i16x8_relaxed_dot_i8x16_i7x16_s) -> {[v128, v128], [v128]};

type_of(i32x4_relaxed_trunc_f32x4_s) -> {[v128], [v128]};
type_of(i32x4_relaxed_trunc_f32x4_u) -> {[v128], [v128]};
type_of(i32x4_relaxed_trunc_f64x2_s_zero) -> {[v128], [v128]};
type_of(i32x4_relaxed_trunc_f64x2_u_zero) -> {[v128], [v128]};

type_of(f32x4_relaxed_madd) -> {[v128, v128, v128], [v128]};
type_of(f32x4_relaxed_nmadd) -> {[v128, v128, v128], [v128]};
type_of(f64x2_relaxed_madd) -> {[v128, v128, v128], [v128]};
type_of(f64x2_relaxed_nmadd) -> {[v128, v128, v128], [v128]};
type_of(i8x16_relaxed_laneselect) -> {[v128, v128, v128], [v128]};
type_of(i16x8_relaxed_laneselect) -> {[v128, v128, v128], [v128]};
type_of(i32x4_relaxed_laneselect) -> {[v128, v128, v128], [v128]};
type_of(i64x2_relaxed_laneselect) -> {[v128, v128, v128], [v128]};
type_of(i32x4_relaxed_dot_i8x16_i7x16_add_s) -> {[v128, v128, v128], [v128]};

type_of(_) -> false.

-doc """
Lane count and types for `extract_lane` and `replace_lane`.

The lane count is returned so the caller can reject an out-of-range immediate,
which is a validation error rather than a decoding one: the byte is
well-formed, it just names a lane the shape does not have.
""".
-spec lane_op(atom()) -> {pos_integer(), [atom()], [atom()]} | false.
lane_op(i8x16_extract_lane_s) -> {16, [v128], [i32]};
lane_op(i8x16_extract_lane_u) -> {16, [v128], [i32]};
lane_op(i8x16_replace_lane)   -> {16, [v128, i32], [v128]};
lane_op(i16x8_extract_lane_s) -> {8, [v128], [i32]};
lane_op(i16x8_extract_lane_u) -> {8, [v128], [i32]};
lane_op(i16x8_replace_lane)   -> {8, [v128, i32], [v128]};
lane_op(i32x4_extract_lane)   -> {4, [v128], [i32]};
lane_op(i32x4_replace_lane)   -> {4, [v128, i32], [v128]};
lane_op(i64x2_extract_lane)   -> {2, [v128], [i64]};
lane_op(i64x2_replace_lane)   -> {2, [v128, i64], [v128]};
lane_op(f32x4_extract_lane)   -> {4, [v128], [f32]};
lane_op(f32x4_replace_lane)   -> {4, [v128, f32], [v128]};
lane_op(f64x2_extract_lane)   -> {2, [v128], [f64]};
lane_op(f64x2_replace_lane)   -> {2, [v128, f64], [v128]};
lane_op(_) -> false.

-doc """
Direction and natural alignment (as log2 bytes) of a vector load or store.

The alignment hint is checked against the bytes the instruction actually
touches, not against the 16 bytes of the result: `v128.load8_splat` reads one
byte and may declare `align=0`.
""".
-spec mem_op(atom()) -> {load | store, 0..4} | false.
mem_op(v128_load)         -> {load, 4};
mem_op(v128_store)        -> {store, 4};
mem_op(v128_load8x8_s)    -> {load, 3};
mem_op(v128_load8x8_u)    -> {load, 3};
mem_op(v128_load16x4_s)   -> {load, 3};
mem_op(v128_load16x4_u)   -> {load, 3};
mem_op(v128_load32x2_s)   -> {load, 3};
mem_op(v128_load32x2_u)   -> {load, 3};
mem_op(v128_load8_splat)  -> {load, 0};
mem_op(v128_load16_splat) -> {load, 1};
mem_op(v128_load32_splat) -> {load, 2};
mem_op(v128_load64_splat) -> {load, 3};
mem_op(v128_load32_zero)  -> {load, 2};
mem_op(v128_load64_zero)  -> {load, 3};
mem_op(_) -> false.

-doc "Direction, natural alignment and lane count of a lane-indexed access.".
-spec lane_mem_op(atom()) -> {load | store, 0..3, pos_integer()} | false.
lane_mem_op(v128_load8_lane)   -> {load, 0, 16};
lane_mem_op(v128_load16_lane)  -> {load, 1, 8};
lane_mem_op(v128_load32_lane)  -> {load, 2, 4};
lane_mem_op(v128_load64_lane)  -> {load, 3, 2};
lane_mem_op(v128_store8_lane)  -> {store, 0, 16};
lane_mem_op(v128_store16_lane) -> {store, 1, 8};
lane_mem_op(v128_store32_lane) -> {store, 2, 4};
lane_mem_op(v128_store64_lane) -> {store, 3, 2};
lane_mem_op(_) -> false.
