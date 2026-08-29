-module(wasm_heap).
-moduledoc """
The garbage-collected object store.

You will not call this directly; `wasm:pin/2` and `wasm:release/2` are the parts
you use. Read it when you want to know what a struct or an array costs, or why
holding a reference needs a pin.

## Why it is not a term inside the instance state

It was, and that was the most expensive thing in this runtime.

`wasm_instance:set_mut/2` writes the `#mut{}` into ETS, ETS copies on insert,
and the object store sat inside it. So one `struct.set` copied every object in
the heap: 20.7 us at a thousand objects, 199 us at ten thousand, 1993 us at a
hundred thousand. That is 19.7 ns per object in the heap, per mutating call,
against 0.15 us for a call that only reads.

The store now lives here, mutated in place, and the handle is immutable: two
ETS table ids and an `atomics` reference. It travels in `#inst{}`, the half of
an instance that never changes, so an allocation or a field write leaves the
state term untouched and the write-back never fires.

## Why ETS, when `array` is faster per operation

`array` wins on both: 13.4 ns against 33.9 ns for a read, 50.6 ns against
93.0 ns for a write. It loses anyway, because those are the wrong numbers to
compare. An `array` has to be written back somewhere to be shared, and writing
it back copies it, so the cost that matters is per *call* and proportional to
the heap. ETS rows are mutated in place. The read pays 20 ns more and the call
stops paying milliseconds.

## Layout

Up to two tables, because they are traversed differently:

- **objects**, a `set`. A struct is `{Id, s, TypeIdx, F0, F1, ...}`, one tuple
  element per field, so reading a field copies the field and not the object.
  An array is its header only: `{Id, a, TypeIdx, Len, Default}`.
- **elements**, an `ordered_set` keyed `{Id, Index}`, holding array elements
  that have actually been written. An array of a million defaults costs one
  row, and the ordering is what lets the collector walk one array's elements
  without scanning the table. A module declaring no array type never gets this
  table, because a table costs about a microsecond and instantiation is under
  three.

## Identity

Ids come from an `atomics` counter and are never reused, so `ref.eq` stays an
integer comparison. The sweep walks the table's rows rather than the id space,
so it costs what is in the store and not what has ever been in it. What growing
ids do still cost is the mark bitmap, which is sized to the highest id handed
out. Reuse needs a free list, and it is not safe until every reference that leaves
the runtime is pinned: today an unpinned one traps, and with reused ids it would
silently name a different live object instead.
""".

-include("wasm.hrl").

-export([new/0, delete/2, is_heap/1]).
-export([register/3, instances/1]).
-export([new_struct/3, new_array/5]).
-export([get_field/3, set_field/4]).
-export([array_len/2, array_get/3, array_set/4, array_set_unchecked/4]).
-export([array_default/2, array_fill/5]).
-export([type_of/2]).
-export([size/1, allocs/1, should_collect/1, collect/2, major_due/1]).
-export([lease/1, unlease/2, try_exclusive/1, release_exclusive/1,
         request_collect/1, readers/1]).
-export([pin/2, unpin/2, unpin_all/1, pins/1]).

-doc "An opaque handle. Immutable: the tables it names are what change.".
-nominal heap() :: {wasm_heap, ets:tid(), undefined | ets:tid(),
                    atomics:atomics_ref()}.
-export_type([heap/0]).

%% Counter slots. `allocs' is a *watermark*, not a running total: the id the
%% counter stood at when the last collection finished. Allocation is then one
%% atomic increment rather than two.
-define(NEXT_ID, 1).
-define(WATERMARK, 2).
-define(LAST_MAJOR, 3).
%% Who is executing against this store, and whether anybody has asked for a
%% collection they could not perform. See "Leases" below.
-define(LEASE, 4).
-define(REQUEST, 5).
%% Set by a collector holding the store exclusively. Above any plausible reader
%% count, and added rather than assigned so a reader that arrives mid-collection
%% and steps back out cannot lose its own decrement.
-define(EXCL, (1 bsl 32)).

-define(DEFAULT_ALLOC_THRESHOLD, 100000).
-define(DEFAULT_MAJOR_RATIO, 2).
%% No major collection below this many objects: tracing a store of forty costs
%% less than deciding not to, and a program that never grows never needs one.
-define(DEFAULT_MIN_MAJOR, 4096).

%% Returned by `ets:lookup_element/4' when the row is not there. No WebAssembly
%% value is an atom other than `null', so this cannot collide with one, and the
%% defaulting form costs nothing on the path where the row *is* there. A `try'
%% around every field read would.
-define(ABSENT, '$wasm_absent').

%% The instances sharing this heap live in a row of the objects table, under a
%% key no object id can take. It was a row in the engine's shared store, and
%% three operations on that named, write-concurrent table cost 2.2 us of a 6.0 us
%% instantiation. A local table is the heap's own and nobody contends for it.
-define(REGISTRY, '$wasm_instances').

%% Who holds the store exclusively, and how much of the lease cell is theirs.
%% Only ever written by that holder, and only while it holds it.
-define(COLLECTOR, '$wasm_collector').

%%% ------------------------------------------------------------ lifecycle ---

