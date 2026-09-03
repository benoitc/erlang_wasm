-module(wasm_validate).
-moduledoc """
Module-level validation. This is what decides whether you get `{error, #{class
:= invalid}}` back, and everything it proves is what the interpreter is then
allowed to assume.

It runs as a separate pass over the decoded AST, before any IR is built and
never during execution. That separation is the whole point: once a module
validates, the interpreter can assume every index is in range, every operand
has the type it expects, and every branch target exists. Anything the
interpreter would otherwise have to re-check on the hot path is checked
exactly once here.

Function bodies are checked by `wasm_validate_code`. This module owns the
surrounding structure: index spaces, limits, imports, exports, segments,
start function, and constant expressions.
""".

-include("wasm.hrl").
-include("wasm_validate.hrl").

-export([module/1, module_unchecked/1, context/1, cached_context/1]).

%%% ----------------------------------------------------------------- api ---

-spec module(#module{}) -> {ok, #module{}} | {error, wasm_error:error()}.
module(M) ->
    wasm_error:capture(fun() -> {ok, module_unchecked(M)} end).

-spec module_unchecked(#module{}) -> #module{}.
module_unchecked(M) ->
    Ctx = context(M),
    check_types(M),
    check_ref_types(M, Ctx),
    check_limits(M),
    check_imports(M, Ctx),
    check_subtypes(M, Ctx),
    check_tags(M, Ctx),
    check_globals(M, Ctx),
    check_elems(M, Ctx),
    check_datas(M, Ctx),
    check_tables(M, Ctx),
    check_exports(M, Ctx),
    check_start(M, Ctx),
    %% Last, because it is the only check that changes the module: each body
    %% comes back annotated with the operand-stack heights the validator worked
    %% them out from. See `wasm_validate_code:function/3`.
    M#module{funcs = check_funcs(M, Ctx), identity = identity(M)}.

%% Every validated module gets an identity, because everything that caches work
%% derived from a module needs one and validation is the single funnel every
%% module passes through. A caller that already knows the module's content hash
%% sets it before getting here and keeps it; anything else gets a fresh
%% reference, which is correct and simply does not share.
identity(#module{identity = undefined}) -> make_ref();
identity(#module{identity = Id}) -> Id.

%%% -------------------------------------------------------------- context ---

%% @doc Build the index spaces a module is validated against.
%%
%% Imports occupy the low indices of each space, before anything the module
%% defines itself. Getting that order wrong silently shifts every index in the
%% module, which produces a runtime that appears to work until a module imports
%% something.
-doc """
As `context/1`, memoised per module in the calling process.

Instantiation rebuilds the context each time, and canonicalisation interns
every recursive type group. A module is immutable, so the answer cannot change;
recomputing it per instance cost a third of instantiation time.
""".
-spec cached_context(#module{}) -> #ctx{}.
cached_context(M) ->
    %% Compared with `=:=' against the last module seen, which for the common
    %% shape (a pool of workers instantiating one cached module) hits every
    %% time. Hashing the module to key a map cost more than it saved: the
    %% modules are large and `phash2' walks all of one.
    case get(wasm_ctx_cache) of
        {M, Ctx} -> Ctx;
        _ ->
            Ctx = context(M),
            put(wasm_ctx_cache, {M, Ctx}),
            Ctx
    end.

-spec context(#module{}) -> #ctx{}.
context(#module{types = Types, imports = Imports, funcs = Funcs, tables = Tables,
                mems = Mems, globals = Globals, elems = Elems, datas = Datas,
                rec_groups = Groups} = M) ->
    ImportedFuncs   = [T || #import{desc = {func, T}} <- Imports],
    ImportedTables  = [T || #import{desc = {table, T}} <- Imports],
    ImportedMems    = [T || #import{desc = {mem, T}} <- Imports],
    ImportedGlobals = [T || #import{desc = {global, T}} <- Imports],
    ImportedTags    = [T || #import{desc = {tag, T}} <- Imports],
    TypeTuple = list_to_tuple(Types),
    Canon = wasm_types:canonicalise(Types, Groups),
    #ctx{
        types   = TypeTuple,
        canon   = Canon,
        fields  = list_to_tuple([type_fields(S) || S <- Types]), kinds   = list_to_tuple([type_kind(S) || S <- Types]), supers  = list_to_tuple(
                    [wasm_types:canon_supers(I, TypeTuple, Canon)
                     || I <- lists:seq(0, length(Types) - 1)]), funcs   = list_to_tuple(ImportedFuncs ++ [T || #func{type = T} <- Funcs]), tables  = list_to_tuple(ImportedTables ++ Tables),
        mems    = list_to_tuple(ImportedMems ++ Mems),
        globals = list_to_tuple(ImportedGlobals ++
                                [T || #global{type = T} <- Globals]), tags    = list_to_tuple(ImportedTags ++ M#module.tags),
        elems   = list_to_tuple([T || #elem{type = T} <- Elems]), n_datas = length(Datas),
        n_imported_globals = length(ImportedGlobals),
        refs    = declared_refs(M),
        shared_globals = shared_globals(M),
        shared_mems = shared_mems(M)
    }.

%% What `struct.get' and `array.get' need to know about a type, resolved once
%% rather than looked up through the type table on every access.
type_fields(#subtype{body = #structtype{fields = Fs}}) -> list_to_tuple(Fs);
type_fields(#subtype{body = #arraytype{field = F}}) -> F;
type_fields(#subtype{}) -> undefined.

type_kind(#subtype{body = #structtype{}}) -> struct;
type_kind(#subtype{body = #arraytype{}}) -> array;
type_kind(#subtype{body = #functype{}}) -> func.

%% A memory is shared when another instance can observe it growing: imported
%% from somewhere, or exported to somewhere.
shared_mems(#module{imports = Imports, mems = Mems, exports = Exports}) ->
    NImported = length([1 || #import{desc = {mem, _}} <- Imports]),
    Total = NImported + length(Mems),
    Exported = maps:from_keys([I || #export{desc = {mem, I}} <- Exports], true),
    maps:from_keys([I || I <- lists:seq(0, Total - 1), I < NImported orelse maps:is_key(I, Exported)],
                   true).

%% A global is shared when a write to it is observable from another module:
%% mutable, and either imported from somewhere or exported to somewhere.
shared_globals(#module{imports = Imports, globals = Globals,
                       exports = Exports}) ->
    Imported = [T || #import{desc = {global, T}} <- Imports],
    Types = Imported ++ [T || #global{type = T} <- Globals],
    NImported = length(Imported),
    Exported = maps:from_keys([I || #export{desc = {global, I}} <- Exports], true),
    maps:from_keys(
      [I || {I, #globaltype{mut = var}} <- lists:enumerate(0, Types), I < NImported orelse maps:is_key(I, Exported)],
      true).

%% Functions that `ref.func' may name.
%%
%% A function becomes referenceable by being exported, or by appearing in any
%% element segment or global initialiser. Without this restriction a module
%% could fabricate a reference to any function in its index space, including
%% ones the embedder deliberately did not expose, and then call it indirectly.
declared_refs(#module{exports = Exports, elems = Elems, globals = Globals,
                      tables = Tables}) ->
    FromExports = [I || #export{desc = {func, I}} <- Exports],
    FromElems = [I || #elem{init = Inits} <- Elems, Expr <- Inits, {ref_func, I} <- Expr],
    FromGlobals = [I || #global{init = Expr} <- Globals, {ref_func, I} <- Expr],
    FromTables = [I || #tabletype{init = Expr} <- Tables, Expr =/= undefined,
                       {ref_func, I} <- Expr],
    maps:from_keys(FromExports ++ FromElems ++ FromGlobals ++ FromTables, true).

%%% --------------------------------------------------------------- checks ---

%% Every `(ref $t)' must name a type that exists.
%%
%% Heap types can appear anywhere a value type can, and the code validator only
%% sees the ones inside function bodies. A `(ref 1)' in a function signature, a
%% table's element type, a global's type or an element segment's type would
%% otherwise pass unchecked and only fail later as a confusing internal error.
check_ref_types(#module{types = Types, imports = Imports, tables = Tables,
                        globals = Globals, elems = Elems, funcs = Funcs,
                        rec_groups = Groups}, Ctx) ->
    N = tuple_size(Ctx#ctx.types),
    check_type_section_refs(Types, Groups),
    Declared =
        [T || #import{desc = D} <- Imports, T <- import_valtypes(D)] ++ [ET || #tabletype{elemtype = ET} <- Tables] ++ [VT || #global{type = #globaltype{valtype = VT}} <- Globals] ++ [ET || #elem{type = ET} <- Elems] ++ [L || #func{locals = Ls} <- Funcs, L <- Ls],
    lists:foreach(fun(T) -> check_ref_type(T, N) end, Declared).

import_valtypes({table, #tabletype{elemtype = ET}}) -> [ET];
import_valtypes({global, #globaltype{valtype = VT}}) -> [VT];
import_valtypes(_) -> [].

check_ref_type({ref, _, {type, Idx}}, N) when Idx >= N ->
    invalid(unknown_type, <<"unknown type">>, #{index => Idx});
check_ref_type(_, _) -> ok.

%% Inside the type section a type may only name types in *earlier* groups or in
%% its own. A forward reference to a later group is unknown, even though the
%% index exists once the section is fully decoded: the groups are what bound
%% recursion, and allowing a reference past one's own would make canonical
%% identity depend on types that had not been canonicalised yet.
check_type_section_refs(Types, Groups) ->
    T = list_to_tuple(Types),
    lists:foreach(
      fun({Start, Count}) ->
              Limit = Start + Count,
              lists:foreach(
                fun(I) ->
                        #subtype{supers = Sup, body = B} = element(I + 1, T),
                        [in_scope(S, Limit) || S <- Sup], [in_scope_vt(V, Limit) || V <- comptype_valtypes(B)] end, lists:seq(Start, Limit - 1))
      end, Groups).

in_scope_vt({ref, _, {type, Idx}}, Limit) -> in_scope(Idx, Limit);
in_scope_vt(_, _Limit) -> ok.

in_scope(Idx, Limit) when Idx < Limit -> ok;
in_scope(Idx, _Limit) ->
    invalid(unknown_type, <<"unknown type">>, #{index => Idx}).

check_types(#module{types = Types}) ->
    %% Multi-value results are permitted; nothing else constrains a type here.
    lists:foreach(fun(#subtype{}) -> ok end, Types).

%% Every value type a composite type mentions, for the heap-type index check.
%% Packed field types name no heap type, so they contribute nothing.
comptype_valtypes(#functype{params = P, results = R}) -> P ++ R;
comptype_valtypes(#structtype{fields = Fs}) -> [T || #fieldtype{type = T} <- Fs];
comptype_valtypes(#arraytype{field = #fieldtype{type = T}}) -> [T].

%% Limits must be internally consistent, and memories additionally cannot
%% exceed the 4 GiB that a 32-bit address space can reach.
check_limits(#module{mems = Mems, tables = Tables, imports = Imports}) ->
    AllMems = [T || #import{desc = {mem, T}} <- Imports] ++ Mems,
    AllTables = [T || #import{desc = {table, T}} <- Imports] ++ Tables,
    %% Multiple memories are permitted. The memory index is threaded through
    %% the decoder, validator and IR rather than pinned to zero, so allowing
    %% them costs nothing here and the specification test suite already uses
    %% them in otherwise-core files.
    lists:foreach(fun(#memtype{limits = L}) -> check_mem_limits(L) end, AllMems),
    lists:foreach(fun(#tabletype{limits = L}) -> check_table_limits(L) end, AllTables).

check_mem_limits(#limits{min = Min, max = Max, shared = Shared,
                         index_type = IdxType}) ->
    %% A shared memory must declare a maximum. Without one it could grow, and
    %% growing means reallocating a region other agents are reading.
    case {Shared, Max} of
        {true, undefined} ->
            invalid(shared_memory_must_have_maximum,
                    <<"shared memory must have maximum">>, #{});
        _ -> ok
    end,
    %% A 64-bit memory is still bounded, just far higher: the proposal caps it
    %% at 2^48 bytes rather than at whatever the index type could express.
    {Ceiling, Msg} =
        case IdxType of
            i32 -> {?MAX_PAGES_32,
                    <<"memory size must be at most 65536 pages (4GiB)">>};
            i64 -> {?MAX_PAGES_64,
                    <<"memory size must be at most 281474976710656 pages">>}
        end,
    case Min > Ceiling of
        true -> invalid(memory_size_too_large, Msg, #{min => Min});
        false -> ok
    end,
    check_max(Max, Min, Ceiling, Msg).

%% Tables have no shared form. The flag decodes because the bit exists in the
%% same byte, and a table that sets it is invalid rather than ignored: it went
%% unchecked entirely until threads landed.
check_table_limits(#limits{shared = true}) ->
    invalid(shared_table_unsupported, <<"shared tables are not supported">>,
            #{});
check_table_limits(#limits{min = Min, max = Max, index_type = IdxType}) ->
    %% A 64-bit table is bounded only by its index type, where a 32-bit one
    %% stops at 2^32-1.
    {Ceiling, Msg} =
        case IdxType of
            i32 -> {?MAX_TABLE_SIZE, <<"table size must be at most 2^32-1">>};
            i64 -> {?MAX_TABLE_SIZE_64, <<"table size must be at most 2^64-1">>}
        end,
    case Min > Ceiling of
        true -> invalid(table_size_too_large, Msg, #{min => Min});
        false -> ok
    end,
    check_max(Max, Min, Ceiling, Msg).

check_max(undefined, _Min, _Ceiling, _Msg) -> ok;
check_max(Max, Min, _Ceiling, _Msg) when Max < Min ->
    invalid(limits_min_greater_than_max,
            <<"size minimum must not be greater than maximum">>,
            #{min => Min, max => Max});
check_max(Max, _Min, Ceiling, Msg) when Max > Ceiling ->
    invalid(limits_max_too_large, Msg, #{max => Max, ceiling => Ceiling});
check_max(_, _, _, _) -> ok.

check_imports(#module{imports = Imports}, Ctx) ->
    lists:foreach(
      fun(#import{desc = {func, T}}) -> check_type_index(T, Ctx);
         (#import{desc = {tag, #tagtype{type = T}}}) -> check_type_index(T, Ctx);
         (_) -> ok
      end, Imports).

check_type_index(T, Ctx) ->
    case T < tuple_size(Ctx#ctx.types) of
        true -> ok;
        false -> invalid(unknown_type, <<"unknown type">>, #{index => T})
    end.

%% A tag's type must exist, and an exception tag carries values without
%% returning any, so its type must have no results.
%% A declared supertype has to be one: the type must actually be structurally
%% below it, the supertype must exist and must not be final, and it must be
%% declared before this one so the relation cannot be circular.
%%
%% And there may be at most one of them. The binary format encodes the
%% supertypes as a vector, which is what makes two of them decodable, and the
%% specification bounds that vector at one; `type-subtyping.wast` asserts it as
%% "multiple supertypes". Without this a module declaring two parents was
%% accepted and each parent checked on its own, which is a coherent thing to do
%% and not what the language says.
check_subtypes(#module{types = Types}, #ctx{types = T, canon = C} = Ctx) ->
    lists:foreach(
      fun({I, #subtype{supers = Supers, body = Body}}) ->
              case Supers of
                  [_, _ | _] ->
                      invalid(multiple_supertypes, <<"multiple supertypes">>,
                              #{type => I, count => length(Supers)});
                  _ -> ok
              end,
              lists:foreach(
                fun(Sup) ->
                        check_super(I, Sup, Body, T, C, Ctx)
                end, Supers)
      end, lists:enumerate(0, Types)).

check_super(I, Sup, Body, T, C, Ctx) ->
    case Sup < tuple_size(T) of
        false -> invalid(unknown_type, <<"unknown type">>, #{index => Sup});
        true -> ok
    end,
    #subtype{final = Final, body = SupBody} = element(Sup + 1, T),
    case Final of
        true -> invalid(subtype_of_final,
                        <<"sub type must not be final">>, #{super => Sup});
        false -> ok
    end,
    case comp_subtype(Body, SupBody, Ctx) of
        true -> ok;
        false -> invalid(type_mismatch, <<"type mismatch">>,
                         #{reason => not_a_subtype, type => I, super => Sup})
    end,
    _ = C,
    ok.

%% Function parameters are contravariant and results covariant; a struct may add
%% fields and narrow existing ones; an array may narrow its element. A *mutable*
%% field is invariant, because it is written through as well as read.
comp_subtype(#functype{params = P1, results = R1},
             #functype{params = P2, results = R2}, Ctx) ->
    length(P1) =:= length(P2) andalso length(R1) =:= length(R2) andalso
        lists:all(fun({A, B}) -> vt_sub(B, A, Ctx) end, lists:zip(P1, P2)) andalso
        lists:all(fun({A, B}) -> vt_sub(A, B, Ctx) end, lists:zip(R1, R2));
comp_subtype(#structtype{fields = F1}, #structtype{fields = F2}, Ctx) ->
    length(F1) >= length(F2) andalso
        lists:all(fun({A, B}) -> field_sub(A, B, Ctx) end,
                  lists:zip(lists:sublist(F1, length(F2)), F2));
comp_subtype(#arraytype{field = F1}, #arraytype{field = F2}, Ctx) ->
    field_sub(F1, F2, Ctx);
comp_subtype(_, _, _Ctx) -> false.

field_sub(#fieldtype{type = T1, mut = const}, #fieldtype{type = T2, mut = const},
          Ctx) ->
    vt_sub(T1, T2, Ctx);
field_sub(#fieldtype{type = T, mut = var}, #fieldtype{type = T, mut = var},
          _Ctx) ->
    true;
field_sub(_, _, _Ctx) -> false.

%% Storage types compare as themselves; only value types have a subtype
%% relation worth consulting.
vt_sub(T, T, _Ctx) -> true;
vt_sub(T1, T2, Ctx) when is_tuple(T1), is_tuple(T2) ->
    wasm_validate_code:subtype(T1, T2, Ctx);
vt_sub(_, _, _Ctx) -> false.

check_tags(#module{tags = Tags, imports = Imports}, Ctx) ->
    %% Imported tags are checked too: an exception tag that returned values
    %% would be meaningless however it entered the module.
    All = [T || #import{desc = {tag, T}} <- Imports] ++ Tags,
    lists:foreach(
      fun(#tagtype{type = T}) ->
              check_type_index(T, Ctx),
              case (element(T + 1, Ctx#ctx.types))#subtype.body of
                  #functype{results = []} -> ok;
                  #functype{results = R} ->
                      invalid(non_empty_tag_result,
                              <<"non-empty tag result type">>, #{results => R})
              end
      end, All).

%% A global's initialiser may read globals that are already defined: every
%% import, plus the globals declared before it. Truncating the visible space to
%% that prefix is what makes the restriction enforceable and, incidentally,
%% what makes instantiation order well defined.
check_globals(#module{globals = Globals}, Ctx) ->
    All = tuple_to_list(Ctx#ctx.globals),
    lists:foldl(
      fun(#global{type = #globaltype{valtype = T}, init = Init}, Visible) ->
              InitCtx = Ctx#ctx{globals = list_to_tuple(
                                            lists:sublist(All, Visible))},
              wasm_validate_code:const_expr(Init, T, InitCtx),
              Visible + 1
      end, Ctx#ctx.n_imported_globals, Globals),
    ok.

%% A table initialiser may only read *imported* globals. The table section
%% precedes the global section in the binary format, so a module's own globals
%% do not exist yet at the point the table is initialised. Validating these
%% against the full global space would accept modules whose behaviour depends
%% on a global that has not been evaluated.
check_tables(#module{tables = Tables}, Ctx) ->
    InitCtx = Ctx#ctx{globals = list_to_tuple(
                                 lists:sublist(tuple_to_list(Ctx#ctx.globals),
                                               Ctx#ctx.n_imported_globals))},
    lists:foreach(
      fun(#tabletype{elemtype = {ref, nonull, _} = ET, init = undefined}) ->
              %% A table's elements start at their type's default, and a
              %% non-nullable reference has none. Such a table must therefore
              %% carry an explicit initialiser expression.
              invalid(type_mismatch, <<"type mismatch">>,
                      #{reason => non_defaultable_table, elemtype => ET});
         (#tabletype{init = undefined}) -> ok;
         (#tabletype{elemtype = ET, init = Init}) ->
              wasm_validate_code:const_expr(Init, ET, InitCtx)
      end, Tables).

check_elems(#module{elems = Elems}, Ctx) ->
    lists:foreach(
      fun(#elem{type = RT, init = Inits, mode = Mode}) ->
              lists:foreach(
                fun(Expr) -> wasm_validate_code:const_expr(Expr, RT, Ctx) end,
                Inits),
              check_elem_mode(Mode, RT, Ctx)
      end, Elems).

check_elem_mode(passive, _RT, _Ctx) -> ok;
check_elem_mode(declarative, _RT, _Ctx) -> ok;
check_elem_mode({active, TableIdx, Offset}, RT, Ctx) ->
    case TableIdx < tuple_size(Ctx#ctx.tables) of
        false -> invalid(unknown_table, <<"unknown table">>, #{index => TableIdx});
        true ->
            #tabletype{elemtype = ET} = element(TableIdx + 1, Ctx#ctx.tables),
            %% The segment's elements only have to *fit* the table, so a
            %% non-nullable segment may initialise a nullable table.
            case wasm_validate_code:subtype(RT, ET, Ctx) of
                true -> ok;
                false -> invalid(type_mismatch, <<"type mismatch">>,
                                 #{table => ET, elem => RT})
            end
    end,
    %% As for data segments, the offset follows the table's index type.
    #tabletype{limits = #limits{index_type = IT}} =
        element(TableIdx + 1, Ctx#ctx.tables),
    wasm_validate_code:const_expr(Offset, IT, Ctx).

%% An active segment's offset is expressed in the memory's own index type, so
%% a data segment for a 64-bit memory carries an `i64.const', not an `i32.const'.
check_datas(#module{datas = Datas}, Ctx) ->
    lists:foreach(
      fun(#data{mode = passive}) -> ok;
         (#data{mode = {active, MemIdx, Offset}}) ->
              case MemIdx < tuple_size(Ctx#ctx.mems) of
                  false -> invalid(unknown_memory, <<"unknown memory">>,
                                   #{index => MemIdx});
                  true ->
                      #memtype{limits = #limits{index_type = T}} =
                          element(MemIdx + 1, Ctx#ctx.mems),
                      wasm_validate_code:const_expr(Offset, T, Ctx)
              end
      end, Datas).

%% Export names must be unique across all kinds, not merely within a kind: the
%% embedder resolves by name alone.
check_exports(#module{exports = Exports}, Ctx) ->
    lists:foldl(
      fun(#export{name = Name, desc = Desc}, Seen) ->
              case maps:is_key(Name, Seen) of
                  true -> invalid(duplicate_export,
                                  <<"duplicate export name">>, #{name => Name});
                  false -> ok
              end,
              check_export_target(Desc, Ctx),
              Seen#{Name => true}
      end, #{}, Exports),
    ok.

check_export_target({func, I}, Ctx) -> in_range(I, Ctx#ctx.funcs, unknown_func,
                                                <<"unknown function">>);
check_export_target({table, I}, Ctx) -> in_range(I, Ctx#ctx.tables, unknown_table,
                                                 <<"unknown table">>);
check_export_target({mem, I}, Ctx) -> in_range(I, Ctx#ctx.mems, unknown_memory,
                                               <<"unknown memory">>);
check_export_target({global, I}, Ctx) -> in_range(I, Ctx#ctx.globals, unknown_global,
                                                  <<"unknown global">>);
check_export_target({tag, I}, Ctx) -> in_range(I, Ctx#ctx.tags, unknown_tag,
                                               <<"unknown tag">>).

in_range(I, Tuple, Kind, Msg) ->
    case I < tuple_size(Tuple) of
        true -> ok;
        false -> invalid(Kind, Msg, #{index => I})
    end.

%% The start function is called with no arguments and its results discarded, so
%% it must take none and return none.
check_start(#module{start = undefined}, _Ctx) -> ok;
check_start(#module{start = F}, Ctx) ->
    case F < tuple_size(Ctx#ctx.funcs) of
        false -> invalid(unknown_func, <<"unknown function">>, #{index => F});
        true ->
            TypeIdx = element(F + 1, Ctx#ctx.funcs),
            case element(TypeIdx + 1, Ctx#ctx.types) of
                #subtype{body = #functype{params = [], results = []}} -> ok;
                FT -> invalid(invalid_start_function,
                              <<"start function must have type [] -> []">>,
                              #{index => F, type => FT})
            end
    end.

%% Function bodies. The index is attached to any failure, because a type
%% mismatch reported without saying which function is close to useless on a
%% module with a thousand of them.
check_funcs(#module{funcs = Funcs, imports = Imports}, Ctx) ->
    Offset = length([1 || #import{desc = {func, _}} <- Imports]),
    {Checked, _} = lists:mapfoldl(
      fun(#func{type = TypeIdx} = F, N) ->
              case TypeIdx < tuple_size(Ctx#ctx.types) of
                  false -> invalid(unknown_type, <<"unknown type">>,
                                   #{index => TypeIdx, func => N});
                  true -> ok
              end,
              %% A function's declared type must actually be a function type:
              %% the type section may now also hold structs and arrays.
              FT = case (element(TypeIdx + 1, Ctx#ctx.types))#subtype.body of
                       #functype{} = Ft -> Ft;
                       Other -> invalid(type_mismatch, <<"type mismatch">>,
                                        #{reason => expected_function_type,
                                          index => TypeIdx,
                                          got => element(1, Other)})
                   end,
              Ann = try
                        wasm_validate_code:function(Ctx, FT, F)
                    catch
                        throw:{wasm_error, Err} ->
                            throw({wasm_error,
                                   wasm_error:add_context(Err, #{func => N})})
                    end,
              %% Tagged rather than left as a bare list, so a decoded module
              %% and a validated one are told apart by their shape. Nothing
              %% expressed that before, and the two are not interchangeable:
              %% only one of them carries heights.
              {F#func{body = {validated, Ann}}, N + 1}
      end, Offset, Funcs),
    Checked.

invalid(Kind, Msg, Ctx) -> wasm_error:invalid(Kind, Msg, Ctx).
