%% @doc Typed function references: the rules that are easy to get wrong.
%%
%% As with `wasm_num_SUITE' and the other unit suites, this duplicates coverage
%% the specification fixtures give. The fixtures are generated rather than
%% committed, so a fresh clone skips them, and when they do run they say *what*
%% broke rather than why the code is shaped the way it is.
-module(wasm_funcref_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(I32, 16#7F).
-define(FUNCREF, 16#70).

all() ->
    [one_spelling_per_type,
     a_non_nullable_reference_rejects_null,
     ref_func_carries_the_functions_type,
     call_ref_traps_on_null,
     a_non_nullable_table_needs_an_initialiser,
     an_uninitialised_local_is_rejected,
     an_unknown_heap_type_is_rejected,
     numeric_comparison_is_untouched].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

%%% ------------------------------------------------------------------ rule ---

%% `funcref' and `(ref null func)' are the same type and must have the same
%% representation. Two spellings for one type is how a subtyping bug gets in:
%% every comparison would have to remember to treat them as equal, and the one
%% that forgot would silently accept or reject the wrong modules.
one_spelling_per_type(_Config) ->
    %% 0x70 is the `funcref' abbreviation; 0x63 0x70 is `(ref null func)'.
    {T1, <<>>} = wasm_decode:reftype(<<16#70>>),
    {T2, <<>>} = wasm_decode:reftype(<<16#63, 16#70>>),
    ?assertEqual(T1, T2),
    ?assertEqual({ref, null, func}, T1),
    %% And the non-nullable form is genuinely different.
    {T3, <<>>} = wasm_decode:reftype(<<16#64, 16#70>>),
    ?assertNotEqual(T1, T3),
    ?assertEqual({ref, nonull, func}, T3),
    %% A heap type may also be a type index rather than an abstract type.
    {T4, <<>>} = wasm_decode:reftype(<<16#64, 3>>),
    ?assertEqual({ref, nonull, {type, 3}}, T4).

%% A global declared non-nullable cannot be initialised with null. Approximating
%% non-nullable references as nullable, which is what this runtime used to do by
%% refusing them outright, would have let exactly this through.
a_non_nullable_reference_rejects_null(_Config) ->
    ?assertMatch({error, #{class := invalid, kind := type_mismatch}},
                 wasm:load(global_module(<<16#64, ?FUNCREF>>, <<16#D0, ?FUNCREF>>))),
    %% The nullable form accepts it.
    ?assertMatch({ok, _},
                 wasm:load(global_module(<<?FUNCREF>>, <<16#D0, ?FUNCREF>>))).

%% `ref.func $f' produces `(ref $t)' for `$f''s own type, not the erased
%% `funcref'. That is what lets it satisfy a non-nullable table, and subtyping
%% is what still lets it satisfy a `funcref' one.
ref_func_carries_the_functions_type(_Config) ->
    %% A non-nullable table initialised with `ref.func' is accepted...
    ?assertMatch({ok, _}, wasm:load(table_module(<<16#64, ?FUNCREF>>, ref_func))),
    %% ...and so is a nullable one, by subtyping.
    ?assertMatch({ok, _}, wasm:load(table_module(<<?FUNCREF>>, ref_func))),
    %% but a null initialiser only satisfies the nullable table.
    ?assertMatch({ok, _}, wasm:load(table_module(<<?FUNCREF>>, ref_null))),
    ?assertMatch({error, #{class := invalid}},
                 wasm:load(table_module(<<16#64, ?FUNCREF>>, ref_null))).

%% Null is a trap at run time, not a type error: `call_ref' accepts a nullable
%% reference and faults if it turns out to be null.
call_ref_traps_on_null(_Config) ->
    {ok, Mod} = wasm:load(call_ref_module()),
    {ok, Inst} = wasm:instantiate(Mod, #{}),
    ?assertMatch({ok, [7]}, wasm:call(Inst, ~"good", [])),
    ?assertMatch({error, #{class := trap, kind := null_reference}},
                 wasm:call(Inst, ~"bad", [])),
    %% The instance survives the trap, as it must after any aborted invocation.
    ?assertMatch({ok, [7]}, wasm:call(Inst, ~"good", [])),
    ok = wasm:destroy(Inst).

%% A table's elements start at their type's default, and a non-nullable
%% reference has none, so such a table must carry an initialiser expression.
a_non_nullable_table_needs_an_initialiser(_Config) ->
    ?assertMatch({error, #{class := invalid,
                           ctx := #{reason := non_defaultable_table}}},
                 wasm:load(bare_table_module(<<16#64, ?FUNCREF>>))),
    %% A nullable table needs none: its elements start null.
    ?assertMatch({ok, _}, wasm:load(bare_table_module(<<?FUNCREF>>))).

%% A local of non-defaultable type holds nothing until it is assigned, so
%% reading it first is a validation error.
%%
%% An assignment made *inside* a control frame does not survive it: only one arm
%% of an `if' runs, and a `block' may be branched out of before its assignments
%% happen. The specification is deliberately this conservative, so setting in a
%% block and reading after it is still rejected.
an_uninitialised_local_is_rejected(_Config) ->
    ?assertMatch({error, #{class := invalid, kind := uninitialized_local}},
                 wasm:load(local_module(read_before_set))),
    ?assertMatch({error, #{class := invalid, kind := uninitialized_local}},
                 wasm:load(local_module(set_inside_block))),
    ?assertMatch({ok, _}, wasm:load(local_module(set_then_read))).

%% A `(ref $t)' naming a type that does not exist is rejected wherever it
%% appears, including in places the code validator never sees.
an_unknown_heap_type_is_rejected(_Config) ->
    %% In a function signature: the module declares one type, so index 1 is out
    %% of range.
    Bad = wasm_asm:module(
            [wasm_asm:section(1, [wasm_asm:uleb(1), 16#60, wasm_asm:uleb(1),
                                  <<16#64, 1>>, wasm_asm:uleb(0)])]),
    ?assertMatch({error, #{class := invalid, kind := unknown_type}},
                 wasm:load(Bad)),
    %% And in a table's element type.
    ?assertMatch({error, #{class := invalid, kind := unknown_type}},
                 wasm:load(bare_table_module(<<16#63, 1>>))).

%% Subtyping must not reach numeric types. `pop_expect/2' compares by equality
%% first and only falls through to subtyping for what is left, which is why
%% `include/wasm.hrl' can still say value types are compared as immediate words.
numeric_comparison_is_untouched(_Config) ->
    %% An i32 where an i64 is wanted is still a plain mismatch, reported
    %% against the types themselves rather than through any reference rule.
    {error, E} = wasm:load(global_module(<<16#7E>>, <<16#41, 0>>)),
    ?assertMatch(#{class := invalid, kind := type_mismatch,
                   ctx := #{expected := i64, got := i32}}, E).

%%% --------------------------------------------------------- module builder ---

%% (global T (init...))
global_module(TypeBytes, Init) ->
    wasm_asm:module(
      [wasm_asm:section(6, [wasm_asm:uleb(1), TypeBytes, 0, Init, 16#0B])]).

%% (table 1 T (init)) with an initialiser expression, encoded as 0x40 0x00.
table_module(TypeBytes, Init) ->
    InitBytes = case Init of
                    ref_func -> <<16#D2, 0>>;               % ref.func 0
                    ref_null -> <<16#D0, ?FUNCREF>>         % ref.null func
                end,
    wasm_asm:module(
      [wasm_asm:type_section([{[], []}]),
       wasm_asm:func_section([0]),
       wasm_asm:section(4, [wasm_asm:uleb(1), 16#40, 16#00, TypeBytes,
                            wasm_asm:limits(16#00, 1, undefined),
                            InitBytes, 16#0B]),
       %% `ref.func' only names a function the module declared referenceable.
       wasm_asm:section(9, [wasm_asm:uleb(1), wasm_asm:uleb(3), 16#00,
                            wasm_asm:uleb(1), wasm_asm:uleb(0)]),
       wasm_asm:code_section([<<16#0B>>])]).

%% A table with no initialiser at all.
bare_table_module(TypeBytes) ->
    wasm_asm:module(
      [wasm_asm:section(4, [wasm_asm:uleb(1), TypeBytes,
                            wasm_asm:limits(16#00, 1, undefined)])]).

%% ```
%% (func $f (result i32) i32.const 7)
%% (func (export "good") (result i32) ref.func $f  call_ref $t)
%% (func (export "bad")  (result i32) ref.null $t  call_ref $t)
%% ```
call_ref_module() ->
    wasm_asm:module(
      [wasm_asm:type_section([{[], [?I32]}]),
       wasm_asm:func_section([0, 0, 0]),
       wasm_asm:export_section([{~"good", 0, 1}, {~"bad", 0, 2}]),
       wasm_asm:section(9, [wasm_asm:uleb(1), wasm_asm:uleb(3), 16#00,
                            wasm_asm:uleb(1), wasm_asm:uleb(0)]),
       wasm_asm:code_section([<<16#41, 7, 16#0B>>,
                              <<16#D2, 0, 16#14, 0, 16#0B>>,
                              <<16#D0, 0, 16#14, 0, 16#0B>>])]).

%% A function with one non-nullable local, read in three different orders.
local_module(Shape) ->
    Body = case Shape of
               read_before_set -> <<16#20, 1, 16#1A>>;
               set_then_read   -> <<16#20, 0, 16#21, 1, 16#20, 1, 16#1A>>;
               %% Set inside a block, read after it.
               set_inside_block ->
                   <<16#02, 16#40, 16#20, 0, 16#21, 1, 16#0B, 16#20, 1, 16#1A>>
           end,
    %% One parameter and one local, both `(ref extern)'.
    Locals = <<1, 1, 16#64, 16#6F>>,
    Code = <<Locals/binary, Body/binary, 16#0B>>,
    wasm_asm:module(
      [wasm_asm:section(1, [wasm_asm:uleb(1), 16#60, wasm_asm:uleb(1),
                            <<16#64, 16#6F>>, wasm_asm:uleb(0)]),
       wasm_asm:func_section([0]),
       wasm_asm:section(10, [wasm_asm:uleb(1),
                             wasm_asm:uleb(byte_size(Code)), Code])]).
