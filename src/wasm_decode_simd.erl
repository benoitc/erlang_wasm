-module(wasm_decode_simd).
-moduledoc """
The `0xFD` opcode space: fixed-width SIMD. Add a vector instruction here.

Split out of `wasm_decode_code` because it is larger than every other opcode
prefix put together, roughly 240 instructions against the 17 behind `0xFC`.

Only five immediate shapes exist across the whole space, so the table below is
almost entirely `Sub -> Atom` and the shapes are named once each:

| shape | instructions |
| --- | --- |
| none | every lane-wise arithmetic, comparison and bitwise operation |
| memarg | `v128.load`, `v128.store`, the splat and extend loads |
| memarg + lane index | `v128.loadN_lane`, `v128.storeN_lane` |
| lane index | `extract_lane`, `replace_lane` |
| 16 bytes | `v128.const`, `i8x16.shuffle` |

`v128.const` and `i8x16.shuffle` both carry 16 raw bytes and are the only
instructions in the format that do.
""".

-export([instr/1]).

%%% ----------------------------------------------------------------- api ---

-doc """
Decode one `0xFD`-prefixed instruction, given the bytes after the prefix.

Returns the instruction and the remaining input, or raises through
`wasm_error` if the subopcode is not one the specification defines.
""".
-spec instr(binary()) -> {tuple() | atom(), binary()}.
instr(R0) ->
    {Sub, R1} = wasm_leb128:u32(R0),
    sub(Sub, R1).

%%% ------------------------------------------------------ memory access ---

