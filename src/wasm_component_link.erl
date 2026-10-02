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

-export([parse/1, link/4, core_imports/1, export_map/1, export_encodings/1,
         export_bindings/1, exports_resolve_on_entry/2, validate_lifts/2]).

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
      | {canon_lower, non_neg_integer(), non_neg_integer() | none,
         string_encoding(), async_mark()}
      | {canon_lift, non_neg_integer(), string_encoding(), async_mark(),
         non_neg_integer() | none, non_neg_integer() | none, non_neg_integer()}
      | {canon_async, atom(), map()}
      | {canon_resource, new | drop | rep, non_neg_integer()}
      | {comp_import_instance, binary()}
      | {comp_import_func, binary()}
      | {comp_export, binary(), byte(), non_neg_integer()}.

-type core_sort() :: func | table | memory | global.

%% The `string-encoding` canon option. This runtime marshals strings as UTF-8, the
%% encoding every WASI toolchain emits; a canon def declaring another is refused at
%% link time rather than silently mis-decoded.
-type string_encoding() :: utf8 | utf16 | latin1_utf16.

%% A lift/lower is `sync`, or `{async, Callback}` where Callback is the callback core
%% function index (or `none` for the stackful async lift with no callback).
-type async_mark() :: sync | {async, non_neg_integer() | none}.

-type graph() :: [item()].

-define(SEC_CORE_MODULE, 1).
-define(SEC_CORE_INSTANCE, 2).
-define(SEC_COMPONENT, 4).
-define(SEC_COMP_INSTANCE, 5).
-define(SEC_ALIAS, 6).
-define(SEC_CANON, 8).
-define(SEC_COMP_IMPORT, 10).
-define(SEC_EXPORT, 11).

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
%% A nested component definition: the content is itself a full component binary
%% (its own `\0asm` preamble and sections), so composition can instantiate it
%% recursively. Component composition (`wac`) produces these.
section(?SEC_COMPONENT, Content) ->
    {ok, [{component_def, Content}]};
section(?SEC_COMP_INSTANCE, Content) ->
    vec(Content, fun comp_instance/1, fun(E) -> E end);
section(?SEC_ALIAS, Content) ->
    vec(Content, fun alias_entry/1, fun(E) -> E end);
section(?SEC_CANON, Content) ->
    vec(Content, fun canon/1, fun(E) -> E end);
section(?SEC_COMP_IMPORT, Content) ->
    vec(Content, fun comp_import/1, fun(E) -> E end);
section(?SEC_EXPORT, Content) ->
    %% Export entries are advisory for linking (see `export_map/1`); an entry shape
    %% this parser does not read must not break the whole parse, so a failure here
    %% yields no export items rather than raising.
    try vec(Content, fun comp_export/1, fun(E) -> E end)
    catch
        _:_ -> {ok, []}
    end;
section(_Other, _Content) ->
    {ok, []}.

%% A component export: a name, a sort byte, an index into that sort's space, and an
%% optional type ascription (`0x00` absent, the toolchain-common case). Consuming the
%% ascription is what keeps a section with more than one export aligned; without it the
%% first export parses and the next reads from the wrong offset.
%% Only func exports (sort 1) are resolved to a core function; the rest are carried so
%% linking can skip them without misreading the section.
comp_export(<<_Kind, R0/binary>>) ->
    {Len, R1} = wasm_leb128:u32(R0),
    <<Name:Len/binary, R2/binary>> = R1,
    <<Sort, R3/binary>> = R2,
    {Idx, R4} = wasm_leb128:u32(R3),
    {{comp_export, Name, Sort, Idx}, skip_export_desc(R4)}.

%% The optional type ascription after an export's sortidx: `0x00` absent (all the standard
%% toolchain emits, and what a hand-authored component uses). A present one (`0x01 ...`)
%% is left for the next entry rather than misparsed; that shape has not been observed.
skip_export_desc(<<16#00, Rest/binary>>) -> Rest;
skip_export_desc(Rest)                   -> Rest.

-doc """
Map each component func export name to the core function that implements it.

Resolves the export section (name -> component-func index) through the graph
(component-func index -> `canon lift` of a core-func index -> the core alias'
export name), so an export renamed from its core function is callable by its
component name. An export that does not resolve to a lifted core function (an
instance export, an imported function) is omitted, and the caller falls back to the
name it was given.
""".
-spec export_map(binary()) -> #{binary() => binary()}.
export_map(Sec) ->
    %% Never fail: an export section this parser cannot read yields an empty map, and
    %% the caller falls back to calling the export by its own name.
    try
        case parse(Sec) of
            {ok, Graph} ->
                {CompFuncs, CoreNames} = index_spaces(Graph),
                maps:from_list(
                  [{Name, CoreName}
                   || {comp_export, Name, 1, Idx} <- Graph,
                      {lift, CFI} <- [maps:get(Idx, CompFuncs, undefined)],
                      CoreName <- [maps:get(CFI, CoreNames, undefined)],
                      is_binary(CoreName)]);
            {error, _} ->
                #{}
        end
    catch
        _:_ -> #{}
    end.

-doc """
Whether the largest-core fast path resolves every exported function correctly.

`true` only when every exported lift that names a core-func alias targets a core
instance of the entry module `EntryModIdx`. When it is `false`, an export's lift
names a core other than the largest, so the caller must interpret the full graph
(build every core, dispatch each export to the instance its lift names) rather
than call the largest core by export name. Tolerant: a graph it cannot read, or a
lift it cannot pin to an alias, yields `true` (the fast path, unchanged).
""".
-spec exports_resolve_on_entry(binary(), non_neg_integer()) -> boolean().
exports_resolve_on_entry(Sec, EntryModIdx) ->
    try
        case parse(Sec) of
            {ok, Graph} ->
                {CompFuncs, AliasInst} = alias_spaces(Graph),
                InstMods = inst_modules(Graph),
                lists:all(
                  fun({comp_export, _Name, 1, Idx}) ->
                          export_on_entry(Idx, CompFuncs, AliasInst, InstMods, EntryModIdx);
                     (_Other) ->
                          true
                  end, Graph);
            {error, _} ->
                true
        end
    catch
        _:_ -> true
    end.

-doc """
Statically check every `canon lift` against its declared component function type.

For each lift the Canonical ABI derives a core signature from the component
function type it declares (params flatten and, past 16 slots, spill to one
pointer; a result of more than one core value returns through a pointer). That
derived signature must equal the core function's own type, read from the module
bytes without instantiating anything. `{error, {invalid_lift_type, _}}` when a
lift declares a type its core function cannot have (e.g. lifting a core `f64` as a
component `u32`), so the component is rejected before any core runs. Tolerant: a
graph, type or core it cannot read yields `ok`, leaving instantiation to fail (or
succeed) as before rather than block on an unreadable input.

`CoreMods` is the component's core module bytes in module-index order.
""".
-spec validate_lifts(binary(), [binary()]) -> ok | {error, term()}.
validate_lifts(Sec, CoreMods) ->
    try
        case parse(Sec) of
            {ok, Graph} ->
                {_CompF, CoreNames} = index_spaces(Graph),
                {_CompF2, AliasInst} = alias_spaces(Graph),
                InstMods = inst_modules(Graph),
                Types = wasm_component_types:parse_types(Sec),
                Mods = list_to_tuple(CoreMods),
                check_lifts(Graph, CoreNames, AliasInst, InstMods, Types, Mods);
            {error, _} ->
                ok
        end
    catch
        _:_ -> ok
    end.

check_lifts([], _CoreNames, _AliasInst, _InstMods, _Types, _Mods) ->
    ok;
check_lifts([{canon_lift, CFI, _Enc, _Async, _Rl, _P, Ft} | Rest],
            CoreNames, AliasInst, InstMods, Types, Mods) ->
    case lift_signatures(CFI, Ft, CoreNames, AliasInst, InstMods, Types, Mods) of
        skip ->
            check_lifts(Rest, CoreNames, AliasInst, InstMods, Types, Mods);
        {Expected, Expected} ->
            check_lifts(Rest, CoreNames, AliasInst, InstMods, Types, Mods);
        {Expected, Actual} ->
            {error, {invalid_lift_type,
                     #{core_func => maps:get(CFI, CoreNames, CFI),
                       expected => Expected, actual => Actual}}}
    end;
