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
time, and `examples/qjs_worker.erl` for logic that arrives as text.

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

## Choose a configuration: `metered` or `compiled`

These two are **mutually exclusive**, and a host that asks for both gets
neither an error nor a warning.

| | `metered` | `compiled` |
| --- | --- | --- |
| `fuel` | a ceiling, from `wasm_limits:untrusted/0` | `infinity` |
| `compile` | absent | `true`, with `profile => script` |
| what stops a runaway | the fuel budget, without a kill | **only** the owner's wall-clock deadline |
| the compiled tier | off | on, after several hundred requests |

`wasm_jit:entry/3` enables generated code only when fuel is `infinity`, so
setting `compile => true` while keeping a fuel ceiling **silently gets you the
interpreter**: no error anywhere, and a worker whose slowness has no visible
cause. `wasm_worker_lang_SUITE` asserts that over 500 requests, because a
shorter run is silent whether the tier is off or merely slow.

Under `compiled` the only thing between the node and a runaway guest is a kill
from outside it. That is a security statement rather than a tuning note: it is
the one configuration where an untrusted guest is bounded by time alone.

Turning the tier on is also where PR #15's compile-side bounds belong, because
CPython's artifact is 80 MB of generated code and the node-wide budget is what
stops one tenant's module taking the node. Both keys are off by default; see
[the compiled tier guide](compiled-tier.md).

**`max_heap_words` in a limits map does not set the process flag.** It is
applied by whoever owns the instance, with `spawn_opt` at creation rather than
`process_flag` inside the process, because the closure and the request are
copied onto the new heap before an in-process call would run. The worker kernel
does this for you; an inline caller does not get it by passing the key.

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

## Every setting, and what it bounds

The kernel in `examples/script_worker.erl` has more knobs than the section
above, and all of them have defaults that a copied example gets silently. They
are listed here because a default nobody can find is a default nobody can
change.

**Per request, in the `limits` map** you hand `script_worker:start_link/2`.
These merge over `wasm_limits:untrusted/0`, so everything that preset bounds
still applies:

| setting | default | what it bounds |
| --- | ---: | --- |
| `timeout` | 5 s | one request, wall clock, enforced by the guardian |
| `max_output_bytes` | 1 MiB | stdout and stderr, each separately; also accepts `#{stdout := N, stderr := M}` |
| `max_result_bytes` | 1 MiB | the dedicated result channel |
| `max_combined_bytes` | 1 MiB | stdout **and** the result together, on `script_v1.combined`, where they share one descriptor |
| `max_request_bytes` | 1 MiB | the source plus the encoded context |
| `max_staged_bytes` | 8 MiB | everything the adapter stages, across all mounts |
| `max_staged_files` | 64 | how many files it stages |

An interpreter needs several of these raised knowingly, and an adapter never
raises one for you: [the Python guide](python.md) has the four CPython needs
and what each was measured at.

**Per worker, in the options map**, beside `root`:

| setting | default | what it bounds |
| --- | ---: | --- |
| `trusted` | `false` | whether a `mode => write` mount is allowed at all |
| `capture_timeout` | 60 s | one snapshot capture and its hooks, at `start_link/2`. CPython needs about 90 s and so must raise it |

**Per reaper**, in the second argument to `worker_reaper:start_link/2`. These
bound cleanup, which runs after a request has already been answered:

| setting | default | what it bounds |
| --- | ---: | --- |
| `max_cleanup_jobs` | 8 | cleanup jobs running at once |
| `cleanup_queue_len` | 256 | jobs waiting; with the above, what **admission** counts against |
| `cleanup_retries` | 3 | attempts after the first failure |
| `cleanup_backoff` | 1 s, 4 s, 16 s | between those attempts |
| `cleanup_timeout` | 30 s | **one callback**, not one job |
| `cleanup_job_deadline` | 120 s | the whole job, every callback and action together |
| `max_cleanup_actions` | 64 | actions an adapter may register per request |

The last three are three different bounds and it is worth being exact about
why. A job with eight actions and a `cleanup/1` could otherwise spend nine
callback timeouts, so the job carries its own total. And the action list is
adapter-controlled, so without a ceiling an adapter in a loop registers until
the reaper's memory is the bound.

When `live + pending + held + queued + running` reaches
`max_cleanup_jobs + cleanup_queue_len`, `submit` answers
`{error, #{kind => cleanup_saturated}}`. That is a refusal you can retry rather
than a leak you cannot see.

**Node-wide, through `application:set_env/3`**:

| setting | default | what it bounds |
| --- | ---: | --- |
| `max_snapshot_bytes` | `infinity` | what every snapshot image **retains**, across the node. `infinity` means unbounded, not off |
| `snapshot_dir` | unset | where images are kept between restarts. Unset means images live only in memory |
| `code_cache_dir` | unset | where generated code is kept. Unset means the compiled tier recompiles on every start |
| `page_limit` | see `wasm_engine` | linear memory pages across every instance on the node |

`max_snapshot_bytes` and `page_limit` are separate on purpose: one bounds the
images beside your instances and the other bounds the instances. See
[snapshots](snapshots.md) for what an image retains, which is much less than
the address space it covers.

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
