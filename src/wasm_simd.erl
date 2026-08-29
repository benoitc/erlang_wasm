-module(wasm_simd).
-moduledoc """
Fixed-width SIMD: `v128` values and the operations on them. Read this before
you add a vector instruction, or when you want to know what one costs.

## Why a 16-byte binary

A `v128` is a 16-byte binary. The alternative was a 128-bit integer, and the
choice was measured rather than assumed. Per operation, 200,000 iterations,
minimum of five runs:

| operation | binary | 128-bit integer |
| --- | ---: | ---: |
| `i32x4.add` | **11.8 ns** | 126.0 ns |
| `i8x16.add` | **14.6 ns** | 610.6 ns |
| `f32x4.mul` | **76.9 ns** | 296.7 ns |
| `i32x4.extract_lane` | **5.0 ns** | 17.4 ns |
| `i8x16.shuffle` | **154 ns** | 497 ns |
| `v128.and` | 11.9 ns | **10.6 ns** |

Bit syntax truncates each field to its declared width, so lane wrapping is free
where the integer form needs an explicit mask per lane, and a binary is built
in one allocation where a shift-and-or chain allocates an intermediate bignum
per lane. The integer form wins only on `v128.and`, and only by 12%.

## Why lanes are matched, not iterated

Every lane operation matches all its lanes in one pattern. The obvious
`binary_to_list`, `lists:zip`, comprehension route costs 182 ns for
`i8x16.add` against 14.6 ns; a binary comprehension with a zip generator is
worse still at 253 ns.

Writing all 240 operations out at full width would be some thousands of lines,
so the lane split is done once per shape in `zip16/3` and friends and the
operations are ordinary funs. That costs 1.4x to 1.8x against inlining
(`i8x16.add` 30.3 ns rather than 17.2 ns) and is still six times better than
iterating. Specialising a hot shape later is a local change.

## Floats

Float lanes are *not* matched with `:32/float`. Erlang cannot represent NaN or
Infinity as a float, and those bit patterns do not match a float field at all,
so a lane holding a NaN would fail to match rather than compare unequal. Lanes
are extracted as integer bit patterns and converted through `wasm_num`, giving
the same hybrid representation the scalar instructions use, and so the same
NaN propagation and quieting rules for free.
""".

-export([unary/2, binary_op/3, shift/3, splat/2, extract/3, replace/4]).
-export([shuffle/3, swizzle/2, bitselect/3, ternary/4]).
-export([load/2, store_bytes/1, load_lane/4, store_lane_bytes/3]).
-export([zero/0, is_v128/1]).

-doc "A 128-bit vector: exactly 16 bytes, little-endian lane order.".
-nominal v128() :: binary().
-export_type([v128/0]).

%%% --------------------------------------------------------------- values ---

-spec zero() -> v128().
zero() -> <<0:128>>.

-spec is_v128(term()) -> boolean().
is_v128(V) -> is_binary(V) andalso byte_size(V) =:= 16.

%%% ---------------------------------------------------------- lane mapping ---

%% One split per shape, shared by every operation on that shape. Unsigned and
%% signed variants are separate rather than one plus a sign-extension step,
%% because bit syntax does the extension in the match itself.

zip16(F, <<A0,A1,A2,A3,A4,A5,A6,A7,A8,A9,A10,A11,A12,A13,A14,A15>>,
         <<B0,B1,B2,B3,B4,B5,B6,B7,B8,B9,B10,B11,B12,B13,B14,B15>>) ->
    <<(F(A0,B0)):8,(F(A1,B1)):8,(F(A2,B2)):8,(F(A3,B3)):8,
      (F(A4,B4)):8,(F(A5,B5)):8,(F(A6,B6)):8,(F(A7,B7)):8,
      (F(A8,B8)):8,(F(A9,B9)):8,(F(A10,B10)):8,(F(A11,B11)):8,
      (F(A12,B12)):8,(F(A13,B13)):8,(F(A14,B14)):8,(F(A15,B15)):8>>.

zip16s(F, <<A0:8/signed,A1:8/signed,A2:8/signed,A3:8/signed,A4:8/signed,
            A5:8/signed,A6:8/signed,A7:8/signed,A8:8/signed,A9:8/signed,
            A10:8/signed,A11:8/signed,A12:8/signed,A13:8/signed,
            A14:8/signed,A15:8/signed>>,
          <<B0:8/signed,B1:8/signed,B2:8/signed,B3:8/signed,B4:8/signed,
            B5:8/signed,B6:8/signed,B7:8/signed,B8:8/signed,B9:8/signed,
            B10:8/signed,B11:8/signed,B12:8/signed,B13:8/signed,
            B14:8/signed,B15:8/signed>>) ->
    <<(F(A0,B0)):8,(F(A1,B1)):8,(F(A2,B2)):8,(F(A3,B3)):8,
      (F(A4,B4)):8,(F(A5,B5)):8,(F(A6,B6)):8,(F(A7,B7)):8,
      (F(A8,B8)):8,(F(A9,B9)):8,(F(A10,B10)):8,(F(A11,B11)):8,
      (F(A12,B12)):8,(F(A13,B13)):8,(F(A14,B14)):8,(F(A15,B15)):8>>.

map16(F, <<A0,A1,A2,A3,A4,A5,A6,A7,A8,A9,A10,A11,A12,A13,A14,A15>>) ->
    <<(F(A0)):8,(F(A1)):8,(F(A2)):8,(F(A3)):8,(F(A4)):8,(F(A5)):8,
      (F(A6)):8,(F(A7)):8,(F(A8)):8,(F(A9)):8,(F(A10)):8,(F(A11)):8,
      (F(A12)):8,(F(A13)):8,(F(A14)):8,(F(A15)):8>>.

map16s(F, <<A0:8/signed,A1:8/signed,A2:8/signed,A3:8/signed,A4:8/signed,
            A5:8/signed,A6:8/signed,A7:8/signed,A8:8/signed,A9:8/signed,
            A10:8/signed,A11:8/signed,A12:8/signed,A13:8/signed,
            A14:8/signed,A15:8/signed>>) ->
    <<(F(A0)):8,(F(A1)):8,(F(A2)):8,(F(A3)):8,(F(A4)):8,(F(A5)):8,
      (F(A6)):8,(F(A7)):8,(F(A8)):8,(F(A9)):8,(F(A10)):8,(F(A11)):8,
      (F(A12)):8,(F(A13)):8,(F(A14)):8,(F(A15)):8>>.

zip8(F, <<A0:16/little,A1:16/little,A2:16/little,A3:16/little,
          A4:16/little,A5:16/little,A6:16/little,A7:16/little>>,
        <<B0:16/little,B1:16/little,B2:16/little,B3:16/little,
          B4:16/little,B5:16/little,B6:16/little,B7:16/little>>) ->
    <<(F(A0,B0)):16/little,(F(A1,B1)):16/little,(F(A2,B2)):16/little,
      (F(A3,B3)):16/little,(F(A4,B4)):16/little,(F(A5,B5)):16/little,
      (F(A6,B6)):16/little,(F(A7,B7)):16/little>>.

