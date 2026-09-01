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
many pages a resource has. That is why `free/1` releases the size the memory is
now rather than the size the handle was made at.
""".
-behaviour(gen_server).

-export([start_link/0, ensure_table/0]).
-export([reserve/4, acquire/3, release/2, transfer/3, discard/1]).
-export([set_limit/2, total_of/1]).
-export([grow_begin/3, grow_commit/4, grow_abort/2]).
-export([resize/3, reconcile/2]).
-export([charge_of/1, holders_of/1, resources/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).
-define(TAB, wasm_holders).

-doc "A holder of a resource. Removing one that is absent is a no-op.".
-type token() :: {instance, reference()}
               | {process, pid()}
               | {build, reference()}
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
                 undefined | atomics:atomics_ref()}
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
names it by.
""".
-spec reserve(non_neg_integer(), meta(), token(), pid() | none) ->
          {ok, resource()}
        | {error, limit | instance_limit | keeper_unavailable}.
reserve(Pages, Meta, Token, Owner) ->
    call({reserve, Pages, Meta, Token, Owner}).

-doc """
Add a holder to a resource that already exists.

`{error, gone}` means the last holder released it before you got here, which an
importer has to treat as a link failure rather than as a memory it may use.
""".
-spec acquire(resource(), token(), pid() | none) ->
          ok | {error, gone | instance_limit | keeper_unavailable}.
acquire(Resource, Token, Owner) -> call({acquire, Resource, Token, Owner}).

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
Move every token `From` holds onto `To`, atomically.

Used when a build succeeds: the entries a builder accumulated become the
instance's, without a window in which they belong to neither.
""".
-spec transfer(token(), token(), pid() | none) -> ok.
transfer(From, To, Owner) ->
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

Answers `{error, limit}` or `{error, instance_limit}` when what the store holds
is past a ceiling. The charge is still recorded: the rows exist whether or not a
ceiling likes them, and refusing to write down memory that has already been
spent is how growth became invisible. Recording it is a fact; the error is a
decision about whether the guest may continue.
""".
-spec reconcile(resource(), non_neg_integer() | infinity) ->
          ok | {error, limit | instance_limit | gone | keeper_unavailable}.
reconcile(Resource, Ceiling) ->
    call({reconcile, Resource, Ceiling}).

-doc """
Set a resource's charge to `Pages`, up or down, in one call.

For a resource whose size is *discovered* rather than requested. A memory grows
by a delta the guest asked for, and allocating its chunks has to happen outside
this process, which is what `grow_begin/3` and `grow_commit/4` are for. A
garbage-collected heap has no chunks to publish and its rows already exist by
the time anyone measures them: what changes is only the number, and it can fall
as well as rise.

A decrease is always allowed and cannot fail. An increase is checked against
every holder's ceiling and the node budget, exactly as a growth is, so a heap
shared by two instances is bounded by the stricter of them.
""".
-spec resize(resource(), non_neg_integer(), non_neg_integer() | infinity) ->
          ok | {error, limit | instance_limit | exceeds_max | gone
                     | keeper_unavailable}.
resize(Resource, Pages, Ceiling) ->
    call({resize, Resource, Pages, Ceiling}).

-doc """
Claim the right to grow `Resource` by `Delta`, up to `Ceiling` pages.

Answers the authoritative current size, which is what the new chunk tuple has
to be built against: another holder may have grown this memory since the caller
last looked. Concurrent growers queue here rather than being refused.
""".
-spec grow_begin(resource(), non_neg_integer(), non_neg_integer()) ->
          {ok, reference(), non_neg_integer()}
        | {error, exceeds_max | limit | instance_limit | gone
                | keeper_unavailable}.
grow_begin(Resource, Delta, Ceiling) ->
    call({grow_begin, Resource, Delta, Ceiling}).

-doc """
Publish the chunk tuple and the new size together, ending the growth.

`stale` when the keeper has no record of this growth, which a restart between
`grow_begin/3` and here produces: it rolled the reservation back, so publishing
now would put a size into the store that nothing is charged for. The caller
gives up and the guest sees -1.
""".
-spec grow_commit(resource(), reference(), tuple(), non_neg_integer()) ->
          ok | stale.
