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

Not yet handled (later phases): nested components, multiple core instances,
aliases and canon parsing (the wiring is taken from the core module's own
canonical exports), imports other than resource intrinsics, and WASI 0.2.
""".

-export([decode/1, instantiate/1, call/4, drop_resource/3]).

-export_type([component/0, instance/0]).

-opaque component() :: #{core := binary(), exports := [binary()]}.
-opaque instance() :: #{core := wasm:instance(), exports := [binary()]}.

-define(CORE_MODULE_SEC, 1).
-define(EXPORT_SEC, 11).
-define(CORE_IMPORT_SEC, 2).
-define(HANDLES, {?MODULE, handles}).

-doc """
Decode a component binary into its embedded core module and export names.

`{error, not_a_component}` if the bytes are a core module or not wasm at all.
""".
-spec decode(binary()) -> {ok, component()} | {error, term()}.
decode(<<16#00, 16#61, 16#73, 16#6d, 16#0d, 16#00, 16#01, 16#00, Rest/binary>>) ->
    case sections(Rest, #{exports => [], cores => []}) of
        {ok, #{cores := []}} ->
            {error, no_core_module};
        {ok, #{cores := Cores, exports := Exports}} ->
            %% A resource component embeds a tiny intrinsics shim beside the guest;
            %% the guest is the larger module. Selecting it by size is a spike
            %% shortcut for parsing the instance/alias graph.
            [Core | _] = lists:sort(fun(A, B) -> byte_size(A) >= byte_size(B) end,
                                    Cores),
            {ok, #{core => Core, exports => Exports}};
        {error, _} = E ->
            E
    end;
decode(<<16#00, 16#61, 16#73, 16#6d, _/binary>>) ->
    {error, not_a_component};
decode(_) ->
    {error, not_wasm}.

%% Walk the top-level sections: each is a one-byte id, a u32 size, then that many
%% content bytes. Only the core module and the export section matter here;
%% everything else (types, instances, aliases, canon, customs) is skipped by size.
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
section(?EXPORT_SEC, Content, Acc) ->
    Acc#{exports => export_names(Content)};
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
            export_names(N - 1, skip_sortidx(Rest2), [Name | Acc]);
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

-doc "Decode and instantiate a component, wiring any resource intrinsics.".
-spec instantiate(binary()) -> {ok, instance()} | {error, term()}.
instantiate(Bin) ->
    case decode(Bin) of
        {ok, #{core := Core, exports := Exports}} ->
            case wasm:load(Core) of
                {ok, Mod} ->
                    Imports = resource_imports(core_imports(Core)),
                    case wasm:instantiate(Mod, Imports) of
                        {ok, Inst}     -> {ok, #{core => Inst,
                                                 exports => Exports}};
                        {error, _} = E -> E
                    end;
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

-doc """
Call a lifted export, lowering `Args` and lifting the result by `Sig`.

`Sig` is `{Params, Result}` of Canonical ABI value descriptors (see `wasm_canon`).
The post-return `cabi_post_<Export>` is run after the result is lifted.
""".
-spec call(instance(), binary(), {[wasm_canon:desc()], wasm_canon:desc()},
           [term()]) -> {ok, term()} | {error, term()}.
call(#{core := Inst}, Export, {Params, Result}, Args) ->
    CoreArgs = wasm_canon:lower_params(Inst, Params, Args),
    case wasm:call(Inst, Export, CoreArgs) of
        {ok, CoreResults} ->
            Value = wasm_canon:lift_result(Inst, Result, CoreResults),
            _ = post_return(Inst, Export, CoreResults),
            {ok, Value};
        {error, _} = E ->
            E
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

%%% ----------------------------------------------------------- core imports ---

%% The `{Module, Field}` of every function import in the core module, so the
%% resource intrinsics can be matched and provided. Non-function imports are
%% skipped past.
core_imports(<<16#00, 16#61, 16#73, 16#6d, _:4/binary, Rest/binary>>) ->
    core_import_sections(Rest).

core_import_sections(<<>>) ->
    [];
core_import_sections(<<Id, Rest0/binary>>) ->
    {Size, Rest1} = wasm_leb128:u32(Rest0),
    <<Content:Size/binary, Rest2/binary>> = Rest1,
    case Id of
        ?CORE_IMPORT_SEC -> import_entries(Content);
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

name(Bin) ->
    {Len, Rest} = wasm_leb128:u32(Bin),
    <<Name:Len/binary, Rest1/binary>> = Rest,
    {Name, Rest1}.

%% Skip one import descriptor: kind byte then its type. Only func (0x00) imports
%% are matched above; the others are stepped over so parsing reaches the next.
skip_importdesc(<<16#00, Rest/binary>>) -> {_T, R} = wasm_leb128:u32(Rest), R;
skip_importdesc(<<16#01, _Reftype, Rest/binary>>) -> skip_limits(Rest);
skip_importdesc(<<16#02, Rest/binary>>) -> skip_limits(Rest);
skip_importdesc(<<16#03, _Valtype, _Mut, Rest/binary>>) -> Rest.

skip_limits(<<0, Rest/binary>>) -> {_Min, R} = wasm_leb128:u32(Rest), R;
skip_limits(<<1, Rest/binary>>) ->
    {_Min, R1} = wasm_leb128:u32(Rest),
    {_Max, R2} = wasm_leb128:u32(R1),
    R2.

%%% --------------------------------------------------------------- helpers ---

post_return(Inst, Export, [RetPtr]) when is_integer(RetPtr) ->
    Post = <<"cabi_post_", Export/binary>>,
    try wasm:call(Inst, Post, [RetPtr]) of
        _ -> ok
    catch
        _:_ -> ok
    end;
post_return(_Inst, _Export, _Results) ->
    ok.
