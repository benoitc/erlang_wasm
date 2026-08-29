-module(wasm_leb128).
-moduledoc """
LEB128 varint decoding, strict per the WebAssembly binary format.

Read this if you are wondering why a varint your encoder produced is rejected.
The specification does not merely require a decodable varint, it constrains
the encoding: `uN`/`sN` admit at most `ceil(N/7)` bytes, and the final byte
may only carry bits that fit the target width (for signed values, the unused
high bits must be a sign extension). Encodings that violate this are
*malformed*, not merely unusual, and the specification test suite checks for
exactly this. Accepting them silently is the classic decoder bug.

Both constraints reduce to two checks:
- a continuation bit still set on the last permitted byte means "integer representation too long";
- a decoded value outside the target width's range means "integer too large". This is provably equivalent to the per-byte
      sign-extension rule, and it is one comparison instead of a mask
      and a branch on every byte.

Single-byte values dominate real modules (every small index and length), so
that case is matched directly before entering the loop.
""".

-export([u32/1, u64/1, s32/1, s64/1, s33/1]).
-export([uleb/2, sleb/2]).
-export([encode_u32/1, encode_s32/1, encode_s64/1]).

-define(U32_MAX_BYTES, 5).
-define(U64_MAX_BYTES, 10).

%%% -------------------------------------------------------------- decoding ---

-doc "Decode an unsigned 32-bit LEB128. Returns the value and the rest.".
-spec u32(binary()) -> {non_neg_integer(), binary()}.
u32(<<0:1, B:7, Rest/binary>>) -> {B, Rest};
u32(Bin) -> uleb(Bin, 32).

-spec u64(binary()) -> {non_neg_integer(), binary()}.
u64(<<0:1, B:7, Rest/binary>>) -> {B, Rest};
u64(Bin) -> uleb(Bin, 64).

-doc """
Decode a signed 32-bit LEB128. A one-byte encoding with bit 6 clear is
a small non-negative value; with bit 6 set it is a small negative one.
""".
-spec s32(binary()) -> {integer(), binary()}.
s32(<<0:1, 0:1, B:6, Rest/binary>>) -> {B, Rest};
s32(<<0:1, 1:1, B:6, Rest/binary>>) -> {B - 64, Rest};
s32(Bin) -> sleb(Bin, 32).

-spec s64(binary()) -> {integer(), binary()}.
s64(<<0:1, 0:1, B:6, Rest/binary>>) -> {B, Rest};
s64(<<0:1, 1:1, B:6, Rest/binary>>) -> {B - 64, Rest};
s64(Bin) -> sleb(Bin, 64).

-doc """
Decode the `s33` used by block types, which must distinguish a negative
value type encoding from a non-negative type index.
""".
-spec s33(binary()) -> {integer(), binary()}.
s33(<<0:1, 0:1, B:6, Rest/binary>>) -> {B, Rest};
s33(<<0:1, 1:1, B:6, Rest/binary>>) -> {B - 64, Rest};
s33(Bin) -> sleb(Bin, 33).

-doc "Decode an unsigned LEB128 of at most `Bits` bits.".
-spec uleb(binary(), pos_integer()) -> {non_neg_integer(), binary()}.
uleb(Bin, Bits) ->
    {Val, Rest} = uleb(Bin, max_bytes(Bits), 1, 0, 0),
    case Val < (1 bsl Bits) of
        true  -> {Val, Rest};
        false -> wasm_error:malformed(integer_too_large, <<"integer too large">>,
                                      #{width => Bits, signed => false})
    end.

uleb(<<0:1, B:7, Rest/binary>>, _Max, _N, Acc, Shift) ->
    {Acc bor (B bsl Shift), Rest};
uleb(<<1:1, _:7, _/binary>>, Max, N, _Acc, _Shift) when N >= Max ->
    wasm_error:malformed(integer_representation_too_long,
                         <<"integer representation too long">>, #{max_bytes => Max});
uleb(<<1:1, B:7, Rest/binary>>, Max, N, Acc, Shift) ->
    uleb(Rest, Max, N + 1, Acc bor (B bsl Shift), Shift + 7);
uleb(<<>>, _Max, _N, _Acc, _Shift) ->
    wasm_error:malformed(unexpected_end, <<"unexpected end">>, #{reading => leb128}).

-doc "Decode a signed LEB128 of at most `Bits` bits.".
-spec sleb(binary(), pos_integer()) -> {integer(), binary()}.
sleb(Bin, Bits) ->
    {Val, Rest} = sleb(Bin, max_bytes(Bits), 1, 0, 0),
    Limit = 1 bsl (Bits - 1),
    case Val >= -Limit andalso Val < Limit of
        true  -> {Val, Rest};
        false -> wasm_error:malformed(integer_too_large, <<"integer too large">>,
                                      #{width => Bits, signed => true})
    end.

sleb(<<0:1, B:7, Rest/binary>>, _Max, _N, Acc, Shift) ->
    Val = Acc bor (B bsl Shift),
    %% Bit 6 of the terminating byte is the sign bit of the encoded value.
    case B band 16#40 of
        0 -> {Val, Rest};
        _ -> {Val - (1 bsl (Shift + 7)), Rest}
    end;
sleb(<<1:1, _:7, _/binary>>, Max, N, _Acc, _Shift) when N >= Max ->
    wasm_error:malformed(integer_representation_too_long,
                         <<"integer representation too long">>, #{max_bytes => Max});
sleb(<<1:1, B:7, Rest/binary>>, Max, N, Acc, Shift) ->
    sleb(Rest, Max, N + 1, Acc bor (B bsl Shift), Shift + 7);
sleb(<<>>, _Max, _N, _Acc, _Shift) ->
    wasm_error:malformed(unexpected_end, <<"unexpected end">>, #{reading => leb128}).

max_bytes(Bits) -> (Bits + 6) div 7.

%%% -------------------------------------------------------------- encoding ---
%%% Used by tests and fixture builders, not on any runtime path.

-spec encode_u32(non_neg_integer()) -> binary().
encode_u32(V) when V >= 0, V < 128 -> <<0:1, V:7>>;
encode_u32(V) when V >= 0 -> <<1:1, (V band 16#7F):7, (encode_u32(V bsr 7))/binary>>.

-spec encode_s32(integer()) -> binary().
encode_s32(V) -> encode_s(V).

-spec encode_s64(integer()) -> binary().
encode_s64(V) -> encode_s(V).

encode_s(V) ->
    Byte = V band 16#7F,
    Rest = V bsr 7,
    Done = (Rest =:= 0 andalso Byte band 16#40 =:= 0)
        orelse (Rest =:= -1 andalso Byte band 16#40 =/= 0),
    case Done of
        true  -> <<0:1, Byte:7>>;
        false -> <<1:1, Byte:7, (encode_s(Rest))/binary>>
    end.
