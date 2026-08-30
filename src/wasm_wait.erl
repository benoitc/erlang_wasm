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
        %% And any naming a notifier left behind by dying inside the two steps
        %% above. The key is this wait's own reference, so nothing else can be
        %% removed by it.
        ets:delete(?TAB, {claimed, Ref}),
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
            true -> 2;
            false -> lost_the_race(Ref)
        end
    end.

%% A notifier has us and counted us as woken. Its send is already done or one
%% instruction away, so wait for it and answer as it did: disagreeing would
%% lose the wakeup.
%%
%% What to wait *on* is the question. A second was the first answer and it was
%% a guess: a notifier killed between claiming us and sending made every waiter
%% report a wakeup that never happened, a second late, and a message arriving
%% after that second lingered past the flush with a reference no later wait can
%% match. So the notifier leaves its own name behind while it sends, and the
%% wait is bounded by that process rather than by a clock -- the message, or
%% the death of the only process that could still send it.
%%
%% No row means the send has already happened and the message is on its way, so
%% the plain receive stands.
lost_the_race(Ref) ->
    case claimer(Ref) of
        none ->
            %% The row goes after the send, so there is no row only once the
            %% message is already in this mailbox.
            receive {wasm_notify, Ref} -> 0 end;
        Pid ->
            Mon = erlang:monitor(process, Pid),
            try
                receive
                    {wasm_notify, Ref} -> 0;
                    %% It died holding our wakeup, so nothing woke us and the
                    %% timeout we already had is the honest answer.
                    {'DOWN', Mon, _, _, _} -> 2
                end
            after
                erlang:demonitor(Mon, [flush])
            end
    end.

claimer(Ref) ->
    try ets:lookup(?TAB, {claimed, Ref}) of
        [{_, Pid}] -> Pid;
        [] -> none
    catch error:badarg -> none
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
    %% Named *before* the claim is attempted, and `insert_new/2` is what makes
    %% the naming the thing that is raced for: exactly one notifier can hold it,
    %% so a waiter that lost has one process to wait on rather than a guess at
    %% how long a send takes. A notifier that does not hold it does not try to
    %% claim, which is why the row can be trusted to name the sender.
    case ets:insert_new(?TAB, {{claimed, Ref}, self()}) of
        false ->
            wake(Rest, Left, N);
        true ->
            case claim(Entry) of
                true ->
                    ok = claimed_hook(),
                    Pid ! {wasm_notify, Ref},
                    %% After the send, so finding no row means the message is
                    %% already in the waiter's mailbox.
                    true = ets:delete(?TAB, {claimed, Ref}),
                    wake(Rest, Left - 1, N + 1);
                false ->
                    %% Somebody else's wakeup, or a waiter that gave up. Either
                    %% way not ours to count, and not one of our `Count` either.
                    true = ets:delete(?TAB, {claimed, Ref}),
                    wake(Rest, Left, N)
            end
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
