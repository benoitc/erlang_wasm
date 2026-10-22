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

## Read this next

The page for your language: [JavaScript](javascript.md), [Python](python.md) or
[Lua](lua.md).
