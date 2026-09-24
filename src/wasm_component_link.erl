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

-export([parse/1, link/4, core_imports/1]).

-export_type([graph/0, item/0]).

%% One entry of an index space, in the order the sections define it. The
%% interpreter folds over this list assigning indices per kind.
-type item() ::
        {core_module, binary()}
      | {core_instance, {instantiate, non_neg_integer(),
                         [{binary(), non_neg_integer()}]}}
      | {core_instance, {exports, [{binary(), core_sort(), non_neg_integer()}]}}
      | {core_alias, core_sort(), non_neg_integer(), binary()}
      | {comp_func_alias, non_neg_integer(), binary()}
      | {canon_lower, non_neg_integer(), non_neg_integer() | none}
      | {canon_lift, non_neg_integer()}
      | {canon_resource, new | drop | rep, non_neg_integer()}
      | {comp_import_instance, binary()}
      | {comp_import_func, binary()}.

-type core_sort() :: func | table | memory | global.

-type graph() :: [item()].

-define(SEC_CORE_MODULE, 1).
-define(SEC_CORE_INSTANCE, 2).
-define(SEC_ALIAS, 6).
-define(SEC_CANON, 8).
-define(SEC_COMP_IMPORT, 10).

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
section(?SEC_CANON, Content) ->
    vec(Content, fun canon/1, fun(E) -> E end);
section(?SEC_COMP_IMPORT, Content) ->
    vec(Content, fun comp_import/1, fun(E) -> E end);
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

%%% ------------------------------------------------------------------ the linker ---

