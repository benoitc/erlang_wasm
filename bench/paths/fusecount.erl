-module(fusecount).
-moduledoc """
Which fusion rules actually fire, and how many dispatches they remove.

Use this after changing `wasm_instance:fuse/1`, before believing a timing.
`fc183c1` added four rules, measured -1.3%, and there was no way to tell
whether the rules had fired at all -- a rule that never matches and a rule that
matches and does not pay look identical in a benchmark.

This is a diagnostic and never a timed run. It counts by walking the lowered IR
of an instance built with `fuse => true' against one built with `fuse => false',
so the interpreter carries no counters and the hot path is untouched.

    erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/fusecount.erl
    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run fusecount main bench/cross/loop.wasm

Add `show` to print the IR of every function, which is readable for a
benchmark loop and is not for anything real.
""".
-include_lib("wasm/include/wasm_exec.hrl").
-export([main/1]).

%% Every rule in `wasm_instance:fuse/1', longest first, in that order. Listed
%% here rather than derived, so that adding a rule and forgetting to add it
%% here shows up as an `other' line instead of silently going uncounted.
-define(RULES, [lg_const_add_set, lg_const_add_tee, lg_const_add,
                lg_lg_store, lg_load_tee, lg_load,
                lg_lg, lg_const, eqz_br_if]).

main([Path]) -> report(Path, false);
main([Path, "show"]) -> report(Path, true).

report(Path, Show) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(Path),
    {ok, M} = wasm:compile(Bin),
    Off = walk(M, false),
    On = walk(M, true),
    Plain = count(Off),
    Fused = count(On),

    io:format("~s~n", [Path]),
    io:format("instructions  unfused ~w  fused ~w  removed ~w (~.1f%)~n",
              [Plain, Fused, Plain - Fused, pct(Plain - Fused, Plain)]),
    io:format("~n~-18s ~8s ~8s~n", ["rule", "sites", "instrs"]),
    Hist = histogram(On),
    [io:format("~-18s ~8w ~8w~s~n",
               [R, maps:get(R, Hist, 0), maps:get(R, Hist, 0) * width(R),
                case maps:get(R, Hist, 0) of 0 -> "   never fires"; _ -> "" end])
     || R <- ?RULES],
    Other = maps:without(?RULES, Hist),
    [io:format("~-18s ~8w        (not in ?RULES)~n", [R, C])
     || {R, C} <- maps:to_list(Other)],

    case Show of
        true ->
            io:format("~n--- fuse => false ---~n"), [show(B, 0) || B <- Off],
            io:format("~n--- fuse => true ---~n"), [show(B, 0) || B <- On];
        false -> ok
    end,
    init:stop().

%% The IR of every function, with lazy bodies forced. Lowering reads the fusion
%% decision off the instance, so the two instances differ in exactly one thing.
walk(M, Fuse) ->
    %% WASI imports are offered unconditionally: a module that does not import
    %% them ignores the map, and every real module here needs them.
    {ok, I} = wasm:instantiate(M, wasi_preview1:imports(#{}), #{fuse => Fuse}),
    Bodies = [wasm_instance:body_of(F, I)
              || F <- tuple_to_list(I#inst.funcs), is_record(F, fn)],
    ok = wasm:destroy(I),
    Bodies.

%% One dispatch per instruction, nested bodies included. A fused instruction
%% counts once, which is the point: the difference between the two totals is
%% the number of dispatches the rules remove.
count(L) when is_list(L) -> lists:sum([count(I) || I <- L]);
count({block, _, _, B}) -> 1 + count(B);
count({loop, _, _, B}) -> 1 + count(B);
count({try_table, _, _, _, B}) -> 1 + count(B);
count({if_, _, _, T, E}) -> 1 + count(T) + count(E);
count(_) -> 1.

histogram(L) -> histogram(L, #{}).

histogram(L, H) when is_list(L) -> lists:foldl(fun histogram/2, H, L);
histogram({block, _, _, B}, H) -> histogram(B, H);
histogram({loop, _, _, B}, H) -> histogram(B, H);
histogram({try_table, _, _, _, B}, H) -> histogram(B, H);
histogram({if_, _, _, T, E}, H) -> histogram(E, histogram(T, H));
histogram(I, H) ->
    Op = if is_atom(I) -> I; true -> element(1, I) end,
    case lists:member(Op, ?RULES) of
        true -> maps:update_with(Op, fun(C) -> C + 1 end, 1, H);
        false -> H
    end.

%% How many source instructions each rule swallows, so `instrs' reads as the
%% work the rule is responsible for rather than as a site count.
width(lg_const_add_set) -> 4;
width(lg_const_add_tee) -> 4;
width(lg_const_add) -> 3;
width(lg_lg_store) -> 3;
width(lg_load_tee) -> 3;
width(_) -> 2.

pct(_, 0) -> 0.0;
pct(A, B) -> A * 100 / B.

show(L, D) when is_list(L) -> [show(I, D) || I <- L];
show({block, _, _, B}, D) -> io:format("~*sblock~n", [D, ""]), show(B, D + 2);
show({loop, _, _, B}, D) -> io:format("~*sloop~n", [D, ""]), show(B, D + 2);
show({if_, _, _, T, E}, D) ->
    io:format("~*sif~n", [D, ""]), show(T, D + 2),
    io:format("~*selse~n", [D, ""]), show(E, D + 2);
show(I, D) -> io:format("~*s~p~n", [D, "", I]).
