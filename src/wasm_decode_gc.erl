-module(wasm_decode_gc).
-moduledoc """
The `0xFB` opcode space: garbage collection.

Structs, arrays, `i31` and the casts. Add a GC instruction here rather than in
`wasm_decode_code`. Split out of `wasm_decode_code` for the
same reason the vector opcodes were: it is a proposal's worth of instructions
and inlining it would bury the rules around it.

Only a few immediate shapes appear:

| shape | instructions |
| --- | --- |
| type index | `struct.new`, `array.new`, `array.len` and most others |
| type index and field index | the `struct.get` family and `struct.set` |
| type index and data or element index | `array.new_data`, `array.init_elem` |
| heap type | `ref.test`, `ref.cast`, in nullable and non-nullable forms |
| flags, label and two heap types | `br_on_cast`, `br_on_cast_fail` |
""".

-export([instr/1]).

-spec instr(binary()) -> {tuple() | atom(), binary()}.
instr(R0) ->
    {Sub, R1} = wasm_leb128:u32(R0),
    sub(Sub, R1).

%%% ------------------------------------------------------------- structs ---

sub(0, R) -> type_arg(R, fun(T) -> {struct_new, T} end);
sub(1, R) -> type_arg(R, fun(T) -> {struct_new_default, T} end);
sub(2, R) -> type_field(R, struct_get);
sub(3, R) -> type_field(R, struct_get_s);
sub(4, R) -> type_field(R, struct_get_u);
sub(5, R) -> type_field(R, struct_set);

%%% -------------------------------------------------------------- arrays ---

sub(6, R) -> type_arg(R, fun(T) -> {array_new, T} end);
sub(7, R) -> type_arg(R, fun(T) -> {array_new_default, T} end);
sub(8, R) -> type_pair(R, array_new_fixed);
sub(9, R) -> type_pair(R, array_new_data);
sub(10, R) -> type_pair(R, array_new_elem);
sub(11, R) -> type_arg(R, fun(T) -> {array_get, T} end);
sub(12, R) -> type_arg(R, fun(T) -> {array_get_s, T} end);
sub(13, R) -> type_arg(R, fun(T) -> {array_get_u, T} end);
sub(14, R) -> type_arg(R, fun(T) -> {array_set, T} end);
sub(15, R) -> {array_len, R};
sub(16, R) -> type_arg(R, fun(T) -> {array_fill, T} end);
sub(17, R) -> type_pair(R, array_copy);
sub(18, R) -> type_pair(R, array_init_data);
sub(19, R) -> type_pair(R, array_init_elem);

%%% --------------------------------------------------------------- casts ---

%% The two forms differ only in whether the *target* type is nullable, which is
%% part of the type being tested rather than a separate flag.
sub(20, R0) -> cast(ref_test, nonull, R0);
sub(21, R0) -> cast(ref_test, null, R0);
sub(22, R0) -> cast(ref_cast, nonull, R0);
sub(23, R0) -> cast(ref_cast, null, R0);
sub(24, R0) -> br_on_cast(br_on_cast, R0);
sub(25, R0) -> br_on_cast(br_on_cast_fail, R0);

%%% ------------------------------------------------------ extern and i31 ---

%% These two only change how a reference is *viewed*: an external reference
%% wrapping an internal one, and back. Neither allocates.
sub(26, R) -> {any_convert_extern, R};
sub(27, R) -> {extern_convert_any, R};
sub(28, R) -> {ref_i31, R};
sub(29, R) -> {i31_get_s, R};
sub(30, R) -> {i31_get_u, R};

sub(Sub, _) ->
    wasm_error:malformed(illegal_opcode, <<"illegal opcode">>,
                         #{opcode => 16#FB, sub => Sub}).

%%% --------------------------------------------------------------- shapes ---

type_arg(Bin, Wrap) ->
    {T, Rest} = wasm_leb128:u32(Bin),
    {Wrap(T), Rest}.

type_field(Bin0, Op) ->
    {T, Bin1} = wasm_leb128:u32(Bin0),
    {F, Bin2} = wasm_leb128:u32(Bin1),
    {{Op, T, F}, Bin2}.

type_pair(Bin0, Op) ->
    {A, Bin1} = wasm_leb128:u32(Bin0),
    {B, Bin2} = wasm_leb128:u32(Bin1),
    {{Op, A, B}, Bin2}.

cast(Op, Null, Bin0) ->
    {HT, Bin1} = wasm_decode:heaptype(Bin0),
    {{Op, {ref, Null, HT}}, Bin1}.

%% The flags byte says whether each of the two heap types is nullable: bit 0 the
%% source, bit 1 the target. They are packed rather than given as reference
%% types because both share the label and are read together.
br_on_cast(Op, Bin0) ->
    case Bin0 of
        <<Flags:8, Bin1/binary>> when Flags =< 3 ->
            {Label, Bin2} = wasm_leb128:u32(Bin1),
            {HT1, Bin3} = wasm_decode:heaptype(Bin2),
            {HT2, Bin4} = wasm_decode:heaptype(Bin3),
            From = {ref, nullability(Flags band 1), HT1},
            To = {ref, nullability(Flags bsr 1), HT2},
            {{Op, Label, From, To}, Bin4};
        <<Flags:8, _/binary>> ->
            wasm_error:malformed(malformed_cast_flags,
                                 <<"malformed cast flags">>, #{flags => Flags});
        <<>> ->
            wasm_error:malformed(unexpected_end, <<"unexpected end">>,
                                 #{reading => br_on_cast})
    end.

nullability(1) -> null;
nullability(0) -> nonull.
