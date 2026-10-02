-module(wasm_resources).
-moduledoc """
Per-component-instance resource handle tables.

A component instance owns a table of the resource handles live in it. A handle
is the integer representation the guest minted (the identity model stays), but
liveness is tracked per instance rather than once per process, so a double drop,
a use-after-drop and a wrong-type handle are detected, and ownership can move
between instances without one instance's drop disturbing another's.

The table lives in the process dictionary of the process that owns the instance
(host imports and intrinsics run there, as the older process-global table did).
A current-instance pointer, set around a guest call by `with_instance/2`, tells
the intrinsics which table to use; it saves and restores, so a cross-component
call nests correctly. When no instance is current the operations are lenient
pass-throughs, so a path that never set one behaves as before.

Entries are `Rep => {Rt, own | borrow}`: the resource-type index for the
wrong-type check, and whether the handle owns the resource (an own may be
dropped and transferred; a borrow is lent for one call). The bridge functions
(`add/4`, `take/2`, `has/2`) name an instance explicitly, because a
cross-component call moves a handle from one instance's table to another's while
a third is current.
""".

-export([new_instance/0, destroy_instance/1, with_instance/2, current/0]).
-export([track/2, lookup/1, drop/1, untrack/1]).
-export([add/4, take/2, has/2]).

-define(CUR, {?MODULE, current}).
-define(TABLES, {?MODULE, tables}).

-type id() :: pos_integer().
-type rep() :: integer().
-type rt() :: non_neg_integer() | undefined.
-type kind() :: own | borrow.

-export_type([id/0]).

%%% ------------------------------------------------------------- lifecycle ---

-doc "Mint a fresh instance id with an empty handle table.".
-spec new_instance() -> id().
new_instance() ->
    Id = erlang:unique_integer([positive, monotonic]),
    put(?TABLES, maps:put(Id, #{}, tables())),
    Id.

-doc "Drop an instance's whole table; another instance's table is untouched.".
-spec destroy_instance(id()) -> ok.
destroy_instance(Id) ->
    put(?TABLES, maps:remove(Id, tables())),
    ok.

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

%%% --------------------------------------------------- current-table ops ---

-doc """
Record `Rep` live in the current instance as an owned handle of type `Rt`
(`resource.new`, or an own arriving across a boundary). A no-op when no instance
is current.
""".
-spec track(rep(), rt()) -> ok.
track(Rep, Rt) ->
    case current() of
        undefined -> ok;
        Id        -> set(Id, Rep, {Rt, own}), ok
    end.

-doc """
The resource type of `Rep` in the current instance, or `error` when it is not
live (a use-after-drop or a never-minted handle). Lenient when no instance is
current, so a direct, un-wrapped call still resolves.
""".
-spec lookup(rep()) -> {ok, rt()} | error.
lookup(Rep) ->
    case current() of
        undefined -> {ok, undefined};
        Id ->
            case maps:find(Rep, table(Id)) of
                {ok, {Rt, _Kind}} -> {ok, Rt};
                error             -> error
            end
    end.

-doc """
Remove `Rep` from the current instance, returning whether it owned the resource,
or `error` when it was not live (a double drop or a drop of a never-minted
handle). Lenient when no instance is current.
""".
-spec drop(rep()) -> {ok, kind()} | error.
drop(Rep) ->
    case current() of
        undefined -> {ok, own};
        Id ->
            case maps:find(Rep, table(Id)) of
                {ok, {_Rt, Kind}} -> del(Id, Rep), {ok, Kind};
                error             -> error
            end
    end.

-doc "Silently forget `Rep` in the current instance if it is live (host-drop cleanup).".
-spec untrack(rep()) -> ok.
untrack(Rep) ->
    case current() of
        undefined -> ok;
        Id        -> del(Id, Rep), ok
    end.

%%% -------------------------------------------------------- bridge (by id) ---

-doc "Add `Rep` of type `Rt` and kind to the named instance's table.".
-spec add(id(), rep(), rt(), kind()) -> ok.
add(Id, Rep, Rt, Kind) ->
    set(Id, Rep, {Rt, Kind}), ok.

-doc "Remove `Rep` from the named instance, returning its type, or `error`.".
-spec take(id(), rep()) -> {ok, rt()} | error.
take(Id, Rep) ->
    case maps:find(Rep, table(Id)) of
        {ok, {Rt, _Kind}} -> del(Id, Rep), {ok, Rt};
        error             -> error
    end.

-doc "Whether `Rep` is live in the named instance.".
-spec has(id(), rep()) -> boolean().
has(Id, Rep) ->
    maps:is_key(Rep, table(Id)).

%%% ---------------------------------------------------------------- internal ---

tables() ->
    case get(?TABLES) of
        undefined -> #{};
        Map       -> Map
    end.

table(Id) ->
    maps:get(Id, tables(), #{}).

set(Id, Rep, Entry) ->
    T = tables(),
    put(?TABLES, maps:put(Id, maps:put(Rep, Entry, maps:get(Id, T, #{})), T)).

del(Id, Rep) ->
    T = tables(),
    put(?TABLES, maps:put(Id, maps:remove(Rep, maps:get(Id, T, #{})), T)).
