-module(wasm_decode_atomic).
-moduledoc """
The `0xFE` opcode space: threads. Add an atomic instruction here.

Sixty-six instructions in four shapes, and only one of them is new to this
decoder:

| shape | instructions |
| --- | --- |
| memory argument | every atomic load, store and read-modify-write, and `memory.atomic.wait` and `notify` |
| a single zero byte | `atomic.fence` |

The `0x03 0x00` encoding of `atomic.fence` is the odd one. The trailing byte is
a memory index reserved for a future proposal and required to be zero, so it is
checked rather than skipped: a non-zero byte there is a malformed module, not a
fence on another memory.
""".

-export([instr/1]).

-spec instr(binary()) -> {tuple() | atom(), binary()}.
instr(R0) ->
    {Sub, R1} = wasm_leb128:u32(R0),
    sub(Sub, R1).

%%% ------------------------------------------------------ wait and notify ---

sub(16#00, R) -> mem(memory_atomic_notify, R);
sub(16#01, R) -> mem(memory_atomic_wait32, R);
sub(16#02, R) -> mem(memory_atomic_wait64, R);

%% The reserved byte is a memory index that must be zero today.
sub(16#03, <<0, R/binary>>) -> {atomic_fence, R};
sub(16#03, <<B, _/binary>>) ->
    wasm_error:malformed(zero_byte_expected, <<"zero byte expected">>,
                         #{op => atomic_fence, got => B});
sub(16#03, <<>>) ->
    wasm_error:malformed(unexpected_end, <<"unexpected end">>,
                         #{op => atomic_fence});

%%% ----------------------------------------------------- loads and stores ---

sub(16#10, R) -> mem(i32_atomic_load, R);
sub(16#11, R) -> mem(i64_atomic_load, R);
sub(16#12, R) -> mem(i32_atomic_load8_u, R);
sub(16#13, R) -> mem(i32_atomic_load16_u, R);
sub(16#14, R) -> mem(i64_atomic_load8_u, R);
sub(16#15, R) -> mem(i64_atomic_load16_u, R);
sub(16#16, R) -> mem(i64_atomic_load32_u, R);

sub(16#17, R) -> mem(i32_atomic_store, R);
sub(16#18, R) -> mem(i64_atomic_store, R);
sub(16#19, R) -> mem(i32_atomic_store8, R);
sub(16#1A, R) -> mem(i32_atomic_store16, R);
sub(16#1B, R) -> mem(i64_atomic_store8, R);
sub(16#1C, R) -> mem(i64_atomic_store16, R);
sub(16#1D, R) -> mem(i64_atomic_store32, R);

%%% ------------------------------------------------- read, modify, write ---
%%
%% Seven widths per operation, in the same order every time: i32 and i64 at
%% full width, then the narrow forms. The names carry the width so the
%% validator and the interpreter can both read it off the atom.

sub(16#1E, R) -> mem(i32_atomic_rmw_add, R);
sub(16#1F, R) -> mem(i64_atomic_rmw_add, R);
sub(16#20, R) -> mem(i32_atomic_rmw8_add_u, R);
sub(16#21, R) -> mem(i32_atomic_rmw16_add_u, R);
sub(16#22, R) -> mem(i64_atomic_rmw8_add_u, R);
sub(16#23, R) -> mem(i64_atomic_rmw16_add_u, R);
sub(16#24, R) -> mem(i64_atomic_rmw32_add_u, R);

sub(16#25, R) -> mem(i32_atomic_rmw_sub, R);
sub(16#26, R) -> mem(i64_atomic_rmw_sub, R);
sub(16#27, R) -> mem(i32_atomic_rmw8_sub_u, R);
sub(16#28, R) -> mem(i32_atomic_rmw16_sub_u, R);
sub(16#29, R) -> mem(i64_atomic_rmw8_sub_u, R);
sub(16#2A, R) -> mem(i64_atomic_rmw16_sub_u, R);
sub(16#2B, R) -> mem(i64_atomic_rmw32_sub_u, R);

sub(16#2C, R) -> mem(i32_atomic_rmw_and, R);
sub(16#2D, R) -> mem(i64_atomic_rmw_and, R);
sub(16#2E, R) -> mem(i32_atomic_rmw8_and_u, R);
sub(16#2F, R) -> mem(i32_atomic_rmw16_and_u, R);
sub(16#30, R) -> mem(i64_atomic_rmw8_and_u, R);
sub(16#31, R) -> mem(i64_atomic_rmw16_and_u, R);
sub(16#32, R) -> mem(i64_atomic_rmw32_and_u, R);

sub(16#33, R) -> mem(i32_atomic_rmw_or, R);
sub(16#34, R) -> mem(i64_atomic_rmw_or, R);
sub(16#35, R) -> mem(i32_atomic_rmw8_or_u, R);
sub(16#36, R) -> mem(i32_atomic_rmw16_or_u, R);
sub(16#37, R) -> mem(i64_atomic_rmw8_or_u, R);
sub(16#38, R) -> mem(i64_atomic_rmw16_or_u, R);
sub(16#39, R) -> mem(i64_atomic_rmw32_or_u, R);

sub(16#3A, R) -> mem(i32_atomic_rmw_xor, R);
sub(16#3B, R) -> mem(i64_atomic_rmw_xor, R);
sub(16#3C, R) -> mem(i32_atomic_rmw8_xor_u, R);
sub(16#3D, R) -> mem(i32_atomic_rmw16_xor_u, R);
sub(16#3E, R) -> mem(i64_atomic_rmw8_xor_u, R);
sub(16#3F, R) -> mem(i64_atomic_rmw16_xor_u, R);
sub(16#40, R) -> mem(i64_atomic_rmw32_xor_u, R);

sub(16#41, R) -> mem(i32_atomic_rmw_xchg, R);
sub(16#42, R) -> mem(i64_atomic_rmw_xchg, R);
sub(16#43, R) -> mem(i32_atomic_rmw8_xchg_u, R);
sub(16#44, R) -> mem(i32_atomic_rmw16_xchg_u, R);
sub(16#45, R) -> mem(i64_atomic_rmw8_xchg_u, R);
sub(16#46, R) -> mem(i64_atomic_rmw16_xchg_u, R);
sub(16#47, R) -> mem(i64_atomic_rmw32_xchg_u, R);

sub(16#48, R) -> mem(i32_atomic_rmw_cmpxchg, R);
sub(16#49, R) -> mem(i64_atomic_rmw_cmpxchg, R);
sub(16#4A, R) -> mem(i32_atomic_rmw8_cmpxchg_u, R);
sub(16#4B, R) -> mem(i32_atomic_rmw16_cmpxchg_u, R);
sub(16#4C, R) -> mem(i64_atomic_rmw8_cmpxchg_u, R);
sub(16#4D, R) -> mem(i64_atomic_rmw16_cmpxchg_u, R);
sub(16#4E, R) -> mem(i64_atomic_rmw32_cmpxchg_u, R);

sub(Sub, _) ->
    wasm_error:malformed(illegal_opcode, <<"illegal opcode">>,
                         #{opcode => 16#FE, sub => Sub}).

mem(Op, Bin) -> wasm_decode_code:mem_arg(Bin, Op).
