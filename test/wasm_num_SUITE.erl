%% @doc Numeric edge cases, each naming the rule it enforces.
%%
%% These duplicate coverage the specification suite already provides. That is
%% deliberate: the spec fixtures say *what* broke, not *why* the code is shaped
%% the way it is. Each case here records a rule that was got wrong once, so the
%% reasoning survives even if the fixtures are regenerated, moved, or skipped.
-module(wasm_num_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [nan_survives_a_round_trip_through_memory,
     arithmetic_nan_results_are_quiet,
     generated_nan_is_canonical,
     nan_payload_is_preserved_when_propagated,
     i64_to_f32_rounds_once,
     i64_to_f32_ties_to_even,
     signed_zero_is_distinguishable].

f32(Bits) -> wasm_num:f32_from_bits(Bits).
bits(F) -> wasm_num:f32_to_bits(F).

%%% ------------------------------------------------------------ defect one ---

%% Loads and stores must be bit-preserving, so a NaN written to linear memory
%% and read back is the same NaN.
%%
%% This failed because `wasm_exec:mem_op/4' computed the effective address from
%% the top of the stack before deciding load versus store. For a store the top
%% of stack is the *value*, and `wasm_num:to_u32/1' passes a non-integer
%% through unchanged, so storing a NaN evaluated `{nan,0,P} + Offset' and raised
%% `badarith' from inside the interpreter.
nan_survives_a_round_trip_through_memory(_Config) ->
    {ok, Mem} = wasm_memory:new(1, 1),
    Payload = 16#200000,
    Bits = bits({nan, 0, Payload}),
    ok = wasm_memory:store(Mem, 0, 4, Bits),
    ?assertEqual(Bits, wasm_memory:load(Mem, 0, 4)),
    ?assertEqual({nan, 0, Payload}, f32(wasm_memory:load(Mem, 0, 4))),
    %% Infinity too: also a non-integer at the Erlang level.
    ok = wasm_memory:store(Mem, 8, 4, bits(infinity)),
    ?assertEqual(infinity, f32(wasm_memory:load(Mem, 8, 4))),
    wasm_memory:free(Mem).

%%% ------------------------------------------------------------ defect two ---

%% An arithmetic operation must produce a *quiet* NaN even when its operand was
%% signalling. Propagating the operand unchanged left the quiet bit clear, and
%% the suite's `arithmetic_nan_bitpattern` tests, which mask with 0x7fc00000,
%% then saw 0x7f800000: the bit pattern of infinity.
arithmetic_nan_results_are_quiet(_Config) ->
    Signalling = f32(16#7f803210),
    Ops = [{~"div", wasm_num_float:divide(32, Signalling, Signalling)},
           {~"add", wasm_num_float:add(32, Signalling, 1.0)},
           {~"mul", wasm_num_float:mul(32, Signalling, 2.0)},
           {~"sub", wasm_num_float:sub(32, 1.0, Signalling)},
           {~"min", wasm_num_float:min(32, Signalling, 1.0)},
           {~"sqrt", wasm_num_float:sqrt(32, Signalling)}],
    [?assertEqual({Name, 16#7fc00000}, {Name, bits(R) band 16#7fc00000})
     || {Name, R} <- Ops].

%% A NaN *generated* from non-NaN operands must be the canonical one, which is
%% a different rule from propagation and is why the two paths are separate.
generated_nan_is_canonical(_Config) ->
    ?assertEqual(16#7fc00000, bits(wasm_num_float:divide(32, 0.0, 0.0))),
    ?assertEqual(16#7fc00000, bits(wasm_num_float:sub(32, infinity, infinity))),
    ?assertEqual(16#7fc00000, bits(wasm_num_float:mul(32, infinity, 0.0))),
    ?assertEqual(16#7fc00000, bits(wasm_num_float:sqrt(32, -1.0))).

%% Quieting must not destroy the payload: only the quiet bit is forced.
nan_payload_is_preserved_when_propagated(_Config) ->
    Signalling = f32(16#7f803210),
    ?assertEqual(16#7fc03210, bits(wasm_num_float:divide(32, Signalling, Signalling))).

%%% ---------------------------------------------------------- defect three ---

%% Integer to f32 must round once. Going via f64 rounds twice, and the theorem
%% that makes double rounding safe for add/sub/mul/div/sqrt does not cover
%% integer conversion, because 64 bits do not fit f64's 53-bit significand.
%%
%% Vectors taken from conversions.wast.
i64_to_f32_rounds_once(_Config) ->
    Cases = [{16#7fffff4000000001, 16#5EFFFFFF},
             {16#0020000020000001, 16#5A000001},
             {16#7fffffffffffffff, 16#5F000000}],
    [?assertEqual({In, Want}, {In, bits(wasm_num_float:convert_i64_s(32, In))})
     || {In, Want} <- Cases],
    Neg = wasm_num:wrap_s64(16#8000004000000001),
    ?assertEqual(16#DEFFFFFF, bits(wasm_num_float:convert_i64_s(32, Neg))),
    %% Values inside the significand are exact and must not be perturbed.
    [?assertEqual(bits(float(N)), bits(wasm_num_float:convert_i64_s(32, N)))
     || N <- [0, 1, 12345, 16777215]].

%% Halfway cases round to even, not away from zero.
i64_to_f32_ties_to_even(_Config) ->
    %% 2^25 + 1 lands exactly halfway between two f32 values; the even
    %% neighbour is 2^25 itself.
    ?assertEqual(bits(float(1 bsl 25)),
                 bits(wasm_num_float:convert_i64_s(32, (1 bsl 25) + 1))),
    %% 2^25 + 3 is halfway too, but here the odd neighbour rounds up.
    ?assertEqual(bits(float((1 bsl 25) + 4)),
                 bits(wasm_num_float:convert_i64_s(32, (1 bsl 25) + 3))).

%%% ----------------------------------------------------------------- misc ---

%% Erlang models signed zero natively since OTP 27, so `copysign` and `min`
%% must not conflate the two.
signed_zero_is_distinguishable(_Config) ->
    ?assertEqual(16#80000000, bits(wasm_num_float:copysign(32, 0.0, -1.0))),
    ?assertEqual(16#00000000, bits(wasm_num_float:copysign(32, -0.0, 1.0))),
    ?assertEqual(16#80000000, bits(wasm_num_float:min(32, 0.0, -0.0))),
    ?assertEqual(16#00000000, bits(wasm_num_float:max(32, 0.0, -0.0))).
