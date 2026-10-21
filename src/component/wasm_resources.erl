-module(wasm_resources).
-moduledoc """
Per-component-instance resource handle tables.

A component instance owns one table of the resource handles live in it. A
handle is a small integer the table mints, starting at 1 and never reused while
the instance lives; it is not the guest's representation. Each entry is
`Handle => {Rt, Rep, Owner}`:

- `Rt` is the resource type, the index in the component's type space, or
  `imported` for a handle that stands for another component's resource;
- `Rep` is what the guest chose to represent the resource with (an `i32`), or
  `{remote, ProviderId, ProviderHandle, Release}` for an imported one;
- `Owner` is `guest` (the guest holds the own handle), `host` (the host holds
  it) or `{lent, N}` (the host holds it and has lent it to N calls in flight).

The guest side (`new/2`, `rep/2`, `drop/2`) acts on the current instance, the
one `with_instance/2` set around a guest call. The host side (`host_*`) names an
instance explicitly. A check that fails throws a trap through
`wasm_error:trap/2`: `resource_not_live` (a handle that was dropped, never
minted, or is not held by the side using it) with `handle` and `operation` in
its context, `resource_wrong_type` with `expected` and `actual`, and
`resource_borrowed` for a host drop of a handle still lent to a call.

The table lives in the process dictionary of the process that owns the
instance, as the host imports and intrinsics run there. When no instance is
current the guest-side operations are pass-throughs (the handle is the
representation), so a path that never set one behaves as it did.
""".

-export([new_instance/0, destroy_instance/1, exists/1, with_instance/2,
         current/0]).
-export([new/2, rep/2, drop/2, lookup/1, take/1]).
-export([host_receive/3, host_give/3, host_lend/3, host_unlend/2,
         host_drop/3, host_lookup/2, live/1]).

-define(CUR, {?MODULE, current}).
-define(TABLES, {?MODULE, tables}).

-type id() :: pos_integer().
-type handle() :: pos_integer().
-type rt() :: non_neg_integer() | imported | undefined.
-type rep() :: integer()
             | {remote, id(), handle(), fun(() -> term())}.
