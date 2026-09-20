# Using workers

This page shows you how to run WebAssembly you did not write, one request at a
time, with a deadline that actually stops the work. `wasm_instance_worker` is
that worker: one instance, in one process, installed with the application.
Read it when a module you did not write handles user traffic.

To run scripts rather than exports (JavaScript, Python, Lua), use the worker
kernel instead: [Hosting scripting languages](scripting.md).

## Decide whether you need one

An inline `wasm:call/3` runs in *your* process. That is the fast path and the
right answer for trusted code you call synchronously. It also means:

| | inline | inside a worker |
| --- | --- | --- |
| module loops forever | hangs you, unkillable without killing yourself | the worker is killed |
| request timeout | impossible; the call is synchronous | a deadline per call |
| runaway allocation, terms | grows *your* heap | `max_heap_size` kills the worker |
| runaway allocation, guest memory | grows linear memory, not your heap | `max_memory_pages` refuses it |
| two callers at once | racy: both read-modify-write the state | serialised by the mailbox |
| visible in `observer` | no | labelled process |

If none of those rows worry you, call inline and skip this page.

A guest that keeps running between requests, reading its own stdin, is
[Streams](streams.md); it uses the same process boundary for the same reasons.

## Start one

```erlang
{ok, Mod} = wasm:load_file("plugin.wasm"),      % decoded once, cached
{ok, W}   = wasm_instance_worker:start_link(Mod, #{isolation => fresh,
                                                   limits => wasm_limits:untrusted()}),
{ok, [R]} = wasm_instance_worker:call(W, ~"handle", [RequestId], 500),
ok        = wasm_instance_worker:stop(W).
```

The last argument of `call/4` is the deadline in milliseconds. The worker is an
ordinary `gen_server`: its `init` calls `wasm:instantiate/3` and its
`handle_call` calls `wasm:call/4`. It uses the same API you would; it just owns
the instance.

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

The deadline is the whole reason for the process. `wasm:call/3` runs in the
calling process and cannot be interrupted, so without a process boundary a
timeout is advice rather than a bound.

## Choose an isolation policy

| policy | what you get | cost per request |
| --- | --- | --- |
| `fresh` (default) | nothing survives a request: memory, globals and tables are all new | one `destroy` plus one `instantiate` |
| `reuse` | faster, but globals and linear memory persist between requests | none |

Use `fresh` for anything untrusted. Data leaking between requests is the
failure `reuse` gives you, and a single-request test cannot see it. `fresh` is
affordable because the module is cached: instantiating and destroying a 46 KB
plugin measures 79 us.

## Bound the work and the time

You need both. **Fuel** bounds *work*, not time, and a host function that
blocks consumes none of it; the deadline bounds time:

```erlang
Limits = #{fuel => 10_000_000,     % execution budget
           max_depth => 256,       % WebAssembly call depth
           max_heap_words => 8 * 1024 * 1024}.
```

When a call passes its deadline, the worker is killed, so the work stops
rather than running on with nobody waiting. `call/3` uses the `worker_timeout`
application setting, five seconds unless you set it; pass a deadline you know
to `call/4` instead.

[Stop a runaway](examples/stop-a-runaway.md) shows both bounds firing.

## Get parallelism from more workers

Never from concurrent calls into one instance: two processes calling one
instance both read-modify-write the same state. Run one worker per scheduler
and give each request to one of them:

```erlang
{ok, Mod} = wasm:load_file("plugin.wasm"),
Pool = [begin {ok, W} = wasm_instance_worker:start_link(Mod, Opts), W end
        || _ <- lists:seq(1, erlang:system_info(schedulers_online))].
```

Put them under your own supervisor, as [Put it in an OTP
application](otp.md) shows. With `isolation => fresh` a worker holds nothing a
restart would lose, so `permanent` is right; with `reuse` it holds state only
its creator can rebuild, so start it `temporary`.

## Clean up

`terminate/2` calls `wasm:destroy/1`, which returns the instance's pages at
once; the worker traps exits, so this runs on a supervisor shutdown. A killed
worker runs no `terminate/2`, and that is safe too: the runtime releases an
instance's pages when its owner exits, kill included.

## What the process does not buy you

A process is a fault and lifecycle boundary, not a security boundary. The
sandbox is validation, bounds checking and the capability model, and those
apply identically to an inline call. `wasm_limits` lists what stays uncovered:
side channels, scheduler saturation across many workers, and host functions
you write yourself. See [Security](security.md).

Every setting is in [Worker configuration](worker-reference.md).
