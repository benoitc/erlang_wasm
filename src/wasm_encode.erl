-module(wasm_encode).
-moduledoc """
WebAssembly binary format encoder: a `#module{}` back to bytes.

Read this when you need a module's bytes, or when you change what bytes a
module gives. It is the decoder run backwards: `wasm_decode` reads the binary
format into the `#module{}` in `include/wasm.hrl`, and this writes that record
out again. `wasm:encode/1` is the supported way to call it.

## One encoding per module

The bytes are an identity. `wasm:load/1` names a module by the SHA-256 of
its bytes, and an embedder may store a module under that digest. So the same
`#module{}` always gives the same bytes, and the rules below are fixed. A
change to any of them changes the digest of modules that are already stored,
which is a breaking change: it needs a changelog entry and an Upgrading note.
`wasm_encode_SUITE` holds golden vectors that fail when the output moves.

Where the binary format has more than one encoding for the same thing, this
writes the one that decodes back to the same record:

- **Sections** in the specification's order: type, import, function, table,
  memory, tag, global, export, start, element, data count, code, data. A
  section with nothing in it is left out.
- **Custom sections** after the last known section, in the record's order.
  The decoder does not keep where a custom section stood among the others,
  so its position cannot be given back.
- **LEB128** in its shortest form everywhere.
- **Data count** written exactly when `data_count` is set.
- **Types**: a recursive group of one type is written as that type alone,
  since the decoder reads both the same; any other group, the empty one
  included, as `rec`. A final type with no supertypes is written bare, one
  with supertypes with `sub final`, and a non-final type with `sub`. Type
  indices, groups and the order of every index space are kept as the record
  holds them, never renumbered or merged.
- **Reference types**: a nullable abstract type in its one-byte short form
  (`funcref` is `0x70`), a nullable type index as `0x63`, a non-nullable type
  as `0x64`.
- **Limits**: the flags byte has a bit for a maximum, for `shared` and for a
  64-bit index, and nothing else.
- **Tables**: the plain form when the table has no initialiser, the `0x40 0x00`
  form when it has one.
- **Element segments**: a segment of type `(ref func)` whose every element is
  a single `ref.func` is written with function indices, in the form for its
  mode (`0` for table 0, `2` for another table, `1` passive, `3`
  declarative). Every other segment is written with expressions: form `4`
  for a `funcref` segment on table 0, otherwise form `6` (active, with its
  table and type), `5` passive or `7` declarative. The decoder reads the
  index forms as `(ref func)` and form `4` as `funcref`, which is why the type
  decides.
- **Data segments**: form `0` for memory 0, form `2` for another memory,
  form `1` passive.
- **Locals** in runs of equal consecutive types, each run as long as it goes.
- **Instructions**: see `wasm_encode_code`. A memory argument names its
  memory only when it is not memory 0, and an `if` writes `else` only when the
  else branch has instructions.

A module built from WAT keeps no `name` section: its identifiers are not
written, so its bytes do not depend on what its author called things.

## What cannot be encoded

A record that has no binary form is an error value, `{error, #{class =>
invalid, kind => unencodable}}`, with the field and the value in its context:
an index or a constant out of the range of its encoding, a name that is not
UTF-8, rec groups that do not cover the types, an instruction this runtime
does not know. So is a record whose bytes the decoder would refuse: a data
count that does not match the data segments, or `memory.init` or `data.drop`
in a module without a data count. A record whose fields do not even have
the types `include/wasm.hrl` gives them is an error value too, an internal
one, since there is nothing to say about it but where it stopped. Nothing
raises.

## Where things are

| you want | look at |
| --- | --- |
| the entry point and the section order | `module/1`, `sections/1` |
| types and recursive groups | `%%% types` |
| element and data segments | `%%% segments` |
| function bodies and locals | `code/1` |
| the integer encodings and their range checks | `%%% integers` |
| instructions | `wasm_encode_code`, and `wasm_encode_simd`, `wasm_encode_gc`, `wasm_encode_atomic` for the prefixed spaces |
""".

-include("wasm.hrl").

-export([module/1, module_unchecked/1]).
-export([valtype/1, reftype/1, heaptype/1, limits/1, name/1]).
-export([u32/1, u64/1, s32/1, s33/1, s64/1, byte/1, vec/2]).
-export([unencodable/2]).

%%% ----------------------------------------------------------------- api ---

