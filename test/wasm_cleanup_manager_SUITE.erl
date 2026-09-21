-module(wasm_cleanup_manager_SUITE).
-moduledoc """
The cleanup manager's capacity accounting.

The manager bounds how many requests may hold cleanup state at once, keyed by
request id. This is the foundation the steward routing builds on; the lease and
recovery machinery arrive with later stages.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [capacity_is_positive,
     admission_is_idempotent,
     admission_stops_at_capacity,
     release_frees_a_slot,
     the_manager_learns_the_reaper_generation].

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

id() -> {req, erlang:unique_integer([positive])}.
