%% @doc The reaper as part of the application.
%%
%% Every case runs in a peer node of its own. They set application
%% environment before `wasm' starts, and they create, kill and remove
%% supervised children, none of which may leak into the Common Test node,
%% where `wasm_worker_kernel_SUITE' and the conformance kit run their own
%% reaper by hand.
-module(wasm_worker_sup_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

suite() -> [{timetrap, {minutes, 5}}].

all() ->
    [a_worker_serves_a_request_with_nobody_starting_a_reaper].

%%% --------------------------------------------------------------- cases ---

%% The whole point of shipping the kernel: an application that depends on
%% `wasm' starts a worker and gets an answer. On the tree before the reaper
%% was supervised this answers `{error, #{kind := no_reaper}}'.
a_worker_serves_a_request_with_nobody_starting_a_reaper(Config) ->
    in_peer(Config, #{}, fun serves_a_request/0).

serves_a_request() ->
    {ok, W} = wasm_script_worker:start_link(fake_reactor_adapter,
                                            #{root => scratch}),
    ?assertMatch({ok, _}, wasm_script_worker:run(W, echo())),
    ok = wasm_script_worker:stop(W).

%%% ------------------------------------------------------------- helpers ---

echo() ->
    {ok, A} = fake_reactor_adapter:artifact(#{}),
    #{base := #{echo := Echo}} = fake_reactor_adapter:conformance_fixtures(A),
    Echo.

%% Runs Fun in a fresh peer node with `Env' set for `wasm' before it starts
%% and the repository root as the working directory, since the fixtures are
%% named relative to it.
%%
%% Fun must return `ok', and anything else fails the case. A worker Fun starts
%% is linked to the process Fun runs in, and a worker that crashed in `init'
%% used to take that process with it; the call then came back without an
%% exception and the first version of this suite passed with nothing having
%% run. So Fun runs in a process of its own, trapping exits, and the outcome
%% is checked here.
in_peer(Config, Env, Fun) ->
    _ = Config,
    Paths = lists:append([["-pa", D] || D <- code:get_path()]),
    {ok, Peer, _} = peer:start_link(#{connection => standard_io,
                                      args => Paths}),
    try
        ok = peer:call(Peer, file, set_cwd, [root()]),
        _ = [ok = peer:call(Peer, application, set_env, [wasm, K, V])
             || K := V <- Env],
        {ok, _} = peer:call(Peer, application, ensure_all_started, [wasm]),
        ?assertEqual(ok, peer:call(Peer, ?MODULE, run_in_peer, [Fun], 120000))
    after
        peer:stop(Peer)
    end.

run_in_peer(Fun) ->
    Parent = self(),
    {Pid, Ref} = spawn_monitor(
                   fun() ->
                       process_flag(trap_exit, true),
                       Parent ! {self(), try Fun() of
                                             ok    -> ok;
                                             Other -> {returned, Other}
                                         catch
                                             C:R:St -> {C, R, St}
                                         end}
                   end),
    receive
        {Pid, Result}            -> demonitor(Ref, [flush]), Result;
        {'DOWN', Ref, _, _, Why} -> {died, Why}
    end.

root() ->
    filename:absname(filename:join([code:lib_dir(wasm), "..", "..", "..", ".."])).
