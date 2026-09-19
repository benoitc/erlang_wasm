# Put it in an OTP application

This page shows where each piece goes in a real application: when to load a
module, which process owns an instance, how workers sit in your supervision
tree, and what happens at shutdown. Read it once your first call works and you
are deciding where it lives.

## Start the runtime with your application

List `wasm` in your application's `applications`, so it starts first:

```erlang
%% src/my_app.app.src
{application, my_app,
 [{applications, [kernel, stdlib, wasm]},
  {mod, {my_app, []}}]}.
```

The `wasm` application owns the module cache, the node's page budget and the
reaper; there is nothing else to start.

## Load modules once, at startup

`wasm:load_file/1` decodes and validates a module and caches it by content
hash, so load it when your application starts and keep the handle:

<!-- check: modules my_app my_app_sup -->
```erlang
-module(my_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    {ok, Mod} = wasm:load_file(filename:join(code:priv_dir(my_app),
                                             "plugin.wasm")),
    persistent_term:put({my_app, plugin}, Mod),
    my_app_sup:start_link().

stop(_State) ->
    ok.
```

A module is immutable and shared: every instance made from it gets its own
state, so one handle serves the whole node.

## Know who owns an instance

An instance belongs to the process that created it. When that process exits,
for any reason, including a kill, the runtime releases the instance's memory.
So:

- a direct `wasm:call/3` runs in your process: fine for trusted code you call
  synchronously, but it cannot be interrupted;
- an instance another process must be able to stop belongs in a worker.

## Supervise workers

`wasm_instance_worker` is one instance in one process, with a deadline per
call. Start a pool of them under a supervisor of your own:

<!-- check: modules my_app my_app_sup -->
```erlang
-module(my_app_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Mod = persistent_term:get({my_app, plugin}),
    Workers = [#{id => {plugin, N},
                 start => {wasm_instance_worker, start_link,
                           [Mod, #{limits => wasm_limits:untrusted(),
                                   isolation => fresh}]},
                 restart => permanent}
               || N <- lists:seq(1, erlang:system_info(schedulers_online))],
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10}, Workers}}.
```

Call one with a deadline you know:

<!-- check: modules my_app -->
```erlang
{ok, [Result]} = wasm_instance_worker:call(Worker, ~"handle", [Request], 500).
```

A call that passes its deadline kills the worker, so the work really stops,
and the supervisor starts a fresh one.

## Shut down cleanly

`wasm_instance_worker` destroys its instance in `terminate/2`, which runs on a
supervisor shutdown because the worker traps exits. A killed worker runs no
`terminate/2`, and that is safe too: the runtime releases memory when the
owner exits, whatever the reason.

For scripts rather than exports, the same shape holds with
`wasm_script_worker`; see [Workers](worker.md).
