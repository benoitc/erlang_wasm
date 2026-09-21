-module(wasm_canon).
-moduledoc """
Internal, Phase 0 spike: the Canonical ABI lift/lower, for a subset of types.

The Canonical ABI is how a component-model value crosses between the host and a
core module's linear memory. `lower_params/3` turns Erlang terms into the flat
core arguments an exported function takes; `lift_result/3` turns the core result
back into an Erlang term. Aggregates go through guest memory: a `list`/`string`
argument is placed with the guest's `cabi_realloc`, and a result too big to return
flat comes back through a guest-allocated area whose pointer the core function
returns.

This subset covers what the Phase 0 fixture needs -- primitives, `list<u8>` and
`string` (both bytes), and `result<T, E>` -- and is written descriptor-driven so
the remaining value types (records, variants, options, tuples, other list
elements) extend it in Phase 1 rather than replace it. Strings are UTF-8; the
other two Canonical ABI string encodings are Phase 1.
""".

-export([lower_params/3, lift_result/3, size_align/1]).

-export_type([desc/0]).

%% A Canonical ABI value descriptor. A subset for now.
-type desc() :: u8 | u16 | u32 | u64
              | s8 | s16 | s32 | s64
              | f32 | f64 | bool | char
              | string
              | {list, desc()}
              | {result, desc() | none, desc() | none}.

%% One flat core value is at most 8 bytes; the ABI limits a flat result to one
%% value, so a wider result is returned through memory instead.
-define(MAX_FLAT_RESULTS, 1).

-doc "Lower each parameter to the flat core values its function takes.".
-spec lower_params(wasm:instance(), [desc()], [term()]) -> [term()].
lower_params(Inst, Descs, Args) ->
    lists:append(lists:zipwith(fun(D, A) -> lower_flat(Inst, D, A) end,
                               Descs, Args)).

%% Flatten one value to core arguments. A `list`/`string` becomes `(ptr, len)`
%% after its bytes are placed in guest memory with the guest allocator; a
%% primitive is passed as itself.
lower_flat(Inst, D, Bin) when D =:= string; D =:= {list, u8} ->
    Len = byte_size(Bin),
    Ptr = realloc(Inst, 1, Len),
    ok = wasm:write_memory(Inst, Ptr, Bin),
    [Ptr, Len];
lower_flat(_Inst, D, V) when is_integer(V) orelse is_float(V) ->
    _ = D,
    [V].

-doc """
Lift the core result of a call by its descriptor.

A result that fits flat comes straight from `CoreResults`; a wider one is a single
pointer to a guest-allocated area, and is read from memory.
""".
-spec lift_result(wasm:instance(), desc(), [term()]) -> term().
lift_result(Inst, Desc, CoreResults) ->
    case flat_count(Desc) =< ?MAX_FLAT_RESULTS of
        true  -> lift_flat(Inst, Desc, CoreResults);
        false ->
            [Ptr] = CoreResults,
            load(Inst, Desc, Ptr)
    end.

lift_flat(_Inst, _Desc, [V]) -> V;
lift_flat(_Inst, _Desc, [])  -> ok.

%% Read a value of `Desc` from linear memory at `Ptr`.
load(Inst, D, Ptr) when D =:= string; D =:= {list, u8} ->
    P = read_u32(Inst, Ptr),
    Len = read_u32(Inst, Ptr + 4),
    {ok, Bin} = wasm:read_memory(Inst, P, Len),
    Bin;
load(Inst, {result, OkD, ErrD}, Ptr) ->
    Disc = read_u8(Inst, Ptr),
    {_, PayAlign} = payload_size_align(OkD, ErrD),
    Off = align_up(1, PayAlign),
    case Disc of
        0 -> {ok, case_value(Inst, OkD, Ptr + Off)};
        1 -> {error, case_value(Inst, ErrD, Ptr + Off)}
    end;
load(Inst, u8, Ptr)  -> read_u8(Inst, Ptr);
load(Inst, u32, Ptr) -> read_u32(Inst, Ptr).

case_value(_Inst, none, _Ptr) -> undefined;
case_value(Inst, D, Ptr)      -> load(Inst, D, Ptr).

-doc "The size and alignment, in bytes, of a value laid out in memory.".
-spec size_align(desc()) -> {non_neg_integer(), pos_integer()}.
size_align(none)                    -> {0, 1};
size_align(D) when D =:= u8; D =:= s8; D =:= bool -> {1, 1};
size_align(D) when D =:= u16; D =:= s16 -> {2, 2};
size_align(D) when D =:= u32; D =:= s32; D =:= f32; D =:= char -> {4, 4};
size_align(D) when D =:= u64; D =:= s64; D =:= f64 -> {8, 8};
size_align(string)      -> {8, 4};
size_align({list, _})   -> {8, 4};
size_align({result, OkD, ErrD}) ->
    {PaySize, PayAlign} = payload_size_align(OkD, ErrD),
    Off = align_up(1, PayAlign),
    {Off + PaySize, PayAlign}.

payload_size_align(OkD, ErrD) ->
    {OkS, OkA} = size_align(OkD),
    {ErrS, ErrA} = size_align(ErrD),
    {max(OkS, ErrS), max(1, max(OkA, ErrA))}.

%% How many flat core values a descriptor lowers to (results only need the small
%% cases; anything that goes through memory just has to exceed the flat limit).
flat_count(none)            -> 0;
flat_count(string)          -> 2;
flat_count({list, _})       -> 2;
flat_count({result, _, _})  -> 2;
flat_count(_Primitive)      -> 1.

align_up(N, A) -> ((N + A - 1) div A) * A.

realloc(Inst, Align, Size) ->
    {ok, [Ptr]} = wasm:call(Inst, <<"cabi_realloc">>, [0, 0, Align, Size]),
    Ptr.

read_u8(Inst, Ptr) ->
    {ok, <<B>>} = wasm:read_memory(Inst, Ptr, 1),
    B.

read_u32(Inst, Ptr) ->
    {ok, <<V:32/little>>} = wasm:read_memory(Inst, Ptr, 4),
    V.
