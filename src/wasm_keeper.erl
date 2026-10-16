-module(wasm_keeper).
-moduledoc """
The authority on who still holds a shared resource.

You do not call this. It is what makes `wasm:destroy/1`, `wasm_memory:free/1`
and a process exiting agree with one another about when a memory's pages go
back to the node.

## Why a holder set and not a count

A count cannot tell two releases by one holder from releases by two. Destroy an
instance twice, or destroy one that imported the same memory through two import
slots, and a count goes down twice for one holder: the node's page counter fell
below zero, wrapped to 2^64-1, and refused every allocation on the node for the
rest of its life.

So a resource is keyed by a stable id and holds a **set of holder tokens**.
Removing a token that is not there is a no-op, which is what makes a double
release harmless, and the resource is reclaimed when the set empties.

| token | held by | removed by |
| --- | --- | --- |
| `{instance, Id}` | an instance that created or imported the memory, table or global | `wasm:destroy/1`, or its builder exiting |
| `{process, Pid}` | a standalone resource | `wasm_memory:free/1`, or `Pid` exiting |
| `manual` | a standalone thread-shared memory | `wasm_memory:free/1` only |
| `{build, Ref}` | an instantiation still in progress | `transfer/3` on success, `discard/1` on failure, or its builder exiting |

The `manual` token is what keeps the documented guarantee that a shared memory
outlives the process that made it: nothing about a process exiting removes it.

## Why death and not only exceptions

A process killed with `exit(Pid, kill)` runs no cleanup, and that is the
documented behaviour of a worker timeout. So every token carries the process
whose death releases it, and the keeper monitors that process. Explicit release
stays the fast path; the monitor is what makes the model true when there is no
chance to be explicit.

## Why the transaction

The node-wide page counter in `wasm_engine` is a fast unsynchronised read. It is
mutated only here, inside a call, together with the registry row that says who
the pages belong to. Reserving pages in the caller and registering the holder
afterwards is exactly how the counter and the registry come apart: die in
between and the pages are charged to nobody.

## Growth, in two stages

Allocating chunks is not cheap and must not happen inside the serialised
callback, or one large growth would stall every release, every rollback and
every other memory's growth behind it. So the keeper validates and reserves,
the *grower* allocates, and the keeper commits the chunk tuple and the published
size together. Concurrent growers queue rather than being refused, because
`memory.grow` returning -1 is observable to the module and must mean the budget
really was exhausted.

The registry, not the caller's possibly stale handle, is the authority for how
many pages a resource has. That is why `release/2` releases the size the memory is
now rather than the size the handle was made at.

## One row, one write

Every change to what a memory owes is a single `ets:insert` of its row, and
the row carries the transaction in flight with it: a growth or an arena
extension, named by the operation id its caller made. A keeper killed between
two steps therefore leaves either the old row or the new one, and a restart
finishes or undoes the transaction from what the row says. The node counter
and the snapshot byte counter are caches of the rows, rebuilt at every start.

A memory owes two things. Its **logical** pages are what the guest sees, and
what `max_memory_pages` and the declared maximum bound. Its **charged** pages
are what is allocated: the page table of an image, its growth chunks and its
arena of private pages. The node budget counts the second.
""".
-behaviour(gen_server).

-export([start_link/0, ensure_table/0]).
-export([reserve/4, acquire/3, release/2, release_all/1, transfer/3,
         discard/1]).
