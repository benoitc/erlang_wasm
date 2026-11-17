# Hosting scripting languages

This page shows you how to run scripts written in JavaScript, Python or Lua.
Each request runs in its own sandbox. Read it when your users (tenants) send
you source code instead of compiled WebAssembly modules.

Two words are used everywhere on this page:

- the **worker kernel**, `wasm_script_worker`, runs each request in its own
  processes. It gives the request a deadline, limits its output, and cleans
  up after it;
- an **adapter** is a module that tells the kernel how to run one language.

## Start a worker for a language

<!-- check: needs qjs -->
```erlang
{ok, W} = wasm_script_worker:start_link(
            wasm_javascript_command, #{path => "test/fixtures/lang/qjs.wasm"}),
{ok, #{result := #{~"answer" := 42}}} =
    wasm_script_worker:run(W, ~"export function main(c) { return {answer: c.value + 1}; }",
                           #{~"value" => 41}).
```

`run/3` takes the source and a context. It returns the value that the
script's `main` function returned. `submit/3`, `await/3` and `cancel/2` do the
same work, but your process does not wait.

| language | adapter | artifact | guide |
| --- | --- | --- | --- |
| JavaScript | `wasm_javascript`, `wasm_javascript_command` | QuickJS | [JavaScript](javascript.md) |
| Python | `wasm_python`, `wasm_python_command` | CPython | [Python](python.md) |
| Lua | `wasm_lua` | Lua 5.4 | [Lua](lua.md) |
| your own | `-behaviour(wasm_worker_adapter)` | yours | [Writing an adapter](worker-contract.md) |

The `_command` adapters start the interpreter again for every request. The
others start it once, when the worker starts, and save a **snapshot**: a copy
of the interpreter's state after start-up. Each request then starts from a
copy of that snapshot (a **restore**). For CPython this changes a request
from most of a minute to a tenth of a second. See [Snapshots](snapshots.md).

## Get a language runtime

The interpreters are built by other projects. The library does not ship them:
you download or build them.

| language | file | how |
| --- | --- | --- |
| JavaScript | `qjs.wasm`, a QuickJS command | `scripts/fetch-qjs-fixture.sh` |
| JavaScript, fast path | `qjs_reactor.wasm` | `scripts/build-quickjs-reactor.sh`, needs the WASI SDK |
| Python | `python.wasm`, a CPython command | `scripts/fetch-python-fixture.sh` |
| Python, fast path | `py_reactor.wasm` and its standard library | `scripts/build-python-reactor.sh`, about twenty minutes |
| Lua | `lua_reactor.wasm` | `scripts/build-lua-reactor.sh`, needs the WASI SDK |

The scripts are in the repository and in the Hex package, under `scripts/`.

## Where request files go

Each request gets its own directory. After the request, the **reaper**
removes it. The reaper is one process per node that cleans up after requests,
even when a request's processes crashed. The application starts it for you.
Set where it keeps files:

```erlang
%% sys.config
[{wasm, [{scratch_roots, #{scratch => "/var/lib/myapp/wasm-scratch"}}]}].
```

With `scratch_roots` set, the reaper starts with the application. It then
cleans up the files that a crashed node left in those directories. Only one
node at a time may use a configured directory.

Without `scratch_roots`, the first worker gives the reaper a directory under
the user cache that only this node uses. A clean shutdown removes it. After a
crash, nothing removes it. So set `scratch_roots` in production.

`wasm_script_worker:cleanup_stats/0` and `cleanup_requests/0` show which
requests the reaper still has to clean, and which process holds each one.

## Know what a crash leaves

A request's directory is named `req-...`. The reaper keeps a journal on
disk, with one record for each running request, so it can find these
directories after a crash. The **runner** in the table is the process that
runs the guest for one request.

| what dies | what is left | who cleans it |
| --- | --- | --- |
| the runner, at a deadline or a crash | nothing of the instance; the request's directory, until its cleanup runs | the reaper, as for any request; the worker starts a new runner before its next request |
| the worker | its runner, which exits when it sees that the worker is gone | nothing else to clean |
| the node, during a request | the request's directory and its journal record | the reaper at the next start, **if** `scratch_roots` names the same directory |
| the host machine, during a request | as above, maybe without the record, because the record is not synced to disk | the next start deletes every `req-` directory that no record names |

When `scratch_roots` is not set, each node uses its own directory, and a later
start never looks in it. So set `scratch_roots` when files left by a crash must
be deleted at the next start.

## Choose a configuration: metered or compiled

A worker runs in one of two configurations:

- **metered**, the default: a fuel budget stops a script that runs too long.
  Fuel counts the work the guest does;
- **compiled**: the [compiled tier](compiled-tier.md) is on, and only the
  deadline stops such a script.

Turn compiled on with one option:

<!-- check: modules my_adapter -->
```erlang
wasm_script_worker:start_link(my_adapter, #{compiled => true}).
```

| | metered | compiled |
| --- | --- | --- |
| `fuel` | a maximum, from `wasm_limits:untrusted/0` | `infinity` |
| option | none | `compiled => true` |
| what stops a script that runs too long | the fuel budget | **only** the deadline |
| speed | interpreted | compiled, after several thousand requests |

`compiled => true` sets `fuel => infinity`, `compile => true`,
`compile_after => 1` and `compile_quality => baseline`. If you set one of
these keys in `limits`, your value is used. There is one exception: a finite
`fuel`. Compiled code cannot count fuel, so the worker refuses to start with
`{bad_option, compiled, #{fuel => N}}`. It does not quietly fall back to the
interpreter.

Compiled helps once the code is hot, that is, once the busy functions are
compiled. A QuickJS reactor request goes from 20.4 ms to 6.9, Lua from 11.4
to 4.4 and CPython from 93.1 to 37.6. Plan for two things:

