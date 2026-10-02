-module(wasm_component_types).
-moduledoc """
Decode a component's type section into `wasm_canon` value descriptors.

Composition needs the signature of each function an interface offers: to bridge one
component's import onto another's export, the runtime lifts and lowers the call, and that
needs the parameter and result descriptors. Nothing else derives a signature from the
binary (a direct component call takes the signature from its caller), so this module reads
the component type section (`0x07`) and the import section (`0x0a`) and resolves, for each
imported interface, its functions' signatures.

The value types it decodes are the Canonical ABI primitives, which cover the common
composition case. An aggregate type (list, record, variant, ...) it does not yet decode is
reported as `{error, {unsupported_valtype, Byte}}`, to be extended rather than guessed.
""".

-export([import_interfaces/1, parse_types/1, resource_dtors/1]).

-export_type([sig/0]).

-type valdesc() :: wasm_canon:desc().
-type sig() :: {[valdesc()], valdesc() | none}.

%% A decoded type: a function, an instance (its exports), or a bare value type. Only what
%% composition consults is modelled; other type forms are kept opaque.
-type typedef() :: {func, [valdesc()], valdesc() | none}
                 | {instance, [{binary(), {func, non_neg_integer()}}]}
                 | {value, valdesc()}
                 | {resource, non_neg_integer() | none}
                 | other.

-define(SEC_TYPE, 7).
-define(SEC_IMPORT, 10).

