# Put it in an OTP application

This page shows where each piece goes in a real application: when to load a
module, which process owns an instance, where workers go in your supervision
tree, and what happens at shutdown. A supervision tree is the set of
supervisors (processes that restart other processes when they crash) that
make up your application. Read this page once your first call works and you
are deciding where the code belongs.

## Start the runtime with your application

List `wasm` in your application's `applications`, so that it starts before
your application:

```erlang
%% src/my_app.app.src
{application, my_app,
 [{applications, [kernel, stdlib, wasm]},
  {mod, {my_app, []}}]}.
```

The `wasm` application owns the module cache, the node's page budget (the
limit on guest memory for the node) and the reaper (the process that cleans up
after requests). You do not need to start anything else.

## Load modules once, at startup

`wasm:load_file/1` decodes and validates a module, and keeps it in a cache
under its content hash (a checksum of its bytes). So load it when your
application starts, and keep the handle:

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

A module never changes and can be shared. Every instance made from it gets
its own state, so one handle is enough for the whole node.

## Know who owns an instance

An instance belongs to the process that created it. When that process exits
for any reason, even when it is killed, the runtime frees the instance's
memory. So:

- a direct `wasm:call/3` runs in your process. This is fine for trusted code
  that you call and wait for, but nothing can interrupt the call;
- if another process must be able to stop an instance, put the instance in a
  worker.

## Supervise workers

`wasm_instance_worker` is one instance in one process, with a deadline for
each call. Start a pool of them under your own supervisor:

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

Call one with a deadline that you choose:

<!-- check: modules my_app -->
```erlang
{ok, [Result]} = wasm_instance_worker:call(Worker, ~"handle", [Request], 500).
```

When a call passes its deadline, the worker is killed, so the work really
stops. The supervisor then starts a new worker.

## Shut down cleanly

`wasm_instance_worker` destroys its instance in `terminate/2`. This callback
runs when the supervisor shuts the worker down, because the worker traps exits
(it receives the exit signal as a message instead of dying at once). A killed
worker does not run `terminate/2`, and that is safe too: the runtime frees the
memory when the owner exits, for any reason.

To run scripts instead of calling exports, use `wasm_script_worker` in the
same way; see [Workers](worker.md).

## Read this next

[Using workers](worker.md), to run code you did not write.
