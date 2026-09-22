-module(wasm_canon).
-moduledoc """
Internal: the Canonical ABI lift/lower for component-model values.

The Canonical ABI is how a component-model value crosses between the host and a
core module's linear memory. `lower_params/3` turns Erlang terms into the flat
core arguments an exported function takes; `lift_result/3` turns the core result
back into an Erlang term. Small values travel in registers ("flat"); aggregates
and anything a `list`/`string` points at travel through guest memory, placed with
the guest's `cabi_realloc`.

Value types and their Erlang shapes:

| descriptor | Erlang |
| --- | --- |
| `u8`..`u64`, `s8`..`s64`, `char` | integer |
| `f32`, `f64` | float |
| `bool` | `true` / `false` |
| `string`, `{list, u8}` | binary (UTF-8 for a string) |
| `{list, D}` | list of `D` |
| `{record, [{Name, D}]}` | `#{Name => value}` |
| `{tuple, [D]}` | tuple |
| `{enum, [Name]}` | the name binary |
| `{variant, [{Name, D | none}]}` | `{Name, Payload}` (`undefined` when none) |
| `{option, D}` | `none` / `{some, value}` |
| `{result, Ok, Err}` | `{ok, value}` / `{error, value}` |
| `{flags, [Name]}` | list of the set name binaries |
| `handle` | integer (a resource `own`/`borrow`, an opaque i32) |

Names in records, variants, enums and flags come from the type descriptor the
host holds, not from guest bytes. Not yet: resources, and a parameter list that
flattens past `MAX_FLAT_PARAMS` (spilled to memory) -- neither is reached by the
current fixtures.
""".

-export([lower_params/3, lift_result/3, size_align/1, flat_types/1]).
-export([lift_params/3, lower_value/3, store_value/4, result_via_memory/1]).

-export_type([desc/0]).

-type name() :: binary().
-type desc() :: u8 | u16 | u32 | u64 | s8 | s16 | s32 | s64
              | f32 | f64 | bool | char | string
              | {list, desc()}
              | {record, [{name(), desc()}]}
              | {tuple, [desc()]}
              | {enum, [name()]}
              | {variant, [{name(), desc() | none}]}
              | {option, desc()}
              | {result, desc() | none, desc() | none}
              | {flags, [name()]}
              | handle.

-define(MAX_FLAT_RESULTS, 1).

%%% -------------------------------------------------------------- params ---

-doc "Lower each parameter to the flat core values its function takes.".
-spec lower_params(wasm:instance(), [desc()], [term()]) -> [term()].
lower_params(Inst, Descs, Args) ->
    lists:append(lists:zipwith(fun(D, A) -> lower_flat(Inst, D, A) end,
                               Descs, Args)).

