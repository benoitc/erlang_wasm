-module(wasm_sup).
-moduledoc """
Root supervisor. What `application:ensure_all_started(wasm)` gets you:

```
wasm_sup
  |
  +-- wasm_engine          node-wide page budget and shared storage
  |
  +-- wasm_keeper          who still holds each shared resource
  |
  +-- wasm_code_slots      which generated BEAM module names are in use
  |
  +-- wasm_module_cache    compiled modules, keyed by content hash
```

There is deliberately no instance supervisor. An instance is owned by the
process that created it, and applications put instances inside whatever
process shape suits them; see `docs/worker.md`. `wasm_engine` starts first
and is `permanent`, because it owns the page budget, so nothing may allocate
memory before it exists.

The supervisor owns the holder registry, the shared store and the waiter table
rather than letting their users create them. An ETS table dies with the process that
created it, so a keeper that created its own registry would take every
resource's accounting down with it on restart and come back believing the node
held nothing, and an engine that owned the store would take away the rows that
registry points at.
""".
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    ok = wasm_keeper:ensure_table(),
    ok = wasm_engine:ensure_store(),
    ok = wasm_engine:ensure_waiter_table(),
    ok = wasm_code_slots:ensure_table(),
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    Children = [
        #{id => wasm_engine,
          start => {wasm_engine, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [wasm_engine]},
        #{id => wasm_keeper,
          start => {wasm_keeper, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [wasm_keeper]},
        #{id => wasm_code_slots,
          start => {wasm_code_slots, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [wasm_code_slots]},
        #{id => wasm_jit_sup,
          start => {wasm_jit_sup, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => supervisor,
          modules => [wasm_jit_sup]},
        #{id => wasm_module_cache,
          start => {wasm_module_cache, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [wasm_module_cache]}
    ],
    {ok, {SupFlags, Children}}.
