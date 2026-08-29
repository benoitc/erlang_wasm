-module(wasm_app).
-moduledoc """
Application callback.

Start the application before you load or instantiate anything: it owns the
module cache and the node page budget. The supervision tree is deliberately
shallow at this stage. Milestones M0-M4
cover decoding, validation, execution and linear memory, none of which owns
long-lived mutable state outside a caller's process. `wasm_engine` exists
from the start only because node-wide page accounting must be in place
before linear memory can grow (M4): `atomics` pages are off-heap and
invisible to `max_heap_size`, so nothing else would bound them.
""".
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    wasm_sup:start_link().

stop(_State) ->
    ok.
