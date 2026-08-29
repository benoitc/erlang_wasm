-module(corespike).
-moduledoc """
Feasibility only: one WebAssembly function compiled to Core Erlang and run.

Use this to answer one question and no others. Can wasm IR turned into Core
Erlang, handed to `compile:forms/2` and loaded with `code:load_binary/3`, run
the benchmark loop at a speed that would make a compiler worth building? The
gate is 10 ns/iteration, and it is a feasibility gate: it says the direction is
worth a project, not that anything here is landable.

    erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/corespike.erl
    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run corespike main bench/cross/loop.wasm

**Nothing here is safe to reuse.** It loads exactly one literal, pre-interned
module name, once, and never unloads or purges it. No user input reaches a
generated name. The lifetime work that would make generated code safe is a
separate phase and none of it is done, which is why this lives in `bench/` and
not in `src/`.

## What it covers

A function whose control flow is blocks and loops with no label operands, and
whose arithmetic is the i32 subset the loop uses. Anything else raises
`{unsupported, Instr}` rather than being quietly skipped, because a compiler
that silently drops an instruction produces a number that means nothing.

## How it works

Every control frame becomes a Core function taking all the locals as
arguments, and a branch is a tail call to it. Locals become Core variables,
which is what makes them registers as far as the BEAM is concerned: there is no
tuple and no `setelement`, because Core is single-assignment and a `local.set`
is a new binding. The operand stack is a compile-time list of Core variables
and literals, so it does not exist at run time at all.

That last part is what the validator's heights make sound, and why Phase 1 came
first: knowing the stack shape at every instruction statically is exactly what
lets the stack be compiled away rather than interpreted.
""".
-include_lib("wasm/include/wasm_exec.hrl").
-export([main/1]).

-define(MOD, wasm_jit_spike).       % one literal name, interned at compile time
-define(FUN, bench).

