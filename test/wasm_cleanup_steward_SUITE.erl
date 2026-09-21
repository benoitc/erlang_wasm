-module(wasm_cleanup_steward_SUITE).
-moduledoc """
The cleanup steward's liveness contract.

The guardian owns the request deadline. Today it also calls the singleton
reaper synchronously for `reserve`, `register`, `withdraw` and `transfer`, so a
reaper that is slow or wedged blocks the guardian in that call and the deadline
it owns cannot fire. That is the defect the steward removes: the guardian
forwards cleanup to a per-request steward and stays in its deadline `receive`,
and the steward is the process that may block on the reaper.

This suite is the north star for that change. `fake_reaper` stands in for the
real reaper and hangs on command, so the wedge is reproduced deterministically
with no sleep as a barrier. On the code before the async forward the deadline
case wedges and fails; once the guardian stops blocking it passes.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% A wedged guardian must fail fast, not run to Common Test's default: the
%% whole point is that a stuck reaper no longer stalls the deadline.
suite() -> [{timetrap, {seconds, 60}}].

all() ->
    [the_seam_parks_a_caller_and_releases_it,
     the_deadline_fires_while_the_reaper_is_stuck_on_register,
     the_reaper_rejects_an_operation_from_a_foreign_caller].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

%% The authentication case drives the real reaper, since it is the reaper's own
%% check under test; the others inject faults with the fake.
init_per_testcase(the_reaper_rejects_an_operation_from_a_foreign_caller, Config) ->
    process_flag(trap_exit, true),
    ok = wasm_worker_sup:suspend_reaper(),
    Dir = filename:join([?config(priv_dir, Config), "auth"]),
    ok = filelib:ensure_path(Dir),
    {ok, _} = wasm_worker_reaper:start_link(#{scratch => Dir}),
    [{dir, Dir} | Config];
init_per_testcase(TC, Config) ->
    process_flag(trap_exit, true),
    %% Free the reaper's registered name so the fake can take it, and keep the
    %% supervisor from starting another underneath us.
    ok = wasm_worker_sup:suspend_reaper(),
    Dir = filename:join([?config(priv_dir, Config), atom_to_list(TC)]),
    ok = filelib:ensure_path(Dir),
    {ok, _} = fake_reaper:start_link(#{dir => Dir, roots => [scratch]}),
    [{dir, Dir} | Config].

end_per_testcase(the_reaper_rejects_an_operation_from_a_foreign_caller, _Config) ->
    quietly(fun() -> wasm_worker_reaper:stop() end),
    quietly(fun() -> wasm_worker_sup:resume_reaper() end),
    ok;
end_per_testcase(_TC, _Config) ->
    %% Let any parked caller go before tearing down, so a wedged guardian from
    %% the pre-fix path unblocks and exits instead of lingering.
    quietly(fun() -> fake_reaper:release(register) end),
    quietly(fun() -> fake_reaper:release(reserve) end),
    case get(worker) of
        undefined -> ok;
        W         -> quietly(fun() -> wasm_script_worker:stop(W) end)
    end,
    quietly(fun() -> fake_reaper:stop() end),
    quietly(fun() -> wasm_worker_sup:resume_reaper() end),
    ok.

quietly(F) -> try F() catch _:_ -> ok end.

%% The harness the later cases lean on, checked on its own terms: a `hang' mode
%% parks the caller in the reaper call (which is the wedge), and `release' lets
%% it return with the value it would have got. `waiting/1' is the deterministic
%% barrier, so nothing here waits on a clock.
the_seam_parks_a_caller_and_releases_it(_Config) ->
    ok = fake_reaper:set_mode(register, ack),
    ?assertMatch({ok, _}, wasm_worker_reaper:register(~"r", fun() -> ok end)),
    ok = fake_reaper:set_mode(register, hang),
    Self = self(),
    _ = spawn_link(fun() ->
                       R = wasm_worker_reaper:register(~"r", fun() -> ok end),
                       Self ! {done, R}
                   end),
    %% Parked in the reaper call: proven by the reaper's own view, not a sleep.
    ok = wait_until(fun() -> fake_reaper:waiting(register) =:= 1 end),
    ?assertEqual(1, fake_reaper:waiting(register)),
    ok = fake_reaper:release(register),
    receive {done, R} -> ?assertMatch({ok, _}, R)
    after 5_000 -> ct:fail(caller_never_returned) end.

%% The guardian starts a request whose `prepare/3' registers a cleanup action.
%% The reaper hangs on that `register', so on the pre-fix path the guardian is
%% blocked in the synchronous call and its 500 ms deadline never fires: the
%% await runs the full five seconds and comes back `still_running'. Once the
%% guardian forwards cleanup instead of blocking, the deadline fires and the
%% await comes back `timeout' in well under a second.
the_deadline_fires_while_the_reaper_is_stuck_on_register(Config) ->
    ok = fake_reaper:set_mode(register, hang),
    Marker = filename:join(?config(dir, Config), "cleanup-marker"),
    %% The deadline lives in the limits map, and it is set well under the await
    %% below, so a fired deadline is unambiguous: a still-running answer means it
    %% never fired, which is the wedge.
    {ok, W} = wasm_script_worker:start_link(
                fake_typed_adapter,
                #{root => scratch, limits => #{timeout => 500}}),
    put(worker, W),
    Request = maps:merge(
                wasm_adapter_conformance:fixture(fake_typed_adapter, echo),
                #{cleanup_marker => Marker}),
    {ok, Ref} = wasm_script_worker:submit(W, Request),
    Outcome = wasm_script_worker:await(W, Ref, 5_000),
    %% Non-vacuity: the register really reached the reaper and parked, so the
    %% guardian really faced the wedge rather than skipping it.
    ?assert(fake_reaper:attempts(register) >= 1),
    ?assertMatch({error, #{kind := timeout}}, Outcome).

%% Only the steward that reserved a request may drive its cleanup. This process
%% makes the reserve call, so it is the steward; an operation from it is
%% accepted, and the same operation from any other process is refused without
%% touching the request.
the_reaper_rejects_an_operation_from_a_foreign_caller(_Config) ->
    Id = ~"authreq0",
    {ok, _Dir} = wasm_worker_reaper:reserve(Id, self(), scratch, ~"req-authreq0"),
    Op = {register, fun() -> ok end},
    ?assertMatch({ok, _},
                 gen_server:call(wasm_worker_reaper, {apply, Id, {Id, 1}, Op})),
    Self = self(),
    _ = spawn(fun() ->
                  R = gen_server:call(wasm_worker_reaper, {apply, Id, {Id, 2}, Op}),
                  Self ! {foreign, R}
              end),
    receive
        {foreign, Foreign} ->
            ?assertMatch({error, #{kind := unauthorised}}, Foreign)
    after 5_000 -> ct:fail(no_foreign_reply) end.

%%% ---------------------------------------------------------------- helpers ---

%% Wait for a condition to hold, polling rather than sleeping a fixed time: it
%% returns the instant the state is reached, and fails loudly if it never is.
wait_until(Pred) -> wait_until(Pred, 100).

wait_until(_Pred, 0)  -> ct:fail(condition_never_held);
wait_until(Pred, N) ->
    case Pred() of
        true  -> ok;
        false -> timer:sleep(20), wait_until(Pred, N - 1)
    end.
