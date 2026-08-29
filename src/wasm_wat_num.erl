-module(wasm_wat_num).
-moduledoc """
Numeric literals of the text format. Read it when a literal round-trips to bits
you did not expect.

The binary format has no literals: a constant is already bits. The text format
has to turn `0x1.921fb6p+1`, `-nan:0x200000` and `1_000` into the same bits,
and the interesting cases are the ones a naive `list_to_float` gets wrong.

**Erlang cannot hold the answers.** `nan` and `inf` are not floats here, so a
literal is converted to a *bit pattern* and handed to `wasm_num`, the same
hybrid representation the interpreter uses. Parsing to an Erlang float first
would lose the payload of `nan:0x200000` and raise on `inf` outright.

**Every literal is rounded exactly once.** A literal becomes an exact rational
and is rounded straight to the target width. Rounding to an Erlang double on
the way rounds twice, and the specification's float suites are written to catch
precisely that: `0x1.fffffefffffff8p127` is the largest finite `f32` and
becomes infinity if a double sees it first.

**Underscores separate digits and nothing else.** `1_000` is a thousand;
`_1`, `1_` and `0x_ff` are malformed. Stripping them before parsing would
accept all three.
""".

-export([integer/2, float_bits/2]).

-doc """
An integer literal, checked against the width and signedness it is used at.

`u32` admits `0` to `2^32-1`; `s32` admits `-2^31` to `2^31-1`; `i32` admits
either, because a constant may be written as a signed or an unsigned pattern
and means the same bits. The answer is always the signed interpretation, which
is how the runtime holds integers.
""".
-spec integer(binary(), u32 | u64 | s32 | s64 | i32 | i64) ->
          {ok, integer()} | error.
integer(Bin, Kind) ->
    case digits(Bin) of
        {ok, Sign, Value} -> range(Sign * Value, Sign, Kind);
        error -> error
    end.

%% A leading sign is only permitted where a signed value is, and `+` on an
%% unsigned literal is accepted because the specification's `uN` allows it.
digits(<<$-, R/binary>>) -> unsigned(R, -1);
digits(<<$+, R/binary>>) -> unsigned(R, 1);
digits(Bin) -> unsigned(Bin, 1).

unsigned(<<"0x", R/binary>>, Sign) -> radix(R, 16, Sign);
unsigned(Bin, Sign) -> radix(Bin, 10, Sign).

radix(Bin, Base, Sign) ->
    case separated(Bin, Base) of
        {ok, Digits} -> {ok, Sign, binary_to_integer(Digits, Base)};
        error -> error
    end.

%% An underscore has to sit between two digits, so the string may not start or
%% end with one and may not contain two in a row.
separated(<<>>, _Base) -> error;
separated(Bin, Base) -> separated(Bin, Base, <<>>, false).

separated(<<>>, _Base, Acc, LastWasDigit) ->
    case LastWasDigit of
        true -> {ok, Acc};
        false -> error
    end;
separated(<<$_, R/binary>>, Base, Acc, true) ->
    separated(R, Base, Acc, false);
separated(<<$_, _/binary>>, _Base, _Acc, false) ->
    error;
separated(<<C, R/binary>>, Base, Acc, _) ->
    case digit_value(C) of
        V when is_integer(V), V < Base -> separated(R, Base, <<Acc/binary, C>>, true);
        _ -> error
    end.

digit_value(C) when C >= $0, C =< $9 -> C - $0;
digit_value(C) when C >= $a, C =< $f -> C - $a + 10;
digit_value(C) when C >= $A, C =< $F -> C - $A + 10;
digit_value(_) -> false.

range(V, _Sign, u32) when V >= 0, V < 16#100000000 -> {ok, wasm_num:wrap_s32(V)};
range(V, _Sign, u64) when V >= 0, V < 16#10000000000000000 -> {ok, wasm_num:wrap_s64(V)};
range(V, _Sign, s32) when V >= -16#80000000, V < 16#80000000 -> {ok, V};
range(V, _Sign, s64) when V >= -16#8000000000000000, V < 16#8000000000000000 ->
    {ok, V};
