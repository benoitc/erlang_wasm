-module(wasm_adapter_conformance).
-moduledoc """
One case list, run against any adapter. The kernel's acceptance rule made
executable.

A new language is accepted when it passes the applicable cases **without
modifying the kernel**. If adding it needs a kernel change, that change must
describe a new generic capability and be exercised by the WAT adapters before
the language adapter uses it. This module is what makes that a property rather
than an aspiration.

## Using it

A suite supplies a context and delegates. It never writes a case of its own:

```erlang
all() -> wasm_adapter_conformance:base_cases().

echo_returns_a_result(Config) ->
    wasm_adapter_conformance:echo_returns_a_result(ctx(Config)).
```

## Opaque fixtures

The kit **never looks inside a request**. It does not parse source, know a
syntax, or recognise a language: it submits what `conformance_fixtures/1`
handed it and asserts only observable behaviour. That is the whole reason
JavaScript and Python can be adapters rather than special cases in a suite.

Fixtures come in two sets, because a single flat list contradicts the
capability model: `fake_typed_adapter` has no stdout and cannot be asked for a
stdout fixture.

## A declared capability is mandatory; an undeclared one is reported

`capabilities/1` decides what is demanded. **A skip is never a pass.** This
repo has had four tests that could not fail, and a skip that looks green is how
a fifth arrives, so an undeclared capability is reported as unsupported and
counted as neither.
""".

-export([base_cases/0, capability_cases/1, capability_cases/2,
         fixtures/1, fixtures/2, fixture/2, fixture/3,
         unsupported/2, has_capability/2]).

-export([echo_returns_a_result/1,
         a_guest_failure_is_a_worker_error/1,
         the_deadline_stops_a_runaway/1,
         cancel_stops_a_runaway/1,
         a_caller_that_dies_cancels/1,
         no_state_leaks_between_requests/1,
         errors_have_the_same_structure/1,
         submit_is_refused_without_a_reaper/1,
         a_second_submit_is_busy/1,
         await_after_acknowledgement_is_unknown/1,
         a_second_await_is_already_awaited/1,
         a_finite_await_leaves_the_slot_free/1,
         an_unacknowledged_outcome_survives/1,
         dead_worker_answers_with_a_value/1,
         the_request_directory_is_removed/1,
         the_journal_survives_the_request/1,
         cleanup_runs_after_a_trap/1,
         transferred_actions_run_only_when_cleanup_fails/1,
         repeated_requests_leak_nothing/1,
         the_reaper_finishes_what_a_killed_guardian_left/1,
         a_restarted_reaper_adopts_a_live_request/1,
         a_corrupt_journal_record_is_quarantined/1,
         a_record_naming_an_unknown_root_is_left_alone/1,
         stage_refuses_an_undeclared_mount/1,
         stage_refuses_a_traversal_path/1,
         stage_refuses_an_absolute_path/1,
         stage_refuses_past_the_byte_bound/1,
         stage_refuses_past_the_file_bound/1,
         a_restage_debits_only_the_delta/1,
         a_writable_mount_needs_a_trusted_worker/1,
         declared_snapshots_export_the_callback/1,
         an_empty_invoke_is_an_adapter_error/1,
         an_infinite_timeout_is_accepted/1,
         the_adapter_decides_the_stop/1,
         a_non_wasi_adapter_never_names_start/1,
         a_stream_bound_terminates_the_runner/1,
         an_exit_stops_the_remaining_invocations/1,
         cleanup_capacity_refuses_admission/1,
         a_silent_guardian_ends_held_holding_capacity/1,
         a_stale_job_is_refused_by_the_replacement/1,
         a_half_written_record_is_ignored/1,
         max_cleanup_actions_refuses_the_next/1,
         a_hanging_cleanup_does_not_wedge_the_reaper/1,
         register_performs_what_it_cannot_record/1,
         a_failed_transfer_aborts_before_the_guest_runs/1,
         the_guardian_reacts_to_the_workers_death/1,
         a_failed_restage_leaves_the_previous_file/1,
         the_result_channel_has_its_own_bound/1,
         host_calls_are_bounded/1,
         a_read_only_mount_refuses_a_guest_write/1,
         the_journal_is_unreachable_from_the_guest/1,
         a_writable_mount_lets_the_guest_write/1,
         memory_pages_are_bounded/1,
         a_reused_pid_denies_the_handshake/1,
         the_job_deadline_bounds_the_whole_chain/1,
         cleanup_that_cannot_finish_is_quarantined/1,
         a_late_finish_does_not_kill_the_reaper/1]).

-include_lib("stdlib/include/assert.hrl").

%% What every adapter must satisfy. The typed adapter failing any of these is
%% the signal that the kernel is a WASI runner, and it is the only signal
%% there is.
base_cases() ->
    [echo_returns_a_result,
     a_guest_failure_is_a_worker_error,
     the_deadline_stops_a_runaway,
     cancel_stops_a_runaway,
     a_caller_that_dies_cancels,
     no_state_leaks_between_requests,
     errors_have_the_same_structure,
     submit_is_refused_without_a_reaper,
     a_second_submit_is_busy,
     await_after_acknowledgement_is_unknown,
     a_second_await_is_already_awaited,
     a_finite_await_leaves_the_slot_free,
     an_unacknowledged_outcome_survives,
     dead_worker_answers_with_a_value,
     the_request_directory_is_removed,
     the_journal_survives_the_request,
     repeated_requests_leak_nothing,
     the_reaper_finishes_what_a_killed_guardian_left,
     a_restarted_reaper_adopts_a_live_request,
     a_corrupt_journal_record_is_quarantined,
     a_record_naming_an_unknown_root_is_left_alone,
     declared_snapshots_export_the_callback,
     an_infinite_timeout_is_accepted,
     cleanup_capacity_refuses_admission,
     a_silent_guardian_ends_held_holding_capacity,
     a_stale_job_is_refused_by_the_replacement,
     a_half_written_record_is_ignored,
     register_performs_what_it_cannot_record,
     the_guardian_reacts_to_the_workers_death,
     a_reused_pid_denies_the_handshake].

