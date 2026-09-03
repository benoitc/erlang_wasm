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

%% Measured, on the pinned guest recorded in `test/audit/PERF.md`: CPython 3.12
%% reaches this many functions in one `_start`, and has this many eligible in
%% the whole module. They are here so that putting the pool back to 2048 fails a
%% case, which nothing derived from `max_funs()` can do.
-define(CPYTHON_HOT_FUNS, 2333).
-define(CPYTHON_WHOLE_FUNS, 11447).

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
       a_cpython_sized_hot_set_is_one_real_unit,
       the_pool_covers_the_measured_cpython_sets,
       compile_whole_reaches_the_background_compiler,
       eight_callers_share_one_background_compile,
       a_compile_outlives_the_process_that_asked_for_it,
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
    N = 4 * max_funs() + 1,
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
    M = build(many_wat(max_funs() + 1)),
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
        %% One unit over its own bound, not four over theirs: the ceiling case
        %% below is the expensive one and there is no reason for two.
        M = build(many_wat(max_funs() + 1)),
        {ok, I} = wasm:instantiate(M, #{}, (whole())#{compile_shards => 1}),
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
    M = build(many_wat(max_funs() + 1)),
    {ok, I} = wasm:instantiate(M, #{}, (whole())#{compile_force => true,
                                                  compile_shards => 1}),
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
%% A guard, not a reproduction: it passes on the parent commit by construction.
%% What it adds over `shard_count/2` is that the OTP compiler actually accepts a
%% generated module of this size, which no pure assertion can say. Sized at
%% CPython's measured hot set, because that is the module this bound exists for.
a_cpython_sized_hot_set_is_one_real_unit(_) ->
    N = ?CPYTHON_HOT_FUNS,
    M = build(many_wat(N)),
    {ok, I} = wasm:instantiate(M, #{}, sync(whole())),
    try
        ?assertEqual({ok, [11]}, wasm:call(I, ~"f", [10])),
        ?assertEqual(1, wasm_jit:shards(I)),
        ?assertEqual(N, compiled()),
        ?assertEqual({ok, [11]}, wasm:call(I, ~"f", [10])),
        ?assert(map_get(entered, wasm_jit:counts()) > 0)
    after
        ok = wasm:destroy(I)
    end.

%% The requirement, as opposed to the algorithm. Everything else in this suite
%% is written against `max_funs()` and would pass just as well at 2048, which is
%% the value CPython does not fit.
the_pool_covers_the_measured_cpython_sets(_) ->
    Max = max_funs(),
    ?assert(Max >= ?CPYTHON_HOT_FUNS,
            "one _start's worth of CPython no longer fits a single unit, so its "
            "artifact is no longer cacheable"),
    ?assertEqual(1, wasm_jit:shard_count(?CPYTHON_HOT_FUNS, #{})),
    ?assertEqual(3, wasm_jit:shard_count(?CPYTHON_WHOLE_FUNS, #{})),
    ?assert(?CPYTHON_WHOLE_FUNS =< 4 * Max).

%% `compile_whole` has to mean the same thing off the calling process.
%%
%% `spawn_compile/2` read `wasm_instance:executed/1` directly rather than going
%% through `wanted/2`, so the background compiler compiled what had run and the
%% option was honoured only under `compile_sync`.
%%
%% 257 functions and not fewer. At or below `?LAZY_THRESHOLD` a module is lowered
%% eagerly, `executed/1` answers `[]`, and `[]` already means every function --
%% so a smaller module passes this whether the bug is there or not.
compile_whole_reaches_the_background_compiler(_) ->
    N = 257,
    M = build(many_wat(N)),
    {ok, I} = wasm:instantiate(M, #{}, whole()),
    try
        %% One function called, every function wanted.
        ?assertEqual({ok, [11]}, wasm:call(I, ~"f", [10])),
        %% On the instance rather than on the global counter: `await/2` answers
        %% as soon as *this* instance has adopted a slot, so a broken
        %% implementation comes back having compiled the one function that ran
        %% and the count below fails at once, instead of a poll timing out
        %% thirty seconds later and saying only that something did not happen.
        ?assertEqual(ok, wasm_jit:await(I, 30000)),
        #{compiled := C, refused := R, failed := F, crashed := Cr} =
            wasm_jit:counts(),
        ?assertEqual(N, C),
        ?assertEqual({0, 0, 0}, {R, F, Cr}),
        ?assertEqual(1, wasm_jit:shards(I)),
        ?assertEqual({ok, [11]}, wasm:call(I, ~"f", [10])),
        ?assert(map_get(entered, wasm_jit:counts()) > 0)
    after
        %% A failing asynchronous case must not leave an instance or a slot
        %% lease behind for the next one to trip over.
        ok = wasm:destroy(I)
    end.

%% One background compile, eight callers, and every observation a delta.
%%
%% The `entered` assertion is the point of the second barrier: eight second
%% calls must give exactly eight entries. A merely positive delta would pass
%% with one caller in generated code and seven still interpreting.
eight_callers_share_one_background_compile(_) ->
    ?assertEqual(ok, until(fun() -> workers() =:= 0 end, 10000)),
    wasm_jit:reset_counts(),
    N = 257,
    M = build(many_wat(N)),
    {ok, I} = wasm:instantiate(M, #{}, whole()),
    try
        Ps = [caller(I) || _ <- lists:seq(1, 8)],
        ?assertEqual(lists:duplicate(8, {ok, [11]}), release(Ps)),
        ?assertEqual(ok, wasm_jit:await(I, 60000)),
        #{compiled := C, refused := R, failed := F, crashed := Cr} =
            wasm_jit:counts(),
        ?assertEqual(N, C, "eight askers compiled the module more than once"),
        ?assertEqual({0, 0, 0}, {R, F, Cr}),
        ?assertEqual(1, wasm_jit:shards(I)),
        Before = map_get(entered, wasm_jit:counts()),
        Qs = [caller(I) || _ <- lists:seq(1, 8)],
        ?assertEqual(lists:duplicate(8, {ok, [11]}), release(Qs)),
        ?assertEqual(8, map_get(entered, wasm_jit:counts()) - Before)
    after
        ok = wasm:destroy(I),
        ?assertEqual(ok, until(fun() -> workers() =:= 0 end, 10000))
    end.

%% The property the `wanted/2` fix rests on: what to compile is read in the
%% calling process, whose dictionary holds it, and copied to the worker before
%% the caller can die.
%%
%% This passes on the parent commit, which read `executed/1` in the same place,
%% so it is a guard rather than a reproduction and is mutation-tested instead:
%% move `wanted/2` into `compiler_loop/0` and it fails.
%%
%% Ordinary compilation, not `compile_whole`, because `wanted/2` answers `[]`
%% for that without reading anything caller-local, and the case would then
%% assert nothing at all.
a_compile_outlives_the_process_that_asked_for_it(_) ->
    a_compile_outlives_the_process_that_asked_for_it(3, 1).

a_compile_outlives_the_process_that_asked_for_it(0, _) ->
    ct:fail("never suspended the compiler before it published");
a_compile_outlives_the_process_that_asked_for_it(Tries, Salt) ->
    ?assertEqual(ok, until(fun() -> workers() =:= 0 end, 10000)),
    wasm_jit:reset_counts(),
    %% `f` calls 200 helpers, so 201 functions are executed and none of the rest
    %% is. A two-function compile would finish before this could suspend it.
    M = build(pair_wat(257, 200, Salt)),
    Self = self(),
    {C, Mon} = spawn_monitor(
                 fun() ->
                     {ok, I} = wasm:instantiate(M, #{}, opts()),
                     {ok, [11]} = wasm:call(I, ~"f", [10]),
                     Self ! {ask_returned, self()},
                     receive stop -> ok end
                 end),
    receive {ask_returned, C} -> ok after 60000 -> ct:fail(no_ask) end,
    %% Establish the schedule rather than hope for it: the caller must die while
    %% the worker is holding the work and before it publishes.
    case suspend_worker() of
        error ->
            exit(C, kill),
            receive {'DOWN', Mon, process, C, _} -> ok end,
            a_compile_outlives_the_process_that_asked_for_it(Tries - 1, Salt + 1);
        {ok, W} ->
            exit(C, kill),
            receive {'DOWN', Mon, process, C, _} -> ok after 10000 -> ct:fail(alive) end,
            true = erlang:resume_process(W),
            ?assertEqual(ok, until(fun() -> compiled() >= 201 end, 60000)),
            ?assertEqual(201, compiled(),
                         "the worker compiled something other than what the "
                         "dead caller had run"),
            %% Which indices, not only how many. A fresh instance adopts what
            %% was published; `f` was run and is compiled, `g` was not and is
            %% not, and `generational_entry/3` bumps `entered` only when
            %% generated code returns or traps -- `{error, not_compiled}` falls
            %% through to the interpreter untouched.
            {ok, J} = wasm:instantiate(M, #{}, opts()),
            try
                E0 = map_get(entered, wasm_jit:counts()),
                ?assertEqual({ok, [11]}, wasm:call(J, ~"f", [10])),
                E1 = map_get(entered, wasm_jit:counts()),
                ?assertEqual(1, E1 - E0, "the selected function was not compiled"),
                ?assertEqual({ok, [17]}, wasm:call(J, ~"g", [10])),
                ?assertEqual(0, map_get(entered, wasm_jit:counts()) - E1,
                             "a function the caller never ran was compiled")
            after
                ok = wasm:destroy(J)
            end
    end.

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
    M = build(many_wat(max_funs() + 1)),
    {ok, I} = wasm:instantiate(M, #{}, (sync(whole()))#{compile_shards => 1}),
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

compiled() -> map_get(compiled, wasm_jit:counts()).

%% `f` plus N-1 more, none of them exported, all of them eligible. Every one is
%% compiled because `compile_whole` asks for what exists rather than what ran.

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

%% `f` at 0 calls `Calls` helpers, so exactly `Calls + 1` functions are executed
%% and `g` at 1 is exported and never among them. `Salt` only changes the bytes,
%% so a retry gets a module identity of its own rather than adopting what the
%% previous round published.
pair_wat(N, Calls, Salt) ->
    iolist_to_binary(
      ["(module (func (export \"f\") (param i32) (result i32)",
       [[" i32.const 0 call ", integer_to_list(I), " drop"]
        || I <- lists:seq(2, Calls + 1)],
       " local.get 0 i32.const ", integer_to_list(Salt), " i32.sub",
       " i32.const ", integer_to_list(Salt), " i32.add i32.const 1 i32.add)",
       "(func (export \"g\") (param i32) (result i32)"
       " local.get 0 i32.const 7 i32.add)",
       [["(func (param i32) (result i32) local.get 0 i32.const ",
         integer_to_list(I rem 100), " i32.add)"] || I <- lists:seq(3, N)],
       ")"]).

%% A process that instantiates nothing and waits to be released, so eight of
%% them can be made to call at the same moment rather than in a queue.
caller(I) ->
    Self = self(),
    spawn_monitor(fun() ->
                      Self ! {ready, self()},
                      receive go -> ok end,
                      Self ! {done, self(), wasm:call(I, ~"f", [10])}
                  end).

release(Ps) ->
    [receive {ready, P} -> ok after 10000 -> ct:fail(never_ready) end
     || {P, _} <- Ps],
    [P ! go || {P, _} <- Ps],
    [receive
         {done, P, R} -> demonitor(Mon, [flush]), R;
         {'DOWN', Mon, process, P, Why} -> ct:fail({caller_died, Why})
     after 60000 -> ct:fail(never_answered)
     end || {P, Mon} <- Ps].

workers() ->
    proplists:get_value(active, supervisor:count_children(wasm_jit_sup)).

%% The one process holding a slot in `loading`, suspended so it cannot publish.
%%
%% It spins, because the worker is not holding the slot yet when the caller
%% returns: `spawn_compile/2` sends it a message and `claim_loading/3` is a
%% `gen_server` call the worker has still to make. Looking once finds every slot
%% free and concludes, wrongly, that nothing is compiling. It gives up when the
%% slot is already `resident`, which is the race genuinely lost, and the caller
%% retries with a module of its own.
suspend_worker() -> suspend_worker(erlang:monotonic_time(millisecond) + 5000).

suspend_worker(Deadline) ->
    case loading_owners() of
        [W | _] ->
            %% `suspend_process/1` raises on a process that has already
            %% exited, which here is just the race lost.
            try erlang:suspend_process(W) of
                true ->
                    case is_process_alive(W) of
                        true -> {ok, W};
                        false -> error
                    end;
                _ -> error
            catch
                _:_ -> error
            end;
        [] ->
            case compiled() > 0 orelse
                 erlang:monotonic_time(millisecond) >= Deadline of
                true -> error;
                false -> timer:sleep(1), suspend_worker(Deadline)
            end
    end.

loading_owners() ->
    [Pid || {_N, _G, {loading, _}, Leases} <- ets:tab2list(wasm_code_slots),
            Pid <- maps:values(Leases), is_pid(Pid)].

opts() -> #{compile => true, compile_after => 1}.

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