- **It takes time to get there.** On QuickJS it takes about 150 s and
  several thousand requests, and all of them run interpreted. Set
  `code_cache_dir` so that a restart does not wait again: a QuickJS worker
  then has compiled code after 1.5 s instead of 147.
- **Time is the only limit.** In this configuration, only the deadline stops
  an untrusted guest.

[The compiled tier](compiled-tier.md) has the rest.

## Give requests room: heap floors

The **runner** is the process that runs one request. When it starts, its
heap holds almost nothing, so the Erlang garbage collector gives it the
smallest heap. The collector then runs dozens of times during the request. On
QuickJS that took 61% of the request time.

A **heap floor** (`runner_min_heap_words`) fixes this: it is the heap size,
in words, that the runner starts with. A word is 8 bytes on a 64-bit system.
The shipped adapters set a floor for you: 200,000 words for Lua and QuickJS,
and for CPython 1,500,000 on the compiled tier and 1,000,000 on the
interpreter. For your own adapter, set it per worker, or export `defaults/1`
as [Writing an adapter](worker-contract.md) shows:

<!-- check: modules my_adapter -->
```erlang
wasm_script_worker:start_link(my_adapter, #{runner_min_heap_words => 200_000}).
```

The right value depends on your guest. [Tuning](tuning.md) shows how to find
it. [How a heap floor works](tuning.md#how-a-heap-floor-works) explains how
the value is rounded, the maximum heap it must stay under, and where the
options go.

`capture_min_heap_words` does the same for the process that captures the
snapshot when the worker starts. It matters most for a guest that starts
slowly: a CPython worker start goes from 92 s to 17 s. No adapter sets it for
you.

<!-- check: modules my_adapter -->
```erlang
wasm_script_worker:start_link(my_adapter, #{capture_min_heap_words => 2_000_000}).
```

Every setting, with its default, is in [Worker
configuration](worker-reference.md). How the kernel's processes work together
is in [Worker internals](worker-internals.md).

## Restore the next instance ahead

Use `restore_ahead` when the guest is restored from an image (the saved copy
of the interpreter after start-up) and your workers are idle between
requests. The worker restores the next instance while it waits, so a new
request starts directly with the guest's own work.

<!-- check: modules my_adapter -->
```erlang
{ok, W} = wasm_script_worker:start_link(my_adapter, #{root => scratch,
                                                      restore_ahead => true}).
```

What it changes:

- Each worker has one runner that lives for many requests. It restores the
  instance and runs the request. The request's imports (preopened directories,
  output sinks, host calls) are the ones the adapter's `prepare/3` built for
  that request. They are installed before the guest runs.
- Every request still gets its own instance, restored from the image and used
  once. Globals, linear memory and the files of one request never reach a
  later request. `wasm_worker_lang_SUITE` checks each of these for every
  shipped reactor.
- An idle worker holds one restored instance. For CPython that is about 42 MB
  of linear memory per worker.
- It needs an adapter that supports snapshots, and imports that are all
  functions. An adapter without snapshots ignores the option. If an import is
  not a function, the worker logs a warning and restores for each request, as
  without the option.

It makes a request shorter only when the worker was idle long enough to finish
the restore. A pool that always gives the next request to the worker that just
answered (last in, first out) leaves it no time; rotate between idle workers
instead. Under full load it does not add throughput, because the restore still
has to run.

## Run a pool from one image

Use this when you start several workers with the same adapter and options.
You do nothing to share the image:
a worker started with the same adapter and the same options as a live worker
holds that worker's image instead of loading or capturing its own. A pool of N
workers holds one copy, counts it once against `max_snapshot_bytes`, and
captures once when no image is stored yet, even when the N workers start at
the same moment.

Sharing needs the adapter's snapshot capability to name a module loaded from
bytes, so it has a content hash, and to give a `compatibility_key`. The
shipped adapters (`wasm_python`, `wasm_javascript`, `wasm_lua`) do. Without
either, each worker captures its own image, as a worker with no store does.

Put the workers under a supervisor of your own:

<!-- check: modules my_pool_sup -->
```erlang
-module(my_pool_sup).
-behaviour(supervisor).
-export([start_link/3, init/1]).

start_link(Adapter, Opts, N) ->
    supervisor:start_link(?MODULE, {Adapter, Opts, N}).

init({Adapter, Opts, N}) ->
    Children = [#{id => {worker, I},
                  start => {wasm_script_worker, start_link, [Adapter, Opts]}}
                || I <- lists:seq(1, N)],
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10},
          Children}}.
```

Start it with the adapter, the options every worker shares, and the pool size:

<!-- check: modules my_pool_sup my_adapter -->
```erlang
{ok, Pool} = my_pool_sup:start_link(my_adapter, #{root => scratch}, 8).
```

What it changes:

- The image is loaded from the snapshot store, or captured and stored, by the
  first worker. The workers that start while it does wait for it, and then
  hold the same image. It is freed with the last worker that holds it; the next
  worker to start loads or captures it again.
- The options must be equal, as `=:=` compares them. A worker with other
  options, another adapter, or an artifact whose module changed has its own
  image.
- Each worker still loads its own artifact (what the adapter loads once at
  start, such as the guest module). A crashed worker restarts alone, on the
  image the others hold.
- Isolation does not change: every request still gets its own instance,
  restored from the image and used once.

`capture_timeout` limits the capture, as before. A worker waits for another
worker's capture at most `capture_timeout` and 30 seconds; past that, it
captures its own.

## Read this next

The page for your language: [JavaScript](javascript.md), [Python](python.md) or
[Lua](lua.md).
