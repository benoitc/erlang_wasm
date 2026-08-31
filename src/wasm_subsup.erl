-module(wasm_subsup).
-moduledoc """
One subsystem of the runtime, with a restart budget of its own.

`wasm_sup` used to supervise all five servers directly, which meant they shared
one allowance: `intensity 5, period 10` counted restarts across the whole set,
so losing the module cache three times and the keeper twice inside ten seconds
took down the engine, the code slots and the application with them. A stress run
reached exactly that, and the tree it left behind kept answering calls while the
node's page accounting had quietly reset.

A subsystem is the unit that should share a budget, so each one gets a
supervisor and the budget lives there. Cache churn can now spend the cache's
allowance and nothing else's.

## Why one module and not five

The difference between the subsystems is a strategy, a budget and a list of
children. That is data, and writing it out five times would put the shape of the
tree in five files instead of in `wasm_sup`, where it is worth reading. Each
supervisor is registered under its own name, so the tree still reads the way the
diagram in `wasm_sup` draws it.

```erlang
wasm_subsup:child(wasm_code_sup, rest_for_one, [wasm_code_slots, wasm_jit_sup])
```
""".
-behaviour(supervisor).

-export([child/3, start_link/3, init/1]).

-doc """
A child spec for `wasm_sup`: one subsystem, under a supervisor of its own.

`Kids` names the modules to supervise, in start order. Each is started by its
own `start_link/0` and is `permanent`, because every one of them owns state the
rest of the runtime reads.
""".
-spec child(atom(), supervisor:strategy(), [module()]) ->
          supervisor:child_spec().
child(Name, Strategy, Kids) ->
    #{id => Name,
      start => {?MODULE, start_link, [Name, Strategy, Kids]},
      restart => permanent,
      shutdown => 10000,
      type => supervisor,
      modules => [?MODULE | Kids]}.

-spec start_link(atom(), supervisor:strategy(), [module()]) ->
          supervisor:startlink_ret().
start_link(Name, Strategy, Kids) ->
    supervisor:start_link({local, Name}, ?MODULE, {Strategy, Kids}).

init({Strategy, Kids}) ->
    %% Ten in sixty rather than five in ten. The old numbers were tuned for a
    %% supervisor holding the whole runtime, where giving up early was the safe
    %% answer; a supervisor holding one subsystem can afford to keep trying,
    %% because the blast radius of it failing is now that subsystem alone. A
    %% subsystem that really cannot start burns ten restarts in a minute and
    %% then reports upward, which is the signal `wasm_sup` acts on.
    Flags = #{strategy => Strategy, intensity => 10, period => 60},
    {ok, {Flags, [spec(K) || K <- Kids]}}.

spec(Mod) ->
    #{id => Mod,
      start => {Mod, start_link, []},
      restart => permanent,
      shutdown => 5000,
      type => kind(Mod),
      modules => [Mod]}.

%% `wasm_jit_sup` is a supervisor and everything else here is a worker. Asked of
%% the module rather than carried in the child list, because getting it wrong is
%% a shutdown bug that only shows up on a release upgrade.
kind(wasm_jit_sup) -> supervisor;
kind(_) -> worker.
