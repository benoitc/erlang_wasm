# Building a worker with an isolated context

This page shows you how to run untrusted WebAssembly per request,
Cloudflare-Workers style: one cached module, a pool of worker processes, one
instance per worker, and no state surviving a request. Read it when a module you
did not write handles user traffic, or when you need a timeout that actually
stops the work. The runtime ships no worker of its own, so what follows is the
pattern, and `examples/wasm_worker.erl` is a working implementation you can copy.

## Decide whether you need one

An inline `wasm:call/3` runs in *your* process. That is the fast path and the
right answer for trusted code you call synchronously. It also means:

| | inline | inside a worker |
| --- | --- | --- |
| module loops forever | hangs you, unkillable without killing yourself | `exit(Pid, kill)` |
| request timeout | impossible; the call is synchronous | `gen_server:call` timeout, then kill |
| runaway allocation, terms | grows *your* heap | `max_heap_size` kills the worker |
| runaway allocation, guest memory | grows linear memory or the object store, neither on your heap | `max_memory_pages` refuses it |
| two callers at once | racy: both read-modify-write the state | serialised by the mailbox |
| visible in `observer` | no | labelled process |

If none of those rows worry you, call inline and skip this page.

A worker that answers *one request per call* is this page. A guest that keeps
running between requests, reading its own stdin, is [streams.md](streams.md);
it uses the same process boundary for the same reasons.

## The request path

```
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

The timeout is the whole reason for the process. `wasm:call/3` runs in the
calling process and cannot be interrupted, so without a process boundary your
timeout is advice rather than a bound.

## Start one

```erlang
{ok, Mod}  = wasm:load_file("plugin.wasm"),      % compiled once, cached
{ok, W}    = wasm_worker:start_link(Mod, #{isolation => fresh,
                                           limits => wasm_limits:untrusted()}),
{ok, [R]}  = wasm_worker:call(W, ~"handle", [RequestId], 500),
ok         = wasm_worker:stop(W).
```

The worker is an ordinary `gen_server`. Its `init` calls `wasm:instantiate/3`
and its `handle_call` calls `wasm:call/4`. That is the whole trick: it uses the
same inline API you would, it just owns the instance.

Two worked embeddings of this pattern, with guests to run in them, are in
[guests.md](guests.md): `examples/plugin_worker.erl` for logic compiled ahead of
time, and `examples/script_worker.erl` for logic that arrives as text.

## Lifecycle

```
   wasm:load(Bin)                     once per module, node-wide, cached
        |
        v
   spawn worker
        |
        v
   init/1 --> wasm:instantiate(Mod, Imports, Limits)
        |     proc_lib:set_label({wasm_worker, Name})
        v
     ready <---------------------------------+
        |                                     |
        | request                             | isolation = reuse
        v                                     |
    running -- wasm:call(Inst, F, Args) ------+
        |                                     |
        | isolation = fresh                   |
        v                                     |
   wasm:destroy + re-instantiate -------------+
        |
        | timeout / kill / crash / shutdown
        v
   terminate -- wasm:destroy(Inst); pages released
                (also automatic if the worker is killed)
```

Only the first caller anywhere on the node pays for decode and validation, since
`wasm:load/1` is cached. Measured on a 122 KB Rust binary: 45 ms the first time,
16 us after that. Instantiating is about 15 us.

## Choose an isolation policy

This is the choice that decides whether your Workers host is correct.

| policy | what you get | cost per request |
| --- | --- | --- |
| `fresh` (default) | nothing survives a request: memory, globals and tables are all new | one `destroy` plus one `instantiate` |
| `reuse` | faster, but globals and linear memory persist between requests | none |

Use `fresh` for anything untrusted. "My worker leaked data between requests" is
the failure `reuse` gives you, and it is the kind that shows up in production
rather than in tests, because a single-request test cannot see it.

You can afford `fresh` precisely because the module is cached and a small
instance costs about 64 KB, so a reset is microseconds rather than milliseconds.

## Bound the work and the time

```erlang
Limits = #{fuel => 10_000_000,     % execution budget
           max_depth => 256,       % WebAssembly call depth
           max_heap_words => 8 * 1024 * 1024}.
```

You need both a fuel budget and a timeout. `fuel` bounds *work*, not *time*, and
a host function that blocks consumes none of it.

Make the timeout kill the worker rather than merely stop waiting. If you abandon
a call, the module keeps running, holding a scheduler and its memory, with
nobody watching:

```erlang
try
    gen_server:call(Pid, {run, F, Args}, Timeout)
catch
    exit:{timeout, _} ->
        exit(Pid, kill),                 % the work actually stops
        {error, timed_out}
end.
```

`wasm_worker:call/3` uses `worker_timeout` for `Timeout`, five seconds unless
you set it:

```erlang
application:set_env(wasm, worker_timeout, 30000).
```

Pass a deadline you actually know to `call/4` instead. The default is there so
that copying the example does not silently give you five seconds.

## Get parallelism from more workers

Never from concurrent calls into one instance. Two processes calling one
instance both read-modify-write the same state, and the last writer wins.

```erlang
%% One module, N workers, check one out per request.
{ok, Mod} = wasm:load_file("plugin.wasm"),
Pool = [begin {ok, W} = wasm_worker:start_link(Mod, Opts), W end
        || _ <- lists:seq(1, erlang:system_info(schedulers_online))],
```

Put them under a supervisor with `restart => temporary`. A worker carries state
only its creator can reconstruct, so restarting one gives you a *different*
worker wearing the same pid.

## Clean up

`terminate/2` calls `wasm:destroy/1`, which returns the instance's pages
immediately. Trap exits, or `terminate/2` will not run at all on a supervisor
shutdown.

Forgetting is safe rather than a leak: `wasm_keeper` monitors the owning process
and releases its pages when it exits, kill included. That matters here, because
the timeout above kills the worker outright and a killed process runs no
`terminate/2`.

## What the process does not buy you

A process is a fault and lifecycle boundary, not a security boundary. The
sandbox is validation, bounds checking and the capability model, and those apply
identically to an inline call. `wasm_limits` lists what stays uncovered: side
channels, scheduler saturation across many workers, and host functions you write
yourself.
