-module(wasm_core).
-moduledoc """
Names and bounds for generated code.

You get here if you turn a WebAssembly function into Core Erlang. Read this
before you generate a name, because a Core function identifier has to be an
atom and the atom table is node-wide and never reclaimed: a name derived from a
module's own bytes is a permanent leak with a remote attacker holding the tap.

`wasm_code_slots` solves that for *module* names by writing sixteen of them out
longhand. Function and frame names cannot be written out longhand, because
QuickJS has 1666 compilable functions, so they are computed instead -- once, at
first use, from a bound that is a literal in this file. The property is the same
one and is what matters: **the set of atoms this module can ever create is
decidable by reading it**, and nothing user-controlled reaches a name.

## The bounds, and where they came from

`bench/paths/subset.erl` reports the shapes a generator is bounded by, over the
Rust plugin and over QuickJS:

| | plugin max | qjs max | qjs p99 |
| --- | ---: | ---: | ---: |
| bound on continuation arity | 20 | 71 | 37 |
| control frames per function | 118 | 1016 | 165 |
| control nesting | 18 | 257 | 30 |
| compilable functions | 150 | 1666 | |

**Arity is not the constraint it looks like.** The worst function in QuickJS
would generate a 71-argument continuation against the BEAM's limit of 255, so
`?MAX_ARITY` costs no coverage at all and exists to refuse the pathological
rather than to shape the common case. The decoder admits a million locals
(`\wasm_decode:expand_locals/1`) and that is what a bound has to survive, not
what it has to accommodate.

**Frame names are bounded by nesting, not by count.** A function with 1016
control frames needs far fewer than 1016 names, because Core `letrec` scoping
puts a sibling frame's name out of scope: names have to be unique only along a
nesting path, which is 257 deep at worst.

A module or function past a bound is not compiled. That is the same answer as
every other refusal here: interpret it.
""".

-export([fun_name/1, frame_name/1, limits/0, atoms/0]).
-export([supported/1, can_compile/2, ops/0, module/4, module/6, forms/5]).

-include("wasm_exec.hrl").
-include("wasm_memory.hrl").

%% Read these as the answer to "how many atoms can this module make", which is
%% `?MAX_FUNS + ?MAX_FRAMES` and nothing else, ever.
-define(MAX_FUNS, 2048).      % qjs has 1666 compilable functions
-define(MAX_FRAMES, 512).     % qjs nests 257 deep at worst
-define(MAX_ARITY, 128).      % qjs would generate 71 at worst; the BEAM allows 255

-define(PT_NAMES, {?MODULE, names}).

-doc """
The name of the Nth function of a compiled unit, counting from zero.

Named by position in the unit rather than by WebAssembly index, so a module that
compiles a hundred of its five thousand functions uses a hundred names.
""".
-spec fun_name(non_neg_integer()) -> atom().
fun_name(N) when N < ?MAX_FUNS ->
    element(N + 1, element(1, names()));
fun_name(_) ->
    erlang:error({limit, too_many_functions}).

-doc "The name of the Nth control frame along one nesting path within a function.".
-spec frame_name(non_neg_integer()) -> atom().
frame_name(N) when N < ?MAX_FRAMES ->
    element(N + 1, element(2, names()));
frame_name(_) ->
    erlang:error({limit, too_deeply_nested}).

-doc "Every bound, so a caller can refuse before it starts rather than part way.".
-spec limits() -> #{atom() => pos_integer()}.
limits() ->
    #{max_funs => ?MAX_FUNS, max_frames => ?MAX_FRAMES, max_arity => ?MAX_ARITY}.

-doc "Every atom this module can create. The whole set, for tests to assert on.".
-spec atoms() -> [atom()].
atoms() ->
    {F, K} = names(),
    tuple_to_list(F) ++ tuple_to_list(K).

%% Tuples rather than lists, so a name is `element/2' and not a walk, and in
%% `persistent_term' rather than the process dictionary because every process
%% that generates code needs the same ones and they never change.
%%
%% Built at most once per node. Two processes racing here both build the pool
%% and one `put' wins; the atoms are the same either way, which is the point of
%% deriving them from a literal.
names() ->
    case persistent_term:get(?PT_NAMES, undefined) of
        undefined ->
            Names = {build("wasm_f_", ?MAX_FUNS), build("wasm_k_", ?MAX_FRAMES)},
            persistent_term:put(?PT_NAMES, Names),
            Names;
        Names ->
            Names
    end.

build(Prefix, N) ->
    list_to_tuple([list_to_atom(Prefix ++ integer_to_list(I))
                   || I <- lists:seq(0, N - 1)]).

%%% ---------------------------------------------------------------- subset ---

%% Every operation the generator emits a call to, and nothing else.
%%
%% Named rather than matched by prefix, because a prefix rule accepts an
%% instruction nobody has implemented and the failure is a wrong answer rather
%% than a refusal. `wasm_core_SUITE' asserts every one of these reaches an
%% implementation in `wasm_exec:op1/2' and `op2/3'.
-define(BINOPS,
        [i32_add, i32_sub, i32_mul, i32_div_s, i32_div_u, i32_rem_s, i32_rem_u,
         i32_and, i32_or, i32_xor, i32_shl, i32_shr_s, i32_shr_u, i32_rotl,
         i32_rotr,
         i64_add, i64_sub, i64_mul, i64_div_s, i64_div_u, i64_rem_s, i64_rem_u,
         i64_and, i64_or, i64_xor, i64_shl, i64_shr_s, i64_shr_u, i64_rotl,
         i64_rotr,
         i32_eq, i32_ne, i32_lt_s, i32_lt_u, i32_gt_s, i32_gt_u, i32_le_s,
         i32_le_u, i32_ge_s, i32_ge_u,
         i64_eq, i64_ne, i64_lt_s, i64_lt_u, i64_gt_s, i64_gt_u, i64_le_s,
         i64_le_u, i64_ge_s, i64_ge_u,
         f32_add, f32_sub, f32_mul, f32_div, f32_min, f32_max, f32_copysign,
         f64_add, f64_sub, f64_mul, f64_div, f64_min, f64_max, f64_copysign,
         f32_eq, f32_ne, f32_lt, f32_gt, f32_le, f32_ge,
         f64_eq, f64_ne, f64_lt, f64_gt, f64_le, f64_ge]).

-define(UNOPS,
        [i32_eqz, i64_eqz,
         i32_clz, i32_ctz, i32_popcnt, i64_clz, i64_ctz, i64_popcnt,
         i32_wrap_i64, i64_extend_i32_s, i64_extend_i32_u,
         i32_extend8_s, i32_extend16_s,
         i64_extend8_s, i64_extend16_s, i64_extend32_s,
         f32_abs, f32_neg, f32_ceil, f32_floor, f32_trunc, f32_nearest,
         f32_sqrt,
         f64_abs, f64_neg, f64_ceil, f64_floor, f64_trunc, f64_nearest,
         f64_sqrt,
         f32_convert_i32_s, f32_convert_i32_u, f32_convert_i64_s,
         f32_convert_i64_u,
         f64_convert_i32_s, f64_convert_i32_u, f64_convert_i64_s,
         f64_convert_i64_u,
         f32_demote_f64, f64_promote_f32,
         i32_trunc_f32_s, i32_trunc_f32_u, i32_trunc_f64_s, i32_trunc_f64_u,
         i64_trunc_f32_s, i64_trunc_f32_u, i64_trunc_f64_s, i64_trunc_f64_u,
         i32_trunc_sat_f32_s, i32_trunc_sat_f32_u, i32_trunc_sat_f64_s,
         i32_trunc_sat_f64_u, i64_trunc_sat_f32_s, i64_trunc_sat_f32_u,
         i64_trunc_sat_f64_s, i64_trunc_sat_f64_u,
         i32_reinterpret_f32, i64_reinterpret_f64,
         f32_reinterpret_i32, f64_reinterpret_i64]).