grow_commit(Resource, GrowRef, Chunks, NewPages) ->
    case call({grow_commit, Resource, GrowRef, Chunks, NewPages}) of
        ok -> ok;
        stale -> stale;
        %% No keeper at all is not the same as a keeper that disowned this
        %% growth: nothing rolled anything back, so the local extension stands.
        {error, keeper_unavailable} -> ok
    end.

-doc "Give back a growth's reservation without publishing anything.".
-spec grow_abort(resource(), reference()) -> ok.
grow_abort(Resource, GrowRef) ->
    case call({grow_abort, Resource, GrowRef}) of
        ok -> ok;
        {error, keeper_unavailable} -> ok
    end.

-doc "Pages currently reserved for a resource, or 0 if it is gone.".
-spec charge_of(resource()) -> non_neg_integer().
charge_of(Resource) ->
    case row(Resource) of
        {_, _, Pages, _} -> Pages;
        undefined -> 0
    end.

-doc "The holders of a resource, for tests and diagnostics.".
-spec holders_of(resource()) -> [token()].
holders_of(Resource) ->
    case row(Resource) of
        {_, _, _, Holders} -> lists:sort(maps:keys(Holders));
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
%% growing :: #{resource() => {reference(), pid(), reference(), Delta}}
%% caps    :: #{token() => non_neg_integer()}, a holder's page ceiling
%% totals  :: #{token() => non_neg_integer()}, what it holds against that
%%
%% A running total rather than an index from holder to memories. Growth has to
%% check every holder of the memory being grown, and a total is one map read
%% each where an index would be a sum over everything they hold.
%% queued  :: #{resource() => [{From, Delta, Ceiling}]}
init([]) ->
    ok = ensure_table(),
    %% A restart inherits the rows the previous keeper left, so the monitors
    %% are rebuilt from them. Without this the registry would survive and its
    %% death-release would not, which is the worse of the two halves to keep.
    {Held, Mons} = adopt(),
    %% And the growths in flight, which used to be forgotten. The charge moves
    %% at `grow_begin` and the size is published at `grow_commit`, so a keeper
    %% that came up believing nothing was growing left the memory charged for
    %% pages the guest could not see, and then answered the *next* grow with
    %% that inflated size as its previous one. `memory.grow` promises the guest
    %% the size before the growth, so that is a specification violation and not
    %% only a leak.
    {Growing, Totals, Caps} = adopt_growths(adopt_totals(), adopt_caps()),
    ok = reconcile_pages(),
    {ok, #{held => Held, mons => Mons, growing => Growing, queued => #{},
           caps => Caps, totals => Totals}}.

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
    Charged = ets:foldl(fun({_Res, _Meta, Pages, H}, Acc) when is_map(H) ->
                                Acc + Pages;
                           (_Other, Acc) -> Acc
                        end, 0, ?TAB),
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

