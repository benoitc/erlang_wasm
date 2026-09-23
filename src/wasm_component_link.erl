-module(wasm_component_link).
-moduledoc """
Internal: read a component's wiring diagram and build its cores.

A component holds one or more core modules plus a wiring diagram (its
core-instance, alias and canon sections) saying how each core gets its imports
and which functions the component exposes. `wasm_component` runs a program by
picking one core and binding its imports to our WASI host functions by name. That
is enough when the program core asks for WASI directly, which every component we
build ourselves does.

This module adds the missing case: a core whose imports are satisfied by *another
core's exports*, not by a host function. It walks the top-level sections in order,
building the core-instance graph, so a core can be instantiated with the exports
of a core built before it (`wasm:extern/2` carries an export across, and one
shared store via `#{link => ...}` lets a memory or table of one core serve
another).

Milestone 1 scope: the non-cyclic core-to-core case, exercised by a two-core
fixture and leaving every native single-core program on its existing path. The
preview1-to-preview2 adapter (a startup cycle broken by a shim table, plus canon
lower/lift) is milestone 2; canon, component-import and component-instance
sections are parsed but not yet interpreted here.

Nothing here raises: a malformed section or an unresolved import is a returned
error value carrying a kind and context, and no name a component supplies becomes
an atom.
""".

-export([parse/1, providers/5, core_imports/1]).

-export_type([graph/0, item/0]).

%% One entry of an index space, in the order the sections define it. The
%% interpreter folds over this list assigning indices per kind.
-type item() ::
        {core_module, binary()}
      | {core_instance, {instantiate, non_neg_integer(),
                         [{binary(), non_neg_integer()}]}}
      | {core_instance, {exports, [{binary(), core_sort(), non_neg_integer()}]}}
      | {core_alias, core_sort(), non_neg_integer(), binary()}
      | {comp_func_alias, non_neg_integer(), binary()}.

-type core_sort() :: func | table | memory | global.

-type graph() :: [item()].

-define(SEC_CORE_MODULE, 1).
-define(SEC_CORE_INSTANCE, 2).
-define(SEC_ALIAS, 6).

%% The import section id inside a *core* module's own section stream (not a
%% component section).
-define(CORE_SEC_IMPORT, 2).

-doc """
Parse a component's top-level sections into an ordered item list.

The component preamble (`00 61 73 6d 0d 00 01 00`) is already stripped by the
caller; `Bin` is the section stream. Sections we do not yet interpret (types,
canon, component imports, component instances, customs) are stepped over by their
declared size, so parsing always reaches the next section.
""".
-spec parse(binary()) -> {ok, graph()} | {error, term()}.
parse(Bin) ->
    sections(Bin, []).

sections(<<>>, Items) ->
    {ok, lists:reverse(Items)};
sections(<<Id, Rest0/binary>>, Items) ->
    {Size, Rest1} = wasm_leb128:u32(Rest0),
    case Rest1 of
        <<Content:Size/binary, Rest2/binary>> ->
            {ok, New} = section(Id, Content),
            sections(Rest2, lists:reverse(New) ++ Items);
        _ ->
            {error, {truncated_section, Id}}
    end.

%% Each recognised section yields its entries as items, in order. An
%% unrecognised one yields none.
section(?SEC_CORE_MODULE, Content) ->
    {ok, [{core_module, Content}]};
section(?SEC_CORE_INSTANCE, Content) ->
    vec(Content, fun core_instance/1, fun(E) -> {core_instance, E} end);
section(?SEC_ALIAS, Content) ->
    vec(Content, fun alias_entry/1, fun(E) -> E end);
section(_Other, _Content) ->
    {ok, []}.

%% Read a vec(count, entries), applying Parse to each and Wrap to the result.
%% Parse returns `{Entry, Rest}` or `skip` (an entry that defines no item, e.g. a
%% type alias); Wrap turns an Entry into an item.
vec(Bin, Parse, Wrap) ->
    {Count, Rest} = wasm_leb128:u32(Bin),
    vec(Count, Rest, Parse, Wrap, []).

vec(0, _Rest, _Parse, _Wrap, Acc) ->
    {ok, lists:reverse(Acc)};