-type owner() :: guest | host | {lent, pos_integer()}.
-type entry() :: {rt(), rep(), owner()}.
-type table() :: {handle(), #{handle() => entry()}}.

-export_type([id/0, handle/0, rt/0, rep/0]).

%%% ------------------------------------------------------------- lifecycle ---

-doc "Mint a fresh instance id with an empty handle table.".
-spec new_instance() -> id().
new_instance() ->
    Id = erlang:unique_integer([positive, monotonic]),
    put(?TABLES, maps:put(Id, {1, #{}}, tables())),
    Id.

-doc """
Discard an instance's whole table; another instance's table is untouched. No
destructor runs: the guest memory the representations point into goes with the
instance.
""".
-spec destroy_instance(id()) -> ok.
destroy_instance(Id) ->
    put(?TABLES, maps:remove(Id, tables())),
    ok.

-doc """
Whether `Id`'s table is here: `false` once the instance was destroyed, or in a
process other than the one that created it.
""".
-spec exists(id()) -> boolean().
exists(Id) ->
    maps:is_key(Id, tables()).

-doc """
Run `Fun` with `Id` as the current instance, restoring the previous current
afterwards (so a nested cross-component call leaves the caller's current intact).
""".
-spec with_instance(id(), fun(() -> T)) -> T.
with_instance(Id, Fun) ->
    Prev = get(?CUR),
    put(?CUR, Id),
    try Fun()
    after
        case Prev of
            undefined -> erase(?CUR);
            _         -> put(?CUR, Prev)
        end
    end.

-doc "The current instance id, or `undefined` outside a guest call.".
-spec current() -> id() | undefined.
current() -> get(?CUR).

%%% ------------------------------------------------------------ guest side ---

-doc """
Mint a handle for `Rep` of type `Rt` in the current instance, held by the guest
(`canon resource.new`, or an own arriving from another component). With no
instance current the representation is the handle.
""".
-spec new(rt(), rep()) -> handle() | rep().
new(Rt, Rep) ->
    case current() of
        undefined -> Rep;
        Id        -> mint(Id, Rt, Rep, guest)
    end.

-doc """
The representation behind a guest-held handle of type `Rt` (`canon
resource.rep`). `Rt` `undefined` checks liveness only. Traps when the handle is
not live in the current instance, not held by the guest, or of another type.
""".
-spec rep(rt(), integer()) -> rep().
rep(Rt, H) ->
    case current() of
        undefined -> H;
        Id ->
            {Rep, _} = guest_entry(Id, Rt, H, rep),
            Rep
    end.

-doc """
Remove a guest-held handle (`canon resource.drop`), returning its
representation for the caller's destructor. A handle that stands for another
component's resource is released there instead, and `remote` is returned.
Traps as `rep/2` does.
""".
-spec drop(rt(), integer()) -> integer() | remote.
drop(Rt, H) ->
    case current() of
        undefined -> H;
        Id ->
            {Rep, _} = guest_entry(Id, Rt, H, drop),
            del(Id, H),
            case Rep of
                {remote, _ProvId, _Hp, Release} -> _ = Release(), remote;
                _                               -> Rep
            end
    end.

-doc """
The entry behind a guest-held handle in the current instance, or `error`.
Lets a cross-component bridge see whether a handle stands for a resource of the
component it is about to call.
""".
-spec lookup(integer()) -> {ok, {rt(), rep()}} | error.
lookup(H) ->
    case current() of
        undefined -> error;
        Id ->
            case maps:find(H, entries(Id)) of
                {ok, {Rt, Rep, guest}} -> {ok, {Rt, Rep}};
                _                      -> error
            end
    end.

-doc """
Remove a guest-held handle from the current instance without releasing what it
stands for: an own moved to another component.
""".
-spec take(integer()) -> ok.
take(H) ->
    case current() of
        undefined -> ok;
        Id        -> del(Id, H), ok
    end.

%%% ------------------------------------------------------------- host side ---

-doc """
An own handle the guest returned to the host: it passes from the guest to the
host. Traps when the guest returned a handle it does not hold, or of another
type than its signature declares.
""".
-spec host_receive(id(), rt(), integer()) -> handle().
host_receive(Id, Rt, H) ->
    {Rep, _} = guest_entry(Id, Rt, H, return),
    set(Id, H, {entry_rt(Id, H), Rep, host}),
    H.

-doc """
An own handle the host passes to the guest: it passes back to the guest, which
receives the handle. Traps unless the host holds it, unlent, with type `Rt`.
""".
-spec host_give(id(), rt(), integer()) -> handle().
host_give(Id, Rt, H) ->
    {Rep, host} = host_entry(Id, Rt, H, own),
    set(Id, H, {entry_rt(Id, H), Rep, guest}),
    H.

-doc """
A handle the host lends to one call as a `borrow`: the guest receives the
representation and the host keeps the handle. Traps unless the host holds it
with type `Rt`. `host_unlend/2` ends the loan.
""".
-spec host_lend(id(), rt(), integer()) -> rep().
host_lend(Id, Rt, H) ->
    {Rep, Owner} = host_entry(Id, Rt, H, borrow),
    N = case Owner of
            host      -> 1;
            {lent, M} -> M + 1
        end,
    set(Id, H, {entry_rt(Id, H), Rep, {lent, N}}),
    Rep.

-doc "End one loan of `H`. A handle that went away meanwhile is ignored.".
-spec host_unlend(id(), integer()) -> ok.
host_unlend(Id, H) ->
    case maps:find(H, entries(Id)) of
        {ok, {Rt, Rep, {lent, 1}}} -> set(Id, H, {Rt, Rep, host});
        {ok, {Rt, Rep, {lent, N}}} -> set(Id, H, {Rt, Rep, {lent, N - 1}});
        _                          -> ok
    end,
    ok.

-doc """
Remove a host-held handle and return its representation, for the destructor.
Traps unless the host holds it with type `Rt`, and while it is lent.
""".
-spec host_drop(id(), rt(), integer()) -> rep().
host_drop(Id, Rt, H) ->
    case host_entry(Id, Rt, H, drop) of
        {Rep, host} ->
            del(Id, H),
            Rep;
        {_Rep, {lent, N}} ->
            wasm_error:trap(resource_borrowed,
                            #{handle => H, operation => drop, loans => N})
    end.

-doc "The type and representation of a host-held handle, or `error`.".
-spec host_lookup(id(), integer()) -> {ok, {rt(), rep()}} | error.
host_lookup(Id, H) ->
    case maps:find(H, entries(Id)) of
        {ok, {_Rt, _Rep, guest}} -> error;
        {ok, {Rt, Rep, _Owner}}  -> {ok, {Rt, Rep}};
        error                    -> error
    end.

-doc "Every live handle in an instance's table, with its type and owner.".
-spec live(id()) -> [{handle(), rt(), owner()}].
live(Id) ->
    lists:sort([{H, Rt, Owner}
                || {H, {Rt, _Rep, Owner}} <- maps:to_list(entries(Id))]).

%%% ---------------------------------------------------------------- checks ---

%% A guest-held entry of the expected type, or a trap. The guest may use only
%% the handles it holds: one it handed to the host, or never had, is not live
%% for it.
guest_entry(Id, Rt, H, Op) ->
    case maps:find(H, entries(Id)) of
        {ok, {Actual, Rep, guest}} ->
            check_type(Rt, Actual, H),
            {Rep, guest};
        _ ->
            not_live(H, Op)
    end.

%% A host-held (or host-lent) entry of the expected type, or a trap.
host_entry(Id, Rt, H, Op) ->
    case maps:find(H, entries(Id)) of
        {ok, {_Actual, _Rep, guest}} ->
            not_live(H, Op);
        {ok, {Actual, Rep, Owner}} ->
            check_type(Rt, Actual, H),
            {Rep, Owner};
        error ->
            not_live(H, Op)
    end.

%% `undefined` expects nothing in particular (liveness only); otherwise the
%% types must agree, and an imported handle never matches a type defined here.
check_type(undefined, _Actual, _H) -> ok;
check_type(Rt, Rt, _H)             -> ok;
check_type(Rt, Actual, H) ->
    wasm_error:trap(resource_wrong_type,
                    #{handle => H, expected => Rt, actual => Actual}).

-spec not_live(term(), atom()) -> no_return().
not_live(H, Op) ->
    wasm_error:trap(resource_not_live, #{handle => H, operation => Op}).

entry_rt(Id, H) ->
    {Rt, _Rep, _Owner} = maps:get(H, entries(Id)),
    Rt.

%%% ---------------------------------------------------------------- tables ---

tables() ->
    case get(?TABLES) of
        undefined -> #{};
        Map       -> Map
    end.

-spec table(id()) -> table().
table(Id) ->
    maps:get(Id, tables(), {1, #{}}).

entries(Id) ->
    element(2, table(Id)).

mint(Id, Rt, Rep, Owner) ->
    {Next, Entries} = table(Id),
    put(?TABLES, maps:put(Id, {Next + 1, Entries#{Next => {Rt, Rep, Owner}}},
                          tables())),
    Next.

%% Writes to a table that was destroyed meanwhile (a loan ending, or another
%% component releasing a handle, after `destroy_instance/1`) do not bring it
%% back.
set(Id, H, Entry) ->
    update(Id, fun(Entries) -> Entries#{H => Entry} end).

del(Id, H) ->
    update(Id, fun(Entries) -> maps:remove(H, Entries) end).

update(Id, Fun) ->
    Tables = tables(),
    case maps:find(Id, Tables) of
        {ok, {Next, Entries}} ->
            put(?TABLES, Tables#{Id => {Next, Fun(Entries)}}),
            ok;
        error ->
            ok
    end.