%% Floats were excluded from this subset on the grounds that
%% `bench/paths/subset.erl' put them under a percentage point of QuickJS
%% coverage. That was a static count of functions, and the time-weighted answer
%% is the opposite: with the boundary made two-way, 95.6% of QuickJS's calls
%% reach compiled code and the run is no faster, because the one function
%% carrying it is refused for `f64_convert_i32_u'. JavaScript numbers are f64.
%% See `test/audit/PERF.md'.
%%
%% They still carry the NaN-payload and symbolic-infinity surface Erlang cannot
%% represent, which is exactly why every one of them routes to `wasm_num_float'
%% through `wasm_exec' rather than being open-coded here. The four that are
%% *total* are the exception and are inlined below.
-define(LOADS,
        [i32_load, i64_load, i32_load8_s, i32_load8_u, i32_load16_s,
         i32_load16_u, i64_load8_s, i64_load8_u, i64_load16_s, i64_load16_u,
         i64_load32_s, i64_load32_u, f32_load, f64_load]).

-define(STORES, [i32_store, i64_store, i32_store8, i32_store16,
                 i64_store8, i64_store16, i64_store32, f32_store, f64_store]).

-define(NULLARY, [nop, drop, select, unreachable, return]).

-doc """
Every operation `wasm_exec:op1/2` and `op2/3` are expected to implement, with
the number of operands it takes.

The arity is answered here rather than guessed by the caller, because guessing
it is how a unary operation gets checked as a binary one and silently passes.
""".
-spec ops() -> [{atom(), 1 | 2}].
ops() -> [{Op, 2} || Op <- ?BINOPS] ++ [{Op, 1} || Op <- ?UNOPS].

-doc """
Whether the generator can emit code for one lowered instruction.

Control instructions carry a body and are answered `true` here; whether their
*contents* are supported is `can_compile/2`'s recursion, not this.
""".
-spec supported(term()) -> boolean().
supported(I) when is_atom(I) ->
    lists:member(I, ?NULLARY) orelse lists:member(I, ?BINOPS)
        orelse lists:member(I, ?UNOPS);
supported({block, _, _, _}) -> true;
supported({loop, _, _, _}) -> true;
supported({if_, _, _, _, _}) -> true;
supported({br, _}) -> true;
supported({br_if, _}) -> true;
supported({br_table, _, _}) -> true;
supported({local_get, _}) -> true;
supported({local_set, _}) -> true;
supported({local_tee, _}) -> true;
supported({i32_const, _}) -> true;
supported({i64_const, _}) -> true;
%% A float constant may be a symbolic infinity or a NaN with a payload, which
%% are an atom and a tuple. `cerl:abstract/1` takes either, so the immediate is
%% a literal whatever shape it has.
supported({f32_const, _}) -> true;
supported({f64_const, _}) -> true;
%% A global that another module can observe is a cell rather than an inline
%% value, and reading one is a different instruction. Out of this subset.
supported({global_get, _}) -> true;
supported({global_set, _}) -> true;
%% `select' carries its optional type annotation, which the interpreter ignores
%% and so does this: the operands are already the right shape.
supported({select, _}) -> true;
%% A direct call. `call_indirect', `return_call' and the rest stay out: they are
%% refused and interpreted, which is not a coverage disaster and is the honest
%% first answer.
supported({call, _}) -> true;
%% Indirect calls resolve and cross at run time. `return_call' and the rest stay
%% out and are interpreted.
supported({call_indirect, _, _}) -> true;
supported({Op, {_Align, _Off, _Mem}}) ->
    lists:member(Op, ?LOADS) orelse lists:member(Op, ?STORES);
%% Bulk memory. The memory64 forms carry a trailing width tag and so are four
%% and five elements wide; matching only the narrow shapes admits the 32-bit
%% memories and refuses memory64 without a word about it, exactly as the
%% load and store clause above does.
%% Vector instructions. `wasm_instance:ir_instr/2` has already sorted them into
%% a handful of shapes, so this is that handful and not the 240 opcodes the
%% proposal lists. They were left out on a static count that put them at a few
%% points of coverage; the time-weighted answer is that one `v128.const` in
%% QuickJS's bytecode interpreter kept 99% of its execution out of compiled
%% code. See `test/audit/PERF.md`.
supported({v128_const, _}) -> true;
supported({i8x16_shuffle, _}) -> true;
supported({simd_unary, _}) -> true;
supported({simd_binary, _}) -> true;
supported({simd_shift, _}) -> true;
supported({simd_splat, _}) -> true;
supported({simd_ternary, _}) -> true;
supported({simd_lane, _, _}) -> true;
supported({simd_replace, _, _}) -> true;
supported({simd_load, _, _, _, _, _}) -> true;
supported({simd_store, _, _, _}) -> true;
supported({simd_load_lane, _, _, _, _, _, _}) -> true;
supported({simd_store_lane, _, _, _, _, _}) -> true;
supported({memory_size, _}) -> true;
supported({memory_grow, _}) -> true;
supported({memory_fill, _}) -> true;
supported({memory_copy, _, _}) -> true;
supported({memory_init, _, _}) -> true;
supported({data_drop, _}) -> true;
supported(_) -> false.

-doc """
Whether a function can be compiled, and what it would cost if so.

Answers a diagnosis rather than a boolean, because a refusal that is expected
and a refusal that is a defect look identical as `false`, and the conformance
suite's force-eligible mode has to tell them apart:

- `{ok, Metadata}` — nothing known to refuse. Generation may still answer
  `{limit, _}`, because a continuation's arity is only known once the
  compile-time operand stack has been walked.
- `{unsupported, Instr}` — outside the subset. Expected, and the common answer.
- `{limit, Reason}` — inside the subset but past a bound. Expected, and rare:
  QuickJS's worst function nests 257 deep against a bound of 512.
""".
-spec can_compile(#fn{}, [term()]) ->
          {ok, map()} | {unsupported, term()} | {limit, atom()}.
can_compile(#fn{nparams = NP, defaults = Defaults}, IR) ->
    #{max_frames := MaxK, max_arity := MaxA} = limits(),
    Locals = NP + length(Defaults),
    case first_unsupported(IR) of
        {value, I} -> {unsupported, I};
        false ->
            Nesting = nesting(IR),
            if
                %% Every continuation carries at least the locals, so this is a
                %% floor on the arity the generator would emit and can be
                %% refused before walking anything.
                Locals > MaxA -> {limit, too_many_locals};
                Nesting >= MaxK -> {limit, too_deeply_nested};
                true ->
                    {ok, #{locals => Locals, nesting => Nesting,
                           shape => shape(IR)}}
            end
    end.

%% What state the generated function has to be handed.
%%
%% `pure' keeps the shape the spike measured at 2.59 ns/iteration: locals are
%% Core variables, the operand stack is gone, and there is nothing to thread.
%% Anything touching memory or a global needs the mutable half of the instance,
%% and `global.set' needs to hand it back and to checkpoint it so that what a
%% trap wrote is still committed.
shape(IR) ->
    case fold(IR, fun(I, Acc) -> max(Acc, touches(I)) end, 0) of
        0 -> pure;
        1 -> reads;
        _ -> writes
    end.

%% Any call at all makes a function stateful. Deciding otherwise means a
%% fixpoint over the call graph to find out whether a callee needs the mutable
%% half, and for real compiler output the answer is almost always yes.
touches({call, _}) -> 2;
touches({call_indirect, _, _}) -> 2;
touches({global_set, _}) -> 2;
touches({global_get, _}) -> 1;
%% The pure vector operations touch nothing; the four that reach memory do.
touches({simd_load, _, _, _, _, _}) -> 1;
touches({simd_store, _, _, _}) -> 2;
touches({simd_load_lane, _, _, _, _, _, _}) -> 2;
touches({simd_store_lane, _, _, _, _, _}) -> 2;
touches({memory_size, _}) -> 1;
%% `grow' and `data.drop' rebind `#mut{}'; the other three trap, and a trap
%% needs the instance to raise against. Either way the function is stateful.
touches({memory_grow, _}) -> 2;
touches({memory_fill, _}) -> 2;
touches({memory_copy, _, _}) -> 2;
touches({memory_init, _, _}) -> 2;
touches({data_drop, _}) -> 2;
touches({Op, {_, _, _}}) ->
    case lists:member(Op, ?STORES) of
        true -> 2;                    % a store traps, so it needs the instance
        false -> case lists:member(Op, ?LOADS) of true -> 1; false -> 0 end
    end;
touches(_) -> 0.

first_unsupported(IR) ->
    fold(IR, fun(I, false) ->
                     case supported(I) of true -> false; false -> {value, I} end;
                (_, Found) -> Found
             end, false).

%% Every instruction of a body including nested ones, left to right, stopping
%% for nothing: an accumulator that has already decided simply ignores the rest.
fold(L, F, Acc0) when is_list(L) -> lists:foldl(fun(I, A) -> fold(I, F, A) end, Acc0, L);
fold({block, _, _, B} = I, F, Acc) -> fold(B, F, F(I, Acc));
fold({loop, _, _, B} = I, F, Acc) -> fold(B, F, F(I, Acc));
fold({try_table, _, _, _, B} = I, F, Acc) -> fold(B, F, F(I, Acc));
fold({if_, _, _, T, E} = I, F, Acc) -> fold(E, F, fold(T, F, F(I, Acc)));
fold(I, F, Acc) -> F(I, Acc).

nesting(L) when is_list(L) -> lists:max([0 | [nesting(I) || I <- L]]);
nesting({block, _, _, B}) -> 1 + nesting(B);
nesting({loop, _, _, B}) -> 1 + nesting(B);
nesting({try_table, _, _, _, B}) -> 1 + nesting(B);
nesting({if_, _, _, T, E}) -> 1 + max(nesting(T), nesting(E));
nesting(_) -> 0.

%%% ------------------------------------------------------------- generation ---
%%
%% The representation, which is the whole reason a compiler is worth building
%% here rather than a faster interpreter loop:
%%
%%   * **Locals are Core variables.** Core is single-assignment, so `local.set'
%%     is a new binding rather than a `setelement/3' on a locals tuple.
%%   * **The operand stack is compile time.** It is a list of Core expressions
%%     during generation and does not exist at run time at all.
%%   * **Control frames are Core functions and a branch is a tail call**, so
%%     `#st.frames', `branch/3' and the control-stack walk have nothing to do.
%%
%% A continuation takes the locals and the frame's results, and nothing else.
%% Operands *below* a frame's base do not need passing: they are Core variables
%% bound in an enclosing scope and Core is lexically scoped, so a branch nested
%% inside can close over them. That is what keeps the arity down to what
%% `bench/paths/subset.erl' measured.

-doc """
Generate and compile one BEAM module for a set of WebAssembly functions.

`Unit` is `[{Pos, Idx, #fn{}, IR}]`, where `Pos` numbers the functions within
this unit and `Idx` is the WebAssembly function index the generated `invoke/5`
dispatches on. Names come from the pools, by `Pos`, so a module compiling a
hundred of five thousand functions uses a hundred names.
""".
-spec module(module(), [{non_neg_integer(), non_neg_integer(), #fn{}, [term()]}],
             #{non_neg_integer() => {non_neg_integer(), non_neg_integer()}},
             #{non_neg_integer() => {non_neg_integer(), non_neg_integer()}}) ->
          {ok, binary()} | {error, term()}.
module(Name, Unit, Sigs, TSigs) -> module(Name, Unit, Sigs, TSigs, full, 0).

-doc """
As `module/4`, choosing how hard the OTP compiler works.

`baseline` skips the SSA optimiser. On QuickJS's 1666 functions that was
**119.9 seconds down to 45.9 for 10% slower code**, which looked like an easy
trade and is not: the same option costs **86% on `bench/cross/loop.wasm`**,
2.51 nanoseconds an iteration against 4.66. Ten percent was what a bytecode
interpreter's dispatch loop happens to lose; tight arithmetic is what the SSA
optimiser is actually for.

So `full` is the default. It is affordable because the two changes that came
after this one made it so: compilation is off the calling process, and it is
sized to the functions that ran rather than the functions that exist, so the 74
seconds is about 8 and nobody waits for it. `baseline` remains for a caller who
would rather have the module sooner.
""".
-spec module(module(), [term()], map(), map(), baseline | full,
             binary() | non_neg_integer()) -> {ok, binary()} | {error, term()}.
module(Name, Unit, Sigs, TSigs, Mode, Stamp) ->
    case forms(Name, Unit, Sigs, TSigs, Stamp) of
        {ok, Core} ->
            case compile:forms(Core, copts(Mode)) of
                {ok, Name, Bin} -> {ok, Bin};
                {error, Es, _Ws} -> {error, {compile, Es}}
            end;
        {error, _} = E -> E
    end.

-doc """
The Core Erlang this unit lowers to, before the OTP compiler sees it.

Use it when you have changed a clause of the generator and want to know what it
produced. `module/6` calls this and then compiles the result, so what you print
here is what runs, and `wasm_jit:dump/1` is the way to reach it from an
instance you already have:

```erlang
{ok, Core} = wasm_core:forms(wasm_code_0, Unit, Sigs, TSigs, 0),
io:format("~s~n", [core_pp:format(Core)]).
```

This exists because the alternative is reading 1,284 lines of `cerl` calls and
imagining the tree. A differential test tells you the generator is wrong; this
tells you how.
""".
-spec forms(module(), [term()], map(), map(),
            binary() | non_neg_integer()) ->
          {ok, cerl:c_module()} | {error, term()}.
forms(Name, Unit, Sigs, TSigs, Stamp) ->
    try
        Shapes = [{Pos, shape_of(IR)} || {Pos, _, _, IR} <- Unit],
        %% What every function needs to know about its siblings, so that a call
        %% to one of them is a local `apply' and a call to anything else is a
        %% crossing back into the interpreter.
        Known = maps:from_list([{Idx, {Pos, maps:get(Pos, maps:from_list(Shapes))}}
                                || {Pos, Idx, _, _} <- Unit]),
        Defs = [{cerl:c_fname(fun_name(Pos), arity(F, S)),
                 function(F, IR, S, {Known, Sigs, TSigs, Name, Stamp})}
                || {{Pos, _Idx, F, IR}, {Pos, S}} <- lists:zip(Unit, Shapes)],
        Invoke = invoke_fn(Unit, maps:from_list(Shapes), Stamp),
        Exports = [cerl:c_fname(invoke, 6)],
        {ok, cerl:c_module(cerl:c_atom(Name), Exports, [], [Invoke | Defs])}
    catch
        throw:{limit, _} = L -> {error, L};
        throw:{unsupported, _} = U -> {error, U}
    end.

%% Only the SSA optimiser is dropped. The three other passes worth turning off
%% (`no_type_opt`, `no_bsm_opt`, `no_postopt`) were measured together and bought
%% a further 3.8 seconds of 45.9, which is not worth giving up whatever they do
%% for.
copts(full) -> [from_core, binary, return_errors];
copts(baseline) -> [from_core, binary, return_errors, no_ssa_opt].

%% The adapter, matching the contract `wasm:invoke_at/6' already calls through
%% (`src/wasm.erl'), so error capture, checkpoint settlement, the heap lease and
%% the budget are untouched by any of this.
shape_of(IR) -> case shape(IR) of pure -> pure; _ -> stateful end.

arity(#fn{nparams = NP}, pure) -> NP;
arity(#fn{nparams = NP}, stateful) -> NP + 3.

invoke_fn(Unit, Shapes, Stamp) ->
    Inst = cerl:c_var('Inst'), Mut = cerl:c_var('Mut'),
    Idx = cerl:c_var('Idx'), Args = cerl:c_var('Args'),
    %% The fifth argument is the caller's call depth, not the limits map it
    %% used to be and ignore. It matters now that the interpreter can re-enter
    %% here part way down a call stack: entering at zero every time would let a
    %% recursion go the whole depth budget deeper at every crossing.
    Depth = cerl:c_var('Depth'),
    Clauses = [invoke_clause(Pos, I, F, maps:get(Pos, Shapes), Inst, Mut, Depth)
               || {Pos, I, F, _} <- Unit]
        ++ [cerl:c_clause([cerl:c_var('_Other')],
                          cerl:c_tuple([cerl:c_atom(error),
                                        cerl:c_atom(not_compiled)]))],
    Body = cerl:c_case(Idx, Clauses),
    %% What this module was built for, checked against what the caller was
    %% promised when it took its call lease.
    %%
    %% This is what makes a slot safe to reuse. A caller reads a slot, decides
    %% which module it means, and only then calls: in that window the slot can
    %% be refilled, and nothing outside the callee can close it, because a lease
    %% is not atomic with the call and `code:soft_purge/1` cannot see a process
    %% that has not entered yet. Comparing here is atomic with the call by
    %% construction, and a mismatch means the caller interprets.
    %%
    %% The stamp is the module's **content hash** where it has one, and the slot
    %% generation otherwise. A hash is what the check actually wants to say --
    %% "am I the code for the module you meant" -- and it is stable across
    %% loads, which is what lets a compiled artifact be cached and reused. The
    %% generation is the fallback for a module built from text, whose identity is
    %% a `reference()` and so not expressible as a literal; those are never
    %% cached, so nothing is lost.
    %% Compared rather than matched. A stamp may be a binary, and
    %% `cerl:abstract/1` gives a *constructed* binary, which is not a pattern:
    %% matching on one makes the whole module fail to compile, and it did, on
    %% every module with a content hash. `=:=` works for a binary and an integer
    %% alike.
    Want = cerl:c_var('Stamp'),
    Checked =
        cerl:c_case(bif('=:=', [Want, cerl:abstract(Stamp)]),
                    [cerl:c_clause([cerl:abstract(true)], Body),
                     cerl:c_clause([cerl:c_var('_Other')],
                                   cerl:c_tuple([cerl:c_atom(error),
                                                 cerl:c_atom(stale)]))]),
    {cerl:c_fname(invoke, 6),
     cerl:c_fun([Inst, Mut, Idx, Args, Depth, Want], Checked)}.

invoke_clause(Pos, Idx, #fn{nparams = NP} = F, Shape, Inst, Mut, Depth) ->
    Vs = [cerl:c_var(N) || N <- lists:seq(1, NP)],
    Name = cerl:c_fname(fun_name(Pos), arity(F, Shape)),
    Body =
        case Shape of
            pure ->
                cerl:c_tuple([cerl:c_atom(ok), cerl:c_apply(Name, Vs), Mut]);
            stateful ->
                R = cerl:c_var('R'), M1 = cerl:c_var('M1'),
                cerl:c_case(cerl:c_apply(Name, [Inst, Mut, Depth | Vs]),
                            [cerl:c_clause([cerl:c_tuple([R, M1])],
                                           cerl:c_tuple([cerl:c_atom(ok), R, M1]))])
        end,
    %% `Args' is a list, so it is taken apart by matching rather than by
    %% `lists:nth/2': one pattern, no walking, and a wrong arity cannot match.
    Bind = cerl:c_case(cerl:c_var('Args'),
                       [cerl:c_clause([list_pat(Vs)], Body)]),
    cerl:c_clause([cerl:abstract(Idx)], Bind).

list_pat([]) -> cerl:c_nil();
list_pat([V | Vs]) -> cerl:c_cons(V, list_pat(Vs)).

%%% -------------------------------------------------------- function bodies ---

%% Generation state, threaded rather than kept in the process dictionary so
%% that a nested body cannot leak a counter into its sibling.
%%
%%   env    local index -> Core expression. A `local.set' rebinds here.
%%   stack  the compile-time operand stack, top first.
%%   frames branch targets, innermost first: `{FName, NArgs}'.
%%   depth  how deep the frames nest, which is what names a continuation.
%%   n      the next Core variable number. Variables are integers, so no atom
%%          is created for one; only *function* identifiers have to be atoms.
%%   inst   the `#inst{}' Core variable, for the checkpoint a `global.set' takes
%%   mut    the current `#mut{}' Core expression, or `undefined' when the
%%          function is pure. A `global.set' rebinds it, because Core is
%%          single-assignment, and a continuation therefore has to carry it the
%%          way it carries the locals.
%%   d      the call-depth Core variable. Threaded *in* and never out: it is
%%          restored by returning, so a callee cannot leak its depth back.
%%   unit   wasm function index -> {Position, pure | stateful} for every
%%          function compiled alongside this one, which is what makes a
%%          compiled-to-compiled call a local call rather than a crossing.
%%   sigs   wasm function index -> {NParams, NResults} for *every* function of
%%          the instance, compiled or not: a call has to know how many operands
%%          to take and how many to put back whichever side it lands on.
%%   tsigs  type index -> {NParams, NResults}. An indirect call is typed by the
%%          *type* it names rather than by any function, since which function it
%%          reaches is not known until it runs.
-record(g, {env = #{}, stack = [], frames = [], depth = 0, n = 0,
            nlocals = 0, nres = 0, inst, mut, d, unit = #{}, sigs = #{},
            tsigs = #{}, mod, gen = 0}).

%% Two shapes, not three. `pure' keeps what the spike measured -- locals as Core
%% variables, nothing threaded, a loop that carries no state. Anything touching
%% memory or a global is handed the instance and the mutable half and hands the
%% latter back, which reading alone does not need but is free to do and saves a
%% third calling convention.
function(#fn{nparams = NP, nresults = NRes, defaults = Defaults}, IR, Shape,
         {Unit, Sigs, TSigs, Mod, Stamp}) ->
    NLocals = NP + length(Defaults),
    {Extra, Inst, Mut, D, N0} =
        case Shape of
            pure -> {[], undefined, undefined, undefined, NP};
            stateful ->
                I = cerl:c_var(NP), M = cerl:c_var(NP + 1),
                Dv = cerl:c_var(NP + 2),
                {[I, M, Dv], I, M, Dv, NP + 3}
        end,
    Params = [cerl:c_var(N) || N <- lists:seq(0, NP - 1)],
    %% Declared locals start at their type's default; for this subset that is
    %% always the integer zero.
    Env = maps:from_list(
            lists:zip(lists:seq(0, NLocals - 1),
                      Params ++ [cerl:abstract(V) || V <- Defaults])),
    %% Core variable names are atoms or integers and nothing else -- a tuple
    %% name crashes `sys_core_fold'. Integers, so no atom is created for a
    %% variable; only *function* identifiers have to be atoms, which is what the
    %% pools in this module exist for.
    G = #g{env = Env, nlocals = NLocals, nres = NRes, n = N0,
           inst = Inst, mut = Mut, d = D, unit = Unit, sigs = Sigs,
           tsigs = TSigs, mod = Mod, gen = Stamp},
    %% Parameters arrive in the interpreter's representation, which holds
    %% integers *signed*, and `wasm_exec:op1/2' and `op2/3' expect exactly that.
    %%
    %% Establishing a range on entry so the SSA type pass can drop the JIT's
    %% type and overflow checks is a real opportunity and is not done here. The
    %% first attempt masked each parameter with `band', which destroys the sign
    %% and made `i32.div_s(-10, 3)' answer 1431655762. Doing it correctly needs
    %% the parameter's declared width, which this generator does not carry, and
    %% it is worth its own change with its own measurement rather than a line
    %% smuggled into this one.
    cerl:c_fun(Extra ++ Params, seq(IR, G, return)).

seq([], G, Exit) -> go(Exit, G);
seq([I | Rest], G, Exit) -> instr(I, Rest, G, Exit).

%% Leaving a frame, or the function. `return' takes the function's results off
%% the stack and makes them a list, which is the one place results are built.
go(return, #g{stack = S, nres = NRes, mut = undefined}) ->
    cerl:make_list(lists:reverse(lists:sublist(S, NRes)));
go(return, #g{stack = S, nres = NRes, mut = Mut}) ->
    cerl:c_tuple([cerl:make_list(lists:reverse(lists:sublist(S, NRes))), Mut]);
go({K, NArgs}, #g{stack = S} = G) ->
    cerl:c_apply(K, carried(G) ++ lists:reverse(lists:sublist(S, NArgs))).

%% What every continuation takes: the locals, and the mutable state when there
%% is any. Both change as a body runs, which is exactly why they are parameters
%% where an operand below the frame's base is closed over instead.
carried(#g{mut = undefined} = G) -> locals(G);
carried(#g{mut = Mut, d = D} = G) -> locals(G) ++ [Mut, D].

locals(#g{env = Env, nlocals = N}) -> [maps:get(I, Env) || I <- lists:seq(0, N - 1)].

%% A fresh Core variable. Integers, so nothing is interned.
var(#g{n = N} = G) -> {cerl:c_var(N), G#g{n = N + 1}}.

%% A continuation takes the locals and the frame's results, and closes over
%% everything else. Its name comes from the nesting depth, because `letrec'
%% scoping puts a sibling's name out of scope and only a nesting path has to be
%% unique.
frame(NRes, #g{depth = Depth, nlocals = NL, n = N0, mut = Mut} = G) ->
    NCarried = case Mut of undefined -> NL; _ -> NL + 2 end,
    Total = NCarried + NRes,
    Name = cerl:c_fname(frame_name(Depth), Total),
    Vars = [cerl:c_var(N) || N <- lists:seq(N0, N0 + Total - 1)],
    Env = maps:from_list(lists:zip(lists:seq(0, NL - 1),
                                   lists:sublist(Vars, NL))),
    {NewMut, NewD} =
        case Mut of
            undefined -> {undefined, undefined};
            _ -> {lists:nth(NL + 1, Vars), lists:nth(NL + 2, Vars)}
        end,
    {Name, Vars, Env, NewMut, NewD, lists:nthtail(NCarried, Vars),
     G#g{n = N0 + Total}}.

%%% -------------------------------------------------------------- control ---

instr({block, NPar, NRes, Body}, Rest, G, Exit) ->
    {K, KVars, KEnv, KMut, KD, KRes, G1} = frame(NRes, G),
    {Top, Below} = split_stack(NPar, G#g.stack),
    Cont = cerl:c_fun(KVars,
                      seq(Rest, G1#g{env = KEnv, mut = KMut, d = KD,
                                     stack = lists:reverse(KRes) ++ Below},
                          Exit)),
    Inner = G1#g{stack = Top, frames = [{K, NRes} | G#g.frames],
                 depth = G#g.depth + 1},
    cerl:c_letrec([{K, Cont}], seq(Body, Inner, {K, NRes}));

%% Branching to a loop label means the top of the loop, so the loop's own frame
%% takes its *parameters* where a block's takes its results, and falling off the
%% end goes to the continuation instead.
instr({loop, NPar, NRes, Body}, Rest, G, Exit) ->
    {K, KVars, KEnv, KMut, KD, KRes, G1} = frame(NRes, G),
    {Top, Below} = split_stack(NPar, G#g.stack),
    Cont = cerl:c_fun(KVars,
                      seq(Rest, G1#g{env = KEnv, mut = KMut, d = KD,
                                     stack = lists:reverse(KRes) ++ Below},
                          Exit)),
    G2 = G1#g{depth = G#g.depth + 1},
    {Lp, LpVars, LpEnv, LpMut, LpD, LpPar, G3} = frame(NPar, G2),
    Inner = G3#g{env = LpEnv, mut = LpMut, d = LpD,
                 stack = lists:reverse(LpPar),
                 frames = [{Lp, NPar} | G#g.frames],
                 depth = G2#g.depth + 1},
    Loop = cerl:c_fun(LpVars, seq(Body, Inner, {K, NRes})),
    cerl:c_letrec(
      [{K, Cont}],
      cerl:c_letrec([{Lp, Loop}],
                    cerl:c_apply(Lp, carried(G) ++ lists:reverse(Top))));

instr({if_, NPar, NRes, Then, Else}, Rest, G0, Exit) ->
    {C, G} = pop(G0),
    {K, KVars, KEnv, KMut, KD, KRes, G1} = frame(NRes, G),
    {Top, Below} = split_stack(NPar, G#g.stack),
    Cont = cerl:c_fun(KVars,
                      seq(Rest, G1#g{env = KEnv, mut = KMut, d = KD,
                                     stack = lists:reverse(KRes) ++ Below},
                          Exit)),
    Inner = G1#g{stack = Top, frames = [{K, NRes} | G#g.frames],
                 depth = G#g.depth + 1},
    Arm = fun(Body) -> seq(Body, Inner, {K, NRes}) end,
    cerl:c_letrec([{K, Cont}],
                  cerl:c_case(C, [cerl:c_clause([cerl:abstract(0)], Arm(Else)),
                                  cerl:c_clause([cerl:c_var('_C')], Arm(Then))]));

%% Everything after a branch is unreachable, which is why `Rest' is dropped.
instr({br, N}, _Rest, G, _Exit) ->
    go(target(N, G), G);

instr({br_if, N}, Rest, G0, Exit) ->
    {C, G} = pop(G0),
    Taken = go(target(N, G), G),
    cerl:c_case(C, [cerl:c_clause([cerl:abstract(0)], seq(Rest, G, Exit)),
                    cerl:c_clause([cerl:c_var('_C')], Taken)]);

instr({br_table, Labels, Default}, _Rest, G0, _Exit) ->
    {I, G} = pop(G0),
    Ls = tuple_to_list(Labels),
    Clauses = [cerl:c_clause([cerl:abstract(N)], go(target(L, G), G))
               || {N, L} <- lists:enumerate(0, Ls)]
        ++ [cerl:c_clause([cerl:c_var('_I')], go(target(Default, G), G))],
    %% An index is unsigned; a negative one takes the default, which is what a
    %% match against the non-negative literals does for free.
    cerl:c_case(I, Clauses);

instr(return, _Rest, G, _Exit) ->
    go(return, G);

instr(unreachable, _Rest, _G, _Exit) ->
    cerl:c_call(cerl:c_atom(wasm_error), cerl:c_atom(trap),
                [cerl:c_atom(unreachable)]);

instr(nop, Rest, G, Exit) ->
    seq(Rest, G, Exit);

%%% ------------------------------------------------------ values and locals ---

instr(drop, Rest, G0, Exit) ->
    {_, G} = pop(G0),
    seq(Rest, G, Exit);

instr({select, _}, Rest, G0, Exit) ->
    {C, G1} = pop(G0), {B, G2} = pop(G1), {A, G3} = pop(G2),
    {V, G4} = var(G3),
    cerl:c_let([V], cerl:c_case(C, [cerl:c_clause([cerl:abstract(0)], B),
                                    cerl:c_clause([cerl:c_var('_C')], A)]),
               seq(Rest, push(V, G4), Exit));

instr({local_get, I}, Rest, #g{env = Env} = G, Exit) ->
    seq(Rest, push(maps:get(I, Env), G), Exit);
instr({local_set, I}, Rest, G0, Exit) ->
    {V, G} = pop(G0),
    seq(Rest, G#g{env = (G#g.env)#{I => V}}, Exit);
instr({local_tee, I}, Rest, #g{stack = [V | _]} = G, Exit) ->
    seq(Rest, G#g{env = (G#g.env)#{I => V}}, Exit);
instr({i32_const, C}, Rest, G, Exit) ->
    seq(Rest, push(cerl:abstract(C), G), Exit);
instr({i64_const, C}, Rest, G, Exit) ->
    seq(Rest, push(cerl:abstract(C), G), Exit);
instr({f32_const, C}, Rest, G, Exit) ->
    seq(Rest, push(cerl:abstract(C), G), Exit);
instr({f64_const, C}, Rest, G, Exit) ->
    seq(Rest, push(cerl:abstract(C), G), Exit);

%%% --------------------------------------------------- memory and globals ---
%%
%% A 32-bit memory lowers to `{Op, {Align, Offset, M}}' and a 64-bit one to a
%% four-element argument, so `supported/1' matching the three-element shape
%% admits exactly the 32-bit memories and refuses memory64 without a word about
%% it. A store writes into `atomics' in place and does not change `#mut{}',
%% which is why only `global.set' rebinds it.

instr({Op, {_Align, Offset, M}}, Rest, G0, Exit) when is_atom(Op), is_integer(Offset) ->
    case lists:member(Op, ?LOADS) of
        true ->
            {Base, G1} = pop(G0),
            {V, G2} = var(G1),
            {load, N, Kind} = wasm_exec:load_spec(Op),
            cerl:c_let([V], access(load, G0#g.mut, M, N, Kind,
                                   address(Base, Offset), undefined),
                       seq(Rest, push(V, G2), Exit));
        false ->
            true = lists:member(Op, ?STORES) orelse throw({unsupported, Op}),
            {Val, G1} = pop(G0), {Base, G2} = pop(G1),
            {store, N, Kind} = wasm_exec:store_spec(Op),
            cerl:c_seq(access(store, G0#g.mut, M, N, Kind,
                              address(Base, Offset), Val),
                       seq(Rest, G2, Exit))
    end;

%%% ------------------------------------------------------------------ simd ---
%%
%% One clause per shape, each the operand shuffle and the same `wasm_simd` call
%% the interpreter makes. The pure ones reach `wasm_simd` directly, because that
%% is where the single implementation lives and a hop through `wasm_exec` would
%% only add a call; the four that touch memory go through `wasm_exec` so that
%% the address width and the bounds check have one definition.

instr({v128_const, Bytes}, Rest, G, Exit) ->
    seq(Rest, push(cerl:abstract(Bytes), G), Exit);

instr({i8x16_shuffle, Lanes}, Rest, G0, Exit) ->
    {B, G1} = pop(G0), {A, G2} = pop(G1),
    simd(shuffle, [cerl:abstract(Lanes), A, B], Rest, G2, Exit);

instr({simd_unary, Op}, Rest, G0, Exit) ->
    {A, G1} = pop(G0),
    simd(unary, [cerl:c_atom(Op), A], Rest, G1, Exit);

instr({simd_binary, Op}, Rest, G0, Exit) ->
    {B, G1} = pop(G0), {A, G2} = pop(G1),
    simd(binary_op, [cerl:c_atom(Op), A, B], Rest, G2, Exit);

instr({simd_shift, Op}, Rest, G0, Exit) ->
    {N, G1} = pop(G0), {A, G2} = pop(G1),
    simd(shift, [cerl:c_atom(Op), A, N], Rest, G2, Exit);

instr({simd_splat, Op}, Rest, G0, Exit) ->
    {X, G1} = pop(G0),
    simd(splat, [cerl:c_atom(Op), X], Rest, G1, Exit);

instr({simd_ternary, Op}, Rest, G0, Exit) ->
    {C, G1} = pop(G0), {B, G2} = pop(G1), {A, G3} = pop(G2),
    simd(ternary, [cerl:c_atom(Op), A, B, C], Rest, G3, Exit);

instr({simd_lane, Op, Lane}, Rest, G0, Exit) ->
    {V, G1} = pop(G0),
    simd(extract, [cerl:c_atom(Op), cerl:abstract(Lane), V], Rest, G1, Exit);

instr({simd_replace, Op, Lane}, Rest, G0, Exit) ->
    {X, G1} = pop(G0), {V, G2} = pop(G1),
    simd(replace, [cerl:c_atom(Op), cerl:abstract(Lane), V, X], Rest, G2, Exit);

instr({simd_load, Op, Offset, M, W, N}, Rest, G0, Exit) ->
    {Base, G1} = pop(G0),
    {V, G2} = var(G1),
    cerl:c_let([V], call_op(simd_load_at,
                            [G0#g.mut, cerl:abstract(M), cerl:c_atom(Op),
                             cerl:abstract(Offset), cerl:abstract(W),
                             cerl:abstract(N), Base]),
               seq(Rest, push(V, G2), Exit));

instr({simd_store, Offset, M, W}, Rest, G0, Exit) ->
    {V, G1} = pop(G0), {Base, G2} = pop(G1),
    cerl:c_seq(call_op(simd_store_at,
                       [G0#g.mut, cerl:abstract(M), cerl:abstract(Offset),
                        cerl:abstract(W), Base, V]),
               seq(Rest, G2, Exit));

instr({simd_load_lane, Op, Offset, M, W, N, Lane}, Rest, G0, Exit) ->
    {V, G1} = pop(G0), {Base, G2} = pop(G1),
    {R, G3} = var(G2),
    cerl:c_let([R], call_op(simd_load_lane_at,
                            [G0#g.mut, cerl:abstract(M), cerl:c_atom(Op),
                             cerl:abstract(Offset), cerl:abstract(W),
                             cerl:abstract(N), cerl:abstract(Lane), Base, V]),
               seq(Rest, push(R, G3), Exit));

instr({simd_store_lane, Op, Offset, M, W, Lane}, Rest, G0, Exit) ->
    {V, G1} = pop(G0), {Base, G2} = pop(G1),
    cerl:c_seq(call_op(simd_store_lane_at,
                       [G0#g.mut, cerl:abstract(M), cerl:c_atom(Op),
                        cerl:abstract(Offset), cerl:abstract(W),
                        cerl:abstract(Lane), Base, V]),
               seq(Rest, G2, Exit));

%% Bulk memory. Each is the operand shuffle and a call to the helper the
%% interpreter's own clause calls, so a bound or a width cannot be restated
%% differently here. The two that change `#mut{}' rebind it; the three that
%% write into `atomics' in place do not.

instr({memory_size, M}, Rest, G0, Exit) ->
    {V, G} = var(G0),
    cerl:c_let([V], call_op(memory_size_at, [G0#g.mut, cerl:abstract(M)]),
               seq(Rest, push(V, G), Exit));

instr({memory_grow, M}, Rest, G0, Exit) ->
    {Delta, G1} = pop(G0),
    {Old, G2} = var(G1),
    {M1, G3} = var(G2),
    cerl:c_case(call_op(memory_grow_at,
                        [G0#g.inst, G0#g.mut, cerl:abstract(M), Delta,
                         cerl:abstract(32)]),
                [cerl:c_clause([cerl:c_tuple([Old, M1])],
                               seq(Rest, push(Old, G3#g{mut = M1}), Exit))]);

instr({memory_fill, M}, Rest, G0, Exit) ->
    {N, G1} = pop(G0), {B, G2} = pop(G1), {D, G3} = pop(G2),
    cerl:c_seq(call_op(memory_fill_at,
                       [G0#g.mut, cerl:abstract(M), D, B, N, cerl:abstract(32)]),
               seq(Rest, G3, Exit));

instr({memory_copy, Dm, Sm}, Rest, G0, Exit) ->
    {N, G1} = pop(G0), {Sa, G2} = pop(G1), {Da, G3} = pop(G2),
    cerl:c_seq(call_op(memory_copy_at,
                       [G0#g.mut, cerl:abstract(Dm), cerl:abstract(Sm), Da, Sa,
                        N, cerl:abstract(32), cerl:abstract(32)]),
               seq(Rest, G3, Exit));

instr({memory_init, D, M}, Rest, G0, Exit) ->
    {N, G1} = pop(G0), {So, G2} = pop(G1), {Da, G3} = pop(G2),
    cerl:c_seq(call_op(memory_init_at,
                       [G0#g.inst, G0#g.mut, cerl:abstract(D), cerl:abstract(M),
                        Da, So, N, cerl:abstract(32)]),
               seq(Rest, G3, Exit));

instr({data_drop, D}, Rest, G0, Exit) ->
    {M1, G1} = var(G0),
    cerl:c_let([M1], call_op(data_drop_at,
                             [G0#g.inst, G0#g.mut, cerl:abstract(D)]),
               seq(Rest, G1#g{mut = M1}, Exit));

instr({global_get, I}, Rest, G0, Exit) ->
    {V, G} = var(G0),
    cerl:c_let([V], call_op(global_at, [G0#g.mut, cerl:abstract(I)]),
               seq(Rest, push(V, G), Exit));

instr({global_set, I}, Rest, G0, Exit) ->
    {Val, G1} = pop(G0),
    {M1, G2} = var(G1),
    cerl:c_let([M1], call_op(set_global_at,
                             [G0#g.inst, G0#g.mut, cerl:abstract(I), Val]),
               seq(Rest, G2#g{mut = M1}, Exit));

%%% ------------------------------------------------------------------ calls ---
%%
%% A callee compiled alongside this function is a *local* apply, because BeamAsm
%% compiles a remote call by setting up an export entry in a register and a
%% local one is direct. Anything else crosses back into the interpreter through
%% `wasm_exec:call_out/5', priced at 37.4 to 43.4 ns against the interpreter's
%% own 43.5 to 44.7 for the same call.

instr({call, F}, Rest, #g{unit = Unit, sigs = Sigs} = G0, Exit) ->
    {NP, NR} = maps:get(F, Sigs),
    {Args, G1} = take(NP, G0),
    Call = case maps:find(F, Unit) of
               {ok, {Pos, stateful}} ->
                   local_call(Pos, NP + 3,
                              [G0#g.inst, G0#g.mut, deeper(G0) | Args]);
               {ok, {Pos, pure}} ->
                   %% A pure callee returns its results and no state, so the
                   %% caller's own state passes straight through.
                   cerl:c_tuple([local_call(Pos, NP, Args), G0#g.mut]);
               error ->
                   call_op(call_out, [G0#g.inst, G0#g.mut, cerl:abstract(F),
                                      cerl:make_list(Args), deeper(G0),
                                      cerl:c_atom(G0#g.mod),
                                      cerl:abstract(G0#g.gen)])
           end,
    %% Results come back as a list, whatever side the call landed on, and are
    %% taken apart by matching: the count is static, so no walking and a wrong
    %% arity cannot match.
    {Rs, G2} = vars(NR, G1),
    {M1, G3} = var(G2),
    Clause = cerl:c_clause([cerl:c_tuple([list_pat(Rs), M1])],
                           seq(Rest, G3#g{mut = M1,
                                          stack = lists:reverse(Rs) ++ G1#g.stack},
                               Exit)),
    %% The depth check is the caller's, so a runaway recursion raises what
    %% `enter/5' raises instead of growing the Erlang stack until the process
    %% runs out of heap.
    cerl:c_seq(call_op(check_depth, [G0#g.inst, G0#g.d]),
               cerl:c_case(Call, [Clause]));

instr({call_indirect, TypeIdx, TableIdx}, Rest,
      #g{tsigs = TSigs, mod = Mod, gen = Stamp} = G0, Exit) ->
    {NP, NR} = maps:get(TypeIdx, TSigs),
    %% The table index is on top, above the arguments.
    {I, G1} = pop(G0),
    {Args, G2} = take(NP, G1),
    %% This module's own name, as a literal, so that a target compiled
    %% alongside the caller is a call into generated code rather than a crossing
    %% back into the interpreter. Passed rather than looked up: which module
    %% this is was decided at generation time, and a bytecode dispatch loop
    %% reaches this often enough that an `atomics` read to rediscover it would
    %% be part of the cost being removed.
    Call = call_op(indirect_out,
                   [G0#g.inst, G0#g.mut, cerl:abstract(TypeIdx),
                    cerl:abstract(TableIdx), I, cerl:make_list(Args),
                    deeper(G0), cerl:c_atom(Mod), cerl:abstract(Stamp)]),
    {Rs, G3} = vars(NR, G2),
    {M1, G4} = var(G3),
    Clause = cerl:c_clause([cerl:c_tuple([list_pat(Rs), M1])],
                           seq(Rest, G4#g{mut = M1,
                                          stack = lists:reverse(Rs) ++ G2#g.stack},
                               Exit)),
    cerl:c_seq(call_op(check_depth, [G0#g.inst, G0#g.d]),
               cerl:c_case(Call, [Clause]));

%%% ---------------------------------------------------------------- numeric ---

instr(Op, Rest, G, Exit) when is_atom(Op) ->
    case lists:member(Op, ?UNOPS) of
        true -> emit1(Op, Rest, G, Exit);
        false ->
            true = lists:member(Op, ?BINOPS) orelse throw({unsupported, Op}),
            emit2(Op, Rest, G, Exit)
    end;

instr(I, _Rest, _G, _Exit) ->
    throw({unsupported, I}).

emit1(Op, Rest, G0, Exit) ->
    {A, G1} = pop(G0),
    {V, G2} = var(G1),
    cerl:c_let([V], unop(Op, A), seq(Rest, push(V, G2), Exit)).

unop(Op, A) ->
    case inline1(Op) of
        false -> call_op(op1, [cerl:c_atom(Op), A]);
        Expr -> Expr(A)
    end.

emit2(Op, Rest, G0, Exit) ->
    {B, G1} = pop(G0), {A, G2} = pop(G1),
    {V, G3} = var(G2),
    %% A second name, for an operation that has to look at its own result before
    %% it can finish. Allocated here because this is where the counter lives.
    {W, G4} = var(G3),
    cerl:c_let([V], binop(Op, A, B, W), seq(Rest, push(V, G4), Exit)).

%%% ------------------------------------------------------ inline arithmetic ---
%%
%% Routing *every* operation through `wasm_exec:op2/3' is what makes compiled
%% and interpreted arithmetic provably identical, and it costs a remote call per
%% operation: `bench/cross/loop.wasm' came out at 30.5 ns/iteration against the
%% interpreter's 68.2, where the spike that inlined its arithmetic managed 2.59.
%%
%% So the *total* operations are inlined and the rest still go through
%% `wasm_exec'. Total means it cannot trap and cannot depend on a representation
%% decision: addition wraps, division does not. Division, remainder and every
%% conversion keep the single implementation, which is where the semantics are
%% actually difficult.
%%
%% Values are held signed, exactly as the interpreter holds them, so wrapping is
%% masking to width and then flipping and subtracting the sign bit: three BIFs
%% and no test, where a comparison would branch.
binop(Op, A, B, W) ->
    case inline_w(Op) of
        false ->
            case inline(Op) of
                false -> call_op(op2, [cerl:c_atom(Op), A, B]);
                Expr -> Expr(A, B)
            end;
        Expr -> Expr(A, B, W)
    end.


-define(W32, 16#FFFFFFFF).
-define(S32, 16#80000000).
-define(W64, 16#FFFFFFFFFFFFFFFF).
-define(P64, 16#10000000000000000).
%% The largest BEAM small integer: 60 bits, signed. A literal at or below this
%% is an immediate and a literal above it is a bignum, which is the whole
%% reason `wrap_sum/2` has two range tests instead of one.
-define(SMALL, 576460752303423487).
-define(P32, 16#100000000).
-define(S64, 16#8000000000000000).

%% The four integer-to-f64 conversions, which are *total*: every i32 and i64
%% has a nearest-representable f64, so none of them can produce a NaN or an
%% infinity and none needs `wasm_num_float'. `round_to(64, F)' is the identity,
%% so the signed pair is `float/1' and the unsigned pair is `float/1' of the
%% value masked to its width, which is exactly what `wasm_num:to_u32/1' and
%% `to_u64/1' compute on a value held signed.
%%
%% These four and not the rest of the float set, because these are the ones the
%% profile named: `f64_convert_i32_u' alone keeps 55% of QuickJS's remaining
%% interpreted calls out of compiled code. It matters that they are inlined
%% rather than called: the BEAM keeps a float unboxed inside a function and
%% boxes it at a call boundary, so routing these through `wasm_exec:op1/2'
%% would allocate on every conversion in the hottest function of the module.
%%
%% f32 is deliberately not here. Every f32 result has to be rounded to single
%% precision, which Erlang has no native way to do, so those stay in
%% `wasm_num_float' where the one implementation lives.
%% The four unary operations a real workload actually spends its time in.
%%
%% Measured, not guessed: a compiled QuickJS run leaves generated code
%% 1,317,284 times for `wasm_exec:op1/2` and for almost nothing else --
%% `check_depth/2`, the next one down, is 23,085 -- and four operations are the
%% whole of it: `i32_eqz` 581,201, `i32_wrap_i64` 521,684,
%% `i64_extend_i32_u` 154,285, `i64_eqz` 60,031. Every one is pure arithmetic
%% with no trap and no state, and every one was a cross-module call.
%%
%% Each is the interpreter's own definition written in Core rather than a second
%% spelling of it: `wasm_num:wrap_s32/1` is `wrap(32, _)`, `wasm_num:to_u32/1`
%% over the i32 domain is `uns(32, _)`, and `i64.extend_i32_s` is the identity
%% because an i32 is already held signed.
inline1(i32_eqz) -> fun(A) -> test('=:=', A, cerl:abstract(0)) end;
inline1(i64_eqz) -> fun(A) -> test('=:=', A, cerl:abstract(0)) end;
inline1(i32_wrap_i64) -> fun(A) -> wrap(32, A) end;
inline1(i64_extend_i32_u) -> fun(A) -> uns(32, A) end;
inline1(i64_extend_i32_s) -> fun(A) -> A end;
inline1(f64_convert_i32_s) -> fun(A) -> bif(float, [A]) end;
inline1(f64_convert_i64_s) -> fun(A) -> bif(float, [A]) end;
inline1(f64_convert_i32_u) ->
    fun(A) -> bif(float, [bif('band', [A, cerl:abstract(?W32)])]) end;
inline1(f64_convert_i64_u) ->
    fun(A) -> bif(float, [bif('band', [A, cerl:abstract(?W64)])]) end;
inline1(_) -> false.

inline(i32_add) -> fun(A, B) -> wrap(32, bif('+', [A, B])) end;
inline(i32_sub) -> fun(A, B) -> wrap(32, bif('-', [A, B])) end;
inline(i32_mul) -> fun(A, B) -> wrap(32, bif('*', [A, B])) end;
inline(i64_add) -> fun(A, B) -> wrap(64, bif('+', [A, B])) end;
inline(i64_sub) -> fun(A, B) -> wrap(64, bif('-', [A, B])) end;
inline(i64_mul) -> fun(A, B) -> wrap(64, bif('*', [A, B])) end;
%% Bitwise operations on signed two's-complement values are the same bits, so
%% `and', `or' and `xor' need no wrapping at all.
inline(i32_and) -> fun(A, B) -> bif('band', [A, B]) end;
inline(i32_or)  -> fun(A, B) -> bif('bor', [A, B]) end;
inline(i32_xor) -> fun(A, B) -> bif('bxor', [A, B]) end;
inline(i64_and) -> fun(A, B) -> bif('band', [A, B]) end;
inline(i64_or)  -> fun(A, B) -> bif('bor', [A, B]) end;
inline(i64_xor) -> fun(A, B) -> bif('bxor', [A, B]) end;
%% A shift count is taken modulo the width, which the specification requires and
%% which also keeps `bsl' from building an enormous bignum.
inline(i32_shl) -> fun(A, B) -> wrap(32, bif('bsl', [A, shamt(32, B)])) end;
inline(i64_shl) -> fun(A, B) -> wrap(64, bif('bsl', [A, shamt(64, B)])) end;
inline(i32_shr_s) -> fun(A, B) -> bif('bsr', [A, shamt(32, B)]) end;
inline(i64_shr_s) -> fun(A, B) -> bif('bsr', [A, shamt(64, B)]) end;
%% Wrapped, unlike `shr_s`: this shifts the *unsigned* reinterpretation, and a
%% value is only back in the signed range once the shift has actually moved the
%% top bit down. A masked count of zero leaves it where it was, so
%% `i32.shr_u(-1, 32)` answered 4294967295 where the specification and
%% `wasm_exec:i32_binop/3` both say -1. Every nonzero count happened to be
%% right, which is why nothing caught it until the conformance suite ran
%% through generated code.
inline(i32_shr_u) -> fun(A, B) -> wrap(32, bif('bsr', [uns(32, A), shamt(32, B)])) end;
inline(i64_shr_u) -> fun(A, B) -> wrap(64, bif('bsr', [uns(64, A), shamt(64, B)])) end;
inline(Op) -> relop(Op).

%% A comparison yields the integer 1 or 0, not a boolean. Unsigned comparisons
%% reinterpret both operands first, which is the whole difference between the
%% signed and unsigned forms.
relop(Op) ->
    case cmp(Op) of
        false -> false;
        {Erl, signed} -> fun(A, B) -> test(Erl, A, B) end;
        {Erl, W} -> fun(A, B) -> test(Erl, uns(W, A), uns(W, B)) end
    end.

cmp(i32_eq) -> {'=:=', signed};   cmp(i64_eq) -> {'=:=', signed};
cmp(i32_ne) -> {'=/=', signed};   cmp(i64_ne) -> {'=/=', signed};
cmp(i32_lt_s) -> {'<', signed};   cmp(i64_lt_s) -> {'<', signed};
cmp(i32_le_s) -> {'=<', signed};  cmp(i64_le_s) -> {'=<', signed};
cmp(i32_gt_s) -> {'>', signed};   cmp(i64_gt_s) -> {'>', signed};
cmp(i32_ge_s) -> {'>=', signed};  cmp(i64_ge_s) -> {'>=', signed};
cmp(i32_lt_u) -> {'<', 32};       cmp(i64_lt_u) -> {'<', 64};
cmp(i32_le_u) -> {'=<', 32};      cmp(i64_le_u) -> {'=<', 64};
cmp(i32_gt_u) -> {'>', 32};       cmp(i64_gt_u) -> {'>', 64};
cmp(i32_ge_u) -> {'>=', 32};      cmp(i64_ge_u) -> {'>=', 64};
cmp(_) -> false.

test(Erl, A, B) ->
    cerl:c_case(bif(Erl, [A, B]),
                [cerl:c_clause([cerl:abstract(true)], cerl:abstract(1)),
                 cerl:c_clause([cerl:abstract(false)], cerl:abstract(0))]).

%% The two operations that are cheaper for looking at their own result.
%%
%% `wrap(64, _)` masks with 2^64-1 and folds with 2^63, and both literals are
%% past the 60 bits a BEAM immediate covers, so the whole expression is bignum
%% arithmetic however small the value is. That is the entire difference between
%% `i32.add` at 1.26 nanoseconds and `i64.add` at 26.40: the i32 constants are
%% immediates and the i64 ones are not.
%%
%% An i64 is always held in `[-2^63, 2^63)` -- that is the invariant every wrap
%% maintains -- so a sum or difference of two of them lands in `(-2^64, 2^64)`
%% and the correction is a comparison and at most one subtraction. Multiply and
%% shift are not here: their results are unbounded and only the mask answers.
inline_w(i64_add) -> fun(A, B, W) -> wrap_sum(bif('+', [A, B]), W) end;
inline_w(i64_sub) -> fun(A, B, W) -> wrap_sum(bif('-', [A, B]), W) end;
%% The 32-bit pair is here for a different reason. Its constants are immediates
%% already, so the branch-free `wrap(32, _)` costs nothing to run -- but it
%% tells the compiler nothing either, and since OTP 25 the JIT emits far better
%% code for arithmetic whose range it knows: an addition drops from ten
%% instructions to four and a comparison from eleven to four. A guard is how
%% that range gets stated, and validation has already proved it.
inline_w(i32_add) -> fun(A, B, W) -> wrap_sum32(bif('+', [A, B]), W) end;
inline_w(i32_sub) -> fun(A, B, W) -> wrap_sum32(bif('-', [A, B]), W) end;
inline_w(_) -> false.

wrap_sum32(E, W) ->
    cerl:c_case(
      E,
      [cerl:c_clause([W],
                     bif('and', [bif('>=', [W, cerl:abstract(-?S32)]),
                                 bif('<', [W, cerl:abstract(?S32)])]),
                     W),
       cerl:c_clause([W], bif('>=', [W, cerl:abstract(?S32)]),
                     bif('-', [W, cerl:abstract(?P32)])),
       cerl:c_clause([W], cerl:abstract(true),
                     bif('+', [W, cerl:abstract(?P32)]))]).

wrap_sum(E, W) ->
    cerl:c_case(
      E,
      [%% Small enough to be a BEAM immediate, which is what almost every value
       %% in real code is. This clause exists because the *next* one compares
       %% against 2^63, and a literal that large is itself a bignum: testing
       %% against it cost about 5.5 nanoseconds a comparison, which was most of
       %% what was left after the mask went. These bounds are the 60-bit
       %% immediate range exactly, so the test is register work.
       cerl:c_clause([W],
                     bif('and', [bif('>=', [W, cerl:abstract(-?SMALL - 1)]),
                                 bif('=<', [W, cerl:abstract(?SMALL)])]),
                     W),
       %% In range but big enough to be a bignum. Correct, and rare.
       cerl:c_clause([W],
                     bif('and', [bif('>=', [W, cerl:abstract(-?S64)]),
                                 bif('<', [W, cerl:abstract(?S64)])]),
                     W),
       cerl:c_clause([W], bif('>=', [W, cerl:abstract(?S64)]),
                     bif('-', [W, cerl:abstract(?P64)])),
       cerl:c_clause([W], cerl:abstract(true),
                     bif('+', [W, cerl:abstract(?P64)]))]).

wrap(32, E) -> bif('-', [bif('bxor', [bif('band', [E, cerl:abstract(?W32)]),
                                      cerl:abstract(?S32)]),
                         cerl:abstract(?S32)]);
wrap(64, E) -> bif('-', [bif('bxor', [bif('band', [E, cerl:abstract(?W64)]),
                                      cerl:abstract(?S64)]),
                         cerl:abstract(?S64)]).

uns(32, E) -> bif('band', [E, cerl:abstract(?W32)]);
uns(64, E) -> bif('band', [E, cerl:abstract(?W64)]).

shamt(W, E) -> bif('band', [E, cerl:abstract(W - 1)]).

bif(Name, Args) -> cerl:c_call(cerl:c_atom(erlang), cerl:c_atom(Name), Args).

%%% ---------------------------------------------------------------- helpers ---

pop(#g{stack = [V | S]} = G) -> {V, G#g{stack = S}}.

%% N operands, in call order rather than stack order.
take(N, #g{stack = S} = G) ->
    {lists:reverse(lists:sublist(S, N)), G#g{stack = lists:nthtail(N, S)}}.

deeper(#g{d = D}) -> cerl:c_call(cerl:c_atom(erlang), cerl:c_atom('+'),
                                 [D, cerl:abstract(1)]).

local_call(Pos, Arity, Args) ->
    cerl:c_apply(cerl:c_fname(fun_name(Pos), Arity), Args).

vars(0, G) -> {[], G};
vars(N, G0) ->
    {V, G1} = var(G0),
    {Vs, G} = vars(N - 1, G1),
    {[V | Vs], G}.
push(V, #g{stack = S} = G) -> G#g{stack = [V | S]}.

split_stack(N, S) -> {lists:sublist(S, N), lists:nthtail(N, S)}.

target(N, #g{frames = Frames}) when N < length(Frames) -> lists:nth(N + 1, Frames);
%% Branching past the outermost frame is a return, which is what the function
%% frame is in the interpreter.
target(_, _) -> return.

call_op(F, Args) ->
    cerl:c_call(cerl:c_atom(wasm_exec), cerl:c_atom(F), Args).

%% The effective address of an access, inline.
%%
%% An i32 operand is held signed and the address is unsigned, which
%% `wasm_num:to_u32/1` did with a remote call per access. Masking to the width
%% is the same answer on a value already in range, which is what an operand of
%% this subset always is, and it is two instructions rather than a call. The
%% offset is a literal, and adding zero is not emitted at all.
address(Base, 0) -> bif('band', [Base, cerl:abstract(?W32)]);
address(Base, Offset) ->
    bif('+', [bif('band', [Base, cerl:abstract(?W32)]), cerl:abstract(Offset)]).

%%% ---------------------------------------------------- inline memory access ---
%%
%% A load or a store, performed here rather than by calling `wasm_exec`.
%%
%% The call was 17.6 nanoseconds for a load and 34.6 for a store against an
%% `atomics` floor of 4.8 and 9.6, and almost all of the difference is work this
%% generator can settle: the width and the signedness are literals, the address
%% is already computed, and the handle's fields are at fixed offsets.
%%
%% **Only the ordinary case is inlined**, and everything else calls the helper
%% that was always there. Ordinary means: a private memory, so the page count
%% and the chunk tuple are in the handle rather than published in a cell; the
%% access in bounds; and the access not straddling two 64-bit words. Anything
%% else -- an imported or exported memory, an out-of-bounds address that has to
%% trap, an unaligned access near a word boundary -- goes to `wasm_exec`, which
%% is the tested implementation and stays the only one that can trap.
%%
%% That is what bounds the risk of doing this at all. The inline path cannot
%% reach a trap, cannot see a growing memory, and cannot handle a straddle; the
%% guard is what says so, and everything it excludes is handled by code that has
%% not changed.
access(Dir, Mut, M, N, Kind, Addr, Val) ->
    Mem = cerl:c_var('Mem'), A = cerl:c_var('A'), Sh = cerl:c_var('Sh'),
    Ix = cerl:c_var('Ix'), Ck = cerl:c_var('Ck'), Bit = cerl:c_var('Bit'),
    Slow = case Dir of
               load -> call_op(load_at, [Mut, cerl:abstract(M), cerl:abstract(N),
                                         cerl:c_atom(Kind), A]);
               store -> call_op(store_at, [Mut, cerl:abstract(M), cerl:abstract(N),
                                           cerl:c_atom(Kind), A, Val])
           end,
    Fast = case Dir of
               load -> inline_load(N, Kind, A, Sh, Ix, Ck, Bit);
               store -> inline_store(N, Kind, A, Sh, Ix, Ck, Bit, Val)
           end,
    %% `Bit' is the bit offset of the access within its word, and the straddle
    %% test is on it, so it is computed once and shared by the guard and the
    %% body.
    cerl:c_let([Mem], mem_at(Mut, M),
      cerl:c_let([A], Addr,
        cerl:c_let([Bit], bif('*', [bif('band', [A, cerl:abstract(7)]),
                                    cerl:abstract(8)]),
          ordinary(Mem, A, N, Bit,
                   cerl:c_let([Sh], field(Mem, ?MEM_SHIFT),
                     cerl:c_let([Ck], chunk_of(Mem, A, Sh),
                       cerl:c_let([Ix], word_index(A, Sh), Fast))),
                   Slow)))).

mem_at(Mut, M) ->
    bif(element, [cerl:abstract(M + 1),
                  bif(element, [cerl:abstract(#mut.mems), Mut])]).

field(Mem, Ix) -> bif(element, [cerl:abstract(Ix), Mem]).

%% In bounds against this handle's own view, and within one word.
%%
%% It used to also require the memory to be *private*, which meant `pages_ref`
%% and `chunks_ref` both `undefined`. That was the whole optimisation's
%% undoing: `wasm_validate:shared_mems/1` publishes a memory that is imported
%% **or exported**, every toolchain exports its memory so the host can read
%% strings out of it, and so no module a real compiler emits ever took this
%% path. Measured at 125.9 nanoseconds a store-and-load against 59.4 for the
%% same module with the export removed.
%%
%% Dropping those two tests is safe, and for a reason the slow path already
%% relies on. `wasm_memory:chunk/2` prefers the handle's own chunk tuple and
%% consults the published cell only for an index beyond it, because growth only
%% *appends* chunks and never moves or replaces one. So an access in bounds
%% against this handle's own `pages` is covered by this handle's own `chunks`,
%% whoever else may have grown the memory since. Anything past that is not in
%% this tuple, fails the bounds test, and goes to the helper, which reads the
%% published count and either finds it there or traps.
%%
%% The handle is also kept current for the growth this instance does itself:
%% `wasm_memory:grow/2` answers a new record and the instance stores it back.
%% Only another instance's growth leaves this one behind, and that is the case
%% the slow path is for.
%%
%% Short-circuiting, and the cheap test first. This was one `erlang:and/2`
%% chain, which is the strict boolean function: every operand ran even after
%% one had already failed.
ordinary(Mem, A, N, Bit, Fast, Slow) ->
    all([%% Arithmetic on `Bit`, which is already computed.
         bif('=<', [bif('+', [Bit, cerl:abstract(N * 8)]), cerl:abstract(64)]),
         %% One field read and a multiply.
         bif('=<', [bif('+', [A, cerl:abstract(N)]),
                    bif('*', [field(Mem, ?MEM_PAGES), cerl:abstract(65536)])])],
        Fast, Slow).

%% Nested cases, because Core Erlang has no `andalso`: it is sugar the parser
%% expands, and this generator emits Core directly.
all([Test], Fast, Slow) ->
    cerl:c_case(Test, [cerl:c_clause([cerl:abstract(true)], Fast),
                       cerl:c_clause([cerl:c_var('_No')], Slow)]);
all([Test | Rest], Fast, Slow) ->
    cerl:c_case(Test, [cerl:c_clause([cerl:abstract(true)], all(Rest, Fast, Slow)),
                       cerl:c_clause([cerl:c_var('_No')], Slow)]).

chunk_of(Mem, A, Sh) ->
    bif(element, [bif('+', [bif('bsr', [A, Sh]), cerl:abstract(1)]),
                  field(Mem, ?MEM_CHUNKS)]).

word_index(A, Sh) ->
    bif('+', [bif('bsr', [bif('band', [A, bif('-', [bif('bsl', [cerl:abstract(1), Sh]),
                                                    cerl:abstract(1)])]),
                          cerl:abstract(3)]),
              cerl:abstract(1)]).

atomic(F, Args) -> cerl:c_call(cerl:c_atom(atomics), cerl:c_atom(F), Args).

%% A full-word load is the word.
%%
%% `ordinary/6` only takes the fast path when the access fits inside one word,
%% so for eight bytes `Bit` is necessarily zero and the shift and the mask are
%% both identities -- but the mask is `2^64-1`, which is past the 60-bit
%% immediate range, so the compiler cannot see that and every `i64.load` did
%% bignum arithmetic on a value that is usually small. `i64.load` measured
%% 39.81 nanoseconds against `i32.load`'s 9.35, which is backwards: an aligned
%% eight-byte load is one `atomics:get` and should be the cheapest of the two.
inline_load(8, Kind, _A, _Sh, Ix, Ck, _Bit) ->
    decode_word(Kind, atomic(get, [Ck, Ix]));
inline_load(N, Kind, _A, _Sh, Ix, Ck, Bit) ->
    Raw = bif('band', [bif('bsr', [atomic(get, [Ck, Ix]), Bit]),
                       cerl:abstract(mask(N))]),
    decode(Kind, N, Raw).

%% The word as `atomics` hands it over: unsigned, `[0, 2^64)`.
%%
%% Reinterpreting that as a signed i64 is one comparison, and the first one is
%% against the immediate bound rather than 2^63 for the reason `wrap_sum/2`
%% gives: a literal that large is a bignum and comparing against it is not free.
decode_word(f64, Raw) ->
    cerl:c_call(cerl:c_atom(wasm_num), cerl:c_atom(f64_from_bits), [Raw]);
decode_word(_Int, Raw) ->
    W = cerl:c_var('Rw'),
    cerl:c_case(Raw,
                [cerl:c_clause([W], bif('=<', [W, cerl:abstract(?SMALL)]), W),
                 cerl:c_clause([W], bif('<', [W, cerl:abstract(?S64)]), W),
                 cerl:c_clause([W], cerl:abstract(true),
                               bif('-', [W, cerl:abstract(?P64)]))]).

%% A narrow store is a read, a splice and a write: `atomics' words are 64 bits
%% and there is no narrower write. That is why a store costs twice a load, and
%% it is a property of the representation rather than of this code.
%% A full-word store is the word, so there is nothing to splice into.
%%
%% The general path reads the word, masks the value with `2^64-1` and merges;
%% for eight bytes the read is pointless, the merge is the identity and the mask
%% is the signed-to-unsigned reinterpretation, which one comparison does without
%% touching a bignum literal. That is a read, a bignum `band` and a splice
%% removed from every `i64.store` and `f64.store`.
inline_store(8, Kind, _A, _Sh, Ix, Ck, _Bit, Val) ->
    atomic(put, [Ck, Ix, unsigned_word(Kind, encode(Kind, Val))]);
inline_store(N, Kind, _A, _Sh, Ix, Ck, Bit, Val) ->
    V = cerl:c_var('V'), Old = cerl:c_var('Old'), Vm = cerl:c_var('Vm'),
    cerl:c_let([V], encode(Kind, Val),
      cerl:c_let([Vm], bif('band', [V, cerl:abstract(mask(N))]),
        cerl:c_let([Old], atomic(get, [Ck, Ix]),
          atomic(put, [Ck, Ix, spliced(N, Old, Vm, Bit)])))).

%% The bits `atomics` wants: unsigned, `[0, 2^64)`. Float bits arrive that way
%% already; a signed i64 needs `2^64` added when it is negative.
unsigned_word(f64, Bits) ->
    Bits;
unsigned_word(_Int, V) ->
    W = cerl:c_var('Uw'),
    cerl:c_case(V,
                [cerl:c_clause([W], bif('>=', [W, cerl:abstract(0)]), W),
                 cerl:c_clause([W], cerl:abstract(true),
                               bif('+', [W, cerl:abstract(?P64)]))]).

%% Where in the word the value goes.
%%
%% The general form builds both the keep-mask and the shift at run time, from a
%% `Bit` that is only known then: `bsl`, `bnot`, `bsl` again. For an *aligned*
%% access `Bit` is one of a couple of values and both become literals the
%% compiler folds, which measured 22.1 nanoseconds a store against 15.8.
%%
%% Compiler output is overwhelmingly aligned, and an i32 walking an array
%% alternates between the two offsets below, so both are worth naming. Anything
%% else keeps the general form, which is the one that was always there.
spliced(N, Old, Vm, Bit) ->
    %% Every offset the width can naturally sit at, not just the two an i32
    %% uses. A byte store lands on any of eight and each is a literal splice;
    %% before this they all fell to the dynamic form, which builds the mask and
    %% both shifts at run time.
    Aligned = [B || B <- lists:seq(0, 56, 8),
                    B + N * 8 =< 64, B rem (N * 8) =:= 0],
    cerl:c_case(Bit,
                [cerl:c_clause([cerl:abstract(B)], splice_at(N, Old, Vm, B))
                 || B <- Aligned]
                ++ [cerl:c_clause([cerl:c_var('_Bit')],
                                  splice_dyn(N, Old, Vm, Bit))]).

%% `Bit` is a literal here, so the whole splice is built from literals -- but
%% not from the *keep-mask*, which is where this used to reach for
%% `16#FFFFFFFF00000000` and take a four-byte store off the immediate path for
%% the sake of a constant.
%%
%% The bits above the field are kept by shifting them out and back, and the bits
%% below by a mask that is small because `B` is at most 32. A word whose other
%% half happens to be zero -- which is most of a freshly grown memory, and any
%% value that fits in the half being written -- then stays in immediates from
%% end to end.
splice_at(N, Old, Vm, B) ->
    Top = B + N * 8,
    Above = case Top of
                64 -> none;
                _ -> bif('bsl', [bif('bsr', [Old, cerl:abstract(Top)]),
                                 cerl:abstract(Top)])
            end,
    Below = case B of
                0 -> none;
                _ -> bif('band', [Old, cerl:abstract((1 bsl B) - 1)])
            end,
    Placed = case B of
                 0 -> Vm;
                 _ -> bif('bsl', [Vm, cerl:abstract(B)])
             end,
    lists:foldl(fun(none, Acc) -> Acc;
                   (E, none) -> E;
                   (E, Acc) -> bif('bor', [Acc, E])
                end, none, [Above, Below, Placed]).

splice_dyn(N, Old, Vm, Bit) ->
    Keep = bif('bxor', [cerl:abstract(?W64),
                        bif('bsl', [cerl:abstract(mask(N)), Bit])]),
    bif('bor', [bif('band', [Old, Keep]), bif('bsl', [Vm, Bit])]).

mask(N) -> wasm_memory:mask(N).

%% The same widening `wasm_exec:decode_loaded/3` does, generated. The float
%% cases keep calling, because a NaN payload is not arithmetic.
%%
%% **Two implementations of one rule.** They cannot be merged: one builds Core
%% and the other runs. What holds them together is
%% `wasm_core_SUITE:every_memory_access_agrees_with_the_interpreter/1`, which
%% walks every load and store against a spread of byte patterns. Change either
%% of these and change that test's expectations at your peril.
decode(i32_u, _N, Raw) -> wrap(32, Raw);
decode(i64_u, _N, Raw) -> wrap(64, Raw);
decode(i32_s, N, Raw) -> wrap(32, sign(N, Raw));
decode(i64_s, N, Raw) -> wrap(64, sign(N, Raw));
decode(f32, _N, Raw) -> cerl:c_call(cerl:c_atom(wasm_num),
                                    cerl:c_atom(f32_from_bits), [Raw]);
decode(f64, _N, Raw) -> cerl:c_call(cerl:c_atom(wasm_num),
                                    cerl:c_atom(f64_from_bits), [Raw]).

%% Sign-extend an N-byte value held unsigned, without a branch: flip the sign
%% bit and subtract it back.
sign(N, Raw) ->
    S = 1 bsl (N * 8 - 1),
    bif('-', [bif('bxor', [Raw, cerl:abstract(S)]), cerl:abstract(S)]).

encode(int, V) -> V;
encode(f32, V) -> cerl:c_call(cerl:c_atom(wasm_num), cerl:c_atom(f32_to_bits), [V]);
encode(f64, V) -> cerl:c_call(cerl:c_atom(wasm_num), cerl:c_atom(f64_to_bits), [V]).

%% A pure vector operation: the same `wasm_simd` call the interpreter makes,
%% with its result bound and pushed.
simd(F, Args, Rest, G0, Exit) ->
    {V, G} = var(G0),
    cerl:c_let([V], cerl:c_call(cerl:c_atom(wasm_simd), cerl:c_atom(F), Args),
               seq(Rest, push(V, G), Exit)).

