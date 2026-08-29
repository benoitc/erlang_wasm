%% @doc SIMD rules that are easy to get wrong, each named.
%%
%% Like `wasm_num_SUITE' and `wasm_memory64_SUITE', this duplicates coverage
%% the specification fixtures already give. The fixtures are generated rather
%% than committed, so a fresh clone skips them; and when they do run they say
%% *what* broke, not why the code is shaped the way it is. Every case here is a
%% rule that was got wrong once, or one whose correctness is not obvious from
%% reading the implementation.
-module(wasm_simd_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [lanes_wrap_rather_than_carry,
     shifts_are_taken_modulo_the_lane_width,
     comparisons_produce_all_ones_not_one,
     narrowing_reads_its_source_signed,
     pmin_is_not_min,
     nan_lanes_survive_a_round_trip,
     swizzle_out_of_range_yields_zero,
     bitmask_gathers_sign_bits_lane_zero_first,
     f32x4_lanes_round_once].

%%% ------------------------------------------------------------------ rule ---

%% Lane arithmetic wraps within the lane and never carries into its neighbour.
%%
%% This is free in bit syntax, which truncates each field to its declared
%% width, and is exactly what the 128-bit-integer representation would have
%% needed an explicit mask per lane to get right.
lanes_wrap_rather_than_carry(_Config) ->
    A = <<255:8, 255:8, 0:112>>,
    B = <<1:8, 1:8, 0:112>>,
    ?assertEqual(<<0:8, 0:8, 0:112>>, wasm_simd:binary_op(i8x16_add, A, B)),
    %% And the same at the top lane, where a carry would fall off the vector.
    Top = <<0:120, 255:8>>,
    ?assertEqual(<<0:128>>, wasm_simd:binary_op(i8x16_add, Top, <<0:120, 1:8>>)).

%% A shift count is reduced modulo the lane width, so no shift can fault and
%% none is a no-op merely because the count was large.
shifts_are_taken_modulo_the_lane_width(_Config) ->
    V = splat32(1),
    ?assertEqual(splat32(2), wasm_simd:shift(i32x4_shl, V, 1)),
    %% 33 mod 32 is 1, not 33: the result is the same as shifting by one.
    ?assertEqual(splat32(2), wasm_simd:shift(i32x4_shl, V, 33)),
    ?assertEqual(V, wasm_simd:shift(i32x4_shl, V, 32)),
    %% An arithmetic right shift keeps the sign; a logical one does not.
    Neg = splat32(16#FFFFFFFF),
    ?assertEqual(Neg, wasm_simd:shift(i32x4_shr_s, Neg, 4)),
    ?assertEqual(splat32(16#0FFFFFFF), wasm_simd:shift(i32x4_shr_u, Neg, 4)).

%% A lane comparison yields all-ones, not 1. That is what makes the result
%% usable directly as a mask for `v128.bitselect`.
comparisons_produce_all_ones_not_one(_Config) ->
    A = <<1:32/little, 2:32/little, 3:32/little, 4:32/little>>,
    B = <<1:32/little, 0:32/little, 3:32/little, 0:32/little>>,
    Eq = wasm_simd:binary_op(i32x4_eq, A, B),
    ?assertEqual(<<16#FFFFFFFF:32/little, 0:32, 16#FFFFFFFF:32/little, 0:32>>,
                 Eq),
    %% All-ones is what makes the result usable as a mask: `bitselect` takes a
    %% lane from its first operand where the mask is set and from its second
    %% where it is clear, which a mask of 1 rather than all-ones would mangle
    %% into a single bit of one lane.
    Mask = <<16#FFFFFFFF:32/little, 0:32, 0:32, 16#FFFFFFFF:32/little>>,
    ?assertEqual(<<1:32/little, 0:32/little, 3:32/little, 4:32/little>>,
                 wasm_simd:bitselect(A, B, Mask)).

%% `i8x16.narrow_i16x8_u` reads its source lanes *signed* even though it
%% produces unsigned ones, so -1 clamps to 0 rather than to 255.
%%
%% Reading the source unsigned would make -1 arrive as 65535 and clamp to 255,
%% which is the opposite answer.
narrowing_reads_its_source_signed(_Config) ->
    A = <<16#FFFF:16/little, 300:16/little, 0:96>>,   % -1, then 300
    B = <<0:128>>,
    <<L0:8, L1:8, _/binary>> = wasm_simd:binary_op(i8x16_narrow_i16x8_u, A, B),
    ?assertEqual(0, L0),
    ?assertEqual(255, L1),
    %% Signed narrowing clamps to the signed range instead.
    <<S0:8/signed, S1:8/signed, _/binary>> =
        wasm_simd:binary_op(i8x16_narrow_i16x8_s, A, B),
    ?assertEqual(-1, S0),
    ?assertEqual(127, S1).

%% `pmin` is not `min`. It is specified as "return the second operand if it
%% compares less than the first, otherwise the first", which propagates the
%% *first* operand when either is NaN and does not order -0.0 below +0.0.
pmin_is_not_min(_Config) ->
    Nan = wasm_num:f32_to_bits({nan, 0, 16#400000}),
    One = wasm_num:f32_to_bits(1.0),
    A = <<Nan:32/little, One:32/little, 0:64>>,
    B = <<One:32/little, Nan:32/little, 0:64>>,
    <<P0:32/little, P1:32/little, _/binary>> =
        wasm_simd:binary_op(f32x4_pmin, A, B),
    %% Neither lane is NaN-propagating in the usual sense: whichever operand is
    %% first wins whenever the comparison is not true, and a NaN comparison is
    %% never true.
    ?assertEqual(Nan, P0),
    ?assertEqual(One, P1),
    %% `min` in contrast is required to produce a NaN if either operand is one.
    <<M0:32/little, _/binary>> = wasm_simd:binary_op(f32x4_min, A, B),
    ?assert(wasm_num:is_nan(wasm_num:f32_from_bits(M0))).

%% A lane holding NaN or Infinity survives being read and written.
%%
%% This is the reason float lanes are not matched with a `:32/float` field:
%% Erlang cannot represent those values as floats, and the bit patterns do not
%% match a float field at all, so such a lane would raise rather than compare
%% unequal.
nan_lanes_survive_a_round_trip(_Config) ->
    Bits = wasm_num:f32_to_bits({nan, 1, 16#123456}),
    Inf = wasm_num:f32_to_bits(infinity),
    V = <<Bits:32/little, Inf:32/little, 0:64>>,
    ?assertEqual({nan, 1, 16#123456}, wasm_simd:extract(f32x4_extract_lane, 0, V)),
    ?assertEqual(infinity, wasm_simd:extract(f32x4_extract_lane, 1, V)),
    Rebuilt = wasm_simd:replace(f32x4_replace_lane, 3, V, {nan, 0, 16#7FFFFF}),
    ?assertEqual({nan, 0, 16#7FFFFF},
                 wasm_simd:extract(f32x4_extract_lane, 3, Rebuilt)),
    ?assertEqual(infinity, wasm_simd:extract(f32x4_extract_lane, 1, Rebuilt)).

%% `i8x16.swizzle` takes its indices at run time, so an index of 16 or more is
%% possible and must yield zero. `i8x16.shuffle` cannot hit this: its indices
%% are immediates and validation has already rejected anything above 31.
swizzle_out_of_range_yields_zero(_Config) ->
    Src = list_to_binary(lists:seq(1, 16)),
    Idx = <<0:8, 15:8, 16:8, 255:8, 0:96>>,
    <<L0:8, L1:8, L2:8, L3:8, _/binary>> = wasm_simd:swizzle(Src, Idx),
    ?assertEqual(1, L0),
    ?assertEqual(16, L1),
    ?assertEqual(0, L2),
    ?assertEqual(0, L3).

%% `bitmask` gathers the sign bit of each lane, lane 0 in bit 0.
bitmask_gathers_sign_bits_lane_zero_first(_Config) ->
    %% Lanes 0 and 2 negative, lanes 1 and 3 not.
    V = <<16#FFFFFFFF:32/little, 0:32, 16#80000000:32/little, 1:32/little>>,
    ?assertEqual(2#0101, wasm_simd:unary(i32x4_bitmask, V)),
    ?assertEqual(0, wasm_simd:unary(i32x4_bitmask, <<0:128>>)),
    All = binary:copy(<<16#FF>>, 16),
    ?assertEqual(16#FFFF, wasm_simd:unary(i8x16_bitmask, All)).

%% Converting to an f32 lane rounds once, from the integer, rather than going
%% through f64. The single-rounding theorem does not cover integer conversion,
%% which is the same rule `wasm_num_SUITE` pins for the scalar instruction.
f32x4_lanes_round_once(_Config) ->
    %% 16777217 is 2^24 + 1, the smallest integer f32 cannot represent.
    V = <<16777217:32/little, 0:96>>,
    <<L0:32/little, _/binary>> = wasm_simd:unary(f32x4_convert_i32x4_s, V),
    ?assertEqual(16777216.0, wasm_num:f32_from_bits(L0)),
    %% Saturating truncation clamps rather than trapping, and NaN becomes zero.
    Nan = wasm_num:f32_to_bits({nan, 0, 16#400000}),
    Big = wasm_num:f32_to_bits(1.0e30),
    F = <<Nan:32/little, Big:32/little, 0:64>>,
    <<T0:32/little-signed, T1:32/little-signed, _/binary>> =
        wasm_simd:unary(i32x4_trunc_sat_f32x4_s, F),
    ?assertEqual(0, T0),
    ?assertEqual(2147483647, T1).

%%% ---------------------------------------------------------------- helpers ---

splat32(X) -> binary:copy(<<X:32/little>>, 4).
