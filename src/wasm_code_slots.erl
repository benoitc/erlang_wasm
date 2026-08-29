-module(wasm_code_slots).
-moduledoc """
Who is still using a piece of generated code, and when its slot may be reused.

You get here if you turn a WebAssembly module into a BEAM module. Read this
before you load one, because loading generated code is the part of a compiler
that goes wrong quietly: the code runs, the numbers look good, and the failure
arrives later as a process killed mid-call or a call that resolved to the wrong
module.

## What it is

A fixed pool of slots. Each slot owns one **pre-interned module name**,
`wasm_code_0` through `wasm_code_N`, written into this module's source and
interned when it is compiled. Nothing derived from a user's module ever becomes
an atom, which is the property that matters: the atom table is node-wide and
never reclaimed, so a generated name taken from a module's own bytes is a
permanent leak with a remote attacker holding the tap.

A slot is claimed for a *content key* -- whatever the caller uses to identify a
module, normally its hash -- and is held by **leases**. There are two kinds and
both are load-bearing:

- an **instance** lease, taken when an instance that may run this code exists
- a **call** lease, taken for the duration of a call into it

An instance can be destroyed while a call into it is still running, so
releasing the instance's lease must not let the code be replaced underneath the
call. Reuse happens only when the last lease of either kind is gone.

The two are taken by different mechanisms, and that is a measurement rather
than an inconsistency. An instance lease is rare and is a `gen_server` call,
about 5.8 us, which buys a monitor so that a dead holder gives its lease back.
A call lease is on the call path -- an interpreted call costs 44 ns -- so it is
one `atomics` increment on a per-slot counter, about 20 ns, the same shape
`wasm_heap` uses for execution leases.

## When to use it

    case wasm_code_slots:claim_loading(Key, {instance, Ref}, self()) of
        {compile, Mod, Token} ->
            case load(Mod, generate()) of
                ok    -> wasm_code_slots:publish(Token);
                error -> wasm_code_slots:abort(Token)
            end;
        {resident, _Mod} -> ok;
        loading          -> interpret;
        {error, no_slot} -> interpret
    end,
    ...
    case wasm_code_slots:lease_call(Mod, Key) of
        ok    -> try Mod:F(Args) after wasm_code_slots:release_call(Mod) end;
        stale -> interpret
    end,
    ...
    ok = wasm_code_slots:release(Key, {instance, Ref}).

**Nothing enters a slot between the reservation and `publish/1`.** The counter
stays at its exclusive value for the whole reservation, which is what stops a
second caller running the slot's previous occupant while the new binary is
still being compiled.

`claim_loading/3` answers `{error, no_slot}` when every slot is held, and
`loading` when somebody else is already filling this key in. **Neither is a
failure**, both are the signal to interpret this module instead. A compiler
that cannot fall back has to either kill a caller or grow the atom table, and
both are worse than being slower.

## What it deliberately does not do

It never calls `code:purge/1`, which kills processes still running old code.
Reuse goes through `code:soft_purge/1`, and a slot whose old code is still
running is left alone and reported as unavailable rather than taken.

**`soft_purge/1` is the authority and the call leases are a hint.** It was the
other way round once and could not be: a lease is given back in an `after`,
which does not run when a process is killed untrappably, and killing a process
is how a runaway invocation is stopped here. Leases leak, so they cannot be what
decides whether a slot may be taken.

What makes reuse safe is not here at all. Generated code carries the stamp it
was built for and refuses a caller carrying another, which is atomic with the
call in a way no lease can be. See `wasm_core:module/6`. That is why a stuck
counter can be repaired from `soft_purge/1` without a race.

`soft_purge/1` runs *inside this server*, so every claim, publish and lease
queues behind an operation whose cost grows with the number of live processes on
the node. It is a known serialisation point, kept deliberately: moving it out
re-opens the window the reservation exists to close, and nothing has measured it
as a problem.

It does not survive a process killed outright. `exit(Pid, kill)` skips the
`after` that would give a call lease back, and that slot's counter stays raised
for ever, so it is never reused again. The consequence is that callers
interpret instead, which is the fallback this module exists to provide, so this
costs speed and never safety. `wasm_heap` accepts the same exposure on the same
reasoning.
""".
-behaviour(gen_server).

