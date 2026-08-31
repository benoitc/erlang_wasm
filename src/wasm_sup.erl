-module(wasm_sup).
-moduledoc """
Root supervisor. What `application:ensure_all_started(wasm)` gets you:

```
wasm_sup                one_for_one, 5 in 300
  |
  +-- wasm_store_sup    one_for_one    the long-lived ETS tables
  |     +-- wasm_store
  |
  +-- wasm_engine_sup   one_for_one    node-wide page budget, shared storage
  |     +-- wasm_engine
  |
  +-- wasm_keeper_sup   one_for_one    who still holds each shared resource
  |     +-- wasm_keeper
  |
  +-- wasm_code_sup     rest_for_one   generated code and the compilers
  |     +-- wasm_code_slots
  |     +-- wasm_jit_sup
  |
  +-- wasm_cache_sup    one_for_one    modules, keyed by content hash
        +-- wasm_module_cache
```

There is deliberately no instance supervisor. An instance is owned by the
process that created it, and applications put instances inside whatever process
shape suits them; see `docs/worker.md`.

## Why a supervisor per subsystem

Because a restart budget is shared by everything under one supervisor, and these
five have nothing to do with each other. Flat, they shared `5 in 10`: losing the
module cache three times and the keeper twice inside ten seconds took the engine
and the code slots down with them, along with the application. That is not
hypothetical, it is what a stress run did, and what it left behind was worse than
a stopped application -- see `wasm_keeper:init/1`.

A subsystem is the unit that should share an allowance, so each one has its own
supervisor and its own `10 in 60`. `wasm_sup` then counts only *subsystems*
collapsing, and a subsystem collapses only after burning ten restarts in a
minute, so `5 in 300` here is a genuinely broken node rather than a busy one.

`wasm_code_sup` is `rest_for_one` because `wasm_code_slots` hands out the slots
the compilers under `wasm_jit_sup` reserve: a slot manager that restarts should
take the in-flight compilers with it rather than leave them writing into slots
nobody is tracking. They are `temporary` and `brutal_kill` already, and losing
one costs only the work.

The rest is `one_for_one`. `wasm_keeper` calls `wasm_engine` for pages, but the
page counters live in `persistent_term` and the store is a table `wasm_store`
owns, so an engine restart takes nothing the keeper depends on; making that
`rest_for_one` would restart the keeper for no gain.

## Why the tables are a subsystem and start first

They used to belong to this process. That gave them the right lifetime against a
worker crash and the wrong one against everything else, because the root is the
process every subsystem hangs off. `wasm_store` owns them now, and it starts
first because nothing may create a table it does not own.
""".
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 300},
    Children =
        [wasm_subsup:child(wasm_store_sup,  one_for_one,  [wasm_store]),
         wasm_subsup:child(wasm_engine_sup, one_for_one,  [wasm_engine]),
         wasm_subsup:child(wasm_keeper_sup, one_for_one,  [wasm_keeper]),
         wasm_subsup:child(wasm_code_sup,   rest_for_one, [wasm_code_slots,
                                                           wasm_jit_sup]),
         wasm_subsup:child(wasm_cache_sup,  one_for_one,  [wasm_module_cache])],
    {ok, {SupFlags, Children}}.