zip8s(F, <<A0:16/little-signed,A1:16/little-signed,A2:16/little-signed,
           A3:16/little-signed,A4:16/little-signed,A5:16/little-signed,
           A6:16/little-signed,A7:16/little-signed>>,
         <<B0:16/little-signed,B1:16/little-signed,B2:16/little-signed,
           B3:16/little-signed,B4:16/little-signed,B5:16/little-signed,
           B6:16/little-signed,B7:16/little-signed>>) ->
    <<(F(A0,B0)):16/little,(F(A1,B1)):16/little,(F(A2,B2)):16/little,
      (F(A3,B3)):16/little,(F(A4,B4)):16/little,(F(A5,B5)):16/little,
      (F(A6,B6)):16/little,(F(A7,B7)):16/little>>.

map8(F, <<A0:16/little,A1:16/little,A2:16/little,A3:16/little,
          A4:16/little,A5:16/little,A6:16/little,A7:16/little>>) ->
    <<(F(A0)):16/little,(F(A1)):16/little,(F(A2)):16/little,(F(A3)):16/little,
      (F(A4)):16/little,(F(A5)):16/little,(F(A6)):16/little,
      (F(A7)):16/little>>.

map8s(F, <<A0:16/little-signed,A1:16/little-signed,A2:16/little-signed,
           A3:16/little-signed,A4:16/little-signed,A5:16/little-signed,
           A6:16/little-signed,A7:16/little-signed>>) ->
    <<(F(A0)):16/little,(F(A1)):16/little,(F(A2)):16/little,(F(A3)):16/little,
      (F(A4)):16/little,(F(A5)):16/little,(F(A6)):16/little,
      (F(A7)):16/little>>.

zip4(F, <<A0:32/little,A1:32/little,A2:32/little,A3:32/little>>,
        <<B0:32/little,B1:32/little,B2:32/little,B3:32/little>>) ->
    <<(F(A0,B0)):32/little,(F(A1,B1)):32/little,
      (F(A2,B2)):32/little,(F(A3,B3)):32/little>>.

zip4s(F, <<A0:32/little-signed,A1:32/little-signed,
           A2:32/little-signed,A3:32/little-signed>>,
         <<B0:32/little-signed,B1:32/little-signed,
           B2:32/little-signed,B3:32/little-signed>>) ->
    <<(F(A0,B0)):32/little,(F(A1,B1)):32/little,
      (F(A2,B2)):32/little,(F(A3,B3)):32/little>>.

map4(F, <<A0:32/little,A1:32/little,A2:32/little,A3:32/little>>) ->
    <<(F(A0)):32/little,(F(A1)):32/little,(F(A2)):32/little,(F(A3)):32/little>>.

map4s(F, <<A0:32/little-signed,A1:32/little-signed,
           A2:32/little-signed,A3:32/little-signed>>) ->
    <<(F(A0)):32/little,(F(A1)):32/little,(F(A2)):32/little,(F(A3)):32/little>>.

zip2(F, <<A0:64/little,A1:64/little>>, <<B0:64/little,B1:64/little>>) ->
    <<(F(A0,B0)):64/little,(F(A1,B1)):64/little>>.

zip2s(F, <<A0:64/little-signed,A1:64/little-signed>>,
         <<B0:64/little-signed,B1:64/little-signed>>) ->
    <<(F(A0,B0)):64/little,(F(A1,B1)):64/little>>.

map2(F, <<A0:64/little,A1:64/little>>) ->
    <<(F(A0)):64/little,(F(A1)):64/little>>.

map2s(F, <<A0:64/little-signed,A1:64/little-signed>>) ->
    <<(F(A0)):64/little,(F(A1)):64/little>>.

%% Float lanes go through the bit-pattern conversions rather than a `/float'
%% field, because a lane holding NaN or Infinity would not match one.
zipf4(F, A, B) ->
    zip4(fun(X, Y) -> f32b(F(f32(X), f32(Y))) end, A, B).

mapf4(F, A) -> map4(fun(X) -> f32b(F(f32(X))) end, A).

zipf2(F, A, B) ->
    zip2(fun(X, Y) -> f64b(F(f64(X), f64(Y))) end, A, B).

mapf2(F, A) -> map2(fun(X) -> f64b(F(f64(X))) end, A).

f32(Bits) -> wasm_num:f32_from_bits(Bits).
f32b(F) -> wasm_num:f32_to_bits(F).
f64(Bits) -> wasm_num:f64_from_bits(Bits).
f64b(F) -> wasm_num:f64_to_bits(F).

%% A lane-wise comparison yields all-ones for true and all-zeros for false,
%% which is what makes `v128.bitselect' a mask operation.
mask(true, Bits) -> (1 bsl Bits) - 1;
mask(false, _Bits) -> 0.

%%% ----------------------------------------------------------- binary ops ---

-doc "Apply a two-operand vector instruction.".
-spec binary_op(atom(), v128(), v128()) -> v128().

%% - bitwise ---------------------------------------------------------------
binary_op(v128_and, <<A0:64,A1:64>>, <<B0:64,B1:64>>) ->
    <<(A0 band B0):64, (A1 band B1):64>>;
binary_op(v128_or, <<A0:64,A1:64>>, <<B0:64,B1:64>>) ->
    <<(A0 bor B0):64, (A1 bor B1):64>>;
binary_op(v128_xor, <<A0:64,A1:64>>, <<B0:64,B1:64>>) ->
    <<(A0 bxor B0):64, (A1 bxor B1):64>>;
binary_op(v128_andnot, <<A0:64,A1:64>>, <<B0:64,B1:64>>) ->
    <<(A0 band (bnot B0)):64, (A1 band (bnot B1)):64>>;

%% - integer comparisons ---------------------------------------------------
binary_op(i8x16_eq, A, B) -> zip16(fun(X,Y) -> mask(X =:= Y, 8) end, A, B);
binary_op(i8x16_ne, A, B) -> zip16(fun(X,Y) -> mask(X =/= Y, 8) end, A, B);
binary_op(i8x16_lt_u, A, B) -> zip16(fun(X,Y) -> mask(X < Y, 8) end, A, B);
binary_op(i8x16_gt_u, A, B) -> zip16(fun(X,Y) -> mask(X > Y, 8) end, A, B);
binary_op(i8x16_le_u, A, B) -> zip16(fun(X,Y) -> mask(X =< Y, 8) end, A, B);
binary_op(i8x16_ge_u, A, B) -> zip16(fun(X,Y) -> mask(X >= Y, 8) end, A, B);
binary_op(i8x16_lt_s, A, B) -> zip16s(fun(X,Y) -> mask(X < Y, 8) end, A, B);
binary_op(i8x16_gt_s, A, B) -> zip16s(fun(X,Y) -> mask(X > Y, 8) end, A, B);
binary_op(i8x16_le_s, A, B) -> zip16s(fun(X,Y) -> mask(X =< Y, 8) end, A, B);
binary_op(i8x16_ge_s, A, B) -> zip16s(fun(X,Y) -> mask(X >= Y, 8) end, A, B);

