-module(wasm_validate_code).
-moduledoc """
Function body validation. Read this when a module you believe is well typed is
being rejected.

This is the specification's abstract type-checking algorithm: an operand
stack of value types and a control stack of open blocks, with the operand
stack becoming *polymorphic* after `unreachable` or an unconditional branch.

The polymorphic rule is the part worth stating explicitly, because it is
where validators go wrong in both directions. After `br`, the rest of the
block is statically unreachable and may pop values that are not there:

```
(func (result i32) (unreachable) (i32.add))   ;; valid
```

`i32.add` pops two operands from an empty stack. Rejecting this wrongly
refuses legal modules that every real compiler emits. Conversely, treating
unreachable code as unchecked wrongly accepts modules whose reachable
continuation is ill-typed. The frame's `height` plus its `unreachable` flag
is what distinguishes the two: popping below the height yields `unknown`
(which unifies with anything) rather than either failing or being skipped.

Because the decoder produces a nested AST rather than a flat stream, blocks
recurse here instead of pushing and popping through `end` opcodes. The
typing rules are identical; only the traversal differs.
""".

-include("wasm.hrl").
-include("wasm_validate.hrl").

-export([function/3, const_expr/3, subtype/3]).
%% For the text format, which needs an instruction's natural alignment to
%% supply the default a missing `align=` means. Exported rather than copied:
%% two tables of natural alignments would be two tables to disagree.
-export([load_store/1]).

%%% ----------------------------------------------------------------- api ---

