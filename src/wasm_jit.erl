-module(wasm_jit).
-moduledoc """
When a module gets compiled, and how a call reaches the result.

You get here from `wasm`, on the path an invocation takes. Everything here is a policy
decision on top of two mechanisms that already exist: `wasm_core` generates and
compiles, and `wasm_code_slots` decides which module name the result may be
loaded into and when that name may be reused.

## Off by default

Compiled code is opt-in, `#{compile => true}` in an instance's limits, the way
`fuse => false` already works. Turning it on by default is a separate decision
with its own gates: differential trap and side-effect tests, an enforced
compile-time and code-size limit, and a scheduler-responsiveness measurement
while a generated loop runs.

## Every failure interprets

A module the generator refuses, a slot pool that is exhausted, another process
already compiling the same module, a finite fuel budget, a compile error: all
of them mean run the interpreter, and none of them is an error. That is what
makes the tier safe to enable at all, and it is also what makes a green test
run prove nothing on its own -- see `counts/0` and the `compile_force` option,
which exist so that a conformance run can say generated code actually ran.

## Fuel

Fuel is charged at every loop back edge, and threading a budget through a
compiled loop gives back what compiling it bought. So an invocation with finite
fuel is interpreted, checked once here rather than in the generated code.

## Three options for a conformance run, and none for production

The defaults are what an embedder wants: compile in the background, compile
only what ran, and interpret anything the generator could not handle. Each of
those is exactly wrong for a test that means to check generated code, because
each of them lets the test pass without any generated code having run.

| Option | Default | What it changes |
| --- | --- | --- |
| `compile_sync` | `false` | Compile on the calling process, so the next call is already compiled rather than probably compiled. |
| `compile_whole` | `false` | Compile every eligible function, not only the ones that have run. |
| `compile_force` | `false` | Raise on a compile error instead of interpreting, so a generator bug fails rather than hides. |

`compile_whole` in particular is a conformance option and not a tuning knob.
Compiling every function of QuickJS is 74 seconds against about 8 for the hot
set, and it spends most of fifteen megabytes of code space on functions the
workload never calls. Specification modules are a few functions each, which is
why it is affordable there and nowhere else.

`wasm_spec_SUITE`'s compiled phase sets all three, and then asserts `counts/0`
moved, because even with all three a refusal still interprets.
""".

-export([entry/3, after_call/2, counts/0, reset_counts/0, await/2, release/1]).
-export([reentered/0]).
-export([compiler_loop/0]).
-export([dump/1, dump/2]).

-include("wasm.hrl").
-include("wasm_exec.hrl").

%% Bumped whenever the shape of generated code changes, so that code compiled by
%% an older version of this runtime is never entered by a newer one.
-define(ABI, 3).

-define(DEFAULT_AFTER, 32).

%% Splitting a compile across units. The unit is what `compile:forms/2` is
%% handed, and that call is 99.3% of the cost, so several of them run at once
%% where one cannot. Sized in words of lowered IR because generated code is
%% linear in that: 11 to 19 bytes of BEAM per word, near enough constant.
%%
%% The floor exists because a split is not free -- it takes a slot per unit out
%% of a pool of sixteen that the whole node shares -- and a module that compiles
%% in a second is not the problem. QuickJS's hot set is about 900,000 words.
-define(SHARD_WORDS, 150000).
-define(MAX_SHARDS, 4).
%% Set by `entry_1/3` when this call found the module hot and unbuilt, read by
%% `after_call/2` once the call has finished. The invocation's own lifetime is
%% exactly the right one for it, which is the same argument the checkpoint key
%% makes for living here.
-define(ASK, wasm_jit_ask).

-define(PT_COUNTS, {?MODULE, counts}).
-define(IX_COMPILED, 1).      % functions compiled
-define(IX_ENTERED, 2).       % invocations that entered generated code
-define(IX_REENTERED, 3).     % calls the interpreter made into generated code
-define(IX_CACHED, 4).        % compilations answered from the on-disk cache

%%% ------------------------------------------------------------------ api ---

