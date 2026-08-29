-module(wasm_global).
-moduledoc """
Mutable globals that two instances can share.

Read this when you link modules that share a global. Module A exports a mutable
global, module B imports it, and a `global.set` in either has to be visible to
the other. A value copied into each instance's state
cannot do that: the two would silently diverge, which is the same defect
imported tables had before 0.2.0.

## Why not every global

A cell is an ETS row, and reading one measured 17.7 ns against 1.9 ns for the
`element/2` read of an inline value. `global.get` is hot in real compiler
output, where the shadow stack pointer is a mutable global read on nearly every
function entry, so paying that on every global would be a poor trade for a
feature only dynamic linking uses.

So a global becomes a cell only when it is mutable *and* either imported or
exported, which is exactly when sharing is observable. That is decided from the
module alone, and `wasm_instance` resolves it into the instruction when the IR
is built, so an ordinary `global.get` still reads a tuple element.

## Lifetime

A cell is held by whoever can reach it: the instance that created it, and every
instance that imported it. It goes when the last of them lets go, so an
exported global outlives the instance that created it. Nothing for you to
release.

It was not so. The cell was tied to the creating process alone, so an exported
global vanished the moment that process exited and the importer's `global.get`
found nothing.
""".

-export([new/1, new/2, get/1, set/2, is_global/1]).
-export([acquire/3, release/2, resource/1]).

-doc "An opaque, shareable handle to one mutable global.".
-nominal global() :: {wasm_global, reference()}.
-export_type([global/0]).

-spec new(term()) -> global().
new(Value) -> new(Value, #{}).

-doc """
Create a cell, saying who holds it.

`holder` is a `{Token, Owner}` pair naming the registry entry to create and the
process whose death removes it. An instance passes its own token, so the cell
lives as long as anything that imported it.
""".
-spec new(term(), map()) -> global().
new(Value, Opts) ->
    {Token, Owner} = maps:get(holder, Opts, {{process, self()}, self()}),
    Id = case wasm_keeper:reserve(0, cell, Token, Owner) of
             {ok, Res} -> Res;
             {error, Why} -> wasm_error:exhaustion(global_unavailable,
                                                   #{reason => Why})
         end,
    ok = wasm_engine:cell_put(Id, Value),
    {wasm_global, Id}.

-doc "Add a holder, for an instance importing this global.".
-spec acquire(global(), wasm_keeper:token(), pid() | none) ->
          ok | {error, gone | keeper_unavailable}.
acquire({wasm_global, Id}, Token, Owner) ->
    wasm_keeper:acquire(Id, Token, Owner).

-doc "Remove a holder. The cell goes when the last one lets go.".
-spec release(global(), wasm_keeper:token()) -> ok.
release({wasm_global, Id}, Token) -> wasm_keeper:release(Id, Token).

-doc "This cell's registry identity.".
-spec resource(global()) -> wasm_keeper:resource().
resource({wasm_global, Id}) -> Id.

-spec get(global()) -> term().
get({wasm_global, Id}) -> wasm_engine:cell_get(Id).

-spec set(global(), term()) -> ok.
set({wasm_global, Id}, Value) -> wasm_engine:cell_put(Id, Value).

-doc """
Whether a term is a global cell.

This doubles as the mutability check across an import boundary: an export hands
over a cell for a mutable global and a bare value for an immutable one, so a
module that declared the wrong mutability is refused rather than linked.
""".
-spec is_global(term()) -> boolean().
is_global({wasm_global, Id}) -> is_reference(Id);
is_global(_) -> false.