vec(N, Bin, Parse, Wrap, Acc) ->
    case Parse(Bin) of
        {skip, Rest}          -> vec(N - 1, Rest, Parse, Wrap, Acc);
        {Entry, Rest}         -> vec(N - 1, Rest, Parse, Wrap, [Wrap(Entry) | Acc])
    end.

%%% ---------------------------------------------------------------- providers ---

-doc """
Build the provider cores that satisfy an entry core's non-host imports.

`Graph` is the parsed item list; `EntryModIdx` the 0-based index of the entry
core module; `Leftovers` the entry's imports left unbound by a host function;
`HostResolve` a fun mapping a core's `[{Mod, Field}]` imports to a
`#{{Mod, Field} => value}` map drawn from the host set; `LoadOpts` the loader and
limits for `wasm:instantiate`.

Returns `{ok, ImportMap, Anchor, BuiltInsts}`: `ImportMap` wires each leftover to
an `extern()` of a provider core, `Anchor` the instance whose store the entry
links to, `BuiltInsts` every provider built (for teardown). Milestone 1 resolves
a provider whose own imports are all host-bound (the non-cyclic case); a deeper
or cyclic graph is a returned `{error, {unsupported_graph, _}}`.
""".
-spec providers(graph(), non_neg_integer(), [{binary(), binary()}],
                fun(([{binary(), binary()}]) -> map()), map()) ->
          {ok, map(), wasm:instance(), [wasm:instance()]} | {error, term()}.
