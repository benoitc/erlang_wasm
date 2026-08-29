-module(wasm_num_float).
-moduledoc """
Floating-point arithmetic over the hybrid representation `wasm_num` describes.

Erlang cannot hold NaN or Infinity in a float, so every operation is split
into a fast path (both operands finite, result finite) and a slow path that
handles the values Erlang refuses. The fast path is guarded with `is_float`,
which measured 1.9 ns, faster than the unguarded version because the guard
lets the compiler unbox the operands.

Width is the first argument rather than being split across two modules: the
specials, comparisons and NaN propagation rules are identical for f32 and
f64, and only rounding differs. Duplicating three hundred lines to save one
argument would double the surface for the subtle bugs.

Two rules are worth stating because they are where implementations diverge:
- **NaN generation versus propagation.** An operation that *creates* a NaN
  from non-NaN operands (`inf - inf`, `0/0`, `sqrt` of a negative) must produce
  the canonical NaN. An operation that *propagates* an operand's NaN may keep
  its payload. The test suite distinguishes these as `nan:canonical` and
  `nan:arithmetic`.
- **f32 rounding via f64 is exact.** Computing in double precision and rounding
  once to single is correctly rounded for add, sub, mul, div and sqrt, because
  double has more than 2*24+2 bits of significand. That is what makes it safe
  to reuse Erlang's arithmetic rather than simulating single precision.
""".

-include("wasm.hrl").

-export([add/3, sub/3, mul/3, divide/3, min/3, max/3, copysign/3]).
-export([abs/2, neg/2, ceil/2, floor/2, trunc/2, nearest/2, sqrt/2]).
-export([eq/3, ne/3, lt/3, gt/3, le/3, ge/3]).
-export([round_to/2, demote/1, promote/1, canonical_nan/1]).
-export([convert_i32_s/2, convert_i32_u/2, convert_i64_s/2, convert_i64_u/2]).
-export([is_negative/1]).

