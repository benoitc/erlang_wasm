-module(reaper_trace_SUITE).
%% Temporary: not committed. Runs the reaper adoption case with call tracing
%% on everything that can remove a request directory or replay a request.
-compile([export_all, nowarn_export_all, nowarn_deprecated_catch]).
-include_lib("common_test/include/ct.hrl").

all() -> [{group, command}].
groups() -> [{command, [{repeat_until_any_fail, 300}], [traced]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    ok = wasm_adapter_conformance:take_over_reaper(),
    Config.
end_per_suite(_) -> wasm_adapter_conformance:hand_back_reaper().
init_per_group(_, Config) -> [{adapter, fake_command_adapter} | Config].
end_per_group(_, _) -> ok.

init_per_testcase(TC, Config) ->
    process_flag(trap_exit, true),
    Root = filename:join([?config(priv_dir, Config), atom_to_list(TC),
                          integer_to_list(erlang:unique_integer([positive])), "root"]),
    ok = filelib:ensure_path(Root),
    {ok, Reaper} = wasm_worker_reaper:start_link(#{scratch => Root}),
    {ok, W} = wasm_script_worker:start_link(fake_command_adapter, #{root => scratch}),
    [{reaper, Reaper}, {worker, W}, {root, Root} | Config].
end_per_testcase(_, Config) ->
    try wasm_script_worker:stop(?config(worker, Config)) catch _:_ -> ok end,
    try wasm_worker_reaper:stop() catch _:_ -> ok end,
    ok.

ctx(Config) ->
    #{adapter => ?config(adapter, Config), root => ?config(root, Config),
      start => fun(Opts) -> wasm_script_worker:start_link(?config(adapter, Config),
                                                           maps:merge(#{root => scratch}, Opts)) end}.

traced(Config) ->
    Self = self(),
    Tracer = spawn(fun() -> collect(Self, []) end),
    erlang:trace(all, true, [call, timestamp, {tracer, Tracer}]),
    Local = [{wasm_worker_reaper, F, '_'} || F <- [schedule, sweep_unrecorded, handshake_reply,
                                                  guardian_down, steward_down, remove_dirs,
                                                  apply_op, adopt_or_orphan, retry_handshake,
                                                  cleanup_done, init]]
         ++ [{wasm_worker_fs, del_dir_r, '_'}, {file, del_dir_r, '_'}, {prim_file, del_dir, '_'},
             {wasm_script_worker, finish, 3}, {wasm_script_worker, runner_died, 2},
             {wasm_worker_reaper, stop, 0}, {wasm_worker_reaper, start_link, 1},
             {wasm_worker_reaper, op_finish, 2},
             {wasm_cleanup_steward, handle_cast, 2}, {wasm_cleanup_steward, handle_info, 2},
             {wasm_cleanup_steward, submit_finish, 2}],
    [erlang:trace_pattern(MFA, [{'_', [], [{message, {caller}}]}], [local]) || MFA <- Local],
    R = (catch wasm_adapter_conformance:a_restarted_reaper_adopts_a_live_request(kit_ctx(Config))),
    erlang:trace(all, false, [call]),
    Tracer ! {done, self()},
    Events = receive {events, E} -> E end,
    case R of
        ok -> ok;
        _ ->
            %% On a failure, everything to stdout, so CI's log has it.
            io:format(user, "~n=== reaper trace: ~p~n", [R]),
            [io:format(user, "~p ~p ~P~n", [T, Who, Call, 40]) || {T, Who, Call} <- Events],
            io:format(user, "requests now ~p~nroot ~p~njournal ~p~n",
                      [wasm_worker_reaper:requests(),
                       file:list_dir(?config(root, Config)),
                       file:list_dir(filename:join(?config(root, Config), ".journal"))]),
            ct:fail({R, length(Events)})
    end.

kit_ctx(Config) -> wasm_worker_kernel_SUITE:ctx(Config).

collect(Owner, Acc) ->
    receive
        {trace_ts, Pid, call, MFA, Caller, TS} -> collect(Owner, [{TS, Pid, {MFA, Caller}} | Acc]);
        {done, From} -> From ! {events, lists:reverse(Acc)};
        _ -> collect(Owner, Acc)
    end.