%% Lower one value to its flat core representation. Aggregates concatenate; a
%% `list`/`string` is placed in memory and becomes `(ptr, len)`; a variant is a
%% discriminant followed by its payload coerced into the joined slots.
lower_flat(_Inst, D, V) when D =:= u8; D =:= u16; D =:= u32;
                             D =:= s8; D =:= s16; D =:= s32; D =:= char ->
    [V band 16#FFFFFFFF];
lower_flat(_Inst, D, V) when D =:= u64; D =:= s64 ->
    [V band 16#FFFFFFFFFFFFFFFF];
%% A resource handle (own or borrow) is an i32 the runtime treats as opaque.
lower_flat(_Inst, handle, V) -> [V band 16#FFFFFFFF];
lower_flat(_Inst, bool, V) -> [bool_int(V)];
lower_flat(_Inst, f32, V)  -> [V];
lower_flat(_Inst, f64, V)  -> [V];
lower_flat(Inst, D, Bin) when D =:= string; D =:= {list, u8} ->
    {Ptr, Len} = place_bytes(Inst, Bin),
    [Ptr, Len];
lower_flat(Inst, {list, ElemD}, List) ->
    {Ptr, Len} = place_list(Inst, ElemD, List),
    [Ptr, Len];
lower_flat(Inst, {record, Fields}, Map) ->
    lists:append([lower_flat(Inst, FD, maps:get(N, Map)) || {N, FD} <- Fields]);
lower_flat(Inst, {tuple, Ds}, Tuple) ->
    lists:append([lower_flat(Inst, D, element(I, Tuple))
                  || {D, I} <- lists:zip(Ds, lists:seq(1, length(Ds)))]);
lower_flat(_Inst, {enum, Names}, Name) ->
    [index_of(Name, Names)];
lower_flat(_Inst, {flags, Names}, Set) ->
    [flags_bits(Names, Set)];
lower_flat(Inst, {option, D}, Opt) ->
    lower_variant(Inst, opt_cases(D), opt_to_variant(Opt));
lower_flat(Inst, {result, OkD, ErrD}, R) ->
    lower_variant(Inst, [{ok, OkD}, {error, ErrD}], result_to_variant(R));
lower_flat(Inst, {variant, Cases}, {Name, Payload}) ->
    lower_variant(Inst, Cases, {Name, Payload}).

%% Discriminant, then the selected case's payload coerced into the joined slots.
lower_variant(Inst, Cases, {Name, Payload}) ->
    Disc = index_of(Name, [N || {N, _} <- Cases]),
    {_, CaseD} = lists:nth(Disc + 1, Cases),
    Joined = join_cases(Cases),
    {PayFlat, PayTypes} =
        case CaseD of
            none -> {[], []};
            _    -> {lower_flat(Inst, CaseD, Payload), flat_types(CaseD)}
        end,
    [Disc | coerce_join(PayFlat, PayTypes, Joined)].

%% Widen each payload value into its joined slot (a wider or reinterpreted core
%% type), and pad the slots the shorter cases do not fill with zero.
coerce_join(_Vals, _Types, []) -> [];
coerce_join([], [], [_Slot | Slots]) -> [0 | coerce_join([], [], Slots)];
coerce_join([V | Vs], [T | Ts], [Slot | Slots]) ->
    [coerce(V, T, Slot) | coerce_join(Vs, Ts, Slots)].

coerce(V, T, T)     -> V;
coerce(V, f32, i32) -> <<I:32>> = <<V:32/float>>, I;
coerce(V, f64, i64) -> <<I:64>> = <<V:64/float>>, I;
coerce(V, f32, i64) -> <<I:32>> = <<V:32/float>>, I;
coerce(V, i32, i64) -> V band 16#FFFFFFFF;
coerce(V, f64, _)   -> <<I:64>> = <<V:64/float>>, I;
coerce(V, _T, _S)   -> V.

%%% ------------------------------------------------------------- results ---

-doc """
Lift the core result of a call by its descriptor.

A result that fits flat comes straight from `CoreResults`; a wider one is a single
pointer to a guest-allocated area, read from memory.
""".
-spec lift_result(wasm:instance(), desc(), [term()]) -> term().
lift_result(Inst, Desc, CoreResults) ->
    case length(flat_types(Desc)) =< ?MAX_FLAT_RESULTS of
        %% lift_value decodes any descriptor from flats, including a single-flat
        %% aggregate such as `result<_, _>` (just a discriminant), which lift_flat
        %% alone does not.
        true  -> {Value, _Rest} = lift_value(Inst, Desc, CoreResults), Value;
        false -> [Ptr] = CoreResults, load(Inst, Desc, Ptr)
    end.

%% Only single-flat values are lifted from registers: the primitives and an enum
%% (just a discriminant). Everything wider came back through memory.
lift_flat(_Inst, handle, [V]) -> V band 16#FFFFFFFF;
lift_flat(_Inst, D, [V]) when D =:= u8; D =:= u16; D =:= u32 -> V;
%% A signed value under 32 bits is a full sign-extended i32 flat, so interpret the
%% 32-bit value (it then already sits in the narrower range); `V' may arrive
%% signed or unsigned, so mask first.
lift_flat(_Inst, D, [V]) when D =:= s8; D =:= s16; D =:= s32 ->
    from_signed(V band 16#FFFFFFFF, 32);
lift_flat(_Inst, u64, [V]) -> V band 16#FFFFFFFFFFFFFFFF;
lift_flat(_Inst, s64, [V]) -> from_signed(V band 16#FFFFFFFFFFFFFFFF, 64);
lift_flat(_Inst, char, [V]) -> V;
lift_flat(_Inst, bool, [V]) -> V =/= 0;
lift_flat(_Inst, f32, [V]) -> V;
lift_flat(_Inst, f64, [V]) -> V.

%%% -------------------------------------------------- host imports (reverse) ---

-doc """
Lift the flat core arguments a guest passed into an imported function.

The inverse of `lower_params/3`: for each parameter descriptor it consumes the
flat values the guest lowered and returns the Erlang term. Any flat values left
over -- a return-area pointer the guest passes for a by-memory result -- are
returned as the second element.
""".
-spec lift_params(wasm:instance(), [desc()], [term()]) -> {[term()], [term()]}.
lift_params(Inst, Descs, Flats) ->
    {Rev, Rest} = lists:foldl(
                    fun(D, {Acc, F0}) ->
                        {V, F1} = lift_value(Inst, D, F0),
                        {[V | Acc], F1}
                    end, {[], Flats}, Descs),
    {lists:reverse(Rev), Rest}.

-doc "Lower one value to its flat core representation (`lower_flat`, exported).".
-spec lower_value(wasm:instance(), desc(), term()) -> [term()].
lower_value(Inst, Desc, Term) -> lower_flat(Inst, Desc, Term).

-doc "Write a value into linear memory at `Ptr` (`store`, exported).".
-spec store_value(wasm:instance(), desc(), non_neg_integer(), term()) -> ok.
store_value(Inst, Desc, Ptr, Term) -> store(Inst, Desc, Ptr, Term).

-doc "Whether a result is returned through memory rather than flat.".
-spec result_via_memory(desc()) -> boolean().
result_via_memory(Desc) -> length(flat_types(Desc)) > ?MAX_FLAT_RESULTS.

%% Lift one value from the head of the flat list, returning it and the rest.
lift_value(Inst, D, [V | R]) when D =:= u8; D =:= u16; D =:= u32;
                                  D =:= s8; D =:= s16; D =:= s32;
                                  D =:= u64; D =:= s64; D =:= char; D =:= bool;
                                  D =:= f32; D =:= f64; D =:= handle ->
    {lift_flat(Inst, D, [V]), R};
lift_value(Inst, D, [Ptr, Len | R]) when D =:= string; D =:= {list, u8} ->
    {ok, Bin} = wasm:read_memory(Inst, Ptr, Len),
    {Bin, R};
lift_value(Inst, {list, ElemD}, [Ptr, Len | R]) ->
    {ESize, _} = size_align(ElemD),
    {[load(Inst, ElemD, Ptr + I * ESize) || I <- lists:seq(0, Len - 1)], R};
lift_value(Inst, {record, Fields}, Flats) ->
    {Map, Rest} = lists:foldl(
                    fun({N, FD}, {Acc, F0}) ->
                        {V, F1} = lift_value(Inst, FD, F0),
                        {Acc#{N => V}, F1}
                    end, {#{}, Flats}, Fields),
    {Map, Rest};
lift_value(Inst, {tuple, Ds}, Flats) ->
    {Vals, Rest} = lists:foldl(
                     fun(FD, {Acc, F0}) ->
                         {V, F1} = lift_value(Inst, FD, F0),
                         {[V | Acc], F1}
                     end, {[], Flats}, Ds),
    {list_to_tuple(lists:reverse(Vals)), Rest};
lift_value(_Inst, {enum, Names}, [Disc | R]) ->
    {lists:nth(Disc + 1, Names), R};
lift_value(_Inst, {flags, Names}, Flats) ->
    {Words, R} = lists:split((length(Names) + 31) div 32, Flats),
    Bits = lists:foldl(fun(W, {Acc, Shift}) -> {Acc bor (W bsl Shift), Shift + 32} end,
                       {0, 0}, Words),
    {bits_flags(Names, element(1, Bits)), R};
lift_value(Inst, {option, D}, Flats) ->
    case lift_variant(Inst, opt_cases(D), Flats) of
        {0, _, R} -> {none, R};
        {1, V, R} -> {{some, V}, R}
    end;
lift_value(Inst, {result, OkD, ErrD}, Flats) ->
    case lift_variant(Inst, [{ok, OkD}, {error, ErrD}], Flats) of
        {0, V, R} -> {{ok, V}, R};
        {1, V, R} -> {{error, V}, R}
    end;
lift_value(Inst, {variant, Cases}, Flats) ->
    {Disc, V, R} = lift_variant(Inst, Cases, Flats),
    {Name, _} = lists:nth(Disc + 1, Cases),
    {{Name, V}, R}.

%% A discriminant, then the payload read out of the joined slots and un-coerced
%% back from the wider slot type. The slots the shorter cases did not use are
%% padding and skipped.
lift_variant(Inst, Cases, [Disc | Rest0]) ->
    Joined = join_cases(Cases),
    {SlotVals, Rest1} = lists:split(length(Joined), Rest0),
    {_, CaseD} = lists:nth(Disc + 1, Cases),
    V = case CaseD of
            none -> undefined;
            _ ->
                PayTypes = flat_types(CaseD),
                Flats = uncoerce(PayTypes, Joined, SlotVals),
                element(1, lift_value(Inst, CaseD, Flats))
        end,
    {Disc, V, Rest1}.

uncoerce([], _Joined, _Slots) -> [];
uncoerce([T | Ts], [S | Ss], [V | Vs]) ->
    [uncoerce_one(V, S, T) | uncoerce(Ts, Ss, Vs)].

uncoerce_one(V, T, T)     -> V;
uncoerce_one(V, i32, f32) -> <<F:32/float>> = <<V:32>>, F;
uncoerce_one(V, i64, f64) -> <<F:64/float>> = <<V:64>>, F;
uncoerce_one(V, i64, f32) -> <<F:32/float>> = <<(V band 16#FFFFFFFF):32>>, F;
uncoerce_one(V, i64, i32) -> V band 16#FFFFFFFF;
uncoerce_one(V, _S, _T)   -> V.

%%% -------------------------------------------------------------- memory ---

%% Read a value of `Desc` from linear memory at `Ptr`.
load(Inst, u8, Ptr)  -> read_int(Inst, Ptr, 1, unsigned);
load(Inst, u16, Ptr) -> read_int(Inst, Ptr, 2, unsigned);
load(Inst, u32, Ptr) -> read_int(Inst, Ptr, 4, unsigned);
load(Inst, handle, Ptr) -> read_int(Inst, Ptr, 4, unsigned);
load(Inst, u64, Ptr) -> read_int(Inst, Ptr, 8, unsigned);
load(Inst, s8, Ptr)  -> read_int(Inst, Ptr, 1, signed);
load(Inst, s16, Ptr) -> read_int(Inst, Ptr, 2, signed);
load(Inst, s32, Ptr) -> read_int(Inst, Ptr, 4, signed);
load(Inst, s64, Ptr) -> read_int(Inst, Ptr, 8, signed);
load(Inst, char, Ptr) -> read_int(Inst, Ptr, 4, unsigned);
load(Inst, bool, Ptr) -> read_int(Inst, Ptr, 1, unsigned) =/= 0;
load(Inst, f32, Ptr) ->
    {ok, <<V:32/float-little>>} = wasm:read_memory(Inst, Ptr, 4), V;
load(Inst, f64, Ptr) ->
    {ok, <<V:64/float-little>>} = wasm:read_memory(Inst, Ptr, 8), V;
load(Inst, D, Ptr) when D =:= string; D =:= {list, u8} ->
    {P, Len} = read_ptr_len(Inst, Ptr),
    {ok, Bin} = wasm:read_memory(Inst, P, Len),
    Bin;
load(Inst, {list, ElemD}, Ptr) ->
    {P, Len} = read_ptr_len(Inst, Ptr),
    {ESize, _} = size_align(ElemD),
    [load(Inst, ElemD, P + I * ESize) || I <- lists:seq(0, Len - 1)];
load(Inst, {record, Fields}, Ptr) ->
    {Map, _} = lists:foldl(
                 fun({N, FD}, {Acc, Off0}) ->
                     {FSize, FAlign} = size_align(FD),
                     Off = align_up(Off0, FAlign),
                     {Acc#{N => load(Inst, FD, Ptr + Off)}, Off + FSize}
                 end, {#{}, 0}, Fields),
    Map;
load(Inst, {tuple, Ds}, Ptr) ->
    {Vals, _} = lists:foldl(
                  fun(FD, {Acc, Off0}) ->
                      {FSize, FAlign} = size_align(FD),
                      Off = align_up(Off0, FAlign),
                      {[load(Inst, FD, Ptr + Off) | Acc], Off + FSize}
                  end, {[], 0}, Ds),
    list_to_tuple(lists:reverse(Vals));
load(Inst, {enum, Names}, Ptr) ->
    lists:nth(read_int(Inst, Ptr, disc_size(length(Names)), unsigned) + 1, Names);
load(Inst, {flags, Names}, Ptr) ->
    {Size, _} = size_align({flags, Names}),
    bits_flags(Names, read_int(Inst, Ptr, Size, unsigned));
load(Inst, {option, D}, Ptr) ->
    case load_variant(Inst, opt_cases(D), Ptr) of
        {0, _} -> none;
        {1, V} -> {some, V}
    end;
load(Inst, {result, OkD, ErrD}, Ptr) ->
    case load_variant(Inst, [{ok, OkD}, {error, ErrD}], Ptr) of
        {0, V} -> {ok, V};
        {1, V} -> {error, V}
    end;
load(Inst, {variant, Cases}, Ptr) ->
    {Idx, V} = load_variant(Inst, Cases, Ptr),
    {Name, _} = lists:nth(Idx + 1, Cases),
    {Name, V}.

load_variant(Inst, Cases, Ptr) ->
    Disc = read_int(Inst, Ptr, disc_size(length(Cases)), unsigned),
    {_, PayAlign} = payload_size_align(Cases),
    Off = align_up(disc_size(length(Cases)), PayAlign),
    {_Name, CaseD} = lists:nth(Disc + 1, Cases),
    V = case CaseD of
            none -> undefined;
            _    -> load(Inst, CaseD, Ptr + Off)
        end,
    {Disc, V}.

%%% --------------------------------------------------------------- layout ---

-doc "The size and alignment, in bytes, of a value laid out in memory.".
-spec size_align(desc() | none) -> {non_neg_integer(), pos_integer()}.
size_align(none)                                  -> {0, 1};
size_align(D) when D =:= u8; D =:= s8; D =:= bool -> {1, 1};
size_align(D) when D =:= u16; D =:= s16           -> {2, 2};
size_align(D) when D =:= u32; D =:= s32; D =:= f32; D =:= char -> {4, 4};
size_align(handle) -> {4, 4};
size_align(D) when D =:= u64; D =:= s64; D =:= f64 -> {8, 8};
size_align(string)    -> {8, 4};
size_align({list, _}) -> {8, 4};
size_align({record, Fields}) -> aggregate([D || {_, D} <- Fields]);
size_align({tuple, Ds})      -> aggregate(Ds);
size_align({enum, Names})    -> {disc_size(length(Names)), disc_size(length(Names))};
size_align({flags, Names})   -> flags_size_align(length(Names));
size_align({option, D})      -> variant_size_align(opt_cases(D));
size_align({result, Ok, Err}) -> variant_size_align([{ok, Ok}, {error, Err}]);
size_align({variant, Cases}) -> variant_size_align(Cases).

aggregate(Ds) ->
    {Size, Align} =
        lists:foldl(fun(D, {Off, A}) ->
                        {S, DA} = size_align(D),
                        {align_up(Off, DA) + S, max(A, DA)}
                    end, {0, 1}, Ds),
    {align_up(Size, Align), Align}.

variant_size_align(Cases) ->
    DiscS = disc_size(length(Cases)),
    {PaySize, PayAlign} = payload_size_align(Cases),
    Align = max(DiscS, PayAlign),
    {align_up(align_up(DiscS, PayAlign) + PaySize, Align), Align}.

payload_size_align(Cases) ->
    lists:foldl(fun({_, none}, Acc) -> Acc;
                   ({_, D}, {S, A}) ->
                        {DS, DA} = size_align(D),
                        {max(S, DS), max(A, DA)}
                end, {0, 1}, Cases).

flags_size_align(N) when N =< 8  -> {1, 1};
flags_size_align(N) when N =< 16 -> {2, 2};
flags_size_align(N) when N =< 32 -> {4, 4};
flags_size_align(N)              -> {4 * ((N + 31) div 32), 4}.

disc_size(N) when N =< 256   -> 1;
disc_size(N) when N =< 65536 -> 2;
disc_size(_)                 -> 4.

%%% ---------------------------------------------------------- flat types ---

-doc "The flat core value types a descriptor lowers to (`i32|i64|f32|f64`).".
-spec flat_types(desc()) -> [i32 | i64 | f32 | f64].
flat_types(D) when D =:= u8; D =:= u16; D =:= u32;
                   D =:= s8; D =:= s16; D =:= s32; D =:= char; D =:= bool -> [i32];
flat_types(handle) -> [i32];
flat_types(D) when D =:= u64; D =:= s64 -> [i64];
flat_types(f32) -> [f32];
flat_types(f64) -> [f64];
flat_types(string)    -> [i32, i32];
flat_types({list, _}) -> [i32, i32];
flat_types({record, Fields}) -> lists:append([flat_types(D) || {_, D} <- Fields]);
flat_types({tuple, Ds})      -> lists:append([flat_types(D) || D <- Ds]);
flat_types({enum, _})        -> [i32];
flat_types({flags, Names})   -> lists:duplicate((length(Names) + 31) div 32, i32);
flat_types({option, D})      -> [i32 | join_cases(opt_cases(D))];
flat_types({result, Ok, Err}) -> [i32 | join_cases([{ok, Ok}, {error, Err}])];
flat_types({variant, Cases}) -> [i32 | join_cases(Cases)].

%% The payload slots of a variant: the per-slot join of the cases' flat types.
join_cases(Cases) ->
    lists:foldl(fun({_, none}, Acc) -> Acc;
                   ({_, D}, Acc) -> join_lists(Acc, flat_types(D))
                end, [], Cases).

join_lists(A, B) -> join_lists(A, B, []).
join_lists([], [], Acc)          -> lists:reverse(Acc);
join_lists([X | Xs], [], Acc)    -> join_lists(Xs, [], [X | Acc]);
join_lists([], [Y | Ys], Acc)    -> join_lists([], Ys, [Y | Acc]);
join_lists([X | Xs], [Y | Ys], Acc) -> join_lists(Xs, Ys, [join(X, Y) | Acc]).

join(T, T)     -> T;
join(i32, f32) -> i32;
join(f32, i32) -> i32;
join(_, _)     -> i64.

%%% -------------------------------------------------------------- memory io ---

place_bytes(Inst, Bin) ->
    Len = byte_size(Bin),
    Ptr = realloc(Inst, 1, Len),
    ok = wasm:write_memory(Inst, Ptr, Bin),
    {Ptr, Len}.

place_list(Inst, ElemD, List) ->
    Len = length(List),
    {ESize, EAlign} = size_align(ElemD),
    Ptr = realloc(Inst, EAlign, Len * ESize),
    _ = [store(Inst, ElemD, Ptr + I * ESize, V)
         || {V, I} <- lists:zip(List, lists:seq(0, Len - 1))],
    {Ptr, Len}.

%% Write a value of `Desc` into linear memory at `Ptr`.
store(Inst, D, Ptr, V) when D =:= u8; D =:= s8 ->
    ok = wasm:write_memory(Inst, Ptr, <<(V band 16#FF):8>>);
store(Inst, bool, Ptr, V) ->
    ok = wasm:write_memory(Inst, Ptr, <<(bool_int(V)):8>>);
store(Inst, D, Ptr, V) when D =:= u16; D =:= s16 ->
    ok = wasm:write_memory(Inst, Ptr, <<(V band 16#FFFF):16/little>>);
store(Inst, D, Ptr, V) when D =:= u32; D =:= s32; D =:= char; D =:= handle ->
    ok = wasm:write_memory(Inst, Ptr, <<(V band 16#FFFFFFFF):32/little>>);
store(Inst, D, Ptr, V) when D =:= u64; D =:= s64 ->
    ok = wasm:write_memory(Inst, Ptr, <<(V band 16#FFFFFFFFFFFFFFFF):64/little>>);
store(Inst, f32, Ptr, V) -> ok = wasm:write_memory(Inst, Ptr, <<V:32/float-little>>);
store(Inst, f64, Ptr, V) -> ok = wasm:write_memory(Inst, Ptr, <<V:64/float-little>>);
store(Inst, D, Ptr, Bin) when D =:= string; D =:= {list, u8} ->
    {P, Len} = place_bytes(Inst, Bin),
    write_ptr_len(Inst, Ptr, P, Len);
store(Inst, {list, ElemD}, Ptr, List) ->
    {P, Len} = place_list(Inst, ElemD, List),
    write_ptr_len(Inst, Ptr, P, Len);
store(Inst, {record, Fields}, Ptr, Map) ->
    _ = lists:foldl(fun({N, FD}, Off0) ->
                        {FS, FA} = size_align(FD),
                        Off = align_up(Off0, FA),
                        ok = store(Inst, FD, Ptr + Off, maps:get(N, Map)),
                        Off + FS
                    end, 0, Fields),
    ok;
store(Inst, {tuple, Ds}, Ptr, Tuple) ->
    _ = lists:foldl(fun({FD, I}, Off0) ->
                        {FS, FA} = size_align(FD),
                        Off = align_up(Off0, FA),
                        ok = store(Inst, FD, Ptr + Off, element(I, Tuple)),
                        Off + FS
                    end, 0, lists:zip(Ds, lists:seq(1, length(Ds)))),
    ok;
store(Inst, {enum, Names}, Ptr, Name) ->
    store_int(Inst, Ptr, disc_size(length(Names)), index_of(Name, Names));
store(Inst, {flags, Names}, Ptr, Set) ->
    {Size, _} = size_align({flags, Names}),
    store_int(Inst, Ptr, Size, flags_bits(Names, Set));
store(Inst, {option, D}, Ptr, Opt) ->
    store_variant(Inst, opt_cases(D), Ptr, opt_to_variant(Opt));
store(Inst, {result, OkD, ErrD}, Ptr, R) ->
    store_variant(Inst, [{ok, OkD}, {error, ErrD}], Ptr, result_to_variant(R));
store(Inst, {variant, Cases}, Ptr, {Name, Payload}) ->
    store_variant(Inst, Cases, Ptr, {Name, Payload}).

store_variant(Inst, Cases, Ptr, {Name, Payload}) ->
    Idx = index_of(Name, [N || {N, _} <- Cases]),
    ok = store_int(Inst, Ptr, disc_size(length(Cases)), Idx),
    {_, CaseD} = lists:nth(Idx + 1, Cases),
    case CaseD of
        none -> ok;
        _ ->
            {_, PayAlign} = payload_size_align(Cases),
            Off = align_up(disc_size(length(Cases)), PayAlign),
            store(Inst, CaseD, Ptr + Off, Payload)
    end.

%%% --------------------------------------------------------------- helpers ---

bool_int(true)  -> 1;
bool_int(false) -> 0.

from_signed(V, Bits) ->
    case (V bsr (Bits - 1)) band 1 of
        1 -> V - (1 bsl Bits);
        0 -> V
    end.

opt_cases(D) -> [{<<"none">>, none}, {<<"some">>, D}].

opt_to_variant(none)      -> {<<"none">>, undefined};
opt_to_variant({some, V}) -> {<<"some">>, V}.

result_to_variant({ok, V})    -> {ok, V};
result_to_variant({error, V}) -> {error, V}.

index_of(X, L) -> index_of(X, L, 0).
index_of(X, [X | _], I) -> I;
index_of(X, [_ | T], I) -> index_of(X, T, I + 1).

flags_bits(Names, Set) ->
    lists:foldl(fun(N, Acc) ->
                    case lists:member(N, Set) of
                        true  -> Acc bor (1 bsl index_of(N, Names));
                        false -> Acc
                    end
                end, 0, Names).

bits_flags(Names, Bits) ->
    [N || N <- Names, ((Bits bsr index_of(N, Names)) band 1) =:= 1].

align_up(N, A) -> ((N + A - 1) div A) * A.

realloc(Inst, Align, Size) ->
    {ok, [Ptr]} = wasm:call(Inst, <<"cabi_realloc">>, [0, 0, Align, Size]),
    Ptr.

read_int(Inst, Ptr, Bytes, Sign) ->
    {ok, Bin} = wasm:read_memory(Inst, Ptr, Bytes),
    case Sign of
        unsigned -> binary:decode_unsigned(Bin, little);
        signed   -> from_signed(binary:decode_unsigned(Bin, little), Bytes * 8)
    end.

store_int(Inst, Ptr, Bytes, V) ->
    ok = wasm:write_memory(Inst, Ptr, <<V:(Bytes * 8)/little>>).

read_ptr_len(Inst, Ptr) ->
    {ok, <<P:32/little, Len:32/little>>} = wasm:read_memory(Inst, Ptr, 8),
    {P, Len}.

write_ptr_len(Inst, Ptr, P, Len) ->
    ok = wasm:write_memory(Inst, Ptr, <<P:32/little, Len:32/little>>).
