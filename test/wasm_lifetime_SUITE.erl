-module(wasm_lifetime_SUITE).
-moduledoc """
Nothing outlives the process responsible for stopping it.

Each case starts a child through the real code path, has the child report its
pid, kills the owner, and asserts the child is gone. Every case failed before
its fix: the child was left running with nothing able to see it.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([a_bound_child_dies_with_its_owner/1,
         the_watcher_ends_with_the_child/1,
         an_async_producer_dies_with_its_task_owner/1,
         a_steward_callback_dies_with_the_steward/1,
         a_callback_run_for_a_missing_reaper_dies_with_its_caller/1,
         an_image_capture_dies_with_the_process_that_started_it/1,
         an_artifact_load_dies_with_the_process_that_started_it/1,
         a_nested_task_leaves_the_outer_tasks_producers_in_its_care/1]).

all() ->
    [a_bound_child_dies_with_its_owner,
     the_watcher_ends_with_the_child,
     an_async_producer_dies_with_its_task_owner,
     a_steward_callback_dies_with_the_steward,
     a_callback_run_for_a_missing_reaper_dies_with_its_caller,
     an_image_capture_dies_with_the_process_that_started_it,
     an_artifact_load_dies_with_the_process_that_started_it,
     a_nested_task_leaves_the_outer_tasks_producers_in_its_care].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_) -> ok.

%%% --------------------------------------------------------------- cases ---

a_bound_child_dies_with_its_owner(_) ->
    Test = self(),
    Owner = spawn(fun() ->
                          Me = self(),
                          _ = spawn(fun() ->
                                            ok = wasm_lifetime:bind(Me),
                                            Test ! {child, self()},
                                            hang()
                                    end),
                          hang()
                  end),
    Child = receive {child, C} -> C after 5000 -> ct:fail(no_child) end,
    exit(Owner, kill),
    gone(Child).

%% The watcher is not left behind when the child finishes first.
the_watcher_ends_with_the_child(_) ->
    Before = length(processes()),
    Owner = self(),
    Ref = make_ref(),
    _ = [spawn(fun() -> ok = wasm_lifetime:bind(Owner), Owner ! Ref end)
         || _ <- lists:seq(1, 100)],
    [receive Ref -> ok after 5000 -> ct:fail(child_did_not_run) end
     || _ <- lists:seq(1, 100)],
    eventually(fun() -> length(processes()) =< Before + 5 end).

%% `wasm_async:end_task/0' stops producers, but a killed owner never runs it.
an_async_producer_dies_with_its_task_owner(_) ->
    Test = self(),
    Owner = spawn(fun() ->
                          ok = wasm_async:begin_task(undefined, #{}),
                          ok = wasm_async:register_producer(
                                 1, report_and_hang(Test)),
                          hang()
                  end),
    Child = receive {child, C} -> C after 5000 -> ct:fail(no_producer) end,
    exit(Owner, kill),
    gone(Child).

%% A steward runs a callback in a child and enforces its deadline itself; the
%% deadline went with a killed steward.
a_steward_callback_dies_with_the_steward(_) ->
    process_flag(trap_exit, true),
    Test = self(),
    Action = fun() -> Test ! {child, self()}, hang() end,
    {ok, Steward} = wasm_cleanup_steward:start_link(
                      {bounded_action, Action, self(), tag}),
    Child = receive {child, C} -> C after 5000 -> ct:fail(no_callback) end,
    exit(Steward, kill),
    receive {'EXIT', Steward, _} -> ok after 5000 -> ok end,
    gone(Child).

%% With no reaper to record it, a cleanup action runs in a bounded child of
%% the caller; the bound went with a killed caller.
a_callback_run_for_a_missing_reaper_dies_with_its_caller(_) ->
    Test = self(),
    Caller = spawn(fun() ->
                           wasm_worker_reaper:unreachable_operation(
                             {register, fun() -> report(Test), hang() end})
                   end),
    Child = receive {child, C} -> C after 5000 -> ct:fail(no_callback) end,
    exit(Caller, kill),
    gone(Child).

%% A guest `init()' that never returns, captured with a deadline the caller
%% holds: the capture went on running after the caller was killed.
an_image_capture_dies_with_the_process_that_started_it(_) ->
    Before = processes(),
    Caller = spawn(fun() ->
                           wasm_script_worker:prepare(
                             fake_reactor_adapter,
                             #{init_call => ~"spin",
                               capture_timeout => 600_000})
                   end),
    %% The capture is the new process running the guest's `init()'.
    Captures = fun() -> [P || P <- processes() -- Before, guest(P)] end,
    eventually(fun() -> Captures() =/= [] end),
    [Capture] = Captures(),
    exit(Caller, kill),
    gone(Capture).

%% Loading an adapter's artifact runs in a child of the caller.
an_artifact_load_dies_with_the_process_that_started_it(_) ->
    Test = self(),
    Caller = spawn(fun() ->
                           wasm_script_worker:prepare(fake_reactor_adapter,
                                                      #{artifact_hang => Test})
                   end),
    Load = receive {artifact_hang, P} -> P after 5000 -> ct:fail(no_load) end,
    exit(Caller, kill),
    gone(Load).

%% A task started inside another (an async call made from a host function the
%% outer task called) cleared the outer task's frame, so the outer task's
%% producers were never stopped.
a_nested_task_leaves_the_outer_tasks_producers_in_its_care(_) ->
    Test = self(),
    Owner = spawn(fun() ->
                          ok = wasm_async:begin_task(undefined, #{}),
                          ok = wasm_async:register_producer(
                                 1, report_and_hang(Test)),
                          %% Until the test has the producer's pid: the outer
                          %% `end_task/0' may otherwise stop it before it says
                          %% who it is.
                          receive go -> ok end,
                          ok = wasm_async:begin_task(undefined, #{}),
                          ok = wasm_async:end_task(),
                          ok = wasm_async:end_task(),
                          Test ! ended,
                          hang()
                  end),
    Child = receive {child, C} -> C after 5000 -> ct:fail(no_producer) end,
    Owner ! go,
    receive ended -> ok after 5000 -> ct:fail(no_end) end,
    gone(Child),
    exit(Owner, kill).

guest(P) ->
    case erlang:process_info(P, current_function) of
        {current_function, {wasm_exec, _, _}} -> true;
        _ -> false
    end.

%%% ------------------------------------------------------------- helpers ---

hang() -> receive after infinity -> ok end.

report(Test) -> Test ! {child, self()}.

report_and_hang(Test) -> fun(_) -> report(Test), hang() end.

gone(Pid) ->
    eventually(fun() -> not is_process_alive(Pid) end).

eventually(Pred) -> eventually(Pred, 100).

eventually(Pred, 0) -> ?assert(Pred());
eventually(Pred, N) ->
    case Pred() of
        true -> ok;
        false -> timer:sleep(20), eventually(Pred, N - 1)
    end.
