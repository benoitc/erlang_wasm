-module(wasm_engine).
-moduledoc """
Node-wide resource accounting.

This is where you cap how much linear memory the whole node may hold, and where
you go to see how much is in use:

```
wasm_engine:set_page_limit(16384),          % 1 GiB
#{pages_in_use := N} = wasm_engine:stats().
```

The budget covers every kind of memory a guest can take that the BEAM cannot see
for it: linear memory, and the garbage-collected object store. Set the cap.
Linear memory is backed by `atomics` arrays, which live outside the process
heap, and a struct or an array is a row in ETS, which is not process heap
either. That is what makes them fast (see the benchmark table in the
design notes), but it also means `max_heap_size` cannot see them: a module can
exhaust node memory without its owning process's heap ever moving. So page
accounting has to be explicit, and it has to be node-wide rather than
per-instance, because a thousand small instances are as much of a threat as one
large one.

The counter can read above the limit. It is the sum of what the registry holds,
and the object store is *measured* rather than requested: by the time the keeper
hears a number, the rows exist, and refusing to record them hides them instead of
giving them back. So already-spent pages are recorded whatever the budget says,
through `charge_pages/1`, and every `reserve_pages/1` refuses while the node is
over. A limit bounds what a guest may take next, not what it has taken.

Reading the counter is a lock-free `atomics` get, which is what keeps it off the
cost of an access. *Moving* it is not: reservation and release happen inside a
`wasm_keeper` transaction, together with the registry row that says whose pages
they are. Reserving here and recording the holder afterwards is exactly how the
two came apart, and a counter that disagrees with the registry is a counter that
eventually refuses every allocation on the node.
""".
-behaviour(gen_server).

-export([start_link/0]).
-export([table_grow_limit/0]).
-export([reserve_pages/1, charge_pages/1, release_pages/1, pages_in_use/0,
         page_limit/0, set_pages_in_use/1,
         set_page_limit/1, stats/0]).
