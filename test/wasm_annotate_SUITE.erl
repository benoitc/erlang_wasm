-module(wasm_annotate_SUITE).
-moduledoc """
The operand-stack heights the validator now hands back.

The validator has always known the stack height at every instruction: the
abstract stack machine cannot work without it. It used to compute it and throw
it away. It is kept now, because a compiler assigning an operand to a slot
rather than to a list needs exactly that number, and recovering it afterwards
means writing the abstract stack machine a second time.

**Comparing against run-time heights would not be enough**, which is why these
cases are structural. Execution never visits an instruction after `br`, never
takes both arms of an `if`, and never enters a function nothing calls, and an
off-by-one in any of those places would survive every run. So: exact heights
asserted on a body small enough to read, invariants asserted over every
function of the real fixtures, and unreachable code asserted explicitly.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("wasm/include/wasm.hrl").
-include_lib("wasm/include/wasm_exec.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([heights_are_exact_on_a_body_small_enough_to_read/1,
         a_frames_body_starts_at_the_frames_own_height/1,
         unreachable_code_is_annotated_too/1,
         both_arms_of_an_if_are_annotated/1,
         real_modules_hold_the_invariants_throughout/1,
         lazily_lowered_functions_inherit_the_annotation/1,
         the_compiler_gets_unfused_ir_whatever_the_instance_asked_for/1,
         revalidating_an_annotated_module_changes_nothing/1,
         an_unvalidated_module_still_instantiates/1]).

all() ->
    [heights_are_exact_on_a_body_small_enough_to_read,
     a_frames_body_starts_at_the_frames_own_height,
     unreachable_code_is_annotated_too,
     both_arms_of_an_if_are_annotated,
     real_modules_hold_the_invariants_throughout,
     lazily_lowered_functions_inherit_the_annotation,
     the_compiler_gets_unfused_ir_whatever_the_instance_asked_for,
     revalidating_an_annotated_module_changes_nothing,
     an_unvalidated_module_still_instantiates].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_) -> ok.

%%% ------------------------------------------------------------- helpers ---

validated(Wat) ->
    {ok, Parsed} = wasm_wat:module(Wat),
    {ok, M} = wasm_validate:module(Parsed),
    M.

%% The annotated body of the Nth defined function, tag removed.
body(M, N) ->
    #func{body = {validated, Ann}} = lists:nth(N, M#module.funcs),
    Ann.

fixture(Parts) ->
    Path = filename:join([wasm_spec_runner:fixtures_dir() | Parts]),
    {ok, Bin} = file:read_file(Path),
    {ok, M} = wasm:compile(Bin),
    M.

%%% --------------------------------------------------------------- cases ---

heights_are_exact_on_a_body_small_enough_to_read(_) ->
    %% `(i32.add (i32.const 1) (i32.const 2))', which is the shortest body
    %% where the height is different at every instruction.
    M = validated(~"""
        (module (func (export "f") (result i32)
          i32.const 1
          i32.const 2
          i32.add))
        """),
    ?assertEqual([{0, {i32_const, 1}},
                  {1, {i32_const, 2}},
                  {2, i32_add}],
                 body(M, 1)),

    %% A block that takes one operand and returns one. The block instruction
    %% itself is entered with the operand on the stack, so its own height is 1
    %% and its base -- what a branch out of it slices back to -- is 0.
    M2 = validated(~"""
        (module (func (export "f") (param i32) (result i32)
          local.get 0
          (block (param i32) (result i32)
            i32.const 7
            i32.add)))
        """),
    ?assertMatch([{0, {local_get, 0}},
                  {1, 0, {block, _, [{1, {i32_const, 7}},
                                     {2, i32_add}]}}],
                 body(M2, 1)).

a_frames_body_starts_at_the_frames_own_height(_) ->
    %% The invariant that ties the two numbers together. A frame's parameters
    %% are popped from the entry height and pushed back on top of the base, so
    %% the first instruction inside sees exactly the height the frame was
    %% entered with. Getting the base wrong breaks this and nothing else would.
    M = validated(~"""
        (module (func (export "f") (param i32 i32) (result i32)
          local.get 0
          local.get 1
          (block (param i32 i32) (result i32)
            i32.add
            (loop (param i32) (result i32)
              i32.const 1
              i32.add))))
        """),
    check_frames(body(M, 1)).

unreachable_code_is_annotated_too(_) ->
    %% Nothing after `br 0' ever runs, so a check that compared annotations
    %% against what execution did would never look here. The validator's stack
    %% is polymorphic in unreachable code and its height stays at the frame's,
    %% which is what the annotation has to record.
    M = validated(~"""
        (module (func (export "f") (result i32)
          (block (result i32)
            i32.const 1
            br 0
            i32.const 2
            i32.add)))
        """),
    [{0, 0, {block, _, Inner}}] = body(M, 1),
    ?assertEqual(4, length(Inner)),
    [_, _, {H1, {i32_const, 2}}, {H2, i32_add}] = Inner,
    %% Both are inside the frame, never below its base.
    ?assert(H1 >= 0),
    ?assert(H2 >= H1),
    check_invariants(body(M, 1)).

both_arms_of_an_if_are_annotated(_) ->
    %% Only one arm runs on any given call, so run-time comparison can only
    %% ever check one of them.
    M = validated(~"""
        (module (func (export "f") (param i32) (result i32)
          local.get 0
          (if (result i32)
            (then i32.const 1 i32.const 2 i32.add)
            (else i32.const 3))))
        """),
    [{0, {local_get, 0}}, {1, 0, {if_, _, Then, Else}}] = body(M, 1),
    ?assertEqual([{0, {i32_const, 1}}, {1, {i32_const, 2}}, {2, i32_add}], Then),
    ?assertEqual([{0, {i32_const, 3}}], Else).

real_modules_hold_the_invariants_throughout(_) ->
    %% Every function of every fixture, including the ones nothing calls. That
    %% is the point: lowering is lazy and execution is selective, so a module
    %% is the only place every body gets looked at.
    Mods = [fixture(["seeds", "fac.wasm"]),
            fixture(["plugin", "plugin.wasm"]),
            fixture(["lang", "qjs.wasm"])],
    [begin
         Funcs = M#module.funcs,
         ?assert(length(Funcs) > 0),
         [begin
              ?assertMatch({validated, _}, F#func.body),
              {validated, Ann} = F#func.body,
              check_invariants(Ann),
              check_frames(Ann)
          end || F <- Funcs]
     end || M <- Mods],
    ok.

lazily_lowered_functions_inherit_the_annotation(_) ->
    %% Above 256 functions a body is lowered on first call rather than at
    %% instantiation, through a path that reads `#func.body' directly. It picks
    %% up whatever shape the module carries, so this is the case that would
    %% have broken silently.
    M = fixture(["lang", "qjs.wasm"]),
    ?assert(length(M#module.funcs) > 256),
    Cfg = #{args => [~"qjs", ~"1"], env => #{}, clocks => [monotonic],
            random => strong,
            stdout => fun(_) -> ok end, stderr => fun(_) -> ok end},
    {ok, I} = wasm:instantiate(M, wasi_preview1:imports(Cfg)),
    %% Deferred bodies are the validated tuple, unchanged, waiting to be
    %% lowered.
    Lazy = [F || F <- tuple_to_list(I#inst.funcs),
                 is_record(F, fn),
                 element(1, F#fn.body) =:= lazy],
    ?assert(length(Lazy) > 256),
    [?assertMatch({lazy, {validated, _}}, F#fn.body) || F <- Lazy],

    %% Lowering one has to strip the annotation, not carry it into the
    %% interpreter, and has to do it at every depth. Sampled across the module
    %% rather than at the front, because the front is where the functions the
    %% start path calls happen to live.
    Sample = [lists:nth(N, Lazy) || N <- [1, 17, 250, length(Lazy) div 2,
                                          length(Lazy)]],
    [begin
         IR = wasm_instance:body_of(F, I),
         ?assert(is_list(IR)),
         no_annotations(IR)
     end || F <- Sample],

    %% And the module still runs, which is the end-to-end form of the same
    %% claim: every body it touches went through that path.
    ?assertMatch({ok, _}, wasm:call(I, ~"_start", [])),
    ok = wasm:destroy(I).

%% The interpreter reads its operands off the stack and would misread an
%% annotation as an instruction. No lowered instruction has a number at its
%% head; every annotated one does.
no_annotations(IR) ->
    [begin
         ?assert(not (is_tuple(I) andalso is_number(element(1, I)))),
         case I of
             {block, _, _, B} -> no_annotations(B);
             {loop, _, _, B} -> no_annotations(B);
             {try_table, _, _, _, B} -> no_annotations(B);
             {if_, _, _, T, E} -> no_annotations(T), no_annotations(E);
             _ -> ok
         end
     end || I <- IR],
    ok.

the_compiler_gets_unfused_ir_whatever_the_instance_asked_for(_) ->
    %% Fusion is on by default and saves the interpreter a dispatch. A compiler
    %% has no dispatch to save, and a superinstruction would only mean a second
    %% spelling of a sequence the generator already handles.
    %%
    %% Two modules, because the two ways a body reaches the compiler are
    %% different code paths: below 256 functions a body is lowered at
    %% instantiation and `#fn.body' is fused IR by then, which cannot be
    %% unfused, so `#fn.raw' is what makes the small case work at all.
    Small = fixture(["plugin", "plugin.wasm"]),
    Big = fixture(["lang", "qjs.wasm"]),
    ?assert(length(Small#module.funcs) =< 256),
    ?assert(length(Big#module.funcs) > 256),
    Cfg = #{args => [~"qjs", ~"1"], env => #{}, clocks => [monotonic],
            random => strong,
            stdout => fun(_) -> ok end, stderr => fun(_) -> ok end},
    [begin
         {ok, I} = wasm:instantiate(M, wasi_preview1:imports(Cfg)),
         Fns = [F || F <- tuple_to_list(I#inst.funcs), is_record(F, fn)],
         [begin
              IR = wasm_instance:compiler_ir(F, I),
              ?assert(is_list(IR)),
              no_annotations(IR),
              ?assertEqual([], fused(IR))
          end || F <- Fns],
         %% And the interpreter still gets what it asked for: reading the
         %% unfused form must not have disturbed the instance's own lowering.
         ?assertNotEqual([], lists:flatten([fused(wasm_instance:body_of(F, I))
                                            || F <- Fns])),
         ok = wasm:destroy(I)
     end || M <- [Small, Big]].

%% Every rule in `wasm_instance:fuse/1'. Named rather than derived so that a new
%% rule the compiler cannot read shows up here instead of passing silently.
fused(L) when is_list(L) -> lists:flatten([fused(I) || I <- L]);
fused({block, _, _, B}) -> fused(B);
fused({loop, _, _, B}) -> fused(B);
fused({try_table, _, _, _, B}) -> fused(B);
fused({if_, _, _, T, E}) -> fused(T) ++ fused(E);
fused(I) ->
    Op = if is_atom(I) -> I; true -> element(1, I) end,
    case lists:member(Op, [lg_const_add_set, lg_const_add_tee, lg_const_add,
                           lg_lg_store, lg_load_tee, lg_load, lg_lg, lg_const,
                           eqz_br_if]) of
        true -> [Op];
        false -> []
    end.

revalidating_an_annotated_module_changes_nothing(_) ->
    %% `wasm:validate/1' is public and a validated module is a legitimate
    %% argument to it. Annotating the annotations would be a slow, silent
    %% corruption.
    M = validated(~"""
        (module (func (export "f") (param i32) (result i32)
          local.get 0
          (block (param i32) (result i32) i32.const 1 i32.add)))
        """),
    {ok, M2} = wasm_validate:module(M),
    ?assertEqual(M, M2),
    {ok, M3} = wasm_validate:module(M2),
    ?assertEqual(M, M3).

an_unvalidated_module_still_instantiates(_) ->
    %% `wasm_wat' builds modules the validator has not seen, and lowering has
    %% to read a raw body without mistaking `{local_get, 1}' for an annotation
    %% pairing height 1 with instruction `local_get'.
    {ok, Parsed} = wasm_wat:module(~"""
        (module (func (export "f") (param i32) (result i32)
          local.get 0
          i32.const 41
          i32.add))
        """),
    ?assertMatch([_ | _], (lists:nth(1, Parsed#module.funcs))#func.body),
    {ok, I} = wasm:instantiate(Parsed, #{}),
    ?assertEqual({ok, [42]}, wasm:call(I, ~"f", [1])),
    ok = wasm:destroy(I).

%%% ---------------------------------------------------------- invariants ---

%% Reachable from any annotated body without knowing what any opcode does,
%% which is deliberate: a checker that re-derived the heights would be the
%% abstract stack machine written a second time, and the two would drift.
check_invariants(Ann) -> check_invariants(Ann, 0).

check_invariants(Ann, Base) ->
    [begin
         {H, Sub} = case I of
                        {Hh, Bb, Inner} ->
                            %% A frame's base is at or below its entry height,
                            %% and at or above the enclosing frame's base.
                            ?assert(is_integer(Bb) andalso Bb >= 0),
                            ?assert(Bb =< Hh),
                            ?assert(Bb >= Base),
                            {Hh, {Bb, Inner}};
                        {Hh, _} -> {Hh, none}
                    end,
         ?assert(is_integer(H) andalso H >= 0),
         %% Nothing is ever entered below the base of the frame it is in. The
         %% validator's polymorphic stack in unreachable code stops at the
         %% frame height rather than going under it.
         ?assert(H >= Base),
         case Sub of
             none -> ok;
             {B2, {block, _, Body}} -> check_invariants(Body, B2);
             {B2, {loop, _, Body}} -> check_invariants(Body, B2);
             {B2, {try_table, _, _, Body}} -> check_invariants(Body, B2);
             {B2, {if_, _, Then, Else}} ->
                 check_invariants(Then, B2),
                 check_invariants(Else, B2)
         end
     end || I <- Ann],
    ok.

%% The first instruction inside a frame is entered at the frame's own entry
%% height. An empty body proves nothing and is skipped rather than faked.
check_frames(Ann) ->
    [begin
         case I of
             {H, _B, {block, _, Body}} -> starts_at(H, Body), check_frames(Body);
             {H, _B, {loop, _, Body}} -> starts_at(H, Body), check_frames(Body);
             {H, _B, {try_table, _, _, Body}} ->
                 starts_at(H, Body), check_frames(Body);
             {H, _B, {if_, _, Then, Else}} ->
                 %% `if' pops its condition before the frame is pushed, so the
                 %% arms start one below the instruction's own height.
                 starts_at(H - 1, Then), starts_at(H - 1, Else),
                 check_frames(Then), check_frames(Else);
             {_H, _} -> ok
         end
     end || I <- Ann],
    ok.

starts_at(_H, []) -> ok;
starts_at(H, [First | _]) ->
    Got = case First of
              {Hh, _, _} -> Hh;
              {Hh, _} -> Hh
          end,
    ?assertEqual(H, Got).