%% A constant accepts either reading of the same 32 or 64 bits.
range(V, _Sign, i32) when V >= -16#80000000, V < 16#100000000 ->
    {ok, wasm_num:wrap_s32(V band 16#FFFFFFFF)};
range(V, _Sign, i64) when V >= -16#8000000000000000, V < 16#10000000000000000 ->
    {ok, wasm_num:wrap_s64(V band 16#FFFFFFFFFFFFFFFF)};
range(_, _, _) -> error.

-doc """
A floating point literal, as the bit pattern of an `f32` or an `f64`.

Answers bits rather than a number because three of the forms have no Erlang
value: `inf`, `nan`, and `nan:0x...` with a chosen payload.
""".
-spec float_bits(binary(), 32 | 64) -> {ok, non_neg_integer()} | error.
float_bits(Bin, Width) ->
    case Bin of
        <<$-, R/binary>> -> signed_float(R, Width, 1);
        <<$+, R/binary>> -> signed_float(R, Width, 0);
        _ -> signed_float(Bin, Width, 0)
    end.

signed_float(<<"inf">>, Width, Sign) ->
    {ok, assemble(Sign, exp_max(Width), 0, Width)};
signed_float(<<"nan">>, Width, Sign) ->
    %% A bare `nan` is the canonical one: the top mantissa bit and nothing else.
    {ok, assemble(Sign, exp_max(Width), canonical_payload(Width), Width)};
signed_float(<<"nan:0x", R/binary>>, Width, Sign) ->
    case separated(R, 16) of
        {ok, Digits} ->
            Payload = binary_to_integer(Digits, 16),
            %% A payload of zero would be infinity, and one that does not fit
            %% would be a different number. Neither is this literal.
            case Payload > 0 andalso Payload =< mantissa_max(Width) of
                true -> {ok, assemble(Sign, exp_max(Width), Payload, Width)};
                false -> error
            end;
        error -> error
    end;
signed_float(<<"0x", R/binary>>, Width, Sign) ->
    hex_float(R, Width, Sign);
signed_float(Bin, Width, Sign) ->
    dec_float(Bin, Width, Sign).

%%% ----------------------------------------------------------- hexadecimal ---

%% Read as an exact rational: an integer mantissa and a power of two. Nothing
%% is rounded until the very end, where `wasm_num_float:round_to/2` does it once
%% at the target width.
hex_float(Bin, Width, Sign) ->
    {Whole, R1} = hex_digits(Bin),
    {Frac, R2} = case R1 of
                     <<$., F/binary>> -> hex_digits(F);
                     _ -> {<<>>, R1}
                 end,
    case {Whole, Frac} of
        {<<>>, <<>>} -> error;
        _ ->
            {Exp, R3} = case R2 of
                            <<$p, E/binary>> -> exponent(E);
                            <<$P, E/binary>> -> exponent(E);
                            _ -> {0, R2}
                        end,
            case {Exp, R3} of
                {error, _} -> error;
                {_, <<>>} -> from_parts(Whole, Frac, 16, Exp, Width, Sign);
                _ -> error
            end
    end.

hex_digits(Bin) -> separated_prefix(Bin, 16).

%%% --------------------------------------------------------------- decimal ---

dec_float(Bin, Width, Sign) ->
    {Whole, R1} = separated_prefix(Bin, 10),
    {Frac, R2} = case R1 of
                     <<$., F/binary>> -> separated_prefix(F, 10);
                     _ -> {<<>>, R1}
                 end,
    case {Whole, Frac} of
        {<<>>, <<>>} -> error;
        _ ->
            {Exp, R3} = case R2 of
                            <<$e, E/binary>> -> exponent(E);
                            <<$E, E/binary>> -> exponent(E);
                            _ -> {0, R2}
                        end,
            case {Exp, R3} of
                {error, _} -> error;
                {_, <<>>} -> from_parts(Whole, Frac, 10, Exp, Width, Sign);
                _ -> error
            end
    end.

exponent(Bin) ->
    {Sign, R} = case Bin of
                    <<$-, X/binary>> -> {-1, X};
                    <<$+, X/binary>> -> {1, X};
                    _ -> {1, Bin}
                end,
    case separated(R, 10) of
        {ok, Digits} -> {Sign * binary_to_integer(Digits, 10), <<>>};
        error -> {error, R}
    end.

%% Both radices produce an exact rational, which is then rounded once.
from_parts(Whole, Frac, 16, Exp, Width, Sign) ->
    Mantissa = to_integer(<<Whole/binary, Frac/binary>>, 16),
    Scale = Exp - 4 * byte_size(Frac),
    finite(binary_value(Mantissa, Scale, Width, Sign), Width);
from_parts(Whole, Frac, 10, Exp, Width, Sign) ->
    Digits = <<Whole/binary, Frac/binary>>,
    finite(decimal_value(to_integer(Digits, 10), Exp - byte_size(Frac),
                         byte_size(Digits), Width, Sign), Width).

%% A literal written as a number has to name one. `0x1p128' and `1e39' are out
%% of range for an `f32' rather than a way of writing infinity, which is spelled
%% `inf' and handled before this. Rounding *down* to zero is not the same case:
%% the specification admits a literal too small to represent.
finite(Bits, Width) ->
    Max = exp_max(Width),
    case (Bits bsr mantissa_bits(Width)) band Max of
        Max -> error;
        _ -> {ok, Bits}
    end.

mantissa_bits(32) -> 23;
mantissa_bits(64) -> 52.

to_integer(<<>>, _Base) -> 0;
to_integer(Digits, Base) -> binary_to_integer(Digits, Base).

%% `Mantissa * 2^Scale'.
binary_value(0, _Scale, Width, Sign) ->
    assemble(Sign, 0, 0, Width);
binary_value(Mantissa, Scale, Width, Sign) ->
    case Scale + bit_length(Mantissa) of
        %% Far enough outside the format that the digits cannot matter, and
        %% shifting by the exponent would allocate the difference.
        E when E > 5000 -> assemble(Sign, exp_max(Width), 0, Width);
        E when E < -5000 -> assemble(Sign, 0, 0, Width);
        _ when Scale >= 0 -> round_ratio(Mantissa bsl Scale, 1, Width, Sign);
        _ -> round_ratio(Mantissa, 1 bsl (-Scale), Width, Sign)
    end.

%% `Mantissa * 10^Scale'. Ten to a large power is an integer nobody needs: past
%% these bounds the answer is infinity or zero whatever the digits are, and
%% building the power would allocate megabytes to find that out.
decimal_value(0, _Scale, _Digits, Width, Sign) ->
    assemble(Sign, 0, 0, Width);
decimal_value(Mantissa, Scale, Digits, Width, Sign) ->
    case Scale + Digits of
        M when M > 400 -> assemble(Sign, exp_max(Width), 0, Width);
        M when M < -400 -> assemble(Sign, 0, 0, Width);
        _ when Scale >= 0 -> round_ratio(Mantissa * pow10(Scale), 1, Width, Sign);
        _ -> round_ratio(Mantissa, pow10(-Scale), Width, Sign)
    end.

pow10(N) -> pow10(N, 1).

pow10(0, Acc) -> Acc;
pow10(N, Acc) -> pow10(N - 1, Acc * 10).

%%% --------------------------------------------------------- exact rounding ---

%% `Num/Den', rounded to the target width once, to nearest with ties to even.
%%
%% Once matters. Rounding to an Erlang double first and to the width second
%% rounds twice, and the second rounding then sees a number that has already
%% moved: `0x1.fffffefffffff8p127' becomes 2^128 as a double and so infinity,
%% where the correct answer is the largest finite `f32'. The specification's own
%% literals are chosen to catch exactly this, and comparing against the binary
%% decoder is what caught it here.
round_ratio(Num, Den, Width, Sign) ->
    Precision = precision(Width),
    Exponent = max(exponent_of(Num, Den), emin(Width)),
    Q = round_shifted(Num, Den, Exponent - Precision + 1),
    %% Rounding up may carry into the next binade, and it is that case that
    %% turns the largest representable value into infinity if it goes unnoticed.
    case Q bsr Precision of
        0 -> place(Q, Exponent, Width, Sign);
        _ -> place(Q bsr 1, Exponent + 1, Width, Sign)
    end.

place(Q, Exponent, Width, Sign) ->
    Hidden = 1 bsl (precision(Width) - 1),
    Max = emax(Width),
    if
        %% Below the smallest normal the exponent stops and the significand
        %% loses bits instead, which is what a subnormal is.
        Q < Hidden -> assemble(Sign, 0, Q, Width);
        Exponent > Max -> assemble(Sign, exp_max(Width), 0, Width);
        true -> assemble(Sign, Exponent - emin(Width) + 1, Q
- Hidden, Width)
    end.

%% The largest E with `Num/Den >= 2^E'. The two bit lengths give it to within
%% one, and one comparison settles which.
exponent_of(Num, Den) ->
    E = bit_length(Num) - bit_length(Den),
    case at_least_pow2(Num, Den, E) of
        true -> E;
        false -> E - 1
    end.

at_least_pow2(Num, Den, E) when E >= 0 -> Num >= (Den bsl E);
at_least_pow2(Num, Den, E) -> (Num bsl (-E)) >= Den.

round_shifted(Num, Den, Shift) ->
    {N, D} = case Shift >= 0 of
                 true -> {Num, Den bsl Shift};
                 false -> {Num bsl (-Shift), Den}
             end,
    Q = N div D,
    Twice = 2 * (N rem D),
    if
        Twice > D -> Q + 1;
        Twice < D -> Q;
        true -> Q + (Q band 1)
    end.

%% Through a binary rather than by shifting, so a mantissa of a few hundred
%% digits costs one pass instead of one bignum per bit.
bit_length(0) -> 0;
bit_length(N) ->
    Bytes = byte_size(binary:encode_unsigned(N)),
    (Bytes - 1) * 8 + top_bits(N bsr ((Bytes - 1) * 8)).

top_bits(0) -> 0;
top_bits(N) -> 1 + top_bits(N bsr 1).

precision(32) -> 24;
precision(64) -> 53.

emin(32) -> -126;
emin(64) -> -1022.

emax(32) -> 127;
emax(64) -> 1023.

%%% --------------------------------------------------------------- helpers ---

%% As `separated/2', but stops at the first character that is not a digit or a
%% valid separator instead of failing, so a fraction or exponent can follow.
separated_prefix(Bin, Base) -> separated_prefix(Bin, Base, <<>>, false).

%% A separator is only consumed when a digit follows it, so `1_' stops with the
%% underscore unread and whoever wanted the whole token sees it left over.
%% Consuming it here is how `1_.0' and `99_' were accepted.
separated_prefix(<<$_, C, R/binary>> = Bin, Base, Acc, true) ->
    case digit_value(C) of
        V when is_integer(V), V < Base ->
            separated_prefix(R, Base, <<Acc/binary, C>>, true);
        _ -> {Acc, Bin}
    end;
separated_prefix(<<$_, _/binary>> = Bin, _Base, Acc, _LastWasDigit) ->
    {Acc, Bin};
separated_prefix(<<C, R/binary>> = Bin, Base, Acc, _) ->
    case digit_value(C) of
        V when is_integer(V), V < Base ->
            separated_prefix(R, Base, <<Acc/binary, C>>, true);
        _ -> {Acc, Bin}
    end;
separated_prefix(<<>>, _Base, Acc, _) ->
    {Acc, <<>>}.

exp_max(32) -> 16#FF;
exp_max(64) -> 16#7FF.

mantissa_max(32) -> 16#7FFFFF;
mantissa_max(64) -> 16#FFFFFFFFFFFFF.

canonical_payload(32) -> 16#400000;
canonical_payload(64) -> 16#8000000000000.

assemble(Sign, Exp, Mantissa, 32) ->
    (Sign bsl 31) bor (Exp bsl 23) bor Mantissa;
assemble(Sign, Exp, Mantissa, 64) ->
    (Sign bsl 63) bor (Exp bsl 52) bor Mantissa.
