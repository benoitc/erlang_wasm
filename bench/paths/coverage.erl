-module(coverage).
-moduledoc """
What share of a real module the compiled tier takes, and what refuses the rest.

Use this before and after every change that adds an instruction to
`wasm_core:supported/1`. It answers the only question that decides whether such
a change paid for itself: how many more functions compile, and what the top
refusal is now.

    erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/coverage.erl
    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run coverage main test/fixtures/lang/qjs.wasm

It walks the lowered IR of every function and asks `wasm_core:can_compile/2`,
so it reports exactly what the tier would decide at run time rather than a
model of it. Refusals are tallied by the *first* refusing instruction in each
function, which is what makes the histogram an ordering rather than a census:
removing the top entry uncovers whatever stood behind it, so predicting the
next coverage number by summing rows overshoots. It has, by 7 points.

A diagnostic, never a timed run.
""".
-include_lib("wasm/include/wasm.hrl").
-include_lib("wasm/include/wasm_exec.hrl").
-export([main/1]).

main([Path]) -> report(Path, 12);
main([Path, N]) -> report(Path, list_to_integer(N)).

report(Path, Top) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(Path),
    {ok, M} = wasm:compile(Bin),
    %% Unfused, because that is what the tier compiles: the superinstructions
    %% save the interpreter a dispatch and generated code has none to save.
    {ok, I} = wasm:instantiate(M, wasi_preview1:imports(#{}), #{fuse => false}),
    Fns = [F || F <- tuple_to_list(I#inst.funcs), is_record(F, fn)],
    Verdicts = [wasm_core:can_compile(F, wasm_instance:compiler_ir(F, I))
                || F <- Fns],
    ok = wasm:destroy(I),

    Total = length(Verdicts),
    Ok = length([x || {ok, _} <- Verdicts]),
    io:format("~ts~n", [Path]),
    io:format("~-34s ~8w~n", ["functions", Total]),
    io:format("~-34s ~8w  ~5.1f%~n",
              ["compilable", Ok, pct(Ok, Total)]),

    Limits = [R || {limit, R} <- Verdicts],
    [io:format("~-34s ~8w~n", ["over a generator bound", length(Limits)])
     || Limits =/= []],
    [io:format("    ~-30s ~8w~n", [R, C]) || {R, C} <- tally(Limits)],

    Refusals = [key(Instr) || {unsupported, Instr} <- Verdicts],
    io:format("~n~-34s ~8s~n", ["first refusing instruction", "count"]),
    [io:format("~-34s ~8w~n", [K, C])
     || {K, C} <- lists:sublist(tally(Refusals), Top)],
    Rest = length(Refusals) - lists:sum(
                                [C || {_, C} <- lists:sublist(tally(Refusals), Top)]),
    [io:format("~-34s ~8w~n", ["(everything else)", Rest]) || Rest > 0],
    init:stop().

pct(_, 0) -> 0.0;
pct(N, D) -> (N * 100) / D.

tally(L) ->
    Counts = lists:foldl(fun(K, A) -> maps:update_with(K, fun(C) -> C + 1 end, 1, A) end,
                         #{}, L),
    lists:sort(fun({_, A}, {_, B}) -> A >= B end, maps:to_list(Counts)).

%% One refusing instruction, named the way the specification names it, so that
%% two encodings of one operation do not appear as two rows. The immediates are
%% dropped: `memory.copy' between memories 0 and 0 and between 0 and 1 are the
%% same missing feature.
key(I) when is_atom(I) -> I;
key({Op, {_Align, _Off, _Mem}}) when is_atom(Op) -> Op;
key(I) when is_tuple(I), is_atom(element(1, I)) -> element(1, I);
key(I) -> I.
