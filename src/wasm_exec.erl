-module(wasm_exec).
-moduledoc """
The interpreter.

Nothing here is called directly; you arrive through `wasm:call/3`. Read it when
you want to know why execution behaves as it does on the BEAM, or before you
change the dispatch loop.

**Continuation lists, not a program counter.** WebAssembly control flow is
structured: `br N` can only exit N enclosing blocks or jump back to a `loop`
header. Nothing can jump to an arbitrary offset. So the instruction stream
never needs to be flattened and there is no program counter at all. A block's
body is a nested cons list, and entering one pushes a control frame holding
the list to resume on exit.

This is the opposite of what a C runtime does, and the benchmarks are why.
Walking a cons list measured 3.7 ns per instruction; the flattened
bytecode-plus-index shape that every C interpreter uses measured 5.6 ns,
because `element/2` with a runtime index is a bounds-checked operation while
matching a list head is a dereference the compiler turns into a jump table.
Porting Wasmtime's IR shape would have cost about 35% for nothing.

**Saved stack tails instead of heights.** A control frame stores the
operand stack *list* as it was on entry, not its depth. Leaving a block
normally then costs nothing at all (validation guarantees the stack is
already correct), and branching out is `take(Arity) ++ SavedTail`. Tracking
an integer height would mean maintaining a counter on every push and pop.

**Explicit call frames.** Calls push onto `frames` rather than recursing
through Erlang. Erlang has no first-class continuations, so recursion would
make suspension impossible; explicit frames keep the whole execution state a
plain term that can be captured, inspected from another process, and bounded.

**Fuel.** Charged at back-edges and calls only. Every unbounded execution has
to pass through one or the other, so bounding those bounds everything while
straight-line code pays nothing. Fuel is there for *resource limits and
metering*, not for scheduler safety: every dispatch step here is an Erlang
function call and therefore consumes a reduction, so the BEAM preempts this loop
whether or not you enabled fuel. A pure-Erlang interpreter cannot monopolise a
scheduler, which is precisely what a NIF-based one can.
""".

-include("wasm.hrl").
-include("wasm_exec.hrl").

-export([call/5, call_toplevel/5, init_state/4]).
-export([open_budget/1, close_budget/1]).
-export([op1/2, op2/3, load_at/5, store_at/6, global_at/2, set_global_at/4]).
%% Read by `wasm_core` at generation time, so the width and signedness of an
%% access are decided once and in one place.
-export([load_spec/1, store_spec/1]).
-export([call_out/7, shard_call/8, check_depth/2, indirect_out/9]).
-export([memory_size_at/2, memory_grow_at/5, memory_fill_at/6, memory_copy_at/8,
         memory_init_at/8, data_drop_at/3]).
-export([simd_load_at/7, simd_store_at/6, simd_load_lane_at/9,
         simd_store_lane_at/8]).

%% One budget per outermost invocation, carrying what must not start again when
%% a host function calls back in: the fuel left, how many host calls have been
%% made, and the WebAssembly depth already reached. `wasm.erl' installs it and
%% takes it away; everything here reads or updates it at a boundary, never on
%% the instruction path, so a charged edge is still an immutable field read.
%%
%% `{Fuel, HostCalls, Depth, MaxHostCalls, MaxDepth}'. The ceilings travel with
%% it as well as the counts: a nested invocation that rebuilt them from its own
%% options got the instance's defaults rather than the limits the embedder
%% asked for on the call it actually made, so `max_depth' bounded nothing at
%% all once a host function was in the way.
-define(BUDGET, wasm_budget).

-define(FUEL_PER_CALL, 10).
-define(FUEL_PER_BACKEDGE, 1).

%%% ----------------------------------------------------------------- api ---

-doc "Invoke function `FuncIdx` with `Args`.".
-spec call(#inst{}, #mut{}, non_neg_integer(), [term()], map()) ->
          {ok, [term()], #mut{}}.
call(Inst, Mut, FuncIdx, Args, Opts) ->
    St = init_state(Inst, Mut, Args, Opts),
    case element(FuncIdx + 1, Inst#inst.funcs) of
        #fn{} = F ->
            check_arity(F#fn.nparams, Args),
            enter_top(F, Args, St);
        #hostfn{} = H ->
            {Results, St1} = call_host(H, Args, St),
            {ok, Results, St1#st.mut}
    end.

-doc """
Invoke, converting an escaping exception into an error.

Only your own call is the outermost frame; a nested invocation lets the
exception keep unwinding, which is what `foreign_call/5` relies on.
""".
-spec call_toplevel(#inst{}, #mut{}, non_neg_integer(), [term()], map()) ->
          {ok, [term()], #mut{}}.
call_toplevel(Inst, Mut, FuncIdx, Args, Opts) ->
    try call(Inst, Mut, FuncIdx, Args, Opts)
    catch throw:{wasm_exception, #exn{values = Vs}} ->
            %% The values go into the error the embedder receives, so they are
            %% leaving the runtime's sight exactly as a call result would.
            %% Nothing else would keep them alive.
            [ok = wasm_heap:pin(Inst#inst.heap, V) || V <- Vs], wasm_error:trap(uncaught_exception, #{values => Vs})
    end.

-spec init_state(#inst{}, #mut{}, [term()], map()) -> #st{}.
init_state(Inst, Mut, _Args, Opts) ->
    %% A nested invocation continues the budget rather than starting one. A
    %% host function calling back in used to get its fuel and its depth reset,
    %% so a module that bounced through an import could run for ever inside a
    %% limit that was being handed back to it each time round.
    {Fuel, Depth, MaxDepth} =
        case get(?BUDGET) of
            undefined ->
                {maps:get(fuel, Opts, infinity), 0,
                 maps:get(max_depth, Opts, 1024)};
            {F, _HC, D, _Max, MD} ->
                {F, D, MD}
        end,
    #st{inst = Inst, mut = Mut, locals = {},
        fuel = Fuel, depth = Depth, max_depth = MaxDepth,
        code = code_module(Fuel, Opts)}.

%% Compiled code does not charge fuel, and charging it round a compiled loop
%% gives back what compiling it bought, so `wasm_jit:entry/3` refuses a metered
%% invocation outright. Clearing it here as well means `do_call/4` never has to
%% ask: an invocation that meters simply has no compiled module to reach.
code_module(infinity, Opts) -> maps:get(code_module, Opts, undefined);
code_module(_Fuel, _Opts) -> undefined.

-doc """
Install a budget for an outermost invocation, answering what to restore.

`wasm:call/4` is the only caller. A nested one inherits what is already there.
""".
-spec open_budget(map()) -> term().
open_budget(Opts) ->
    put(?BUDGET, {maps:get(fuel, Opts, infinity), 0, 0,
                  maps:get(max_host_calls, Opts, infinity),
                  maps:get(max_depth, Opts, 1024)}).

-doc "Take away a budget, restoring whatever an enclosing invocation had.".
-spec close_budget(term()) -> ok.
close_budget(undefined) -> erase(?BUDGET), ok;
close_budget(Prev) -> put(?BUDGET, Prev), ok.

%% What is left when an invocation ends, so an enclosing one resumes from it
%% rather than from what it had before the host call.
publish_fuel(Fuel) ->
    case get(?BUDGET) of
        undefined -> ok;
        {_, HC, D, Max, MD} -> put(?BUDGET, {Fuel, HC, D, Max, MD}), ok
    end.

check_arity(N, Args) when length(Args) =:= N -> ok;
check_arity(N, Args) ->
    wasm_error:link_error(argument_arity, <<"wrong number of arguments">>,
                          #{expected => N, got => length(Args)}).

%%% ---------------------------------------------------------- call entry ---

%% Entering a function installs fresh locals and a single `func' control frame.
%% `Args' arrives already reversed, matching the order values sit on the stack.
enter(#fn{} = F, Locals, Cont, Ctrl, #st{depth = D, max_depth = Max} = St) ->
    case D >= Max of
        true -> wasm_error:exhaustion(call_stack_exhausted, #{depth => D});
        false -> ok
    end,
    Frame = {Cont, Ctrl, St#st.locals, St#st.stack},
    run(case F#fn.body of {lazy, _} -> body_of(F, St); B -> B end, [F#fn.frame],
        St#st{stack = [], locals = Locals, depth = D + 1,
              frames = [Frame | St#st.frames]}).

%% Pop `N' arguments off the operand stack straight into the locals list.
%%
%% The obvious version is `lists:split' then `lists:reverse' then `++ Defaults',
%% which walks the arguments three times and allocates three lists. Popping
%% top-first and consing produces the correct order in one pass, and seeding
%% the accumulator with the declared locals' defaults appends them for free.
pop_locals(0, Stack, Acc) -> {Acc, Stack};
pop_locals(N, [V | Stack], Acc) -> pop_locals(N - 1, Stack, [V | Acc]).

