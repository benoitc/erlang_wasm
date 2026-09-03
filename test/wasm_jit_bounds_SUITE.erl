%% @doc What the compiled tier does with a module it cannot fit in one unit.
%%
%% `wasm_core` draws every name a compiled unit can use from a pool it generates
%% at startup, because nothing a guest supplies may become an atom. The pool is
%% `max_funs` deep, and a unit past it is refused.
%%
%% Three things about that refusal were wrong at once, and CPython found all
%% three: the split that would keep each unit under the bound never happened,
%% the bin packing balanced words without regard to the bound, and the refusal
%% left `wasm_core:forms/8` as an exception rather than a value, so
%% `wasm_jit:compiler_loop/0` swallowed it and the tier declined a 25 MB guest
%% silently, for ever, while asking again every retry interval.
%%
%% Every case here that reproduces one of those fails on the commit before it,
%% which is noted case by case. The ones that only guard a behaviour say so.
-module(wasm_jit_bounds_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("wasm/include/wasm.hrl").

all() ->
    [{group, running}, {group, without_the_table}].

groups() ->
    [{running, [],
      [more_functions_than_one_unit_holds_still_compiles,
       an_uneven_split_still_respects_the_function_bound,
       a_module_past_every_shard_is_refused_and_says_so,
       a_unit_over_the_bound_is_a_value_not_an_exception,
       a_refusal_is_paced_by_the_retry_interval,
       a_forced_refusal_is_counted_once,
       the_shard_policy_splits_only_what_does_not_fit,
       a_module_under_the_bound_is_still_one_unit,
       the_ring_keeps_only_the_newest,
       the_ring_normalises_what_it_is_given,
       normalising_never_builds_the_representation]},
     %% Its own group because it stops the application, which takes the store
     %% and its tables with it. A test process cannot delete them: they are
     %% bequeathed to `wasm_store_sup`.
     {without_the_table, [],
      [every_diagnostic_api_tolerates_the_absent_table]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_) -> ok.

init_per_group(running, Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config;
init_per_group(without_the_table, Config) ->
    ok = application:stop(wasm),
    Config.

end_per_group(running, _) -> ok;
end_per_group(without_the_table, _) ->
    {ok, _} = application:ensure_all_started(wasm),
    ok.

init_per_testcase(_, Config) ->
    wasm_jit:reset_counts(),
    Config.

end_per_testcase(_, _) ->
    wasm_jit:reset_counts(),
    ok.

%%% ---------------------------------------------------------------- cases ---

%% Reproduces the defect. On the parent commit `{limit, too_many_functions}`
%% escapes as an exception, the compiler swallows it, and every counter stays
%% at zero while the module answers interpreted for ever.
more_functions_than_one_unit_holds_still_compiles(_) ->
    N = max_funs() + 8,
    M = build(many_wat(N)),
    {ok, I} = wasm:instantiate(M, #{}, sync(whole())),
    ?assertEqual({ok, [11]}, wasm:call(I, ~"f", [10])),
    %% The second call is the one that can enter: the first asks when it ends.
    ?assertEqual({ok, [11]}, wasm:call(I, ~"f", [10])),
    #{entered := E, compiled := C, refused := R} = wasm_jit:counts(),
    ?assertEqual(0, R, "a module that fits in two units was refused"),
    ?assert(C >= N, "not every eligible function was compiled"),
    ?assert(E > 0, "generated code was never entered, so this case compared "
                   "the interpreter with itself"),
    ?assertEqual(2, wasm_jit:shards(I)),
    ok = wasm:destroy(I).

%% The adversarial split. One function is orders of magnitude larger in IR than
%% the rest, so a bin packer balancing words alone puts every small function in
%% the other bin and blows the bound there. Fails on the parent commit and on
%% the shard policy alone; passes only once the packing counts functions too.
an_uneven_split_still_respects_the_function_bound(_) ->
    Small = max_funs() + 8,
    M = build(lopsided_wat(Small, 2000)),
    {ok, I} = wasm:instantiate(M, #{}, sync(whole())),
    ?assertEqual({ok, [11]}, wasm:call(I, ~"f", [10])),
    #{refused := R, failed := F} = wasm_jit:counts(),
    ?assertEqual({0, 0}, {R, F},
                 "a word-balanced split overfilled one unit"),
    ?assertEqual([], wasm_jit:diagnostics()),
    ok = wasm:destroy(I).

%% Past every shard there is no split that fits, and the answer is a refusal
%% that says so rather than silence. Reproduces the invisibility.
a_module_past_every_shard_is_refused_and_says_so(_) ->
    N = 4 * max_funs() + 4,
    M = build(many_wat(N)),
    {ok, I} = wasm:instantiate(M, #{}, sync(whole())),
    %% Still answers, because interpreting is always correct.
    ?assertEqual({ok, [11]}, wasm:call(I, ~"f", [10])),
    #{refused := R, entered := E, crashed := Cr} = wasm_jit:counts(),
    ?assertEqual(1, R),
    ?assertEqual(0, Cr, "a refusal was counted as a crash"),
    ?assertEqual(0, E),
    ?assertMatch([{refused, _, {limit, {too_many_functions, N}}}],
                 wasm_jit:diagnostics()),
    ok = wasm:destroy(I).

%% The root defect, at the boundary where it lived: a unit over the bound must
%% come back from the generator as a value. Forced to one shard so the deep
%% refusal in `wasm_core:fun_name/1` is what answers, not the cheap pre-check.
%%
%% `wasm_core_SUITE` asserts `?assertError` on `fun_name/1` and `frame_name/1`
%% and still passes: the helpers keep their contract, the boundary caught the
%% wrong class.
a_unit_over_the_bound_is_a_value_not_an_exception(_) ->
    M = build(many_wat(max_funs() + 8)),
    {ok, I} = wasm:instantiate(M, #{}, (sync(whole()))#{compile_shards => 1}),
    ?assertEqual({ok, [11]}, wasm:call(I, ~"f", [10])),
    #{refused := R, crashed := Cr} = wasm_jit:counts(),
    ?assertEqual({1, 0}, {R, Cr}),
    ?assertMatch([{refused, _, {limit, too_many_functions}}],
                 wasm_jit:diagnostics()),
    ok = wasm:destroy(I).

%% A refusal leaves the ask standing so the retry interval paces it. Releasing
%% it would set the timestamp to zero and the next call would ask again at
%% once, which is what the parent commit does, invisibly.
a_refusal_is_paced_by_the_retry_interval(_) ->
    Was = application:get_env(wasm, compile_retry_seconds),
    ok = application:set_env(wasm, compile_retry_seconds, 1),
    try
        M = build(called_wat(4 * max_funs() + 4)),
        {ok, I} = wasm:instantiate(M, #{}, whole()),
        [?assertEqual({ok, [11]}, wasm:call(I, ~"f", [10])) || _ <- lists:seq(1, 5)],
        ?assertEqual(ok, until(fun() -> refused() >= 1 end, 5000)),
        %% Five calls inside one interval, one refusal.
        ?assertEqual(1, refused()),
        timer:sleep(1500),
        ?assertEqual({ok, [11]}, wasm:call(I, ~"f", [10])),
        ?assertEqual(ok, until(fun() -> refused() >= 2 end, 5000),
                     "the interval expired and nothing asked again"),
        ok = wasm:destroy(I)
    after
        case Was of
            undefined -> application:unset_env(wasm, compile_retry_seconds);
            {ok, V} -> application:set_env(wasm, compile_retry_seconds, V)
        end
    end.

%% `compile_force` raises deliberately. That raise happens after the outcome is
%% recorded and outside the compiler's `try`, so it is one record and not a
%% refusal plus a crash. Fails on the parent commit, where the raise is inside
%% `build/7` and lands in the catch.
a_forced_refusal_is_counted_once(_) ->
    M = build(called_wat(4 * max_funs() + 4)),
    {ok, I} = wasm:instantiate(M, #{}, (whole())#{compile_force => true}),
    ?assertEqual({ok, [11]}, wasm:call(I, ~"f", [10])),
    ?assertEqual(ok, until(fun() -> refused() >= 1 end, 5000)),
    timer:sleep(200),
    #{refused := R, crashed := Cr} = wasm_jit:counts(),
    ?assertEqual({1, 0}, {R, Cr}),
    ok = wasm:destroy(I).

%% A guard on the policy, not a reproduction: pure, and asserted directly.
the_shard_policy_splits_only_what_does_not_fit(_) ->
    Max = max_funs(),
    ?assertEqual(1, wasm_jit:shard_count(1, #{})),
    ?assertEqual(1, wasm_jit:shard_count(Max, #{})),
    ?assertEqual(2, wasm_jit:shard_count(Max + 1, #{})),
    ?assertEqual(2, wasm_jit:shard_count(2 * Max, #{})),
    ?assertEqual(3, wasm_jit:shard_count(2 * Max + 1, #{})),
    %% Capped, and past the cap is what `generate_1/5` refuses.
    ?assertEqual(4, wasm_jit:shard_count(400 * Max, #{})),
    %% An explicit request still wins, and is the number of bins *asked* for:
    %% empty ones are dropped, so one function in four bins is one part.
    ?assertEqual(4, wasm_jit:shard_count(1, #{compile_shards => 4})),
    ?assertEqual(4, wasm_jit:shard_count(1, #{compile_shards => 99})).

%% A guard: a guest that fits in one unit must still be one unit, because a
%% split turns a call between functions into a crossing.
a_module_under_the_bound_is_still_one_unit(_) ->
    M = build(many_wat(16)),
    {ok, I} = wasm:instantiate(M, #{}, sync(whole())),
    ?assertEqual({ok, [11]}, wasm:call(I, ~"f", [10])),
    ?assertEqual(1, wasm_jit:shards(I)),
    ok = wasm:destroy(I).

the_ring_keeps_only_the_newest(_) ->
    ok = wasm_code_slots:clear_diagnostics(),
    [ok = wasm_code_slots:record_diagnostic(Seq, refused, {k, Seq},
                                            {limit, Seq})
     || Seq <- lists:seq(1, 200)],
    D = wasm_code_slots:diagnostics(),
    ?assertEqual(64, length(D)),
    %% Oldest first, and the oldest kept is the 137th of 200.
    ?assertEqual([{refused, {k, S}, {limit, S}} || S <- lists:seq(137, 200)], D),
    ok = wasm_code_slots:clear_diagnostics(),
    ?assertEqual([], wasm_code_slots:diagnostics()).

the_ring_normalises_what_it_is_given(_) ->
    ok = wasm_code_slots:clear_diagnostics(),
    M = build(many_wat(4 * max_funs() + 4)),
    {ok, I} = wasm:instantiate(M, #{}, sync(whole())),
    {ok, _} = wasm:call(I, ~"f", [10]),
    [{refused, _, Reason}] = wasm_jit:diagnostics(),
    %% Small, and measured with `flat_size/1`. Not `erts_debug:size/1`, which
    %% allocates 172 words for every word it walks and has already produced one
    %% false finding in this project's measurement record.
    ?assert(erts_debug:flat_size(Reason) < 32),
    ok = wasm:destroy(I).

%% Checking the stored row cannot see a huge transient. This runs the
%% normalisation under a heap ceiling: a formatting implementation builds the
%% whole representation and is killed, a structural one allocates nothing.
normalising_never_builds_the_representation(_) ->
    Huge = lists:duplicate(1000000, $x),
    {P, _Ref} = spawn_opt(
                  fun() ->
                      ok = wasm_code_slots:record_diagnostic(
                             1, failed, k,
                             wasm_jit:normalize_reason({odd, Huge})),
                      exit(done)
                  end,
                  [monitor, {max_heap_size, #{size => 200000, kill => true,
                                              error_logger => false}}]),
    ?assertEqual(done, wait_exit(P)).

every_diagnostic_api_tolerates_the_absent_table(_) ->
    ?assertEqual(undefined, ets:whereis(wasm_code_diag)),
    ?assertEqual([], wasm_code_slots:diagnostics()),
    ?assertEqual(ok, wasm_code_slots:clear_diagnostics()),
    ?assertEqual(ok, wasm_code_slots:record_diagnostic(1, refused, k, r)),
    ?assertEqual([], wasm_code_slots:diagnostics()).

%%% -------------------------------------------------------------- helpers ---

max_funs() -> map_get(max_funs, wasm_core:limits()).

whole() -> #{compile => true, compile_after => 1, compile_whole => true}.

sync(Opts) -> Opts#{compile_sync => true}.

refused() -> map_get(refused, wasm_jit:counts()).

%% `f` plus N-1 more, none of them exported, all of them eligible. Every one is
%% compiled because `compile_whole` asks for what exists rather than what ran.
%%
%% Synchronous compilation only. `wasm_jit:spawn_compile/2` reads
%% `wasm_instance:executed/1` directly rather than going through `wanted/2`, so
%% the asynchronous path compiles what ran whatever `compile_whole` says. The
%% cases that need a large unit off the calling process use `called_wat/1`.
many_wat(N) ->
    iolist_to_binary(
      ["(module (func (export \"f\") (param i32) (result i32)
          local.get 0 i32.const 1 i32.add)",
       [["(func (param i32) (result i32) local.get 0 i32.const ",
         integer_to_list(I rem 100), " i32.add)"] || I <- lists:seq(2, N)],
       ")"]).

%% Many tiny functions and one enormous one, so the IR words are lopsided and
%% the packing has to keep counting functions rather than only weighing them.
lopsided_wat(Small, Big) ->
    iolist_to_binary(
      ["(module (func (export \"f\") (param i32) (result i32)
          local.get 0 i32.const 1 i32.add)",
       [["(func (param i32) (result i32) local.get 0 i32.const ",
         integer_to_list(I rem 100), " i32.add)"] || I <- lists:seq(2, Small)],
       "(func (param i32) (result i32) local.get 0",
       [" i32.const 1 i32.add" || _ <- lists:seq(1, Big)],
       ")",
       ")"]).

%% As `many_wat/1`, and `f` calls every one of them, so they are all *executed*
%% and the asynchronous path -- which compiles what ran and not what exists --
%% sees the whole module.
called_wat(N) ->
    iolist_to_binary(
      ["(module (func (export \"f\") (param i32) (result i32)",
       [[" i32.const 0 call ", integer_to_list(I), " drop"]
        || I <- lists:seq(1, N - 1)],
       " local.get 0 i32.const 1 i32.add)",
       [["(func (param i32) (result i32) local.get 0 i32.const ",
         integer_to_list(I rem 100), " i32.add)"] || I <- lists:seq(2, N)],
       ")"]).

build(Wat) ->
    {ok, P} = wasm_wat:module(Wat),
    {ok, M} = wasm_validate:module(P),
    M.

until(F, Ms) -> until(F, Ms, erlang:monotonic_time(millisecond) + Ms).

until(F, Ms, Deadline) ->
    case F() of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) < Deadline of
                false -> timeout;
                true -> timer:sleep(20), until(F, Ms, Deadline)
            end
    end.

wait_exit(P) ->
    receive {'DOWN', _, process, P, R} -> R after 30000 -> timeout end.
