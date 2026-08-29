-module(wasm_validate_atomic).
-moduledoc """
Types and alignment for the `0xFE` opcode space.

Ask it for `{Kind, ValueType, Width}` for any atomic instruction, where `Width`
is the access in bytes. The interpreter reads the same answer, so the two cannot
drift apart.

The read-modify-write family is written out rather than derived from the
instruction's name. Parsing the name would be shorter, but this function is
consulted for *every* memory instruction in a module, including the ordinary
loads and stores of a module with no atomics in it, and a fallthrough that
builds a string per instruction is not something to put on the path that
validates and instantiates every module.

**Alignment is exact here, not a hint.** An ordinary load may declare any
alignment up to the natural one and the number is only advice; an atomic access
*must* declare exactly its natural alignment, and a module that declares
anything else is invalid rather than merely slow. That is what lets an
implementation assume the access does not straddle two words.
""".

-export([mem_op/1]).

-doc """
The shape of an atomic instruction.

`Kind` is one of `load`, `store`, `{rmw, Operation}`, `cmpxchg`, `wait` or
`notify`, which is what decides how many operands come off the stack:

| kind | operands, top of stack last | result |
| --- | --- | --- |
| `load` | address | the value |
| `store` | address, value | none |
| `rmw` | address, value | the value that was there |
| `cmpxchg` | address, expected, replacement | the value that was there |
| `wait` | address, expected, timeout (i64) | i32: 0 woken, 1 not equal, 2 timed out |
| `notify` | address, count (i32) | i32: how many were woken |
""".
-spec mem_op(atom()) ->
          {atom() | {rmw, atom()}, i32 | i64, 1..8} | false.

mem_op(memory_atomic_notify) -> {notify, i32, 4};
mem_op(memory_atomic_wait32) -> {wait, i32, 4};
mem_op(memory_atomic_wait64) -> {wait, i64, 8};

mem_op(i32_atomic_load) -> {load, i32, 4};
mem_op(i64_atomic_load) -> {load, i64, 8};
mem_op(i32_atomic_load8_u) -> {load, i32, 1};
mem_op(i32_atomic_load16_u) -> {load, i32, 2};
mem_op(i64_atomic_load8_u) -> {load, i64, 1};
mem_op(i64_atomic_load16_u) -> {load, i64, 2};
mem_op(i64_atomic_load32_u) -> {load, i64, 4};

mem_op(i32_atomic_store) -> {store, i32, 4};
mem_op(i64_atomic_store) -> {store, i64, 8};
mem_op(i32_atomic_store8) -> {store, i32, 1};
mem_op(i32_atomic_store16) -> {store, i32, 2};
mem_op(i64_atomic_store8) -> {store, i64, 1};
mem_op(i64_atomic_store16) -> {store, i64, 2};
mem_op(i64_atomic_store32) -> {store, i64, 4};

mem_op(i32_atomic_rmw_add) -> {{rmw, add}, i32, 4};
mem_op(i64_atomic_rmw_add) -> {{rmw, add}, i64, 8};
mem_op(i32_atomic_rmw8_add_u) -> {{rmw, add}, i32, 1};
mem_op(i32_atomic_rmw16_add_u) -> {{rmw, add}, i32, 2};
mem_op(i64_atomic_rmw8_add_u) -> {{rmw, add}, i64, 1};
mem_op(i64_atomic_rmw16_add_u) -> {{rmw, add}, i64, 2};
mem_op(i64_atomic_rmw32_add_u) -> {{rmw, add}, i64, 4};

mem_op(i32_atomic_rmw_sub) -> {{rmw, sub}, i32, 4};
mem_op(i64_atomic_rmw_sub) -> {{rmw, sub}, i64, 8};
mem_op(i32_atomic_rmw8_sub_u) -> {{rmw, sub}, i32, 1};
mem_op(i32_atomic_rmw16_sub_u) -> {{rmw, sub}, i32, 2};
mem_op(i64_atomic_rmw8_sub_u) -> {{rmw, sub}, i64, 1};
mem_op(i64_atomic_rmw16_sub_u) -> {{rmw, sub}, i64, 2};
mem_op(i64_atomic_rmw32_sub_u) -> {{rmw, sub}, i64, 4};