binary_op(i16x8_eq, A, B) -> zip8(fun(X,Y) -> mask(X =:= Y, 16) end, A, B);
binary_op(i16x8_ne, A, B) -> zip8(fun(X,Y) -> mask(X =/= Y, 16) end, A, B);
binary_op(i16x8_lt_u, A, B) -> zip8(fun(X,Y) -> mask(X < Y, 16) end, A, B);
binary_op(i16x8_gt_u, A, B) -> zip8(fun(X,Y) -> mask(X > Y, 16) end, A, B);
binary_op(i16x8_le_u, A, B) -> zip8(fun(X,Y) -> mask(X =< Y, 16) end, A, B);
binary_op(i16x8_ge_u, A, B) -> zip8(fun(X,Y) -> mask(X >= Y, 16) end, A, B);
binary_op(i16x8_lt_s, A, B) -> zip8s(fun(X,Y) -> mask(X < Y, 16) end, A, B);
binary_op(i16x8_gt_s, A, B) -> zip8s(fun(X,Y) -> mask(X > Y, 16) end, A, B);
binary_op(i16x8_le_s, A, B) -> zip8s(fun(X,Y) -> mask(X =< Y, 16) end, A, B);
binary_op(i16x8_ge_s, A, B) -> zip8s(fun(X,Y) -> mask(X >= Y, 16) end, A, B);

binary_op(i32x4_eq, A, B) -> zip4(fun(X,Y) -> mask(X =:= Y, 32) end, A, B);
binary_op(i32x4_ne, A, B) -> zip4(fun(X,Y) -> mask(X =/= Y, 32) end, A, B);
binary_op(i32x4_lt_u, A, B) -> zip4(fun(X,Y) -> mask(X < Y, 32) end, A, B);
binary_op(i32x4_gt_u, A, B) -> zip4(fun(X,Y) -> mask(X > Y, 32) end, A, B);
binary_op(i32x4_le_u, A, B) -> zip4(fun(X,Y) -> mask(X =< Y, 32) end, A, B);
binary_op(i32x4_ge_u, A, B) -> zip4(fun(X,Y) -> mask(X >= Y, 32) end, A, B);
binary_op(i32x4_lt_s, A, B) -> zip4s(fun(X,Y) -> mask(X < Y, 32) end, A, B);
binary_op(i32x4_gt_s, A, B) -> zip4s(fun(X,Y) -> mask(X > Y, 32) end, A, B);
binary_op(i32x4_le_s, A, B) -> zip4s(fun(X,Y) -> mask(X =< Y, 32) end, A, B);
binary_op(i32x4_ge_s, A, B) -> zip4s(fun(X,Y) -> mask(X >= Y, 32) end, A, B);

binary_op(i64x2_eq, A, B) -> zip2(fun(X,Y) -> mask(X =:= Y, 64) end, A, B);
binary_op(i64x2_ne, A, B) -> zip2(fun(X,Y) -> mask(X =/= Y, 64) end, A, B);
binary_op(i64x2_lt_s, A, B) -> zip2s(fun(X,Y) -> mask(X < Y, 64) end, A, B);
binary_op(i64x2_gt_s, A, B) -> zip2s(fun(X,Y) -> mask(X > Y, 64) end, A, B);
binary_op(i64x2_le_s, A, B) -> zip2s(fun(X,Y) -> mask(X =< Y, 64) end, A, B);
binary_op(i64x2_ge_s, A, B) -> zip2s(fun(X,Y) -> mask(X >= Y, 64) end, A, B);

%% - float comparisons -----------------------------------------------------
%% Delegated to the scalar comparisons, which already give NaN the unordered
%% result rather than an Erlang term ordering.
binary_op(f32x4_eq, A, B) -> fcmp4(fun wasm_num_float:eq/3, A, B);
binary_op(f32x4_ne, A, B) -> fcmp4(fun wasm_num_float:ne/3, A, B);
binary_op(f32x4_lt, A, B) -> fcmp4(fun wasm_num_float:lt/3, A, B);
binary_op(f32x4_gt, A, B) -> fcmp4(fun wasm_num_float:gt/3, A, B);
binary_op(f32x4_le, A, B) -> fcmp4(fun wasm_num_float:le/3, A, B);
binary_op(f32x4_ge, A, B) -> fcmp4(fun wasm_num_float:ge/3, A, B);
binary_op(f64x2_eq, A, B) -> fcmp2(fun wasm_num_float:eq/3, A, B);
binary_op(f64x2_ne, A, B) -> fcmp2(fun wasm_num_float:ne/3, A, B);
binary_op(f64x2_lt, A, B) -> fcmp2(fun wasm_num_float:lt/3, A, B);
binary_op(f64x2_gt, A, B) -> fcmp2(fun wasm_num_float:gt/3, A, B);
binary_op(f64x2_le, A, B) -> fcmp2(fun wasm_num_float:le/3, A, B);
binary_op(f64x2_ge, A, B) -> fcmp2(fun wasm_num_float:ge/3, A, B);

%% - integer arithmetic ----------------------------------------------------
binary_op(i8x16_add, A, B) -> zip16(fun erlang:'+'/2, A, B);
binary_op(i8x16_sub, A, B) -> zip16(fun(X,Y) -> X - Y end, A, B);
binary_op(i16x8_add, A, B) -> zip8(fun erlang:'+'/2, A, B);
binary_op(i16x8_sub, A, B) -> zip8(fun(X,Y) -> X - Y end, A, B);
binary_op(i16x8_mul, A, B) -> zip8(fun erlang:'*'/2, A, B);
binary_op(i32x4_add, A, B) -> zip4(fun erlang:'+'/2, A, B);
binary_op(i32x4_sub, A, B) -> zip4(fun(X,Y) -> X - Y end, A, B);
binary_op(i32x4_mul, A, B) -> zip4(fun erlang:'*'/2, A, B);
binary_op(i64x2_add, A, B) -> zip2(fun erlang:'+'/2, A, B);
binary_op(i64x2_sub, A, B) -> zip2(fun(X,Y) -> X - Y end, A, B);
binary_op(i64x2_mul, A, B) -> zip2(fun erlang:'*'/2, A, B);

binary_op(i8x16_add_sat_s, A, B) -> zip16s(sat_add(7), A, B);
binary_op(i8x16_sub_sat_s, A, B) -> zip16s(sat_sub(7), A, B);
binary_op(i16x8_add_sat_s, A, B) -> zip8s(sat_add(15), A, B);
binary_op(i16x8_sub_sat_s, A, B) -> zip8s(sat_sub(15), A, B);
binary_op(i8x16_add_sat_u, A, B) -> zip16(sat_add_u(8), A, B);
binary_op(i8x16_sub_sat_u, A, B) -> zip16(sat_sub_u(8), A, B);
binary_op(i16x8_add_sat_u, A, B) -> zip8(sat_add_u(16), A, B);
binary_op(i16x8_sub_sat_u, A, B) -> zip8(sat_sub_u(16), A, B);