-export([table_put/2, table_get/1, table_forget/1]).
-export([cell_put/2, cell_get/1, cell_forget/1]).
-export([intern_rec_group/1, ensure_store/0]).
-export([rec_group_limit/0, rec_groups_in_use/0]).
-export([ensure_waiters/0, ensure_waiter_table/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).
-define(PT_KEY, {wasm_engine, counters}).
-define(TABLES_TAB, wasm_tables).
-define(WAITERS_TAB, wasm_waiters).

%% Slots in the atomics array.
-define(SLOT_PAGES, 1).
-define(SLOT_LIMIT, 2).
-define(SLOT_TYPE_IDS, 3).

%% 1 GiB of linear memory across the whole node unless configured otherwise.
-define(DEFAULT_PAGE_LIMIT, 16384).
%% Distinct recursive type groups this node will intern. A row is never removed
%% (see `intern_rec_group/1'), so this is the whole bound on that table.
-define(DEFAULT_REC_GROUP_LIMIT, 100000).

%% The largest a table may become. Not a node-wide budget: it bounds the work
%% one `table.grow' can be asked to do, since a table's declared maximum may be
%% as high as the index type allows.
-define(DEFAULT_TABLE_GROW_LIMIT, 16777216).

%%% ----------------------------------------------------------------- api ---

-doc """
Start the engine, or adopt the one that is already there.

The waiter table needs an owner that outlives any waiter, and a threaded module
can be run before the application is started. So the engine, like
`wasm_keeper`, may already exist by the time the supervisor gets here; adopting
it keeps the table it owns instead of taking every parked agent's registration
down with it.
""".
start_link() ->
    case gen_server:start_link({local, ?SERVER}, ?MODULE, [], []) of
        {ok, Pid} -> {ok, Pid};
        {error, {already_started, Pid}} -> true = link(Pid), {ok, Pid}
    end.

-doc """
Reserve `N` pages against the node-wide budget.

Call this from `wasm_keeper` and nowhere else: a reservation that is not
recorded against a holder in the same step belongs to nobody, and nothing will
ever give it back. You get `{error, limit}` rather than an exception, because
`memory.grow` has to turn a refusal into the value -1 that the specification
requires, not into a trap.
""".
-spec reserve_pages(non_neg_integer()) -> ok | {error, limit}.
reserve_pages(0) -> ok;
reserve_pages(N) when is_integer(N), N > 0 ->
    Ref = counters_ref(),
    Limit = atomics:get(Ref, ?SLOT_LIMIT),
    reserve_loop(Ref, N, Limit).

reserve_loop(Ref, N, Limit) ->
    Cur = atomics:get(Ref, ?SLOT_PAGES),
    New = Cur + N,
    if
        New > Limit ->
            {error, limit};
        true ->
            case atomics:compare_exchange(Ref, ?SLOT_PAGES, Cur, New) of
                ok -> ok;
                _Actual -> reserve_loop(Ref, N, Limit)
            end
    end.

-doc """
Count `N` pages that have already been spent, over the limit if need be.

`reserve_pages/1` asks permission for memory nobody has taken yet, and refusing
it costs nothing. This is for memory that is *already there*: the object store
is measured rather than requested, and by the time the keeper hears the number
the ETS rows exist. Refusing to record them does not give them back, it only
hides them, and a review found exactly that -- a heap sitting at twelve pages
charged for six, once per heap on the node.

So the count always moves and the answer only says whether it went over. It can
therefore read above `page_limit/0`, which is the truth: `pages_in_use/0` is the
sum of what the registry holds. While it is over, every `reserve_pages/1` on the
node refuses, which is the point, and the pages come back on destroy through the
same `release_pages/1` as any other.

Call this from `wasm_keeper` reconciliation and nowhere else.
""".
-spec charge_pages(non_neg_integer()) -> ok | {error, limit}.
charge_pages(0) -> ok;
charge_pages(N) when is_integer(N), N > 0 ->
    Ref = counters_ref(),
    New = atomics:add_get(Ref, ?SLOT_PAGES, N),
    case New > atomics:get(Ref, ?SLOT_LIMIT) of
        true -> {error, limit};
        false -> ok
    end.

-spec release_pages(non_neg_integer()) -> ok.
release_pages(0) -> ok;
release_pages(N) when is_integer(N), N > 0 ->
    _ = atomics:sub(counters_ref(), ?SLOT_PAGES, N),
    ok.

-spec pages_in_use() -> non_neg_integer().
pages_in_use() -> atomics:get(counters_ref(), ?SLOT_PAGES).

-doc """
Set the page count outright, for `wasm_keeper` reconciliation and nothing else.

The counter lives in `persistent_term` and so outlives the supervision tree; the
registry that says who holds those pages is a table that does not. If the tree
goes, the count survives with nobody left to give any of it back, and every page
charged at that moment is gone for the life of the node. `wasm_keeper` puts the
two back in step when it starts, which it can do safely because every
`reserve_pages/1` and `release_pages/1` call in the runtime goes through that
process.

Call it from anywhere else and the node's accounting becomes a number somebody
chose rather than a sum of what is held.
""".
-spec set_pages_in_use(non_neg_integer()) -> ok.
set_pages_in_use(N) when is_integer(N), N >= 0 ->
    atomics:put(counters_ref(), ?SLOT_PAGES, N).

-spec page_limit() -> non_neg_integer().
page_limit() -> atomics:get(counters_ref(), ?SLOT_LIMIT).

-doc """
Cap the total linear memory pages every instance on this node may hold together.

Set this once at startup if you run modules you do not control. A page is
64 KiB, so `set_page_limit(16384)` is 1 GiB. Reserving past the cap makes
`memory.grow` return -1 to the module, as the specification requires, rather
than trapping.
""".
-spec set_page_limit(non_neg_integer()) -> ok.
set_page_limit(N) when is_integer(N), N >= 0 ->
    atomics:put(counters_ref(), ?SLOT_LIMIT, N).

-doc """
The largest number of entries a table may hold.

Set it with the `table_grow_limit` application environment key. Unlike the page
budget it bounds each table rather than their node-wide total, because what it
is there for is stopping one `table.grow` from doing unbounded work.
""".
-spec table_grow_limit() -> non_neg_integer().
table_grow_limit() ->
    application:get_env(wasm, table_grow_limit, ?DEFAULT_TABLE_GROW_LIMIT).

-doc "Read the current page budget and what is in use.".
-spec stats() -> #{atom() => term()}.
stats() ->
    #{pages_in_use => pages_in_use(),
      page_limit   => page_limit(),
      bytes_in_use => pages_in_use() * 65536}.

%% The reference is written to `persistent_term' exactly once at boot, so the
%% global scan that a put triggers is paid once rather than per access. Reads
%% are then free of copying.
counters_ref() ->
    case persistent_term:get(?PT_KEY, undefined) of
        undefined -> ensure_started();
        Ref -> Ref
    end.

%% Allows the decoder/memory modules to be used without the application
%% running, which keeps unit tests and escript embedding simple.
ensure_started() ->
    case whereis(?SERVER) of
        undefined ->
            Ref = new_counters(),
            %% Racy by construction; whichever ref lands first wins and the
            %% loser's array is garbage collected. Only reachable in the
            %% no-application path.
            case persistent_term:get(?PT_KEY, undefined) of
                undefined -> persistent_term:put(?PT_KEY, Ref), Ref;
                Existing -> Existing
            end;
        _Pid ->
            persistent_term:get(?PT_KEY)
    end.

new_counters() ->
    Ref = atomics:new(3, [{signed, false}]),
    atomics:put(Ref, ?SLOT_PAGES, 0),
    atomics:put(Ref, ?SLOT_LIMIT, configured_limit()),
    Ref.

configured_limit() ->
    application:get_env(wasm, page_limit, ?DEFAULT_PAGE_LIMIT).

-doc """
How many distinct recursive type groups this node may intern.

Set it with `application:set_env(wasm, max_rec_groups, N)`. The default is high
enough that no legitimate workload reaches it: a real module declares tens of
groups and the interning is shared, so this is a bound on churn from modules
that keep arriving with types nothing has seen before.
""".
-spec rec_group_limit() -> pos_integer().
rec_group_limit() ->
    application:get_env(wasm, max_rec_groups, ?DEFAULT_REC_GROUP_LIMIT).

-doc "How many are interned. Never goes down: see `intern_rec_group/1`.".
-spec rec_groups_in_use() -> non_neg_integer().
rec_groups_in_use() -> atomics:get(counters_ref(), ?SLOT_TYPE_IDS).

%%% --------------------------------------------------------- table storage ---
%%
%% Table contents live here rather than inside an instance, because a table can
%% be exported by one module and imported by another, and both must see the
%% same thing.
%%
%% This module is only the storage. Who holds a row, and when it goes, is
%% `wasm_keeper''s business: the row is keyed by the resource identity the
%% keeper minted, and the keeper deletes it when the last holder lets go.
%%
%% Readers do not hit ETS on every access: `wasm_table' caches the array behind
%% a version counter and only reloads when somebody else has written.

-doc """
The shared store, under its general name.

`wasm_table` was the first user, so the rows are called tables; a shared
mutable global is one term in the same store, with the same lifetime rules.
""".
-spec cell_put(reference(), term()) -> ok.
cell_put(Id, Value) -> table_put(Id, Value).

-spec cell_get(reference()) -> term().
cell_get(Id) -> table_get(Id).

-spec cell_forget(reference()) -> ok.
cell_forget(Id) -> table_forget(Id).

-doc """
Intern a canonical recursive type group, returning its node-wide identity.

Node-wide because type identity has to hold across modules: one module imports
a function whose type another declared, and they must agree it is the same type.

Lock-free. A racing pair may both allocate an id, but only one `insert_new`
wins and the loser re-reads the winner's, so an id is never handed to two
different groups. Interning happens once per group at compile time, so the
retry costs nothing worth avoiding.
""".
-spec intern_rec_group(term()) -> non_neg_integer().
intern_rec_group(Key) ->
    ensure_tables_table(),
    case ets:lookup(?TABLES_TAB, {rec_group, Key}) of
        [{_, Id}] -> Id;
        [] ->
            %% Bounded, because a row here is never removed and never can be: a
            %% type id is compared by `ref.eq` and by import matching, so
            %% dropping one would silently make two different types the same for
            %% whatever module still holds it, and nothing here knows when the
            %% last such module is gone. A `#module{}` is a plain term with no
            %% lifetime to hang a reference count on.
            %%
            %% So the table grows for the life of the node, and a caller feeding
            %% it distinct type groups grew it without bound while the module
            %% cache beside it stayed bounded. This turns that into a limit that
            %% refuses a module, which is what every other node-wide budget here
            %% does: `wasm_engine:set_page_limit/1` for pages,
            %% `max_resident_modules` for the cache.
            rec_groups_in_use() < rec_group_limit()
                orelse wasm_error:invalid(
                         too_many_rec_groups,
                         ~"the node's recursive type table is full",
                         #{limit => rec_group_limit()}),
            Id = atomics:add_get(counters_ref(), ?SLOT_TYPE_IDS, 1),
            case ets:insert_new(?TABLES_TAB, {{rec_group, Key}, Id}) of
                true -> Id;
                false -> ets:lookup_element(?TABLES_TAB, {rec_group, Key}, 2)
            end
    end.

-spec table_put(reference(), term()) -> ok.
table_put(Id, Array) ->
    ensure_tables_table(),
    true = ets:insert(?TABLES_TAB, {Id, Array}),
    ok.

-spec table_get(reference()) -> term().
table_get(Id) -> ets:lookup_element(?TABLES_TAB, Id, 2).

-spec table_forget(reference()) -> ok.
table_forget(Id) ->
    case ets:whereis(?TABLES_TAB) of
        undefined -> ok;
        _ -> true = ets:delete(?TABLES_TAB, Id), ok
    end.

-doc """
Make sure the waiter table exists, owned by something that outlives waiters.

`wasm_wait` calls this rather than creating the table itself. An ETS table dies
with the process that created it, and a waiter is a guest's process: when one
was killed on a worker timeout it took every other agent's registration with
it, and the next `notify` woke nobody.

There is no fallback to creating it locally. That fallback existed so a
threaded module could run without the application, and it reintroduced exactly
the defect it sits next to: an owner that is a waiter. An unsupervised engine
is started on demand instead, so there is one behaviour to reason about and one
that gets tested.
""".
-spec ensure_waiters() -> ok.
ensure_waiters() -> gen_server:call(engine(), ensure_waiters, infinity).

engine() ->
    case whereis(?SERVER) of
        undefined -> orphan();
        Pid -> Pid
    end.

orphan() ->
    %% Unlinked, so it outlives whichever process happened to need it first.
    case gen_server:start({local, ?SERVER}, ?MODULE, [], []) of
        {ok, Pid} -> Pid;
        {error, {already_started, Pid}} -> Pid
    end.

-doc """
Create the waiter table if it is not there.

`wasm_sup` calls this so the table belongs to the supervisor: an engine restart
would otherwise strand every parked agent, since a wait is a `receive` that
only a row in this table can be found by.
""".
-spec ensure_waiter_table() -> ok.
ensure_waiter_table() -> ensure_waiters_table().

ensure_waiters_table() ->
    case ets:whereis(?WAITERS_TAB) of
        undefined ->
            try ets:new(?WAITERS_TAB, [named_table, bag, public,
                                       {write_concurrency, true},
                                       {read_concurrency, true}])
            catch error:badarg -> ok
            end,
            ok;
        _ -> ok
    end.

-doc """
Make sure the shared store exists.

`wasm_sup` calls this so the store belongs to the supervisor. It holds every
table's contents, every shared global's value and every published chunk tuple,
and `wasm_keeper`'s registry names rows in it: an engine restart that took the
store with it would leave the registry pointing at nothing.
""".
-spec ensure_store() -> ok.
ensure_store() -> ensure_tables_table().

ensure_tables_table() ->
    case ets:whereis(?TABLES_TAB) of
        undefined ->
            try ets:new(?TABLES_TAB, [named_table, set, public,
                                      {read_concurrency, true},
                                      {write_concurrency, true}])
            catch error:badarg -> ok
            end,
            ok;
        _ -> ok
    end.

%%% ------------------------------------------------------------ callbacks ---

init([]) ->
    ensure_tables_table(),
    ensure_waiters_table(),
    case persistent_term:get(?PT_KEY, undefined) of
        undefined -> persistent_term:put(?PT_KEY, new_counters());
        _ -> ok
    end,
    process_flag(trap_exit, true),
    {ok, #{}}.

handle_call(ensure_waiters, _From, State) ->
    ok = ensure_waiters_table(),
    {reply, ok, State};
handle_call(stats, _From, State) ->
    {reply, stats(), State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.