main([Path]) ->
    {ok, _} = application:ensure_all_started(wasm),
    jit = erlang:system_info(emu_flavor),
    {ok, Bin} = file:read_file(Path),
    {ok, M} = wasm:compile(Bin),
    %% Unfused, because the superinstructions exist to save the interpreter a
    %% dispatch and there is no dispatch here to save.
    {ok, I} = wasm:instantiate(M, #{}, #{fuse => false}),
    Fn = hd([F || F <- tuple_to_list(I#inst.funcs), is_record(F, fn)]),
    IR = wasm_instance:body_of(Fn, I),

    Core = core_module(Fn, IR),
    {ok, ?MOD, Beam} = compile:forms(Core, [from_core, binary, return_errors]),
    {module, ?MOD} = code:load_binary(?MOD, "wasm_jit_spike.core", Beam),
    io:format("compiled ~w bytes of beam~n", [byte_size(Beam)]),

    %% Same answer as the interpreter at every size, or the number below is
    %% about a different computation.
    Sizes = loop_erl:sizes(10000000),
    [begin
         {ok, [Want]} = wasm:call(I, ~"bench", [N]),
         Got = ?MOD:?FUN(N),
         Want =:= Got orelse erlang:error({checksum, N, Want, Got})
     end || N <- Sizes],
    io:format("checksums agree with the interpreter at ~w sizes~n", [length(Sizes)]),

    [_ = ?MOD:?FUN(1000000) || _ <- lists:seq(1, 3)],   % warmup, in this process
    Points = [{N, best(N)} || N <- Sizes],
    [io:format("  n=~-10w ~10.1f us~n", [N, T]) || {N, T} <- Points],
    {Slope, _, R2} = loop_erl:fit(Points),
    io:format("compiled: ~.2f ns/iter r2=~.5f~n", [Slope * 1000, R2]),
    init:stop().

best(N) ->
    float(lists:min([element(1, timer:tc(fun() -> ?MOD:?FUN(N) end))
                     || _ <- lists:seq(1, 5)])).

%%% ------------------------------------------------------- core generation ---

core_module(#fn{nparams = NP, defaults = Defaults}, IR) ->
    NLocals = NP + length(Defaults),
    put(nlocals, NLocals),
    put(counter, 0),
    Params = [var() || _ <- lists:seq(1, NP)],
    Env = maps:from_list(lists:zip(lists:seq(0, NP - 1), Params)),
    %% Declared locals start at their type's default, which for this subset is
    %% always the integer zero.
    Env1 = maps:merge(Env, maps:from_list(
                             [{NP + K, cerl:abstract(D)}
                              || {K, D} <- lists:zip(lists:seq(0, length(Defaults) - 1),
                                                     Defaults)])),
    Name = cerl:c_fname(?FUN, NP),
    Body = seq(IR, [], Env1, [], return),
    cerl:c_module(cerl:c_atom(?MOD), [Name], [], [{Name, cerl:c_fun(Params, Body)}]).

var() ->
    N = get(counter),
    put(counter, N + 1),
    cerl:c_var(list_to_atom("_v" ++ integer_to_list(N))).

fname(Arity) ->
    N = get(counter),
    put(counter, N + 1),
    cerl:c_fname(list_to_atom("_k" ++ integer_to_list(N)), Arity).

idxs() -> lists:seq(0, get(nlocals) - 1).

%% A frame's function takes every local, so a branch to it needs no other
%% state. The operand stack never crosses a frame boundary here, which is the
%% restriction that keeps this a spike.
frame_args(Env) -> [maps:get(I, Env) || I <- idxs()].

fresh_frame() ->
    Vars = [var() || _ <- idxs()],
    {fname(length(Vars)), Vars, maps:from_list(lists:zip(idxs(), Vars))}.

%% `return' is the outermost exit: the function's result is whatever is on the
%% stack, which for this subset is one value.
go(return, [V | _], _Env) -> V;
go(return, [], _Env) -> cerl:abstract(0);
go(K, _Stack, Env) -> cerl:c_apply(K, frame_args(Env)).

seq([], Stack, Env, _Frames, Exit) -> go(Exit, Stack, Env);
seq([I | Rest], Stack, Env, Frames, Exit) -> instr(I, Rest, Stack, Env, Frames, Exit).

%% - control ---------------------------------------------------------------

instr({block, 0, 0, Body}, Rest, [], Env, Frames, Exit) ->
    {K, KVars, KEnv} = fresh_frame(),
    Cont = cerl:c_fun(KVars, seq(Rest, [], KEnv, Frames, Exit)),
    cerl:c_letrec([{K, Cont}], seq(Body, [], Env, [K | Frames], K));

instr({loop, 0, 0, Body}, Rest, [], Env, Frames, Exit) ->
    {K, KVars, KEnv} = fresh_frame(),
    {Lp, LpVars, LpEnv} = fresh_frame(),
    Cont = cerl:c_fun(KVars, seq(Rest, [], KEnv, Frames, Exit)),
    %% Branching to a loop label means the top of the loop, so its own frame
    %% points at itself and falling off the end goes to the continuation.
    Loop = cerl:c_fun(LpVars, seq(Body, [], LpEnv, [Lp | Frames], K)),
    cerl:c_letrec([{K, Cont}],
                  cerl:c_letrec([{Lp, Loop}],
                                cerl:c_apply(Lp, frame_args(Env))));

instr({br, N}, _Rest, _Stack, Env, Frames, _Exit) ->
    cerl:c_apply(lists:nth(N + 1, Frames), frame_args(Env));

instr({br_if, N}, Rest, [C | S], Env, Frames, Exit) ->
    Taken = cerl:c_apply(lists:nth(N + 1, Frames), frame_args(Env)),
    cerl:c_case(C, [cerl:c_clause([cerl:abstract(0)], seq(Rest, S, Env, Frames, Exit)),
                    cerl:c_clause([var()], Taken)]);

%% - variables and constants -----------------------------------------------

instr({local_get, I}, Rest, S, Env, Frames, Exit) ->
    seq(Rest, [maps:get(I, Env) | S], Env, Frames, Exit);
instr({local_set, I}, Rest, [V | S], Env, Frames, Exit) ->
    %% No assignment and no `setelement': a new binding, which is what makes a
    %% local a register rather than a slot in a tuple.
    seq(Rest, S, Env#{I => V}, Frames, Exit);
instr({local_tee, I}, Rest, [V | _] = S, Env, Frames, Exit) ->
    seq(Rest, S, Env#{I => V}, Frames, Exit);
instr({i32_const, C}, Rest, S, Env, Frames, Exit) ->
    seq(Rest, [cerl:abstract(C) | S], Env, Frames, Exit);

%% - arithmetic ------------------------------------------------------------

instr(Op, Rest, [B, A | S], Env, Frames, Exit) when is_atom(Op) ->
    V = var(),
    cerl:c_let([V], binop(Op, A, B), seq(Rest, [V | S], Env, Frames, Exit));

instr(I, _Rest, _S, _Env, _Frames, _Exit) ->
    erlang:error({unsupported, I}).

%%% ---------------------------------------------------------------- values ---

bif(Name, Args) -> cerl:c_call(cerl:c_atom(erlang), cerl:c_atom(Name), Args).

%% Values are held signed, exactly as the interpreter holds them, so the same
%% checksum comes out. Wrapping is branch-free rather than a comparison:
%% masking to 32 bits then flipping and subtracting the sign bit costs three
%% BIFs and no test.
wrap32(E) ->
    bif('-', [bif('bxor', [bif('band', [E, cerl:abstract(16#FFFFFFFF)]),
                           cerl:abstract(16#80000000)]),
              cerl:abstract(16#80000000)]).

u32(E) -> bif('band', [E, cerl:abstract(16#FFFFFFFF)]).

binop(i32_add, A, B) -> wrap32(bif('+', [A, B]));
binop(i32_sub, A, B) -> wrap32(bif('-', [A, B]));
binop(i32_mul, A, B) -> wrap32(bif('*', [A, B]));
binop(i32_and, A, B) -> bif('band', [A, B]);
binop(i32_or, A, B) -> bif('bor', [A, B]);
binop(i32_xor, A, B) -> bif('bxor', [A, B]);
binop(i32_shl, A, B) -> wrap32(bif('bsl', [A, bif('band', [B, cerl:abstract(31)])]));
binop(i32_shr_u, A, B) -> bif('bsr', [u32(A), bif('band', [B, cerl:abstract(31)])]);
binop(i32_shr_s, A, B) -> bif('bsr', [A, bif('band', [B, cerl:abstract(31)])]);
binop(Op, A, B) -> relop(Op, A, B).

%% A comparison yields the integer 1 or 0, not a boolean.
relop(Op, A, B) ->
    {Erl, L, R} = cmp(Op, A, B),
    cerl:c_case(bif(Erl, [L, R]),
                [cerl:c_clause([cerl:abstract(true)], cerl:abstract(1)),
                 cerl:c_clause([cerl:abstract(false)], cerl:abstract(0))]).

cmp(i32_eq, A, B) -> {'=:=', A, B};
cmp(i32_ne, A, B) -> {'=/=', A, B};
cmp(i32_lt_s, A, B) -> {'<', A, B};
cmp(i32_le_s, A, B) -> {'=<', A, B};
cmp(i32_gt_s, A, B) -> {'>', A, B};
cmp(i32_ge_s, A, B) -> {'>=', A, B};
cmp(i32_lt_u, A, B) -> {'<', u32(A), u32(B)};
cmp(i32_le_u, A, B) -> {'=<', u32(A), u32(B)};
cmp(i32_gt_u, A, B) -> {'>', u32(A), u32(B)};
cmp(i32_ge_u, A, B) -> {'>=', u32(A), u32(B)};
cmp(Op, _, _) -> erlang:error({unsupported, Op}).