-export([start_link/0, ensure_table/0]).
-export([claim_loading/3, publish/1, abort/1]).
-export([lease/3, release/2, lookup/1, slots/0, slot_module/1, resident/0]).
-export([lease_ref/1, lease_at/2, release_at/2]).
-export([resident_module/1]).
-export([lease_call/1, lease_call/2, release_call/1, calls_in/1]).
-export([hot/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([key/0, lease/0, token/0]).

-type key() :: term().
-type lease() :: {instance, reference()} | {call, reference()} | {manual, term()}.
%% Names the reservation, not the slot: `{Name, Generation}'.
-type token() :: {module(), non_neg_integer()}.

%% The pool size is fixed here rather than configured, because the names are
%% atoms and the set of atoms this module can ever create has to be decidable
%% by reading it. Raising it means editing this list, which is the point.
-define(NAMES, ['wasm_code_0', 'wasm_code_1', 'wasm_code_2', 'wasm_code_3',
                'wasm_code_4', 'wasm_code_5', 'wasm_code_6', 'wasm_code_7',
                'wasm_code_8', 'wasm_code_9', 'wasm_code_10', 'wasm_code_11',
                'wasm_code_12', 'wasm_code_13', 'wasm_code_14', 'wasm_code_15']).
-define(NAME_TUPLE, {'wasm_code_0', 'wasm_code_1', 'wasm_code_2', 'wasm_code_3',
                     'wasm_code_4', 'wasm_code_5', 'wasm_code_6', 'wasm_code_7',
                     'wasm_code_8', 'wasm_code_9', 'wasm_code_10', 'wasm_code_11',
                     'wasm_code_12', 'wasm_code_13', 'wasm_code_14', 'wasm_code_15'}).

%% Owned by the supervisor, so a crash here does not take the record of what is
%% loaded with it. Same reason as `wasm_holders': an ETS table dies with the
%% process that created it, and a manager that created its own would come back
%% believing no code was resident while sixteen modules were still loaded.
-define(TAB, wasm_code_slots).

%% How many times each module has been called, until it is hot enough to
%% compile. Its own table rather than a row shape in `?TAB': every reader of
%% `?TAB' walks the whole thing, and a counter row would have to be skipped by
%% each of them.
-define(CALLS, wasm_code_calls).

%% One counter per slot, holding the number of calls currently inside its code,
%% plus `?EXCL' while the manager is replacing it. Published in `persistent_term'
%% the way `wasm_engine' publishes its counters, because every process that
%% enters compiled code has to reach it without asking anybody.
%%
%% This is the same shape `wasm_heap' uses for execution leases, and for the
%% same reason: a call lease is on the call path, and a round trip there costs
%% more than the thing it guards. Measured at 5.8 us through the manager against
%% about 20 ns here.
-define(PT_COUNTERS, {?MODULE, counters}).
-define(EXCL, (1 bsl 32)).

%% `{Name, Gen, State, Leases}'.
%%
%% `State' is `free', `{loading, Key}' while somebody is compiling into it, or
%% `{resident, Key}' once the code is loaded. The three are not the same and
%% treating the first two alike is how a caller ends up running the slot's
%% *previous* occupant: the row named the new key before the new binary
%% existed.
%%
%% `Gen' is bumped on every reservation and is what a loading token carries.
%% Addressing `publish/1' by key rather than by generation would let a slow
%% compiler publish over a later reservation of the same key.
%%
%% `Leases' is a map from lease to the pid holding it, so a holder that dies is
%% noticed.
%%
%% The monitor index runs both ways. A `DOWN' arrives with the reference, and a
%% release arrives with the lease, and both have to find the other: without
%% `refs' a released lease left its monitor behind for ever, so the manager
%% accumulated one monitor per lease it had ever handed out.
%%
%% Neither map lives in the table. A monitor belongs to *this* process and is
%% meaningless after a restart, which is why `init/1' re-monitors from the rows
%% rather than reading references back.
%% `loading' monitors whoever holds a reservation. A compiler killed mid-flight
%% would otherwise hold the slot exclusively for the life of the node, taking it
%% out of the pool for good, so its `DOWN' aborts the reservation.
-record(state, {monitors = #{} :: #{reference() => {key(), lease()}},
                refs     = #{} :: #{{key(), lease()} => reference()},
                loading  = #{} :: #{reference() => token()}}).

%%% ----------------------------------------------------------------- api ---

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "Create the slot table. Called by the supervisor, before the manager.".
-spec ensure_table() -> ok.
ensure_table() ->
    case ets:info(?TAB, name) of
        undefined ->
            ?TAB = ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]),
            [true = ets:insert(?TAB, {N, 0, free, #{}}) || N <- ?NAMES],
            ok;
        _ -> ok
    end,
    case ets:info(?CALLS, name) of
        undefined ->
            ?CALLS = ets:new(?CALLS, [named_table, public, set,
                                      {write_concurrency, true}]),
            ok;
        _ -> ok
    end,
    ensure_counters().

%% Separate from the table's own guard: the counters are a different resource
%% and a table that already exists says nothing about whether they do.
ensure_counters() ->
    case persistent_term:get(?PT_COUNTERS, undefined) of
        undefined ->
            persistent_term:put(?PT_COUNTERS,
                                atomics:new(length(?NAMES), [{signed, false}]));
        _ -> ok
    end,
    ok.

counters() -> persistent_term:get(?PT_COUNTERS).

-doc """
Reserve a slot for `Key`, held by `Lease` on behalf of `Owner`.

Four answers, and they are four situations rather than two:

- `{compile, Name, Token}` — the slot is yours, empty, and held exclusively
  until you `publish/1` or `abort/1`. Nothing can enter it meanwhile.
- `{resident, Name}` — already loaded. A lease was added; nothing was reloaded.
- `loading` — somebody else is filling this key in. **Interpret.** Waiting on
  another process's compilation is a latency hazard and interpreting is always
  correct.
- `{error, no_slot}` — every slot is held. Interpret.

`Owner` is monitored for the duration of the reservation as well as for the
lease, so a compiler that dies does not hold the slot for ever.
""".
-spec claim_loading(key(), lease(), pid()) ->
          {compile, module(), token()} | {resident, module()}
        | loading | {error, no_slot}.
claim_loading(Key, Lease, Owner) ->
    gen_server:call(?MODULE, {claim_loading, Key, Lease, Owner}).

-doc """
Finish a reservation, after `code:load_binary/3` has succeeded.

Answers `stale` when the slot has moved on to a later reservation, which is what
the generation in the token is for: a compiler slow enough to be overtaken must
not publish over whatever took its place.
""".
-spec publish(token()) -> ok | stale.
publish(Token) -> gen_server:call(?MODULE, {publish, Token}).

-doc "Give up a reservation. The slot goes back to the pool.".
-spec abort(token()) -> ok.
abort(Token) -> gen_server:call(?MODULE, {abort, Token}).

-doc "Another lease on a slot already claimed for `Key`.".
-spec lease(key(), lease(), pid()) -> ok | {error, not_resident}.
lease(Key, Lease, Owner) -> gen_server:call(?MODULE, {lease, Key, Lease, Owner}).

-doc """
Give up one lease. The slot becomes reusable when the last one goes, and not
before: an instance lease released while a call is still running leaves the
code exactly where it is.
""".
-spec release(key(), lease()) -> ok.
release(Key, Lease) -> gen_server:call(?MODULE, {release, Key, Lease}).

-doc """
Take a call lease on a slot, by the module name `claim/3` answered with.

This is the one on the call path, so it is an `atomics` increment and not a
message: about 20 ns against the 5.8 us a manager round trip costs. It names
the *slot* rather than the key, because "do not replace this code while I am
inside it" is a property of the slot.

Answers `stale` rather than waiting when the slot is held exclusively, which is
a reservation in progress. Interpret in that case.

Pair it with `release_call/1` under `try ... after`, so a throw still gives it
back. A process killed outright leaves the count raised and that slot is then
never reused, which costs speed and never safety: a caller who cannot get a
slot interprets instead, which is what this module is built to do.
""".
-spec lease_call(module()) -> ok | stale.
lease_call(Name) -> take(counters(), slot_index(Name)).

-doc """
Take a call lease and check that the slot still holds the code you meant.

The counter protects the *slot*; it says nothing about which module is in it.
A caller that remembered a name can be overtaken by a reuse between remembering
and leasing, and would then run somebody else's code. This takes the lease
first, so nothing can change underneath the check, and gives it back if the
answer is no.
""".
-spec lease_call(module(), key()) -> {ok, non_neg_integer()} | stale.
lease_call(Name, Key) ->
    Ref = counters(),
    Idx = slot_index(Name),
    case take(Ref, Idx) of
        stale -> stale;
        ok ->
            case row(Name) of
                {Gen, {resident, Key}} -> {ok, Gen};
                _ -> atomics:sub(Ref, Idx, 1), stale
            end
    end.

%% The generation as well as the state. The generation is what generated code
%% is built against, so a caller has to hand it on: see `wasm_core:module/6`.
row(Name) ->
    case ets:lookup(?TAB, Name) of
        [{_N, Gen, St, _L}] -> {Gen, St};
        [] -> undefined
    end.

%% Never waits. The exclusive hold used to last one `code:soft_purge/1' and
%% spinning on it terminated; a *reservation* holds it for as long as a
%% compilation takes, and blocking a call on somebody else's compilation is a
%% latency hazard. So a caller that cannot get in is told so and interprets,
%% which is what this module exists to make possible.
take(Ref, Idx) ->
    case atomics:add_get(Ref, Idx, 1) >= ?EXCL of
        false -> ok;
        true -> atomics:sub(Ref, Idx, 1), stale
    end.

-doc """
The counter and index a slot's call lease uses, resolved once.

`lease_call/2` looks both up on every call, and so does `release_call/1`: a
`persistent_term:get` and a name-to-index dispatch, four times across a call
that may be a few hundred nanoseconds. They are fixed for the life of a slot
name, so a caller that will enter the same code repeatedly resolves them once
and uses `lease_at/2` and `release_at/2`.
""".
-spec lease_ref(module()) -> {atomics:atomics_ref(), pos_integer()}.
lease_ref(Name) -> {counters(), slot_index(Name)}.

-doc """
Take a call lease on an already-resolved slot.

The same counter `lease_call/2` takes, without the row lookup that checks which
key the slot holds. That check is for a caller which remembered a slot and was
overtaken by a reuse, and it is not the only thing standing in the way: generated
code refuses a caller whose stamp is not the one it was built for. A caller whose
stamp is the module's own content hash therefore does not need the row, because
another module's code cannot match that hash. A caller identified by a
`reference()` has no stamp but the slot generation, which only the row can give,
and keeps using `lease_call/2`.
""".
-spec lease_at(atomics:atomics_ref(), pos_integer()) -> ok | stale.
lease_at(Ref, Idx) -> take(Ref, Idx).

-doc "Give back a lease taken with `lease_at/2`.".
-spec release_at(atomics:atomics_ref(), pos_integer()) -> ok.
release_at(Ref, Idx) -> atomics:sub(Ref, Idx, 1).

-doc "Give back a call lease.".
-spec release_call(module()) -> ok.
release_call(Name) ->
    atomics:sub(counters(), slot_index(Name), 1).

%% Written out rather than derived, for the same reason `?NAMES' is: this
%% module's whole safety argument is that you can read what it does with atoms.
%% `wasm_code_slots_SUITE' asserts these agree with `?NAMES', so the two cannot
%% drift.
slot_index('wasm_code_0') -> 1;
slot_index('wasm_code_1') -> 2;
slot_index('wasm_code_2') -> 3;
slot_index('wasm_code_3') -> 4;
slot_index('wasm_code_4') -> 5;
slot_index('wasm_code_5') -> 6;
slot_index('wasm_code_6') -> 7;
slot_index('wasm_code_7') -> 8;
slot_index('wasm_code_8') -> 9;
slot_index('wasm_code_9') -> 10;
slot_index('wasm_code_10') -> 11;
slot_index('wasm_code_11') -> 12;
slot_index('wasm_code_12') -> 13;
slot_index('wasm_code_13') -> 14;
slot_index('wasm_code_14') -> 15;
slot_index('wasm_code_15') -> 16.

-doc """
Count one call on a module, and say whether it has reached `After`.

Counts per module rather than per instance: a workload of short-lived instances
would otherwise never get hot. The row is dropped the moment the threshold is
reached, so this costs an `ets:update_counter/3` during warmup and nothing at
all afterwards, and the table does not grow with every module ever seen.
""".
-spec hot(key(), pos_integer()) -> boolean().
hot(Identity, After) ->
    case ets:update_counter(?CALLS, Identity, {2, 1}, {Identity, 0}) >= After of
        false -> false;
        true -> true = ets:delete(?CALLS, Identity), true
    end.

-doc "How many calls are inside a slot's code. For tests.".
-spec calls_in(module()) -> non_neg_integer().
calls_in(Name) -> atomics:get(counters(), slot_index(Name)).

-doc """
The module `Key` is resident in, as a select rather than a listing.

On the path every call takes when a module is hot and not yet adopted, so it is
a match spec the emulator runs over sixteen rows and not a term built for the
caller to filter. Asking the gen_server instead cost 320 microseconds a call on
a three-microsecond one.
""".
-spec resident_module(key()) -> {ok, module()} | error.
resident_module(Key) ->
    case ets:select(?TAB, [{{'$1', '_', {resident, Key}, '_'}, [], ['$1']}]) of
        [N] -> {ok, N};
        [] -> error
    end.

-doc """
The module `Key` is loaded into, without taking a lease.

Reading without claiming is the point: `wasm_jit:await/2` uses it to tell a
module that is still compiling from one that is ready, and claiming there would
take the free slot away from the compiler that is filling it.
""".
-spec lookup(key()) -> {ok, module()} | error.
lookup(Key) ->
    case [N || {N, _G, {resident, K}, _} <- ets:tab2list(?TAB), K =:= Key] of
        [N] -> {ok, N};
        [] -> error
    end.

-doc "Every slot name, in order. The complete set of atoms this module makes.".
-spec slots() -> [module()].
slots() -> ?NAMES.

-doc """
The module name in one slot, by index.

`lists:nth/2` over the name list is fine where a slot is resolved once per
invocation and not where it is resolved per call, which is what re-entry from
the interpreter made it. A tuple index instead, and the tuple is a literal.
""".
-spec slot_module(pos_integer()) -> module().
slot_module(Slot) -> element(Slot, ?NAME_TUPLE).

-doc "`{Name, Key, LeaseCount}` for every slot that holds something.".
-spec resident() -> [{module(), key(), non_neg_integer()}].
resident() ->
    [{N, K, map_size(L)} || {N, _G, {resident, K}, L} <- ets:tab2list(?TAB)].

%%% -------------------------------------------------------------- server ---

init([]) ->
    ok = ensure_table(),
    %% Rebuild the monitors from the table, so a restart does not lose track of
    %% who is holding what. The rows outlive this process by design.
    {Ms, Rs} = lists:foldl(
           fun({_N, _G, free, _}, Acc) -> Acc;
              ({_N, _G, St, Leases}, Acc) ->
                   K = element(2, St),
                   maps:fold(fun(L, Pid, {A, B}) when is_pid(Pid) ->
                                     Ref = erlang:monitor(process, Pid),
                                     {A#{Ref => {K, L}}, B#{{K, L} => Ref}};
                                (_, _, A) -> A
                             end, Acc, Leases)
           end, {#{}, #{}}, ets:tab2list(?TAB)),
    %% A reservation does not survive the manager. Its owner was monitored by
    %% the process that just died, so nothing would ever abort it, and the slot
    %% would stay exclusively held for the life of the node. Freeing them here
    %% is safe because nothing has been loaded into them yet, by definition.
    [begin
         true = ets:insert(?TAB, {N, G, free, #{}}),
         ok = release_hold(N)
     end || {N, G, {loading, _}, _} <- ets:tab2list(?TAB)],
    {ok, #state{monitors = Ms, refs = Rs}}.

handle_call({claim_loading, Key, Lease, Owner}, _From, S) ->
    case find(Key) of
        %% Somebody else is filling this in. Interpret rather than wait.
        {ok, {_N, _G, {loading, _}, _}} ->
            {reply, loading, S};
        {ok, {Name, Gen, {resident, _} = St, Leases}} ->
            {reply, {resident, Name}, add(Name, Gen, St, Leases, Lease, Owner, S)};
        error ->
            reserve(Key, Lease, Owner, S)
    end;

handle_call({publish, {Name, Gen} = Token}, _From, S) ->
    case ets:lookup(?TAB, Name) of
        [{Name, Gen, {loading, Key}, Leases}] ->
            true = ets:insert(?TAB, {Name, Gen, {resident, Key}, Leases}),
            %% Only now. Until this line the code is not there, and a call lease
            %% taken before it would be a lease on the previous occupant.
            ok = release_hold(Name),
            {reply, ok, unwatch(Token, S)};
        _ ->
            {reply, stale, S}
    end;

handle_call({abort, {Name, Gen} = Token}, _From, S) ->
    case ets:lookup(?TAB, Name) of
        [{Name, Gen, {loading, Key}, Leases}] ->
            S1 = lists:foldl(fun(L, A) -> unmonitor(Key, L, A) end,
                             S, maps:keys(Leases)),
            true = ets:insert(?TAB, {Name, Gen, free, #{}}),
            ok = release_hold(Name),
            {reply, ok, unwatch(Token, S1)};
        _ ->
            {reply, ok, S}
    end;

handle_call({lease, Key, Lease, Owner}, _From, S) ->
    case find(Key) of
        {ok, {Name, Gen, {resident, _} = St, Leases}} ->
            {reply, ok, add(Name, Gen, St, Leases, Lease, Owner, S)};
        _ -> {reply, {error, not_resident}, S}
    end;

handle_call({release, Key, Lease}, _From, S) ->
    {reply, ok, drop(Key, Lease, S)};

handle_call(_Req, _From, S) -> {reply, {error, unknown}, S}.

%% Take a free slot and hold it exclusively until the caller publishes or
%% aborts. `free_slot/1' leaves the counter at `?EXCL', and it stays there: that
%% is the whole difference from the old `claim/3', which released it before the
%% binary existed.
reserve(Key, Lease, Owner, #state{loading = Ls} = S) ->
    case free_slot(Key) of
        {ok, Name} ->
            [{Name, Gen0, _, _}] = ets:lookup(?TAB, Name),
            Gen = Gen0 + 1,
            true = ets:insert(?TAB, {Name, Gen, {loading, Key}, #{}}),
            S1 = add(Name, Gen, {loading, Key}, #{}, Lease, Owner, S),
            Ref = erlang:monitor(process, Owner),
            Token = {Name, Gen},
            {reply, {compile, Name, Token},
             S1#state{loading = Ls#{Ref => Token}}};
        error ->
            %% Interpret it. Every alternative is worse.
            {reply, {error, no_slot}, S}
    end.

unwatch(Token, #state{loading = Ls} = S) ->
    case [R || {R, T} <- maps:to_list(Ls), T =:= Token] of
        [Ref] ->
            _ = erlang:demonitor(Ref, [flush]),
            S#state{loading = maps:remove(Ref, Ls)};
        [] -> S
    end.

handle_cast(_Msg, S) -> {noreply, S}.

%% A holder that dies gives its lease back. An instance whose owner is killed
%% mid-call still has the call's lease, held by whichever process is running
%% it, so the code survives exactly as long as something is inside it.
handle_info({'DOWN', Ref, process, _Pid, _Reason},
            #state{monitors = Ms, loading = Ls} = S) ->
    case maps:find(Ref, Ls) of
        %% A compiler that died. Its reservation holds the slot exclusively and
        %% nothing else will ever give it back.
        {ok, Token} ->
            {reply, ok, S1} = handle_call({abort, Token}, self(), S),
            {noreply, S1#state{loading = maps:remove(Ref, Ls)}};
        error ->
            case maps:find(Ref, Ms) of
                %% `drop/3' clears both indexes, so the reference does not need
                %% taking out here as well.
                {ok, {Key, Lease}} -> {noreply, drop(Key, Lease, S)};
                error -> {noreply, S}
            end
    end;
handle_info(_Info, S) -> {noreply, S}.

%%% ------------------------------------------------------------- internal ---

%% Both a loading and a resident slot answer, because a caller arriving while
%% somebody else is filling one in has to be told to interpret rather than being
%% handed a name whose code is not there yet.
find(Key) ->
    case [{N, G, St, L} || {N, G, St, L} <- ets:tab2list(?TAB),
                           St =:= {loading, Key} orelse St =:= {resident, Key}] of
        [Row] -> {ok, Row};
        [] -> error
    end.

%% A slot is free if it holds nothing, or if it holds something nobody is using
%% *and* the old code can be dropped without killing a process. `soft_purge/1`
%% answering false means a lease was released while a call was still inside,
%% which is a bug in the caller; refusing the slot turns that bug into slower
%% code rather than a killed process.
%% A slot is a candidate when nothing holds it, and is only actually taken once
%% its call counter has been raised to `?EXCL' from zero. The counter is what
%% makes this safe against a call lease taken between the two, because that
%% lease is an increment on the same word: either it gets in first and the
%% exchange fails, or the exchange gets in first and the lease backs out.
%%
%% The slot stays held until `release_hold/1', which the claim runs after the
%% row is written, so nothing can enter code that is still being replaced.
free_slot(Key) ->
    Empty = [N || {N, _G, St, L} <- ets:tab2list(?TAB),
                  St =:= free orelse
                  (map_size(L) =:= 0 andalso element(1, St) =:= resident)],
    reusable(prefer(Key, Empty)).

%% A module's own slot first.
%%
%% A compiled artifact carries its module name in its BEAM file, so a cached one
%% is only usable in the slot it was built for. Giving every module a home slot
%% derived from its key makes the cache hit across restarts instead of depending
%% on which slot happened to be free. It is a preference and never a
%% requirement: any free slot will do, and this only decides the order.
prefer(Key, Empty) ->
    Home = lists:nth(erlang:phash2(Key, length(?NAMES)) + 1, ?NAMES),
    case lists:member(Home, Empty) of
        true -> [Home | Empty -- [Home]];
        false -> Empty
    end.

reusable([]) -> error;
reusable([N | Rest]) ->
    case take_exclusive(N) of
        ok ->
            case purgeable(N) of
                true -> {ok, N};
                false -> ok = release_hold(N), reusable(Rest)
            end;
        error -> reusable(Rest)
    end.

%% Raise the counter to the exclusive hold: from zero when every call lease was
%% given back, and from whatever is stuck there when one was not.
%%
%% A lease is released in an `after`, and an `after` does not run when a process
%% is killed untrappably. `exit(Pid, kill)` is how an embedder stops a runaway
%% invocation on this runtime, so leaked leases are ordinary rather than a
%% caller bug. Without this, sixteen killed callers pin every slot and nothing
%% is ever compiled again for the life of the node.
%%
%% Repairing it is only sound because the counter no longer carries
%% correctness. It used to be the only thing stopping a caller that had chosen a
%% slot from entering it after somebody else refilled it, and `code:soft_purge/1`
%% cannot see that caller: between `lease_call/2` and `Mod:invoke/6` the process
%% holds a lease and is not yet in the code. What stops it now is that generated
%% code checks the generation it was built for against the one the caller was
%% promised, which is atomic with the call in a way no lease can be. A caller
%% that loses this race is told `stale` by the callee and interprets.
take_exclusive(N) ->
    Ix = slot_index(N),
    case atomics:compare_exchange(counters(), Ix, 0, ?EXCL) of
        ok -> ok;
        Stuck when Stuck > 0, Stuck < ?EXCL -> repair(N, Ix, Stuck);
        %% Already exclusively held. Not this slot.
        _ -> error
    end.

repair(N, Ix, Stuck) ->
    case purgeable(N) of
        false -> error;
        true ->
            case atomics:compare_exchange(counters(), Ix, Stuck, ?EXCL) of
                ok -> ok;
                _ -> error
            end
    end.

purgeable(N) ->
    case code:is_loaded(N) of
        false -> true;
        {file, _} -> code:soft_purge(N)
    end.

release_hold(N) ->
    atomics:sub(counters(), slot_index(N), ?EXCL).

add(Name, Gen, St, Leases, Lease, Owner, #state{monitors = Ms, refs = Rs} = S) ->
    Key = element(2, St),
    case maps:is_key(Lease, Leases) of
        true ->
            true = ets:insert(?TAB, {Name, Gen, St, Leases}),
            S;
        false ->
            Ref = erlang:monitor(process, Owner),
            true = ets:insert(?TAB, {Name, Gen, St, Leases#{Lease => Owner}}),
            S#state{monitors = Ms#{Ref => {Key, Lease}},
                    refs = Rs#{{Key, Lease} => Ref}}
    end.

drop(Key, Lease, S) ->
    S1 = unmonitor(Key, Lease, S),
    case find(Key) of
        error -> S1;
        {ok, {Name, Gen, St, Leases}} ->
            Left = maps:remove(Lease, Leases),
            %% The key stays on the slot with no leases. Claiming it again is
            %% then a hit rather than a reload, and the slot is still available
            %% to anything that needs one.
            true = ets:insert(?TAB, {Name, Gen, St, Left}),
            S1
    end.

%% `flush' because the holder may have died between the release and here, in
%% which case a `DOWN' is already in the mailbox naming a lease that is gone.
unmonitor(Key, Lease, #state{monitors = Ms, refs = Rs} = S) ->
    case maps:take({Key, Lease}, Rs) of
        error -> S;
        {Ref, Rs1} ->
            _ = erlang:demonitor(Ref, [flush]),
            S#state{monitors = maps:remove(Ref, Ms), refs = Rs1}
    end.
