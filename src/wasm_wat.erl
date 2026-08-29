-module(wasm_wat).
-moduledoc """
The text format, parsed into the same `#module{}` the binary decoder produces.

Hand a `.wat` file to `wasm:load/1` and you land here. Everything downstream is
unchanged: a text module is validated, instantiated and
run by exactly the code a binary one is. The text format is a *front end*, not a
second runtime, and the way to keep it honest is to make it produce the same
value rather than a parallel one.

## Three passes

Index spaces are collected first and bodies parsed last, because the format
allows forward references: a function may call one declared later in the file.
A single pass would have to patch indices afterwards, which is the same passes
with the bookkeeping hidden.

Between them sits a pass for *implicit types*. A function written
`(func (param i32))` names no type, and the specification says it means the
lowest-numbered existing type that matches, or a new one appended to the module
if none does. So the type section is not known until every type use in the file
has been read, including the ones inside function bodies at `call_indirect` and
at any block that takes parameters. That pass walks for type uses and nothing
else, and the pass that follows only ever *finds* a type: appending one there
would be an index nobody else agrees with, so it is an error instead.

## Abbreviations

Most of the work is not instructions, it is the shorthand. (func $f (export
"f") (param i32)) is three declarations wearing one set of parentheses: a type
if none matches, a function, and an export. The specification calls these
abbreviations and they are not optional; real files are written almost entirely
in them.
""".

-include("wasm.hrl").

-export([module/1, module_form/1]).

%% The instructions that carry a type use. `call_indirect' names a signature
%% because the callee is only known at run time; a block names one when it takes
%% parameters. Everywhere else a type index is written out.
-define(TYPEUSE_HEAD(K),
        K =:= <<"block">>; K =:= <<"loop">>; K =:= <<"if">>;
        K =:= <<"try_table">>; K =:= <<"call_indirect">>;
        K =:= <<"return_call_indirect">>).

%% Declaration syntax, which is not an instruction wherever it turns up. A
%% function's locals and results come before its body, so one written after it
%% is a mistake rather than a call to something named `local'.
-define(DECLARATION(K),
        K =:= <<"param">>; K =:= <<"result">>; K =:= <<"local">>;
        K =:= <<"type">>; K =:= <<"catch">>; K =:= <<"catch_ref">>;
        K =:= <<"catch_all">>; K =:= <<"catch_all_ref">>;
        K =:= <<"then">>).

