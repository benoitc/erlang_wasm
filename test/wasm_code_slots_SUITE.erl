-module(wasm_code_slots_SUITE).
-moduledoc """
The lifetime of generated code, before any of it is generated.

Every case here is a way loading generated BEAM code goes wrong *quietly*: the
code runs, the numbers look good, and the failure arrives later as a process
killed mid-call, a call that resolved to the wrong module, or an atom table
that grows for as long as somebody keeps sending modules.

The cases were named in the plan before the mechanism existed, which is the
only way a test list means anything.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2]).
-export([an_old_instance_still_reaches_its_own_code/1,
         destroying_an_instance_during_a_call_does_not_free_the_slot/1,
         exhaustion_answers_no_slot_rather_than_taking_one/1,
         loading_and_unloading_the_same_module_repeatedly/1,
         a_manager_restart_keeps_the_slots_and_the_monitors/1,
         a_holder_that_dies_gives_its_lease_back/1,
         many_distinct_modules_do_not_grow_the_atom_table/1,
         code_still_running_is_never_purged/1,
         releasing_a_lease_gives_back_its_monitor/1,
         each_slot_has_its_own_call_counter/1,
         a_call_lease_holds_a_slot_while_somebody_is_really_inside/1,
         a_call_lease_comes_back_after_a_throw/1,
         a_call_lease_is_far_cheaper_than_a_manager_round_trip/1,
         a_reserved_slot_cannot_be_entered_before_it_is_published/1,
         a_stale_publish_does_not_overwrite_a_later_reservation/1,
         a_compiler_that_dies_gives_the_slot_back/1,
         a_call_lease_checks_the_key_and_not_just_the_slot/1,
         a_module_becomes_hot_once_and_then_stops_counting/1]).

all() ->
    [an_old_instance_still_reaches_its_own_code,
     destroying_an_instance_during_a_call_does_not_free_the_slot,
     exhaustion_answers_no_slot_rather_than_taking_one,
     loading_and_unloading_the_same_module_repeatedly,
     a_manager_restart_keeps_the_slots_and_the_monitors,
     a_holder_that_dies_gives_its_lease_back,
     many_distinct_modules_do_not_grow_the_atom_table,
     code_still_running_is_never_purged,
     releasing_a_lease_gives_back_its_monitor,
     each_slot_has_its_own_call_counter,
     a_call_lease_holds_a_slot_while_somebody_is_really_inside,
     a_call_lease_comes_back_after_a_throw,
     a_call_lease_is_far_cheaper_than_a_manager_round_trip,
     a_reserved_slot_cannot_be_entered_before_it_is_published,
     a_stale_publish_does_not_overwrite_a_later_reservation,
     a_compiler_that_dies_gives_the_slot_back,
     a_call_lease_checks_the_key_and_not_just_the_slot,
     a_module_becomes_hot_once_and_then_stops_counting].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_) -> ok.

init_per_testcase(_Case, Config) ->
    %% Cases claim slots by name, so each one starts from an empty pool.
    [begin
         _ = code:purge(N),
         _ = code:delete(N),
         _ = code:purge(N)
     end || N <- wasm_code_slots:slots()],
    %% The table is the supervisor's and outlives every case, so a case starts
    %% from an empty pool rather than from whatever the last one left.
    [true = ets:insert(wasm_code_slots, {N, 0, free, #{}})
     || N <- wasm_code_slots:slots()],
    %% Call leases live in an `atomics' counter rather than in the table, so
    %% they have to be drained separately or a case that left one raised would
    %% take a slot out of the pool for every case after it.
    [[ok = wasm_code_slots:release_call(N)
      || _ <- lists:seq(1, wasm_code_slots:calls_in(N))]
     || N <- wasm_code_slots:slots()],
    Config.

leases_of(Key) ->
    [L || {_N, _G, St, Ls} <- ets:tab2list(wasm_code_slots),
          St =:= {resident, Key} orelse St =:= {loading, Key},
          L <- maps:keys(Ls)].

%% The whole loading transaction in one step, which is what most cases want:
%% reserve, publish at once, answer the name. The cases that are *about* the
%% transaction drive `claim_loading/3' directly.
claim(Key, Lease, Owner) ->
    case wasm_code_slots:claim_loading(Key, Lease, Owner) of
        {compile, Mod, Token} -> ok = wasm_code_slots:publish(Token), {ok, Mod};
        {resident, Mod} -> {ok, Mod};
        Other -> Other
    end.

%%% --------------------------------------------------------------- cases ---

an_old_instance_still_reaches_its_own_code(_) ->
    %% The failure this prevents: a name is reused, and a fully qualified call
    %% from an instance built against the old code resolves to the new. The
    %% lease is what makes the reuse impossible while the old instance exists.
    Ref = make_ref(),
    {ok, Mod} = claim(key_a, {instance, Ref}, self()),
    ok = load_answering(Mod, 1),
    ?assertEqual(1, Mod:answer()),

    %% Somebody else wants a slot for a different module. It must not get this
    %% one, and with a pool of this size it will get another.
    {ok, Other} = claim(key_b, {instance, make_ref()}, self()),
    ?assertNotEqual(Mod, Other),
    ok = load_answering(Other, 2),

    %% The old instance still resolves to its own code.
    ?assertEqual(1, Mod:answer()),
    ?assertEqual(2, Other:answer()).

destroying_an_instance_during_a_call_does_not_free_the_slot(_) ->
    %% An instance can be destroyed while a call into it is running. Releasing
    %% the instance lease must not let the code be replaced underneath that
    %% call, which is why calls hold a lease of their own.
    IRef = make_ref(),
    CRef = make_ref(),
    {ok, Mod} = claim(key_a, {instance, IRef}, self()),
    ok = wasm_code_slots:lease(key_a, {call, CRef}, self()),

    ok = wasm_code_slots:release(key_a, {instance, IRef}),
    ?assertMatch([{Mod, key_a, 1}], wasm_code_slots:resident()),

    %% Only now, with the call gone as well.
    ok = wasm_code_slots:release(key_a, {call, CRef}),
    ?assertMatch([{Mod, key_a, 0}], wasm_code_slots:resident()).

exhaustion_answers_no_slot_rather_than_taking_one(_) ->
    %% The pool is finite and the answer when it is full is "interpret this
    %% one". A manager that could not say that would have to kill a caller or
    %% grow the atom table.
    N = length(wasm_code_slots:slots()),
    Keys = [{full, K} || K <- lists:seq(1, N)],
    [?assertMatch({ok, _}, claim(K, {instance, make_ref()}, self()))
     || K <- Keys],
    ?assertEqual({error, no_slot},
                 claim(one_too_many, {instance, make_ref()}, self())),

    %% Giving one back makes one available, and not before.
    [First | _] = Keys,
    [L] = leases_of(First),
    ok = wasm_code_slots:release(First, L),
    ?assertMatch({ok, _}, claim(one_too_many, {instance, make_ref()}, self())).

loading_and_unloading_the_same_module_repeatedly(_) ->
    %% The same content key over and over must not walk through the pool. It
    %% takes the slot it already has.
    Firsts = [begin
                  R = make_ref(),
                  {ok, M} = claim(key_a, {instance, R}, self()),
                  ok = wasm_code_slots:release(key_a, {instance, R}),
                  M
              end || _ <- lists:seq(1, 50)],
    ?assertEqual(1, length(lists:usort(Firsts))),
    ?assertEqual(1, length(wasm_code_slots:resident())).

a_manager_restart_keeps_the_slots_and_the_monitors(_) ->
    %% The table is the supervisor's, so a crash here loses nothing. What has
    %% to be rebuilt is the monitors: without them a holder could die
    %% unnoticed and hold its slot for the life of the node.
    Holder = spawn(fun() -> receive stop -> ok end end),
    Ref = make_ref(),
    {ok, Mod} = claim(key_a, {instance, Ref}, Holder),

    Pid = whereis(wasm_code_slots),
    MRef = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', MRef, _, _, _} -> ok after 5000 -> ct:fail(no_exit) end,
    wait_for(fun() -> is_pid(whereis(wasm_code_slots)) end),

    ?assertMatch([{Mod, key_a, 1}], wasm_code_slots:resident()),

    %% And the rebuilt monitor still fires.
    Holder ! stop,
    wait_for(fun() -> wasm_code_slots:resident() =:= [{Mod, key_a, 0}] end).

a_holder_that_dies_gives_its_lease_back(_) ->
    Holder = spawn(fun() -> receive stop -> ok end end),
    {ok, Mod} = claim(key_a, {instance, make_ref()}, Holder),
    ?assertMatch([{Mod, key_a, 1}], wasm_code_slots:resident()),
    Holder ! stop,
    wait_for(fun() -> wasm_code_slots:resident() =:= [{Mod, key_a, 0}] end).

many_distinct_modules_do_not_grow_the_atom_table(_) ->
    %% The argument for pre-interned names, measured rather than asserted.
    %% Atoms are node-wide and never reclaimed, so a name derived from a
    %% module's own bytes is a permanent leak with the sender holding the tap.
    %% This covers the loop and continuation identifiers a generator would
    %% make as well, by generating and loading real code into every slot.
    Before = erlang:system_info(atom_count),
    [begin
         Key = {churn, K},
         R = make_ref(),
         case claim(Key, {instance, R}, self()) of
             {ok, Mod} ->
                 ok = load_answering(Mod, K),
                 ?assertEqual(K, Mod:answer()),
                 ok = wasm_code_slots:release(Key, {instance, R});
             {error, no_slot} -> ok
         end
     end || K <- lists:seq(1, 500)],
    After = erlang:system_info(atom_count),
    %% Some slack for whatever else the node interned meanwhile; the point is
    %% that it is not proportional to 500.
    ?assert(After - Before < 100,
            lists:flatten(io_lib:format("atom table grew by ~w over 500 modules",
                                        [After - Before]))).

code_still_running_is_never_purged(_) ->
    %% `code:purge/1' kills processes still running old code, so reuse goes
    %% through `soft_purge/1' instead.
    %%
    %% What `soft_purge/1' can see is *old* code, which only exists once a name
    %% has been loaded twice. So the leases are the primary guarantee -- they
    %% are what says nobody is in the current generation -- and `soft_purge/1'
    %% is the second: it catches anyone still in the generation before. This
    %% case walks both generations, because checking only one proves nothing.
    Ref = make_ref(),
    {ok, Mod} = claim(key_a, {instance, Ref}, self()),
    ok = load_looping(Mod),
    Self = self(),
    Runner = spawn(fun() -> Self ! running, Mod:spin() end),
    receive running -> ok after 5000 -> ct:fail(no_start) end,

    %% The lease is released while a call is still inside, which is the caller
    %% bug this exists to contain. The slot is handed out, because nothing can
    %% see a process sitting in code that is still current.
    %%
    %% Asked for under the same key, so it is the same slot. A module prefers
    %% its own home slot now, so a *different* key would be given a different
    %% one and this case would stop being about a slot whose code is still
    %% running.
    ok = wasm_code_slots:release(key_a, {instance, Ref}),
    {ok, Mod} = claim(key_a, {instance, make_ref()}, self()),
    ok = load_answering(Mod, 2),
    ?assertEqual(2, Mod:answer()),

    %% Now the looping code is old and somebody is in it. The next reuse must
    %% refuse this slot rather than take it, because taking it means killing
    %% that process.
    [L] = leases_of(key_a),
    ok = wasm_code_slots:release(key_a, L),
    ?assertEqual(false, code:soft_purge(Mod)),
    Rest = [{fill, K} || K <- lists:seq(1, length(wasm_code_slots:slots()) - 1)],
    [?assertMatch({ok, _}, claim(K, {instance, make_ref()}, self()))
     || K <- Rest],
    ?assertEqual({error, no_slot},
                 claim(needs_a_slot, {instance, make_ref()}, self())),

    %% And it becomes available again the moment nothing is inside it.
    exit(Runner, kill),
    wait_for(fun() -> code:soft_purge(Mod) end),
    ?assertMatch({ok, Mod}, claim(needs_a_slot, {instance, make_ref()}, self())).

releasing_a_lease_gives_back_its_monitor(_) ->
    %% The leak this prevents: `drop/3' removed the lease from the table and
    %% left the monitor behind, so the manager accumulated one monitor per
    %% lease it had ever handed out and never dropped a single one.
    Before = monitor_count(),
    [begin
         Ref = make_ref(),
         {ok, _} = claim(churn, {instance, Ref}, self()),
         ok = wasm_code_slots:release(churn, {instance, Ref})
     end || _ <- lists:seq(1, 200)],
    ?assertEqual(Before, monitor_count()).

each_slot_has_its_own_call_counter(_) ->
    %% Two slots sharing a counter would be invisible until a slot was reused
    %% underneath a live call, which is the failure this whole module exists to
    %% prevent. Leasing each in turn and reading all of them says they do not.
    Slots = wasm_code_slots:slots(),
    [begin
         ok = wasm_code_slots:lease_call(N),
         ?assertEqual([{M, case M of N -> 1; _ -> 0 end} || M <- Slots],
                      [{M, wasm_code_slots:calls_in(M)} || M <- Slots]),
         ok = wasm_code_slots:release_call(N)
     end || N <- Slots].

a_call_lease_holds_a_slot_while_somebody_is_really_inside(_) ->
    %% An instance destroyed mid-call releases its lease while the call is still
    %% inside the code, and the call lease is the only thing left saying so.
    %%
    %% "Really inside" is the whole of the contract now, and it used to be more
    %% than that. A raised counter alone no longer keeps a slot out of the pool,
    %% because a raised counter is not evidence: `release_call/1` runs in an
    %% `after`, an `after` does not run when a process is killed untrappably,
    %% and killing a process is how a runaway invocation is stopped here. Slots
    %% that could never be reclaimed were the result.
    %%
    %% `code:soft_purge/1` is the evidence instead, and what makes *that* safe
    %% is that generated code checks the slot generation it was built for
    %% against the one its caller was promised. A caller holding a lease but not
    %% yet inside is exactly the case `soft_purge` cannot see, and exactly the
    %% case the generation check catches.
    Ref = make_ref(),
    {ok, Mod} = claim(key_a, {instance, Ref}, self()),
    ok = load_answering(Mod, 1),
    ok = wasm_code_slots:lease_call(Mod),
    ok = wasm_code_slots:release(key_a, {instance, Ref}),
    ?assertEqual([], leases_of(key_a)),

    %% Nobody is executing the code, so the slot is reclaimable despite the
    %% raised counter, and the counter is repaired on the way.
    Rest = [{fill, K} || K <- lists:seq(1, length(wasm_code_slots:slots()) - 1)],
    [?assertMatch({ok, _}, claim(K, {instance, make_ref()}, self()))
     || K <- Rest],
    ?assertMatch({ok, _},
                 claim(one_too_many, {instance, make_ref()}, self())),
    ?assertEqual(0, wasm_code_slots:calls_in(Mod)).

a_call_lease_comes_back_after_a_throw(_) ->
    %% A trap is a throw, and a trap out of compiled code is ordinary. Without
    %% the `after' the count would stay raised and the slot would be lost for
    %% the lifetime of the node.
    {ok, Mod} = claim(key_a, {instance, make_ref()}, self()),
    ok = wasm_code_slots:lease_call(Mod),
    ?assertEqual(boom,
                 try (try throw(boom) after ok = wasm_code_slots:release_call(Mod) end)
                 catch throw:B -> B end),
    ?assertEqual(0, wasm_code_slots:calls_in(Mod)).

a_call_lease_is_far_cheaper_than_a_manager_round_trip(_) ->
    %% The reason there are two mechanisms at all. An interpreted call costs
    %% 44 ns, so a lease through the manager at 5.8 us cannot be taken per
    %% call, and this is the number that says the cheap one stayed cheap.
    %% The threshold is loose on purpose: it is here to catch a call lease that
    %% has quietly become a message again, not to track nanoseconds.
    {ok, Mod} = claim(key_a, {instance, make_ref()}, self()),
    N = 10000,
    {Us, ok} = timer:tc(fun() -> churn_call_lease(Mod, N) end),
    Each = Us * 1000 / N,
    ct:log("call lease + release: ~.1f ns", [Each]),
    ?assert(Each < 1000).

churn_call_lease(_Mod, 0) -> ok;
churn_call_lease(Mod, N) ->
    ok = wasm_code_slots:lease_call(Mod),
    ok = wasm_code_slots:release_call(Mod),
    churn_call_lease(Mod, N - 1).

a_reserved_slot_cannot_be_entered_before_it_is_published(_) ->
    %% The race this closes: the old `claim/3' wrote the row naming the new key
    %% and dropped the exclusive hold *before* the binary was loaded, so a second
    %% caller for the same key got the name and ran the slot's previous
    %% occupant.
    {compile, Mod, Token} =
        wasm_code_slots:claim_loading(key_a, {instance, make_ref()}, self()),

    %% Nothing may enter it while it is being filled in.
    ?assertEqual(stale, wasm_code_slots:lease_call(Mod, key_a)),
    ?assertEqual(loading,
                 wasm_code_slots:claim_loading(key_a, {instance, make_ref()},
                                               self())),

    ok = load_answering(Mod, 7),
    ok = wasm_code_slots:publish(Token),

    ?assertMatch({ok, _Gen}, wasm_code_slots:lease_call(Mod, key_a)),
    ?assertEqual(7, Mod:answer()),
    ok = wasm_code_slots:release_call(Mod),
    ?assertMatch({resident, Mod},
                 wasm_code_slots:claim_loading(key_a, {instance, make_ref()},
                                               self())).

a_stale_publish_does_not_overwrite_a_later_reservation(_) ->
    %% A compiler slow enough to be overtaken must not publish over whatever
    %% took its place. Keying `publish/1' on the content key rather than on the
    %% slot generation is exactly how it would.
    Ref = make_ref(),
    {compile, Mod, Token} =
        wasm_code_slots:claim_loading(key_a, {instance, Ref}, self()),
    ok = wasm_code_slots:abort(Token),

    %% The slot is free again and somebody else takes it, for the same key.
    {compile, Mod, Token2} =
        wasm_code_slots:claim_loading(key_a, {instance, make_ref()}, self()),
    ?assertNotEqual(Token, Token2),
    ?assertEqual(stale, wasm_code_slots:publish(Token)),
    ?assertEqual(ok, wasm_code_slots:publish(Token2)).

a_compiler_that_dies_gives_the_slot_back(_) ->
    %% Otherwise the slot stays exclusively held for the life of the node and is
    %% never reused, which takes it out of the pool for good.
    Self = self(),
    Owner = spawn(fun() ->
                          R = wasm_code_slots:claim_loading(key_a, {instance, make_ref()},
                                                            self()),
                          Self ! {reserved, R},
                          receive never -> ok end
                  end),
    Mod = receive {reserved, {compile, M, _}} -> M
          after 1000 -> ct:fail(timeout)
          end,
    ?assertEqual(stale, wasm_code_slots:lease_call(Mod, key_a)),

    exit(Owner, kill),
    wait_for(fun() -> wasm_code_slots:calls_in(Mod) =:= 0 end),
    %% The same key, so the same slot: a module prefers its home slot and this
    %% one is free again. Asking for a *different* key would be a fair test of
    %% the pool recovering but not of this slot being the one that came back.
    ?assertMatch({compile, Mod, _},
                 wasm_code_slots:claim_loading(key_a, {instance, make_ref()},
                                               self())).

a_call_lease_checks_the_key_and_not_just_the_slot(_) ->
    %% A caller that remembered a name can be overtaken by a reuse between
    %% remembering and leasing. The counter protects the slot; it says nothing
    %% about which module is in it, so the lease has to check.
    Ref = make_ref(),
    {ok, Mod} = claim(key_a, {instance, Ref}, self()),
    ok = load_answering(Mod, 1),
    ?assertMatch({ok, _Gen}, wasm_code_slots:lease_call(Mod, key_a)),
    ok = wasm_code_slots:release_call(Mod),

    %% Every other slot taken first, so that releasing this one leaves exactly
    %% one reusable and the next claim has to land on it. Which slot a claim
    %% picks is otherwise table order, which is not an order.
    Rest = [{fill, K} || K <- lists:seq(1, length(wasm_code_slots:slots()) - 1)],
    [?assertMatch({ok, _}, claim(K, {instance, make_ref()}, self())) || K <- Rest],

    %% The instance goes, the slot is reused for something else, and the name
    %% the old caller remembered now holds different code.
    ok = wasm_code_slots:release(key_a, {instance, Ref}),
    {ok, Mod} = claim(key_z, {instance, make_ref()}, self()),
    ?assertEqual(stale, wasm_code_slots:lease_call(Mod, key_a)),
    ?assertEqual(0, wasm_code_slots:calls_in(Mod)).

a_module_becomes_hot_once_and_then_stops_counting(_) ->
    Id = {sha256, <<"a">>},
    ?assertEqual([false, false, true],
                 [wasm_code_slots:hot(Id, 3) || _ <- lists:seq(1, 3)]),
    %% The row is gone, so counting starts again rather than growing for ever.
    %% Nothing asks after the module is compiled, which is why that is fine.
    ?assertEqual([], ets:lookup(wasm_code_calls, Id)),

    %% Counting is per module, so two identities do not interfere.
    Other = {sha256, <<"b">>},
    ?assertEqual(false, wasm_code_slots:hot(Other, 2)),
    ?assertEqual(false, wasm_code_slots:hot(Id, 2)),
    ?assertEqual(true, wasm_code_slots:hot(Other, 2)).

%%% -------------------------------------------------------------- helpers ---

monitor_count() ->
    {monitors, Ms} = erlang:process_info(whereis(wasm_code_slots), monitors),
    length(Ms).

%% A real generated module, so the case exercises loading and purging and not
%% just bookkeeping.
load_answering(Mod, N) ->
    Forms = [{attribute, 1, module, Mod},
             {attribute, 1, export, [{answer, 0}]},
             {function, 1, answer, 0, [{clause, 1, [], [], [{integer, 1, N}]}]}],
    {ok, Mod, Bin} = compile:forms(Forms, [binary, return_errors]),
    {module, Mod} = code:load_binary(Mod, atom_to_list(Mod) ++ ".erl", Bin),
    ok.

load_looping(Mod) ->
    Forms = [{attribute, 1, module, Mod},
             {attribute, 1, export, [{spin, 0}]},
             {function, 1, spin, 0,
              [{clause, 1, [], [],
                [{call, 1, {remote, 1, {atom, 1, timer}, {atom, 1, sleep}},
                  [{integer, 1, 60000}]},
                 {call, 1, {atom, 1, spin}, []}]}]}],
    {ok, Mod, Bin} = compile:forms(Forms, [binary, return_errors]),
    {module, Mod} = code:load_binary(Mod, atom_to_list(Mod) ++ ".erl", Bin),
    ok.

wait_for(F) -> wait_for(F, 100).
wait_for(_F, 0) -> ct:fail(timeout);
wait_for(F, N) ->
    case F() of
        true -> ok;
        _ -> timer:sleep(20), wait_for(F, N - 1)
    end.