-doc """
The imported interfaces of a component and each of their functions' signatures.

`Sec` is the component's section stream (the bytes after the 8-byte preamble). Returns
`#{InterfaceName => #{FuncName => sig()}}` for every import whose extern is an instance
(an interface). An import that is a bare function is returned under the interface name
with a single `FuncName` equal to the import name.
""".
-spec import_interfaces(binary()) ->
          {ok, #{binary() => #{binary() => sig()}}} | {error, term()}.
import_interfaces(Sec) ->
    wasm_error:capture(
      fun() ->
          Types = types_table(collect(?SEC_TYPE, Sec)),
          Imports = collect(?SEC_IMPORT, Sec),
          {ok, resolve_imports(Imports, Types)}
      end).

-doc "Decode the first type section in `Sec` into a map of type index to `typedef()`.".
-spec parse_types(binary()) -> #{non_neg_integer() => typedef()}.
parse_types(Sec) ->
    types_table(collect(?SEC_TYPE, Sec)).

%%% ------------------------------------------------------------- sections ---

%% Concatenate the content of every section with id `Id` in the stream, in order (a
%% component may split types or imports across several sections, one entry each).
collect(Id, Sec) ->
    collect(Id, Sec, <<>>).

collect(_Id, <<>>, Acc) ->
    Acc;
collect(Id, <<SecId, Rest0/binary>>, Acc) ->
    {Size, Rest1} = wasm_leb128:u32(Rest0),
    <<Content:Size/binary, Rest2/binary>> = Rest1,
    case SecId of
        Id -> collect(Id, Rest2, <<Acc/binary, Content/binary>>);
        _  -> collect(Id, Rest2, Acc)
    end.

%%% ---------------------------------------------------------------- types ---

%% Build the type index space: each entry is one `deftype`, numbered from 0 in order.
types_table(Content) ->
    {Count, Rest} = wasm_leb128:u32(Content),
    types_table(Count, Rest, 0, #{}).

types_table(0, _Rest, _Idx, Acc) ->
    Acc;
types_table(N, Bin, Idx, Acc) ->
    {Def, Rest} = deftype(Bin),
    types_table(N - 1, Rest, Idx + 1, Acc#{Idx => Def}).

%% A `deftype`: `0x40` functype, `0x42` instancetype, or a value type (a primitive byte
%% or an aggregate). Component/resource type forms are consumed only enough to model them
%% as `other` where composition does not need their shape.
deftype(<<16#40, Rest0/binary>>) ->
    {Params, Rest1} = func_params(Rest0),
    {Result, Rest2} = func_result(Rest1),
    {{func, Params, Result}, Rest2};
deftype(<<16#42, Rest0/binary>>) ->
    {Decls, Rest1} = instance_decls(Rest0),
    {{instance, Decls}, Rest1};
%% A resource type: `0x3f`, a one-byte core rep valtype, then `0x00` (no
%% destructor) or `0x01` and the destructor's core-func index. The index lets the
%% runtime run the destructor when an owned handle of this type is dropped.
deftype(<<16#3f, _Rep, 16#00, Rest/binary>>) ->
    {{resource, none}, Rest};
deftype(<<16#3f, _Rep, 16#01, Rest0/binary>>) ->
    {Dtor, Rest1} = wasm_leb128:u32(Rest0),
    {{resource, Dtor}, Rest1};
deftype(Bin) ->
    {Desc, Rest} = valtype(Bin),
    {{value, Desc}, Rest}.

-doc """
Each defined resource type's destructor, as `#{TypeIndex => CoreFuncIndex}`.

A resource type may name a core function the runtime runs when an owned handle of
that type is dropped. Only the first type section is read (as `parse_types/1`),
which covers a component that defines its resources there. A resource with no
destructor, or a type that is not a resource, is omitted. Never raises.
""".
-spec resource_dtors(binary()) -> #{non_neg_integer() => non_neg_integer()}.
resource_dtors(Sec) ->
    try
        {Count, Rest} = wasm_leb128:u32(collect(?SEC_TYPE, Sec)),
        resource_dtors(Count, Rest, 0, #{})
    catch
        _:_ -> #{}
    end.

resource_dtors(0, _Rest, _Idx, Acc) ->
    Acc;
resource_dtors(N, Bin, Idx, Acc) ->
    {Def, Rest} = deftype(Bin),
    Acc1 = case Def of
               {resource, Dtor} when is_integer(Dtor) -> Acc#{Idx => Dtor};
               _                                      -> Acc
           end,
    resource_dtors(N - 1, Rest, Idx + 1, Acc1).

%% Function parameters: a vector of `(name, valtype)`.
func_params(Bin) ->
    {Count, Rest} = wasm_leb128:u32(Bin),
    func_params(Count, Rest, []).

func_params(0, Rest, Acc) ->
    {lists:reverse(Acc), Rest};
func_params(N, Bin, Acc) ->
    {_Name, Rest0} = plain_name(Bin),
    {Desc, Rest1} = valtype(Rest0),
    func_params(N - 1, Rest1, [Desc | Acc]).

%% The result: `0x00 valtype` (one unnamed result) or `0x01 vec<(name, valtype)>` (named
%% results; composition uses the single-result case, so a named vector keeps its first).
func_result(<<16#00, Rest0/binary>>) ->
    valtype(Rest0);
func_result(<<16#01, Rest0/binary>>) ->
    {Count, Rest1} = wasm_leb128:u32(Rest0),
    named_result(Count, Rest1).

%% Named results: composition uses the single-result shape, so keep the first result's
%% descriptor and step over any others; no results is `none`.
named_result(0, Rest) ->
    {none, Rest};
named_result(N, Bin) ->
    {_Name, Rest0} = plain_name(Bin),
    {Desc, Rest1} = valtype(Rest0),
    {Desc, skip_results(N - 1, Rest1)}.

skip_results(0, Rest) ->
    Rest;
skip_results(N, Bin) ->
    {_Name, Rest0} = plain_name(Bin),
    {_Desc, Rest1} = valtype(Rest0),
    skip_results(N - 1, Rest1).

%% Instance declarations: a vector of `type` (0x01, a nested deftype), `export`
%% (0x04, a name and an externdesc), or a form consumed and ignored. A local type index
%% space accrues so an export's `func <idx>` resolves against the types declared here.
instance_decls(Bin) ->
    {Count, Rest} = wasm_leb128:u32(Bin),
    instance_decls(Count, Rest, 0, #{}, []).

instance_decls(0, Rest, _Idx, _Local, Exports) ->
    {lists:reverse(Exports), Rest};
instance_decls(N, <<16#01, Rest0/binary>>, Idx, Local, Exports) ->
    {Def, Rest1} = deftype(Rest0),
    instance_decls(N - 1, Rest1, Idx + 1, Local#{Idx => Def}, Exports);
instance_decls(N, <<16#04, Rest0/binary>>, Idx, Local, Exports) ->
    {_Name0, Rest1} = label(Rest0),
    {Extern, Rest2} = externdesc(Rest1),
    case Extern of
        {func, TypeIdx} ->
            %% A function export: its type lives in the instance's own (local) type
            %% space and its parameter/result types reference other local types, so
            %% resolve it against `Local`; a func export does not add a type index.
            Sig = resolve_func(TypeIdx, Local),
            instance_decls(N - 1, Rest2, Idx, Local, [{_Name0, Sig} | Exports]);
        {type, _Bound} ->
            %% A type export (e.g. a resource) introduces a type into the instance's type
            %% index space, so later `own`/`borrow` and function types line up; its shape
            %% is opaque to a signature (own/borrow lower to an i32 handle).
            instance_decls(N - 1, Rest2, Idx + 1, Local#{Idx => resource}, Exports);
        _ ->
            instance_decls(N - 1, Rest2, Idx, Local, Exports)
    end;
instance_decls(N, Bin, Idx, Local, Exports) ->
    %% Other instance declarations (alias, core type) are not needed to resolve the
    %% interface's functions; step over the one that is there.
    {_, Rest} = instance_decl_skip(Bin),
    instance_decls(N - 1, Rest, Idx, Local, Exports).

%% Resolve a local func type to a concrete signature `{func, Params, Result}`.
resolve_func(TypeIdx, Local) ->
    case maps:get(TypeIdx, Local, undefined) of
        {func, Params, Result} ->
            {func, [resolve(P, Local) || P <- Params], resolve(Result, Local)};
        _ ->
            {func, [], none}
    end.

instance_decl_skip(<<_Tag, Rest/binary>>) -> {skip, Rest}.

%% An externdesc: the sort byte then a type index. `0x01` func, `0x05` instance are the
%% ones composition reads; the rest are kept as their sort so a caller can ignore them.
externdesc(<<16#01, Rest0/binary>>) ->
    {Idx, Rest1} = wasm_leb128:u32(Rest0),
    {{func, Idx}, Rest1};
externdesc(<<16#05, Rest0/binary>>) ->
    {Idx, Rest1} = wasm_leb128:u32(Rest0),
    {{instance, Idx}, Rest1};
%% A type extern (`0x03`) carries a type bound, not a plain index: `0x00 <typeidx>` (eq
%% that type) or `0x01` (a subtype of resource). Consuming it exactly keeps the following
%% declarations aligned - getting this wrong is what shifted the resource type index.
externdesc(<<16#03, 16#00, Rest0/binary>>) ->
    {Idx, Rest1} = wasm_leb128:u32(Rest0),
    {{type, {eq, Idx}}, Rest1};
externdesc(<<16#03, 16#01, Rest/binary>>) ->
    {{type, sub_resource}, Rest};
externdesc(<<Sort, Rest0/binary>>) ->
    {Idx, Rest1} = wasm_leb128:u32(Rest0),
    {{Sort, Idx}, Rest1}.

%% A component-model value type: a Canonical ABI primitive (0x73..0x7f), an inline
%% type constructor (0x68..0x72), or a reference to a defined type by index (any other
%% leading byte, read as a u32). A reference is kept as `{typeref, Idx}` and resolved to a
%% concrete descriptor once the whole type table is built (`resolve/2`), since a type may
%% be referenced before this decoder has recorded it.
valtype(<<16#7f, R/binary>>) -> {bool, R};
valtype(<<16#7e, R/binary>>) -> {s8, R};
valtype(<<16#7d, R/binary>>) -> {u8, R};
valtype(<<16#7c, R/binary>>) -> {s16, R};
valtype(<<16#7b, R/binary>>) -> {u16, R};
valtype(<<16#7a, R/binary>>) -> {s32, R};
valtype(<<16#79, R/binary>>) -> {u32, R};
valtype(<<16#78, R/binary>>) -> {s64, R};
valtype(<<16#77, R/binary>>) -> {u64, R};
valtype(<<16#76, R/binary>>) -> {f32, R};
valtype(<<16#75, R/binary>>) -> {f64, R};
valtype(<<16#74, R/binary>>) -> {char, R};
valtype(<<16#73, R/binary>>) -> {string, R};
%% list<T>
valtype(<<16#70, R0/binary>>) ->
    {Elem, R1} = valtype(R0),
    {{list, Elem}, R1};
%% record { field: type, ... }
valtype(<<16#72, R0/binary>>) ->
    {Fields, R1} = named_types(R0),
    {{record, Fields}, R1};
%% tuple<T, ...>
valtype(<<16#6f, R0/binary>>) ->
    {Elems, R1} = valtype_vec(R0),
    {{tuple, Elems}, R1};
%% variant { case(name, type?), ... }
valtype(<<16#71, R0/binary>>) ->
    {Cases, R1} = variant_cases(R0),
    {{variant, Cases}, R1};
%% enum (names only)
valtype(<<16#6d, R0/binary>>) ->
    {Names, R1} = label_vec(R0),
    {{enum, Names}, R1};
%% flags (names only)
valtype(<<16#6e, R0/binary>>) ->
    {Names, R1} = label_vec(R0),
    {{flags, Names}, R1};
%% option<T>
valtype(<<16#6b, R0/binary>>) ->
    {Elem, R1} = valtype(R0),
    {{option, Elem}, R1};
%% result<ok?, err?>
valtype(<<16#6a, R0/binary>>) ->
    {Ok, R1} = opt_valtype(R0),
    {Err, R2} = opt_valtype(R1),
    {{result, Ok, Err}, R2};
%% own<rt> / borrow<rt>: a resource handle, opaque to the ABI as an i32. The
%% resource-type index is kept so the runtime can type-check and transfer the
%% handle; marshalling treats both as a bare i32 (see wasm_canon).
valtype(<<16#69, R0/binary>>) ->
    {Rt, R1} = wasm_leb128:u32(R0),
    {{own, Rt}, R1};
valtype(<<16#68, R0/binary>>) ->
    {Rt, R1} = wasm_leb128:u32(R0),
    {{borrow, Rt}, R1};
valtype(Bin) ->
    {Idx, R} = wasm_leb128:u32(Bin),
    {{typeref, Idx}, R}.

%% A vector of value types.
valtype_vec(Bin) ->
    {Count, Rest} = wasm_leb128:u32(Bin),
    valtype_vec(Count, Rest, []).

valtype_vec(0, Rest, Acc) -> {lists:reverse(Acc), Rest};
valtype_vec(N, Bin, Acc) ->
    {D, Rest} = valtype(Bin),
    valtype_vec(N - 1, Rest, [D | Acc]).

%% A vector of (label, valtype), for record fields.
named_types(Bin) ->
    {Count, Rest} = wasm_leb128:u32(Bin),
    named_types(Count, Rest, []).

named_types(0, Rest, Acc) -> {lists:reverse(Acc), Rest};
named_types(N, Bin, Acc) ->
    {Name, R0} = plain_name(Bin),
    {D, R1} = valtype(R0),
    named_types(N - 1, R1, [{Name, D} | Acc]).

%% A vector of labels, for enum and flags.
label_vec(Bin) ->
    {Count, Rest} = wasm_leb128:u32(Bin),
    label_vec(Count, Rest, []).

label_vec(0, Rest, Acc) -> {lists:reverse(Acc), Rest};
label_vec(N, Bin, Acc) ->
    {Name, Rest} = plain_name(Bin),
    label_vec(N - 1, Rest, [Name | Acc]).

%% Variant cases: each is a label, an optional payload type, and an optional refinement
%% index (which this decoder does not need and steps over).
variant_cases(Bin) ->
    {Count, Rest} = wasm_leb128:u32(Bin),
    variant_cases(Count, Rest, []).

variant_cases(0, Rest, Acc) -> {lists:reverse(Acc), Rest};
variant_cases(N, Bin, Acc) ->
    {Name, R0} = plain_name(Bin),
    {Payload, R1} = opt_valtype(R0),
    R2 = skip_refinement(R1),
    variant_cases(N - 1, R2, [{Name, Payload} | Acc]).

skip_refinement(<<16#00, R/binary>>) -> R;
skip_refinement(<<16#01, R0/binary>>) ->
    {_Idx, R1} = wasm_leb128:u32(R0),
    R1.

%% An optional value type: `0x00` none, `0x01 valtype` some. `none` for an absent type
%% (an empty variant case payload, or a missing ok/err in a result).
opt_valtype(<<16#00, R/binary>>) ->
    {none, R};
opt_valtype(<<16#01, R0/binary>>) ->
    valtype(R0).

%% An import/export/instance-export name: a leading kind byte, a u32 length, the bytes.
label(<<_Kind, Rest0/binary>>) ->
    {Len, Rest1} = wasm_leb128:u32(Rest0),
    <<Name:Len/binary, Rest2/binary>> = Rest1,
    {Name, Rest2}.

%% A function parameter/result name: a u32 length then the bytes, with no kind byte.
plain_name(Bin) ->
    {Len, Rest0} = wasm_leb128:u32(Bin),
    <<Name:Len/binary, Rest1/binary>> = Rest0,
    {Name, Rest1}.

%%% -------------------------------------------------------------- imports ---

%% Each import is a name and an externdesc; an instance extern is an interface, whose
%% type lists the functions. A func extern is a single function under its own name.
resolve_imports(Content, Types) ->
    {Count, Rest} = wasm_leb128:u32(Content),
    resolve_imports(Count, Rest, Types, #{}).

resolve_imports(0, _Rest, _Types, Acc) ->
    Acc;
resolve_imports(N, Bin, Types, Acc) ->
    {Name, Rest0} = label(Bin),
    {Extern, Rest1} = externdesc(Rest0),
    Acc1 = case Extern of
               {instance, TypeIdx} ->
                   Acc#{Name => interface_sigs(maps:get(TypeIdx, Types, other), Types)};
               {func, TypeIdx} ->
                   Acc#{Name => #{Name => global_sig(maps:get(TypeIdx, Types, other), Types)}};
               _ ->
                   Acc
           end,
    resolve_imports(N - 1, Rest1, Types, Acc1).

%% For an instance type, the signature of each function it exports. The exports already
%% carry concrete signatures (resolved against the instance's local types).
interface_sigs({instance, Exports}, _Types) ->
    maps:from_list([{Name, sig_of(F)} || {Name, F} <- Exports]);
interface_sigs(_Other, _Types) ->
    #{}.

sig_of({func, Params, Result}) -> {Params, Result};
sig_of(_Other)                 -> {[], none}.

%% A bare (non-interface) func import references a type in the component's global type
%% space; resolve it there.
global_sig({func, Params, Result}, Types) ->
    {[resolve(P, Types) || P <- Params], resolve(Result, Types)};
global_sig(_Other, _Types) ->
    {[], none}.

%% Replace every `{typeref, Idx}` in a descriptor with the concrete descriptor the type
%% table holds at that index, recursively through aggregates. Component type indices
%% reference earlier definitions, so this terminates; a reference the table does not hold
%% is left as the typeref (an unresolved type is better surfaced than silently dropped).
resolve({typeref, Idx}, Types) ->
    case maps:get(Idx, Types, undefined) of
        {value, Desc} -> resolve(Desc, Types);
        {func, _, _}  -> {typeref, Idx};
        _             -> {typeref, Idx}
    end;
resolve({list, D}, Types)      -> {list, resolve(D, Types)};
resolve({option, D}, Types)    -> {option, resolve(D, Types)};
resolve({tuple, Ds}, Types)    -> {tuple, [resolve(D, Types) || D <- Ds]};
resolve({record, Fs}, Types)   -> {record, [{N, resolve(D, Types)} || {N, D} <- Fs]};
resolve({variant, Cs}, Types)  -> {variant, [{N, resolve(D, Types)} || {N, D} <- Cs]};
resolve({result, Ok, Err}, Types) -> {result, resolve(Ok, Types), resolve(Err, Types)};
resolve(Desc, _Types)          -> Desc.
