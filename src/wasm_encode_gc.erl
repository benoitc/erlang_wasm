-module(wasm_encode_gc).
-moduledoc """
The `0xFB` opcode space, garbage collection, written back to bytes:
`wasm_decode_gc` run backwards. Add a GC instruction here when you add it
there.

Two shapes need a choice. `ref.test` and `ref.cast` take one sub-opcode for a
nullable target and another for a non-nullable one, so the target's
nullability picks it. `br_on_cast` and `br_on_cast_fail` pack the
nullability of both of their types into one flags byte: bit 0 the source,
bit 1 the target.
""".

-export([instr/1]).

-doc "One `0xFB` instruction, or `false` when the instruction is not in this space.".
-spec instr(tuple() | atom()) -> iodata() | false.
%% - structs ---------------------------------------------------------------
instr({struct_new, T}) -> [16#FB, 0, u32(T)];
instr({struct_new_default, T}) -> [16#FB, 1, u32(T)];
instr({struct_get, T, F}) -> [16#FB, 2, u32(T), u32(F)];
instr({struct_get_s, T, F}) -> [16#FB, 3, u32(T), u32(F)];
instr({struct_get_u, T, F}) -> [16#FB, 4, u32(T), u32(F)];
instr({struct_set, T, F}) -> [16#FB, 5, u32(T), u32(F)];

%% - arrays ----------------------------------------------------------------
instr({array_new, T}) -> [16#FB, 6, u32(T)];
instr({array_new_default, T}) -> [16#FB, 7, u32(T)];
instr({array_new_fixed, T, N}) -> [16#FB, 8, u32(T), u32(N)];
instr({array_new_data, T, D}) -> [16#FB, 9, u32(T), u32(D)];
instr({array_new_elem, T, E}) -> [16#FB, 10, u32(T), u32(E)];
instr({array_get, T}) -> [16#FB, 11, u32(T)];
instr({array_get_s, T}) -> [16#FB, 12, u32(T)];
instr({array_get_u, T}) -> [16#FB, 13, u32(T)];
instr({array_set, T}) -> [16#FB, 14, u32(T)];
instr(array_len) -> <<16#FB, 15>>;
instr({array_fill, T}) -> [16#FB, 16, u32(T)];
instr({array_copy, Dst, Src}) -> [16#FB, 17, u32(Dst), u32(Src)];
instr({array_init_data, T, D}) -> [16#FB, 18, u32(T), u32(D)];
instr({array_init_elem, T, E}) -> [16#FB, 19, u32(T), u32(E)];

%% - casts -----------------------------------------------------------------
instr({ref_test, {ref, nonull, HT}}) -> [16#FB, 20, heaptype(HT)];
instr({ref_test, {ref, null, HT}}) -> [16#FB, 21, heaptype(HT)];
instr({ref_cast, {ref, nonull, HT}}) -> [16#FB, 22, heaptype(HT)];
instr({ref_cast, {ref, null, HT}}) -> [16#FB, 23, heaptype(HT)];
instr({br_on_cast, L, From, To}) -> [16#FB, 24 | br_on_cast(L, From, To)];
instr({br_on_cast_fail, L, From, To}) -> [16#FB, 25 | br_on_cast(L, From, To)];

%% - extern and i31 --------------------------------------------------------
instr(any_convert_extern) -> <<16#FB, 26>>;
instr(extern_convert_any) -> <<16#FB, 27>>;
instr(ref_i31) -> <<16#FB, 28>>;
instr(i31_get_s) -> <<16#FB, 29>>;
instr(i31_get_u) -> <<16#FB, 30>>;

instr(_) -> false.

%%% --------------------------------------------------------------- shapes ---

br_on_cast(L, {ref, N1, HT1}, {ref, N2, HT2}) ->
    [nullable(N1) bor (nullable(N2) bsl 1), u32(L), heaptype(HT1), heaptype(HT2)];
br_on_cast(L, From, To) ->
    wasm_encode:unencodable(br_on_cast, {L, From, To}).

nullable(null) -> 1;
nullable(nonull) -> 0;
nullable(N) -> wasm_encode:unencodable(nullability, N).

u32(V) -> wasm_encode:u32(V).

heaptype(HT) -> wasm_encode:heaptype(HT).