%% Required only when declared, and never skipped when it is. Snapshots are the
%% one exception and the reason is the phase gate: their cases need
%% `wasm:snapshot/1', which does not exist yet, so they live in
%% `wasm_snapshot_SUITE'. What is checked here is the *declaration*, which is
%% checkable with nothing implemented.
capability_cases(Adapter) -> capability_cases(Adapter, #{}).

-doc """
As `capability_cases/1`, for an adapter whose artifact needs options.

A real language adapter is handed a path to an engine, and the case list has to
be known before `init_per_suite` runs, so the options come in here rather than
out of a context that does not exist yet.
""".
-spec capability_cases(module(), map()) -> [atom()].
capability_cases(Adapter, Opts) ->
    #{by_capability := By} = fixtures(Adapter, Opts),
    lists:append([cases_for(K) || K <- lists:sort(maps:keys(By))]).

%% **Fixture-driven, not capability-driven**, and the difference is what makes
%% a third adapter possible. A case needs two things: a capability the adapter
%% has, and a request shape only that adapter knows how to build. Keying on the
%% capability alone gave the first of those and assumed the second, so a new
%% adapter declaring `framed_stream' inherited cases whose requests it had no
%% idea how to answer.
%%
%% So an adapter opts in by supplying the fixture, which is exactly the
%% contract the kit already had: it never looks inside one, it only submits it.
cases_for(stage_probe) ->
    [stage_refuses_an_undeclared_mount,
     stage_refuses_a_traversal_path,
     stage_refuses_an_absolute_path,
     stage_refuses_past_the_byte_bound,
     stage_refuses_past_the_file_bound,
     a_restage_debits_only_the_delta,
     a_failed_restage_leaves_the_previous_file,
     a_writable_mount_needs_a_trusted_worker,
     cleanup_that_cannot_finish_is_quarantined];
cases_for(memory_grow) ->
    [memory_pages_are_bounded];
cases_for(guest_probe) ->
    [a_read_only_mount_refuses_a_guest_write,
     the_journal_is_unreachable_from_the_guest,
     a_writable_mount_lets_the_guest_write];
%% Observing cleanup needs a side effect only the adapter can arrange, so it is
%% a declared hook rather than a base case. The plan's base fixtures are `echo',
%% `failure', `runaway' and `state_change', and nothing else may be assumed.
%%
%% The fixture's *value* is unused: supplying the key is how an adapter says it
%% honours `cleanup_marker' and `fail_cleanup' on any request, so the cases
%% below add those to the base fixtures rather than needing four more.
cases_for(empty_invoke) ->
    [an_empty_invoke_is_an_adapter_error];
cases_for(cleanup_marker) ->
    [cleanup_runs_after_a_trap,
     transferred_actions_run_only_when_cleanup_fails,
     a_hanging_cleanup_does_not_wedge_the_reaper];
cases_for(classify_stop) ->
    [the_adapter_decides_the_stop];
cases_for(invoke_twice) ->
    [an_exit_stops_the_remaining_invocations];
cases_for(framed_stream) ->
    [a_stream_bound_terminates_the_runner];
cases_for(adapter_hooks) ->
    [max_cleanup_actions_refuses_the_next,
     a_failed_transfer_aborts_before_the_guest_runs,
     the_job_deadline_bounds_the_whole_chain,
     a_late_finish_does_not_kill_the_reaper,
     the_result_channel_has_its_own_bound,
     host_calls_are_bounded];
cases_for(no_wasi) ->
    [a_non_wasi_adapter_never_names_start];
cases_for(_Other) ->
    %% An adapter is free to carry fixtures for its own suite. The kit reports
    %% what it does not recognise rather than guessing at it.
    [].

has_capability(Adapter, Cap) ->
    {ok, Artifact} = Adapter:artifact(#{}),
    Caps = Adapter:capabilities(Artifact),
    lists:member(Cap, maps:get(input_channels, Caps, [])) orelse
        lists:member(Cap, maps:get(result_channels, Caps, [])).

unsupported(Adapter, Cap) ->
    ct:comment(io_lib:format("~p does not declare ~p: reported, not passed",
                             [Adapter, Cap])).

fixtures(Adapter) -> fixtures(Adapter, #{}).

fixtures(Adapter, Opts) ->
    case Adapter:artifact(Opts) of
        {ok, Artifact} ->
            Adapter:conformance_fixtures(Artifact);
        {error, E} ->
            %% Loudly, because the quiet version of this is a case list that
            %% came back empty and a run that looked green having asserted
            %% nothing at all.
            erlang:error({cannot_build_artifact, Adapter, E})
    end.

fixture(Adapter, Name) -> fixture(Adapter, Name, #{}).

fixture(Adapter, Name, Opts) ->
    #{base := Base} = fixtures(Adapter, Opts),
    maps:get(Name, Base).

%%% -------------------------------------------------------------- the cases ---
%%
%% Every one takes a context the suite builds:
%%
%%   #{adapter := module(),          the adapter under test
%%     worker  := pid(),             one already started with the defaults
%%     root    := filename(),        the scratch root the reaper was given
%%     start   := fun((map()) -> {ok, pid()})}   another worker, other options

echo_returns_a_result(Ctx) ->
    ?assertMatch({ok, _}, run(Ctx, echo)).

a_guest_failure_is_a_worker_error(Ctx) ->
    {error, E} = run(Ctx, failure),
    ?assert(worker_error:is_error(E)),
    %% Nothing a guest supplied became an atom on the way here: the kind is
    %% from the closed set this layer defines, and the language's own
    %% vocabulary travels as a binary in `ctx'.
    ?assert(lists:member(maps:get(kind, E), worker_error:kinds())).

the_deadline_stops_a_runaway(Ctx) ->
    %% Twice what the adapter says it needs, rather than a number the kit made
    %% up. An engine that takes a quarter of a second to start declares
    %% `min_timeout' accordingly, and a kit that ignored it would be asserting
    %% `timeout' against a request the policy had already refused for being
    %% impossible.
    W = start(Ctx, #{limits => #{timeout => 2 * min_timeout(Ctx, runaway),
                                 fuel => infinity}}),
    {error, E} = script_worker:run(W, fix(Ctx, runaway)),
    ?assertEqual(timeout, maps:get(kind, E)),
    ok = script_worker:stop(W).

cancel_stops_a_runaway(Ctx) ->
    W = patient(Ctx),
    {ok, Ref} = script_worker:submit(W, fix(Ctx, runaway)),
    ok = script_worker:cancel(W, Ref),
    {error, E} = script_worker:await(W, Ref, patience(Ctx)),
    ?assertEqual(cancelled, maps:get(kind, E)),
    ok = script_worker:stop(W).

a_caller_that_dies_cancels(Ctx) ->
    W = patient(Ctx),
    Self = self(),
    {Pid, Mon} = spawn_monitor(
                   fun() ->
                       {ok, R} = script_worker:submit(W, fix(Ctx, runaway)),
                       Self ! {submitted, R},
                       receive never -> ok end
                   end),
    receive {submitted, _} -> ok after 5_000 -> ct:fail(no_submit) end,
    exit(Pid, kill),
    receive {'DOWN', Mon, process, Pid, _} -> ok end,
    %% The slot freeing is what says the guardian actually stopped.
    ?assertMatch({ok, _}, until_free(W, fix(Ctx, echo), ticks(Ctx))),
    ok = script_worker:stop(W).

no_state_leaks_between_requests(Ctx) ->
    A = run(Ctx, state_change),
    B = run(Ctx, state_change),
    %% A fresh instance per request means the second request sees exactly what
    %% the first one saw. Replacing a language's globals would not give this.
    ?assertEqual(A, B).

errors_have_the_same_structure(Ctx) ->
    {error, E} = run(Ctx, failure),
    %% Exactly these four keys, whichever adapter produced it, which is what
    %% makes the error model a contract rather than a convention.
    %%
    %% Deliberately not an `?assertMatch' on the shape: dialyzer pointed out
    %% that `run/2' is specced to return a `worker_error()', so matching one is
    %% provably true and the assertion could not fail. Comparing the key set is
    %% a check that survives an adapter ignoring the spec.
    ?assertEqual([class, ctx, kind, msg], lists:sort(maps:keys(E))),
    ?assert(worker_error:is_error(E)).

%% This asserts the contract and not which layer enforces it, which is worth
%% saying because the obvious reading is wrong. There are two: `submit' checks
%% `worker_reaper:alive/0', and the guardian's `reserve' fails anyway against a
%% dead reaper. Removing either alone changes nothing observable, and only
%% removing both makes this fail. Measured, not assumed.
submit_is_refused_without_a_reaper(Ctx) ->
    ok = worker_reaper:stop(),
    {error, E} = script_worker:submit(worker(Ctx), fix(Ctx, echo)),
    ?assertEqual(no_reaper, maps:get(kind, E)).

a_second_submit_is_busy(Ctx) ->
    W = patient(Ctx),
    {ok, Ref} = script_worker:submit(W, fix(Ctx, runaway)),
    {error, E} = script_worker:submit(W, fix(Ctx, echo)),
    ?assertEqual(busy, maps:get(kind, E)),
    ok = script_worker:cancel(W, Ref),
    ok = script_worker:stop(W).

await_after_acknowledgement_is_unknown(Ctx) ->
    W = worker(Ctx),
    {ok, Ref} = script_worker:submit(W, fix(Ctx, echo)),
    {ok, _} = script_worker:await(W, Ref, patience(Ctx)),
    {error, E} = script_worker:await(W, Ref, 1_000),
    ?assertEqual(unknown_ref, maps:get(kind, E)).

a_second_await_is_already_awaited(Ctx) ->
    W = patient(Ctx),
    {ok, Ref} = script_worker:submit(W, fix(Ctx, runaway)),
    Self = self(),
    _ = spawn(fun() ->
                  Self ! waiting,
                  %% `infinity`, because this one exists to *hold* the slot.
                  %% A finite wait here gives it up again, and the case then
                  %% asks for a slot nobody is holding.
                  _ = script_worker:await(W, Ref, infinity)
              end),
    receive waiting -> ok after 5_000 -> ct:fail(no_waiter) end,
    ?assertEqual(already_awaited, kind_of_second_await(W, Ref, ticks(Ctx))),
    ok = script_worker:cancel(W, Ref),
    ok = script_worker:stop(W).

a_finite_await_leaves_the_slot_free(Ctx) ->
    W = patient(Ctx),
    {ok, Ref} = script_worker:submit(W, fix(Ctx, runaway)),
    {error, E1} = script_worker:await(W, Ref, 200),
    ?assertEqual(still_running, maps:get(kind, E1)),
    %% The case a caught `gen_server' timeout alone would fail: the server must
    %% no longer believe the abandoning caller holds the single waiter slot.
    ok = script_worker:cancel(W, Ref),
    {error, E2} = script_worker:await(W, Ref, patience(Ctx)),
    ?assertEqual(cancelled, maps:get(kind, E2)),
    ok = script_worker:stop(W).

an_unacknowledged_outcome_survives(Ctx) ->
    W = worker(Ctx),
    {ok, Ref} = script_worker:submit(W, fix(Ctx, echo)),
    %% `withdraw_waiter/3' answers with the outcome once it is published and
    %% does **not** acknowledge it, so this observes retention without any
    %% await having consumed anything. Sending is not consuming.
    Outcome = until_published(W, Ref, ticks(Ctx)),
    ?assertMatch({ok, _}, Outcome),
    ?assertEqual(Outcome, script_worker:await(W, Ref, patience(Ctx))).

dead_worker_answers_with_a_value(Ctx) ->
    W = start(Ctx, #{}),
    ok = script_worker:stop(W),
    Echo = fix(Ctx, echo),
    ?assertMatch({error, #{kind := no_worker}}, script_worker:submit(W, Echo)),
    ?assertMatch({error, #{kind := no_worker}}, script_worker:run(W, Echo)),
    ?assertMatch({error, #{kind := no_worker}},
                 script_worker:cancel(W, make_ref())),
    ?assertMatch({error, #{kind := no_worker}},
                 script_worker:await(W, make_ref(), 100)).

the_request_directory_is_removed(Ctx) ->
    {ok, _} = run(Ctx, echo),
    ?assertEqual([], until_swept(root(Ctx), ticks(Ctx))).

the_journal_survives_the_request(Ctx) ->
    {ok, _} = run(Ctx, echo),
    %% It never lived in a request directory, so removing every one of them
    %% leaves it standing. There is also no arrangement of mounts that reaches
    %% it, which is why it is not under one.
    ?assert(filelib:is_dir(filename:join(root(Ctx), ".journal"))).

cleanup_runs_after_a_trap(Ctx) ->
    {Marker, Action} = markers(Ctx),
    {error, _} = script_worker:run(worker(Ctx),
                                   with_marker(fix(Ctx, failure), Marker)),
    %% Ran after the guest trapped, and the caller already had its answer
    %% before any of this: cleanup cannot change the outcome.
    ?assert(until_exists(Marker, 60)),
    %% The action was transferred to `cleanup/1', which succeeded, so it must
    %% not have run as well. Retention is what makes the failure case work,
    %% not a second unconditional release.
    timer:sleep(200),
    ?assertNot(filelib:is_file(Action)).

transferred_actions_run_only_when_cleanup_fails(Ctx) ->
    {Marker, Action} = markers(Ctx),
    Request = (with_marker(fix(Ctx, echo), Marker))#{fail_cleanup => true},
    %% A `cleanup/1' that raises never becomes an error in a result the caller
    %% already has: it is logged and counted, and the answer stands.
    ?assertMatch({ok, _}, script_worker:run(worker(Ctx), Request)),
    ?assert(until_exists(Action, 60)),
    %% And it ran *after* `cleanup/1', which is the order the retention exists
    %% for: a transferred action covers a resource `cleanup/1' now owns, so
    %% releasing it first would be releasing it behind that callback's back.
    ?assertEqual({ok, ~"after-cleanup"}, file:read_file(Action)).

repeated_requests_leak_nothing(Ctx) ->
    W = worker(Ctx),
    Echo = fix(Ctx, echo),
    %% Three, not ten. The assertions are exact counts -- reservations,
    %% request directories, journal records -- so a leak of one per request
    %% shows on the second, and ten was an arbitrary number that cost eight
    %% minutes against an interpreter.
    [{ok, _} = script_worker:run(W, Echo) || _ <- lists:seq(1, 3)],
    ?assertEqual([], until_swept(root(Ctx), ticks(Ctx))),
    %% Exact counts, not aggregates: `erlang:memory/0' and the node process
    %% count are too noisy to assert on, and a GC that has not run yet is not
    %% a leak.
    ?assertEqual([], until_no_reservations(ticks(Ctx))),
    ?assertEqual([], journal_records(root(Ctx))).

the_reaper_finishes_what_a_killed_guardian_left(Ctx) ->
    W = patient(Ctx),
    {ok, Ref} = script_worker:submit(W, fix(Ctx, runaway)),
    [#{guardian := G}] = until_reservations(1, 40),
    exit(G, kill),
    {error, E} = script_worker:await(W, Ref, patience(Ctx)),
    ?assertEqual(crashed, maps:get(kind, E)),
    %% The guardian is gone, so what removes its directory is the reaper.
    ?assertEqual([], until_swept(root(Ctx), 60)),
    ok = script_worker:stop(W).

a_restarted_reaper_adopts_a_live_request(Ctx) ->
    W = patient(Ctx),
    {ok, Ref} = script_worker:submit(W, fix(Ctx, runaway)),
    [#{id := Id}] = until_reservations(1, 40),
    Dir = filename:join(root(Ctx), <<"req-", Id/binary>>),
    ?assert(filelib:is_dir(Dir)),
    ok = worker_reaper:stop(),
    {ok, _} = worker_reaper:start_link(#{scratch => root(Ctx)}),
    %% The guardian is alive and answers the handshake, so the replacement
    %% adopts rather than replaying. This is what separates a fallback from a
    %% saboteur: a reaper that replayed here would delete a running request's
    %% mounts.
    ?assert(still_there(Dir, 20)),
    ok = script_worker:cancel(W, Ref),
    {error, _} = script_worker:await(W, Ref, patience(Ctx)),
    ok = script_worker:stop(W).

a_corrupt_journal_record_is_quarantined(Ctx) ->
    ok = worker_reaper:stop(),
    Journal = filename:join(root(Ctx), ".journal"),
    ok = file:write_file(filename:join(Journal, "planted.rec"),
                         <<"not a record at all\n">>),
    {ok, _} = worker_reaper:start_link(#{scratch => root(Ctx)}),
    %% The journal is exactly where an adversarial file would have to be
    %% planted, so a record that does not parse is moved aside and counted
    %% rather than acted on.
    ?assertEqual(1, maps:get(quarantined, worker_reaper:stats())),
    ?assert(filelib:is_file(
              filename:join([Journal, "quarantine", "planted.rec"]))).

a_record_naming_an_unknown_root_is_left_alone(Ctx) ->
    ok = worker_reaper:stop(),
    Journal = filename:join(root(Ctx), ".journal"),
    Rec = [<<"v1 ">>, worker_reaper:incarnation(), <<" 1 ">>,
           list_to_binary(pid_to_list(self())), <<" abcd\n">>,
           <<"remove_tree nosuchroot req-abcd\n">>],
    ok = file:write_file(filename:join(Journal, "unknown.rec"),
                         iolist_to_binary(Rec)),
    {ok, _} = worker_reaper:start_link(#{scratch => root(Ctx)}),
    %% Guessed at, it would name a directory nobody configured. So it is not
    %% guessed at.
    ?assertEqual(1, maps:get(quarantined, worker_reaper:stats())).

declared_snapshots_export_the_callback(Ctx) ->
    Adapter = adapter(Ctx),
    {ok, Artifact} = Adapter:artifact(artifact_opts(Ctx)),
    Declared = maps:get(snapshots, Adapter:capabilities(Artifact)) =/= unsupported,
    Exported = erlang:function_exported(Adapter, snapshot_capability, 1),
    %% All Phase 1 can check is that the two agree, which is checkable with
    %% nothing implemented. The behaviour of a snapshot belongs to its own
    %% suite under its own gate.
    ?assertEqual(Declared, Exported).

an_empty_invoke_is_an_adapter_error(Ctx) ->
    %% A spec that runs nothing is an adapter bug rather than a legitimate
    %% shape, so it is an error and not a quiet success. Only an adapter that
    %% can be *asked* for an empty sequence can be asked this, which is why it
    %% is a declared fixture: a real language adapter has no such request.
    {error, E} = script_worker:run(worker(Ctx), fix_cap(Ctx, empty_invoke)),
    ?assertEqual(adapter_failure, maps:get(kind, E)).

an_infinite_timeout_is_accepted(Ctx) ->
    W = start(Ctx, #{limits => #{timeout => infinity}}),
    %% `wasm_limits:trusted/0' sets this, so it is a legitimate value and every
    %% remaining-time computation has to read it as "no deadline" rather than
    %% doing arithmetic on an atom.
    ?assertMatch({ok, _}, script_worker:run(W, fix(Ctx, echo))),
    ok = script_worker:stop(W).

%%% ------------------------------------------------ capability: streams ---

a_stream_bound_terminates_the_runner(Ctx) ->
    W = start(Ctx, #{limits => #{max_output_bytes => 64, fuel => infinity,
                                 timeout => patience(Ctx)}}),
    {error, E} = script_worker:run(W, fix_cap(Ctx, framed_stream)),
    %% This is the assertion, and asserting only that the guest stopped writing
    %% would not be: `exit/1' also unwinds the invocation, so the guest stops
    %% either way. What it does not do is stop the **runner**, which sails on
    %% into `decode/2' with a bogus internal error where this should be.
    %% `exit/2' sends a signal no `try' can intercept, and this is how you tell.
    ?assertEqual(output_limit, maps:get(kind, E)),
    %% And the deadline is not what stopped it: 30 s against a bound of 64.
    ok = script_worker:stop(W).

the_adapter_decides_the_stop(Ctx) ->
    W = worker(Ctx),
    {error, Stopped} = script_worker:run(W, fix_cap(Ctx, classify_stop)),
    {error, Continued} = script_worker:run(W, fix_cap(Ctx, classify_continue)),
    %% The same trap, the same `execution_result()', a different answer,
    %% because `classify/2' is what decides and the kernel interprets none of
    %% it. "The kernel stops on every trap" could not express this: a WASI exit
    %% *is* a trap, so telling one from another would mean calling
    %% `wasi_preview1:exit_code/1' from the kernel.
    %%
    %% Asserted as a difference rather than as two values, because what the
    %% guest wrote is the adapter's business and the kit does not read
    %% fixtures. A kernel that stopped on every trap would make these equal.
    ?assertNotEqual(written(Stopped, stderr), written(Continued, stderr)).

an_exit_stops_the_remaining_invocations(Ctx) ->
    W = worker(Ctx),
    {ok, Once} = script_worker:run(W, fix_cap(Ctx, invoke_once)),
    {ok, Twice} = script_worker:run(W, fix_cap(Ctx, invoke_twice)),
    %% `proc_exit(0)' earns a stop for the same reason a non-zero one does: a
    %% runtime that has run its atexit handlers is in a state nobody specified.
    %% So the second invocation never ran, and one call's worth of output is
    %% all there is.
    ?assertEqual(Once, Twice).

a_non_wasi_adapter_never_names_start(Ctx) ->
    Adapter = adapter(Ctx),
    {ok, Artifact} = Adapter:artifact(artifact_opts(Ctx)),
    ?assertEqual(false, maps:get(wasi, Adapter:capabilities(Artifact))),
    %% There is no `_start' to name. A kernel that translated a `{start}'
    %% invocation would be carrying WASI knowledge in a type, and this is the
    %% fixture that would catch it.
    #{module := M} = Artifact,
    {ok, Inst} = wasm:instantiate(M, no_wasi_bindings(), #{}),
    Exports = maps:keys(wasm:exports(Inst)),
    ok = wasm:destroy(Inst),
    ?assertNot(lists:member(~"_start", Exports)),
    %% And nothing it imports is WASI either, so no arrangement of this
    %% adapter could have reached `wasi_preview1'.
    ?assertEqual([~"host"],
                 lists:usort([Mod || {Mod, _} <- maps:keys(no_wasi_bindings())])).

%%% ------------------------------------------------- capability: files ---

stage_refuses_an_undeclared_mount(Ctx) ->
    ?assertEqual(bad_stage_path, stage_kind(Ctx, nosuchmount, ~"a.txt", ~"x")).

stage_refuses_a_traversal_path(Ctx) ->
    ?assertEqual(bad_stage_path, stage_kind(Ctx, ro, ~"../escape.txt", ~"x")),
    ?assertEqual(bad_stage_path, stage_kind(Ctx, ro, ~"a/../../b.txt", ~"x")).

stage_refuses_an_absolute_path(Ctx) ->
    %% Deliberately not `/etc/passwd'. On macOS `/etc' is a symlink, so that
    %% path is refused by the symlink check whether or not the absolute-path
    %% check exists, and the case passed for the wrong reason on one platform
    %% and would have been the only thing guarding this on another.
    ?assertEqual(bad_stage_path, stage_kind(Ctx, ro, ~"/absolute.txt", ~"x")).

stage_refuses_past_the_byte_bound(Ctx) ->
    W = start(Ctx, #{limits => #{max_staged_bytes => 16}}),
    K = stage_kind_on(W, Ctx, ro, ~"big.txt", binary:copy(~"x", 64)),
    ?assertEqual(insufficient_limit, K),
    ok = script_worker:stop(W).

stage_refuses_past_the_file_bound(Ctx) ->
    W = start(Ctx, #{limits => #{max_staged_files => 1}}),
    %% Counted across all mounts together, which is why the bound is on the
    %% worker and not on a mount.
    K = stage_kind_on(W, Ctx, ro, [{~"a.txt", ~"a"}, {~"b.txt", ~"b"}]),
    ?assertEqual(insufficient_limit, K),
    ok = script_worker:stop(W).

a_restage_debits_only_the_delta(Ctx) ->
    W = start(Ctx, #{limits => #{max_staged_bytes => 8, max_staged_files => 4}}),
    %% Four bytes written three times is four bytes, not twelve, and the file
    %% count does not move either. An adapter rewriting a file does not pay
    %% twice.
    ?assertEqual(ok, stage_kind_on(W, Ctx, ro, [{~"a.txt", ~"aaaa"},
                                                {~"a.txt", ~"bbbb"},
                                                {~"a.txt", ~"cccc"}])),
    ok = script_worker:stop(W).

a_writable_mount_needs_a_trusted_worker(Ctx) ->
    Untrusted = start(Ctx, #{}),
    {error, E} = script_worker:run(Untrusted, writable(fix(Ctx, echo))),
    %% `max_staged_bytes' bounds the adapter, not the guest, and nothing bounds
    %% what a guest writes once the preopen exists. Until that exists, a
    %% writable mount is refused rather than pretended.
    ?assertEqual(insufficient_limit, maps:get(kind, E)),
    ok = script_worker:stop(Untrusted),
    Trusted = start(Ctx, #{trusted => true}),
    ?assertMatch({ok, _}, script_worker:run(Trusted, writable(fix(Ctx, echo)))),
    ok = script_worker:stop(Trusted).

%%% ---------------------------------------------------------------- helpers ---

adapter(#{adapter := A}) -> A.
worker(#{worker := W})   -> W.
root(#{root := R})       -> R.

start(#{start := Start}, Opts) ->
    {ok, W} = Start(Opts),
    W.

%% Long deadline and no fuel ceiling, so what stops a runaway is the thing the
%% case is about rather than whichever bound happened to fire first.
patient(Ctx) ->
    %% The deadline has to be one the *adapter* would accept: a worker whose
    %% `timeout` is below what `requirements/2` asks for is refused with
    %% `insufficient_limit`, and a case that then asserted `cancelled` would be
    %% asserting against a request that never started.
    start(Ctx, #{limits => #{timeout => patience(Ctx), fuel => infinity}}).

fix(Ctx, Name) -> fixture(adapter(Ctx), Name, artifact_opts(Ctx)).

fix_cap(Ctx, Name) ->
    #{by_capability := By} = fixtures(adapter(Ctx), artifact_opts(Ctx)),
    maps:get(Name, By).

%% How long this adapter's guest plausibly takes, in milliseconds.
%%
%% Every wait below is a multiple of it rather than a number the kit made up. A
%% WAT guest answers in microseconds and CPython takes the better part of a
%% minute, and a kit that assumed the first reports the second as a failure:
%% four cases did exactly that before this existed.
patience(Ctx) -> max(2_000, 3 * min_timeout(Ctx, echo)).

%% Poll iterations from the same budget. **Every helper below sleeps
%% `?TICK` ms**, or the arithmetic here is wrong for whichever one does not:
%% one slept 20 and so waited 40% of the budget it was handed.
-define(TICK, 50).
ticks(Ctx) -> patience(Ctx) div ?TICK.

%% What the adapter itself says this request needs. Asked rather than assumed,
%% because only the adapter knows what its guest costs to start.
min_timeout(Ctx, Name) ->
    Adapter = adapter(Ctx),
    {ok, Artifact} = Adapter:artifact(artifact_opts(Ctx)),
    {ok, Reqs} = Adapter:requirements(fix(Ctx, Name), Artifact),
    maps:get(min_timeout, Reqs).

%% What `Adapter:artifact/1` needs. Empty for a WAT adapter that builds its own
%% guests; a path to an engine for one that does not.
artifact_opts(Ctx) -> maps:get(artifact_opts, Ctx, #{}).

%% Every error the guardian publishes carries what the guest had already
%% written, which is most of what makes one debuggable.
written(#{ctx := #{channels := Chans}}, Which) -> maps:get(Which, Chans).

%% Every import this guest declares, and not one of them is WASI. That is the
%% point of the case: there is no `_start' and nothing named
%% `wasi_snapshot_preview1'.
no_wasi_bindings() ->
    #{{~"host", ~"input"} => fun(_Ctx, []) -> {ok, [0]} end,
      {~"host", ~"emit"}  => fun(_Ctx, []) -> {ok, []} end}.

run(Ctx, Name) -> script_worker:run(worker(Ctx), fix(Ctx, Name)).

with_marker(Request, Path) -> Request#{cleanup_marker => Path}.

markers(Ctx) ->
    Marker = filename:join(root(Ctx), "cleanup-marker"),
    Action = filename:join(root(Ctx), "action-marker"),
    _ = file:delete(Marker),
    _ = file:delete(Action),
    {Marker, Action}.

writable(Request) -> Request#{write_mount => true}.

stage_kind(Ctx, Mount, Path, Data) ->
    stage_kind_on(worker(Ctx), Ctx, Mount, Path, Data).

stage_kind_on(W, Ctx, Mount, Path, Data) ->
    stage_kind_on(W, Ctx, Mount, [{Path, Data}]).

stage_kind_on(W, Ctx, Mount, Writes) ->
    case probe(W, Ctx, Mount, Writes) of
        {error, E} -> maps:get(kind, E);
        Outcomes   -> case [K || K <- Outcomes, K =/= ok] of
                          []      -> ok;
                          [K | _] -> K
                      end
    end.

%% Every write's outcome, in order, from **one** request. Accounting is
%% per request, so a case about a refund cannot spread its writes across two.
probe(W, Ctx, Mount, Writes) ->
    Request = (fix_cap(Ctx, stage_probe))#{stage_probe => {Mount, Writes}},
    case script_worker:run(W, Request) of
        {ok, Result}   -> maps:get(probe, Result);
        {error, _} = E -> E
    end.

%% The slot frees when the outcome is relayed and cleanup runs after that, so a
%% following request can legitimately see `busy' for a moment.
until_free(_W, _R, 0) -> {error, gave_up};
until_free(W, R, N) ->
    case script_worker:run(W, R) of
        {error, #{kind := busy}} -> timer:sleep(?TICK), until_free(W, R, N - 1);
        Other                    -> Other
    end.

until_published(_W, _Ref, 0) -> {error, never_published};
until_published(W, Ref, N) ->
    case script_worker:withdraw_waiter(W, Ref, make_ref()) of
        {ok, Outcome} -> Outcome;
        _             -> timer:sleep(?TICK), until_published(W, Ref, N - 1)
    end.

kind_of_second_await(_W, _Ref, 0) -> gave_up;
kind_of_second_await(W, Ref, N) ->
    case script_worker:await(W, Ref, 100) of
        {error, #{kind := already_awaited}} -> already_awaited;
        _ -> timer:sleep(?TICK), kind_of_second_await(W, Ref, N - 1)
    end.

until_swept(_Root, 0) -> not_swept;
until_swept(Root, N) ->
    case filelib:wildcard(filename:join(Root, "req-*")) of
        []  -> [];
        _   -> timer:sleep(?TICK), until_swept(Root, N - 1)
    end.

until_no_reservations(0) -> worker_reaper:requests();
until_no_reservations(N) ->
    case worker_reaper:requests() of
        [] -> [];
        _  -> timer:sleep(?TICK), until_no_reservations(N - 1)
    end.

until_reservations(_Want, 0) -> [];
until_reservations(Want, N) ->
    case worker_reaper:requests() of
        R when length(R) =:= Want -> R;
        _ -> timer:sleep(?TICK), until_reservations(Want, N - 1)
    end.

until_exists(_Path, 0) -> false;
until_exists(Path, N) ->
    case filelib:is_file(Path) of
        true  -> true;
        false -> timer:sleep(?TICK), until_exists(Path, N - 1)
    end.

%% Deliberately the opposite shape: proving something is *not* deleted means
%% waiting and finding it still there.
still_there(Dir, 0) -> filelib:is_dir(Dir);
still_there(Dir, N) ->
    case filelib:is_dir(Dir) of
        false -> false;
        true  -> timer:sleep(?TICK), still_there(Dir, N - 1)
    end.

restart_reaper(Ctx, Opts) ->
    ok = worker_reaper:stop(),
    {ok, _} = worker_reaper:start_link(#{scratch => root(Ctx)}, Opts),
    ok.

%% A record naming a live process that is not a guardian. Everything in it is a
%% number, a hex string, a pid literal or a verb from a fixed table, which is
%% why writing one by hand is possible at all and why decoding one can never
%% mint an atom.
plant(Ctx, Name, PidText, RootName) ->
    Rec = [<<"v1 ">>, worker_reaper:incarnation(), <<" 1 ">>,
           list_to_binary(PidText), <<" beefbeef\n">>,
           <<"remove_tree ">>, list_to_binary(RootName), <<" req-beefbeef\n">>],
    ok = file:write_file(filename:join([root(Ctx), ".journal", Name]),
                         iolist_to_binary(Rec)).

until_state(_Want, 0) -> [S || #{state := S} <- worker_reaper:requests()];
until_state(Want, N) ->
    case [S || #{state := S} <- worker_reaper:requests()] of
        [Want] -> Want;
        _      -> timer:sleep(?TICK), until_state(Want, N - 1)
    end.

until_delivered(0) -> worker_reaper:requests();
until_delivered(N) ->
    case worker_reaper:requests() of
        [#{delivered := true}] = R -> R;
        _ -> timer:sleep(?TICK), until_delivered(N - 1)
    end.

until_gone(_Id, 0) -> false;
until_gone(Id, N) ->
    case [I || #{id := I} <- worker_reaper:requests(), I =:= Id] of
        []  -> true;
        [_] -> timer:sleep(?TICK), until_gone(Id, N - 1)
    end.

until_quarantined(_Want, 0) -> maps:get(quarantined, worker_reaper:stats());
until_quarantined(Want, N) ->
    case maps:get(quarantined, worker_reaper:stats()) of
        Want -> Want;
        _    -> timer:sleep(?TICK), until_quarantined(Want, N - 1)
    end.

%% Put the mode back, or the test framework cannot clean up after itself.
unwedge(Ctx) ->
    [file:change_mode(D, 8#700)
     || D <- filelib:wildcard(filename:join([root(Ctx), "req-*", "ro", "locked"]))],
    ok.

journal_records(Root) ->
    filelib:wildcard(filename:join([Root, ".journal", "*.rec"])).

%%% ------------------------------------------------- cleanup and recovery ---

cleanup_capacity_refuses_admission(Ctx) ->
    %% Admission is the only place capacity is enforced, and a reservation is a
    %% claim on *future* cleanup, so a hundred long-running requests would
    %% otherwise overbook it and discover the shortfall as they finished.
    restart_reaper(Ctx, #{max_cleanup_jobs => 1, cleanup_queue_len => 1}),
    A = patient(Ctx),
    B = patient(Ctx),
    C = patient(Ctx),
    {ok, RefA} = script_worker:submit(A, fix(Ctx, runaway)),
    {ok, RefB} = script_worker:submit(B, fix(Ctx, runaway)),
    %% Two live reservations is the whole capacity, and `live' counts.
    {error, E} = script_worker:submit(C, fix(Ctx, runaway)),
    %% A refusal it can retry rather than a leak it cannot see.
    ?assertEqual(cleanup_saturated, maps:get(kind, E)),
    ok = script_worker:cancel(A, RefA),
    ok = script_worker:cancel(B, RefB),
    [ok = script_worker:stop(W) || W <- [A, B, C]].

a_silent_guardian_ends_held_holding_capacity(Ctx) ->
    %% A record naming this process, which is alive and will never answer the
    %% handshake. That is the *unknown* case, and a timeout is not a denial: a
    %% guardian descheduled or behind a full mailbox is a live guardian that
    %% happens to be slow.
    ok = worker_reaper:stop(),
    plant(Ctx, "silent.rec", pid_to_list(self()), "scratch"),
    {ok, _} = worker_reaper:start_link(#{scratch => root(Ctx)},
                                       #{max_cleanup_jobs => 1,
                                         cleanup_queue_len => 0}),
    %% It retries, then holds. Never quarantined, because the request may still
    %% be running, and never replayed, because leaking a directory is
    %% recoverable where deleting a live request's mounts is not.
    ?assertEqual(held, until_state(held, 100)),
    ?assertEqual(0, maps:get(quarantined, worker_reaper:stats())),
    %% And it still holds its capacity. If it did not, a new request would
    %% consume what the reservation is still holding, the guardian would
    %% confirm, and cleanup would be overcommitted with no check having failed.
    W = start(Ctx, #{}),
    {error, E} = script_worker:submit(W, fix(Ctx, echo)),
    ?assertEqual(cleanup_saturated, maps:get(kind, E)),
    ok = script_worker:stop(W).

a_stale_job_is_refused_by_the_replacement(Ctx) ->
    %% A *real* reservation, because a made-up id is refused for having no
    %% record at all and would say nothing about the generation. That version
    %% of this case passed with the check removed.
    W = patient(Ctx),
    {ok, Ref} = script_worker:submit(W, fix(Ctx, runaway)),
    [#{id := Id}] = until_reservations(1, 40),
    Old = worker_reaper:generation(),
    ok = worker_reaper:stop(),
    {ok, _} = worker_reaper:start_link(#{scratch => root(Ctx)}),
    New = worker_reaper:generation(),
    ?assert(New > Old),
    [#{id := Id}] = until_reservations(1, 40),
    %% Links are not ordering: a supervisor can see the reaper's `DOWN' and
    %% start the replacement before the old jobs have processed their parent's
    %% exit signal. So acting on a record needs authorisation from the
    %% *currently registered* reaper, which checks a generation it holds in
    %% memory and answers serially. A job that wakes after its reaper is gone
    %% reaches the replacement, whose generation no longer matches.
    ?assertEqual({error, stale}, worker_reaper:authorise(Id, Old)),
    ?assertEqual(ok, worker_reaper:authorise(Id, New)),
    %% Teardown only, and deliberately not asserted on. Whether the request is
    %% still running by now is `a_restarted_reaper_adopts_a_live_request\'s
    %% subject, which asserts it directly; making this case depend on it as
    %% well only bought a race between the restart and the request.
    _ = script_worker:cancel(W, Ref),
    _ = script_worker:await(W, Ref, patience(Ctx)),
    ok = script_worker:stop(W).

a_half_written_record_is_ignored(Ctx) ->
    ok = worker_reaper:stop(),
    Journal = filename:join(root(Ctx), ".journal"),
    ok = file:write_file(filename:join(Journal, "torn.rec.part"),
                         <<"v1 half written and then the node">>),
    {ok, _} = worker_reaper:start_link(#{scratch => root(Ctx)}),
    %% A partial temp file is simply not the record: the sweep reads `.rec' and
    %% the rename is what makes one exist. Not quarantined either, because
    %% nothing about it is adversarial or corrupt.
    ?assertEqual(0, maps:get(quarantined, worker_reaper:stats())),
    ?assert(filelib:is_file(filename:join(Journal, "torn.rec.part"))).

a_hanging_cleanup_does_not_wedge_the_reaper(Ctx) ->
    restart_reaper(Ctx, #{cleanup_timeout => 300, cleanup_retries => 0}),
    {Marker, _} = markers(Ctx),
    W = start(Ctx, #{}),
    Request = (with_marker(fix(Ctx, echo), Marker))#{fail_cleanup => hang},
    ?assertMatch({ok, _}, script_worker:run(W, Request)),
    %% One bad adapter must not stop registration and recovery for every worker
    %% on the node, which is why the singleton never runs a callback itself.
    %% There is no polling here on purpose: `stats/0' waits for ever, so a
    %% wedged reaper fails this at the timetrap rather than answering late.
    ?assert(is_map(worker_reaper:stats())),
    %% And the directory still goes, because the job carries on past the
    %% callback it had to kill.
    ?assertEqual([], until_swept(root(Ctx), 100)),
    ok = script_worker:stop(W).

register_performs_what_it_cannot_record(Ctx) ->
    Marker = filename:join(root(Ctx), "unrecorded"),
    _ = file:delete(Marker),
    ok = worker_reaper:stop(),
    Result = worker_reaper:register(~"noreq",
                                    fun() -> file:write_file(Marker, ~"ran") end),
    %% A `register' that returns an error having done neither leaks precisely
    %% the resource the adapter allocated one line earlier. So it says which of
    %% the three happened, and `released' is a claim about the world.
    ?assertMatch({error, #{kind := no_reaper}, released}, Result),
    %% Asserted by the resource being gone, not merely by the error value.
    ?assert(filelib:is_file(Marker)).

the_guardian_reacts_to_the_workers_death(Ctx) ->
    W = patient(Ctx),
    {ok, _Ref} = script_worker:submit(W, fix(Ctx, runaway)),
    [_] = until_reservations(1, 40),
    %% Monitors are one-way. The worker monitors the guardian; this is the
    %% other direction, and without it the guardian would run to its deadline
    %% holding a request nobody is waiting for.
    exit(W, kill),
    ?assertEqual([], until_swept(root(Ctx), 100)).

%%% ---------------------------------------- typed adapter: bounds and hooks ---

max_cleanup_actions_refuses_the_next(Ctx) ->
    {error, E} = script_worker:run(worker(Ctx),
                                   (fix_cap(Ctx, adapter_hooks))#{register_n => 65}),
    %% The action list is adapter-controlled: without a ceiling an adapter in a
    %% loop registers until the reaper's memory is the bound.
    ?assertEqual(cleanup_saturated, maps:get(kind, E)).

a_failed_transfer_aborts_before_the_guest_runs(Ctx) ->
    Marker = filename:join(root(Ctx), "mirror-marker"),
    _ = file:delete(Marker),
    Request = (fix_cap(Ctx, adapter_hooks))#{cleanup_marker => Marker,
                                             kill_reaper_in_prepare => true},
    {error, _} = script_worker:run(worker(Ctx), Request),
    %% Transfer fails when the reaper is gone, and the reaper *is* the
    %% registry, so what cleans up is the guardian's **mirror**: it made every
    %% `register' call and kept the list as it went. The reaper's registry
    %% could not have supplied this.
    ?assert(until_exists(Marker, 60)).

the_result_channel_has_its_own_bound(Ctx) ->
    W = start(Ctx, #{limits => #{max_result_bytes => 64, fuel => infinity,
                                 max_host_calls => infinity,
                                 timeout => patience(Ctx)}}),
    {error, E} = script_worker:run(W, (fix_cap(Ctx, adapter_hooks))#{op => emit}),
    %% Separate from the output bound, because the channels are separate: this
    %% adapter has no stdout at all and still has a result to bound.
    ?assertEqual(result_limit, maps:get(kind, E)),
    ok = script_worker:stop(W).

host_calls_are_bounded(Ctx) ->
    W = start(Ctx, #{limits => #{max_host_calls => 100, fuel => infinity,
                                 max_result_bytes => 1_000_000_000,
                                 timeout => patience(Ctx)}}),
    {error, E} = script_worker:run(W, (fix_cap(Ctx, adapter_hooks))#{op => emit}),
    %% A host call burns no fuel by construction, so this is the only thing
    %% bounding a guest that does its work through an import. It matters most
    %% with `fuel => infinity', which is the compiled configuration.
    ?assertEqual(runtime_failure, maps:get(kind, E)),
    ?assertMatch(#{kind := host_call_limit},
                 maps:get(error, maps:get(ctx, E))),
    ok = script_worker:stop(W).

%%% ------------------------------------------------ capability: files ---

a_failed_restage_leaves_the_previous_file(Ctx) ->
    %% Tight on purpose: 16 bytes is room for the 5 and then the 11, and no
    %% room at all if the failed write in between charged for its 6.
    W = start(Ctx, #{limits => #{max_staged_bytes => 16, max_staged_files => 8}}),
    %% Staging `a.txt' and then `a.txt/b' cannot work, because the second needs
    %% `a.txt' to be a directory. What is asserted is the accounting: a failed
    %% stage refunds its bytes, so the budget still matches what is on disk.
    %%
    %% This exercises the failure *before* the write rather than during it. The
    %% temp-and-rename protocol covers the second, and inducing a mid-write
    %% failure portably is not something a case can do, so this does not claim
    %% to prove it.
    ?assertEqual([ok, crashed, ok],
                 probe(W, Ctx, ro, [{~"a.txt", ~"first"},
                                    {~"a.txt/b", ~"second"},
                                    {~"a.txt", ~"elevenchars"}])),
    ok = script_worker:stop(W).

%%% ------------------------------------ capability: what the guest can do ---

%% These four ask the *guest*, from inside its own sandbox, rather than
%% asserting on what the host believes it granted. A mount's mode is a claim
%% about what a preopen can do, and only a guest can check it.

a_read_only_mount_refuses_a_guest_write(Ctx) ->
    %% `ENOTCAPABLE', not `EACCES': the right was never granted, rather than
    %% granted and then denied by the filesystem. A preopen carries its rights
    %% and everything opened beneath it inherits them.
    ?assertEqual(76, probe_byte(Ctx, 0)),
    %% And reading what was staged still works, so the refusal is the mode and
    %% not a broken mount.
    ?assertEqual(0, probe_byte(Ctx, 2)).

the_journal_is_unreachable_from_the_guest(Ctx) ->
    %% Two halves, and the second is the one that matters here.
    %%
    %% The guest cannot climb out of a preopen. That is WASI's doing rather
    %% than the kernel's, and it holds wherever the journal lives, so on its
    %% own it would prove nothing about where the journal was put.
    ?assertEqual(76, probe_byte(Ctx, 1)),
    %% So: no preopen the kernel hands out contains the journal. Rights are
    %% granted per directory subtree and inherited by everything opened
    %% beneath, which is exactly why the record must not sit anywhere in that
    %% tree. This is the half a kernel change could break.
    {ok, Result} = script_worker:run(worker(Ctx), probe_request(Ctx)),
    Journal = filename:join(root(Ctx), ".journal"),
    ?assert(filelib:is_dir(Journal)),
    Dirs = maps:values(maps:get(mount_dirs, Result)),
    %% Checked first, because a comprehension over an empty list asserts
    %% nothing and would make every line below it vacuous.
    ?assert(Dirs =/= []),
    [?assertNot(contains(Dir, Journal)) || Dir <- Dirs],
    ok.

a_writable_mount_lets_the_guest_write(Ctx) ->
    W = start(Ctx, #{trusted => true}),
    Request = (probe_request(Ctx))#{write_mount => true},
    {ok, Result} = script_worker:run(W, Request),
    %% Same guest, same call, a different mount: `rw' is fd 4 and it succeeds
    %% where fd 3 refused. Without this, "read" and "write" would be two words
    %% for the same behaviour.
    ?assertEqual(0, binary:at(maps:get(stdout, Result), 3)),
    ok = script_worker:stop(W).

memory_pages_are_bounded(Ctx) ->
    Tight = start(Ctx, #{limits => #{max_memory_pages => 1}}),
    Grow = fix_cap(Ctx, memory_grow),
    {ok, Refused} = script_worker:run(Tight, Grow),
    %% `memory.grow' answers -1 as the specification requires, rather than
    %% trapping or growing past what the instance was promised.
    ?assertEqual(255, binary:at(maps:get(stdout, Refused), 0)),
    ok = script_worker:stop(Tight),
    Roomy = start(Ctx, #{limits => #{max_memory_pages => 64}}),
    {ok, Grown} = script_worker:run(Roomy, Grow),
    %% The previous size, which says the same guest does grow when it may.
    ?assertEqual(1, binary:at(maps:get(stdout, Grown), 0)),
    ok = script_worker:stop(Roomy).

%% Whether `Journal' sits anywhere beneath `Dir'.
%%
%% Both sides are forced to binary first, and that is not tidiness: mount
%% directories arrive as binaries and the suite builds the journal path as a
%% string, so `lists:prefix/2` compared binaries against strings and answered
%% `false` for every input. The assertion passed for a type reason rather than
%% a path reason, which falsification is what caught.
contains(Dir, Journal) ->
    D = filename:split(iolist_to_binary(Dir)),
    J = filename:split(iolist_to_binary(Journal)),
    lists:prefix(D, J).

probe_request(Ctx) -> fix_cap(Ctx, guest_probe).

probe_byte(Ctx, N) ->
    {ok, Result} = script_worker:run(worker(Ctx), probe_request(Ctx)),
    binary:at(maps:get(stdout, Result), N).

%%% ------------------------------------------- recovery, the harder cases ---

a_reused_pid_denies_the_handshake(Ctx) ->
    W = patient(Ctx),
    {ok, Ref} = script_worker:submit(W, fix(Ctx, runaway)),
    [#{guardian := G}] = until_reservations(1, 40),
    ok = worker_reaper:stop(),
    %% A record naming a live process that is a guardian, but for a *different*
    %% request. Liveness alone is not enough: pids are reused within one
    %% incarnation, so a record naming a dead guardian whose pid now belongs to
    %% something else would be adopted and never cleaned.
    plant(Ctx, "reused.rec", pid_to_list(G), "scratch"),
    {ok, _} = worker_reaper:start_link(#{scratch => root(Ctx)}),
    %% The planted reservation goes away, and that is the whole assertion.
    %% Every other answer keeps it: adoption would leave it `live', and silence
    %% would leave it `pending' and then `held', because a timeout is not a
    %% denial. Only an explicit `no' orphans it, so disappearing is what says
    %% the handshake was answered and answered in the negative.
    ?assert(until_gone(~"beefbeef", 100)),
    %% And it was orphaned rather than quarantined: a denial is an answer, not
    %% the ambiguity quarantine is for.
    ?assertEqual(0, maps:get(quarantined, worker_reaper:stats())),
    _ = script_worker:cancel(W, Ref),
    _ = script_worker:await(W, Ref, patience(Ctx)),
    ok = script_worker:stop(W).

the_job_deadline_bounds_the_whole_chain(Ctx) ->
    %% Each callback stays well under `cleanup_timeout'. What stops the chain
    %% is the job's own budget, and a job with a `cleanup/1' and three actions
    %% could otherwise spend four callback timeouts.
    restart_reaper(Ctx, #{cleanup_timeout => 5_000, cleanup_job_deadline => 400,
                          cleanup_retries => 0}),
    {Marker, _} = markers(Ctx),
    W = start(Ctx, #{}),
    Slow = (with_marker(fix_cap(Ctx, adapter_hooks), Marker))#{sleep_cleanup => 350,
                                                  fail_cleanup => true,
                                                  slow_actions => {3, 200,
                                                                   root(Ctx)}},
    ?assertMatch({ok, _}, script_worker:run(W, Slow)),
    ?assert(until_exists(Marker, 60)),
    %% `cleanup/1` alone spent most of the budget, so none of its transferred
    %% actions got to finish. They are not retried here either: what is being
    %% asserted is that the job stopped, not that the work was lost.
    timer:sleep(800),
    [?assertNot(filelib:is_file(filename:join(root(Ctx), "slow-" ++ N)))
     || N <- ["1", "2", "3"]],
    ok = script_worker:stop(W).

cleanup_that_cannot_finish_is_quarantined(Ctx) ->
    restart_reaper(Ctx, #{cleanup_retries => 1, cleanup_backoff => [50],
                          cleanup_timeout => 500}),
    W = start(Ctx, #{}),
    %% Something inside the request tree that genuinely cannot be removed, so
    %% the job fails on its own terms rather than being told it did.
    Wedged = (fix_cap(Ctx, stage_probe))#{wedge_cleanup => true},
    ?assertMatch({ok, _}, script_worker:run(W, Wedged)),
    %% Retried, then quarantined. This is the **only** cause of quarantine:
    %% an unresolved ownership handshake is `held', and a full queue is a
    %% refusal at admission. Work that genuinely cannot be done ends here, and
    %% the count is what an operator alerts on.
    ?assertEqual(1, until_quarantined(1, 200)),
    ok = script_worker:stop(W),
    unwedge(Ctx).

a_late_finish_does_not_kill_the_reaper(Ctx) ->
    %% A guardian that had to run its own mirror tells the reaper afterwards,
    %% and by then the reservation's monitor is long gone: it was cleared the
    %% moment the guardian's `DOWN' was processed. The reaper is a singleton,
    %% so one `badarg' here stops cleanup and recovery for every worker on the
    %% node, which is what made this worth a case rather than a guard.
    restart_reaper(Ctx, #{cleanup_timeout => 5_000}),
    {Marker, _} = markers(Ctx),
    W = patient(Ctx),
    Slow = (with_marker(fix(Ctx, runaway), Marker))#{sleep_cleanup => 2_000},
    {ok, _Ref} = script_worker:submit(W, Slow),
    %% Wait for the state to have been delivered, not merely for the
    %% reservation to exist. A reservation is written before `prepare/3` even
    %% runs, so killing the guardian at that point leaves the job with no
    %% `cleanup/1' to call and nothing to be slow about.
    [#{id := Id, guardian := G}] = until_delivered(40),
    %% The `DOWN' clears the monitor and a job starts, so the reservation is
    %% still there with nothing left to demonitor.
    exit(G, kill),
    ?assertEqual(running, until_state(running, 100)),
    ok = worker_reaper:finish(Id),
    ?assert(is_map(worker_reaper:stats())),
    ok = script_worker:stop(W).
