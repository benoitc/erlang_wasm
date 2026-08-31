%% @doc What the compiled tier does when things go wrong around it.
%%
%% Compilation runs on a process nobody waits for, owns a slot reservation while
%% it does, and publishes code that other processes then call. Every one of
%% those is a lifetime that can end early: the compiler can be killed, the
%% instance can be destroyed underneath it, the caller can be killed while it is
%% inside generated code, and the sixteen slots can all be taken.
%%
%% None of that may lose a slot, run somebody else's code, or answer wrongly.
%% Interpreting is always available and is the correct answer to every failure
%% here, which is what makes the property testable at all: the *answers* must be
%% identical whatever happened to the machinery.
%%
%% This is the gate item `test/audit/PERF.md` lists as unmet before the tier
%% could reasonably be on by default.
-module(wasm_jit_lifetime_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("wasm/include/wasm.hrl").
-include_lib("wasm/include/wasm_exec.hrl").

all() ->
    [a_compiler_killed_mid_flight_leaves_no_slot_behind,
     destroying_the_instance_while_it_compiles_is_harmless,
     a_caller_killed_inside_generated_code_leaves_the_slot_usable,
     every_slot_pinned_by_a_leaked_lease_still_recovers,
     a_killed_compiler_lets_its_instance_ask_again,
     the_compiler_is_supervised,
     a_stale_temp_file_in_the_cache_is_swept,
     a_cached_artifact_is_used_instead_of_compiling_again,
     a_module_without_a_content_hash_is_never_cached,
     many_processes_compiling_at_once_all_answer_the_same,
     more_modules_than_slots_still_all_answer,
     hashed_modules_contending_for_slots_all_answer,
     a_metered_invocation_never_reaches_generated_code,
     destroying_an_instance_gives_its_slot_lease_back,
     a_caller_that_never_destroys_keeps_a_bounded_entry_cache,
     a_module_split_across_shards_answers_the_same,
     a_profile_sets_what_you_did_not,
     an_unknown_profile_is_a_value_not_a_crash,
     both_engines_answer_the_same_bad_arguments].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_) -> ok.

init_per_testcase(_, Config) -> wasm_test_slots:reset(), Config.
end_per_testcase(_, _) -> wasm_test_slots:reset(), ok.

%%% --------------------------------------------------------------- cases ---