%% Rebuilt from the registry on a restart, for the same reason the monitors are.
adopt_totals() ->
    ets:foldl(
      fun({_Res, _Meta, Pages, Holders}, Acc) when is_map(Holders) ->
          maps:fold(fun(Tok, _Owner, A) ->
                        A#{Tok => maps:get(Tok, A, 0) + Pages}
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
      fun({Res, _Meta, _Pages, Holders}, Acc) when is_map(Holders) ->
          maps:fold(fun(_Tok, none, A) -> A;
                       (Tok, Pid, A) -> add_held(Pid, Res, Tok, A)
                    end, Acc, Holders);
         (_Other, Acc) -> Acc
      end, {#{}, #{}}, ?TAB).

%% Growths the previous keeper was holding when it died.
%%
%% A live grower keeps its transaction: it is between `extend/3` and
%% `grow_commit/4` and may still succeed, so the monitor is rebuilt and the
%% entry restored. A dead one cannot, and its reservation goes back the way the
%% `DOWN` handler would have given it back.
%%
%% The `{growing, Res}` row exists for this and for nothing else. The state map
%% did not survive the restart and the charge did, which is the asymmetry that
%% made the defect.
adopt_growths(Totals, Caps) ->
    Rows = ets:select(?TAB, [{{{growing, '$1'}, '$2'}, [], [{{'$1', '$2'}}]}]),
    lists:foldl(
      fun({Res, {GrowRef, Pid, Delta}}, {G, T, C}) ->
          case is_process_alive(Pid) of
              true ->
                  MonRef = erlang:monitor(process, Pid),
                  {G#{Res => {GrowRef, Pid, MonRef, Delta}}, T, C};
              false ->
                  true = ets:delete(?TAB, {growing, Res}),
                  %% `caps` as well as `totals`: `sub_total/3` drops a token's
                  %% ceiling with its last page, and this runs before the state
                  %% map exists.
                  #{totals := T1, caps := C1} =
                      unreserve(Res, Delta, #{totals => T, caps => C}),
                  {G, T1, C1}
          end
      end, {#{}, Totals, Caps}, Rows).

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

handle_call({reserve, Pages, Meta, Token, Owner}, _From, State) ->
    case within(Token, Pages, State) of
        false ->
            {reply, {error, instance_limit}, State};
        true ->
            case wasm_engine:reserve_pages(Pages) of
                {error, limit} ->
                    {reply, {error, limit}, State};
                ok ->
                    Res = make_ref(),
                    true = ets:insert(?TAB, {Res, Meta, Pages, #{Token => Owner}}),
                    S1 = add_total(Token, Pages, State),
                    {reply, {ok, Res}, watch(Owner, Res, Token, S1)}
            end
    end;

handle_call({acquire, Res, Token, Owner}, _From, State) ->
    case ets:lookup(?TAB, Res) of
        [] ->
            {reply, {error, gone}, State};
        [{Res, Meta, Pages, Holders}] ->
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
                                                     Holders#{Token => Owner}}),
                            S1 = add_total(Token, Pages, State),
                            {reply, ok, watch(Owner, Res, Token, S1)}
                    end
            end
    end;

handle_call({release, Res, Token}, _From, State) ->
    {reply, ok, drop(Res, Token, State)};

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

handle_call({reconcile, Res, Ceiling}, _From, State) ->
    ok = hook(charge_entry),
    case ets:lookup(?TAB, Res) of
        [{Res, {heap, Objs, Elems}, _Pages, _Holders}] ->
            Words = words_of(Objs) + words_of(Elems),
            Pages = (Words * erlang:system_info(wordsize) + 65535) div 65536,
            %% `record`: these pages are spent, and the answer is only whether
            %% that put the holder or the node over.
            {reply, R, S1} = do_resize(Res, Pages, Ceiling, record, State),
            {reply, R, S1};
        _ ->
            {reply, {error, gone}, State}
    end;

handle_call({resize, Res, Want, Ceiling}, _From, State) ->
    ok = hook(charge_entry),
    {reply, R, S1} = do_resize(Res, Want, Ceiling, request, State),
    {reply, R, S1};

handle_call({grow_begin, Res, Delta, Ceiling}, From,
            #{growing := Growing} = State) ->
    case maps:is_key(Res, Growing) of
        true ->
            %% Queued, not refused. A refusal would surface as -1 to the guest,
            %% which the specification reserves for a budget that really is
            %% exhausted rather than for a momentarily busy registry.
            Q = maps:get(Res, maps:get(queued, State), []),
            {noreply, State#{queued := (maps:get(queued, State))
                                       #{Res => Q ++ [{From, Delta, Ceiling}]}}};
        false ->
            {Reply, S1} = start_growth(Res, Delta, Ceiling, From, State),
            {reply, Reply, S1}
    end;

handle_call({grow_commit, Res, GrowRef, Chunks, NewPages}, _From,
            #{growing := Growing} = State) ->
    case maps:find(Res, Growing) of
        {ok, {GrowRef, _Pid, MonRef, _Delta}} ->
            erlang:demonitor(MonRef, [flush]),
            true = ets:delete(?TAB, {growing, Res}),
            ok = publish(Res, Chunks, NewPages),
            {reply, ok, next_growth(Res, State#{growing := maps:remove(Res, Growing)})};
        %% A transaction this keeper does not have. It answered `ok` and
        %% published nothing, so the guest believed it had grown while the store
        %% still held the old size and the old chunk tuple, and the next grow
        %% reported the inflated charge as the previous size. `stale` instead,
        %% and the grower gives up: a refused `memory.grow` is a legal -1 and a
        %% silently unpublished one is not.
        _ ->
            {reply, stale, State}
    end;

handle_call({grow_abort, Res, GrowRef}, _From, #{growing := Growing} = State) ->
    case maps:find(Res, Growing) of
        {ok, {GrowRef, _Pid, MonRef, Delta}} ->
            erlang:demonitor(MonRef, [flush]),
            true = ets:delete(?TAB, {growing, Res}),
            %% Removed from `growing', which this did not do. The commit path
            %% and the `DOWN' handler both did, so an aborted growth was the one
            %% way out that left the resource marked as growing for ever, and
            %% `grow_begin/3' queues behind that mark on an `infinity' call:
            %% every later grow of that memory blocked, permanently, with no
            %% error and no timeout.
            Left = maps:remove(Res, Growing),
            {reply, ok,
             next_growth(Res, unreserve(Res, Delta, State#{growing := Left}))};
        _ ->
            {reply, ok, State}
    end;

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info({'DOWN', MonRef, process, Pid, _Reason},
            #{growing := Growing} = State) ->
    %% A grower that died between claiming the growth and committing it. Its
    %% reservation goes back, and whoever is queued behind it proceeds.
    Aborted = [{Res, Delta} || {Res, {_G, P, M, Delta}} <- maps:to_list(Growing),
                               P =:= Pid, M =:= MonRef],
    S1 = lists:foldl(
           fun({Res, Delta}, S) ->
               Left = maps:remove(Res, maps:get(growing, S)),
               true = ets:delete(?TAB, {growing, Res}),
               next_growth(Res, unreserve(Res, Delta, S#{growing := Left}))
           end, State, Aborted),
    {noreply, forget_holder(Pid, S1)};

handle_info(_Info, State) ->
    {noreply, State}.

move_cap(From, To, #{caps := Caps} = State) ->
    case maps:take(From, Caps) of
        {Max, Rest} ->
            true = ets:delete(?TAB, {cap, From}),
            true = ets:insert(?TAB, {{cap, To}, Max}),
            State#{caps := Rest#{To => Max}};
        error ->
            State
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

drop(Res, Token, State) ->
    case ets:lookup(?TAB, Res) of
        [] ->
            State;
        [{Res, Meta, Pages, Holders}] ->
            case maps:take(Token, Holders) of
                error ->
                    State;
                {Owner, Rest} when map_size(Rest) =:= 0 ->
                    ok = reclaim(Res, Meta, Pages),
                    unhold(Owner, Res, Token, sub_total(Token, Pages, State));
                {Owner, Rest} ->
                    true = ets:insert(?TAB, {Res, Meta, Pages, Rest}),
                    unhold(Owner, Res, Token, sub_total(Token, Pages, State))
            end
    end.

retag(Res, From, To, Owner, State) ->
    case ets:lookup(?TAB, Res) of
        [{Res, Meta, Pages, Holders}] ->
            case maps:take(From, Holders) of
                {Old, Rest} ->
                    true = ets:insert(?TAB, {Res, Meta, Pages,
                                             Rest#{To => Owner}}),
                    S1 = add_total(To, Pages, sub_total(From, Pages, State)),
                    watch(Owner, Res, To, unhold(Old, Res, From, S1));
                error ->
                    State
            end;
        [] -> State
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

%% Everything this process still held is unreachable now.
forget_holder(Pid, #{held := Held, mons := Mons} = State) ->
    Mine = maps:get(Pid, Held, #{}),
    S0 = State#{held := maps:remove(Pid, Held), mons := maps:remove(Pid, Mons)},
    lists:foldl(fun({Res, Token}, S) -> drop(Res, Token, S) end,
                S0, maps:keys(Mine)).

reclaim(Res, Meta, Pages) ->
    ok = forget_meta(Res, Meta),
    ok = wasm_engine:release_pages(Pages),
    true = ets:delete(?TAB, Res),
    ok.

forget_meta(_Res, {memory, undefined, _}) -> ok;
forget_meta(_Res, {memory, CRef, _}) -> wasm_engine:cell_forget(CRef);
forget_meta(Res, cell) -> wasm_engine:cell_forget(Res);
%% Nothing in the shared store belongs to a heap: it owns its own two ETS
%% tables and `wasm_heap:drop_tables/2` deletes them. The registry row and the
%% charge are all there is to reclaim here.
forget_meta(_Res, {heap, _, _}) -> ok.

%% A table that has already gone answers `undefined`, which is a heap being torn
%% down while a reconcile was in flight.
words_of(Tab) ->
    case ets:info(Tab, memory) of
        undefined -> 0;
        N -> N
    end.

%%% --------------------------------------------------------------- growth ---

start_growth(Res, Delta, Ceiling, {Pid, _} = _From, State) ->
    case ets:lookup(?TAB, Res) of
        [] ->
            {{error, gone}, State};
        [{Res, Meta, Pages, Holders}] ->
            New = Pages + Delta,
            Toks = maps:keys(Holders),
            %% Every holder, not just the one asking. A memory two instances
            %% share grows only as far as the stricter of them allows, or one
            %% of them would be growing past a ceiling the other was promised.
            AllFit = lists:all(fun(T) -> within(T, Delta, State) end, Toks),
            if
                New > Ceiling ->
                    {{error, exceeds_max}, State};
                not AllFit ->
                    {{error, instance_limit}, State};
                true ->
                    case wasm_engine:reserve_pages(Delta) of
                        {error, limit} ->
                            {{error, limit}, State};
                        ok ->
                            %% The charge moves now rather than at commit, so a
                            %% keeper that dies mid-growth leaves the pages
                            %% attributed to the memory that asked for them and
                            %% a later release gives them back.
                            true = ets:insert(?TAB, {Res, Meta, New, Holders}),
                            GrowRef = make_ref(),
                            %% Written beside the charge and in the same table,
                            %% because the two have to survive together: a
                            %% keeper that came up with the charge and without
                            %% the transaction left the memory paying for pages
                            %% nobody could see. `adopt_growths/1` is the other
                            %% half of this line.
                            true = ets:insert(?TAB,
                                              {{growing, Res},
                                               {GrowRef, Pid, Delta}}),
                            MonRef = erlang:monitor(process, Pid),
                            S1 = lists:foldl(
                                   fun(T, S) -> add_total(T, Delta, S) end,
                                   State, Toks),
                            G = (maps:get(growing, S1))#{Res =>
                                    {GrowRef, Pid, MonRef, Delta}},
                            {{ok, GrowRef, Pages}, S1#{growing := G}}
                    end
            end
    end.

%% Up or down to an absolute number, in one transaction with the registry row.
%%
%% The counter and the row move together here for the same reason they do in
%% `start_growth/5`: a charge recorded against no resource is a charge nothing
%% will ever give back, and `wasm_engine`'s moduledoc is explicit that a counter
%% which disagrees with the registry eventually refuses every allocation on the
%% node.
do_resize(Res, Want, Ceiling, Mode, State) ->
    case ets:lookup(?TAB, Res) of
        [] ->
            {reply, {error, gone}, State};
        [{Res, Meta, Pages, Holders}] when Want < Pages ->
            %% Giving pages back never fails and never consults a ceiling.
            Back = Pages - Want,
            ok = wasm_engine:release_pages(Back),
            true = ets:insert(?TAB, {Res, Meta, Want, Holders}),
            S1 = lists:foldl(fun(T, S) -> sub_total(T, Back, S) end,
                             State, maps:keys(Holders)),
            {reply, ok, S1};
        %% Including `Want =:= Pages`, which is not a no-op: a resource that
        %% is *already* over a holder's ceiling has to keep saying so, or a
        %% guest whose next interval happens not to move the page count is let
        %% through. `within/3` asks about the total, not about the delta.
        [{Res, Meta, Pages, Holders}] ->
            Delta = Want - Pages,
            Toks = maps:keys(Holders),
            grow(Res, Meta, Want, Delta, Holders, Toks,
                 ceilings(Want, Ceiling, Delta, Toks, State), Mode, State)
    end.

%% Which ceiling refuses this growth, if any. Asked before the node budget so a
%% `record` resize can know all of it and still commit.
ceilings(Want, Ceiling, Delta, Toks, State) ->
    AllFit = lists:all(fun(T) -> within(T, Delta, State) end, Toks),
    if
        Ceiling =/= infinity andalso Want > Ceiling -> {error, exceeds_max};
        not AllFit -> {error, instance_limit};
        true -> ok
    end.

%% `request` may refuse and change nothing: nobody has taken the memory yet.
%%
%% `record` is for memory already spent. The rows exist whether or not a ceiling
%% likes them, so the registry row, the holder totals and the node counter all
%% move to the measured size and the refusal is only the *answer*. Leaving them
%% behind was how a heap sat at twelve pages charged for six, once per heap.
grow(_Res, _Meta, _Want, _Delta, _Holders, _Toks, {error, Why}, request,
     State) ->
    {reply, {error, Why}, State};
grow(Res, Meta, Want, Delta, Holders, Toks, Ceil, Mode, State) ->
    Node = case Mode of
               request -> wasm_engine:reserve_pages(Delta);
               record -> wasm_engine:charge_pages(Delta)
           end,
    case {Node, Mode} of
        {{error, limit}, request} ->
            {reply, {error, limit}, State};
        _ ->
            true = ets:insert(?TAB, {Res, Meta, Want, Holders}),
            S1 = lists:foldl(fun(T, S) -> add_total(T, Delta, S) end,
                             State, Toks),
            {reply, first_error(Ceil, Node), S1}
    end.

first_error(ok, R) -> R;
first_error({error, _} = E, _R) -> E.

-ifdef(TEST).
%% A sync point at the top of the transaction that sets a heap's charge.
%%
%% `wasm_heap:charge/1` used to measure the two tables and *then* call here, so
%% an older, smaller sample could land after a newer, larger one and release the
%% pages of rows that still existed. A test cannot land in that window by
%% racing, and the one written for it passed whether the defect was there or
%% not. Holding a process here instead makes the schedule exact: the store grows
%% while a charge is in flight, and where the measurement happens decides the
%% answer. Both clauses carry it because the defect put the measurement on the
%% other side of this line. Never compiled into a release.
hook(Where) ->
    case application:get_env(wasm, keeper_hook) of
        {ok, F} when is_function(F, 1) -> _ = F(Where), ok;
        _ -> ok
    end.
-else.
hook(_Where) -> ok.
-endif.

%% The reservation an abandoned growth took, given back without publishing
%% anything. The delta is the growth's own, not a difference between the charge
%% and a published size: a private memory publishes nothing, so there would be
%% nothing to take the difference against.
unreserve(Res, Delta, State) ->
    case ets:lookup(?TAB, Res) of
        [{Res, Meta, Pages, Holders}] ->
            Back = erlang:min(Delta, Pages),
            true = ets:insert(?TAB, {Res, Meta, Pages - Back, Holders}),
            ok = wasm_engine:release_pages(Back),
            lists:foldl(fun(T, S) -> sub_total(T, Back, S) end,
                        State, maps:keys(Holders));
        [] ->
            State
    end.

publish(Res, Chunks, NewPages) ->
    case ets:lookup(?TAB, Res) of
        [{Res, {memory, CRef, PagesRef} = Meta, _Pages, Holders}] ->
            %% Chunks first, then the size. A reader that sees the new size
            %% therefore always finds the chunks that back it; the reverse
            %% order would hand it an index past the end of the tuple.
            CRef =:= undefined orelse wasm_engine:cell_put(CRef, Chunks),
            PagesRef =:= undefined orelse atomics:put(PagesRef, 1, NewPages),
            true = ets:insert(?TAB, {Res, Meta, NewPages, Holders}),
            ok;
        _ ->
            ok
    end.

next_growth(Res, #{queued := Queued} = State) ->
    case maps:get(Res, Queued, []) of
        [] ->
            State#{queued := maps:remove(Res, Queued)};
        [{From, Delta, Ceiling} | Rest] ->
            {Reply, S1} = start_growth(Res, Delta, Ceiling, From, State),
            gen_server:reply(From, Reply),
            S2 = S1#{queued := Queued#{Res => Rest}},
            case Reply of
                {ok, _, _} -> S2;
                %% A refusal frees the slot again, so the rest of the queue is
                %% not left waiting behind a growth that never started.
                _ -> next_growth(Res, S2)
            end
    end.