%% The outermost invocation gets a `toplevel' sentinel rather than a caller
%% frame, so that returning from it terminates instead of unwinding into a
%% frame that does not exist.
enter_top(#fn{} = F, Args, #st{depth = Base, max_depth = Max} = St) ->
    %% Checked here as well as in `enter/5'. A re-entrant chain enters through
    %% this clause every time round, so leaving the check to ordinary calls
    %% meant `max_depth' bounded one leg of a recursion rather than the
    %% recursion.
    Base >= Max andalso
        wasm_error:exhaustion(call_stack_exhausted, #{depth => Base}),
    Locals = list_to_tuple(Args ++ F#fn.defaults),
    %% From the depth already reached, not from zero: a guest that recurses by
    %% going out through an import and back in is as deep as one that recursed
    %% directly, and `max_depth` has to see it that way.
    run(case F#fn.body of {lazy, _} -> body_of(F, St); B -> B end, [F#fn.frame],
        St#st{stack = [], locals = Locals, depth = Base + 1,
              frames = [toplevel]}).

%% Leaving a function pops the caller's continuation back off `frames'.
leave(NRes, #st{stack = Stack, frames = Frames, depth = D} = St) ->
    Results = take(NRes, Stack),
    case Frames of
        [toplevel] ->
            ok = publish_fuel(St#st.fuel),
            {ok, lists:reverse(Results), St#st.mut};
        [] ->
            ok = publish_fuel(St#st.fuel),
            {ok, lists:reverse(Results), St#st.mut};
        [{Cont, Ctrl, Locals, CallerStack} | Rest] ->
            run(Cont, Ctrl,
                St#st{stack = Results ++ CallerStack, locals = Locals,
                      frames = Rest, depth = D - 1})
    end.

%%% ------------------------------------------------------------- dispatch ---

%% End of an instruction list: resume the enclosing control frame.
run([], [{block, Cont, _N, _Saved} | Ctrl], St) -> run(Cont, Ctrl, St);
run([], [{try_table, Cont, _N, _Saved, _C} | Ctrl], St) -> run(Cont, Ctrl, St);
run([], [{loop, Cont, _B, _N, _Saved} | Ctrl], St) -> run(Cont, Ctrl, St);
run([], [{func, NRes}], St) -> leave(NRes, St);
run([], [], St) -> leave(0, St);

%% - control ---------------------------------------------------------------
run([unreachable | _], _Ctrl, _St) ->
    wasm_error:trap(unreachable);
run([nop | Rest], Ctrl, St) ->
    run(Rest, Ctrl, St);

run([{block, NPar, NRes, Body} | Rest], Ctrl, #st{stack = S} = St) ->
    %% The saved tail is the stack below the block's parameters.
    Saved = drop(NPar, S),
    run(Body, [{block, Rest, NRes, Saved} | Ctrl], St);

run([{loop, NPar, _NRes, Body} = L | Rest], Ctrl, #st{stack = S} = St) ->
    Saved = drop(NPar, S),
    run(Body, [{loop, Rest, L, NPar, Saved} | Ctrl], St);

%% A `try_table' frame is an ordinary block frame that also remembers its
%% handlers, so leaving it normally costs exactly what leaving a block costs.
%% Only a throw looks at the handlers.
run([{try_table, NPar, NRes, Catches, Body} | Rest], Ctrl, #st{stack = S} = St) ->
    Saved = drop(NPar, S),
    run(Body, [{try_table, Rest, NRes, Saved, Catches} | Ctrl], St);

run([{throw, TagIdx} | _], Ctrl, St) ->
    Tag = element(TagIdx + 1, (St#st.inst)#inst.tags),
    {func, NParams} = tag_arity(Tag),
    {RevArgs, Stack1} = split(NParams, St#st.stack),
    throw_exn(#exn{tag = Tag, values = lists:reverse(RevArgs)},
              Ctrl, St#st{stack = Stack1});

run([throw_ref | _], _Ctrl, #st{stack = [null | _]}) ->
    wasm_error:trap(null_reference);
run([throw_ref | _], Ctrl, #st{stack = [#exn{} = E | S]} = St) ->
    throw_exn(E, Ctrl, St#st{stack = S});

run([{if_, NPar, NRes, Then, Else} | Rest], Ctrl, #st{stack = [C | S]} = St) ->
    Body = case C of 0 -> Else; _ -> Then end,
    Saved = drop(NPar, S),
    run(Body, [{block, Rest, NRes, Saved} | Ctrl], St#st{stack = S});

run([{br, N} | _], Ctrl, St) ->
    branch(N, Ctrl, St);
run([{br_if, N} | Rest], Ctrl, #st{stack = [C | S]} = St) ->
    case C of
        0 -> run(Rest, Ctrl, St#st{stack = S});
        _ -> branch(N, Ctrl, St#st{stack = S})
    end;
run([{br_table, Labels, Default} | _], Ctrl, #st{stack = [I | S]} = St) ->
    N = select_label(I, Labels, Default),
    branch(N, Ctrl, St#st{stack = S});

run([return | _], Ctrl, St) ->
    {func, NRes} = lists:last(Ctrl),
    leave(NRes, St);

run([{call, F} | Rest], Ctrl, St) ->
    do_call(F, Rest, Ctrl, charge(?FUEL_PER_CALL, St));

%% A tail call replaces the current invocation rather than nesting inside it.
%%
%% This falls out of frames being explicit. `enter/5' pushes a frame; a tail
%% call runs the callee's body against the frame list unchanged, so `leave/2'
%% later pops the *original* caller's frame and the callee returns straight to
%% it. Depth does not grow either, which is what makes unbounded mutual tail
%% recursion run in constant space rather than exhausting `max_depth'.
run([{return_call, F} | _], _Ctrl, St) ->
    do_return_call(F, charge(?FUEL_PER_CALL, St));

run([{return_call_indirect, TypeIdx, TableIdx} | _], Ctrl,
    #st{stack = [I | S]} = St0) ->
    St = charge(?FUEL_PER_CALL, St0#st{stack = S}),
    case indirect_target(TypeIdx, TableIdx, I, St) of
        {same, F} -> do_return_call(F, St);
        %% A callee in another instance cannot reuse this frame, because it
        %% runs against its own state. It is called normally and this function
        %% then returns its results, which is observably the same thing apart
        %% from not being space-safe across the boundary.
        {foreign, FInst, F} -> foreign_call(FInst, F, [return], Ctrl, St)
    end;

run([{call_indirect, TypeIdx, TableIdx} | Rest], Ctrl,
    #st{stack = [I | S]} = St0) ->
    St = charge(?FUEL_PER_CALL, St0#st{stack = S}),
    case indirect_target(TypeIdx, TableIdx, I, St) of
        {same, F} -> do_call(F, Rest, Ctrl, St);
        %% A reference from another module runs against *its* instance: its
        %% memory, its globals, its tables. Doing otherwise would let a shared
        %% table smuggle one module's code into another's state.
        {foreign, FInst, F} -> foreign_call(FInst, F, Rest, Ctrl, St)
    end;

%% A call through a reference. The reference already carries its defining
%% instance, so this reuses the same dispatch `call_indirect' does; what it does
%% not need is the table lookup or the run-time type check, since the type came
%% from the instruction and the validator has already matched it.
run([{call_ref, _TypeIdx} | Rest], Ctrl, #st{stack = [R | S]} = St0) ->
    St = charge(?FUEL_PER_CALL, St0#st{stack = S}),
    case ref_target(R, St) of
        {same, F} -> do_call(F, Rest, Ctrl, St);
        {foreign, FInst, F} -> foreign_call(FInst, F, Rest, Ctrl, St)
    end;
run([{return_call_ref, _TypeIdx} | _], Ctrl, #st{stack = [R | S]} = St0) ->
    St = charge(?FUEL_PER_CALL, St0#st{stack = S}),
    case ref_target(R, St) of
        {same, F} -> do_return_call(F, St);
        {foreign, FInst, F} -> foreign_call(FInst, F, [return], Ctrl, St)
    end;

run([ref_as_non_null | _], _Ctrl, #st{stack = [null | _]}) ->
    wasm_error:trap(null_reference);
run([ref_as_non_null | Rest], Ctrl, St) ->
    run(Rest, Ctrl, St);

%% Branch when the reference *is* null; the reference is consumed either way,
%% and on the fall-through it is pushed back now known to be non-null.
run([{br_on_null, N} | Rest], Ctrl, #st{stack = [R | S]} = St) ->
    case R of
        null -> branch(N, Ctrl, St#st{stack = S});
        _ -> run(Rest, Ctrl, St)
    end;
%% The mirror: branch when it is *not* null, carrying the reference with it.
run([{br_on_non_null, N} | Rest], Ctrl, #st{stack = [R | S]} = St) ->
    case R of
        null -> run(Rest, Ctrl, St#st{stack = S});
        _ -> branch(N, Ctrl, St)
    end;

%% - parametric ------------------------------------------------------------
run([drop | Rest], Ctrl, #st{stack = [_ | S]} = St) ->
    run(Rest, Ctrl, St#st{stack = S});
run([{select, _} | Rest], Ctrl, #st{stack = [C, B, A | S]} = St) ->
    V = case C of 0 -> B; _ -> A end,
    run(Rest, Ctrl, St#st{stack = [V | S]});

%% - superinstructions -----------------------------------------------------
%%
%% Fused by `wasm_instance:fuse/1' from the sequences that actually dominate
%% real compiler output. Each saves a dispatch and, for the arithmetic ones, an
%% intermediate push and pop. Local indices arrive pre-incremented so the
%% tuple access needs no arithmetic here.
run([{lg_lg, I, J} | Rest], Ctrl, #st{locals = L} = St) ->
    run2(Rest, Ctrl, St, element(J, L), element(I, L));
run([{lg_const, I, C} | Rest], Ctrl, #st{locals = L} = St) ->
    run2(Rest, Ctrl, St, C, element(I, L));
run([{lg_const_add, I, C} | Rest], Ctrl, #st{locals = L} = St) ->
    run1(Rest, Ctrl, St, wasm_num:wrap_s32(element(I, L) + C));
run([{lg_load, I, {_A, Offset, M}} | Rest], Ctrl,
    #st{stack = S, locals = L, mut = Mu} = St) ->
    Mem = element(M + 1, Mu#mut.mems),
    Addr = wasm_num:to_u32(element(I, L)) + Offset,
    V = wasm_num:wrap_s32(wasm_memory:load(Mem, Addr, 4)),
    run(Rest, Ctrl, St#st{stack = [V | S]});
%% The consuming end of the three rules above. Each takes a dispatch, a record
%% update and a cons cell out of a sequence that was already being fused up to
%% the instruction that used its result.
run([{lg_const_add_set, I, C, T} | Rest], Ctrl, #st{locals = L} = St) ->
    V = wasm_num:wrap_s32(element(I, L) + C),
    run(Rest, Ctrl, St#st{locals = setelement(T, L, V)});
run([{lg_const_add_tee, I, C, T} | Rest], Ctrl,
    #st{stack = S, locals = L} = St) ->
    V = wasm_num:wrap_s32(element(I, L) + C),
    run(Rest, Ctrl, St#st{stack = [V | S], locals = setelement(T, L, V)});
run([{lg_lg_store, I, J, {_A, Offset, M}} | Rest], Ctrl,
    #st{locals = L, mut = Mu} = St) ->
    Mem = element(M + 1, Mu#mut.mems),
    Addr = wasm_num:to_u32(element(I, L)) + Offset,
    ok = wasm_memory:store(Mem, Addr, 4, element(J, L)),
    run(Rest, Ctrl, St);
run([{lg_load_tee, I, {_A, Offset, M}, T} | Rest], Ctrl,
    #st{stack = S, locals = L, mut = Mu} = St) ->
    Mem = element(M + 1, Mu#mut.mems),
    Addr = wasm_num:to_u32(element(I, L)) + Offset,
    V = wasm_num:wrap_s32(wasm_memory:load(Mem, Addr, 4)),
    run(Rest, Ctrl, St#st{stack = [V | S], locals = setelement(T, L, V)});
run([{eqz_br_if, N} | Rest], Ctrl, #st{stack = [V | S]} = St) ->
    %% `i32.eqz' then `br_if' is "branch if zero", so the branch is taken
    %% exactly when the value is zero.
    case V of
        0 -> branch(N, Ctrl, St#st{stack = S});
        _ -> run(Rest, Ctrl, St#st{stack = S})
    end;

%% - variables -------------------------------------------------------------
run([{local_get, I} | Rest], Ctrl, #st{locals = L} = St) ->
    run1(Rest, Ctrl, St, element(I + 1, L));
run([{local_set, I} | Rest], Ctrl, #st{stack = [V | S], locals = L} = St) ->
    run(Rest, Ctrl, St#st{stack = S, locals = setelement(I + 1, L, V)});
run([{local_tee, I} | Rest], Ctrl, #st{stack = [V | _] = S, locals = L} = St) ->
    run(Rest, Ctrl, St#st{stack = S, locals = setelement(I + 1, L, V)});
run([{global_get, I} | Rest], Ctrl, #st{stack = S, mut = M} = St) ->
    run(Rest, Ctrl, St#st{stack = [element(I + 1, M#mut.globals) | S]});
run([{global_set, I} | Rest], Ctrl, #st{stack = [V | S], mut = M} = St) ->
    Mu1 = M#mut{globals = setelement(I + 1, M#mut.globals, V)},
    run(Rest, Ctrl, St#st{stack = S, mut = checkpoint(St, Mu1)});
%% A global another module can observe is a cell rather than a value, so the
%% tuple slot holds the handle and the access goes through it. Which globals
%% those are is decided when the IR is built, so the two clauses above stay a
%% tuple read and a tuple write.
run([{global_get_ref, I} | Rest], Ctrl, #st{stack = S, mut = M} = St) ->
    Cell = element(I + 1, M#mut.globals),
    run(Rest, Ctrl, St#st{stack = [wasm_global:get(Cell) | S]});
run([{global_set_ref, I} | Rest], Ctrl, #st{stack = [V | S], mut = M} = St) ->
    ok = wasm_global:set(element(I + 1, M#mut.globals), V),
    run(Rest, Ctrl, St#st{stack = S});

%% - references ------------------------------------------------------------
run([{ref_null, _T} | Rest], Ctrl, #st{stack = S} = St) ->
    run(Rest, Ctrl, St#st{stack = [null | S]});
run([ref_is_null | Rest], Ctrl, #st{stack = [R | S]} = St) ->
    V = case R of null -> 1; _ -> 0 end,
    run(Rest, Ctrl, St#st{stack = [V | S]});
run([{ref_func, F} | Rest], Ctrl, #st{stack = S} = St) ->
    %% Names the defining instance, so the reference stays meaningful after it
    %% is stored in a table another module imports. It names rather than
    %% carries it: an instance record holds the module's compiled functions,
    %% and a table of these goes through `ets:insert', which copies without
    %% preserving sharing.
    run(Rest, Ctrl, St#st{stack = [{funcref, inst_id(St), F} | S]});

%% - constants -------------------------------------------------------------
run([{i32_const, V} | Rest], Ctrl, St) ->
    run1(Rest, Ctrl, St, V);
run([{i64_const, V} | Rest], Ctrl, #st{stack = S} = St) ->
    run(Rest, Ctrl, St#st{stack = [V | S]});
run([{f32_const, V} | Rest], Ctrl, #st{stack = S} = St) ->
    run(Rest, Ctrl, St#st{stack = [V | S]});
run([{f64_const, V} | Rest], Ctrl, #st{stack = S} = St) ->
    run(Rest, Ctrl, St#st{stack = [V | S]});

%% - memory ----------------------------------------------------------------
run([{memory_size, M} | Rest], Ctrl, #st{stack = S, mut = Mu} = St) ->
    Mem = element(M + 1, Mu#mut.mems),
    run(Rest, Ctrl, St#st{stack = [wasm_memory:size_pages(Mem) | S]});
%% The 64-bit forms carry a trailing width tag from IR build. Page counts and
%% lengths are ordinary Erlang integers either way; the width says how wide the
%% operands are, and so how a negative one is to be read as unsigned.
run([{memory_grow, M, 64} | Rest], Ctrl, St) ->
    memory_grow(M, 64, Rest, Ctrl, St);
run([{memory_fill, M, 64} | Rest], Ctrl, St) ->
    memory_fill(M, 64, Rest, Ctrl, St);
run([{memory_copy, D, Src, DW, SW} | Rest], Ctrl, St) ->
    memory_copy(D, Src, DW, SW, Rest, Ctrl, St);
run([{memory_init, D, M, 64} | Rest], Ctrl, St) ->
    memory_init(D, M, 64, Rest, Ctrl, St);
run([{memory_grow, M} | Rest], Ctrl, St) ->
    memory_grow(M, 32, Rest, Ctrl, St);
run([{memory_fill, M} | Rest], Ctrl, St) ->
    memory_fill(M, 32, Rest, Ctrl, St);
run([{memory_copy, D, Src} | Rest], Ctrl, St) ->
    memory_copy(D, Src, 32, 32, Rest, Ctrl, St);
run([{memory_init, D, M} | Rest], Ctrl, St) ->
    memory_init(D, M, 32, Rest, Ctrl, St);
run([{data_drop, D} | Rest], Ctrl, #st{mut = Mu} = St) ->
    run(Rest, Ctrl, St#st{mut = data_drop_at(St#st.inst, Mu, D)});

%% - tables ----------------------------------------------------------------
run([{table_get, T} | Rest], Ctrl, #st{stack = [I | S], mut = Mu} = St) ->
    Table = element(T + 1, Mu#mut.tables),
    Idx = table_index(I),
    case Idx < wasm_table:size(Table) of
        false -> wasm_error:trap(out_of_bounds_table_access, #{index => Idx});
        true -> run(Rest, Ctrl, St#st{stack = [wasm_table:get(Table, Idx) | S]})
    end;
run([{table_set, T} | Rest], Ctrl, #st{stack = [V, I | S], mut = Mu} = St) ->
    Table = element(T + 1, Mu#mut.tables),
    Idx = table_index(I),
    case Idx < wasm_table:size(Table) of
        false -> wasm_error:trap(out_of_bounds_table_access, #{index => Idx});
        true ->
            %% In place: the table is shared, so `#mut{}' does not change.
            ok = wasm_table:set(Table, Idx, V),
            run(Rest, Ctrl, St#st{stack = S})
    end;
run([{table_size, T} | Rest], Ctrl, #st{stack = S, mut = Mu} = St) ->
    Table = element(T + 1, Mu#mut.tables),
    run(Rest, Ctrl, St#st{stack = [wasm_table:size(Table) | S]});
run([{elem_drop, E} | Rest], Ctrl, #st{mut = Mu} = St) ->
    Mu1 = Mu#mut{dropped_elems = maps:put(E, true, Mu#mut.dropped_elems)},
    run(Rest, Ctrl, St#st{mut = checkpoint(St, Mu1)});
run([{table_grow, T} | Rest], Ctrl, #st{stack = [N, Init | S], mut = Mu} = St) ->
    Table = element(T + 1, Mu#mut.tables),
    Delta = table_index(N),
    %% Like `memory.grow', refusal is the value -1 rather than a trap.
    case wasm_table:grow(Table, Delta, Init) of
        {ok, Old} -> run(Rest, Ctrl, St#st{stack = [Old | S]});
        {error, exceeds_max} -> run(Rest, Ctrl, St#st{stack = [-1 | S]})
    end;
run([{table_fill, T} | Rest], Ctrl, #st{stack = [N, V, D | S], mut = Mu} = St) ->
    Table = element(T + 1, Mu#mut.tables),
    Dst = table_index(D),
    Len = table_index(N),
    check_table_range(Dst, Len, wasm_table:size(Table)),
    ok = wasm_table:fill(Table, Dst, Len, V),
    run(Rest, Ctrl, St#st{stack = S});
run([{table_copy, Dt, Stb} | Rest], Ctrl, #st{stack = [N, Sa, Da | S], mut = Mu} = St) ->
    DstT = element(Dt + 1, Mu#mut.tables),
    SrcT = element(Stb + 1, Mu#mut.tables),
    Dst = table_index(Da),
    Src = table_index(Sa),
    Len = table_index(N),
    check_table_range(Dst, Len, wasm_table:size(DstT)),
    check_table_range(Src, Len, wasm_table:size(SrcT)),
    ok = wasm_table:copy(DstT, Dst, SrcT, Src, Len),
    run(Rest, Ctrl, St#st{stack = S});
run([{table_init, E, T} | Rest], Ctrl, #st{stack = [N, So, Da | S], mut = Mu} = St) ->
    Table = element(T + 1, Mu#mut.tables),
    Seg = case maps:is_key(E, Mu#mut.dropped_elems) of
              true -> [];
              false -> element(E + 1, (St#st.inst)#inst.elems)
          end,
    Dst = table_index(Da),
    Src = table_index(So),
    Len = table_index(N),
    check_table_range(Dst, Len, wasm_table:size(Table)),
    check_table_range(Src, Len, length(Seg)),
    ok = wasm_table:init(Table, Dst, lists:sublist(Seg, Src + 1, Len)),
    run(Rest, Ctrl, St#st{stack = S});

%% - vectors ---------------------------------------------------------------
%% Placed before the scalar loads and stores because the lane-indexed vector
%% accesses share their `{Op, MemArg}' shape with a third element.
run([{v128_const, Bytes} | Rest], Ctrl, #st{stack = S} = St) ->
    run(Rest, Ctrl, St#st{stack = [Bytes | S]});
run([{i8x16_shuffle, Lanes} | Rest], Ctrl, #st{stack = [B, A | S]} = St) ->
    run(Rest, Ctrl, St#st{stack = [wasm_simd:shuffle(Lanes, A, B) | S]});
run([{simd_ternary, Op} | Rest], Ctrl, #st{stack = [C, B, A | S]} = St) ->
    run(Rest, Ctrl, St#st{stack = [wasm_simd:ternary(Op, A, B, C) | S]});
run([{simd_lane, Op, Lane} | Rest], Ctrl, #st{stack = [V | S]} = St) ->
    run(Rest, Ctrl, St#st{stack = [wasm_simd:extract(Op, Lane, V) | S]});
run([{simd_replace, Op, Lane} | Rest], Ctrl, #st{stack = [X, V | S]} = St) ->
    run(Rest, Ctrl, St#st{stack = [wasm_simd:replace(Op, Lane, V, X) | S]});
%% The four that touch memory go through the same helpers generated code
%% calls, so a bound or an address width has one definition. The rest are pure
%% and both sides call `wasm_simd` directly.
run([{simd_load, Op, Offset, M, W, N} | Rest], Ctrl,
    #st{stack = [Base | S], mut = Mu} = St) ->
    run(Rest, Ctrl,
        St#st{stack = [simd_load_at(Mu, M, Op, Offset, W, N, Base) | S]});
run([{simd_store, Offset, M, W} | Rest], Ctrl,
    #st{stack = [V, Base | S], mut = Mu} = St) ->
    ok = simd_store_at(Mu, M, Offset, W, Base, V),
    run(Rest, Ctrl, St#st{stack = S});
run([{simd_load_lane, Op, Offset, M, W, N, Lane} | Rest], Ctrl,
    #st{stack = [V, Base | S], mut = Mu} = St) ->
    run(Rest, Ctrl,
        St#st{stack = [simd_load_lane_at(Mu, M, Op, Offset, W, N, Lane, Base, V)
                       | S]});
run([{simd_store_lane, Op, Offset, M, W, Lane} | Rest], Ctrl,
    #st{stack = [V, Base | S], mut = Mu} = St) ->
    ok = simd_store_lane_at(Mu, M, Op, Offset, W, Lane, Base, V),
    run(Rest, Ctrl, St#st{stack = S});
run([{simd_binary, Op} | Rest], Ctrl, #st{stack = [B, A | S]} = St) ->
    run(Rest, Ctrl, St#st{stack = [wasm_simd:binary_op(Op, A, B) | S]});
run([{simd_unary, Op} | Rest], Ctrl, #st{stack = [A | S]} = St) ->
    run(Rest, Ctrl, St#st{stack = [wasm_simd:unary(Op, A) | S]});
run([{simd_shift, Op} | Rest], Ctrl, #st{stack = [N, A | S]} = St) ->
    run(Rest, Ctrl, St#st{stack = [wasm_simd:shift(Op, A, N) | S]});
run([{simd_splat, Op} | Rest], Ctrl, #st{stack = [X | S]} = St) ->
    run(Rest, Ctrl, St#st{stack = [wasm_simd:splat(Op, X) | S]});

%% - atomics ---------------------------------------------------------------
%% Placed before the ordinary loads and stores because they share the
%% `{Op, MemArg}' shape; the lowering pass has already told them apart, so this
%% is a distinct tag rather than a guard.
run([{atomic, load, W, T, Offset, M, AW} | Rest], Ctrl,
    #st{stack = [Base | S], mut = Mu} = St) ->
    Raw = wasm_memory:atomic_load(mem_at(M, Mu), unsigned(Base, AW) + Offset, W),
    run(Rest, Ctrl, St#st{stack = [wrap(T, Raw) | S]});
run([{atomic, store, W, _T, Offset, M, AW} | Rest], Ctrl,
    #st{stack = [V, Base | S], mut = Mu} = St) ->
    ok = wasm_memory:atomic_store(mem_at(M, Mu), unsigned(Base, AW) + Offset,
                                  W, V),
    run(Rest, Ctrl, St#st{stack = S});
run([{atomic, {rmw, Op}, W, T, Offset, M, AW} | Rest], Ctrl,
    #st{stack = [V, Base | S], mut = Mu} = St) ->
    Old = wasm_memory:atomic_rmw(mem_at(M, Mu), unsigned(Base, AW) + Offset,
                                 W, Op, V),
    run(Rest, Ctrl, St#st{stack = [wrap(T, Old) | S]});
run([{atomic, cmpxchg, W, T, Offset, M, AW} | Rest], Ctrl,
    #st{stack = [New, Expected, Base | S], mut = Mu} = St) ->
    Old = wasm_memory:atomic_cmpxchg(mem_at(M, Mu),
                                     unsigned(Base, AW) + Offset,
                                     W, Expected, New),
    run(Rest, Ctrl, St#st{stack = [wrap(T, Old) | S]});
run([{atomic, wait, W, _T, Offset, M, AW} | Rest], Ctrl,
    #st{stack = [Timeout, Expected, Base | S], mut = Mu} = St) ->
    Mem = mem_at(M, Mu),
    Addr = unsigned(Base, AW) + Offset,
    R = atomic_wait(Mem, Addr, W, Expected, Timeout),
    run(Rest, Ctrl, St#st{stack = [R | S]});
run([{atomic, notify, W, _T, Offset, M, AW} | Rest], Ctrl,
    #st{stack = [Count, Base | S], mut = Mu} = St) ->
    Mem = mem_at(M, Mu),
    Addr = unsigned(Base, AW) + Offset,
    %% The address is still checked, so notifying out of bounds traps even
    %% though nothing is read. Notifying a memory nobody waits on answers zero.
    _ = wasm_memory:atomic_load(Mem, Addr, W),
    N = wasm_wait:notify(wasm_memory:id(Mem), Addr, unsigned(Count, 32)),
    run(Rest, Ctrl, St#st{stack = [N | S]});
%% Every access here is through `atomics', which is sequentially consistent, so
%% there is no reordering for a fence to prevent.
run([atomic_fence | Rest], Ctrl, St) ->
    run(Rest, Ctrl, St);

%% - loads and stores ------------------------------------------------------
%% The `is_integer(Offset)' guard is not redundant. A memory argument is
%% `{Align, Offset, Mem}', and a *reference type* is `{ref, Null, HeapType}':
%% both are three-element tuples inside a two-element instruction, so
%% `{ref_test, {ref, null, none}}' matched this clause and computed an address
%% from the atom `none'. The guard tells the two shapes apart by content, which
%% clause ordering only hid.
run([{Op, {_Align, Offset, M}} | Rest], Ctrl, St)
  when is_atom(Op), is_integer(Offset) ->
    run(Rest, Ctrl, mem_op(Op, Offset, M, 32, St));
run([{Op, {_Align, Offset, M, 64}} | Rest], Ctrl, St)
  when is_atom(Op), is_integer(Offset) ->
    run(Rest, Ctrl, mem_op(Op, Offset, M, 64, St));

%% - garbage collection ----------------------------------------------------
run([{struct_new, T} | Rest], Ctrl, St) ->
    Fs = struct_fields(T, St),
    {RevFields, S} = split(length(Fs), St#st.stack),
    %% Packed fields are truncated on the way in here too, not only in
    %% `struct.set': a field declared i8 must never hold more than a byte.
    Narrowed = [narrow(F, V) || {F, V} <- lists:zip(Fs, lists:reverse(RevFields))],
    Ref = wasm_heap:new_struct(heap(St), T, Narrowed),
    run(Rest, Ctrl, St#st{stack = [Ref | S]});
run([{struct_new_default, T} | Rest], Ctrl, #st{stack = S} = St) ->
    Fields = [field_default(F) || F <- struct_fields(T, St)],
    Ref = wasm_heap:new_struct(heap(St), T, Fields),
    run(Rest, Ctrl, St#st{stack = [Ref | S]});
run([{Op, T, F} | Rest], Ctrl, #st{stack = [R | S]} = St)
  when Op =:= struct_get; Op =:= struct_get_s; Op =:= struct_get_u ->
    null_check(R),
    V = widen(Op, field_at(T, F, St), wasm_heap:get_field(heap(St), R, F)),
    run(Rest, Ctrl, St#st{stack = [V | S]});
run([{struct_set, T, F} | Rest], Ctrl, #st{stack = [V, R | S]} = St) ->
    null_check(R),
    ok = wasm_heap:set_field(heap(St), R, F, narrow(field_at(T, F, St), V)),
    run(Rest, Ctrl, St#st{stack = S});

run([{array_new, T} | Rest], Ctrl, #st{stack = [N, V | S]} = St) ->
    Field = elem_of(T, St),
    Ref = wasm_heap:new_array(heap(St), T, alloc_len(N), narrow(Field, V),
                              traced(Field)),
    run(Rest, Ctrl, St#st{stack = [Ref | S]});
run([{array_new_default, T} | Rest], Ctrl, #st{stack = [N | S]} = St) ->
    Field = elem_of(T, St),
    Ref = wasm_heap:new_array(heap(St), T, alloc_len(N), field_default(Field),
                              traced(Field)),
    run(Rest, Ctrl, St#st{stack = [Ref | S]});
run([{array_new_fixed, T, N} | Rest], Ctrl, St) ->
    {RevVs, S} = split(N, St#st.stack),
    Field = elem_of(T, St),
    Vs = [narrow(Field, V) || V <- lists:reverse(RevVs)],
    Ref = wasm_heap:new_array(heap(St), T, N, undefined, traced(Field)),
    ok = write_elements(heap(St), Ref, 0, Vs),
    run(Rest, Ctrl, St#st{stack = [Ref | S]});
run([{Op, T} | Rest], Ctrl, #st{stack = [I, R | S]} = St)
  when Op =:= array_get; Op =:= array_get_s; Op =:= array_get_u ->
    null_check(R),
    V = widen(Op, elem_of(T, St),
              wasm_heap:array_get(heap(St), R, wasm_num:to_u32(I))),
    run(Rest, Ctrl, St#st{stack = [V | S]});
run([{array_set, T} | Rest], Ctrl, #st{stack = [V, I, R | S]} = St) ->
    null_check(R),
    ok = wasm_heap:array_set(heap(St), R, wasm_num:to_u32(I),
                             narrow(elem_of(T, St), V)),
    run(Rest, Ctrl, St#st{stack = S});
run([array_len | Rest], Ctrl, #st{stack = [R | S]} = St) ->
    null_check(R),
    run(Rest, Ctrl, St#st{stack = [wasm_heap:array_len(heap(St), R) | S]});
run([{array_fill, T} | Rest], Ctrl, #st{stack = [N, V, D, R | S]} = St) ->
    null_check(R),
    H = heap(St),
    Val = narrow(elem_of(T, St), V),
    Dst = wasm_num:to_u32(D),
    Len = wasm_num:to_u32(N),
    check_array_range(H, R, Dst, Len),
    ok = wasm_heap:array_fill(H, R, Dst, Len, Val),
    run(Rest, Ctrl, St#st{stack = S});
run([{array_copy, D, _Src} | Rest], Ctrl,
    #st{stack = [N, SrcI, SrcR, DstI, DstR | S]} = St) ->
    null_check(DstR), null_check(SrcR),
    H = heap(St),
    Len = wasm_num:to_u32(N),
    SrcStart = wasm_num:to_u32(SrcI),
    DstStart = wasm_num:to_u32(DstI),
    %% Both ranges are checked before anything is written, so a copy that traps
    %% leaves the destination untouched.
    check_array_range(H, SrcR, SrcStart, Len),
    check_array_range(H, DstR, DstStart, Len),
    _ = D,
    %% Read every source element before writing any of them, so an overlapping
    %% copy behaves. The list is then consumed in order rather than indexed with
    %% `lists:nth/2', which made this quadratic: 127, then 416, then 4604 ns per
    %% element as the length went 100, 1000, 10000.
    Vals = [wasm_heap:array_get(H, SrcR, SrcStart + I)
            || I <- lists:seq(0, Len - 1)],
    ok = write_elements(H, DstR, DstStart, Vals),
    run(Rest, Ctrl, St#st{stack = S});

%% An array built from a data or element segment. The segment is read as the
%% element type's storage width, so an array of i8 takes one byte per element
%% and an array of f64 takes eight.
run([{array_new_data, T, D} | Rest], Ctrl, #st{stack = [N, Off | S]} = St) ->
    Field = elem_of(T, St),
    Vals = data_elements(D, wasm_num:to_u32(Off), wasm_num:to_u32(N), Field, St),
    Ref = fill_new_array(heap(St), T, Vals, traced(Field)),
    run(Rest, Ctrl, St#st{stack = [Ref | S]});
run([{array_new_elem, T, E} | Rest], Ctrl, #st{stack = [N, Off | S]} = St) ->
    Vals = elem_elements(E, wasm_num:to_u32(Off), wasm_num:to_u32(N), St),
    Ref = fill_new_array(heap(St), T, Vals, traced(elem_of(T, St))),
    run(Rest, Ctrl, St#st{stack = [Ref | S]});
run([{array_init_data, T, D} | Rest], Ctrl,
    #st{stack = [N, Off, DstI, R | S]} = St) ->
    null_check(R),
    H = heap(St),
    Len = wasm_num:to_u32(N),
    check_array_range(H, R, wasm_num:to_u32(DstI), Len),
    Vals = data_elements(D, wasm_num:to_u32(Off), Len, elem_of(T, St), St),
    ok = write_elements(H, R, wasm_num:to_u32(DstI), Vals),
    run(Rest, Ctrl, St#st{stack = S});
run([{array_init_elem, T, E} | Rest], Ctrl,
    #st{stack = [N, Off, DstI, R | S]} = St) ->
    null_check(R),
    _ = T,
    H = heap(St),
    Len = wasm_num:to_u32(N),
    check_array_range(H, R, wasm_num:to_u32(DstI), Len),
    Vals = elem_elements(E, wasm_num:to_u32(Off), Len, St),
    ok = write_elements(H, R, wasm_num:to_u32(DstI), Vals),
    run(Rest, Ctrl, St#st{stack = S});

run([ref_eq | Rest], Ctrl, #st{stack = [B, A | S]} = St) ->
    run(Rest, Ctrl, St#st{stack = [bool(A =:= B) | S]});
run([{ref_test, Target} | Rest], Ctrl, #st{stack = [R | S]} = St) ->
    run(Rest, Ctrl, St#st{stack = [bool(ref_matches(R, Target, St)) | S]});
run([{ref_cast, Target} | Rest], Ctrl, #st{stack = [R | _]} = St) ->
    case ref_matches(R, Target, St) of
        true -> run(Rest, Ctrl, St);
        false -> wasm_error:trap(cast_failure, #{target => Target})
    end;
run([{br_on_cast, N, _From, To} | Rest], Ctrl, #st{stack = [R | _]} = St) ->
    case ref_matches(R, To, St) of
        true -> branch(N, Ctrl, St);
        false -> run(Rest, Ctrl, St)
    end;
run([{br_on_cast_fail, N, _From, To} | Rest], Ctrl, #st{stack = [R | _]} = St) ->
    case ref_matches(R, To, St) of
        true -> run(Rest, Ctrl, St);
        false -> branch(N, Ctrl, St)
    end;

%% The two conversions move a reference between the `extern' and `any'
%% hierarchies. Neither allocates, but neither is a no-op either: the whole
%% point is that the *same* reference reads as a different heap type
%% afterwards, so `ref.test' has to be able to tell which side it is on.
%% Symmetric wrappers. Converting an internal reference outwards and back must
%% give the identical reference, and so must the reverse for a host one, which
%% is why each direction unwraps its counterpart rather than wrapping again.
run([Op | Rest], Ctrl, #st{stack = [null | _]} = St)
  when Op =:= extern_convert_any; Op =:= any_convert_extern ->
    run(Rest, Ctrl, St);
run([extern_convert_any | Rest], Ctrl, #st{stack = [{internal, V} | S]} = St) ->
    run(Rest, Ctrl, St#st{stack = [V | S]});
run([extern_convert_any | Rest], Ctrl, #st{stack = [V | S]} = St) ->
    run(Rest, Ctrl, St#st{stack = [{extern, V} | S]});
run([any_convert_extern | Rest], Ctrl, #st{stack = [{extern, V} | S]} = St) ->
    run(Rest, Ctrl, St#st{stack = [V | S]});
run([any_convert_extern | Rest], Ctrl, #st{stack = [V | S]} = St) ->
    run(Rest, Ctrl, St#st{stack = [{internal, V} | S]});
run([ref_i31 | Rest], Ctrl, #st{stack = [V | S]} = St) ->
    %% An i31 keeps only the low 31 bits, sign-extended when read back.
    run(Rest, Ctrl, St#st{stack = [{i31, V band 16#7FFFFFFF} | S]});
run([i31_get_s | Rest], Ctrl, #st{stack = [R | S]} = St) ->
    null_check(R),
    {i31, V} = R,
    Signed = case V >= 16#40000000 of
                 true -> V - 16#80000000;
                 false -> V
             end,
    run(Rest, Ctrl, St#st{stack = [Signed | S]});
run([i31_get_u | Rest], Ctrl, #st{stack = [R | S]} = St) ->
    null_check(R),
    {i31, V} = R,
    run(Rest, Ctrl, St#st{stack = [V | S]});

%% - numeric ---------------------------------------------------------------
run([Op | Rest], Ctrl, St) when is_atom(Op) ->
    run(Rest, Ctrl, numeric(Op, St)).

%% The operations the bounded cache handles in its own clauses. Division and
%% remainder are deliberately absent: they trap, and a trap out of a slotted
%% clause is one more path to reason about for two instructions that are not
%% hot. They fall back and are unaffected.
-define(I32_BINOP(Op),
        (Op =:= i32_add orelse Op =:= i32_sub orelse Op =:= i32_mul orelse
         Op =:= i32_and orelse Op =:= i32_or orelse Op =:= i32_xor orelse
         Op =:= i32_shl orelse Op =:= i32_shr_s orelse Op =:= i32_shr_u orelse
         Op =:= i32_rotl orelse Op =:= i32_rotr)).
-define(I64_BINOP(Op),
        (Op =:= i64_add orelse Op =:= i64_sub orelse Op =:= i64_mul orelse
         Op =:= i64_and orelse Op =:= i64_or orelse Op =:= i64_xor orelse
         Op =:= i64_shl orelse Op =:= i64_shr_s orelse Op =:= i64_shr_u orelse
         Op =:= i64_rotl orelse Op =:= i64_rotr)).
-define(I32_RELOP(Op),
        (Op =:= i32_eq orelse Op =:= i32_ne orelse Op =:= i32_lt_s orelse
         Op =:= i32_lt_u orelse Op =:= i32_gt_s orelse Op =:= i32_gt_u orelse
         Op =:= i32_le_s orelse Op =:= i32_le_u orelse Op =:= i32_ge_s orelse
         Op =:= i32_ge_u)).

%%% ------------------------------------------------ bounded operand cache ---
%%
%% The top one or two operands live in arguments rather than in `#st.stack'.
%%
%% The cost this removes is not the cons cell, which is two words. It is the
%% record update: `St#st{stack = [V | S]}' copies a nine-field record, ten
%% words, and every instruction that touches the stack did one. Counting
%% dispatches said the same thing from the other side -- `fc183c1' removed
%% 6.25% of them and bought 2.5% of the time, so the time is in what the
%% dispatch does, not in reaching it.
%%
%% This is wasm3's technique and not more of it: wasm3 keeps *one* integer and
%% *one* float register in its calling convention, not the whole stack. Erlang
%% caps arity at 255 and real functions exceed that in locals alone, so a
%% design that passed everything was never available. `#st.stack' remains the
%% spill area and every boundary -- a branch, a call, a block, anything not
%% listed below -- spills to it first, so nothing outside these clauses needs
%% to know slots exist.
%%
%% `A' is the top of the stack and `B' the one under it. The last clause of
%% each spills and hands back to `run/3', which is what makes this safe to add
%% instruction by instruction rather than all at once.

%% - one operand cached ----------------------------------------------------

%% A constant feeding an operation is one operand, not two: reading the next
%% instruction here keeps both slots and skips a dispatch. Without it a
%% constant is the thing that forces the cache to shift, which on the loop was
%% four of the fifteen instructions.
run1([{i32_const, V}, Op | Rest], Ctrl, St, A) when ?I32_BINOP(Op) ->
    run1(Rest, Ctrl, St, i32_binop(Op, A, V));
run1([{i32_const, V}, Op | Rest], Ctrl, St, A) when ?I32_RELOP(Op) ->
    run1(Rest, Ctrl, St, int_relop(Op, A, V, 32));
run1([{i64_const, V}, Op | Rest], Ctrl, St, A) when ?I64_BINOP(Op) ->
    run1(Rest, Ctrl, St, i64_binop(Op, A, V));
run1([{i32_const, V} | Rest], Ctrl, St, A) ->
    run2(Rest, Ctrl, St, V, A);
run1([{i64_const, V} | Rest], Ctrl, St, A) ->
    run2(Rest, Ctrl, St, V, A);
run1([{local_get, I} | Rest], Ctrl, #st{locals = L} = St, A) ->
    run2(Rest, Ctrl, St, element(I + 1, L), A);
%% Consumers, not entry points. These fire only when the cache is already
%% holding something, so they can only remove a spill and can never add one.
%% That distinction is the whole lesson of the QuickJS regression: an entry
%% point costs every time the next instruction is not held, and a consumer
%% costs nothing ever.
%%
%% The address is what is in the slot and the result goes back into it, so a
%% load in the middle of an address calculation touches the record not at all.
%% Only the 32-bit memarg, matched by its three elements; a 64-bit memory tags
%% a fourth and falls through.
run1([{i32_load, {_A, Off, M}} | Rest], Ctrl, #st{mut = Mu} = St, A) ->
    Mem = element(M + 1, Mu#mut.mems),
    Addr = wasm_num:to_u32(A) + Off,
    run1(Rest, Ctrl, St, wasm_num:wrap_s32(wasm_memory:load(Mem, Addr, 4)));
run1([{global_get, I} | Rest], Ctrl, #st{mut = Mu} = St, A) ->
    run2(Rest, Ctrl, St, element(I + 1, Mu#mut.globals), A);
run1([{local_set, I} | Rest], Ctrl, #st{locals = L} = St, A) ->
    run(Rest, Ctrl, St#st{locals = setelement(I + 1, L, A)});
run1([{local_tee, I} | Rest], Ctrl, #st{locals = L} = St, A) ->
    run1(Rest, Ctrl, St#st{locals = setelement(I + 1, L, A)}, A);
%% The second operand comes off the stack, which is still cheaper than the
%% unslotted form: one record update instead of two, and one cons instead of
%% three.
%% One type test and one jump table rather than a guard per family. The cache
%% holds a minority of the instruction set and real compiler output reaches the
%% fallback constantly, so the fallback has to be the cheap answer.
run1([Op | Rest] = Is, Ctrl, St, A) when is_atom(Op) ->
    case op_kind(Op) of
        b32 -> #st{stack = [B | S]} = St,
               run1(Rest, Ctrl, St#st{stack = S}, i32_binop(Op, B, A));
        r32 -> #st{stack = [B | S]} = St,
               run1(Rest, Ctrl, St#st{stack = S}, int_relop(Op, B, A, 32));
        b64 -> #st{stack = [B | S]} = St,
               run1(Rest, Ctrl, St#st{stack = S}, i64_binop(Op, B, A));
        r64 -> #st{stack = [B | S]} = St,
               run1(Rest, Ctrl, St#st{stack = S}, int_relop(Op, B, A, 64));
        eqz -> run1(Rest, Ctrl, St, case A of 0 -> 1; _ -> 0 end);
        none -> spill1(Is, Ctrl, St, A)
    end;
run1([{br_if, N} | Rest], Ctrl, St, A) ->
    case A of
        0 -> run(Rest, Ctrl, St);
        _ -> branch(N, Ctrl, St)
    end;
run1([{eqz_br_if, N} | Rest], Ctrl, St, A) ->
    case A of
        0 -> branch(N, Ctrl, St);
        _ -> run(Rest, Ctrl, St)
    end;
%% Everything else: spill and carry on. An operand is in a slot only between
%% its producer and its consumer within one straight-line run.
run1(Is, Ctrl, St, A) -> spill1(Is, Ctrl, St, A).

spill1(Is, Ctrl, #st{stack = S} = St, A) ->
    run(Is, Ctrl, St#st{stack = [A | S]}).

%% - two operands cached ---------------------------------------------------

run2([Op | Rest] = Is, Ctrl, St, A, B) when is_atom(Op) ->
    case op_kind(Op) of
        b32 -> run1(Rest, Ctrl, St, i32_binop(Op, B, A));
        r32 -> run1(Rest, Ctrl, St, int_relop(Op, B, A, 32));
        b64 -> run1(Rest, Ctrl, St, i64_binop(Op, B, A));
        r64 -> run1(Rest, Ctrl, St, int_relop(Op, B, A, 64));
        eqz -> run2(Rest, Ctrl, St, case A of 0 -> 1; _ -> 0 end, B);
        none -> spill2(Is, Ctrl, St, A, B)
    end;
%% `i32.store' pops the value it was given last, so the value is the top slot
%% and the address the one under it. Both are in slots, so the store touches
%% the record not at all.
run2([{i32_store, {_A, Off, M}} | Rest], Ctrl, #st{mut = Mu} = St, A, B) ->
    Mem = element(M + 1, Mu#mut.mems),
    ok = wasm_memory:store(Mem, wasm_num:to_u32(B) + Off, 4, A),
    run(Rest, Ctrl, St);
run2([{local_set, I} | Rest], Ctrl, #st{locals = L} = St, A, B) ->
    run1(Rest, Ctrl, St#st{locals = setelement(I + 1, L, A)}, B);
run2([{local_tee, I} | Rest], Ctrl, #st{locals = L} = St, A, B) ->
    run2(Rest, Ctrl, St#st{locals = setelement(I + 1, L, A)}, A, B);
%% A third operand arrives: the oldest goes to the stack and the slots shift
%% down. This is the boundary of the cache and it costs exactly what pushing
%% cost before, which is why widening it further has to be measured rather
%% than assumed.
run2([{i32_const, V}, Op | Rest], Ctrl, St, A, B) when ?I32_BINOP(Op) ->
    run2(Rest, Ctrl, St, i32_binop(Op, A, V), B);
run2([{i32_const, V}, Op | Rest], Ctrl, St, A, B) when ?I32_RELOP(Op) ->
    run2(Rest, Ctrl, St, int_relop(Op, A, V, 32), B);
run2([{i64_const, V}, Op | Rest], Ctrl, St, A, B) when ?I64_BINOP(Op) ->
    run2(Rest, Ctrl, St, i64_binop(Op, A, V), B);
run2([{i32_const, V} | Rest], Ctrl, #st{stack = S} = St, A, B) ->
    run2(Rest, Ctrl, St#st{stack = [B | S]}, V, A);
run2([{i64_const, V} | Rest], Ctrl, #st{stack = S} = St, A, B) ->
    run2(Rest, Ctrl, St#st{stack = [B | S]}, V, A);
run2([{local_get, I} | Rest], Ctrl, #st{stack = S, locals = L} = St, A, B) ->
    run2(Rest, Ctrl, St#st{stack = [B | S]}, element(I + 1, L), A);
run2([{br_if, N} | Rest], Ctrl, St, A, B) ->
    case A of
        0 -> run1(Rest, Ctrl, St, B);
        _ -> branch(N, Ctrl, St#st{stack = [B | St#st.stack]})
    end;
run2(Is, Ctrl, St, A, B) -> spill2(Is, Ctrl, St, A, B).

spill2(Is, Ctrl, #st{stack = S} = St, A, B) ->
    run(Is, Ctrl, St#st{stack = [A, B | S]}).

-doc """
A call out of compiled code into an interpreted function.

`call/5` rebuilds fuel and depth from the `?BUDGET` process dictionary
(`init_state/4`) and so does not inherit a compiled caller's depth. This takes
it explicitly, which is what keeps `max_depth` meaning the same thing on both
sides of the crossing.

Priced before it was written, in `bench/paths/callcost.erl`: 37.4 to 43.4 ns
against the interpreter's own 43.5 to 44.7 for the same call.
""".
-spec call_out(#inst{}, #mut{}, non_neg_integer(), [term()], non_neg_integer(),
               module(), non_neg_integer()) -> {[term()], #mut{}}.
call_out(Inst, Mut, Idx, Args, Depth, Mod, Gen) ->
    %% Naming the generated module lets the interpreter this crosses into call
    %% back the other way, which is what stops the boundary being a one-way
    %% door. Safe without a lease of its own: this runs inside compiled code,
    %% so the invocation already holds one for the whole call.
    %%
    %% The name and the generation come from the caller as literals, because the
    %% caller *is* the generated module and knew both when it was built. Reading
    %% them out of the slot table instead would put a lookup on every crossing.
    Limits = (Inst#inst.limits)#{max_depth => max_depth(Inst) - Depth,
                                 code_module => {Mod, Gen}},
    {ok, Results, Mut1} = call(Inst, Mut, Idx, Args, Limits),
    {Results, Mut1}.

-doc """
Call a function this generated module does not hold but a sibling does.

One wasm module may be compiled into several generated ones, and a call between
them is a call, not a crossing: which unit holds which function was decided
before either was generated, so the name is a literal exactly as the caller's
own is. Going out through the interpreter and back in through the head of the
chain instead measured 268.5 ms against 174.4 on QuickJS.

`{error, _}` means the sibling's slot was refilled between generation and now,
which its stamp check catches. The crossing is the right answer to that, and it
is the same one a caller with no sibling at all gets.
""".
-spec shard_call(#inst{}, #mut{}, non_neg_integer(), [term()],
                 non_neg_integer(), module(), module(),
                 non_neg_integer() | binary()) -> {[term()], #mut{}}.
shard_call(Inst, Mut, Idx, Args, Depth, Target, Head, Gen) ->
    case Target:invoke(Inst, Mut, Idx, Args, Depth, Gen) of
        {ok, Results, Mut1} -> {Results, Mut1};
        {error, _} -> call_out(Inst, Mut, Idx, Args, Depth, Head, Gen)
    end.

-doc """
Charge one level of call depth, or raise what `enter/5` raises.

Compiled recursion runs on the Erlang stack, which grows on the process heap
rather than overflowing, so without this a runaway one exhausts memory instead
of trapping.
""".
-spec check_depth(#inst{}, non_neg_integer()) -> ok.
check_depth(Inst, Depth) ->
    case Depth >= max_depth(Inst) of
        true -> wasm_error:exhaustion(call_stack_exhausted, #{depth => Depth});
        false -> ok
    end.

max_depth(#inst{limits = L}) -> maps:get(max_depth, L, 1024).

-doc """
An indirect call out of compiled code.

`indirect_target/4` already does the whole resolution -- bounds, null, and the
type check against the canonical type -- and already tells a target in this
instance from one in another, so it is reused rather than restated and the three
traps it raises stay identical. It wants an `#st{}`, and the two fields it reads
are the two given here.

Every target crosses back into the interpreter, including one that was compiled
alongside the caller. Turning that into a local call needs a per-module
dispatcher and is worth its own measurement.
""".
-spec indirect_out(#inst{}, #mut{}, non_neg_integer(), non_neg_integer(),
                   term(), [term()], non_neg_integer(), module(),
                   non_neg_integer()) -> {[term()], #mut{}}.
indirect_out(Inst, Mut, TypeIdx, TableIdx, I, Args, Depth, Mod, Gen) ->
    case indirect_target(TypeIdx, TableIdx, I, Inst, Mut) of
        %% A target in this instance that was compiled alongside the caller is
        %% a call into generated code. Which function it is was not known until
        %% now, so this cannot be a local `apply` the way a direct call is, but
        %% it is still a call rather than a crossing. `Mod` is a literal the
        %% generator wrote in, and the invocation already holds a lease on it.
        {same, F} ->
            case Mod:invoke(Inst, Mut, F, Args, Depth, Gen) of
                {ok, Results, Mut1} -> {Results, Mut1};
                {error, _} -> call_out(Inst, Mut, F, Args, Depth, Mod, Gen)
            end;
        %% A callee in another instance runs against its own state, exactly as
        %% `foreign_call/5' has it: its mutable half is read, threaded and
        %% written back, and this instance's is untouched.
        {foreign, FInst, F} ->
            FMut = wasm_instance:mut(FInst),
            {ok, Results, FMut1} = call(FInst, FMut, F, Args, FInst#inst.limits),
            ok = wasm_instance:set_mut(FInst, FMut1),
            {Results, Mut}
    end.

-doc "A memory load, for generated code. Bounds-checks and traps as the interpreter does.".
-spec load_at(#mut{}, non_neg_integer(), pos_integer(), atom(),
              non_neg_integer()) -> term().
%% The width, the kind and the address all arrive settled.
%%
%% `load_spec/1` and the offset addition used to happen here, once per load, for
%% answers the generator knew when it emitted the call: the operation is a
%% literal at the call site and its width and signedness follow from it. So the
%% generator consults the table at *generation* time and the address arithmetic
%% is Core, which leaves this the memory access and nothing else. Measured at
%% 6.2 nanoseconds of an 18.9 nanosecond load.
%%
%% The table stays one table. `wasm_exec:load_spec/1` is exported for the
%% generator to read rather than copied into it, so a width can still only be
%% wrong in one place.
load_at(Mu, M, N, Kind, Addr) ->
    Mem = element(M + 1, Mu#mut.mems),
    decode_loaded(Kind, N, wasm_memory:load(Mem, Addr, N)).

-doc "A memory store. Writes into `atomics` in place, so `#mut{}` does not change.".
-spec store_at(#mut{}, non_neg_integer(), pos_integer(), atom(), non_neg_integer(),
               term()) -> ok.
store_at(Mu, M, N, Kind, Addr, Value) ->
    Mem = element(M + 1, Mu#mut.mems),
    wasm_memory:store(Mem, Addr, N, encode_stored(Kind, Value)).

%%% ------------------------------------------------------------ simd memory ---
%%
%% A vector access is a byte range rather than a word, so these go through
%% `wasm_memory:load_bytes/3` and `store_bytes/3` and not through `load_at/5`.
%% `W` is the memory's address width, which the lowering pass has already
%% resolved, so memory64 needs nothing special here.

-doc "A vector load, for generated code.".
-spec simd_load_at(#mut{}, non_neg_integer(), atom(), non_neg_integer(),
                   32 | 64, pos_integer(), term()) -> term().
simd_load_at(Mu, M, Op, Offset, W, N, Base) ->
    Mem = element(M + 1, Mu#mut.mems),
    wasm_simd:load(Op, wasm_memory:load_bytes(Mem, unsigned(Base, W) + Offset, N)).

-doc "A vector store. Writes bytes in place, so `#mut{}` does not change.".
-spec simd_store_at(#mut{}, non_neg_integer(), non_neg_integer(), 32 | 64,
                    term(), term()) -> ok.
simd_store_at(Mu, M, Offset, W, Base, V) ->
    Mem = element(M + 1, Mu#mut.mems),
    wasm_memory:store_bytes(Mem, unsigned(Base, W) + Offset,
                            wasm_simd:store_bytes(V)).

-doc "A vector load into one lane of an existing vector.".
-spec simd_load_lane_at(#mut{}, non_neg_integer(), atom(), non_neg_integer(),
                        32 | 64, pos_integer(), non_neg_integer(), term(),
                        term()) -> term().
simd_load_lane_at(Mu, M, Op, Offset, W, N, Lane, Base, V) ->
    Mem = element(M + 1, Mu#mut.mems),
    wasm_simd:load_lane(Op, Lane, V,
                        wasm_memory:load_bytes(Mem, unsigned(Base, W) + Offset, N)).

-doc "A store of one lane of a vector.".
-spec simd_store_lane_at(#mut{}, non_neg_integer(), atom(), non_neg_integer(),
                         32 | 64, non_neg_integer(), term(), term()) -> ok.
simd_store_lane_at(Mu, M, Op, Offset, W, Lane, Base, V) ->
    Mem = element(M + 1, Mu#mut.mems),
    wasm_memory:store_bytes(Mem, unsigned(Base, W) + Offset,
                            wasm_simd:store_lane_bytes(Op, Lane, V)).

-doc "Read a global that is an inline value rather than a shared cell.".
-spec global_at(#mut{}, non_neg_integer()) -> term().
global_at(Mu, I) -> element(I + 1, Mu#mut.globals).

-doc """
Write a global, and record the mutation so a trap does not lose it.

The checkpoint is the reason this is a named helper rather than a `setelement/3`
open-coded in Core: every store mutation has to be visible to the invocation's
catch, or what a trapping call wrote is silently rolled back in compiled code
and kept in interpreted code.
""".
-spec set_global_at(#inst{}, #mut{}, non_neg_integer(), term()) -> #mut{}.
set_global_at(#inst{ckpt = Key}, Mu, I, V) ->
    Mu1 = Mu#mut{globals = setelement(I + 1, Mu#mut.globals, V)},
    put(Key, Mu1),
    Mu1.

%%% -------------------------------------------------------- bulk memory ---
%%
%% The interpreter's own bulk-memory clauses call these too, so there is one
%% implementation of each and the compiled and interpreted paths cannot disagree
%% about a bound or a width. Each takes the operand widths the way `wasm_ir'
%% tagged them; generated code passes 32, because `wasm_core:supported/1'
%% refuses the memory64 forms.
%%
%% `fill', `copy' and `init' write into `atomics' in place and so leave `#mut{}'
%% alone. `grow' and `data.drop' change it, and therefore checkpoint, for the
%% same reason `set_global_at/4' does: what a later trap unwinds past has still
%% happened.

-doc "The size of a memory in pages.".
-spec memory_size_at(#mut{}, non_neg_integer()) -> non_neg_integer().
memory_size_at(Mu, M) ->
    wasm_memory:size_pages(element(M + 1, Mu#mut.mems)).

-doc "Grow a memory, answering the old size and the new state.".
-spec memory_grow_at(#inst{}, #mut{}, non_neg_integer(), term(), 32 | 64) ->
          {integer(), #mut{}}.
memory_grow_at(#inst{ckpt = Key}, Mu, M, Delta, W) ->
    case wasm_memory:grow(element(M + 1, Mu#mut.mems), unsigned(Delta, W)) of
        {ok, Old, Mem1} ->
            Mu1 = Mu#mut{mems = setelement(M + 1, Mu#mut.mems, Mem1)},
            put(Key, Mu1),
            {Old, Mu1};
        {error, _} ->
            %% Refusal is a value, not a trap: the specification requires -1.
            {-1, Mu}
    end.

-doc "Fill a range of a memory with one byte.".
-spec memory_fill_at(#mut{}, non_neg_integer(), term(), term(), term(),
                     32 | 64) -> ok.
%% The fill byte stays i32 whatever the memory's index type is; only the
%% destination and the length follow the memory.
memory_fill_at(Mu, M, D, B, N, W) ->
    wasm_memory:fill(element(M + 1, Mu#mut.mems), unsigned(D, W),
                     B band 16#FF, unsigned(N, W)).

-doc "Copy a range between two memories, or within one.".
-spec memory_copy_at(#mut{}, non_neg_integer(), non_neg_integer(), term(),
                     term(), term(), 32 | 64, 32 | 64) -> ok.
%% The destination is counted in the destination memory's index type, the source
%% in the source memory's, and the length in the narrower of the two, since it
%% has to be a valid count in both.
memory_copy_at(Mu, Dm, Sm, Da, Sa, N, DW, SW) when Dm =:= Sm ->
    wasm_memory:copy(element(Dm + 1, Mu#mut.mems), unsigned(Da, DW),
                     unsigned(Sa, SW), unsigned(N, min(DW, SW)));
memory_copy_at(Mu, Dm, Sm, Da, Sa, N, DW, SW) ->
    wasm_memory:copy(element(Dm + 1, Mu#mut.mems), unsigned(Da, DW),
                     element(Sm + 1, Mu#mut.mems), unsigned(Sa, SW),
                     unsigned(N, min(DW, SW))).

-doc "Copy from a passive data segment into a memory.".
-spec memory_init_at(#inst{}, #mut{}, non_neg_integer(), non_neg_integer(),
                     term(), term(), term(), 32 | 64) -> ok.
%% The segment's offset and length are i32 whatever the memory is, since they
%% index the segment rather than the memory.
memory_init_at(Inst, Mu, D, M, Da, So, N, W) ->
    wasm_memory:init(element(M + 1, Mu#mut.mems), unsigned(Da, W),
                     data_segment(Inst, Mu, D), unsigned(So, 32),
                     unsigned(N, 32)).

-doc "Drop a passive data segment, answering the new state.".
-spec data_drop_at(#inst{}, #mut{}, non_neg_integer()) -> #mut{}.
data_drop_at(#inst{ckpt = Key}, Mu, D) ->
    Mu1 = Mu#mut{dropped_datas = maps:put(D, true, Mu#mut.dropped_datas)},
    put(Key, Mu1),
    Mu1.

%%% ------------------------------------------ operations, for generated code ---
%%
%% The pure value-level surface `wasm_core' generates calls to. Deliberate and
%% named, rather than a scattering of incidental exports: generated code has to
%% be able to reach every operation that traps or is subtly typed.
%%
%% Nothing here reimplements anything. Each one dispatches to the function the
%% interpreter itself uses, so compiled and interpreted arithmetic cannot
%% diverge and `wasm_spec_SUITE' checks both at once. That property is the
%% reason to route through here at all rather than open-coding division in Core
%% and getting `integer_divide_by_zero' subtly wrong.

-doc "A binary operation on two operand values. Traps exactly as the interpreter does.".
-spec op2(atom(), term(), term()) -> term().
op2(Op, A, B) ->
    case op_kind(Op) of
        b32 -> i32_binop(Op, A, B);
        b64 -> i64_binop(Op, A, B);
        r32 -> int_relop(Op, A, B, 32);
        r64 -> int_relop(Op, A, B, 64);
        _ -> op2_rest(Op, A, B)
    end.

%% Division and remainder are not in `op_kind/1', which classifies the
%% operations the operand cache fast paths and those are the total ones. These
%% are exactly the ones that trap.
op2_rest(Op, A, B) when Op =:= i32_div_s; Op =:= i32_div_u;
                        Op =:= i32_rem_s; Op =:= i32_rem_u ->
    i32_binop(Op, A, B);
op2_rest(Op, A, B) when Op =:= i64_div_s; Op =:= i64_div_u;
                        Op =:= i64_rem_s; Op =:= i64_rem_u ->
    i64_binop(Op, A, B);
%% Floats, through the same table `numeric_rest/2` reads, so `wasm_num_float`
%% owns the NaN payloads and the symbolic infinities exactly once and compiled
%% and interpreted arithmetic cannot disagree about them.
op2_rest(Op, A, B) ->
    {W, F} = float_binop(Op),
    F(W, A, B).

-doc "A unary operation on one operand value.".
-spec op1(atom(), term()) -> term().
op1(i32_eqz, A) -> b(A =:= 0);
op1(i64_eqz, A) -> b(A =:= 0);
op1(Op, A) when Op =:= i32_clz; Op =:= i32_ctz; Op =:= i32_popcnt ->
    int_unop(Op, A, 32);
op1(Op, A) when Op =:= i64_clz; Op =:= i64_ctz; Op =:= i64_popcnt ->
    int_unop(Op, A, 64);
op1(Op, A) ->
    unop(Op, A).

%% One clause per operation, so the compiler builds a jump table on the atom.
op_kind(i32_add) -> b32; op_kind(i32_sub) -> b32; op_kind(i32_mul) -> b32;
op_kind(i32_and) -> b32; op_kind(i32_or) -> b32; op_kind(i32_xor) -> b32;
op_kind(i32_shl) -> b32; op_kind(i32_shr_s) -> b32; op_kind(i32_shr_u) -> b32;
op_kind(i32_rotl) -> b32; op_kind(i32_rotr) -> b32;
op_kind(i64_add) -> b64; op_kind(i64_sub) -> b64; op_kind(i64_mul) -> b64;
op_kind(i64_and) -> b64; op_kind(i64_or) -> b64; op_kind(i64_xor) -> b64;
op_kind(i64_shl) -> b64; op_kind(i64_shr_s) -> b64; op_kind(i64_shr_u) -> b64;
op_kind(i64_rotl) -> b64; op_kind(i64_rotr) -> b64;
op_kind(i32_eq) -> r32; op_kind(i32_ne) -> r32; op_kind(i32_lt_s) -> r32;
op_kind(i32_lt_u) -> r32; op_kind(i32_gt_s) -> r32; op_kind(i32_gt_u) -> r32;
op_kind(i32_le_s) -> r32; op_kind(i32_le_u) -> r32; op_kind(i32_ge_s) -> r32;
op_kind(i32_ge_u) -> r32;
op_kind(i64_eq) -> r64; op_kind(i64_ne) -> r64; op_kind(i64_lt_s) -> r64;
op_kind(i64_lt_u) -> r64; op_kind(i64_gt_s) -> r64; op_kind(i64_gt_u) -> r64;
op_kind(i64_le_s) -> r64; op_kind(i64_le_u) -> r64; op_kind(i64_ge_s) -> r64;
op_kind(i64_ge_u) -> r64;
op_kind(i32_eqz) -> eqz; op_kind(i64_eqz) -> eqz;
op_kind(_) -> none.

%%% -------------------------------------------------------------- branches ---

%% Branching to depth N unwinds N+1 control frames. A `loop' frame is the one
%% construct that jumps backwards, so it is re-pushed rather than discarded,
%% and it keeps the loop's parameters rather than its results.
%% The loop back edge, which is every iteration of every loop and was costing a
%% record update to write the stack it already held. `Saved` appears twice in
%% the head: once bound from the frame, once as the pattern the stack has to
%% match, so this fires exactly when the body left the stack where it found it.
%% A parameterless loop is the overwhelmingly common shape, and with fuel off
%% `charge/2` returns the state unchanged, so the whole edge allocates nothing.
branch(0, [{loop, _Cont, {loop, 0, _NRes, Body}, 0, Saved} = Target | Rest],
       #st{stack = Saved} = St) ->
    run(Body, [Target | Rest], charge(?FUEL_PER_BACKEDGE, St));
%% `lists:nth/2' and `lists:nthtail/2' walk the same N+1 cells twice, and
%% replacing them with one traversal returning `{Target, Rest}' cost QuickJS
%% 75%: 102.7 ms against 181.8, five interleaved passes, every one of them.
%% Whatever the mechanism, one more call and one more tuple inside the branch
%% path is not affordable, and real code branches shallowly enough that the
%% second walk is over one or two cells. See `test/audit/PERF.md'.
branch(N, Ctrl, St) ->
    Target = lists:nth(N + 1, Ctrl),
    Rest = lists:nthtail(N + 1, Ctrl),
    case Target of
        {block, Cont, Arity, Saved} ->
            run(Cont, Rest, St#st{stack = take(Arity, St#st.stack) ++ Saved});
        {try_table, Cont, Arity, Saved, _Catches} ->
            run(Cont, Rest, St#st{stack = take(Arity, St#st.stack) ++ Saved});
        {loop, _Cont, {loop, NPar, _NRes, Body}, NPar, Saved} ->
            St1 = charge(?FUEL_PER_BACKEDGE, St),
            run(Body, [Target | Rest],
                St1#st{stack = take(NPar, St1#st.stack) ++ Saved});
        {func, NRes} ->
            leave(NRes, St)
    end.


%% `br_table' indexes with an unsigned value; anything out of range takes the
%% default label.
%%
%% The labels are a tuple, lowered by `wasm_instance:ir_instr/2', so both the
%% range test and the selection are O(1). As a list this walked the labels twice
%% per dispatch, once to count them and once to index.
select_label(I, Labels, Default) ->
    Idx = wasm_num:to_u32(I),
    case Idx < tuple_size(Labels) of
        true -> element(Idx + 1, Labels);
        false -> Default
    end.

%%% ------------------------------------------------------------ exceptions ---

%% Unwinding falls out of frames being explicit.
%%
%% `run/3' already carries the control stack as a list, and each call frame
%% holds the caller's control stack, so a throw walks outwards through both
%% without needing Erlang exceptions or a separate stack discipline. This is the
%% same traversal `branch/3' does, just searching for a handler rather than
%% counting to a depth.
%%
%% A *trap* deliberately does not come through here. Traps are not catchable,
%% so they stay `wasm_error' throws and pass straight through any `try_table'.
throw_exn(Exn, Ctrl, St) ->
    case find_handler(Exn, Ctrl, (St#st.inst)#inst.tags) of
        {Cont, Rest, Saved, Vals} ->
            run(Cont, Rest, St#st{stack = lists:reverse(Vals) ++ Saved});
        none ->
            unwind_frame(Exn, St)
    end.

%% Handlers are searched innermost first, and within a frame in declaration
%% order, which is what lets a `catch_all' after a `catch' act as a fallback.
find_handler(_Exn, [], _Tags) -> none;
find_handler(Exn, [{try_table, _Cont, _N, _Saved, Catches} | Rest], Tags) ->
    case match_catch(Exn, Catches, Tags) of
        %% The label is relative to where the `try_table' sits, so it counts
        %% from the frame outside it: the same scope the validator used.
        {ok, Label, Vals} -> handler_target(Label, Rest, Vals);
        none -> find_handler(Exn, Rest, Tags)
    end;
find_handler(Exn, [_Frame | Rest], Tags) -> find_handler(Exn, Rest, Tags).

%% The label is relative to the frame *inside* the `try_table', so resolving it
%% counts from the handler's own frame outwards, exactly as `br' would from the
%% same point.
handler_target(Label, Ctrl, Vals) ->
    case lists:nth(Label + 1, Ctrl) of
        {block, Cont, Arity, S} -> {Cont, lists:nthtail(Label + 1, Ctrl), S,
                                    take_last(Arity, Vals)};
        {try_table, Cont, Arity, S, _} -> {Cont, lists:nthtail(Label + 1, Ctrl),
                                           S, take_last(Arity, Vals)};
        {loop, _Cont, {loop, NPar, _NRes, Body}, NPar, S} ->
            {Body, [lists:nth(Label + 1, Ctrl) | lists:nthtail(Label + 1, Ctrl)],
             S, take_last(NPar, Vals)}
    end.

take_last(N, L) when length(L) =< N -> L;
take_last(N, L) -> lists:nthtail(length(L) - N, L).

%% A catch clause names a tag by *index*, while the exception carries the tag's
%% identity, so the index is resolved against this instance's tags. That is what
%% makes two modules importing the same tag agree, and two distinct tags with
%% identical types stay distinct.
match_catch(_Exn, [], _Tags) -> none;
match_catch(#exn{tag = Tag, values = Vs} = E, [{catch_, T, L} | Rest], Tags) ->
    case Tag =:= element(T + 1, Tags) of
        true -> {ok, L, Vs};
        false -> match_catch(E, Rest, Tags)
    end;
match_catch(#exn{tag = Tag, values = Vs} = E, [{catch_ref, T, L} | Rest], Tags) ->
    case Tag =:= element(T + 1, Tags) of
        true -> {ok, L, Vs ++ [E]};
        false -> match_catch(E, Rest, Tags)
    end;
match_catch(_E, [{catch_all, _, L} | _], _Tags) -> {ok, L, []};
match_catch(E, [{catch_all_ref, _, L} | _], _Tags) -> {ok, L, [E]}.

%% No handler in this invocation: unwind into the caller and keep looking. At
%% the outermost frame the exception escapes the module, which is an error the
%% embedder sees rather than something a module can observe.
unwind_frame(Exn, #st{frames = Frames} = St) ->
    case Frames of
        [toplevel] -> uncaught(Exn);
        [] -> uncaught(Exn);
        [{_Cont, CallerCtrl, Locals, CallerStack} | Rest] ->
            throw_exn(Exn, CallerCtrl,
                      St#st{stack = CallerStack, locals = Locals,
                            frames = Rest, depth = St#st.depth - 1})
    end.

%% Thrown rather than turned into an error here, because this invocation may be
%% nested inside another instance's call. `call/5' converts it at the outermost
%% frame, which is the only place it is genuinely uncaught.
-spec uncaught(#exn{}) -> no_return().
uncaught(Exn) -> erlang:throw({wasm_exception, Exn}).

tag_arity({wasm_tag, _Id, _Canon, #functype{params = P}}) -> {func, length(P)}.

%%% ----------------------------------------------------------------- calls ---

%% The common case, and the one worth keeping cheap: no generated module to
%% reach, so this is one element comparison on the call path and nothing at all
%% on the dispatch path.
%%
%% `wasm.erl` used to say compiled code is entered at the outermost invocation
%% and nowhere else, on the grounds that a test here is the kind of change that
%% has cost 70% on QuickJS three times. It was right about the risk and wrong
%% about the conclusion: entering only at the outermost invocation makes the
%% boundary a one-way door, so the first refused function or the first
%% `call_indirect` dropped the whole program into the interpreter permanently,
%% and 83% of QuickJS compiled for no gain at all. The risk is answered by
%% measuring the interpreted arm, not by leaving the door shut.
do_call(F, Cont, Ctrl, #st{code = undefined} = St) ->
    interpreted_call(F, Cont, Ctrl, St);
do_call(F, Cont, Ctrl, #st{code = {Mod, Gen}, inst = Inst, mut = Mu} = St) ->
    case element(F + 1, Inst#inst.funcs) of
        #fn{nparams = NP} = Fn ->
            %% `pop_locals/3` is shared with the interpreted path, so a callee
            %% the generator refused pays one `sublist` rather than a second
            %% walk of the operand stack.
            {Locals, Stack1} = pop_locals(NP, St#st.stack, Fn#fn.defaults),
            St1 = St#st{stack = Stack1},
            try Mod:invoke(Inst, Mu, F, lists:sublist(Locals, NP), St#st.depth,
                           Gen) of
                %% Most functions of a real module are outside the subset. Not a
                %% failure, and the reason this is a value rather than a raise.
                %% Not in the unit, or the slot was refilled underneath this
                %% invocation. Interpreting answers both.
                {error, _} ->
                    enter(Fn, list_to_tuple(Locals), Cont, Ctrl, St1);
                {ok, Results, Mut1} ->
                    ok = wasm_jit:reentered(),
                    run(Cont, Ctrl,
                        St1#st{stack = lists:reverse(Results) ++ Stack1,
                               mut = Mut1})
            catch
                %% Compiled code cannot throw a wasm exception itself, but it
                %% can call out to interpreted code that does, and that throw
                %% would unwind straight past this instance's `try_table`
                %% frames. Put back into the interpreter's own unwinding at the
                %% point of the call, exactly as a host call is.
                throw:{wasm_exception, Exn} ->
                    throw_exn(Exn, Ctrl, St1)
            end;
        #hostfn{} ->
            interpreted_call(F, Cont, Ctrl, St)
    end.

interpreted_call(F, Cont, Ctrl, St) ->
    case element(F + 1, (St#st.inst)#inst.funcs) of
        #fn{nparams = NP} = Fn ->
            {Locals, Stack1} = pop_locals(NP, St#st.stack, Fn#fn.defaults),
            enter(Fn, list_to_tuple(Locals), Cont, Ctrl, St#st{stack = Stack1});
        #hostfn{nparams = NP} = H ->
            {RevArgs, Stack1} = split(NP, St#st.stack),
            %% A host function that is really another module's export may raise
            %% a wasm exception. It arrives as an Erlang throw, which would
            %% unwind straight past this instance's `try_table' frames, so it
            %% is caught here and put back into the interpreter's own
            %% unwinding at the point the call was made.
            try call_host(H, lists:reverse(RevArgs), St#st{stack = Stack1}) of
                {Results, St1} ->
                    run(Cont, Ctrl, St1#st{stack = lists:reverse(Results) ++ Stack1})
            catch
                throw:{wasm_exception, Exn} ->
                    throw_exn(Exn, Ctrl, St#st{stack = Stack1})
            end
    end.

%% Record a store mutation where the invocation's own catch can find it.
%%
%% A trapped computation leaves the store as it made it. The specification says
%% so and `linking.wast` asserts it: a module that fills an imported memory,
%% writes a reference into an imported table and then traps must leave both
%% behind. Memories and tables are shared structures and keep their writes
%% however the call ends, but a global that is not a cell, the grown size of a
%% private memory, and the dropped-segment sets all live in the `#mut{}' that
%% is threaded through the interpreter, and that goes with the stack the trap
%% unwinds.
%%
%% One process dictionary write, measured at 5.7 ns against 1.2 ns for the
%% `setelement' it accompanies. Cheap enough to do on every mutation, which is
%% the only schedule that is actually correct: a checkpoint taken anywhere else
%% loses whatever happened after it.
-compile({inline, [checkpoint/2]}).
checkpoint(#st{inst = #inst{ckpt = Key}}, Mut) ->
    put(Key, Mut),
    Mut.

%% Host functions run in the calling process. An Erlang exception raised by one
%% becomes a trap rather than escaping: the embedder's `wasm:call/3' must fail
%% as a value, and a host function crashing the caller would make the runtime
%% unusable for untrusted plugins whose imports are supplied by the embedder.
call_host(#hostfn{fun_ = Fun, nresults = NRes, name = Name}, Args, St) ->
    Inst = St#st.inst,
    Ctx = #{instance => Inst, mut => St#st.mut, fuel => St#st.fuel},
    %% The host function may call back into this instance, or into another one
    %% that shares state with it. Publishing lets that nested call see what this
    %% call has done; the version check afterwards lets this call see what the
    %% nested one did, instead of overwriting it at the end.
    Mut = St#st.mut,
    Prev = wasm_instance:publish(Inst, Mut),
    %% Counted here and nowhere else, and published with the fuel so anything
    %% the host calls back into continues from both.
    ok = charge_host_call(St),
    try Fun(Ctx, Args) of
        {ok, Results} when length(Results) =:= NRes ->
            {Results, adopt_fuel(adopt(Inst, Mut, St))};
        {ok, Results} ->
            wasm_error:trap({host_error, result_arity},
                            #{host => Name, expected => NRes,
                              got => length(Results)});
        {trap, Reason} ->
            wasm_error:trap({host_error, Reason}, #{host => Name})
    catch
        throw:{wasm_error, _} = E -> erlang:throw(E);
        %% A wasm exception raised by an imported function keeps unwinding in
        %% this instance rather than becoming a host error, so a `try_table'
        %% here can catch what a `throw' over there raised.
        throw:{wasm_exception, _} = E -> erlang:throw(E);
        Class:Reason:Stack ->
            wasm_error:trap({host_error, Reason},
                            #{host => Name, class => Class, stacktrace => Stack})
    after
        ok = wasm_instance:unpublish(Inst, Prev)
    end.

%% Nothing nested wrote, so this call's own state is still the newest and the
%% published term is the one it published. Otherwise a nested call refreshed it,
%% and its state is the newer one.
adopt(Inst, Mine, St) ->
    case wasm_instance:published(Inst) of
        Mine -> St;
        Newer -> St#st{mut = Newer}
    end.

%% `max_host_calls' was listed as a limit and enforced nowhere. A module in a
%% loop over an import did unbounded work for free, because a host call burns
%% no fuel by construction: what it costs is the host's, not the guest's.
charge_host_call(#st{fuel = Fuel, depth = Depth}) ->
    case get(?BUDGET) of
        undefined ->
            ok;
        {_, HC, _D, Max, MD} ->
            HC1 = HC + 1,
            HC1 > Max andalso
                wasm_error:exhaustion(host_call_limit,
                                      #{limit => Max, calls => HC1}),
            put(?BUDGET, {Fuel, HC1, Depth, Max, MD}),
            ok
    end.

%% Whatever the host function spent, by calling back in or not at all.
adopt_fuel(St) ->
    case get(?BUDGET) of
        undefined -> St;
        {Fuel, _HC, _D, _Max, _MD} -> St#st{fuel = Fuel}
    end.


func_type_in(Inst, F) ->
    case element(F + 1, Inst#inst.funcs) of
        #fn{type = T} -> T;
        #hostfn{type = T} -> T
    end.

%% Resolve a reference value to a callee, or trap on null. No type check: the
%% instruction named the type and the validator matched the reference against
%% it, which is what distinguishes `call_ref' from `call_indirect'.
ref_target(null, _St) ->
    wasm_error:trap(null_reference);
ref_target({funcref, Id, F}, St) ->
    case Id =:= inst_id(St) of
        true -> {same, F};
        false -> {foreign, foreign_inst(Id), F}
    end;
ref_target({funcref, F}, _St) -> {same, F}.

inst_id(#st{inst = #inst{id = Id}}) -> Id.

%% A function's body is lowered the first time it is entered, not when the
%% module was instantiated. `wasm_instance' owns the cache; this is the one
%% place execution asks for it.
%% The cache is read here rather than behind a call into `wasm_instance', so an
%% already-lowered function costs one dictionary read and nothing else.
body_of(#fn{body = {lazy, _}, idx = Idx} = F, #st{inst = Inst}) ->
    case get({wasm_ir, Inst#inst.id, Idx}) of
        undefined -> wasm_instance:body_of(F, Inst);
        IR -> IR
    end;
body_of(#fn{body = IR}, _St) -> IR.

%% The instance a reference names. Resolved only when the reference is not the
%% running instance's own, which is the rare case: an instance record is
%% immutable, so this process's note of it can never be stale.
foreign_inst(Id) ->
    case wasm_instance:lookup(Id) of
        {ok, Inst} ->
            Inst;
        error ->
            %% The same situation `foreign_reference' already names for
            %% objects: a reference from an instance this process cannot see.
            %% Saying so beats guessing at an instance.
            wasm_error:trap(foreign_reference, #{instance => Id})
    end.

%% Resolve a `call_indirect' table entry to a callee, or trap.
%%
%% The declared type must match the callee's actual type. This is the one type
%% check that cannot be done statically, because the table's contents are only
%% known at run time.
%% Takes the two fields it reads rather than the whole state, so that generated
%% code -- which has an instance and a mutable half and no `#st{}' at all -- can
%% reuse it instead of restating the three traps it raises.
indirect_target(TypeIdx, TableIdx, I, #st{inst = Inst, mut = Mut}) ->
    indirect_target(TypeIdx, TableIdx, I, Inst, Mut).

indirect_target(TypeIdx, TableIdx, I, Inst, Mut) ->
    Table = element(TableIdx + 1, Mut#mut.tables),
    Idx = table_index(I),
    case Idx < wasm_table:size(Table) of
        false -> wasm_error:trap(undefined_element, #{index => Idx});
        true -> ok
    end,
    Expected = canon_at(TypeIdx, Inst),
    case wasm_table:get(Table, Idx) of
        null -> wasm_error:trap(uninitialized_element, #{index => Idx});
        {funcref, Id, F} when Id =:= element(#inst.id, Inst) ->
            %% The overwhelmingly common case, and it reaches the callee's type
            %% through the running instance rather than resolving anything.
            check_indirect_type(Expected, func_type_in(Inst, F)),
            {same, F};
        {funcref, Id, F} ->
            FInst = foreign_inst(Id),
            check_indirect_type(Expected, func_type_in(FInst, F)),
            {foreign, FInst, F};
        {funcref, F} ->
            %% A reference with no instance attached predates instance-aware
            %% funcrefs and can only mean the current one.
            check_indirect_type(Expected, func_type_in(Inst, F)),
            {same, F}
    end.

canon_at(Idx, #inst{canon = C}) -> element(Idx + 1, C).

%% The callee's type must be a *subtype* of the declared one, not equal to it.
%% Both sides are canonical, and the callee carries its whole supertype chain
%% because it may come from a module whose type indices mean nothing here.
check_indirect_type(Expected, {_, Supers, Actual}) ->
    case lists:member(Expected, Supers) of
        true -> ok;
        false -> wasm_error:trap(indirect_call_type_mismatch,
                                 #{expected => Expected, got => Actual})
    end.

%% A tail call reuses the current frame: `do_call' pushes one, this does not.
do_return_call(F, St) ->
    case element(F + 1, (St#st.inst)#inst.funcs) of
        #fn{nparams = NP} = Fn ->
            {Locals, _Discarded} = pop_locals(NP, St#st.stack, Fn#fn.defaults),
            %% The rest of this function's operand stack goes with the frame it
            %% is replacing, so it is dropped rather than carried.
            run(case Fn#fn.body of {lazy, _} -> body_of(Fn, St); B -> B end,
                [Fn#fn.frame],
                St#st{stack = [], locals = list_to_tuple(Locals)});
        #hostfn{nparams = NP} = H ->
            {RevArgs, Stack1} = split(NP, St#st.stack),
            {Results, St1} = call_host(H, lists:reverse(RevArgs),
                                       St#st{stack = Stack1}),
            leave(length(Results), St1#st{stack = lists:reverse(Results)})
    end.

%% Call a function belonging to another instance.
%%
%% It runs as a nested invocation against the callee's own mutable state, which
%% is then written back, exactly as a call through `wasm:extern/2' would. The
%% caller's state is untouched apart from the arguments consumed and the
%% results pushed.
foreign_call(FInst, F, Cont, Ctrl, St) ->
    NParams = case element(F + 1, FInst#inst.funcs) of
                  #fn{nparams = N} -> N;
                  #hostfn{nparams = N} -> N
              end,
    {RevArgs, Stack1} = split(NParams, St#st.stack),
    Args = lists:reverse(RevArgs),
    Limits = FInst#inst.limits,
    FMut = wasm_instance:mut(FInst),
    %% An exception that escapes the callee is not the callee's failure: it
    %% keeps unwinding in *this* instance, where a `try_table' may catch it.
    %% Only reaching the outermost invocation makes it an error.
    try wasm_exec:call(FInst, FMut, F, Args, Limits) of
        {ok, Results, FMut1} ->
            ok = wasm_instance:set_mut(FInst, FMut1),
            run(Cont, Ctrl, St#st{stack = lists:reverse(Results) ++ Stack1})
    catch
        throw:{wasm_exception, Exn} ->
            throw_exn(Exn, Ctrl, St#st{stack = Stack1})
    end.

%%% ------------------------------------------------------ bulk memory ops ---

%% Each of these is the operand shuffle and nothing else. The work is in the
%% `_at' helpers below, which generated code calls with the same arguments, so
%% neither side can drift from the other on a bounds check or a width.

memory_grow(M, W, Rest, Ctrl, #st{stack = [Delta | S], mut = Mu} = St) ->
    {Old, Mu1} = memory_grow_at(St#st.inst, Mu, M, Delta, W),
    run(Rest, Ctrl, St#st{stack = [Old | S], mut = Mu1}).

memory_fill(M, W, Rest, Ctrl, #st{stack = [N, B, D | S], mut = Mu} = St) ->
    ok = memory_fill_at(Mu, M, D, B, N, W),
    run(Rest, Ctrl, St#st{stack = S}).

memory_copy(Dm, Sm, DW, SW, Rest, Ctrl, #st{stack = [N, Sa, Da | S], mut = Mu} = St) ->
    ok = memory_copy_at(Mu, Dm, Sm, Da, Sa, N, DW, SW),
    run(Rest, Ctrl, St#st{stack = S}).

memory_init(D, M, W, Rest, Ctrl, #st{stack = [N, So, Da | S], mut = Mu} = St) ->
    ok = memory_init_at(St#st.inst, Mu, D, M, Da, So, N, W),
    run(Rest, Ctrl, St#st{stack = S}).

%% A passive data segment, or the empty one it becomes after `data.drop'.
data_segment(#inst{datas = Datas}, #mut{dropped_datas = Dropped}, D) ->
    case maps:is_key(D, Dropped) of
        true -> <<>>;
        false -> element(D + 1, Datas)
    end.

%%% -------------------------------------------------------------------- gc ---

null_check(null) -> wasm_error:trap(null_reference);
null_check(_) -> ok.

bool(true) -> 1;
bool(false) -> 0.

%% A negative length means the module asked for more than 2^31 elements, which
%% no allocation can satisfy.
alloc_len(N) ->
    case wasm_num:to_u32(N) of
        Len when Len =< 16#FFFFFFF -> Len;
        Len -> wasm_error:trap(array_too_large, #{length => Len})
    end.

comptype_at(T, #st{inst = #inst{types = Ts}}) ->
    (element(T + 1, Ts))#subtype.body.

struct_fields(T, St) ->
    #structtype{fields = Fs} = comptype_at(T, St),
    Fs.

%% Both are two `element/2' calls against tuples resolved when the module was
%% validated. `field_at/3' was `lists:nth(F + 1, ...)' over a list rebuilt from
%% the type table, so reading the tenth field of a struct cost ten times reading
%% the first.
field_at(T, F, #st{inst = #inst{fields = Fs}}) ->
    element(F + 1, element(T + 1, Fs)).

elem_of(T, #st{inst = #inst{fields = Fs}}) -> element(T + 1, Fs).

%% Whether a field can hold a reference. An array of numbers is a leaf: the
%% collector marks it and never walks it, however many elements it has.
traced(#fieldtype{type = {ref, _, _}}) -> true;
traced(#fieldtype{}) -> false.

%% A packed field stores only its own width; the operand stack never holds one.
narrow(#fieldtype{type = i8}, V) -> V band 16#FF;
narrow(#fieldtype{type = i16}, V) -> V band 16#FFFF;
narrow(_F, V) -> V.

widen(Op, #fieldtype{type = i8}, V) when Op =:= struct_get_s; Op =:= array_get_s ->
    sign_extend(1, V);
widen(Op, #fieldtype{type = i16}, V) when Op =:= struct_get_s; Op =:= array_get_s ->
    sign_extend(2, V);
widen(_Op, _F, V) -> V.

field_default(#fieldtype{type = T}) -> storage_default(T).

storage_default(i8) -> 0;
storage_default(i16) -> 0;
storage_default(T) -> wasm_instance:default_value(T).

fill_new_array(H, T, Vals, Traced) ->
    Ref = wasm_heap:new_array(H, T, length(Vals), undefined, Traced),
    ok = write_elements(H, Ref, 0, Vals),
    Ref.

write_elements(H, Ref, Start, Vals) ->
    lists:foreach(fun({I, V}) -> wasm_heap:array_set_unchecked(H, Ref, Start + I, V) end,
                  lists:enumerate(0, Vals)).

%% Reading a segment as elements rather than bytes. The width comes from the
%% array's own field type, and a read past the end of the segment traps.
data_elements(D, Off, N, #fieldtype{type = Ty}, #st{inst = Inst, mut = Mu}) ->
    Seg = data_segment(Inst, Mu, D),
    W = storage_width(Ty),
    case Off + (N * W) =< byte_size(Seg) of
        false -> wasm_error:trap(out_of_bounds_memory_access,
                                 #{segment => D, offset => Off, count => N});
        true ->
            <<_:Off/binary, Slice:(N * W)/binary, _/binary>> = Seg,
            decode_elements(Slice, Ty, W)
    end.

storage_width(i8) -> 1;
storage_width(i16) -> 2;
storage_width(i32) -> 4;
storage_width(f32) -> 4;
storage_width(i64) -> 8;
storage_width(f64) -> 8.

decode_elements(Bin, Ty, W) ->
    [decode_element(E, Ty) || <<E:(W * 8)/little>> <= Bin].

decode_element(V, i8) -> V;
decode_element(V, i16) -> V;
decode_element(V, i32) -> wasm_num:wrap_s32(V);
decode_element(V, i64) -> wasm_num:wrap_s64(V);
decode_element(V, f32) -> wasm_num:f32_from_bits(V);
decode_element(V, f64) -> wasm_num:f64_from_bits(V).

elem_elements(E, Off, N, #st{inst = Inst, mut = Mu}) ->
    Seg = case maps:is_key(E, Mu#mut.dropped_elems) of
              true -> [];
              false -> element(E + 1, Inst#inst.elems)
          end,
    case Off + N =< length(Seg) of
        false -> wasm_error:trap(out_of_bounds_table_access,
                                 #{segment => E, offset => Off, count => N});
        true -> lists:sublist(Seg, Off + 1, N)
    end.

%% A bulk operation that traps must leave the array untouched, so the whole
%% range is checked before the first write rather than element by element.
check_array_range(H, Ref, Start, Len) ->
    Size = wasm_heap:array_len(H, Ref),
    case Start + Len =< Size of
        true -> ok;
        false -> wasm_error:trap(out_of_bounds_array_access,
                                 #{start => Start, length => Len, size => Size})
    end.

mem_at(M, Mu) -> element(M + 1, Mu#mut.mems).

%% Memory holds bit patterns; the operand stack holds signed integers. A
%% full-width atomic load therefore reinterprets, while a narrow one is an
%% unsigned widening and is already in range. Wrapping by the *value type*
%% rather than the access width gets both without a case on the width.
wrap(i32, V) -> wasm_num:wrap_s32(V);
wrap(i64, V) -> wasm_num:wrap_s64(V).

%% Waiting is only meaningful on a memory more than one agent can reach, so it
%% traps on a memory that was not declared shared rather than blocking forever.
atomic_wait(Mem, Addr, W, Expected, Timeout) ->
    case wasm_memory:is_shared(Mem) of
        false -> wasm_error:trap(expected_shared_memory, #{});
        true ->
            Want = Expected band mask_bits(W * 8),
            Read = fun() ->
                       case wasm_memory:atomic_load(Mem, Addr, W) of
                           Want -> equal;
                           _ -> not_equal
                       end
                   end,
            wasm_wait:wait(wasm_memory:id(Mem), Addr, Read, Timeout)
    end.

mask_bits(N) -> (1 bsl N) - 1.

%% The object store. It lives in the immutable half of the instance, because the
%% handle is immutable even though everything it names changes.
heap(#st{inst = #inst{heap = H}}) -> H.

%% The run-time type test behind `ref.test', `ref.cast' and the cast branches.
%% It walks the reference's *actual* type through the same subtype relation the
%% validator uses, which is why the canonical identities have to be available
%% at run time and not only at compile time.
ref_matches(null, {ref, null, _}, _St) -> true;
ref_matches(null, {ref, nonull, _}, _St) -> false;
ref_matches(R, {ref, _, HT}, St) -> heap_test(heap_of(R, St), HT, St).

heap_of({i31, _}, _St) -> i31;
%% A concrete reference carries its *canonical* type and the closure of types it
%% is a subtype of. Returning the abstract `func' or `struct' instead would lose
%% exactly the information `ref.test' asks about, and canonical identities are
%% what let the answer hold for a reference that came from another module.
heap_of({objref, _} = Ref, St) ->
    {_Kind, T} = wasm_heap:type_of(heap(St), Ref),
    {concrete, kind_at(T, St), supers_at(T, St)};
heap_of({funcref, Id, F}, St) ->
    Inst = case Id =:= inst_id(St) of
               true -> St#st.inst;
               false -> foreign_inst(Id)
           end,
    {_, Supers, _} = fn_type(Inst, F),
    {concrete, func, Supers};
heap_of({funcref, _}, _St) -> {concrete, func, []};
heap_of({extern, _}, _St) -> extern;
heap_of({internal, _}, _St) -> any;
heap_of(_, _St) -> extern.

fn_type(Inst, F) ->
    case element(F + 1, Inst#inst.funcs) of
        #fn{type = T} -> T;
        #hostfn{type = T} -> T
    end.

kind_at(T, #st{inst = #inst{kinds = Ks}}) -> element(T + 1, Ks).

%% Every `ref.test' and `ref.cast' recomputed this closure and then searched it.
%% The closure cannot change once the module is validated.
supers_at(T, #st{inst = #inst{supers = Ss}}) -> element(T + 1, Ss).

heap_test(H, H, _St) -> true;
heap_test(i31, T, _St) -> lists:member(T, [i31, eq, any]);
heap_test({concrete, _K, Supers}, {type, B}, St) ->
    lists:member(canon_at(B, St#st.inst), Supers);
heap_test({concrete, func, _}, func, _St) -> true;
heap_test({concrete, struct, _}, H, _St) ->
    lists:member(H, [struct, eq, any]);
heap_test({concrete, array, _}, H, _St) ->
    lists:member(H, [array, eq, any]);
heap_test(_, _, _St) -> false.

%%% ----------------------------------------------------------------- table ---

%% Interpret a table index, count or delta as unsigned.
%%
%% Unlike memory addresses, this needs no width parameter. Under memory64 a
%% table may be indexed by i64, and reading such an index as u32 would mask
%% 2^32 down to 0, turning an out-of-bounds access into a silent success. u64
%% is also correct for a 32-bit table: the validator has already guaranteed the
%% value is an i32, and for a negative i32 both interpretations land far above
%% any table's size, so both trap.
table_index(V) -> wasm_num:to_u64(V).

%%% ---------------------------------------------------------------- memory ---

%% The effective address is computed in Erlang integers, so a base near 2^32
%% plus a large static offset cannot wrap into a valid address. `wasm_memory'
%% then bounds-checks the whole access.
%%
%% The address is computed *inside* each branch, because the two instruction
%% shapes put different things on top of the stack: a load has the address
%% there, a store has the value being stored with the address beneath it.
%% Computing it once up front from the stack top looked like a harmless
%% hoist and was not. For a store it read the value, and `to_u32/1' passes
%% non-integers through unchanged, so storing a symbolic float turned into
%% `{nan, 0, 16#200000} + Offset' and raised `badarith' from deep inside the
%% interpreter. Every `f32.store' of a NaN failed with an internal error.
mem_op(Op, Offset, M, Width, #st{mut = Mu} = St) ->
    Mem = element(M + 1, Mu#mut.mems),
    case load_spec(Op) of
        {load, N, Kind} ->
            [Base | S] = St#st.stack,
            Addr = unsigned(Base, Width) + Offset,
            Raw = wasm_memory:load(Mem, Addr, N),
            St#st{stack = [decode_loaded(Kind, N, Raw) | S]};
        false ->
            {store, N, Kind} = store_spec(Op),
            [Value, Base | S] = St#st.stack,
            Addr = unsigned(Base, Width) + Offset,
            wasm_memory:store(Mem, Addr, N, encode_stored(Kind, Value)),
            St#st{stack = S}
    end.

%% Also generated inline by `wasm_core:decode/3`, which cannot share this code
%% because it builds Core rather than running. The two are pinned together by
%% `wasm_core_SUITE:every_memory_access_agrees_with_the_interpreter/1`.
decode_loaded(i32_s, N, Raw) -> wasm_num:wrap_s32(sign_extend(N, Raw));
decode_loaded(i32_u, _N, Raw) -> wasm_num:wrap_s32(Raw);
decode_loaded(i64_s, N, Raw) -> wasm_num:wrap_s64(sign_extend(N, Raw));
decode_loaded(i64_u, _N, Raw) -> wasm_num:wrap_s64(Raw);
decode_loaded(f32, _N, Raw) -> wasm_num:f32_from_bits(Raw);
decode_loaded(f64, _N, Raw) -> wasm_num:f64_from_bits(Raw).

sign_extend(N, Raw) ->
    Bits = N * 8,
    case Raw >= (1 bsl (Bits - 1)) of
        true -> Raw - (1 bsl Bits);
        false -> Raw
    end.

encode_stored(int, V) -> V;
encode_stored(f32, V) -> wasm_num:f32_to_bits(V);
encode_stored(f64, V) -> wasm_num:f64_to_bits(V).

load_spec(i32_load)     -> {load, 4, i32_u};
load_spec(i64_load)     -> {load, 8, i64_u};
load_spec(f32_load)     -> {load, 4, f32};
load_spec(f64_load)     -> {load, 8, f64};
load_spec(i32_load8_s)  -> {load, 1, i32_s};
load_spec(i32_load8_u)  -> {load, 1, i32_u};
load_spec(i32_load16_s) -> {load, 2, i32_s};
load_spec(i32_load16_u) -> {load, 2, i32_u};
load_spec(i64_load8_s)  -> {load, 1, i64_s};
load_spec(i64_load8_u)  -> {load, 1, i64_u};
load_spec(i64_load16_s) -> {load, 2, i64_s};
load_spec(i64_load16_u) -> {load, 2, i64_u};
load_spec(i64_load32_s) -> {load, 4, i64_s};
load_spec(i64_load32_u) -> {load, 4, i64_u};
load_spec(_) -> false.

store_spec(i32_store)   -> {store, 4, int};
store_spec(i64_store)   -> {store, 8, int};
store_spec(f32_store)   -> {store, 4, f32};
store_spec(f64_store)   -> {store, 8, f64};
store_spec(i32_store8)  -> {store, 1, int};
store_spec(i32_store16) -> {store, 2, int};
store_spec(i64_store8)  -> {store, 1, int};
store_spec(i64_store16) -> {store, 2, int};
store_spec(i64_store32) -> {store, 4, int}.

%%% ---------------------------------------------------------------- fuel ---

charge(_N, #st{fuel = infinity} = St) -> St;
charge(N, #st{fuel = F} = St) when F > N -> St#st{fuel = F - N};
charge(_N, _St) -> wasm_error:exhaustion(out_of_fuel).

%%% --------------------------------------------------------------- helpers ---

take(0, _) -> [];
take(N, L) -> lists:sublist(L, N).

%% Values are held signed, so reinterpreting an address as unsigned depends on
%% the memory's index width.
unsigned(V, 32) -> wasm_num:to_u32(V);
unsigned(V, 64) -> wasm_num:to_u64(V).

%% Table bulk operations check bounds up front, so a trap never leaves a
%% partially-written table behind.
check_table_range(Start, Len, Size) when Start + Len =< Size -> ok;
check_table_range(Start, Len, Size) ->
    wasm_error:trap(out_of_bounds_table_access,
                    #{start => Start, len => Len, size => Size}).



drop(0, L) -> L;
drop(N, L) -> lists:nthtail(N, L).

split(0, L) -> {[], L};
split(N, L) -> lists:split(N, L).

%%% -------------------------------------------------------------- numeric ---
%%
%% Integers are held signed, so the `_u' operations reinterpret before
%% comparing or dividing. Results are wrapped back into signed range, which
%% keeps small values as immediate machine words: i32 arithmetic measured
%% 1.3 ns against 9.7 ns for values that spill into bignums.

numeric(Op, #st{stack = [B, A | S]} = St) when
      Op =:= i32_add; Op =:= i32_sub; Op =:= i32_mul; Op =:= i32_div_s;
      Op =:= i32_div_u; Op =:= i32_rem_s; Op =:= i32_rem_u; Op =:= i32_and;
      Op =:= i32_or; Op =:= i32_xor; Op =:= i32_shl; Op =:= i32_shr_s;
      Op =:= i32_shr_u; Op =:= i32_rotl; Op =:= i32_rotr ->
    St#st{stack = [i32_binop(Op, A, B) | S]};
numeric(Op, #st{stack = [B, A | S]} = St) when
      Op =:= i64_add; Op =:= i64_sub; Op =:= i64_mul; Op =:= i64_div_s;
      Op =:= i64_div_u; Op =:= i64_rem_s; Op =:= i64_rem_u; Op =:= i64_and;
      Op =:= i64_or; Op =:= i64_xor; Op =:= i64_shl; Op =:= i64_shr_s;
      Op =:= i64_shr_u; Op =:= i64_rotl; Op =:= i64_rotr ->
    St#st{stack = [i64_binop(Op, A, B) | S]};
numeric(Op, #st{stack = [B, A | S]} = St) when
      Op =:= i32_eq; Op =:= i32_ne; Op =:= i32_lt_s; Op =:= i32_lt_u;
      Op =:= i32_gt_s; Op =:= i32_gt_u; Op =:= i32_le_s; Op =:= i32_le_u;
      Op =:= i32_ge_s; Op =:= i32_ge_u ->
    St#st{stack = [int_relop(Op, A, B, 32) | S]};
numeric(Op, #st{stack = [B, A | S]} = St) when
      Op =:= i64_eq; Op =:= i64_ne; Op =:= i64_lt_s; Op =:= i64_lt_u;
      Op =:= i64_gt_s; Op =:= i64_gt_u; Op =:= i64_le_s; Op =:= i64_le_u;
      Op =:= i64_ge_s; Op =:= i64_ge_u ->
    St#st{stack = [int_relop(Op, A, B, 64) | S]};
numeric(i32_eqz, #st{stack = [A | S]} = St) ->
    St#st{stack = [b(A =:= 0) | S]};
numeric(i64_eqz, #st{stack = [A | S]} = St) ->
    St#st{stack = [b(A =:= 0) | S]};
numeric(Op, #st{stack = [A | S]} = St) when
      Op =:= i32_clz; Op =:= i32_ctz; Op =:= i32_popcnt ->
    St#st{stack = [int_unop(Op, A, 32) | S]};
numeric(Op, #st{stack = [A | S]} = St) when
      Op =:= i64_clz; Op =:= i64_ctz; Op =:= i64_popcnt ->
    St#st{stack = [int_unop(Op, A, 64) | S]};
numeric(Op, St) -> numeric_rest(Op, St).

%% - float binary ----------------------------------------------------------
%%
%% The stack pattern must not be the only thing selecting this clause: a unary
%% conversion applied to a single-element stack would otherwise fall off the
%% end of the function rather than reaching `numeric_unary'.
numeric_rest(Op, #st{stack = [B, A | S]} = St) ->
    case float_binop(Op) of
        {W, F} -> St#st{stack = [F(W, A, B) | S]};
        false -> numeric_unary(Op, St)
    end;
numeric_rest(Op, St) ->
    numeric_unary(Op, St).

float_binop(f32_add) -> {32, fun wasm_num_float:add/3};
float_binop(f32_sub) -> {32, fun wasm_num_float:sub/3};
float_binop(f32_mul) -> {32, fun wasm_num_float:mul/3};
float_binop(f32_div) -> {32, fun wasm_num_float:divide/3};
float_binop(f32_min) -> {32, fun wasm_num_float:min/3};
float_binop(f32_max) -> {32, fun wasm_num_float:max/3};
float_binop(f32_copysign) -> {32, fun wasm_num_float:copysign/3};
float_binop(f64_add) -> {64, fun wasm_num_float:add/3};
float_binop(f64_sub) -> {64, fun wasm_num_float:sub/3};
float_binop(f64_mul) -> {64, fun wasm_num_float:mul/3};
float_binop(f64_div) -> {64, fun wasm_num_float:divide/3};
float_binop(f64_min) -> {64, fun wasm_num_float:min/3};
float_binop(f64_max) -> {64, fun wasm_num_float:max/3};
float_binop(f64_copysign) -> {64, fun wasm_num_float:copysign/3};
float_binop(f32_eq) -> {32, fun wasm_num_float:eq/3};
float_binop(f32_ne) -> {32, fun wasm_num_float:ne/3};
float_binop(f32_lt) -> {32, fun wasm_num_float:lt/3};
float_binop(f32_gt) -> {32, fun wasm_num_float:gt/3};
float_binop(f32_le) -> {32, fun wasm_num_float:le/3};
float_binop(f32_ge) -> {32, fun wasm_num_float:ge/3};
float_binop(f64_eq) -> {64, fun wasm_num_float:eq/3};
float_binop(f64_ne) -> {64, fun wasm_num_float:ne/3};
float_binop(f64_lt) -> {64, fun wasm_num_float:lt/3};
float_binop(f64_gt) -> {64, fun wasm_num_float:gt/3};
float_binop(f64_le) -> {64, fun wasm_num_float:le/3};
float_binop(f64_ge) -> {64, fun wasm_num_float:ge/3};
float_binop(_) -> false.

%% - unary and conversions -------------------------------------------------
numeric_unary(Op, #st{stack = [A | S]} = St) ->
    St#st{stack = [unop(Op, A) | S]}.

unop(f32_abs, A) -> wasm_num_float:abs(32, A);
unop(f32_neg, A) -> wasm_num_float:neg(32, A);
unop(f32_ceil, A) -> wasm_num_float:ceil(32, A);
unop(f32_floor, A) -> wasm_num_float:floor(32, A);
unop(f32_trunc, A) -> wasm_num_float:trunc(32, A);
unop(f32_nearest, A) -> wasm_num_float:nearest(32, A);
unop(f32_sqrt, A) -> wasm_num_float:sqrt(32, A);
unop(f64_abs, A) -> wasm_num_float:abs(64, A);
unop(f64_neg, A) -> wasm_num_float:neg(64, A);
unop(f64_ceil, A) -> wasm_num_float:ceil(64, A);
unop(f64_floor, A) -> wasm_num_float:floor(64, A);
unop(f64_trunc, A) -> wasm_num_float:trunc(64, A);
unop(f64_nearest, A) -> wasm_num_float:nearest(64, A);
unop(f64_sqrt, A) -> wasm_num_float:sqrt(64, A);

unop(i32_wrap_i64, A) -> wasm_num:wrap_s32(A);
unop(i64_extend_i32_s, A) -> A;
unop(i64_extend_i32_u, A) -> wasm_num:to_u32(A);
unop(i32_extend8_s, A) -> wasm_num:wrap_s32(sign_extend(1, A band 16#FF));
unop(i32_extend16_s, A) -> wasm_num:wrap_s32(sign_extend(2, A band 16#FFFF));
unop(i64_extend8_s, A) -> wasm_num:wrap_s64(sign_extend(1, A band 16#FF));
unop(i64_extend16_s, A) -> wasm_num:wrap_s64(sign_extend(2, A band 16#FFFF));
unop(i64_extend32_s, A) -> wasm_num:wrap_s64(sign_extend(4, A band 16#FFFFFFFF));

unop(f32_demote_f64, A) -> wasm_num_float:demote(A);
unop(f64_promote_f32, A) -> wasm_num_float:promote(A);
unop(f32_convert_i32_s, A) -> wasm_num_float:convert_i32_s(32, A);
unop(f32_convert_i32_u, A) -> wasm_num_float:convert_i32_u(32, A);
unop(f32_convert_i64_s, A) -> wasm_num_float:convert_i64_s(32, A);
unop(f32_convert_i64_u, A) -> wasm_num_float:convert_i64_u(32, A);
unop(f64_convert_i32_s, A) -> wasm_num_float:convert_i32_s(64, A);
unop(f64_convert_i32_u, A) -> wasm_num_float:convert_i32_u(64, A);
unop(f64_convert_i64_s, A) -> wasm_num_float:convert_i64_s(64, A);
unop(f64_convert_i64_u, A) -> wasm_num_float:convert_i64_u(64, A);

unop(i32_reinterpret_f32, A) -> wasm_num:wrap_s32(wasm_num:f32_to_bits(A));
unop(i64_reinterpret_f64, A) -> wasm_num:wrap_s64(wasm_num:f64_to_bits(A));
unop(f32_reinterpret_i32, A) -> wasm_num:f32_from_bits(wasm_num:to_u32(A));
unop(f64_reinterpret_i64, A) -> wasm_num:f64_from_bits(wasm_num:to_u64(A));

unop(Op, A) -> wasm_num_trunc:apply(Op, A).

%%% ------------------------------------------------------ integer operations ---

i32_binop(i32_add, A, B) -> wasm_num:wrap_s32(A + B);
i32_binop(i32_sub, A, B) -> wasm_num:wrap_s32(A - B);
i32_binop(i32_mul, A, B) -> wasm_num:wrap_s32(A * B);
i32_binop(i32_and, A, B) -> wasm_num:wrap_s32(A band B);
i32_binop(i32_or, A, B) -> wasm_num:wrap_s32(A bor B);
i32_binop(i32_xor, A, B) -> wasm_num:wrap_s32(A bxor B);
i32_binop(i32_div_s, _A, 0) -> wasm_error:trap(integer_divide_by_zero);
%% The one signed division that overflows: -2^31 / -1 has no 32-bit result.
i32_binop(i32_div_s, -2147483648, -1) -> wasm_error:trap(integer_overflow);
i32_binop(i32_div_s, A, B) -> wasm_num:wrap_s32(trunc_div(A, B));
i32_binop(i32_div_u, _A, 0) -> wasm_error:trap(integer_divide_by_zero);
i32_binop(i32_div_u, A, B) ->
    wasm_num:wrap_s32(wasm_num:to_u32(A) div wasm_num:to_u32(B));
i32_binop(i32_rem_s, _A, 0) -> wasm_error:trap(integer_divide_by_zero);
i32_binop(i32_rem_s, A, B) -> wasm_num:wrap_s32(trunc_rem(A, B));
i32_binop(i32_rem_u, _A, 0) -> wasm_error:trap(integer_divide_by_zero);
i32_binop(i32_rem_u, A, B) ->
    wasm_num:wrap_s32(wasm_num:to_u32(A) rem wasm_num:to_u32(B));
%% Shift counts are taken modulo the width, which is what WebAssembly specifies
%% and what C leaves undefined.
i32_binop(i32_shl, A, B) -> wasm_num:wrap_s32(A bsl (B band 31));
i32_binop(i32_shr_s, A, B) -> wasm_num:wrap_s32(A bsr (B band 31));
i32_binop(i32_shr_u, A, B) -> wasm_num:wrap_s32(wasm_num:to_u32(A) bsr (B band 31));
i32_binop(i32_rotl, A, B) -> rot(wasm_num:to_u32(A), B band 31, 32, left);
i32_binop(i32_rotr, A, B) -> rot(wasm_num:to_u32(A), B band 31, 32, right).

i64_binop(i64_add, A, B) -> wasm_num:wrap_s64(A + B);
i64_binop(i64_sub, A, B) -> wasm_num:wrap_s64(A - B);
i64_binop(i64_mul, A, B) -> wasm_num:wrap_s64(A * B);
i64_binop(i64_and, A, B) -> wasm_num:wrap_s64(A band B);
i64_binop(i64_or, A, B) -> wasm_num:wrap_s64(A bor B);
i64_binop(i64_xor, A, B) -> wasm_num:wrap_s64(A bxor B);
i64_binop(i64_div_s, _A, 0) -> wasm_error:trap(integer_divide_by_zero);
i64_binop(i64_div_s, -9223372036854775808, -1) -> wasm_error:trap(integer_overflow);
i64_binop(i64_div_s, A, B) -> wasm_num:wrap_s64(trunc_div(A, B));
i64_binop(i64_div_u, _A, 0) -> wasm_error:trap(integer_divide_by_zero);
i64_binop(i64_div_u, A, B) ->
    wasm_num:wrap_s64(wasm_num:to_u64(A) div wasm_num:to_u64(B));
i64_binop(i64_rem_s, _A, 0) -> wasm_error:trap(integer_divide_by_zero);
i64_binop(i64_rem_s, A, B) -> wasm_num:wrap_s64(trunc_rem(A, B));
i64_binop(i64_rem_u, _A, 0) -> wasm_error:trap(integer_divide_by_zero);
i64_binop(i64_rem_u, A, B) ->
    wasm_num:wrap_s64(wasm_num:to_u64(A) rem wasm_num:to_u64(B));
i64_binop(i64_shl, A, B) -> wasm_num:wrap_s64(A bsl (B band 63));
i64_binop(i64_shr_s, A, B) -> wasm_num:wrap_s64(A bsr (B band 63));
i64_binop(i64_shr_u, A, B) -> wasm_num:wrap_s64(wasm_num:to_u64(A) bsr (B band 63));
i64_binop(i64_rotl, A, B) -> rot(wasm_num:to_u64(A), B band 63, 64, left);
i64_binop(i64_rotr, A, B) -> rot(wasm_num:to_u64(A), B band 63, 64, right).

%% Erlang's `div' and `rem' already truncate toward zero, which is what
%% WebAssembly requires (unlike floor division).
trunc_div(A, B) -> A div B.
trunc_rem(A, B) -> A rem B.

rot(V, 0, W, _) -> wrap_w(W, V);
rot(V, N, W, left) -> wrap_w(W, ((V bsl N) bor (V bsr (W - N))));
rot(V, N, W, right) -> wrap_w(W, ((V bsr N) bor (V bsl (W - N)))).

wrap_w(32, V) -> wasm_num:wrap_s32(V);
wrap_w(64, V) -> wasm_num:wrap_s64(V).

%% One clause per opcode, on the atom.
%%
%% This built a *string* from the opcode atom and then matched suffixes
%% against it, on every comparison executed. `atom_to_list/1' allocates and
%% copies, and the match then walks up to ten patterns over the result:
%% measured at 25.3 ns for `i32.ge_u' and 17.1 ns for `i32.eq' against 5.1 and
%% 2.1 ns for the same answers matched directly. Comparisons are in every loop
%% bound and every conditional branch a real module has.
%%
%% Written out rather than generated, because the compiler turns a set of
%% atom clauses into a jump table and there is nothing here worth being clever
%% about.
int_relop(i32_eq, A, B, _W) -> b(A =:= B);
int_relop(i64_eq, A, B, _W) -> b(A =:= B);
int_relop(i32_ne, A, B, _W) -> b(A =/= B);
int_relop(i64_ne, A, B, _W) -> b(A =/= B);
int_relop(i32_lt_s, A, B, _W) -> b(A < B);
int_relop(i64_lt_s, A, B, _W) -> b(A < B);
int_relop(i32_gt_s, A, B, _W) -> b(A > B);
int_relop(i64_gt_s, A, B, _W) -> b(A > B);
int_relop(i32_le_s, A, B, _W) -> b(A =< B);
int_relop(i64_le_s, A, B, _W) -> b(A =< B);
int_relop(i32_ge_s, A, B, _W) -> b(A >= B);
int_relop(i64_ge_s, A, B, _W) -> b(A >= B);
int_relop(i32_lt_u, A, B, W) -> b(u(A, W) < u(B, W));
int_relop(i64_lt_u, A, B, W) -> b(u(A, W) < u(B, W));
int_relop(i32_gt_u, A, B, W) -> b(u(A, W) > u(B, W));
int_relop(i64_gt_u, A, B, W) -> b(u(A, W) > u(B, W));
int_relop(i32_le_u, A, B, W) -> b(u(A, W) =< u(B, W));
int_relop(i64_le_u, A, B, W) -> b(u(A, W) =< u(B, W));
int_relop(i32_ge_u, A, B, W) -> b(u(A, W) >= u(B, W));
int_relop(i64_ge_u, A, B, W) -> b(u(A, W) >= u(B, W)).

u(V, 32) -> wasm_num:to_u32(V);
u(V, 64) -> wasm_num:to_u64(V).

int_unop(i32_clz, A, W) -> clz(u(A, W), W);
int_unop(i64_clz, A, W) -> clz(u(A, W), W);
int_unop(i32_ctz, A, W) -> ctz(u(A, W), W);
int_unop(i64_ctz, A, W) -> ctz(u(A, W), W);
int_unop(i32_popcnt, A, W) -> popcnt(u(A, W));
int_unop(i64_popcnt, A, W) -> popcnt(u(A, W)).

clz(0, W) -> W;
clz(V, W) -> W - bit_length(V).

bit_length(V) -> bit_length(V, 0).
bit_length(0, N) -> N;
bit_length(V, N) -> bit_length(V bsr 1, N + 1).

ctz(0, W) -> W;
ctz(V, _W) -> ctz_loop(V, 0).
ctz_loop(V, N) when V band 1 =:= 1 -> N;
ctz_loop(V, N) -> ctz_loop(V bsr 1, N + 1).

popcnt(V) -> popcnt(V, 0).
popcnt(0, N) -> N;
popcnt(V, N) -> popcnt(V bsr 1, N + (V band 1)).

b(true) -> 1;
b(false) -> 0.
