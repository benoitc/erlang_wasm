-module(wasm_table).
-moduledoc """
Tables, with reference semantics.

Read this when you are linking modules that share a table. A table is mutable
state two instances can share: module A exports a table, module B imports it and
writes an element segment into it, and a `call_indirect` in A has to see B's
entry. That is how dynamic linking works, and an `array` held inside each
instance cannot do it, because `array` is immutable and every instance ends up
initialising its own copy.

Memories already share correctly, because `atomics` is a reference. Tables now
do too, by the same route: the handle is a reference, the contents live in one
place, and every holder sees the same thing.

## How reads stay fast

The contents are an `array` in a shared ETS row, so a naive read would copy the
whole table on every `call_indirect`. Instead each process caches the array it
last saw together with a version counter held in `atomics`. A hit is an
`atomics:get` plus a process dictionary lookup, neither of which copies; any
writer bumps the counter and every other process reloads on its next read.

That is the same mechanism `wasm_instance:mut/1` uses, and it was measured
there at 398 ns down to 19 ns.

## Lifetime

A table is held by whoever can reach it, the same way a memory is: the instance
that created it, every instance that imported it, or the process that made it
standalone. It goes when the last of them lets go. You do not have to release
anything by hand.

It was not so. The row was tied to the creating process alone, so an exported
table vanished out from under an importer the moment the exporter's process
exited, and `call_indirect` through it found nothing.
""".

-include("wasm.hrl").

-export([new/2, new/3, size/1, limits/1, elemtype/1, is_table/1, get/2, set/3,
         grow/3, fill/4, copy/5, init/3, to_list/1]).
-export([acquire/3, release/2, resource/1]).

