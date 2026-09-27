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

-export([import_interfaces/1, parse_types/1]).

-export_type([sig/0]).

-type valdesc() :: wasm_canon:desc().
-type sig() :: {[valdesc()], valdesc() | none}.

%% A decoded type: a function, an instance (its exports), or a bare value type. Only what
%% composition consults is modelled; other type forms are kept opaque.
-type typedef() :: {func, [valdesc()], valdesc() | none}
                 | {instance, [{binary(), {func, non_neg_integer()}}]}
                 | {value, valdesc()}
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
deftype(Bin) ->
    {Desc, Rest} = valtype(Bin),
    {{value, Desc}, Rest}.

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
    {Name, Rest1} = label(Rest0),
    {Extern, Rest2} = externdesc(Rest1),
    Export = case Extern of
                 {func, TypeIdx} -> [{Name, resolve_local(TypeIdx, Local)}];
                 _               -> []
             end,
    instance_decls(N - 1, Rest2, Idx, Local, Export ++ Exports);
instance_decls(N, Bin, Idx, Local, Exports) ->
    %% Other instance declarations (alias, core type) are not needed to resolve the
    %% interface's functions; step over the one that is there.
    {_, Rest} = instance_decl_skip(Bin),
    instance_decls(N - 1, Rest, Idx, Local, Exports).

resolve_local(TypeIdx, Local) ->
    case maps:get(TypeIdx, Local, undefined) of
        {func, Params, Result} -> {func, Params, Result};
        _                      -> {func_ref, TypeIdx}
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
externdesc(<<Sort, Rest0/binary>>) ->
    {Idx, Rest1} = wasm_leb128:u32(Rest0),
    {{Sort, Idx}, Rest1}.

%% A component-model value type: a Canonical ABI primitive (encoded 0x73..0x7f) or a
%% reference to a defined type by index. Aggregates are not decoded yet.
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
valtype(<<Byte, _/binary>>) ->
    wasm_error:link_error(unsupported_valtype,
                          <<"a component value type is not yet decoded">>,
                          #{byte => Byte}).

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
                   Acc#{Name => #{Name => sig_of(maps:get(TypeIdx, Types, other))}};
               _ ->
                   Acc
           end,
    resolve_imports(N - 1, Rest1, Types, Acc1).

%% For an instance type, the signature of each function it exports.
interface_sigs({instance, Exports}, Types) ->
    maps:from_list(
      [{Name, sig_of(func_def(Ref, Types))} || {Name, Ref} <- Exports]);
interface_sigs(_Other, _Types) ->
    #{}.

func_def({func, _, _} = F, _Types) -> F;
func_def({func_ref, Idx}, Types)   -> maps:get(Idx, Types, other);
func_def(_Other, _Types)           -> other.

sig_of({func, Params, Result}) -> {Params, Result};
sig_of(_Other)                 -> {[], none}.
