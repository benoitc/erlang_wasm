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
     a_metered_invocation_never_reaches_generated_code].

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
    Children = supervisor:which_children(wasm_sup),
    ?assertMatch({wasm_jit_sup, _, supervisor, _},
                 lists:keyfind(wasm_jit_sup, 1, Children)),
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

%%% -------------------------------------------------------------- helpers ---

opts() -> #{compile => true, compile_after => 1}.

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
kill_compilers() ->
    [begin
         [exit(Pid, kill) || Pid <- maps:keys(Leases), is_pid(Pid)],
         ok
     end || {_N, _G, {loading, _}, Leases} <- ets:tab2list(wasm_code_slots)],
    ok.

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