-export([set_limit/2, build_limit/2, total_of/1]).
-export([grow_begin/4, grow_commit/3, grow_abort/2]).
-export([arena_begin/4, arena_commit/3, arena_abort/2, ack/2]).
-export([image_reserve/3, image_live/1]).
-export([reconcile/2, reconcile/3]).
-export([charge_of/1, holders_of/1, resources/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include("wasm_snapshot_budget.hrl").

-define(SERVER, ?MODULE).
-define(TAB, wasm_holders).

-doc "A holder of a resource. Removing one that is absent is a no-op.".
-type token() :: {instance, reference()}
               | {process, pid()}
               | {build, reference()}
               | {snapshot, reference()}
               | manual.

-doc "A resource's stable identity, minted here so it exists before the
resource does. Reserving pages under an id the caller cannot yet have computed
is what keeps the reservation and the registration in one transaction.".
-type resource() :: reference().

-doc """
What reclaiming this resource means once the last holder is gone.

`cell` is a row in the shared store keyed by the resource's own identity, which
is what a table's contents and a shared global's value are. Minting the
identity here and using it as the row key means there is one name for the
thing, not two that have to be kept in step.
""".
-type meta() :: {memory, undefined | reference(),
                 undefined | atomics:atomics_ref(),
                 undefined | reference(), undefined | resource(),
                 {non_neg_integer(), pos_integer()}}
              | cell
              %% A garbage-collected object store, and the two ETS tables it
              %% is. They are recorded here rather than passed to `reconcile/2`
              %% so the keeper measures the tables it was told about at
              %% `reserve/4` and never a table identifier a caller handed it.
              | {heap, ets:tid(), ets:tid()}.

-export_type([token/0, resource/0]).

%%% ----------------------------------------------------------------- api ---

-doc """
Start the supervised keeper, or adopt the one that is already there.

A memory can be made before the application is started, so a keeper may already
exist by the time the supervisor gets here. Replacing it would throw away the
monitors that are the only record of who holds what, and the new keeper would
come up believing the node held nothing. So it is adopted instead: linked into
the supervision tree, and asked to name the supervisor as its table's heir so a
later crash does not take the registry with it.
""".
start_link() ->
    case gen_server:start_link({local, ?SERVER}, ?MODULE, [], []) of
        {ok, Pid} ->
            {ok, Pid};
        {error, {already_started, Pid}} ->
            true = link(Pid),
            ok = gen_server:call(Pid, {bequeath, self()}, infinity),
            {ok, Pid}
    end.

-doc """
Reserve `Pages` and register `Token` as the first holder, in one step.

The `Owner` is the process whose death releases the token, or `none` for a
`manual` token. You get back the resource's identity, which every later call
names it by. `gone` answers a memory to be laid over an image that is no
longer registered.
""".
-spec reserve(non_neg_integer(), meta(), token(), pid() | none) ->
          {ok, resource()}
        | {error, limit | instance_limit | gone | keeper_unavailable}.
reserve(Pages, Meta, Token, Owner) ->
    call({reserve, Pages, Meta, Token, Owner, pending_limit(Token)}).

-doc """
Add a holder to a resource that already exists.

`{error, gone}` means the last holder released it before you got here, which an
importer has to treat as a link failure rather than as a memory it may use.
""".
-spec acquire(resource(), token(), pid() | none) ->
          ok | {error, gone | instance_limit | keeper_unavailable}.
acquire(Resource, Token, Owner) ->
    call({acquire, Resource, Token, Owner, pending_limit(Token)}).

-doc """
Remove a holder. The resource goes when the set empties.

Always `ok`: releasing a token that is not held, or a resource that is already
gone, is the case this exists to make harmless.
""".
-spec release(resource(), token()) -> ok.
release(Resource, Token) ->
    case call({release, Resource, Token}) of
        ok -> ok;
        {error, keeper_unavailable} -> ok
    end.

-doc """
Remove several holders in one step, as `release/2` does each of them.

What `wasm:destroy/1` uses: an instance holds a memory, its tables and its
mutable globals, and releasing them one call at a time put that many round
trips through this process on every request a worker served.
""".
-spec release_all([{resource(), token()}]) -> ok.
release_all([]) -> ok;
release_all(Pairs) ->
    case call({release_all, Pairs}) of
        ok -> ok;
        {error, keeper_unavailable} -> ok
    end.

-doc """
Move every token `From` holds onto `To`, atomically.

Used when a build succeeds: the entries a builder accumulated become the
instance's, without a window in which they belong to neither.
""".
-spec transfer(token(), token(), pid() | none) -> ok.
transfer(From, To, Owner) ->
    _ = erase({?MODULE, limit, From}),
    case call({transfer, From, To, Owner}) of
        ok -> ok;
        {error, keeper_unavailable} -> ok
    end.

-doc """
Cap how many pages one holder may reach in total.

`max_memory_pages` was documented as a per-instance ceiling and enforced
nowhere: a module declaring three hundred pages instantiated under a limit of
two hundred and fifty-six. Checking it where a memory is created would not have
been enough either, because an imported memory is never created by the instance
that imports it.

So the ceiling belongs to the *holder*, and every way of becoming one goes
through this module. A shared memory therefore grows only as far as its
strictest holder allows, which is a consequence worth stating rather than a
rule of its own: the alternative is one instance growing a memory past a limit
another instance was promised.
""".
-spec set_limit(token(), non_neg_integer() | infinity) -> ok.
set_limit(_Token, infinity) -> ok;
set_limit(Token, Max) ->
    case call({set_limit, Token, Max}) of
        ok -> ok;
        {error, keeper_unavailable} -> ok
    end.

-doc """
`set_limit/2` for a build token, without a round trip of its own.

Kept in the calling process and carried by the next `reserve/4` or `acquire/3`
under the same token, which is every way a build takes its first page, so the
ceiling is in place before anything it bounds. `transfer/3` and `discard/1`
forget it. Only the process that builds may use it: the ceiling travels with
that process's own calls.
""".
-spec build_limit(token(), non_neg_integer() | infinity) -> ok.
build_limit(_Token, infinity) -> ok;
build_limit(Token, Max) ->
    _ = put({?MODULE, limit, Token}, Max),
    ok.

pending_limit(Token) -> get({?MODULE, limit, Token}).

-doc "Pages a holder holds across every memory it can reach. Diagnostics.".
-spec total_of(token()) -> non_neg_integer().
total_of(Token) ->
    case call({total_of, Token}) of
        {ok, N} -> N;
        _ -> 0
    end.

-doc """
Release everything the calling process holds under `Token`.

What a build transaction is rolled back with. A ledger threaded through the
build is lost the moment it throws, because the exception carries the error and
not the newest value from the abandoned stack; the keeper holds it instead, so
there is something left to roll back.
""".
-spec discard(token()) -> ok.
discard(Token) ->
    _ = erase({?MODULE, limit, Token}),
    case call({discard, Token}) of
        ok -> ok;
        {error, keeper_unavailable} -> ok
    end.

-doc """
Charge a heap for what its tables currently hold.

The measurement happens *here*, inside the callback that applies it, because a
caller that measures and then calls has already lost: two processes sharing a
linked store can interleave so that an older, smaller sample lands after a newer,
larger one and releases the pages of rows that still exist.

Answers `{error, limit}`, `{error, instance_limit}` or, for a finite `Ceiling`,
`{error, exceeds_max}` when what the store holds is past a ceiling. The charge
is still recorded: the rows exist whether or not a ceiling likes them, and
refusing to write down memory that has already been spent is how growth became
invisible. Recording it is a fact; the error is a decision about whether the
guest may continue.
""".
-spec reconcile(resource(), non_neg_integer() | infinity) ->
          ok | {error, limit | instance_limit | exceeds_max | gone
                     | keeper_unavailable}.
reconcile(Resource, Ceiling) ->
    reconcile(Resource, Ceiling, 0).

-doc """
As `reconcile/2`, refusing as though `Extra` words were already written.

What is recorded is still what the tables hold. `Extra` moves only the refusal,
so a caller about to write one very large row can be told no before the row
exists rather than after: a store is measured, and a measurement cannot see what
has not happened yet. One `struct.new_default` of a hundred thousand fields
walked through a one-page ceiling that way.
""".
-spec reconcile(resource(), non_neg_integer() | infinity, non_neg_integer()) ->
          ok | {error, limit | instance_limit | exceeds_max | gone
                     | keeper_unavailable}.
reconcile(Resource, Ceiling, Extra) ->
    call({reconcile, Resource, Ceiling, Extra}).

-doc """
Claim the right to grow `Resource` by `Delta`, up to `Ceiling` pages, as
operation `OpId`.

Answers the size before the growth. Every holder's ceiling and the node budget
are checked, and the chunks the growth needs are charged, before the answer.
Asking again with the same `OpId` answers the same: a caller that lost the
reply to a keeper restart resumes its own transaction rather than queueing
behind it. Concurrent growers of one memory queue rather than being refused.
""".
-spec grow_begin(resource(), reference(), non_neg_integer(),
                 non_neg_integer()) ->
          {ok, non_neg_integer()} | {done, term()}
        | {error, exceeds_max | limit | instance_limit | gone
                | keeper_unavailable}.
grow_begin(Resource, OpId, Delta, Ceiling) ->
    call({grow_begin, Resource, OpId, Delta, Ceiling}).

-doc """
Publish growth `OpId`: the chunk tuple, then the size, then the end of the
transaction. Answers the size before the growth, or `aborted` when a restart
found the grower gone and gave the growth back, or `stale` when this memory
has no such operation.
""".
-spec grow_commit(resource(), reference(), tuple()) ->
          {ok, non_neg_integer()} | aborted | stale
        | {error, keeper_unavailable}.
grow_commit(Resource, OpId, Chunks) ->
    call({grow_commit, Resource, OpId, Chunks}).

-doc "Give back growth `OpId` without publishing it. Always `ok` once answered.".
-spec grow_abort(resource(), reference()) -> ok | {error, keeper_unavailable}.
grow_abort(Resource, OpId) ->
    call({txn_abort, Resource, OpId}).

-doc """
Make sure the memory's arena has `Target` chunks, as operation `OpId`. The
caller names the published length it saw and the pages chunks from there to
`Target` cost. `covered` when another writer already published them,
`{changed, Have}` when the length moved and the cost has to be worked out
again, and `{ok, Have}` when the caller is to allocate chunks `Have + 1..Target`
and commit them.
""".
-spec arena_begin(resource(), reference(), pos_integer(),
                  {non_neg_integer(), non_neg_integer()}) ->
          covered | {ok, non_neg_integer()} | {changed, non_neg_integer()}
        | {done, term()} | {error, limit | gone | keeper_unavailable}.
arena_begin(Resource, OpId, Target, Pages) ->
    call({arena_begin, Resource, OpId, Target, Pages}).

-doc "Publish arena extension `OpId`. Never replaces a published tuple.".
-spec arena_commit(resource(), reference(), tuple()) ->
          ok | aborted | stale | {error, keeper_unavailable}.
arena_commit(Resource, OpId, Arena) ->
    call({arena_commit, Resource, OpId, Arena}).

-doc "Give back arena extension `OpId` without publishing it.".
-spec arena_abort(resource(), reference()) -> ok | {error, keeper_unavailable}.
arena_abort(Resource, OpId) ->
    call({txn_abort, Resource, OpId}).

-doc """
Forget the outcome kept for the caller's operation `OpId`, now that it has
the answer. Kept until then so a caller retrying after a lost reply gets its
own result back, whatever has happened to the memory since.
""".
-spec ack(resource(), reference()) -> ok.
ack(Resource, OpId) ->
    case whereis(?SERVER) of
        undefined -> ok;
        Pid -> gen_server:cast(Pid, {ack, Resource, OpId, self()})
    end.

-doc """
Charge an image's `Bytes` to the node's snapshot budget and register it, held
by `Owner` under `{snapshot, Id}`. The image is reclaimed, and its bytes given
back, when that holder has gone and no memory restored from it remains.
""".
-spec image_reserve(non_neg_integer(), pid(), reference()) ->
          {ok, resource()} | {error, wasm_error:error()}.
image_reserve(Bytes, Owner, Id) ->
    case call({image_reserve, Bytes, Owner, Id}) of
        {error, keeper_unavailable} ->
            {error, #{class => exhaustion, kind => snapshot_budget,
                      msg => ~"the keeper is not available",
                      ctx => #{wanted => Bytes}}};
        R -> R
    end.

-doc "Whether an image is registered and not being reclaimed.".
-spec image_live(resource()) -> boolean().
image_live(ImgRes) ->
    case row(ImgRes) of
        {_, {image, _}, _, _, #{state := live}} -> true;
        _ -> false
    end.

-doc "Pages currently reserved for a resource, or 0 if it is gone.".
-spec charge_of(resource()) -> non_neg_integer().
charge_of(Resource) ->
    case row(Resource) of
        {_, _, Pages, _, _} -> Pages;
        undefined -> 0
    end.

-doc "The holders of a resource, for tests and diagnostics.".
-spec holders_of(resource()) -> [token()].
holders_of(Resource) ->
    case row(Resource) of
        {_, _, _, Holders, _} -> lists:sort(maps:keys(Holders));
        undefined -> []
    end.

-doc "How many resources are registered. Diagnostics.".
-spec resources() -> non_neg_integer().
resources() ->
    ensure_table(),
    ets:info(?TAB, size).

row(Resource) ->
    case ets:whereis(?TAB) of
        undefined -> undefined;
        _ ->
            case ets:lookup(?TAB, Resource) of
                [Row] -> Row;
                [] -> undefined
            end
    end.

%%% ------------------------------------------------------------ plumbing ---

%% The keeper has to be reachable without the application, because the
%% conformance suite, escript embedding and plain unit tests all use memories
%% without starting anything. Routing a resource through a process that may not
%% exist is how the waiter table broke three `atomic.wast` assertions, so this
%% path is the same one `wasm_engine' already offers: start an unsupervised
%% keeper on demand, and let whoever loses the race use the winner's.
call(Req) ->
    try gen_server:call(keeper(), Req, infinity)
    catch exit:_ -> {error, keeper_unavailable}
    end.

keeper() ->
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
Create the registry table if it is not there.

`wasm_sup` calls this so the table belongs to the supervisor rather than to the
keeper: a keeper restart then finds its state where it left it instead of
starting from an empty registry with every resource on the node unaccounted
for. The table is `public` so the keeper writes to it directly, which keeps the
supervisor off a path anything waits on.
""".
-spec ensure_table() -> ok.
ensure_table() ->
    case ets:whereis(?TAB) of
        undefined ->
            try ets:new(?TAB, [named_table, set, public,
                               {read_concurrency, true},
                               {write_concurrency, true}])
            catch error:badarg -> ok
            end,
            ok;
        _ -> ok
    end.

%%% ------------------------------------------------------------ callbacks ---

%% held    :: #{pid() => #{{resource(), token()} => true}}
%% mons    :: #{pid() => reference()}
%% caps    :: #{token() => non_neg_integer()}, a holder's page ceiling
%% totals  :: #{token() => non_neg_integer()}, what it holds against that
%% queued  :: #{resource() => [{From, Request}]}, transactions waiting for the
%%            one in flight on that memory
%% writers :: #{pid() => {reference(), #{resource() => true}}}, the processes
%%            with a transaction in flight or an outcome not yet acknowledged,
%%            monitored so their death ends either
%% images  :: #{resource() => non_neg_integer()}, how many memory rows name
%%            each image; derived from the rows and rebuilt at every start
%%
%% A running total rather than an index from holder to memories. Growth has to
%% check every holder of the memory being grown, and a total is one map read
%% each where an index would be a sum over everything they hold.
init([]) ->
    ok = ensure_table(),
    %% A restart inherits the rows the previous keeper left, so the monitors
    %% are rebuilt from them. Without this the registry would survive and its
    %% death-release would not, which is the worse of the two halves to keep.
    {Held, Mons} = adopt(),
    S0 = #{held => Held, mons => Mons, queued => #{}, writers => #{},
           caps => adopt_caps(), totals => adopt_totals(),
           images => adopt_images()},
    %% Cleanups a dead keeper left half done, then the transactions it left in
    %% flight: each is finished if what it published is there, kept for a
    %% writer that is still alive, and undone for one that is not.
    S1 = finish_retiring(S0),
    S2 = recover_transactions(S1),
    S3 = sweep_images(S2),
    ok = reconcile_pages(),
    ok = reconcile_snapshot_bytes(),
    {ok, S3}.

%% Put the node page counter back in step with the registry.
%%
%% The counter is an `atomics' array in `persistent_term': it outlives this
%% process, the supervision tree, and `application:stop(wasm)'. The registry is
%% a table that does not. When the two part company the counter is the half that
%% survives, holding a charge for memories whose monitors are gone, so nothing
%% will ever release them: a killed tree used to cost the node eight megabytes
%% of budget per thirty-two page instance, permanently, accumulating across
%% application restarts until only a node restart cleared it.
%%
%% The registry is the truth, because it is the only thing that can give pages
%% back. Doing this here is race-free without any locking: every
%% `wasm_engine:reserve_pages/1' and `release_pages/1' call in the runtime is
%% made from this process, and callers block on `gen_server:call' until `init/1'
%% returns, so no reservation can be in flight while it runs.
reconcile_pages() ->
    Charged = ets:foldl(fun(Row, Acc) -> Acc + charged(Row) end, 0, ?TAB),
    %% Per resource row, not per holder: `adopt_totals/0' counts a two-holder
    %% memory twice on purpose, because it is building per-token totals. The
    %% node count must not.
    case wasm_engine:pages_in_use() - Charged of
        0 ->
            ok;
        Orphaned ->
            ok = wasm_engine:set_pages_in_use(Charged),
            logger:warning("wasm: page counter held ~p pages no holder claims; "
                           "reset to ~p to match the registry",
                           [Orphaned, Charged]),
            ok
    end.

%% What a row costs the node budget: a memory its page table, growth chunks
%% and arena, reserved or published; a heap or a cell its pages; an image
%% nothing, since images are counted in bytes against their own budget.
charged({_Res, {memory, _, _, _, _, _}, _L, H, #{phys := Phys}})
  when is_map(H) ->
    maps:fold(fun(_K, V, A) -> A + V end, 0, Phys);
charged({_Res, {image, _}, _L, H, _Ledger}) when is_map(H) ->
    0;
charged({_Res, _Meta, Pages, H, _Ledger}) when is_map(H) ->
    Pages;
charged(_Other) ->
    0.

%% The snapshot byte counter, rebuilt from the image rows as the page counter
%% is from the memory rows. Its reference is remembered in a row of its own,
%% so a node whose last image went while the keeper was down still finds it.
reconcile_snapshot_bytes() ->
    case snapshot_counter() of
        undefined ->
            ok;
        Ref ->
            Bytes = ets:foldl(fun({_, {image, B}, _, H, _}, A) when is_map(H) ->
                                      A + B;
                                 (_Other, A) -> A
                              end, 0, ?TAB),
            atomics:put(Ref, 1, Bytes)
    end.

snapshot_counter() ->
    case persistent_term:get(?SNAPSHOT_BUDGET_KEY, undefined) of
        {snapshot_counter, ?SNAPSHOT_BUDGET_VERSION, Ref} -> Ref;
        _ -> undefined
    end.

%% Rebuilt from the registry on a restart, for the same reason the monitors are.
%% Logical pages for a memory, which is what a holder's ceiling bounds; what a
%% heap or a cell is charged; nothing for an image.
adopt_totals() ->
    ets:foldl(
      fun({_Res, Meta, Pages, Holders, _}, Acc) when is_map(Holders) ->
          Counted = case Meta of {image, _} -> 0; _ -> Pages end,
          maps:fold(fun(Tok, _Owner, A) ->
                        A#{Tok => maps:get(Tok, A, 0) + Counted}
                    end, Acc, Holders);
         (_Other, Acc) -> Acc
      end, #{}, ?TAB).

%% And the ceilings, which used to be dropped. A keeper that came up with no
%% caps let every instance grow to the node budget: an instance created with a
%% two-page maximum refused the third page before a restart and took it after,
%% which is the limit `wasm:instantiate/3` promised being silently withdrawn.
%%
%% So a cap lives in the registry beside the pages it bounds, and goes when the
%% last page under its token goes.
adopt_caps() ->
    ets:foldl(fun({{cap, Tok}, Max}, Acc) -> Acc#{Tok => Max};
                 (_Other, Acc) -> Acc
              end, #{}, ?TAB).

adopt() ->
    ets:foldl(
      fun({Res, _Meta, _Pages, Holders, _}, Acc) when is_map(Holders) ->
          maps:fold(fun(_Tok, none, A) -> A;
                       (Tok, Pid, A) -> add_held(Pid, Res, Tok, A)
                    end, Acc, Holders);
         (_Other, Acc) -> Acc
      end, {#{}, #{}}, ?TAB).

adopt_images() ->
    ets:foldl(fun({_, {memory, _, _, _, Img, _}, _, H, _}, A)
                    when is_map(H), Img =/= undefined ->
                      A#{Img => maps:get(Img, A, 0) + 1};
                 (_Other, A) -> A
              end, #{}, ?TAB).

finish_retiring(State) ->
    Rows = ets:select(?TAB, [{{'_', '_', '_', '_', #{state => retiring}}, [],
                              ['$_']}]),
    lists:foldl(fun(Row, S) -> retire(Row, S) end, State, Rows).

%% Transactions the previous keeper left in flight, and outcomes it was keeping
%% for writers that had not acknowledged them.
recover_transactions(State) ->
    Rows = ets:select(?TAB, [{{'_', {memory, '_', '_', '_', '_', '_'}, '_', '_',
                               '_'}, [], ['$_']}]),
    lists:foldl(fun recover_row/2, State, Rows).

recover_row({Res, _Meta, _L, _H, #{txn := Txn, done := Done}} = Row, S0) ->
    %% Outcomes for writers still alive stay, watched; the rest go.
    Live = maps:filter(fun(Pid, _) -> is_process_alive(Pid) end, Done),
    S1 = maps:fold(fun(Pid, _, S) -> watch_writer(Pid, Res, S) end, S0, Live),
    Row1 = case map_size(Live) =:= map_size(Done) of
               true -> Row;
               false -> put_ledger(Row, done, Live)
           end,
    case Txn of
        none -> S1;
        T ->
            Pid = element(2, T),
            case is_process_alive(Pid) of
                true -> watch_writer(Pid, Res, S1);
                false -> settle(Res, Row1, T, S1)
            end
    end.

%% Images with no holder and no memory left, which a keeper killed between the
%% last release and the reclaim leaves behind.
sweep_images(State) ->
    Rows = ets:select(?TAB, [{{'_', {image, '_'}, '_', '_', '_'}, [], ['$_']}]),
    lists:foldl(fun({Img, _, _, H, _} = Row, S) ->
                        case map_size(H) =:= 0 andalso image_count(Img, S) =:= 0 of
                            true -> retire(Row, S);
                            false -> S
                        end
                end, State, Rows).

handle_call({bequeath, Heir}, _From, State) ->
    %% A no-op when the supervisor created the table itself, which is the
    %% ordinary case.
    case ets:info(?TAB, owner) of
        Owner when Owner =:= self() ->
            true = ets:setopts(?TAB, {heir, Heir, wasm_holders});
        _ ->
            ok
    end,
    {reply, ok, State};

handle_call({set_limit, Token, Max}, _From, #{caps := Caps} = State) ->
    true = ets:insert(?TAB, {{cap, Token}, Max}),
    {reply, ok, State#{caps := Caps#{Token => Max}}};

handle_call({total_of, Token}, _From, #{totals := Totals} = State) ->
    {reply, {ok, maps:get(Token, Totals, 0)}, State};

handle_call({reserve, Pages, Meta, Token, Owner, Limit}, _From, State0) ->
    State = pending_cap(Token, Limit, State0),
    case {within(Token, Pages, State), image_ok(Meta)} of
        {false, _} ->
            {reply, {error, instance_limit}, State};
        {true, false} ->
            {reply, {error, gone}, State};
        {true, true} ->
            Ledger = new_ledger(Meta, Pages),
            case wasm_engine:reserve_pages(charged({x, Meta, Pages, #{},
                                                    Ledger})) of
                {error, limit} ->
                    {reply, {error, limit}, State};
                ok ->
                    Res = make_ref(),
                    true = ets:insert(?TAB, {Res, Meta, Pages, #{Token => Owner},
                                             Ledger}),
                    S1 = count_image(Meta, 1, add_total(Token, Pages, State)),
                    {reply, {ok, Res}, watch(Owner, Res, Token, S1)}
            end
    end;

handle_call({acquire, Res, Token, Owner, Limit}, _From, State0) ->
    State = pending_cap(Token, Limit, State0),
    case ets:lookup(?TAB, Res) of
        [{Res, _Meta, _Pages, _Holders, #{state := retiring}}] ->
            {reply, {error, gone}, State};
        [] ->
            {reply, {error, gone}, State};
        [{Res, Meta, Pages, Holders, Ledger}] ->
            %% Idempotent by construction: one instance importing the same
            %% memory through two slots is one holder, which is what makes the
            %% accounting count memories rather than import slots, and what
            %% keeps a second slot from charging the ceiling twice.
            case maps:is_key(Token, Holders) of
                true ->
                    {reply, ok, State};
                false ->
                    case within(Token, Pages, State) of
                        false ->
                            {reply, {error, instance_limit}, State};
                        true ->
                            true = ets:insert(?TAB, {Res, Meta, Pages,
                                                     Holders#{Token => Owner},
                                                     Ledger}),
                            S1 = add_total(Token, Pages, State),
                            {reply, ok, watch(Owner, Res, Token, S1)}
                    end
            end
    end;

handle_call({release, Res, Token}, _From, State) ->
    {reply, ok, drop(Res, Token, State)};

handle_call({release_all, Pairs}, _From, State) ->
    {reply, ok, lists:foldl(fun({Res, Token}, S) -> drop(Res, Token, S) end,
                            State, Pairs)};

handle_call({discard, Token}, {Pid, _}, #{held := Held} = State) ->
    Mine = [Res || {Res, Tok} <- maps:keys(maps:get(Pid, Held, #{})),
                   Tok =:= Token],
    S1 = lists:foldl(fun(Res, S) -> drop(Res, Token, S) end, State, Mine),
    %% And the ceiling, which nothing else would take: `sub_total/3` drops one
    %% with the token's last page, and a build that failed before reserving
    %% anything has no page to drop.
    {reply, ok, forget_cap(Token, S1)};

handle_call({transfer, From, To, Owner}, {Pid, _}, #{held := Held} = State) ->
    %% Off the reverse index rather than a scan of the registry: what a builder
    %% accumulated is small, and the registry is every resource on the node.
    Moved = [Res || {Res, Tok} <- maps:keys(maps:get(Pid, Held, #{})),
                    Tok =:= From],
    %% The ceiling moves first. `retag' drops what the old token held, and
    %% dropping the last of it takes its ceiling with it, so moving after would
    %% leave the instance with no limit at all: growth was refused during the
    %% build and unbounded for the whole life of the instance afterwards.
    %% Nothing moved means the instance holds nothing to bound and never will:
    %% everything is acquired during the build, and growth only extends a
    %% memory that is already here. So the ceiling is dropped rather than
    %% carried, which is what keeps a cap from outliving every use of it.
    S1 = case Moved of
             [] -> forget_cap(From, State);
             _ -> move_cap(From, To, State)
         end,
    S2 = lists:foldl(fun(Res, S) -> retag(Res, From, To, Owner, S) end,
                     S1, Moved),
    {reply, ok, S2};

handle_call({reconcile, Res, Ceiling, Extra}, _From, State) ->
    ok = hook(charge_entry),
    case ets:lookup(?TAB, Res) of
        [{Res, {heap, Objs, Elems}, _Pages, _Holders, _}] ->
            Words = words_of(Objs) + words_of(Elems),
            Pages = pages_of(Words),
            %% These pages are spent, and the answer is only whether that,
            %% plus what the caller is about to write, put the holder or the
            %% node over.
            {reply, R, S1} =
                do_resize(Res, Pages, Ceiling, pages_of(Extra), State),
            {reply, R, S1};
        _ ->
            {reply, {error, gone}, State}
    end;

handle_call({image_reserve, Bytes, Owner, Id}, _From, State) ->
    case snapshot_counter() of
        undefined ->
            {reply, {error, #{class => invalid,
                              kind => snapshot_counter_uninitialised,
                              msg => ~"the snapshot budget counter is not initialised",
                              ctx => #{}}}, State};
        Ref ->
            Limit = application:get_env(wasm, max_snapshot_bytes, infinity),
            Now = atomics:add_get(Ref, 1, Bytes),
            case Limit =:= infinity orelse Now =< Limit of
                false ->
                    _ = atomics:sub_get(Ref, 1, Bytes),
                    {reply, {error, #{class => exhaustion,
                                      kind => snapshot_budget,
                                      msg => ~"the node snapshot budget is exhausted",
                                      ctx => #{limit => Limit, wanted => Bytes}}},
                     State};
                true ->
                    ok = hook(image_charged),
                    Img = make_ref(),
                    Token = {snapshot, Id},
                    true = ets:insert(?TAB, {Img, {image, Bytes}, 0,
                                             #{Token => Owner},
                                             #{state => live}}),
                    {reply, {ok, Img}, watch(Owner, Img, Token, State)}
            end
    end;

handle_call({grow_begin, Res, OpId, _Delta, _Ceiling} = Req, From, State) ->
    transaction(Res, OpId, Req, From, State);
handle_call({arena_begin, Res, OpId, _Target, _Pages} = Req, From, State) ->
    transaction(Res, OpId, Req, From, State);

handle_call({grow_commit, Res, OpId, Chunks}, {Pid, _}, State) ->
    case lookup(Res) of
        {Res, {memory, CRef, PagesRef, _, _, _}, _L, _H,
         #{txn := {OpId, _P, grow, From, To, _PD, CT}}} = Row ->
            ok = hook(grow_commit_start),
            ok = publish_chunks(CRef, Chunks, CT),
            ok = hook(grow_commit_chunks),
            PagesRef =:= undefined orelse atomics:put(PagesRef, 1, To),
            ok = hook(grow_commit_size),
            S1 = finish(Res, Row, Pid, OpId, {ok, From}, State),
            {reply, {ok, From}, next_transaction(Res, S1)};
        Row ->
            {reply, outcome(Row, Pid, OpId), State}
    end;

handle_call({arena_commit, Res, OpId, Arena}, {Pid, _}, State) ->
    case lookup(Res) of
        {Res, {memory, _, _, ARef, _, _}, _L, _H,
         #{txn := {OpId, _P, arena, _Have, Target, _PD}}} = Row ->
            ok = hook(arena_commit_start),
            ok = publish_chunks(ARef, Arena, Target),
            ok = hook(arena_commit_published),
            S1 = finish(Res, Row, Pid, OpId, ok, State),
            {reply, ok, next_transaction(Res, S1)};
        Row ->
            {reply, case outcome(Row, Pid, OpId) of
                        {ok, _} -> ok;
                        Other -> Other
                    end, State}
    end;

handle_call({txn_abort, Res, OpId}, {Pid, _}, State) ->
    case lookup(Res) of
        {Res, _, _, _, #{txn := {OpId, _, arena, _, _, _} = T}} = Row ->
            S1 = settle(Res, Row, T, State),
            {reply, ok, S1};
        {Res, _, _, _, #{txn := {OpId, _, _, _, _, _, _} = T}} = Row ->
            S1 = settle(Res, Row, T, State),
            {reply, ok, S1};
        _ ->
            {reply, ok, forget_outcome(Res, OpId, Pid, State)}
    end;

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({ack, Res, OpId, Pid}, State) ->
    {noreply, forget_outcome(Res, OpId, Pid, State)};
handle_cast(_Msg, State) -> {noreply, State}.

handle_info({'DOWN', MonRef, process, Pid, _Reason},
            #{writers := Writers} = State) ->
    %% A writer that died: its transactions are finished if what they published
    %% is there and undone if not, and the outcomes kept for it go.
    S1 = case maps:find(Pid, Writers) of
             {ok, {MonRef, Rs}} ->
                 S0 = State#{writers := maps:remove(Pid, Writers)},
                 lists:foldl(fun(Res, S) -> writer_gone(Res, Pid, S) end,
                             S0, maps:keys(Rs));
             _ ->
                 State
         end,
    {noreply, forget_holder(Pid, MonRef, S1)};

%% A heap whose creating process died. Named as heir by `wasm_heap:new/2` so
%% the store outlives the process that made it, which a linked instance in
%% another process may still be running on. It is deleted at the last holder,
%% like any other, so nothing more is needed here than owning it.
handle_info({'ETS-TRANSFER', _Tab, _From, wasm_heap}, State) ->
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%% ------------------------------------------------------------- ledger ---

lookup(Res) ->
    case ets:lookup(?TAB, Res) of
        [Row] -> Row;
        [] -> undefined
    end.

%% What a new row owes. A memory's charge is its geometry's; anything else is
%% charged its pages.
new_ledger({memory, _, _, _, _, {I, C}}, L) ->
    #{phys => #{table => table_pages(I), growth => growth_pages(L, I, C),
                arena => 0},
      txn => none, done => #{}, state => live};
new_ledger(_Meta, _Pages) ->
    #{state => live}.

%% Sixteen 64-bit entries per image page, and two more after them.
table_pages(0) -> 0;
table_pages(I) -> ((I * 16 + 2) * 8 + 65535) div 65536.

%% The growth chunks a memory of `L' pages has allocated past an image of `I',
%% in chunks of `C' pages. Image placeholders are not chunks and never count.
growth_pages(L, I, C) ->
    ((max(0, L - I) + C - 1) div C) * C.

chunk_count(L, C) -> (L + C - 1) div C.

image_ok({memory, _, _, _, Img, _}) when Img =/= undefined -> image_live(Img);
image_ok(_Meta) -> true.

count_image({memory, _, _, _, Img, _}, N, #{images := Imgs} = S)
  when Img =/= undefined ->
    S#{images := Imgs#{Img => maps:get(Img, Imgs, 0) + N}};
count_image(_Meta, _N, S) ->
    S.

image_count(Img, #{images := Imgs}) -> maps:get(Img, Imgs, 0).

put_ledger({Res, Meta, L, H, Ledger}, Key, Value) ->
    Row = {Res, Meta, L, H, Ledger#{Key => Value}},
    true = ets:insert(?TAB, Row),
    Row.

%% A growth or an arena extension. A retry of the caller's own operation is
%% answered from the row, so it never queues behind itself; anything else
%% waits for the transaction in flight on this memory.
transaction(Res, OpId, Req, {Pid, _} = From, State) ->
    case lookup(Res) of
        undefined ->
            {reply, {error, gone}, State};
        {Res, _, _, _, #{state := retiring}} ->
            {reply, {error, gone}, State};
        {Res, _, _, _, #{txn := Txn, done := Done}} = Row ->
            case {Txn, maps:find(Pid, Done)} of
                {_, {ok, {OpId, Result}}} ->
                    {reply, {done, Result}, State};
                {{OpId, _, grow, F, _, _, _}, _} ->
                    {reply, {ok, F}, State};
                {{OpId, _, arena, Have, _, _}, _} ->
                    {reply, {ok, Have}, State};
                {none, _} ->
                    {Reply, S1} = start(Req, Row, Pid, State),
                    {reply, Reply, S1};
                _Busy ->
                    #{queued := Q} = State,
                    Waiting = maps:get(Res, Q, []) ++ [{From, Req}],
                    {noreply, State#{queued := Q#{Res => Waiting}}}
            end;
        _ ->
            {reply, {error, gone}, State}
    end.

start({grow_begin, Res, OpId, Delta, Ceiling},
      {Res, {memory, _, _, _, _, {I, C}} = Meta, L, H, Ledger}, Pid, State) ->
    To = L + Delta,
    #{phys := Phys} = Ledger,
    PD = growth_pages(To, I, C) - growth_pages(L, I, C),
    Toks = maps:keys(H),
    %% Every holder, not just the one asking. A memory two instances share
    %% grows only as far as the stricter of them allows, or one of them would
    %% be growing past a ceiling the other was promised. Checked whether or not
    %% the growth needs a new chunk: capacity already allocated is not a
    %% licence to pass a limit.
    AllFit = lists:all(fun(T) -> within(T, Delta, State) end, Toks),
    if
        To > Ceiling ->
            {{error, exceeds_max}, State};
        not AllFit ->
            {{error, instance_limit}, State};
        true ->
            case wasm_engine:reserve_pages(PD) of
                {error, limit} ->
                    {{error, limit}, State};
                ok ->
                    ok = hook(grow_reserved),
                    Txn = {OpId, Pid, grow, L, To, PD, chunk_count(To, C)},
                    true = ets:insert(
                             ?TAB, {Res, Meta, To, H,
                                    Ledger#{phys := Phys#{growth :=
                                                maps:get(growth, Phys) + PD},
                                            txn := Txn,
                                            done := maps:remove(Pid,
                                                maps:get(done, Ledger))}}),
                    ok = hook(grow_begun),
                    S1 = lists:foldl(fun(T, S) -> add_total(T, Delta, S) end,
                                     State, Toks),
                    {{ok, L}, watch_writer(Pid, Res, S1)}
            end
    end;
start({arena_begin, Res, OpId, Target, {Seen, PD}},
      {Res, {memory, _, _, ARef, _, _} = Meta, L, H, Ledger}, Pid, State) ->
    Have = tuple_size(wasm_engine:cell_get(ARef)),
    if
        Have >= Target ->
            {covered, State};
        %% The charge was worked out from a published length that has moved
        %% since: the caller works it out again.
        Have =/= Seen ->
            {{changed, Have}, State};
        true ->
            case wasm_engine:reserve_pages(PD) of
                {error, limit} ->
                    {{error, limit}, State};
                ok ->
                    ok = hook(arena_reserved),
                    #{phys := Phys} = Ledger,
                    Txn = {OpId, Pid, arena, Have, Target, PD},
                    true = ets:insert(
                             ?TAB, {Res, Meta, L, H,
                                    Ledger#{phys := Phys#{arena :=
                                                maps:get(arena, Phys) + PD},
                                            txn := Txn,
                                            done := maps:remove(Pid,
                                                maps:get(done, Ledger))}}),
                    ok = hook(arena_begun),
                    {{ok, Have}, watch_writer(Pid, Res, State)}
            end
    end.

%% A tuple goes into its cell only while the cell is still shorter than the
%% tuple the transaction is for. A published tuple is never replaced: a slot
%% may already be living in one of its arrays.
publish_chunks(undefined, _Tuple, _Target) ->
    ok;
publish_chunks(Ref, Tuple, Target) ->
    case tuple_size(wasm_engine:cell_get(Ref)) < Target of
        true -> wasm_engine:cell_put(Ref, Tuple);
        false -> ok
    end.

%% The transaction ends with its outcome kept for its writer.
finish(Res, {Res, Meta, L, H, Ledger}, Pid, OpId, Result, State) ->
    #{done := Done} = Ledger,
    true = ets:insert(?TAB, {Res, Meta, L, H,
                             Ledger#{txn := none,
                                     done := Done#{Pid => {OpId, Result}}}}),
    ok = hook(txn_finished),
    watch_writer(Pid, Res, State).

%% What a commit for an operation that is not in flight is told: the outcome
%% kept for it, or that there is no such operation.
outcome({_, _, _, _, #{done := Done}}, Pid, OpId) ->
    case maps:find(Pid, Done) of
        {ok, {OpId, Result}} -> Result;
        _ -> stale
    end;
outcome(_Row, _Pid, _OpId) ->
    stale.

%% A transaction whose writer cannot finish it: dead, or asking to abort.
%% Finished when what it was to publish is already published, undone otherwise.
settle(Res, {Res, Meta, L, H, Ledger} = Row, Txn, State) ->
    case published(Meta, Txn) of
        true ->
            finish_published(Res, Row, Txn, State);
        false ->
            {OpId, Pid, Kind, A, B, PD} = undo_shape(Txn),
            #{phys := Phys, done := Done} = Ledger,
            Key = case Kind of grow -> growth; arena -> arena end,
            L1 = case Kind of grow -> A; arena -> L end,
            true = ets:insert(?TAB, {Res, Meta, L1, H,
                                     Ledger#{phys := Phys#{Key :=
                                                 maps:get(Key, Phys) - PD},
                                             txn := none,
                                             done := Done#{Pid =>
                                                 {OpId, aborted}}}}),
            ok = hook(txn_undone),
            ok = wasm_engine:release_pages(PD),
            S1 = case Kind of
                     grow ->
                         lists:foldl(fun(T, S) -> sub_total(T, B - A, S) end,
                                     State, maps:keys(H));
                     arena ->
                         State
                 end,
            next_transaction(Res, S1)
    end.

undo_shape({OpId, Pid, grow, From, To, PD, _CT}) -> {OpId, Pid, grow, From, To, PD};
undo_shape({OpId, Pid, arena, Have, Target, PD}) ->
    {OpId, Pid, arena, Have, Target, PD}.

%% Whether a transaction's first visible effect happened. For a growth that
%% allocated chunks that is the chunk tuple, which is published before the
%% size; for one inside capacity it is the size itself, since capacity proves
%% nothing. A private memory publishes nothing at all: its only copy of a
%% growth is in its grower's handle.
published({memory, CRef, PagesRef, _, _, _},
          {_OpId, _Pid, grow, _From, To, PD, CT}) ->
    case {CRef, PD} of
        {undefined, _} -> false;
        {_, 0} -> atomics:get(PagesRef, 1) >= To;
        _ -> tuple_size(wasm_engine:cell_get(CRef)) >= CT
    end;
published({memory, _, _, ARef, _, _}, {_OpId, _Pid, arena, _Have, Target, _}) ->
    tuple_size(wasm_engine:cell_get(ARef)) >= Target.

finish_published(Res, Row, {OpId, Pid, grow, From, To, _PD, _CT}, State) ->
    {Res, {memory, _, PagesRef, _, _, _}, _, _, _} = Row,
    atomics:put(PagesRef, 1, To),
    next_transaction(Res, finish(Res, Row, Pid, OpId, {ok, From}, State));
finish_published(Res, Row, {OpId, Pid, arena, _Have, _Target, _PD}, State) ->
    next_transaction(Res, finish(Res, Row, Pid, OpId, ok, State)).

next_transaction(Res, #{queued := Queued} = State) ->
    case maps:get(Res, Queued, []) of
        [] ->
            State#{queued := maps:remove(Res, Queued)};
        [{From, Req} | Rest] ->
            S0 = State#{queued := Queued#{Res => Rest}},
            OpId = element(3, Req),
            case transaction(Res, OpId, Req, From, S0) of
                {reply, Reply, S1} ->
                    gen_server:reply(From, Reply),
                    %% A refusal or an answer from the row frees the slot
                    %% again, so the rest of the queue is not left waiting.
                    case lookup(Res) of
                        {_, _, _, _, #{txn := none}} -> next_transaction(Res, S1);
                        _ -> S1
                    end;
                {noreply, S1} ->
                    S1
            end
    end.

watch_writer(Pid, Res, #{writers := Writers} = State) ->
    case maps:find(Pid, Writers) of
        {ok, {Mon, Rs}} ->
            State#{writers := Writers#{Pid => {Mon, Rs#{Res => true}}}};
        error ->
            Mon = erlang:monitor(process, Pid),
            State#{writers := Writers#{Pid => {Mon, #{Res => true}}}}
    end.

%% A writer died: its transaction on `Res', if any, is settled, and the
%% outcome kept for it goes.
writer_gone(Res, Pid, State) ->
    case lookup(Res) of
        {Res, _, _, _, #{txn := Txn, done := Done}} = Row ->
            Row1 = case maps:is_key(Pid, Done) of
                       true -> put_ledger(Row, done, maps:remove(Pid, Done));
                       false -> Row
                   end,
            case Txn of
                {_, Pid, _, _, _, _} -> settle(Res, Row1, Txn, State);
                {_, Pid, _, _, _, _, _} -> settle(Res, Row1, Txn, State);
                _ -> State
            end;
        _ ->
            State
    end.

forget_outcome(Res, OpId, Pid, State) ->
    case lookup(Res) of
        {Res, _, _, _, #{done := Done}} = Row ->
            case maps:find(Pid, Done) of
                {ok, {OpId, _}} ->
                    _ = put_ledger(Row, done, maps:remove(Pid, Done)),
                    unwatch_writer(Pid, Res, State);
                _ ->
                    State
            end;
        _ ->
            unwatch_writer(Pid, Res, State)
    end.

%% A writer with nothing left on `Res': no transaction, no outcome kept.
unwatch_writer(Pid, Res, #{writers := Writers} = State) ->
    case maps:find(Pid, Writers) of
        {ok, {Mon, Rs}} ->
            case maps:remove(Res, Rs) of
                Empty when map_size(Empty) =:= 0 ->
                    erlang:demonitor(Mon, [flush]),
                    State#{writers := maps:remove(Pid, Writers)};
                Rest ->
                    State#{writers := Writers#{Pid => {Mon, Rest}}}
            end;
        error ->
            State
    end.

move_cap(From, To, #{caps := Caps} = State) ->
    case maps:take(From, Caps) of
        {Max, Rest} ->
            true = ets:delete(?TAB, {cap, From}),
            true = ets:insert(?TAB, {{cap, To}, Max}),
            State#{caps := Rest#{To => Max}};
        error ->
            State
    end.

%% A ceiling carried by a build's own reservation. Only the first one sets it:
%% the build names one ceiling and every later call carries the same.
pending_cap(_Token, undefined, State) ->
    State;
pending_cap(Token, Max, #{caps := Caps} = State) ->
    case maps:is_key(Token, Caps) of
        true  -> State;
        false -> true = ets:insert(?TAB, {{cap, Token}, Max}),
                 State#{caps := Caps#{Token => Max}}
    end.

forget_cap(Token, #{caps := Caps} = State) ->
    true = ets:delete(?TAB, {cap, Token}),
    State#{caps := maps:remove(Token, Caps)}.

%% Whether this holder can take `Pages` more without passing its ceiling.
within(Token, Pages, #{caps := Caps, totals := Totals}) ->
    case maps:get(Token, Caps, infinity) of
        infinity -> true;
        Max -> maps:get(Token, Totals, 0) + Pages =< Max
    end.

add_total(_Token, 0, State) ->
    State;
add_total(Token, Pages, #{totals := Totals} = State) ->
    State#{totals := Totals#{Token => maps:get(Token, Totals, 0) + Pages}}.

sub_total(Token, Pages, #{totals := Totals, caps := Caps} = State) ->
    case maps:get(Token, Totals, 0) - Pages of
        N when N =< 0 ->
            %% Nothing left under this token, so its ceiling goes with it. A
            %% build token that was transferred, or an instance destroyed.
            true = ets:delete(?TAB, {cap, Token}),
            State#{totals := maps:remove(Token, Totals),
                   caps := maps:remove(Token, Caps)};
        N ->
            State#{totals := Totals#{Token => N}}
    end.

%%% -------------------------------------------------------------- holders ---

%% `manual' is the token with no process behind it, which is exactly what makes
%% a standalone shared memory outlive its creator.
watch(none, _Res, _Token, State) ->
    State;
watch(Pid, Res, Token, #{held := Held, mons := Mons} = State) ->
    {Held1, Mons1} = add_held(Pid, Res, Token, {Held, Mons}),
    State#{held := Held1, mons := Mons1}.

add_held(Pid, Res, Token, {Held, Mons}) ->
    Mons1 = case maps:is_key(Pid, Mons) of
                true -> Mons;
                %% A monitor on an already-dead process delivers `DOWN'
                %% immediately, so a holder that died during its own
                %% registration is released rather than missed.
                false -> Mons#{Pid => erlang:monitor(process, Pid)}
            end,
    Mine = maps:get(Pid, Held, #{}),
    {Held#{Pid => Mine#{{Res, Token} => true}}, Mons1}.

%% What a holder counts against its ceiling: a memory's logical pages, a heap's
%% or a cell's charge, nothing for an image.
counted({image, _}, _Pages) -> 0;
counted(_Meta, Pages) -> Pages.

drop(Res, Token, State) ->
    case lookup(Res) of
        undefined ->
            State;
        {Res, Meta, Pages, Holders, Ledger} = Row ->
            case maps:take(Token, Holders) of
                error ->
                    State;
                {Owner, Rest} ->
                    S1 = unhold(Owner, Res, Token,
                                sub_total(Token, counted(Meta, Pages), State)),
                    case map_size(Rest) =:= 0 andalso reclaimable(Meta, Res, S1) of
                        true ->
                            retire(setelement(4, Row, Rest), S1);
                        false ->
                            true = ets:insert(?TAB, {Res, Meta, Pages, Rest,
                                                     Ledger}),
                            S1
                    end
            end
    end.

%% An image outlives its last snapshot holder for as long as a memory restored
%% from it remains, because that memory reads the image's pages.
reclaimable({image, _}, Img, State) -> image_count(Img, State) =:= 0;
reclaimable(_Meta, _Res, _State) -> true.

retag(Res, From, To, Owner, State) ->
    case lookup(Res) of
        {Res, Meta, Pages, Holders, Ledger} ->
            case maps:take(From, Holders) of
                {Old, Rest} ->
                    true = ets:insert(?TAB, {Res, Meta, Pages,
                                             Rest#{To => Owner}, Ledger}),
                    N = counted(Meta, Pages),
                    S1 = add_total(To, N, sub_total(From, N, State)),
                    watch(Owner, Res, To, unhold(Old, Res, From, S1));
                error ->
                    State
            end;
        undefined -> State
    end.

unhold(none, _Res, _Token, State) ->
    State;
unhold(Pid, Res, Token, #{held := Held} = State) ->
    case maps:find(Pid, Held) of
        error ->
            State;
        {ok, Mine} ->
            case maps:remove({Res, Token}, Mine) of
                Empty when map_size(Empty) =:= 0 -> unwatch(Pid, State);
                Rest -> State#{held := Held#{Pid => Rest}}
            end
    end.

unwatch(Pid, #{held := Held, mons := Mons} = State) ->
    case maps:take(Pid, Mons) of
        {Ref, Rest} ->
            erlang:demonitor(Ref, [flush]),
            State#{held := maps:remove(Pid, Held), mons := Rest};
        error ->
            State#{held := maps:remove(Pid, Held)}
    end.

%% Everything this process still held is unreachable now. Only when `MonRef' is
%% the holder monitor: a writer's monitor is a different one.
forget_holder(Pid, MonRef, #{held := Held, mons := Mons} = State) ->
    case maps:find(Pid, Mons) of
        {ok, MonRef} ->
            Mine = maps:get(Pid, Held, #{}),
            S0 = State#{held := maps:remove(Pid, Held),
                        mons := maps:remove(Pid, Mons)},
            lists:foldl(fun({Res, Token}, S) -> drop(Res, Token, S) end,
                        S0, maps:keys(Mine));
        _ ->
            State
    end.

%% The end of a resource, restartable. The row is marked first, so a keeper
%% killed anywhere after that finds the duty to finish and finishes it: the
%% cells are forgotten before the row that names them goes, the row before the
%% charge is given back, and the memory before its image.
retire({Res, Meta, Pages, H, Ledger} = Row0, State) ->
    Row = case Ledger of
              #{state := retiring} -> Row0;
              _ -> R = {Res, Meta, Pages, H, Ledger#{state => retiring}},
                   true = ets:insert(?TAB, R),
                   R
          end,
    ok = hook(retiring),
    ok = forget_meta(Res, Meta),
    ok = hook(forgotten),
    true = ets:delete(?TAB, Res),
    ok = hook(deleted),
    ok = give_back(Row),
    after_retire(Meta, State).

give_back({_, {image, Bytes}, _, _, _}) ->
    case snapshot_counter() of
        undefined -> ok;
        Ref -> _ = atomics:sub_get(Ref, 1, Bytes), ok
    end;
give_back(Row) ->
    wasm_engine:release_pages(charged(Row)).

after_retire({memory, _, _, _, Img, _} = Meta, State) when Img =/= undefined ->
    S1 = count_image(Meta, -1, State),
    case {image_count(Img, S1), lookup(Img)} of
        {0, {Img, {image, _}, _, H, _} = ImgRow} when map_size(H) =:= 0 ->
            retire(ImgRow, S1);
        _ ->
            S1
    end;
after_retire(_Meta, State) ->
    State.

forget_meta(_Res, {memory, CRef, _, ARef, _, _}) ->
    CRef =:= undefined orelse wasm_engine:cell_forget(CRef),
    ARef =:= undefined orelse wasm_engine:cell_forget(ARef),
    ok;
forget_meta(_Res, {image, _}) -> ok;
forget_meta(Res, cell) -> wasm_engine:cell_forget(Res);
%% A heap's two tables, which nothing else is left to delete.
%%
%% They used to be dropped by `wasm_heap:delete/2` when the *instance registry
%% map* emptied, which is a different question from whether anything still holds
%% the resource: a build holding it between `acquire/3` and `register/3` was
%% left with both tables gone and its pages still charged. It is also the only
%% place that covers a last holder whose process simply died, where no
%% `delete/2` is ever called.
%%
%% Deleting a table from a process that does not own it is allowed while it is
%% `public`, which both of these are.
forget_meta(_Res, {heap, Objs, Elems}) ->
    try ets:delete(Objs) catch error:badarg -> true end,
    try ets:delete(Elems) catch error:badarg -> true end,
    ok;
forget_meta(_Res, _Other) ->
    ok.

%% A table that has already gone answers `undefined`, which is a heap being torn
%% down while a reconcile was in flight.
words_of(Tab) ->
    case ets:info(Tab, memory) of
        undefined -> 0;
        N -> N
    end.

%%% ---------------------------------------------------------------- heaps ---

pages_of(Words) ->
    (Words * erlang:system_info(wordsize) + 65535) div 65536.

%% Up or down to what the tables were just measured at.
%%
%% There used to be a second caller, `resize/3`, taking an absolute size from
%% whoever asked. That is the shape this function was moved here to make
%% unrepresentable: it could set a live fourteen-page store to zero without
%% looking at it. Nothing used it.
do_resize(Res, Want, Ceiling, Extra, State) ->
    case lookup(Res) of
        undefined ->
            {reply, {error, gone}, State};
        {Res, Meta, Pages, Holders, Ledger} when Want < Pages ->
            %% Giving pages back never fails and never consults a ceiling.
            Back = Pages - Want,
            true = ets:insert(?TAB, {Res, Meta, Want, Holders, Ledger}),
            ok = wasm_engine:release_pages(Back),
            S1 = lists:foldl(fun(T, S) -> sub_total(T, Back, S) end,
                             State, maps:keys(Holders)),
            {reply, ok, S1};
        %% Including `Want =:= Pages`, which is not a no-op: a resource that
        %% is *already* over a holder's ceiling has to keep saying so, or a
        %% guest whose next interval happens not to move the page count is let
        %% through. `within/3` asks about the total, not about the delta.
        {Res, Meta, Pages, Holders, Ledger} ->
            Delta = Want - Pages,
            Toks = maps:keys(Holders),
            grow(Res, Meta, Want, Delta, Holders, Ledger, Toks,
                 ceilings(Want, Ceiling, Delta, Extra, Toks, State),
                 Extra, State)
    end.

%% Which ceiling refuses this growth, if any. Asked before the node budget so
%% the answer can name a reason and the charge still be recorded.
%%
%% `Extra` is what the caller is about to write and the tables cannot show yet.
%% It counts against every ceiling and is recorded nowhere.
ceilings(Want, Ceiling, Delta, Extra, Toks, State) ->
    AllFit = lists:all(fun(T) -> within(T, Delta + Extra, State) end, Toks),
    if
        Ceiling =/= infinity andalso Want + Extra > Ceiling ->
            {error, exceeds_max};
        not AllFit ->
            {error, instance_limit};
        true ->
            ok
    end.

%% This memory is already spent. The rows exist whether or not a ceiling likes
%% them, so the registry row, the holder totals and the node counter all move to
%% the measured size and the refusal is only the *answer*. Leaving them behind
%% was how a heap sat at twelve pages charged for six, once per heap.
grow(Res, Meta, Want, Delta, Holders, Ledger, Toks, Ceil, Extra, State) ->
    Node = wasm_engine:charge_pages(Delta, Extra),
    true = ets:insert(?TAB, {Res, Meta, Want, Holders, Ledger}),
    S1 = lists:foldl(fun(T, S) -> add_total(T, Delta, S) end, State, Toks),
    {reply, first_error(Ceil, Node), S1}.

first_error(ok, R) -> R;
first_error({error, _} = E, _R) -> E.

-ifdef(TEST).
%% A sync point inside a transaction, for a test to hold a process at or to
%% kill the keeper at. `charge_entry' is the top of the heap charge, where an
%% older, smaller sample used to land after a newer, larger one; the others are
%% the boundaries between the effects of a growth, an arena extension and a
%% reclaim. A test cannot land in those windows by racing, and holding the
%% keeper here makes the schedule exact. Never compiled into a release.
hook(Where) ->
    case application:get_env(wasm, keeper_hook) of
        {ok, F} when is_function(F, 1) -> _ = F(Where), ok;
        _ -> ok
    end.
-else.
hook(_Where) -> ok.
-endif.
