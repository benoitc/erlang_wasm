%% @doc Linking: what an import is checked against, and what it shares.
%%
%% These were found by looking at what the specification baseline was actually
%% carrying. Every entry in it is supposed to name an unimplemented proposal;
%% several instead named one while hiding a defect behind it, which is the
%% failure mode a baseline has. Each case here is one of those.
-module(wasm_linking_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(I32, 16#7F).
-define(I64, 16#7E).

all() ->
    [an_import_of_the_wrong_kind_is_a_link_error,
     a_mutable_global_is_shared_with_its_importer,
     an_immutable_global_is_copied,
     import_mutability_must_match,
     a_function_import_signature_is_checked,
     an_embedder_function_is_taken_on_trust,
     engine_rows_go_when_their_creator_does,
     destroying_an_importer_does_not_free_the_memory,
     freeing_a_grown_memory_releases_what_it_grew_to].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

%% An imported memory belongs to whoever exported it. Freeing it on destroy
%% released pages another instance was still using, and doing it twice took the
%% node counter below zero, where it wrapped to 2^64-1 and refused every
%% allocation on the node for the rest of its life.
destroying_an_importer_does_not_free_the_memory(_Config) ->
    {ok, Mem} = wasm_memory:new(1, 4),
    {ok, P} = wasm_wat:module(~"(module (import \"e\" \"m\" (memory 1 4)))"),
    {ok, Mod} = wasm_validate:module(P),
    Base = wasm_engine:pages_in_use(),
    Imports = #{{~"e", ~"m"} => Mem},
    {ok, A} = wasm:instantiate(Mod, Imports),
    {ok, B} = wasm:instantiate(Mod, Imports),
    ?assertEqual(Base, wasm_engine:pages_in_use()),
    ok = wasm:destroy(A),
    ?assertEqual(Base, wasm_engine:pages_in_use()),
    ok = wasm:destroy(B),
    %% Still charged, and still the owner's to read and to free.
    ?assertEqual(Base, wasm_engine:pages_in_use()),
    ?assertEqual(0, wasm_memory:atomic_load(Mem, 0, 4)),
    ok = wasm_memory:free(Mem),
    ?assertEqual(Base - 1, wasm_engine:pages_in_use()).

%% `free/1' matched the page count in the handle, which is the size that handle
%% was made at. A grown memory therefore returned only its original pages and
%% left the rest charged forever.
freeing_a_grown_memory_releases_what_it_grew_to(_Config) ->
    Base = wasm_engine:pages_in_use(),
    {ok, Mem} = wasm_memory:new(1, 8),
    {ok, _, Grown} = wasm_memory:grow(Mem, 3),
    ?assertEqual(Base + 4, wasm_engine:pages_in_use()),
    ok = wasm_memory:free(Grown),
    ?assertEqual(Base, wasm_engine:pages_in_use()).

end_per_suite(_Config) -> ok.

%%% ------------------------------------------------------------------ rule ---

%% An embedder hands over bare Erlang terms, so an import may be satisfied with
%% something of entirely the wrong kind. Nothing it passes may raise out of the
%% runtime.
%%
%% Handing a table to a module that imports a memory used to reach
%% `wasm_memory:limits/1' and die with a `function_clause', reported as an
%% internal error. That is a hole in the property the whole library rests on:
%% every failure is a value.
an_import_of_the_wrong_kind_is_a_link_error(_Config) ->
    {ok, MemMod} = wasm:load(imports_memory()),
    Table = wasm_table:new(1, null),
    {ok, Mem} = wasm_memory:new(1, 1),
    Wrong = [Table, 666, ~"not a memory", fun(_, _) -> {ok, []} end],
    [?assertMatch({error, #{class := link, kind := incompatible_import_type}},
                  wasm:instantiate(MemMod, #{{~"env", ~"x"} => W}))
     || W <- Wrong],
    %% And the right kind still links.
    {ok, Inst} = wasm:instantiate(MemMod, #{{~"env", ~"x"} => Mem}),
    ok = wasm:destroy(Inst),

    %% The same in the other direction: a memory where a table is declared.
    {ok, TabMod} = wasm:load(imports_table()),
    [?assertMatch({error, #{class := link, kind := incompatible_import_type}},
                  wasm:instantiate(TabMod, #{{~"env", ~"x"} => W}))
     || W <- [Mem, 666, ~"not a table"]],
    {ok, Inst2} = wasm:instantiate(TabMod, #{{~"env", ~"x"} => Table}),
    ok = wasm:destroy(Inst2).

%% A mutable global is shared state, not a value copied into each instance.
%%
%% Two modules linked to the same global must agree about it: a `global.set` in
%% one has to be visible in the other. Copying the value in gave each instance
%% its own, so they diverged silently. This is the same defect imported tables
%% had before 0.2.0.
a_mutable_global_is_shared_with_its_importer(_Config) ->
    {ok, Exporter} = wasm:load(exports_mutable_global()),
    {ok, A} = wasm:instantiate(Exporter, #{}),
    {ok, Ext} = wasm:extern(A, ~"g"),

    {ok, Importer} = wasm:load(imports_global(true)),
    {ok, B} = wasm:instantiate(Importer, #{{~"env", ~"g"} => Ext}),

    %% Both start from the exporter's initialiser.
    ?assertMatch({ok, [7]}, wasm:call(A, ~"get", [])),
    ?assertMatch({ok, [7]}, wasm:call(B, ~"get", [])),

    %% A write in the importer is visible in the exporter, and the reverse.
    {ok, []} = wasm:call(B, ~"set", [42]),
    ?assertMatch({ok, [42]}, wasm:call(A, ~"get", [])),
    {ok, []} = wasm:call(A, ~"set", [99]),
    ?assertMatch({ok, [99]}, wasm:call(B, ~"get", [])),

    %% And the embedder's own view agrees with both.
    ?assertMatch({ok, [99]}, wasm:get_global(A, ~"g")),
    ok = wasm:destroy(A),
    ok = wasm:destroy(B).

%% An immutable global has nothing to share, so it hands over its value rather
%% than a cell. The declared type travels with it either way, because a bare
%% value cannot say whether it is `funcref`, `(ref func)` or `(ref $t)`.
an_immutable_global_is_copied(_Config) ->
    {ok, Exporter} = wasm:load(exports_immutable_global()),
    {ok, A} = wasm:instantiate(Exporter, #{}),
    ?assertMatch({ok, {wasm_global_const, 7, _}}, wasm:extern(A, ~"g")),
    ok = wasm:destroy(A).

%% Mutability must match exactly across an import boundary. Importing a mutable
%% global as immutable would let the importer cache a value that changes under
%% it; the reverse would let it believe a write is visible when it is not.
import_mutability_must_match(_Config) ->
    {ok, MutExp} = wasm:load(exports_mutable_global()),
    {ok, A} = wasm:instantiate(MutExp, #{}),
    {ok, MutRef} = wasm:extern(A, ~"g"),

    {ok, ConstExp} = wasm:load(exports_immutable_global()),
    {ok, B} = wasm:instantiate(ConstExp, #{}),
    {ok, ConstVal} = wasm:extern(B, ~"g"),

    {ok, WantsMut} = wasm:load(imports_global(true)),
    {ok, WantsConst} = wasm:load(imports_global(false)),

    ?assertMatch({error, #{class := link, kind := incompatible_import_type,
                           ctx := #{reason := mutability_mismatch}}},
                 wasm:instantiate(WantsMut, #{{~"env", ~"g"} => ConstVal})),
    ?assertMatch({error, #{class := link, kind := incompatible_import_type,
                           ctx := #{reason := mutability_mismatch}}},
                 wasm:instantiate(WantsConst, #{{~"env", ~"g"} => MutRef})),
    ok = wasm:destroy(A),
    ok = wasm:destroy(B).

%% A function exported by one instance carries its type, so an importer that
%% declares a different signature is refused at link time rather than producing
%% a call that goes wrong later.
a_function_import_signature_is_checked(_Config) ->
    {ok, Exporter} = wasm:load(exports_i32_to_i32()),
    {ok, A} = wasm:instantiate(Exporter, #{}),
    {ok, Ext} = wasm:extern(A, ~"f"),

    {ok, Right} = wasm:load(imports_func([?I32], [?I32])),
    {ok, B} = wasm:instantiate(Right, #{{~"env", ~"f"} => Ext}),
    ?assertMatch({ok, [8]}, wasm:call(B, ~"go", [7])),
    ok = wasm:destroy(B),

    [?assertMatch({error, #{class := link, kind := incompatible_import_type}},
                  wasm:instantiate(element(2, wasm:load(imports_func(P, R))),
                                   #{{~"env", ~"f"} => Ext}))
     || {P, R} <- [{[?I64], [?I32]}, {[?I32], [?I64]}, {[], [?I32]}]],
    ok = wasm:destroy(A).

%% An embedder's own function is a bare fun with no type to carry, so it adopts
%% whatever the importer declared. That is deliberate, and stated here so the
%% asymmetry with wasm-to-wasm linking is not mistaken for an oversight.
an_embedder_function_is_taken_on_trust(_Config) ->
    {ok, Mod} = wasm:load(imports_func([?I32], [?I32])),
    Fun = fun(_Ctx, [X]) -> {ok, [X * 2]} end,
    {ok, Inst} = wasm:instantiate(Mod, #{{~"env", ~"f"} => Fun}),
    ?assertMatch({ok, [14]}, wasm:call(Inst, ~"go", [7])),
    ok = wasm:destroy(Inst).

%% A table array, a global cell and a shared memory's chunk tuple all live in
%% the engine's store, keyed by a reference the handle carries. They are
%% released when the process that created them exits.
%%
%% They used to be released by nothing: `wasm_engine:table_forget/1` and
%% `cell_forget/1` had no callers anywhere in the repository, so every one ever
%% created stayed until the node stopped. `wasm_table`'s own documentation said
%% the engine dropped them when the creator exited; the monitor existed and the
%% drop did not.
engine_rows_go_when_their_creator_does(_Config) ->
    Before = ets:info(wasm_tables, size),
    Self = self(),
    Pid = spawn(fun() ->
                    {ok, Mod} = wasm:load(shared_state_module()),
                    {ok, _Inst} = wasm:instantiate(Mod, #{}),
                    Self ! {rows, ets:info(wasm_tables, size)},
                    receive done -> ok end
                end),
    During = receive {rows, N} -> N after 5000 -> ct:fail(no_instance) end,
    ?assert(During > Before, {no_rows_created, Before, During}),
    Ref = erlang:monitor(process, Pid),
    Pid ! done,
    receive {'DOWN', Ref, _, _, _} -> ok after 5000 -> ct:fail(alive) end,
    ?assertEqual(Before, eventually(fun() -> ets:info(wasm_tables, size) end,
                                    Before)),
    ok.

%% The engine drops rows in a cast, so the count settles rather than changing
%% the instant the process exits.
eventually(F, Want) -> eventually(F, Want, 50).

eventually(F, _Want, 0) -> F();
eventually(F, Want, N) ->
    case F() of
        Want -> Want;
        _ -> timer:sleep(20), eventually(F, Want, N - 1)
    end.

%%% --------------------------------------------------------- module builder ---

%% An exported table and an exported mutable global, so instantiating it puts a
%% table array and a global cell into the engine's store.
%% No type section on purpose: an interned recursive type group is node-wide by
%% design and never released, so declaring one would leave a row behind and
%% muddy what this test is measuring.
shared_state_module() ->
    wasm_asm:module(
      [wasm_asm:table_section([{16#70, 1, 1}]),
       wasm_asm:global_section([{16#7F, true, <<16#41, 0>>}]),
       wasm_asm:export_section([{~"t", 1, 0}, {~"g", 3, 0}])]).

%% (import "env" "x" (memory 1))
imports_memory() ->
    wasm_asm:module([wasm_asm:import_section([{~"env", ~"x", 16#00, 1}])]).

%% (import "env" "x" (table 1 funcref))
imports_table() ->
    wasm_asm:module(
      [wasm_asm:section(2, [wasm_asm:uleb(1), wasm_asm:name(~"env"),
                            wasm_asm:name(~"x"), 16#01, 16#70,
                            wasm_asm:limits(16#00, 1, undefined)])]).

%% (global $g (mut i32) (i32.const 7)) with get and set exported.
exports_mutable_global() ->
    wasm_asm:module(
      [wasm_asm:type_section([{[], [?I32]}, {[?I32], []}]),
       wasm_asm:func_section([0, 1]),
       wasm_asm:global_section([{?I32, true, <<16#41, 7>>}]),
       wasm_asm:export_section([{~"g", 3, 0}, {~"get", 0, 0}, {~"set", 0, 1}]),
       wasm_asm:code_section([<<16#23, 0, 16#0B>>,          % global.get 0
                              <<16#20, 0, 16#24, 0, 16#0B>>])]).  % global.set 0

exports_immutable_global() ->
    wasm_asm:module(
      [wasm_asm:global_section([{?I32, false, <<16#41, 7>>}]),
       wasm_asm:export_section([{~"g", 3, 0}])]).

%% (import "env" "g" (global i32)) or (global (mut i32)).
%%
%% The immutable form exports only `get': a `global.set' on an immutable global
%% is an invalid module, so including one would fail validation before linking
%% ever got a chance to reject the import.
imports_global(true) ->
    wasm_asm:module(
      [wasm_asm:type_section([{[], [?I32]}, {[?I32], []}]),
       wasm_asm:section(2, [wasm_asm:uleb(1), wasm_asm:name(~"env"),
                            wasm_asm:name(~"g"), 16#03, ?I32, 1]),
       wasm_asm:func_section([0, 1]),
       wasm_asm:export_section([{~"get", 0, 0}, {~"set", 0, 1}]),
       wasm_asm:code_section([<<16#23, 0, 16#0B>>,
                              <<16#20, 0, 16#24, 0, 16#0B>>])]);
imports_global(false) ->
    wasm_asm:module(
      [wasm_asm:type_section([{[], [?I32]}]),
       wasm_asm:section(2, [wasm_asm:uleb(1), wasm_asm:name(~"env"),
                            wasm_asm:name(~"g"), 16#03, ?I32, 0]),
       wasm_asm:func_section([0]),
       wasm_asm:export_section([{~"get", 0, 0}]),
       wasm_asm:code_section([<<16#23, 0, 16#0B>>])]).

%% (func (export "f") (param i32) (result i32) local.get 0; i32.const 1; i32.add)
exports_i32_to_i32() ->
    wasm_asm:module(
      [wasm_asm:type_section([{[?I32], [?I32]}]),
       wasm_asm:func_section([0]),
       wasm_asm:export_section([{~"f", 0, 0}]),
       wasm_asm:code_section([<<16#20, 0, 16#41, 1, 16#6A, 16#0B>>])]).

%% Imports "env"."f" with the given signature and forwards to it from "go".
%%
%% `go' has the same signature as the import, so the module is valid whatever
%% signature is asked for. Otherwise a mismatched import would make the module
%% ill-typed and fail validation, which is a different check from the one this
%% is meant to exercise.
imports_func(Params, Results) ->
    Forward = iolist_to_binary(
                [[<<16#20, I>>] || I <- lists:seq(0, length(Params) - 1)]),
    wasm_asm:module(
      [wasm_asm:type_section([{Params, Results}]),
       wasm_asm:section(2, [wasm_asm:uleb(1), wasm_asm:name(~"env"),
                            wasm_asm:name(~"f"), 16#00, wasm_asm:uleb(0)]),
       wasm_asm:func_section([0]),
       wasm_asm:export_section([{~"go", 0, 1}]),
       wasm_asm:code_section([<<Forward/binary, 16#10, 0, 16#0B>>])]).
