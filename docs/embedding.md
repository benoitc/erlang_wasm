# Hold modules and instances

This page tells you where modules and instances live in a long-running
application: which process owns each one, where they go in your supervision
tree, why you load a module once, and how much guest memory the node allows.
A supervision tree is the set of supervisors (processes that start other
processes and restart them when they crash) that make up your application.
Read this page once your first `wasm:call/3` works and you are deciding where
the code belongs. For a first try, start with
[Getting started](getting-started.md).

## Start the runtime with your application

List `wasm` in your application's `applications`, so that it starts before
your application:

```erlang
%% src/my_app.app.src
{application, my_app,
 [{applications, [kernel, stdlib, wasm]},
  {mod, {my_app, []}}]}.
```

In the shell, or in a test, start it by hand:

```erlang
{ok, _} = application:ensure_all_started(wasm).
```

The `wasm` application has its own processes: the module cache, the node's
page budget (the limit on guest memory for the node), the keeper (it records
who holds each shared table, global and memory), and the cleanup after worker
requests. There is no instance supervisor. Your instances live in your
processes, in the shape your application chooses:

```text
your node
  +-- wasm_sup               the wasm application, started before yours
  |     +-- wasm_store_sup   the long-lived ETS tables
  |     +-- wasm_engine_sup  the node-wide page budget
  |     +-- wasm_keeper_sup  who holds each shared resource
  |     +-- wasm_code_sup    generated code, the compilers
  |     +-- wasm_cache_sup   the module cache, the images workers share
  |     +-- wasm_worker_sup  request cleanup for workers
  |
  +-- my_app_sup             your application
        +-- {plugin, 1}      a wasm_instance_worker: one instance
        +-- {plugin, 2}      a wasm_instance_worker: one instance
        +-- ...
```

