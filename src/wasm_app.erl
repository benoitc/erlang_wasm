-module(wasm_app).
-moduledoc """
Application callback.

Start the application before you load or instantiate anything: it owns the
module cache and the node page budget.

The tree is one supervisor per subsystem, so a restart budget is shared only by
things that belong together; `wasm_sup` draws it. It was flat until a stress run
showed what that costs: five servers under one `intensity => 5, period => 10`
meant losing the module cache repeatedly could take the engine and the keeper
with it, and the tables went too. `wasm_engine` still starts before anything
that allocates, because node-wide page accounting must be in place before linear
memory can grow: `atomics` pages are off-heap and invisible to `max_heap_size`,
so nothing else would bound them.
""".
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    wasm_sup:start_link().

stop(_State) ->
    ok.