binary_op(i8x16_min_s, A, B) -> zip16s(fun erlang:min/2, A, B);
binary_op(i8x16_max_s, A, B) -> zip16s(fun erlang:max/2, A, B);
binary_op(i8x16_min_u, A, B) -> zip16(fun erlang:min/2, A, B);
binary_op(i8x16_max_u, A, B) -> zip16(fun erlang:max/2, A, B);
binary_op(i16x8_min_s, A, B) -> zip8s(fun erlang:min/2, A, B);
binary_op(i16x8_max_s, A, B) -> zip8s(fun erlang:max/2, A, B);
binary_op(i16x8_min_u, A, B) -> zip8(fun erlang:min/2, A, B);
binary_op(i16x8_max_u, A, B) -> zip8(fun erlang:max/2, A, B);
binary_op(i32x4_min_s, A, B) -> zip4s(fun erlang:min/2, A, B);
binary_op(i32x4_max_s, A, B) -> zip4s(fun erlang:max/2, A, B);
binary_op(i32x4_min_u, A, B) -> zip4(fun erlang:min/2, A, B);
binary_op(i32x4_max_u, A, B) -> zip4(fun erlang:max/2, A, B);

%% Rounding average: the +1 makes it round half away from zero.
binary_op(i8x16_avgr_u, A, B) -> zip16(fun(X,Y) -> (X + Y + 1) bsr 1 end, A, B);
binary_op(i16x8_avgr_u, A, B) -> zip8(fun(X,Y) -> (X + Y + 1) bsr 1 end, A, B);

