-module(wasm_cleanup_manager_SUITE).
-moduledoc """
The cleanup manager's capacity accounting, its tracking of the reaper, and its
job leases.

The admission cases call `wasm_cleanup_manager:admit/1` and `release/1`
directly: nothing in `src/` calls them yet, because the reaper still decides
admission. The other cases check that the manager learns the current reaper's
generation and that local cleanup jobs stay within `max_cleanup_jobs`.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [capacity_is_positive,
     admission_is_idempotent,
     admission_stops_at_capacity,
     release_frees_a_slot,
     the_manager_learns_the_reaper_generation,
     local_cleanup_jobs_are_bounded,
     queued_cleanup_jobs_start_in_the_order_queued].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

capacity_is_positive(_Config) ->
    ?assert(wasm_cleanup_manager:capacity() > 0).

admission_is_idempotent(_Config) ->
    Id = id(),
    Before = wasm_cleanup_manager:admitted(),
    ?assertEqual(ok, wasm_cleanup_manager:admit(Id)),
    ?assertEqual(ok, wasm_cleanup_manager:admit(Id)),
    ?assertEqual(Before + 1, wasm_cleanup_manager:admitted()),
    ok = wasm_cleanup_manager:release(Id),
    ?assertEqual(Before, wasm_cleanup_manager:admitted()).

%% Fill the node to its ceiling and prove the next request is refused, then
%% release everything this case admitted.
admission_stops_at_capacity(_Config) ->
    Base = wasm_cleanup_manager:admitted(),
    Cap = wasm_cleanup_manager:capacity(),
    Room = Cap - Base,
    Ids = [id() || _ <- lists:seq(1, Room)],
    [?assertEqual(ok, wasm_cleanup_manager:admit(I)) || I <- Ids],
    ?assertEqual(Cap, wasm_cleanup_manager:admitted()),
    ?assertEqual({error, cleanup_saturated}, wasm_cleanup_manager:admit(id())),
    [ok = wasm_cleanup_manager:release(I) || I <- Ids],
    ?assertEqual(Base, wasm_cleanup_manager:admitted()).

release_frees_a_slot(_Config) ->
    Base = wasm_cleanup_manager:admitted(),
    Cap = wasm_cleanup_manager:capacity(),
    Ids = [id() || _ <- lists:seq(1, Cap - Base)],
    [ok = wasm_cleanup_manager:admit(I) || I <- Ids],
    ?assertEqual({error, cleanup_saturated}, wasm_cleanup_manager:admit(id())),
    ok = wasm_cleanup_manager:release(hd(Ids)),
    Extra = id(),
    ?assertEqual(ok, wasm_cleanup_manager:admit(Extra)),
    [ok = wasm_cleanup_manager:release(I) || I <- [Extra | tl(Ids)]],
    ?assertEqual(Base, wasm_cleanup_manager:admitted()).

%% With no reaper the manager is `recovering`. Lazily start one and the manager
%% learns its generation from the announcement and reaches `ready`.
the_manager_learns_the_reaper_generation(_Config) ->
    ok = wasm_worker_sup:ensure_reaper(),
    true = wait_until(fun() -> wasm_cleanup_manager:phase() =:= ready end, 100),
    ?assertEqual(ready, wasm_cleanup_manager:phase()),
    ?assertEqual(wasm_worker_reaper:generation(),
                 wasm_cleanup_manager:reaper_generation()).

wait_until(_Pred, 0) -> false;
wait_until(Pred, N) ->
    case Pred() of
        true  -> true;
        false -> timer:sleep(20), wait_until(Pred, N - 1)
    end.

%% Local cleanup jobs share the node's `max_cleanup_jobs' bound: a burst of
%% fallbacks starts at most that many at once and queues the rest, so a reaper
%% outage cannot make local cleanup an unbounded spawn. Each job's action blocks
%% until released, so all the started ones hold their leases at once.
local_cleanup_jobs_are_bounded(_Config) ->
    Cap = wasm_worker_reaper:setting(#{}, max_cleanup_jobs),
    Self = self(),
    Blocker = fun() ->
                  Self ! {started, self()},
                  receive release -> ok after 10_000 -> ok end
              end,
    Mirror = #{dir => "/nonexistent/cleanup", adapter_state => undefined,
               actions => [Blocker]},
    [ok = wasm_cleanup_manager:start_local_cleanup(
            integer_to_binary(N), Mirror#{id => integer_to_binary(N)})
     || N <- lists:seq(1, Cap + 1)],
    Started = collect_started(Cap, 3_000),
    ?assertEqual(Cap, length(Started)),
    %% The (Cap + 1)th is queued, not started, while every slot is held.
    ?assertEqual(timeout, collect_one(300)),
    %% Release one; the queued job takes its freed slot and runs.
    hd(Started) ! release,
    ?assertMatch({started, _}, collect_one(3_000)),
    %% Release the rest so nothing lingers.
    [P ! release || P <- tl(Started)],
    _ = collect_one(2_000),
    ok.

%% Jobs queued behind the cap start first in, first out. The overflow was a
%% list appended at its end and is a `queue' now: this holds the order, it does
%% not reproduce a defect. Slots another case still holds only delay the jobs
%% queued here, so every job that starts is released until the three have.
queued_cleanup_jobs_start_in_the_order_queued(_Config) ->
    Cap = wasm_worker_reaper:setting(#{}, max_cleanup_jobs),
    Self = self(),
    Start = fun(Id, Tag) ->
                Job = fun() ->
                          Self ! {started, Tag, self()},
                          receive release -> ok after 10_000 -> ok end
                      end,
                ok = wasm_cleanup_manager:start_local_cleanup(
                       Id, #{id => Id, dir => "/nonexistent/cleanup",
                             adapter_state => undefined, actions => [Job]})
            end,
    [Start(<<"fifo-held-", (integer_to_binary(N))/binary>>, held)
     || N <- lists:seq(1, Cap)],
    Held = held_started(300),
    ?assertNotEqual([], Held),
    [Start(<<"fifo-", (integer_to_binary(K))/binary>>, K) || K <- [1, 2, 3]],
    {Order, Rest} = release_until(3, Held, [], []),
    ?assertEqual([1, 2, 3], Order),
    [P ! release || P <- Rest],
    ok.

held_started(Timeout) ->
    receive {started, held, P} -> [P | held_started(Timeout)]
    after Timeout -> []
    end.

%% Release one held job at a time and note which queued job takes the slot.
release_until(0, Held, Order, Started) ->
    {lists:reverse(Order), Held ++ Started};
release_until(N, [P | Held], Order, Started) ->
    P ! release,
    receive
        {started, held, P2} -> release_until(N, Held ++ [P2], Order, Started);
        {started, Tag, Q}   -> release_until(N - 1, Held, [Tag | Order],
                                             [Q | Started])
    after 5_000 ->
        ct:fail({no_job_started, lists:reverse(Order)})
    end.

collect_started(0, _Timeout) -> [];
collect_started(N, Timeout) ->
    case collect_one(Timeout) of
        {started, Pid} -> [Pid | collect_started(N - 1, Timeout)];
        timeout        -> []
    end.

collect_one(Timeout) ->
    receive {started, Pid} -> {started, Pid} after Timeout -> timeout end.

id() -> {req, erlang:unique_integer([positive])}.