mem_op(i32_atomic_rmw_and) -> {{rmw, 'and'}, i32, 4};
mem_op(i64_atomic_rmw_and) -> {{rmw, 'and'}, i64, 8};
mem_op(i32_atomic_rmw8_and_u) -> {{rmw, 'and'}, i32, 1};
mem_op(i32_atomic_rmw16_and_u) -> {{rmw, 'and'}, i32, 2};
mem_op(i64_atomic_rmw8_and_u) -> {{rmw, 'and'}, i64, 1};
mem_op(i64_atomic_rmw16_and_u) -> {{rmw, 'and'}, i64, 2};
mem_op(i64_atomic_rmw32_and_u) -> {{rmw, 'and'}, i64, 4};

mem_op(i32_atomic_rmw_or) -> {{rmw, 'or'}, i32, 4};
mem_op(i64_atomic_rmw_or) -> {{rmw, 'or'}, i64, 8};
mem_op(i32_atomic_rmw8_or_u) -> {{rmw, 'or'}, i32, 1};
mem_op(i32_atomic_rmw16_or_u) -> {{rmw, 'or'}, i32, 2};
mem_op(i64_atomic_rmw8_or_u) -> {{rmw, 'or'}, i64, 1};
mem_op(i64_atomic_rmw16_or_u) -> {{rmw, 'or'}, i64, 2};
mem_op(i64_atomic_rmw32_or_u) -> {{rmw, 'or'}, i64, 4};

mem_op(i32_atomic_rmw_xor) -> {{rmw, 'xor'}, i32, 4};
mem_op(i64_atomic_rmw_xor) -> {{rmw, 'xor'}, i64, 8};
mem_op(i32_atomic_rmw8_xor_u) -> {{rmw, 'xor'}, i32, 1};
mem_op(i32_atomic_rmw16_xor_u) -> {{rmw, 'xor'}, i32, 2};
mem_op(i64_atomic_rmw8_xor_u) -> {{rmw, 'xor'}, i64, 1};
mem_op(i64_atomic_rmw16_xor_u) -> {{rmw, 'xor'}, i64, 2};
mem_op(i64_atomic_rmw32_xor_u) -> {{rmw, 'xor'}, i64, 4};

mem_op(i32_atomic_rmw_xchg) -> {{rmw, xchg}, i32, 4};
mem_op(i64_atomic_rmw_xchg) -> {{rmw, xchg}, i64, 8};
mem_op(i32_atomic_rmw8_xchg_u) -> {{rmw, xchg}, i32, 1};
mem_op(i32_atomic_rmw16_xchg_u) -> {{rmw, xchg}, i32, 2};
mem_op(i64_atomic_rmw8_xchg_u) -> {{rmw, xchg}, i64, 1};
mem_op(i64_atomic_rmw16_xchg_u) -> {{rmw, xchg}, i64, 2};
mem_op(i64_atomic_rmw32_xchg_u) -> {{rmw, xchg}, i64, 4};

mem_op(i32_atomic_rmw_cmpxchg) -> {cmpxchg, i32, 4};
mem_op(i64_atomic_rmw_cmpxchg) -> {cmpxchg, i64, 8};
mem_op(i32_atomic_rmw8_cmpxchg_u) -> {cmpxchg, i32, 1};
mem_op(i32_atomic_rmw16_cmpxchg_u) -> {cmpxchg, i32, 2};
mem_op(i64_atomic_rmw8_cmpxchg_u) -> {cmpxchg, i64, 1};
mem_op(i64_atomic_rmw16_cmpxchg_u) -> {cmpxchg, i64, 2};
mem_op(i64_atomic_rmw32_cmpxchg_u) -> {cmpxchg, i64, 4};

mem_op(_) -> false.
