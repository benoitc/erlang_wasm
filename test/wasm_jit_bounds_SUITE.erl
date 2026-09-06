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
%% `?MAX_SHARDS` is private to `wasm_jit`; this is the same number, asserted
%% against `compile_limits/0` so a change there fails here rather than silently.
-define(MAX_SHARDS_HERE, 4).

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
       a_request_past_the_ceiling_is_refused_before_it_is_lowered,
       compile_whole_reaches_the_background_compiler,
       eight_callers_share_one_background_compile,
       a_compile_outlives_the_process_that_asked_for_it,
       the_ring_keeps_only_the_newest,
       the_ring_normalises_what_it_is_given,
       normalising_never_builds_the_representation,
       a_compile_over_the_ceiling_is_refused_and_the_guest_still_answers,
       the_ceiling_reaches_the_process_that_runs_the_compiler,
       a_bad_ceiling_is_reported_once_and_compiles_anyway]},
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

%% The ceiling fires, the outcome is a value naming the configured number, and
%% the guest is unaffected. Watched to fail on the parent commit, where
%% `compile_max_heap_words` is read by nothing: `refused` stays at zero and the
%% diagnostic is absent.
a_compile_over_the_ceiling_is_refused_and_the_guest_still_answers(_) ->
    W = min_heap_words() * 2,
    with_ceiling(W, fun () ->
        M = build(many_wat(64)),
        {ok, I} = wasm:instantiate(M, #{}, sync(whole())),
        %% Before and after, because a killed compiler must leave the guest
        %% exactly where it found it.
        ?assertEqual({ok, [11]}, wasm:call(I, ~"f", [10])),
        #{refused := R, crashed := Cr, compiled := C} = wasm_jit:counts(),
        ?assertEqual({1, 0, 0}, {R, Cr, C}),
        ?assertMatch([{refused, _, {limit, {compile_memory, W}}}],
                     wasm_jit:diagnostics()),
        ?assertEqual({ok, [11]}, wasm:call(I, ~"f", [10])),
        ok = wasm:destroy(I)
    end).

%% The defect that killed the earlier design, pinned: a ceiling set on a process
%% that only waits. This asserts the flag is on the process that is *inside* the
%% OTP compiler, not on the one blocked in a receive.
%%
%% On the parent commit no spawned process carries a non-default ceiling, so
%% `Found` is empty. On the design that was dropped, the pid carrying the
%% ceiling would be the coordinator and its stacktrace would be a receive, which
%% is why the stacktrace is asserted and not only the flag.
the_ceiling_reaches_the_process_that_runs_the_compiler(_) ->
    W = min_heap_words() * 100000,
    with_ceiling(W, fun () -> reaches(W, 3) end).

reaches(_W, 0) ->
    ct:fail(never_caught_the_compiler);
reaches(W, Tries) ->
    %% Deliberately slow, so the child is alive long enough to be caught. A
    %% spawn trace message is not a scheduling barrier: the child is runnable
    %% the moment it exists and this process learns of it asynchronously, so
    %% losing the race is ordinary and is retried rather than tolerated.
    M = build(many_wat(400)),
    Me = self(),
    Runner = spawn(fun () ->
                       {ok, I} = wasm:instantiate(M, #{}, sync(whole())),
                       A = wasm:call(I, ~"f", [10]),
                       %% Read here, while this process is certainly alive:
                       %% asking after it has answered gets `undefined`.
                       Me ! {answered, self(), A,
                             process_info(self(), max_heap_size)}
                   end),
    1 = erlang:trace(Runner, true, [procs, set_on_spawn]),
    Found = catch_compiler(Runner, []),
    RunnerFlag =
        receive {answered, Runner, A, RFlag} ->
                ?assertEqual({ok, [11]}, A),
                RFlag
        after 120000 -> ct:fail(runner_never_answered)
        end,
    %% `trace/3` raises on a process that has already exited, and by here the
    %% runner always has.
    try erlang:trace(Runner, false, [procs, set_on_spawn]) catch _:_ -> 0 end,
    flush_trace(),
    case Found of
        [] -> reaches(W, Tries - 1);
        [{Flag, Stack} | _] ->
            ?assertMatch(#{size := W, kill := true,
                           include_shared_binaries := true}, Flag),
            %% Caught inside the OTP compiler, which is the whole claim: the
            %% ceiling is on the process doing the work and not on one waiting
            %% for it.
            ?assert(lists:any(fun ({compile, _, _, _}) -> true;
                                  (_) -> false
                              end, Stack)),
            %% And the coordinator is not itself capped, which is what the
            %% design that was dropped would have done: it set the ceiling on
            %% the process blocked in a receive.
            ?assertMatch({max_heap_size, #{size := 0}}, RunnerFlag)
    end.

%% Poll the child rather than suspending it the instant it appears. A spawn
%% trace message is not a scheduling barrier and `initial_call` for a fun is
%% `{erlang,apply,2}`, so neither the moment of arrival nor the name it started
%% with says what this process is. What does say it is finding it *inside* the
%% OTP compiler, and the compile takes seconds, so there is a wide window to
%% look in. `process_info/2` on a running process is safe.
catch_compiler(Runner, Acc) ->
    receive
        {trace, _, spawn, Child, _MFA} ->
            case poll_child(Child, erlang:monotonic_time(millisecond) + 5000) of
                skip -> catch_compiler(Runner, Acc);
                Got -> catch_compiler(Runner, [Got | Acc])
            end;
        {trace, _, _, _, _} -> catch_compiler(Runner, Acc);
        {trace, _, _, _} -> catch_compiler(Runner, Acc)
    after 2000 -> Acc
    end.

poll_child(Child, Deadline) ->
    case {process_info(Child, max_heap_size),
          process_info(Child, current_stacktrace)} of
        %% The reaper is spawned plain and carries no ceiling, so it is skipped
        %% here without ever being mistaken for the compiler.
        {{max_heap_size, #{size := S} = Flag}, {_, Stack}} when S > 0 ->
            case lists:any(fun ({compile, _, _, _}) -> true;
                               (_) -> false
                           end, Stack) of
                true -> {Flag, Stack};
                false -> again(Child, Deadline)
            end;
        %% Dead, or not ours.
        {undefined, _} -> skip;
        _ -> skip
    end.

again(Child, Deadline) ->
    case erlang:monotonic_time(millisecond) < Deadline of
        true -> timer:sleep(5), poll_child(Child, Deadline);
        false -> skip
    end.

flush_trace() ->
    receive
        {trace, _, _, _, _} -> flush_trace();
        {trace, _, _, _} -> flush_trace()
    after 0 -> ok
    end.

%% A mistyped value must not turn the tier off, must not spend a diagnostics
%% row, and must be said once per uninterrupted occurrence. The last row is the
%% upper bound, which nothing documents: `size` has to be a small integer.
a_bad_ceiling_is_reported_once_and_compiles_anyway(_) ->
    Min = min_heap_words(),
    %% Every shape of wrong, including the two edges. `Min - 1` is where
    %% `spawn_opt` raises `badarg` at the bottom and `1 bsl 59` is where it
    %% raises at the top, which nothing documents.
    [bad_ceiling(V) || V <- [banana, -1, 1.5, Min - 1, 1 bsl 59]],
    %% Said once per uninterrupted occurrence of the same value, which is the
    %% part a `persistent_term` memo could not promise: two compilers reading
    %% it concurrently would both see the old value and both warn.
    ?assertEqual(1, warnings(fun () -> two_compiles(banana) end)),
    ?assertEqual(1, warnings(fun () -> two_compiles(banana),
                                       two_compiles(banana) end)),
    %% Corrected, then mistyped the same way again: the condition cleared, so
    %% it is news a second time. This is what fails if the server is told only
    %% about the failures.
    ?assertEqual(2, warnings(fun () -> two_compiles(banana),
                                       two_compiles(Min * 4),
                                       two_compiles(banana) end)),
    %% Two different wrong values are two conditions, which is what fails if
    %% the memo keys on the environment key instead of the raw term.
    ?assertEqual(2, warnings(fun () -> two_compiles(banana),
                                       two_compiles(-1) end)),
    %% And the two values that mean "no ceiling" say nothing at all.
    [begin
         wasm_jit:reset_counts(),
         with_ceiling(V, fun () ->
             ?assertEqual(0, wasm_jit:max_heap_words()),
             ?assertEqual(0, map_get(max_heap_words, wasm_jit:compile_limits()))
         end)
     end || V <- [0, undefined]],
    ok.

%% Count the warnings a body produces, by being the `logger` handler for it.
warnings(Body) ->
    reset_config_memo(),
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => #{pid => self()}}),
    try
        Body(),
        drain_warnings(0)
    after
        _ = logger:remove_handler(?MODULE),
        reset_config_memo()
    end.

drain_warnings(N) ->
    receive {warned, _} -> drain_warnings(N + 1)
    after 200 -> N
    end.

%% The `logger` handler callback. Only this module's own message is counted, so
%% anything else the node says during the body is ignored.
log(#{level := warning, msg := {Fmt, Args}}, #{config := #{pid := Pid}}) ->
    Text = unicode:characters_to_list(io_lib:format(Fmt, Args)),
    case string:find(Text, "compile_max_heap_words") of
        nomatch -> ok;
        _ -> Pid ! {warned, Text}, ok
    end;
log(_, _) ->
    ok.

two_compiles(Value) ->
    with_ceiling(Value, fun () ->
        M = build(many_wat(8)),
        [begin
             {ok, I} = wasm:instantiate(M, #{}, sync(whole())),
             _ = wasm:call(I, ~"f", [10]),
             ok = wasm:destroy(I)
         end || _ <- [1, 2]]
    end).

bad_ceiling(Value) ->
    wasm_jit:reset_counts(),
    reset_config_memo(),
    with_ceiling(Value, fun () ->
        ?assertEqual(0, wasm_jit:max_heap_words()),
        M = build(many_wat(8)),
        {ok, I} = wasm:instantiate(M, #{}, sync(whole())),
        ?assertEqual({ok, [11]}, wasm:call(I, ~"f", [10])),
        {ok, J} = wasm:instantiate(M, #{}, sync(whole())),
        ?assertEqual({ok, [11]}, wasm:call(J, ~"f", [10])),
        %% The tier still works, and nothing was counted as a failure of it.
        #{compiled := C, refused := R, failed := F, crashed := Cr} =
            wasm_jit:counts(),
        ?assert(C > 0),
        ?assertEqual({0, 0, 0}, {R, F, Cr}),
        %% The complaint is not a diagnostic and must not evict one.
        ?assertEqual([], wasm_jit:diagnostics()),
        ok = wasm:destroy(I),
        ok = wasm:destroy(J)
    end).

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
    Ceiling = map_get(max_compile_funs, wasm_jit:compile_limits()),
    ?assert(Max >= ?CPYTHON_HOT_FUNS,
            "one _start's worth of CPython no longer fits a single unit, so its "
            "artifact is no longer cacheable"),
    ?assertEqual(1, wasm_jit:shard_count(?CPYTHON_HOT_FUNS, #{})),
    ?assertEqual(3, wasm_jit:shard_count(?CPYTHON_WHOLE_FUNS, #{})),
    %% The hot set is admitted; the whole module is **not**, and that is the
    %% point of the two bounds being separate. The name pool genuinely covers
    %% 11,447 names across three units -- it would compile, given the memory --
    %% and admission rejects it anyway, because a request that size was measured
    %% at 33 GB resident and published nothing.
    ?assert(?CPYTHON_HOT_FUNS =< Ceiling),
    ?assert(?CPYTHON_WHOLE_FUNS > Ceiling,
            "the acceptance ceiling admits the whole-module compile again"),
    ?assert(?CPYTHON_WHOLE_FUNS =< ?MAX_SHARDS_HERE * Max,
            "the name pool no longer covers what admission is refusing, so the "
            "refusal would happen for the wrong reason"),
    %% And the ceiling itself: exactly at it is admitted, one past it is not.
    ?assertEqual(1, wasm_jit:shard_count(1, #{})),
    ?assert(Ceiling > Max, "the ceiling is not distinct from the name pool").

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

%% Admission counts what was *asked for*, before anything is lowered.
%%
%% `unit/2` lowers every selected function and only then filters by
%% `can_compile/2`, so counting its output meant a refused request had already
%% built and retained its whole IR -- 3.7 M words for CPython. It also meant a
%% module of many unsupported functions could lower an arbitrary number of them
%% while never reaching the ceiling in *eligible* ones, which is what this
%% module is: 8,193 functions the generator refuses.
%%
%% On the parent that costs 8,193 lowerings and answers `retry`, because
%% `can_compile/2` rejects them all, `unit/2` returns `[]` and an empty unit is
%% a retry rather than a refusal. Here it costs none and answers `refused`.
%% Unsupported on purpose, so the parent-failure run cannot accidentally start
%% an enormous compilation.
a_request_past_the_ceiling_is_refused_before_it_is_lowered(_) ->
    N = map_get(max_compile_funs, wasm_jit:compile_limits()) + 1,
    M = build(unsupported_wat(N)),
    {module, _} = code:ensure_loaded(wasm_instance),
    1 = erlang:trace_pattern({wasm_instance, compiler_ir, 2}, true,
                             [call_count]),
    try
        {ok, I} = wasm:instantiate(M, #{}, sync(whole())),
        try
            %% Still answers, because a refusal means interpret.
            ?assertEqual({ok, [11]}, wasm:call(I, ~"f", [10])),
            ?assertEqual(1, refused()),
            ?assertMatch([{refused, _, {limit, {too_many_functions, N}}}],
                         wasm_jit:diagnostics()),
            {call_count, Lowered} =
                erlang:trace_info({wasm_instance, compiler_ir, 2}, call_count),
            ?assertEqual(0, Lowered,
                         "a refused request lowered its functions anyway")
        after
            ok = wasm:destroy(I)
        end
    after
        _ = erlang:trace_pattern({wasm_instance, compiler_ir, 2}, false,
                                 [call_count])
    end.

%% `f` compiles; every other function reads an exported mutable global, which
%% becomes a reference cell and is refused with `global_get_ref`.
unsupported_wat(N) ->
    iolist_to_binary(
      ["(module (global $g (export \"g\") (mut i32) (i32.const 0))
         (func (export \"f\") (param i32) (result i32)
           local.get 0 i32.const 1 i32.add)",
       [["(func (param i32) (result i32) global.get $g drop local.get 0"
         " i32.const ", integer_to_list(I rem 100), " i32.add)"]
        || I <- lists:seq(2, N)],
       ")"]).

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

min_heap_words() ->
    {min_heap_size, Min} = erlang:system_info(min_heap_size),
    Min.

%% Set, run, restore. `undefined` means the key was absent, which is not the
%% same as it being present and set to `undefined`.
%%
%% It does *not* reset the server's held value on the way in: several of the
%% cases above depend on what it is holding from the previous body.
with_ceiling(Value, F) ->
    Was = application:get_env(wasm, compile_max_heap_words),
    ok = application:set_env(wasm, compile_max_heap_words, Value),
    try F()
    after
        case Was of
            undefined -> application:unset_env(wasm, compile_max_heap_words);
            {ok, Old} -> application:set_env(wasm, compile_max_heap_words, Old)
        end,
        ok
    end.

%% Guarded, so this helper works on a commit that has no `observe_config/1`.
%% Without the guard every case using it fails with `undef` on the parent, which
%% is a failure that proves nothing: it would look identical if the behaviour
%% under test were present and correct.
reset_config_memo() ->
    _ = code:ensure_loaded(wasm_code_slots),
    case erlang:function_exported(wasm_code_slots, observe_config, 1) of
        true -> wasm_code_slots:observe_config(ok);
        false -> ok
    end.

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
