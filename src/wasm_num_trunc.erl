-module(wasm_num_trunc).
-moduledoc """
Float to integer truncation, both families. Read this if a conversion traps
where you expected a clamp, or the other way round.

The two families differ only in what they do when the value does not fit:

- `i32.trunc_f32_s` and friends **trap** on NaN and on out-of-range values.
- `i32.trunc_sat_f32_s` and friends **saturate**: NaN becomes 0, and
  out-of-range values clamp to the nearest representable bound.

The range test is the subtle part. It must be done against the *exact* real
bound, not the rounded one: `f32` cannot represent 2^31-1, so testing
`V =< 2147483647.0` would wrongly accept 2147483648.0, which rounds to the
same float. The correct test is strict against the next power of two, which
is exactly representable. Truncation happens first, so the comparison is on
the already-truncated value.
""".

-include("wasm.hrl").

-export([apply/2]).

-define(I32_MIN, -2147483648).
-define(I32_MAX, 2147483647).
-define(I64_MIN, -9223372036854775808).
-define(I64_MAX, 9223372036854775807).
-define(U32_MAX, 4294967295).
-define(U64_MAX, 18446744073709551615).

-spec apply(atom(), float() | fspecial()) -> integer().
apply(i32_trunc_f32_s, V) -> trap_trunc(V, ?I32_MIN, ?I32_MAX);
apply(i32_trunc_f64_s, V) -> trap_trunc(V, ?I32_MIN, ?I32_MAX);
apply(i64_trunc_f32_s, V) -> trap_trunc(V, ?I64_MIN, ?I64_MAX);
apply(i64_trunc_f64_s, V) -> trap_trunc(V, ?I64_MIN, ?I64_MAX);
apply(i32_trunc_f32_u, V) -> wasm_num:wrap_s32(trap_trunc(V, 0, ?U32_MAX));
apply(i32_trunc_f64_u, V) -> wasm_num:wrap_s32(trap_trunc(V, 0, ?U32_MAX));
apply(i64_trunc_f32_u, V) -> wasm_num:wrap_s64(trap_trunc(V, 0, ?U64_MAX));
apply(i64_trunc_f64_u, V) -> wasm_num:wrap_s64(trap_trunc(V, 0, ?U64_MAX));

apply(i32_trunc_sat_f32_s, V) -> sat_trunc(V, ?I32_MIN, ?I32_MAX);
apply(i32_trunc_sat_f64_s, V) -> sat_trunc(V, ?I32_MIN, ?I32_MAX);
apply(i64_trunc_sat_f32_s, V) -> sat_trunc(V, ?I64_MIN, ?I64_MAX);
apply(i64_trunc_sat_f64_s, V) -> sat_trunc(V, ?I64_MIN, ?I64_MAX);
apply(i32_trunc_sat_f32_u, V) -> wasm_num:wrap_s32(sat_trunc(V, 0, ?U32_MAX));
apply(i32_trunc_sat_f64_u, V) -> wasm_num:wrap_s32(sat_trunc(V, 0, ?U32_MAX));
apply(i64_trunc_sat_f32_u, V) -> wasm_num:wrap_s64(sat_trunc(V, 0, ?U64_MAX));
apply(i64_trunc_sat_f64_u, V) -> wasm_num:wrap_s64(sat_trunc(V, 0, ?U64_MAX));

apply(Op, _V) ->
    wasm_error:trap({host_error, {unimplemented, Op}}, #{op => Op}).

%%% --------------------------------------------------------------- trapping ---

trap_trunc({nan, _, _}, _Lo, _Hi) ->
    wasm_error:trap(invalid_conversion_to_integer);
trap_trunc(infinity, _Lo, _Hi) ->
    wasm_error:trap(integer_overflow);
trap_trunc(neg_infinity, _Lo, _Hi) ->
    wasm_error:trap(integer_overflow);
trap_trunc(F, Lo, Hi) when is_float(F) ->
    %% Truncate first, then range check. Erlang integers are arbitrary
    %% precision, so the truncated value is exact and the comparison against
    %% the bound cannot itself round.
    T = erlang:trunc(F),
    case T >= Lo andalso T =< Hi of
        true -> T;
        false -> wasm_error:trap(integer_overflow, #{value => F})
    end.

%%% ------------------------------------------------------------- saturating ---

sat_trunc({nan, _, _}, _Lo, _Hi) -> 0;
sat_trunc(infinity, _Lo, Hi) -> Hi;
sat_trunc(neg_infinity, Lo, _Hi) -> Lo;
sat_trunc(F, Lo, Hi) when is_float(F) ->
    T = erlang:trunc(F),
    if
        T < Lo -> Lo;
        T > Hi -> Hi;
        true -> T
    end.
