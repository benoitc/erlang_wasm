-module(wasm_encode_atomic).
-moduledoc """
The `0xFE` opcode space, threads, written back to bytes: `wasm_decode_atomic`
run backwards. Every instruction but the fence carries a memory argument;
the fence carries one reserved byte, which must be zero.
""".

-export([instr/1]).

-doc "One `0xFE` instruction, or `false` when the instruction is not in this space.".
-spec instr(tuple() | atom()) -> iodata() | false.
instr({memory_atomic_notify, MA}) -> [<<16#FE, 16#00>>, mem_arg(MA)];
instr({memory_atomic_wait32, MA}) -> [<<16#FE, 16#01>>, mem_arg(MA)];
instr({memory_atomic_wait64, MA}) -> [<<16#FE, 16#02>>, mem_arg(MA)];
%% The reserved byte is a memory index that must be zero today.
instr(atomic_fence) -> <<16#FE, 16#03, 16#00>>;
instr({i32_atomic_load, MA}) -> [<<16#FE, 16#10>>, mem_arg(MA)];
instr({i64_atomic_load, MA}) -> [<<16#FE, 16#11>>, mem_arg(MA)];
instr({i32_atomic_load8_u, MA}) -> [<<16#FE, 16#12>>, mem_arg(MA)];
instr({i32_atomic_load16_u, MA}) -> [<<16#FE, 16#13>>, mem_arg(MA)];
instr({i64_atomic_load8_u, MA}) -> [<<16#FE, 16#14>>, mem_arg(MA)];
instr({i64_atomic_load16_u, MA}) -> [<<16#FE, 16#15>>, mem_arg(MA)];
instr({i64_atomic_load32_u, MA}) -> [<<16#FE, 16#16>>, mem_arg(MA)];
instr({i32_atomic_store, MA}) -> [<<16#FE, 16#17>>, mem_arg(MA)];
instr({i64_atomic_store, MA}) -> [<<16#FE, 16#18>>, mem_arg(MA)];
instr({i32_atomic_store8, MA}) -> [<<16#FE, 16#19>>, mem_arg(MA)];
instr({i32_atomic_store16, MA}) -> [<<16#FE, 16#1A>>, mem_arg(MA)];
instr({i64_atomic_store8, MA}) -> [<<16#FE, 16#1B>>, mem_arg(MA)];
instr({i64_atomic_store16, MA}) -> [<<16#FE, 16#1C>>, mem_arg(MA)];
instr({i64_atomic_store32, MA}) -> [<<16#FE, 16#1D>>, mem_arg(MA)];
instr({i32_atomic_rmw_add, MA}) -> [<<16#FE, 16#1E>>, mem_arg(MA)];
instr({i64_atomic_rmw_add, MA}) -> [<<16#FE, 16#1F>>, mem_arg(MA)];
instr({i32_atomic_rmw8_add_u, MA}) -> [<<16#FE, 16#20>>, mem_arg(MA)];
instr({i32_atomic_rmw16_add_u, MA}) -> [<<16#FE, 16#21>>, mem_arg(MA)];
instr({i64_atomic_rmw8_add_u, MA}) -> [<<16#FE, 16#22>>, mem_arg(MA)];
instr({i64_atomic_rmw16_add_u, MA}) -> [<<16#FE, 16#23>>, mem_arg(MA)];
instr({i64_atomic_rmw32_add_u, MA}) -> [<<16#FE, 16#24>>, mem_arg(MA)];
instr({i32_atomic_rmw_sub, MA}) -> [<<16#FE, 16#25>>, mem_arg(MA)];
instr({i64_atomic_rmw_sub, MA}) -> [<<16#FE, 16#26>>, mem_arg(MA)];
instr({i32_atomic_rmw8_sub_u, MA}) -> [<<16#FE, 16#27>>, mem_arg(MA)];
instr({i32_atomic_rmw16_sub_u, MA}) -> [<<16#FE, 16#28>>, mem_arg(MA)];
instr({i64_atomic_rmw8_sub_u, MA}) -> [<<16#FE, 16#29>>, mem_arg(MA)];
instr({i64_atomic_rmw16_sub_u, MA}) -> [<<16#FE, 16#2A>>, mem_arg(MA)];
instr({i64_atomic_rmw32_sub_u, MA}) -> [<<16#FE, 16#2B>>, mem_arg(MA)];
instr({i32_atomic_rmw_and, MA}) -> [<<16#FE, 16#2C>>, mem_arg(MA)];
instr({i64_atomic_rmw_and, MA}) -> [<<16#FE, 16#2D>>, mem_arg(MA)];
instr({i32_atomic_rmw8_and_u, MA}) -> [<<16#FE, 16#2E>>, mem_arg(MA)];
instr({i32_atomic_rmw16_and_u, MA}) -> [<<16#FE, 16#2F>>, mem_arg(MA)];
instr({i64_atomic_rmw8_and_u, MA}) -> [<<16#FE, 16#30>>, mem_arg(MA)];
instr({i64_atomic_rmw16_and_u, MA}) -> [<<16#FE, 16#31>>, mem_arg(MA)];
instr({i64_atomic_rmw32_and_u, MA}) -> [<<16#FE, 16#32>>, mem_arg(MA)];
instr({i32_atomic_rmw_or, MA}) -> [<<16#FE, 16#33>>, mem_arg(MA)];
instr({i64_atomic_rmw_or, MA}) -> [<<16#FE, 16#34>>, mem_arg(MA)];
instr({i32_atomic_rmw8_or_u, MA}) -> [<<16#FE, 16#35>>, mem_arg(MA)];
instr({i32_atomic_rmw16_or_u, MA}) -> [<<16#FE, 16#36>>, mem_arg(MA)];
instr({i64_atomic_rmw8_or_u, MA}) -> [<<16#FE, 16#37>>, mem_arg(MA)];
instr({i64_atomic_rmw16_or_u, MA}) -> [<<16#FE, 16#38>>, mem_arg(MA)];
instr({i64_atomic_rmw32_or_u, MA}) -> [<<16#FE, 16#39>>, mem_arg(MA)];
instr({i32_atomic_rmw_xor, MA}) -> [<<16#FE, 16#3A>>, mem_arg(MA)];
instr({i64_atomic_rmw_xor, MA}) -> [<<16#FE, 16#3B>>, mem_arg(MA)];
instr({i32_atomic_rmw8_xor_u, MA}) -> [<<16#FE, 16#3C>>, mem_arg(MA)];
instr({i32_atomic_rmw16_xor_u, MA}) -> [<<16#FE, 16#3D>>, mem_arg(MA)];
instr({i64_atomic_rmw8_xor_u, MA}) -> [<<16#FE, 16#3E>>, mem_arg(MA)];
instr({i64_atomic_rmw16_xor_u, MA}) -> [<<16#FE, 16#3F>>, mem_arg(MA)];
instr({i64_atomic_rmw32_xor_u, MA}) -> [<<16#FE, 16#40>>, mem_arg(MA)];
instr({i32_atomic_rmw_xchg, MA}) -> [<<16#FE, 16#41>>, mem_arg(MA)];
instr({i64_atomic_rmw_xchg, MA}) -> [<<16#FE, 16#42>>, mem_arg(MA)];
instr({i32_atomic_rmw8_xchg_u, MA}) -> [<<16#FE, 16#43>>, mem_arg(MA)];
instr({i32_atomic_rmw16_xchg_u, MA}) -> [<<16#FE, 16#44>>, mem_arg(MA)];
instr({i64_atomic_rmw8_xchg_u, MA}) -> [<<16#FE, 16#45>>, mem_arg(MA)];
instr({i64_atomic_rmw16_xchg_u, MA}) -> [<<16#FE, 16#46>>, mem_arg(MA)];
instr({i64_atomic_rmw32_xchg_u, MA}) -> [<<16#FE, 16#47>>, mem_arg(MA)];
instr({i32_atomic_rmw_cmpxchg, MA}) -> [<<16#FE, 16#48>>, mem_arg(MA)];
instr({i64_atomic_rmw_cmpxchg, MA}) -> [<<16#FE, 16#49>>, mem_arg(MA)];
instr({i32_atomic_rmw8_cmpxchg_u, MA}) -> [<<16#FE, 16#4A>>, mem_arg(MA)];
instr({i32_atomic_rmw16_cmpxchg_u, MA}) -> [<<16#FE, 16#4B>>, mem_arg(MA)];
instr({i64_atomic_rmw8_cmpxchg_u, MA}) -> [<<16#FE, 16#4C>>, mem_arg(MA)];
instr({i64_atomic_rmw16_cmpxchg_u, MA}) -> [<<16#FE, 16#4D>>, mem_arg(MA)];
instr({i64_atomic_rmw32_cmpxchg_u, MA}) -> [<<16#FE, 16#4E>>, mem_arg(MA)];
instr(_) -> false.

mem_arg(MA) -> wasm_encode_code:mem_arg(MA).
