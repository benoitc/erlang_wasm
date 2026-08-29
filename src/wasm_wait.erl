-module(wasm_wait).
-moduledoc """
`memory.atomic.wait` and `memory.atomic.notify`. Read this when a threaded
guest is parked and you want to know who is meant to wake it.

A waiting agent parks until another writes the address it is watching and
notifies it. On other runtimes this is a futex; here it is an Erlang process
blocking in `receive`, which is the one part of the threads proposal the BEAM
makes easier rather than harder.

## The race, and why the mailbox settles it

A futex has a famous hazard. The waiter must check the value and then sleep,
and a notifier that writes and signals *between* those two steps signals
nobody: the waiter sleeps forever holding a value it already knows is stale.
Real implementations close it with a lock around the queue, or with a kernel
that performs the compare and the sleep as one operation.

Here the waiter registers **before** it re-reads the value. A notify arriving
after that lands in the waiter's mailbox, and `receive` finds it whether it
arrived before or after the call. There is nothing to lose, because a mailbox
is not a signal that can be missed; it is a queue.

Each wait carries a fresh reference, so a notify that arrives after a waiter
gave up cannot be mistaken for an answer to that waiter's next wait. The
mailbox is swept on the way out either way, so a stale message cannot
accumulate.

## What is not modelled

Nothing here reorders memory. Every access goes through `atomics`, which is
sequentially consistent, so `atomic.fence` has nothing to do and the relaxed
memory model the proposal permits is not exploited. That is a choice worth
naming: an implementation that reordered would be faster and would also make
the ordering bugs in guest programs unreproducible.
""".

-export([wait/4, notify/3]).

-define(TAB, wasm_waiters).

-doc """
Park until notified, the value changes, or the timeout expires.

Answers 0 if woken, 1 if the value at the address was not the expected one, and
2 if it timed out. A negative timeout means no timeout at all.
""".
-spec wait(term(), non_neg_integer(), fun(() -> integer()), integer()) ->
          0 | 1 | 2.
wait(MemId, Addr, Read, TimeoutNs) ->
    ensure_table(),
    Key = {MemId, Addr},
    Ref = make_ref(),
    %% Registered first. Everything after this point is safe against a notify
    %% arriving concurrently, because the notify becomes a message rather than
    %% an event that has to find someone listening.
    true = ets:insert(?TAB, {Key, self(), Ref}),
    Entry = {Key, self(), Ref},
    try
        case Read() of
            not_equal -> 1;
            equal -> park(Entry, Ref, TimeoutNs)
        end
    after
        ets:delete_object(?TAB, Entry),
        flush(Ref)
    end.

park(Entry, Ref, TimeoutNs) ->
    Timeout = timeout_ms(TimeoutNs),
    receive
        {wasm_notify, Ref} -> 0
    after Timeout ->
        %% Race the notifier for our own row, and let whoever removes it decide.
        %%
        %% Looking in the mailbox instead was not enough. A notifier claims the
        %% row and *then* sends, and between those two the waiter could time
        %% out, find nothing, delete a row that was already gone and flush an
        %% empty mailbox: the message arrived afterwards and stayed there for
        %% ever, because `Ref` is per wait and no later wait can match it. A
        %% worker that times out often accumulated one per wait.
        %%
        %% `claim/1` removes the row and answers whether *this* caller removed
        %% it, so exactly one of the two wins and the loser knows it lost.
        case claim(Entry) of
            true ->
                2;
            false ->
                %% A notifier has us and counted us as woken. Its send is
                %% already done or one instruction away, so wait for it and
                %% answer as it did: disagreeing would lose the wakeup.
                receive {wasm_notify, Ref} -> 0
                after 1000 -> 0
                end
        end
    end.

-doc "Wake up to `Count` agents waiting on `Addr`, answering how many.".
-spec notify(term(), non_neg_integer(), non_neg_integer()) ->
          non_neg_integer().