%% Q15 fixed-point multiply with rounding, saturated. The only lane operation
%% whose saturation can actually trigger is the single case -1 * -1.
binary_op(i16x8_q15mulr_sat_s, A, B) ->
    zip8s(fun(X, Y) -> sat_s((X * Y + 16#4000) bsr 15, 15) end, A, B);

%% - float arithmetic ------------------------------------------------------
binary_op(f32x4_add, A, B) -> zipf4(fn3(fun wasm_num_float:add/3, 32), A, B);
binary_op(f32x4_sub, A, B) -> zipf4(fn3(fun wasm_num_float:sub/3, 32), A, B);
binary_op(f32x4_mul, A, B) -> zipf4(fn3(fun wasm_num_float:mul/3, 32), A, B);
binary_op(f32x4_div, A, B) -> zipf4(fn3(fun wasm_num_float:divide/3, 32), A, B);
binary_op(f32x4_min, A, B) -> zipf4(fn3(fun wasm_num_float:min/3, 32), A, B);
binary_op(f32x4_max, A, B) -> zipf4(fn3(fun wasm_num_float:max/3, 32), A, B);
binary_op(f64x2_add, A, B) -> zipf2(fn3(fun wasm_num_float:add/3, 64), A, B);
binary_op(f64x2_sub, A, B) -> zipf2(fn3(fun wasm_num_float:sub/3, 64), A, B);
binary_op(f64x2_mul, A, B) -> zipf2(fn3(fun wasm_num_float:mul/3, 64), A, B);
binary_op(f64x2_div, A, B) -> zipf2(fn3(fun wasm_num_float:divide/3, 64), A, B);
binary_op(f64x2_min, A, B) -> zipf2(fn3(fun wasm_num_float:min/3, 64), A, B);
binary_op(f64x2_max, A, B) -> zipf2(fn3(fun wasm_num_float:max/3, 64), A, B);

%% `pmin`/`pmax` are deliberately *not* `min`/`max`. They are specified as
%% "return the second operand if the comparison is true, otherwise the first",
%% which propagates the second operand's NaN and treats -0.0 and +0.0 as equal.
binary_op(f32x4_pmin, A, B) -> zipf4(pmin(32), A, B);
binary_op(f32x4_pmax, A, B) -> zipf4(pmax(32), A, B);
binary_op(f64x2_pmin, A, B) -> zipf2(pmin(64), A, B);
binary_op(f64x2_pmax, A, B) -> zipf2(pmax(64), A, B);

%% - narrowing -------------------------------------------------------------
%% Two vectors in, one out: the result's first half comes from A and its second
%% from B, each lane saturated into the narrower width.
binary_op(i8x16_narrow_i16x8_s, A, B) ->
    <<(narrow(A, 16, 8, signed))/binary, (narrow(B, 16, 8, signed))/binary>>;
binary_op(i8x16_narrow_i16x8_u, A, B) ->
    <<(narrow(A, 16, 8, unsigned))/binary, (narrow(B, 16, 8, unsigned))/binary>>;
binary_op(i16x8_narrow_i32x4_s, A, B) ->
    <<(narrow(A, 32, 16, signed))/binary, (narrow(B, 32, 16, signed))/binary>>;
binary_op(i16x8_narrow_i32x4_u, A, B) ->
    <<(narrow(A, 32, 16, unsigned))/binary, (narrow(B, 32, 16, unsigned))/binary>>;

%% - extending multiply ----------------------------------------------------
binary_op(Op, A, B) when Op =:= i16x8_extmul_low_i8x16_s;
                         Op =:= i16x8_extmul_high_i8x16_s;
                         Op =:= i16x8_extmul_low_i8x16_u;
                         Op =:= i16x8_extmul_high_i8x16_u;
                         Op =:= i32x4_extmul_low_i16x8_s;
                         Op =:= i32x4_extmul_high_i16x8_s;
                         Op =:= i32x4_extmul_low_i16x8_u;
                         Op =:= i32x4_extmul_high_i16x8_u;
                         Op =:= i64x2_extmul_low_i32x4_s;
                         Op =:= i64x2_extmul_high_i32x4_s;
                         Op =:= i64x2_extmul_low_i32x4_u;
                         Op =:= i64x2_extmul_high_i32x4_u ->
    {From, Half, Sign} = extmul_shape(Op),
    Wide = From * 2,
    As = lanes(half(A, Half), From, Sign),
    Bs = lanes(half(B, Half), From, Sign),
    << <<(X * Y):Wide/little>> || {X, Y} <- lists:zip(As, Bs) >>;

%% - dot product -----------------------------------------------------------
%% Each result lane is the sum of two adjacent products, so this is the one
%% instruction whose lanes are not in one-to-one correspondence.
binary_op(i32x4_dot_i16x8_s, A, B) ->
    As = lanes(A, 16, signed),
    Bs = lanes(B, 16, signed),
    Products = [X * Y || {X, Y} <- lists:zip(As, Bs)],
    << <<(P0 + P1):32/little>> || [P0, P1] <- pairs(Products) >>;

%% - swizzle ---------------------------------------------------------------
binary_op(i8x16_swizzle, A, B) -> swizzle(A, B);

%% - relaxed ---------------------------------------------------------------
%% Every relaxed instruction here answers exactly as its strict counterpart
%% does. The proposal permits a set of answers per operator and requires only
%% that an implementation pick one and keep to it; there is no vector hardware
%% underneath this runtime to be faster by picking differently, so the choice
%% that costs nothing is the one that makes a module give the same answer
%% everywhere. That is the specification's own deterministic profile.
%%
%% `wasm_relaxed_simd_SUITE' asserts each of these choices by name, because
%% the conformance suite writes them as `either' and would accept any of them.

%% Out-of-range indices give zero, as `i8x16.swizzle' does.
binary_op(i8x16_relaxed_swizzle, A, B) -> swizzle(A, B);

%% IEEE min and max: NaN propagates, and -0.0 orders below +0.0.
binary_op(f32x4_relaxed_min, A, B) -> binary_op(f32x4_min, A, B);
binary_op(f32x4_relaxed_max, A, B) -> binary_op(f32x4_max, A, B);
binary_op(f64x2_relaxed_min, A, B) -> binary_op(f64x2_min, A, B);
binary_op(f64x2_relaxed_max, A, B) -> binary_op(f64x2_max, A, B);

%% Saturating, so the single -1 * -1 overflow gives 32767 rather than -32768.
binary_op(i16x8_relaxed_q15mulr_s, A, B) ->
    binary_op(i16x8_q15mulr_sat_s, A, B);

%% Both operands read as signed. The name says the second is a 7-bit value, so
%% its top bit is only set on input the producer promised would not occur; when
%% it is set anyway, reading it as signed is one of the two permitted answers.
binary_op(i16x8_relaxed_dot_i8x16_i7x16_s, A, B) ->
    As = lanes(A, 8, signed),
    Bs = lanes(B, 8, signed),
    Products = [X * Y || {X, Y} <- lists:zip(As, Bs)],
    << <<(P0 + P1):16/little>> || [P0, P1] <- pairs(Products) >>.

%%% ------------------------------------------------------------ unary ops ---

-doc """
Apply a one-operand vector instruction.

Most return a `v128`, but `bitmask`, `all_true` and `any_true` return an i32,
which is why the result type is not `v128()`.
""".
-spec unary(atom(), v128()) -> v128() | integer().

unary(v128_not, <<A0:64,A1:64>>) ->
    <<(bnot A0):64, (bnot A1):64>>;

unary(i8x16_abs, A) -> map16s(fun erlang:abs/1, A);
unary(i16x8_abs, A) -> map8s(fun erlang:abs/1, A);
unary(i32x4_abs, A) -> map4s(fun erlang:abs/1, A);
unary(i64x2_abs, A) -> map2s(fun erlang:abs/1, A);
unary(i8x16_neg, A) -> map16(fun(X) -> -X end, A);
unary(i16x8_neg, A) -> map8(fun(X) -> -X end, A);
unary(i32x4_neg, A) -> map4(fun(X) -> -X end, A);
unary(i64x2_neg, A) -> map2(fun(X) -> -X end, A);
unary(i8x16_popcnt, A) -> map16(fun popcount/1, A);

unary(v128_any_true, <<A0:64, A1:64>>) ->
    case A0 =/= 0 orelse A1 =/= 0 of true -> 1; false -> 0 end;
unary(i8x16_all_true, A) -> all_true(A, 8);
unary(i16x8_all_true, A) -> all_true(A, 16);
unary(i32x4_all_true, A) -> all_true(A, 32);
unary(i64x2_all_true, A) -> all_true(A, 64);
unary(i8x16_bitmask, A) -> bitmask(A, 8);
unary(i16x8_bitmask, A) -> bitmask(A, 16);
unary(i32x4_bitmask, A) -> bitmask(A, 32);
unary(i64x2_bitmask, A) -> bitmask(A, 64);

%% - widening --------------------------------------------------------------
unary(Op, A) when Op =:= i16x8_extend_low_i8x16_s;
                  Op =:= i16x8_extend_high_i8x16_s;
                  Op =:= i16x8_extend_low_i8x16_u;
                  Op =:= i16x8_extend_high_i8x16_u;
                  Op =:= i32x4_extend_low_i16x8_s;
                  Op =:= i32x4_extend_high_i16x8_s;
                  Op =:= i32x4_extend_low_i16x8_u;
                  Op =:= i32x4_extend_high_i16x8_u;
                  Op =:= i64x2_extend_low_i32x4_s;
                  Op =:= i64x2_extend_high_i32x4_s;
                  Op =:= i64x2_extend_low_i32x4_u;
                  Op =:= i64x2_extend_high_i32x4_u ->
    {From, Half, Sign} = extend_shape(Op),
    Wide = From * 2,
    << <<X:Wide/little>> || X <- lanes(half(A, Half), From, Sign) >>;

%% Adjacent lanes summed with widening, so eight i8 lanes become four i16.
unary(i16x8_extadd_pairwise_i8x16_s, A) -> extadd(A, 8, signed);
unary(i16x8_extadd_pairwise_i8x16_u, A) -> extadd(A, 8, unsigned);
unary(i32x4_extadd_pairwise_i16x8_s, A) -> extadd(A, 16, signed);
unary(i32x4_extadd_pairwise_i16x8_u, A) -> extadd(A, 16, unsigned);

%% - float unary -----------------------------------------------------------
unary(f32x4_abs, A) -> mapf4(fn2(fun wasm_num_float:abs/2, 32), A);
unary(f32x4_neg, A) -> mapf4(fn2(fun wasm_num_float:neg/2, 32), A);
unary(f32x4_sqrt, A) -> mapf4(fn2(fun wasm_num_float:sqrt/2, 32), A);
unary(f32x4_ceil, A) -> mapf4(fn2(fun wasm_num_float:ceil/2, 32), A);
unary(f32x4_floor, A) -> mapf4(fn2(fun wasm_num_float:floor/2, 32), A);
unary(f32x4_trunc, A) -> mapf4(fn2(fun wasm_num_float:trunc/2, 32), A);
unary(f32x4_nearest, A) -> mapf4(fn2(fun wasm_num_float:nearest/2, 32), A);
unary(f64x2_abs, A) -> mapf2(fn2(fun wasm_num_float:abs/2, 64), A);
unary(f64x2_neg, A) -> mapf2(fn2(fun wasm_num_float:neg/2, 64), A);
unary(f64x2_sqrt, A) -> mapf2(fn2(fun wasm_num_float:sqrt/2, 64), A);
unary(f64x2_ceil, A) -> mapf2(fn2(fun wasm_num_float:ceil/2, 64), A);
unary(f64x2_floor, A) -> mapf2(fn2(fun wasm_num_float:floor/2, 64), A);
unary(f64x2_trunc, A) -> mapf2(fn2(fun wasm_num_float:trunc/2, 64), A);
unary(f64x2_nearest, A) -> mapf2(fn2(fun wasm_num_float:nearest/2, 64), A);

%% - conversions -----------------------------------------------------------
unary(i32x4_trunc_sat_f32x4_s, A) ->
    map4(fun(Bits) -> trunc_sat(f32(Bits), i32_s) end, A);
unary(i32x4_trunc_sat_f32x4_u, A) ->
    map4(fun(Bits) -> trunc_sat(f32(Bits), i32_u) end, A);
unary(f32x4_convert_i32x4_s, A) ->
    map4s(fun(X) -> f32b(wasm_num_float:round_to(32, X * 1.0)) end, A);
unary(f32x4_convert_i32x4_u, A) ->
    map4(fun(X) -> f32b(wasm_num_float:round_to(32, X * 1.0)) end, A);

%% The `_zero` suffix is literal: two lanes are converted and the upper two are
%% set to zero, because the source shape has half as many lanes.
unary(i32x4_trunc_sat_f64x2_s_zero, <<A0:64/little, A1:64/little>>) ->
    <<(trunc_sat(f64(A0), i32_s)):32/little,
      (trunc_sat(f64(A1), i32_s)):32/little, 0:64>>;
unary(i32x4_trunc_sat_f64x2_u_zero, <<A0:64/little, A1:64/little>>) ->
    <<(trunc_sat(f64(A0), i32_u)):32/little,
      (trunc_sat(f64(A1), i32_u)):32/little, 0:64>>;
%% - relaxed ---------------------------------------------------------------
%% NaN gives zero and an out-of-range value saturates, exactly as the strict
%% `trunc_sat' family does. See the note on `binary_op/3' for why.
unary(i32x4_relaxed_trunc_f32x4_s, A) ->
    unary(i32x4_trunc_sat_f32x4_s, A);
unary(i32x4_relaxed_trunc_f32x4_u, A) ->
    unary(i32x4_trunc_sat_f32x4_u, A);
unary(i32x4_relaxed_trunc_f64x2_s_zero, A) ->
    unary(i32x4_trunc_sat_f64x2_s_zero, A);
unary(i32x4_relaxed_trunc_f64x2_u_zero, A) ->
    unary(i32x4_trunc_sat_f64x2_u_zero, A);

unary(f64x2_convert_low_i32x4_s, <<A0:32/little-signed, A1:32/little-signed,
                                   _:64>>) ->
    <<(f64b(A0 * 1.0)):64/little, (f64b(A1 * 1.0)):64/little>>;
unary(f64x2_convert_low_i32x4_u, <<A0:32/little, A1:32/little, _:64>>) ->
    <<(f64b(A0 * 1.0)):64/little, (f64b(A1 * 1.0)):64/little>>;
unary(f32x4_demote_f64x2_zero, <<A0:64/little, A1:64/little>>) ->
    <<(f32b(wasm_num_float:demote(f64(A0)))):32/little,
      (f32b(wasm_num_float:demote(f64(A1)))):32/little, 0:64>>;
unary(f64x2_promote_low_f32x4, <<A0:32/little, A1:32/little, _:64>>) ->
    <<(f64b(wasm_num_float:promote(f32(A0)))):64/little,
      (f64b(wasm_num_float:promote(f32(A1)))):64/little>>.

%%% ------------------------------------------------------------ shifts ---

-doc """
Apply a vector shift.

The shift count is taken modulo the lane width, so it is always in range and no
lane operation can fault.
""".
-spec shift(atom(), v128(), integer()) -> v128().
shift(i8x16_shl, A, N) -> map16(fun(X) -> X bsl (N band 7) end, A);
shift(i8x16_shr_u, A, N) -> map16(fun(X) -> X bsr (N band 7) end, A);
shift(i8x16_shr_s, A, N) -> map16s(fun(X) -> X bsr (N band 7) end, A);
shift(i16x8_shl, A, N) -> map8(fun(X) -> X bsl (N band 15) end, A);
shift(i16x8_shr_u, A, N) -> map8(fun(X) -> X bsr (N band 15) end, A);
shift(i16x8_shr_s, A, N) -> map8s(fun(X) -> X bsr (N band 15) end, A);
shift(i32x4_shl, A, N) -> map4(fun(X) -> X bsl (N band 31) end, A);
shift(i32x4_shr_u, A, N) -> map4(fun(X) -> X bsr (N band 31) end, A);
shift(i32x4_shr_s, A, N) -> map4s(fun(X) -> X bsr (N band 31) end, A);
shift(i64x2_shl, A, N) -> map2(fun(X) -> X bsl (N band 63) end, A);
shift(i64x2_shr_u, A, N) -> map2(fun(X) -> X bsr (N band 63) end, A);
shift(i64x2_shr_s, A, N) -> map2s(fun(X) -> X bsr (N band 63) end, A).

%%% ------------------------------------------------ lanes and construction ---

-doc "Broadcast a scalar into every lane.".
-spec splat(atom(), term()) -> v128().
splat(i8x16_splat, X) -> binary:copy(<<X:8>>, 16);
splat(i16x8_splat, X) -> binary:copy(<<X:16/little>>, 8);
splat(i32x4_splat, X) -> binary:copy(<<X:32/little>>, 4);
splat(i64x2_splat, X) -> binary:copy(<<X:64/little>>, 2);
splat(f32x4_splat, F) -> binary:copy(<<(f32b(F)):32/little>>, 4);
splat(f64x2_splat, F) -> binary:copy(<<(f64b(F)):64/little>>, 2).

-doc "Read one lane out as a scalar.".
-spec extract(atom(), non_neg_integer(), v128()) -> term().
extract(i8x16_extract_lane_s, L, V) -> lane_signed(V, L, 8);
extract(i8x16_extract_lane_u, L, V) -> lane_unsigned(V, L, 8);
extract(i16x8_extract_lane_s, L, V) -> lane_signed(V, L, 16);
extract(i16x8_extract_lane_u, L, V) -> lane_unsigned(V, L, 16);
extract(i32x4_extract_lane, L, V) -> lane_signed(V, L, 32);
extract(i64x2_extract_lane, L, V) -> lane_signed(V, L, 64);
extract(f32x4_extract_lane, L, V) -> f32(lane_unsigned(V, L, 32));
extract(f64x2_extract_lane, L, V) -> f64(lane_unsigned(V, L, 64)).

-doc "Write one lane, returning the whole vector.".
-spec replace(atom(), non_neg_integer(), v128(), term()) -> v128().
replace(i8x16_replace_lane, L, V, X) -> put_lane(V, L, 8, X);
replace(i16x8_replace_lane, L, V, X) -> put_lane(V, L, 16, X);
replace(i32x4_replace_lane, L, V, X) -> put_lane(V, L, 32, X);
replace(i64x2_replace_lane, L, V, X) -> put_lane(V, L, 64, X);
replace(f32x4_replace_lane, L, V, F) -> put_lane(V, L, 32, f32b(F));
replace(f64x2_replace_lane, L, V, F) -> put_lane(V, L, 64, f64b(F)).

-doc """
Select 16 bytes from the concatenation of two vectors.

The lane indices are immediates, so they are already known to be below 32 by
the time this runs: validation rejects anything else.
""".
-spec shuffle(binary(), v128(), v128()) -> v128().
shuffle(<<L0,L1,L2,L3,L4,L5,L6,L7,L8,L9,L10,L11,L12,L13,L14,L15>>, A, B) ->
    Both = <<A/binary, B/binary>>,
    <<(pick(Both,L0)):8,(pick(Both,L1)):8,(pick(Both,L2)):8,(pick(Both,L3)):8,
      (pick(Both,L4)):8,(pick(Both,L5)):8,(pick(Both,L6)):8,(pick(Both,L7)):8,
      (pick(Both,L8)):8,(pick(Both,L9)):8,(pick(Both,L10)):8,
      (pick(Both,L11)):8,(pick(Both,L12)):8,(pick(Both,L13)):8,
      (pick(Both,L14)):8,(pick(Both,L15)):8>>.

pick(Bin, I) -> binary:at(Bin, I).

-doc """
Select bytes of `A` by the dynamic indices in `B`.

Unlike `shuffle/3` the indices are runtime values, so an index of 16 or more is
possible and yields zero rather than faulting.
""".
-spec swizzle(v128(), v128()) -> v128().
swizzle(A, B) -> map16(fun(I) -> swizzle_at(A, I) end, B).

swizzle_at(_A, I) when I >= 16 -> 0;
swizzle_at(A, I) -> binary:at(A, I).

-doc """
Every three-operand vector instruction.

`v128.bitselect` was the only one until the relaxed proposal added nine more,
and the interpreter used to match its name as a literal. It dispatches by shape
now, like the one
- and two-operand instructions.
""".
-spec ternary(atom(), v128(), v128(), v128()) -> v128().
ternary(v128_bitselect, A, B, M) -> bitselect(A, B, M);

%% A lane whose mask is all ones or all zeros selects; the proposal leaves a
%% *partial* mask open, and a bitwise select is one of the permitted answers
%% for every lane width.
ternary(Op, A, B, M) when Op =:= i8x16_relaxed_laneselect;
                          Op =:= i16x8_relaxed_laneselect;
                          Op =:= i32x4_relaxed_laneselect;
                          Op =:= i64x2_relaxed_laneselect ->
    bitselect(A, B, M);

%% Unfused: the product is rounded to the lane width before the addition, so
%% there are two roundings. That is one of the two permitted answers and it is
%% the one that can be computed exactly. Erlang has no fused multiply-add, and
%% doing the arithmetic in double precision and rounding once would give an
%% answer that is *neither* permitted in the rare double-rounding case.
ternary(f32x4_relaxed_madd, A, B, C) -> madd4(plus, A, B, C);
ternary(f32x4_relaxed_nmadd, A, B, C) -> madd4(minus, A, B, C);
ternary(f64x2_relaxed_madd, A, B, C) -> madd2(plus, A, B, C);
ternary(f64x2_relaxed_nmadd, A, B, C) -> madd2(minus, A, B, C);

%% The dot product above, then a lane-wise addition that is allowed to wrap.
ternary(i32x4_relaxed_dot_i8x16_i7x16_add_s, A, B, C) ->
    Dot = binary_op(i16x8_relaxed_dot_i8x16_i7x16_s, A, B),
    Widened = << <<(P0 + P1):32/little>>
                 || [P0, P1] <- pairs(lanes(Dot, 16, signed)) >>,
    binary_op(i32x4_add, Widened, C).

%% There is no three-vector lane splitter, and one instruction family does not
%% earn a fourth `zip'. The three vectors are taken apart here instead.
madd4(Sign, <<A0:32/little, A1:32/little, A2:32/little, A3:32/little>>,
            <<B0:32/little, B1:32/little, B2:32/little, B3:32/little>>,
            <<C0:32/little, C1:32/little, C2:32/little, C3:32/little>>) ->
    << <<(f32b(fma(32, Sign, f32(X), f32(Y), f32(Z)))):32/little>>
       || {X, Y, Z} <- [{A0, B0, C0}, {A1, B1, C1}, {A2, B2, C2},
                        {A3, B3, C3}] >>.

madd2(Sign, <<A0:64/little, A1:64/little>>,
            <<B0:64/little, B1:64/little>>,
            <<C0:64/little, C1:64/little>>) ->
    << <<(f64b(fma(64, Sign, f64(X), f64(Y), f64(Z)))):64/little>>
       || {X, Y, Z} <- [{A0, B0, C0}, {A1, B1, C1}] >>.

%% Rounded twice on purpose: `mul' returns a value already at the lane's width.
fma(W, plus, X, Y, Z) ->
    wasm_num_float:add(W, wasm_num_float:mul(W, X, Y), Z);
fma(W, minus, X, Y, Z) ->
    wasm_num_float:add(W, wasm_num_float:neg(W, wasm_num_float:mul(W, X, Y)), Z).

-doc "Bitwise select: take a bit from `A` where the mask bit is set.".
-spec bitselect(v128(), v128(), v128()) -> v128().
bitselect(<<A0:64,A1:64>>, <<B0:64,B1:64>>, <<M0:64,M1:64>>) ->
    <<((A0 band M0) bor (B0 band (bnot M0))):64,
      ((A1 band M1) bor (B1 band (bnot M1))):64>>.

%%% --------------------------------------------------------- memory access ---

-doc """
Turn the bytes read from linear memory into a vector.

The caller does the bounds-checked read; the width it must read is
`load_width/1`. Splitting it this way keeps every memory concern in
`wasm_memory` and every lane concern here.
""".
-spec load(atom(), binary()) -> v128().
load(v128_load, Bytes) -> Bytes;
load(v128_load8x8_s, B) -> widen(B, 8, 16, signed);
load(v128_load8x8_u, B) -> widen(B, 8, 16, unsigned);
load(v128_load16x4_s, B) -> widen(B, 16, 32, signed);
load(v128_load16x4_u, B) -> widen(B, 16, 32, unsigned);
load(v128_load32x2_s, B) -> widen(B, 32, 64, signed);
load(v128_load32x2_u, B) -> widen(B, 32, 64, unsigned);
load(v128_load8_splat, B) -> binary:copy(B, 16);
load(v128_load16_splat, B) -> binary:copy(B, 8);
load(v128_load32_splat, B) -> binary:copy(B, 4);
load(v128_load64_splat, B) -> binary:copy(B, 2);
load(v128_load32_zero, B) -> <<B/binary, 0:96>>;
load(v128_load64_zero, B) -> <<B/binary, 0:64>>.

-doc "The whole vector, ready to be written to linear memory.".
-spec store_bytes(v128()) -> binary().
store_bytes(V) -> V.

-doc "Replace one lane from bytes read out of linear memory.".
-spec load_lane(atom(), non_neg_integer(), v128(), binary()) -> v128().
load_lane(v128_load8_lane, L, V, <<X:8>>) -> put_lane(V, L, 8, X);
load_lane(v128_load16_lane, L, V, <<X:16/little>>) -> put_lane(V, L, 16, X);
load_lane(v128_load32_lane, L, V, <<X:32/little>>) -> put_lane(V, L, 32, X);
load_lane(v128_load64_lane, L, V, <<X:64/little>>) -> put_lane(V, L, 64, X).

-doc "One lane, ready to be written to linear memory.".
-spec store_lane_bytes(atom(), non_neg_integer(), v128()) -> binary().
store_lane_bytes(v128_store8_lane, L, V) -> <<(lane_unsigned(V,L,8)):8>>;
store_lane_bytes(v128_store16_lane, L, V) -> <<(lane_unsigned(V,L,16)):16/little>>;
store_lane_bytes(v128_store32_lane, L, V) -> <<(lane_unsigned(V,L,32)):32/little>>;
store_lane_bytes(v128_store64_lane, L, V) -> <<(lane_unsigned(V,L,64)):64/little>>.

%%% --------------------------------------------------------------- helpers ---

lane_unsigned(V, L, Bits) ->
    Skip = L * Bits,
    <<_:Skip, X:Bits/little, _/bitstring>> = V,
    X.

lane_signed(V, L, Bits) ->
    Skip = L * Bits,
    <<_:Skip, X:Bits/little-signed, _/bitstring>> = V,
    X.

put_lane(V, L, Bits, X) ->
    Skip = L * Bits,
    <<Pre:Skip/bitstring, _:Bits, Post/bitstring>> = V,
    <<Pre/bitstring, X:Bits/little, Post/bitstring>>.

%% Lanes as a list, for the handful of operations whose lanes do not correspond
%% one to one: widening, narrowing, pairwise addition and the dot product.
lanes(Bin, Bits, unsigned) -> [X || <<X:Bits/little>> <= Bin];
lanes(Bin, Bits, signed) -> [X || <<X:Bits/little-signed>> <= Bin].

half(V, low) -> binary:part(V, 0, 8);
half(V, high) -> binary:part(V, 8, 8).

pairs([]) -> [];
pairs([A, B | Rest]) -> [[A, B] | pairs(Rest)].

widen(Bin, From, To, Sign) ->
    << <<X:To/little>> || X <- lanes(Bin, From, Sign) >>.

narrow(V, From, To, Sign) ->
    Clamp = case Sign of
                signed -> fun(X) -> sat_s(X, To - 1) end;
                unsigned -> fun(X) -> sat_u(X, To) end
            end,
    %% The source lanes are always read signed: narrowing is defined on the
    %% signed interpretation even when the destination is unsigned, which is
    %% what makes `narrow_i16x8_u` clamp -1 to 0 rather than to 65535.
    << <<(Clamp(X)):To/little>> || X <- lanes(V, From, signed) >>.

extadd(V, From, Sign) ->
    Wide = From * 2,
    << <<(A + B):Wide/little>> || [A, B] <- pairs(lanes(V, From, Sign)) >>.

extend_shape(Op) -> ext_shape(atom_to_list(Op)).
extmul_shape(Op) -> ext_shape(atom_to_list(Op)).

%% `i32x4_extmul_high_i16x8_s' names its source width, its half and its sign in
%% that order, so one parse serves both families.
ext_shape(Name) ->
    Half = case string:find(Name, "_low_") of nomatch -> high; _ -> low end,
    Sign = case lists:last(Name) of $s -> signed; $u -> unsigned end,
    From = case re:run(Name, "_i(8|16|32)x", [{capture, [1], list}]) of
               {match, [W]} -> list_to_integer(W)
           end,
    {From, Half, Sign}.

popcount(X) -> popcount(X, 0).
popcount(0, N) -> N;
popcount(X, N) -> popcount(X bsr 1, N + (X band 1)).

all_true(V, Bits) ->
    case lists:all(fun(X) -> X =/= 0 end, lanes(V, Bits, unsigned)) of
        true -> 1;
        false -> 0
    end.

%% The sign bit of each lane, gathered into an i32 with lane 0 in bit 0.
bitmask(V, Bits) ->
    Signs = [case X < 0 of true -> 1; false -> 0 end
             || X <- lanes(V, Bits, signed)],
    lists:foldr(fun(B, Acc) -> (Acc bsl 1) bor B end, 0, Signs).

%% Saturation. `sat_s(X, 7)' clamps into a signed byte.
sat_s(X, Bits) ->
    Max = (1 bsl Bits) - 1,
    Min = -(1 bsl Bits),
    erlang:min(Max, erlang:max(Min, X)).

sat_u(X, Bits) -> erlang:min((1 bsl Bits) - 1, erlang:max(0, X)).

sat_add(Bits) -> fun(X, Y) -> sat_s(X + Y, Bits) end.
sat_sub(Bits) -> fun(X, Y) -> sat_s(X - Y, Bits) end.
sat_add_u(Bits) -> fun(X, Y) -> sat_u(X + Y, Bits) end.
sat_sub_u(Bits) -> fun(X, Y) -> sat_u(X - Y, Bits) end.

%% The scalar float helpers take the width first, so they are partially applied
%% here rather than wrapped at every use.
fn2(F, W) -> fun(X) -> F(W, X) end.
fn3(F, W) -> fun(X, Y) -> F(W, X, Y) end.

%% `pmin x y` is "y < x ? y : x", which is not `min`: it returns x when either
%% operand is NaN, and does not order -0.0 below +0.0. The scalar comparisons
%% answer with the i32 0 or 1 that the scalar instructions push.
pmin(W) -> fun(X, Y) -> case wasm_num_float:lt(W, Y, X) of
                            1 -> Y; 0 -> X end end.
pmax(W) -> fun(X, Y) -> case wasm_num_float:lt(W, X, Y) of
                            1 -> Y; 0 -> X end end.

fcmp4(F, A, B) ->
    zip4(fun(X, Y) -> mask(F(32, f32(X), f32(Y)) =:= 1, 32) end, A, B).

fcmp2(F, A, B) ->
    zip2(fun(X, Y) -> mask(F(64, f64(X), f64(Y)) =:= 1, 64) end, A, B).

%% Saturating float-to-int, per lane. Shared with the scalar instruction, which
%% already gives NaN zero and clamps out-of-range values. The unsigned form
%% comes back signed-wrapped, which is what the lane field wants anyway.
trunc_sat(F, i32_s) -> wasm_num_trunc:apply(i32_trunc_sat_f64_s, F);
trunc_sat(F, i32_u) -> wasm_num_trunc:apply(i32_trunc_sat_f64_u, F).
