%% @doc Threads: the properties a single-threaded test cannot see.
%%
%% The specification suite runs one agent. It checks that
%% `i32.atomic.rmw.add` adds, which a plain load and store would also pass.
%% What it cannot check is that the operation is *indivisible*, and that is the
%% only reason the instruction exists.
%%
%% Every case here runs real Erlang processes against one shared memory and is
%% built so that a wrong implementation loses an update or a wakeup rather than
%% merely being slow. `a_read_then_write_would_lose_updates' is the control: it
%% performs the same arithmetic without the atomic instruction and is asserted
%% to *fail*, so the test above it is known to be measuring something.
-module(wasm_threads_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("wasm/include/wasm.hrl").

-define(WORKERS, 16).
-define(ROUNDS, 10000).

-define(I32, 16#7F).
-define(I64, 16#7E).
-define(FE, 16#FE).

all() ->
    [a_shared_memory_links_only_to_a_shared_import,
     concurrent_increments_lose_nothing,
     a_read_then_write_would_lose_updates,
     compare_exchange_admits_exactly_one_winner,
     wait_wakes_on_notify,
     wait_returns_not_equal_without_blocking,
     wait_times_out,
     notify_wakes_no_more_than_asked,
     killing_a_waiter_does_not_strand_the_others,
     two_notifiers_never_both_claim_one_waiter,
     the_waiter_table_never_belongs_to_a_waiter,
     wait_on_an_unshared_memory_traps,
     a_shared_memory_outlives_the_process_that_made_it].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

%%% ------------------------------------------------------------- linking ---

%% Sharing has to match in both directions. A module importing a memory as
%% shared will run atomics and `wait' on it; one importing it as unshared may
%% assume nothing else writes it. Neither is safe to satisfy with the other.
a_shared_memory_links_only_to_a_shared_import(_Config) ->
    {ok, Shared} = wasm_memory:new(shared_limits()),
    {ok, Plain} = wasm_memory:new(1, 2),
    {ok, Mod} = wasm:load(importing_module(shared)),
    ?assertMatch({ok, _}, wasm:instantiate(Mod, imports(Shared))),
    ?assertMatch({error, #{class := link, kind := incompatible_import_type}},
                 wasm:instantiate(Mod, imports(Plain))),
    {ok, PlainMod} = wasm:load(importing_module(unshared)),
    ?assertMatch({ok, _}, wasm:instantiate(PlainMod, imports(Plain))),
    ?assertMatch({error, #{class := link, kind := incompatible_import_type}},
                 wasm:instantiate(PlainMod, imports(Shared))).

%%% ---------------------------------------------------------- atomicity ---

%% Sixteen processes adding one, ten thousand times each, to the same address.
%% The answer has to be exactly 160,000: any lost update shows up as a shortfall
%% and no amount of luck can produce a surplus.
concurrent_increments_lose_nothing(_Config) ->
    ?assertEqual(?WORKERS * ?ROUNDS, hammer(~"bump")).

%% The control. `bump_racy` does the same arithmetic with an ordinary load, an
%% add and an ordinary store, which is what an atomic read-modify-write would
%% be if it were not atomic. This asserts that it *loses* updates: if it did
%% not, the test above would prove nothing about the instruction it is testing.
a_read_then_write_would_lose_updates(_Config) ->
    Total = hammer(~"bump_racy"),
    ?assert(Total < ?WORKERS * ?ROUNDS,
            {no_updates_lost, Total,
             "the racy control did not race, so the atomic test above is "
             "not measuring atomicity"}).

%% Every process tries to move the cell from 0 to its own identity with one
%% compare-exchange. Exactly one may succeed, and the cell has to end holding
%% that one's value.
compare_exchange_admits_exactly_one_winner(_Config) ->
    {ok, Mem} = wasm_memory:new(shared_limits()),
    Self = self(),
    Pids = [spawn_link(fun() ->
                           {ok, I} = instantiate(atomic_module(), Mem),
                           {ok, [Old]} = wasm:call(I, ~"claim", [N]),
                           Self ! {claimed, N, Old}
                       end) || N <- lists:seq(1, ?WORKERS)],
    Results = [receive {claimed, N, Old} -> {N, Old} end || _ <- Pids],
    Winners = [N || {N, 0} <- Results],
    ?assertEqual(1, length(Winners), {winners, Winners}),
    [Winner] = Winners,
    ?assertEqual(Winner, wasm_memory:atomic_load(Mem, 0, 4)).

%%% -------------------------------------------------------- wait, notify ---

%% The point of the proposal: an agent parks and another wakes it.
wait_wakes_on_notify(_Config) ->
    {ok, Mem} = wasm_memory:new(shared_limits()),
    Self = self(),
    Waiter = spawn_link(fun() ->
                            {ok, I} = instantiate(atomic_module(), Mem),
                            Self ! ready,
                            {ok, [R]} = wasm:call(I, ~"wait", [0, -1]),
                            Self ! {woke, R}
                        end),
    receive ready -> ok after 5000 -> ct:fail(no_waiter) end,
    %% Given long enough to actually be parked, so this is a wakeup and not a
    %% notify that happened to arrive before the wait began.
    timer:sleep(200),
    {ok, Notifier} = instantiate(atomic_module(), Mem),
    ?assertMatch({ok, [1]}, wasm:call(Notifier, ~"notify", [1])),
    receive {woke, R} -> ?assertEqual(0, R)
    after 5000 -> ct:fail(never_woke)
    end,
    _ = Waiter.

%% A value that already differs answers immediately and does not park, which is
%% what stops a caller sleeping on a condition that has already happened.
wait_returns_not_equal_without_blocking(_Config) ->
    {ok, Mem} = wasm_memory:new(shared_limits()),
    {ok, I} = instantiate(atomic_module(), Mem),
    ok = wasm_memory:atomic_store(Mem, 0, 4, 99),
    %% Expects 0, finds 99, so 1 rather than parking forever on no timeout.
    ?assertMatch({ok, [1]}, wasm:call(I, ~"wait", [0, -1])).

wait_times_out(_Config) ->
    {ok, Mem} = wasm_memory:new(shared_limits()),
    {ok, I} = instantiate(atomic_module(), Mem),
    T0 = erlang:monotonic_time(millisecond),
    ?assertMatch({ok, [2]}, wasm:call(I, ~"wait", [0, 50 * 1000 * 1000])),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    ?assert(Elapsed >= 50, {returned_early, Elapsed}).

%% Notifying one of three wakes one. The other two stay parked, which is what
%% makes `notify` a bounded wakeup rather than a broadcast.
notify_wakes_no_more_than_asked(_Config) ->
    {ok, Mem} = wasm_memory:new(shared_limits()),
    Self = self(),
    [spawn_link(fun() ->
                    {ok, I} = instantiate(atomic_module(), Mem),
                    Self ! ready,
                    {ok, [R]} = wasm:call(I, ~"wait", [0, 3000 * 1000 * 1000]),
                    Self ! {woke, R}
                end) || _ <- lists:seq(1, 3)],
    [receive ready -> ok after 5000 -> ct:fail(no_waiter) end
     || _ <- lists:seq(1, 3)],
    timer:sleep(200),
    {ok, N} = instantiate(atomic_module(), Mem),
    ?assertMatch({ok, [1]}, wasm:call(N, ~"notify", [1])),
    receive {woke, 0} -> ok after 2000 -> ct:fail(nobody_woke) end,
    %% Nobody else, until their own timeout.
    receive {woke, _} -> ct:fail(woke_too_many) after 300 -> ok end.

%% Killing a parked agent is exactly what a worker timeout does, and it used to
%% take everybody else down with it. The registration table was created by
%% whichever agent waited first, so it died with that agent, and the row a
%% killed waiter leaves behind was counted as woken because `exit(Pid, kill)'
%% runs no `after' clause. Either defect alone strands the survivor.
killing_a_waiter_does_not_strand_the_others(_Config) ->
    {ok, Mem} = wasm_memory:new(shared_limits()),
    Self = self(),
    %% The first agent owns the table under the old code, and is registered
    %% before the second arrives.
    Doomed = waiter(Mem, -1, Self),
    receive ready -> ok after 5000 -> ct:fail(no_waiter) end,
    Live = waiter(Mem, 5000 * 1000 * 1000, Self),
    receive ready -> ok after 5000 -> ct:fail(no_waiter) end,
    timer:sleep(200),
    exit(Doomed, kill),
    timer:sleep(200),
    {ok, N} = instantiate(atomic_module(), Mem),
    %% Exactly one, so a row left by the killed agent cannot be the one counted.
    ?assertMatch({ok, [1]}, wasm:call(N, ~"notify", [1])),
    receive {woke, R} -> ?assertEqual(0, R)
    after 5000 -> ct:fail(survivor_was_stranded)
    end,
    _ = Live.

waiter(Mem, Timeout, Parent) ->
    spawn(fun() ->
              {ok, I} = instantiate(atomic_module(), Mem),
              Parent ! ready,
              {ok, [R]} = wasm:call(I, ~"wait", [0, Timeout]),
              Parent ! {woke, R}
          end).

%% Waiting needs somewhere for the other agent to be. On a memory nothing else
%% can reach, parking would be a deadlock dressed as a feature.
wait_on_an_unshared_memory_traps(_Config) ->
    {ok, Mem} = wasm_memory:new(1, 2),
    {ok, I} = instantiate(unshared_atomic_module(), Mem),
    ?assertMatch({error, #{class := trap, kind := expected_shared_memory}},
                 wasm:call(I, ~"wait", [0, 0])).

%% An agent is an Erlang process, so a shared memory has to belong to the group
%% rather than to whichever agent happened to create it. The natural shape is a
%% coordinator that makes the memory and spawns workers over it, and that
%% coordinator must be free to exit.
%%
%% It was not. The memory was charged to its creating process and its published
%% chunk tuple was dropped when that process exited, so the node's page
%% accounting fell to zero while the memory was still in use, and growing it
%% afterwards failed. A shared memory is held manually now: no process's exit
%% removes that hold, and `free/1` is what releases it.
a_shared_memory_outlives_the_process_that_made_it(_Config) ->
    Before = wasm_engine:pages_in_use(),
    Self = self(),
    Coord = spawn(fun() ->
                      {ok, M} = wasm_memory:new(shared_limits()),
                      Self ! {mem, M},
                      receive done -> ok end
                  end),
    Mem = receive {mem, M} -> M after 5000 -> ct:fail(no_memory) end,
    ok = wasm_memory:atomic_store(Mem, 0, 4, 42),
    ?assertEqual(Before + 1, wasm_engine:pages_in_use()),
    Ref = erlang:monitor(process, Coord),
    Coord ! done,
    receive {'DOWN', Ref, _, _, _} -> ok after 5000 -> ct:fail(alive) end,
    timer:sleep(200),
    %% Still readable, still charged, and still able to grow.
    ?assertEqual(42, wasm_memory:atomic_load(Mem, 0, 4)),
    ?assertEqual(Before + 1, wasm_engine:pages_in_use()),
    {ok, _, Grown} = wasm_memory:grow(Mem, 1),
    ?assertEqual(0, wasm_memory:atomic_load(Grown, 70000, 4)),
    ok = wasm_memory:free(Grown),
    ?assertEqual(Before, wasm_engine:pages_in_use()).

%% `notify` answers how many agents it woke, and two of them racing for one
%% parked agent both said 1. `ets:delete_object/2` answers `true` whether or not
%% the row was there, so both notifiers deleted, both sent, and both counted a
%% waiter only one of them woke. Nothing hung, because the waiter discards the
%% second message; what was wrong was the number, which a guest uses to decide
%% whether anybody was listening.
%%
%% Five thousand rounds because one round wins the race by luck often enough to
%% look green.
two_notifiers_never_both_claim_one_waiter(_Config) ->
    Reported = [one_contested_wakeup() || _ <- lists:seq(1, 5000)],
    %% One waiter existed each round, so exactly one wakeup was available each
    %% round, however the two notifiers were scheduled.
    ?assertEqual(5000, length(Reported)),
    ?assertEqual([1], lists:usort(Reported)).

one_contested_wakeup() ->
    MemId = make_ref(),
    Self = self(),
    %% The row is inserted before `Read' is called, so signalling from inside it
    %% is what makes the waiter known to be registered.
    Waiter = spawn(fun() ->
                       R = wasm_wait:wait(MemId, 0,
                                          fun() -> Self ! ready, equal end,
                                          5000000000),
                       Self ! {woke, R}
                   end),
    receive ready -> ok after 5000 -> ct:fail(never_registered) end,
    Tag = make_ref(),
    _ = [spawn(fun() -> Self ! {Tag, wasm_wait:notify(MemId, 0, 1)} end)
         || _ <- [a, b]],
    A = receive {Tag, X} -> X after 5000 -> ct:fail(no_first) end,
    B = receive {Tag, Y} -> Y after 5000 -> ct:fail(no_second) end,
    receive {woke, 0} -> ok after 5000 -> ct:fail({not_woken, Waiter}) end,
    A + B.

%% The table has to be owned by something that outlives waiters, and a waiter
%% is a guest's process that a worker timeout kills outright. There used to be
%% a fallback that created it in whichever agent got there first, taken when
%% the application was not running; it is gone, and an unsupervised engine is
%% started on demand instead.
the_waiter_table_never_belongs_to_a_waiter(_Config) ->
    MemId = make_ref(),
    %% Force the table into existence through the ordinary path.
    0 = wasm_wait:notify(MemId, 0, 1),
    Owner = ets:info(wasm_waiters, owner),
    ?assert(Owner =:= whereis(wasm_sup) orelse Owner =:= whereis(wasm_engine)),
    ?assertNotEqual(self(), Owner).

%%% ---------------------------------------------------------------- setup ---

%% Every worker gets its own instance over one shared memory, which is how the
%% proposal models agents: separate instances, one store of memory.
hammer(Fn) ->
    {ok, Mem} = wasm_memory:new(shared_limits()),
    Self = self(),
    Pids = [spawn_link(fun() ->
                           {ok, I} = instantiate(atomic_module(), Mem),
                           {ok, []} = wasm:call(I, Fn, [?ROUNDS]),
                           Self ! {done, self()}
                       end) || _ <- lists:seq(1, ?WORKERS)],
    [receive {done, P} -> ok after 60000 -> ct:fail({worker_stuck, P}) end
     || P <- Pids],
    wasm_memory:atomic_load(Mem, 0, 4).

shared_limits() ->
    #limits{min = 1, max = 2, shared = true}.

instantiate(Bin, Mem) ->
    {ok, Mod} = wasm:load(Bin),
    wasm:instantiate(Mod, imports(Mem)).

imports(Mem) -> #{{~"env", ~"mem"} => Mem}.

%%% -------------------------------------------------------- module builder ---

%% ```
%% (import "env" "mem" (memory 1 2 shared))
%% (func (export "bump") (param i32))        ;; n atomic increments of [0]
%% (func (export "bump_racy") (param i32))   ;; the same, non-atomically
%% (func (export "claim") (param i32) (result i32))
%% (func (export "wait") (param i32 i64) (result i32))
%% (func (export "notify") (param i32) (result i32))
%% ```
atomic_module() -> atomic_module(shared).

unshared_atomic_module() -> atomic_module(unshared).

atomic_module(Sharing) ->
    Types = wasm_asm:type_section(
              [{[?I32], []},
               {[?I32], [?I32]},
               {[?I32, ?I64], [?I32]}]),
    %% loop { atomic.rmw.add [0] += 1 ; countdown }
    Bump = <<16#03, 16#40,
               16#41, 0, 16#41, 1, ?FE, 16#1E, 2, 0, 16#1A,
               (countdown())/binary,
             16#0B, 16#0B>>,
    %% The same shape with an ordinary load, add and store: three steps another
    %% process can interleave with.
    Racy = <<16#03, 16#40,
               16#41, 0,
               16#41, 0, 16#28, 2, 0,
               16#41, 1, 16#6A,
               16#36, 2, 0,
               (countdown())/binary,
             16#0B, 16#0B>>,
    %% cmpxchg [0], expecting 0, replacing with the parameter.
    Claim = <<16#41, 0, 16#41, 0, 16#20, 0, ?FE, 16#48, 2, 0, 16#0B>>,
    Wait = <<16#41, 0, 16#20, 0, 16#20, 1, ?FE, 16#01, 2, 0, 16#0B>>,
    Notify = <<16#41, 0, 16#20, 0, ?FE, 16#00, 2, 0, 16#0B>>,
    wasm_asm:module(
      [Types,
       memory_import(Sharing),
       wasm_asm:func_section([0, 0, 1, 2, 1]),
       wasm_asm:export_section([{~"bump", 0, 0}, {~"bump_racy", 0, 1},
                                {~"claim", 0, 2}, {~"wait", 0, 3},
                                {~"notify", 0, 4}]),
       wasm_asm:code_section([Bump, Racy, Claim, Wait, Notify])]).

%% A module that only imports a memory, for the linking case.
importing_module(Sharing) ->
    wasm_asm:module([wasm_asm:type_section([]), memory_import(Sharing)]).

%% Flags bit 0 is "has maximum" and bit 1 is "shared".
memory_import(shared) -> memory_import_flags(16#03);
memory_import(unshared) -> memory_import_flags(16#01).

memory_import_flags(Flags) ->
    wasm_asm:section(
      2, [wasm_asm:uleb(1), wasm_asm:name(~"env"), wasm_asm:name(~"mem"),
          16#02, Flags, wasm_asm:uleb(1), wasm_asm:uleb(2)]).

%% local.get 0; i32.const 1; i32.sub; local.tee 0; br_if 0
countdown() -> <<16#20, 0, 16#41, 1, 16#6B, 16#22, 0, 16#0D, 0>>.
