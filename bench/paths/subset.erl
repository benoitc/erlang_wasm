-module(subset).
-moduledoc """
How much of a real module a compiler could actually take, one restriction at a
time.

Use this before building a compiler back end, to find out whether the subset
you were about to support ever occurs. `corespike` compiles a function whose
body is i32 arithmetic, locals and structured control flow, and reports 2.59
ns/iteration. That number is worthless if no function in a real module has that
shape, and nothing so far has said whether one does.

This is a diagnostic and never a timed run. It walks the lowered IR of every
function, sorts each instruction into a category, and reports which categories
a function uses. A compiler that supports a set of categories can compile
exactly the functions whose categories are a subset of it, so the tier table
below is a direct answer to "what would we get for the next restriction we
lift".

    erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/subset.erl
    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run subset main test/fixtures/lang/qjs.wasm

Add `why` to list, for each function outside the base subset, the single
category that puts it there, which is the marginal value of that one lift.

Instructions are weighted equally, which is wrong in the way every static count
is wrong: a loop body executes more often than the code around it. Read the
tier table as an upper bound on coverage, not as a share of run time.
""".
-include_lib("wasm/include/wasm.hrl").
-include_lib("wasm/include/wasm_exec.hrl").
-export([main/1]).

%% The categories, in the order a compiler would plausibly lift them, and the
%% base subset `corespike' already covers. Listed rather than derived: a new
%% instruction that fits none of the patterns lands in `other' and is printed,
%% instead of being silently counted as supported.
-define(BASE, [i32, ctrl, local]).
-define(LIFTS, [i64, trap, mem, global, float, call]).

main([Path]) -> report(Path, false);
main([Path, "why"]) -> report(Path, true).