check_lifts([_Other | Rest], CoreNames, AliasInst, InstMods, Types, Mods) ->
    check_lifts(Rest, CoreNames, AliasInst, InstMods, Types, Mods).

%% The declared (expected) and actual core signatures of one lift, or `skip` when
%% any piece is missing (a non-alias core func, an unresolvable module, a component
%% type that is not a function type): the lift is then left unchecked.
lift_signatures(CFI, Ft, CoreNames, AliasInst, InstMods, Types, Mods) ->
    case {maps:get(CFI, CoreNames, undefined), maps:get(CFI, AliasInst, undefined),
          maps:get(Ft, Types, undefined)} of
        {Name, InstIdx, {func, Params, Result}}
          when is_binary(Name), is_integer(InstIdx) ->
            ModIdx = maps:get(InstIdx, InstMods, undefined),
            case module_bytes(ModIdx, Mods) of
                {ok, Bytes} ->
                    case wasm:func_type_of(Bytes, Name) of
                        {ok, Actual} -> {derive_lift_sig(Params, Result), Actual};
                        {error, _}   -> skip
                    end;
                error ->
                    skip
            end;
        _ ->
            skip
    end.

module_bytes(ModIdx, Mods)
  when is_integer(ModIdx), ModIdx >= 0, ModIdx < tuple_size(Mods) ->
    {ok, element(ModIdx + 1, Mods)};
module_bytes(_ModIdx, _Mods) ->
    error.

%% The core signature the Canonical ABI derives from a lift's component params and
%% result: params flatten, spilling to one i32 pointer past MAX_FLAT_PARAMS; a
%% result of more than one core value returns through an i32 pointer.
derive_lift_sig(Params, Result) ->
    ExpParams = case wasm_canon:params_spill(Params) of
                    true  -> [i32];
                    false -> lists:append([wasm_canon:flat_types(P) || P <- Params])
                end,
    ExpResults = case Result of
                     none -> [];
                     _    -> case wasm_canon:result_via_memory(Result) of
                                 true  -> [i32];
                                 false -> wasm_canon:flat_types(Result)
                             end
                 end,
    {ExpParams, ExpResults}.

export_on_entry(Idx, CompFuncs, AliasInst, InstMods, EntryModIdx) ->
    case maps:get(Idx, CompFuncs, undefined) of
        {lift, CFI} ->
            case maps:get(CFI, AliasInst, undefined) of
                undefined -> true;  %% not an alias-backed lift; the entry core covers it
                InstIdx   -> maps:get(InstIdx, InstMods, EntryModIdx) =:= EntryModIdx
            end;
        _ ->
            true
    end.

