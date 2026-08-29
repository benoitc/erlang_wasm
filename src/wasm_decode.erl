-module(wasm_decode).
-moduledoc """
WebAssembly binary format decoder.

This is the layer that meets your input first, so read it when you are asking
what a malformed module can do. It walks the input with sub-binary matching
throughout: no section, name or
data segment is copied out of the original binary unless it has to be.

Two invariants matter more than speed here, because this is the layer that
faces hostile input directly:
- **No atoms from module data.** Import, export and custom section names stay binaries. The atom table is node-wide and never reclaimed,
      so a module that could mint atoms would be a permanent memory leak
      and eventually a node kill. `wasm_decode_SUITE` asserts the atom count
      does not move across a decode.
- **Bounds before allocation.** Every declared vector length is checked against the remaining input before any list is built. Each
      vector element occupies at least one byte, so a count exceeding the
      remaining bytes is unsatisfiable and is rejected in constant time.
      Without this, `vec` of 4294967295 is a one-line denial of service.
""".

-include("wasm.hrl").

-export([module/1, module_unchecked/1]).
-export([valtype/1, reftype/1, heaptype/1, limits/1, name/1]).
-export([imports/1]).

%%% ----------------------------------------------------------------- api ---

-doc """
The module and field names a decoded module imports.

An accessor rather than a record field reached by position: the record grew a
field before `imports` when recursive type groups arrived, and the one caller
that indexed it positionally silently started reading the wrong thing.
""".
-spec imports(#module{}) -> [{binary(), binary()}].
imports(#module{imports = Is}) ->
    [{Mod, Name} || #import{module = Mod, name = Name} <- Is].

-doc "Decode a module binary.".
-spec module(binary()) -> {ok, #module{}} | {error, wasm_error:error()}.
module(Bin) when is_binary(Bin) ->
    wasm_error:capture(fun() -> {ok, module_unchecked(Bin)} end);
module(_) ->
    {error, #{class => malformed, kind => not_a_binary,
              msg => <<"input is not a binary">>, ctx => #{}}}.

-doc "Decode, letting the internal throw escape. For use inside a `capture`.".
-spec module_unchecked(binary()) -> #module{}.
module_unchecked(<<"\0asm", 1:32/little, Rest/binary>>) ->
    {M, Seen} = sections(Rest, 0, #{}, #module{}),
    post_check(M, Seen);
module_unchecked(<<"\0asm", V:32/little, _/binary>>) ->
    wasm_error:malformed(unknown_binary_version, <<"unknown binary version">>,
                         #{version => V});
module_unchecked(Bin) when byte_size(Bin) < 8 ->
    wasm_error:malformed(unexpected_end, <<"unexpected end">>,
                         #{size => byte_size(Bin)});
module_unchecked(_) ->
    wasm_error:malformed(magic_header_not_detected,
                         <<"magic header not detected">>).

%%% ------------------------------------------------------------- sections ---

sections(<<>>, _Rank, Seen, M) ->
    {M, Seen};
sections(<<Id:8, Rest0/binary>>, Rank, Seen, M) ->
    {Size, Rest1} = wasm_leb128:u32(Rest0),
    case Rest1 of
        <<Body:Size/binary, Rest2/binary>> ->
            {M1, Rank1, Seen1} = section(Id, Body, Rank, Seen, M),
            sections(Rest2, Rank1, Seen1, M1);
        _ ->
            wasm_error:malformed(unexpected_end,
                                 <<"unexpected end of section or function">>,
                                 #{section => Id, declared_size => Size,
                                   remaining => byte_size(Rest1)})
    end.

section(?SEC_CUSTOM, Body, Rank, Seen, M) ->
    %% Custom sections may appear anywhere and repeat, so they do not advance
    %% the ordering rank. Contents are kept as a sub-binary: the name section
    %% is useful for diagnostics and the component model will want the rest.
    {Name, Payload} = name(Body),
    {M#module{customs = M#module.customs ++ [{Name, Payload}]}, Rank, Seen};
section(Id, Body, Rank, Seen, M) ->
    NewRank = order_rank(Id),
    case NewRank > Rank of
        false ->
            wasm_error:malformed(section_out_of_order,
                                 <<"junk after last section">>,
                                 #{section => Id, previous_rank => Rank});
        true ->
            M1 = decode_section(Id, Body, M),
            {M1, NewRank, Seen#{Id => true}}
    end.

%% The data count section carries id 12 but is placed between the element
%% section (9) and the code section (10). Ordering therefore has to be checked
%% against placement rank, not the raw section id. Using the id directly is a
%% common decoder bug that wrongly rejects every module with passive data.
order_rank(?SEC_TYPE)      -> 1;
order_rank(?SEC_IMPORT)    -> 2;
order_rank(?SEC_FUNCTION)  -> 3;
order_rank(?SEC_TABLE)     -> 4;
order_rank(?SEC_MEMORY)    -> 5;
%% The tag section carries id 13 but sits between memory and global, so like
%% the data count section it is ordered by placement rather than by id.
order_rank(?SEC_TAG)       -> 6;
order_rank(?SEC_GLOBAL)    -> 7;
order_rank(?SEC_EXPORT)    -> 8;
order_rank(?SEC_START)     -> 9;
order_rank(?SEC_ELEMENT)   -> 10;
order_rank(?SEC_DATACOUNT) -> 11;
order_rank(?SEC_CODE)      -> 12;
order_rank(?SEC_DATA)      -> 13;
order_rank(Id) ->
    wasm_error:malformed(malformed_section_id, <<"malformed section id">>,
                         #{section => Id}).

decode_section(?SEC_TYPE, Body, M) ->
    Groups = exact(Body, fun(B) -> vec(B, fun rectype/1) end, type),
    {Types, Bounds} = flatten_groups(Groups),
    M#module{types = Types, rec_groups = Bounds};
decode_section(?SEC_IMPORT, Body, M) ->
    M#module{imports = exact(Body, fun(B) -> vec(B, fun import/1) end, import)};
decode_section(?SEC_FUNCTION, Body, M) ->
    %% Type indices only. Bodies arrive in the code section and are merged in
    %% `post_check', which is also where a count mismatch is caught.
    Idx = exact(Body, fun(B) -> vec(B, fun wasm_leb128:u32/1) end, function),
    M#module{funcs = [#func{type = T} || T <- Idx]};
decode_section(?SEC_TABLE, Body, M) ->
    M#module{tables = exact(Body, fun(B) -> vec(B, fun tabletype/1) end, table)};
decode_section(?SEC_MEMORY, Body, M) ->
    M#module{mems = exact(Body, fun(B) -> vec(B, fun memtype/1) end, memory)};
decode_section(?SEC_TAG, Body, M) ->
    M#module{tags = exact(Body, fun(B) -> vec(B, fun tagtype/1) end, tag)};
decode_section(?SEC_GLOBAL, Body, M) ->
    M#module{globals = exact(Body, fun(B) -> vec(B, fun global/1) end, global)};
decode_section(?SEC_EXPORT, Body, M) ->
    M#module{exports = exact(Body, fun(B) -> vec(B, fun export/1) end, export)};
decode_section(?SEC_START, Body, M) ->
    M#module{start = exact(Body, fun wasm_leb128:u32/1, start)};
decode_section(?SEC_ELEMENT, Body, M) ->
    M#module{elems = exact(Body, fun(B) -> vec(B, fun elem/1) end, element)};
decode_section(?SEC_DATACOUNT, Body, M) ->
    M#module{data_count = exact(Body, fun wasm_leb128:u32/1, data_count)};
decode_section(?SEC_CODE, Body, M) ->
    M#module{funcs = merge_code(M#module.funcs,
                                exact(Body, fun(B) -> vec(B, fun code/1) end, code))};
decode_section(?SEC_DATA, Body, M) ->
    M#module{datas = exact(Body, fun(B) -> vec(B, fun data/1) end, data)}.

%% A section body must be consumed exactly. Trailing bytes mean the declared
%% size disagrees with the content, which is malformed rather than ignorable.
exact(Body, Fun, What) ->
    case Fun(Body) of
        {Value, <<>>} -> Value;
        {_, Left} ->
            wasm_error:malformed(section_size_mismatch,
                                 <<"section size mismatch">>,
                                 #{section => What, trailing => byte_size(Left)})
    end.

%%% ------------------------------------------------------------- structure ---

%% A type section entry is a *recursive group*: one or more types that may
%% refer to one another, including to themselves. The flat list is what every
%% type index in the binary format names, so the group boundaries are recorded
%% separately rather than nesting the types.
%%
%% Grouping matters only for identity. Two types are the same type when their
%% groups canonicalise identically *and* they sit at the same position, which is
%% what keeps two structurally identical members of one group distinct.
rectype(<<16#4E, R0/binary>>) -> vec(R0, fun subtype/1);
rectype(Bin) ->
    {T, Rest} = subtype(Bin),
    {[T], Rest}.

%% `0x50' declares a subtype that may itself be subtyped; `0x4F' declares a
%% final one. A bare composite type is final with no supertypes.
subtype(<<16#50, R0/binary>>) -> subtype_with(false, R0);
subtype(<<16#4F, R0/binary>>) -> subtype_with(true, R0);
subtype(Bin) ->
    {CT, Rest} = comptype(Bin),
    {#subtype{final = true, supers = [], body = CT}, Rest}.

subtype_with(Final, R0) ->
    {Supers, R1} = vec(R0, fun wasm_leb128:u32/1),
    {CT, R2} = comptype(R1),
    {#subtype{final = Final, supers = Supers, body = CT}, R2}.

comptype(<<16#5E, R0/binary>>) ->
    {FT, R1} = fieldtype(R0),
    {#arraytype{field = FT}, R1};
comptype(<<16#5F, R0/binary>>) ->
    {Fs, R1} = vec(R0, fun fieldtype/1),
    {#structtype{fields = Fs}, R1};
comptype(Bin) -> functype(Bin).

%% A field's storage type is a value type or one of the two packed types, and
%% packed types exist nowhere else in the format.
fieldtype(Bin0) ->
    {ST, Bin1} = storagetype(Bin0),
    case Bin1 of
        <<0, R/binary>> -> {#fieldtype{type = ST, mut = const}, R};
        <<1, R/binary>> -> {#fieldtype{type = ST, mut = var}, R};
        <<B:8, _/binary>> ->
            wasm_error:malformed(malformed_mutability,
                                 <<"malformed mutability">>, #{byte => B});
        <<>> -> wasm_error:malformed(unexpected_end, <<"unexpected end">>,
                                     #{reading => fieldtype})
    end.

storagetype(<<16#78, R/binary>>) -> {i8, R};
storagetype(<<16#77, R/binary>>) -> {i16, R};
storagetype(Bin) -> valtype(Bin).

%% Groups are flattened into the index space every type reference uses, with
%% their boundaries kept alongside for canonicalisation.
%%
%% Accumulated in reverse and reversed once. Appending to the growing list
%% instead is quadratic in the number of groups, and since almost every group
%% holds a single type that is quadratic in the number of *types*: it cost 14%
%% of compile time on a module with thirty of them.
flatten_groups(Groups) ->
    {RevTypes, RevBounds, _} =
        lists:foldl(
          fun(G, {Ts, Bs, Off}) ->
                  N = length(G),
                  {lists:reverse(G, Ts), [{Off, N} | Bs], Off + N}
          end, {[], [], 0}, Groups),
    {lists:reverse(RevTypes), lists:reverse(RevBounds)}.

functype(<<16#60, Rest0/binary>>) ->
    {Params, Rest1} = vec(Rest0, fun valtype/1),
    {Results, Rest2} = vec(Rest1, fun valtype/1),
    {#functype{params = Params, results = Results}, Rest2};
functype(<<B:8, _/binary>>) ->
    wasm_error:malformed(malformed_functype, <<"integer representation too long">>,
                         #{byte => B});
functype(<<>>) ->
    wasm_error:malformed(unexpected_end, <<"unexpected end">>, #{reading => functype}).

%% The leading byte is the tag's attribute. Only `0x00', an exception tag,
%% is defined.
tagtype(<<16#00, R0/binary>>) ->
    {T, R1} = wasm_leb128:u32(R0),
    {#tagtype{type = T}, R1};
tagtype(<<B:8, _/binary>>) ->
    wasm_error:malformed(malformed_tag_attribute,
                         <<"malformed tag attribute">>, #{byte => B});
tagtype(<<>>) ->
    wasm_error:malformed(unexpected_end, <<"unexpected end">>, #{reading => tagtype}).

import(Bin0) ->
    {Mod, Bin1} = name(Bin0),
    {Nm, Bin2} = name(Bin1),
    {Desc, Bin3} = importdesc(Bin2),
    {#import{module = Mod, name = Nm, desc = Desc}, Bin3}.

importdesc(<<16#00, R0/binary>>) ->
    {T, R1} = wasm_leb128:u32(R0),
    {{func, T}, R1};
importdesc(<<16#01, R0/binary>>) ->
    {T, R1} = tabletype(R0),
    {{table, T}, R1};
importdesc(<<16#02, R0/binary>>) ->
    {T, R1} = memtype(R0),
    {{mem, T}, R1};
importdesc(<<16#03, R0/binary>>) ->
    {T, R1} = globaltype(R0),
    {{global, T}, R1};
importdesc(<<16#04, R0/binary>>) ->
    {T, R1} = tagtype(R0),
    {{tag, T}, R1};
importdesc(<<B:8, _/binary>>) ->
    wasm_error:malformed(malformed_import_kind, <<"malformed import kind">>,
                         #{byte => B});
importdesc(<<>>) ->
    wasm_error:malformed(unexpected_end, <<"unexpected end">>, #{reading => importdesc}).

export(Bin0) ->
    {Nm, Bin1} = name(Bin0),
    {Kind, Bin2} = exportkind(Bin1),
    {Idx, Bin3} = wasm_leb128:u32(Bin2),
    {#export{name = Nm, desc = {Kind, Idx}}, Bin3}.

exportkind(<<16#00, R/binary>>) -> {func, R};
exportkind(<<16#01, R/binary>>) -> {table, R};
exportkind(<<16#02, R/binary>>) -> {mem, R};
exportkind(<<16#03, R/binary>>) -> {global, R};
exportkind(<<16#04, R/binary>>) -> {tag, R};
exportkind(<<B:8, _/binary>>) ->
    wasm_error:malformed(malformed_export_kind, <<"malformed export kind">>,
                         #{byte => B});
exportkind(<<>>) ->
    wasm_error:malformed(unexpected_end, <<"unexpected end">>, #{reading => exportkind}).

global(Bin0) ->
    {T, Bin1} = globaltype(Bin0),
    {Init, Bin2} = wasm_decode_code:expr(Bin1),
    {#global{type = T, init = Init}, Bin2}.

%%% ----------------------------------------------------------------- types ---

-spec valtype(binary()) -> {valtype(), binary()}.
valtype(<<16#7F, R/binary>>) -> {i32, R};
valtype(<<16#7E, R/binary>>) -> {i64, R};
valtype(<<16#7D, R/binary>>) -> {f32, R};
valtype(<<16#7C, R/binary>>) -> {f64, R};
valtype(<<16#7B, R/binary>>) -> {v128, R};
valtype(<<16#70, R/binary>>) -> {?FUNCREF, R};
valtype(<<16#6F, R/binary>>) -> {?EXTERNREF, R};
valtype(<<16#6E, _/binary>> = B) -> reftype(B);
valtype(<<16#6D, _/binary>> = B) -> reftype(B);
valtype(<<16#6C, _/binary>> = B) -> reftype(B);
valtype(<<16#6B, _/binary>> = B) -> reftype(B);
valtype(<<16#6A, _/binary>> = B) -> reftype(B);
valtype(<<16#71, _/binary>> = B) -> reftype(B);
valtype(<<16#69, _/binary>> = B) -> reftype(B);
valtype(<<16#74, _/binary>> = B) -> reftype(B);
valtype(<<16#73, _/binary>> = B) -> reftype(B);
valtype(<<16#72, _/binary>> = B) -> reftype(B);
valtype(<<16#63, _/binary>> = B) -> reftype(B);
valtype(<<16#64, _/binary>> = B) -> reftype(B);
valtype(<<B:8, _/binary>>) ->
    wasm_error:malformed(malformed_value_type, <<"malformed value type">>,
                         #{byte => B});
valtype(<<>>) ->
    wasm_error:malformed(unexpected_end, <<"unexpected end">>, #{reading => valtype}).

%% Reference types have a short form and a general form. `0x70'/`0x6F' are the
%% familiar `funcref'/`externref', and `0x73'/`0x72' their bottom types. The
%% general forms are `0x63 ht' for `(ref null ht)' and `0x64 ht' for `(ref ht)'.
%%
%% Everything normalises to `{ref, Null, HeapType}'. The short forms are
%% abbreviations in the *binary format*, not distinct types, and keeping them as
%% distinct atoms internally would mean `funcref' and `(ref null func)' were two
%% terms for one type that subtyping then had to treat as equal.
-spec reftype(binary()) -> {reftype(), binary()}.
reftype(<<16#70, R/binary>>) -> {?FUNCREF, R};
reftype(<<16#6F, R/binary>>) -> {?EXTERNREF, R};
reftype(<<16#6E, R/binary>>) -> {{ref, null, any}, R};
reftype(<<16#6D, R/binary>>) -> {{ref, null, eq}, R};
reftype(<<16#6C, R/binary>>) -> {{ref, null, i31}, R};
reftype(<<16#6B, R/binary>>) -> {{ref, null, struct}, R};
reftype(<<16#6A, R/binary>>) -> {{ref, null, array}, R};
reftype(<<16#71, R/binary>>) -> {{ref, null, none}, R};
reftype(<<16#69, R/binary>>) -> {?EXNREF, R};
reftype(<<16#74, R/binary>>) -> {{ref, null, noexn}, R};
reftype(<<16#73, R/binary>>) -> {{ref, null, nofunc}, R};
reftype(<<16#72, R/binary>>) -> {{ref, null, noextern}, R};
reftype(<<16#63, R0/binary>>) ->
    {HT, R1} = heaptype(R0),
    {{ref, null, HT}, R1};
reftype(<<16#64, R0/binary>>) ->
    {HT, R1} = heaptype(R0),
    {{ref, nonull, HT}, R1};
reftype(<<B:8, _/binary>>) ->
    wasm_error:malformed(malformed_reference_type, <<"malformed reference type">>,
                         #{byte => B});
reftype(<<>>) ->
    wasm_error:malformed(unexpected_end, <<"unexpected end">>, #{reading => reftype}).

%% Heap types share the encoding blocktypes use: a negative signed value is one
%% of the abstract types, a non-negative one is a type index. So a single signed
%% read distinguishes `(ref func)' from `(ref $t)'.
%%
%% The garbage collection heap types are refused by name. They decode perfectly
%% well, so this is `invalid' rather than `malformed': the runtime understands
%% the bytes and declines the type.
-spec heaptype(binary()) -> {heaptype(), binary()}.
heaptype(Bin) ->
    {X, Rest} = wasm_leb128:s33(Bin),
    case X of
        -16 -> {func, Rest};
        -17 -> {extern, Rest};
        -13 -> {nofunc, Rest};
        -14 -> {noextern, Rest};
        -23 -> {exn, Rest};
        -12 -> {noexn, Rest};
        -18 -> {any, Rest};
        -19 -> {eq, Rest};
        -20 -> {i31, Rest};
        -21 -> {struct, Rest};
        -22 -> {array, Rest};
        -15 -> {none, Rest};
        N when N >= 0 -> {{type, N}, Rest};
        _ ->
            wasm_error:malformed(malformed_heap_type,
                                 <<"malformed heap type">>, #{code => X})
    end.

%% Table definitions have two encodings. The bare form is a table type. The
%% `0x40 0x00' prefixed form additionally carries an initialiser expression,
%% used when the element type has no natural default.
tabletype(<<16#40, 16#00, Bin0/binary>>) ->
    {ET, Bin1} = reftype(Bin0),
    {L, Bin2} = limits(Bin1),
    {Init, Bin3} = wasm_decode_code:expr(Bin2),
    {#tabletype{limits = L, elemtype = ET, init = Init}, Bin3};
tabletype(Bin0) ->
    {ET, Bin1} = reftype(Bin0),
    {L, Bin2} = limits(Bin1),
    {#tabletype{limits = L, elemtype = ET}, Bin2}.

elemtype(Bin) -> reftype(Bin).

memtype(Bin0) ->
    {L, Bin1} = limits(Bin0),
    {#memtype{limits = L}, Bin1}.

globaltype(Bin0) ->
    {VT, Bin1} = valtype(Bin0),
    case Bin1 of
        <<16#00, R/binary>> -> {#globaltype{valtype = VT, mut = const}, R};
        <<16#01, R/binary>> -> {#globaltype{valtype = VT, mut = var}, R};
        <<B:8, _/binary>> ->
            wasm_error:malformed(malformed_mutability, <<"malformed mutability">>,
                                 #{byte => B});
        <<>> ->
            wasm_error:malformed(unexpected_end, <<"unexpected end">>,
                                 #{reading => mutability})
    end.

%% Flag 0x03 is the threads proposal's shared-with-maximum form. It is decoded
%% so the field exists, and rejected by validation until threads are supported;
%% decoding it here keeps the failure in one place.
%% Bounds are read as u64, not u32. A module declaring 2^32 pages is *invalid*
%% ("memory size must be at most 65536 pages"), not malformed: the value is a
%% well-formed varint that simply names an impossible size. Reading it as u32
%% would misclassify the failure, and misclassification matters because a
%% decoder that rejects too early also rejects legal memory64 modules later.
%% The range check belongs to `wasm_validate'.
%% The flags byte is a bit set, not an enumeration:
%%
%%   bit 0  a maximum follows
%%   bit 1  shared (threads)
%%   bit 2  the index type is i64 (memory64)
%%
%% Decoding it as a bit set rather than matching whole bytes is what keeps the
%% combinations from multiplying: shared-and-64-bit is then rejected by
%% validation for being shared, not by the decoder for being an unknown byte.
-spec limits(binary()) -> {#limits{}, binary()}.
limits(<<0:5, Sixty4:1, Shared:1, HasMax:1, R0/binary>>) ->
    {Min, R1} = wasm_leb128:u64(R0),
    {Max, R2} = case HasMax of
                    1 -> wasm_leb128:u64(R1);
                    0 -> {undefined, R1}
                end,
    {#limits{min = Min, max = Max,
             shared = Shared =:= 1,
             index_type = case Sixty4 of 1 -> i64; 0 -> i32 end}, R2};
limits(<<B:8, _/binary>>) ->
    wasm_error:malformed(malformed_limits, <<"integer too large">>, #{flags => B});
limits(<<>>) ->
    wasm_error:malformed(unexpected_end, <<"unexpected end">>, #{reading => limits}).

%%% -------------------------------------------------------------- segments ---

%% Eight element segment encodings. Bit 0 selects passive/declarative, bit 1
%% selects an explicit table index, bit 2 selects expression initialisers.
elem(Bin0) ->
    {Flags, Bin1} = wasm_leb128:u32(Bin0),
    elem(Flags, Bin1).

%% Forms 0 to 3 hold a vector of function indices, so every element is a
%% `ref.func' and the segment's type is the non-nullable `(ref func)'. Subtyping
%% then lets such a segment initialise a table of either nullability.
elem(0, Bin0) ->
    {Offset, Bin1} = wasm_decode_code:expr(Bin0),
    {Funcs, Bin2} = vec(Bin1, fun wasm_leb128:u32/1),
    {#elem{type = {ref, nonull, func}, init = ref_func_exprs(Funcs),
           mode = {active, 0, Offset}}, Bin2};
elem(1, Bin0) ->
    {_Kind, Bin1} = elemkind(Bin0),
    {Funcs, Bin2} = vec(Bin1, fun wasm_leb128:u32/1),
    {#elem{type = {ref, nonull, func}, init = ref_func_exprs(Funcs), mode = passive}, Bin2};
elem(2, Bin0) ->
    {TableIdx, Bin1} = wasm_leb128:u32(Bin0),
    {Offset, Bin2} = wasm_decode_code:expr(Bin1),
    {_Kind, Bin3} = elemkind(Bin2),
    {Funcs, Bin4} = vec(Bin3, fun wasm_leb128:u32/1),
    {#elem{type = {ref, nonull, func}, init = ref_func_exprs(Funcs),
           mode = {active, TableIdx, Offset}}, Bin4};
elem(3, Bin0) ->
    {_Kind, Bin1} = elemkind(Bin0),
    {Funcs, Bin2} = vec(Bin1, fun wasm_leb128:u32/1),
    {#elem{type = {ref, nonull, func}, init = ref_func_exprs(Funcs), mode = declarative}, Bin2};
elem(4, Bin0) ->
    {Offset, Bin1} = wasm_decode_code:expr(Bin0),
    {Exprs, Bin2} = vec(Bin1, fun wasm_decode_code:expr/1),
    %% Unlike forms 0 to 3 this holds arbitrary expressions, so `ref.null func'
    %% is legal in it and the element type has to stay nullable.
    {#elem{type = ?FUNCREF, init = Exprs, mode = {active, 0, Offset}}, Bin2};
elem(5, Bin0) ->
    {RT, Bin1} = elemtype(Bin0),
    {Exprs, Bin2} = vec(Bin1, fun wasm_decode_code:expr/1),
    {#elem{type = RT, init = Exprs, mode = passive}, Bin2};
elem(6, Bin0) ->
    {TableIdx, Bin1} = wasm_leb128:u32(Bin0),
    {Offset, Bin2} = wasm_decode_code:expr(Bin1),
    {RT, Bin3} = elemtype(Bin2),
    {Exprs, Bin4} = vec(Bin3, fun wasm_decode_code:expr/1),
    {#elem{type = RT, init = Exprs, mode = {active, TableIdx, Offset}}, Bin4};
elem(7, Bin0) ->
    {RT, Bin1} = elemtype(Bin0),
    {Exprs, Bin2} = vec(Bin1, fun wasm_decode_code:expr/1),
    {#elem{type = RT, init = Exprs, mode = declarative}, Bin2};
elem(Flags, _) ->
    wasm_error:malformed(malformed_elem_segment, <<"malformed element segment">>,
                         #{flags => Flags}).

elemkind(<<16#00, R/binary>>) -> {?FUNCREF, R};
elemkind(<<B:8, _/binary>>) ->
    wasm_error:malformed(malformed_elem_kind, <<"malformed element kind">>,
                         #{byte => B});
elemkind(<<>>) ->
    wasm_error:malformed(unexpected_end, <<"unexpected end">>, #{reading => elemkind}).

%% The index-list forms are normalised into the expression form so the rest of
%% the pipeline handles one shape instead of two.
ref_func_exprs(Funcs) -> [[{ref_func, F}] || F <- Funcs].

data(Bin0) ->
    {Flags, Bin1} = wasm_leb128:u32(Bin0),
    data(Flags, Bin1).

data(0, Bin0) ->
    {Offset, Bin1} = wasm_decode_code:expr(Bin0),
    {Bytes, Bin2} = bytevec(Bin1),
    {#data{init = Bytes, mode = {active, 0, Offset}}, Bin2};
data(1, Bin0) ->
    {Bytes, Bin1} = bytevec(Bin0),
    {#data{init = Bytes, mode = passive}, Bin1};
data(2, Bin0) ->
    {MemIdx, Bin1} = wasm_leb128:u32(Bin0),
    {Offset, Bin2} = wasm_decode_code:expr(Bin1),
    {Bytes, Bin3} = bytevec(Bin2),
    {#data{init = Bytes, mode = {active, MemIdx, Offset}}, Bin3};
data(Flags, _) ->
    wasm_error:malformed(malformed_data_segment, <<"malformed data segment">>,
                         #{flags => Flags}).

%% Function body: a declared size, then locals and the expression, which
%% together must consume exactly that many bytes.
code(Bin0) ->
    {Size, Bin1} = wasm_leb128:u32(Bin0),
    case Bin1 of
        <<Body:Size/binary, Rest/binary>> ->
            {Locals, Body1} = vec(Body, fun locals_entry/1),
            {Expr, Body2} = wasm_decode_code:expr(Body1),
            case Body2 of
                <<>> -> {{expand_locals(Locals), Expr}, Rest};
                _ ->
                    wasm_error:malformed(function_size_mismatch,
                                         <<"section size mismatch">>,
                                         #{trailing => byte_size(Body2)})
            end;
        _ ->
            wasm_error:malformed(unexpected_end,
                                 <<"unexpected end of section or function">>,
                                 #{declared_size => Size,
                                   remaining => byte_size(Bin1)})
    end.

locals_entry(Bin0) ->
    {N, Bin1} = wasm_leb128:u32(Bin0),
    {VT, Bin2} = valtype(Bin1),
    {{N, VT}, Bin2}.

%% Locals are run-length encoded. Expanding them here rather than at execution
%% time keeps the interpreter's frame setup to a single `erlang:make_tuple'.
%% The total is bounded first: a module declaring 2^32 locals of one type is
%% only a few bytes but would otherwise build a list that exhausts the node.
expand_locals(Groups) ->
    Total = lists:sum([N || {N, _} <- Groups]),
    case Total > 16#FFFFFFFF of
        true -> wasm_error:malformed(too_many_locals, <<"too many locals">>,
                                     #{count => Total});
        false -> ok
    end,
    case Total > 1000000 of
        true -> wasm_error:exhaustion(too_many_locals, #{count => Total});
        false -> ok
    end,
    lists:append([lists:duplicate(N, VT) || {N, VT} <- Groups]).

%%% --------------------------------------------------------------- helpers ---

-doc """
A length-prefixed UTF-8 name. Stays a binary: see the module note on
why module-controlled data must never become an atom.
""".
-spec name(binary()) -> {binary(), binary()}.
name(Bin0) ->
    {Len, Bin1} = wasm_leb128:u32(Bin0),
    case Bin1 of
        <<Str:Len/binary, Rest/binary>> ->
            case unicode:characters_to_binary(Str, utf8, utf8) of
                Str -> {Str, Rest};
                _ -> wasm_error:malformed(malformed_utf8,
                                          <<"malformed UTF-8 encoding">>)
            end;
        _ ->
            wasm_error:malformed(unexpected_end, <<"unexpected end">>,
                                 #{reading => name, declared => Len,
                                   remaining => byte_size(Bin1)})
    end.

bytevec(Bin0) ->
    {Len, Bin1} = wasm_leb128:u32(Bin0),
    case Bin1 of
        <<Bytes:Len/binary, Rest/binary>> -> {Bytes, Rest};
        _ -> wasm_error:malformed(unexpected_end,
                                  <<"unexpected end of section or function">>,
                                  #{reading => bytes, declared => Len,
                                    remaining => byte_size(Bin1)})
    end.

%% Generic vector: count, then that many elements. The count is bounded against
%% the remaining input before any allocation happens.
vec(Bin0, Fun) ->
    {N, Bin1} = wasm_leb128:u32(Bin0),
    case N > byte_size(Bin1) of
        true ->
            wasm_error:malformed(length_out_of_bounds, <<"length out of bounds">>,
                                 #{declared => N, remaining => byte_size(Bin1)});
        false ->
            vec(N, Bin1, Fun, [])
    end.

vec(0, Bin, _Fun, Acc) -> {lists:reverse(Acc), Bin};
vec(N, Bin, Fun, Acc) ->
    {V, Rest} = Fun(Bin),
    vec(N - 1, Rest, Fun, [V | Acc]).

%%% ---------------------------------------------------------- post-checks ---

merge_code(Funcs, Bodies) when length(Funcs) =:= length(Bodies) ->
    [F#func{locals = L, body = B} || {F, {L, B}} <- lists:zip(Funcs, Bodies)];
merge_code(Funcs, Bodies) ->
    wasm_error:malformed(function_code_mismatch,
                         <<"function and code section have inconsistent lengths">>,
                         #{functions => length(Funcs), bodies => length(Bodies)}).

%% A function section with no matching code section (or the reverse) is
%% malformed. `merge_code' only catches the case where both are present, so the
%% one-sided case is checked here against which sections were actually seen.
post_check(M, Seen) ->
    check_func_code_pairing(M, Seen),
    check_data_count(M),
    check_data_count_required(M),
    M.

%% `memory.init' and `data.drop' name a data segment by index, and the binary
%% format requires the data count section to be present whenever either
%% appears. The specification classes a missing one as malformed rather than
%% invalid, because the code section cannot be decoded into a well-formed
%% module without knowing how many segments to expect.
%%
%% The scan only runs for modules that declare no data count, and stops at the
%% first offending instruction, so modules that use bulk memory correctly never
%% pay for it.
check_data_count_required(#module{data_count = N}) when N =/= undefined ->
    ok;
check_data_count_required(#module{funcs = Funcs}) ->
    case lists:any(fun(#func{body = B}) -> uses_data_index(B) end, Funcs) of
        false -> ok;
        true ->
            wasm_error:malformed(data_count_section_required,
                                 <<"data count section required">>, #{})
    end.

uses_data_index([{memory_init, _, _} | _]) -> true;
uses_data_index([{data_drop, _} | _]) -> true;
uses_data_index([{block, _, Body} | Rest]) ->
    uses_data_index(Body) orelse uses_data_index(Rest);
uses_data_index([{loop, _, Body} | Rest]) ->
    uses_data_index(Body) orelse uses_data_index(Rest);
uses_data_index([{if_, _, Then, Else} | Rest]) ->
    uses_data_index(Then) orelse uses_data_index(Else) orelse uses_data_index(Rest);
uses_data_index([_ | Rest]) -> uses_data_index(Rest);
uses_data_index([]) -> false.

check_func_code_pairing(#module{funcs = Funcs}, Seen) ->
    HasFunc = maps:is_key(?SEC_FUNCTION, Seen),
    HasCode = maps:is_key(?SEC_CODE, Seen),
    case {HasFunc, HasCode, Funcs} of
        {_, _, []} -> ok;
        {true, true, _} -> ok;         % lengths already agreed in merge_code
        {true, false, _} ->
            wasm_error:malformed(
              function_code_mismatch,
              <<"function and code section have inconsistent lengths">>,
              #{functions => length(Funcs), bodies => 0});
        {false, true, _} ->
            wasm_error:malformed(
              function_code_mismatch,
              <<"function and code section have inconsistent lengths">>,
              #{functions => 0, bodies => length(Funcs)});
        {false, false, _} -> ok
    end.

check_data_count(#module{data_count = undefined}) ->
    ok;
check_data_count(#module{data_count = N, datas = Datas}) when N =:= length(Datas) ->
    ok;
check_data_count(#module{data_count = N, datas = Datas}) ->
    wasm_error:malformed(data_count_mismatch,
                         <<"data count and data section have inconsistent lengths">>,
                         #{declared => N, actual => length(Datas)}).