a_compiler_killed_mid_flight_leaves_no_slot_behind(_) ->
    %% The reservation is owned by the process doing the work precisely so that
    %% this is true. Killing it must return the slot, not strand it: sixteen
    %% stranded slots and the tier is off for the life of the node.
    M = build(loop_wat()),
    ?assert(free_slots() > 0),
    [begin
         {ok, I} = wasm:instantiate(M, #{}, opts()),
         {ok, _} = wasm:call(I, ~"f", [10]),
         %% The compiler is whatever process is holding a slot loading. Kill it
         %% while it is in there.
         kill_compilers(),
         ok = wasm:destroy(I)
     end || _ <- lists:seq(1, 8)],
    %% No slot may be left reserved by a process that no longer exists. Not
    %% immediately: the owner's DOWN has to be seen. A slot that reached
    %% `resident` before the kill landed is a success and not a leak, which is
    %% why this counts stuck reservations rather than free slots.
    ?assertEqual(ok, until(fun() -> loading_slots() =:= 0 end, 5000),
                 "a killed compiler left its slot reserved"),
    %% And the module still answers, through whichever path is left.
    {ok, J} = wasm:instantiate(M, #{}, opts()),
    ?assertEqual({ok, [55]}, wasm:call(J, ~"f", [10])),
    ok = wasm:destroy(J).

destroying_the_instance_while_it_compiles_is_harmless(_) ->
    %% The compiler holds the instance in a closure, so destroying it does not
    %% take the term away, but it does release the memories and tables the
    %% instance held. Generating reads only the immutable half, so this must
    %% finish or fail cleanly rather than crash the compiler and strand a slot.
    M = build(loop_wat()),
    Before = free_slots(),
    [begin
         {ok, I} = wasm:instantiate(M, #{}, opts()),
         {ok, _} = wasm:call(I, ~"f", [10]),
         ok = wasm:destroy(I)
     end || _ <- lists:seq(1, 4)],
    ?assertEqual(ok, until(fun() -> free_slots() >= Before - 1 end, 10000)),
    {ok, J} = wasm:instantiate(M, #{}, opts()),
    ?assertEqual({ok, [55]}, wasm:call(J, ~"f", [10])),
    ok = wasm:destroy(J).

a_caller_killed_inside_generated_code_leaves_the_slot_usable(_) ->
    %% A call lease is taken around every entry into generated code and given
    %% back in an `after`. A process killed while it holds one must not leave
    %% the slot pinned for ever, or the module can never be replaced.
    %%
    %% This is also the answer to cancellation on this runtime: an embedder
    %% running something untrusted kills the process, which BEAM makes safe, and
    %% that is why compiled code does not need an interruption check on its
    %% back edges.
    M = build(loop_wat()),
    {ok, I} = wasm:instantiate(M, #{}, opts()),
    {ok, _} = wasm:call(I, ~"f", [10]),
    ok = wasm_jit:await(I, 30000),
    Slot = wasm_instance:code_slot(I),
    ?assertNotEqual(undefined, Slot),
    Mod = wasm_code_slots:slot_module(Slot),

    %% Long enough that the kill lands while it is inside.
    [begin
         P = spawn(fun() -> _ = wasm:call(I, ~"f", [200000000]) end),
         timer:sleep(20),
         true = exit(P, kill),
         ok
     end || _ <- lists:seq(1, 5)],
    %% The lease counter does *not* come back: `release_call/1` runs in an
    %% `after`, and an `after` does not run for an untrappable kill. That is the
    %% leak, and the property that matters is that it cannot pin the slot: the
    %% next module must still be able to take it, because `code:soft_purge/1`
    %% is asked whenever the counter disagrees with reality.
    ?assert(wasm_code_slots:calls_in(Mod) > 0),
    ?assertEqual({ok, [55]}, wasm:call(I, ~"f", [10])),
    ok = wasm:destroy(I).

every_slot_pinned_by_a_leaked_lease_still_recovers(_) ->
    %% A call lease is given back in an `after`, and an `after` does not run
    %% when a process is killed untrappably. `exit(Pid, kill)` is how an
    %% embedder stops a runaway invocation on this runtime, so leaked leases are
    %% ordinary rather than a caller bug, and every one of them used to pin a
    %% slot for the life of the node.
    %%
    %% What makes reclaiming them safe is that the counter no longer carries
    %% correctness: generated code checks the slot generation it was built for
    %% against the one its caller was promised, which is atomic with the call in
    %% a way no lease can be. So a stuck counter can be repaired from
    %% `code:soft_purge/1`, and a caller that loses the race is told `stale` by
    %% the callee and interprets.
    %%
    %% One pinned slot proves nothing, because the next module simply takes a
    %% different one: the failure is when *every* slot is pinned. A module built
    %% from text takes a fresh identity every time it is validated, so sixteen
    %% builds of the same source are sixteen modules and fill sixteen slots.
    N = length(wasm_code_slots:slots()),
    Is = [begin
              M = build(loop_wat()),
              {ok, I} = wasm:instantiate(M, #{}, opts()),
              {ok, _} = wasm:call(I, ~"f", [10]),
              ok = wasm_jit:await(I, 60000),
              %% Leak a call lease: killed untrappably, so the `after` that
              %% would give it back never runs.
              P = spawn(fun() -> _ = wasm:call(I, ~"f", [200000000]) end),
              timer:sleep(20),
              true = exit(P, kill),
              I
          end || _ <- lists:seq(1, N)],
    Pinned = [wasm_code_slots:calls_in(Nm) || Nm <- wasm_code_slots:slots()],
    ct:log("call counters after ~p killed callers: ~p", [N, Pinned]),
    ?assert(lists:sum(Pinned) > 0, "no lease was actually leaked"),
    [ok = wasm:destroy(I) || I <- Is],

    %% Every slot now holds a counter nobody will ever give back. A further
    %% module must still compile.
    Other = build(loop_wat()),
    {ok, J} = wasm:instantiate(Other, #{}, opts()),
    {ok, [55]} = wasm:call(J, ~"f", [10]),
    ?assertEqual(ok, wasm_jit:await(J, 60000),
                 "leaked call leases pinned every slot for good"),
    ?assertEqual({ok, [55]}, wasm:call(J, ~"f", [10])),
    ok = wasm:destroy(J).

a_killed_compiler_lets_its_instance_ask_again(_) ->
    %% The leak this exists for. An instance records that it has asked for a
    %% compile so that every hot call during the tens of seconds it takes does
    %% not ask again, and each ask copies the instance to the process that will
    %% do the work.
    %%
    %% That record used to be a flag given back only on the `error` *return*, so
    %% a compiler that crashed or was killed left it set and the instance was
    %% never compiled again for the life of the node, with nothing to see. It is
    %% a time now, and a time expires.
    M = build(loop_wat()),
    {ok, I} = wasm:instantiate(M, #{}, opts()),
    {ok, _} = wasm:call(I, ~"f", [10]),
    %% Kill whoever is compiling, before it can publish.
    kill_compilers(),
    ?assertEqual(ok, until(fun() -> loading_slots() =:= 0 end, 5000)),

    %% Inside the window a second ask is refused, which is what stops every hot
    %% call copying the instance while a compile is genuinely in flight.
    ?assertNot(wasm_instance:ask_compile(I)),

    %% And once the window passes, asking is possible again. This is the whole
    %% property: with the record kept as a flag rather than a time, a compiler
    %% that was killed left it set and this instance could never be compiled
    %% again for the life of the node.
    ok = application:set_env(wasm, compile_retry_seconds, 0),
    try
        ?assert(wasm_instance:ask_compile(I),
                "a killed compiler left this instance unable to ask again")
    after
        ok = application:unset_env(wasm, compile_retry_seconds)
    end,
    ok = wasm:destroy(I).

the_compiler_is_supervised(_) ->
    %% A process nothing can see is a process nothing can stop, bound or count.
    %% Compiling used to be a bare `spawn/1`: invisible to the tree, outliving
    %% `application:stop(wasm)`, and unbounded.
    %% Under `wasm_code_sup` rather than the root: the slot manager and the
    %% compilers that reserve slots from it share one subsystem, and one
    %% restart budget, on purpose. See `wasm_sup`.
    ?assertMatch({wasm_code_sup, _, supervisor, _},
                 lists:keyfind(wasm_code_sup, 1,
                               supervisor:which_children(wasm_sup))),
    ?assertMatch({wasm_jit_sup, _, supervisor, _},
                 lists:keyfind(wasm_jit_sup, 1,
                               supervisor:which_children(wasm_code_sup))),
    %% Started empty and told what to compile afterwards, so the instance is
    %% copied to the child and not through the supervisor as well.
    {ok, Pid} = supervisor:start_child(wasm_jit_sup, []),
    ?assert(is_process_alive(Pid)),
    ?assertEqual(1, proplists:get_value(workers,
                                        supervisor:count_children(wasm_jit_sup))),
    exit(Pid, kill),
    ?assertEqual(ok, until(fun() ->
        proplists:get_value(workers, supervisor:count_children(wasm_jit_sup)) =:= 0
    end, 5000), "a killed compiler was not reaped").

a_cached_artifact_is_used_instead_of_compiling_again(_) ->
    %% What the cache is for: a node that has compiled a module once does not
    %% pay for it again, here or after a restart.
    %%
    %% A restart is simulated by throwing the slots away, which is what a fresh
    %% node has: no resident code and no memory of having compiled anything. The
    %% cache is on disk and survives that, which is the whole point.
    Dir = cache_dir("codecache"),
    ok = application:set_env(wasm, code_cache_dir, Dir),
    ok = wasm_code_cache:purge(),
    try
        %% A fixture, because the cache only keys on a content hash and a module
        %% built from text takes a fresh `reference()` on every validation. This
        %% project decodes wasm and never writes it, so bytes have to come from
        %% a file.
        Bin = fixture(["seeds", "fac.wasm"]),
        Compile = fun() ->
            {ok, M} = wasm:compile(Bin, #{identity => {sha256, crypto:hash(sha256, Bin)}}),
            {ok, I} = wasm:instantiate(M, #{}, opts()),
            {ok, [120]} = wasm:call(I, ~"fac-rec", [5]),
            ok = wasm_jit:await(I, 60000),
            %% Again, after waiting: the call that makes a module hot always
            %% interprets, because the compiler has not finished yet. That is
            %% the design, and it is why this has to call twice to see compiled
            %% code run at all.
            {ok, [120]} = wasm:call(I, ~"fac-rec", [5]),
            ok = wasm:destroy(I)
        end,
        ok = wasm_jit:reset_counts(),
        Compile(),
        ?assertEqual(0, maps:get(cached, wasm_jit:counts()),
                     "the first compilation cannot have come from the cache"),

        %% The restart.
        wasm_test_slots:reset(),
        ok = wasm_jit:reset_counts(),
        Compile(),
        ?assertEqual(1, maps:get(cached, wasm_jit:counts()),
                     "the second compilation did not use the cached artifact"),
        %% And it is real code, not a file that merely loaded.
        ?assert(maps:get(entered, wasm_jit:counts()) > 0)
    after
        ok = wasm_code_cache:purge(),
        ok = application:unset_env(wasm, code_cache_dir)
    end.

a_stale_temp_file_in_the_cache_is_swept(_) ->
    %% `store/2` writes to a temporary name and renames, and a node killed
    %% between the two leaves the temp behind. Named `X.beam.<n>` it was
    %% invisible to both the sweep and the size cap: `*.beam` does not match it,
    %% so it accumulated for ever and counted for nothing.
    Dir = cache_dir("codecache3"),
    ok = application:set_env(wasm, code_cache_dir, Dir),
    ok = wasm_code_cache:purge(),
    try
        Old = filename:join(Dir, "999999.tmp"),
        ok = file:write_file(Old, <<"half written">>),
        %% Backdate it past the sweep's hour.
        Then = calendar:gregorian_seconds_to_datetime(
                 calendar:datetime_to_gregorian_seconds(calendar:local_time())
                 - 7200),
        ok = file:change_time(Old, Then),
        %% Any store sweeps.
        ok = wasm_code_cache:store(crypto:hash(sha256, <<"k">>), <<"artifact">>),
        ?assertEqual(false, filelib:is_regular(Old),
                     "a stale temp survived a store"),
        %% And purging takes the temps as well as the entries.
        ok = file:write_file(Old, <<"again">>),
        ok = wasm_code_cache:purge(),
        ?assertEqual([], filelib:wildcard(filename:join(Dir, "*")))
    after
        ok = wasm_code_cache:purge(),
        ok = application:unset_env(wasm, code_cache_dir)
    end.

a_module_without_a_content_hash_is_never_cached(_) ->
    %% Text modules take a fresh identity on every validation, so caching them
    %% would fill the cache with entries nothing can ever hit.
    Dir = cache_dir("codecache2"),
    ok = application:set_env(wasm, code_cache_dir, Dir),
    ok = wasm_code_cache:purge(),
    try
        ?assertEqual(undefined,
                     wasm_code_cache:key(make_ref(), 1, wasm_code_0, full, [1], x)),
        M = build(loop_wat()),
        {ok, I} = wasm:instantiate(M, #{}, opts()),
        {ok, [55]} = wasm:call(I, ~"f", [10]),
        ok = wasm_jit:await(I, 60000),
        ok = wasm:destroy(I),
        ?assertEqual([], filelib:wildcard(filename:join(Dir, "*.beam")))
    after
        ok = wasm_code_cache:purge(),
        ok = application:unset_env(wasm, code_cache_dir)
    end.

many_processes_compiling_at_once_all_answer_the_same(_) ->
    %% Two processes can reach a hot call together, and both may ask. Only one
    %% may publish, and every one of them must answer the same thing whether it
    %% ended up interpreting or not.
    M = build(loop_wat()),
    Args = [0, 1, 10, 100],
    Want = [begin {ok, R} = call_fresh(M, #{}, A), R end || A <- Args],
    Self = self(),
    Ps = [spawn_monitor(
            fun() ->
                Got = [begin {ok, R} = call_fresh(M, opts(), A), R end || A <- Args],
                Self ! {self(), Got}
            end) || _ <- lists:seq(1, 24)],
    [receive
         {P, Got} -> ?assertEqual(Want, Got), demonitor(Mon, [flush]);
         {'DOWN', Mon, process, P, Why} -> ct:fail({worker_died, Why})
     after 60000 -> ct:fail(timeout)
     end || {P, Mon} <- Ps],
    ok.

%% The same contention, for modules identified by a content hash.
%%
%% Those take a different entry: their stamp is the hash and does not depend on
%% the slot generation, so the lease skips the row lookup that says which key a
%% slot holds. What stops one of them running another's code is the stamp check
%% inside generated code, and nothing else. Every module here answers a
%% different number, so borrowing a neighbour's code is visible in the result.
%%
%% `more_modules_than_slots_still_all_answer' cannot cover this: it builds from
%% text, and a text module takes a fresh `reference()` and the generational
%% entry.
hashed_modules_contending_for_slots_all_answer(_) ->
    Ms = [hashed(N) || N <- lists:seq(1, 24)],
    Want = [{ok, [N + 7]} || N <- lists:seq(1, 24)],
    %% Twice per instance, because compiling happens on the way out of the first
    %% call: it is the second that can run compiled. Calling once per instance
    %% and throwing it away, which is what the case above does, never enters
    %% generated code at all.
    Run = fun() ->
              [begin
                   %% Synchronously, so the second call really is after the
                   %% compile rather than racing it. `opts/0` compiles in the
                   %% background, which is right everywhere else and useless
                   %% here.
                   Sync = (opts())#{compile_sync => true},
                   {ok, I} = wasm:instantiate(M, #{}, Sync),
                   _ = wasm:call(I, ~"f", [7]),
                   R = wasm:call(I, ~"f", [7]),
                   ok = wasm:destroy(I),
                   R
               end || M <- Ms]
          end,
    ?assertEqual(Want, Run()),
    ok = wasm_jit:reset_counts(),
    %% Again, with every slot now holding somebody's code.
    ?assertEqual(Want, Run()),
    %% And they really ran compiled. Every refusal in this design falls back to
    %% the interpreter, which answers correctly, so the results above are
    %% equally consistent with nothing having been entered at all: a stamp that
    %% never matched would pass the assertions and prove nothing.
    #{entered := Entered} = wasm_jit:counts(),
    ?assert(Entered > 0),
    wasm_test_slots:reset().

more_modules_than_slots_still_all_answer(_) ->
    %% There are sixteen slots. The seventeenth module gets `no_slot` and
    %% interprets, which is a correct answer and not a failure, and it must not
    %% wedge anything for the ones that did get a slot.
    Ms = [build(numbered_wat(N)) || N <- lists:seq(1, 24)],
    Want = [{ok, [N + 7]} || N <- lists:seq(1, 24)],
    Got = [begin
               {ok, I} = wasm:instantiate(M, #{}, opts()),
               R = wasm:call(I, ~"f", [7]),
               ok = wasm:destroy(I),
               R
           end || M <- Ms],
    ?assertEqual(Want, Got),
    %% Ask them all again, now that the slots are contended.
    Got2 = [begin
                {ok, I} = wasm:instantiate(M, #{}, opts()),
                R = wasm:call(I, ~"f", [7]),
                ok = wasm:destroy(I),
                R
            end || M <- Ms],
    ?assertEqual(Want, Got2).

a_metered_invocation_never_reaches_generated_code(_) ->
    %% Fuel is charged at every loop back edge, and charging it round a compiled
    %% loop gives back what compiling it bought, so a metered invocation is
    %% interpreted outright. That is a deliberate refusal and it has to hold
    %% even for an instance whose module is already compiled and adopted, or a
    %% caller that asked for a fuel limit would silently not get one.
    M = build(loop_wat()),
    {ok, I} = wasm:instantiate(M, #{}, opts()),
    {ok, _} = wasm:call(I, ~"f", [10]),
    ok = wasm_jit:await(I, 30000),
    ?assertNotEqual(undefined, wasm_instance:code_slot(I)),

    ok = wasm_jit:reset_counts(),
    {ok, [55]} = wasm:call(I, ~"f", [10], #{fuel => 1000000}),
    ?assertEqual(0, maps:get(entered, wasm_jit:counts())),
    %% And the limit is real: a loop that needs more fuel than it has traps.
    ?assertMatch({error, #{kind := out_of_fuel}},
                 wasm:call(I, ~"f", [1000000], #{fuel => 5000})),
    %% With no limit it is compiled again, so the refusal is per invocation and
    %% not a permanent downgrade.
    ok = wasm_jit:reset_counts(),
    {ok, [55]} = wasm:call(I, ~"f", [10]),
    ?assert(maps:get(entered, wasm_jit:counts()) > 0),
    ok = wasm:destroy(I).

destroying_an_instance_gives_its_slot_lease_back(_) ->
    %% Compiling takes an instance lease on the slot, and it is the *instance*
    %% that owns it, so `wasm:destroy/1' has to hand it back. It did not: the
    %% lease was released only when the owning process died, and a long-lived
    %% process serving many distinct modules therefore pinned slots one by one
    %% until the tier was off for good.
    %%
    %% Distinct hashed modules, because two instances of one module share a
    %% slot and would hide the accumulation behind a single lease.
    ?assertEqual(0, instance_leases()),
    N = length(wasm_code_slots:slots()) + 4,
    [begin
         M = hashed(I),
         {ok, Inst} = wasm:instantiate(M, #{}, sync_opts()),
         {ok, _} = wasm:call(Inst, ~"f", [1]),
         ok = wasm:destroy(Inst)
     end || I <- lists:seq(1, N)],
    ?assertEqual(ok, until(fun() -> instance_leases() =:= 0 end, 5000),
                 "destroy left an instance lease on a code slot"),
    %% And the pool is usable afterwards, which is the consequence that matters:
    %% with the leases stranded there was no free slot left and every later
    %% module interpreted for the life of the node.
    ?assert(free_slots() > 0),
    %% Under 64: `hashed/1' writes the immediate as one signed LEB byte.
    {ok, J} = wasm:instantiate(hashed(50), #{}, sync_opts()),
    ?assertEqual({ok, [51]}, wasm:call(J, ~"f", [1])),
    ok = wasm:destroy(J).

%% One wasm module compiled into several generated ones. Each holds some of the
%% functions and names the next as a literal, so a call for an index this one
%% does not have is handed along the chain rather than sent back to the
%% interpreter. What must not change is any answer.
%%
%% Forced with `compile_shards`, because the automatic split only fires on a
%% module big enough that compiling it in one piece is the latency problem, and
%% no test module is remotely that.
a_module_split_across_shards_answers_the_same(_) ->
    M = build(chain_wat()),
    %% Interpreted, for the answers the compiled ones have to match.
    {ok, Plain} = wasm:instantiate(M, #{}, #{}),
    Want = [wasm:call(Plain, N, [7]) || N <- exports()],
    ?assertEqual([{ok, [7]}, {ok, [14]}, {ok, [21]}, {ok, [28]}, {ok, [35]}],
                 Want),
    ok = wasm:destroy(Plain),

    C0 = wasm_jit:counts(),
    {ok, I} = wasm:instantiate(M, #{}, (sync_opts())#{compile_shards => 3,
                                                      compile_whole => true}),
    %% One call to get it compiled. `compile_sync` builds at the *end* of an
    %% invocation, because what to compile is read from what has run, so the
    %% call that triggers it is itself interpreted.
    _ = wasm:call(I, ~"f1", [7]),
    Before = wasm_jit:counts(),
    %% Every function was compiled, so nothing was quietly dropped on the way
    %% into a unit: five functions across three of them.
    ?assertEqual(5, maps:get(compiled, Before) - maps:get(compiled, C0)),
    ?assertEqual(Want, [wasm:call(I, N, [7]) || N <- exports()]),
    After = wasm_jit:counts(),
    %% And every call *entered* generated code, which is the assertion that
    %% makes this case worth having. Answers alone prove nothing: a chain that
    %% does not chain answers `not_compiled`, the caller interprets, and the
    %% results are identical. Checked by breaking `wasm_core:miss/6` and
    %% watching this line fail.
    ?assertEqual(5, maps:get(entered, After) - maps:get(entered, Before)),
    %% And three slots are held, not one.
    ?assert(instance_leases() >= 3),
    ok = wasm:destroy(I),
    ?assertEqual(ok, until(fun() -> instance_leases() =:= 0 end, 5000),
                 "destroy left a shard's lease behind").

exports() -> [~"f1", ~"f2", ~"f3", ~"f4", ~"f5"].

%% Five functions, each calling the one below it, so a call crosses whatever
%% shard boundary the split happens to draw.
chain_wat() ->
    ~"(module
        (func (export \"f1\") (param i32) (result i32) local.get 0)
        (func (export \"f2\") (param i32) (result i32)
          local.get 0 call 0 local.get 0 i32.add)
        (func (export \"f3\") (param i32) (result i32)
          local.get 0 call 1 local.get 0 i32.add)
        (func (export \"f4\") (param i32) (result i32)
          local.get 0 call 2 local.get 0 i32.add)
        (func (export \"f5\") (param i32) (result i32)
          local.get 0 call 3 local.get 0 i32.add))".
%% A profile names a workload and expands into options that already exist. What
%% has to hold is that it sets them and that anything you set yourself wins,
%% because the whole point is a starting position rather than a policy.
a_profile_sets_what_you_did_not(_) ->
    M = build(loop_wat()),
    %% `script` asks for a compile after one call, so one call is enough. Under
    %% the default threshold of 32 nothing would be compiled here at all, which
    %% is exactly the case it exists for.
    Before = maps:get(compiled, wasm_jit:counts()),
    {ok, I} = wasm:instantiate(M, #{}, #{profile => script,
                                         compile_sync => true}),
    {ok, [55]} = wasm:call(I, ~"f", [10]),
    ?assert(maps:get(compiled, wasm_jit:counts()) > Before),
    ok = wasm:destroy(I),

    %% And an explicit option beats the profile's: `compile => false` means the
    %% tier is off however loudly the profile asks for it.
    Mid = maps:get(compiled, wasm_jit:counts()),
    {ok, J} = wasm:instantiate(M, #{}, #{profile => script, compile => false,
                                         compile_sync => true}),
    {ok, [55]} = wasm:call(J, ~"f", [10]),
    ?assertEqual(Mid, maps:get(compiled, wasm_jit:counts())),
    ok = wasm:destroy(J).

%% Nothing in this library raises, including on a name nobody defined.
an_unknown_profile_is_a_value_not_a_crash(_) ->
    M = build(loop_wat()),
    ?assertMatch({error, #{kind := unknown_profile}},
                 wasm:instantiate(M, #{}, #{profile => turbo})).

%% The compiled entry is built once per instance and kept in the *calling*
%% process's dictionary under a bare reference, which is what makes a hit one
%% `get/1'. Nothing else can recognise that key as belonging to an instance, so
%% the sweep that drops a destroyed instance's caches could not reach it and
%% `wasm_instance:release/1' only ever runs in the process that destroys the
%% instance. A worker calling instances a request handler creates and destroys
%% kept one closure per instance for as long as it lived.
%%
%% The number is not the point; that it stops growing is.
a_caller_that_never_destroys_keeps_a_bounded_entry_cache(_) ->
    M = build(loop_wat()),
    Caller = spawn(fun() -> serve() end),
    Mon = monitor(process, Caller),
    try
        First = serve_and_count(M, Caller, 200),
        Second = serve_and_count(M, Caller, 200),
        ct:pal("entry cache after 200: ~p, after 400: ~p", [First, Second]),
        ?assert(First < 200),
        %% Four hundred instances served, and still bounded: the sweep collects
        %% them the same way it collects everything else keyed by instance.
        ?assert(Second < 200)
    after
        %% It has to survive two reports, so the report clause cannot be what
        %% ends it. Stopped here instead, rather than left running for the rest
        %% of the suite holding four hundred instances' worth of closures.
        Caller ! stop,
        receive {'DOWN', Mon, _, _, _} -> ok
        after 5000 -> exit(Caller, kill)
        end
    end.

serve_and_count(M, Caller, N) ->
    Self = self(),
    _ = [begin
             {ok, I} = wasm:instantiate(M, #{}, sync_opts()),
             Caller ! {call, I, Self},
             receive
                 called -> ok;
                 {'DOWN', _, _, _, Why} -> ct:fail({caller_died, Why})
             after 10000 -> ct:fail(no_call) end,
             %% Destroyed here, which is the point: the caller never runs the
             %% erase and has no way to key one.
             ok = wasm:destroy(I)
         end || _ <- lists:seq(1, N)],
    Caller ! {report, Self},
    receive {cached, K} -> K after 10000 -> ct:fail(no_report) end.

serve() ->
    receive
        {call, I, From} ->
            %% Twice: the first call adopts the slot and interprets, and the
            %% second is the one that builds and caches the compiled entry.
            {ok, [_]} = wasm:call(I, ~"f", [3]),
            {ok, [_]} = wasm:call(I, ~"f", [3]),
            From ! called,
            serve();
        {report, To} ->
            To ! {cached, length([K || {K, _} <- get(), is_reference(K)])},
            serve();
        stop ->
            ok
    end.

%%% -------------------------------------------------------------- helpers ---

%% The two engines answer a bad argument the same way.
%%
%% `wasm_exec:check_arity/2` guards the interpreter and the compiled tier never
%% reaches it, so the same mistake used to answer `{link, argument_arity}`
%% interpreted and `{malformed, internal}` compiled, and which one an embedder
%% saw depended on whether the function was hot yet. Types were checked on
%% neither: a float where an i32 belonged crashed the interpreter into a
%% captured error, and the tier ran `i32.add` on it and answered `{ok, [-2.5]}`.
%%
%% Both arms call with a valid argument first, which is what makes the second
%% arm compiled at all. The counter assertion is the non-vacuity half: without
%% it this passes just as well with the tier switched off, comparing the
%% interpreter against itself.
both_engines_answer_the_same_bad_arguments(_Config) ->
    %% Straight-line, not `loop_wat/0`. Before the check existed the tier ran
    %% `i32.eqz` against a float, never matched, and spun for ever: the first
    %% version of this case did not fail against the parent commit, it hung.
    M = build(~"(module (func (export \"f\") (param i32) (result i32)
                  local.get 0 i32.const 1 i32.add))"),
    Bad = [[], [1, 2], [1.5], [-3.5], [<<"x">>], [null]],
    Interp = answers(M, #{}, Bad),
    wasm_jit:reset_counts(),
    Jit = answers(M, sync_opts(), Bad),
    #{entered := Entered} = wasm_jit:counts(),
    ?assert(Entered > 0, "the compiled tier was never entered, so this case "
                         "compared the interpreter with itself"),
    ?assertEqual(Interp, Jit),
    %% And every one of them is a link error naming the problem, rather than an
    %% internal one or, worse, an answer.
    [?assertMatch({link, K} when K =:= argument_arity orelse
                                 K =:= argument_type, A)
     || A <- Interp].

%% One instance, a valid call to make it hot, then each bad argument list.
answers(M, Opts, Argss) ->
    {ok, I} = wasm:instantiate(M, #{}, Opts),
    try
        {ok, [11]} = wasm:call(I, ~"f", [10]),
        {ok, [11]} = wasm:call(I, ~"f", [10]),
        [case wasm:call(I, ~"f", A) of
             {ok, V} -> {ok, V};
             {error, #{class := C, kind := K}} -> {C, K}
         end || A <- Argss]
    after
        wasm:destroy(I)
    end.

opts() -> #{compile => true, compile_after => 1}.

%% On the calling process, so a case that counts leases counts them after the
%% compilation rather than racing a background compiler.
sync_opts() -> (opts())#{compile_sync => true}.

call_fresh(M, Opts, Arg) ->
    {ok, I} = wasm:instantiate(M, #{}, Opts),
    R = wasm:call(I, ~"f", [Arg]),
    ok = wasm:destroy(I),
    R.

%% A loop, so a call can be made to last long enough to be killed in the middle,
%% and so the answer is a checkable sum rather than a constant.
loop_wat() ->
    ~"(module (func (export \"f\") (param i32) (result i32) (local i32)
        block loop
          local.get 0 i32.eqz br_if 1
          local.get 1 local.get 0 i32.add local.set 1
          local.get 0 i32.const 1 i32.sub local.set 0
          br 0
        end end
        local.get 1))".

%% Distinct modules, so each takes its own slot rather than sharing one.
numbered_wat(N) ->
    iolist_to_binary(
      ["(module (func (export \"f\") (param i32) (result i32)
          local.get 0 i32.const ", integer_to_list(N), " i32.add))"]).

cache_dir(Name) ->
    D = filename:join(["_build", "test", "logs", Name]),
    _ = filelib:ensure_path(D),
    D.

fixture(Parts) ->
    {ok, Bin} = file:read_file(
                  filename:join([wasm_spec_runner:fixtures_dir() | Parts])),
    Bin.

build(Wat) ->
    {ok, P} = wasm_wat:module(Wat),
    {ok, M} = wasm_validate:module(P),
    M.

%% `numbered_wat/1' as bytes, so it can carry a content hash.
%%
%% A module built from text takes a fresh `reference()` every validation and
%% therefore the generational entry; only a module loaded from bytes gets a
%% hash, and only a hash reaches the entry this exercises. So this one is
%% assembled rather than parsed.
hashed(N) ->
    Body = <<16#20, 0,                       % local.get 0
             16#41, (N):8/signed,            % i32.const N
             16#6A,                          % i32.add
             16#0B>>,                        % end
    Bin = wasm_asm:module(
            [wasm_asm:type_section([{[16#7F], [16#7F]}]),
             wasm_asm:func_section([0]),
             wasm_asm:export_section([{~"f", 0, 0}]),
             wasm_asm:section(10, [wasm_asm:uleb(1),
                                   wasm_asm:uleb(byte_size(Body) + 1),
                                   <<0>>, Body])]),
    {ok, M} = wasm:compile(Bin, #{identity => {sha256, crypto:hash(sha256, Bin)}}),
    M.

free_slots() ->
    length([N || {N, _G, free, _} <- ets:tab2list(wasm_code_slots)]).

loading_slots() ->
    length([N || {N, _G, St, _} <- ets:tab2list(wasm_code_slots),
                 is_tuple(St), element(1, St) =:= loading]).

%% Whoever is holding a slot in `loading`. There is no api for this, and there
%% should not be: it exists to be killed from a test.
%%
%% The *values*, not the keys. A lease map is `Lease => Owner', so the keys are
%% `{instance, Id}' tuples and `is_pid/1' over them matched nothing: this killed
%% no compiler at all, and the case that calls it passed for four months by
%% doing nothing. The fourth vacuous test in this project.
kill_compilers() ->
    [begin
         [exit(Pid, kill) || Pid <- maps:values(Leases), is_pid(Pid)],
         ok
     end || {_N, _G, {loading, _}, Leases} <- ets:tab2list(wasm_code_slots)],
    ok.

%% Slots holding an instance lease, which is what `wasm:destroy/1' has to give
%% back. A lease map is `Lease => Owner'.
instance_leases() ->
    length([L || {_N, _G, _St, Leases} <- ets:tab2list(wasm_code_slots),
                 {instance, _} = L <- maps:keys(Leases)]).

compiled_something() -> maps:get(compiled, wasm_jit:counts()) > 0.

until(F, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    until_1(F, Deadline).

until_1(F, Deadline) ->
    case F() of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) < Deadline of
                false -> timeout;
                true -> timer:sleep(25), until_1(F, Deadline)
            end
    end.

