-module(wasm_num).
-moduledoc """
Conversion between IEEE 754 bit patterns and the runtime float representation.

Read this when a float coming out of a module is not the shape you expected.
Erlang cannot hold NaN or Infinity in a float. Arithmetic that would produce
one raises `badarith`, and `<<F:64/float>>` does not even match the bit
patterns `7FF0...` or `7FF8...`. WebAssembly requires both, including NaN
payload propagation, so floats use a hybrid representation:
- finite values are Erlang floats, which is the fast and common case;
- `infinity` and `neg_infinity` are atoms;
- NaN is `{nan, Sign, Payload}`, keeping the payload bits that the
  specification's NaN propagation rules make observable.
Signed zero needs no special case: since OTP 27 `-0.0 =/= 0.0` and
`<<(-0.0):64/float>>` produces the correct sign bit, so Erlang models it
natively.

Arithmetic over this representation lives in `wasm_num_f32` and `wasm_num_f64`.
This module is only the boundary with bit patterns: constants in the binary
format, `reinterpret` instructions, and linear memory loads and stores.
""".

-include("wasm.hrl").

-export([f32_from_bits/1, f32_to_bits/1, f64_from_bits/1, f64_to_bits/1]).
-export([is_nan/1, is_infinite/1, is_finite/1]).
-export([f32_canonical_nan/0, f64_canonical_nan/0]).
-export([wrap_u32/1, wrap_u64/1, wrap_s32/1, wrap_s64/1,
         to_u32/1, to_u64/1]).