-doc """
An opaque, shareable table handle.

The declared limits travel in the handle rather than being supplied at each
call, because a table imported from another module is bounded by the *defining*
module's declaration, not by the importer's view of it. That is also what lets
an importer check that the index type it declared is the one it was handed.
""".
-nominal table() :: {wasm_table, reference(), atomics:atomics_ref(),
                     #tabletype{}}.
-export_type([table/0]).

-define(TAB, wasm_tables).

%%% ----------------------------------------------------------------- api ---

-spec new(non_neg_integer() | #limits{} | #tabletype{}, term()) -> table().
new(Size, Default) -> new(Size, Default, #{}).

-doc """
Create a table, saying who holds it.

`holder` is a `{Token, Owner}` pair naming the registry entry to create and the
process whose death removes it. Leave it out and the table belongs to the
calling process; an instance passes its own token, so the table survives for as
long as anything that imported it is alive.
""".
-spec new(non_neg_integer() | #limits{} | #tabletype{}, term(), map()) ->
          table().
new(Size, Default, Opts) when is_integer(Size) ->
    new(#limits{min = Size}, Default, Opts);
new(#limits{} = Limits, Default, Opts) ->
    new(#tabletype{limits = Limits, elemtype = ?FUNCREF}, Default, Opts);
new(#tabletype{limits = #limits{min = Size}} = TT, Default, Opts) ->
    {Token, Owner} = maps:get(holder, Opts, {{process, self()}, self()}),
    %% No pages: a table costs Erlang heap, which `max_heap_words' bounds, not
    %% the off-heap linear memory the node budget is there for. The registry
    %% entry is for the lifetime, not for the accounting.
    Id = case wasm_keeper:reserve(0, cell, Token, Owner) of
             {ok, Res} -> Res;
             {error, Why} -> wasm_error:exhaustion(table_unavailable,
                                                   #{reason => Why})
         end,
    Version = atomics:new(1, []),
    Array = array:new([{size, Size}, {default, Default}, {fixed, false}]),
    ok = wasm_engine:table_put(Id, Array),
    {wasm_table, Id, Version, TT}.

-doc "Add a holder, for an instance importing this table.".
-spec acquire(table(), wasm_keeper:token(), pid() | none) ->
          ok | {error, gone | keeper_unavailable}.
acquire({wasm_table, Id, _V, _TT}, Token, Owner) ->
    wasm_keeper:acquire(Id, Token, Owner).

-doc "Remove a holder. The table goes when the last one lets go.".
-spec release(table(), wasm_keeper:token()) -> ok.
release({wasm_table, Id, _V, _TT}, Token) -> wasm_keeper:release(Id, Token).

-doc "This table's registry identity.".
-spec resource(table()) -> wasm_keeper:resource().
resource({wasm_table, Id, _V, _TT}) -> Id.

-spec size(table()) -> non_neg_integer().
size(T) -> array:size(array_of(T)).

-doc """
Whether a term is a table handle.

An embedder hands over bare terms, so a module importing a table may be given a
memory, a function or a number. That has to come back as a link error rather
than as a `function_clause` from inside the runtime.
""".
-spec is_table(term()) -> boolean().
is_table({wasm_table, _, _, #tabletype{}}) -> true;
is_table(_) -> false.

-doc "The limits this table was declared with.".
-spec limits(table()) -> #limits{}.
limits({wasm_table, _Id, _Version, #tabletype{limits = L}}) -> L.

-doc """
The element type this table was declared with.

Carried for the same reason a global's type is: an importer has to check that
the table it was handed holds what it expects, and the contents alone cannot
say whether they are `funcref` or `(ref $t)`.
""".
-spec elemtype(table()) -> reftype().
elemtype({wasm_table, _Id, _Version, #tabletype{elemtype = ET}}) -> ET.

-spec get(table(), non_neg_integer()) -> term().
get(T, Idx) -> array:get(Idx, array_of(T)).

-spec set(table(), non_neg_integer(), term()) -> ok.
set(T, Idx, Value) -> store(T, array:set(Idx, Value, array_of(T))).

-doc """
Grow by `Delta`, returning the previous size.

Refusal is a value rather than a trap, because `table.grow` is specified to
push -1 rather than fault.
""".
-spec grow(table(), non_neg_integer(), term()) ->
          {ok, non_neg_integer()} | {error, exceeds_max}.
grow({wasm_table, _, _,
      #tabletype{limits = #limits{max = Max, index_type = IT}}} = T,
     Delta, Init) ->
    Array = array_of(T),
    Old = array:size(Array),
    Ceiling = case Max of
                  undefined when IT =:= i64 -> ?MAX_TABLE_SIZE_64;
                  undefined -> ?MAX_TABLE_SIZE;
                  N -> N
              end,
    New = Old + Delta,
    case New > Ceiling orelse New > wasm_engine:table_grow_limit() of
        true -> {error, exceeds_max};
        false ->
            ok = store(T, fill_new(Array, New, Old, Delta, Init)),
            {ok, Old}
    end.

%% A declared maximum is no protection against an expensive grow: an undeclared
%% maximum means 2^32-1 entries, or 2^64-1 under memory64, and filling those one
%% at a time wedges a scheduler. So growth also stops at a node-wide ceiling.
%% The specification allows exactly this: growth that cannot be satisfied is
%% required to produce -1, not to trap.
%%
%% Below that ceiling, `array' being sparse means the resize itself is O(1) and
%% appending the array's own default costs nothing. That is the common case:
%% `table.grow' almost always appends nulls.
fill_new(Array, New, Old, Delta, Init) ->
    Resized = array:resize(New, Array),
    case Init =:= array:default(Array) of
        true -> Resized;
        false -> fill_range(Resized, Old, Delta, Init)
    end.

-spec fill(table(), non_neg_integer(), non_neg_integer(), term()) -> ok.
fill(T, Dst, Len, Value) ->
    store(T, fill_range(array_of(T), Dst, Len, Value)).

-doc """
Copy a range, possibly between two different tables.

The source slice is read out in full before anything is written, so an overlap
within one table behaves like `memmove` rather than smearing the first element.
""".
-spec copy(table(), non_neg_integer(), table(), non_neg_integer(),
           non_neg_integer()) -> ok.
copy(Dst, DstIdx, Src, SrcIdx, Len) ->
    SrcArray = array_of(Src),
    Vals = [array:get(SrcIdx + I, SrcArray) || I <- lists:seq(0, Len - 1)],
    init(Dst, DstIdx, Vals).

-spec init(table(), non_neg_integer(), [term()]) -> ok.
init(T, Dst, Vals) ->
    Array = lists:foldl(fun({I, V}, Acc) -> array:set(Dst + I, V, Acc) end,
                        array_of(T), lists:enumerate(0, Vals)),
    store(T, Array).

-spec to_list(table()) -> [term()].
to_list(T) -> array:to_list(array_of(T)).

%%% ------------------------------------------------------- shared storage ---

%% A cache hit costs an `atomics:get' and a process dictionary lookup. The
%% version is what makes it safe across processes: any write bumps it, so a
%% stale cache is detected rather than served.
array_of({wasm_table, Id, Version, _TT}) ->
    Now = atomics:get(Version, 1),
    case get({wasm_table_cache, Id}) of
        {Now, Cached} -> Cached;
        _ ->
            Array = wasm_engine:table_get(Id),
            put({wasm_table_cache, Id}, {Now, Array}),
            Array
    end.

store({wasm_table, Id, Version, _TT}, Array) ->
    ok = wasm_engine:table_put(Id, Array),
    %% Bump first, then cache at the new version, so this process's own write
    %% leaves its cache valid while every other process reloads.
    New = atomics:add_get(Version, 1, 1),
    put({wasm_table_cache, Id}, {New, Array}),
    ok.

fill_range(Array, _Dst, 0, _V) -> Array;
fill_range(Array, Dst, Len, V) ->
    fill_range(array:set(Dst, V, Array), Dst + 1, Len - 1, V).
