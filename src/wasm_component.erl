-module(wasm_component).
-moduledoc """
Internal: decode and run a WebAssembly **component**.

The first slices of component-model support (see the plan). A component binary
shares the core preamble magic but a different version/layer
(`00 61 73 6d 0d 00 01 00`, layer 1) where a core module is layer 0
(`... 01 00 00 00`). `decode/1` walks the top-level sections, extracts the
embedded core module (section id 1) and the exported names (section id 11).
`instantiate/1` loads and instantiates that core module through the existing
runtime, providing the resource intrinsics its imports declare; `call/4` lowers
Erlang terms into the guest, calls the export, lifts the result and runs the
post-return.

**Resources.** A component that exports a resource imports the resource
built-ins `[resource-new]`/`[resource-rep]`/`[resource-drop]` from its own
canon, and the host provides them: they are the instance's handle table
(`wasm_resources`). A handle is a small index the table mints, not the guest's
representation. `call/4` checks and translates handles by the export's real
signature, read from the component's type space: an `own` result passes to the
host, a `borrow` argument is lent and the guest gets the representation, an
`own` argument passes back to the guest. `drop_resource/3` checks a host-held
handle and runs the guest destructor with its representation.

A component whose entry core imports only WASI (every program we build) stays on
this single-core path. When the entry core imports from *another* core,
`wasm_component_link` reads the core-instance graph and wires those imports from
the other cores' exports; `instantiate/3` keeps every built core in `cores` so
`destroy/1` frees them all.

Not yet handled (later phases): nested components, the preview1-to-preview2
adapter's startup cycle (a shim table filled at instantiate) and its canon
lower/lift, and the async Canonical ABI.
""".

-export([decode/1, instantiate/1, instantiate/2, instantiate/3, call/4,
         call_async/4, call_async/5, destroy/1, destroy/2, drop_resource/3]).
-export([import_fun/2, exports/1]).
-export([host_new/2, host_get/1, host_update/2, host_drop/1, host_live/0]).

-export_type([component/0, instance/0]).

-opaque component() :: #{core := binary(), cores := [binary()],
                         sec := binary(), entry_idx := non_neg_integer(),
                         exports := [binary()]}
                      | #{composed := true, sec := binary(),
                          exports := [binary()]}.
-opaque instance() :: #{core := wasm:instance(), exports := [binary()],
                        cores := [wasm:instance()],
                        export_map => #{binary() => binary()},
                        str_enc => #{binary() => utf16 | latin1_utf16},
                        res_id => wasm_resources:id(),
                        res_sigs => #{binary() => wasm_component_types:sig()},
                        res_defined => [non_neg_integer()],
                        res_dtors => #{binary() => non_neg_integer()}}
                     | #{composed := true, exports := [binary()],
                         insts := #{non_neg_integer() =>
                                        {instance, instance()} |
                                        {iface_ref, non_neg_integer(), binary()} |
                                        {import_iface, binary()}},
                         cores := [wasm:instance()],
                         dispatch := #{binary() => {non_neg_integer(), binary()}}}.

-define(CORE_MODULE_SEC, 1).
-define(NESTED_COMPONENT_SEC, 4).
-define(EXPORT_SEC, 11).
-define(HOST, {?MODULE, host_resources}).
-define(HOST_NEXT, {?MODULE, host_next}).
%% An optional cap on how many host resources may be live at once, so a guest that
%% creates and never drops (forgets) them cannot exhaust host memory. `infinity`
%% (the default) is no cap; a caller sets it through `instantiate` opts.
-define(HOST_LIMIT, {?MODULE, host_limit}).
%% The handles a call has lent to the guest as borrows, given back when it ends.
-define(LOANS, {?MODULE, loans}).

%% Max total callback turns `call_async` drives before giving up (a runaway guard, not
%% a progress check): a legitimate stream takes one turn per read round.
-define(ASYNC_BUDGET, 1000000).

