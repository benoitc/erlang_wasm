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
     the_result_is_published_before_the_cleanup_handoff,
     the_reaper_rejects_an_operation_from_a_foreign_caller,
     a_duplicate_operation_returns_the_stored_result,
     a_gap_asks_the_steward_to_resend,
     the_operation_ceiling_bounds_the_request,
     finish_is_accepted_over_the_operation_ceiling,
     a_reaper_restart_recovers_the_volatile_cleanup].

%% These drive the reaper's own apply logic, so they run a real reaper the test
%% starts itself (the ceiling case needs its own options); the others inject
%% faults with the fake reaper.
direct_reaper_cases() ->
    [the_reaper_rejects_an_operation_from_a_foreign_caller,
     a_duplicate_operation_returns_the_stored_result,
     a_gap_asks_the_steward_to_resend,
     the_operation_ceiling_bounds_the_request,
     finish_is_accepted_over_the_operation_ceiling,
     a_reaper_restart_recovers_the_volatile_cleanup].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

init_per_testcase(TC, Config) ->
    process_flag(trap_exit, true),
    %% Free the reaper's registered name, and keep the supervisor from starting
    %% another underneath us.
    ok = wasm_worker_sup:suspend_reaper(),
    Dir = filename:join([?config(priv_dir, Config), atom_to_list(TC)]),
    ok = filelib:ensure_path(Dir),
    case lists:member(TC, direct_reaper_cases()) of
        true  -> [{dir, Dir} | Config];    %% the case starts its own real reaper
        false ->
            {ok, _} = fake_reaper:start_link(#{dir => Dir, roots => [scratch]}),
            [{dir, Dir} | Config]
    end.

end_per_testcase(TC, _Config) ->
    case lists:member(TC, direct_reaper_cases()) of
        true ->
            case get(worker) of
                undefined -> ok;
                W         -> quietly(fun() -> wasm_script_worker:stop(W) end)
            end,
            quietly(fun() -> wasm_worker_reaper:stop() end);
        false ->
            %% Let any parked caller go, so a wedged guardian from the pre-fix
            %% path unblocks and exits instead of lingering.
            quietly(fun() -> fake_reaper:release(register) end),
            quietly(fun() -> fake_reaper:release(reserve) end),
            quietly(fun() -> fake_reaper:release(finish) end),
            case get(worker) of
                undefined -> ok;
                W         -> quietly(fun() -> wasm_script_worker:stop(W) end)
            end,
            quietly(fun() -> fake_reaper:stop() end)
    end,
    quietly(fun() -> wasm_worker_sup:resume_reaper() end),
    ok.

%% Start a real reaper the direct cases drive, rooted at the case's scratch dir.
start_reaper(Config, Opts) ->
    {ok, _} = wasm_worker_reaper:start_link(#{scratch => ?config(dir, Config)},
                                            Opts),
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

%% The guardian publishes its result before it hands cleanup off, so a reaper
%% wedged on the finish barrier cannot hold the result up: the request answers on
%% its own time, and the finish is still submitted (the steward parks on it).
the_result_is_published_before_the_cleanup_handoff(_Config) ->
    ok = fake_reaper:set_mode(finish, hang),
    {ok, W} = wasm_script_worker:start_link(
                fake_typed_adapter, #{root => scratch, limits => #{timeout => 30_000}}),
    put(worker, W),
    Request = wasm_adapter_conformance:fixture(fake_typed_adapter, echo),
    {Micros, Result} = timer:tc(fun() -> wasm_script_worker:run(W, Request) end),
    ?assertMatch({ok, _}, Result),
    %% Well under the handoff grace: the result is not held behind the wedge.
    ?assert(Micros < 3_000_000, {stalled, Micros}),
    ok = wait_until(fun() -> fake_reaper:attempts(finish) >= 1 end).

%% Only the steward that reserved a request may drive its cleanup. This process
%% makes the reserve call, so it is the steward; an operation from it is
%% accepted, and the same operation from any other process is refused without
%% touching the request.
the_reaper_rejects_an_operation_from_a_foreign_caller(Config) ->
    ok = start_reaper(Config, #{}),
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

%% The same operation id, sent twice, must not run twice: the reaper answers the
%% duplicate from its ledger, and only one action is owned.
a_duplicate_operation_returns_the_stored_result(Config) ->
    ok = start_reaper(Config, #{}),
    Id = ~"dupreq00",
    {ok, _} = wasm_worker_reaper:reserve(Id, self(), scratch, ~"req-dupreq00"),
    Op = {register, fun() -> ok end},
    First  = gen_server:call(wasm_worker_reaper, {apply, Id, {Id, 1}, Op}),
    Second = gen_server:call(wasm_worker_reaper, {apply, Id, {Id, 1}, Op}),
    ?assertMatch({ok, _}, First),
    %% Same token, not a fresh one: the duplicate was answered from the ledger
    %% rather than registering a second action.
    ?assertEqual(First, Second).

%% A sequence the reaper has not reached yet is not applied out of order; it asks
%% for the one it is still missing.
a_gap_asks_the_steward_to_resend(Config) ->
    ok = start_reaper(Config, #{}),
    Id = ~"gapreq00",
    {ok, _} = wasm_worker_reaper:reserve(Id, self(), scratch, ~"req-gapreq00"),
    Op = {register, fun() -> ok end},
    ?assertEqual({resend, 1},
                 gen_server:call(wasm_worker_reaper, {apply, Id, {Id, 2}, Op})).

%% Past the per-request operation ceiling the reaper refuses without growing its
%% ledger, and the sequence stays contiguous so it never wedges on a gap.
the_operation_ceiling_bounds_the_request(Config) ->
    ok = start_reaper(Config, #{max_cleanup_operations_per_request => 3}),
    Id = ~"boundreq",
    {ok, _} = wasm_worker_reaper:reserve(Id, self(), scratch, ~"req-boundreq"),
    Op = fun(N) -> {apply, Id, {Id, N}, {register, fun() -> ok end}} end,
    [?assertMatch({ok, _}, gen_server:call(wasm_worker_reaper, Op(N)))
     || N <- [1, 2, 3]],
    ?assertMatch({error, #{kind := cleanup_saturated}, cleanup_failed},
                 gen_server:call(wasm_worker_reaper, Op(4))),
    %% The next in-order operation is still served, not stuck behind a gap.
    ?assertMatch({error, #{kind := cleanup_saturated}, cleanup_failed},
                 gen_server:call(wasm_worker_reaper, Op(5))).

%% finish is always accepted, even past the per-request operation ceiling; it
%% must never be treated as an over-limit operation, which had no reply clause
%% and crashed the singleton reaper for the whole node.
finish_is_accepted_over_the_operation_ceiling(Config) ->
    ok = start_reaper(Config, #{max_cleanup_operations_per_request => 2}),
    Id = ~"finreq00",
    {ok, _} = wasm_worker_reaper:reserve(Id, self(), scratch, ~"req-finreq00"),
    Reg = fun(N) -> {apply, Id, {Id, N}, {register, fun() -> ok end}} end,
    ?assertMatch({ok, _}, gen_server:call(wasm_worker_reaper, Reg(1))),
    ?assertMatch({ok, _}, gen_server:call(wasm_worker_reaper, Reg(2))),
    ?assertMatch({error, #{kind := cleanup_saturated}, cleanup_failed},
                 gen_server:call(wasm_worker_reaper, Reg(3))),
    %% Over the ceiling, but finish is accepted and the reaper stays alive.
    ?assertEqual(ok, gen_server:call(wasm_worker_reaper,
                                     {apply, Id, {Id, 4}, finish})),
    ?assert(is_pid(whereis(wasm_worker_reaper))).

%% A reaper that restarts mid-request keeps durable ops through its journal but
%% loses the volatile funs and adapter state, which lived only in its memory. The
%% v2 record names the steward, so the replacement asks it and recovers them:
%% the request's action count returns to what it was, from nowhere but the
%% surviving steward.
a_reaper_restart_recovers_the_volatile_cleanup(Config) ->
    Dir = ?config(dir, Config),
    {ok, _} = wasm_worker_reaper:start_link(#{scratch => Dir}),
    Marker = filename:join(Dir, "cleanup-marker"),
    {ok, W} = wasm_script_worker:start_link(
                fake_typed_adapter,
                #{root => scratch, limits => #{timeout => 30_000, fuel => infinity}}),
    put(worker, W),
    Request = maps:merge(
                wasm_adapter_conformance:fixture(fake_typed_adapter, runaway),
                #{cleanup_marker => Marker}),
    {ok, Ref} = wasm_script_worker:submit(W, Request),
    %% The register has reached the reaper: it owns the volatile action.
    ok = wait_until(fun() -> owned_actions() >= 1 end),
    %% Restart. The journal keeps the durable ops but not the fun.
    ok = wasm_worker_reaper:stop(),
    {ok, _} = wasm_worker_reaper:start_link(#{scratch => Dir}),
    %% The replacement recovered the fun from the steward, not the journal.
    ok = wait_until(fun() -> owned_actions() >= 1 end),
    ok = wasm_script_worker:cancel(W, Ref),
    _ = wasm_script_worker:await(W, Ref, 10_000).

owned_actions() ->
    case wasm_worker_reaper:requests() of
        Rs when is_list(Rs) -> lists:sum([maps:get(actions, R, 0) || R <- Rs]);
        _                   -> 0
    end.

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