-doc """
Validate one function body against its declared type, and return it annotated.

The validator already knows the operand-stack height at every instruction: it
is `#vs.nopds`, and the abstract stack machine cannot work without it. It used
to be computed and thrown away. It is returned instead, because a compiler that
wants to assign an operand to a slot rather than to a list needs exactly that
number, and recovering it afterwards means writing the abstract stack machine a
second time and keeping the two in step.

Every instruction is paired with the height on entry. The four that contain a
body carry their frame's base as well, because a branch slices the stack back
to the base of the frame it targets, and that is a property of the frame rather
than of any instruction inside it. See `annotate/3` for the two shapes.
""".
-spec function(#ctx{}, #functype{}, #func{}) -> [tuple()].
function(Ctx0, #functype{params = Params, results = Results}, #func{locals = Ls,
                                                                   body = Body0}) ->
    Ctx = Ctx0#ctx{locals = list_to_tuple(Params ++ Ls), results = Results},
    %% Parameters always hold a value; declared locals hold their type's
    %% default, and a type with no default holds nothing until it is assigned.
    Init = maps:from_keys(lists:seq(0, length(Params) - 1), true),
    S0 = #vs{ctx = Ctx, inited = Init},
    S1 = push_ctrl(func, [], Results, S0),
    {Ann, S2} = instrs(strip(Body0), S1),
    {_Frame, S3} = pop_ctrl(S2),
    case S3#vs.nopds of
        0 -> Ann;
        N -> fail(type_mismatch, <<"type mismatch">>,
                  #{reason => operands_remaining, count => N})
    end.

-doc """
An annotated body back to the instructions it was built from.

Validating a module that is already validated has to mean the same thing as
validating it once, and `wasm:validate/1` is public. Stripping first makes
re-validation idempotent instead of annotating the annotations.
""".
-spec strip([tuple() | atom()] | {validated, [tuple()]}) -> [tuple() | atom()].
strip({validated, Ann}) -> unann_all(Ann);
%% A body that was never validated carries no annotation and is already what
%% this returns. Deciding that from the tag rather than from the shape of each
%% instruction is the whole point: `{local_get, 1}` and `{Height, Instr}` are
%% both pairs, and a stripper that guessed turned the first into `1`.
strip(Is) when is_list(Is) -> Is.

unann_all(Is) -> [unann(I) || I <- Is].

unann({_H, _Base, {block, BT, Body}}) -> {block, BT, unann_all(Body)};
unann({_H, _Base, {loop, BT, Body}}) -> {loop, BT, unann_all(Body)};
unann({_H, _Base, {if_, BT, Then, Else}}) ->
    {if_, BT, unann_all(Then), unann_all(Else)};
unann({_H, _Base, {try_table, BT, Cs, Body}}) ->
    {try_table, BT, Cs, unann_all(Body)};
unann({_H, I}) -> I.

%%% ------------------------------------------------- abstract stack machine ---

push_opd(T, #vs{opds = O, nopds = N} = S) -> S#vs{opds = [T | O], nopds = N + 1}.

push_opds(Ts, S) -> lists:foldl(fun push_opd/2, S, Ts).

%% Popping below the current frame's height is an error unless the frame is
%% unreachable, in which case the stack is polymorphic and yields `unknown'.
pop_opd(#vs{ctrls = [#ctrl{height = H, unreachable = U} | _], nopds = N} = S) ->
    if
        N =:= H, U -> {unknown, S};
        N =:= H ->
            fail(type_mismatch, <<"type mismatch">>, #{reason => stack_underflow});
        true ->
            [T | Rest] = S#vs.opds,
            {T, S#vs{opds = Rest, nopds = N - 1}}
    end;
pop_opd(#vs{ctrls = []}) ->
    fail(type_mismatch, <<"type mismatch">>, #{reason => no_control_frame}).

%% `unknown' unifies with any expected type in either direction. That is what
%% lets unreachable code type-check without weakening reachable code.
%%
%% This is the *only* place two value types are compared: every rule reaches it
%% through `pop_expects/2'. The `{T, T}' clause therefore stays first and stays
%% an equality test, so numeric and vector types keep the immediate-word
%% comparison `wasm.hrl' gives them as the reason value types are bare atoms.
%% Only reference types fall past it into subtyping.
pop_expect(Expect, S0) ->
    {Actual, S1} = pop_opd(S0),
    case {Actual, Expect} of
        {unknown, _} -> {Expect, S1};
        {_, unknown} -> {Actual, S1};
        {T, T} -> {T, S1};
        {A, E} ->
            case matches(A, E, S0) of
                true -> {E, S1};
                false -> fail(type_mismatch, <<"type mismatch">>,
                              #{expected => E, got => A})
            end
    end.

-doc """
Whether `A` is usable where `B` is expected.

Exported for the module-level checks in `wasm_validate`, which compare declared
types outside any operand stack.
""".
-spec subtype(valtype(), valtype(), #ctx{}) -> boolean().
subtype(T, T, _Ctx) -> true;
subtype(A, B, Ctx) -> matches(A, B, #vs{ctx = Ctx}).

%% Subtyping. Reached only when the two types are not already identical, so it
%% never runs for i32, i64, f32, f64 or v128.
%%
%% A non-nullable reference is usable wherever its nullable counterpart is, and
%% the heap types form two disjoint hierarchies rooted at `func' and `extern',
%% each with a bottom type that a null reference inhabits.
matches({ref, N1, H1}, {ref, N2, H2}, S) ->
    (N1 =:= N2 orelse N2 =:= null) andalso heap_matches(H1, H2, S);
matches(_, _, _) -> false.

%% The heap type hierarchies. Each is disjoint from the others and bottoms out
%% in a type that only a null reference inhabits.
%%
%%   func   > $t (function types)    > nofunc
%%   extern                          > noextern
%%   exn                             > noexn
%%   any > eq > {i31, struct, array} > none
%%             $t (struct and array types) sit under struct and array
heap_matches(H, H, _S) -> true;
heap_matches(nofunc, H, S) -> is_func_heap(H, S);
heap_matches(noextern, extern, _S) -> true;
heap_matches(noexn, exn, _S) -> true;
heap_matches(none, H, S) -> is_any_heap(H, S);
heap_matches(i31, H, _S) -> H =:= eq orelse H =:= any;
heap_matches(struct, H, _S) -> H =:= eq orelse H =:= any;
heap_matches(array, H, _S) -> H =:= eq orelse H =:= any;
heap_matches(eq, any, _S) -> true;
%% A concrete type sits under whichever abstract type matches its shape.
heap_matches({type, T}, func, S) -> kind_of(T, S) =:= func;
heap_matches({type, T}, struct, S) -> kind_of(T, S) =:= struct;
heap_matches({type, T}, array, S) -> kind_of(T, S) =:= array;
heap_matches({type, T}, H, S) when H =:= eq; H =:= any ->
    lists:member(kind_of(T, S), [struct, array]);
%% Two concrete types relate when they are the same type, or when one declares
%% the other. Identity is canonical: two structurally identical members of one
%% recursive group are *different* types.
heap_matches({type, A}, {type, B}, #vs{ctx = Ctx}) ->
    wasm_types:is_subtype(A, B, Ctx#ctx.types, Ctx#ctx.canon);
heap_matches(_, _, _S) -> false.

is_func_heap(func, _S) -> true;
is_func_heap(nofunc, _S) -> true;
is_func_heap({type, T}, S) -> kind_of(T, S) =:= func;
is_func_heap(_, _S) -> false.

is_any_heap(H, _S) when H =:= any; H =:= eq; H =:= i31;
                        H =:= struct; H =:= array; H =:= none -> true;
is_any_heap({type, T}, S) -> lists:member(kind_of(T, S), [struct, array]);
is_any_heap(_, _S) -> false.

%% Which composite kind a declared type is, for placing it in a hierarchy.
kind_of(T, S) ->
    case type(T, S) of
        #subtype{body = #functype{}} -> func;
        #subtype{body = #structtype{}} -> struct;
        #subtype{body = #arraytype{}} -> array
    end.

pop_expects(Ts, S) ->
    lists:foldl(fun(T, Acc) -> {_, A} = pop_expect(T, Acc), A end,
                S, lists:reverse(Ts)).

push_ctrl(Op, In, Out, #vs{nopds = N, ctrls = Cs, inited = Init} = S) ->
    Frame = #ctrl{opcode = Op, start_types = In, end_types = Out, height = N,
                  inited = Init},
    push_opds(In, S#vs{ctrls = [Frame | Cs]}).

pop_ctrl(#vs{ctrls = [F | Rest]} = S0) ->
    S1 = pop_expects(F#ctrl.end_types, S0),
    case S1#vs.nopds =:= F#ctrl.height of
        %% Assignments made inside the frame do not survive it.
        true -> {F, S1#vs{ctrls = Rest, inited = F#ctrl.inited}};
        false ->
            fail(type_mismatch, <<"type mismatch">>,
                 #{reason => block_stack_height,
                   expected => F#ctrl.height, got => S1#vs.nopds})
    end;
pop_ctrl(#vs{ctrls = []}) ->
    fail(type_mismatch, <<"type mismatch">>, #{reason => no_control_frame}).

%% Discard everything above the frame height and mark the frame polymorphic.
mark_unreachable(#vs{ctrls = [F | Rest], nopds = N, opds = O} = S) ->
    H = F#ctrl.height,
    S#vs{opds = lists:nthtail(N - H, O), nopds = H,
         ctrls = [F#ctrl{unreachable = true} | Rest]}.

%% A branch to depth N targets the Nth enclosing frame. A `loop' branches back
%% to its own start, so its label types are its parameters; every other
%% construct branches forward to its end, so its label types are its results.
label_types(#ctrl{opcode = loop, start_types = Ts}) -> Ts;
label_types(#ctrl{end_types = Ts}) -> Ts.

nth_ctrl(N, #vs{ctrls = Cs}) ->
    case length(Cs) > N of
        true -> lists:nth(N + 1, Cs);
        false -> fail(unknown_label, <<"unknown label">>, #{depth => N})
    end.

%%% ---------------------------------------------------------- instructions ---

%% Validate a sequence and annotate it in the same pass. The height on entry is
%% read before the instruction runs, which is the number a consumer wants: it
%% says where this instruction's operands are, not where it left them.
%% Body-recursive rather than a fold with an accumulator, and no clearing of
%% `#vs.ann` between instructions. Both are for the same reason: this runs once
%% per instruction of every function of every module, 560,000 times on the
%% largest fixture here, and a fold that pairs the list with the state allocates
%% a tuple per step while clearing `ann` copies the whole record. Between them
%% they cost more than the annotation itself.
instrs([], S) -> {[], S};
instrs([I | Is], S0) ->
    H = S0#vs.nopds,
    S1 = instr(I, S0),
    A = annotate(I, H, S1),
    {Rest, S} = instrs(Is, S1),
    {[A | Rest], S}.

%% Two shapes, and the size tells them apart:
%%
%% ```
%%   {Height, Instruction}                 every instruction
%%   {Height, Base, Instruction}           the four that contain a body
%% ```
%%
%% `Height' is the operand-stack height on entry. `Base' is the height the
%% frame slices back to, which for a block is where its parameters start.
%%
%% The four that contain a body come first and are matched on the instruction,
%% not on whether `ann` happens to be set. That is what lets the field be left
%% dirty between instructions: nothing reads it except the clause for the
%% instruction that just wrote it.
annotate({block, BT, _}, H, #vs{ann = {Base, Body}}) ->
    {H, Base, {block, BT, Body}};
annotate({loop, BT, _}, H, #vs{ann = {Base, Body}}) ->
    {H, Base, {loop, BT, Body}};
annotate({if_, BT, _, _}, H, #vs{ann = {Base, Then, Else}}) ->
    {H, Base, {if_, BT, Then, Else}};
annotate({try_table, BT, Cs, _}, H, #vs{ann = {Base, Body}}) ->
    {H, Base, {try_table, BT, Cs, Body}};
annotate(I, H, _S) -> {H, I}.

%% The base of the frame just pushed, which `push_ctrl/4' recorded as the height
%% after the block's parameters were popped and before they were pushed back.
base(#vs{ctrls = [#ctrl{height = H} | _]}) -> H.

%% - control ---------------------------------------------------------------
instr(unreachable, S) -> mark_unreachable(S);
instr(nop, S) -> S;

instr({block, BT, Body}, S0) ->
    {In, Out} = blocktype(BT, S0),
    S1 = pop_expects(In, S0),
    S2 = push_ctrl(block, In, Out, S1),
    {Ann, S3} = instrs(Body, S2),
    {_, S4} = pop_ctrl(S3),
    (push_opds(Out, S4))#vs{ann = {base(S2), Ann}};

instr({loop, BT, Body}, S0) ->
    {In, Out} = blocktype(BT, S0),
    S1 = pop_expects(In, S0),
    S2 = push_ctrl(loop, In, Out, S1),
    {Ann, S3} = instrs(Body, S2),
    {_, S4} = pop_ctrl(S3),
    (push_opds(Out, S4))#vs{ann = {base(S2), Ann}};

instr({if_, BT, Then, Else}, S0) ->
    {In, Out} = blocktype(BT, S0),
    {_, S1} = pop_expect(i32, S0),
    S2 = pop_expects(In, S1),
    %% Both arms are checked against the same signature. A missing `else' is
    %% represented as an empty one, which enforces the specification's rule
    %% that the block's parameters must already match its results.
    S3 = push_ctrl(if_, In, Out, S2),
    {AnnThen, S4} = instrs(Then, S3),
    {F, S5} = pop_ctrl(S4),
    S6 = push_ctrl(else_, F#ctrl.start_types, F#ctrl.end_types, S5),
    {AnnElse, S7} = instrs(Else, S6),
    {_, S8} = pop_ctrl(S7),
    %% Both arms start from the same base, so either frame answers for it.
    (push_opds(Out, S8))#vs{ann = {base(S3), AnnThen, AnnElse}};

%% - exceptions ------------------------------------------------------------
%% `throw' consumes the tag's parameters and never returns, so like `br' it
%% leaves the rest of the block statically unreachable.
instr({throw, TagIdx}, S0) ->
    #functype{params = In} = tag_type(TagIdx, S0),
    mark_unreachable(pop_expects(In, S0));

instr(throw_ref, S0) ->
    {_, S1} = pop_expect(?EXNREF, S0),
    mark_unreachable(S1);

%% A `try_table' is an ordinary block that also names handlers. Each handler
%% branches to a label, so the label's types have to match what the handler
%% delivers: the tag's parameters, plus the exception itself for the `_ref'
%% forms, and just the exception for `catch_all_ref'.
instr({try_table, BT, Catches, Body}, S0) ->
    {In, Out} = blocktype(BT, S0),
    S1 = pop_expects(In, S0),
    %% Handlers branch *out* of the `try_table', so their labels are resolved
    %% in the enclosing scope: checking them after pushing the frame would
    %% shift every label by one.
    lists:foreach(fun(C) -> check_catch(C, S1) end, Catches),
    S2 = push_ctrl(block, In, Out, S1),
    {Ann, S3} = instrs(Body, S2),
    {_, S4} = pop_ctrl(S3),
    (push_opds(Out, S4))#vs{ann = {base(S2), Ann}};

instr({br, N}, S0) ->
    Frame = nth_ctrl(N, S0),
    S1 = pop_expects(label_types(Frame), S0),
    mark_unreachable(S1);

instr({br_if, N}, S0) ->
    Frame = nth_ctrl(N, S0),
    {_, S1} = pop_expect(i32, S0),
    Ts = label_types(Frame),
    S2 = pop_expects(Ts, S1),
    push_opds(Ts, S2);

instr({br_table, Labels, Default}, S0) ->
    {_, S1} = pop_expect(i32, S0),
    DefTs = label_types(nth_ctrl(Default, S1)),
    Arity = length(DefTs),
    %% Every label must agree on arity, and each label's types must be
    %% compatible with the current stack. Each check pops and then *discards
    %% the resulting state*, restoring the stack for the next label.
    %%
    %% Popping and pushing back instead would be wrong in unreachable code.
    %% There the stack is polymorphic and popping yields `unknown' without
    %% actually removing anything, so pushing back would materialise a concrete
    %% type above the frame height, and the next label with a different type
    %% would then see a real mismatch. That rejects this legal module:
    %%
    %% ```
    %% (block (result f64) (block (result f32)
    %%   (unreachable) (br_table 0 1 1 (i32.const 1))) (drop) (f64.const 0))
    %% '''
    %%
    %% Discarding keeps the stack polymorphic across all the labels, which is
    %% what the declarative rule means when it says the label types need only
    %% have a common subtype.
    lists:foreach(
      fun(N) ->
          Ts = label_types(nth_ctrl(N, S1)),
          case length(Ts) =:= Arity of
              true -> ok;
              false -> fail(type_mismatch, <<"type mismatch">>,
                            #{reason => br_table_arity,
                              expected => Arity, got => length(Ts)})
          end,
          _ = pop_expects(Ts, S1),
          ok
      end, Labels),
    S3 = pop_expects(DefTs, S1),
    mark_unreachable(S3);

instr(return, S0) ->
    S1 = pop_expects((S0#vs.ctx)#ctx.results, S0),
    mark_unreachable(S1);

instr({call, F}, S0) ->
    #functype{params = In, results = Out} = func_type(F, S0),
    push_opds(Out, pop_expects(In, S0));

instr({call_indirect, TypeIdx, TableIdx}, S0) ->
    check_indirect_table(TableIdx, S0),
    #functype{params = In, results = Out} = ftype(TypeIdx, S0),
    {_, S1} = pop_expect(table_index_type(TableIdx, S0), S0),
    push_opds(Out, pop_expects(In, S1));

%% A tail call both calls and returns, so it is typed as both. The callee's
%% results must equal the *enclosing function's* results, since they become
%% that function's results without passing through it; and like `return', what
%% follows is unreachable and so leaves the stack polymorphic.
instr({return_call, F}, S0) ->
    #functype{params = In, results = Out} = func_type(F, S0),
    check_tail_results(Out, S0),
    mark_unreachable(pop_expects(In, S0));

instr({return_call_indirect, TypeIdx, TableIdx}, S0) ->
    check_indirect_table(TableIdx, S0),
    #functype{params = In, results = Out} = ftype(TypeIdx, S0),
    check_tail_results(Out, S0),
    {_, S1} = pop_expect(table_index_type(TableIdx, S0), S0),
    mark_unreachable(pop_expects(In, S1));

%% A call through a reference. The callee is a value rather than an index, so
%% the type immediate supplies the signature and the reference must be a
%% subtype of `(ref null $t)'. Null is a trap at run time, not a type error.
instr({call_ref, TypeIdx}, S0) ->
    #functype{params = In, results = Out} = ftype(TypeIdx, S0),
    {_, S1} = pop_expect({ref, null, {type, TypeIdx}}, S0),
    push_opds(Out, pop_expects(In, S1));

instr({return_call_ref, TypeIdx}, S0) ->
    #functype{params = In, results = Out} = ftype(TypeIdx, S0),
    check_tail_results(Out, S0),
    {_, S1} = pop_expect({ref, null, {type, TypeIdx}}, S0),
    mark_unreachable(pop_expects(In, S1));

%% Refines a reference to its non-nullable form, trapping at run time if it is
%% actually null.
instr(ref_as_non_null, S0) ->
    {T, S1} = pop_ref(S0),
    push_opd(non_null(T), S1);

%% `br_on_null' branches when the reference *is* null, so the branch carries
%% the label's types without it, and the fall-through keeps it refined to
%% non-nullable.
instr({br_on_null, N}, S0) ->
    Ts = label_types(nth_ctrl(N, S0)),
    {T, S1} = pop_ref(S0),
    S2 = push_opds(Ts, pop_expects(Ts, S1)),
    push_opd(non_null(T), S2);

%% `br_on_non_null' is the mirror: the branch carries the reference, so the
%% label's last type is what it must fit, and the fall-through has consumed it.
instr({br_on_non_null, N}, S0) ->
    case label_types(nth_ctrl(N, S0)) of
        [] -> fail(type_mismatch, <<"type mismatch">>,
                   #{reason => br_on_non_null_label});
        Ts ->
            {T, S1} = pop_ref(S0),
            Init = lists:droplast(Ts),
            _ = pop_expect(lists:last(Ts), push_opd(non_null(T), S1)),
            push_opds(Init, pop_expects(Init, S1))
    end;

%% - garbage collection ----------------------------------------------------
instr({struct_new, T}, S0) ->
    #structtype{fields = Fs} = struct_type(T, S0),
    push_opd({ref, nonull, {type, T}},
             pop_expects([unpack(F) || F <- Fs], S0));
instr({struct_new_default, T}, S0) ->
    #structtype{fields = Fs} = struct_type(T, S0),
    [defaultable(unpack(F), S0) || F <- Fs],
    push_opd({ref, nonull, {type, T}}, S0);
instr({Op, T, F}, S0) when Op =:= struct_get; Op =:= struct_get_s;
                           Op =:= struct_get_u ->
    Field = struct_field(T, F, S0),
    check_packed(Op, Field, S0),
    {_, S1} = pop_expect({ref, null, {type, T}}, S0),
    push_opd(unpack(Field), S1);
instr({struct_set, T, F}, S0) ->
    Field = #fieldtype{mut = Mut} = struct_field(T, F, S0),
    mutable(Mut, S0),
    {_, S1} = pop_expect(unpack(Field), S0),
    {_, S2} = pop_expect({ref, null, {type, T}}, S1),
    S2;

instr({array_new, T}, S0) ->
    Field = array_field(T, S0),
    {_, S1} = pop_expect(i32, S0),
    {_, S2} = pop_expect(unpack(Field), S1),
    push_opd({ref, nonull, {type, T}}, S2);
instr({array_new_default, T}, S0) ->
    defaultable(unpack(array_field(T, S0)), S0),
    {_, S1} = pop_expect(i32, S0),
    push_opd({ref, nonull, {type, T}}, S1);
instr({array_new_fixed, T, N}, S0) ->
    Elem = unpack(array_field(T, S0)),
    push_opd({ref, nonull, {type, T}},
             pop_expects(lists:duplicate(N, Elem), S0));
instr({Op, T, Seg}, S0) when Op =:= array_new_data; Op =:= array_new_elem ->
    Field = array_field(T, S0),
    check_segment(Op, Seg, S0),
    check_segment_element(Op, Seg, Field, S0),
    push_opd({ref, nonull, {type, T}}, pop_expects([i32, i32], S0));
instr({Op, T}, S0) when Op =:= array_get; Op =:= array_get_s;
                        Op =:= array_get_u ->
    Field = array_field(T, S0),
    check_packed(Op, Field, S0),
    {_, S1} = pop_expect(i32, S0),
    {_, S2} = pop_expect({ref, null, {type, T}}, S1),
    push_opd(unpack(Field), S2);
instr({array_set, T}, S0) ->
    Field = #fieldtype{mut = Mut} = array_field(T, S0),
    mutable(Mut, S0),
    pop_expects([{ref, null, {type, T}}, i32, unpack(Field)], S0);
instr(array_len, S0) ->
    {_, S1} = pop_expect({ref, null, array}, S0),
    push_opd(i32, S1);
instr({array_fill, T}, S0) ->
    Field = #fieldtype{mut = Mut} = array_field(T, S0),
    mutable(Mut, S0),
    pop_expects([{ref, null, {type, T}}, i32, unpack(Field), i32], S0);
instr({array_copy, D, Src}, S0) ->
    Dst = #fieldtype{mut = Mut} = array_field(D, S0),
    mutable(Mut, S0),
    SrcF = array_field(Src, S0),
    check_element_compatible(SrcF, Dst, S0),
    pop_expects([{ref, null, {type, D}}, i32,
                 {ref, null, {type, Src}}, i32, i32], S0);
instr({Op, T, Seg}, S0) when Op =:= array_init_data; Op =:= array_init_elem ->
    #fieldtype{mut = Mut} = Field = array_field(T, S0),
    mutable(Mut, S0),
    check_segment(Op, Seg, S0),
    check_segment_element(Op, Seg, Field, S0),
    pop_expects([{ref, null, {type, T}}, i32, i32, i32], S0);

instr(ref_eq, S0) ->
    pop_expects([{ref, null, eq}, {ref, null, eq}], S0),
    push_opd(i32, pop_expects([{ref, null, eq}, {ref, null, eq}], S0));

%% A cast tests a reference against a heap type. The operand only has to be in
%% the same hierarchy as the target: casting between hierarchies could never
%% succeed, so it is a type error rather than a test that always fails.
instr({ref_test, Target}, S0) ->
    {T, S1} = pop_ref(S0),
    cast_ok(T, Target, S0),
    push_opd(i32, S1);
instr({ref_cast, Target}, S0) ->
    {T, S1} = pop_ref(S0),
    cast_ok(T, Target, S0),
    push_opd(Target, S1);
instr({Op, N, From, To}, S0) when Op =:= br_on_cast; Op =:= br_on_cast_fail ->
    Ts = label_types(nth_ctrl(N, S0)),
    case subtype(To, From, S0#vs.ctx) of
        true -> ok;
        false -> fail(type_mismatch, <<"type mismatch">>,
                      #{reason => cast_target_not_narrower,
                        from => From, to => To})
    end,
    {_, S1} = pop_expect(From, S0),
    %% The branch carries the cast's *result* for `br_on_cast' and its
    %% *remainder* for `br_on_cast_fail', so the two differ only in which type
    %% goes to the label and which continues.
    {Branch, Fall} = case Op of
                         br_on_cast -> {To, diff_type(From, To)};
                         br_on_cast_fail -> {diff_type(From, To), To}
                     end,
    case Ts of
        [] -> fail(type_mismatch, <<"type mismatch">>, #{reason => br_on_cast_label});
        _ ->
            Init = lists:droplast(Ts),
            case subtype(Branch, lists:last(Ts), S0#vs.ctx) of
                true -> ok;
                false -> fail(type_mismatch, <<"type mismatch">>,
                              #{reason => br_on_cast_label,
                                expected => lists:last(Ts), got => Branch})
            end,
            S2 = push_opds(Init, pop_expects(Init, S1)),
            push_opd(Fall, S2)
    end;

instr(any_convert_extern, S0) ->
    {T, S1} = pop_ref(S0),
    push_opd({ref, nullability_of(T), any}, S1);
instr(extern_convert_any, S0) ->
    {T, S1} = pop_ref(S0),
    push_opd({ref, nullability_of(T), extern}, S1);
instr(ref_i31, S0) ->
    {_, S1} = pop_expect(i32, S0),
    push_opd({ref, nonull, i31}, S1);
instr(Op, S0) when Op =:= i31_get_s; Op =:= i31_get_u ->
    {_, S1} = pop_expect({ref, null, i31}, S0),
    push_opd(i32, S1);

%% - parametric ------------------------------------------------------------
instr(drop, S0) ->
    {_, S1} = pop_opd(S0),
    S1;

%% Untyped `select' only works for numeric and vector operands: reference
%% types are excluded because the instruction has no way to keep the reference
%% distinguishable for the garbage collector.
instr({select, undefined}, S0) ->
    {_, S1} = pop_expect(i32, S0),
    {T1, S2} = pop_opd(S1),
    {T2, S3} = pop_opd(S2),
    T = unify_select(T1, T2),
    case T of
        unknown -> push_opd(unknown, S3);
        _ ->
            case is_numeric(T) of
                true -> push_opd(T, S3);
                false -> fail(type_mismatch, <<"type mismatch">>,
                              #{reason => select_reference_operand, got => T})
            end
    end;
instr({select, [T]}, S0) ->
    check_heap_type(T, S0),
    {_, S1} = pop_expect(i32, S0),
    {_, S2} = pop_expect(T, S1),
    {_, S3} = pop_expect(T, S2),
    push_opd(T, S3);
instr({select, Ts}, _S) ->
    fail(invalid_result_arity, <<"invalid result arity">>, #{types => Ts});

%% - variables -------------------------------------------------------------
instr({local_get, I}, S0) ->
    T = local(I, S0),
    check_inited(I, T, S0),
    push_opd(T, S0);
instr({local_set, I}, S0) ->
    {_, S1} = pop_expect(local(I, S0), S0),
    set_inited(I, S1);
instr({local_tee, I}, S0) ->
    T = local(I, S0),
    {_, S1} = pop_expect(T, S0),
    push_opd(T, set_inited(I, S1));
instr({global_get, I}, S0) ->
    #globaltype{valtype = T} = global(I, S0),
    push_opd(T, S0);
instr({global_set, I}, S0) ->
    case global(I, S0) of
        #globaltype{mut = var, valtype = T} ->
            {_, S1} = pop_expect(T, S0),
            S1;
        #globaltype{mut = const} ->
            fail(immutable_global, <<"global is immutable">>, #{index => I})
    end;

%% - references ------------------------------------------------------------
instr(ref_is_null, S0) ->
    {T, S1} = pop_opd(S0),
    case T =:= unknown orelse is_reference_type(T) of
        true -> push_opd(i32, S1);
        false -> fail(type_mismatch, <<"type mismatch">>,
                      #{reason => ref_is_null_operand, got => T})
    end;
%% `ref.null $t' names a type index, which has to exist.
instr({ref_null, {ref, null, {type, Idx}} = T}, S0) ->
    _ = type(Idx, S0),
    push_opd(T, S0);
instr({ref_null, T}, S0) -> push_opd(T, S0);
instr({ref_func, F}, S0) ->
    Ctx = S0#vs.ctx,
    case F < tuple_size(Ctx#ctx.funcs) of
        false -> fail(unknown_func, <<"unknown function">>, #{index => F});
        true -> ok
    end,
    case maps:is_key(F, Ctx#ctx.refs) of
        true ->
            %% A reference to a known function is non-nullable and carries the
            %% function's own type, not the erased `funcref'.
            push_opd({ref, nonull, {type, element(F + 1, Ctx#ctx.funcs)}}, S0);
        false ->
            %% Undeclared functions are deliberately unreferenceable: see the
            %% note on `refs' in wasm_validate.hrl.
            fail(undeclared_function_reference,
                 <<"undeclared function reference">>, #{index => F})
    end;

%% - tables ----------------------------------------------------------------
%% As with memories, a table declared with a 64-bit index type counts its
%% entries in i64, so indices, sizes and lengths all follow the table's own
%% index type rather than being i32 throughout.
instr({table_get, I}, S0) ->
    #tabletype{elemtype = T} = table(I, S0),
    {_, S1} = pop_expect(table_index_type(I, S0), S0),
    push_opd(T, S1);
instr({table_set, I}, S0) ->
    #tabletype{elemtype = T} = table(I, S0),
    {_, S1} = pop_expect(T, S0),
    {_, S2} = pop_expect(table_index_type(I, S0), S1),
    S2;
instr({table_size, I}, S0) ->
    push_opd(table_index_type(I, S0), S0);
instr({table_grow, I}, S0) ->
    #tabletype{elemtype = T} = table(I, S0),
    A = table_index_type(I, S0),
    {_, S1} = pop_expect(A, S0),
    {_, S2} = pop_expect(T, S1),
    push_opd(A, S2);
instr({table_fill, I}, S0) ->
    #tabletype{elemtype = T} = table(I, S0),
    A = table_index_type(I, S0),
    {_, S1} = pop_expect(A, S0),
    {_, S2} = pop_expect(T, S1),
    {_, S3} = pop_expect(A, S2),
    S3;
instr({table_copy, D, Src}, S0) ->
    #tabletype{elemtype = TD} = table(D, S0),
    #tabletype{elemtype = TS} = table(Src, S0),
    case subtype(TS, TD, S0#vs.ctx) of
        true -> ok;
        false -> fail(type_mismatch, <<"type mismatch">>,
                      #{reason => table_copy_elemtype, dst => TD, src => TS})
    end,
    A = table_index_type(D, S0),
    B = table_index_type(Src, S0),
    Len = case {A, B} of {i64, i64} -> i64; _ -> i32 end,
    pop_expects([A, B, Len], S0);
instr({table_init, E, T}, S0) ->
    #tabletype{elemtype = TT} = table(T, S0),
    ET = elem_type(E, S0),
    case subtype(ET, TT, S0#vs.ctx) of
        true -> ok;
        false -> fail(type_mismatch, <<"type mismatch">>,
                      #{reason => table_init_elemtype, table => TT, elem => ET})
    end,
    %% The element segment is indexed in 32 bits whatever the table is.
    pop_expects([table_index_type(T, S0), i32, i32], S0);
instr({elem_drop, E}, S0) ->
    _ = elem_type(E, S0),
    S0;

%% - memory ----------------------------------------------------------------
%% Size, growth and the bulk operations are all expressed in the memory's own
%% index type: a 64-bit memory counts its pages and lengths in i64.
instr({memory_size, M}, S0) ->
    push_opd(addr_type(M, S0), S0);
instr({memory_grow, M}, S0) ->
    A = addr_type(M, S0),
    {_, S1} = pop_expect(A, S0),
    push_opd(A, S1);
instr({memory_fill, M}, S0) ->
    A = addr_type(M, S0),
    pop_expects([A, i32, A], S0);
instr({memory_copy, D, Src}, S0) ->
    A = addr_type(D, S0),
    B = addr_type(Src, S0),
    %% The length is counted in the narrower of the two index types, since it
    %% has to be a valid count in both.
    Len = case {A, B} of {i64, i64} -> i64; _ -> i32 end,
    pop_expects([A, B, Len], S0);
instr({memory_init, D, M}, S0) ->
    A = addr_type(M, S0),
    check_data_index(D, S0),
    %% The data segment is indexed in 32 bits whatever the memory is.
    pop_expects([A, i32, i32], S0);
instr({data_drop, D}, S0) ->
    check_data_index(D, S0),
    S0;

%% - constants -------------------------------------------------------------
instr({i32_const, _}, S) -> push_opd(i32, S);
instr({i64_const, _}, S) -> push_opd(i64, S);
instr({f32_const, _}, S) -> push_opd(f32, S);
instr({f64_const, _}, S) -> push_opd(f64, S);

%% - vectors ---------------------------------------------------------------
%% Types come from `wasm_validate_simd'; what is specific here is that three of
%% the four immediate shapes carry a lane index, and an index naming a lane the
%% shape does not have is invalid rather than malformed.
instr({v128_const, Bytes}, S0) when byte_size(Bytes) =:= 16 ->
    push_opd(v128, S0);
instr({i8x16_shuffle, Lanes}, S0) when byte_size(Lanes) =:= 16 ->
    %% A shuffle selects from the concatenation of both operands, so its lane
    %% indices run to 31 rather than 15.
    [check_lane(L, 32) || <<L:8>> <= Lanes],
    push_opds([v128], pop_expects([v128, v128], S0));
instr({Op, Lane}, S0) when is_atom(Op), is_integer(Lane) ->
    case wasm_validate_simd:lane_op(Op) of
        {Count, In, Out} ->
            check_lane(Lane, Count),
            push_opds(Out, pop_expects(In, S0));
        false -> fail(unknown_operator, <<"unknown operator">>, #{op => Op})
    end;
instr({Op, {Align, Offset, M}, Lane}, S0) when is_atom(Op) ->
    {Dir, Natural, Count} = wasm_validate_simd:lane_mem_op(Op),
    Addr = addr_type(M, S0),
    check_align(Align, Natural),
    check_offset(Offset, Addr),
    check_lane(Lane, Count),
    {_, S1} = pop_expect(v128, S0),
    {_, S2} = pop_expect(Addr, S1),
    case Dir of
        load -> push_opd(v128, S2);
        store -> S2
    end;

%% - loads and stores, ordinary and atomic ---------------------------------
%% Both share the `{Op, MemArg}' shape. The ordinary ones are looked up first
%% because they are the common case and the atomic table's fallthrough parses
%% the instruction's name, which is not something to do per memory access in a
%% module that has no atomics in it.
instr({Op, {Align, Offset, M}}, S0) when is_atom(Op) ->
    case load_store(Op) of
        false -> atomic_instr(Op, Align, Offset, M, S0);
        Shape -> load_store_instr(Shape, Align, Offset, M, S0)
    end;

%% The one instruction in the `0xFE' space that is a bare atom. It names no
%% memory, so it never reaches `atomic_instr/5' above, and it needs no memory to
%% exist: a module with a fence and no memory at all is valid. Takes nothing off
%% the stack and puts nothing back.
%%
%% Missing until a generated module found it. `wasm_decode_atomic' decodes it
%% and `wasm_exec' runs it, so only this clause was absent, and every module
%% carrying a fence was rejected `unknown_operator'. The specification suite
%% cannot catch that: `proposals/threads/atomic.wast' has no `atomic.fence' in
%% it, so the baseline had nothing to fail on.
instr(atomic_fence, S) -> S;

%% - numeric ---------------------------------------------------------------
instr(Op, S0) when is_atom(Op) ->
    case numeric(Op) of
        {In, Out} -> push_opds(Out, pop_expects(In, S0));
        false -> fail(unknown_operator, <<"unknown operator">>, #{op => Op})
    end;
instr(Op, _S) ->
    fail(unknown_operator, <<"unknown operator">>, #{op => Op}).

load_store_instr({load, T, Natural}, Align, Offset, M, S0) ->
    Addr = addr_type(M, S0),
    check_align(Align, Natural),
    check_offset(Offset, Addr),
    {_, S1} = pop_expect(Addr, S0),
    push_opd(T, S1);
load_store_instr({store, T, Natural}, Align, Offset, M, S0) ->
    Addr = addr_type(M, S0),
    check_align(Align, Natural),
    check_offset(Offset, Addr),
    {_, S1} = pop_expect(T, S0),
    {_, S2} = pop_expect(Addr, S1),
    S2.

%% An atomic access declares exactly its natural alignment. For an ordinary
%% load the number is a hint and anything up to natural is allowed; here a
%% different number makes the module invalid, because the guarantee depends on
%% the access not straddling a word.
atomic_instr(Op, Align, Offset, M, S0) ->
    case wasm_validate_atomic:mem_op(Op) of
        {Kind, T, Width} ->
            Addr = addr_type(M, S0),
            check_exact_align(Align, Width),
            check_offset(Offset, Addr),
            atomic_operands(Kind, T, Addr, S0);
        false ->
            fail(unknown_operator, <<"unknown operator">>, #{op => Op})
    end.

atomic_operands(load, T, Addr, S0) ->
    {_, S1} = pop_expect(Addr, S0),
    push_opd(T, S1);
atomic_operands(store, T, Addr, S0) ->
    {_, S1} = pop_expect(T, S0),
    {_, S2} = pop_expect(Addr, S1),
    S2;
atomic_operands({rmw, _}, T, Addr, S0) ->
    {_, S1} = pop_expect(T, S0),
    {_, S2} = pop_expect(Addr, S1),
    push_opd(T, S2);
atomic_operands(cmpxchg, T, Addr, S0) ->
    {_, S1} = pop_expect(T, S0),
    {_, S2} = pop_expect(T, S1),
    {_, S3} = pop_expect(Addr, S2),
    push_opd(T, S3);
%% The timeout is always an i64, whatever width the value being watched is.
atomic_operands(wait, T, Addr, S0) ->
    {_, S1} = pop_expect(i64, S0),
    {_, S2} = pop_expect(T, S1),
    {_, S3} = pop_expect(Addr, S2),
    push_opd(i32, S3);
atomic_operands(notify, _T, Addr, S0) ->
    {_, S1} = pop_expect(i32, S0),
    {_, S2} = pop_expect(Addr, S1),
    push_opd(i32, S2).

check_exact_align(Align, Natural) ->
    case 1 bsl Align =:= Natural of
        true -> ok;
        false -> fail(alignment_must_be_natural,
                      <<"alignment must not be larger than natural">>,
                      #{align => 1 bsl Align, natural => Natural})
    end.

%%% --------------------------------------------------------- context access ---

blocktype(empty, _S) -> {[], []};
blocktype({valtype, T}, S) -> check_heap_type(T, S), {[], [T]};
blocktype({typeidx, I}, S) ->
    #functype{params = In, results = Out} = ftype(I, S),
    {In, Out}.

%% A type index names a declared type, which since garbage collection may be a
%% struct or an array as well as a function.
type(I, #vs{ctx = #ctx{types = Ts}}) ->
    case I < tuple_size(Ts) of
        true -> element(I + 1, Ts);
        false -> fail(unknown_type, <<"unknown type">>, #{index => I})
    end.

%% The same, where only a function type will do: `call_indirect' and friends
%% name a signature, and a struct type there is a validation error rather than
%% something to crash on.
ftype(I, S) ->
    case type(I, S) of
        #subtype{body = #functype{} = F} -> F;
        #subtype{body = Other} ->
            fail(type_mismatch, <<"type mismatch">>,
                 #{reason => expected_function_type, index => I,
                   got => element(1, Other)})
    end.

func_type(F, #vs{ctx = #ctx{funcs = Fs}} = S) ->
    case F < tuple_size(Fs) of
        true -> ftype(element(F + 1, Fs), S);
        false -> fail(unknown_func, <<"unknown function">>, #{index => F})
    end.

table(I, #vs{ctx = #ctx{tables = Ts}}) ->
    case I < tuple_size(Ts) of
        true -> element(I + 1, Ts);
        false -> fail(unknown_table, <<"unknown table">>, #{index => I})
    end.

memory(I, #vs{ctx = #ctx{mems = Ms}}) ->
    case I < tuple_size(Ms) of
        true -> element(I + 1, Ms);
        false -> fail(unknown_memory, <<"unknown memory">>, #{index => I})
    end.

%% The value type used to address a memory: i32, or i64 under memory64.
addr_type(I, S) ->
    #memtype{limits = #limits{index_type = T}} = memory(I, S),
    T.

%% The value type used to index a table: i32, or i64 under memory64.
table_index_type(I, S) ->
    #tabletype{limits = #limits{index_type = T}} = table(I, S),
    T.

global(I, #vs{ctx = #ctx{globals = Gs}}) ->
    case I < tuple_size(Gs) of
        true -> element(I + 1, Gs);
        false -> fail(unknown_global, <<"unknown global">>, #{index => I})
    end.

local(I, #vs{ctx = #ctx{locals = Ls}}) ->
    case I < tuple_size(Ls) of
        true -> element(I + 1, Ls);
        false -> fail(unknown_local, <<"unknown local">>, #{index => I})
    end.

elem_type(I, #vs{ctx = #ctx{elems = Es}}) ->
    case I < tuple_size(Es) of
        true -> element(I + 1, Es);
        false -> fail(unknown_elem, <<"unknown elem segment">>, #{index => I})
    end.

check_data_index(I, #vs{ctx = #ctx{n_datas = N}}) ->
    case I < N of
        true -> ok;
        false -> fail(unknown_data, <<"unknown data segment">>, #{index => I})
    end.

%% The alignment hint is a promise, not a request: a module may under-promise
%% but never claim an access is more aligned than its own width allows.
%% The table must hold functions. Its element type is always a reference type,
%% so only the heap type is in question.
check_indirect_table(TableIdx, S0) ->
    {ref, _, H} = (table(TableIdx, S0))#tabletype.elemtype,
    case is_func_heap(H, S0) of
        true -> ok;
        false -> fail(type_mismatch, <<"type mismatch">>,
                      #{reason => call_indirect_table, got => H})
    end.

%% The callee's results become the caller's, so each must *fit* the caller's
%% declared result: a callee returning `(ref $t)' satisfies a caller declaring
%% `funcref'.
check_tail_results(Out, #vs{ctx = Ctx}) ->
    Results = Ctx#ctx.results,
    Ok = length(Out) =:= length(Results) andalso
        lists:all(fun({A, B}) -> subtype(A, B, Ctx) end,
                  lists:zip(Out, Results)),
    case Ok of
        true -> ok;
        false -> fail(type_mismatch, <<"type mismatch">>,
                      #{reason => tail_call_results, expected => Results,
                        got => Out})
    end.

%% A lane index has to name a lane the shape actually has. The byte itself is
%% well formed, so this is a validation error rather than a decoding one.
check_lane(Lane, Count) when Lane < Count -> ok;
check_lane(Lane, Count) ->
    fail(invalid_lane_index, <<"invalid lane index">>,
         #{lane => Lane, lanes => Count}).

check_align(Align, Natural) when Align =< Natural -> ok;
check_align(Align, Natural) ->
    fail(alignment_too_large,
         <<"alignment must not be larger than natural">>,
         #{align => Align, natural => Natural}).

%% A static offset must be addressable in the memory's own index space, which
%% is what makes this a per-memory check rather than a constant.
check_offset(_Offset, i64) -> ok;
check_offset(Offset, i32) when Offset =< 16#FFFFFFFF -> ok;
check_offset(Offset, i32) ->
    fail(offset_out_of_range, <<"offset out of range">>, #{offset => Offset}).

%%% --------------------------------------------------- constant expressions ---

-doc """
Validate a constant expression and check it yields `Expected`.

Constant expressions are a small pure sublanguage: literals, null and
function references, reads of immutable globals already in scope, and (from
the extended-const proposal, now part of the specification) integer add,
sub and mul.

Two restrictions carry weight. `global.get` may only read an *immutable*
global that is already defined, which is what keeps initialisation order
unobservable and the result deterministic. And `ref.func` may only name a
declared function, so a module cannot fabricate a reference to a function
the embedder never exposed.

The caller controls which globals are in scope by passing a context whose
global space is truncated to the visible prefix, so the same code serves
global initialisers (which see only earlier globals) and segment offsets
(which see all of them).
""".
-spec const_expr([instr()], valtype(), #ctx{}) -> ok.
const_expr(Instrs, Expected, Ctx) ->
    case const_eval(Instrs, [], Ctx) of
        [Expected] -> ok;
        %% Subtyping applies here too: `ref.func $f' has the non-nullable typed
        %% reference `(ref $t)', which is a subtype of the `funcref' an ordinary
        %% element segment declares.
        [Got] ->
            case matches(Got, Expected, #vs{ctx = Ctx}) of
                true -> ok;
                false ->
                    fail(type_mismatch, <<"type mismatch">>,
                         #{expected => Expected, got => Got, in => const_expr})
            end;
        Types -> fail(type_mismatch, <<"type mismatch">>,
                      #{reason => const_expr_arity, got => length(Types)})
    end.

%% A tiny type-only abstract stack: enough for the arithmetic forms without
%% duplicating the full validator.
const_eval([], Stack, _Ctx) ->
    lists:reverse(Stack);
const_eval([I | Rest], Stack, Ctx) ->
    const_eval(Rest, const_step(I, Stack, Ctx), Ctx).

const_step({i32_const, _}, S, _) -> [i32 | S];
const_step({i64_const, _}, S, _) -> [i64 | S];
const_step({f32_const, _}, S, _) -> [f32 | S];
const_step({f64_const, _}, S, _) -> [f64 | S];
const_step({v128_const, _}, S, _) -> [v128 | S];
%% Allocation is permitted in a constant expression: a global may be
%% initialised with a struct or an array.
const_step({struct_new, T}, S, Ctx) ->
    #structtype{fields = Fs} = const_struct(T, Ctx),
    [{ref, nonull, {type, T}} | drop_n(length(Fs), S)];
const_step({struct_new_default, T}, S, Ctx) ->
    _ = const_struct(T, Ctx),
    [{ref, nonull, {type, T}} | S];
const_step({array_new, T}, S, _Ctx) ->
    [{ref, nonull, {type, T}} | drop_n(2, S)];
const_step({array_new_default, T}, S, _Ctx) ->
    [{ref, nonull, {type, T}} | drop_n(1, S)];
const_step({array_new_fixed, T, N}, S, _Ctx) ->
    [{ref, nonull, {type, T}} | drop_n(N, S)];
const_step(ref_i31, S, _Ctx) -> [{ref, nonull, i31} | drop_n(1, S)];
const_step(any_convert_extern, S, _Ctx) -> [{ref, null, any} | drop_n(1, S)];
const_step(extern_convert_any, S, _Ctx) -> [{ref, null, extern} | drop_n(1, S)];
const_step({ref_null, T}, S, _) -> [T | S];
const_step({ref_func, F}, S, #ctx{funcs = Fs, refs = Refs}) ->
    case F < tuple_size(Fs) of
        false -> fail(unknown_func, <<"unknown function">>, #{index => F});
        true ->
            case maps:is_key(F, Refs) of
                true -> [{ref, nonull, {type, element(F + 1, Fs)}} | S];
                false -> fail(undeclared_function_reference,
                              <<"undeclared function reference">>, #{index => F})
            end
    end;
const_step({global_get, I}, S, #ctx{globals = Gs}) ->
    case I < tuple_size(Gs) of
        false ->
            fail(unknown_global, <<"unknown global">>,
                 #{index => I, reason => not_yet_defined});
        true ->
            case element(I + 1, Gs) of
                #globaltype{mut = const, valtype = T} -> [T | S];
                #globaltype{mut = var} ->
                    fail(constant_expression_required,
                         <<"constant expression required">>,
                         #{index => I, reason => mutable_global})
            end
    end;
const_step(Op, S, _) when Op =:= i32_add; Op =:= i32_sub; Op =:= i32_mul ->
    const_binop(i32, Op, S);
const_step(Op, S, _) when Op =:= i64_add; Op =:= i64_sub; Op =:= i64_mul ->
    const_binop(i64, Op, S);
const_step(I, _S, _) ->
    fail(constant_expression_required, <<"constant expression required">>,
         #{instr => I}).

drop_n(0, S) -> S;
drop_n(N, [_ | S]) -> drop_n(N - 1, S);
drop_n(_N, []) -> [].

const_struct(T, #ctx{types = Ts}) when T < tuple_size(Ts) ->
    case (element(T + 1, Ts))#subtype.body of
        #structtype{} = St -> St;
        _ -> fail(type_mismatch, <<"type mismatch">>,
                  #{reason => expected_struct_type, index => T})
    end;
const_struct(T, _Ctx) ->
    fail(unknown_type, <<"unknown type">>, #{index => T}).

const_binop(T, _Op, [T, T | S]) -> [T | S];
const_binop(T, Op, S) ->
    fail(type_mismatch, <<"type mismatch">>,
         #{in => const_expr, op => Op, expected => T, stack => S}).

%%% --------------------------------------------------------------- helpers ---

%% A handler delivers a known list of types to its label, so the label must
%% accept exactly those. The label is resolved against the `try_table' frame
%% itself, which is why this runs after the frame is pushed.
check_catch({Kind, TagIdx, Label}, S) ->
    %% A caught exception is never null, so the `_ref' forms deliver the
    %% non-nullable `(ref exn)'. Subtyping still lets a label declaring
    %% `exnref' accept it.
    Exn = {ref, nonull, exn},
    Delivered =
        case Kind of
            catch_ -> tag_params(TagIdx, S);
            catch_ref -> tag_params(TagIdx, S) ++ [Exn];
            catch_all -> [];
            catch_all_ref -> [Exn]
        end,
    Ts = label_types(nth_ctrl(Label, S)),
    Ok = length(Ts) =:= length(Delivered) andalso
        lists:all(fun({A, B}) -> subtype(A, B, S#vs.ctx) end,
                  lists:zip(Delivered, Ts)),
    case Ok of
        true -> ok;
        false -> fail(type_mismatch, <<"type mismatch">>,
                      #{reason => catch_label, expected => Ts,
                        delivered => Delivered})
    end.

tag_params(TagIdx, S) ->
    #functype{params = In} = tag_type(TagIdx, S),
    In.

tag_type(I, #vs{ctx = #ctx{tags = Ts}} = S) ->
    case I < tuple_size(Ts) of
        true ->
            #tagtype{type = T} = element(I + 1, Ts),
            ftype(T, S);
        false -> fail(unknown_tag, <<"unknown tag">>, #{index => I})
    end.

%% A field's storage type widens to i32 when it is read: `i8' and `i16' exist
%% only in the heap, never on the operand stack.
unpack(#fieldtype{type = i8}) -> i32;
unpack(#fieldtype{type = i16}) -> i32;
unpack(#fieldtype{type = T}) -> T.

%% The signed and unsigned readers exist *because* a field can be packed, so
%% using one on an unpacked field, or the plain reader on a packed one, is an
%% error rather than a harmless redundancy.
check_packed(Op, #fieldtype{type = T}, _S) ->
    Packed = T =:= i8 orelse T =:= i16,
    Signed = lists:member(Op, [struct_get_s, struct_get_u,
                               array_get_s, array_get_u]),
    case Packed =:= Signed of
        true -> ok;
        false -> fail(type_mismatch, <<"type mismatch">>,
                      #{reason => packed_field_access, op => Op, field => T})
    end.

mutable(var, _S) -> ok;
mutable(const, _S) ->
    fail(type_mismatch, <<"type mismatch">>, #{reason => immutable_field}).

%% A type with no default cannot be created by `struct.new_default'.
defaultable({ref, nonull, _} = T, _S) ->
    fail(type_mismatch, <<"type mismatch">>,
         #{reason => non_defaultable_field, type => T});
defaultable(_T, _S) -> ok.

struct_type(T, S) ->
    case type(T, S) of
        #subtype{body = #structtype{} = St} -> St;
        _ -> fail(type_mismatch, <<"type mismatch">>,
                  #{reason => expected_struct_type, index => T})
    end.

struct_field(T, F, S) ->
    #structtype{fields = Fs} = struct_type(T, S),
    case F < length(Fs) of
        true -> lists:nth(F + 1, Fs);
        false -> fail(unknown_field, <<"unknown field">>, #{index => F})
    end.

array_field(T, S) ->
    case type(T, S) of
        #subtype{body = #arraytype{field = F}} -> F;
        _ -> fail(type_mismatch, <<"type mismatch">>,
                  #{reason => expected_array_type, index => T})
    end.

%% Copying between arrays compares *storage* types, not the types they widen
%% to. An `i8' array and an `i16' array both read as i32, so unpacking first
%% would call them compatible when their in-heap widths differ.
check_element_compatible(#fieldtype{type = S}, #fieldtype{type = D}, _St)
  when S =:= i8; S =:= i16; D =:= i8; D =:= i16 ->
    case S =:= D of
        true -> ok;
        false -> fail(type_mismatch, <<"type mismatch">>,
                      #{reason => array_copy_element, src => S, dst => D})
    end;
check_element_compatible(Src, Dst, St) ->
    case subtype(unpack(Src), unpack(Dst), St#vs.ctx) of
        true -> ok;
        false -> fail(type_mismatch, <<"type mismatch">>,
                      #{reason => array_copy_element})
    end.

%% A data segment holds bytes, so it can only initialise a numeric element; an
%% element segment holds references, which must fit the array's element type.
check_segment_element(Op, _Seg, #fieldtype{type = T}, _S)
  when Op =:= array_new_data; Op =:= array_init_data ->
    case T of
        {ref, _, _} -> fail(type_mismatch, <<"type mismatch">>,
                            #{reason => data_segment_into_reference_array});
        _ -> ok
    end;
check_segment_element(_Op, Seg, Field, S) ->
    ET = elem_type(Seg, S),
    case subtype(ET, unpack(Field), S#vs.ctx) of
        true -> ok;
        false -> fail(type_mismatch, <<"type mismatch">>,
                      #{reason => elem_segment_element, elem => ET,
                        field => unpack(Field)})
    end.

check_segment(Op, Seg, S) when Op =:= array_new_data; Op =:= array_init_data ->
    check_data_index(Seg, S);
check_segment(_Op, Seg, S) ->
    _ = elem_type(Seg, S),
    ok.

nullability_of({ref, N, _}) -> N;
nullability_of(_) -> null.

%% In unreachable code the operand is polymorphic and any cast is admissible.
cast_ok(unknown, _To, _S) -> ok;
cast_ok(From, To, S) -> same_hierarchy(From, To, S).

%% A cast may only stay within one hierarchy. Two unrelated struct types are a
%% legitimate cast that fails at run time; a struct type and a function type are
%% a type error, because no value could ever satisfy both.
%%
%% Requiring a subtype relation instead was too strict: it rejected a cast
%% between siblings, which is exactly what `ref.test' is for.
same_hierarchy({ref, _, H1}, {ref, _, H2}, S) ->
    case top_of(H1, S) =:= top_of(H2, S) of
        true -> ok;
        false -> fail(type_mismatch, <<"type mismatch">>,
                      #{reason => cast_between_hierarchies,
                        from => H1, to => H2})
    end.

top_of(H, _S) when H =:= any; H =:= eq; H =:= i31; H =:= struct;
                   H =:= array; H =:= none -> any;
top_of(H, _S) when H =:= func; H =:= nofunc -> func;
top_of(H, _S) when H =:= extern; H =:= noextern -> extern;
top_of(H, _S) when H =:= exn; H =:= noexn -> exn;
top_of({type, T}, S) ->
    case kind_of(T, S) of
        func -> func;
        _ -> any
    end.

%% What is left of a reference type when a cast to `To' fails.
%%
%% A cast to a *non-nullable* type excludes nothing about nullability, so the
%% remainder keeps the source's. A cast to a *nullable* type would have caught
%% null, so the remainder cannot be null.
%% Both arguments are the instruction's own immediates, so neither is ever the
%% polymorphic `unknown' that a popped operand can be.
diff_type({ref, N, H}, {ref, nonull, _}) -> {ref, N, H};
diff_type({ref, _, H}, {ref, null, _}) -> {ref, nonull, H}.

%% A `(ref $t)' inside a block signature or a `select' annotation still has to
%% name a type that exists. The module-level pass in `wasm_validate' cannot see
%% these: they are instruction immediates, not declared types.
check_heap_type({ref, _, {type, Idx}}, S) -> _ = type(Idx, S), ok;
check_heap_type(_, _S) -> ok.

%% A local whose type has a default always holds one. A non-nullable reference
%% does not, so reading it before it is assigned is a validation error rather
%% than something the runtime has to represent.
check_inited(I, {ref, nonull, _}, #vs{inited = Init}) ->
    case maps:is_key(I, Init) of
        true -> ok;
        false -> fail(uninitialized_local, <<"uninitialized local">>,
                      #{index => I})
    end;
check_inited(_I, _T, _S) -> ok.

set_inited(I, #vs{inited = Init} = S) -> S#vs{inited = Init#{I => true}}.

%% Pop any reference type. In unreachable code the stack is polymorphic and
%% yields `unknown', which stays unknown rather than being invented into a
%% concrete reference.
pop_ref(S0) ->
    {T, S1} = pop_opd(S0),
    case T of
        unknown -> {unknown, S1};
        {ref, _, _} -> {T, S1};
        Other -> fail(type_mismatch, <<"type mismatch">>,
                      #{reason => expected_reference, got => Other})
    end.

non_null(unknown) -> unknown;
non_null({ref, _, H}) -> {ref, nonull, H}.

is_reference_type({ref, _, _}) -> true;
is_reference_type(_) -> false.

is_numeric(i32) -> true;
is_numeric(i64) -> true;
is_numeric(f32) -> true;
is_numeric(f64) -> true;
is_numeric(v128) -> true;
is_numeric(_) -> false.

unify_select(unknown, T) -> T;
unify_select(T, unknown) -> T;
unify_select(T, T) -> T;
unify_select(A, B) ->
    fail(type_mismatch, <<"type mismatch">>,
         #{reason => select_operands, left => A, right => B}).

fail(Kind, Msg, Ctx) -> wasm_error:invalid(Kind, Msg, Ctx).

%%% ------------------------------------------------------ opcode signatures ---

-doc "Direction, value type and natural alignment (log2 bytes) of an access.".
-spec load_store(atom()) -> {load | store, atom(), 0..4} | false.
load_store(i32_load)     -> {load, i32, 2};
load_store(i64_load)     -> {load, i64, 3};
load_store(f32_load)     -> {load, f32, 2};
load_store(f64_load)     -> {load, f64, 3};
load_store(i32_load8_s)  -> {load, i32, 0};
load_store(i32_load8_u)  -> {load, i32, 0};
load_store(i32_load16_s) -> {load, i32, 1};
load_store(i32_load16_u) -> {load, i32, 1};
load_store(i64_load8_s)  -> {load, i64, 0};
load_store(i64_load8_u)  -> {load, i64, 0};
load_store(i64_load16_s) -> {load, i64, 1};
load_store(i64_load16_u) -> {load, i64, 1};
load_store(i64_load32_s) -> {load, i64, 2};
load_store(i64_load32_u) -> {load, i64, 2};
load_store(i32_store)    -> {store, i32, 2};
load_store(i64_store)    -> {store, i64, 3};
load_store(f32_store)    -> {store, f32, 2};
load_store(f64_store)    -> {store, f64, 3};
load_store(i32_store8)   -> {store, i32, 0};
load_store(i32_store16)  -> {store, i32, 1};
load_store(i64_store8)   -> {store, i64, 0};
load_store(i64_store16)  -> {store, i64, 1};
load_store(i64_store32)  -> {store, i64, 2};
%% Vector loads and stores. Their natural alignment is the width of the access
%% rather than of the result: `v128.load8_splat' reads one byte.
load_store(Op) ->
    case wasm_validate_simd:mem_op(Op) of
        {Dir, Natural} -> {Dir, v128, Natural};
        false -> false
    end.

%% {ParameterTypes, ResultTypes}. Parameters are listed in source order, so the
%% rightmost is the top of the stack.
numeric(i32_eqz) -> {[i32], [i32]};
numeric(i64_eqz) -> {[i64], [i32]};
numeric(i32_clz) -> {[i32], [i32]};
numeric(i32_ctz) -> {[i32], [i32]};
numeric(i32_popcnt) -> {[i32], [i32]};
numeric(i64_clz) -> {[i64], [i64]};
numeric(i64_ctz) -> {[i64], [i64]};
numeric(i64_popcnt) -> {[i64], [i64]};
numeric(i32_extend8_s) -> {[i32], [i32]};
numeric(i32_extend16_s) -> {[i32], [i32]};
numeric(i64_extend8_s) -> {[i64], [i64]};
numeric(i64_extend16_s) -> {[i64], [i64]};
numeric(i64_extend32_s) -> {[i64], [i64]};
numeric(i32_wrap_i64) -> {[i64], [i32]};
numeric(i64_extend_i32_s) -> {[i32], [i64]};
numeric(i64_extend_i32_u) -> {[i32], [i64]};
numeric(f32_demote_f64) -> {[f64], [f32]};
numeric(f64_promote_f32) -> {[f32], [f64]};
numeric(i32_reinterpret_f32) -> {[f32], [i32]};
numeric(i64_reinterpret_f64) -> {[f64], [i64]};
numeric(f32_reinterpret_i32) -> {[i32], [f32]};
numeric(f64_reinterpret_i64) -> {[i64], [f64]};
%% Truncations, both the trapping and the saturating families. Listed
%% explicitly rather than derived from the name, because the operand width and
%% the result width differ and the name encodes them in opposite positions.
numeric(i32_trunc_f32_s) -> {[f32], [i32]};
numeric(i32_trunc_f32_u) -> {[f32], [i32]};
numeric(i32_trunc_f64_s) -> {[f64], [i32]};
numeric(i32_trunc_f64_u) -> {[f64], [i32]};
numeric(i64_trunc_f32_s) -> {[f32], [i64]};
numeric(i64_trunc_f32_u) -> {[f32], [i64]};
numeric(i64_trunc_f64_s) -> {[f64], [i64]};
numeric(i64_trunc_f64_u) -> {[f64], [i64]};
numeric(i32_trunc_sat_f32_s) -> {[f32], [i32]};
numeric(i32_trunc_sat_f32_u) -> {[f32], [i32]};
numeric(i32_trunc_sat_f64_s) -> {[f64], [i32]};
numeric(i32_trunc_sat_f64_u) -> {[f64], [i32]};
numeric(i64_trunc_sat_f32_s) -> {[f32], [i64]};
numeric(i64_trunc_sat_f32_u) -> {[f32], [i64]};
numeric(i64_trunc_sat_f64_s) -> {[f64], [i64]};
numeric(i64_trunc_sat_f64_u) -> {[f64], [i64]};
numeric(f32_convert_i32_s) -> {[i32], [f32]};
numeric(f32_convert_i32_u) -> {[i32], [f32]};
numeric(f32_convert_i64_s) -> {[i64], [f32]};
numeric(f32_convert_i64_u) -> {[i64], [f32]};
numeric(f64_convert_i32_s) -> {[i32], [f64]};
numeric(f64_convert_i32_u) -> {[i32], [f64]};
numeric(f64_convert_i64_s) -> {[i64], [f64]};
numeric(f64_convert_i64_u) -> {[i64], [f64]};
numeric(Op) ->
    simd_or_false(Op).

simd_or_false(Op) ->
    case wasm_validate_simd:type_of(Op) of
        {_, _} = T -> T;
        false -> numeric_fallback(Op)
    end.

numeric_fallback(Op) ->
    case atom_to_list(Op) of
        "i32_" ++ Rest -> int_op(i32, Rest);
        "i64_" ++ Rest -> int_op(i64, Rest);
        "f32_" ++ Rest -> float_op(f32, Rest);
        "f64_" ++ Rest -> float_op(f64, Rest);
        _ -> false
    end.

%% Comparisons yield i32 regardless of operand width; everything else is
%% width-preserving. Conversions are handled above, before this fallback.
int_op(T, Name) ->
    case classify_int(Name) of
        binop -> {[T, T], [T]};
        relop -> {[T, T], [i32]};
        false -> false
    end.

float_op(T, Name) ->
    case classify_float(T, Name) of
        binop -> {[T, T], [T]};
        unop -> {[T], [T]};
        relop -> {[T, T], [i32]};
        false -> false
    end.

classify_int(N) when N =:= "add"; N =:= "sub"; N =:= "mul";
                     N =:= "div_s"; N =:= "div_u"; N =:= "rem_s"; N =:= "rem_u";
                     N =:= "and"; N =:= "or"; N =:= "xor";
                     N =:= "shl"; N =:= "shr_s"; N =:= "shr_u";
                     N =:= "rotl"; N =:= "rotr" -> binop;
classify_int(N) when N =:= "eq"; N =:= "ne";
                     N =:= "lt_s"; N =:= "lt_u"; N =:= "gt_s"; N =:= "gt_u";
                     N =:= "le_s"; N =:= "le_u"; N =:= "ge_s"; N =:= "ge_u" -> relop;
classify_int(_) -> false.

classify_float(_T, N) when N =:= "add"; N =:= "sub"; N =:= "mul"; N =:= "div";
                           N =:= "min"; N =:= "max"; N =:= "copysign" -> binop;
classify_float(_T, N) when N =:= "abs"; N =:= "neg"; N =:= "ceil"; N =:= "floor";
                           N =:= "trunc"; N =:= "nearest"; N =:= "sqrt" -> unop;
classify_float(_T, N) when N =:= "eq"; N =:= "ne"; N =:= "lt"; N =:= "gt";
                           N =:= "le"; N =:= "ge" -> relop;
classify_float(_T, _) -> false.