%% The component-func index space and, for each core-func alias, the core instance
%% it aliases, in the same order `index_step`/`step` assign indices.
alias_spaces(Graph) ->
    {CompF, AliasInst, _PF, _CF} =
        lists:foldl(fun alias_step/2, {#{}, #{}, 0, 0}, Graph),
    {CompF, AliasInst}.

alias_step({comp_import_func, _}, {CF, AI, PF, C}) -> {CF#{PF => import}, AI, PF + 1, C};
alias_step({comp_func_alias, _, _}, {CF, AI, PF, C}) -> {CF#{PF => alias}, AI, PF + 1, C};
alias_step({canon_lift, CFI, _, _, _, _, _}, {CF, AI, PF, C}) -> {CF#{PF => {lift, CFI}}, AI, PF + 1, C};
alias_step({canon_lower, _, _, _, _}, {CF, AI, PF, C}) -> {CF, AI, PF, C + 1};
alias_step({canon_async, _, _}, {CF, AI, PF, C}) -> {CF, AI, PF, C + 1};
alias_step({canon_resource, _, _}, {CF, AI, PF, C}) -> {CF, AI, PF, C + 1};
alias_step({core_alias, func, InstIdx, _Name}, {CF, AI, PF, C}) -> {CF, AI#{C => InstIdx}, PF, C + 1};
alias_step(_Other, Acc) -> Acc.

%% Core-instance index -> the module it instantiates, in `step`'s core-instance
%% order (both `instantiate` and `exports` instances take an index; a synthetic
%% `exports` instance names no single module and is omitted).
inst_modules(Graph) ->
    {_N, Map} = lists:foldl(fun inst_mod_step/2, {0, #{}}, Graph),
    Map.

inst_mod_step({core_instance, {instantiate, ModIdx, _Args}}, {N, Map}) ->
    {N + 1, Map#{N => ModIdx}};
inst_mod_step({core_instance, {exports, _Entries}}, {N, Map}) ->
    {N + 1, Map};
inst_mod_step(_Other, Acc) ->
    Acc.

-doc """
Each exported function's string encoding, when it is not the default UTF-8.

A component's `canon lift` carries a `string-encoding` option; `call/4` marshals that
export's strings with it. Returns `#{ExportName => utf16 | latin1_utf16}`, omitting UTF-8
exports (the default), so the common component adds nothing.
""".
-spec export_encodings(binary()) -> #{binary() => string_encoding()}.
export_encodings(Sec) ->
    try
        case parse(Sec) of
            {ok, Graph} ->
                Encs = comp_func_encodings(Graph),
                maps:from_list(
                  [{Name, Enc}
                   || {comp_export, Name, 1, Idx} <- Graph,
                      Enc <- [maps:get(Idx, Encs, utf8)],
                      Enc =/= utf8]);
            {error, _} ->
                #{}
        end
    catch
        _:_ -> #{}
    end.

%% The component-func index space mapped to each lift's string encoding, in the order
%% `step/2` assigns func indices (import-func, func-alias and lift each take one).
comp_func_encodings(Graph) ->
    {_PF, Encs} = lists:foldl(fun cfe_step/2, {0, #{}}, Graph),
    Encs.

cfe_step({comp_import_func, _}, {PF, E})        -> {PF + 1, E};
cfe_step({comp_func_alias, _, _}, {PF, E})      -> {PF + 1, E};
cfe_step({canon_lift, _CFI, Enc, _Async, _Rl, _P, _Ft}, {PF, E}) -> {PF + 1, E#{PF => Enc}};
cfe_step(_Other, Acc)                           -> Acc.

-doc """
Each exported function's declared realloc and post-return, as core export names.

A `canon lift` names the allocator and cleanup the runtime must use; `call/4` allocates
through that realloc and runs that post-return rather than guessing `cabi_realloc`/
`cabi_post_<export>`. Returns `#{ExportName => #{realloc => Name | none, post_return =>
Name | none}}`, omitting exports whose lift declares neither.
""".
-spec export_bindings(binary()) ->
          #{binary() => #{realloc => binary() | none, post_return => binary() | none}}.
export_bindings(Sec) ->
    try
        case parse(Sec) of
            {ok, Graph} ->
                {_CompFuncs, CoreNames} = index_spaces(Graph),
                Lifts = lift_bindings(Graph),
                maps:from_list(
                  [{Name, binding_of(maps:get(Idx, Lifts), CoreNames)}
                   || {comp_export, Name, 1, Idx} <- Graph,
                      maps:is_key(Idx, Lifts),
                      binding_of(maps:get(Idx, Lifts), CoreNames) =/=
                          #{realloc => none, post_return => none}]);
            {error, _} ->
                #{}
        end
    catch
        _:_ -> #{}
    end.

%% The component-func index space mapped to each lift's {realloc, post-return} core-func
%% indices, in the same order `step/2` assigns func indices.
lift_bindings(Graph) ->
    {_PF, M} = lists:foldl(fun lb_step/2, {0, #{}}, Graph),
    M.

lb_step({comp_import_func, _}, {PF, M})   -> {PF + 1, M};
lb_step({comp_func_alias, _, _}, {PF, M}) -> {PF + 1, M};
lb_step({canon_lift, _CFI, _Enc, _Async, Rl, P, _Ft}, {PF, M}) -> {PF + 1, M#{PF => {Rl, P}}};
lb_step(_Other, Acc)                      -> Acc.

binding_of({RlIdx, PIdx}, CoreNames) ->
    #{realloc => name_of(RlIdx, CoreNames), post_return => name_of(PIdx, CoreNames)}.

name_of(none, _CoreNames) -> none;
name_of(Idx, CoreNames)   -> maps:get(Idx, CoreNames, none).

%% Fold the graph into the component-func index space (index -> what implements it)
%% and the core-func index space (index -> the core export name it aliases), in the
%% same order `step/2` assigns them.
index_spaces(Graph) ->
    {CompF, CoreN, _PF, _CF} =
        lists:foldl(fun index_step/2, {#{}, #{}, 0, 0}, Graph),
    {CompF, CoreN}.

index_step({comp_import_func, _}, {CompF, CoreN, PF, CF}) ->
    {CompF#{PF => import}, CoreN, PF + 1, CF};
index_step({comp_func_alias, _, _}, {CompF, CoreN, PF, CF}) ->
    {CompF#{PF => alias}, CoreN, PF + 1, CF};
index_step({canon_lift, CFI, _Enc, _Async, _Rl, _P, _Ft}, {CompF, CoreN, PF, CF}) ->
    {CompF#{PF => {lift, CFI}}, CoreN, PF + 1, CF};
index_step({canon_lower, _, _, _, _}, {CompF, CoreN, PF, CF}) ->
    {CompF, CoreN, PF, CF + 1};
index_step({canon_async, _, _}, {CompF, CoreN, PF, CF}) ->
    {CompF, CoreN, PF, CF + 1};
index_step({canon_resource, _, _}, {CompF, CoreN, PF, CF}) ->
    {CompF, CoreN, PF, CF + 1};
index_step({core_alias, func, _InstIdx, Name}, {CompF, CoreN, PF, CF}) ->
    {CompF, CoreN#{CF => Name}, PF, CF + 1};
index_step(_Other, Acc) ->
    Acc.

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
          {ok, #{core := wasm:instance(), cores := [wasm:instance()],
                 export_targets := #{binary() => {wasm:instance(), binary()}}}}
          | {error, term()}.
link(Graph, EntryModIdx, HostResolve, Opts) ->
    S0 = #{mods => list_to_tuple([B || {core_module, B} <- Graph]),
           resolve => HostResolve, opts => Opts, anchor => undefined,
           core_insts => #{}, n_ci => 0, core_funcs => #{}, n_cf => 0,
           core_mems => #{}, n_cm => 0, core_tables => #{}, n_ct => 0,
           core_globals => #{}, n_cg => 0, comp_insts => #{}, n_pi => 0,
           comp_funcs => #{}, n_pf => 0, built => [], entry_mod => EntryModIdx,
           entry_by_mod => undefined, run_inst => undefined,
           core_func_target => #{},
           %% The resource types this component DEFINES (a `resource.new` names
           %% only a defined type). Liveness is enforced on drop/rep of these; an
           %% imported or host resource (a WASI stream) is not a defined type and
           %% its drop passes straight through, as before.
           defined_rts => [Rt || {canon_resource, new, Rt} <- Graph]},
    case fold(Graph, S0) of
        {ok, S} ->
            Built = lists:reverse(maps:get(built, S)),
            case entry(S) of
                {ok, Core}     -> {ok, #{core => Core, cores => Built,
                                         export_targets => export_targets(Graph, S)}};
                {error, _} = E -> destroy_built(S), E
            end;
        {error, Reason, S} ->
            destroy_built(S),
            {error, Reason}
    end.

%% Record which real core instance a core-func alias resolved to, keyed by the
%% core-func index it takes. A synthetic or as-yet-unbuilt source records nothing;
%% the export then falls back to name resolution, as before.
record_func_target(S, CFI, InstIdx, Name) ->
    case maps:get(InstIdx, maps:get(core_insts, S), undefined) of
        {real, Inst} ->
            T = maps:get(core_func_target, S),
            S#{core_func_target => T#{CFI => {Inst, Name}}};
        _ ->
            S
    end.

%% Resolve each exported function to the `{Inst, CoreName}` its declared lift names,
%% authoritative over export-name matching (two cores can export the same name). An
%% export whose lift the linker could not pin to a real instance is omitted, so the
%% caller keeps its name-based fallback for it.
export_targets(Graph, S) ->
    CompFuncs = maps:get(comp_funcs, S),
    Targets = maps:get(core_func_target, S),
    maps:from_list(
      [{Name, Target}
       || {comp_export, Name, 1, Idx} <- Graph,
          {lift, CFI} <- [maps:get(Idx, CompFuncs, undefined)],
          Target <- [maps:get(CFI, Targets, undefined)],
          Target =/= undefined]).

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
%% Composition items (a nested component definition, its instantiation, a synthetic
%% instance) are handled by `wasm_component:instantiate_composed`, not the core linker.
%% A core-linked component that reaches `link/4` carries them only incidentally and they
%% wire nothing here; skipping them without indexing keeps this exactly as it was when
%% these sections were dropped before parsing recognised them (the component-instance
%% index space the aliases here reference is the imported instances, declared first).
step({component_def, _}, S) ->
    {ok, S};
step({comp_instantiate, _CompIdx, _Args}, S) ->
    {ok, S};
step({comp_inst_exports, _Exports}, S) ->
    {ok, S};
step({comp_instance_alias, _InstIdx, _Name}, S) ->
    {ok, S};
step({comp_export, _Name, _Sort, _Idx}, S) ->
    %% Export entries name what the component offers; they do not wire anything, so
    %% linking skips them (`export_map/1` reads them instead).
    {ok, S};
step({comp_import_instance, Name}, S) ->
    {ok, bump(S, n_pi, comp_insts, Name)};
step({comp_import_func, Name}, S) ->
    {ok, bump(S, n_pf, comp_funcs, {import_func, Name})};
step({comp_func_alias, InstIdx, Field}, S) ->
    Iface = maps:get(InstIdx, maps:get(comp_insts, S)),
    {ok, bump(S, n_pf, comp_funcs, {host, Iface, Field})};
step({canon_lift, CoreFuncIdx, Enc, _Async, _Rl, _P, _Ft}, S) ->
    case supported_encoding(Enc) of
        ok             -> {ok, bump(S, n_pf, comp_funcs, {lift, CoreFuncIdx})};
        {error, _} = E -> E
    end;
step({canon_lower, CompFuncIdx, ReallocIdx, Enc, Async}, S) ->
    case supported_encoding(Enc) of
        {error, _} = E ->
            E;
        ok ->
            case host_fun(maps:get(CompFuncIdx, maps:get(comp_funcs, S)), S) of
                {ok, {async_import, Sig, Fun, {producer, PFun}}} ->
                    %% A suspending async import: completes later via a subtask event.
                    {ok, bump(S, n_cf, core_funcs, wasm_async:async_lower(Sig, Fun, PFun))};
                {ok, {async_import, Sig, Fun}} ->
                    %% An async import: the guest calls it expecting a subtask status.
                    {ok, bump(S, n_cf, core_funcs, wasm_async:async_lower(Sig, Fun))};
                {ok, Fun} when Async =:= sync ->
                    Realloc = realloc_callable(ReallocIdx, S),
                    {ok, bump(S, n_cf, core_funcs, lowered(Fun, Realloc, Enc, S))};
                {ok, _Fun} ->
                    {error, {async_import_not_registered, CompFuncIdx}};
                {error, _} = E ->
                    E
            end
    end;
step({canon_async, Which, Meta}, S) ->
    %% Each async built-in is a core function the guest imports; bind it to the
    %% `wasm_async` runtime (a task is a BEAM process, a wait a selective receive).
    {ok, bump(S, n_cf, core_funcs, wasm_async:builtin(Which, Meta))};
step({canon_resource, drop, Rt}, S) ->
    %% `canon resource.drop` runs the drop function the caller supplied (which closes
    %% a host resource and forgets its handle), so a guest that drops a socket or file
    %% frees it at once instead of leaking until the instance is destroyed. With no
    %% drop function it stays a no-op (the destroy-time sweep still frees everything).
    %% For a resource this component DEFINES, the handle's liveness is checked first,
    %% so dropping one twice or dropping a never-minted handle traps.
    Drop = maps:get(drop_fun, maps:get(opts, S), fun(_H) -> ok end),
    Defined = lists:member(Rt, maps:get(defined_rts, S, [])),
    Fun = fun(_Ctx, [H]) -> resource_drop(Defined, H, Drop) end,
    {ok, bump(S, n_cf, core_funcs, Fun)};
step({canon_resource, new, Rt}, S) ->
    %% A defined resource: record the handle live in the current instance so a later
    %% drop or rep can tell a live handle from a dropped or bogus one.
    Fun = fun(_Ctx, [Rep]) -> wasm_resources:track(Rep, Rt), {ok, [Rep]} end,
    {ok, bump(S, n_cf, core_funcs, Fun)};
step({canon_resource, rep, Rt}, S) ->
    Defined = lists:member(Rt, maps:get(defined_rts, S, [])),
    Fun = fun(_Ctx, [H]) -> resource_rep(Defined, H) end,
    {ok, bump(S, n_cf, core_funcs, Fun)};
step({core_alias, func, InstIdx, Name}, S) ->
    case export_val(S, InstIdx, Name) of
        {ok, Val} ->
            %% Remember which real instance this core-func index resolved to, keyed
            %% by the core-func index `bump` is about to assign, so an exported lift
            %% of it dispatches to that exact instance.
            S1 = record_func_target(S, maps:get(n_cf, S), InstIdx, Name),
            {ok, note_run(Name, InstIdx, bump(S1, n_cf, core_funcs, Val))};
        {error, _} = E ->
            E
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
lowered(Fun, Realloc, Enc, S) ->
    Bound = bind_realloc(Fun, Realloc, S),
    %% Strings this import lifts and lowers use the lower's string encoding; utf8 installs
    %% no context, so the common case is exactly the realloc-bound function above.
    case Enc of
        utf8 -> Bound;
        _    -> fun(Ctx, Flats) ->
                    wasm_canon:with_string_encoding(
                      Enc, fun() -> Bound(Ctx, Flats) end)
                end
    end.

bind_realloc(Fun, _Realloc, #{entry_by_mod := undefined}) ->
    Fun;
bind_realloc(Fun, Realloc, #{entry_by_mod := Guest}) ->
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

%% An import the host set does not cover is a link-time error naming the interface
%% and function, so an unresolved import is a clean value at link time rather than a
%% trap when the guest first calls it. The whole WASI 0.2 surface is implemented, so
%% a real program links without any placeholder imports.
missing(Key, _S) ->
    {error, {unresolved_import, Key}}.

%% `canon resource.drop`. For a defined resource the handle must be live in the
%% current instance; a double drop or a drop of a never-minted handle traps.
%% Dropping a live one forgets it and runs the host drop (which closes a socket or
%% file). A handle of a type this component does not define (an imported or host
%% resource) is not tracked here, so it passes straight to the host drop as before.
resource_drop(true, H, Drop) ->
    case wasm_resources:drop(H) of
        error ->
            wasm_error:trap(resource_not_live, #{handle => H, operation => drop});
        {ok, _Kind} ->
            case Drop(H) of
                {trap, _} = Trap -> Trap;
                _                -> {ok, []}
            end
    end;
resource_drop(false, H, Drop) ->
    case Drop(H) of
        {trap, _} = Trap -> Trap;
        _                -> {ok, []}
    end.

%% `canon resource.rep`. For a defined resource the handle must be live, so reading
%% the representation of a dropped or bogus handle traps; otherwise it passes
%% through (the representation is the handle in the identity model).
resource_rep(true, H) ->
    case wasm_resources:lookup(H) of
        {ok, _Rt} -> {ok, [H]};
        error     -> wasm_error:trap(resource_not_live, #{handle => H, operation => rep})
    end;
resource_rep(false, H) ->
    {ok, [H]}.

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
            Limits = link_to(maps:get(anchor, S), maps:without([loader], Opts)),
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
    {{exports, Exports}, Rest1};
core_instance(<<Tag, _/binary>>) ->
    wasm_error:link_error(unsupported_core_instance,
                          <<"unsupported core instance form">>, #{tag => Tag}).

%% A component instance is either the instantiation of a component (`0x00 compidx args`)
%% or a synthetic instance collecting named exports (`0x01 exports`). Each `arg` is a
%% `name` and a sort-indexed reference (its bytes are consumed so parsing reaches the
%% next); argument wiring beyond consuming them is composition's job.
comp_instance(<<16#00, Rest0/binary>>) ->
    {CompIdx, Rest1} = wasm_leb128:u32(Rest0),
    {Args, Rest2} = comp_inst_args(Rest1),
    {{comp_instantiate, CompIdx, Args}, Rest2};
comp_instance(<<16#01, Rest0/binary>>) ->
    {Exports, Rest1} = comp_inline_exports(Rest0),
    {{comp_inst_exports, Exports}, Rest1};
comp_instance(<<Tag, _/binary>>) ->
    wasm_error:link_error(unsupported_component_instance,
                          <<"unsupported component instance form">>, #{tag => Tag}).

comp_inst_args(Bin) ->
    {Count, Rest} = wasm_leb128:u32(Bin),
    comp_inst_args(Count, Rest, []).

comp_inst_args(0, Rest, Acc) ->
    {lists:reverse(Acc), Rest};
comp_inst_args(N, Bin, Acc) ->
    {Name, Rest0} = name(Bin),
    %% `sort:byte idx:u32` reference; keep the name and the (sort, idx) pair.
    <<Sort, Rest1/binary>> = Rest0,
    {Idx, Rest2} = wasm_leb128:u32(Rest1),
    comp_inst_args(N - 1, Rest2, [{Name, Sort, Idx} | Acc]).

comp_inline_exports(Bin) ->
    {Count, Rest} = wasm_leb128:u32(Bin),
    comp_inline_exports(Count, Rest, []).

comp_inline_exports(0, Rest, Acc) ->
    {lists:reverse(Acc), Rest};
comp_inline_exports(N, Bin, Acc) ->
    {Name, Rest0} = name(Bin),
    <<Sort, Rest1/binary>> = Rest0,
    {Idx, Rest2} = wasm_leb128:u32(Rest1),
    comp_inline_exports(N - 1, Rest2, [{Name, Sort, Idx} | Acc]).

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
%% Instance export from a component instance: `0x05 0x00 inst name`. A composed
%% component aliases one instance's interface export (e.g. the provider's
%% `host:math/ops`) to feed another instance's import; composition reads these.
alias_entry(<<16#05, 16#00, Rest0/binary>>) ->
    {InstIdx, Rest1} = wasm_leb128:u32(Rest0),
    {Name, Rest2} = name(Rest1),
    {{comp_instance_alias, InstIdx, Name}, Rest2};
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
    {skip, Rest2};
alias_entry(Bin) ->
    %% An alias whose sort/target this linker does not recognise: rather than run off
    %% the end of the strict matches (a function_clause the fold would only report as a
    %% generic crash), name it so a malformed or unsupported component links to a value.
    wasm_error:link_error(unsupported_alias, <<"unsupported component alias">>,
                          #{bytes => binary:part(Bin, 0, min(4, byte_size(Bin)))}).

%%% --------------------------------------------------------------------- canon ---

%% `0x00 0x00 f opts ft` lift (a component func over core func `f`);
%% `0x01 0x00 f opts` lower (a core func over component func `f`);
%% `0x02/03/04 rt` resource new/drop/rep (a core func). Of the ABI options the
%% linker reads only the two it must act on: a lower's realloc index (a result that
%% crosses by memory allocates through it) and the string encoding (a non-UTF-8 one
%% is refused in `step/2` rather than silently mis-marshalled); the rest are stepped
%% over, since the linker binds host functions by name.
canon(<<16#00, 16#00, R0/binary>>) ->
    {F, R1} = wasm_leb128:u32(R0),
    %% A lift keeps its realloc and post-return function indices (not just the string
    %% encoding): the runtime allocates through the declared realloc and runs the declared
    %% post-return, rather than guessing `cabi_realloc`/`cabi_post_<export>` by name.
    {Realloc, Post, Enc, Async, R2} = lift_opts(R1),
    %% The declared component function-type index, kept so a static pass can check the
    %% lift's core function has the signature the Canonical ABI derives from this type.
    {Ft, R3} = wasm_leb128:u32(R2),
    {{canon_lift, F, Enc, Async, Realloc, Post, Ft}, R3};
canon(<<16#01, 16#00, R0/binary>>) ->
    {F, R1} = wasm_leb128:u32(R0),
    {Realloc, Enc, Async, R2} = lower_opts(R1),
    {{canon_lower, F, Realloc, Enc, Async}, R2};
canon(<<16#02, R0/binary>>) ->
    {Rt, R1} = wasm_leb128:u32(R0),
    {{canon_resource, new, Rt}, R1};
canon(<<16#03, R0/binary>>) ->
    {Rt, R1} = wasm_leb128:u32(R0),
    {{canon_resource, drop, Rt}, R1};
canon(<<16#04, R0/binary>>) ->
    {Rt, R1} = wasm_leb128:u32(R0),
    {{canon_resource, rep, Rt}, R1};
%% The async Canonical ABI built-ins. Each is a core function the guest imports; the
%% linker binds it to a `wasm_async` builtin in `step/2`. Operands are parsed so the
%% section is consumed exactly; the type/slot/encoding a built-in needs is carried in
%% its item. Opcodes 0x26+ (the threads proposal) are refused rather than crashed.
canon(<<16#05, R0/binary>>) -> {{canon_async, task_cancel, #{}}, R0};
canon(<<16#06, _Async, R1/binary>>) ->
    {{canon_async, subtask_cancel, #{}}, R1};
canon(<<16#09, R0/binary>>) ->
    {Result, R1} = result_list(R0),
    {Enc, _Async, R2} = canonopts(R1),
    {{canon_async, task_return, #{result => Result, enc => Enc}}, R2};
canon(<<16#0A, R0/binary>>) ->
    {Vt, R1} = val_type(R0),
    {Slot, R2} = wasm_leb128:u32(R1),
    {{canon_async, context_get, #{type => Vt, slot => Slot}}, R2};
canon(<<16#0B, R0/binary>>) ->
    {Vt, R1} = val_type(R0),
    {Slot, R2} = wasm_leb128:u32(R1),
    {{canon_async, context_set, #{type => Vt, slot => Slot}}, R2};
canon(<<16#0C, _Cancellable, R1/binary>>) ->
    {{canon_async, yield, #{}}, R1};
canon(<<16#0D, R0/binary>>) -> {{canon_async, subtask_drop, #{}}, R0};
canon(<<16#0E, R0/binary>>) -> async_ty(stream_new, R0);
canon(<<16#0F, R0/binary>>) -> async_ty_opts(stream_read, R0);
canon(<<16#10, R0/binary>>) -> async_ty_opts(stream_write, R0);
canon(<<16#11, R0/binary>>) -> async_ty_flag(stream_cancel_read, R0);
canon(<<16#12, R0/binary>>) -> async_ty_flag(stream_cancel_write, R0);
canon(<<16#13, R0/binary>>) -> async_ty(stream_drop_readable, R0);
canon(<<16#14, R0/binary>>) -> async_ty(stream_drop_writable, R0);
canon(<<16#15, R0/binary>>) -> async_ty(future_new, R0);
canon(<<16#16, R0/binary>>) -> async_ty_opts(future_read, R0);
canon(<<16#17, R0/binary>>) -> async_ty_opts(future_write, R0);
canon(<<16#18, R0/binary>>) -> async_ty_flag(future_cancel_read, R0);
canon(<<16#19, R0/binary>>) -> async_ty_flag(future_cancel_write, R0);
canon(<<16#1A, R0/binary>>) -> async_ty(future_drop_readable, R0);
canon(<<16#1B, R0/binary>>) -> async_ty(future_drop_writable, R0);
canon(<<16#1C, R0/binary>>) ->
    {_Enc, _Async, R1} = canonopts(R0),
    {{canon_async, error_context_new, #{}}, R1};
canon(<<16#1D, R0/binary>>) ->
    {_Enc, _Async, R1} = canonopts(R0),
    {{canon_async, error_context_debug_message, #{}}, R1};
canon(<<16#1E, R0/binary>>) -> {{canon_async, error_context_drop, #{}}, R0};
canon(<<16#1F, R0/binary>>) -> {{canon_async, waitable_set_new, #{}}, R0};
canon(<<16#20, _Cancellable, R1/binary>>) ->
    {_Mem, R2} = wasm_leb128:u32(R1),
    {{canon_async, waitable_set_wait, #{}}, R2};
canon(<<16#21, _Cancellable, R1/binary>>) ->
    {_Mem, R2} = wasm_leb128:u32(R1),
    {{canon_async, waitable_set_poll, #{}}, R2};
canon(<<16#22, R0/binary>>) -> {{canon_async, waitable_set_drop, #{}}, R0};
canon(<<16#23, R0/binary>>) -> {{canon_async, waitable_join, #{}}, R0};
canon(<<16#24, R0/binary>>) -> {{canon_async, backpressure_inc, #{}}, R0};
canon(<<16#25, R0/binary>>) -> {{canon_async, backpressure_dec, #{}}, R0};
canon(<<Op, _/binary>>) -> error({unsupported_canon_opcode, Op}).

%% Async built-in operand shapes: a bare type index; a type index plus a canonopts
%% vec (memory/encoding/async, stepped over); a type index plus an async bool flag.
async_ty(Which, R0) ->
    {Ty, R1} = wasm_leb128:u32(R0),
    {{canon_async, Which, #{type => Ty}}, R1}.

async_ty_opts(Which, R0) ->
    {Ty, R1} = wasm_leb128:u32(R0),
    {_Enc, _Async, R2} = canonopts(R1),
    {{canon_async, Which, #{type => Ty}}, R2}.

async_ty_flag(Which, R0) ->
    {Ty, R1} = wasm_leb128:u32(R0),
    <<_Flag, R2/binary>> = R1,
    {{canon_async, Which, #{type => Ty}}, R2}.

%% A canon `task.return` result list: `0x00 valtype` (one result) or `0x01 0x00`
%% (none). The result type is kept so the built-in lifts the returned value.
result_list(<<16#00, R0/binary>>) ->
    {Vt, R1} = val_type(R0),
    {Vt, R1};
result_list(<<16#01, 16#00, R0/binary>>) ->
    {none, R0}.

%% A component `valtype`: a primitive (one byte 0x73..0x7f) mapped to its value
%% descriptor, else a type index kept as `{type, Idx}` (resolved when a built-in
%% that reads a compound type is implemented).
val_type(<<B, R/binary>>) when B >= 16#73, B =< 16#7f ->
    {primitive_desc(B), R};
val_type(R0) ->
    {Idx, R1} = wasm_leb128:u32(R0),
    {{type, Idx}, R1}.

primitive_desc(16#7F) -> bool;
primitive_desc(16#7E) -> s8;
primitive_desc(16#7D) -> u8;
primitive_desc(16#7C) -> s16;
primitive_desc(16#7B) -> u16;
primitive_desc(16#7A) -> s32;
primitive_desc(16#79) -> u32;
primitive_desc(16#78) -> s64;
primitive_desc(16#77) -> u64;
primitive_desc(16#76) -> f32;
primitive_desc(16#75) -> f64;
primitive_desc(16#74) -> char;
primitive_desc(16#73) -> string.

%% A vec of canonopt, returning the string encoding (default UTF-8) and the async
%% marking (`sync`, or `{async, Callback|none}` for an async lift/lower). Codes:
%% `0x00/01/02` string-encoding (bare), `0x06` async (bare), `0x03 m`/`0x04 f`/
%% `0x05 f`/`0x07 f`/`0x08 t` carry an index (memory, realloc, post-return,
%% callback, core-type). The callback index is kept; the rest are stepped over,
%% since the linker binds host functions by name.
canonopts(Bin) ->
    {Count, Rest} = wasm_leb128:u32(Bin),
    canonopts(Count, Rest, utf8, sync).

canonopts(0, Rest, Enc, Async) ->
    {Enc, Async, Rest};
canonopts(N, <<16#00, Rest0/binary>>, _Enc, Async) ->
    canonopts(N - 1, Rest0, utf8, Async);
canonopts(N, <<16#01, Rest0/binary>>, _Enc, Async) ->
    canonopts(N - 1, Rest0, utf16, Async);
canonopts(N, <<16#02, Rest0/binary>>, _Enc, Async) ->
    canonopts(N - 1, Rest0, latin1_utf16, Async);
canonopts(N, <<16#06, Rest0/binary>>, Enc, sync) ->
    canonopts(N - 1, Rest0, Enc, {async, none});
canonopts(N, <<16#06, Rest0/binary>>, Enc, Async) ->
    canonopts(N - 1, Rest0, Enc, Async);
canonopts(N, <<16#07, Rest0/binary>>, Enc, _Async) ->
    {Cb, Rest1} = wasm_leb128:u32(Rest0),
    canonopts(N - 1, Rest1, Enc, {async, Cb});
canonopts(N, <<Op, Rest0/binary>>, Enc, Async) when Op =:= 16#03; Op =:= 16#04;
                                                    Op =:= 16#05; Op =:= 16#08 ->
    {_Idx, Rest1} = wasm_leb128:u32(Rest0),
    canonopts(N - 1, Rest1, Enc, Async);
canonopts(N, <<_Op, Rest0/binary>>, Enc, Async) ->
    canonopts(N - 1, Rest0, Enc, Async).

%% Only UTF-8 is marshalled; another declared encoding is a link-time refusal.
supported_encoding(utf8)         -> ok;
supported_encoding(utf16)        -> ok;
supported_encoding(latin1_utf16) -> ok;
supported_encoding(Enc)          -> {error, {unsupported_string_encoding, Enc}}.

%% A lower's options, keeping the realloc function index (`0x04 f`) and the string
%% encoding. A result that crosses by memory (a string or list) allocates through
%% realloc, and the adapter names its own, not one reachable on the instance calling
%% the import; the encoding is checked in `step/2` (only UTF-8 is marshalled).
%% A lift's options, keeping the realloc (`0x04`) and post-return (`0x05`) function
%% indices and the string encoding. Memory (`0x03`) and core-type (`0x08`) carry an index
%% that is consumed but not yet acted on (all fixtures use the default memory).
lift_opts(Bin) ->
    {Count, Rest} = wasm_leb128:u32(Bin),
    lift_opts(Count, Rest, none, none, utf8, sync).

lift_opts(0, Rest, Realloc, Post, Enc, Async) ->
    {Realloc, Post, Enc, Async, Rest};
lift_opts(N, <<16#00, R/binary>>, Rl, P, _E, A) -> lift_opts(N - 1, R, Rl, P, utf8, A);
lift_opts(N, <<16#01, R/binary>>, Rl, P, _E, A) -> lift_opts(N - 1, R, Rl, P, utf16, A);
lift_opts(N, <<16#02, R/binary>>, Rl, P, _E, A) ->
    lift_opts(N - 1, R, Rl, P, latin1_utf16, A);
lift_opts(N, <<16#06, R/binary>>, Rl, P, E, sync) ->
    lift_opts(N - 1, R, Rl, P, E, {async, none});
lift_opts(N, <<16#06, R/binary>>, Rl, P, E, A) -> lift_opts(N - 1, R, Rl, P, E, A);
lift_opts(N, <<16#07, R0/binary>>, Rl, P, E, _A) ->
    {Cb, R1} = wasm_leb128:u32(R0),
    lift_opts(N - 1, R1, Rl, P, E, {async, Cb});
lift_opts(N, <<16#04, R0/binary>>, _Rl, P, E, A) ->
    {Idx, R1} = wasm_leb128:u32(R0),
    lift_opts(N - 1, R1, Idx, P, E, A);
lift_opts(N, <<16#05, R0/binary>>, Rl, _P, E, A) ->
    {Idx, R1} = wasm_leb128:u32(R0),
    lift_opts(N - 1, R1, Rl, Idx, E, A);
lift_opts(N, <<Op, R0/binary>>, Rl, P, E, A) when Op =:= 16#03; Op =:= 16#08 ->
    {_Idx, R1} = wasm_leb128:u32(R0),
    lift_opts(N - 1, R1, Rl, P, E, A);
lift_opts(N, <<_Op, R0/binary>>, Rl, P, E, A) ->
    lift_opts(N - 1, R0, Rl, P, E, A).

lower_opts(Bin) ->
    {Count, Rest} = wasm_leb128:u32(Bin),
    lower_opts(Count, Rest, none, utf8, sync).

lower_opts(0, Rest, Realloc, Enc, Async) ->
    {Realloc, Enc, Async, Rest};
lower_opts(N, <<16#00, Rest0/binary>>, Realloc, _Enc, Async) ->
    lower_opts(N - 1, Rest0, Realloc, utf8, Async);
lower_opts(N, <<16#01, Rest0/binary>>, Realloc, _Enc, Async) ->
    lower_opts(N - 1, Rest0, Realloc, utf16, Async);
lower_opts(N, <<16#02, Rest0/binary>>, Realloc, _Enc, Async) ->
    lower_opts(N - 1, Rest0, Realloc, latin1_utf16, Async);
lower_opts(N, <<16#06, Rest0/binary>>, Realloc, Enc, sync) ->
    lower_opts(N - 1, Rest0, Realloc, Enc, {async, none});
lower_opts(N, <<16#06, Rest0/binary>>, Realloc, Enc, Async) ->
    lower_opts(N - 1, Rest0, Realloc, Enc, Async);
lower_opts(N, <<16#04, Rest0/binary>>, _Realloc, Enc, Async) ->
    {Idx, Rest1} = wasm_leb128:u32(Rest0),
    lower_opts(N - 1, Rest1, Idx, Enc, Async);
lower_opts(N, <<Op, Rest0/binary>>, Realloc, Enc, Async) when Op =:= 16#03;
                                                              Op =:= 16#05;
                                                              Op =:= 16#07;
                                                              Op =:= 16#08 ->
    {_Idx, Rest1} = wasm_leb128:u32(Rest0),
    lower_opts(N - 1, Rest1, Realloc, Enc, Async);
lower_opts(N, <<_Op, Rest0/binary>>, Realloc, Enc, Async) ->
    lower_opts(N - 1, Rest0, Realloc, Enc, Async).

%%% ---------------------------------------------------------- component import ---

%% `namekind name externdesc`. Only the instance and function forms are wired
%% (the adapter imports WASI interfaces as instances); each names the interface
%% or field its index later binds to a host function.
comp_import(<<16#00, R0/binary>>) ->
    {Name, R1} = name(R0),
    externdesc(Name, R1);
comp_import(<<Tag, _/binary>>) ->
    wasm_error:link_error(unsupported_component_import,
                          <<"unsupported component import form">>, #{tag => Tag}).

externdesc(Name, <<16#05, R0/binary>>) ->
    {_TypeIdx, R1} = wasm_leb128:u32(R0),
    {{comp_import_instance, Name}, R1};
externdesc(Name, <<16#01, R0/binary>>) ->
    {_TypeIdx, R1} = wasm_leb128:u32(R0),
    {{comp_import_func, Name}, R1};
externdesc(_Name, <<Tag, _/binary>>) ->
    %% Value, type, component or core-module import extern: not something this linker
    %% resolves, so name it rather than running off the strict matches.
    wasm_error:link_error(unsupported_externdesc,
                          <<"unsupported import extern">>, #{tag => Tag}).

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
