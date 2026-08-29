%% @doc Relaxed SIMD: the choices this runtime made, asserted by name.
%%
%% The proposal gives each of these instructions a *set* of permitted answers
%% and asks only that an implementation pick one and keep to it. The
%% conformance suite writes that as `either', so it accepts any member of the
%% set and cannot tell a considered choice from an accident.
%%
%% This runtime picks the specification's deterministic profile: every relaxed
%% instruction answers exactly as its strict counterpart does. There is no
%% vector hardware underneath a pure Erlang interpreter to be faster by picking
%% differently, so the choice that costs nothing is the one that makes a module
%% give the same answer on every machine.
%%
%% Each case below names the choice and asserts it on an input where the
%% permitted answers differ, which is the only place a choice is observable.
-module(wasm_relaxed_simd_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(V128, 16#7B).
-define(FD, 16#FD).

all() ->
    [every_instruction_decodes_validates_and_runs,
     swizzle_reads_out_of_range_as_zero,
     truncation_saturates_and_maps_nan_to_zero,
     laneselect_is_a_bitwise_select,
     min_and_max_propagate_nan,
     q15mulr_saturates_its_one_overflow,
     madd_rounds_twice,
     dot_reads_both_operands_as_signed,
     every_instruction_is_deterministic].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

%%% ------------------------------------------------------------- plumbing ---

%% All twenty through a real module: two-byte LEB128 sub-opcodes decode, the
%% validator knows their types, and the interpreter dispatches them.
%%
%% This is not redundant with conformance. `i32x4_relaxed_trunc.wast` upstream
%% is eight lines containing a module and no assertions at all, so the four
%% truncation instructions have no conformance coverage whatsoever.
every_instruction_decodes_validates_and_runs(_Config) ->
    {ok, Inst} = instantiate(all_relaxed_module()),
    A = lanes8([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0]),
    B = lanes8([2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2]),
    C = lanes8([3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3]),
    lists:foreach(
      fun({Name, 1}) -> ?assertMatch({ok, [<<_:16/binary>>]},
                                     wasm:call(Inst, Name, [A]));
         ({Name, 2}) -> ?assertMatch({ok, [<<_:16/binary>>]},
                                     wasm:call(Inst, Name, [A, B]));
         ({Name, 3}) -> ?assertMatch({ok, [<<_:16/binary>>]},
                                     wasm:call(Inst, Name, [A, B, C]))
      end, instructions()),
    ?assertEqual(20, length(instructions())),
    ok = wasm:destroy(Inst).

%%% --------------------------------------------------------- the choices ---

%% An index of 16 or more may read as zero or modulo 16. Zero, as
%% `i8x16.swizzle` does.
swizzle_reads_out_of_range_as_zero(_Config) ->
    A = lanes8(lists:seq(100, 115)),
    Idx = lanes8([0, 16, 17, 255, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    Got = wasm_simd:binary_op(i8x16_relaxed_swizzle, A, Idx),
    ?assertEqual(wasm_simd:swizzle(A, Idx), Got),
    ?assertEqual([100, 0, 0, 0, 101], lists:sublist(binary_to_list(Got), 5)).

%% NaN may become 0 or the type's minimum, and an out-of-range value may
%% saturate or become the maximum. Zero and saturate, as `trunc_sat` does.
truncation_saturates_and_maps_nan_to_zero(_Config) ->
    Nan = <<0:32, 16#7FC00000:32/little, 16#7F7FFFFF:32/little, 0:32>>,
    Got = wasm_simd:unary(i32x4_relaxed_trunc_f32x4_s, Nan),
    ?assertEqual(wasm_simd:unary(i32x4_trunc_sat_f32x4_s, Nan), Got),
    [_, NanLane, BigLane, _] = [X || <<X:32/little-signed>> <= Got],
    ?assertEqual(0, NanLane),
    ?assertEqual(16#7FFFFFFF, BigLane).

%% A lane whose mask is all ones or all zeros selects either way; a *partial*
%% mask is where the choice shows. A bitwise select, not a top-bit test.
laneselect_is_a_bitwise_select(_Config) ->
    A = lanes8(lists:duplicate(16, 16#FF)),
    B = lanes8(lists:duplicate(16, 16#00)),
    Partial = lanes8(lists:duplicate(16, 16#0F)),
    Got = wasm_simd:ternary(i8x16_relaxed_laneselect, A, B, Partial),
    ?assertEqual(wasm_simd:bitselect(A, B, Partial), Got),
    %% A top-bit test would have answered all zeros, since bit 7 is clear.
    ?assertEqual(lists:duplicate(16, 16#0F), binary_to_list(Got)).

%% With a NaN operand, either operand may be returned. IEEE min and max, so the
%% NaN propagates.
min_and_max_propagate_nan(_Config) ->
    Nan = <<16#7FC00000:32/little, 0:32, 0:32, 0:32>>,
    Zero = <<0:128>>,
    Min = wasm_simd:binary_op(f32x4_relaxed_min, Nan, Zero),
    Max = wasm_simd:binary_op(f32x4_relaxed_max, Nan, Zero),
    ?assertEqual(wasm_simd:binary_op(f32x4_min, Nan, Zero), Min),
    ?assertEqual(wasm_simd:binary_op(f32x4_max, Nan, Zero), Max),
    [MinLane | _] = [X || <<X:32/little>> <= Min],
    ?assert(MinLane band 16#7F800000 =:= 16#7F800000 andalso
            MinLane band 16#7FFFFF =/= 0, {not_a_nan, MinLane}).

%% The single case -32768 * -32768 may give -32768 or 32767. Saturating, so
%% 32767, as `i16x8.q15mulr_sat_s` does.
q15mulr_saturates_its_one_overflow(_Config) ->
    V = << <<16#8000:16/little>> || _ <- lists:seq(1, 8) >>,
    Got = wasm_simd:binary_op(i16x8_relaxed_q15mulr_s, V, V),
    ?assertEqual(wasm_simd:binary_op(i16x8_q15mulr_sat_s, V, V), Got),
    ?assertEqual(lists:duplicate(8, 32767),
                 [X || <<X:16/little-signed>> <= Got]).

%% The product may be rounded once, fused with the addition, or twice. Twice:
%% the product is rounded to the lane width before the addition.
%%
%% The witness has to make the product land exactly on a rounding tie, which is
%% the only place the two answers differ.
%%
%% With a = b = 1 + 2^-12, the exact product is 1 + 2^-11 + 2^-24. An f32's ulp
%% near 1 is 2^-23, so that trailing 2^-24 is exactly half an ulp and ties to
%% even, giving 1 + 2^-11. Adding c = -(1 + 2^-11) then cancels to **zero**.
%% Fused, the addition sees the unrounded product and the answer is 2^-24.
madd_rounds_twice(_Config) ->
    A = f32v(1.0 + math:pow(2, -12)),
    C = f32v(-(1.0 + math:pow(2, -11))),
    Got = wasm_simd:ternary(f32x4_relaxed_madd, A, A, C),
    ?assertEqual(lists:duplicate(4, 0), [X || <<X:32/little>> <= Got],
                 fused_would_have_left_two_to_the_minus_24),
    %% And it is exactly the two strict operations performed in order.
    ?assertEqual(wasm_simd:binary_op(f32x4_add,
                                     wasm_simd:binary_op(f32x4_mul, A, A), C),
                 Got).

%% The second operand is named `i7x16`, so its top bit is only set on input the
%% producer promised would not occur. When it is set anyway it may read as
%% signed or unsigned. Signed.
dot_reads_both_operands_as_signed(_Config) ->
    A = lanes8(lists:duplicate(16, 1)),
    B = lanes8(lists:duplicate(16, 16#FF)),          % -1 signed, 255 unsigned
    Got = wasm_simd:binary_op(i16x8_relaxed_dot_i8x16_i7x16_s, A, B),
    ?assertEqual(lists:duplicate(8, -2),
                 [X || <<X:16/little-signed>> <= Got], signed_reading).

%%% ---------------------------------------------------------- consistency ---

%% The proposal requires that a choice be fixed within an environment. Calling
%% each instruction twice with the same operands has to give the same answer,
%% which is what makes the results above a property of the runtime rather than
%% of a particular run.
every_instruction_is_deterministic(_Config) ->
    {ok, Inst} = instantiate(all_relaxed_module()),
    A = lanes8(lists:seq(200, 215)),
    B = lanes8(lists:seq(1, 16)),
    C = lanes8(lists:duplicate(16, 16#5A)),
    lists:foreach(
      fun({Name, N}) ->
          Args = lists:sublist([A, B, C], N),
          {ok, [First]} = wasm:call(Inst, Name, Args),
          [?assertEqual({ok, [First]}, wasm:call(Inst, Name, Args))
           || _ <- lists:seq(1, 3)]
      end, instructions()),
    ok = wasm:destroy(Inst).

%%% ---------------------------------------------------------------- module ---

%% Every relaxed instruction, with its export name and operand count.
instructions() ->
    [{~"i8x16.relaxed_swizzle", 2},
     {~"i32x4.relaxed_trunc_f32x4_s", 1},
     {~"i32x4.relaxed_trunc_f32x4_u", 1},
     {~"i32x4.relaxed_trunc_f64x2_s_zero", 1},
     {~"i32x4.relaxed_trunc_f64x2_u_zero", 1},
     {~"f32x4.relaxed_madd", 3},
     {~"f32x4.relaxed_nmadd", 3},
     {~"f64x2.relaxed_madd", 3},
     {~"f64x2.relaxed_nmadd", 3},
     {~"i8x16.relaxed_laneselect", 3},
     {~"i16x8.relaxed_laneselect", 3},
     {~"i32x4.relaxed_laneselect", 3},
     {~"i64x2.relaxed_laneselect", 3},
     {~"f32x4.relaxed_min", 2},
     {~"f32x4.relaxed_max", 2},
     {~"f64x2.relaxed_min", 2},
     {~"f64x2.relaxed_max", 2},
     {~"i16x8.relaxed_q15mulr_s", 2},
     {~"i16x8.relaxed_dot_i8x16_i7x16_s", 2},
     {~"i32x4.relaxed_dot_i8x16_i7x16_add_s", 3}].

%% One function per instruction: push its operands, run it, return the vector.
all_relaxed_module() ->
    Ops = lists:zip(instructions(), lists:seq(256, 275)),
    Types = wasm_asm:type_section(
              [{[?V128], [?V128]},
               {[?V128, ?V128], [?V128]},
               {[?V128, ?V128, ?V128], [?V128]}]),
    Bodies = [body(N, Sub) || {{_, N}, Sub} <- Ops],
    wasm_asm:module(
      [Types,
       wasm_asm:func_section([N - 1 || {{_, N}, _} <- Ops]),
       wasm_asm:export_section(
         [{Name, 0, I} || {{{Name, _}, _}, I} <- lists:zip(Ops, lists:seq(0, 19))]),
       wasm_asm:code_section(Bodies)]).

body(N, Sub) ->
    Gets = << <<16#20, (I - 1)>> || I <- lists:seq(1, N) >>,
    <<Gets/binary, ?FD, (wasm_asm:uleb(Sub))/binary, 16#0B>>.

%%% --------------------------------------------------------------- helpers ---

instantiate(Bin) ->
    {ok, Mod} = wasm:load(Bin),
    wasm:instantiate(Mod, #{}).

lanes8(Bytes) -> list_to_binary(Bytes).

%% The same f32 in all four lanes, as its bit pattern.
f32v(F) ->
    Bits = wasm_num:f32_to_bits(wasm_num_float:round_to(32, F)),
    << <<Bits:32/little>> || _ <- lists:seq(1, 4) >>.