-doc """
Instantiate a component by interpreting its whole core-instance graph.

`Graph` is the parsed items; `EntryModIdx` the largest core's index (the entry
for a program whose exports the caller calls directly, e.g. a reactor);
`HostResolve` maps a core's `[{Mod, Field}]` imports to the host functions that
satisfy them (version-normalised); `Opts` the loader and limits.

Every core instance is built in graph order: a core's imports come from the cores
named in its `with` args (an `extern()` carried across a shared store) or, for a
namespace of lowered host functions, from `HostResolve`. The entry is the core
that exports `wasi:cli/run...#run` (a command) or, failing that, the largest core
(a reactor). Returns `{ok, #{core, cores}}` -- `core` is the entry instance,
`cores` every built instance for teardown -- or a named `{error, _}`.
""".
-spec link(graph(), non_neg_integer(),
           fun(([{binary(), binary()}]) -> map()), map()) ->
          {ok, #{core := wasm:instance(), cores := [wasm:instance()]}}
          | {error, term()}.
link(Graph, EntryModIdx, HostResolve, Opts) ->
    S0 = #{mods => list_to_tuple([B || {core_module, B} <- Graph]),
           resolve => HostResolve, opts => Opts, anchor => undefined,
           core_insts => #{}, n_ci => 0, core_funcs => #{}, n_cf => 0,
           core_mems => #{}, n_cm => 0, core_tables => #{}, n_ct => 0,
           core_globals => #{}, n_cg => 0, comp_insts => #{}, n_pi => 0,
           comp_funcs => #{}, n_pf => 0, built => [], entry_mod => EntryModIdx,
           entry_by_mod => undefined, run_inst => undefined},
    case fold(Graph, S0) of
        {ok, S} ->
            Built = lists:reverse(maps:get(built, S)),
            case entry(S) of
                {ok, Core}     -> {ok, #{core => Core, cores => Built}};
                {error, _} = E -> destroy_built(S), E
            end;
        {error, Reason, S} ->
            destroy_built(S),
            {error, Reason}
    end.

%% A partial link that failed still built some cores; free them so a mid-graph
%% error leaks nothing.
destroy_built(S) ->
    lists:foreach(fun wasm:destroy/1, maps:get(built, S)).

%% The entry instance: the core that exports the run function, else the largest.
entry(#{run_inst := Idx, core_insts := CI}) when Idx =/= undefined ->
    {real, Inst} = maps:get(Idx, CI),
    {ok, Inst};
entry(#{entry_by_mod := Inst}) when Inst =/= undefined ->
    {ok, Inst};
entry(_S) ->
    {error, no_entry_core}.

fold([], S) ->
    {ok, S};
fold([Item | Rest], S) ->
    %% A malformed graph can make `step` raise (a bad index, a strict match); carry
    %% the state out so `link/4` frees the cores already built rather than leaking
    %% them on the exception path.
    try step(Item, S) of
        {ok, S1}        -> fold(Rest, S1);
        {error, Reason} -> {error, Reason, S}
    catch
        Class:Reason -> {error, {link_crashed, {Class, Reason}}, S}
    end.

step({core_module, _}, S) ->
    {ok, S};
step({comp_import_instance, Name}, S) ->
    {ok, bump(S, n_pi, comp_insts, Name)};
step({comp_import_func, Name}, S) ->
    {ok, bump(S, n_pf, comp_funcs, {import_func, Name})};
step({comp_func_alias, InstIdx, Field}, S) ->
    Iface = maps:get(InstIdx, maps:get(comp_insts, S)),
    {ok, bump(S, n_pf, comp_funcs, {host, Iface, Field})};
step({canon_lift, CoreFuncIdx}, S) ->
    {ok, bump(S, n_pf, comp_funcs, {lift, CoreFuncIdx})};
step({canon_lower, CompFuncIdx, ReallocIdx}, S) ->
    case host_fun(maps:get(CompFuncIdx, maps:get(comp_funcs, S)), S) of
        {ok, Fun} ->
            Realloc = realloc_callable(ReallocIdx, S),
            {ok, bump(S, n_cf, core_funcs, lowered(Fun, Realloc, S))};
        {error, _} = E ->
            E
    end;
step({canon_resource, Kind, _Rt}, S) ->
    {ok, bump(S, n_cf, core_funcs, resource_fun(Kind))};
step({core_alias, func, InstIdx, Name}, S) ->
    case export_val(S, InstIdx, Name) of
        {ok, Val}      -> {ok, note_run(Name, InstIdx, bump(S, n_cf, core_funcs, Val))};
        {error, _} = E -> E
    end;
step({core_alias, memory, InstIdx, Name}, S) ->
    alias_into(S, n_cm, core_mems, InstIdx, Name);
step({core_alias, table, InstIdx, Name}, S) ->
    alias_into(S, n_ct, core_tables, InstIdx, Name);
step({core_alias, global, InstIdx, Name}, S) ->
    alias_into(S, n_cg, core_globals, InstIdx, Name);
step({core_instance, {exports, Entries}}, S) ->
    case synthetic(Entries, S) of
        {ok, Map}      -> {ok, add_inst(S, {synthetic, Map})};
        {error, _} = E -> E
    end;
step({core_instance, {instantiate, ModIdx, Args}}, S) ->
    instantiate_core(ModIdx, Args, S).

alias_into(S, Counter, Space, InstIdx, Name) ->
    case export_val(S, InstIdx, Name) of
        {ok, Val}      -> {ok, bump(S, Counter, Space, Val)};
        {error, _} = E -> E
    end.

%% Append Val at the next index of Space, advancing its counter.
bump(S, Counter, Space, Val) ->
    N = maps:get(Counter, S),
    S#{Counter => N + 1, Space => maps:put(N, Val, maps:get(Space, S))}.

%% Record the entry when an alias pulls the run export out of a core instance.
note_run(Name, InstIdx, S) ->
    case is_run(Name) of
        true  -> S#{run_inst => InstIdx};
        false -> S
    end.

is_run(Name) ->
    binary:match(Name, <<"wasi:cli/run">>) =/= nomatch
        andalso binary:longest_common_suffix([Name, <<"#run">>]) =:= 4.

%% A component func resolved to a host function: a `{host, Iface, Field}` alias is
%% our WASI implementation for that interface and method (version-normalised by
%% `HostResolve`); unresolved otherwise.
host_fun({host, Iface, Field}, S) ->
    Resolve = maps:get(resolve, S),
    case maps:get({Iface, Field}, Resolve([{Iface, Field}]), undefined) of
        undefined -> missing({Iface, Field}, S);
        Fun       -> {ok, Fun}
    end;
host_fun({import_func, Name}, _S) ->
    {error, {unsupported, {comp_func_import, Name}}};
host_fun({lift, _CoreFuncIdx}, _S) ->
    {error, {unsupported, lower_of_lift}}.

%% A lowered host function runs with the guest instance as its context (for its
%% shared memory: the adapter's lowering memory is the guest's, and both cores
%% share it) and, for a result that allocates, with the realloc the lower's
%% options name (the adapter's own, reached indirectly through the shim table, not
%% by name on any single instance). Before any core is built (a single-core
%% component) there is no guest to bind, so the function keeps its own context.
lowered(Fun, _Realloc, #{entry_by_mod := undefined}) ->
    Fun;
lowered(Fun, Realloc, #{entry_by_mod := Guest}) ->
    fun(Ctx, Flats) ->
        wasm_canon:with_realloc(Realloc,
                                fun() -> Fun(Ctx#{instance => Guest}, Flats) end)
    end.

%% The realloc function a lower names, as a callable, or `undefined` when the
%% lower has no realloc (its result does not allocate).
realloc_callable(none, _S) ->
    undefined;
realloc_callable(Idx, S) ->
    case maps:get(Idx, maps:get(core_funcs, S), undefined) of
        {wasm_func, Fun, _Type}    -> Fun;
        Fun when is_function(Fun)  -> Fun;
        _                          -> undefined
    end.

%% An import the host set does not cover. The preview1 adapter lowers the whole
%% preview2 surface, so a program that uses one interface still names them all; a
%% caller running such a component (`stub => true`) fills the unused ones with a
%% function that traps only if actually called, rather than failing to link.
%% Otherwise it is a named error, so a real missing import is visible.
missing(Key, S) ->
    case maps:get(stub, maps:get(opts, S), false) of
        true  -> {ok, fun(_Ctx, _Args) -> {trap, {unimplemented_import, Key}} end};
        false -> {error, {unresolved_import, Key}}
    end.

%% Identity handle intrinsics for `canon resource.{new,drop,rep}`; the host owns
%% real resource state elsewhere, so these just pass the handle through.
resource_fun(new)  -> fun(_Ctx, [Rep])    -> {ok, [Rep]} end;
resource_fun(drop) -> fun(_Ctx, [_Handle]) -> {ok, []} end;
resource_fun(rep)  -> fun(_Ctx, [Handle]) -> {ok, [Handle]} end.

%% The value of core instance `InstIdx`'s export `Name`: an `extern()` from a real
%% instance, or the stored value of a synthetic one.
export_val(S, InstIdx, Name) ->
    case maps:get(InstIdx, maps:get(core_insts, S), undefined) of
        {real, Inst} ->
            wasm:extern(Inst, Name);
        {synthetic, Map} ->
            case maps:find(Name, Map) of
                {ok, Val} -> {ok, Val};
                error     -> {error, {unknown_export, InstIdx, Name}}
            end;
        undefined ->
            {error, {unknown_core_instance, InstIdx}}
    end.

%% A synthetic instance groups already-built index-space items under names.
synthetic(Entries, S) ->
    synthetic(Entries, S, #{}).

synthetic([], _S, Map) ->
    {ok, Map};
synthetic([{Name, Sort, Idx} | Rest], S, Map) ->
    Space = space_of(Sort),
    case maps:get(Idx, maps:get(Space, S), undefined) of
        undefined -> {error, {unknown_index, Sort, Idx}};
        Val       -> synthetic(Rest, S, Map#{Name => Val})
    end.

space_of(func)   -> core_funcs;
space_of(memory) -> core_mems;
space_of(table)  -> core_tables;
space_of(global) -> core_globals.

%% Build a core instance's imports from its `with` args and instantiate it,
%% sharing one store across the component's cores.
instantiate_core(ModIdx, Args, S) ->
    Bytes = element(ModIdx + 1, maps:get(mods, S)),
    case imports_for(core_imports(Bytes), maps:from_list(Args), S) of
        {ok, ImportMap} ->
            Opts = maps:get(opts, S),
            Loader = maps:get(loader, Opts, load),
            Limits = link_to(maps:get(anchor, S), maps:without([loader, stub], Opts)),
            case load_core(Loader, Bytes) of
                {ok, Mod} ->
                    case wasm:instantiate(Mod, ImportMap, Limits) of
                        {ok, Inst}     -> {ok, record_inst(S, ModIdx, Inst)};
                        {error, _} = E -> E
                    end;
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%% One import at a time: from the source core instance the args name for its
%% namespace, or, for a namespace with no arg, straight from the host set.
imports_for(CoreImports, ArgsMap, S) ->
    imports_for(CoreImports, ArgsMap, S, #{}).

imports_for([], _ArgsMap, _S, Acc) ->
    {ok, Acc};
imports_for([{NS, Name} = Key | Rest], ArgsMap, S, Acc) ->
    Result = case maps:get(NS, ArgsMap, undefined) of
                 undefined -> host_import(Key, S);
                 SrcIdx    -> export_val(S, SrcIdx, Name)
             end,
    case Result of
        {ok, Val}      -> imports_for(Rest, ArgsMap, S, Acc#{Key => Val});
        {error, _} = E -> E
    end.

host_import(Key, S) ->
    Resolve = maps:get(resolve, S),
    case maps:get(Key, Resolve([Key]), undefined) of
        undefined -> missing(Key, S);
        Val       -> {ok, Val}
    end.

%% Add a real instance to the index space; the first starts the shared store, and
%% the instance built from the entry module is the reactor fallback entry.
record_inst(S, ModIdx, Inst) ->
    S1 = add_inst(S, {real, Inst}),
    S2 = S1#{built => [Inst | maps:get(built, S1)]},
    S3 = case maps:get(anchor, S2) of
             undefined -> S2#{anchor => Inst};
             _         -> S2
         end,
    case ModIdx =:= maps:get(entry_mod, S3) andalso
         maps:get(entry_by_mod, S3) =:= undefined of
        true  -> S3#{entry_by_mod => Inst};
        false -> S3
    end.

add_inst(S, Entry) ->
    N = maps:get(n_ci, S),
    S#{n_ci => N + 1, core_insts => maps:put(N, Entry, maps:get(core_insts, S))}.

link_to(undefined, Limits) -> Limits;
link_to(Anchor, Limits)    -> Limits#{link => Anchor}.

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

%%% --------------------------------------------------------------------- canon ---

%% `0x00 0x00 f opts ft` lift (a component func over core func `f`);
%% `0x01 0x00 f opts` lower (a core func over component func `f`);
%% `0x02/03/04 rt` resource new/drop/rep (a core func). `opts` is skipped: the
%% linker binds host functions by name and does not read the ABI options here.
canon(<<16#00, 16#00, R0/binary>>) ->
    {F, R1} = wasm_leb128:u32(R0),
    R2 = canonopts(R1),
    {_Ft, R3} = wasm_leb128:u32(R2),
    {{canon_lift, F}, R3};
canon(<<16#01, 16#00, R0/binary>>) ->
    {F, R1} = wasm_leb128:u32(R0),
    {Realloc, R2} = lower_opts(R1),
    {{canon_lower, F, Realloc}, R2};
canon(<<16#02, R0/binary>>) ->
    {Rt, R1} = wasm_leb128:u32(R0),
    {{canon_resource, new, Rt}, R1};
canon(<<16#03, R0/binary>>) ->
    {Rt, R1} = wasm_leb128:u32(R0),
    {{canon_resource, drop, Rt}, R1};
canon(<<16#04, R0/binary>>) ->
    {Rt, R1} = wasm_leb128:u32(R0),
    {{canon_resource, rep, Rt}, R1}.

%% A vec of canonopt; step over each. `0x00/01/02` are flags (no operand);
%% `0x03 m`, `0x04 f`, `0x05 f`, `0x07 f` carry an index; `0x06`/`0x08` none.
canonopts(Bin) ->
    {Count, Rest} = wasm_leb128:u32(Bin),
    canonopts(Count, Rest).

canonopts(0, Rest) ->
    Rest;
canonopts(N, <<Op, Rest0/binary>>) when Op =:= 16#03; Op =:= 16#04;
                                        Op =:= 16#05; Op =:= 16#07 ->
    {_Idx, Rest1} = wasm_leb128:u32(Rest0),
    canonopts(N - 1, Rest1);
canonopts(N, <<_Op, Rest0/binary>>) ->
    canonopts(N - 1, Rest0).

%% A lower's options, keeping the realloc function index (`0x04 f`); a result that
%% crosses by memory (a string or list) allocates through it, and the adapter
%% names its own realloc, not one reachable on the instance calling the import.
lower_opts(Bin) ->
    {Count, Rest} = wasm_leb128:u32(Bin),
    lower_opts(Count, Rest, none).

lower_opts(0, Rest, Realloc) ->
    {Realloc, Rest};
lower_opts(N, <<16#04, Rest0/binary>>, _Realloc) ->
    {Idx, Rest1} = wasm_leb128:u32(Rest0),
    lower_opts(N - 1, Rest1, Idx);
lower_opts(N, <<Op, Rest0/binary>>, Realloc) when Op =:= 16#03; Op =:= 16#05;
                                                  Op =:= 16#07 ->
    {_Idx, Rest1} = wasm_leb128:u32(Rest0),
    lower_opts(N - 1, Rest1, Realloc);
lower_opts(N, <<_Op, Rest0/binary>>, Realloc) ->
    lower_opts(N - 1, Rest0, Realloc).

%%% ---------------------------------------------------------- component import ---

%% `namekind name externdesc`. Only the instance and function forms are wired
%% (the adapter imports WASI interfaces as instances); each names the interface
%% or field its index later binds to a host function.
comp_import(<<16#00, R0/binary>>) ->
    {Name, R1} = name(R0),
    externdesc(Name, R1).

externdesc(Name, <<16#05, R0/binary>>) ->
    {_TypeIdx, R1} = wasm_leb128:u32(R0),
    {{comp_import_instance, Name}, R1};
externdesc(Name, <<16#01, R0/binary>>) ->
    {_TypeIdx, R1} = wasm_leb128:u32(R0),
    {{comp_import_func, Name}, R1}.

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