-doc """
Encode a module. Takes a body as decoded or as validated: the validator's
annotations are stripped first.
""".
-spec module(#module{}) -> {ok, binary()} | {error, wasm_error:error()}.
module(M) ->
    wasm_error:capture(fun() -> {ok, module_unchecked(M)} end).

-doc "Encode, letting the internal throw escape. For use inside a `capture`.".
-spec module_unchecked(#module{}) -> binary().
module_unchecked(#module{} = M) ->
    iolist_to_binary([<<"\0asm", 1:32/little>> | sections(M)]);
module_unchecked(Other) ->
    unencodable(module, Other).

%%% ------------------------------------------------------------- sections ---

%% The specification's order. The data count section has id 12 and the tag
%% section id 13, but they sit where the format places them, not by id.
sections(#module{} = M) ->
    check_data_count(M),
    [section(?SEC_TYPE, type_groups(M), fun rectype/1),
     section(?SEC_IMPORT, M#module.imports, fun import/1),
     section(?SEC_FUNCTION, M#module.funcs, fun(#func{type = T}) -> u32(T);
                                               (F) -> unencodable(func, F)
                                            end),
     section(?SEC_TABLE, M#module.tables, fun tabletype/1),
     section(?SEC_MEMORY, M#module.mems, fun memtype/1),
     section(?SEC_TAG, M#module.tags, fun tagtype/1),
     section(?SEC_GLOBAL, M#module.globals, fun global/1),
     section(?SEC_EXPORT, M#module.exports, fun export/1),
     start(M#module.start),
     section(?SEC_ELEMENT, M#module.elems, fun elem/1),
     data_count(M#module.data_count),
     section(?SEC_CODE, M#module.funcs, fun code/1),
     section(?SEC_DATA, M#module.datas, fun data/1)
     | customs(M#module.customs)].

%% A vector section with nothing in it is left out.
section(_Id, [], _Fun) -> [];
section(Id, L, Fun) -> section(Id, vec(L, Fun)).

%% A one-byte content is a bare integer, which is iodata only inside a list.
section(Id, Content) -> [Id, u32(iolist_size([Content])), Content].

start(undefined) -> [];
start(F) -> section(?SEC_START, u32(F)).

data_count(undefined) -> [];
data_count(N) -> section(?SEC_DATACOUNT, u32(N)).

customs(Cs) ->
    [custom(C) || C <- Cs].

custom({Name, Payload}) ->
    Content = [name(Name), Payload],
    [?SEC_CUSTOM, u32(iolist_size(Content)), Content].

%% The decoder refuses both of these, so writing them would give bytes that
%% are not a module.
check_data_count(#module{data_count = undefined, funcs = Funcs}) ->
    case lists:any(fun(#func{body = B}) -> uses_data_index(body(B));
                      (_) -> false
                   end, Funcs) of
        false -> ok;
        true -> unencodable(data_count, undefined,
                            #{reason => data_count_required})
    end;
check_data_count(#module{data_count = N, datas = Datas})
  when is_list(Datas), N =:= length(Datas) ->
    ok;
check_data_count(#module{data_count = N, datas = Datas}) ->
    unencodable(data_count, N, #{reason => data_count_mismatch,
                                 datas => length(Datas)}).

uses_data_index([{memory_init, _, _} | _]) -> true;
uses_data_index([{data_drop, _} | _]) -> true;
uses_data_index([{block, _, Body} | Rest]) ->
    uses_data_index(Body) orelse uses_data_index(Rest);
uses_data_index([{loop, _, Body} | Rest]) ->
    uses_data_index(Body) orelse uses_data_index(Rest);
uses_data_index([{if_, _, Then, Else} | Rest]) ->
    uses_data_index(Then) orelse uses_data_index(Else)
        orelse uses_data_index(Rest);
uses_data_index([{try_table, _, _, Body} | Rest]) ->
    uses_data_index(Body) orelse uses_data_index(Rest);
uses_data_index([_ | Rest]) -> uses_data_index(Rest);
uses_data_index(_) -> false.

%%% ---------------------------------------------------------------- types ---

%% `rec_groups' names the groups by `{First, Count}' over the flat type list.
%% A record built by hand often leaves it empty, which means every type is a
%% group of its own; anything else must cover the types exactly, in order.
type_groups(#module{types = Types, rec_groups = []}) when is_list(Types) ->
    [[T] || T <- Types];
type_groups(#module{types = Types, rec_groups = Groups})
  when is_list(Types), is_list(Groups) ->
    split_groups(Groups, 0, Types);
type_groups(#module{types = Types}) ->
    unencodable(types, Types).

split_groups([], _Next, []) ->
    [];
split_groups([{Next, Count} | Groups], Next, Types)
  when is_integer(Count), Count >= 0, Count =< length(Types) ->
    {Group, Rest} = lists:split(Count, Types),
    [Group | split_groups(Groups, Next + Count, Rest)];
split_groups(Groups, Next, Types) ->
    unencodable(rec_groups, Groups, #{next_type => Next,
                                      types_left => length(Types)}).

rectype([T]) -> subtype(T);
rectype(Group) -> [16#4E | vec(Group, fun subtype/1)].

subtype(#subtype{final = true, supers = [], body = CT}) ->
    comptype(CT);
subtype(#subtype{final = true, supers = Supers, body = CT}) ->
    [16#4F, vec(Supers, fun u32/1), comptype(CT)];
subtype(#subtype{final = false, supers = Supers, body = CT}) ->
    [16#50, vec(Supers, fun u32/1), comptype(CT)];
subtype(T) ->
    unencodable(subtype, T).

comptype(#functype{params = Ps, results = Rs}) ->
    [16#60, vec(Ps, fun valtype/1), vec(Rs, fun valtype/1)];
comptype(#structtype{fields = Fs}) ->
    [16#5F | vec(Fs, fun fieldtype/1)];
comptype(#arraytype{field = F}) ->
    [16#5E | fieldtype(F)].

fieldtype(#fieldtype{type = T, mut = Mut}) ->
    [storagetype(T), mut(Mut)];
fieldtype(F) ->
    unencodable(fieldtype, F).

storagetype(i8) -> 16#78;
storagetype(i16) -> 16#77;
storagetype(T) -> valtype(T).

mut(const) -> 16#00;
mut(var) -> 16#01.

-doc "A value type. A reference type takes the shortest form that reads back the same.".
-spec valtype(valtype()) -> iodata() | byte().
valtype(i32) -> 16#7F;
valtype(i64) -> 16#7E;
valtype(f32) -> 16#7D;
valtype(f64) -> 16#7C;
valtype(v128) -> 16#7B;
valtype({ref, _, _} = RT) -> reftype(RT);
valtype(T) -> unencodable(valtype, T).

-spec reftype(reftype()) -> iodata() | byte().
reftype({ref, null, {type, _} = HT}) -> [16#63, heaptype(HT)];
reftype({ref, null, HT}) -> heaptype(HT);
reftype({ref, nonull, HT}) -> [16#64, heaptype(HT)];
reftype(RT) -> unencodable(reftype, RT).

%% An abstract heap type is a negative `s33' that fits one byte, and that
%% byte is also the short form of the nullable reference to it.
-spec heaptype(heaptype()) -> iodata() | byte().
heaptype(func) -> 16#70;
heaptype(extern) -> 16#6F;
heaptype(any) -> 16#6E;
heaptype(eq) -> 16#6D;
heaptype(i31) -> 16#6C;
heaptype(struct) -> 16#6B;
heaptype(array) -> 16#6A;
heaptype(exn) -> 16#69;
heaptype(noexn) -> 16#74;
heaptype(nofunc) -> 16#73;
heaptype(noextern) -> 16#72;
heaptype(none) -> 16#71;
heaptype({type, N}) when is_integer(N), N >= 0, N =< 16#FFFFFFFF -> s33(N);
heaptype(HT) -> unencodable(heaptype, HT).

-spec limits(#limits{}) -> iodata().
limits(#limits{min = Min, max = Max, shared = Shared, index_type = IT})
  when is_boolean(Shared), (IT =:= i32 orelse IT =:= i64) ->
    Flags = (case Max of undefined -> 0; _ -> 1 end)
        bor (case Shared of true -> 2; false -> 0 end)
        bor (case IT of i64 -> 4; i32 -> 0 end),
    case Max of
        undefined -> [Flags, u64(Min)];
        _ -> [Flags, u64(Min), u64(Max)]
    end;
limits(L) ->
    unencodable(limits, L).

tabletype(#tabletype{limits = L, elemtype = RT, init = undefined}) ->
    [reftype(RT), limits(L)];
tabletype(#tabletype{limits = L, elemtype = RT, init = Init}) ->
    [16#40, 16#00, reftype(RT), limits(L), expr(Init)];
tabletype(T) ->
    unencodable(tabletype, T).

memtype(#memtype{limits = L}) -> limits(L);
memtype(T) -> unencodable(memtype, T).

%% The leading byte is the tag's attribute: `0x00', an exception, is the only
%% one defined.
tagtype(#tagtype{type = T}) -> [16#00, u32(T)];
tagtype(T) -> unencodable(tagtype, T).

globaltype(#globaltype{valtype = VT, mut = Mut}) -> [valtype(VT), mut(Mut)].

%%% ------------------------------------------------------------ structure ---

import(#import{module = Mod, name = Nm, desc = Desc}) ->
    [name(Mod), name(Nm), importdesc(Desc)];
import(I) ->
    unencodable(import, I).

importdesc({func, T}) -> [16#00, u32(T)];
importdesc({table, T}) -> [16#01, tabletype(T)];
importdesc({mem, T}) -> [16#02, memtype(T)];
importdesc({global, T}) -> [16#03, globaltype(T)];
importdesc({tag, T}) -> [16#04, tagtype(T)].

export(#export{name = Nm, desc = {Kind, Idx}}) ->
    [name(Nm), exportkind(Kind), u32(Idx)];
export(E) ->
    unencodable(export, E).

exportkind(func) -> 16#00;
exportkind(table) -> 16#01;
exportkind(mem) -> 16#02;
exportkind(global) -> 16#03;
exportkind(tag) -> 16#04.

global(#global{type = T, init = Init}) -> [globaltype(T), expr(Init)];
global(G) -> unencodable(global, G).

%%% ------------------------------------------------------------- segments ---

%% See the module doc for which form each shape takes.
elem(#elem{type = {ref, nonull, func} = RT, init = Init, mode = Mode}) ->
    case func_indices(Init) of
        {ok, Funcs} -> elem_indices(Mode, Funcs);
        false -> elem_exprs(Mode, RT, Init)
    end;
elem(#elem{type = RT, init = Init, mode = Mode}) ->
    elem_exprs(Mode, RT, Init).

func_indices(Init) -> func_indices(Init, []).

func_indices([], Acc) -> {ok, lists:reverse(Acc)};
func_indices([[{ref_func, F}] | Rest], Acc) -> func_indices(Rest, [F | Acc]);
func_indices(_, _) -> false.

elem_indices({active, 0, Offset}, Funcs) ->
    [0, expr(Offset), vec(Funcs, fun u32/1)];
elem_indices(passive, Funcs) ->
    [1, 16#00, vec(Funcs, fun u32/1)];
elem_indices({active, T, Offset}, Funcs) ->
    [2, u32(T), expr(Offset), 16#00, vec(Funcs, fun u32/1)];
elem_indices(declarative, Funcs) ->
    [3, 16#00, vec(Funcs, fun u32/1)].

elem_exprs({active, 0, Offset}, ?FUNCREF, Init) ->
    [4, expr(Offset), vec(Init, fun expr/1)];
elem_exprs(passive, RT, Init) ->
    [5, reftype(RT), vec(Init, fun expr/1)];
elem_exprs({active, T, Offset}, RT, Init) ->
    [6, u32(T), expr(Offset), reftype(RT), vec(Init, fun expr/1)];
elem_exprs(declarative, RT, Init) ->
    [7, reftype(RT), vec(Init, fun expr/1)].

data(#data{init = Bytes, mode = {active, 0, Offset}}) when is_binary(Bytes) ->
    [0, expr(Offset), bytes(Bytes)];
data(#data{init = Bytes, mode = passive}) when is_binary(Bytes) ->
    [1, bytes(Bytes)];
data(#data{init = Bytes, mode = {active, M, Offset}}) when is_binary(Bytes) ->
    [2, u32(M), expr(Offset), bytes(Bytes)];
data(D) ->
    unencodable(data, D).

%% A body is its size, then its locals and its expression. The size is the
%% only reason a body is built apart from the rest of the section.
code(#func{locals = Locals, body = Body}) when is_list(Locals) ->
    Content = [vec(runs(Locals), fun({N, VT}) -> [u32(N), valtype(VT)] end),
               expr(body(Body))],
    [u32(iolist_size(Content)), Content];
code(F) ->
    unencodable(func, F).

%% A validated body carries the operand-stack heights; the bytes do not.
body({validated, _} = B) -> wasm_validate_code:strip(B);
body(B) -> B.

%% Consecutive locals of one type, each run as long as it goes.
runs([]) -> [];
runs([T | Ts]) -> runs(Ts, T, 1).

runs([T | Ts], T, N) -> runs(Ts, T, N + 1);
runs([U | Ts], T, N) -> [{N, T} | runs(Ts, U, 1)];
runs([], T, N) -> [{N, T}].

expr(Is) -> wasm_encode_code:expr(Is).

%%% ------------------------------------------------------------- integers ---

%% The value is written straight into the iolist when it fits one byte, as
%% most indices and lengths do, so the common case builds no binary.
-doc "An unsigned 32-bit LEB128.".
-spec u32(non_neg_integer()) -> iodata() | byte().
u32(V) when is_integer(V), V >= 0, V < 128 -> V;
u32(V) when is_integer(V), V >= 0, V =< 16#FFFFFFFF -> wasm_leb128:encode_u32(V);
u32(V) -> unencodable(u32, V).

-doc "An unsigned 64-bit LEB128, for limits and memory offsets.".
-spec u64(non_neg_integer()) -> iodata() | byte().
u64(V) when is_integer(V), V >= 0, V < 128 -> V;
u64(V) when is_integer(V), V >= 0, V =< 16#FFFFFFFFFFFFFFFF ->
    wasm_leb128:encode_u64(V);
u64(V) -> unencodable(u64, V).

-doc "A signed 32-bit LEB128.".
-spec s32(integer()) -> iodata() | byte().
s32(V) when is_integer(V), V >= 0, V < 64 -> V;
s32(V) when is_integer(V), V < 0, V >= -64 -> V + 128;
s32(V) when is_integer(V), V >= -16#80000000, V =< 16#7FFFFFFF ->
    wasm_leb128:encode_s32(V);
s32(V) -> unencodable(s32, V).

-doc "A signed 33-bit LEB128: a type index where a block or heap type is expected.".
-spec s33(integer()) -> iodata() | byte().
s33(V) when is_integer(V), V >= 0, V < 64 -> V;
s33(V) when is_integer(V), V >= -16#100000000, V =< 16#FFFFFFFF ->
    wasm_leb128:encode_s33(V);
s33(V) -> unencodable(s33, V).

-doc "A signed 64-bit LEB128.".
-spec s64(integer()) -> iodata() | byte().
s64(V) when is_integer(V), V >= 0, V < 64 -> V;
s64(V) when is_integer(V), V < 0, V >= -64 -> V + 128;
s64(V) when is_integer(V), V >= -16#8000000000000000, V =< 16#7FFFFFFFFFFFFFFF ->
    wasm_leb128:encode_s64(V);
s64(V) -> unencodable(s64, V).

-doc "One raw byte, such as a SIMD lane index.".
-spec byte(byte()) -> byte().
byte(V) when is_integer(V), V >= 0, V =< 255 -> V;
byte(V) -> unencodable(byte, V).

%%% -------------------------------------------------------------- helpers ---

-doc "A length-prefixed UTF-8 name, refused if it is not UTF-8.".
-spec name(binary()) -> iodata().
name(N) when is_binary(N) ->
    case unicode:characters_to_binary(N, utf8, utf8) of
        N -> [u32(byte_size(N)), N];
        _ -> unencodable(name, N, #{reason => not_utf8})
    end;
name(N) ->
    unencodable(name, N).

bytes(B) -> [u32(byte_size(B)), B].

-doc "A vector: its length, then each element as `Fun` writes it.".
-spec vec(list(), fun((term()) -> iodata() | byte())) -> iodata().
vec(L, Fun) when is_list(L) -> [u32(length(L)) | [Fun(X) || X <- L]];
vec(L, _Fun) -> unencodable(vector, L).

-doc """
Raise the encoder's error for a field whose value has no binary form.
`wasm_encode_code` and the prefixed-space encoders use it too.
""".
-spec unencodable(atom(), term()) -> no_return().
unencodable(What, Value) ->
    unencodable(What, Value, #{}).

unencodable(What, Value, Ctx) ->
    wasm_error:invalid(unencodable, <<"no binary encoding">>,
                       Ctx#{field => What, value => Value}).
