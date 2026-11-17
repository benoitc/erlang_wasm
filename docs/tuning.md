# Tuning a worker host

This guide is for a worker host whose requests take much longer than the
guest's own work, or whose pool answers fewer requests than its size
predicts. It says what you can tune, when each setting helps, which way to
move it, and how to measure the result on your own host. Most of the time
the cause is garbage collection in the process the kernel starts for each
request, and one worker option fixes it.

**Do you need this?** Yes, when a request costs much more than the same work
measured alone. No, until something is measurably slow.

The numbers behind this page are in `test/audit/PERF.md`, section "The
tuning guide's measurements (from docs/tuning.md)", and in the sections of
that file it names.

## The words on this page

| word | what it means here |
| --- | --- |
| **worker** | a process that runs guest requests one at a time; here, `wasm_script_worker`. See [Using workers](worker.md). |
| **runner** | the process the worker starts to run one request. |
| **capture** | the step at worker start that runs the guest's initialisation and saves the result as an image ([Snapshots](snapshots.md)). |
| **word** | the Erlang VM's unit of process memory: 8 bytes on a 64-bit system. |
| **heap floor** | the size a process heap starts at (`min_heap_size`). The heap can still grow above it. |
| **knee** | in a sweep, the smallest value after which the time stops falling. |

## Find out where the time goes

Do this before you change any setting. The tools below are modules in this
repository's `bench/paths/`, not part of the installed application, so run
them from a checkout. Build the test profile once, then compile the tool:

```sh
rebar3 as test compile
erlc -o bench/paths -pa _build/test/lib/wasm/ebin bench/paths/allocwords.erl
erlc -o bench/paths -pa _build/test/lib/wasm/ebin \
     -pa _build/test/lib/wasm/examples bench/paths/workerbench.erl
```

To see one process's own allocation and collection time, and the floor a
process actually got:

<!-- check: modules allocwords -->
```erlang
allocwords:measure(fun() -> wasm_script_worker:run(W, Req) end).
erlang:process_info(Pid, garbage_collection).
```

Do not use `erlang:statistics(garbage_collection)`: it counts the whole node
and hides what one process does.

To compare settings, run them in one emulator, alternating, with the order
reversed every second round. `workerbench`'s `floors` mode does that. The
reactor guests are built fixtures; [Fixtures](contributing/fixtures.md) says
how to get them:

```sh
erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples \
    -pa bench/paths -run workerbench main floors qjs_reactor metered 10 0 100000 200000
```

Check the load average first, take minimums, and never compare a number
from one run with a number from another. Run the same setting against
itself first: if the two halves differ by more than a few per cent, the
machine is too busy to measure on. [Measuring](contributing/measuring.md) has
the whole protocol.

## How a heap floor works

A heap floor is the `min_heap_size` the kernel gives a process when it
starts it. There are two options, one for each process:

| option | process | started |
| --- | --- | --- |
| `runner_min_heap_words` | the request runner | once per request |
| `capture_min_heap_words` | the snapshot capture | once, at `start_link/2` |

Both processes keep almost nothing live on their own heap, so the collector
starts them at 233 words and then collects dozens or thousands of times while
the guest allocates. A floor makes the heap start at the size the work needs.

- **Put both options next to `root`, not inside `limits`.** A floor is not a
  maximum. A floor written inside the limits map is ignored, with no warning.
- **The emulator rounds the floor up** to a heap-size class: 200,000 words
  becomes 318,187, about 2.4 MiB more heap for each runner running at once.
- **The floor must fit under `max_heap_words`**, with room for that rounding
  and for the work. A floor that does not fit is dropped with a warning; the
  warning says `(the adapter's default)` when the value came from the
  adapter. A Lua or QuickJS default does not fit only under 400,000 words of
  `max_heap_words`; CPython's, under 2,000,000 interpreted and 3,000,000
  compiled. A floor that fits but leaves too little room kills the process
  with an error naming `max_heap_words` and the floor, so raise the two
  together.
- `wasm_script_worker:runner_heap_words/2` tells you what a pair of options
  and limits gives, without starting a worker. Merge the adapter's
  `defaults/1` under your options first.

## Give the request runner a heap floor

The shipped adapters already set one: 200,000 words for `wasm_lua` and
`wasm_javascript`, and for `wasm_python` 1,500,000 on the compiled tier and
1,000,000 on the interpreter. Pass the option to change it, or `0` to turn it
off:

<!-- check: modules my_adapter -->
```erlang
wasm_script_worker:start_link(my_adapter, #{root => scratch,
                                            runner_min_heap_words => 200_000}).
```

To find the value for your guest, sweep it:

1. Include `0` (no floor) in the sweep, or nothing shows the floor did
   anything.
2. Go past the knee. Above it, time rises again, because each collection has
   a larger heap to scan.
3. Take the knee and stop.

On the guests measured here, the knee took Lua from 30 ms to 13, QuickJS from
56 to 21, and CPython from 367 to 118.

