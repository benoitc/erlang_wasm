-module(wasm_worker_lang_SUITE).
-moduledoc """
The conformance kit against a real language, in both configurations.

The kit is the same one `wasm_worker_kernel_SUITE` runs. That is the point: a
language is accepted when it passes without the kernel changing, so the case
list must be the identical one and not a copy with allowances in it.

**This suite needs a fetched artifact and skips without one.** That is safe
because CI verifies the fixtures against their checksums in a step of its own
before this runs, so a missing or mismatched artifact fails the job rather
than quietly reducing what ran.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(KIT, wasm_adapter_conformance).

%% Generous, because this suite runs against real interpreters: a CPython
%% request is measured at 48 s and several cases make three of them. The two
%% tier cases override it again, for a different reason.
suite() -> [{timetrap, {minutes, 10}}].

%% CPython is **not** in `all/0`, and that is a measurement rather than a
%% preference: a request costs 48 s here, so the same case list takes about
%% fifty minutes per configuration. Run it deliberately:
%%
%%     rebar3 ct --suite=test/wasm_worker_lang_SUITE --group=python_metered
%%
%% `python_compiled` is not run at all. The tier needs several hundred requests
%% *plus* a compile measured at 567 s, which is hours, and Phase 5 is where
%% that measurement belongs.
all() -> [{group, qjs_metered}, {group, qjs_compiled}, {group, qjs_reactor},
          {group, lua_reactor}, {group, qjs_reactor_ahead},
          {group, lua_reactor_ahead}].

groups() ->
    [{qjs_metered, [], cases() ++ [asking_for_both_silently_gets_the_interpreter]},
     {qjs_compiled, [], cases() ++ [the_tier_enters_a_compiled_worker]},
     %% The same kit over an image of an already-started engine. Its `echo` and
     %% `state_change` cases are what say a restore is a *fresh* instance: one
     %% tenant's globals do not reach the next, which is the claim a persistent
     %% interpreter could not make.
     {qjs_reactor, [], reactor_cases() ++ [a_restored_worker_answers_faster]},
     {python_metered, [], python_cases()},
     {python_compiled, [], python_cases()},
     %% Not in `all/0` for the same reason the Python groups are not: it starts
     %% with a 90 s capture. Run it deliberately, with
     %% `--group=python_reactor`.
     {python_reactor, [], python_reactor_cases() ++ [time_monotonic_is_usable]},
     %% The third language, and the one the mechanism was **not** designed
     %% around: it was written after the kernel, the profile and snapshots, and
     %% none of them changed to admit it. It starts in milliseconds, so unlike
     %% the Python groups it belongs in `all/0`.
     {lua_reactor, [], lua_cases()},
     %% Each reactor again with `restore_ahead': the whole kit, unchanged, and
     %% then what only a waiting instance could get wrong. CPython's is not in
     %% `all/0` for the reason its other groups are not.
     {qjs_reactor_ahead, [], reactor_cases() ++ ahead_cases()},
     {lua_reactor_ahead, [], lua_cases() ++ ahead_cases()},
     {python_reactor_ahead, [], python_reactor_cases() ++ ahead_cases()}].

%% `groups/0' runs before `init_per_suite', and listing an adapter's capability
%% cases means building its artifact, which for a real engine means loading a
%% module and therefore a started application. Idempotent, and the alternative
%% was a kit that returns an empty list when it cannot tell.
cases() ->
    {ok, _} = application:ensure_all_started(wasm),
    ?KIT:base_cases() ++ ?KIT:capability_cases(wasm_javascript_command, artifact_opts()).

reactor_cases() ->
    {ok, _} = application:ensure_all_started(wasm),
    ?KIT:base_cases() ++ ?KIT:capability_cases(wasm_javascript,
                                               reactor_opts()).

python_cases() ->
    {ok, _} = application:ensure_all_started(wasm),
    ?KIT:base_cases() ++ ?KIT:capability_cases(wasm_python_command, python_opts()).

lua_cases() ->
    {ok, _} = application:ensure_all_started(wasm),
    ?KIT:base_cases() ++ ?KIT:capability_cases(wasm_lua, lua_opts()).

python_reactor_cases() ->
    {ok, _} = application:ensure_all_started(wasm),
    ?KIT:base_cases() ++ ?KIT:capability_cases(wasm_python,
                                               python_reactor_opts()).

artifact_opts() -> #{path => engine()}.

reactor_opts() -> #{path => reactor()}.

lua_opts() -> #{path => lua()}.

lua() ->
    filename:join([wasm_spec_runner:fixtures_dir(), "lang", "lua_reactor.wasm"]).

python_reactor_opts() ->
    #{path => python_reactor(), lib => python_reactor_lib()}.

python_reactor() ->
    filename:join([wasm_spec_runner:fixtures_dir(), "lang", "py_reactor.wasm"]).

python_reactor_lib() ->
    filename:join([wasm_spec_runner:fixtures_dir(), "lang", "py_reactor_lib"]).

reactor() ->
    filename:join([wasm_spec_runner:fixtures_dir(), "lang", "qjs_reactor.wasm"]).

python_opts() -> #{path => python()}.

python() ->
    filename:join([wasm_spec_runner:fixtures_dir(), "lang", "python.wasm"]).

init_per_suite(Config) ->
    case filelib:is_file(engine()) of
        false ->
            {skip, "no QuickJS build: run scripts/fetch-qjs-fixture.sh"};
        true ->
            {ok, _} = application:ensure_all_started(wasm),
            ok = wasm_adapter_conformance:take_over_reaper(),
            Config
    end.

end_per_suite(_Config) ->
    wasm_adapter_conformance:hand_back_reaper().

engine() ->
    filename:join([wasm_spec_runner:fixtures_dir(), "lang", "qjs.wasm"]).

%% `wasm_limits:untrusted/0' sets `fuel => 10_000_000' and `wasm_jit:entry/3'
%% enables generated code only when fuel is `infinity', so the untrusted preset
%% and the compiled tier are **mutually exclusive**. A host that set both would
%% silently get the interpreter, which is why they are two named
%% configurations rather than a set of knobs.
init_per_group(qjs_metered, Config) ->
    [{adapter, wasm_javascript_command}, {config, metered}, {limits, metered()} | Config];
init_per_group(qjs_compiled, Config) ->
    [{adapter, wasm_javascript_command}, {config, compiled}, {limits, compiled()} | Config];
init_per_group(qjs_reactor, Config) ->
    skip_without(reactor(), "no QuickJS reactor: run "
                            "scripts/build-quickjs-reactor.sh",
                 [{adapter, wasm_javascript}, {config, reactor},
                  {engine, reactor()}, {opts, reactor_opts()},
                  {limits, reactor_limits()} | Config]);
init_per_group(lua_reactor, Config) ->
    skip_without(lua(), "no Lua reactor: run scripts/build-lua-reactor.sh",
                 [{adapter, wasm_lua}, {config, reactor},
                  {engine, lua()}, {opts, lua_opts()},
                  {limits, wasm_lua:limits()} | Config]);
init_per_group(python_reactor, Config) ->
    skip_without(python_reactor(), "no CPython reactor: run "
                                   "scripts/build-python-reactor.sh",
                 [{adapter, wasm_python}, {config, reactor},
                  {engine, python_reactor()}, {opts, python_reactor_opts()},
                  %% One interpreter start is 83 to 90 s, so the 60 s default
                  %% would kill every capture. Raised knowingly, like every
                  %% other CPython ceiling.
                  {worker_opts, #{capture_timeout => 180_000}},
                  {limits, python_reactor_limits()} | Config]);
init_per_group(qjs_reactor_ahead, Config) ->
    ahead(init_per_group(qjs_reactor, Config));
init_per_group(lua_reactor_ahead, Config) ->
    ahead(init_per_group(lua_reactor, Config));
init_per_group(python_reactor_ahead, Config) ->
    ahead(init_per_group(python_reactor, Config));
init_per_group(python_metered, Config) ->
    skip_without(python(), [{adapter, wasm_python_command}, {config, metered},
                            {engine, python()}, {opts, python_opts()},
                            {limits, python_metered()} | Config]);
init_per_group(python_compiled, Config) ->
    skip_without(python(), [{adapter, wasm_python_command}, {config, compiled},
                            {engine, python()}, {opts, python_opts()},
                            {limits, python_compiled()} | Config]).

ahead({skip, _} = Skip) ->
    Skip;
ahead(Config) ->
    Opts = proplists:get_value(worker_opts, Config, #{}),
    [{worker_opts, Opts#{restore_ahead => true}}
     | proplists:delete(worker_opts, Config)].

skip_without(Path, Config) ->
    skip_without(Path, "no CPython build: run scripts/fetch-python-fixture.sh",
                 Config).

skip_without(Path, Why, Config) ->
    case filelib:is_file(Path) of
        true  -> Config;
        false -> {skip, Why}
    end.

%% `fuel => infinity` because the engine is a whole JavaScript runtime and the
%% untrusted preset does not reach its first line, exactly as it does not for
%% the command artifact. The deadline is what bounds a runaway here.
%% The adapter's own ceilings, with the deadline cut to what this guest
%% actually needs: a restore is 0.6 s and a request 0.3 s, so 30 s is generous
%% and it is what bounds the runaway cases instead of two minutes each.
python_reactor_limits() ->
    (wasm_python:limits())#{timeout => 30_000}.

reactor_limits() ->
    #{timeout => 30_000, fuel => infinity, max_memory_pages => 4096,
      max_host_calls => 1_000_000, max_heap_words => 16 * 1024 * 1024}.

%% Every one of these was measured, and none of them is a round number chosen
%% for looking safe. `PYTHON.md` says what each was measured at.
%%
%% `max_heap_words` especially: 16M ran a request in 48 s and 64M took 85 s,
%% because a larger bound lets the heap grow and the collections cost more. A
%% ceiling is not a target.
python_metered() ->
    #{timeout => 300_000, max_memory_pages => 4096, max_host_calls => 1_000_000,
      max_heap_words => 16 * 1024 * 1024,
      %% A thousand times the untrusted preset, and measured: the preset's
      %% 10,000,000 does not get CPython to its first line, and 1e9 completes a
      %% request with room to spare. A host running an interpreter raises this
      %% knowingly, which is the whole reason an adapter never raises it.
      fuel => 4_000_000_000}.

python_compiled() ->
    maps:merge(python_metered(),
               #{fuel => infinity, compile => true, profile => script}).

end_per_group(_G, _Config) -> ok.

%% `untrusted/0' as it stands, except for the two ceilings a host running an
%% interpreter has to raise knowingly: a quarter-second of engine startup does
%% not fit a 1 second timeout, and 16 MiB does not hold QuickJS.
metered() ->
    #{timeout => 30_000, max_memory_pages => 2048, max_host_calls => 100_000}.

%% No fuel, so termination is entirely the guardian's wall-clock deadline.
%% `docs/worker.md' carries that as a security statement rather than a tuning
%% note: under `compiled' the only thing between the node and a runaway is a
%% kill from outside the guest.
compiled() ->
    #{timeout => 30_000, max_memory_pages => 2048, max_host_calls => 100_000,
      fuel => infinity, compile => true, profile => script}.

init_per_testcase(TC, Config) ->
    process_flag(trap_exit, true),
    Root = filename:join([?config(priv_dir, Config), atom_to_list(TC), "root"]),
    ok = filelib:ensure_path(Root),
    {ok, Reaper} = wasm_worker_reaper:start_link(#{scratch => Root}),
    {ok, W} = start(Config, #{}),
    [{reaper, Reaper}, {worker, W}, {root, Root} | Config].

end_per_testcase(_TC, Config) ->
    try wasm_script_worker:stop(?config(worker, Config)) catch _:_ -> ok end,
    try wasm_worker_reaper:stop() catch _:_ -> ok end,
    ok.

start(Config, Opts) ->
    %% Whatever else the adapter's own options carry -- the Python reactor
    %% needs a `lib` beside its module, and nothing else does.
    Extra = maps:merge(maps:without([path],
                                    proplists:get_value(opts, Config, #{})),
                       proplists:get_value(worker_opts, Config, #{})),
    Base = Extra#{root => scratch,
                  path => proplists:get_value(engine, Config, engine()),
                  limits => ?config(limits, Config)},
    Merged = maps:merge(Base, Opts),
    %% A case that asks for its own limits is asking for an override, not a
    %% replacement: the engine still needs room to start.
    wasm_script_worker:start_link(
      ?config(adapter, Config),
      Merged#{limits => maps:merge(?config(limits, Config),
                                   maps:get(limits, Opts, #{}))}).

ctx(Config) ->
    Root = ?config(root, Config),
    #{adapter => ?config(adapter, Config),
      worker => ?config(worker, Config),
      root => Root,
      artifact_opts => proplists:get_value(opts, Config, artifact_opts()),
      start => fun(Opts) -> start(Config, Opts) end}.

%%% ---------------------------------------------------------- restore ahead ---

ahead_cases() ->
    [each_request_reads_its_own_files,
     guest_memory_does_not_reach_the_waiting_instance].

%% The waiting instance was restored before this request's directory existed,
%% so the files it reads can only be this request's if its imports were bound
%% when the request started. A preopen fixed at restore would read the
%% capture's empty directory, or the previous request's, which is removed.
each_request_reads_its_own_files(Config) ->
    W = ?config(worker, Config),
    Echo = ?KIT:fixture(?config(adapter, Config), echo,
                        proplists:get_value(opts, Config, #{})),
    [?assertMatch({ok, #{result := #{~"answer" := Want}}},
                  wasm_script_worker:run(W, Echo#{context => #{~"value" => V}}))
     || {V, Want} <- [{1, 2}, {41, 42}, {99, 100}]].

%% A marker the guest keeps in a global, looked for in the instance restored
%% for the next request. The same guest string, read from the same memory,
%% would be found if the next request were handed the instance this one used.
guest_memory_does_not_reach_the_waiting_instance(Config) ->
    W = ?config(worker, Config),
    Tag = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
    Marker = <<"MARK-", Tag/binary>>,
    {ok, _} = wasm_script_worker:run(
                W, #{source => marker_source(?config(adapter, Config)),
                     context => #{~"tag" => Tag}}),
    Mem = waiting_memory(W),
    %% The read is real: a string every image of this engine holds is there.
    ?assertNotEqual(nomatch, binary:match(Mem, image_string(?config(adapter, Config)))),
    ?assertEqual(nomatch, binary:match(Mem, Marker)).

marker_source(wasm_javascript) ->
    ~"export function main(c) { globalThis.keep = 'MARK-' + c.tag; return {}; }";
marker_source(wasm_lua) ->
    ~"function main(c) keep = 'MARK-' .. c.tag return {} end";
marker_source(wasm_python) ->
    ~"def main(c):\n    global keep\n    keep = 'MARK-' + c['tag']\n    return {}\n".

image_string(wasm_javascript) -> ~"Array";
image_string(wasm_lua) -> ~"tostring";
image_string(wasm_python) -> ~"__name__".

%% The memory of the instance the worker's runner restored for the next
%% request, once it has one. Between requests the worker monitors exactly one
%% process, its runner.
waiting_memory(W) -> waiting_memory(W, 500).

waiting_memory(W, 0) -> ct:fail({no_instance_waiting, W});
waiting_memory(W, N) ->
    Waiting = case process_info(W, monitors) of
                  {monitors, [{process, R}]} ->
                      case process_info(R, dictionary) of
                          {dictionary, D} ->
                              proplists:get_value(wasm_worker_ahead, D);
                          undefined ->
                              undefined
                      end;
                  _ ->
                      undefined
              end,
    case Waiting of
        {Inst, _Keys, _Opts} ->
            {ok, Pages} = wasm:memory_size(Inst),
            {ok, Mem} = wasm:read_memory(Inst, 0, Pages * 65536),
            Mem;
        undefined ->
            timer:sleep(20),
            waiting_memory(W, N - 1)
    end.

%%% --------------------------------------------------- the two configurations ---

asking_for_both_silently_gets_the_interpreter(Config) ->
    %% The trap the two named configurations exist to prevent. `wasm_jit:entry/3`
    %% enables generated code only when fuel is `infinity`, so a host that sets
    %% `compile => true` *and* keeps a fuel ceiling gets neither an error nor a
    %% tier: it gets the interpreter, quietly, and a slow worker it cannot
    %% explain.
    %%
    %% Over the same span the compiled configuration needs, because the tier
    %% takes 353 requests to be entered here and a shorter run is silent
    %% whether the tier is off or merely slow.
    ct:timetrap({minutes, 6}),
    Before = entered(),
    {ok, W} = start(Config, #{limits => #{compile => true, profile => script}}),
    [_ = wasm_script_worker:run(W, echo(Config)) || _ <- lists:seq(1, 500)],
    ?assertEqual(Before, entered()),
    ok = wasm_script_worker:stop(W).

the_tier_enters_a_compiled_worker(Config) ->
    %% Minutes, and measured rather than guessed: on this box the tier was
    %% entered at **request 353, 76.2 s, 326 functions compiled**. Compiling
    %% 1.8 MB of QuickJS is not instant and the plan expects it at request
    %% 420-432, so a case that gave up sooner would be asserting the clock.
    ct:timetrap({minutes, 6}),
    W = ?config(worker, Config),
    %% **Requests, not sleep.** The first version of this slept, which never
    %% works: `wasm_jit:after_call/2' asks at the end of an outermost
    %% invocation, so the tier advances when calls happen and not when time
    %% passes. `profile => script' sets `compile_after => 1' because a script
    %% is often a single call and the default threshold of 32 is never reached.
    ?assert(until_entered(W, echo(Config), 800)).

entered() -> maps:get(entered, wasm_jit:counts(), 0).

until_entered(_W, _R, 0) -> false;
until_entered(W, R, N) ->
    _ = wasm_script_worker:run(W, R),
    case entered() > 0 of
        true  -> true;
        false -> until_entered(W, R, N - 1)
    end.

echo(Config) ->
    ?KIT:fixture(?config(adapter, Config), echo,
                 proplists:get_value(opts, Config, artifact_opts())).


%%% ------------------------------------------------------------- the clock ---

%% `time.monotonic()' raised `OverflowError: timestamp out of range for C
%% PyTime_t': the WASI monotonic clock handed the guest BEAM's raw monotonic
%% time, negative and wrapped to ~1.8e19 as a u64, and asyncio, timeouts and
%% `perf_counter' went with it. wasi_SUITE checks the import; this checks
%% that the interpreter can use it.
time_monotonic_is_usable(Config) ->
    W = ?config(worker, Config),
    Src = <<"def main(c):\n"
            "    import time\n"
            "    a = time.monotonic()\n"
            "    b = time.monotonic()\n"
            "    return {'a': a, 'b': b}\n">>,
    {ok, #{result := #{<<"a">> := A, <<"b">> := B}}} =
        wasm_script_worker:run(W, #{source => Src, context => #{}}),
    ?assert(is_number(A)),
    ?assert(A >= 0),
    ?assert(B >= A),
    %% Seconds since the node started; three decades of uptime would be news.
    ?assert(A < 1.0e9).

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

%% The claim Phase 6 was gated on, as a case rather than only as a number in
%% `PERF.md`: a restored request is faster than one that starts the engine
%% itself. The threshold is deliberately loose -- the measured gap is 6.1x and
%% this asserts 2x -- because a case that encodes a measurement becomes a case
%% that fails when the box is busy.
a_restored_worker_answers_faster(Config) ->
    Request = ?KIT:fixture(wasm_javascript, echo, reactor_opts()),
    Reactor = best_of(wasm_javascript, reactor_opts(), Request),
    Command = best_of(wasm_javascript_command, artifact_opts(),
                      ?KIT:fixture(wasm_javascript_command, echo, artifact_opts())),
    ct:pal("reactor ~p ms, command ~p ms", [Reactor, Command]),
    ?assert(Reactor * 2 < Command),
    Config.

best_of(Adapter, Opts, Request) ->
    {ok, W} = wasm_script_worker:start_link(
                Adapter, Opts#{root => scratch, limits => reactor_limits()}),
    Ts = [begin
              T = erlang:monotonic_time(millisecond),
              {ok, _} = wasm_script_worker:run(W, Request),
              erlang:monotonic_time(millisecond) - T
          end || _ <- lists:seq(1, 5)],
    ok = wasm_script_worker:stop(W),
    lists:min(Ts).