-doc """
Create a heap.

The tables are owned by the calling process, which is the process instantiating
the module, so a heap has exactly the lifetime `#inst.store` already has and
adds no new ownership rule.
""".
-spec new() -> heap().
new() ->
    Objs = ets:new(wasm_heap_objects, [set, public, {read_concurrency, true}]),
    %% The second table holds array elements *and* the write barrier's
    %% remembered set, so every heap needs it. A struct-only module briefly got
    %% away without one, which saved about a microsecond of instantiation; the
    %% remembered set has to live somewhere and a third table would cost more.
    Elems = ets:new(wasm_heap_elements,
                    [ordered_set, public, {read_concurrency, true}]),
    true = ets:insert(Objs, {?REGISTRY, #{}}),
    {wasm_heap, Objs, Elems, atomics:new(5, [{signed, false}])}.

-doc """
Record that an instance's roots have to be traced when this heap collects.

A heap outlives any one of its instances, because linked instances share it.
Deleting it when the last one goes is what keeps that from leaking, and it is
why `delete/2` takes the instance that is leaving rather than just the heap.

What is stored is a summary, not the whole `#inst{}`. ETS copies on insert, and
an instance record carries its type table, its compiled functions and its
exports; registering one cost 1.9 us of a 5.7 us instantiation. The summary is
the four fields a root scan actually reads.
""".
-spec register(undefined | heap(), term(), term()) -> ok.
register(undefined, _Key, _Inst) -> ok;
register({wasm_heap, Objs, _, _}, Key, Inst) ->
    true = ets:insert(Objs, {?REGISTRY, (registry(Objs))#{Key => Inst}}),
    ok.

-doc "Every instance registered with this heap.".
-spec instances(undefined | heap()) -> [term()].
instances(undefined) -> [];
instances({wasm_heap, Objs, _, _}) ->
    maps:values(registry(Objs)).

%% Answers `#{}' for a table that is already gone, so `delete/2' is idempotent.
registry(Objs) ->
    try ets:lookup_element(Objs, ?REGISTRY, 2, #{})
    catch error:badarg -> #{}
    end.

-doc """
Drop an instance, releasing the heap once none is left.

Idempotent: `wasm:destroy/1` is documented as safe to call twice.
""".
-spec delete(undefined | heap(), term()) -> ok.
delete(undefined, _Key) -> ok;
delete({wasm_heap, Objs, Elems, _}, Key) ->
    Remaining = maps:remove(Key, registry(Objs)),
    case map_size(Remaining) of
        0 -> drop_tables(Objs, Elems);
        _ -> true = ets:insert(Objs, {?REGISTRY, Remaining}), ok
    end.

drop_tables(Objs, Elems) ->
    try ets:delete(Objs) catch error:badarg -> true end,
    Elems =:= undefined orelse
        (try ets:delete(Elems) catch error:badarg -> true end),
    ok.

-spec is_heap(term()) -> boolean().
is_heap({wasm_heap, _, _, _}) -> true;
is_heap(_) -> false.

%%% ----------------------------------------------------------- allocation ---

-spec new_struct(heap(), non_neg_integer(), [term()]) -> {objref, non_neg_integer()}.
new_struct({wasm_heap, Objs, _, Ctr}, TypeIdx, Fields) ->
    Id = atomics:add_get(Ctr, ?NEXT_ID, 1) - 1,
    true = ets:insert(Objs, list_to_tuple([Id, s, TypeIdx | Fields])),
    {objref, Id}.

-doc """
Allocate an array.

`Traced` says whether its elements can hold references. An array of `i32` or
`i8` cannot, so the collector never walks it: no scan of its elements, however
many have been written. That is most of what a language like Java or Kotlin
allocates, and walking a million-element byte array to find no references in it
is the kind of work worth not doing.
""".
-spec new_array(heap(), non_neg_integer(), non_neg_integer(), term(),
                boolean()) -> {objref, non_neg_integer()}.
new_array({wasm_heap, Objs, _, Ctr}, TypeIdx, Len, Default, Traced) ->
    Id = atomics:add_get(Ctr, ?NEXT_ID, 1) - 1,
    Kind = case Traced of true -> a; false -> n end,
    true = ets:insert(Objs, {Id, Kind, TypeIdx, Len, Default}),
    {objref, Id}.

%%% --------------------------------------------------------------- access ---

%% Every accessor answers `undefined' with a trap. A module declaring no struct
%% or array type has no heap, but still has instructions that can reach an
%% object: `array.len' and `ref.eq' carry no type index, and a reference can
%% arrive through an import typed `anyref'. The reference then belongs to
%% another instance's store and cannot be followed from here, which is a trap
%% and not a `function_clause' from three layers inside the runtime. Sharing one
%% store between linked instances is what turns this from a trap into an answer.
-spec get_field(undefined | heap(), term(), non_neg_integer()) -> term().
get_field(undefined, Ref, _Idx) -> foreign(Ref);
get_field({wasm_heap, Objs, _, _}, {objref, Id} = Ref, Idx) ->
    case ets:lookup_element(Objs, Id, 4 + Idx, ?ABSENT) of
        ?ABSENT -> foreign(Ref);
        Value -> Value
    end.

-spec set_field(undefined | heap(), term(), non_neg_integer(), term()) -> ok.
set_field(undefined, Ref, _Idx, _Value) -> foreign(Ref);
set_field({wasm_heap, Objs, Elems, Ctr}, {objref, Id} = Ref, Idx, Value) ->
    case ets:update_element(Objs, Id, {4 + Idx, Value}) of
        true -> remember(Elems, Ctr, Id, Value);
        false -> foreign(Ref)
    end.

-spec array_len(undefined | heap(), term()) -> non_neg_integer().
array_len(undefined, Ref) -> foreign(Ref);
array_len({wasm_heap, Objs, _, _}, {objref, Id} = Ref) ->
    case ets:lookup_element(Objs, Id, 4, ?ABSENT) of
        ?ABSENT -> foreign(Ref);
        Len -> Len
    end.

-spec array_default(heap(), term()) -> term().
array_default({wasm_heap, Objs, _, _}, {objref, Id} = Ref) ->
    case ets:lookup_element(Objs, Id, 5, ?ABSENT) of
        ?ABSENT -> foreign(Ref);
        Default -> Default
    end.

%% An element that was never written is not stored, so a miss means the array's
%% default. That is what keeps `array.new_default` of a million elements a
%% single row.
-spec array_get(undefined | heap(), term(), non_neg_integer()) -> term().
array_get(undefined, Ref, _Idx) -> foreign(Ref);
array_get({wasm_heap, Objs, Elems, _} = H, {objref, Id} = Ref, Idx) ->
    case array_len(H, Ref) of
        Len when Idx < Len ->
            case ets:lookup(Elems, {Id, Idx}) of
                [{_, V}] -> V;
                [] -> ets:lookup_element(Objs, Id, 5)
            end;
        Len ->
            wasm_error:trap(out_of_bounds_array_access,
                            #{index => Idx, length => Len})
    end.

-spec array_set(undefined | heap(), term(), non_neg_integer(), term()) -> ok.
array_set(undefined, Ref, _Idx, _Value) -> foreign(Ref);
array_set({wasm_heap, _, Elems, Ctr} = H, {objref, Id} = Ref, Idx, Value) ->
    case array_len(H, Ref) of
        Len when Idx < Len ->
            true = ets:insert(Elems, {{Id, Idx}, Value}),
            remember(Elems, Ctr, Id, Value);
        Len ->
            wasm_error:trap(out_of_bounds_array_access,
                            #{index => Idx, length => Len})
    end.

-doc """
Write an element whose index is already known to be in range.

Every bulk operation checks its whole range up front, because one that traps
must leave the array untouched. Checking again per element then doubles the
table operations to answer a question already answered.
""".
-spec array_set_unchecked(heap(), term(), non_neg_integer(), term()) -> ok.
array_set_unchecked({wasm_heap, _, Elems, Ctr}, {objref, Id}, Idx, Value) ->
    true = ets:insert(Elems, {{Id, Idx}, Value}),
    remember(Elems, Ctr, Id, Value).

-doc """
Fill a range with one value.

A fill covering the whole array is not a loop at all: every element becomes the
same value, which is precisely what the default means here, so it is one row
update plus dropping whatever overrides existed. `Arrays.fill` and zeroing a
freshly allocated array are both this shape.

The caller has already checked the range.
""".
-spec array_fill(heap(), term(), non_neg_integer(), non_neg_integer(), term()) ->
          ok.
array_fill({wasm_heap, Objs, Elems, Ctr} = H, {objref, Id} = Ref, 0, Len, Value) ->
    case ets:lookup_element(Objs, Id, 4) of
        Len ->
            true = ets:update_element(Objs, Id, {5, Value}),
            ok = delete_elements(Elems, Id),
            remember(Elems, Ctr, Id, Value);
        _ ->
            fill_each(H, Ref, 0, Len, Value)
    end;
array_fill(H, Ref, Start, Len, Value) ->
    fill_each(H, Ref, Start, Len, Value).

fill_each(H, Ref, Start, Len, Value) ->
    lists:foreach(fun(I) -> array_set_unchecked(H, Ref, Start + I, Value) end,
                  lists:seq(0, Len - 1)).

-doc """
The kind and declared type of an object, for `ref.test` and `ref.cast`.

A reference naming a slot that is not there is a trap, not a crash. It means a
reference outlived the object it named, and reporting that as a
`case_clause` three layers down says nothing about what went wrong.
""".
-spec type_of(undefined | heap(), term()) -> {struct | array, non_neg_integer()}.
type_of(undefined, Ref) -> foreign(Ref);
type_of({wasm_heap, Objs, _, _}, {objref, Id} = Ref) ->
    case ets:lookup_element(Objs, Id, 2, ?ABSENT) of
        s -> {struct, ets:lookup_element(Objs, Id, 3)};
        ?ABSENT -> foreign(Ref);
        _Array -> {array, ets:lookup_element(Objs, Id, 3)}
    end.

%%% ----------------------------------------------------------- accounting ---

-doc "How many objects the store holds. For tests and diagnostics.".
-spec size(undefined | heap()) -> non_neg_integer().
size(undefined) -> 0;
size({wasm_heap, Objs, _, _}) ->
    %% Minus the registry row, and minus the collector row when there is one:
    %% neither is an object, and `major_due/1` compares this against a live-set
    %% baseline that must not drift because a collection is in progress.
    ets:info(Objs, size) - 1 - collector_rows(Objs).

collector_rows(Objs) ->
    case lookup_collector(Objs) of
        none -> 0;
        _ -> 1
    end.

-spec allocs(undefined | heap()) -> non_neg_integer().
allocs(undefined) -> 0;
allocs({wasm_heap, _, _, Ctr}) ->
    atomics:get(Ctr, ?NEXT_ID) - atomics:get(Ctr, ?WATERMARK).

-doc """
Whether enough has been allocated since the last collection to be worth
tracing. A call that allocates nothing answers in two `atomics` reads.
""".
-spec should_collect(undefined | heap()) -> boolean().
should_collect(undefined) -> false;
should_collect(H) -> allocs(H) >= threshold().

threshold() ->
    application:get_env(wasm, gc_alloc_threshold, ?DEFAULT_ALLOC_THRESHOLD).

%%% --------------------------------------------------------------- leases ---
%%
%% Collection traces from roots, and a root is something the runtime can see: a
%% global, a table, a passive element segment, a pin. What it cannot see is a
%% reference held in another process's interpreter state, in a local or on an
%% operand stack halfway through a call. Within one process that is handled by
%% only ever collecting at depth zero. Across processes it is not, and linked
%% instances share a store precisely so that two processes can use it.
%%
%% So an execution takes a read lease and a collector needs the store to
%% itself. The lease is one `atomics' counter, not a process, because it is on
%% the call path and a round trip there would cost more than the collection it
%% guards.
%%
%% **A collection request never blocks anybody.** There is no writer-pending
%% state, deliberately: a reader arriving while a collection is merely *wanted*
%% goes straight in. If the requester is the only reader it upgrades and
%% collects at once; otherwise it records the request and returns, and whoever
%% is last out of the store performs it. A collection that is actually running
%% is exclusive, so a call arriving then does wait, for a bounded time. The
%% property is that no call is blocked indefinitely, not that no call ever
%% waits.
%%
%% If execution never stops, collection never runs. That is a consequence
%% rather than an accident, and the memory limits are the backstop.

-doc """
Take a read lease on the store, answering whether one was taken.

Answers `false` for a module with no object store at all, which is every module
declaring no struct and no array type, so those pay one comparison.
""".
-spec lease(undefined | heap()) -> boolean().
lease(undefined) -> false;
lease({wasm_heap, Objs, _, Ctr}) ->
    read_lease(Objs, Ctr, 0),
    %% Who is holding it, so that a reader killed before its `after` runs can be
    %% told from one still working. The count alone cannot: a leaked increment
    %% and a busy reader look identical, and the leaked one stopped `try_
    %% exclusive/1` from ever matching again, which stopped collection for the
    %% life of the store.
    %%
    %% One `ets:update_counter` per *outermost* invocation, and only for a
    %% module that declares a struct or an array type: `lease/1` already answers
    %% `false` for every other module, so nothing that does not use the object
    %% store pays for this.
    ok = remember_reader(Objs),
    true.

read_lease(Objs, Ctr, Tries) ->
    case atomics:add_get(Ctr, ?LEASE, 1) >= ?EXCL of
        false ->
            ok;
        true ->
            %% A collector has it. Step back out rather than hold a count it is
            %% waiting on, and try again; a collection is bounded, and one
            %% cannot start while a reader is inside.
            atomics:sub(Ctr, ?LEASE, 1),
            Tries > 16 andalso reclaim(Objs, Ctr),
            erlang:yield(),
            read_lease(Objs, Ctr, Tries + 1)
    end.

%% A collection is pure computation with no receive in it, so the only way to
%% stop halfway is `exit(Pid, kill)' -- which is exactly what a worker timeout
%% does. Left alone that would hold the store exclusively for ever and every
%% reader would spin against it, so a reader that has waited longer than a
%% collection plausibly takes checks whether there is still anybody there.
%%
%% Only the holder writes the row, and only while it holds the store, so
%% reading it is safe. The compare-and-exchange names exactly the value a dead
%% holder left, so at most one reader reclaims, and a reader that happens to be
%% transiently added simply makes it fail and try again.
reclaim(Objs, Ctr) ->
    case lookup_collector(Objs) of
        {Pid, Held} ->
            is_process_alive(Pid) orelse
                atomics:compare_exchange(Ctr, ?LEASE, ?EXCL + Held, 0) =:= ok;
        none ->
            false
    end.

lookup_collector(Objs) ->
    try ets:lookup(Objs, ?COLLECTOR) of
        [{_, Pid, Held}] -> {Pid, Held};
        [] -> none
    catch error:badarg -> none
    end.

%% Recorded so a reader can tell a collection in progress from one whose
%% collector is gone. `Held' is what the holder's own read lease contributes,
%% which differs between an upgrade and a claim from an empty store.
mark_collector(Objs, Held) ->
    try ets:insert(Objs, {?COLLECTOR, self(), Held}) catch error:badarg -> true end,
    ok.

unmark_collector(Objs) ->
    try ets:delete(Objs, ?COLLECTOR) catch error:badarg -> true end,
    ok.

%% Take the mark back only if it is still ours. A plain delete would take a
%% concurrent collector's mark away with it, and that collector holds the store:
%% readers would then find `?EXCL` with nobody marked, which is exactly the
%% state marking first exists to make impossible.
unmark_if_mine(Objs) ->
    Me = self(),
    try ets:select_delete(Objs, [{{?COLLECTOR, Me, '_'}, [], [true]}])
    catch error:badarg -> 0
    end,
    ok.

-doc """
Give up a read lease.

Answers `collect_now` when this was the last reader out and somebody asked for
a collection they could not perform themselves. The caller does it, because
gathering roots is not this module's business.
""".
-spec unlease(undefined | heap(), boolean()) -> ok | collect_now.
unlease(_H, false) -> ok;
unlease({wasm_heap, Objs, _, Ctr}, true) ->
    ok = forget_reader(Objs),
    case atomics:sub_get(Ctr, ?LEASE, 1) of
        0 -> last_out(Objs, Ctr);
        N -> still_inside(Objs, Ctr, N)
    end.

%% Somebody is still in, so this reader is not the one to collect. Unless the
%% somebody is dead: a reader killed with `exit(Pid, kill)` never ran the
%% `after` that gives its count back, and `last_out/2` would then never see
%% zero again however long the store waited.
%%
%% Checked only when a collection is actually pending, so the ordinary path is
%% the same two atomics it has always been, and only from the *falling* edge, so
%% a store with steady traffic pays for it once per invocation that leaves
%% somebody behind rather than once per invocation.
still_inside(Objs, Ctr, N) ->
    case atomics:get(Ctr, ?REQUEST) of
        0 -> ok;
        _ -> reap(Objs, Ctr, N)
    end.

%% Give back what dead readers are holding, and collect if that empties the
%% store. `is_process_alive/1` is the authority here for the same reason
%% `code:soft_purge/1` is the authority in `wasm_code_slots`: a lease is given
%% back in an `after` and an `after` does not run for a killed process, so the
%% lease cannot be what decides.
reap(Objs, Ctr, N) ->
    case dead_readers(Objs) of
        0 -> ok;
        Dead ->
            case atomics:sub_get(Ctr, ?LEASE, min(Dead, N)) of
                0 -> case last_out(Objs, Ctr) of
                         collect_now -> collect_now;
                         ok -> ok
                     end;
                _ -> ok
            end
    end.

%% Rows are deleted as they are counted, so two reapers cannot both subtract
%% for the same corpse: `ets:take/2` hands the row to exactly one of them.
dead_readers(Objs) ->
    try ets:select(Objs, [{{{reader, '$1'}, '_'}, [], ['$1']}]) of
        Pids ->
            lists:sum([Held || Pid <- Pids, not is_process_alive(Pid),
                               Held <- [taken(Objs, Pid)]])
    catch error:badarg -> 0
    end.

taken(Objs, Pid) ->
    case ets:take(Objs, {reader, Pid}) of
        [{_, Held}] -> Held;
        [] -> 0
    end.

remember_reader(Objs) ->
    Key = {reader, self()},
    try ets:update_counter(Objs, Key, {2, 1}, {Key, 0}) catch error:badarg -> 0 end,
    ok.

forget_reader(Objs) ->
    Key = {reader, self()},
    try
        case ets:update_counter(Objs, Key, {2, -1}, {Key, 0}) of
            N when N =< 0 -> ets:delete(Objs, Key);
            _ -> true
        end
    catch error:badarg -> true
    end,
    ok.

last_out(Objs, Ctr) ->
    case atomics:get(Ctr, ?REQUEST) of
        0 -> ok;
        _ ->
            %% Marked first, for the reason `try_exclusive/1` gives.
            ok = mark_collector(Objs, 0),
            case atomics:compare_exchange(Ctr, ?LEASE, 0, ?EXCL) of
                ok -> collect_now;
                %% Somebody came back in first. The request stands and the next
                %% one out will find it.
                _ -> ok = unmark_if_mine(Objs), ok
            end
    end.

-doc """
Take the store exclusively, from a caller already holding one read lease.

Succeeds only if that lease is the only one, which is what makes this an
upgrade that cannot deadlock: there is nobody to wait for.
""".
-spec try_exclusive(undefined | heap()) -> boolean().
try_exclusive(undefined) -> false;
try_exclusive({wasm_heap, Objs, _, Ctr}) ->
    %% Marked *before* the exchange, and this order is the whole safety of it.
    %% The other way round left a window where the store read as exclusive with
    %% no collector row: a process killed in there stranded `?EXCL` for ever,
    %% `reclaim/2` found `none` and answered `false`, and every reader spun in
    %% `read_lease/3` without bound. This way that state cannot exist, and the
    %% state this order does allow -- marked, not exclusive -- is harmless,
    %% because the row is only ever consulted once the count is already at
    %% `?EXCL`.
    ok = mark_collector(Objs, 1),
    case atomics:compare_exchange(Ctr, ?LEASE, 1, ?EXCL + 1) of
        ok -> true;
        _ -> ok = unmark_if_mine(Objs), false
    end.

-doc "Release the exclusive hold, leaving any read lease the caller had.".
-spec release_exclusive(undefined | heap()) -> ok.
release_exclusive(undefined) -> ok;
release_exclusive({wasm_heap, Objs, _, Ctr}) ->
    ok = unmark_collector(Objs),
    %% Subtracted, not assigned: a reader that arrived during the collection
    %% added to this cell and will subtract again, and assigning zero would
    %% take its decrement below zero and wrap.
    atomics:sub(Ctr, ?LEASE, ?EXCL),
    atomics:put(Ctr, ?REQUEST, 0),
    ok.

-doc "Record that a collection is wanted but could not be performed now.".
-spec request_collect(undefined | heap()) -> ok.
request_collect(undefined) -> ok;
request_collect({wasm_heap, _, _, Ctr}) -> atomics:put(Ctr, ?REQUEST, 1).

-doc "How many read leases are outstanding. For tests and diagnostics.".
-spec readers(undefined | heap()) -> non_neg_integer().
readers(undefined) -> 0;
readers({wasm_heap, _, _, Ctr}) -> atomics:get(Ctr, ?LEASE) rem ?EXCL.

%%% ------------------------------------------------------------ collector ---

-doc """
Collect, minor unless the old generation has grown enough to warrant a major.

**Minor.** Objects allocated since the last collection are exactly the id range
`[watermark, next_id)`, because ids are handed out by a counter and never
reused. So the nursery needs no bookkeeping at all: it is an integer range, and
sweeping it is a loop over that range rather than a walk of the store.

A minor collection never traces an old object, which is what makes the pause
proportional to what was just allocated rather than to everything alive. That is
sound because an old object can only point at a young one through a write made
since the last collection, and `set_field/4` and `array_set/4` record those.

**Major.** Traces and sweeps everything, and is where the long pause lives. It
runs when the store has grown past `gc_major_ratio` times its size after the
last major (default 2), so a program with a stable live set almost never has one.

Mark and sweep rather than copying, because object ids are handed out and
compared by `ref.eq`, so they must not move. The mark set is an `atomics` bitmap
and the worklist holds ids rather than values: the first collector kept its live
set in a map and built its worklist with `++`, costing 76 ns per object for the
map alone and growing the *calling process's* BEAM heap by 8.5 words per object.
""".
-spec collect(undefined | heap(), [term()]) -> ok.
collect(undefined, _Roots) -> ok;
collect({wasm_heap, _, Elems, Ctr} = H, Roots) ->
    Next = atomics:get(Ctr, ?NEXT_ID),
    case major_due(H) of
        true -> major(H, Roots, Next);
        false -> minor(H, Roots, Next)
    end,
    %% The watermark first, then the remembered set. A collector killed between
    %% the two used to drop the remembered set while the watermark still named
    %% the previous generation, so the next minor collection traced neither the
    %% old-to-young references nor the objects they pointed at, and freed live
    %% ones. This order leaves the conservative state instead: a remembered set
    %% larger than it needs to be, which costs a longer trace and nothing else.
    atomics:put(Ctr, ?WATERMARK, Next),
    forget_all(Elems),
    ok.

-doc "Whether the next collection will trace the whole store.".
-spec major_due(undefined | heap()) -> boolean().
major_due(undefined) -> false;
major_due({wasm_heap, _, _, Ctr} = H) ->
    Baseline = atomics:get(Ctr, ?LAST_MAJOR),
    ?MODULE:size(H) >= max(Baseline * major_ratio(), min_major()).

major({wasm_heap, Objs, Elems, Ctr} = H, Roots, Next) ->
    Marks = bitmap(0, Next),
    mark(root_ids(Roots), H, Marks, 0),
    sweep(Objs, Elems, Marks),
    atomics:put(Ctr, ?LAST_MAJOR, ?MODULE:size(H)).

%% The nursery is `[Base, Next)'. Marking starts from the roots and from every
%% old object the write barrier recorded, and stops at anything older than
%% `Base': old objects are assumed live, which is the whole point.
minor({wasm_heap, Objs, Elems, Ctr} = H, Roots, Next) ->
    Base = atomics:get(Ctr, ?WATERMARK),
    Marks = bitmap(Base, Next),
    Roots1 = root_ids(Roots) ++ remembered_children(Objs, Elems),
    mark(Roots1, H, Marks, Base),
    sweep_range(Objs, Elems, Marks, Base, Base, Next).

bitmap(Base, Next) ->
    atomics:new(max((Next - Base) div 64 + 1, 1), [{signed, false}]).

major_ratio() ->
    application:get_env(wasm, gc_major_ratio, ?DEFAULT_MAJOR_RATIO).

min_major() ->
    application:get_env(wasm, gc_min_major_size, ?DEFAULT_MIN_MAJOR).

%%% ----------------------------------------------------------------- pins ---

-doc """
Keep an object alive across collections until it is released.

A reference you are handed is not reachable from any root the runtime can see,
so without this the next collection frees it and leaves you holding an id that
names nothing. Call results, `wasm:get_global/2` results and the values of an
uncaught exception are pinned on the way out.

Reference counted, so a reference handed out twice needs releasing twice. The
count lives beside the object rather than in the instance state, which is what
stopped pinning from costing a state write-back on every call: it used to be a
list rebuilt with `lists:usort/1` per call that never shrank.
""".
-spec pin(undefined | heap(), term()) -> ok.
pin(undefined, _Ref) -> ok;
pin({wasm_heap, _, Elems, _}, {objref, Id}) ->
    _ = ets:update_counter(Elems, {pinned, Id}, {2, 1}, {{pinned, Id}, 0}),
    ok;
pin(_H, _Other) -> ok.

-doc """
Release one pin, letting the object be collected once nothing else holds it.

Releasing a reference that was never pinned is not an error, so you can release
everything you have seen without remembering which ones counted.
""".
-spec unpin(undefined | heap(), term()) -> ok.
unpin(undefined, _Ref) -> ok;
unpin({wasm_heap, _, Elems, _}, {objref, Id}) ->
    Key = {pinned, Id},
    try ets:update_counter(Elems, Key, {2, -1}) of
        N when N =< 0 -> true = ets:delete(Elems, Key), ok;
        _ -> ok
    catch
        error:badarg -> ok
    end;
unpin(_H, _Other) -> ok.

-doc "Release every pin, for when you scope references to a request.".
-spec unpin_all(undefined | heap()) -> ok.
unpin_all(undefined) -> ok;
unpin_all({wasm_heap, _, Elems, _}) ->
    unpin_all_from(Elems, ets:next(Elems, {pinned, -1})).

unpin_all_from(Elems, {pinned, _} = Key) ->
    Next = ets:next(Elems, Key),
    true = ets:delete(Elems, Key),
    unpin_all_from(Elems, Next);
unpin_all_from(_Elems, _Other) ->
    ok.

-doc "Every pinned reference, as collection roots.".
-spec pins(undefined | heap()) -> [term()].
pins(undefined) -> [];
pins({wasm_heap, _, Elems, _}) ->
    pins(Elems, ets:next(Elems, {pinned, -1}), []).

pins(Elems, {pinned, Id} = Key, Acc) ->
    pins(Elems, ets:next(Elems, Key), [{objref, Id} | Acc]);
pins(_Elems, _Other, Acc) ->
    Acc.

%%% --------------------------------------------------------- write barrier ---

%% Note a reference stored into an object older than the nursery.
%%
%% Only a store of a reference into an old object costs anything: a number, a
%% null or an `i31' is not a pointer and falls through on one pattern match,
%% and a young container is traced anyway. Recording is idempotent, so an object
%% written a thousand times is remembered once.
remember(undefined, _Ctr, _Id, _Value) -> ok;
remember(Elems, Ctr, Id, {objref, _}) ->
    case Id < atomics:get(Ctr, ?WATERMARK) of
        true -> true = ets:insert(Elems, {{remembered, Id}, []}), ok;
        false -> ok
    end;
remember(Elems, Ctr, Id, {extern, V}) -> remember(Elems, Ctr, Id, V);
remember(Elems, Ctr, Id, {internal, V}) -> remember(Elems, Ctr, Id, V);
remember(_Elems, _Ctr, _Id, _Value) -> ok.

%% Every young object an old, written-to object refers to.
remembered_children(Objs, Elems) ->
    remembered_children(Objs, Elems, ets:next(Elems, {remembered, -1}), []).

remembered_children(Objs, Elems, {remembered, Id} = Key, Acc) ->
    Acc1 = case ets:lookup(Objs, Id) of
               [Row] when element(2, Row) =:= s -> push_fields(Row, 4, Acc);
               [Row] when element(2, Row) =:= a ->
                   push_elements(Elems, Id, push_ref(element(5, Row), Acc));
               _ -> Acc
           end,
    remembered_children(Objs, Elems, ets:next(Elems, Key), Acc1);
remembered_children(_Objs, _Elems, _Other, Acc) ->
    Acc.

forget_all(undefined) -> ok;
forget_all(Elems) -> forget_all(Elems, ets:next(Elems, {remembered, -1})).

forget_all(Elems, {remembered, _} = Key) ->
    Next = ets:next(Elems, Key),
    true = ets:delete(Elems, Key),
    forget_all(Elems, Next);
forget_all(_Elems, _Other) ->
    ok.

root_ids(Roots) -> root_ids(Roots, []).

root_ids([], Acc) -> Acc;
%% A wrapped reference still refers to whatever it wraps.
root_ids([{extern, V} | Rest], Acc) -> root_ids([V | Rest], Acc);
root_ids([{internal, V} | Rest], Acc) -> root_ids([V | Rest], Acc);
root_ids([{objref, Id} | Rest], Acc) -> root_ids(Rest, [Id | Acc]);
root_ids([_ | Rest], Acc) -> root_ids(Rest, Acc).

%% An explicit worklist of *ids*, not values: an object graph may be a million
%% deep, and recursion would be a million Erlang frames. Pushing ids one at a
%% time keeps the list's length bounded by the graph's width rather than by the
%% number of objects, which is what the old `children(Obj) ++ Rest' did not.
mark([], _H, _Marks, _Base) -> ok;
%% Older than the nursery, so this is a minor collection and the object is
%% assumed live. Not marked, not traced, not swept.
mark([Id | Rest], H, Marks, Base) when Id < Base ->
    mark(Rest, H, Marks, Base);
mark([Id | Rest], {wasm_heap, Objs, Elems, _} = H, Marks, Base) ->
    case set_mark(Marks, Id - Base) of false ->
            mark(Rest, H, Marks, Base);
        true ->
            %% A struct and an array are told apart by element 2, not by shape:
            %% a two-field struct and an array header are both 5-tuples.
            case ets:lookup(Objs, Id) of
                [Row] when element(2, Row) =:= s ->
                    mark(scan(Row, 4, tuple_size(Row), Rest), H, Marks, Base);
                [Row] when element(2, Row) =:= a ->
                    Acc = push_ref(element(5, Row), Rest),
                    mark(push_elements(Elems, Id, Acc), H, Marks, Base);
                [_Row] ->
                    %% An array whose elements cannot be references. Marked,
                    %% because it is live, but never walked.
                    mark(Rest, H, Marks, Base);
                [] ->
                    mark(Rest, H, Marks, Base)
            end
    end.

%% Walks a struct's fields in one function rather than calling `push_ref/2' per
%% field, and computes `tuple_size/1' once instead of on every iteration. The
%% loop runs once per field of every object marked, so a call and a BIF per
%% field is worth removing; the primitives underneath it are not, at 35.8 ns for
%% the row lookup and 22.3 ns for the mark bit.
scan(_Row, Idx, Max, Acc) when Idx > Max -> Acc;
scan(Row, Idx, Max, Acc) ->
    case element(Idx, Row) of
        {objref, Id} -> scan(Row, Idx + 1, Max, [Id | Acc]);
        {extern, V} -> scan(Row, Idx + 1, Max, push_ref(V, Acc));
        {internal, V} -> scan(Row, Idx + 1, Max, push_ref(V, Acc));
        _ -> scan(Row, Idx + 1, Max, Acc)
    end.

push_fields(Row, Idx, Acc) -> scan(Row, Idx, tuple_size(Row), Acc).

%% Walks one array's written elements using the ordered_set's ordering, so an
%% array with three elements written out of a million costs three steps.
push_elements(undefined, _Id, Acc) -> Acc;
push_elements(Elems, Id, Acc) ->
    push_elements(Elems, Id, ets:next(Elems, {Id, -1}), Acc).

push_elements(Elems, Id, {Id, _} = Key, Acc) ->
    Acc1 = push_ref(ets:lookup_element(Elems, Key, 2), Acc),
    push_elements(Elems, Id, ets:next(Elems, Key), Acc1);
push_elements(_Elems, _Id, _Other, Acc) ->
    Acc.

push_ref({objref, Id}, Acc) -> [Id | Acc];
push_ref({extern, V}, Acc) -> push_ref(V, Acc);
push_ref({internal, V}, Acc) -> push_ref(V, Acc);
push_ref(_, Acc) -> Acc.

%% Answers whether this call set the bit, so the caller traces the object only
%% the first time it reaches it.
set_mark(Marks, Id) ->
    Word = (Id bsr 6) + 1,
    Bit = 1 bsl (Id band 63),
    Current = atomics:get(Marks, Word),
    case Current band Bit of
        0 -> atomics:put(Marks, Word, Current bor Bit), true;
        _ -> false
    end.

is_marked(Marks, Id) ->
    atomics:get(Marks, (Id bsr 6) + 1) band (1 bsl (Id band 63)) =/= 0.

%% A minor sweep walks the nursery's id range rather than the store, so it costs
%% what was allocated since the last collection and not what is alive.
sweep_range(_Objs, _Elems, _Marks, _Base, Id, Next) when Id >= Next -> ok;
sweep_range(Objs, Elems, Marks, Base, Id, Next) ->
    case is_marked(Marks, Id - Base) of true -> ok;
        false ->
            ets:delete(Objs, Id),
            delete_elements(Elems, Id)
    end,
    sweep_range(Objs, Elems, Marks, Base, Id + 1, Next).

%% Traversal by key, so a row is never copied out just to decide it is dead.
%% `safe_fixtable' is what makes deleting during the walk defined.
sweep(Objs, Elems, Marks) ->
    true = ets:safe_fixtable(Objs, true),
    try
        sweep_from(ets:first(Objs), Objs, Elems, Marks)
    after
        true = ets:safe_fixtable(Objs, false)
    end.

sweep_from('$end_of_table', _Objs, _Elems, _Marks) -> ok;
%% The registry and collector rows are keyed by an atom rather than an id, so
%% they are not objects and have no mark bit. The collector row is always
%% present during a sweep, because taking the store exclusively is what writes
%% it and what a sweep runs under.
%% An object id is an integer, so anything else in this table is bookkeeping:
%% the registry, the collector, and the reader rows. Written as the shape of a
%% key rather than as a list of them, because the list had to be extended every
%% time a row was added and forgetting would have deleted live objects.
sweep_from(Key, Objs, Elems, Marks) when not is_integer(Key) ->
    sweep_from(ets:next(Objs, Key), Objs, Elems, Marks);
sweep_from(Id, Objs, Elems, Marks) ->
    Next = ets:next(Objs, Id),
    case is_marked(Marks, Id) of
        true -> ok;
        false ->
            true = ets:delete(Objs, Id),
            delete_elements(Elems, Id)
    end,
    sweep_from(Next, Objs, Elems, Marks).

delete_elements(undefined, _Id) -> ok;
delete_elements(Elems, Id) ->
    delete_elements(Elems, Id, ets:next(Elems, {Id, -1})).

delete_elements(Elems, Id, {Id, _} = Key) ->
    Next = ets:next(Elems, Key),
    true = ets:delete(Elems, Key),
    delete_elements(Elems, Id, Next);
delete_elements(_Elems, _Id, _Other) ->
    ok.

%% The reference names no object in this store. Either it belongs to another
%% instance that was never linked to this one, or it outlived what it named.
%% Both are traps rather than crashes: a `badarg' from inside `ets' says nothing
%% about which mistake was made.
foreign({objref, Id}) ->
    wasm_error:trap(foreign_reference, #{object => Id}).