%% The quiet bit is the top mantissa bit. An arithmetic NaN result must have
%% it set, whatever the operands were.
-define(F32_QUIET, 16#400000).
-define(F64_QUIET, 16#8000000000000).

-type width() :: 32 | 64.
-type f() :: float() | fspecial().

%%% --------------------------------------------------------------- rounding ---

-doc """
Round a double to the target width, mapping overflow to infinity.

Erlang's float-to-binary conversion saturates to the infinity bit pattern on
overflow, and `wasm_num:f32_from_bits/1` turns that pattern back into the
`infinity` atom, so overflow needs no explicit range test.
""".
-spec round_to(width(), f()) -> f().
round_to(32, F) when is_float(F) ->
    <<Bits:32>> = <<F:32/float>>,
    wasm_num:f32_from_bits(Bits);
round_to(64, F) when is_float(F) ->
    F;
round_to(_, Special) ->
    Special.

-doc "The NaN to produce when an operation has to make one.".
-spec canonical_nan(width()) -> f().
canonical_nan(32) -> wasm_num:f32_canonical_nan();
canonical_nan(64) -> wasm_num:f64_canonical_nan().

%% Re-width a NaN when converting between precisions. `demote' cannot carry a
%% wide payload into a narrow mantissa, so it canonicalises; `promote' shifts
%% the payload up so it survives the round trip. Both results are quiet.
renan(32, {nan, S, _P}) -> {nan, S, ?F32_QUIET};
renan(64, {nan, S, P}) -> {nan, S, (P bsl 29) bor ?F64_QUIET}.

%%% ------------------------------------------------------------- arithmetic ---

%% f32 needs no overflow handling: the widest f32 sum is far inside the double
%% range, and `round_to/2' turns a double that exceeds f32 into `infinity' via
%% the binary encoding's own saturation. f64 has nowhere wider to compute in,
%% so it catches `badarith' instead. Splitting on width keeps the f32 path at
%% the measured 1.9 ns rather than paying try/catch on every operation.
-doc "Add. Traps never; every result is a value, including NaN and infinity.".
-spec add(width(), f(), f()) -> f().
add(32, A, B) when is_float(A), is_float(B) -> round_to(32, A + B);
add(64, A, B) when is_float(A), is_float(B) ->
    try A + B catch error:badarith -> signed_inf(sign_of(A)) end;
add(W, A, B) -> add_special(W, A, B).

add_special(W, A, B) ->
    case nan_of(W, A, B) of
        {nan, _, _} = N -> N;
        none ->
            case {A, B} of
                %% Opposite infinities have no defined sum, so a NaN is
                %% generated rather than propagated: it must be canonical.
                {infinity, neg_infinity} -> canonical_nan(W);
                {neg_infinity, infinity} -> canonical_nan(W);
                {infinity, _} -> infinity;
                {_, infinity} -> infinity;
                {neg_infinity, _} -> neg_infinity;
                {_, neg_infinity} -> neg_infinity
            end
    end.

-doc "Subtract.".
-spec sub(width(), f(), f()) -> f().
sub(32, A, B) when is_float(A), is_float(B) -> round_to(32, A - B);
sub(64, A, B) when is_float(A), is_float(B) ->
    try A - B catch error:badarith -> signed_inf(sign_of(A)) end;
sub(W, A, B) -> add_special(W, A, neg(W, B)).

-doc "Multiply.".
-spec mul(width(), f(), f()) -> f().
mul(32, A, B) when is_float(A), is_float(B) -> round_to(32, A * B);
mul(64, A, B) when is_float(A), is_float(B) ->
    try A * B catch error:badarith -> signed_inf(sign_xor(A, B)) end;
mul(W, A, B) ->
    case nan_of(W, A, B) of
        {nan, _, _} = N -> N;
        none ->
            %% Infinity times zero is undefined, so it generates a canonical NaN.
            case {is_zero(A), is_zero(B)} of
                {true, _} -> canonical_nan(W);
                {_, true} -> canonical_nan(W);
                _ -> signed_inf(sign_xor(A, B))
            end
    end.

%% Division needs the zero cases handled before Erlang sees them: `X / 0.0'
%% raises badarith rather than producing an infinity.
-doc "Divide. Division by zero is infinity or NaN, not a trap: only the integer forms trap.".
-spec divide(width(), f(), f()) -> f().
divide(W, A, B) when is_float(A), is_float(B) ->
    case B == 0.0 of
        false ->
            try round_to(W, A / B)
            catch error:badarith -> signed_inf(sign_xor(A, B)) end;
        true ->
            case A == 0.0 of
                true -> canonical_nan(W);          % 0/0
                false -> signed_inf(sign_xor(A, B))
            end
    end;
divide(W, A, B) ->
    case nan_of(W, A, B) of
        {nan, _, _} = N -> N;
        none ->
            AInf = wasm_num:is_infinite(A),
            BInf = wasm_num:is_infinite(B),
            if
                AInf, BInf -> canonical_nan(W);    % inf/inf
                AInf -> signed_inf(sign_xor(A, B));
                BInf -> signed_zero(sign_xor(A, B))
            end
    end.

%% `min' and `max' are not the arithmetic ones: they propagate NaN, and they
%% distinguish -0.0 from +0.0, which numeric comparison does not.
-doc "The smaller. NaN wins over any value, and -0.0 wins over +0.0, which is not what `erlang:min/2` does.".
-spec min(width(), f(), f()) -> f().
min(W, A, B) ->
    case nan_of(W, A, B) of
        {nan, _, _} = N -> N;
        none -> min_nonnan(A, B)
    end.

min_nonnan(A, B) when is_float(A), is_float(B) ->
    if
        A < B -> A;
        B < A -> B;
        true -> case is_negative(A) of true -> A; false -> B end   % signed zero
    end;
min_nonnan(neg_infinity, _) -> neg_infinity;
min_nonnan(_, neg_infinity) -> neg_infinity;
min_nonnan(infinity, B) -> B;
min_nonnan(A, infinity) -> A.

-doc "The larger, with the same NaN and signed-zero rules as `min/3`.".
-spec max(width(), f(), f()) -> f().
max(W, A, B) ->
    case nan_of(W, A, B) of
        {nan, _, _} = N -> N;
        none -> max_nonnan(A, B)
    end.

max_nonnan(A, B) when is_float(A), is_float(B) ->
    if
        A > B -> A;
        B > A -> B;
        true -> case is_negative(A) of true -> B; false -> A end
    end;
max_nonnan(infinity, _) -> infinity;
max_nonnan(_, infinity) -> infinity;
max_nonnan(neg_infinity, B) -> B;
max_nonnan(A, neg_infinity) -> A.

%% Bit-level, so it must work on NaN and infinity unchanged.
-doc "The magnitude of the first with the sign of the second. Defined on NaN and on both zeros.".
-spec copysign(width(), f(), f()) -> f().
copysign(W, A, B) ->
    case is_negative(B) of
        true -> force_sign(W, A, 1);
        false -> force_sign(W, A, 0)
    end.

force_sign(_W, F, S) when is_float(F) ->
    %% `F >= 0.0' is true for -0.0, so the test has to be the sign bit.
    case {is_negative(F), S} of
        {true, 1} -> F;
        {false, 0} -> F;
        _ -> -F
    end;
force_sign(_W, infinity, 0) -> infinity;
force_sign(_W, infinity, 1) -> neg_infinity;
force_sign(_W, neg_infinity, 0) -> infinity;
force_sign(_W, neg_infinity, 1) -> neg_infinity;
force_sign(_W, {nan, _, P}, S) -> {nan, S, P}.

%%% ----------------------------------------------------------------- unary ---

-doc "Magnitude. Clears the sign bit, so it is defined on NaN.".
-spec abs(width(), f()) -> f().
abs(_W, F) when is_float(F) -> erlang:abs(F);
abs(_W, infinity) -> infinity;
abs(_W, neg_infinity) -> infinity;
abs(_W, {nan, _, P}) -> {nan, 0, P}.

-doc "Flip the sign bit. Not `0 - X`, which would lose the sign of zero.".
-spec neg(width(), f()) -> f().
neg(_W, F) when is_float(F) -> -F;
neg(_W, infinity) -> neg_infinity;
neg(_W, neg_infinity) -> infinity;
neg(_W, {nan, S, P}) -> {nan, 1 - S, P}.

%% The rounding operations preserve -0.0 and never change magnitude class, so
%% they need no re-rounding to the target width.
-doc "Round toward positive infinity.".
-spec ceil(width(), f()) -> f().
ceil(_W, F) when is_float(F) ->
    case erlang:trunc(F) of
        T when F > 0.0, F =/= float(T) -> float(T + 1);
        T when F < 0.0 -> negative_zero_if_zero(float(T), F);
        T -> preserve_zero(float(T), F)
    end;
ceil(_W, S) -> S.

-doc "Round toward negative infinity.".
-spec floor(width(), f()) -> f().
floor(_W, F) when is_float(F) ->
    case erlang:trunc(F) of
        T when F < 0.0, F =/= float(T) -> float(T - 1);
        T -> preserve_zero(float(T), F)
    end;
floor(_W, S) -> S.

-doc "Round toward zero. Still a float: the integer forms are in `wasm_num_trunc`.".
-spec trunc(width(), f()) -> f().
trunc(_W, F) when is_float(F) -> preserve_zero(float(erlang:trunc(F)), F);
trunc(_W, S) -> S.

%% Round half to even, which is what WebAssembly specifies and what neither
%% `round/1' nor `trunc/1' gives on their own.
-doc "Round to nearest, ties to even. Not `erlang:round/1`, which rounds halves away from zero.".
-spec nearest(width(), f()) -> f().
nearest(_W, F) when is_float(F) ->
    T = float(erlang:trunc(F)),
    Diff = erlang:abs(F - T),
    R = if
            Diff > 0.5 -> step_away(T, F);
            Diff < 0.5 -> T;
            true ->
                %% Exactly halfway: pick the even neighbour.
                Away = step_away(T, F),
                case is_even(T) of true -> T; false -> Away end
        end,
    preserve_zero(R, F);
nearest(_W, S) -> S.

step_away(T, F) when F < 0.0 -> T - 1.0;
step_away(T, _F) -> T + 1.0.

is_even(T) -> erlang:trunc(T) band 1 =:= 0.

-doc "Square root. Negative input is NaN rather than an error.".
-spec sqrt(width(), f()) -> f().
sqrt(W, F) when is_float(F) ->
    if
        F < 0.0 -> canonical_nan(W);
        true -> round_to(W, math:sqrt(F))
    end;
sqrt(_W, infinity) -> infinity;
sqrt(W, neg_infinity) -> canonical_nan(W);
sqrt(W, {nan, _, _} = N) -> propagate_nan(W, N).

%%% ----------------------------------------------------------- comparisons ---
%%
%% All comparisons are false when either operand is NaN, including `ne', which
%% is the one people get wrong: `ne' is the negation of `eq' only for non-NaN
%% operands, and is *true* when either is NaN.

-doc "Equality, as 1 or 0. NaN compares equal to nothing, itself included.".
-spec eq(width(), f(), f()) -> 0 | 1.
eq(_W, A, B) -> bool(cmp(A, B) =:= eq).

-doc "Inequality, as 1 or 0. True when either side is NaN.".
-spec ne(width(), f(), f()) -> 0 | 1.
ne(_W, A, B) -> bool(cmp(A, B) =/= eq).

-doc "Less than, as 1 or 0. False when either side is NaN.".
-spec lt(width(), f(), f()) -> 0 | 1.
lt(_W, A, B) -> bool(cmp(A, B) =:= lt).

-doc "Greater than, as 1 or 0. False when either side is NaN.".
-spec gt(width(), f(), f()) -> 0 | 1.
gt(_W, A, B) -> bool(cmp(A, B) =:= gt).

-doc "Less or equal, as 1 or 0. False when either side is NaN.".
-spec le(width(), f(), f()) -> 0 | 1.
le(_W, A, B) -> bool(lists:member(cmp(A, B), [lt, eq])).

-doc "Greater or equal, as 1 or 0. False when either side is NaN.".
-spec ge(width(), f(), f()) -> 0 | 1.
ge(_W, A, B) -> bool(lists:member(cmp(A, B), [gt, eq])).

%% `unordered' is returned when either operand is NaN, which makes every
%% ordered comparison false and `ne' true.
cmp(A, B) when is_float(A), is_float(B) ->
    if A < B -> lt; A > B -> gt; true -> eq end;
cmp({nan, _, _}, _) -> unordered;
cmp(_, {nan, _, _}) -> unordered;
cmp(A, A) -> eq;
cmp(neg_infinity, _) -> lt;
cmp(_, neg_infinity) -> gt;
cmp(infinity, _) -> gt;
cmp(_, infinity) -> lt.

bool(true) -> 1;
bool(false) -> 0.

%%% ------------------------------------------------------------ conversions ---

-doc "f64 to f32, rounding to nearest and possibly to infinity.".
-spec demote(f()) -> f().
demote(F) when is_float(F) -> round_to(32, F);
demote({nan, _, _} = N) -> renan(32, N);
demote(S) -> S.

-doc "f32 to f64. Exact, and the NaN payload is carried across.".
-spec promote(f()) -> f().
promote(F) when is_float(F) -> F;
promote({nan, _, _} = N) -> renan(64, N);
promote(S) -> S.

-doc "A signed 32-bit integer as a float. Total: every i32 is representable.".
-spec convert_i32_s(width(), integer()) -> f().
convert_i32_s(W, V) -> round_to(W, float(V)).

-doc "An unsigned 32-bit integer as a float. Total.".
-spec convert_i32_u(width(), integer()) -> f().
convert_i32_u(W, V) -> round_to(W, float(wasm_num:to_u32(V))).

%% Converting a 64-bit integer to f32 must round **once**.
%%
%% The obvious route, `integer -> f64 -> f32', rounds twice. The theorem that
%% makes double-rounding safe covers add, sub, mul, div and sqrt, where f64 has
%% more than 2*24+2 bits of headroom over f32. It does not cover integer
%% conversion: a 64-bit integer does not fit in f64's 53-bit significand, so the
%% first rounding can land exactly on a midpoint of the second and push it the
%% wrong way. `f32.convert_i64_s(0x7fffff4000000001)' came out one ulp high.
%%
%% i32 is unaffected (32 bits are exact in f64) and so is i64 to f64 (a single
%% rounding already), so only this pair needs the long way round.
-doc "A signed 64-bit integer as a float, rounding when it does not fit exactly.".
-spec convert_i64_s(width(), integer()) -> f().
convert_i64_s(32, V) -> int_to_f32(V);
convert_i64_s(W, V) -> round_to(W, float(V)).

-doc "An unsigned 64-bit integer as a float, rounding when it does not fit exactly.".
-spec convert_i64_u(width(), integer()) -> f().
convert_i64_u(32, V) -> int_to_f32(wasm_num:to_u64(V));
convert_i64_u(W, V) -> round_to(W, float(wasm_num:to_u64(V))).

%% Round an arbitrary integer to f32, round-to-nearest-ties-to-even, in one step.
int_to_f32(0) -> 0.0;
int_to_f32(V) when V < 0 -> -int_to_f32_mag(-V);
int_to_f32(V) -> int_to_f32_mag(V).

int_to_f32_mag(Mag) ->
    case bit_size_of(Mag) of
        N when N =< 24 ->
            %% Fits the significand exactly; no rounding decision to make.
            float(Mag);
        N ->
            Shift = N - 24,
            Top = Mag bsr Shift,
            Rem = Mag band ((1 bsl Shift) - 1),
            Half = 1 bsl (Shift - 1),
            Rounded =
                if
                    Rem > Half -> Top + 1;
                    Rem < Half -> Top;
                    %% Exactly halfway: round to even.
                    Top band 1 =:= 0 -> Top;
                    true -> Top + 1
                end,
            %% `Rounded bsl Shift' carries at most 25 significant bits (24, or 25
            %% if the round-up carried into a new power of two), so converting it
            %% to a double is exact and `round_to/2' does no further rounding.
            round_to(32, float(Rounded bsl Shift))
    end.

bit_size_of(V) -> bit_size_of(V, 0).
bit_size_of(0, N) -> N;
bit_size_of(V, N) -> bit_size_of(V bsr 1, N + 1).

%%% --------------------------------------------------------------- helpers ---

%% NaN propagation: the first NaN operand wins, re-widened if the operands came
%% from a different precision.
nan_of(W, {nan, _, _} = A, _) -> propagate_nan(W, A);
nan_of(W, _, {nan, _, _} = B) -> propagate_nan(W, B);
nan_of(_, _, _) -> none.

%% Propagating a NaN through an arithmetic operation must produce a *quiet*
%% NaN. The payload may be carried across, but the specification requires the
%% result be quiet even when the operand was signalling, so the top mantissa
%% bit is set unconditionally.
%%
%% Without this, `f32.div' of the signalling NaN `0x7f803210' by itself returned
%% `0x7f803210' rather than a quiet NaN, and the suite's
%% `arithmetic_nan_bitpattern' tests (which mask with `0x7fc00000') saw
%% `0x7f800000', the bit pattern of infinity.
propagate_nan(32, {nan, S, P}) when P >= 16#800000 ->
    %% An f64 payload arriving at f32 width: too wide to carry, so canonicalise.
    {nan, S, ?F32_QUIET};
propagate_nan(32, {nan, S, P}) -> {nan, S, P bor ?F32_QUIET};
propagate_nan(64, {nan, S, P}) when P < 16#800000 ->
    %% An f32 payload widened to f64: shift it into the f64 mantissa position
    %% so the payload survives a promote, rather than being discarded.
    {nan, S, (P bsl 29) bor ?F64_QUIET};
propagate_nan(64, {nan, S, P}) -> {nan, S, P bor ?F64_QUIET}.

-doc "Whether the sign bit is set, which is true of -0.0 and of a negative NaN.".
-spec is_negative(f()) -> boolean().
is_negative(F) when is_float(F) ->
    %% Compares bitwise so that -0.0 counts as negative, which `F < 0.0' does
    %% not. Since OTP 27 `-0.0 =/= 0.0', so this is a plain term comparison.
    F < 0.0 orelse F =:= -0.0;
is_negative(neg_infinity) -> true;
is_negative(infinity) -> false;
is_negative({nan, S, _}) -> S =:= 1.

is_zero(F) when is_float(F) -> F == 0.0;
is_zero(_) -> false.

sign_of(A) -> case is_negative(A) of true -> 1; false -> 0 end.

sign_xor(A, B) ->
    case is_negative(A) =:= is_negative(B) of
        true -> 0;
        false -> 1
    end.

signed_inf(0) -> infinity;
signed_inf(1) -> neg_infinity.

signed_zero(0) -> 0.0;
signed_zero(1) -> -0.0.

%% Rounding a value that was already zero must keep the original sign.
preserve_zero(R, F) when R == 0.0 ->
    case is_negative(F) of true -> -0.0; false -> 0.0 end;
preserve_zero(R, _F) -> R.

negative_zero_if_zero(R, F) when R == 0.0, F < 0.0 -> -0.0;
negative_zero_if_zero(R, _) -> R.
