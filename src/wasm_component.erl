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
intrinsics `[resource-new]`/`[resource-drop]` from its own canon, and the host
must provide them: they are the handle table. This module keeps a per-process
table (the instance is process-scoped, and the intrinsics run in that process),
minting a handle for each resource the guest exports and tracking which are live.
The guest here uses identity handles (it imports no `[resource-rep]`), so a handle
is its representation; a resource value crosses the Canonical ABI as a `u32`
handle. `drop_resource/3` runs the guest destructor for a handle the host owns.

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
         destroy/1, destroy/2, drop_resource/3]).
-export([import_fun/2, exports/1]).
-export([host_new/2, host_get/1, host_update/2, host_drop/1, host_live/0]).

-export_type([component/0, instance/0]).

-opaque component() :: #{core := binary(), cores := [binary()],
                         sec := binary(), entry_idx := non_neg_integer(),
                         exports := [binary()]}.
-opaque instance() :: #{core := wasm:instance(), exports := [binary()],
                        cores := [wasm:instance()],
                        export_map => #{binary() => binary()}}.

-define(CORE_MODULE_SEC, 1).
-define(EXPORT_SEC, 11).
-define(HANDLES, {?MODULE, handles}).
-define(HOST, {?MODULE, host_resources}).
-define(HOST_NEXT, {?MODULE, host_next}).
%% An optional cap on how many host resources may be live at once, so a guest that
%% creates and never drops (forgets) them cannot exhaust host memory. `infinity`
%% (the default) is no cap; a caller sets it through `instantiate` opts.
-define(HOST_LIMIT, {?MODULE, host_limit}).

-doc """
Decode a component binary into its embedded core module and export names.

`{error, not_a_component}` if the bytes are a core module or not wasm at all.
""".
-spec decode(binary()) -> {ok, component()} | {error, term()}.
decode(<<16#00, 16#61, 16#73, 16#6d, 16#0d, 16#00, 16#01, 16#00, Rest/binary>>) ->
    case sections(Rest, #{exports => [], cores => []}) of
        {ok, #{cores := []}} ->
            {error, no_core_module};
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

instantiate_decoded(#{core := Core, exports := Exports, sec := Sec} = Decoded,
                    Imports, Opts, Limits) ->
    Loader = maps:get(loader, Opts, load),
    EntryImports = wasm_component_link:core_imports(Core),
    Host = resolve_imports(EntryImports, Imports, resource_imports(EntryImports)),
    %% The export map lets `call/4` reach a core function whose name differs from the
    %% component export name; where they coincide it is the identity and the same-name
    %% fallback in `call/4` covers exports it does not resolve.
    ExportMap = wasm_component_link:export_map(Sec),
    %% Imports the host set does not cover are wired from other cores of this
    %% component (the linker); a program that asks for WASI directly has none, so
    %% it stays on the single-core path unchanged.
    Result = case [K || K <- EntryImports, not maps:is_key(K, Host)] of
                 [] ->
                     start(Loader, Core, Host, Limits, Exports, []);
                 _Leftovers ->
                     link_in(Decoded, Imports, Opts)
             end,
    with_export_map(Result, ExportMap).

with_export_map({ok, Inst}, ExportMap) -> {ok, Inst#{export_map => ExportMap}};
with_export_map(Other, _ExportMap)     -> Other.

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
                  resolve_imports(Imps, Imports, resource_imports(Imps))
              end,
    LinkOpts = Opts#{drop_fun => drop_fun(Opts)},
    case wasm_component_link:parse(Sec) of
        {ok, Graph} ->
            case wasm_component_link:link(Graph, EntryIdx, Resolve, LinkOpts) of
                {ok, #{core := Inst, cores := Cores}} ->
                    {ok, #{core => Inst, exports => Exports, cores => Cores}};
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
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
    sweep_host(Closer),
    ok.

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
    _ = erase(?HANDLES),
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
call(#{} = I, Export, {Params, Result}, Args) ->
    CoreName = resolve_export(I, Export),
    %% A multi-core component lifts different exports from different cores (a proxy
    %% component lifts `wasi:cli/run#run` from a command shim and
    %% `wasi:http/incoming-handler#handle` from the main module). The entry core is
    %% the run shim, so an export the entry core does not carry is looked up on the
    %% core that does.
    Inst = core_with_export(I, CoreName),
    CoreArgs = wasm_canon:lower_params(Inst, Params, Args),
    case wasm:call(Inst, CoreName, CoreArgs) of
        {ok, CoreResults} ->
            Value = lift_call_result(Inst, Result, CoreResults),
            _ = post_return(Inst, CoreName, CoreResults),
            {ok, Value};
        {error, _} = E ->
            E
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
Run a resource's destructor for a handle the host owns.

`Prefix` is the resource's interface-qualified name, e.g.
`example:counter/counters#`; the destructor export is `<Prefix>[dtor]<Res>`.
""".
-spec drop_resource(instance(), binary(), non_neg_integer()) -> ok.
drop_resource(#{core := Inst}, DtorExport, Handle) ->
    _ = wasm:call(Inst, DtorExport, [Handle]),
    _ = untrack(Handle),
    ok.

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

%% For each resource intrinsic the core module imports, a host function backed by
%% the per-process handle table. `[resource-new]` mints a handle for a resource
%% the guest exports (identity here: the handle is the representation) and tracks
%% it live; `[resource-drop]` and `[resource-rep]` serve a guest that manages its
%% own owns.
resource_imports(Imports) ->
    maps:from_list([{{Mod, Field}, intrinsic(Field)}
                    || {Mod, Field} <- Imports, is_intrinsic(Field)]).

is_intrinsic(Field) ->
    lists:any(fun(P) -> binary:match(Field, P) =/= nomatch end,
              [<<"[resource-new]">>, <<"[resource-drop]">>,
               <<"[resource-rep]">>]).

intrinsic(Field) ->
    case intrinsic_kind(Field) of
        new  -> fun(_Ctx, [Rep])    -> {ok, [track(Rep)]} end;
        drop -> fun(_Ctx, [Handle]) -> _ = untrack(Handle), {ok, []} end;
        rep  -> fun(_Ctx, [Handle]) -> {ok, [Handle]} end
    end.

intrinsic_kind(Field) ->
    case binary:match(Field, <<"[resource-new]">>) of
        nomatch ->
            case binary:match(Field, <<"[resource-drop]">>) of
                nomatch -> rep;
                _       -> drop
            end;
        _ -> new
    end.

%% Identity handles: the handle is the representation. The table records which are
%% live so a double drop or a use-after-drop is a table miss rather than silent.
track(Rep) ->
    put(?HANDLES, maps:put(Rep, true, live())),
    Rep.

untrack(Handle) ->
    put(?HANDLES, maps:remove(Handle, live())),
    ok.

live() ->
    case get(?HANDLES) of
        undefined -> #{};
        Map       -> Map
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

%% Post-return frees the guest memory the result was lifted from. It is best
%% effort: a component without a `cabi_post_<export>`, or one that traps during
%% cleanup, must not turn an otherwise-successful call into a failure.
post_return(Inst, Export, [RetPtr]) when is_integer(RetPtr) ->
    Post = <<"cabi_post_", Export/binary>>,
    try wasm:call(Inst, Post, [RetPtr]) of
        _ -> ok
    catch
        _:_ -> ok
    end;
post_return(_Inst, _Export, _Results) ->
    ok.