providers(Graph, EntryModIdx, Leftovers, HostResolve, LoadOpts) ->
    ModVec = list_to_tuple([B || {core_module, B} <- Graph]),
    InstVec = list_to_tuple([E || {core_instance, E} <- Graph]),
    case entry_args(InstVec, EntryModIdx) of
        {ok, Args} ->
            Ctx = #{mods => ModVec, insts => InstVec, resolve => HostResolve,
                    opts => LoadOpts},
            build_leftovers(Leftovers, Args, Ctx, #{}, #{}, []);
        {error, _} = E ->
            E
    end.

%% The `with` args of the core instance that instantiates the entry module, as a
%% `#{Namespace => CoreInstanceIdx}` map. A component instantiates each core once,
%% so the first match is it.
entry_args(InstVec, EntryModIdx) ->
    entry_args(InstVec, EntryModIdx, 1, tuple_size(InstVec)).

entry_args(_InstVec, EntryModIdx, I, N) when I > N ->
    {error, {no_instantiate_for_core, EntryModIdx}};
entry_args(InstVec, EntryModIdx, I, N) ->
    case element(I, InstVec) of
        {instantiate, EntryModIdx, Args} -> {ok, maps:from_list(Args)};
        _                                -> entry_args(InstVec, EntryModIdx, I + 1, N)
    end.

build_leftovers([], _Args, _Ctx, ImportMap, Built, Order) ->
    Insts = [maps:get(K, Built) || K <- lists:reverse(Order)],
    case Insts of
        [Anchor | _] -> {ok, ImportMap, Anchor, Insts};
        []           -> {error, no_providers}
    end;
build_leftovers([{NS, Field} = Key | Rest], Args, Ctx, ImportMap, Built, Order) ->
    case source_instance(NS, Args, Ctx) of
        {instantiate, InstIdx} ->
            case get_or_build(InstIdx, Ctx, Built, Order) of
                {ok, Inst, Built1, Order1} ->
                    case wasm:extern(Inst, Field) of
                        {ok, Extern} ->
                            build_leftovers(Rest, Args, Ctx,
                                            ImportMap#{Key => Extern}, Built1, Order1);
                        {error, _} = E ->
                            E
                    end;
                {error, _} = E ->
                    E
            end;
        unresolved ->
            %% Either the entry core does not name a source for this namespace,
            %% or the graph feeds it from a synthetic namespace of host functions
            %% the component expected to be supplied. Neither is another core's
            %% export, so it is a host import the caller left unbound, named.
            {error, {unresolved_import, Key}}
    end.

%% Where the entry's `with` args draw namespace `NS` from: a real core instance
%% we can build, or nothing we can wire (a synthetic host-function namespace, or
%% an absent arg).
source_instance(NS, Args, Ctx) ->
    case maps:get(NS, Args, undefined) of
        undefined ->
            unresolved;
        InstIdx ->
            case element(InstIdx + 1, maps:get(insts, Ctx)) of
                {instantiate, _ModIdx, _Args} -> {instantiate, InstIdx};
                {exports, _}                  -> unresolved
            end
    end.

get_or_build(InstIdx, Ctx, Built, Order) ->
    case maps:find(InstIdx, Built) of
        {ok, Inst} ->
            {ok, Inst, Built, Order};
        error ->
            {instantiate, ModIdx, _Args} = element(InstIdx + 1, maps:get(insts, Ctx)),
            build_instance(InstIdx, ModIdx, Ctx, Built, Order)
    end.

%% Instantiate a provider core whose own imports are all host-bound. A provider
%% that itself needs another core (a deeper or cyclic link) is milestone 2.
build_instance(InstIdx, ModIdx, Ctx, Built, Order) ->
    Bytes = element(ModIdx + 1, maps:get(mods, Ctx)),
    Imports = core_imports(Bytes),
    Host = (maps:get(resolve, Ctx))(Imports),
    case [K || K <- Imports, not maps:is_key(K, Host)] of
        [] ->
            Opts = maps:get(opts, Ctx),
            Loader = maps:get(loader, Opts, load),
            Limits = link_to(Built, maps:remove(loader, Opts)),
            case load_core(Loader, Bytes) of
                {ok, Mod} ->
                    case wasm:instantiate(Mod, Host, Limits) of
                        {ok, Inst} ->
                            {ok, Inst, Built#{InstIdx => Inst}, [InstIdx | Order]};
                        {error, _} = E ->
                            E
                    end;
                {error, _} = E ->
                    E
            end;
        Deeper ->
            {error, {unsupported_graph, {deeper_core_link, Deeper}}}
    end.

%% Every core of one component shares one store; the first built starts it and the
%% rest link to any already-built member of that store.
link_to(Built, Limits) when map_size(Built) =:= 0 -> Limits;
link_to(Built, Limits) -> Limits#{link => hd(maps:values(Built))}.

load_core(compile, Bytes) -> wasm:compile(Bytes);
load_core(_Load, Bytes)   -> wasm:load(Bytes).

%%% ------------------------------------------------------------ core instance ---

%% `0x00 m:u32 args:vec(name, 0x12, inst:u32)` instantiate;
%% `0x01 exports:vec(name, coresort:byte, idx:u32)` inline exports.
core_instance(<<16#00, Rest0/binary>>) ->
    {ModIdx, Rest1} = wasm_leb128:u32(Rest0),
    {Args, Rest2} = args(Rest1),
    {{instantiate, ModIdx, Args}, Rest2};
core_instance(<<16#01, Rest0/binary>>) ->
    {Exports, Rest1} = inline_exports(Rest0),
    {{exports, Exports}, Rest1}.

args(Bin) ->
    {Count, Rest} = wasm_leb128:u32(Bin),
    args(Count, Rest, []).

args(0, Rest, Acc) ->
    {lists:reverse(Acc), Rest};
args(N, Bin, Acc) ->
    {Name, Rest0} = name(Bin),
    %% Each arg is `name 0x12 inst`; 0x12 is the core-instance sort.
    <<16#12, Rest1/binary>> = Rest0,
    {InstIdx, Rest2} = wasm_leb128:u32(Rest1),
    args(N - 1, Rest2, [{Name, InstIdx} | Acc]).

inline_exports(Bin) ->
    {Count, Rest} = wasm_leb128:u32(Bin),
    inline_exports(Count, Rest, []).

inline_exports(0, Rest, Acc) ->
    {lists:reverse(Acc), Rest};
inline_exports(N, Bin, Acc) ->
    {Name, Rest0} = name(Bin),
    <<Sort, Rest1/binary>> = Rest0,
    {Idx, Rest2} = wasm_leb128:u32(Rest1),
    inline_exports(N - 1, Rest2, [{Name, core_sort(Sort), Idx} | Acc]).

%%% -------------------------------------------------------------------- alias ---

%% Core export: `0x00 coresort:byte 0x01 inst:u32 name` (a core func is
%% `00 00 01 <inst> <name>`). Component-instance func export: `0x01 0x00 inst name`.
%% A type alias (`0x03 ...`) defines nothing we run, so it is skipped.
alias_entry(<<16#00, Sort, 16#01, Rest0/binary>>) ->
    {InstIdx, Rest1} = wasm_leb128:u32(Rest0),
    {Name, Rest2} = name(Rest1),
    {{core_alias, core_sort(Sort), InstIdx, Name}, Rest2};
alias_entry(<<16#01, 16#00, Rest0/binary>>) ->
    {InstIdx, Rest1} = wasm_leb128:u32(Rest0),
    {Name, Rest2} = name(Rest1),
    {{comp_func_alias, InstIdx, Name}, Rest2};
alias_entry(<<16#03, 16#00, Rest0/binary>>) ->
    %% Type alias from a component instance export: skip inst + name.
    {_InstIdx, Rest1} = wasm_leb128:u32(Rest0),
    {_Name, Rest2} = name(Rest1),
    {skip, Rest2};
alias_entry(<<16#03, 16#01, Rest0/binary>>) ->
    %% Type alias from a core instance export: skip inst + name.
    {_InstIdx, Rest1} = wasm_leb128:u32(Rest0),
    {_Name, Rest2} = name(Rest1),
    {skip, Rest2};
alias_entry(<<_Sort, 16#02, Rest0/binary>>) ->
    %% Outer alias: `sort 0x02 ct:u32 idx:u32` (nested components only). Skip.
    {_Ct, Rest1} = wasm_leb128:u32(Rest0),
    {_Idx, Rest2} = wasm_leb128:u32(Rest1),
    {skip, Rest2}.

%%% -------------------------------------------------------------- core imports ---

-doc """
The `{Module, Field}` of every import in a core module.

`Bin` is the core module's own bytes (a core preamble, not the component). The
importing core names each import by module and field; resolution binds those
names to host functions or, through the graph above, to another core's exports.
Non-function imports are stepped over by their type so parsing reaches the next.
""".
-spec core_imports(binary()) -> [{binary(), binary()}].
core_imports(<<16#00, 16#61, 16#73, 16#6d, _:4/binary, Rest/binary>>) ->
    core_import_sections(Rest).

core_import_sections(<<>>) ->
    [];
core_import_sections(<<Id, Rest0/binary>>) ->
    {Size, Rest1} = wasm_leb128:u32(Rest0),
    <<Content:Size/binary, Rest2/binary>> = Rest1,
    case Id of
        ?CORE_SEC_IMPORT -> import_entries(Content);
        _                -> core_import_sections(Rest2)
    end.

import_entries(Bin) ->
    {Count, Rest} = wasm_leb128:u32(Bin),
    import_entries(Count, Rest, []).

import_entries(0, _Rest, Acc) ->
    lists:reverse(Acc);
import_entries(N, Bin, Acc) ->
    {Mod, Rest1} = name(Bin),
    {Field, Rest2} = name(Rest1),
    Rest3 = skip_importdesc(Rest2),
    import_entries(N - 1, Rest3, [{Mod, Field} | Acc]).

%% Skip one import descriptor: a kind byte then its type, so parsing reaches the
%% next import. Every import's `{Mod, Field}` is kept regardless of kind.
skip_importdesc(<<16#00, Rest/binary>>) -> {_T, R} = wasm_leb128:u32(Rest), R;
skip_importdesc(<<16#01, _Reftype, Rest/binary>>) -> skip_limits(Rest);
skip_importdesc(<<16#02, Rest/binary>>) -> skip_limits(Rest);
skip_importdesc(<<16#03, _Valtype, _Mut, Rest/binary>>) -> Rest.

skip_limits(<<0, Rest/binary>>) -> {_Min, R} = wasm_leb128:u32(Rest), R;
skip_limits(<<1, Rest/binary>>) ->
    {_Min, R1} = wasm_leb128:u32(Rest),
    {_Max, R2} = wasm_leb128:u32(R1),
    R2.

%%% ------------------------------------------------------------------ helpers ---

name(Bin) ->
    {Len, Rest} = wasm_leb128:u32(Bin),
    <<Name:Len/binary, Rest1/binary>> = Rest,
    {Name, Rest1}.

core_sort(16#00) -> func;
core_sort(16#01) -> table;
core_sort(16#02) -> memory;
core_sort(16#03) -> global.