%% Index spaces, name to index. `types` also carries the declared function
%% types so an inline `(param ...) (result ...)` can find an existing match
%% rather than appending a duplicate, which is what the specification says to
%% do and what makes a round trip through the binary format stable.
-record(ctx, {
    names = #{} :: #{atom() => #{binary() => non_neg_integer()}},
    counts = #{} :: #{atom() => non_neg_integer()},
    types = [] :: [#subtype{}],
    %% The type definitions as written, kept until every type *name* is known.
    %% A recursive group's members refer to one another, so a body cannot be
    %% built at the point it is read without failing on its own siblings.
    type_forms = [] :: [term()],
    %% Field names, per struct type. A field name is scoped to the type that
    %% declares it, so `struct.get $s $x' resolves `$x' only after `$s'.
    field_names = #{} :: #{non_neg_integer() => #{binary() => non_neg_integer()}},
    %% The types written as a plain `(type ...)' field. An implicit type use
    %% may only match one of those, never a member of an explicit `(rec ...)',
    %% so a group's members are not silently reused as somebody's signature.
    plain_types = #{} :: #{non_neg_integer() => true},
    in_rec = false :: boolean(),
    %% Whether anything has been *defined* yet. Imports occupy the low indices
    %% of every space, so the format requires them to be written first and a
    %% later one is malformed rather than merely surprising.
    defined = false :: boolean(),
    started = false :: boolean(),
    %% Where each recursive group starts and how many types it holds. Not
    %% cosmetic: type identity is nominal *within* a group and structural
    %% across groups, so a front end that lost the boundaries would make two
    %% distinct types equal.
    groups = [] :: [{non_neg_integer(), pos_integer()}],
    labels = [] :: [binary() | undefined]
}).

-doc "Parse a text module.".
-spec module(binary()) -> {ok, #module{}} | {error, wasm_error:error()}.
module(Source) ->
    wasm_error:capture(fun() -> {ok, parse(Source)} end).

-doc """
Parse a module that has already been read.

For `.wast` scripts, whose commands are read once as a whole and whose modules
are parsed one at a time afterwards. Reading the file twice would mean a script
with one malformed module in an `assert_malformed` could not be read at all.
""".
-spec module_form(wasm_wat_sexp:sexp()) -> {ok, #module{}} | {error, wasm_error:error()}.
module_form(Form) ->
    wasm_error:capture(fun() -> {ok, parse_forms([Form])} end).

parse(Source) ->
    parse_forms(wasm_wat_sexp:forms_of(Source)).

parse_forms(Forms) ->
    ok = ensure_instruction_atoms(),
    Fields = module_fields(Forms),
    Ctx = resolve(Fields, declared_types(collect(Fields, #ctx{}))),
    with_data_count(build(Fields, Ctx)).

%% The data count section is present exactly when a data index appears in the
%% code, which is what lets `memory.init' be validated without reading the data
%% section. Emitting it merely because there are segments is a different module
%% from the one the binary format produces for the same source.
with_data_count(#module{datas = []} = M) ->
    M;
with_data_count(#module{datas = Datas, funcs = Funcs} = M) ->
    case lists:any(fun(#func{body = Body}) -> names_data(Body) end, Funcs) of
        true -> M#module{data_count = length(Datas)};
        false -> M
    end.

names_data(Body) -> lists:any(fun names_data_instr/1, Body).

names_data_instr({block, _, Body}) -> names_data(Body);
names_data_instr({loop, _, Body}) -> names_data(Body);
names_data_instr({if_, _, Then, Else}) -> names_data(Then) orelse names_data(Else);
names_data_instr({try_table, _, _, Body}) -> names_data(Body);
names_data_instr({memory_init, _, _}) -> true;
names_data_instr({data_drop, _}) -> true;
names_data_instr({array_new_data, _, _}) -> true;
names_data_instr({array_init_data, _, _}) -> true;
names_data_instr(_Instr) -> false.

declared_types(Ctx) ->
    Ctx#ctx{types = [subtype(Form, Ctx) || Form <- Ctx#ctx.type_forms], field_names = field_names(Ctx#ctx.type_forms)}.

field_names(Forms) ->
    element(2, lists:foldl(
                 fun(Form, {I, Acc}) ->
                         case struct_fields(Form) of
                             {ok, Args} ->
                                 case named_fields(Args, 0, #{}) of
                                     Empty when map_size(Empty) =:= 0 -> {I + 1, Acc};
                                     Names -> {I + 1, Acc#{I => Names}}
                                 end;
                             false -> {I + 1, Acc}
                         end
                 end, {0, #{}}, Forms)).

struct_fields([Form]) ->
    struct_fields(Form);
struct_fields({list, _, [{keyword, _, <<"struct">>} | Args]}) ->
    {ok, Args};
struct_fields({list, _, [{keyword, _, <<"sub">>} | Args]}) ->
    case lists:reverse(Args) of
        [Body | _] -> struct_fields(Body);
        [] -> false
    end;
struct_fields(_Form) ->
    false.

%% Only `(field $x t)' names anything: `(field t t)' declares two fields and no
%% names, so the position has to be counted rather than assumed.
named_fields([], _I, Acc) ->
    Acc;
named_fields([{list, _, [{keyword, _, <<"field">>}, {id, _, Name}, _T]} | Rest],
             I, Acc) ->
    case maps:is_key(Name, Acc) of
        true -> fail(duplicate_identifier, Name);
        false -> named_fields(Rest, I + 1, Acc#{Name => I})
    end;
named_fields([{list, _, [{keyword, _, <<"field">>} | Types]} | Rest], I, Acc) ->
    named_fields(Rest, I + length(Types), Acc);
named_fields([_ | Rest], I, Acc) ->
    named_fields(Rest, I + 1, Acc).

%% An instruction's atom is looked up rather than created, because the atom
%% table is node-wide and never reclaimed: a text module that could create atoms
%% would be a permanent resource leak, and a `.wast` file is untrusted input
%% like any other. Looking one up only works if it already exists, and an atom
%% exists once the module whose literals mention it is loaded, so the decoders
%% are loaded first. They are where every instruction atom is written down.
%%
%% Found by the differential test rather than by reasoning: `i32.const` came
%% back as a binary because `wasm_decode_code` happened not to be loaded yet.
ensure_instruction_atoms() ->
    lists:foreach(fun(M) -> _ = code:ensure_loaded(M) end,
                  [wasm_decode_code, wasm_decode_simd, wasm_decode_gc,
                   wasm_decode_atomic]),
    ok.

%% A file may write the outer `(module ...)` or leave it out entirely.
module_fields([{list, _, [{keyword, _, <<"module">>} | Rest]}]) ->
    skip_id(Rest);
module_fields(Forms) ->
    Forms.

skip_id([{id, _, _} | Rest]) -> Rest;
skip_id(Fields) -> Fields.

%%% ------------------------------------------------------------ first pass ---

%% Assign an index to every named entity before any body is parsed. Imports
%% occupy the low indices of their space, which is why they are counted here in
%% the order they appear rather than after the definitions.
collect([], Ctx) -> Ctx;
collect([Field | Rest], Ctx) ->
    collect(Rest, collect_field(Field, Ctx)).

collect_field({list, _, [{keyword, _, Kind} | Args]}, Ctx) ->
    collect_kind(Kind, Args, Ctx);
collect_field(Form, _Ctx) ->
    fail(unexpected_module_field, Form).

collect_kind(<<"type">>, Args, Ctx) ->
    {Name, Rest} = optional_id(Args),
    First = length(Ctx#ctx.type_forms),
    declare(type, Name,
            Ctx#ctx{type_forms = Ctx#ctx.type_forms ++ [Rest],
                    groups = Ctx#ctx.groups ++ [{First, 1}],
                    plain_types = plain(First, Ctx)});
%% An explicit `(rec ...)` is one group however many types it declares, which
%% is what makes two identical members of it distinct types. Zero is a count
%% like any other: `(rec)` declares an empty group and still occupies one.
collect_kind(<<"rec">>, Args, Ctx) ->
    First = length(Ctx#ctx.type_forms),
    Ctx1 = lists:foldl(fun(F, C) -> collect_field(F, C) end,
                       Ctx#ctx{in_rec = true}, Args),
    Count = length(Ctx1#ctx.type_forms) - First,
    Groups = lists:sublist(Ctx1#ctx.groups, length(Ctx#ctx.groups)),
    Ctx1#ctx{groups = Groups ++ [{First, Count}], in_rec = Ctx#ctx.in_rec};
collect_kind(<<"import">>, Args, Ctx) ->
    [_Mod, _Name, Desc] = Args,
    collect_import(Desc, ordered(Ctx));
collect_kind(<<"func">>, Args, Ctx) -> declare_maybe(func, Args, Ctx);
collect_kind(<<"table">>, Args, Ctx) -> declare_maybe(table, Args, Ctx);
collect_kind(<<"memory">>, Args, Ctx) -> declare_maybe(memory, Args, Ctx);
collect_kind(<<"global">>, Args, Ctx) -> declare_maybe(global, Args, Ctx);
collect_kind(<<"tag">>, Args, Ctx) -> declare_maybe(tag, Args, Ctx);
collect_kind(<<"elem">>, Args, Ctx) -> declare_maybe(elem, Args, Ctx);
collect_kind(<<"data">>, Args, Ctx) -> declare_maybe(data, Args, Ctx);
collect_kind(<<"export">>, _Args, Ctx) -> Ctx;
%% A module has one start function or none.
collect_kind(<<"start">>, _Args, #ctx{started = true}) ->
    fail(multiple_start_sections, <<"start">>);
collect_kind(<<"start">>, _Args, Ctx) ->
    Ctx#ctx{started = true};
collect_kind(K, _Args, _Ctx) ->
    fail(unknown_module_field, K).

%% An inline import inside a definition counts in the same space, so
%% `(func (import "m" "n") ...)` and `(import "m" "n" (func ...))` agree.
%% The description of an import is not itself a definition, so it takes an
%% index in its space without ending the run of imports.
collect_import({list, _, [{keyword, _, Kind} | Args]}, Ctx) ->
    {Name, _} = optional_id(Args),
    declare(space_of(Kind), Name, Ctx);
collect_import(Form, _Ctx) ->
    fail(unexpected_import_desc, Form).

space_of(<<"func">>) -> func;
space_of(<<"table">>) -> table;
space_of(<<"memory">>) -> memory;
space_of(<<"global">>) -> global;
space_of(<<"tag">>) -> tag;
space_of(K) -> fail(unknown_import_kind, K).

%% An inline import counts as an import, so `(func (import "m" "n"))' after a
%% definition is out of order exactly as `(import "m" "n" (func))' would be.
%% Segments are not in any of the imported spaces and do not affect the order.
declare_maybe(Space, Args, Ctx) when Space =:= elem; Space =:= data ->
    {Name, _} = optional_id(Args),
    declare(Space, Name, Ctx);
declare_maybe(Space, Args, Ctx) ->
    {Name, Rest} = optional_id(Args),
    {_Exports, Rest1} = inline_exports(Rest),
    Ctx1 = case inline_import(Rest1) of
               {undefined, _} -> Ctx#ctx{defined = true};
               {_Import, _} -> ordered(Ctx)
           end,
    declare(Space, Name, Ctx1).

ordered(#ctx{defined = true}) -> fail(import_after_definition, <<"import">>);
ordered(Ctx) -> Ctx.

declare(Space, Name, #ctx{names = Names, counts = Counts} = Ctx) ->
    Index = maps:get(Space, Counts, 0),
    Named = maps:get(Space, Names, #{}),
    Named1 = case Name of
                 undefined -> Named;
                 _ ->
                     case maps:is_key(Name, Named) of
                         true -> fail(duplicate_identifier, Name);
                         false -> Named#{Name => Index}
                     end
             end,
    Ctx#ctx{names = Names#{Space => Named1},
            counts = Counts#{Space => Index + 1}}.

optional_id([{id, _, Name} | Rest]) -> {Name, Rest};
optional_id(Args) -> {undefined, Args}.

plain(_Index, #ctx{in_rec = true, plain_types = Plain}) -> Plain;
plain(Index, #ctx{plain_types = Plain}) -> Plain#{Index => true}.

%%% ------------------------------------------------------ implicit types ---

%% Walk every type use in the file, in the order the file writes them, and
%% append a type for each one that matches none. Order is the whole point: the
%% specification says a type use means the *lowest* matching index, so a type
%% appended for an earlier use is available to a later one and the two share it.
%%
%% Appending only ever happens at the end, so a use that found index N here
%% finds the same N in the pass that follows, where the list is longer but only
%% beyond N. That is what makes running the walk and the build separately safe.
resolve(Fields, Ctx) ->
    lists:foldl(fun(Field, C) -> resolve_field(Field, C) end, Ctx, Fields).

resolve_field({list, _, [{keyword, _, Kind} | Args]}, Ctx) ->
    resolve_kind(Kind, Args, Ctx).

%% Explicit type definitions are already in the list and must not be walked: a
%% `(func ...)' inside `(type ...)' is the type itself, not a use of one.
resolve_kind(<<"type">>, _Args, Ctx) -> Ctx;
resolve_kind(<<"rec">>, _Args, Ctx) -> Ctx;
resolve_kind(<<"func">>, Args, Ctx) ->
    {R1, _Exports, _Import} = declaration(Args),
    {R2, Ctx1} = resolve_typeuse(R1, Ctx),
    resolve_instrs(skip_locals(R2), Ctx1);
resolve_kind(<<"tag">>, Args, Ctx) ->
    {R1, _Exports, _Import} = declaration(Args),
    element(2, resolve_typeuse(R1, Ctx));
resolve_kind(<<"import">>, [_Mod, _Name, Desc], Ctx) ->
    resolve_import(Desc, Ctx);
resolve_kind(<<"global">>, Args, Ctx) ->
    {R1, _Exports, _Import} = declaration(Args),
    case R1 of
        [_Type | Init] -> resolve_instrs(Init, Ctx);
        [] -> Ctx
    end;
%% Element and data segments hold expressions and a table may hold an inline
%% element list, so all three are walked for type uses like any other body.
resolve_kind(Kind, Args, Ctx)
  when Kind =:= <<"elem">>; Kind =:= <<"data">>; Kind =:= <<"table">> ->
    resolve_instrs(Args, Ctx);
resolve_kind(_Kind, _Args, Ctx) ->
    Ctx.

resolve_import({list, _, [{keyword, _, Kind} | Args]}, Ctx)
  when Kind =:= <<"func">>; Kind =:= <<"tag">> ->
    {_Name, Rest} = optional_id(Args),
    element(2, resolve_typeuse(Rest, Ctx));
resolve_import(_Desc, Ctx) ->
    Ctx.

%% Within an instruction sequence the only forms are instructions, so a
%% generic descent is safe here in a way it is not over module fields.
resolve_instrs([], Ctx) ->
    Ctx;
resolve_instrs([{keyword, _, K} | Rest], Ctx) when ?TYPEUSE_HEAD(K) ->
    {Rest1, Ctx1} = resolve_head(K, Rest, Ctx),
    resolve_instrs(Rest1, Ctx1);
resolve_instrs([{list, _, [{keyword, _, K} | Args]} | Rest], Ctx)
  when ?TYPEUSE_HEAD(K) ->
    {Args1, Ctx1} = resolve_head(K, Args, Ctx),
    resolve_instrs(Rest, resolve_instrs(Args1, Ctx1));
resolve_instrs([{list, _, Items} | Rest], Ctx) ->
    resolve_instrs(Rest, resolve_instrs(Items, Ctx));
resolve_instrs([_ | Rest], Ctx) ->
    resolve_instrs(Rest, Ctx).

resolve_head(K, Forms, Ctx)
  when K =:= <<"call_indirect">>; K =:= <<"return_call_indirect">> ->
    {_Table, F1} = take_indices(Forms, 1),
    resolve_typeuse(F1, Ctx);
resolve_head(_K, Forms, Ctx) ->
    resolve_blocktype(skip_id(Forms), Ctx).

resolve_typeuse(Forms, Ctx) ->
    {Explicit, F1} = explicit_type(Forms, Ctx),
    {Params, F2} = named_params(F1, Ctx, []),
    {Results, F3} = results(F2, Ctx, []),
    case Explicit of
        undefined -> {F3, register_type(signature(Params, Results), Ctx)};
        _ -> {F3, Ctx}
    end.

%% A block needs a type only when it takes parameters or returns more than one
%% value. Anything simpler is written directly into the block's own encoding.
resolve_blocktype(Forms, Ctx) ->
    {Explicit, F1} = explicit_type(Forms, Ctx),
    {Params, F2} = anonymous_params(F1, Ctx, []),
    {Results, F3} = results(F2, Ctx, []),
    case {Explicit, Params, Results} of
        {undefined, [], []} -> {F3, Ctx};
        {undefined, [], [_]} -> {F3, Ctx};
        {undefined, _, _} -> {F3, register_type(signature(Params, Results), Ctx)};
        _ -> {F3, Ctx}
    end.

register_type(FT, Ctx) ->
    case type_index(FT, Ctx) of
        {ok, _} -> Ctx;
        error ->
            First = length(Ctx#ctx.types),
            Ctx#ctx{types = Ctx#ctx.types ++ [#subtype{body = FT}],
                    groups = Ctx#ctx.groups ++ [{First, 1}],
                    plain_types = (Ctx#ctx.plain_types)#{First => true}}
    end.

type_index(FT, #ctx{types = Types, plain_types = Plain}) ->
    type_index(FT, Types, Plain, 0).

type_index(_FT, [], _Plain, _I) ->
    error;
type_index(FT, [T | Rest], Plain, I) ->
    case matching_type(FT, T) andalso maps:is_key(I, Plain) of
        true -> {ok, I};
        false -> type_index(FT, Rest, Plain, I + 1)
    end.

%% A type use matches on the signature alone. Whether the type is final or has
%% a supertype does not enter into it: `(type $t (sub (func)))' is what an
%% implicit `(func)' resolves to if it is the first type with that signature.
matching_type(FT, #subtype{body = FT}) -> true;
matching_type(_FT, _Type) -> false.

signature(Params, Results) ->
    #functype{params = [T || {_Name, T} <- Params], results = Results}.

%%% ----------------------------------------------------------- second pass ---

build(Fields, Ctx) ->
    lists:foldl(fun(Field, M) -> build_field(Field, M, Ctx) end,
                #module{types = Ctx#ctx.types,
                        rec_groups = Ctx#ctx.groups}, Fields).

build_field({list, _, [{keyword, _, Kind} | Args]}, M, Ctx) ->
    build_kind(Kind, Args, M, Ctx).

%% Types were built in the first pass, since an inline type reference needs
%% them before any body is read.
build_kind(<<"type">>, _Args, M, _Ctx) -> M;
build_kind(<<"rec">>, _Args, M, _Ctx) -> M;
build_kind(<<"export">>, [{string, _, Name}, Desc], M, Ctx) ->
    M#module{exports = M#module.exports ++
                 [#export{name = name(Name), desc = export_desc(Desc, Ctx)}]};
build_kind(<<"start">>, [Idx], M, Ctx) ->
    M#module{start = index(Idx, func, Ctx)};
build_kind(<<"import">>, [{string, _, Mod}, {string, _, Name}, Desc], M, Ctx) ->
    {Space, Rest} = import_desc(Desc),
    add_import(name(Mod), name(Name), Space, Rest, M, Ctx);
build_kind(<<"memory">>, Args, M, Ctx) ->
    {R1, Exports, Import} = declaration(Args),
    M1 = add_exports(Exports, {mem, current(memory, M)}, M),
    case Import of
        {Mod, Name} -> add_import(Mod, Name, memory, R1, M1, Ctx);
        undefined -> memory_definition(R1, M1, Ctx)
    end;
build_kind(<<"global">>, Args, M, Ctx) ->
    {R1, Exports, Import} = declaration(Args),
    M1 = add_exports(Exports, {global, current(global, M)}, M),
    case Import of
        {Mod, Name} -> add_import(Mod, Name, global, R1, M1, Ctx);
        undefined ->
            [TypeForm | InitForms] = R1,
            M1#module{globals = M1#module.globals ++
                          [#global{type = globaltype(TypeForm, Ctx),
                                   init = expr(InitForms, Ctx)}]}
    end;
build_kind(<<"table">>, Args, M, Ctx) ->
    {R1, Exports, Import} = declaration(Args),
    Idx = current(table, M),
    M1 = add_exports(Exports, {table, Idx}, M),
    case Import of
        {Mod, Name} -> add_import(Mod, Name, table, R1, M1, Ctx);
        undefined -> table_definition(R1, Idx, M1, Ctx)
    end;
build_kind(<<"func">>, Args, M, Ctx) ->
    {R1, Exports, Import} = declaration(Args),
    M1 = add_exports(Exports, {func, current(func, M)}, M),
    {TypeIdx, Params, R2} = typeuse(R1, Ctx),
    case Import of
        {Mod, Name} ->
            M1#module{imports = M1#module.imports ++
                          [#import{module = Mod, name = Name,
                                   desc = {func, TypeIdx}}]};
        undefined ->
            {Locals, R3} = locals(R2, Ctx, []),
            Ctx1 = with_locals(Params ++ Locals, Ctx),
            M1#module{funcs = M1#module.funcs ++
                          [#func{type = TypeIdx,
                                 locals = [T || {_Name2, T} <- Locals], body = seq_all(R3, Ctx1)}]}
    end;
build_kind(<<"tag">>, Args, M, Ctx) ->
    {R1, Exports, Import} = declaration(Args),
    M1 = add_exports(Exports, {tag, current(tag, M)}, M),
    case Import of
        {Mod, Name} -> add_import(Mod, Name, tag, R1, M1, Ctx);
        undefined ->
            {TypeIdx, _Params, _Rest} = typeuse(R1, Ctx),
            M1#module{tags = M1#module.tags ++ [#tagtype{type = TypeIdx}]}
    end;
build_kind(<<"elem">>, Args, M, Ctx) ->
    {_Name, Rest} = optional_id(Args),
    M#module{elems = M#module.elems ++ [elem_segment(Rest, Ctx)]};
build_kind(<<"data">>, Args, M, Ctx) ->
    {_Name, Rest} = optional_id(Args),
    M#module{datas = M#module.datas ++ [data_segment(Rest, Ctx)]}.

%%% --------------------------------------------------------- declarations ---

%% Everything but a segment is written the same way: a name, any number of
%% inline exports, and at most one inline import. Reading the three in one
%% place is what keeps `(memory $m (export "m") (import "a" "b") 1)' from
%% needing a clause per combination.
declaration(Args) ->
    {_Name, R0} = optional_id(Args),
    {Exports, R1} = inline_exports(R0),
    {Import, R2} = inline_import(R1),
    {R2, Exports, Import}.

inline_exports([{list, _, [{keyword, _, <<"export">>}, {string, _, N}]} | Rest]) ->
    {More, Rest1} = inline_exports(Rest),
    {[name(N) | More], Rest1};
inline_exports(Rest) ->
    {[], Rest}.

inline_import([{list, _, [{keyword, _, <<"import">>},
                          {string, _, Mod}, {string, _, Name}]} | Rest]) ->
    {{name(Mod), name(Name)}, Rest};
inline_import(Rest) ->
    {undefined, Rest}.

%% A string is bytes, but a *name* is text: the format requires valid UTF-8 and
%% the binary decoder enforces it, so a module written as text cannot be a way
%% around that.
name(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Bin -> Bin;
        _ -> fail(malformed_utf8, <<"malformed UTF-8 encoding">>)
    end.

import_desc({list, _, [{keyword, _, Kind} | Args]}) ->
    {_Name, Rest} = optional_id(Args),
    {space_of(Kind), Rest};
import_desc(Form) ->
    fail(unexpected_import_desc, Form).

add_import(Mod, Name, Space, Forms, M, Ctx) ->
    M#module{imports = M#module.imports ++
                 [#import{module = Mod, name = Name,
                          desc = extern_type(Space, Forms, Ctx)}]}.

extern_type(func, Forms, Ctx) ->
    {TypeIdx, _Params, _Rest} = typeuse(Forms, Ctx),
    {func, TypeIdx};
extern_type(tag, Forms, Ctx) ->
    {TypeIdx, _Params, _Rest} = typeuse(Forms, Ctx),
    {tag, #tagtype{type = TypeIdx}};
extern_type(table, Forms, Ctx) ->
    {table, tabletype(Forms, Ctx)};
extern_type(memory, Forms, Ctx) ->
    {mem, #memtype{limits = limits(Forms, Ctx)}};
extern_type(global, [Form], Ctx) ->
    {global, globaltype(Form, Ctx)}.

%%% ------------------------------------------------ memories and tables ---

%% `(memory (data "..."))' is a memory large enough to hold the string and an
%% active segment that fills it, which is two declarations in one pair of
%% parentheses.
memory_definition(Forms, M, Ctx) ->
    case index_type(Forms) of
        {IndexType, [{list, _, [{keyword, _, <<"data">>} | Strings]}]} ->
            inline_data(datastring(Strings), IndexType, M);
        _ ->
            M#module{mems = M#module.mems ++
                         [#memtype{limits = limits(Forms, Ctx)}]}
    end.

inline_data(Bytes, IndexType, M) ->
    Pages = (byte_size(Bytes) + ?PAGE_SIZE - 1) div ?PAGE_SIZE,
    Idx = current(memory, M),
    M1 = M#module{mems = M#module.mems ++
                      [#memtype{limits = #limits{min = Pages, max = Pages,
                                                 index_type = IndexType}}]},
    M1#module{datas = M1#module.datas ++
                  [#data{init = Bytes, mode = {active, Idx, zero(IndexType)}}]}.

%% `(table funcref (elem ...))' is the same abbreviation for tables.
table_definition(Forms, Idx, M, Ctx) ->
    case index_type(Forms) of
        {IndexType, [RT, {list, _, [{keyword, _, <<"elem">>} | Items]}]} ->
            inline_elem(RT, Items, IndexType, Idx, M, Ctx);
        _ ->
            M#module{tables = M#module.tables ++ [tabletype(Forms, Ctx)]}
    end.

inline_elem(RT, Items, IndexType, Idx, M, Ctx) ->
    ElemType = reftype_of(RT, Ctx),
    {Type, Init} = elem_list(Items, Ctx),
    Count = length(Init),
    M1 = M#module{tables = M#module.tables ++
                      [#tabletype{limits = #limits{min = Count, max = Count,
                                                   index_type = IndexType},
                                  elemtype = ElemType}]},
    M1#module{elems = M1#module.elems ++
                  [#elem{type = segment_type(Type, ElemType), init = Init,
                         mode = {active, Idx, zero(IndexType)}}]}.

%% The generated segment initialises this table, so it carries the table's own
%% element type. The short form written as function indices is only available
%% where that type is `funcref', which is the only one it can encode.
segment_type({ref, nonull, func}, ?FUNCREF) -> {ref, nonull, func};
segment_type({ref, nonull, func}, ElemType) -> ElemType;
segment_type(Type, _ElemType) -> Type.

%% An address in a memory or table declared `i64' is an `i64', including the
%% zero an abbreviation generates.
zero(i32) -> [{i32_const, 0}];
zero(i64) -> [{i64_const, 0}].

%% `<indextype>? <min> <max>? <reftype> <init>?'. The initialiser is what the
%% `0x40 0x00' encoding exists for: an element type with no null to default to.
tabletype(Forms, Ctx) ->
    {IndexType, F1} = index_type(Forms),
    {Bounds, F2} = take_indices(F1, 2),
    case F2 of
        [RT | Init] ->
            #tabletype{limits = table_limits(Bounds, IndexType),
                       elemtype = reftype_of(RT, Ctx),
                       init = table_init(Init, Ctx)};
        [] ->
            fail(unsupported_table_type, Forms)
    end.

table_limits([{keyword, _, Min}], IndexType) ->
    #limits{min = bound(Min, IndexType), index_type = IndexType};
table_limits([{keyword, _, Min}, {keyword, _, Max}], IndexType) ->
    #limits{min = bound(Min, IndexType), max = bound(Max, IndexType),
            index_type = IndexType};
table_limits(Bounds, _IndexType) ->
    fail(unsupported_limits, Bounds).

table_init([], _Ctx) -> undefined;
table_init(Forms, Ctx) -> expr(Forms, Ctx).

%%% --------------------------------------------------------------- segments ---

%% An element segment is passive, declarative, or active at some table. The
%% offset is written `(offset expr)' or as a single folded instruction, and the
%% two are told apart by the keyword rather than by guessing.
elem_segment([{keyword, _, <<"declare">>} | Rest], Ctx) ->
    {Type, Init} = elem_list(Rest, Ctx),
    #elem{type = Type, init = Init, mode = declarative};
elem_segment([{list, _, [{keyword, _, <<"table">>}, Idx]} | Rest], Ctx) ->
    {Offset, Rest1} = offset(Rest, Ctx),
    {Type, Init} = elem_list(Rest1, Ctx),
    #elem{type = Type, init = Init,
          mode = {active, index(Idx, table, Ctx), Offset}};
elem_segment(Forms, Ctx) ->
    case is_offset(Forms) of
        true ->
            {Offset, Rest} = offset(Forms, Ctx),
            {Type, Init} = elem_list(Rest, Ctx),
            #elem{type = Type, init = Init, mode = {active, 0, Offset}};
        false ->
            {Type, Init} = elem_list(Forms, Ctx),
            #elem{type = Type, init = Init, mode = passive}
    end.

data_segment([{list, _, [{keyword, _, <<"memory">>}, Idx]} | Rest], Ctx) ->
    {Offset, Strings} = offset(Rest, Ctx),
    #data{init = datastring(Strings),
          mode = {active, index(Idx, memory, Ctx), Offset}};
data_segment(Forms, Ctx) ->
    case is_offset(Forms) of
        true ->
            {Offset, Strings} = offset(Forms, Ctx),
            #data{init = datastring(Strings), mode = {active, 0, Offset}};
        false ->
            #data{init = datastring(Forms), mode = passive}
    end.

%% A segment's contents are strings, an element list, or `(item ...)' forms;
%% none of those begin with a folded instruction, so a list whose head is not
%% one of the segment's own keywords is the offset.
is_offset([{list, _, [{keyword, _, K} | _]} | _]) ->
    not lists:member(K, [<<"item">>, <<"ref">>]);
is_offset(_Forms) ->
    false.

offset([{list, _, [{keyword, _, <<"offset">>} | Expr]} | Rest], Ctx) ->
    {expr(Expr, Ctx), Rest};
offset([Folded | Rest], Ctx) ->
    {expr([Folded], Ctx), Rest};
offset([], _Ctx) ->
    fail(missing_offset, <<"offset">>).

%% Written as function indices the segment is a vector of them and its type is
%% the non-nullable `(ref func)'; written as expressions it is whatever type it
%% declares. The two are different encodings and so different segments, which
%% is why the abbreviation is kept rather than normalised away.
elem_list([{keyword, _, <<"func">>} | Funcs], Ctx) ->
    funcidx_list(Funcs, Ctx);
elem_list([{list, _, [{keyword, _, <<"ref">>} | _]} = RT | Items], Ctx) ->
    {reftype_of(RT, Ctx), [item(I, Ctx) || I <- Items]};
%% No declared type, so the elements are expressions of the default `funcref'.
elem_list([{list, _, _} | _] = Items, Ctx) ->
    {?FUNCREF, [item(I, Ctx) || I <- Items]};
elem_list([{keyword, _, K} = First | Items] = Forms, Ctx) ->
    case is_reftype_keyword(K) of
        true -> {reftype_of(First, Ctx), [item(I, Ctx) || I <- Items]}; false -> funcidx_list(Forms, Ctx)
    end;
elem_list(Forms, Ctx) ->
    funcidx_list(Forms, Ctx).

funcidx_list(Forms, Ctx) ->
    {{ref, nonull, func}, [[{ref_func, index(F, func, Ctx)}] || F <- Forms]}.

is_reftype_keyword(K) ->
    lists:member(K, [<<"funcref">>, <<"externref">>, <<"exnref">>, <<"anyref">>,
                     <<"eqref">>, <<"i31ref">>, <<"structref">>, <<"arrayref">>,
                     <<"nullref">>, <<"nullfuncref">>, <<"nullexternref">>,
                     <<"nullexnref">>]).

item({list, _, [{keyword, _, <<"item">>} | Expr]}, Ctx) -> expr(Expr, Ctx);
item(Form, Ctx) -> expr([Form], Ctx).

%% A data segment's contents are any number of strings, concatenated.
datastring(Forms) ->
    iolist_to_binary([S || {string, _, S} <- Forms]).

%%% ------------------------------------------------------------ bookkeeping ---

%% The index the next definition of a space will have. Imports occupy the low
%% indices, and the format requires them to be written first, so counting both
%% in the order they arrive is enough.
current(Space, M) -> imported(Space, M) + defined(Space, M).

imported(Space, #module{imports = Imports}) ->
    Tag = desc_tag(Space),
    length([1 || #import{desc = Desc} <- Imports, element(1, Desc) =:= Tag]).

defined(func, M) -> length(M#module.funcs);
defined(table, M) -> length(M#module.tables);
defined(memory, M) -> length(M#module.mems);
defined(global, M) -> length(M#module.globals);
defined(tag, M) -> length(M#module.tags).

add_exports([], _Desc, M) -> M;
add_exports([Name | Rest], Desc, M) ->
    add_exports(Rest, Desc,
                M#module{exports = M#module.exports ++
                             [#export{name = Name, desc = Desc}]}).

export_desc({list, _, [{keyword, _, Kind}, Idx]}, Ctx) ->
    Space = space_of(Kind),
    {desc_tag(Space), index(Idx, Space, Ctx)}.

desc_tag(memory) -> mem;
desc_tag(Space) -> Space.

%%% ----------------------------------------------------------------- types ---

subtype({list, _, [{keyword, _, <<"func">>} | Args]}, Ctx) ->
    #subtype{body = functype(Args, Ctx)};
subtype({list, _, [{keyword, _, <<"struct">>} | Args]}, Ctx) ->
    #subtype{body = #structtype{fields = fields(Args, Ctx)}};
subtype({list, _, [{keyword, _, <<"array">>} | Args]}, Ctx) ->
    [Field] = fields([{list, 0, [{keyword, 0, <<"field">>} | Args]}], Ctx),
    #subtype{body = #arraytype{field = Field}};
%% `(sub final? $super* body)'. `final' is a promise that nothing extends this
%% type, so it is part of the declaration rather than a hint.
subtype({list, _, [{keyword, _, <<"sub">>} | Args]}, Ctx) ->
    {Final, Rest} = case Args of
                        [{keyword, _, <<"final">>} | R] -> {true, R};
                        _ -> {false, Args}
                    end,
    {Supers, [Body]} = lists:splitwith(fun({list, _, _}) -> false;
                                          (_) -> true
                                       end, Rest),
    Inner = subtype(Body, Ctx),
    Inner#subtype{final = Final,
                  supers = [index(S, type, Ctx) || S <- Supers]};
subtype([{list, _, _} = Form], Ctx) ->
    subtype(Form, Ctx);
subtype(Form, _Ctx) ->
    fail(unsupported_type_form, Form).

%% `(field $name t)' and `(field t t t)' are both allowed, and a bare type is
%% shorthand for a field of it.
fields(Forms, Ctx) -> lists:flatmap(fun(F) -> field(F, Ctx) end, Forms).

field({list, _, [{keyword, _, <<"field">>} | Args]}, Ctx) ->
    [fieldtype(F, Ctx) || F <- skip_id_forms(Args)];
field(Form, Ctx) ->
    [fieldtype(Form, Ctx)].

fieldtype({list, _, [{keyword, _, <<"mut">>}, T]}, Ctx) ->
    #fieldtype{type = storagetype(T, Ctx), mut = var};
fieldtype(T, Ctx) ->
    #fieldtype{type = storagetype(T, Ctx), mut = const}.

%% A field may be narrower than any value type, which is why `struct.get' comes
%% in signed and unsigned forms.
storagetype({keyword, _, <<"i8">>}, _Ctx) -> i8;
storagetype({keyword, _, <<"i16">>}, _Ctx) -> i16;
storagetype(T, Ctx) -> valtype(T, Ctx).

%% Parameters come before results, so a `(param ...)' after a `(result ...)' is
%% left over rather than added, and saying so is the difference between
%% refusing that and silently declaring a different type.
functype(Args, Ctx) ->
    {Params, Rest} = params(Args, Ctx, []),
    case results(Rest, Ctx, []) of
        {Results, []} -> #functype{params = Params, results = Results};
        {_Results, [Form | _]} -> fail(unexpected_token, Form)
    end.

params([{list, _, [{keyword, _, <<"param">>} | Rest]} | More], Ctx, Acc) ->
    params(More, Ctx, Acc ++ valtypes(skip_id_forms(Rest), Ctx));
params(Rest, _Ctx, Acc) ->
    {Acc, Rest}.

%%% -------------------------------------------------------------- type uses ---

%% `(type $t)? (param ...)* (result ...)*'. The answer carries the parameters
%% with their names, because a parameter is also a local and may be referred to
%% by name from the body.
typeuse(Forms, Ctx) -> typeuse(Forms, Ctx, named).

%% Only a function may name its parameters. A block or a `call_indirect' takes
%% a signature and nothing that could refer to one of its parameters, so a name
%% there would bind nothing.
typeuse(Forms, Ctx, Naming) ->
    {Explicit, F1} = explicit_type(Forms, Ctx),
    {Params, F2} = params_of(Naming, F1, Ctx),
    {Results, F3} = results(F2, Ctx, []),
    case {Explicit, Params, Results} of
        {undefined, _, _} ->
            {find_type(signature(Params, Results), Ctx), Params, F3};
        %% `(type $t)' alone still has to say how many locals the parameters
        %% take up, so the count comes from the type it names.
        {N, [], []} ->
            {N, [{undefined, T} || T <- declared_params(N, Ctx)], F3}; %% Written both ways, the two have to agree. They are one declaration,
        %% not a type and a separate claim about it.
        {N, _, _} ->
            ok = same_signature(N, signature(Params, Results), Ctx),
            {N, Params, F3}
    end.

params_of(named, Forms, Ctx) -> named_params(Forms, Ctx, []);
params_of(anonymous, Forms, Ctx) -> anonymous_params(Forms, Ctx, []).

anonymous_params([{list, _, [{keyword, _, <<"param">>}, {id, _, Name} | _]} | _],
                 _Ctx, _Acc) ->
    fail(unexpected_token, Name);
anonymous_params([{list, _, [{keyword, _, <<"param">>} | Rest]} | More], Ctx, Acc) ->
    anonymous_params(More, Ctx, Acc ++ named_entries(Rest, Ctx));
anonymous_params(Rest, _Ctx, Acc) ->
    {Acc, Rest}.

same_signature(N, Signature, #ctx{types = Types}) when N < length(Types) ->
    case lists:nth(N + 1, Types) of
        #subtype{body = Signature} -> ok;
        _ -> fail(inline_function_type, N)
    end;
%% Written both ways, the index has to name a type for the two to be compared.
%% `(func (type 2))' alone carries the index into the module and validation
%% refuses it there, but there is nothing to check an inline signature against.
same_signature(N, _Signature, _Ctx) ->
    fail(unknown_type, N).

explicit_type([{list, _, [{keyword, _, <<"type">>}, Idx]} | Rest], Ctx) ->
    {index(Idx, type, Ctx), Rest};
explicit_type(Forms, _Ctx) ->
    {undefined, Forms}.

%% A type index naming no type is *invalid*, not malformed, so it travels into
%% the module and validation rejects it there. The parameters it would have
%% declared are unknown, which only matters for numbering locals a body that
%% will never be validated might declare.
declared_params(N, #ctx{types = Types}) when N < length(Types) ->
    case lists:nth(N + 1, Types) of
        #subtype{body = #functype{params = Params}} -> Params;
        _ -> []
    end;
declared_params(_N, _Ctx) ->
    [].

%% `(param $x i32)' names one parameter; `(param i32 i64)' names none. The two
%% forms cannot be mixed inside a single `(param ...)', which is what makes the
%% name unambiguous.
named_params([{list, _, [{keyword, _, <<"param">>} | Rest]} | More], Ctx, Acc) ->
    named_params(More, Ctx, Acc ++ named_entries(Rest, Ctx));
named_params(Rest, _Ctx, Acc) ->
    {Acc, Rest}.

locals([{list, _, [{keyword, _, <<"local">>} | Rest]} | More], Ctx, Acc) ->
    locals(More, Ctx, Acc ++ named_entries(Rest, Ctx));
locals(Rest, _Ctx, Acc) ->
    {Acc, Rest}.

%% Skips over the locals without reading them, for the pass that is only
%% looking for type uses and would otherwise treat `(local i32)' as one.
skip_locals([{list, _, [{keyword, _, <<"local">>} | _]} | Rest]) ->
    skip_locals(Rest);
skip_locals(Forms) ->
    Forms.

named_entries([{id, _, Name}, T], Ctx) ->
    [{Name, valtype(T, Ctx)}];
named_entries(Forms, Ctx) ->
    [{undefined, valtype(F, Ctx)} || F <- Forms].

%% Parameters and locals share one index space, in that order.
with_locals(Entries, Ctx) ->
    Named = element(2, lists:foldl(
                          fun({undefined, _}, {I, Acc}) -> {I + 1, Acc};
                             ({Name, _}, {I, Acc}) ->
                                  case maps:is_key(Name, Acc) of
                                      true -> fail(duplicate_identifier, Name);
                                      false -> {I + 1, Acc#{Name => I}}
                                  end
                          end, {0, #{}}, Entries)),
    Ctx#ctx{names = (Ctx#ctx.names)#{local => Named}, labels = []}.

find_type(FT, Ctx) ->
    case type_index(FT, Ctx) of
        {ok, I} -> I;
        %% The pass that collects implicit types walks every type use there is,
        %% so a use arriving here unmatched means the two passes disagree about
        %% where type uses live. Failing says so rather than inventing an index.
        error -> fail(unresolved_type, FT)
    end.

results([{list, _, [{keyword, _, <<"result">>} | Rest]} | More], Ctx, Acc) ->
    results(More, Ctx, Acc ++ valtypes(Rest, Ctx));
results(Rest, _Ctx, Acc) ->
    {Acc, Rest}.

skip_id_forms([{id, _, _} | Rest]) -> Rest;
skip_id_forms(Forms) -> Forms.

valtypes(Forms, Ctx) -> [valtype(F, Ctx) || F <- Forms].

valtype({keyword, _, <<"i32">>}, _Ctx) -> i32;
valtype({keyword, _, <<"i64">>}, _Ctx) -> i64;
valtype({keyword, _, <<"f32">>}, _Ctx) -> f32;
valtype({keyword, _, <<"f64">>}, _Ctx) -> f64;
valtype({keyword, _, <<"v128">>}, _Ctx) -> v128;
valtype({keyword, _, <<"funcref">>}, _Ctx) -> ?FUNCREF;
valtype({keyword, _, <<"externref">>}, _Ctx) -> ?EXTERNREF;
valtype({keyword, _, <<"exnref">>}, _Ctx) -> ?EXNREF;
valtype({keyword, _, <<"anyref">>}, _Ctx) -> {ref, null, any};
valtype({keyword, _, <<"eqref">>}, _Ctx) -> {ref, null, eq};
valtype({keyword, _, <<"i31ref">>}, _Ctx) -> {ref, null, i31};
valtype({keyword, _, <<"structref">>}, _Ctx) -> {ref, null, struct};
valtype({keyword, _, <<"arrayref">>}, _Ctx) -> {ref, null, array};
valtype({keyword, _, <<"nullref">>}, _Ctx) -> {ref, null, none};
valtype({keyword, _, <<"nullfuncref">>}, _Ctx) -> {ref, null, nofunc};
valtype({keyword, _, <<"nullexternref">>}, _Ctx) -> {ref, null, noextern};
valtype({keyword, _, <<"nullexnref">>}, _Ctx) -> {ref, null, noexn};
valtype({list, _, [{keyword, _, <<"ref">>} | Rest]}, Ctx) ->
    reftype(Rest, Ctx);
valtype(Form, _Ctx) ->
    fail(unknown_valtype, Form).

reftype([{keyword, _, <<"null">>} | Rest], Ctx) ->
    {ref, null, heaptype(Rest, Ctx)};
reftype(Rest, Ctx) ->
    {ref, nonull, heaptype(Rest, Ctx)}.

heaptype([{keyword, _, K}], _Ctx) when K =:= <<"func">>; K =:= <<"extern">>;
                                       K =:= <<"any">>; K =:= <<"eq">>;
                                       K =:= <<"i31">>; K =:= <<"struct">>;
                                       K =:= <<"array">>; K =:= <<"exn">>;
                                       K =:= <<"none">>; K =:= <<"nofunc">>;
                                       K =:= <<"noextern">>; K =:= <<"noexn">> ->
    binary_to_existing_atom(K, utf8);
heaptype([Idx], Ctx) ->
    {type, index(Idx, type, Ctx)};
heaptype(Forms, _Ctx) ->
    fail(unknown_heaptype, Forms).

globaltype({list, _, [{keyword, _, <<"mut">>}, T]}, Ctx) ->
    #globaltype{valtype = valtype(T, Ctx), mut = var};
globaltype(T, Ctx) ->
    #globaltype{valtype = valtype(T, Ctx), mut = const}.

limits(Forms, _Ctx) ->
    {IndexType, F1} = index_type(Forms),
    {Shared, Rest} = shared_flag(F1),
    case Rest of
        [{keyword, _, Min}] ->
            #limits{min = bound(Min, IndexType), shared = Shared,
                    index_type = IndexType};
        [{keyword, _, Min}, {keyword, _, Max} | _] ->
            #limits{min = bound(Min, IndexType), max = bound(Max, IndexType),
                    shared = Shared, index_type = IndexType};
        _ -> fail(unsupported_limits, Forms)
    end.

%% A memory or table addressed by i64 says so before its limits, and its bounds
%% are then 64-bit numbers rather than 32-bit ones.
index_type([{keyword, _, <<"i64">>} | Rest]) -> {i64, Rest};
index_type([{keyword, _, <<"i32">>} | Rest]) -> {i32, Rest};
index_type(Forms) -> {i32, Forms}.

%% Read at 64 bits whatever the index type, because a bound too large for the
%% memory it describes is *invalid* rather than malformed: `(memory
%% 0x1_0000_0000)' has to reach validation to be told it is too many pages.
bound(Bin, _IndexType) -> u64(Bin).

u64(Bin) ->
    case wasm_wat_num:integer(Bin, u64) of
        {ok, V} when V >= 0 -> V;
        {ok, V} -> V band 16#FFFFFFFFFFFFFFFF;
        error -> fail(malformed_integer, Bin)
    end.

%% `shared` follows the limits, so it is stripped from the end.
shared_flag(Forms) ->
    case lists:reverse(Forms) of
        [{keyword, _, <<"shared">>} | Rev] -> {true, lists:reverse(Rev)};
        _ -> {false, Forms}
    end.

u32(Bin) ->
    case wasm_wat_num:integer(Bin, u32) of
        {ok, V} when V >= 0 -> V;
        {ok, V} -> V band 16#FFFFFFFF;
        error -> fail(malformed_integer, Bin)
    end.

%%% ----------------------------------------------------------- expressions ---

%% A constant expression is a fold of instructions, so it goes through the same
%% instruction parser everything else does. No terminator: the binary decoder
%% drops the `end` opcode, and a front end that kept it would produce a module
%% that is equal to nothing the rest of the runtime makes.
expr(Forms, Ctx) -> seq_all(Forms, Ctx).

%%% --------------------------------------------------------- instructions ---

%% The format writes the same instructions two ways. Flat, they are a stream
%% ending at `end'; folded, an instruction and its operands share a pair of
%% parentheses, operands first. Both are parsed here rather than by rewriting
%% one into the other, because a block is folded and flat at once: `(block ...)'
%% has no `end' but its body may contain flat blocks that do.
seq_all(Forms, Ctx) ->
    case seq(Forms, Ctx) of
        {Instrs, []} -> Instrs;
        {_, [Form | _]} -> fail(unexpected_instruction, Form)
    end.

%% Stops at `end' and `else' without consuming them: whoever opened the block
%% is the one that knows which of the two it is expecting.
seq([], _Ctx) ->
    {[], []};
seq([{keyword, _, K} | _] = Forms, _Ctx) when K =:= <<"end">>; K =:= <<"else">> ->
    {[], Forms};
seq(Forms, Ctx) ->
    {Instrs, Rest} = one(Forms, Ctx),
    {More, Rest1} = seq(Rest, Ctx),
    {Instrs ++ More, Rest1}.

one([{keyword, _, K} | _], _Ctx) when ?DECLARATION(K) ->
    fail(unexpected_token, K);
one([{list, _, [{keyword, _, K} | _]} | _], _Ctx) when ?DECLARATION(K) ->
    fail(unexpected_token, K);
one([{keyword, _, <<"block">>} | Rest], Ctx) -> flat_block(block, Rest, Ctx);
one([{keyword, _, <<"loop">>} | Rest], Ctx) -> flat_block(loop, Rest, Ctx);
one([{keyword, _, <<"if">>} | Rest], Ctx) -> flat_if(Rest, Ctx);
one([{keyword, _, <<"try_table">>} | Rest], Ctx) -> flat_try(Rest, Ctx);
one([{keyword, _, Name} | Rest], Ctx) ->
    {Instr, Rest1} = immediate(Name, Rest, Ctx),
    {[Instr], Rest1};
one([{list, _, [{keyword, _, <<"block">>} | Args]} | Rest], Ctx) ->
    {[folded_block(block, Args, Ctx)], Rest};
one([{list, _, [{keyword, _, <<"loop">>} | Args]} | Rest], Ctx) ->
    {[folded_block(loop, Args, Ctx)], Rest};
one([{list, _, [{keyword, _, <<"if">>} | Args]} | Rest], Ctx) ->
    {folded_if(Args, Ctx), Rest};
one([{list, _, [{keyword, _, <<"try_table">>} | Args]} | Rest], Ctx) ->
    {[folded_try(Args, Ctx)], Rest};
one([{list, _, [{keyword, _, Name} | Args]} | Rest], Ctx) ->
    {Instr, Args1} = immediate(Name, Args, Ctx),
    {seq_all(Args1, Ctx) ++ [Instr], Rest};
one([Form | _], _Ctx) ->
    fail(unexpected_instruction, Form).

%%% ---------------------------------------------------------------- blocks ---

flat_block(Kind, Forms, Ctx) ->
    {Label, F1} = optional_id(Forms),
    {BT, F2} = blocktype(F1, Ctx),
    {Body, F3} = seq(F2, push_label(Label, Ctx)),
    {[{Kind, BT, Body}], expect_end(F3, Label)}.

folded_block(Kind, Args, Ctx) ->
    {Label, A1} = optional_id(Args),
    {BT, A2} = blocktype(A1, Ctx),
    {Kind, BT, seq_all(A2, push_label(Label, Ctx))}.

flat_if(Forms, Ctx) ->
    {Label, F1} = optional_id(Forms),
    {BT, F2} = blocktype(F1, Ctx),
    Inner = push_label(Label, Ctx),
    {Then, F3} = seq(F2, Inner),
    {Else, F4} = case F3 of
                     [{keyword, _, <<"else">>} | F] ->
                         seq(matching_label(F, Label), Inner);
                     _ -> {[], F3}
                 end,
    {[{if_, BT, Then, Else}], expect_end(F4, Label)}.

%% Folded, the condition comes before `(then ...)' and is *outside* the block,
%% so it is parsed against the enclosing labels rather than the block's own.
folded_if(Args, Ctx) ->
    {Label, A1} = optional_id(Args),
    {BT, A2} = blocktype(A1, Ctx),
    {CondForms, A3} = lists:splitwith(fun(F) -> not is_head(F, <<"then">>) end, A2),
    %% The condition of a folded `if' is itself folded. A bare instruction here
    %% is the flat form wearing the folded form's parentheses.
    [fail(unexpected_token, F) || F <- CondForms, not is_list_form(F)],
    Inner = push_label(Label, Ctx),
    {Then, Else} =
        case A3 of
            [{list, _, [_ | ThenItems]}] ->
                {seq_all(ThenItems, Inner), []};
            [{list, _, [_ | ThenItems]}, {list, _, [{keyword, _, <<"else">>} | E]}] ->
                {seq_all(ThenItems, Inner), seq_all(E, Inner)};
            _ ->
                fail(missing_then, {list, 0, A2})
        end,
    seq_all(CondForms, Ctx) ++ [{if_, BT, Then, Else}].

flat_try(Forms, Ctx) ->
    {Label, F1} = optional_id(Forms),
    {BT, F2} = blocktype(F1, Ctx),
    {Catches, F3} = catches(F2, Ctx, []),
    {Body, F4} = seq(F3, push_label(Label, Ctx)),
    {[{try_table, BT, Catches, Body}], expect_end(F4, Label)}.

folded_try(Args, Ctx) ->
    {Label, A1} = optional_id(Args),
    {BT, A2} = blocktype(A1, Ctx),
    {Catches, A3} = catches(A2, Ctx, []),
    {try_table, BT, Catches, seq_all(A3, push_label(Label, Ctx))}.

%% A handler's label is resolved outside the block, because branching out of a
%% `try_table' is what a handler does.
catches([{list, _, [{keyword, _, K} | Args]} | Rest], Ctx, Acc)
  when K =:= <<"catch">>; K =:= <<"catch_ref">>;
       K =:= <<"catch_all">>; K =:= <<"catch_all_ref">> ->
    catches(Rest, Ctx, [catch_clause(K, Args, Ctx) | Acc]);
catches(Forms, _Ctx, Acc) ->
    {lists:reverse(Acc), Forms}.

catch_clause(<<"catch">>, [Tag, Label], Ctx) ->
    {catch_, index(Tag, tag, Ctx), index(Label, label, Ctx)};
catch_clause(<<"catch_ref">>, [Tag, Label], Ctx) ->
    {catch_ref, index(Tag, tag, Ctx), index(Label, label, Ctx)};
catch_clause(<<"catch_all">>, [Label], Ctx) ->
    {catch_all, undefined, index(Label, label, Ctx)};
catch_clause(<<"catch_all_ref">>, [Label], Ctx) ->
    {catch_all_ref, undefined, index(Label, label, Ctx)};
catch_clause(K, Args, _Ctx) ->
    fail(malformed_catch_clause, {K, length(Args)}).

expect_end([{keyword, _, <<"end">>} | Rest], Label) ->
    matching_label(Rest, Label);
expect_end([Form | _], _Label) ->
    fail(missing_end, Form);
expect_end([], _Label) ->
    fail(missing_end, <<"end">>).

%% `end $l' and `else $l' have to name the label the block opened with, or
%% nothing. A block with no name cannot be closed by one.
matching_label([{id, _, Name} | Rest], Name) -> Rest;
matching_label([{id, _, Name} | _], _Label) -> fail(mismatching_label, Name);
matching_label(Forms, _Label) -> Forms.

%% A block occupies a label slot whether or not it is named, because `br 1'
%% counts blocks rather than names.
push_label(Label, #ctx{labels = Labels} = Ctx) ->
    Ctx#ctx{labels = [Label | Labels]}.

is_head({list, _, [{keyword, _, K} | _]}, K) -> true;
is_head(_, _) -> false.

is_list_form({list, _, _}) -> true;
is_list_form(_Form) -> false.

blocktype(Forms, Ctx) ->
    {Explicit, F1} = explicit_type(Forms, Ctx),
    {Params, F2} = anonymous_params(F1, Ctx, []),
    {Results, F3} = results(F2, Ctx, []),
    BT = case {Explicit, Params, Results} of
             {undefined, [], []} -> empty;
             {undefined, [], [T]} -> {valtype, T};
             {undefined, _, _} -> {typeidx, find_type(signature(Params, Results), Ctx)};
             {N, [], []} -> {typeidx, N};
             {N, _, _} ->
                 ok = same_signature(N, signature(Params, Results), Ctx),
                 {typeidx, N}
         end,
    {BT, F3}.

%%% ------------------------------------------------------------ immediates ---

immediate(Name, Args, Ctx) ->
    case wasm_wat_instr:immediate(Name) of
        plain -> {known(Name), Args};
        {const, T} -> const(Name, T, Args);
        {idx, Space} -> one_index(Name, Space, Args, Ctx);
        {idx_opt, Space} -> opt_index(Name, Space, Args, Ctx);
        {idx2, A, B} -> two_indices(Name, A, B, Args, Ctx);
        {copy2, Space} -> copy2(Name, Space, Args, Ctx);
        {init2, Space, Seg} -> init2(Name, Space, Seg, Args, Ctx);
        {memarg, Natural} -> memarg(Name, Natural, Args, Ctx);
        {memarg_lane, Natural, _} -> memarg_lane(Name, Natural, Args, Ctx);
        {lane, _} -> lane(Name, Args);
        call_indirect -> call_indirect(Name, Args, Ctx);
        br_table -> br_table(Name, Args, Ctx);
        select -> select(Name, Args, Ctx);
        heaptype -> ref_null(Name, Args, Ctx);
        reftype -> one_reftype(Name, Args, Ctx);
        br_on_cast -> br_on_cast(Name, Args, Ctx);
        shuffle -> shuffle(Name, Args);
        v128const -> v128_const(Name, Args)
    end.

const(Name, T, [{keyword, _, Lit} | Rest]) when T =:= i32; T =:= i64 ->
    case wasm_wat_num:integer(Lit, T) of
        {ok, V} -> {{known(Name), V}, Rest};
        error -> fail(malformed_integer, Lit)
    end;
const(Name, T, [{keyword, _, Lit} | Rest]) ->
    Width = case T of f32 -> 32; f64 -> 64 end,
    case wasm_wat_num:float_bits(Lit, Width) of
        {ok, Bits} -> {{known(Name), from_bits(Width, Bits)}, Rest};
        error -> fail(malformed_float, Lit)
    end;
const(Name, _T, Args) ->
    fail(missing_literal, {Name, Args}).

from_bits(32, Bits) -> wasm_num:f32_from_bits(Bits);
from_bits(64, Bits) -> wasm_num:f64_from_bits(Bits).

one_index(Name, Space, [Form | Rest], Ctx) ->
    {{known(Name), index(Form, Space, Ctx)}, Rest};
one_index(Name, _Space, [], _Ctx) ->
    fail(missing_index, Name).

opt_index(Name, Space, Args, Ctx) ->
    case take_indices(Args, 1) of
        {[Form], Rest} -> {{known(Name), index(Form, Space, Ctx)}, Rest};
        {[], Rest} -> {{known(Name), 0}, Rest}
    end.

%% A field index is read against the type the same instruction names, so the
%% two are resolved in order rather than independently.
two_indices(Name, type, field, [A, B | Rest], Ctx) ->
    Type = index(A, type, Ctx),
    {{known(Name), Type, field_index(B, Type, Ctx)}, Rest};
two_indices(Name, SpaceA, SpaceB, [A, B | Rest], Ctx) ->
    {{known(Name), index(A, SpaceA, Ctx), index(B, SpaceB, Ctx)}, Rest};
two_indices(Name, _A, _B, _Args, _Ctx) ->
    fail(missing_index, Name).

%% `memory.copy' and `table.copy' name a destination and a source, and either
%% both are written or neither is.
copy2(Name, Space, Args, Ctx) ->
    case take_indices(Args, 2) of
        {[Dst, Src], Rest} ->
            {{known(Name), index(Dst, Space, Ctx), index(Src, Space, Ctx)}, Rest};
        {[], Rest} ->
            {{known(Name), 0, 0}, Rest};
        _ ->
            fail(missing_index, Name)
    end.

%% `memory.init' and `table.init' are written with the memory or table first
%% and the segment second, and encoded the other way round.
init2(Name, Space, Seg, Args, Ctx) ->
    case take_indices(Args, 2) of
        {[A, B], Rest} ->
            {{known(Name), index(B, Seg, Ctx), index(A, Space, Ctx)}, Rest};
        {[A], Rest} ->
            {{known(Name), index(A, Seg, Ctx), 0}, Rest};
        {[], _Rest} ->
            fail(missing_index, Name)
    end.

%% `call_indirect <table>? <typeuse>'. The table is unambiguous because a type
%% use always begins with a parenthesis.
call_indirect(Name, Args, Ctx) ->
    {Table, A1} = case take_indices(Args, 1) of
                      {[Form], R} -> {index(Form, table, Ctx), R};
                      {[], R} -> {0, R}
                  end,
    {TypeIdx, _Params, A2} = typeuse(A1, Ctx, anonymous),
    {{known(Name), TypeIdx, Table}, A2}.

%% `br_table' takes a vector of labels and a default, written as one run with
%% the default last.
br_table(Name, Args, Ctx) ->
    case take_indices(Args, all) of
        {[], _} ->
            fail(missing_index, Name);
        {Forms, Rest} ->
            {Labels, [Default]} = lists:split(length(Forms) - 1, Forms),
            {{br_table, [index(L, label, Ctx) || L <- Labels], index(Default, label, Ctx)}, Rest}
    end.

%% A bare `select' takes its type from the operands; one with a result type is
%% the only form that works on references.
select(_Name, Args, Ctx) ->
    case results(Args, Ctx, []) of
        {[], Rest} -> {{select, undefined}, Rest};
        {Results, Rest} -> {{select, Results}, Rest}
    end.

ref_null(_Name, [Form | Rest], Ctx) ->
    {{ref_null, {ref, null, heaptype([Form], Ctx)}}, Rest};
ref_null(Name, [], _Ctx) ->
    fail(missing_heaptype, Name).

one_reftype(Name, [Form | Rest], Ctx) ->
    {{known(Name), reftype_of(Form, Ctx)}, Rest};
one_reftype(Name, [], _Ctx) ->
    fail(missing_reftype, Name).

br_on_cast(Name, [Label, From, To | Rest], Ctx) ->
    {{known(Name), index(Label, label, Ctx),
      reftype_of(From, Ctx), reftype_of(To, Ctx)}, Rest};
br_on_cast(Name, _Args, _Ctx) ->
    fail(missing_reftype, Name).

reftype_of(Form, Ctx) ->
    case valtype(Form, Ctx) of
        {ref, _, _} = RT -> RT;
        Other -> fail(not_a_reference_type, Other)
    end.

%%% ------------------------------------------------------- memory arguments ---

%% `<memidx>? offset=<u64>? align=<power of two>?'. A missing alignment means
%% the natural one, which is why the parser has to know the access width: the
%% number the validator checks is the one written here.
memarg(Name, Natural, Args, Ctx) ->
    {MemArg, Rest} = mem_arg(Natural, Args, Ctx),
    {{known(Name), MemArg}, Rest}.

%% `<memidx>? offset=? align=? <laneidx>'. Both indices are bare numbers with
%% nothing between them when the memory argument is left out, so which one a
%% single number is depends on whether another follows: the lane is mandatory
%% and last, the memory optional and first.
memarg_lane(Name, Natural, Args, Ctx) ->
    {Leading, A1} = take_indices(Args, 2),
    {Offset, A2} = tagged_number(<<"offset=">>, A1, u64),
    {Align, A3} = tagged_number(<<"align=">>, A2, u32),
    {Trailing, A4} = take_indices(A3, 1),
    {MemForm, LaneForm} = split_lane(Leading, Trailing, Name),
    Mem = case MemForm of
              [Form] -> index(Form, memory, Ctx);
              [] -> 0
          end,
    MemArg = {align_log2(Align, Natural), default(Offset, 0), Mem},
    {{known(Name), MemArg, integer_lane_of(LaneForm)}, A4}.

split_lane([], [Lane], _Name) -> {[], Lane};
split_lane([Mem], [Lane], _Name) -> {[Mem], Lane};
split_lane([Mem, Lane], [], _Name) -> {[Mem], Lane};
split_lane([Lane], [], _Name) -> {[], Lane};
split_lane(_Leading, _Trailing, Name) -> fail(missing_lane, Name).

mem_arg(Natural, Args, Ctx) ->
    {Mem, A1} = case take_indices(Args, 1) of
                    {[Form], R} -> {index(Form, memory, Ctx), R};
                    {[], R} -> {0, R}
                end,
    {Offset, A2} = tagged_number(<<"offset=">>, A1, u64),
    {Align, A3} = tagged_number(<<"align=">>, A2, u64),
    {{align_log2(Align, Natural), default(Offset, 0), Mem}, A3}.

tagged_number(Tag, [{keyword, _, K} | Rest] = Forms, Kind) ->
    Size = byte_size(Tag),
    case K of
        <<Tag:Size/binary, Value/binary>> ->
            case wasm_wat_num:integer(Value, Kind) of
                {ok, V} -> {unsigned(V, Kind), Rest};
                error -> fail(malformed_integer, Value)
            end;
        _ -> {undefined, Forms}
    end;
tagged_number(_Tag, Forms, _Kind) ->
    {undefined, Forms}.

%% `wasm_wat_num' answers with the signed reading of the bits, and an offset is
%% a magnitude.
unsigned(V, _Kind) when V >= 0 -> V;
unsigned(V, u32) -> V band 16#FFFFFFFF;
unsigned(V, u64) -> V band 16#FFFFFFFFFFFFFFFF.

default(undefined, D) -> D;
default(V, _D) -> V.

%% Alignment is written in bytes and encoded as its logarithm, so a value that
%% is not a power of two has no encoding at all. One that is a power of two but
%% wider than the access does: it is invalid, and saying so is validation's job.
align_log2(undefined, Natural) -> Natural;
align_log2(Bytes, _Natural) when Bytes > 0, Bytes band (Bytes - 1) =:= 0 ->
    log2_exact(Bytes, 0);
align_log2(Bytes, _Natural) ->
    fail(alignment_not_a_power_of_two, integer_to_binary(Bytes)).

log2_exact(1, Acc) -> Acc;
log2_exact(N, Acc) -> log2_exact(N bsr 1, Acc + 1).

lane(Name, [{keyword, _, _} = Form | Rest]) ->
    {{known(Name), integer_lane_of(Form)}, Rest};
lane(Name, _Args) ->
    fail(missing_lane, Name).

%%% ------------------------------------------------------------ vector data ---

%% Sixteen lane indices, encoded as the sixteen bytes the binary format holds.
shuffle(Name, Args) ->
    {Lanes, Rest} = lists:split(16, enough(Args, 16, Name)),
    {{known(Name), << <<(integer_lane_of(L)):8>> || L <- Lanes >>}, Rest}.

%% A lane index is an unsigned byte, so it carries no sign and one that does
%% not fit has no encoding at all. Naming a lane the vector does not have is a
%% different thing, invalid rather than malformed, and left to validation.
integer_lane_of({keyword, _, <<Sign, _/binary>> = Lit}) when Sign =:= $+;
                                                            Sign =:= $- ->
    fail(unexpected_token, Lit);
integer_lane_of({keyword, _, Lit}) ->
    case u32(Lit) of
        Lane when Lane =< 255 -> Lane;
        _ -> fail(constant_out_of_range, Lit)
    end;
integer_lane_of(Form) ->
    fail(unexpected_lane, Form).

enough(Args, N, _Name) when length(Args) >= N -> Args;
enough(_Args, _N, Name) -> fail(missing_lane, Name).

%% `v128.const' writes its lanes in the shape it names and the binary format
%% holds sixteen bytes, so the shape decides how many literals to read and how
%% wide each one is.
v128_const(Name, [{keyword, _, Shape} | Rest]) ->
    {Count, Bits} = vector_shape(Shape),
    {Lits, Rest1} = lists:split(Count, enough(Rest, Count, Name)),
    {{known(Name), << <<(lane_bits(L, Shape, Bits)):Bits/little>> || L <- Lits >>},
     Rest1};
v128_const(Name, _Args) ->
    fail(missing_shape, Name).

vector_shape(<<"i8x16">>) -> {16, 8};
vector_shape(<<"i16x8">>) -> {8, 16};
vector_shape(<<"i32x4">>) -> {4, 32};
vector_shape(<<"i64x2">>) -> {2, 64};
vector_shape(<<"f32x4">>) -> {4, 32};
vector_shape(<<"f64x2">>) -> {2, 64};
vector_shape(Shape) -> fail(unknown_vector_shape, Shape).

lane_bits({keyword, _, Lit}, <<"f32x4">>, _Bits) -> float_lane(Lit, 32);
lane_bits({keyword, _, Lit}, <<"f64x2">>, _Bits) -> float_lane(Lit, 64);
lane_bits({keyword, _, Lit}, _Shape, Bits) -> integer_lane(Lit, Bits);
lane_bits(Form, _Shape, _Bits) -> fail(unexpected_lane, Form).

%% A narrow lane may be written as either reading of its bits, so it is read at
%% the widest signed width that holds both and then has to fit the lane: for an
%% `i8' that is -128 to 255, and `0x100' is neither.
integer_lane(Lit, Bits) ->
    Kind = case Bits of 64 -> i64; _ -> i32 end,
    case wasm_wat_num:integer(Lit, Kind) of
        {ok, V} when V >= -(1 bsl (Bits - 1)), V < (1 bsl Bits) ->
            V band ((1 bsl Bits) - 1);
        {ok, _} -> fail(constant_out_of_range, Lit);
        error -> fail(malformed_integer, Lit)
    end.

float_lane(Lit, Width) ->
    case wasm_wat_num:float_bits(Lit, Width) of
        {ok, Bits} -> Bits;
        error -> fail(malformed_float, Lit)
    end.

%%% --------------------------------------------------------------- indices ---

%% An index is a number or a name; a folded operand is neither, which is what
%% lets an optional index be told apart from the operand that would follow it.
take_indices(Forms, N) -> take_indices(Forms, N, []).

take_indices(Forms, 0, Acc) ->
    {lists:reverse(Acc), Forms};
take_indices([{id, _, _} = Form | Rest], N, Acc) ->
    take_indices(Rest, decrement(N), [Form | Acc]);
take_indices([{keyword, _, <<C, _/binary>>} = Form | Rest], N, Acc)
  when C >= $0, C =< $9 ->
    take_indices(Rest, decrement(N), [Form | Acc]);
take_indices(Forms, _N, Acc) ->
    {lists:reverse(Acc), Forms}.

decrement(all) -> all;
decrement(N) -> N - 1.

%% An index is written as a number or as a name declared elsewhere.
index({keyword, _, Bin}, _Space, _Ctx) -> u32(Bin);
%% A label is not declared in an index space: it is the distance out to the
%% block that opened it, so the innermost name wins and shadowing is legal.
index({id, _, Name}, label, #ctx{labels = Labels}) ->
    case index_of(Name, Labels, 0) of
        {ok, Depth} -> Depth;
        error -> fail(unknown_label, Name)
    end;
index({id, _, Name}, Space, #ctx{names = Names}) ->
    case maps:get(Name, maps:get(Space, Names, #{}), undefined) of
        undefined -> fail(unknown_identifier, {Space, Name});
        Index -> Index
    end;
index(Form, _Space, _Ctx) ->
    fail(unexpected_index, Form).

field_index({keyword, _, Bin}, _Type, _Ctx) ->
    u32(Bin);
field_index({id, _, Name}, Type, #ctx{field_names = Fields}) ->
    case maps:get(Name, maps:get(Type, Fields, #{}), undefined) of
        undefined -> fail(unknown_identifier, {field, Name});
        Index -> Index
    end;
field_index(Form, _Type, _Ctx) ->
    fail(unexpected_index, Form).

index_of(_Name, [], _I) -> error;
index_of(Name, [Name | _], I) -> {ok, I};
index_of(Name, [_ | Rest], I) -> index_of(Name, Rest, I + 1).

%% A name that denotes no instruction is reported here rather than becoming an
%% atom nobody asked for.
known(Name) ->
    case wasm_wat_instr:atom_of(Name) of
        Atom when is_atom(Atom) -> Atom;
        _ -> fail(unknown_instruction, Name)
    end.

fail(Kind, Detail) ->
    wasm_error:malformed(Kind, atom_to_binary(Kind), #{detail => detail(Detail)}).

%% Positions and tokens are large; a name or an atom is what a reader wants.
detail({keyword, _, B}) -> B;
detail({id, _, B}) -> B;
detail({list, Pos, _}) -> #{offset => Pos};
detail(D) when is_binary(D); is_atom(D) -> D;
detail(D) -> iolist_to_binary(io_lib:format("~0p", [D])).
