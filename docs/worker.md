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
| **image** | a saved copy of a guest after its startup. A new instance can be restored from it instead of starting again. See [Snapshots](snapshots.md). |
| **restore** | make a new instance from an image. |
| **adapter** | the module that teaches the worker kernel one language, such as Python. |
| **runner** | the process that runs the guest for one request. |
| **holder** | a process that keeps an image alive. The image is freed when no process holds it. |
| **reaper** | the node-wide process that deletes the files a request left on disk. |

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
covered in [Streams](streams.md). It uses a process for the same reasons.

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

Put them under your own supervisor, as [Put it in an OTP
application](otp.md) shows. With `isolation => fresh`, a restart loses nothing,
so start the worker `permanent`. With `reuse`, the worker keeps state that only
the process that created it can rebuild, so start it `temporary`.

## Clean up

`terminate/2` calls `wasm:destroy/1`, which frees the instance's memory pages
at once. The worker traps exits, so this also runs when a supervisor shuts it
down. A killed worker does not run `terminate/2`, and that is safe too: the
runtime frees an instance's pages when its owner process exits, even when it
is killed.

## Restore a script worker's next instance ahead

This section is about `wasm_script_worker`, the kernel used by the JavaScript,
Python and Lua adapters. Use `restore_ahead` when the guest is restored from an
image and your workers are idle between requests. The worker restores the next
instance while it waits, so a new request starts directly with the guest's own
work.

<!-- check: modules my_adapter -->
```erlang
{ok, W} = wasm_script_worker:start_link(my_adapter, #{root => scratch,
                                                      restore_ahead => true}).
```

What it changes:

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
  functions. If one is missing, the worker logs a warning and restores for each
  request, as without the option.

It makes a request shorter only when the worker was idle long enough to finish
the restore. A pool that always gives the next request to the worker that just
answered (last in, first out) leaves it no time; rotate between idle workers
instead. Under full load it does not add throughput, because the restore still
has to run.

## Run a pool from one image

This section is also about `wasm_script_worker`. Use it when you start several
workers with the same adapter and options. If you start them one by one, each
worker loads or captures its own copy of the image. A pool of N workers then
holds N copies, counts N times against `max_snapshot_bytes`, and captures up to
N times when no image is stored yet. Instead, prepare the image once and start
every worker from it:

<!-- check: modules my_adapter -->
```erlang
{ok, P} = wasm_script_worker:prepare(my_adapter, Opts),
{ok, W} = wasm_script_worker:start_link(my_adapter, Opts#{prepared => P}),
ok = wasm_script_worker:release_prepared(P).
```

Put it under a supervisor, with a small holder process started first. If the
holder restarts, the pool prepares the image again. The holder prepares the
image in `init/1` and releases it in `terminate/2`:

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

The supervisor uses `rest_for_one`. The holder comes first, then a supervisor
for the workers. So a new image restarts every worker, and a crashed worker
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

- The image is loaded from the snapshot store, or captured and stored, only
  once, in a temporary process. The pool holds one copy and counts it once. The
  copy is freed when the holder and the last worker have released it.
- Each worker still loads its own artifact (what the adapter loads once at
  start, such as the guest module). It checks that its options, without `prepared`, are equal to the ones you
  prepared with. It checks that its adapter is the same, and that the image's
  store key and module hash are the ones it would have used. If anything
  differs, the start fails with `{error, {bad_option, prepared, Why}}`.
- If you kill the holder, every worker restarts on a new image. If you kill one
  worker, only that worker restarts, on the image the others hold. A worker
  started from an image that no holder keeps any more refuses to start with
  `snapshot_invalidated`.
- Isolation does not change: every request still gets its own instance,
  restored from the image and used once.

`capture_timeout` limits only the capture, as in a normal start. Loading the
artifact and reading the store have no time limit. An adapter without
snapshots returns `{error, #{kind := unsupported}}`; start its workers without
`prepared`.

## Know what a crash leaves

Each request gets its own directory, named `req-...`. The reaper keeps a
journal on disk, with one record for each running request, so it can find
these directories after a crash.

| what dies | what is left | who cleans it |
| --- | --- | --- |
| the runner, at a deadline or a crash | nothing of the instance; the request's directory, until its cleanup runs | the reaper, as for any request; the worker starts a new runner before its next request |
| the worker | its runner, which exits when it sees that the worker is gone | nothing else to clean |
| the node, during a request | the request's directory and its journal record | the reaper at the next start, **if** `scratch_roots` names the same directory |
| the host machine, during a request | as above, maybe without the record, because the record is not synced to disk | the next start deletes every `req-` directory that no record names |

When `scratch_roots` is not set, each node uses its own directory, and a later
start never looks in it. So set `scratch_roots` when files left by a crash must
be deleted at the next start.

## What the process does not protect

A process limits the damage of a crash and controls the instance's lifetime.
It is not a security boundary. The sandbox is made of validation, bounds checks
and the capability model, and they work the same way in an inline call.
`wasm_limits` lists what they do not cover: side channels, schedulers kept busy
by many workers, and host functions you write yourself. See
[Security](security.md).

Every setting is in [Worker configuration](worker-reference.md).

## Read this next

[Hosting scripting languages](scripting.md), then [Worker
configuration](worker-reference.md).