## Give the capture a floor as well

<!-- check: modules my_adapter -->
```erlang
wasm_script_worker:start_link(my_adapter, #{root => scratch,
                                       capture_min_heap_words => 2_000_000}).
```

Use it for a guest that takes a long time to start: it took a CPython start
from about 92 s to 17 s. It applies only when a capture really happens, not
to a worker that loads its image from `snapshot_dir`. No shipped adapter sets
one, because it needs a larger `max_heap_words` too, as [Python](python.md)
shows.

## Leave the emulator's heap flags alone

| setting | default | what it is |
| --- | ---: | --- |
| `+hms Size` | 233 words | initial heap for **every** process |
| `+hmbs Size` | 46,422 words | binary virtual heap, which also triggers collections |
| `+hmax Size` | 0, meaning off | default maximum heap |
| `+hmaxib` | `false` | whether shared binaries count toward the maximum |

`+hms` sets the heap of every process in your release, not only the runner's;
`runner_min_heap_words` is the same idea for the one process that needs it.
`+hmbs` is part of the cause: the collector computes it from the live data
too, so a runner that keeps nothing goes over it all the time. Linear memory
is outside the process heap, so no heap limit sees it. Read one process's
values with `erlang:process_info(Pid, garbage_collection)`, and the node's
with `erlang:system_info(min_heap_size)`, which returns the tuple
`{min_heap_size, 233}`.

Do not set what the runtime already sizes: `wasm:compile/1` gives itself a
floor of two words per input byte, the process that owns an instance applies
`max_heap_words` at `spawn_opt` ([Worker internals](worker-internals.md)), and
`compile_max_heap_words` bounds a compiler ([the compiled
tier](compiled-tier.md)).

## When the start is slow, not the request

- `snapshot_dir` stores an initialized image on disk. It takes a CPython
  worker start from 104 s to about 1 s. See [Snapshots](snapshots.md).
- `code_cache_dir` keeps generated code across restarts. See [the compiled
  tier](compiled-tier.md).

Workers with the same adapter and options share one image, so
`max_snapshot_bytes` limits the number of different images on the node, not
the number of workers. "Run a pool from one image" in
[Using workers](worker.md) has the details.

A script worker restores its image for every request: the restored memory
reads the image's pages where they are and copies only the 4 KiB pages a
request writes, so a node holds one copy of each image however many requests
run. There is nothing to set.

## Size a node for many workers

A runner's floor exists only while it runs a request, so the extra memory is
at most the floor times the number of busy workers. Use Little's law: busy
workers = requests per second x time per request. The floor gives the same
speed-up at every worker count, and on the guests measured here a node used
less memory with it, because less garbage piles up between collections.

If the node's RSS is higher than `erlang:memory(total)` explains: a floored
heap gets a memory segment of its own, and the emulator caches freed
segments. `+MMmcs 0` gives them back to the operating system. It works against
`+MMmcs 30` below, which makes restores faster under load, so choose it when
RSS is your limit, and measure your own pool.

## Serve many callers from a pool

Measure a pool with `reqbench`, another tool in `bench/paths/`. It drives a
pool from many callers and samples the queues of the node-wide processes a
request can wait on. A queue whose maximum stays at 0 or 1 is not a
bottleneck; one that grows is:

```sh
erlc -o bench/paths -pa _build/test/lib/wasm/ebin bench/paths/reqbench.erl
REQBENCH_WARM=240 erl -noshell -pa _build/test/lib/wasm/ebin -pa bench/paths \
    -run reqbench main py 14 64 10 ""
```

To restore the next instance while the worker waits, so a request does not
wait for its restore:

<!-- check: modules my_adapter -->
```erlang
wasm_script_worker:start_link(my_adapter, #{root => scratch,
                                            restore_ahead => true}).
```

It needs idle time between a worker's requests, so give each request to the
idle worker that has waited longest (first in, first out). At full load it
adds no throughput, and each idle worker holds one restored instance. A
restore now takes about 0.8 ms on CPython, so it saves less than it once did.

When many workers allocate memory at the same time, a larger segment cache
halves the cost of new memory:

```sh
erl +MMmcs 30 +MMamcbf 1000000 ...
```

Expect a few per cent end to end at most. It also keeps freed runner heaps,
so with heap floors it raises RSS: read the section above first.

## Stop compiling the same Python on every request

If a CPython worker always runs the same code and only the context changes,
give that code to the worker as `entry` instead of sending it as `source`. It
then runs once, at the capture, and each request calls a function already in
the image: the guest's call went from about 40 ms to 2 ms.
[Python](python.md) shows how.

## What this project has not measured

There is no measurement in this project for allocator flags other than the
segment cache above, scheduler binding (`+sbt`), scheduler counts, or dirty
schedulers, so this page gives no advice about them. If you measure any of
them, add the numbers to `test/audit/PERF.md`.

## Read this next

[Snapshots](snapshots.md), then [The compiled tier](compiled-tier.md).
