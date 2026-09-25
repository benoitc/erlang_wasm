-module(wasm_worker_kernel_SUITE).
-moduledoc """
The kernel, exercised by two adapters built from WAT at test time.

**This suite never skips.** It downloads nothing and needs no network, which is
what lets it be the required gate: a skip here is a failure, since the whole
point is that it cannot be skipped.

Every case body lives in `wasm_adapter_conformance`, not here. That is the
acceptance rule made structural: a new language is accepted when it passes the
applicable cases **without modifying the kernel**, and a suite that wrote its
own cases would let a language quietly become a special case instead.

The two adapters run the identical **base** list. Their capability cases differ
by construction, since `fake_typed_adapter` declares no files and is therefore
never asked to stage one. What must not differ is the base list: the typed
adapter failing there is the signal that the kernel is a WASI runner, and it is
the only signal there is.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(KIT, wasm_adapter_conformance).

%% A wedged case must fail rather than run to Common Test's default, because
%% breaking the deadline or the cancel path on purpose has to be seen quickly.
suite() -> [{timetrap, {seconds, 90}}].

all() ->
    [every_setting_is_documented,
     a_runner_heap_floor_is_resolved_and_reported,
     {group, typed}, {group, command}, {group, script_v1},
     {group, script_v1_channel}, {group, reactor}, {group, reactor_ahead},
     {group, wrappers}].

groups() ->
    [{typed, [], cases(fake_typed_adapter)},
     {command, [], cases(fake_command_adapter)},
     %% The profile runs the same kit as everything else, and then the cases
     %% that are about the profile rather than the kernel. It needs no
     %% interpreter: a WAT guest that reads the marker out of `argv' and frames
     %% its result on stdout exercises `script_v1.combined' completely, so a
     %% failure here is the profile's rather than QuickJS's.
     {script_v1, [], cases(fake_script_v1_adapter) ++ profile_cases()},
     %% The other transport, and the reason both exist: three descriptors
     %% rather than two things sharing one, so the bounds are independent and
     %% no delimiter is involved at all.
     {script_v1_channel, [],
      cases(fake_script_v1_channel_adapter) ++ channel_cases()},
     %% The kernel's snapshot path, in the job that always runs. It otherwise
     %% exists only where a QuickJS or CPython build does, and those are in the
     %% integration job: a capability the required gate cannot exercise is a
     %% capability nobody would notice breaking.
     {reactor, [], cases(fake_reactor_adapter) ++ snapshot_cases()},
     %% The same, with the next instance restored before each request arrives.
     %% Every case the kit has must hold unchanged, which is the claim that a
     %% waiting instance is as fresh as one restored on demand.
     {reactor_ahead, [],
      cases(fake_reactor_adapter) ++ snapshot_cases() ++ ahead_cases()},
     %% `run/3' and `submit/3', through an adapter that records the request
     %% it is handed, since the kernel never looks inside one.
     {wrappers, [], [run_3_hands_the_adapter_source_and_context,
                     submit_3_can_be_awaited_and_cancelled]}].

%% A declared capability makes its cases mandatory; an undeclared one
%% contributes none and is reported rather than passed.
%%
%% `groups/0` runs before `init_per_suite`, and listing an adapter's capability
%% cases means building its artifact. For the WAT adapters that is
%% `wasm:compile/1` and needs nothing; for `fake_reactor_adapter` it is
%% `wasm:load/1`, which needs a started application. Idempotent, and without it
%% `groups/0` raises and Common Test reports **zero suites** rather than an
%% error anyone would read.
cases(Adapter) ->
    {ok, _} = application:ensure_all_started(wasm),
    ?KIT:base_cases() ++ ?KIT:capability_cases(Adapter).

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    ok = wasm_adapter_conformance:take_over_reaper(),
    Config.

end_per_suite(_Config) ->
    wasm_adapter_conformance:hand_back_reaper().

init_per_group(wrappers, Config)  -> [{adapter, fake_recording_adapter} | Config];
init_per_group(typed, Config)     -> [{adapter, fake_typed_adapter} | Config];
init_per_group(command, Config)   -> [{adapter, fake_command_adapter} | Config];
init_per_group(script_v1, Config) -> [{adapter, fake_script_v1_adapter} | Config];
init_per_group(script_v1_channel, Config) ->
    [{adapter, fake_script_v1_channel_adapter} | Config];
init_per_group(reactor, Config) -> [{adapter, fake_reactor_adapter} | Config];
init_per_group(reactor_ahead, Config) ->
    [{adapter, fake_reactor_adapter},
     {worker_opts, #{restore_ahead => true}} | Config].

%% Three things the kernel does only on this path, each of which would
%% otherwise be exercised by nothing in the required gate.
snapshot_cases() ->
    [a_request_starts_from_the_image,
     a_capture_that_does_not_finish_fails_the_start,
     a_validate_that_refuses_fails_the_start,
     a_worker_starts_from_a_filed_image,
     a_worker_ignores_an_image_it_cannot_read,
     a_runner_gets_the_heap_floor_it_was_given,
     an_unset_floor_leaves_the_runner_the_system_default,
     a_floor_with_no_room_under_the_ceiling_still_answers,
     a_capture_floor_does_not_stop_a_worker_starting].

end_per_group(_G, _Config) -> ok.

%% Needs no worker, no reaper and no adapter: it reads names out of the code
%% and looks for them in a guide.
init_per_testcase(every_setting_is_documented, Config) ->
    Config;
init_per_testcase(a_runner_heap_floor_is_resolved_and_reported, Config) ->
    Config;
init_per_testcase(TC, Config) ->
    process_flag(trap_exit, true),
    Root = filename:join([?config(priv_dir, Config), atom_to_list(TC), "root"]),
    ok = filelib:ensure_path(Root),
    {ok, Reaper} = wasm_worker_reaper:start_link(#{scratch => Root}),
    {ok, W} = start(Config, Root, #{}),
    [{reaper, Reaper}, {worker, W}, {root, Root} | Config].

end_per_testcase(every_setting_is_documented, _Config) ->
    ok;
end_per_testcase(a_runner_heap_floor_is_resolved_and_reported, _Config) ->
    ok;
end_per_testcase(_TC, Config) ->
    try wasm_script_worker:stop(?config(worker, Config)) catch _:_ -> ok end,
    try wasm_worker_reaper:stop() catch _:_ -> ok end,
    ok.

start(Config, _Root, Opts) ->
    Group = proplists:get_value(worker_opts, Config, #{}),
    wasm_script_worker:start_link(?config(adapter, Config),
                                  maps:merge(Group#{root => scratch}, Opts)).

%% What every case is handed. The kit reads nothing else, so a suite for a
%% language adapter is this function and the delegations below.
ctx(Config) ->
    Root = ?config(root, Config),
    #{adapter => ?config(adapter, Config),
      worker => ?config(worker, Config),
      root => Root,
      start => fun(Opts) -> start(Config, Root, Opts) end}.

%%% ---------------------------------------------------- restore ahead cases ---

ahead_cases() ->
    [an_instance_is_waiting_before_the_request,
     a_runner_killed_at_the_deadline_is_replaced,
     a_runner_that_dies_between_requests_is_replaced,
     a_request_handed_a_dead_runner_still_runs,
     stopping_the_worker_stops_its_runner].

an_instance_is_waiting_before_the_request(Config) ->
    W = ?config(worker, Config),
    Runner = waiting(W),
    {ok, First} = wasm_script_worker:run(W, #{}),
    %% `handle' bumps a counter `init' left in memory. The same answer twice is
    %% two fresh instances; a rising one is the first request's memory reaching
    %% the second.
    ?assertEqual({ok, First}, wasm_script_worker:run(W, #{})),
    %% And it was the same runner both times: nothing was killed, and the
    %% instance the second request used was restored while the worker waited.
    ?assertEqual(Runner, waiting(W)).

a_runner_killed_at_the_deadline_is_replaced(Config) ->
    {ok, W} = start(Config, ?config(root, Config),
                    #{limits => #{timeout => 300, fuel => infinity}}),
    Runner = waiting(W),
    ?assertMatch({error, #{kind := timeout}},
                 wasm_script_worker:run(W, #{call => ~"spin"})),
    ?assertNot(is_process_alive(Runner)),
    %% The replacement is there before the next request is accepted, and that
    %% request answers as if nothing had happened.
    ?assertMatch({ok, #{values := _}}, wasm_script_worker:run(W, #{})),
    ?assertNotEqual(Runner, waiting(W)),
    ok = wasm_script_worker:stop(W).

a_runner_that_dies_between_requests_is_replaced(Config) ->
    W = ?config(worker, Config),
    Runner = waiting(W),
    Mon = erlang:monitor(process, Runner),
    exit(Runner, kill),
    receive {'DOWN', Mon, process, Runner, _} -> ok end,
    ?assertMatch({ok, #{values := _}}, wasm_script_worker:run(W, #{})),
    ?assertNotEqual(Runner, waiting(W)).

%% The worker learns of a runner's death by message, and a request can arrive
%% first. The guardian then finds a runner that is not there, and the request
%% runs the way it would without `restore_ahead' rather than failing. The dead
%% pid is planted directly because the ordinary race cannot be scheduled.
a_request_handed_a_dead_runner_still_runs(Config) ->
    W = ?config(worker, Config),
    Runner = waiting(W),
    {Dead, DMon} = spawn_monitor(fun() -> ok end),
    receive {'DOWN', DMon, process, Dead, _} -> ok end,
    sys:replace_state(W, fun(S) -> swap(S, Runner, Dead) end),
    ?assertMatch({ok, #{values := _}}, wasm_script_worker:run(W, #{})),
    %% Told, the worker started a runner of its own rather than keep the dead
    %% one. The one it had is still alive and nobody's, which only this case
    %% can arrange, so it goes here.
    New = waiting(W),
    ?assertNotEqual(Dead, New),
    exit(Runner, kill).

stopping_the_worker_stops_its_runner(Config) ->
    {ok, W} = start(Config, ?config(root, Config), #{}),
    Runner = waiting(W),
    Mon = erlang:monitor(process, Runner),
    ok = wasm_script_worker:stop(W),
    receive {'DOWN', Mon, process, Runner, _} -> ok
    after 5_000 -> ct:fail(runner_outlived_its_worker)
    end.

%% The worker's runner, once it has an instance waiting. Between requests the
%% worker monitors exactly one process, and that is it.
waiting(W) -> waiting(W, 200).

waiting(W, 0) -> ct:fail({no_instance_waiting, W});
waiting(W, N) ->
    case process_info(W, monitors) of
        {monitors, [{process, Runner}]} ->
            case process_info(Runner, dictionary) of
                {dictionary, D} ->
                    case lists:keymember(wasm_worker_ahead, 1, D) of
                        true  -> Runner;
                        false -> timer:sleep(10), waiting(W, N - 1)
                    end;
                undefined ->
                    timer:sleep(10), waiting(W, N - 1)
            end;
        _ ->
            timer:sleep(10), waiting(W, N - 1)
    end.

swap(Term, From, To) when Term =:= From -> To;
swap(T, From, To) when is_tuple(T) ->
    list_to_tuple([swap(E, From, To) || E <- tuple_to_list(T)]);
swap(Term, _From, _To) -> Term.

%%% -------------------------------------------------------- wrapper cases ---

run_3_hands_the_adapter_source_and_context(Config) ->
    W = ?config(worker, Config),
    ok = fake_recording_adapter:forget(),
    Source = ~"handle",
    Context = #{~"value" => 41},
    Three = wasm_script_worker:run(W, Source, Context),
    ?assertEqual(#{source => Source, context => Context},
                 fake_recording_adapter:last_request()),
    ?assertMatch({ok, _}, Three),
    ?assertEqual(Three, wasm_script_worker:run(W, #{source => Source,
                                                    context => Context})).

submit_3_can_be_awaited_and_cancelled(Config) ->
    W = ?config(worker, Config),
    ok = fake_recording_adapter:forget(),
    {ok, Ref} = wasm_script_worker:submit(W, ~"handle", #{}),
    ?assert(is_reference(Ref)),
    ?assertMatch({ok, _}, wasm_script_worker:await(W, Ref, 10000)),
    ?assertEqual(#{source => ~"handle", context => #{}},
                 fake_recording_adapter:last_request()),
    {ok, Ref2} = wasm_script_worker:submit(W, ~"spin", #{}),
    ok = wasm_script_worker:cancel(W, Ref2),
    ?assertMatch({error, #{kind := cancelled}},
                 wasm_script_worker:await(W, Ref2, 10000)).

%%% --------------------------------------------------------- profile cases ---
%%
%% These are about `script_v1' and not about the kernel, which is why they live
%% here rather than in the kit: the kit is what a *language* reuses, and a
%% second profile would bring its own list.

profile_cases() ->
    [a_decoy_hex_string_is_not_the_delimiter,
     the_last_marker_wins_and_authenticates_nothing,
     nothing_framed_is_no_result,
     a_non_json_result_is_bad_result,
     profile_codes_are_binaries,
     the_context_reaches_the_guest_as_json,
     the_combined_stream_and_stderr_are_bounded_apart,
     every_profile_code_has_a_fixture,
     an_invented_code_is_a_bad_result].

request(Config, Extra) ->
    maps:merge(?KIT:fixture(?config(adapter, Config), echo), Extra).

run(Config, Extra) ->
    wasm_script_worker:run(?config(worker, Config), request(Config, Extra)).

a_decoy_hex_string_is_not_the_delimiter(Config) ->
    %% Tenant output containing a different 32-hex string. A fixed delimiter
    %% would have collided with ordinary output; sixteen random bytes per
    %% request make that negligible.
    {ok, Result} = run(Config, #{shape => decoy}),
    ?assertMatch(#{~"answer" := 42}, maps:get(result, Result)),
    %% And the tenant keeps every byte it printed, decoy included. What comes
    %% back as `stdout` is the stream up to the delimiter, not the stream since
    %% the last thing that looked like one.
    ?assertEqual(match, re:run(maps:get(stdout, Result), "deadbeef",
                               [{capture, none}])).

the_last_marker_wins_and_authenticates_nothing(Config) ->
    %% One fixture, two meanings, and they are the same observation.
    %%
    %% The guest frames `{"fake":1}` and then `{"answer":42}`, both behind the
    %% real marker. Reading the **last** occurrence is what makes the second
    %% the result: until the guest terminates, any byte could be followed by
    %% more.
    %%
    %% And the tenant can read `argv`, so it can print the marker itself, which
    %% is exactly what this fixture does. The transport cannot tell bootstrap
    %% output from tenant output imitating it, and does not pretend to. A
    %% tenant controls its own result either way, so nothing is lost that was
    %% ever held, but `argv` is not a boundary. Strict framing needs
    %% `script_v1.channel` and its dedicated `worker.result` import.
    ?assertMatch({ok, #{result := #{~"answer" := 42}}},
                 run(Config, #{shape => echo_marker})).

nothing_framed_is_no_result(Config) ->
    {error, E} = run(Config, #{shape => no_result}),
    ?assertEqual(adapter_failure, maps:get(kind, E)),
    ?assertEqual(~"no_result", maps:get(code, maps:get(ctx, E))).

a_non_json_result_is_bad_result(Config) ->
    {error, E} = run(Config, #{shape => bad_result}),
    ?assertEqual(adapter_failure, maps:get(kind, E)),
    ?assertEqual(~"bad_result", maps:get(code, maps:get(ctx, E))).

profile_codes_are_binaries(Config) ->
    %% The kernel's `kind' set stays closed and the profile's vocabulary is
    %% binaries in `ctx', because the atom table is node-wide and never
    %% reclaimed. A profile can add codes for ever without moving that set.
    [?assert(is_binary(C)) || C <- wasm_script_v1:codes()],
    {error, E} = run(Config, #{shape => no_result}),
    ?assert(lists:member(maps:get(code, maps:get(ctx, E)), wasm_script_v1:codes())),
    ?assert(lists:member(maps:get(kind, E), wasm_worker_error:kinds())).

the_context_reaches_the_guest_as_json(Config) ->
    %% Encoded once, staged as a file, and the keys stay binaries all the way
    %% through: `json:decode/1' does not intern them, which is the half of the
    %% atom rule that matters on the way back.
    Ctx = #{~"value" => 41, ~"nested" => #{~"a" => [1, 2, 3]}},
    ?assertEqual(Ctx, json:decode(wasm_script_v1:encode_context(Ctx))),
    ?assertMatch({ok, #{result := _}}, run(Config, #{context => Ctx})).

every_profile_code_has_a_fixture(Config) ->
    %% All four, each produced by a guest rather than asserted about. The two
    %% below the line are what a bootstrap reports when the tenant's code never
    %% ran or ran and raised, which is why the framed value is an envelope: a
    %% bare result cannot say which of those happened.
    Produced = [{~"no_result", no_result}, {~"bad_result", bad_result},
                {~"no_entry_point", no_entry_point}, {~"exception", raised}],
    [begin
         {error, E} = run(Config, #{shape => Shape}),
         ?assertEqual(adapter_failure, maps:get(kind, E)),
         ?assertEqual(Code, maps:get(code, maps:get(ctx, E))),
         %% A binary, every time. The kernel's `kind' set stays closed and the
         %% profile's vocabulary never reaches the atom table.
         ?assert(is_binary(maps:get(code, maps:get(ctx, E))))
     end || {Code, Shape} <- Produced],
    ?assertEqual(lists:sort(wasm_script_v1:codes()),
                 lists:sort([C || {C, _} <- Produced])).

an_invented_code_is_a_bad_result(Config) ->
    {error, E} = run(Config, #{shape => invented_code}),
    %% The code set belongs to the profile, not to the tenant. A host that
    %% switched on an unrecognised one would be switching on tenant input, so
    %% a guest naming a code nobody defined has simply returned a malformed
    %% result.
    ?assertEqual(~"bad_result", maps:get(code, maps:get(ctx, E))).

the_combined_stream_and_stderr_are_bounded_apart(Config) ->
    %% On this transport stdout carries the tenant's output *and* the framed
    %% result, so it is one descriptor carrying two things and the combined
    %% budget belongs to it. `stderr` is a different descriptor and keeps its
    %% own, which is why a single number would have been wrong: bounding the
    %% shared stream tightly would have bounded the unshared one with it.
    Limits = wasm_script_v1:combined_limits(#{max_combined_bytes => 64,
                                         max_output_bytes => 1_000_000}),
    {ok, W} = wasm_script_worker:start_link(?config(adapter, Config),
                                       #{root => scratch, limits => Limits,
                                         timeout => 30_000}),
    {error, E} = wasm_script_worker:run(W, request(Config, #{shape => flood})),
    ?assertEqual(output_limit, maps:get(kind, E)),
    ?assertEqual(stdout, maps:get(stream, maps:get(ctx, E))),
    %% Same worker, same tight combined budget: a guest writing to stderr is
    %% untouched by it and still frames its result.
    ?assertMatch({ok, #{result := #{~"answer" := 42}}},
                 wasm_script_worker:run(W, request(Config, #{shape => noisy_stderr}))),
    ok = wasm_script_worker:stop(W).

%%% ----------------------------------------------- the channel transport ---

channel_cases() ->
    [the_result_does_not_travel_on_stdout,
     stdout_and_result_are_bounded_independently,
     nothing_written_is_no_result,
     a_non_json_channel_result_is_bad_result].

the_result_does_not_travel_on_stdout(Config) ->
    {ok, Result} = run(Config, #{}),
    ?assertMatch(#{~"answer" := 42}, maps:get(result, Result)),
    %% The tenant's own output is exactly what the tenant wrote, with no
    %% delimiter in it and nothing stripped out of it, because the result was
    %% never in this stream.
    ?assertEqual(~"tenant output\n", maps:get(stdout, Result)).

stdout_and_result_are_bounded_independently(Config) ->
    %% Generous for the result, tight for stdout. On the combined transport
    %% these are one descriptor and this configuration cannot be expressed;
    %% here it is the ordinary case.
    {ok, W} = wasm_script_worker:start_link(
                ?config(adapter, Config),
                #{root => scratch, timeout => 30_000,
                  limits => #{max_output_bytes => 128,
                              max_result_bytes => 1_000_000}}),
    %% The output bound kills the runner, so the guardian finishes from the
    %% runner's own `DOWN'. That path used to wait 5 s for a `DOWN' it had
    %% already consumed; the trip must return promptly.
    {Us, {error, Flooded}} =
        timer:tc(fun() ->
                         wasm_script_worker:run(W,
                                                request(Config,
                                                        #{shape => flood_stdout}))
                 end),
    ?assert(Us < 2_000_000, {stalled, Us}),
    ?assertEqual(output_limit, maps:get(kind, Flooded)),
    ?assertEqual(stdout, maps:get(stream, maps:get(ctx, Flooded))),
    ok = wasm_script_worker:stop(W),
    %% And the other way round: a result that runs away is stopped by its own
    %% bound, which the combined transport does not consult at all.
    {ok, W2} = wasm_script_worker:start_link(
                 ?config(adapter, Config),
                 #{root => scratch, timeout => 30_000,
                   limits => #{max_output_bytes => 1_000_000,
                               max_result_bytes => 128, fuel => infinity}}),
    {error, Runaway} = wasm_script_worker:run(W2, request(Config, #{shape => flood_result})),
    ?assertEqual(result_limit, maps:get(kind, Runaway)),
    ok = wasm_script_worker:stop(W2).

nothing_written_is_no_result(Config) ->
    {error, E} = run(Config, #{shape => no_result}),
    ?assertEqual(~"no_result", maps:get(code, maps:get(ctx, E))).

a_non_json_channel_result_is_bad_result(Config) ->
    {error, E} = run(Config, #{shape => bad_result}),
    ?assertEqual(~"bad_result", maps:get(code, maps:get(ctx, E))).


%%% ------------------------------------------------------------ delegation ---

a_caller_that_dies_cancels(Config) -> ?KIT:a_caller_that_dies_cancels(ctx(Config)).
a_corrupt_journal_record_is_quarantined(Config) -> ?KIT:a_corrupt_journal_record_is_quarantined(ctx(Config)).
a_failed_restage_leaves_the_previous_file(Config) -> ?KIT:a_failed_restage_leaves_the_previous_file(ctx(Config)).
a_failed_transfer_aborts_before_the_guest_runs(Config) -> ?KIT:a_failed_transfer_aborts_before_the_guest_runs(ctx(Config)).
a_finite_await_leaves_the_slot_free(Config) -> ?KIT:a_finite_await_leaves_the_slot_free(ctx(Config)).
a_guest_failure_is_a_worker_error(Config) -> ?KIT:a_guest_failure_is_a_worker_error(ctx(Config)).
a_half_written_record_is_ignored(Config) -> ?KIT:a_half_written_record_is_ignored(ctx(Config)).
a_hanging_cleanup_does_not_wedge_the_reaper(Config) -> ?KIT:a_hanging_cleanup_does_not_wedge_the_reaper(ctx(Config)).
a_late_finish_does_not_kill_the_reaper(Config) -> ?KIT:a_late_finish_does_not_kill_the_reaper(ctx(Config)).
a_non_wasi_adapter_never_names_start(Config) -> ?KIT:a_non_wasi_adapter_never_names_start(ctx(Config)).
a_read_only_mount_refuses_a_guest_write(Config) -> ?KIT:a_read_only_mount_refuses_a_guest_write(ctx(Config)).
a_record_naming_an_unknown_root_is_left_alone(Config) -> ?KIT:a_record_naming_an_unknown_root_is_left_alone(ctx(Config)).
a_restage_debits_only_the_delta(Config) -> ?KIT:a_restage_debits_only_the_delta(ctx(Config)).
a_restarted_reaper_adopts_a_live_request(Config) -> ?KIT:a_restarted_reaper_adopts_a_live_request(ctx(Config)).
a_reused_pid_denies_the_handshake(Config) -> ?KIT:a_reused_pid_denies_the_handshake(ctx(Config)).
a_second_await_is_already_awaited(Config) -> ?KIT:a_second_await_is_already_awaited(ctx(Config)).
a_second_submit_is_busy(Config) -> ?KIT:a_second_submit_is_busy(ctx(Config)).
a_silent_guardian_ends_held_holding_capacity(Config) -> ?KIT:a_silent_guardian_ends_held_holding_capacity(ctx(Config)).
a_stale_job_is_refused_by_the_replacement(Config) -> ?KIT:a_stale_job_is_refused_by_the_replacement(ctx(Config)).
a_stream_bound_terminates_the_runner(Config) -> ?KIT:a_stream_bound_terminates_the_runner(ctx(Config)).
a_writable_mount_lets_the_guest_write(Config) -> ?KIT:a_writable_mount_lets_the_guest_write(ctx(Config)).
a_writable_mount_needs_a_trusted_worker(Config) -> ?KIT:a_writable_mount_needs_a_trusted_worker(ctx(Config)).
an_empty_invoke_is_an_adapter_error(Config) -> ?KIT:an_empty_invoke_is_an_adapter_error(ctx(Config)).
an_exit_stops_the_remaining_invocations(Config) -> ?KIT:an_exit_stops_the_remaining_invocations(ctx(Config)).
an_infinite_timeout_is_accepted(Config) -> ?KIT:an_infinite_timeout_is_accepted(ctx(Config)).
an_unacknowledged_outcome_survives(Config) -> ?KIT:an_unacknowledged_outcome_survives(ctx(Config)).
await_after_acknowledgement_is_unknown(Config) -> ?KIT:await_after_acknowledgement_is_unknown(ctx(Config)).
cancel_stops_a_runaway(Config) -> ?KIT:cancel_stops_a_runaway(ctx(Config)).
cleanup_capacity_refuses_admission(Config) -> ?KIT:cleanup_capacity_refuses_admission(ctx(Config)).
cleanup_runs_after_a_trap(Config) -> ?KIT:cleanup_runs_after_a_trap(ctx(Config)).
cleanup_that_cannot_finish_is_quarantined(Config) -> ?KIT:cleanup_that_cannot_finish_is_quarantined(ctx(Config)).
dead_worker_answers_with_a_value(Config) -> ?KIT:dead_worker_answers_with_a_value(ctx(Config)).
declared_snapshots_export_the_callback(Config) -> ?KIT:declared_snapshots_export_the_callback(ctx(Config)).
echo_returns_a_result(Config) -> ?KIT:echo_returns_a_result(ctx(Config)).
errors_have_the_same_structure(Config) -> ?KIT:errors_have_the_same_structure(ctx(Config)).
host_calls_are_bounded(Config) -> ?KIT:host_calls_are_bounded(ctx(Config)).
max_cleanup_actions_refuses_the_next(Config) -> ?KIT:max_cleanup_actions_refuses_the_next(ctx(Config)).
memory_pages_are_bounded(Config) -> ?KIT:memory_pages_are_bounded(ctx(Config)).
no_state_leaks_between_requests(Config) -> ?KIT:no_state_leaks_between_requests(ctx(Config)).
register_performs_what_it_cannot_record(Config) -> ?KIT:register_performs_what_it_cannot_record(ctx(Config)).
repeated_requests_leak_nothing(Config) -> ?KIT:repeated_requests_leak_nothing(ctx(Config)).
stage_refuses_a_traversal_path(Config) -> ?KIT:stage_refuses_a_traversal_path(ctx(Config)).
stage_refuses_an_absolute_path(Config) -> ?KIT:stage_refuses_an_absolute_path(ctx(Config)).
stage_refuses_an_undeclared_mount(Config) -> ?KIT:stage_refuses_an_undeclared_mount(ctx(Config)).
stage_refuses_past_the_byte_bound(Config) -> ?KIT:stage_refuses_past_the_byte_bound(ctx(Config)).
stage_refuses_past_the_file_bound(Config) -> ?KIT:stage_refuses_past_the_file_bound(ctx(Config)).
submit_is_refused_without_a_reaper(Config) -> ?KIT:submit_is_refused_without_a_reaper(ctx(Config)).
the_adapter_decides_the_stop(Config) -> ?KIT:the_adapter_decides_the_stop(ctx(Config)).
the_deadline_stops_a_runaway(Config) -> ?KIT:the_deadline_stops_a_runaway(ctx(Config)).
the_guardian_reacts_to_the_workers_death(Config) -> ?KIT:the_guardian_reacts_to_the_workers_death(ctx(Config)).
the_job_deadline_bounds_the_whole_chain(Config) -> ?KIT:the_job_deadline_bounds_the_whole_chain(ctx(Config)).
the_journal_is_unreachable_from_the_guest(Config) -> ?KIT:the_journal_is_unreachable_from_the_guest(ctx(Config)).
the_journal_survives_the_request(Config) -> ?KIT:the_journal_survives_the_request(ctx(Config)).
the_reaper_finishes_what_a_killed_guardian_left(Config) -> ?KIT:the_reaper_finishes_what_a_killed_guardian_left(ctx(Config)).
the_request_directory_is_removed(Config) -> ?KIT:the_request_directory_is_removed(ctx(Config)).
the_result_channel_has_its_own_bound(Config) -> ?KIT:the_result_channel_has_its_own_bound(ctx(Config)).
transferred_actions_run_only_when_cleanup_fails(Config) -> ?KIT:transferred_actions_run_only_when_cleanup_fails(ctx(Config)).

%%% ----------------------------------------------------- the snapshot path ---

%% `handle` adds a counter it bumps to a number `init` wrote into memory. A
%% restored instance answers the same thing every time; an instance that
%% carried state between requests counts up. This is the isolation claim and
%% the *only* way to see it from outside.
a_request_starts_from_the_image(Config) ->
    W = ?config(worker, Config),
    First = wasm_script_worker:run(W, #{}),
    ?assertMatch({ok, #{values := [_]}}, First),
    ?assertEqual(First, wasm_script_worker:run(W, #{})),
    ?assertEqual(First, wasm_script_worker:run(W, #{})),
    %% And it really is the image talking: `init` wrote 1234 and `handle` adds
    %% its first bump, so anything else means the capture did not happen.
    {ok, #{values := [V]}} = First,
    ?assertEqual(1235, V).

%% `capture_timeout` bounds one `init()`. A limits map cannot do it -- a
%% timeout there is enforced by whoever owns the instance, and an inline call
%% cannot be interrupted -- so this is what says the kernel gave the capture an
%% owner rather than running it in the worker.
a_capture_that_does_not_finish_fails_the_start(Config) ->
    Start = maps:get(start, ctx(Config)),
    T = erlang:monotonic_time(millisecond),
    Got = Start(#{init_call => ~"spin", capture_timeout => 300}),
    Took = erlang:monotonic_time(millisecond) - T,
    ?assertMatch({error, #{class := worker, kind := timeout}}, Got),
    %% Bounded by the setting, not by a test timetrap that would pass whatever
    %% the kernel did.
    ?assert(Took < 5_000).

%% Declaring the capability is a promise. A worker that started anyway would
%% invoke `handle` on an instance that never ran `init`.
a_validate_that_refuses_fails_the_start(Config) ->
    Start = maps:get(start, ctx(Config)),
    ?assertMatch({error, #{class := adapter, kind := adapter_failure}},
                 Start(#{validate => refuse})).

%% **The 90 s fix, in the gate that always runs.** A worker files the image it
%% captured and the next one reads it instead of running `init()` again.
%%
%% With a WAT reactor there is no time to measure and both workers answer the
%% same thing either way, so the assertion that matters is the **capture
%% count**: the adapter bumps it in `validate`, which runs on the capture path
%% and not on the read. Without that this case passes with the lookup deleted,
%% which is how a test that cannot fail arrives.
a_worker_starts_from_a_filed_image(Config) ->
    %% Its own directory per run: two groups run this case, and the second
    %% would otherwise read the image the first one filed.
    Dir = filename:join(?config(priv_dir, Config),
                        "images-" ++ integer_to_list(
                                       erlang:unique_integer([positive]))),
    with_store(Dir, fun() ->
        Start = maps:get(start, ctx(Config)),
        ok = fake_reactor_adapter:reset_captures(),
        {ok, W1} = Start(#{}),
        First = wasm_script_worker:run(W1, #{}),
        ok = wasm_script_worker:stop(W1),
        ?assertEqual(1, fake_reactor_adapter:captures()),
        ?assertMatch([_], filelib:wildcard(filename:join(Dir, "*.img"))),
        {ok, W2} = Start(#{}),
        ?assertEqual(First, wasm_script_worker:run(W2, #{})),
        %% Still one. The second worker read the file.
        ?assertEqual(1, fake_reactor_adapter:captures()),
        ok = wasm_script_worker:stop(W2)
    end).

%% Every reason a file might be unusable has the same answer, and it is to
%% capture. A corrupt one must not fail a start that would otherwise have
%% worked perfectly well.
a_worker_ignores_an_image_it_cannot_read(Config) ->
    Dir = filename:join(?config(priv_dir, Config), "bad-images"),
    with_store(Dir, fun() ->
        Start = maps:get(start, ctx(Config)),
        {ok, W1} = Start(#{}),
        First = wasm_script_worker:run(W1, #{}),
        ok = wasm_script_worker:stop(W1),
        [File] = filelib:wildcard(filename:join(Dir, "*.img")),
        {ok, <<H:40/binary, B, R/binary>>} = file:read_file(File),
        ok = file:write_file(File, <<H/binary, (B bxor 255), R/binary>>),
        Before = fake_reactor_adapter:captures(),
        {ok, W2} = Start(#{}),
        ?assertEqual(First, wasm_script_worker:run(W2, #{})),
        %% It captured, which is what a miss must cost and all it must cost.
        ?assertEqual(Before + 1, fake_reactor_adapter:captures()),
        ok = wasm_script_worker:stop(W2)
    end).

%%% ------------------------------------------------- the runner heap floor ---
%%
%% `runner_min_heap_words' is a floor on the request runner's heap, and the
%% reason it exists is that a restored instance keeps almost nothing on that
%% heap -- the module is a cache handle, the memories are `atomics' pages --
%% so the collector sizes the runner a 233-word heap and collects through the
%% request dozens of times. `test/audit/PERF.md' has the measurements and
%% `docs/tuning.md' is how to find the number for a guest.
%%
%% None of the cases here asserts a time. What they assert is that the number
%% resolves the way the policy says and that it reaches the process that runs
%% the guest, which is a claim a suite can hold at any load average.

%% Pure: no worker, no reaper, no adapter. Two different set values, because
%% one value cannot tell a setting being read from a constant that matches it.
a_runner_heap_floor_is_resolved_and_reported(_Config) ->
    Limits = #{max_heap_words => 8 * 1024 * 1024},
    ?assertEqual({0, ok}, wasm_script_worker:runner_heap_words(#{}, Limits)),
    ?assertEqual({0, ok}, wasm_script_worker:runner_heap_words(
                            #{runner_min_heap_words => 0}, Limits)),
    ?assertEqual({100_000, ok},
                 wasm_script_worker:runner_heap_words(
                   #{runner_min_heap_words => 100_000}, Limits)),
    ?assertEqual({200_000, ok},
                 wasm_script_worker:runner_heap_words(
                   #{runner_min_heap_words => 200_000}, Limits)),
    %% Nothing that is not a heap size becomes one. A floor taken literally
    %% from a float or a negative number is a `badarg' from `spawn_opt', which
    %% is a worker whose every request dies at creation.
    [?assertMatch({0, {bad, Bad}},
                  wasm_script_worker:runner_heap_words(
                    #{runner_min_heap_words => Bad}, Limits))
     || Bad <- [-1, 1.5, unlimited, ~"200000", 1 bsl 59]],
    %% Below the emulator's own minimum is not a floor either.
    {min_heap_size, Min} = erlang:system_info(min_heap_size),
    ?assertMatch({0, {bad, _}},
                 wasm_script_worker:runner_heap_words(
                   #{runner_min_heap_words => Min - 1}, Limits)),
    %% The ceiling is read from the limits and the headroom is real: half the
    %% ceiling fits, more than half does not.
    Small = #{max_heap_words => 400_000},
    ?assertEqual({200_000, ok},
                 wasm_script_worker:runner_heap_words(
                   #{runner_min_heap_words => 200_000}, Small)),
    ?assertEqual({0, {no_room, 400_000}},
                 wasm_script_worker:runner_heap_words(
                   #{runner_min_heap_words => 200_001}, Small)).

%% That the resolved number reaches the process running the guest, which the
%% case above cannot say. The adapter reads its own flags in `decode/2', after
%% the guest has run, so this is the floor holding across the call.
%%
%% A lower bound, not equality: the emulator rounds a requested floor up to a
%% heap-size class, and 200,000 words becomes 318,187.
a_runner_gets_the_heap_floor_it_was_given(Config) ->
    Start = maps:get(start, ctx(Config)),
    {ok, W} = Start(#{runner_min_heap_words => 200_000}),
    {ok, #{runner_heap := Words}} = wasm_script_worker:run(W, #{probe => heap}),
    ?assert(Words >= 200_000),
    ok = wasm_script_worker:stop(W).

%% Off unless set, and "off" means the emulator's default rather than some
%% number of this module's own. Without this, hardcoding any floor passes
%% every other case here.
an_unset_floor_leaves_the_runner_the_system_default(Config) ->
    {min_heap_size, Min} = erlang:system_info(min_heap_size),
    {ok, #{runner_heap := Words}} =
        wasm_script_worker:run(?config(worker, Config), #{probe => heap}),
    ?assertEqual(Min, Words).

%% The case that matters, and the one whose failure does not look like a wrong
%% number: a floor the ceiling has no room for must leave the runner without
%% one, because `min_heap_size' above `max_heap_size' is a kill at spawn and a
%% worker whose every request fails for a reason nothing names.
%%
%% The floor asked for here fits *under* the ceiling and still has no room,
%% which is the whole point of the headroom: the emulator rounds up.
a_floor_with_no_room_under_the_ceiling_still_answers(Config) ->
    Start = maps:get(start, ctx(Config)),
    {min_heap_size, Min} = erlang:system_info(min_heap_size),
    {ok, W} = Start(#{runner_min_heap_words => 300_000,
                      limits => #{max_heap_words => 400_000}}),
    {ok, #{runner_heap := Words}} = wasm_script_worker:run(W, #{probe => heap}),
    ?assertEqual(Min, Words),
    ok = wasm_script_worker:stop(W).

%% The capture floor is the same policy on a different process, so what the
%% cases above prove about resolution carries. What does not carry is that a
%% capture still *works* with one, and a capture failing fails the start, so
%% this asserts a worker that answers.
%%
%% No timing. The effect is 5x on a CPython start and nothing measurable on a
%% WAT reactor that captures in microseconds, and a suite is the wrong place
%% for either.
a_capture_floor_does_not_stop_a_worker_starting(Config) ->
    Limits = #{max_heap_words => 8 * 1024 * 1024},
    ?assertEqual({200_000, ok},
                 wasm_script_worker:capture_heap_words(
                   #{capture_min_heap_words => 200_000}, Limits)),
    ?assertEqual({0, ok}, wasm_script_worker:capture_heap_words(#{}, Limits)),
    %% Resolved from its own key, not the runner's: a worker given only the
    %% runner's floor must capture without one.
    ?assertEqual({0, ok},
                 wasm_script_worker:capture_heap_words(
                   #{runner_min_heap_words => 200_000}, Limits)),
    Start = maps:get(start, ctx(Config)),
    {ok, W} = Start(#{capture_min_heap_words => 200_000}),
    ?assertMatch({ok, _}, wasm_script_worker:run(W, #{})),
    ok = wasm_script_worker:stop(W).

with_store(Dir, F) ->
    ok = filelib:ensure_path(Dir),
    application:set_env(wasm, snapshot_dir, Dir),
    try F()
    after
        application:unset_env(wasm, snapshot_dir)
    end.

%%% ------------------------------------------------------------- settings ---

%% **A default nobody can find is a default nobody can change.** Six of these
%% existed only as a `-define` and a `default/1` clause: not in a guide, not in
%% a moduledoc, invisible to anyone who had not read the source. This is what
%% stops the next one being added the same way.
%%
%% It reads the names out of the code rather than listing them here, so adding
%% a setting and forgetting the guide fails rather than passing.
every_setting_is_documented(_Config) ->
    Guide = read_guide("worker-reference.md"),
    Undocumented = [S || S <- settings(), not documented(S, Guide)],
    ?assertEqual([], Undocumented).

settings() ->
    Worker = maps:keys(wasm_script_worker:default_limits()),
    Worker ++ wasm_worker_reaper:setting_keys() ++
        [trusted, capture_timeout, runner_min_heap_words,
         capture_min_heap_words, restore_ahead,
         root,
         %% Node-wide, and each one turns something substantial on or off.
         max_snapshot_bytes, max_snapshot_dir_bytes, snapshot_dir,
         code_cache_dir, scratch_roots, reaper_options, worker_timeout].

documented(Setting, Guide) ->
    binary:match(Guide, atom_to_binary(Setting, utf8)) =/= nomatch.

%% Walked up from the built application rather than counting `..` segments,
%% because how deep `_build` puts it is rebar's business and not this suite's.
read_guide(Name) ->
    {ok, Bin} = file:read_file(find_guide(code:lib_dir(wasm), Name, 8)),
    Bin.

find_guide(_Dir, Name, 0) ->
    ct:fail({no_guide, Name});
find_guide(Dir, Name, N) ->
    Path = filename:join([Dir, "docs", Name]),
    case filelib:is_regular(Path) of
        true  -> Path;
        false -> find_guide(filename:dirname(Dir), Name, N - 1)
    end.
