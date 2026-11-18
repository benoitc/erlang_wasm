# Using workers

This page shows you how to run WebAssembly you did not write, one request at a
time, with a deadline that really stops the work. `wasm_instance_worker` is
that worker: one instance in one process, shipped with the application. Read
this page when a module you did not write handles user traffic.

To run scripts instead of calling exports (JavaScript, Python, Lua), use the
worker kernel instead: [Hosting scripting languages](scripting.md).

## The words on this page

| word | what it means here |
| --- | --- |
| **worker** | an Erlang process that owns one guest instance and runs requests on it, one at a time. |
| **deadline** | the time a call may take, in milliseconds. When it passes, the worker is killed. |
| **isolation** | what a worker keeps between two requests: nothing with `fresh`, the instance's state with `reuse`. |

Other terms are in the [glossary](concepts.md#glossary).

## Decide whether you need one

An inline `wasm:call/3` runs in *your* process. It is the fast way, and the
right one for trusted code that you call and wait for. It also means:

| | inline | inside a worker |
| --- | --- | --- |
| module loops forever | your process hangs; only killing it stops the guest | the worker is killed |
| request timeout | impossible; you wait for the call to return | a deadline per call |
| guest creates too many Erlang terms | grows *your* heap | `max_heap_size` kills the worker |
| guest asks for too much guest memory | grows linear memory, not your heap | `max_memory_pages` refuses it |
| two callers at once | unsafe: both read and change the same state | the mailbox runs them one after the other |
| visible in `observer` | no | as a named process |

If none of these rows is a problem for you, call inline and skip this page.

A guest that keeps running between requests and reads its own stdin is
covered in [Talk to a running guest](streams.md). It uses a process for the
same reasons.

## Start one

```erlang
{ok, Mod} = wasm:load_file("plugin.wasm"),      % decoded once, cached
{ok, W}   = wasm_instance_worker:start_link(Mod, #{isolation => fresh,
                                                   limits => wasm_limits:untrusted()}),
{ok, [R]} = wasm_instance_worker:call(W, ~"handle", [RequestId], 500),
ok        = wasm_instance_worker:stop(W).
```

The last argument of `call/4` is the deadline in milliseconds. The worker is a
normal `gen_server`. Its `init` calls `wasm:instantiate/3` and its
`handle_call` calls `wasm:call/4`. It uses the same API as you; the only
difference is that it owns the instance.

## The request path

```text
  caller                worker process           erlang_wasm            guest
    │                        │                        │                   │
    ├── call(W, Req, 500) ──►│                        │                   │
    │                        ├── fuel, fresh state ──►│                   │
    │                        │                        ├── an export ─────►│
    │                        │                        │◄── WASI syscall ──┤
    │                        │                        │   (capability     │
    │                        │                        │    checked here)  │
    │                        │◄─────── result ────────┤                   │
    │◄────── {ok, R} ────────┤                        │                   │
    │                        │                        │                   │
    │        timeout ──► worker killed, pages released                    │
```

The deadline is the main reason for the separate process. `wasm:call/3` runs in
the calling process and nothing can interrupt it. Without a separate process, a
timeout cannot stop the guest.

## Choose an isolation policy

| policy | what you get | cost per request |
| --- | --- | --- |
| `fresh` (default) | nothing is kept after a request: memory, globals and tables are all new | one `destroy` plus one `instantiate` |
| `reuse` | faster, but globals and linear memory are kept between requests | none |

Use `fresh` for any untrusted code. With `reuse`, data from one request can
reach the next one, and a test with a single request cannot show this. `fresh`
is cheap because the module is cached: to instantiate and destroy a 46 KB
plugin takes 79 us.

## Limit the work and the time

You need both limits. **Fuel** counts guest instructions: it limits *work*, not
time. A host function that blocks uses no fuel. The deadline limits time:

```erlang
Limits = #{fuel => 10_000_000,     % execution budget
           max_depth => 256,       % WebAssembly call depth
           max_heap_words => 8 * 1024 * 1024}.
```

When a call passes its deadline, the worker is killed. The work stops; it does
not continue with nobody waiting for the result. `call/3` uses the
`worker_timeout` application setting, which is five seconds unless you change
it. If you know the right deadline, pass it to `call/4` instead.

The module's start function runs when the worker instantiates it, before any
request, and has a deadline too: `timeout` in the worker's `limits`, or
`worker_timeout`. A start that runs past it kills the worker.

[Stop a runaway](examples/stop-a-runaway.md) shows both limits stopping a
guest.

## Run requests in parallel with more workers

Do not call one instance from several processes at once: both calls would read
and change the same state. Instead, run one worker per scheduler and give each
request to one of them:

```erlang
{ok, Mod} = wasm:load_file("plugin.wasm"),
Pool = [begin {ok, W} = wasm_instance_worker:start_link(Mod, Opts), W end
        || _ <- lists:seq(1, erlang:system_info(schedulers_online))].
```

Put them under your own supervisor, as [Hold modules and
instances](embedding.md#supervise-workers) shows. With `isolation => fresh`, a
restart loses nothing, so start the worker `permanent`. With `reuse`, the
worker keeps state that only the process that created it can rebuild, so start
it `temporary`.

## Clean up

`terminate/2` calls `wasm:destroy/1`, which frees the instance's memory pages
at once. The worker traps exits, so this also runs when a supervisor shuts it
down. A killed worker does not run `terminate/2`, and that is safe too: the
runtime frees an instance's pages when its owner process exits, even when it
is killed.

## What the process does not protect

A process limits the damage of a crash and controls the instance's lifetime.
It is not a security boundary. The sandbox is made of validation, bounds checks
and the capability model, and they work the same way in an inline call.
`wasm_limits` lists what they do not cover: side channels, schedulers kept busy
by many workers, and host functions you write yourself. See
[Security](security.md).

`start_link/2` takes four options: `imports`, `limits`, `isolation` and
`name`. The `worker_timeout` application setting is in
[Configuration](configuration.md).

## Read this next

[Security](security.md), for what the limits cover. To run scripts instead,
[Hosting scripting languages](scripting.md).