report(Path, Why) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(Path),
    {ok, M} = wasm:compile(Bin),
    %% Unfused: the superinstructions exist to save the interpreter a dispatch,
    %% and a compiler has no dispatch to save. Categorising the fused forms
    %% would answer a question nobody is asking.
    {ok, I} = wasm:instantiate(M, wasi_preview1:imports(#{}), #{fuse => false}),
    Fns = [F || F <- tuple_to_list(I#inst.funcs), is_record(F, fn)],
    Funs = [{F#fn.idx, F, wasm_instance:compiler_ir(F, I)} || F <- Fns],
    ok = wasm:destroy(I),

    %% One row per function: its size, and the set of categories it uses.
    Rows = [{Idx, count(B), cats(B)} || {Idx, _F, B} <- Funs],
    Total = length(Rows),
    Instrs = lists:sum([N || {_, N, _} <- Rows]),

    io:format("~s~n~w functions, ~w instructions~n~n", [Path, Total, Instrs]),

    io:format("~-10s ~8s ~8s~n", ["category", "funcs", "instrs"]),
    Hist = lists:foldl(fun({_, N, Cs}, H) ->
                               lists:foldl(fun(C, A) -> bump(C, N, A) end, H, Cs)
                       end, #{}, Rows),
    [io:format("~-10s ~8w ~8w~n", [C, F, N])
     || {C, {F, N}} <- lists:sort(fun({_, {_, A}}, {_, {_, B}}) -> A >= B end,
                                  maps:to_list(Hist))],

    io:format("~n~-28s ~8s ~7s ~9s ~7s~n",
              ["compiler supports", "funcs", "%", "instrs", "%"]),
    lists:foldl(
      fun(Lift, Set0) ->
              Set = case Lift of base -> ?BASE; _ -> [Lift | Set0] end,
              {F, N} = covered(Rows, Set),
              io:format("~-28s ~8w ~6.1f% ~9w ~6.1f%~n",
                        [label(Lift), F, pct(F, Total), N, pct(N, Instrs)]),
              Set
      end, [], [base | ?LIFTS]),

    shapes(M, Funs),
    case Why of
        true -> marginal(Rows);
        false -> ok
    end,
    init:stop().

%%% ------------------------------------------------------------- shapes ---

%% What the generator's limits have to be set from, rather than guessed at.
%%
%% A generated control continuation carries every local the frame needs plus
%% whatever operands are live across its boundary, so its arity is bounded by
%% params plus locals plus the operand height at that point. The validator has
%% already computed those heights and `#func.body' still carries them, so the
%% bound is read rather than re-derived.
%%
%% Two atom pools are sized from the other two columns: one name per compiled
%% function, and one per control frame within a function.
shapes(M, Funs) ->
    %% `#fn.idx' counts imports first, and `#module.funcs' holds only the
    %% defined ones, so the two are lined up by sorted index rather than by
    %% assuming an offset.
    Idxs = lists:sort([Idx || {Idx, _, _} <- Funs]),
    Heights = maps:from_list(
                lists:zip(Idxs, [height(B) || #func{body = B} <- M#module.funcs])),
    Rows = [{Idx,
             F#fn.nparams + length(F#fn.defaults),
             nesting(IR),
             frames(IR),
             maps:get(Idx, Heights, 0)}
            || {Idx, F, IR} <- Funs],
    io:format("~n~-34s ~8s ~8s~n", ["generator limit", "max", "p99"]),
    [io:format("~-34s ~8w ~8w~n", [Label, lists:max(Col), pct99(Col)])
     || {Label, Col} <-
            [{"params + locals", [A || {_, A, _, _, _} <- Rows]},
             {"operand height", [H || {_, _, _, _, H} <- Rows]},
             {"bound on continuation arity",
              [A + H || {_, A, _, _, H} <- Rows]},
             {"control frames per function", [N || {_, _, _, N, _} <- Rows]},
             {"control nesting", [D || {_, _, D, _, _} <- Rows]}]],
    io:format("~-34s ~8w~n", ["compilable functions per module", length(Rows)]).

pct99([]) -> 0;
pct99(L) ->
    S = lists:sort(L),
    lists:nth(max(1, (length(S) * 99) div 100), S).

%% The greatest operand-stack height the validator recorded anywhere in a body.
%% An unvalidated body has no heights and answers zero.
height({validated, Ann}) -> height(Ann);
height(L) when is_list(L) -> lists:max([0 | [height(I) || I <- L]]);
height({H, I}) when is_integer(H) -> max(H, height(I));
height({H, _B, I}) when is_integer(H) -> max(H, height(I));
height({block, _, Body}) -> height(Body);
height({loop, _, Body}) -> height(Body);
height({if_, _, T, E}) -> max(height(T), height(E));
height({try_table, _, _, Body}) -> height(Body);
height(_) -> 0.

%% One continuation per control frame, and they nest.
nesting(L) when is_list(L) -> lists:max([0 | [nesting(I) || I <- L]]);
nesting({block, _, _, B}) -> 1 + nesting(B);
nesting({loop, _, _, B}) -> 1 + nesting(B);
nesting({try_table, _, _, _, B}) -> 1 + nesting(B);
nesting({if_, _, _, T, E}) -> 1 + max(nesting(T), nesting(E));
nesting(_) -> 0.

frames(L) when is_list(L) -> lists:sum([frames(I) || I <- L]);
frames({block, _, _, B}) -> 1 + frames(B);
frames({loop, _, _, B}) -> 1 + frames(B);
frames({try_table, _, _, _, B}) -> 1 + frames(B);
frames({if_, _, _, T, E}) -> 1 + frames(T) + frames(E);
frames(_) -> 0.

label(base) -> "i32 + control + locals";
label(Lift) -> "  + " ++ atom_to_list(Lift).

%% Functions whose whole category set fits inside what the compiler supports.
%% Anything else falls back to the interpreter, whole.
covered(Rows, Set) ->
    In = [{N, Cs} || {_, N, Cs} <- Rows, Cs -- Set =:= []],
    {length(In), lists:sum([N || {N, _} <- In])}.

%% For each function one lift away from compilable, which lift. This is the
%% number that says whether a restriction is worth removing on its own, as
%% against the tier table, where every row includes every row above it.
marginal(Rows) ->
    H = lists:foldl(fun({_, N, Cs}, A) ->
                            case Cs -- ?BASE of
                                [One] -> bump(One, N, A);
                                _ -> A
                            end
                    end, #{}, Rows),
    io:format("~none lift away from the base subset~n~n", []),
    io:format("~-10s ~8s ~8s~n", ["lift", "funcs", "instrs"]),
    [io:format("~-10s ~8w ~8w~n", [C, F, N])
     || {C, {F, N}} <- lists:sort(maps:to_list(H))].

bump(K, N, H) ->
    maps:update_with(K, fun({F, I}) -> {F + 1, I + N} end, {1, N}, H).

pct(_, 0) -> 0.0;
pct(A, B) -> A * 100 / B.

%%% ------------------------------------------------------- categorisation ---

count(L) when is_list(L) -> lists:sum([count(I) || I <- L]);
count({block, _, _, B}) -> 1 + count(B);
count({loop, _, _, B}) -> 1 + count(B);
count({try_table, _, _, _, B}) -> 1 + count(B);
count({if_, _, _, T, E}) -> 1 + count(T) + count(E);
count(_) -> 1.

cats(B) -> lists:usort(cats(B, [])).

cats(L, A) when is_list(L) -> lists:foldl(fun cats/2, A, L);
cats({block, _, _, B}, A) -> cats(B, [ctrl | A]);
cats({loop, _, _, B}, A) -> cats(B, [ctrl | A]);
cats({try_table, _, _, _, B}, A) -> cats(B, [call | A]);
cats({if_, _, _, T, E}, A) -> cats(E, cats(T, [ctrl | A]));
cats(I, A) -> [cat(op(I)) | A].

op(I) when is_atom(I) -> I;
op(I) -> element(1, I).

%% One rule per category, tried in order, so that an instruction none of them
%% recognises comes out as its own name and gets printed. A compiler that
%% quietly counts an unknown instruction as supported produces a coverage
%% figure that means nothing.
-define(RULES,
        [{mem,    fun(_, S) -> sub(S, "_load") orelse sub(S, "_store")
                                    orelse pre(S, "memory_") end},
         {global, fun(_, S) -> pre(S, "global_") end},
         {table,  fun(Op, S) -> pre(S, "table_")
                                    orelse one(Op, [elem_drop, data_drop, ref_func]) end},
         {call,   fun(Op, S) -> pre(S, "call") orelse pre(S, "return_call")
                                    orelse one(Op, [throw, throw_ref, try_table]) end},
         {gc,     fun(Op, S) -> pre(S, "struct_") orelse pre(S, "array_")
                                    orelse pre(S, "ref_") orelse pre(S, "i31_")
                                    orelse pre(S, "br_on_")
                                    orelse one(Op, [any_convert_extern,
                                                    extern_convert_any]) end},
         {simd,   fun(_, S) -> pre(S, "simd_") orelse pre(S, "v128_")
                                   orelse pre(S, "i8x16_") end},
         {atomic, fun(Op, _) -> one(Op, [atomic, atomic_fence]) end},
         {float,  fun(_, S) -> pre(S, "f32_") orelse pre(S, "f64_") end},
         %% Division and remainder trap on a zero divisor, so they are their
         %% own tier: a compiler with no way to raise the interpreter's trap
         %% cannot take them, even though they are otherwise plain arithmetic.
         {trap,   fun(Op, _) -> one(Op, [i32_div_s, i32_div_u, i32_rem_s, i32_rem_u,
                                         i64_div_s, i64_div_u, i64_rem_s,
                                         i64_rem_u]) end},
         {i64,    fun(_, S) -> pre(S, "i64_") end},
         {ctrl,   fun(Op, _) -> one(Op, [block, loop, br, br_if, br_table, if_,
                                         return, nop, drop, select, unreachable,
                                         eqz_br_if]) end},
         {local,  fun(_, S) -> pre(S, "local_") orelse pre(S, "lg_") end},
         {i32,    fun(_, S) -> pre(S, "i32_") end}]).

cat(Name) ->
    Str = atom_to_list(Name),
    case lists:search(fun({_, P}) -> P(Name, Str) end, ?RULES) of
        {value, {C, _}} -> C;
        false -> Name                   % printed as itself, never assumed
    end.

one(Op, L) -> lists:member(Op, L).

pre(S, P) -> lists:prefix(P, S).

sub(S, Sub) -> string:find(S, Sub) =/= nomatch.