-define(F32_EXP_MASK,  16#7F800000).
-define(F32_MANT_MASK, 16#007FFFFF).
-define(F32_SIGN_MASK, 16#80000000).
-define(F64_EXP_MASK,  16#7FF0000000000000).
-define(F64_MANT_MASK, 16#000FFFFFFFFFFFFF).
-define(F64_SIGN_MASK, 16#8000000000000000).

%% Canonical NaN has the top mantissa bit set and all others clear.
-define(F32_CANON_PAYLOAD, 16#400000).
-define(F64_CANON_PAYLOAD, 16#8000000000000).

%%% ----------------------------------------------------------------- f32 ---

-doc """
A 32-bit IEEE 754 bit pattern as a runtime float.

Total: every one of the 2^32 patterns has an answer. An exponent of all ones
becomes `infinity`, `neg_infinity` or `{nan, Sign, Payload}`, because an Erlang
float cannot hold those. Everything else is an Erlang float.
""".
-spec f32_from_bits(non_neg_integer()) -> f32().
f32_from_bits(Bits) when Bits band ?F32_EXP_MASK =:= ?F32_EXP_MASK ->
    %% Exponent all ones: infinity or NaN, neither of which Erlang can hold.
    case Bits band ?F32_MANT_MASK of
        0 when Bits band ?F32_SIGN_MASK =:= 0 -> infinity;
        0 -> neg_infinity;
        Payload -> {nan, Bits bsr 31, Payload}
    end;
f32_from_bits(Bits) ->
    <<F:32/float>> = <<Bits:32>>,
    F.

-doc "The inverse of `f32_from_bits/1`. NaN payload and sign survive the round trip.".
-spec f32_to_bits(f32()) -> non_neg_integer().
f32_to_bits(F) when is_float(F) ->
    <<Bits:32>> = <<F:32/float>>,
    Bits;
f32_to_bits(infinity)         -> ?F32_EXP_MASK;
f32_to_bits(neg_infinity)     -> ?F32_SIGN_MASK bor ?F32_EXP_MASK;
f32_to_bits({nan, S, P})      -> (S bsl 31) bor ?F32_EXP_MASK bor P.

-doc "The NaN the specification requires an operation to produce when it makes one.".
-spec f32_canonical_nan() -> f32().
f32_canonical_nan() -> {nan, 0, ?F32_CANON_PAYLOAD}.

%%% ----------------------------------------------------------------- f64 ---

-doc "As `f32_from_bits/1`, at 64 bits.".
-spec f64_from_bits(non_neg_integer()) -> f64().
f64_from_bits(Bits) when Bits band ?F64_EXP_MASK =:= ?F64_EXP_MASK ->
    case Bits band ?F64_MANT_MASK of
        0 when Bits band ?F64_SIGN_MASK =:= 0 -> infinity;
        0 -> neg_infinity;
        Payload -> {nan, Bits bsr 63, Payload}
    end;
f64_from_bits(Bits) ->
    <<F:64/float>> = <<Bits:64>>,
    F.

-doc "As `f32_to_bits/1`, at 64 bits.".
-spec f64_to_bits(f64()) -> non_neg_integer().
f64_to_bits(F) when is_float(F) ->
    <<Bits:64>> = <<F:64/float>>,
    Bits;
f64_to_bits(infinity)     -> ?F64_EXP_MASK;
f64_to_bits(neg_infinity) -> ?F64_SIGN_MASK bor ?F64_EXP_MASK;
f64_to_bits({nan, S, P})  -> (S bsl 63) bor ?F64_EXP_MASK bor P.

-doc "As `f32_canonical_nan/0`, at 64 bits.".
-spec f64_canonical_nan() -> f64().
f64_canonical_nan() -> {nan, 0, ?F64_CANON_PAYLOAD}.

%%% ----------------------------------------------------------- predicates ---

-doc "Whether this is a NaN. Never true of an Erlang float, which cannot be one.".
-spec is_nan(f32() | f64()) -> boolean().
is_nan({nan, _, _}) -> true;
is_nan(_) -> false.

-doc "Whether this is either infinity.".
-spec is_infinite(f32() | f64()) -> boolean().
is_infinite(infinity) -> true;
is_infinite(neg_infinity) -> true;
is_infinite(_) -> false.

-doc "Whether this is an ordinary value, which is exactly when it is an Erlang float.".
-spec is_finite(f32() | f64()) -> boolean().
is_finite(F) -> is_float(F).

%%% ------------------------------------------------------------- integers ---
%%
%% Integers are held in signed two's-complement interpretation. Keeping them
%% signed means small and negative values stay immediate machine words; an
%% unsigned representation would make every negative i64 a heap bignum, and
%% bignum arithmetic measured 1.8x slower than immediate arithmetic.

-doc "Reduce to the unsigned 32-bit range.".
-spec wrap_u32(integer()) -> non_neg_integer().
wrap_u32(V) -> V band 16#FFFFFFFF.

-doc "Reduce to the unsigned 64-bit range.".
-spec wrap_u64(integer()) -> non_neg_integer().
wrap_u64(V) -> V band 16#FFFFFFFFFFFFFFFF.

-doc "Reduce to the signed 32-bit range, wrapping like two's complement.".
-spec wrap_s32(integer()) -> integer().
wrap_s32(V) ->
    case V band 16#FFFFFFFF of
        W when W >= 16#80000000 -> W - 16#100000000;
        W -> W
    end.

-doc "Reduce to the signed 64-bit range, wrapping like two's complement.".
-spec wrap_s64(integer()) -> integer().
wrap_s64(V) ->
    case V band 16#FFFFFFFFFFFFFFFF of
        W when W >= 16#8000000000000000 -> W - 16#10000000000000000;
        W -> W
    end.

-doc "Reinterpret a signed value as unsigned, for the `_u` operations.".
-spec to_u32(integer()) -> non_neg_integer().
to_u32(V) when V < 0 -> V + 16#100000000;
to_u32(V) -> V.

-doc "Reinterpret a signed value as unsigned, at 64 bits.".
-spec to_u64(integer()) -> non_neg_integer().
to_u64(V) when V < 0 -> V + 16#10000000000000000;
to_u64(V) -> V.
