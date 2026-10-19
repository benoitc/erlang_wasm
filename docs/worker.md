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

## Restore a script worker's next instance ahead

This part is about `wasm_script_worker`, the kernel behind the JavaScript, Python
and Lua adapters. Use `restore_ahead` when the guest restores from a captured
image and your workers have idle time between requests: the next instance is
restored while the worker waits, so a request starts at the guest's own work.

<!-- check: modules my_adapter -->
```erlang
{ok, W} = wasm_script_worker:start_link(my_adapter, #{root => scratch,
                                                      restore_ahead => true}).
```

What it changes:

- One long-lived runner per worker restores the instance and runs the request.
  The request's imports (preopens, output sinks, host calls) are the ones its
  adapter's `prepare/3` built for it, installed before the guest runs.
- Every request still gets an instance restored from the image and used once.
  Globals, linear memory and the files of an earlier request never reach a
  later one; `wasm_worker_lang_SUITE` checks each of these for every shipped
  reactor.
- An idle worker holds one restored instance: for CPython that is about 42 MB
  of linear memory per worker.
- It needs a snapshot capability and imports that are all functions. Without
  either, the worker logs a warning and restores per request as before.

It shortens a request only when the worker was idle long enough to finish the
restore. A pool that always hands the next request to the worker that just
answered (last in, first out) gives it no time; rotate idle workers instead.
Under full load it adds no throughput, because the restore still has to run.

## Run a pool from one image

This part is about `wasm_script_worker` too. Use it when you start several
workers on the same adapter and options: started one by one, each worker loads
or captures its own copy of the image, so a pool of N holds N copies, charges
`max_snapshot_bytes` N times, and captures up to N times when no image is filed
yet. Prepare the image once and start every worker from it instead:

<!-- check: modules my_adapter -->
```erlang
{ok, P} = wasm_script_worker:prepare(my_adapter, Opts),
{ok, W} = wasm_script_worker:start_link(my_adapter, Opts#{prepared => P}),
ok = wasm_script_worker:release_prepared(P).
```

Put it under a supervisor with a small holder process first, so the pool
prepares again if the holder restarts. The holder prepares in `init/1` and lets
go in `terminate/2`:

<!-- check: modules my_pool_sup my_pool_holder -->
```erlang
-module(my_pool_holder).
-behaviour(gen_server).
-export([start_link/2, start_worker/0]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

start_link(Adapter, Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, {Adapter, Opts}, []).

%% A worker's start function: fetch the prepared image and start from it.
start_worker() ->
    {Adapter, Opts, P} = gen_server:call(?MODULE, prepared),
    wasm_script_worker:start_link(Adapter, Opts#{prepared => P}).

init({Adapter, Opts}) ->
    process_flag(trap_exit, true),
    case wasm_script_worker:prepare(Adapter, Opts) of
        {ok, P} -> {ok, {Adapter, Opts, P}};
        {error, Reason} -> {stop, Reason}
    end.

handle_call(prepared, _From, State) ->
    {reply, State, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, {_Adapter, _Opts, P}) ->
    wasm_script_worker:release_prepared(P).
```

The supervisor is `rest_for_one`, the holder first and a supervisor of the
workers after it, so a new image restarts every worker and a crashed worker
restarts alone:

<!-- check: modules my_pool_sup my_pool_holder -->
```erlang
-module(my_pool_sup).
-behaviour(supervisor).
-export([start_link/3, init/1]).

start_link(Adapter, Opts, N) ->
    supervisor:start_link(?MODULE, {pool, Adapter, Opts, N}).

init({pool, Adapter, Opts, N}) ->
    Holder = #{id => holder,
               start => {my_pool_holder, start_link, [Adapter, Opts]}},
    Workers = #{id => workers, type => supervisor,
                start => {supervisor, start_link, [?MODULE, {workers, N}]}},
    {ok, {#{strategy => rest_for_one}, [Holder, Workers]}};
init({workers, N}) ->
    Children = [#{id => {worker, I},
                  start => {my_pool_holder, start_worker, []}}
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

- The image is loaded from the snapshot store, or captured and filed, once,
  in a temporary process. The pool holds one copy, charged once, and it is
  freed when the holder and the last worker have let go.
- Each worker still loads its own artifact. It checks that its options, less
  `prepared`, equal the ones you prepared with, that its adapter is the same,
  and that the image's store key and module hash are the ones it would have
  used. Any difference refuses the start with
  `{error, {bad_option, prepared, Why}}`.
- Killing the holder restarts every worker on a new image; killing one
  worker restarts that worker alone, on the image the others hold. A worker
  started from an image every holder has let go of refuses to start with
  `snapshot_invalidated`.
- Isolation is unchanged: every request still gets an instance restored from
  the image and used once.

`capture_timeout` bounds the capture only, as in a plain start: loading the
artifact and reading the store are not bounded. An adapter without snapshots
answers `{error, #{kind := unsupported}}`; start its workers without
`prepared`.

## Know what a crash leaves

| what dies | what is left | who cleans it |
| --- | --- | --- |
| the runner, at a deadline or a crash | nothing of the instance; the request's directory until its cleanup runs | the reaper, as for any request; the worker starts a new runner before its next request |
| the worker | its runner, which exits when it sees the worker go | nothing else to clean |
| the node, mid-request | the request's directory and its journal record | the reaper at the next start, **if** `scratch_roots` names the same directory |
| the host, mid-request | as above, possibly without the record, which is not synced | the next start removes every `req-` directory no record names |

With `scratch_roots` unset, each node uses a directory of its own that a later
start never looks at, so set it wherever a crash must be cleaned up at the next
start.

## What the process does not buy you

A process is a fault and lifecycle boundary, not a security boundary. The
sandbox is validation, bounds checking and the capability model, and those
apply identically to an inline call. `wasm_limits` lists what stays uncovered:
side channels, scheduler saturation across many workers, and host functions
you write yourself. See [Security](security.md).

Every setting is in [Worker configuration](worker-reference.md).

## Read this next

[Hosting scripting languages](scripting.md), then [Worker
configuration](worker-reference.md).