notify(MemId, Addr, Count) ->
    ensure_table(),
    Waiters = ets:lookup(?TAB, {MemId, Addr}),
    %% Rows left by killed waiters are dropped before the count is applied. A
    %% waiter that gives up normally removes its own row in an `after' clause,
    %% but `exit(Pid, kill)' runs no `after', and counting one of those against
    %% `Count' would swallow a live agent's wakeup.
    %%
    %% The whole live list is offered rather than the first `Count' of it,
    %% because a candidate another notifier claims first must not use up one of
    %% ours: `Count' bounds how many are *woken*, not how many are tried.
    wake(live(Waiters), Count, 0).

live(Waiters) ->
    [W || {_Key, Pid, _Ref} = W <- Waiters, alive(W, Pid)].

alive(Entry, Pid) ->
    case is_process_alive(Pid) of
        true -> true;
        false -> ets:delete_object(?TAB, Entry), false
    end.

wake(_Waiters, 0, N) -> N;
wake([], _Left, N) -> N;
wake([{_Key, Pid, Ref} = Entry | Rest], Left, N) ->
    case claim(Entry) of
        true ->
            ok = claimed_hook(),
            Pid ! {wasm_notify, Ref},
            wake(Rest, Left - 1, N + 1);
        false ->
            %% Somebody else's wakeup, or a waiter that gave up. Either way not
            %% ours to count, and not one of our `Count' either.
            wake(Rest, Left, N)
    end.

%% Removing the row is what claims the waiter, and it has to answer whether
%% *this* call removed it.
%%
%% `ets:delete_object/2' answers `true' whether or not the row was there, so
%% two notifiers racing for one waiter both deleted, both sent, and both
%% counted it. The waiter woke once and discarded the second message, so
%% nothing hung; what was wrong was the number each notifier reported, which
%% the specification defines as the waiters it woke. Two calls of
%% `notify(_, _, 1)` against a single parked agent returned 1 each.
%%
%% `ets:select_delete/2' answers how many rows it removed, so exactly one
%% caller sees 1.
claim({Key, Pid, Ref}) ->
    ets:select_delete(?TAB, [{{Key, Pid, Ref}, [], [true]}]) =:= 1.

-ifdef(TEST).
%% A sync point between claiming a waiter and sending to it.
%%
%% The window between those two is nanoseconds wide and a test cannot land in it
%% by racing: two thousand rounds of trying hit it zero times, which is how a
%% test for this ends up passing whether the defect is there or not. So the
%% notifier can be held open here on request. Never compiled into a release.
claimed_hook() ->
    case application:get_env(wasm, wait_claim_hook) of
        {ok, F} when is_function(F, 0) -> _ = F(), ok;
        _ -> ok
    end.
-else.
claimed_hook() -> ok.
-endif.

%% A negative timeout is "wait forever". The specification counts nanoseconds
%% and Erlang counts milliseconds, so a timeout under a millisecond rounds up
%% rather than down: returning "timed out" before the requested time has passed
%% would be wrong, while returning it late is merely imprecise.
timeout_ms(Ns) when Ns < 0 -> infinity;
timeout_ms(Ns) -> (Ns + 999999) div 1000000.

flush(Ref) ->
    receive {wasm_notify, Ref} -> ok
    after 0 -> ok
    end.

%% The engine owns the table, not whichever agent happened to touch it first.
%% An ETS table dies with its creator, and creating this one here meant a
%% waiter killed on a worker timeout took every other agent's registration with
%% it: the next `notify' found an empty table and woke nobody, and anything
%% parked with no timeout parked forever.
ensure_table() ->
    case ets:whereis(?TAB) of
        undefined -> create();
        _ -> ok
    end.

%% There is no local fallback. One existed so a threaded module could run
%% without the application, and it put the table back in the hands of a waiter,
%% which is the whole defect. `wasm_engine' starts unsupervised on demand
%% instead, so the owner outlives waiters whether the application is running or
%% not, and there is one path rather than a tested one and an untested one.
create() -> wasm_engine:ensure_waiters().