-doc """
The entry to run this invocation through: generated code, or the one given.

Called once per outermost invocation. Everything it can answer cheaply it
answers first -- the tier being off, or fuel being finite -- so a workload that
does not use this pays one map lookup.
""".
-spec entry(#inst{}, map(), fun()) -> fun().
entry(Inst, Limits, Entry) ->
    case maps:get(compile, Limits, false) andalso
         maps:get(fuel, Limits, infinity) =:= infinity of
        false -> Entry;
        true -> entry_1(Inst, Limits, Entry)
    end.

-doc """
Called once at the end of an outermost invocation, to decide about compiling.

At the *end*, and that is the whole point. Which functions a workload runs is
recorded for free by the lowering cache, and at the start of a call that record
is empty: an instance asking then compiles all 1666 of QuickJS's functions
because it cannot yet know that 223 of them is the answer. Asking here, when the
invocation has finished and the record is full, is the difference between
compiling what exists and compiling what ran.

Adopting a module somebody else compiled happens here too, so `entry/3` on the
hot path is one `atomics` read and nothing else.
""".
-spec after_call(#inst{}, map()) -> ok.
after_call(Inst, Limits) ->
    case erase(?ASK) of
        undefined -> ok;
        true -> ask(Inst, Limits)
    end.

entry_1(Inst, Limits, Entry) ->
    case wasm_instance:code_slot(Inst) of
        undefined -> maybe_adopt(Inst, Limits, Entry);
        Slot -> cached_entry(Inst, Slot, Entry)
    end.

%% The compiled entry, built once per instance rather than once per call.
%%
%% `compiled/3` walks the slot list for the module name, builds the slot key,
%% resolves the lease counter and allocates a closure, and every one of those is
%% fixed for as long as this instance keeps this slot. They were paid on every
%% call: the closure alone measured 24.8 nanoseconds of a 373 nanosecond call,
%% and the counter and index lookups another chunk of the lease's 108.
%%
%% Keyed by a bare `reference()` the instance carries, for the reason
%% `#inst.ckpt` is one: a tuple key has to be built and hashed each time and
%% costs more than what it keys. `code_slot/1` is one `atomics:get`, so noticing
%% that the slot changed is cheaper than rebuilding.
%%
%% `Entry` is in the key because there are two of them: `wasm_exec:call/5` lets
%% an escaping exception through and `call_toplevel/5` converts it, and handing
%% back the wrong one would change what a trap does.
cached_entry(#inst{entry_key = K} = Inst, Slot, Entry) when K =/= undefined ->
    case get(K) of
        {Slot, Entry, Fun} -> Fun;
        %% First time this process caches anything under this key, so the id it
        %% belongs to is recorded: nothing else can tell a bare reference from
        %% any other dictionary key, and without that the sweep that drops a
        %% destroyed instance's caches leaves this one behind for ever.
        undefined -> fresh(Inst, Slot, Entry, K, note);
        _ -> fresh(Inst, Slot, Entry, K, known)
    end;
cached_entry(Inst, Slot, Entry) ->
    compiled(Inst, Slot, Entry).

fresh(#inst{id = Id} = Inst, Slot, Entry, Key, Seen) ->
    Fun = compiled(Inst, Slot, Entry),
    Seen =:= note andalso wasm_instance:note_entry(Id, Key),
    put(Key, {Slot, Entry, Fun}),
    Fun.

%% Adopting happens here and asking happens at the end of the call, and the
%% split is the point.
%%
%% Adopting is a lease and a compare-exchange against a module somebody already
%% compiled, and an instance that waited until the end of its first call to do
%% it would interpret that call for nothing -- which for a workload of one call
%% per instance means interpreting always. Asking cannot happen here, because
%% what to compile is read from what this process has run and at the start of a
%% call it has run nothing.
maybe_adopt(Inst, Limits, Entry) ->
    After = maps:get(compile_after, Limits, ?DEFAULT_AFTER),
    case wasm_code_slots:hot(key(Inst), After) of
        false -> Entry;
        true ->
            %% Read first, claim second. `claim_loading/3` is a gen_server call
            %% and this runs on every hot call until the module arrives, which
            %% for `compile_after => 1` is every call: a claim-and-abort pair
            %% here cost 320 microseconds on a three-microsecond call.
            case wasm_code_slots:resident_module(key(Inst)) of
                {ok, _Mod} ->
                    case compile(Inst, Limits, [], adopt) of
                        {ok, Slot} -> compiled(Inst, Slot, Entry);
                        error -> Entry
                    end;
                %% Nothing to adopt. Ask once the call has finished and this
                %% process knows which functions it needed.
                error -> put(?ASK, true), Entry
            end
    end.

-doc """
Give back the slot lease this instance took, if it took one.

Called from `wasm:destroy/1` beside the memory, table and global releases, and
for the same reason: the lease names the *instance*, so it has to go when the
instance does. Until this existed it went only when the owning process died,
and a long-lived process serving many distinct modules pinned the slots one at
a time until the pool was gone and every later module interpreted for the life
of the node. `wasm_code_slots`'s moduledoc describes exactly this shape as the
usage it expects and nothing called it.

Idempotent, because `destroy/1` is: releasing a lease that is not there is a
no-op in `wasm_code_slots`, which is the same property that makes a double
release of a memory harmless.
""".
-spec release(#inst{}) -> ok.
release(Inst) ->
    ok = wasm_code_slots:release(key(Inst), {instance, Inst#inst.id}),
    each_shard(Inst, 2, fun(Key) ->
                            wasm_code_slots:release(Key, {instance, Inst#inst.id})
                        end).

-doc "How much has been compiled, and how often generated code was entered.".
-spec counts() -> #{atom() => non_neg_integer()}.
counts() ->
    R = counters(),
    #{compiled => atomics:get(R, ?IX_COMPILED),
      entered => atomics:get(R, ?IX_ENTERED),
      reentered => atomics:get(R, ?IX_REENTERED),
      cached => atomics:get(R, ?IX_CACHED)}.

-doc "For tests, which need to count what one run did rather than what a node did.".
-spec reset_counts() -> ok.
reset_counts() ->
    R = counters(),
    atomics:put(R, ?IX_COMPILED, 0),
    atomics:put(R, ?IX_ENTERED, 0),
    atomics:put(R, ?IX_REENTERED, 0),
    atomics:put(R, ?IX_CACHED, 0).

%%% -------------------------------------------------------------- entering ---

%% Two shapes, and which one applies is decided here rather than per call.
%%
%% A module identified by a content hash has a stamp that does not depend on the
%% slot generation, so its lease needs no row lookup: `lease_at/2` takes the
%% counter and nothing else, and generated code left by another module cannot
%% match this module's hash. That is the ordinary case, and it is every module
%% loaded from bytes.
%%
%% A module identified by a `reference()` -- one built from text, never cached
%% -- has no stamp but the generation, and only the row carries that. It keeps
%% `lease_call/2`, which checks the key as well as the slot: a caller that
%% remembered a slot can be overtaken by a reuse between remembering and
%% leasing, and would otherwise run somebody else's code.
compiled(Inst, Slot, Entry) ->
    Mod = wasm_code_slots:slot_module(Slot),
    {Ref, SIdx} = wasm_code_slots:lease_ref(Mod),
    case wasm_instance:identity(Inst) of
        {sha256, Hash} -> hashed_entry(Mod, Ref, SIdx, Hash, Entry);
        _ -> generational_entry(Inst, Mod, Entry)
    end.

hashed_entry(Mod, Ref, SIdx, Stamp, Entry) ->
    fun(I, Mut, Idx, Args, L) ->
        case wasm_code_slots:lease_at(Ref, SIdx) of
            stale -> Entry(I, Mut, Idx, Args, L);
            ok ->
                try Mod:invoke(I, Mut, Idx, Args, 0, Stamp) of
                    {error, not_compiled} ->
                        Entry(I, Mut, Idx, Args, L#{code_module => {Mod, Stamp}});
                    {error, stale} -> Entry(I, Mut, Idx, Args, L);
                    Result -> bump(?IX_ENTERED, 1), Result
                catch
                    Class:Reason:St ->
                        bump(?IX_ENTERED, 1),
                        erlang:raise(Class, Reason, St)
                after
                    wasm_code_slots:release_at(Ref, SIdx)
                end
        end
    end.

generational_entry(Inst, Mod, Entry) ->
    Key = key(Inst),
    fun(I, Mut, Idx, Args, L) ->
        case wasm_code_slots:lease_call(Mod, Key) of
            stale -> Entry(I, Mut, Idx, Args, L);
            {ok, Gen} ->
                %% Zero: this is the outermost invocation. The interpreter
                %% re-enters at its own depth, which is why generated code takes
                %% one at all. The stamp is what the callee refuses on if it is
                %% not the code this caller meant.
                Stamp = stamp(I, Gen),
                try Mod:invoke(I, Mut, Idx, Args, 0, Stamp) of
                    %% This function of the module was not compiled. Common, and
                    %% not a failure: most functions of a real module are
                    %% outside the subset. The interpreter it falls back to is
                    %% told the module name, so a compiled callee further down
                    %% is still reached; the lease this holds covers it.
                    {error, not_compiled} ->
                        Entry(I, Mut, Idx, Args, L#{code_module => {Mod, Stamp}});
                    %% The slot was refilled between reading it and calling.
                    %% Rare, and interpreting is the answer.
                    {error, stale} -> Entry(I, Mut, Idx, Args, L);
                    Result -> bump(?IX_ENTERED, 1), Result
                catch
                    %% A trap is an entry. The generated function ran and did
                    %% what the specification says it should, and it leaves by
                    %% throwing rather than returning, so counting only the
                    %% `of` clauses made `counts/0` report zero for a workload
                    %% that traps every time. That is the one workload a
                    %% differential test most wants to be sure ran compiled.
                    Class:Reason:St ->
                        bump(?IX_ENTERED, 1),
                        erlang:raise(Class, Reason, St)
                after
                    wasm_code_slots:release_call(Mod)
                end
        end
    end.

-doc """
Wait for this instance's module to finish compiling, or give up.

Compilation is asynchronous, so a caller that wants to measure compiled code, or
to warm an instance before serving with it, needs to know when it has arrived.
Answers `ok` as soon as the instance has adopted a slot.
""".
-spec await(#inst{}, timeout()) -> ok | timeout.
await(Inst, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    await_1(Inst, Deadline).

await_1(Inst, Deadline) ->
    case wasm_instance:code_slot(Inst) of
        undefined ->
            %% The compilation was asked for by whichever instance went hot
            %% first, and it adopts the slot for itself. Every other instance of
            %% the module picks it up on its own next hot call. Waiting has to
            %% do that adoption rather than watch for it, or an instance that
            %% never goes hot again waits for ever.
            %%
            %% `lookup/1` reads without claiming, which matters: claiming here
            %% would take a free slot away from the compiler that is filling it.
            case wasm_code_slots:lookup(key(Inst)) of
                {ok, _Mod} ->
                    case compile(Inst, #{}, [], adopt) of
                        {ok, _Slot} -> ok;
                        error -> retry(Inst, Deadline)
                    end;
                error -> retry(Inst, Deadline)
            end;
        _Slot -> ok
    end.

retry(Inst, Deadline) ->
    case erlang:monotonic_time(millisecond) < Deadline of
        false -> timeout;
        true -> timer:sleep(20), await_1(Inst, Deadline)
    end.

%%% ------------------------------------------------------------- compiling ---

%% Counted per module rather than per instance, or a workload of short-lived
%% instances never gets hot.
%% Compilation happens somewhere else, and this call interprets.
%%
%% A real module takes tens of seconds to compile, and doing that inside the
%% call that happened to be the hot one makes the tier a latency defect however
%% fast the code it produces. Interpreting is always correct, so the honest
%% answer to "this is hot" is to start the work and carry on.
%%
%% The process that does the work also *owns* the slot reservation, which is
%% what makes this safe: if it dies the reservation dies with it, and the
%% generation token in `publish/1` means a compiler slow enough to be overtaken
%% cannot publish over whatever replaced it. A caller could not own it, because
%% a caller returns long before the compile finishes and would take the
%% reservation with it.
%%
%% Nothing bounds the number of compilers except the sixteen slots, which is
%% the bound that matters: the seventeenth gets `no_slot` and interprets.
ask(Inst, Limits) ->
    case maps:get(compile_sync, Limits, false) of
        %% Synchronous compilation, for callers that would rather wait than
        %% measure something half compiled. The conformance suite is one.
        true ->
            _ = compile(Inst, Limits, wanted(Limits, Inst), generate),
            ok;
        false ->
            _ = wasm_instance:ask_compile(Inst) andalso spawn_compile(Inst, Limits),
            ok
    end.

%% Which functions to compile: the ones that ran, or all of them.
%%
%% `ran/1` already reads the empty list as "everything eligible", so asking for
%% the whole module is asking for that list. See `unit/2`.
wanted(Limits, Inst) ->
    case maps:get(compile_whole, Limits, false) of
        true -> [];
        false -> wasm_instance:executed(Inst)
    end.

spawn_compile(Inst, Limits) ->
    %% Read here rather than in the compiler, because the record of what has
    %% run lives in *this* process's dictionary and the compiler's is empty.
    Executed = wasm_instance:executed(Inst),
    case start_compiler() of
        {ok, Pid} ->
            %% Started empty and then told what to do: passing the instance as a
            %% start argument would copy it into the supervisor as well, and a
            %% real instance is 35 MB.
            Pid ! {compile, Inst, Limits, Executed},
            true;
        %% Every slot is already being filled, so there is nothing for a
        %% seventeenth compiler to publish into. Give the ask back and let the
        %% next hot call decide again.
        {error, _} ->
            wasm_instance:release_ask(Inst),
            true
    end.

%% One more compiler, unless there are already as many as there are slots.
%%
%% A soft bound, and deliberately: the hard one is the slots themselves, and a
%% compiler that cannot claim one gives up immediately. This exists so that the
%% seventeenth does not copy a 35 MB instance to find that out. Racy against
%% another caller starting one at the same moment, which costs one extra
%% compiler and nothing else.
start_compiler() ->
    Running = proplists:get_value(workers, supervisor:count_children(wasm_jit_sup)),
    case Running < length(wasm_code_slots:slots()) of
        false -> {error, busy};
        true -> supervisor:start_child(wasm_jit_sup, [])
    end.

-doc """
A compiler, waiting to be told what to compile. Started by `wasm_jit_sup`.

This process *owns* the slot reservation for as long as it holds one, which is
why the work happens here rather than in a long-lived pool worker: the slot is
released when its owner dies, and that is what makes a compiler that crashes or
is killed cost nothing but the work it had done.

The wait has a deadline for the same reason: a child whose sender died between
`start_child` and the message would otherwise sit in the tree for ever.
""".
-spec compiler_loop() -> ok.
compiler_loop() ->
    receive
        {compile, Inst, Limits, Executed} ->
            try compile(Inst, Limits, Executed, generate) of
                {ok, _Slot} -> ok;
                %% No slot free, or another process got there first. Give the
                %% ask back so this instance tries again when it next goes hot,
                %% rather than waiting out the retry interval.
                error -> wasm_instance:release_ask(Inst)
            catch
                %% A compile that fails must not leave the instance thinking it
                %% has one in flight. This does not cover being killed, which
                %% is what the ask expiring is for.
                _:_ -> wasm_instance:release_ask(Inst)
            end
    after 30000 ->
        ok
    end.

compile(Inst, Limits, Executed, Mode) ->
    Key = key(Inst),
    case wasm_code_slots:claim_loading(Key, {instance, Inst#inst.id}, self()) of
        {resident, Mod} ->
            %% The rest of the chain as well. Shard one is what `code_slot`
            %% names and what a call leases, but shard one *calls* the others,
            %% and a slot nobody holds can be taken while it is idle. Losing a
            %% later shard is not unsafe -- its replacement carries a different
            %% stamp and the chain gets `stale`, so the caller interprets -- but
            %% it is silent and permanent, because shard one is still resident
            %% and nothing asks for a recompile.
            ok = lease_rest(Inst, 2),
            adopt(Inst, Mod);
        %% Somebody else is compiling this module. Interpreting is always
        %% correct, and waiting on another process's compilation is not.
        loading -> error;
        {error, no_slot} -> error;
        %% Nothing resident and a slot is free. In `adopt` mode that is not what
        %% was wanted: give the slot straight back rather than generate on a
        %% caller's process, which is the whole thing this asynchrony exists to
        %% avoid. Claiming and aborting rather than reading first is what makes
        %% it race-free.
        {compile, _Mod, Token} when Mode =:= adopt ->
            ok = wasm_code_slots:abort(Token),
            error;
        {compile, Mod, Token} -> generate(Inst, Limits, Mod, Token, Executed)
    end.

generate(Inst, Limits, Mod, Token, Executed) ->
    case unit(Inst, Executed) of
        [] ->
            ok = wasm_code_slots:abort(Token),
            error;
        Unit ->
            %% `full` unless the caller asks for `baseline`, and this
            %% default has now moved three times. It is worth reading why,
            %% because the reason it moved back is not the reason it moved.
            %%
            %% It was `full`, then `baseline`, because the SSA optimiser bought
            %% *nothing*: QuickJS ran in 141.1 ms against 142.1, a tight
            %% arithmetic loop was 3.35 ns an iteration either way, and it cost
            %% 123.1 seconds against 54.8 to compile. That measurement was
            %% correct and is no longer true.
            %%
            %% What changed is the code handed to it. Since OTP 25 the JIT emits
            %% far better arithmetic when the compiler knows a value's range --
            %% an addition drops from ten instructions to four, a comparison
            %% from eleven to four -- and the range comes from the SSA type
            %% pass, which is exactly what `no_ssa_opt` turns off. The generator
            %% used to state no ranges, so there was nothing for the pass to
            %% find and skipping it was free. It states them now, in the guards
            %% `wrap_sum/2`, `wrap_sum32/2` and `decode_word/2` are written as,
            %% and QuickJS is **75.0 to 76.8 ms at `full` against 86.1 to 87.7
            %% at `baseline`**.
            %%
            %% It still costs 129.3 seconds against 58.1 to compile the hot set,
            %% and that is what `compile_shards` is for.
            Mode = maps:get(compile_quality, Limits, full),
            {_Name, Gen} = Token,
            Stamp = stamp(Inst, Gen),
            build(Inst, Limits, Mode, Stamp, Unit, split(Unit, Limits),
                  [{Mod, Token}])
    end.

%% One unit or several, and the difference is only how many slots are held.
%%
%% Splitting exists for wall clock and nothing else: 99.3% of a compile is
%% `compile:forms/2`, the units are independent BEAM modules, and this box has
%% fourteen cores. It does not reduce the work and it does not let anything be
%% used sooner, because the functions worth compiling are the ones expensive to
%% compile: sixteen of QuickJS's hot functions are already 30 seconds of the 54.
%% See `test/audit/PERF.md`.
build(Inst, Limits, Mode, Stamp, Unit, [_], [{Mod, Token}]) ->
    case artifact(Inst, Mod, Unit, Mode, Stamp, undefined, Mod, #{}) of
        {ok, Bin} ->
            {module, Mod} = code:load_binary(Mod, "wasm_generated", Bin),
            ok = wasm_code_slots:publish(Token),
            bump(?IX_COMPILED, length(Unit)),
            adopt(Inst, Mod);
        {error, Reason} ->
            ok = wasm_code_slots:abort(Token),
            forced(Limits) andalso erlang:error({compile_failed, Reason}),
            error
    end;
build(Inst, Limits, Mode, Stamp, _Unit, Parts, [First]) ->
    %% Every slot claimed before anything is generated, because each unit names
    %% the next as a literal and cannot be built until that name exists. This
    %% process owns all of them, so a compiler that dies takes every reservation
    %% with it rather than stranding the ones it had not published yet.
    case claim_rest(Inst, length(Parts) - 1, [First]) of
        {error, Held} ->
            _ = [wasm_code_slots:abort(T) || {_, T} <- Held],
            error;
        Tokens ->
            Mods = [M || {M, _} <- Tokens],
            Head = hd(Mods),
            %% Which unit holds each function, so a call between them is a call
            %% and not a crossing. Known here because the split happens before
            %% anything is generated.
            Where = maps:from_list(
                      [{Idx, M} || {P, M} <- lists:zip(Parts, Mods),
                                   {_, Idx, _, _} <- P]),
            Jobs = lists:zip3(Parts, Mods, tl(Mods) ++ [undefined]),
            Bins = pmap(fun({U, M, Next}) ->
                            Mine = [Idx || {_, Idx, _, _} <- U],
                            artifact(Inst, M, U, Mode, Stamp, Next, Head,
                                     maps:without(Mine, Where))
                        end, Jobs),
            publish_all(Inst, Limits, Tokens, Parts, Bins)
    end.

%% All or nothing. A chain with a hole in it would answer `not_compiled` for
%% every function past the hole, which is correct but is most of the work thrown
%% away, and the slots would be held for it.
publish_all(Inst, Limits, Tokens, Parts, Bins) ->
    case [R || {error, _} = R <- Bins] of
        [{error, Reason} | _] ->
            _ = [wasm_code_slots:abort(T) || {_, T} <- Tokens],
            forced(Limits) andalso erlang:error({compile_failed, Reason}),
            error;
        [] ->
            %% Every module loaded before any of them is published, and the two
            %% must not be interleaved.
            %%
            %% Publishing shard one is what makes the whole chain adoptable:
            %% `await/2` returns on it and the next instance calls straight into
            %% it. If the rest is still being loaded at that moment, the chain
            %% reaches a module that does not exist yet and generated code
            %% raises `undef`, which arrives as an internal error on somebody
            %% else's first call. That is exactly what happened, and only off
            %% the calling process, because nothing else was racing the loop.
            _ = [{module, M} = code:load_binary(M, "wasm_generated", B)
                 || {{M, _}, {ok, B}} <- lists:zip(Tokens, Bins)],
            _ = [ok = wasm_code_slots:publish(T) || {_, T} <- Tokens],
            bump(?IX_COMPILED, lists:sum([length(P) || P <- Parts])),
            adopt(Inst, element(1, hd(Tokens)))
    end.

%% Balanced by IR words, largest first into the lightest unit so far.
%%
%% Not by function count: one QuickJS function is 98,191 words and 8.4 seconds
%% on its own, and an even count would put it with fifty others and leave the
%% other units idle. Longest-processing-time-first is the standard answer and
%% the critical path here is one function whatever the split, so it is close to
%% the best available.
split(Unit, Limits) ->
    Sized = [{erts_debug:flat_size(IR), U} || {_, _, _, IR} = U <- Unit],
    case shards(lists:sum([W || {W, _} <- Sized]), Limits) of
        1 -> [Unit];
        N -> renumber(bins(lists:reverse(lists:sort(Sized)), empty_bins(N)))
    end.

%% `auto` is one, which is to say splitting is off unless you ask for it.
%%
%% It works, and what it buys and costs are both measured. QuickJS's
%% 223-function hot set, background compiler, at the `full` quality that is now
%% the default:
%%
%% | | compile | warm `_start` |
%% | --- | ---: | ---: |
%% | one unit | 129.3 s | 76.5 ms |
%% | four units | **33.2 s** | **93.3 ms** |
%%
%% **3.9x faster to compile and about 22% slower to run.** The second half is a
%% call between units going through `wasm_exec:shard_call/8` where a call within
%% one is a local `apply`; it was 1.5x until those calls stopped going out
%% through the interpreter and back in through the head of the chain.
%%
%% The default is one unit anyway, because the trade depends on something this
%% module cannot know: ninety-six seconds saved against seventeen milliseconds a
%% run is about five thousand six hundred invocations to break even. A worker
%% that serves a module for a day should not split; something that compiles a
%% module to run it a few times should. So it is `compile_shards`, and it is the
%% embedder's call.
shards(Words, Limits) ->
    case maps:get(compile_shards, Limits, auto) of
        auto -> auto_shards(Words);
        N when is_integer(N), N >= 1 -> erlang:min(?MAX_SHARDS, N)
    end.

auto_shards(_Words) -> 1.

empty_bins(N) -> [{0, []} || _ <- lists:seq(1, N)].

bins([], Bins) ->
    [lists:reverse(Us) || {_, Us} <- Bins, Us =/= []];
bins([{W, U} | Rest], Bins) ->
    [{Load, Us} | Others] = lists:sort(Bins),
    bins(Rest, [{Load + W, [U | Us]} | Others]).

%% `wasm_core` names functions by position in the unit, so each unit needs a
%% dense range of its own.
renumber(Parts) ->
    [[{Pos, Idx, F, IR} || {Pos, {_, Idx, F, IR}} <- lists:enumerate(0, P)]
     || P <- Parts].

%% Shard one keeps the module's own key, so `maybe_adopt/3` finds a compiled
%% module by asking the same question it always did.
shard_key(Inst, N) -> {wasm_instance:identity(Inst), ?ABI, N}.

%% Take an instance lease on shards two and up, stopping at the first gap: the
%% chain is contiguous by construction, so a gap means there is nothing further.
lease_rest(Inst, N) ->
    each_shard(Inst, N, fun(Key) -> lease_one(Inst, Key) end).

lease_one(Inst, Key) ->
    case wasm_code_slots:claim_loading(Key, {instance, Inst#inst.id}, self()) of
        {resident, _} ->
            ok;
        %% Nothing there. Reading first would race; claiming and giving it
        %% straight back is what `maybe_adopt/3` does for the same reason.
        {compile, _, Token} ->
            ok = wasm_code_slots:abort(Token),
            stop;
        _ ->
            stop
    end.

each_shard(_Inst, N, _F) when N > ?MAX_SHARDS ->
    ok;
each_shard(Inst, N, F) ->
    case F(shard_key(Inst, N)) of
        stop -> ok;
        _ -> each_shard(Inst, N + 1, F)
    end.

claim_rest(_Inst, 0, Acc) ->
    lists:reverse(Acc);
claim_rest(Inst, N, Acc) ->
    case wasm_code_slots:claim_loading(shard_key(Inst, length(Acc) + 1),
                                       {instance, Inst#inst.id}, self()) of
        {compile, Mod, Token} -> claim_rest(Inst, N - 1, [{Mod, Token} | Acc]);
        %% No slot, or somebody else holds this shard's key. Give back what this
        %% call took and compile as one unit next time round.
        _ -> {error, Acc}
    end.

%% Run the units at once. `compile:forms/2` is the whole of the cost and the
%% units share nothing, so this is the wall clock the split is for.
pmap(F, Xs) ->
    Parent = self(),
    Pids = [element(1, spawn_monitor(fun() -> Parent ! {self(), F(X)} end))
            || X <- Xs],
    [collect(P) || P <- Pids].

collect(Pid) ->
    receive
        {Pid, R} -> receive {'DOWN', _, process, Pid, _} -> R after 5000 -> R end;
        {'DOWN', _, process, Pid, Why} -> {error, {compiler_died, Why}}
    end.

%% The compiled module: from the cache when it is there, and compiled and kept
%% when it is not.
%%
%% Nothing about the artifact depends on which compilation produced it. That is
%% what the stamp change bought: generated code is built for the module's content
%% hash rather than for a slot generation, so yesterday's artifact answers for
%% today's instance. What it *does* depend on is the slot, because a module's
%% name is part of its BEAM file, which is why the slot is in the key and why
%% `wasm_code_slots` prefers a module's own slot when one is free.
artifact(Inst, Mod, Unit, Mode, Stamp, Next, Head, Elsewhere) ->
    %% Not cached when it is one of several. The key would have to carry which
    %% module the chain points at next, and a shard set is only reproducible if
    %% the same split falls out of the same workload, which nothing promises.
    Key = case Next of
              undefined ->
                  wasm_code_cache:key(wasm_instance:identity(Inst), ?ABI, Mod,
                                      Mode,
                                      [Idx || {_P, Idx, _F, _IR} <- Unit],
                                      Stamp);
              _ -> undefined
          end,
    case Key =/= undefined andalso wasm_code_cache:lookup(Key) of
        {ok, Bin} -> bump(?IX_CACHED, 1), {ok, Bin};
        _ ->
            case wasm_core:module(Mod, Unit, sigs(Inst), tsigs(Inst), Mode,
                                  Stamp, Next, Head, Elsewhere) of
                {ok, Bin} = Ok ->
                    Key =:= undefined orelse wasm_code_cache:store(Key, Bin),
                    Ok;
                Error -> Error
            end
    end.

%%% ------------------------------------------------------------ inspection ---

-doc """
The Core Erlang this instance's module would compile to, as text.

Read it when you have changed the generator and want to see what came out. A
differential test tells you a lowering is wrong; this tells you how. Nothing in
the tier depends on it and it compiles nothing: it builds the same unit
`generate/5` builds and stops one step earlier.

```erlang
{ok, I} = wasm:instantiate(M, #{}, #{}),
io:format("~s~n", [wasm_jit:dump(I)]).
```

Answers `{error, nothing_to_compile}` when the generator refuses every function
of the module, which is the same condition that makes the tier decline it.
""".
-spec dump(#inst{}) -> iodata() | {error, term()}.
dump(Inst) -> dump(Inst, all).

-doc """
As `dump/1`, for one function index.

Real modules are large and a maintainer is usually looking at one function.
`wasm_core` names functions by position in the unit rather than by module
index, so a whole-module dump means counting; this takes the index the module
uses.
""".
-spec dump(#inst{}, all | non_neg_integer()) -> iodata() | {error, term()}.
dump(Inst, Which) ->
    case [U || {_P, Idx, _F, _IR} = U <- unit(Inst, []),
               Which =:= all orelse Idx =:= Which] of
        [] -> {error, nothing_to_compile};
        Some ->
            %% Renumbered, because `unit/2` numbers by position and filtering
            %% one function out of the middle would leave a hole where
            %% `fun_name/1` expects a dense range.
            Unit = [{Pos, Idx, F, IR}
                    || {Pos, {_, Idx, F, IR}} <- lists:enumerate(0, Some)],
            %% Zero for the stamp: a dump is read, not entered, so there is no
            %% caller whose generation has to match.
            case wasm_core:forms(dump, Unit, sigs(Inst), tsigs(Inst), 0) of
                {ok, Core} -> core_pp:format(Core);
                {error, _} = E -> E
            end
    end.

%%% --------------------------------------------------------------- helpers ---

%% Every function of the instance, compiled or not, host or guest: a call has to
%% know how many operands to take and how many to put back whichever side it
%% lands on.
sigs(Inst) ->
    maps:from_list(
      [{Idx, sig(F)}
       || {Idx, F} <- lists:enumerate(0, tuple_to_list(Inst#inst.funcs))]).

%% An indirect call is typed by the type it names, not by any function, since
%% which function it reaches is not known until it runs.
tsigs(Inst) ->
    maps:from_list(
      [{Idx, S} || {Idx, T} <- lists:enumerate(0, tuple_to_list(Inst#inst.types)),
                   S <- [tsig(T)], S =/= undefined]).

%% The type table holds whichever shape the module put there, so both are
%% matched rather than one assumed: a struct or array type simply has no
%% signature and no indirect call can name it.
tsig(#functype{params = P, results = R}) -> {length(P), length(R)};
tsig(#subtype{body = #functype{params = P, results = R}}) -> {length(P), length(R)};
tsig(_) -> undefined.


sig(#fn{nparams = NP, nresults = NR}) -> {NP, NR};
sig(#hostfn{nparams = NP, nresults = NR}) -> {NP, NR}.

%% Every function the oracle accepts, numbered by position in the unit so that
%% names are drawn from the pool by how many are compiled and not by how many
%% the module has.
unit(Inst, Executed) ->
    Fns = [F || F <- tuple_to_list(Inst#inst.funcs), is_record(F, fn)],
    Ran = ran(Executed),
    Ok = [{F, wasm_instance:compiler_ir(F, Inst)} || F <- Fns, Ran(F#fn.idx)],
    Eligible = [{F, IR} || {F, IR} <- Ok,
                           element(1, wasm_core:can_compile(F, IR)) =:= ok],
    [{Pos, F#fn.idx, F, IR}
     || {Pos, {F, IR}} <- lists:enumerate(0, Eligible)].

%% Compile what ran, not what exists.
%%
%% QuickJS is 1666 functions and a workload reaches about 223 of them, so
%% compiling all of them is most of the time and most of the fifteen megabytes
%% spent on code nothing will execute. A function left out is not a correctness
%% question: `invoke/5` answers `not_compiled` and it is interpreted, and since
%% the boundary became two-way it can still call back into compiled code.
%%
%% One shot, and honestly so. A function that becomes hot after this runs is
%% never compiled, because there is only one slot per module and no mapping from
%% a function to a shard. That is the next change and it is not this one.
ran([]) -> fun(_) -> true end;
ran(Executed) ->
    Set = maps:from_keys(Executed, []),
    fun(Idx) -> is_map_key(Idx, Set) end.

%% Record the slot on the instance. The compare-exchange answers whether this
%% caller was the one that set it, and only that one takes the instance lease,
%% because two processes can reach a hot call together.
adopt(Inst, Mod) ->
    Slot = slot_of(Mod),
    case wasm_instance:set_code_slot(Inst, Slot) of
        true -> {ok, Slot};
        false -> {ok, wasm_instance:code_slot(Inst)}
    end.

slot_of(Mod) ->
    {Slot, _} = hd([X || {_, N} = X <- lists:enumerate(wasm_code_slots:slots()),
                         N =:= Mod]),
    Slot.

forced(Limits) -> maps:get(compile_force, Limits, false).

key(Inst) -> {wasm_instance:identity(Inst), ?ABI}.

%% What generated code is built for and what a caller must present to enter it.
%%
%% The content hash where the module has one, because that is stable across
%% loads and across nodes and so lets a compiled artifact be cached. The slot
%% generation otherwise: a module built from text is identified by a
%% `reference()`, which cannot be a literal in generated code, and is never
%% cached, so the generation is enough for it.
stamp(Inst, Gen) ->
    case wasm_instance:identity(Inst) of
        {sha256, Hash} -> Hash;
        _Ref -> Gen
    end.

%%% ------------------------------------------------------------- counters ---

bump(Ix, N) -> atomics:add(counters(), Ix, N).

-doc """
Record one call the interpreter made into generated code.

A diagnostic on a hot path, and it is here rather than inlined so that its cost
is one place to look when it is time to decide whether to keep it. Without it a
green run says nothing: re-entry that silently never happens looks exactly like
re-entry that happens and does not pay.
""".
-spec reentered() -> ok.
reentered() -> _ = bump(?IX_REENTERED, 1), ok.

%% Rebuilt when what is there is too small, which is what a node that was hot
%% upgraded from a version with fewer counters has. Reading past the end of an
%% `atomics` array raises `badarg`, and counting is a diagnostic: it may not be
%% the thing that brings a node down.
counters() ->
    case persistent_term:get(?PT_COUNTS, undefined) of
        undefined -> fresh_counters();
        R ->
            case maps:get(size, atomics:info(R)) >= ?IX_CACHED of
                true -> R;
                false -> fresh_counters()
            end
    end.

fresh_counters() ->
    R = atomics:new(?IX_CACHED, [{signed, false}]),
    persistent_term:put(?PT_COUNTS, R),
    R.