%% Loads and stores are the only SIMD instructions with immediates that are not
%% lane indices, and their alignment hints are validated against the *access*
%% width rather than 16 bytes: `v128.load32_splat' reads four bytes.
sub(0, R) -> mem(v128_load, R);
sub(1, R) -> mem(v128_load8x8_s, R);
sub(2, R) -> mem(v128_load8x8_u, R);
sub(3, R) -> mem(v128_load16x4_s, R);
sub(4, R) -> mem(v128_load16x4_u, R);
sub(5, R) -> mem(v128_load32x2_s, R);
sub(6, R) -> mem(v128_load32x2_u, R);
sub(7, R) -> mem(v128_load8_splat, R);
sub(8, R) -> mem(v128_load16_splat, R);
sub(9, R) -> mem(v128_load32_splat, R);
sub(10, R) -> mem(v128_load64_splat, R);
sub(11, R) -> mem(v128_store, R);

%% The only two instructions carrying sixteen raw bytes.
sub(12, <<Bytes:16/binary, R/binary>>) -> {{v128_const, Bytes}, R};
sub(12, _) ->
    wasm_error:malformed(unexpected_end, <<"unexpected end">>, #{op => v128_const});
sub(13, <<Lanes:16/binary, R/binary>>) -> {{i8x16_shuffle, Lanes}, R};
sub(13, _) ->
    wasm_error:malformed(unexpected_end, <<"unexpected end">>, #{op => i8x16_shuffle});

sub(14, R) -> {i8x16_swizzle, R};
sub(15, R) -> {i8x16_splat, R};
sub(16, R) -> {i16x8_splat, R};
sub(17, R) -> {i32x4_splat, R};
sub(18, R) -> {i64x2_splat, R};
sub(19, R) -> {f32x4_splat, R};
sub(20, R) -> {f64x2_splat, R};

sub(21, R) -> lane(i8x16_extract_lane_s, R);
sub(22, R) -> lane(i8x16_extract_lane_u, R);
sub(23, R) -> lane(i8x16_replace_lane, R);
sub(24, R) -> lane(i16x8_extract_lane_s, R);
sub(25, R) -> lane(i16x8_extract_lane_u, R);
sub(26, R) -> lane(i16x8_replace_lane, R);
sub(27, R) -> lane(i32x4_extract_lane, R);
sub(28, R) -> lane(i32x4_replace_lane, R);
sub(29, R) -> lane(i64x2_extract_lane, R);
sub(30, R) -> lane(i64x2_replace_lane, R);
sub(31, R) -> lane(f32x4_extract_lane, R);
sub(32, R) -> lane(f32x4_replace_lane, R);
sub(33, R) -> lane(f64x2_extract_lane, R);
sub(34, R) -> lane(f64x2_replace_lane, R);

%%% ------------------------------------------------------ comparisons ---

sub(35, R) -> {i8x16_eq, R};
sub(36, R) -> {i8x16_ne, R};
sub(37, R) -> {i8x16_lt_s, R};
sub(38, R) -> {i8x16_lt_u, R};
sub(39, R) -> {i8x16_gt_s, R};
sub(40, R) -> {i8x16_gt_u, R};
sub(41, R) -> {i8x16_le_s, R};
sub(42, R) -> {i8x16_le_u, R};
sub(43, R) -> {i8x16_ge_s, R};
sub(44, R) -> {i8x16_ge_u, R};

sub(45, R) -> {i16x8_eq, R};
sub(46, R) -> {i16x8_ne, R};
sub(47, R) -> {i16x8_lt_s, R};
sub(48, R) -> {i16x8_lt_u, R};
sub(49, R) -> {i16x8_gt_s, R};
sub(50, R) -> {i16x8_gt_u, R};
sub(51, R) -> {i16x8_le_s, R};
sub(52, R) -> {i16x8_le_u, R};
sub(53, R) -> {i16x8_ge_s, R};
sub(54, R) -> {i16x8_ge_u, R};

sub(55, R) -> {i32x4_eq, R};
sub(56, R) -> {i32x4_ne, R};
sub(57, R) -> {i32x4_lt_s, R};
sub(58, R) -> {i32x4_lt_u, R};
sub(59, R) -> {i32x4_gt_s, R};
sub(60, R) -> {i32x4_gt_u, R};
sub(61, R) -> {i32x4_le_s, R};
sub(62, R) -> {i32x4_le_u, R};
sub(63, R) -> {i32x4_ge_s, R};
sub(64, R) -> {i32x4_ge_u, R};

sub(65, R) -> {f32x4_eq, R};
sub(66, R) -> {f32x4_ne, R};
sub(67, R) -> {f32x4_lt, R};
sub(68, R) -> {f32x4_gt, R};
sub(69, R) -> {f32x4_le, R};
sub(70, R) -> {f32x4_ge, R};

sub(71, R) -> {f64x2_eq, R};
sub(72, R) -> {f64x2_ne, R};
sub(73, R) -> {f64x2_lt, R};
sub(74, R) -> {f64x2_gt, R};
sub(75, R) -> {f64x2_le, R};
sub(76, R) -> {f64x2_ge, R};

%%% ----------------------------------------------------------- bitwise ---

sub(77, R) -> {v128_not, R};
sub(78, R) -> {v128_and, R};
sub(79, R) -> {v128_andnot, R};
sub(80, R) -> {v128_or, R};
sub(81, R) -> {v128_xor, R};
sub(82, R) -> {v128_bitselect, R};
sub(83, R) -> {v128_any_true, R};

%% Lane-indexed loads and stores. The lane index follows the memarg.
sub(84, R) -> mem_lane(v128_load8_lane, R);
sub(85, R) -> mem_lane(v128_load16_lane, R);
sub(86, R) -> mem_lane(v128_load32_lane, R);
sub(87, R) -> mem_lane(v128_load64_lane, R);
sub(88, R) -> mem_lane(v128_store8_lane, R);
sub(89, R) -> mem_lane(v128_store16_lane, R);
sub(90, R) -> mem_lane(v128_store32_lane, R);
sub(91, R) -> mem_lane(v128_store64_lane, R);
sub(92, R) -> mem(v128_load32_zero, R);
sub(93, R) -> mem(v128_load64_zero, R);

sub(94, R) -> {f32x4_demote_f64x2_zero, R};
sub(95, R) -> {f64x2_promote_low_f32x4, R};

%%% -------------------------------------------------------------- i8x16 ---

sub(96, R) -> {i8x16_abs, R};
sub(97, R) -> {i8x16_neg, R};
sub(98, R) -> {i8x16_popcnt, R};
sub(99, R) -> {i8x16_all_true, R};
sub(100, R) -> {i8x16_bitmask, R};
sub(101, R) -> {i8x16_narrow_i16x8_s, R};
sub(102, R) -> {i8x16_narrow_i16x8_u, R};
sub(103, R) -> {f32x4_ceil, R};
sub(104, R) -> {f32x4_floor, R};
sub(105, R) -> {f32x4_trunc, R};
sub(106, R) -> {f32x4_nearest, R};
sub(107, R) -> {i8x16_shl, R};
sub(108, R) -> {i8x16_shr_s, R};
sub(109, R) -> {i8x16_shr_u, R};
sub(110, R) -> {i8x16_add, R};
sub(111, R) -> {i8x16_add_sat_s, R};
sub(112, R) -> {i8x16_add_sat_u, R};
sub(113, R) -> {i8x16_sub, R};
sub(114, R) -> {i8x16_sub_sat_s, R};
sub(115, R) -> {i8x16_sub_sat_u, R};
sub(116, R) -> {f64x2_ceil, R};
sub(117, R) -> {f64x2_floor, R};
sub(118, R) -> {i8x16_min_s, R};
sub(119, R) -> {i8x16_min_u, R};
sub(120, R) -> {i8x16_max_s, R};
sub(121, R) -> {i8x16_max_u, R};
sub(122, R) -> {f64x2_trunc, R};
sub(123, R) -> {i8x16_avgr_u, R};

sub(124, R) -> {i16x8_extadd_pairwise_i8x16_s, R};
sub(125, R) -> {i16x8_extadd_pairwise_i8x16_u, R};
sub(126, R) -> {i32x4_extadd_pairwise_i16x8_s, R};
sub(127, R) -> {i32x4_extadd_pairwise_i16x8_u, R};

%%% -------------------------------------------------------------- i16x8 ---

sub(128, R) -> {i16x8_abs, R};
sub(129, R) -> {i16x8_neg, R};
sub(130, R) -> {i16x8_q15mulr_sat_s, R};
sub(131, R) -> {i16x8_all_true, R};
sub(132, R) -> {i16x8_bitmask, R};
sub(133, R) -> {i16x8_narrow_i32x4_s, R};
sub(134, R) -> {i16x8_narrow_i32x4_u, R};
sub(135, R) -> {i16x8_extend_low_i8x16_s, R};
sub(136, R) -> {i16x8_extend_high_i8x16_s, R};
sub(137, R) -> {i16x8_extend_low_i8x16_u, R};
sub(138, R) -> {i16x8_extend_high_i8x16_u, R};
sub(139, R) -> {i16x8_shl, R};
sub(140, R) -> {i16x8_shr_s, R};
sub(141, R) -> {i16x8_shr_u, R};
sub(142, R) -> {i16x8_add, R};
sub(143, R) -> {i16x8_add_sat_s, R};
sub(144, R) -> {i16x8_add_sat_u, R};
sub(145, R) -> {i16x8_sub, R};
sub(146, R) -> {i16x8_sub_sat_s, R};
sub(147, R) -> {i16x8_sub_sat_u, R};
sub(148, R) -> {f64x2_nearest, R};
sub(149, R) -> {i16x8_mul, R};
sub(150, R) -> {i16x8_min_s, R};
sub(151, R) -> {i16x8_min_u, R};
sub(152, R) -> {i16x8_max_s, R};
sub(153, R) -> {i16x8_max_u, R};
sub(155, R) -> {i16x8_avgr_u, R};
sub(156, R) -> {i16x8_extmul_low_i8x16_s, R};
sub(157, R) -> {i16x8_extmul_high_i8x16_s, R};
sub(158, R) -> {i16x8_extmul_low_i8x16_u, R};
sub(159, R) -> {i16x8_extmul_high_i8x16_u, R};

%%% -------------------------------------------------------------- i32x4 ---

sub(160, R) -> {i32x4_abs, R};
sub(161, R) -> {i32x4_neg, R};
sub(163, R) -> {i32x4_all_true, R};
sub(164, R) -> {i32x4_bitmask, R};
sub(167, R) -> {i32x4_extend_low_i16x8_s, R};
sub(168, R) -> {i32x4_extend_high_i16x8_s, R};
sub(169, R) -> {i32x4_extend_low_i16x8_u, R};
sub(170, R) -> {i32x4_extend_high_i16x8_u, R};
sub(171, R) -> {i32x4_shl, R};
sub(172, R) -> {i32x4_shr_s, R};
sub(173, R) -> {i32x4_shr_u, R};
sub(174, R) -> {i32x4_add, R};
sub(177, R) -> {i32x4_sub, R};
sub(181, R) -> {i32x4_mul, R};
sub(182, R) -> {i32x4_min_s, R};
sub(183, R) -> {i32x4_min_u, R};
sub(184, R) -> {i32x4_max_s, R};
sub(185, R) -> {i32x4_max_u, R};
sub(186, R) -> {i32x4_dot_i16x8_s, R};
sub(188, R) -> {i32x4_extmul_low_i16x8_s, R};
sub(189, R) -> {i32x4_extmul_high_i16x8_s, R};
sub(190, R) -> {i32x4_extmul_low_i16x8_u, R};
sub(191, R) -> {i32x4_extmul_high_i16x8_u, R};

%%% -------------------------------------------------------------- i64x2 ---

sub(192, R) -> {i64x2_abs, R};
sub(193, R) -> {i64x2_neg, R};
sub(195, R) -> {i64x2_all_true, R};
sub(196, R) -> {i64x2_bitmask, R};
sub(199, R) -> {i64x2_extend_low_i32x4_s, R};
sub(200, R) -> {i64x2_extend_high_i32x4_s, R};
sub(201, R) -> {i64x2_extend_low_i32x4_u, R};
sub(202, R) -> {i64x2_extend_high_i32x4_u, R};
sub(203, R) -> {i64x2_shl, R};
sub(204, R) -> {i64x2_shr_s, R};
sub(205, R) -> {i64x2_shr_u, R};
sub(206, R) -> {i64x2_add, R};
sub(209, R) -> {i64x2_sub, R};
sub(213, R) -> {i64x2_mul, R};
sub(214, R) -> {i64x2_eq, R};
sub(215, R) -> {i64x2_ne, R};
sub(216, R) -> {i64x2_lt_s, R};
sub(217, R) -> {i64x2_gt_s, R};
sub(218, R) -> {i64x2_le_s, R};
sub(219, R) -> {i64x2_ge_s, R};
sub(220, R) -> {i64x2_extmul_low_i32x4_s, R};
sub(221, R) -> {i64x2_extmul_high_i32x4_s, R};
sub(222, R) -> {i64x2_extmul_low_i32x4_u, R};
sub(223, R) -> {i64x2_extmul_high_i32x4_u, R};

%%% -------------------------------------------------------------- f32x4 ---

sub(224, R) -> {f32x4_abs, R};
sub(225, R) -> {f32x4_neg, R};
sub(227, R) -> {f32x4_sqrt, R};
sub(228, R) -> {f32x4_add, R};
sub(229, R) -> {f32x4_sub, R};
sub(230, R) -> {f32x4_mul, R};
sub(231, R) -> {f32x4_div, R};
sub(232, R) -> {f32x4_min, R};
sub(233, R) -> {f32x4_max, R};
sub(234, R) -> {f32x4_pmin, R};
sub(235, R) -> {f32x4_pmax, R};

%%% -------------------------------------------------------------- f64x2 ---

sub(236, R) -> {f64x2_abs, R};
sub(237, R) -> {f64x2_neg, R};
sub(239, R) -> {f64x2_sqrt, R};
sub(240, R) -> {f64x2_add, R};
sub(241, R) -> {f64x2_sub, R};
sub(242, R) -> {f64x2_mul, R};
sub(243, R) -> {f64x2_div, R};
sub(244, R) -> {f64x2_min, R};
sub(245, R) -> {f64x2_max, R};
sub(246, R) -> {f64x2_pmin, R};
sub(247, R) -> {f64x2_pmax, R};

%%% --------------------------------------------------------- conversions ---

sub(248, R) -> {i32x4_trunc_sat_f32x4_s, R};
sub(249, R) -> {i32x4_trunc_sat_f32x4_u, R};
sub(250, R) -> {f32x4_convert_i32x4_s, R};
sub(251, R) -> {f32x4_convert_i32x4_u, R};
sub(252, R) -> {i32x4_trunc_sat_f64x2_s_zero, R};
sub(253, R) -> {i32x4_trunc_sat_f64x2_u_zero, R};
sub(254, R) -> {f64x2_convert_low_i32x4_s, R};
sub(255, R) -> {f64x2_convert_low_i32x4_u, R};

%%% -------------------------------------------------------- relaxed SIMD ---
%%
%% The relaxed proposal continues above 255, so its sub-opcodes take two bytes
%% of LEB128. Nothing else changes: every one carries no immediate, so they are
%% bare atoms like the rest of the arithmetic.

sub(256, R) -> {i8x16_relaxed_swizzle, R};
sub(257, R) -> {i32x4_relaxed_trunc_f32x4_s, R};
sub(258, R) -> {i32x4_relaxed_trunc_f32x4_u, R};
sub(259, R) -> {i32x4_relaxed_trunc_f64x2_s_zero, R};
sub(260, R) -> {i32x4_relaxed_trunc_f64x2_u_zero, R};
sub(261, R) -> {f32x4_relaxed_madd, R};
sub(262, R) -> {f32x4_relaxed_nmadd, R};
sub(263, R) -> {f64x2_relaxed_madd, R};
sub(264, R) -> {f64x2_relaxed_nmadd, R};
sub(265, R) -> {i8x16_relaxed_laneselect, R};
sub(266, R) -> {i16x8_relaxed_laneselect, R};
sub(267, R) -> {i32x4_relaxed_laneselect, R};
sub(268, R) -> {i64x2_relaxed_laneselect, R};
sub(269, R) -> {f32x4_relaxed_min, R};
sub(270, R) -> {f32x4_relaxed_max, R};
sub(271, R) -> {f64x2_relaxed_min, R};
sub(272, R) -> {f64x2_relaxed_max, R};
sub(273, R) -> {i16x8_relaxed_q15mulr_s, R};
sub(274, R) -> {i16x8_relaxed_dot_i8x16_i7x16_s, R};
sub(275, R) -> {i32x4_relaxed_dot_i8x16_i7x16_add_s, R};

sub(Sub, _) ->
    wasm_error:malformed(illegal_opcode, <<"illegal opcode">>,
                         #{opcode => 16#FD, sub => Sub}).

%%% --------------------------------------------------------------- shapes ---

mem(Op, Bin) -> wasm_decode_code:mem_arg(Bin, Op).

%% The lane index is a single byte, after the memarg.
mem_lane(Op, Bin) ->
    {{_, MemArg}, R1} = wasm_decode_code:mem_arg(Bin, Op),
    case R1 of
        <<Lane:8, R2/binary>> -> {{Op, MemArg, Lane}, R2};
        <<>> -> wasm_error:malformed(unexpected_end, <<"unexpected end">>,
                                     #{op => Op})
    end.

lane(Op, <<Lane:8, R/binary>>) -> {{Op, Lane}, R};
lane(Op, <<>>) ->
    wasm_error:malformed(unexpected_end, <<"unexpected end">>, #{op => Op}).