-doc """
Decode a component binary into its embedded core module and export names.

`{error, not_a_component}` if the bytes are a core module or not wasm at all.
""".
-spec decode(binary()) -> {ok, component()} | {error, term()}.
decode(<<16#00, 16#61, 16#73, 16#6d, 16#0d, 16#00, 16#01, 16#00, Rest/binary>>) ->
    case sections(Rest, #{exports => [], cores => [], nested => false}) of
        {ok, #{cores := [], exports := Exports}} ->
            %% No top-level core module: a composed component whose cores live inside
            %% nested components (e.g. from `wac`), or an import-only / re-export / empty
            %% component, which is legal. Composition resolves the whole graph
            %% (`instantiate_composed`); an empty graph yields an instance with no exports.
            {ok, #{composed => true, sec => Rest, exports => Exports}};
        {ok, #{cores := RevCores, exports := Exports}} ->
            %% The entry core is the guest: the largest module (a resource or
            %% WASI component embeds smaller shim/adapter cores beside it). Its
            %% index in the module space lets the linker, if the entry has a
            %% cross-core import, find how the graph wires it. Section 11 gives
            %% the names in the same cheap walk; the fuller graph is parsed only
            %% when linking (`sec` keeps the section stream for that).
            Cores = lists:reverse(RevCores),
            {EntryIdx, Core} = largest(Cores),
            {ok, #{core => Core, cores => Cores, sec => Rest,
                   entry_idx => EntryIdx, exports => Exports}};
        {error, _} = E ->
            E
    end;
decode(<<16#00, 16#61, 16#73, 16#6d, _/binary>>) ->
    {error, not_a_component};
decode(_) ->
    {error, not_wasm}.

%% The largest core module and its 0-based index in the module space. A strict
%% `>` keeps the earliest on a tie, so the pick is stable.
largest([First | _] = Cores) ->
    Indexed = lists:zip(lists:seq(0, length(Cores) - 1), Cores),
    lists:foldl(fun({I, B}, {_BI, Best} = Acc) ->
                    case byte_size(B) > byte_size(Best) of
                        true  -> {I, B};
                        false -> Acc
                    end
                end, {0, First}, Indexed).

%% Walk the top-level sections: each is a one-byte id, a u32 size, then that many
%% content bytes. Only the core module and export sections matter here; the
%% instance/alias/canon graph is parsed later (`wasm_component_link`) and only
%% when the entry core has a cross-core import, so the common path skips it.
sections(<<>>, Acc) ->
    {ok, Acc};
sections(<<Id, Rest0/binary>>, Acc) ->
    {Size, Rest1} = wasm_leb128:u32(Rest0),
    case Rest1 of
        <<Content:Size/binary, Rest2/binary>> ->
            sections(Rest2, section(Id, Content, Acc));
        _ ->
            {error, truncated_section}
    end.

section(?CORE_MODULE_SEC, Content, #{cores := Cs} = Acc) ->
    Acc#{cores => [Content | Cs]};
section(?EXPORT_SEC, Content, #{exports := Es} = Acc) ->
    %% A component may split its exports across several export sections (one per
    %% export is what the standard toolchain emits), so accumulate rather than
    %% replace: overwriting kept only the last section and dropped, for a proxy
    %% component, `wasi:http/incoming-handler` in favour of `wasi:cli/run`.
    Acc#{exports => Es ++ export_names(Content)};
section(?NESTED_COMPONENT_SEC, _Content, Acc) ->
    Acc#{nested => true};
section(_Other, _Content, Acc) ->
    Acc.

%% Read the exported names, tolerantly: a component export is a name string
%% (a leading kind byte then a u32 length and the bytes) followed by a sort and
%% index we do not need here.
export_names(<<>>) ->
    [];
export_names(Bin) ->
    {Count, Rest} = wasm_leb128:u32(Bin),
    export_names(Count, Rest, []).

export_names(0, _Rest, Acc) ->
    lists:reverse(Acc);
export_names(N, <<_Kind, Rest0/binary>>, Acc) ->
    {Len, Rest1} = wasm_leb128:u32(Rest0),
    case Rest1 of
        <<Name:Len/binary, Rest2/binary>> ->
            export_names(N - 1, skip_desc(skip_sortidx(Rest2)), [Name | Acc]);
        _ ->
            lists:reverse(Acc)
    end;
export_names(_N, _Bin, Acc) ->
    lists:reverse(Acc).

skip_sortidx(<<_Sort, Rest0/binary>>) ->
    {_Idx, Rest1} = wasm_leb128:u32(Rest0),
    Rest1;
skip_sortidx(Bin) ->
    Bin.

%% The optional type ascription after a sortidx: `0x00` absent (the common case,
%% and all the standard toolchain emits), `0x01` present. Only the absent form is
%% skipped past to reach the next entry; a present descriptor stops the walk, which
%% is harmless because each export sits in its own section (count 1).
skip_desc(<<0, Rest/binary>>) -> Rest;
skip_desc(Bin)               -> Bin.

-doc "Decode and instantiate a component, wiring any resource intrinsics.".
-spec instantiate(binary()) -> {ok, instance()} | {error, term()}.
instantiate(Bin) ->
    instantiate(Bin, #{}).

-doc """
Instantiate a component, providing host functions for the interfaces it imports.

`Imports` is a map keyed `{InterfaceName, FieldName}` (e.g.
`{~"example:host/clock", ~"now"}`) to a `fun(Ctx, Args)` host function, the way
the host supplies a WASI 0.2 world. It is merged over the resource intrinsics the
component needs, so a component that both imports an interface and exports a
resource gets both.
""".
-spec instantiate(binary(), #{{binary(), binary()} => function()}) ->
          {ok, instance()} | {error, term()}.
instantiate(Bin, Imports) ->
    instantiate(Bin, Imports, #{}).

-doc """
As `instantiate/2`, passing `Limits` (memory and fuel bounds) to the inner core
instance, so a component honours the same limits a core module does. This is what
the worker uses per request.
""".
-spec instantiate(binary(), #{{binary(), binary()} => function()}, map()) ->
          {ok, instance()} | {error, term()}.
instantiate(Bin, Imports, Opts) ->
    %% `loader => compile` builds an inline module with `wasm:compile` instead of
    %% `wasm:load`, whose node cache is rate-limited to 50/s; a runner that
    %% instantiates many single-use components (the wasi-testsuite) needs it to
    %% avoid `load_rate_exceeded`. An unresolved import is a link-time error, never a
    %% trap-if-called placeholder. Everything else in Opts is instance limits.
    Limits = maps:without([loader, resource_closer, resource_predrop,
                           resource_limit], Opts),
    %% Cap the live host resources for this run, if the caller set one.
    put(?HOST_LIMIT, maps:get(resource_limit, Opts, infinity)),
    %% Decode and the graph parsers match bytes strictly and signal by throwing;
    %% capture turns a malformed component into a value here, the same boundary the
    %% core decoder uses, while letting an in-flight guest exception pass through.
    wasm_error:capture(
      fun() ->
          case decode(Bin) of
              {ok, Decoded} ->
                  instantiate_decoded(Decoded, Imports, Opts, Limits);
              {error, _} = E ->
                  E
          end
      end).

instantiate_decoded(#{composed := true} = Decoded, Imports, Opts, _Limits) ->
    instantiate_composed(Decoded, Imports, Opts);
instantiate_decoded(#{core := Core, sec := Sec} = Decoded, Imports, Opts, Limits) ->
    %% Reject a component whose `canon lift` declares a type its core function cannot
    %% have (the Canonical ABI derives the core signature from the declared component
    %% type) before any core is built or its start function runs.
    case wasm_component_link:validate_lifts(Sec, maps:get(cores, Decoded, [Core])) of
        {error, _} = Invalid -> Invalid;
        ok -> instantiate_valid(Decoded, Imports, Opts, Limits)
    end.

instantiate_valid(#{core := Core, exports := Exports, sec := Sec} = Decoded,
                  Imports, Opts, Limits) ->
    Loader = maps:get(loader, Opts, load),
    EntryIdx = maps:get(entry_idx, Decoded, 0),
    %% What the resource built-ins and the host boundary check handles by: each
    %% export's real signature, the types this component defines, and the type
    %% of each built-in the entry core imports.
    Res = wasm_component_link:resource_info(Sec, EntryIdx),
    EntryImports = wasm_component_link:core_imports(Core),
    Host = resolve_imports(EntryImports, Imports,
                           resource_imports(EntryImports, Res)),
    %% The export map lets `call/4` reach a core function whose name differs from the
    %% component export name; where they coincide it is the identity and the same-name
    %% fallback in `call/4` covers exports it does not resolve.
    ExportMap = wasm_component_link:export_map(Sec),
    %% Imports the host set does not cover are wired from other cores of this
    %% component (the linker). A multi-core component whose entry is self-sufficient
    %% still takes the linker when an exported lift names a core other than the
    %% largest, so every core is built and the export reaches the core its lift names
    %% rather than the largest by size. A lone core, or one whose exports all resolve
    %% on the entry, stays on the single-core path unchanged.
    Cores = maps:get(cores, Decoded, [Core]),
    Leftovers = [K || K <- EntryImports, not maps:is_key(K, Host)],
    UseSimple = Leftovers =:= []
        andalso (length(Cores) =:= 1
                 orelse wasm_component_link:exports_resolve_on_entry(Sec, EntryIdx)),
    %% This instance's own resource handle table (see wasm_resources). It is
    %% current while the cores are built, so a start function that mints a
    %% handle mints it here; guest calls run with it current, and destroy frees
    %% it.
    ResId = wasm_resources:new_instance(),
    Result = wasm_resources:with_instance(
               ResId,
               fun() ->
                   case UseSimple of
                       true  -> start(Loader, Core, Host, Limits, Exports, []);
                       false -> link_in(Decoded, Imports, Opts)
                   end
               end),
    %% Each export's string encoding (only the non-UTF-8 ones are recorded) and its
    %% declared realloc/post-return, so `call/4` marshals strings and allocates/cleans up
    %% the way the component's canon lift asks, rather than by name.
    StrEnc = wasm_component_link:export_encodings(Sec),
    Bindings = wasm_component_link:export_bindings(Sec),
    with_export_map(Result, ExportMap, StrEnc, Bindings, ResId, Res).

with_export_map({ok, Inst}, ExportMap, StrEnc, Bindings, ResId, Res) ->
    #{sigs := Sigs, defined := Defined, dtors := Dtors} = Res,
    {ok, Inst#{export_map => ExportMap, str_enc => StrEnc,
               export_bindings => Bindings, res_id => ResId,
               res_sigs => Sigs, res_defined => Defined, res_dtors => Dtors}};
with_export_map(Other, _ExportMap, _StrEnc, _Bindings, ResId, _Res) ->
    wasm_resources:destroy_instance(ResId),
    Other.

%% The core function that implements a component export. A core export of the same
%% name is used directly, so a working component is never affected; only when the
%% export name is not a core export is the export map consulted for the renamed core
%% function, with the same name as the last fallback.
resolve_export(#{core := Inst} = I, Export) ->
    case maps:is_key(Export, wasm:exports(Inst)) of
        true  -> Export;
        false -> maps:get(Export, maps:get(export_map, I, #{}), Export)
    end.

%% The entry core imports something the host set does not cover (another core's
%% export). Interpret the whole core-instance graph: `wasm_component_link:link/4`
%% builds every core, wiring core-to-core imports and binding lowered WASI imports
%% to the host set, and returns the entry instance plus every built core.
link_in(#{sec := Sec, entry_idx := EntryIdx, exports := Exports}, Imports, Opts) ->
    Resolve = fun(Imps) ->
                  resolve_imports(Imps, Imports, resource_imports(Imps, #{}))
              end,
    LinkOpts = Opts#{drop_fun => drop_fun(Opts),
                     resource_dtors => wasm_component_types:resource_dtors(Sec)},
    case wasm_component_link:parse(Sec) of
        {ok, Graph} ->
            case wasm_component_link:link(Graph, EntryIdx, Resolve, LinkOpts) of
                {ok, #{core := Inst, cores := Cores, export_targets := Targets}} ->
                    {ok, #{core => Inst, exports => Exports, cores => Cores,
                           export_targets => Targets}};
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%% A composed component (nested component definitions instantiated and their exports
%% wired together, as `wac` produces) has no top-level core. Instantiate each nested
%% component recursively and build an instance whose exports dispatch to the
%% sub-instance that provides them. Wiring one sub-instance's export into another's
%% import (`comp_instantiate` args) is the next composition step; this handles a nested
%% component instantiated with no arguments whose export is aliased out and re-exported.
instantiate_composed(#{sec := Sec, exports := Exports}, Imports, Opts) ->
    case wasm_component_link:parse(Sec) of
        {ok, Graph} ->
            S0 = #{comps => #{}, n_comp => 0, insts => #{}, n_inst => 0,
                   funcs => #{}, n_func => 0, dispatch => #{},
                   imports => Imports, opts => Opts},
            #{insts := Insts, dispatch := Dispatch} =
                lists:foldl(fun compose_step/2, S0, Graph),
            Cores = lists:append([cores_of(Sub)
                                  || {instance, Sub} <- maps:values(Insts)]),
            {ok, #{composed => true, exports => Exports, insts => Insts,
                   dispatch => Dispatch, cores => Cores}};
        {error, _} = E ->
            E
    end.

%% Fold one graph item into the composition state. The component-instance index space
%% (`insts`) holds either a real instantiated sub-instance (`{instance, Sub}`) or a
%% reference to another instance's interface export (`{iface_ref, Src, Name}`, from an
%% instance-sort alias), the way the linker maintains the core index spaces.
compose_step({component_def, Bytes}, #{comps := Comps, n_comp := N} = S) ->
    S#{comps => Comps#{N => Bytes}, n_comp => N + 1};
%% An imported instance (an interface the composed component itself imports, e.g. WASI)
%% occupies a slot in the component-instance index space, so the indices that
%% instantiate/alias arguments reference stay aligned. It is host-provided, not a sibling
%% to bridge, so it is recorded as an import reference and otherwise left alone.
compose_step({comp_import_instance, Name}, #{insts := Insts, n_inst := N} = S) ->
    S#{insts => Insts#{N => {import_iface, Name}}, n_inst => N + 1};
compose_step({comp_instance_alias, SrcInst, Name},
             #{insts := Insts, n_inst := N} = S) ->
    S#{insts => Insts#{N => {iface_ref, SrcInst, Name}}, n_inst => N + 1};
compose_step({comp_instantiate, CompIdx, Args},
             #{comps := Comps, insts := Insts, n_inst := N,
               imports := Imports, opts := Opts} = S) ->
    Bytes = maps:get(CompIdx, Comps),
    %% Wire the arguments (a sibling instance's interface feeding this one's import) as
    %% host bridges, over any host imports the composition itself was given.
    Bridged = maps:merge(Imports, bridge_imports(Args, Bytes, Insts)),
    case instantiate(Bytes, Bridged, Opts) of
        {ok, Sub} ->
            S#{insts => Insts#{N => {instance, Sub}}, n_inst => N + 1};
        {error, E} ->
            wasm_error:link_error(nested_component_failed,
                                  <<"a nested component did not instantiate">>,
                                  #{component => CompIdx, error => E})
    end;
compose_step({comp_func_alias, InstIdx, Name}, #{funcs := Funcs, n_func := N} = S) ->
    S#{funcs => Funcs#{N => {InstIdx, Name}}, n_func => N + 1};
%% A func export (component sort 1) names a component func; map the export name to the
%% instance export that func resolves to.
compose_step({comp_export, Name, 1, Idx}, #{funcs := Funcs, dispatch := D} = S) ->
    case maps:find(Idx, Funcs) of
        {ok, Target} -> S#{dispatch => D#{Name => Target}};
        error        -> S
    end;
compose_step(_Other, S) ->
    S.

%% The host imports a nested component needs from its instantiate arguments. For each
%% argument that binds one of the component's imported interfaces to another instance's
%% interface export, build a bridge for every function that interface declares: a host
%% function that lifts the caller's arguments to terms, calls the providing sub-instance's
%% export, and lowers the result. Values cross as Erlang terms and each side uses its own
%% memory, so a cross-component call is two ordinary component calls back to back. The
%% function signatures come from the component's own type section (`wasm_component_types`).
bridge_imports(Args, Bytes, Insts) ->
    <<_:8/binary, Sec/binary>> = Bytes,
    Ifaces = case wasm_component_types:import_interfaces(Sec) of
                 {ok, Map}  -> Map;
                 {error, _} -> #{}
             end,
    lists:foldl(
      fun({ArgName, _Sort, Idx}, Acc) ->
          case maps:get(Idx, Insts, undefined) of
              {iface_ref, SrcInst, ProvExport} ->
                  {instance, Provider} = maps:get(SrcInst, Insts),
                  Funcs = maps:get(ArgName, Ifaces, #{}),
                  maps:fold(
                    fun(FuncName, Sig, A) ->
                        %% The provider exposes an interface function under the
                        %% interface-qualified core export name `<interface>#<func>`.
                        Target = <<ProvExport/binary, "#", FuncName/binary>>,
                        A#{{ArgName, FuncName} => bridge(Provider, Target, Sig)}
                    end, Acc, Funcs);
              _ ->
                  Acc
          end
      end, #{}, Args).

%% One cross-component call, as a host function the consumer's core imports. This
%% function runs in the consumer's instance context; `call/4` switches to the
%% provider for the call and back. Each instance keeps its own handle table, so
%% a handle is translated as it crosses. An own the provider returns stays in
%% the provider's table, held from outside it, and the consumer gets a handle of
%% its own that stands for it. Passing that handle back (a borrow, or an own)
%% gives the provider its own handle, which `call/4` checks against the
%% provider's table like any host-held one. The consumer dropping it releases it
%% in the provider and runs the provider's destructor. So a resource is usable
%% only by the side that holds it, and using it after it was handed away or
%% dropped traps.
bridge(Provider, FuncName, {Params, Result} = Sig) ->
    ProviderId = maps:get(res_id, Provider, undefined),
    import_fun(Sig,
               fun(Terms) ->
                   Args = to_provider(Params, Terms, ProviderId),
                   case call(Provider, FuncName, Sig, Args) of
                       {ok, Value} ->
                           from_provider(Result, Value, Provider, ProviderId);
                       {error, _} = E ->
                           throw({wasm_bridge_failed, FuncName, E})
                   end
               end).

%% A consumer handle that stands for one of this provider's resources becomes
%% the provider's handle; an own leaves the consumer's table as it goes.
%% Anything else passes through.
to_provider(_Params, Terms, undefined) ->
    Terms;
to_provider(Params, Terms, ProviderId) when length(Params) =:= length(Terms) ->
    Fun = fun(Kind, _Rt, H) ->
              case wasm_resources:lookup(H) of
                  {ok, {imported, {remote, ProviderId, Hp, _Release}}} ->
                      ok = moved(Kind, H),
                      Hp;
                  _ ->
                      H
              end
          end,
    [walk(P, T, Fun) || {P, T} <- lists:zip(Params, Terms)];
to_provider(_Params, Terms, _ProviderId) ->
    Terms.

%% An own goes with the call: the consumer no longer holds it. A borrow stays.
moved(own, H)     -> wasm_resources:take(H);
moved(borrow, _H) -> ok.

%% An own the provider returned, held there from outside, gets a consumer handle
%% that stands for it.
from_provider(none, Value, _Provider, _ProviderId) ->
    Value;
from_provider(_Result, Value, _Provider, undefined) ->
    Value;
from_provider(Result, Value, Provider, ProviderId) ->
    Fun = fun(own, _Rt, Hp) ->
                  case wasm_resources:host_lookup(ProviderId, Hp) of
                      {ok, _} ->
                          Release = fun() -> release(Provider, Hp) end,
                          wasm_resources:new(imported,
                                             {remote, ProviderId, Hp, Release});
                      error ->
                          Hp
                  end;
             (borrow, _Rt, H) ->
                  H
          end,
    walk(Result, Value, Fun).

%% The consumer dropped its handle: drop the provider's, running the provider's
%% destructor for it when one is known. Never raises into the consumer's drop.
release(#{res_id := Id} = Provider, Hp) ->
    Dtors = maps:get(res_dtors, Provider, #{}),
    case wasm_resources:host_lookup(Id, Hp) of
        {ok, {Rt, _Rep}} ->
            case [D || {D, T} <- maps:to_list(Dtors), T =:= Rt] of
                [Dtor | _] ->
                    _ = drop_resource(Provider, Dtor, Hp);
                [] ->
                    _ = wasm_error:capture(
                          fun() -> wasm_resources:host_drop(Id, Rt, Hp) end)
            end,
            ok;
        error ->
            ok
    end.

%% The drop function `canon resource.drop` runs, returning `ok` or `{trap, Reason}`.
%% A caller that owns OS resources supplies `resource_closer` (the same closer
%% `destroy/2` uses); a dropped host resource is closed and its handle forgotten at
%% once, so it does not leak until destroy. `resource_predrop` may veto a drop with a
%% trap (a resource that still has a live borrow may not be dropped). A handle that is
%% not a host resource (a guest identity handle) is left alone; with no closer, drop
%% stays a no-op.
drop_fun(Opts) ->
    Closer = maps:get(resource_closer, Opts, fun(_R) -> ok end),
    PreDrop = maps:get(resource_predrop, Opts, fun(_H) -> ok end),
    fun(Handle) ->
        case PreDrop(Handle) of
            {trap, _} = Trap ->
                Trap;
            _ ->
                case host_get(Handle) of
                    {ok, Resource} -> _ = Closer(Resource), _ = host_drop(Handle), ok;
                    error          -> ok
                end
        end
    end.

start(Loader, Core, Imports, Limits, Exports, Extra) ->
    case load_core(Loader, Core) of
        {ok, Mod} ->
            case wasm:instantiate(Mod, Imports, Limits) of
                {ok, Inst} ->
                    {ok, #{core => Inst, exports => Exports,
                           cores => [Inst | Extra]}};
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

load_core(compile, Core) -> wasm:compile(Core);
load_core(_Load, Core)   -> wasm:load(Core).

-doc """
Destroy a component instance, freeing every core it built and sweeping the host
resource tables. A resource may own an OS handle (a file descriptor, a socket)
that GC does not reclaim, so `destroy/2` takes a closer the host layer supplies to
close each one; `destroy/1` closes nothing, for pure components with no OS state.

The instance's resource handle table goes with it: every handle still live is
discarded and no guest destructor runs, since the guest memory the
representations point into is freed with the instance. A handle used afterwards
answers what the destroyed instance answers.

The host resource tables are per-process, not per-instance, so `destroy` sweeps
every live host resource in the calling process. The contract is therefore one
live instance per process, destroyed from that same process: the worker runs one
instance per request and destroys it in its runner, and the inline API instantiates
and destroys in order in one process. Running two instances concurrently in one
process and destroying one would free the other's handles; do not.
""".
-spec destroy(instance()) -> ok.
destroy(Inst) ->
    destroy(Inst, fun(_Resource) -> ok end).

-doc "As `destroy/1`, closing each live host resource with `Closer` first.".
-spec destroy(instance(), fun(({atom(), term()}) -> ok)) -> ok.
destroy(Inst, Closer) ->
    lists:foreach(fun wasm:destroy/1, cores_of(Inst)),
    lists:foreach(fun wasm_resources:destroy_instance/1, res_ids(Inst)),
    sweep_host(Closer),
    ok.

%% The resource-table ids an instance holds: its own, plus every sub-instance's
%% for a composed instance, so destroying it frees each nested table and leaves
%% any other instance's table in the process untouched.
res_ids(#{insts := Insts}) ->
    [Id || {instance, Sub} <- maps:values(Insts),
           Id <- res_ids(Sub)];
res_ids(#{res_id := Id}) -> [Id];
res_ids(_) -> [].

cores_of(#{cores := Insts}) -> Insts;
cores_of(#{core := Inst})   -> [Inst].

%% Close and drop every live host resource so no OS handle outlives the instance,
%% and clear the identity table. The handle counter is left advancing rather than
%% reset, so a fresh handle never collides with one still held elsewhere in a
%% process that runs more than one instance in sequence.
sweep_host(Closer) ->
    lists:foreach(
      fun(H) ->
          case host_get(H) of
              {ok, Resource} -> _ = Closer(Resource);
              error          -> ok
          end,
          host_drop(H)
      end, host_live()),
    ok.

-doc "The export names a decoded component instance offers.".
-spec exports(instance()) -> [binary()].
exports(#{exports := Exports}) ->
    Exports.

-doc """
Call a lifted export, lowering `Args` and lifting the result by `Sig`.

`Sig` is `{Params, Result}` of Canonical ABI value descriptors (see `wasm_canon`).
The post-return `cabi_post_<Export>` is run after the result is lifted.
""".
-spec call(instance(), binary(),
           {[wasm_canon:desc()], wasm_canon:desc() | none}, [term()]) ->
          {ok, term()} | {error, term()}.
call(#{composed := true, dispatch := Dispatch, insts := Insts}, Export, Sig, Args) ->
    %% A composed component has no core of its own: an export is provided by one of the
    %% instantiated nested components, so dispatch the call to that sub-instance's export.
    case maps:find(Export, Dispatch) of
        {ok, {InstIdx, SubExport}} ->
            %% The export must resolve to an instantiated sub-component. An export backed
            %% only by an imported interface (a re-export) or an unresolved index is a
            %% value, not a crash; full import-re-export wiring is a composition follow-up.
            case maps:get(InstIdx, Insts, undefined) of
                {instance, Sub} -> call(Sub, SubExport, Sig, Args);
                _               -> {error, {unresolved_export, Export}}
            end;
        error ->
            {error, {unknown_export, Export}}
    end;
call(#{} = I, Export, {Params, Result}, Args) ->
    %% Lifting the result and lowering the arguments cross the Canonical ABI, where
    %% malformed guest output (a bad char, invalid UTF-8, an out-of-range discriminant)
    %% or a malformed argument would otherwise raise. `capture/1` turns any such throw
    %% or raw crash into an `{error, _}` value, so nothing raises to the caller (a guest
    %% exception in flight still passes through, to unwind to an outer handler).
    Enc = maps:get(Export, maps:get(str_enc, I, #{}), utf8),
    wasm_error:capture(
      fun() ->
          wasm_canon:with_string_encoding(
            Enc, fun() -> do_call(I, Export, {Params, Result}, Args) end)
      end).

do_call(I, Export, Sig, Args) ->
    %% Run with this component instance's resource handle table current, so the
    %% resource intrinsics (and a cross-component bridge) act on the right table.
    wasm_resources:with_instance(
      maps:get(res_id, I),
      fun() -> do_call_1(I, Export, Sig, Args) end).

do_call_1(I, Export, {Params, Result}, Args) ->
    %% A multi-core component lifts different exports from different cores (a proxy
    %% component lifts `wasi:cli/run#run` from a command shim and
    %% `wasi:http/incoming-handler#handle` from the main module), and two cores can
    %% export the same name. The linker resolves each export to the instance its
    %% declared lift names; only when it has no such target does the entry-core
    %% export map / same-name fallback decide.
    {Inst, CoreName} = target_for(I, Export),
    Binding = maps:get(Export, maps:get(export_bindings, I, #{}), #{}),
    %% Resource handles cross by the export's real signature: checked against
    %% the instance's table before the guest runs, the guest given the
    %% representation for a borrow and the handle for an own, and an own result
    %% handed to the host.
    HSig = handle_sig(I, Export, CoreName, {Params, Result}),
    %% Allocate the arguments through the allocator the lift declares (not `cabi_realloc`
    %% by name); `undefined` keeps the default `cabi_realloc` path for a lift that names
    %% none. The override only affects the by-memory lowering `wasm_canon:realloc` reads.
    Realloc = realloc_fun(Inst, maps:get(realloc, Binding, none)),
    with_loans(
      I,
      fun() ->
          Args1 = lower_handles(I, HSig, Args),
          wasm_canon:with_realloc(
            Realloc,
            fun() ->
                CoreArgs = wasm_canon:lower_params(Inst, Params, Args1),
                case wasm:call(Inst, CoreName, CoreArgs) of
                    {ok, CoreResults} ->
                        Value = lift_call_result(Inst, Result, CoreResults),
                        %% Run the declared post-return; a trap in cleanup fails
                        %% the call rather than being swallowed.
                        PostReturn = maps:get(post_return, Binding, none),
                        ok = run_post_return(Inst, PostReturn, CoreResults),
                        {ok, lift_handles(I, HSig, Value)};
                    {error, _} = E ->
                        E
                end
            end)
      end).

%%% ------------------------------------------------------- host boundary ---

%% The signature a call's handles cross by. The export's real signature, from
%% the component's type space, is authoritative, so `{[u32], u32}` for a method
%% is checked exactly like `{[{borrow, 0}], u32}`. Only when the type space does
%% not give it are the caller's descriptors used, and then only for a component
%% that defines a resource, typed loosely (liveness, not type).
handle_sig(#{res_id := Id} = I, Export, CoreName, CallerSig) ->
    case wasm_resources:exists(Id) of
        true  -> handle_sig_1(I, Export, CoreName, CallerSig);
        %% A destroyed instance (or one this process does not own) has no table;
        %% the call answers what such an instance answers.
        false -> none
    end;
handle_sig(_I, _Export, _CoreName, _CallerSig) ->
    none.

handle_sig_1(I, Export, CoreName, CallerSig) ->
    Sigs = maps:get(res_sigs, I, #{}),
    Defined = maps:get(res_defined, I, []),
    case maps:find(Export, Sigs) of
        {ok, Sig} -> {strict, Sig, Defined};
        error ->
            case maps:find(CoreName, Sigs) of
                {ok, Sig}                 -> {strict, Sig, Defined};
                error when Defined =:= [] -> none;
                error                     -> {loose, CallerSig, Defined}
            end
    end.

%% Arguments from the host: an own passes from the host to the guest, which gets
%% the handle; a borrow is lent for the call, and the guest gets the
%% representation. A handle the host does not hold, or of another type, traps.
lower_handles(_I, none, Args) ->
    Args;
lower_handles(#{res_id := Id}, {_Mode, {Params, _Res}, _Def} = HSig, Args)
  when length(Params) =:= length(Args) ->
    Fun = fun(own, Rt, H)    -> wasm_resources:host_give(Id, Rt, H);
             (borrow, Rt, H) -> lend(Id, Rt, H)
          end,
    [walk(P, A, handle_fun(HSig, Fun)) || {P, A} <- lists:zip(Params, Args)];
lower_handles(_I, _HSig, Args) ->
    Args.

%% A result to the host: an own the guest returns passes to the host.
lift_handles(_I, none, Value) ->
    Value;
lift_handles(_I, {_Mode, {_Params, none}, _Defined}, Value) ->
    Value;
lift_handles(#{res_id := Id}, {_Mode, {_Params, Result}, _Def} = HSig, Value) ->
    Fun = fun(own, Rt, H)     -> wasm_resources:host_receive(Id, Rt, H);
             (borrow, _Rt, H) -> H
          end,
    walk(Result, Value, handle_fun(HSig, Fun));
lift_handles(_I, _HSig, Value) ->
    Value.

%% Apply `Fun` to the handles of a type this component defines (strict), or to
%% every handle untyped (loose); another component's handles pass through.
handle_fun({strict, _Sig, Defined}, Fun) ->
    fun(Kind, Rt, H) ->
        case lists:member(Rt, Defined) of
            true  -> Fun(Kind, Rt, H);
            false -> H
        end
    end;
handle_fun({loose, _Sig, _Defined}, Fun) ->
    fun(Kind, _Rt, H) -> Fun(Kind, undefined, H) end.

%% The loans a call takes are given back when it returns, traps or fails a check
%% part way through lowering.
with_loans(#{res_id := Id}, Fun) ->
    Prev = get(?LOANS),
    put(?LOANS, []),
    try Fun()
    after
        Loans = get(?LOANS),
        case Prev of
            undefined -> erase(?LOANS);
            _         -> put(?LOANS, Prev)
        end,
        lists:foreach(fun(H) -> wasm_resources:host_unlend(Id, H) end, Loans)
    end;
with_loans(_I, Fun) ->
    Fun().

lend(Id, Rt, H) ->
    Rep = wasm_resources:host_lend(Id, Rt, H),
    put(?LOANS, [H | get(?LOANS)]),
    Rep.

%% Walk a value by its descriptor, applying `Fun(own | borrow, Rt, Handle)` at
%% each resource handle. A value whose shape does not match its descriptor is
%% left alone (marshalling reports it).
walk({own, Rt}, H, Fun) when is_integer(H) -> Fun(own, Rt, H);
walk({borrow, Rt}, H, Fun) when is_integer(H) -> Fun(borrow, Rt, H);
walk({option, D}, {some, V}, Fun) -> {some, walk(D, V, Fun)};
walk({result, Ok, _Err}, {ok, V}, Fun) when Ok =/= none ->
    {ok, walk(Ok, V, Fun)};
walk({result, _Ok, Err}, {error, V}, Fun) when Err =/= none ->
    {error, walk(Err, V, Fun)};
walk({list, D}, L, Fun) when is_list(L) -> [walk(D, V, Fun) || V <- L];
walk({tuple, Ds}, T, Fun) when is_tuple(T), tuple_size(T) =:= length(Ds) ->
    Pairs = lists:zip(Ds, tuple_to_list(T)),
    list_to_tuple([walk(D, V, Fun) || {D, V} <- Pairs]);
walk({record, Fields}, M, Fun) when is_map(M) ->
    lists:foldl(fun({Name, D}, Acc) ->
                    case maps:find(Name, Acc) of
                        {ok, V} -> Acc#{Name => walk(D, V, Fun)};
                        error   -> Acc
                    end
                end, M, Fields);
walk({variant, Cases}, {Name, V}, Fun) ->
    case lists:keyfind(Name, 1, Cases) of
        {Name, D} when D =/= none -> {Name, walk(D, V, Fun)};
        _                         -> {Name, V}
    end;
walk(_Desc, V, _Fun) ->
    V.

%% The instance and core-function name implementing a component export. The linker's
%% declared-lift target wins when present (authoritative across cores sharing a
%% name); otherwise the export map / same-name fallback against the entry core.
target_for(I, Export) ->
    case maps:get(Export, maps:get(export_targets, I, #{}), undefined) of
        {Inst, CoreName} ->
            {Inst, CoreName};
        undefined ->
            CoreName = resolve_export(I, Export),
            {core_with_export(I, CoreName), CoreName}
    end.

%% A host function that calls the named core allocator, for `wasm_canon:with_realloc`.
realloc_fun(_Inst, none) ->
    undefined;
realloc_fun(Inst, Name) ->
    fun(_Ctx, Args) -> wasm:call(Inst, Name, Args) end.

-doc """
Call an async-lifted export, lowering `Args` and lifting the result by `Sig`.

The async counterpart of `call/4`, for an export lifted with the async Canonical ABI
(`async func`). It calls the `[async-lift]<export>` core function and then drives the
Component Model callback loop: on EXIT it lifts the value the guest handed back through
`task.return`; on WAIT it waits on the named waitable-set (`wasm_async:wait_on_set/1`)
for a completion from a producer and re-enters the guest through its callback with the
`(event, waitable, code)` triple; on YIELD it re-enters with a NONE event. It loops
until EXIT (or an execution budget is exhausted).

A `future<T>`/`stream<T>` parameter's argument selects how the readable end is fed: a
bare value/binary is EAGER (read completes at once); `{ready_before, V}` queues the
completion before the guest runs (found at WAIT without blocking); `{producer, PFun}`
spawns a monitored producer that supplies the value/bytes later. `Opts` may carry
`wait_hook => Pid`, notified each time the task blocks in `wait_on_set` (for tests to
release a producer only after the owner is provably waiting).
""".
-spec call_async(instance(), binary(),
                 {[wasm_canon:desc()], wasm_canon:desc() | none}, [term()]) ->
          {ok, term()} | {error, term()}.
call_async(I, Export, Sig, Args) ->
    call_async(I, Export, Sig, Args, #{}).

-spec call_async(instance(), binary(),
                 {[wasm_canon:desc()], wasm_canon:desc() | none}, [term()], map()) ->
          {ok, term()} | {error, term()}.
call_async(#{} = I, Export, {Params, Result}, Args, Opts) ->
    %% Same boundary as `call/4`: the async lift/lower is captured so a malformed
    %% value returns `{error, _}` rather than raising (see `call/4`).
    wasm_error:capture(
      fun() -> do_call_async(I, Export, {Params, Result}, Args, Opts) end).

do_call_async(I, Export, {Params, Result}, Args, Opts) ->
    case async_lift_name(I, Export) of
        {ok, LiftName} ->
            Inst = core_with_export(I, LiftName),
            Callback = async_callback(I, LiftName),
            ok = wasm_async:begin_task(Inst, Opts),
            try
                {Descs, Lowered} = prepare_async_params(Params, Args),
                CoreArgs = wasm_canon:lower_params(Inst, Descs, Lowered),
                case wasm:call(Inst, LiftName, CoreArgs) of
                    {ok, [Status]} -> finish_async(Result,
                                                    drive(Callback, Status, ?ASYNC_BUDGET));
                    {ok, _}        -> {error, {async_bad_status, LiftName}};
                    {error, _} = E -> E
                end
            after
                wasm_async:end_task()
            end;
        error ->
            {error, {no_async_export, Export}}
    end.

%% When the result is itself a `future<T>`/`stream<T>` the guest produced and returned,
%% `task.return` handed back its readable handle; read the value the guest wrote before
%% the task frame is torn down. Any other result passes straight through.
finish_async({future, _}, {ok, Handle}) -> produced(Handle);
finish_async({stream, _}, {ok, Handle}) -> produced(Handle);
finish_async(_Result, Res)              -> Res.

produced(Handle) ->
    case wasm_async:take_produced(Handle) of
        {ok, Value} -> {ok, Value};
        error       -> {ok, undefined}
    end.

%% Drive the callback loop from a callee status. The status is an unsigned i32 packing
%% `code | (waitable_set << 4)`; mask before extracting so a set index with the top bit
%% set does not read as negative. The budget bounds total turns (a runaway guard, not a
%% progress check - a stream legitimately takes many turns).
drive(_Callback, _Status, 0) ->
    {error, async_budget_exhausted};
drive(Callback, Status, Budget) ->
    Bits = Status band 16#FFFFFFFF,
    case {Bits band 16#F, Bits bsr 4} of
        {0, _} ->
            case wasm_async:take_return() of
                {ok, Value} -> {ok, Value};
                undefined   -> {ok, undefined}
            end;
        {1, _} ->
            resume(Callback, [0, 0, 0], Budget);
        {2, Set} ->
            case wasm_async:wait_on_set(Set) of
                {event, EC, W, P} -> resume(Callback, [EC, W, P], Budget);
                {error, _} = Err  -> Err
            end;
        {Other, _} ->
            {error, {async_bad_status, Other}}
    end.

%% Re-enter the guest through its callback with an event triple; a lift with no
%% callback export is the stackful form, which this milestone does not drive.
resume(none, _Args, _Budget) ->
    {error, async_stackful_unsupported};
resume({CbInst, CbName}, Args, Budget) ->
    case wasm:call(CbInst, CbName, Args) of
        {ok, [Status]} -> drive({CbInst, CbName}, Status, Budget - 1);
        {ok, _}        -> {error, async_bad_result};
        {error, _} = E -> E
    end.

%% Lower an async call's parameters: a `future<T>`/`stream<T>` argument becomes the
%% readable end of a waitable (an i32 handle the guest reads from), fed eagerly, queued
%% before-WAIT, or by a spawned producer; any other parameter lowers by its descriptor.
prepare_async_params(Params, Args) ->
    lists:unzip([prepare_async_param(P, A) || {P, A} <- lists:zip(Params, Args)]).

prepare_async_param({future, Desc}, {producer, PFun}) ->
    H = wasm_async:new_future_channel(Desc),
    ok = wasm_async:register_producer(H, PFun),
    {handle, H};
prepare_async_param({future, Desc}, {ready_before, Value}) ->
    H = wasm_async:new_future_channel(Desc),
    ok = wasm_async:deliver_before(H, {value, Value}),
    {handle, H};
prepare_async_param({future, Desc}, Value) ->
    {handle, wasm_async:new_future_readable(Desc, Value)};
prepare_async_param({stream, Desc}, {producer, PFun}) ->
    H = wasm_async:new_stream_channel(Desc),
    ok = wasm_async:register_producer(H, PFun),
    {handle, H};
prepare_async_param({stream, Desc}, {ready_before, Bin}) ->
    H = wasm_async:new_stream_channel(Desc),
    ok = wasm_async:deliver_before(H, {data, Bin}),
    ok = wasm_async:deliver_before(H, close),
    {handle, H};
prepare_async_param({stream, Desc}, Elements) ->
    {handle, wasm_async:new_stream_readable(Desc, Elements)};
prepare_async_param(Desc, Value) ->
    {Desc, Value}.

%% The `[callback]<lift>` core function that resumes the async task, on whichever core
%% carries it; `none` when the lift has no callback (the stackful form).
async_callback(I, LiftName) ->
    CbName = <<"[callback]", LiftName/binary>>,
    case [C || C <- cores_of(I), maps:is_key(CbName, wasm:exports(C))] of
        [CbInst | _] -> {CbInst, CbName};
        []           -> none
    end.

%% The `[async-lift]<iface>#<fn>` (or `[async-lift]<fn>`) core function a component's
%% async export lifts from, found across the built cores (the lift often lives on a
%% core other than the entry). The component export names the interface or function;
%% the lift core export prefixes it with `[async-lift]`.
async_lift_name(I, Export) ->
    Prefix = <<"[async-lift]", Export/binary>>,
    Names = lists:append([maps:keys(wasm:exports(C)) || C <- cores_of(I)]),
    case [N || N <- Names, is_async_lift(N, Prefix)] of
        [Name | _] -> {ok, Name};
        []         -> error
    end.

%% A core export is this export's async lift when it is exactly `[async-lift]Export`
%% or `[async-lift]Export#<fn>` (an interface export names the function after `#`).
is_async_lift(Name, Prefix) ->
    Name =:= Prefix orelse
        case Name of
            <<Prefix:(byte_size(Prefix))/binary, $#, _/binary>> -> true;
            _                                                   -> false
        end.

%% The core instance that exports `CoreName`: the entry core when it carries it
%% (the common single-core path), else the first other core that does, falling back
%% to the entry so the existing `unknown_export` value is what surfaces.
core_with_export(#{core := Entry} = I, CoreName) ->
    case maps:is_key(CoreName, wasm:exports(Entry)) of
        true  -> Entry;
        false ->
            case [C || C <- cores_of(I), maps:is_key(CoreName, wasm:exports(C))] of
                [C | _] -> C;
                []      -> Entry
            end
    end.

%% A `none` result (an export that returns nothing) lifts to `undefined`.
lift_call_result(_Inst, none, _CoreResults) -> undefined;
lift_call_result(Inst, Result, CoreResults) ->
    wasm_canon:lift_result(Inst, Result, CoreResults).

-doc """
Wrap a typed host function as an import, handling the Canonical ABI both ways.

`Sig` is `{Params, Result}` of value descriptors. The returned raw import lifts
the guest's flat arguments to Erlang terms, calls `Fun(Terms)`, and lowers the
result -- into the guest's return area for a by-memory result (a `string`, a
`list`, a `record`), or flat for a small one. `Result` may be `none` for a
function that returns nothing.
""".
-spec import_fun({[wasm_canon:desc()], wasm_canon:desc() | none},
                 fun(([term()]) -> term())) -> function().
import_fun({Params, Result}, Fun) ->
    fun(Ctx, Flats) ->
        Inst = maps:get(instance, Ctx),
        {Terms, Rest} = wasm_canon:lift_params(Inst, Params, Flats),
        Value = Fun(Terms),
        lower_import_result(Inst, Result, Rest, Value)
    end.

lower_import_result(_Inst, none, _Rest, _Value) ->
    {ok, []};
lower_import_result(Inst, Result, Rest, Value) ->
    case wasm_canon:result_via_memory(Result) of
        true ->
            [RetPtr] = Rest,
            ok = wasm_canon:store_value(Inst, Result, RetPtr, Value),
            {ok, []};
        false ->
            {ok, wasm_canon:lower_value(Inst, Result, Value)}
    end.

-doc """
Drop a resource handle the host holds, running the resource's destructor.

`DtorExport` is the destructor's export, the resource's interface-qualified
prefix followed by `[dtor]<res>`, e.g. `example:counter/counters#[dtor]counter`.
The handle must be live, held by the host, and of the type that destructor
destroys; otherwise the answer is a `resource_not_live` or `resource_wrong_type`
trap and the destructor is not called. On success the handle is removed from
the instance's table, the destructor runs with the guest's representation, and
its result is answered: `ok`, or the trap it raised.
""".
-spec drop_resource(instance(), binary(), non_neg_integer()) ->
          ok | {error, term()}.
drop_resource(#{composed := true, insts := Insts}, DtorExport, Handle) ->
    case [Sub || {instance, Sub} <- maps:values(Insts),
                 provides(Sub, DtorExport)] of
        [Sub | _] -> drop_resource(Sub, DtorExport, Handle);
        []        -> {error, {unknown_export, DtorExport}}
    end;
drop_resource(#{core := _} = I, DtorExport, Handle) ->
    wasm_error:capture(
      fun() ->
          case provides(I, DtorExport) of
              true  -> drop_checked(I, DtorExport, Handle);
              false -> {error, {unknown_export, DtorExport}}
          end
      end).

drop_checked(#{res_id := Id} = I, DtorExport, Handle) ->
    {Inst, CoreName} = target_for(I, DtorExport),
    Rt = maps:get(DtorExport, maps:get(res_dtors, I, #{}), undefined),
    case wasm_resources:exists(Id) of
        true  -> drop_live(Id, Rt, Inst, CoreName, Handle);
        %% No table: answer what the destroyed (or unowned) instance answers.
        false -> run_dtor(Inst, CoreName, Handle)
    end.

drop_live(Id, Rt, Inst, CoreName, Handle) ->
    wasm_resources:with_instance(
      Id,
      fun() ->
          run_dtor(Inst, CoreName, wasm_resources:host_drop(Id, Rt, Handle))
      end).

run_dtor(Inst, CoreName, Rep) ->
    case wasm:call(Inst, CoreName, [Rep]) of
        {ok, _}        -> ok;
        {error, _} = E -> E
    end.

%% Whether an instance has a core function for `Export`.
provides(#{composed := true, insts := Insts}, Export) ->
    lists:any(fun({instance, Sub}) -> provides(Sub, Export);
                 (_Other)          -> false
              end, maps:values(Insts));
provides(#{core := _} = I, Export) ->
    {Inst, CoreName} = target_for(I, Export),
    maps:is_key(CoreName, wasm:exports(Inst)).

%%% ------------------------------------------------------ import resolution ---

%% Key each core import to a provider. A real component imports versioned ids
%% (`wasi:io/streams@0.2.0`) while the host is keyed bare (`wasi:io/streams`), so
%% resolution strips the version. An explicit provider wins over an auto resource
%% intrinsic, so a host-owned resource's `[resource-drop]` reaches the host table
%% rather than the guest's identity table. A core import with no provider is left
%% out, and instantiation refuses it, as before.
resolve_imports(CoreImports, Explicit, Auto) ->
    maps:from_list(
      lists:filtermap(
        fun({Mod, Field} = Key) ->
            case find_provider(Mod, Field, Explicit, Auto) of
                undefined -> false;
                Provider  -> {true, {Key, Provider}}
            end
        end, CoreImports)).

find_provider(Mod, Field, Explicit, Auto) ->
    case maps:find({strip_version(Mod), Field}, Explicit) of
        {ok, Provider} -> Provider;
        error          -> maps:get({Mod, Field}, Auto, undefined)
    end.

%% `namespace:package/interface@version` -> `namespace:package/interface`.
strip_version(Id) ->
    case binary:split(Id, <<"@">>) of
        [Base, _Version] -> Base;
        _                -> Id
    end.

%%% -------------------------------------------------------- resource table ---

%% For each resource built-in the core module imports, a host function backed by
%% the instance's handle table (see wasm_resources). `[resource-new]` mints a
%% handle for the representation the guest gives it, `[resource-rep]` answers
%% the representation behind a live handle of its type, and `[resource-drop]`
%% removes the handle and runs the destructor. `Res` gives each built-in's
%% resource type, read from the graph; one it does not cover is checked for
%% liveness only.
resource_imports(Imports, Res) ->
    Types = maps:get(intrinsics, Res, #{}),
    maps:from_list([{Key, intrinsic(Key, maps:get(Key, Types, none))}
                    || {_Mod, Field} = Key <- Imports, is_intrinsic(Field)]).

is_intrinsic(Field) ->
    lists:any(fun(P) -> binary:match(Field, P) =/= nomatch end,
              [<<"[resource-new]">>, <<"[resource-drop]">>,
               <<"[resource-rep]">>]).

intrinsic({_Mod, Field} = Key, Typed) ->
    Rt = case Typed of
             {_Kind, T} -> T;
             none       -> undefined
         end,
    case intrinsic_kind(Field) of
        new  -> fun(_Ctx, [Rep]) -> {ok, [wasm_resources:new(Rt, Rep)]} end;
        rep  -> fun(_Ctx, [H])   -> {ok, [wasm_resources:rep(Rt, H)]} end;
        drop -> Dtor = dtor_name(Key, Rt),
                fun(Ctx, [H]) -> intrinsic_drop(Ctx, Rt, Dtor, H) end
    end.

%% A guest drop of a handle it holds: a double drop, a use-after-drop or a
%% never-minted handle traps. The destructor of a resource defined here runs
%% with the representation; one that stands for another component's resource is
%% released there.
intrinsic_drop(Ctx, Rt, Dtor, H) ->
    case wasm_resources:drop(Rt, H) of
        remote -> {ok, []};
        Rep    -> run_named_dtor(Ctx, Dtor, Rep), {ok, []}
    end.

%% The destructor the toolchain exports for a resource the component defines:
%% `[resource-drop]<res>` imported from `[export]<iface>` is destroyed by the
%% core export `<iface>#[dtor]<res>`. `none` for a type defined elsewhere.
dtor_name(_Key, undefined) ->
    none;
dtor_name({<<"[export]", Iface/binary>>, <<"[resource-drop]", Res/binary>>},
          _Rt) ->
    <<Iface/binary, "#[dtor]", Res/binary>>;
dtor_name(_Key, _Rt) ->
    none.

run_named_dtor(_Ctx, none, _Rep) ->
    ok;
run_named_dtor(#{instance := Inst}, Dtor, Rep) ->
    case maps:is_key(Dtor, wasm:exports(Inst)) of
        true  -> _ = wasm:call(Inst, Dtor, [Rep]), ok;
        false -> ok
    end;
run_named_dtor(_Ctx, _Dtor, _Rep) ->
    ok.

intrinsic_kind(Field) ->
    case binary:match(Field, <<"[resource-new]">>) of
        nomatch ->
            case binary:match(Field, <<"[resource-drop]">>) of
                nomatch -> rep;
                _       -> drop
            end;
        _ -> new
    end.

%%% -------------------------------------------------- host resource table ---

%% A resource the host owns, kept in the instance-owning process (host imports
%% run there, like the identity table above). A WASI 0.2 world mints a handle
%% here when it returns an `own`, dispatches methods by looking the handle up,
%% and drops it on `[resource-drop]`. Separate from the identity table: a
%% host-owned resource has state and its own handle space.

-doc """
Mint a fresh host-owned resource handle carrying `State`, tagged `Tag`.

The table is per-process, shared by every instance in the process; `destroy`
sweeps all of it, so the contract is one live instance per process (see `destroy/2`).
""".
-spec host_new(atom(), term()) -> pos_integer().
host_new(Tag, State) ->
    Table = host_table(),
    case get(?HOST_LIMIT) of
        Limit when is_integer(Limit), map_size(Table) >= Limit ->
            %% Over the cap: refuse rather than grow without bound. It surfaces as a
            %% resource-limit trap (a guest cannot recover host memory it exhausted),
            %% the same boundary wasmtime enforces.
            wasm_error:trap(resource_limit_reached, #{limit => Limit});
        _ ->
            Handle = case get(?HOST_NEXT) of undefined -> 1; N -> N end,
            put(?HOST_NEXT, Handle + 1),
            put(?HOST, maps:put(Handle, {Tag, State}, Table)),
            Handle
    end.

-doc "The tag and state behind a host handle, or `error` if it is not live.".
-spec host_get(pos_integer()) -> {ok, {atom(), term()}} | error.
host_get(Handle) ->
    maps:find(Handle, host_table()).

-doc "Replace the state behind a live host handle, keeping its tag.".
-spec host_update(pos_integer(), term()) -> ok.
host_update(Handle, State) ->
    case maps:find(Handle, host_table()) of
        {ok, {Tag, _Old}} ->
            put(?HOST, maps:put(Handle, {Tag, State}, host_table())),
            ok;
        error ->
            ok
    end.

-doc "Drop a host handle. A miss (double drop, unknown handle) is a no-op.".
-spec host_drop(pos_integer()) -> ok.
host_drop(Handle) ->
    put(?HOST, maps:remove(Handle, host_table())),
    ok.

-doc "The live host handles in this process, for tests and teardown checks.".
-spec host_live() -> [pos_integer()].
host_live() ->
    lists:sort(maps:keys(host_table())).

host_table() ->
    case get(?HOST) of
        undefined -> #{};
        Map       -> Map
    end.

%%% --------------------------------------------------------------- helpers ---

%% Post-return frees the guest memory the result was lifted from. It runs the function the
%% lift DECLARED (not `cabi_post_<export>` by name), passing the core result the same way
%% the lift consumed it; a lift that declares none has no cleanup. A trap during cleanup
%% is a defined failure of the call, not swallowed (the Canonical ABI traps it).
run_post_return(_Inst, none, _CoreResults) ->
    ok;
run_post_return(Inst, Name, CoreResults) ->
    case wasm:call(Inst, Name, CoreResults) of
        {ok, _}    -> ok;
        {error, E} -> wasm_error:trap({host_error, {post_return_failed, Name, E}}, #{})
    end.
