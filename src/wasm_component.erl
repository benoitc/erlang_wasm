-module(wasm_component).
-moduledoc """
Internal, Phase 0 spike: decode and run a WebAssembly **component**.

This is the first slice of component-model support (see the plan). It handles the
smallest real case end to end: a single-core-module component that imports
nothing, so it exercises the component front-end and the Canonical ABI without any
WASI 0.2 host. It is deliberately a subset.

A component binary shares the core preamble magic but a different version/layer
(`00 61 73 6d 0d 00 01 00`, layer 1) and a different set of top-level sections. A
core module is layer 0 (`... 01 00 00 00`). `decode/1` walks the top-level
sections, extracts the embedded core module (section id 1) and reads the exported
function names (section id 11); `instantiate/1` loads and instantiates that core
module through the existing runtime; `call/4` lowers an Erlang term into the
guest, calls the lifted export, lifts the result back and runs the post-return.

Not yet handled (later phases): nested components, component/core instance
sections beyond one module, aliases and canon parsing (the wiring is taken from
the core module's own canonical exports here), resources, imports, and WASI 0.2.
""".

-export([decode/1, instantiate/1, call/4]).

-export_type([component/0, instance/0]).

-opaque component() :: #{core := binary(), exports := [binary()]}.
-opaque instance() :: #{core := wasm:instance(), exports := [binary()]}.

-define(CORE_MODULE_SEC, 1).
-define(EXPORT_SEC, 11).

-doc """
Decode a component binary into its embedded core module and export names.

`{error, not_a_component}` if the bytes are a core module or not wasm at all.
""".
-spec decode(binary()) -> {ok, component()} | {error, term()}.
decode(<<16#00, 16#61, 16#73, 16#6d, 16#0d, 16#00, 16#01, 16#00, Rest/binary>>) ->
    case sections(Rest, #{exports => []}) of
        {ok, #{core := _} = C} -> {ok, C};
        {ok, _}                -> {error, no_core_module};
        {error, _} = E         -> E
    end;
decode(<<16#00, 16#61, 16#73, 16#6d, _/binary>>) ->
    {error, not_a_component};
decode(_) ->
    {error, not_wasm}.

%% Walk the top-level sections: each is a one-byte id, a u32 size, then that many
%% content bytes. Only the core module and the export section matter to the spike;
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

section(?CORE_MODULE_SEC, Content, Acc) ->
    %% The content is a full core module binary, magic and all.
    Acc#{core => Content};
section(?EXPORT_SEC, Content, Acc) ->
    Acc#{exports => export_names(Content)};
section(_Other, _Content, Acc) ->
    Acc.

%% Read the exported names, tolerantly: a component export is a name string
%% (a leading kind byte then a u32 length and the bytes) followed by a sort and
%% index we do not need here. We keep only the names; the sort/index is resolved
%% against the core module's own exports at call time in this spike.
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
            %% Skip the sort byte and the index that follow the name.
            Rest3 = skip_sortidx(Rest2),
            export_names(N - 1, Rest3, [Name | Acc]);
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

-doc "Decode and instantiate a component. The core module imports nothing.".
-spec instantiate(binary()) -> {ok, instance()} | {error, term()}.
instantiate(Bin) ->
    case decode(Bin) of
        {ok, #{core := Core, exports := Exports}} ->
            case wasm:load(Core) of
                {ok, Mod} ->
                    case wasm:instantiate(Mod, #{}) of
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
Call a lifted export, lowering `Input` and lifting the result by `Sig`.

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

%% The result is returned through a guest-allocated area; `cabi_post_<name>` frees
%% it. Absent (a flat result) it is a no-op.
post_return(Inst, Export, [RetPtr]) when is_integer(RetPtr) ->
    Post = <<"cabi_post_", Export/binary>>,
    try wasm:call(Inst, Post, [RetPtr]) of
        _ -> ok
    catch
        _:_ -> ok
    end;
post_return(_Inst, _Export, _Results) ->
    ok.
