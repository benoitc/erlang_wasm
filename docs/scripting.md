# Hosting scripting languages

This page shows you how to run code that arrives as text, JavaScript, Python
or Lua, one request per sandbox. The **worker kernel**, `wasm_script_worker`,
runs each request in processes of its own, with a deadline, bounded output and
a cleanup afterwards; an **adapter** teaches it one language. Read it when
tenants send you scripts rather than compiled modules.

## Start a worker for a language

<!-- check: needs qjs -->
```erlang
{ok, W} = wasm_script_worker:start_link(
            wasm_javascript_command, #{path => "test/fixtures/lang/qjs.wasm"}),
{ok, #{result := #{~"answer" := 42}}} =
    wasm_script_worker:run(W, ~"export function main(c) { return {answer: c.value + 1}; }",
                           #{~"value" => 41}).
```

`run/3` takes the source and a context, and answers with what the script's
`main` returned. `submit/3`, `await/3` and `cancel/2` do the same without
blocking you.

| language | adapter | artifact | guide |
| --- | --- | --- | --- |
| JavaScript | `wasm_javascript`, `wasm_javascript_command` | QuickJS | [JavaScript](javascript.md) |
| Python | `wasm_python`, `wasm_python_command` | CPython | [Python](python.md) |
| Lua | `wasm_lua` | Lua 5.4 | [Lua](lua.md) |
| your own | `-behaviour(wasm_worker_adapter)` | yours | [Writing an adapter](worker-contract.md) |

The `_command` adapters start the interpreter for every request. The others
start it once, when the worker starts, and restore a **snapshot** of it per
request, which is what turns a CPython request from most of a minute into a
tenth of a second; see [Snapshots](snapshots.md).

## Where request files go

Each request gets its own directory, and a node-wide **reaper** removes it
afterwards, even when the request's processes died. The application runs the
reaper for you. Set where it keeps files:

```erlang
%% sys.config
[{wasm, [{scratch_roots, #{scratch => "/var/lib/myapp/wasm-scratch"}}]}].
```

With `scratch_roots` set, the reaper starts with the application and cleans up
what a crashed node left in those directories. A configured directory belongs
to one node at a time. Without it, the first worker gives the reaper a
directory of this node's own under the user cache, removed at a clean
shutdown; after a crash it is not reclaimed, which is why production should
set it.

`wasm_script_worker:cleanup_stats/0` and `cleanup_requests/0` show what the
reaper holds, and which process holds each request.

## Choose a configuration: metered or compiled

`metered` means a fuel budget stops a runaway script; `compiled` means the
compiled tier is on and only the deadline stops it. They are **mutually
exclusive**: generated code cannot count fuel, so asking for both silently
gets you the interpreter.

| | metered | compiled |
| --- | --- | --- |
| `fuel` | a ceiling, from `wasm_limits:untrusted/0` | `infinity` |
| `compile` | absent | `true`, with `profile => script` |
| what stops a runaway | the fuel budget | **only** the deadline |
| speed | interpreted | compiled, after several hundred requests |

Compiled is worth it once the code is hot: a QuickJS reactor request goes from
20.6 ms to 7.4, Lua from 11.3 to 4.4 and CPython from 119 to 65. Two things
to budget for:

- **Getting there takes a while**, about 150 s and several thousand requests
  on QuickJS, every one of them interpreted. Set `code_cache_dir` so a restart
  does not pay it again: a QuickJS worker then gets there in 1.5 s instead of
  147.
- **Time is the only bound**, so compiled is the one configuration where an
  untrusted guest is stopped by the deadline alone.

[The compiled tier](compiled-tier.md) has the rest.

## Give requests room: heap floors

A request runner holds almost nothing on its own heap, so the collector gives
it the smallest heap and then collects through the request dozens of times; on
QuickJS that was 61% of the request. A floor fixes it:

<!-- check: modules my_adapter -->
```erlang
wasm_script_worker:start_link(my_adapter, #{runner_min_heap_words => 200_000}).
```

The right value belongs to your guest: Lua and QuickJS plateau at 200,000
words, CPython at five times that. [Tuning](tuning.md) is how to find yours.
The emulator rounds a floor up to a heap-size class, 200,000 becoming 318,187
words, 2.4 MiB per concurrent runner; and a floor that does not fit under
`max_heap_words` is refused with a warning.

`capture_min_heap_words` is the same for the process that captures the
snapshot when the worker starts, and on a slow-starting guest it matters most:
a CPython worker start goes from 92 s to 17 s.

<!-- check: modules my_adapter -->
```erlang
wasm_script_worker:start_link(my_adapter, #{capture_min_heap_words => 2_000_000}).
```

Every setting, with its default, is in [Worker configuration](worker-reference.md).
How the kernel's processes fit together is in [Worker
internals](worker-internals.md).