[Architecture](architecture.md#the-supervision-tree) has the full tree of
the `wasm` application, with the module that runs each part.

## Load modules once, at startup

A module and an instance are different things, and the difference tells you
where to put each one:

| | module | instance |
| --- | --- | --- |
| what | decoded, validated code | running state: memory, globals, tables |
| can change | no | yes |
| shared | yes, by the whole node, cached by content hash (a checksum of its bytes) | no, owned by one process |
| cost | 1.6 ms to compile a 46 KB plugin and 310 ms for a 1.8 MB QuickJS build, 18 us to load either again | 540 us for that plugin and 3.2 ms for QuickJS, plus its declared memory |

`wasm:load_file/1` and `wasm:load/1` decode and validate a module, and keep it
in the **module cache** under its content hash. So load a module when your
application starts, keep the handle, and make as many instances from it as
you need:

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

Why once, and not per request:

- The cache keeps modules in `persistent_term`. Reading is fast, but each
  change makes the BEAM scan every process. So the node accepts at most 50
  new modules a second (`max_module_loads_per_second`), and holds at most 256
  modules and 2 GiB. Past these, a load returns an error.
- A request path that loads and unloads a module decodes it every time, and
  past 50 requests a second it fails with `load_rate_exceeded`.
- Loading bytes that are already in the cache is cheap and is not counted
  against the rate.

[Modules are loaded once](design-principles.md#modules-are-loaded-once) gives
the whole reason, and [Configuration](configuration.md) has the three
settings.

The process that loads a module holds it. When the last process that holds a
module exits, the module leaves the cache, and instantiating from the old
handle returns `{error, #{kind := module_not_loaded}}`. Your application's
`start/2` runs in a process that lives as long as your application, so a
module loaded there stays. A server that runs a component per request calls
`wasm_component:hold/1` once from a long-lived process, for the same reason.

A module from the cache is also what lets processes share an instance's
code. In a module with more than 256 functions, each function body is
prepared the first time a process calls it, and each process keeps its own
copy. When several processes call one instance, as a kernel's tasks or a
component's threads do, and the module came from `wasm:load/1`, they publish
what they prepare for each other instead, so the work is done once and kept
once. `wasm_module_cache:stats/0` reports the memory it holds as `ir_bytes`.

`wasm:compile/1` does not use the cache. Use it only for work you do once.
It also takes the text format:

```erlang
{ok, Mod} = wasm:compile({wat, ~"(module (func (export \"f\") (result i32) i32.const 7))"}).
```

`load/1` takes only bytes. A module built from text gets a new identity each
time it is validated, so the cache would have no stable key for it.

## Know who owns the instance

An instance belongs to the process that created it, like a port or an ETS
table (an in-memory table owned by one process):

| event | effect |
| --- | --- |
| owner alive | the handle is valid; you may pass it to other processes |
| **two processes call at the same time** | **unsafe**: both read and change the same state, and the last write wins |
| trap | the call stops; the instance stays valid and you can use it |
| fuel or call depth runs out | the same: the call stops, and you can still use the instance |
| `destroy/1` | frees pages and state; calling it twice is harmless |
| owner exits | pages are freed automatically, even when it is killed |

The row about two processes is the one that causes bugs. If more than one
process needs to call an instance, or another process must be able to stop
it, put the instance inside a process: a worker. Its mailbox then handles the
calls one at a time. A direct `wasm:call/3` runs in your own process. That is
fine for trusted code that you call and wait for, but nothing can interrupt
the call.

If you forget `destroy/1`, nothing leaks. `wasm_keeper` monitors the owner
process and frees its pages when it exits, however it exits.

Stopping the `wasm` application stops what it made: its store and its page
accounting go with it. After you start it again, an instance made before the
stop can no longer grow its memory, and a call that reaches its wasm tables or
shared globals traps with `runtime_stopped`. Make new instances after the
restart, and drop the old ones: their memory is freed when nothing refers to
them.

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
stops. The supervisor then starts a new worker. To run scripts instead of
calling exports, use `wasm_script_worker` in the same way; see
[Using workers](worker.md).

## Shut down cleanly

`wasm_instance_worker` destroys its instance in `terminate/2`. This callback
runs when the supervisor shuts the worker down, because the worker traps exits
(it receives the exit signal as a message instead of dying at once). A killed
worker does not run `terminate/2`, and that is safe too: the runtime frees the
memory when the owner exits, for any reason.

## Set limits

Per instance:

```erlang
{ok, Inst} = wasm:instantiate(Mod, Imports, #{fuel => 10_000_000,
                                              max_depth => 256}).
```

Or per call, which is usually what you want for a request:

```erlang
{ok, R} = wasm:call(Inst, ~"handle", [Req], #{fuel => 1_000_000}).
```

Start from `wasm_limits:untrusted/0` or `wasm_limits:trusted/0`, and raise
the values you need.

`fuel` limits work, not time. The runtime takes fuel at each call and each
time a loop jumps back to its start. Code that runs forever must do one of
these again and again, so fuel always stops a loop that never ends. It does
not stop a host function that blocks. To limit real time, you need a timeout,
and a timeout needs a separate process.

## Move bytes in and out

```erlang
{ok, Bin} = wasm:read_memory(Inst, Ptr, Len),
ok        = wasm:write_memory(Inst, Ptr, <<"data">>),
{ok, Pages} = wasm:memory_size(Inst).
```

Plan for about the declared memory per instance: a module that declares one
64 KiB page uses about 64 KB, plus the process you put it in. Large copies run
at about 0.5 GB/s, because the runtime builds the bytes from 64-bit words.

## Set the page budget

Linear memory is stored outside the process heap, and `max_heap_size` does
not see it. So the node's page budget is the only thing that limits it. Set
it to what your node can afford:

```erlang
wasm_engine:set_page_limit(16384),          % 1 GiB
#{pages_in_use := N} = wasm_engine:stats().
```

Without a call, the limit is 16384 pages (1 GiB), or the `page_limit` value
in the `wasm` application environment; see
[Configuration](configuration.md). While the node is over the limit, every
new allocation on the node is refused. What the budget counts (chunks,
restored pages, the store of garbage-collected objects) is in
[The node page budget](memory.md#the-node-page-budget).

## Keep garbage-collected references

A module that uses garbage collection can return a reference to one of its
objects. The runtime cannot see what you keep in your own variables, so it
**pins** every reference that leaves it: call results, `wasm:get_global/2`
results, and the values carried by an uncaught exception. A pinned object is
never collected. You release it when you are done:

```erlang
{ok, [Ref]} = wasm:call(Inst, ~"make", []),
%% ... use it ...
ok = wasm:release(Inst, Ref).
ok = wasm:release_all(Inst).        % or drop the lot, per request
```

- If you never release, the pins stay for the life of the instance. An
  embedder that calls a function returning a struct a million times keeps a
  million objects alive.
- `release_all/1` fits a request: run it, take what you need out of the
  results, then drop every pin.
- A reference pinned twice needs releasing twice. Releasing one that was never
  pinned is not an error.
- Call `wasm:pin/2` yourself in one case: a **host function that keeps a
  reference it received**. Its arguments are safe during the call, and not
  after it.

How the heap stores pins is in
[Garbage collection](gc.md#references-the-embedder-holds).

## Link modules together

Use an export of one instance as an import of another:

```erlang
{ok, LogFn} = wasm:extern(Lib, ~"log"),
{ok, App}   = wasm:instantiate(AppMod, #{{~"lib", ~"log"} => LogFn}).
```

Imported memories and tables are shared, not copied, so both instances see
the same bytes and the same table entries. A `funcref` (a reference to a
function) remembers the instance that defined it. So when one module writes a
reference into a shared table, a call through it runs that module's function,
with that module's memory and globals.

## Read this next

[Host functions](host-functions.md), to give a module Erlang code to call,
then [Configuration](configuration.md) for every setting named here.
