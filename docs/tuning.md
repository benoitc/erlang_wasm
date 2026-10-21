# Tuning a worker host

This guide is for one problem: a request takes much longer than the guest's
own work, and you cannot see where the time goes. For example, a request
takes tens of milliseconds, but the same call measured alone takes a few.
Most of the time the cause is garbage collection in the process that the
kernel starts for each request, and one worker option fixes it. In the other
cases the slow part is the worker start, not the request, and a different
guide covers it.

**Do you need this?** Yes, when a request costs much more than the same work
measured alone. No, until something is measurably slow.

Every number here was measured on this project. `test/audit/PERF.md` records
each one, and `bench/paths/README.md` describes how they were measured.

## The words on this page

| word | what it means here |
| --- | --- |
| **worker** | a process that runs guest requests one at a time; here, `wasm_script_worker`. See [Using workers](worker.md). |
| **runner** | the process the worker starts to run one request. |
| **capture** | the step at worker start that runs the guest's initialisation and saves the result as an image. |
| **image** | a saved copy of a guest after its initialisation. See [Snapshots](snapshots.md). |
| **restore** | building a new instance from an image, instead of starting the guest from zero. |
| **word** | the Erlang VM's unit of process memory: 8 bytes on a 64-bit system. |
| **heap floor** | the size a process heap starts at (`min_heap_size`). The heap can still grow above it. |
| **knee** | in a sweep, the smallest value after which the time stops falling. |
| **arm** | one of the settings that a benchmark run compares. |
| **page budget** | the node-wide limit on guest memory pages. See [Memory](memory.md). |

## Find out where the time goes

Do this before you change any setting. Check the load average first. Take
minimums, not means. Never compare a number from one run with a number from
another run.

<!-- check: modules allocwords -->
```erlang
%% one process's own allocation and collection time
allocwords:measure(fun() -> wasm_script_worker:run(W, Req) end).
```

```erlang
%% the floors and ceilings a process actually got
erlang:process_info(Pid, garbage_collection).
```

**Do not use `erlang:statistics(garbage_collection)` for this.** It counts the
whole node. `bench/paths/allocwords.erl` exists because that counter showed no
change while the collections of one process fell 51x. That mistake cost an
afternoon of investigation in the wrong direction.

To compare settings, run them in one emulator, alternating between them, and
reverse the order on every second round:

```sh
erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples \
    -pa bench/paths -run workerbench main floors qjs_reactor metered 10 0 100000 200000
```

On a machine that runs other work, this is the only useful comparison. First
run the same setting against itself (a null experiment). If the two halves
differ by more than a few per cent, the machine is too busy to measure on.

## How a heap floor works

Read this once before you set either floor. A heap floor is the
`min_heap_size` that the kernel gives a process when it starts it. There are
two options, one for each process:

| option | process | started |
| --- | --- | --- |
| `runner_min_heap_words` | the request runner | once per request |
| `capture_min_heap_words` | the snapshot capture | once, at `start_link/2` |

Both processes keep almost nothing on their own heap. So the garbage collector
starts them at 233 words, and then collects dozens or thousands of times while
they work. A floor makes the heap start at the size the work needs.

- **A floor is not a maximum.** It sets where a heap starts, not how far it
  can grow. The maximum is `max_heap_words` in `limits`. So both options go
  next to `root` in the worker's options, **not** inside `limits`. A floor
  written inside the limits map is ignored, with no warning.
- **There are two options because there are two processes.** A worker that
  reads its image from `snapshot_dir` never captures. It uses the runner's
  floor and never the capture's.
- The emulator rounds the number **up** to a heap-size class, and the step is
  large: 200,000 words becomes 318,187, and 1,000 becomes 1,598. That is
  2.4 MiB of extra heap for each runner that runs at the same time. Overall it
  does not cost you memory: see the scaling section below.
- The floor must fit under this worker's `max_heap_words`, with room for that
  rounding. If it does not fit, the worker logs a warning and the process gets
  no floor, because a `min_heap_size` above `max_heap_size` kills the process
  when it starts.
- **That check does not catch everything.** It catches a floor too large to
  start with. It cannot catch a floor that starts fine but leaves too little
  room under the maximum for the work. `max_heap_words` limits the peak, and a
  floor raises the starting point of that peak, so raise the two together.
  CPython captures at the 16 M words its adapter asks for. With a 2 M capture
  floor, the capture dies about three times in four. When that happens, the
  error names `max_heap_words` and the floor, not only `killed`.

`wasm_script_worker:runner_heap_words/2` tells you what a given pair of
options and limits gives, so you can check a configuration without starting a
worker. It reads only the options you pass it. To see what a worker would get,
first merge the adapter's `defaults/1` (called with the worker's limits) under
your options.

A default that does not fit is refused in the same way, and the warning says
`(the adapter's default)`, so you can tell it from a value you set. A Lua or
QuickJS default does not fit only when `max_heap_words` is under 400,000
words. For CPython the limit is 2,000,000 interpreted and 3,000,000 compiled.

## Give the request runner a heap floor

The shipped adapters already set the floor they were measured at, in their
`defaults/1`: 200,000 words for `wasm_lua` and `wasm_javascript` on both tiers;
for `wasm_python`, 1,500,000 on the compiled tier and 1,000,000 on the
interpreter. You need this section only to change or turn off a default, or to
find the number for your own adapter.

To override a default, pass the option. To turn it off, pass `0`:

<!-- check: modules my_adapter -->
```erlang
wasm_script_worker:start_link(my_adapter, #{root => scratch,
                                       runner_min_heap_words => 0}).
```

To set one for an adapter that has none:

<!-- check: modules my_adapter -->
```erlang
wasm_script_worker:start_link(my_adapter, #{root => scratch,
                                       runner_min_heap_words => 200_000}).
```

A request runner keeps almost nothing on its own heap. The module is a cache
handle, the memories are `atomics` pages, and a restored image's contents are
reference-counted binaries. The collector sizes a heap from the data that is
still live. So it gives the runner the emulator's default of 233 words, and
then collects dozens of times during the request, while the guest allocates
hundreds of millions of words.

QuickJS, ten requests per floor, all settings in one emulator:

| floor, words | request, min | collections | time in collections |
| ---: | ---: | ---: | ---: |
| none | 56.0 ms | 98 | 35.0 ms |
| 50,000 | 48.1 ms | 71 | 29.6 ms |
| 100,000 | 45.8 ms | 67 | 25.9 ms |
| 130,000 | 22.4 ms | 49 | 3.0 ms |
| 200,000 | 21.1 ms | 34 | 2.9 ms |
| 400,000 | 21.3 ms | 25 | 3.0 ms |

The time drops suddenly at the knee, then stays flat. **A floor larger than
the knee starts to cost time again**, so a sweep must go past the knee and not
stop at the first improvement. CPython at 1,000,000, 2,000,000 and 4,000,000
words takes 124, 124 and 145 ms. The number of collections still falls (43,
then 29, then 19), but the time spent in them rises from 8.3 to 12.6 ms. When
a heap is much larger than its live data, each collection has more to scan.

**Find your own value.** The right value depends on the guest, not on this
runtime. The three guests measured here need values up to 5x apart:

| guest | no floor | its knee | time at the knee |
| --- | ---: | ---: | ---: |
| Lua | 30.0 ms | 200,000 words | 12.7 ms |
| QuickJS | 56.0 ms | 200,000 | 21.1 ms |
| CPython | 367.1 ms | 1,000,000 | 117.8 ms |

Sweep, take the knee, and stop. Two rules, learned from mistakes:

- **Include "no floor" in the sweep.** Without it, nothing in the run shows
  that the floors had any effect. One CPython sweep here came back flat for
  this reason and had to be thrown away.
- **Go past the knee.** Otherwise you cannot tell where the time stops
  falling, and you may pick a value that is already too large.

## Give the capture a floor as well

<!-- check: modules my_adapter -->
```erlang
wasm_script_worker:start_link(my_adapter, #{root => scratch,
                                       capture_min_heap_words => 2_000_000}).
```

This is the same setting for the process that runs a snapshot capture. For a
guest that takes a long time to start, it helps more than anything else in
this guide. A CPython worker start, settings alternated, with `snapshot_dir`
unset so that every run really captures:

| capture floor | worker start |
| ---: | ---: |
| none | 91.3 to 94.8 s |
| 2,000,000 words | **17.4 s** |

The cause is the same as for the request floor: this process also keeps
little live data. The gain is larger because the work is longer. It applies
only when a capture happens. A worker that reads its image from `snapshot_dir`
does not capture, and neither does an adapter that declares no snapshot
capability.

No shipped adapter sets a capture floor by default. On 0.7.0, CPython with
2,000,000 words under the 16 M words of `wasm_python:limits/0` killed the
capture in three starts out of four. So set it only together with a larger
`max_heap_words`, as [Python](python.md) does.

## Do not try `+hms` first

These are the emulator's own heap settings, with their default values here:

| setting | default | what it is |
| --- | ---: | --- |
| `+hms Size` | 233 words | initial heap for **every** process |
| `+hmbs Size` | 46,422 words | binary virtual heap, which also triggers collections |
| `+hmax Size` | 0, meaning off | default maximum heap |
| `+hmaxk` / `+hmaxel` | `true` / `true` | kill on breach, and log it |
| `+hmaxib` | `false` | whether shared binaries count toward the maximum |
| `fullsweep_after` | 65,535 | generations before a fullsweep, also `ERL_FULLSWEEP_AFTER` |

Three of these are easy to choose by mistake:

- **`+hms` applies to the whole node, not only to the runner.** It sets the
  heap of the guardian, of the reaper's child processes (both described in
  [Worker internals](worker-internals.md)), of every process this runtime
  starts, and of everything else in your release.
  `runner_min_heap_words` is the same idea, limited to the one process that
  needs it.
- **`+hmbs` is part of the cause.** The collector also computes this limit
  from the live data. So a runner that keeps nothing stays at the default
  46,422 and goes over it all the time.
- **`+hmaxib` is `false`.** This is the emulator side of what `wasm_limits`
  explains: linear memory is outside the process heap, and no heap limit can
  see it.

Read the values of one process with `erlang:process_info(Pid,
garbage_collection)`. Read the node's value with
`erlang:system_info(min_heap_size)`, which returns the tuple
`{min_heap_size, 233}`, not an integer.

## What the runtime already sizes for you

Do not set these again, and do not work against them:

- `wasm:compile/1` sets its own heap floor at two words per input byte. That
  takes QuickJS from 244 ms to 55.
- `max_heap_words` in a limits map is applied at `spawn_opt` by the process
  that owns the instance. See [Worker internals](worker-internals.md).
- `compile_max_heap_words` limits a compiler process. See [the compiled tier
  guide](compiled-tier.md).

## When the start is slow, not the request

Nothing above helps a guest that takes ninety seconds to start and a third of
a second to answer. Two other settings do:

- `snapshot_dir` stores an initialized image on disk. It takes a CPython
  worker start from 104 s to 998 ms. See [the snapshots guide](snapshots.md).
- `code_cache_dir` keeps generated code across restarts. See [the compiled
  tier guide](compiled-tier.md).

If you start a pool one worker at a time and no image is stored yet, each
worker may capture its own image. After that, each worker holds its own copy,
and each copy is charged to `max_snapshot_bytes`. Instead, prepare the image
once with `wasm_script_worker:prepare/2` and start the pool from it: one
capture, one image, one charge. Then `max_snapshot_bytes` limits the number of
different images on the node, not the number of workers. "Run a pool from one
image" in [Using workers](worker.md) shows how. Four CPython workers with no
stored image started in 16 s this way, against 40 s when started together
(`test/audit/PERF.md`, "One image for a pool").

## How it scales, and what it costs

Each runner that runs at the same time has its own floor. So the real question
is whether the floor still helps with many runners. It does, by the same
factor at every count. QuickJS, 25 requests per worker, on 14 cores about 70%
idle:

| workers | no floor | at 200,000 |
| ---: | ---: | ---: |
| 1 | 17.8 req/s | 44.4 |
| 2 | 34.3 | 89.8 |
| 4 | 65.1 | 159.7 |
| 8 | 107.6 | 255.2 |
| 14 | 126.1 | **300.4** |

CPython, 20 requests per worker, at a floor of 1,000,000 and about 60% idle:

| workers | no floor | at 1,000,000 |
| ---: | ---: | ---: |
| 1 | 2.4 req/s | 7.2 |
| 2 | 4.2 | 13.1 |
| 4 | 6.4 | 18.7 |
| 8 | 9.1 | 27.5 |
| 14 | 10.5 | **30.8** |

Peak process memory was measured at fourteen workers only: 204 MB without a
floor against 129 MB with one on QuickJS, and 556 MB against 398 MB on
CPython.

Two conclusions from both tables:

- **The floor gives the same speed-up at every worker count**: 2.4x on
  QuickJS and about 3x on CPython. It does not disappear under concurrency.
- **Throughput grows less than the worker count, with or without the floor**:
  7.1x without against 6.8x with on QuickJS, 4.4x against 4.3x on CPython. The
  floor raises the curve; it does not change its shape.

Do not read the top of these curves as a limit of the runtime. During these
runs only about 10 and 8 of the 14 cores were really free, and that is most of
why the curves flatten where they do. The comparison between floor and no
floor is still valid, because both settings ran on the same machine in the
same minute. An absolute scaling limit would not be.

**It uses less memory, not more.** You might expect the opposite, since every
runner reserves extra heap. Fourteen workers peak at 129 MB with the floor
against 204 MB without. This first comparison is even unfair to the floor, for
two reasons. The run with the floor finishes in 1164 ms against 2775, so it is
sampled fewer times. And it includes 34 MB of reserved heap that the other run
does not have. In a second run, with request counts chosen so both settings
take the same time (1156 ms against 1130), it is 122 MB against 195 to 210.
Without a floor, the garbage that piles up between collections is larger than
the heap a floor reserves.

To measure your own, use the `throughput` mode, and first read the warning in
`bench/paths/README.md`. Alternating runs protects a latency sweep from a busy
machine, but it cannot protect a scaling curve. A scaling curve needs a quiet
machine, and nothing can replace one.

## How much memory the floors hold

Read this before you size a node for many workers. A runner's floor exists
only while that runner runs a request, and a worker runs at most one request
at a time. Requests waiting in a queue hold nothing, and the runner's heap is
freed when the request ends. So the extra memory is at most the floor times
the number of **busy workers**. It does not grow with requests per second or
with the number of callers waiting.

Measured with ten workers, compiled tier except where noted, at 64 and 256
callers, floors on against off, two rounds:

| guest | throughput | extra `erlang:memory(total)`, mean |
| --- | ---: | ---: |
| Lua | +13 to 18% | 17 to 18 MB |
| QuickJS | +8 to 13% | 13 MB |
| CPython, 1,000,000 | +17 to 24% | 51 to 55 MB |
| CPython, 1,500,000 | +29 to 34% | 53 to 56 MB |
| Lua, interpreted | 2.1 to 2.2x | 14 to 16 MB |

The extra memory did not grow from 64 callers to 256. With the floors, the
share of CPU spent in garbage collection fell from about 9% to 1% on Lua, p99
latency fell, and allocator segment calls fell 2 to 4x.

To size a node, use Little's law: busy workers = requests per second x time
per request. The table below is calculated from the one above, not measured,
for 10,000 requests per second:

| guest | busy workers, off | on | held by the floors |
| --- | ---: | ---: | ---: |
| Lua | 96 | 83 | about 145 MB |
| QuickJS | 133 | 120 | about 155 MB |
| CPython, 1,500,000 | 346 | 265 | 1.4 to 1.5 GB |
| Lua, interpreted | 393 | 182 | about 280 MB |

The floors hold that memory. In exchange, the same rate needs 10 to 54% fewer
busy workers.

### Why the operating system sees more than `erlang:memory`

Read this when, after you give runners a floor, the node's RSS (the memory the
operating system counts for it) is higher than `erlang:memory(total)`
explains. A floor of 200,000 words rounds up to a heap of 318,187 words, about
2.5 MB. That is above the single-block threshold of the process heap allocator
(`sbct`, 512 KB), so every runner heap with a floor gets a memory segment (a
carrier) of its own. When the runner exits, that carrier goes to the
emulator's segment cache, not back to the operating system. The cache keeps
up to 10 segments per allocator instance. Those pages count in RSS but not in
`erlang:memory`.

Ten workers, 64 callers, mean over two rounds:

| guest | floors off | floors on | floors on, `+MMmcs 0` |
| --- | ---: | ---: | ---: |
| Lua, RSS | 150 MB | 261 MB | 151 MB |
| QuickJS, RSS | 317 MB | 496 MB | 317 MB |

`+MMmcs 2` keeps a small cache. It removes most of Lua's difference (194 MB)
and part of QuickJS's (332 MB). Raising `+MHsbct` does not help: the heaps
then go into multiblock carriers, which are cached in the same way.

This flag works against the section "Keep freed memory segments" below. A
larger segment cache makes restores faster when many workers allocate at the
same time. A smaller one gives memory back sooner. The effect of `+MMmcs 0`
on throughput with floors is not measured yet: on this machine it changed by
less than the 30 to 60% that the rounds varied by. Choose it when RSS is your
limit, and measure your own pool.

For CPython, RSS is not a reliable measure here. On a machine short of memory,
the operating system compresses idle pages and removes them from RSS. Read
`footprint` (macOS) or the process's proportional set size instead. By
footprint, floors on with `+MMmcs 0` came to about 1,310 MB, against about
1,450 MB for floors off with the same flag. A heap that starts at its working
size does not leave old, outgrown heaps behind.

## Serve many callers from a pool

Use this when a pool of workers answers fewer requests per second than its
worker count and the time of one request predict. Measure with
`bench/paths/reqbench.erl`. It sends requests to a pool from many callers and
samples the queues of the node-wide processes that a request can wait on:

```sh
REQBENCH_WARM=240 erl -noshell -pa _build/test/lib/wasm/ebin -pa bench/paths \
    -run reqbench main py 14 64 10 ""
```

CPython reactor, 14 workers, 64 callers, compiled tier already warm, on a
14-core machine at a load average of 10 to 30:

| | requests a second | `file_server_2` queue, max / mean | reaper queue, max / mean |
| --- | ---: | ---: | ---: |
| 0.4.3 | 173 | 12 / 4.4 | 22 / 2.6 |
| 0.5.0 | 202 to 218 | 0 / 0 | 3 to 7 / under 0.1 |

The keeper and code-slot queues stay at 2 or below in both versions. In
alternating runs on the same machine, while other work loaded it, 0.4.3 gave
99 to 179 requests a second and 0.5.0 gave 167 to 211. The busier the disk,
the larger the difference, because a request no longer waits for the file
system calls of another request. `test/audit/PERF.md` has every run.

With those queues at 0 to 2, the remaining cost was CPU. At that time, a
restore wrote the image into memory one word at a time and allocated about
42 MB of pages, and then the guest ran. Today a restore shares the image and
copies only the pages a request writes (see "Every request shares the image"
below). On this machine, 10 of the 14 cores are performance cores, so 14
workers do not reach 14 times the rate of one request.

### Restore the next instance ahead

<!-- check: modules my_adapter -->
```erlang
wasm_script_worker:start_link(my_adapter, #{root => scratch,
                                            restore_ahead => true}).
```

The worker restores the next instance while it waits for a request. A request
that finds one ready does not wait for a restore. CPython, one request at a
time, a pause between requests, median of 60 in one emulator:

| phase | per request | `restore_ahead` |
| --- | ---: | ---: |
| deliver and restore | 14.8 ms | 0.04 ms |
| the guest's own call | 28.3 ms | 28.3 ms |
| whole request, first to last callback | 46.4 ms | 30.0 ms |

These figures were measured before images were shared. A CPython restore now
takes about 0.8 ms, so `restore_ahead` saves less than it did. A request still
pays for copying the pages it writes for the first time, during the call.

It needs idle time between a worker's requests. A pool that gives the next
request to the worker that just answered leaves it no idle time, so rotate
idle workers (first in, first out). At full load it adds no throughput: the
restore still runs, only earlier. Each idle worker holds one restored
instance.

### Keep freed memory segments

New memory for a growing guest, and the arena (the instance's own memory)
that a restored memory copies its written pages into, are allocated new each
time. With many workers allocating at the same time, the operating system's
page mapping becomes a cost of its own. If the emulator keeps more freed
segments in its cache, that cost is halved:

```sh
erl +MMmcs 30 +MMamcbf 1000000 ...
```

| 43 chunks of 1 MiB, allocated and touched | alone | 14 at once |
| --- | ---: | ---: |
| default | 4.0 ms | 11.1 ms |
| `+MMmcs 30 +MMamcbf 1000000` | 2.4 ms | 5.2 ms |

On the pool above, the gain end to end was about 3%. That was measured when a
CPython restore still allocated all 43 chunks. A restore now allocates only
what the request writes, so expect less. The same cache also keeps freed
runner heaps, so with heap floors it raises RSS too: read "Why the operating
system sees more than `erlang:memory`" above before you raise it.

## Stop compiling the same Python on every request

Use this when a CPython worker always runs the same code and only the context
changes. If you send that code as a `source`, it is compiled and imported
again on every request. If you give it to the worker as `entry`, it runs once,
at the capture, and each request calls a function that is already in the
image. [Python](python.md) shows how.

The same agent request, a dispatch to a trivial `init`, compiled tier on, the
three workers alternating in one emulator, 40 requests each:

| path | the guest's call, median | minimum | whole request, median |
| --- | ---: | ---: | ---: |
| `handle()`, the 0.5.0 reactor | 59.1 ms | 46.8 ms | 88.4 ms |
| `handle()`, this reactor | 40.4 ms | 30.9 ms | 70.0 ms |
| `call()`, an `entry` | 2.1 ms | 1.8 ms | 19.9 ms |

The rest of a request, about 18 ms, is the restore and the kernel code around
it. `restore_ahead`, above, moves that out of the request. These runs were
taken while another job loaded the machine (load average 250 to 275), so
compare the differences, not the absolute times. `test/audit/PERF.md` has the
runs.

## Every request shares the image

A script worker restores its image for every request and keeps nothing
between requests. The restored memory reads the image's pages where they are,
and a request copies only the 4 KiB pages it writes. So a node holds one copy
of each image, however many requests run. There is nothing to set.

The node page budget counts what is allocated: a restored memory's page table
(the list of where each of its pages is) and the pages it wrote, and for any
memory, its growth in whole chunks. A memory created with three pages uses one
256 KiB chunk and counts as four pages.

## What this project has not measured

There is no measurement in this project for: allocator flags other than the
segment cache above, scheduler binding (`+sbt`), scheduler counts, and dirty
schedulers. A claim here must cite `test/audit/PERF.md`, so this page gives no
general advice about them. If you measure any of them, add the numbers to
that file.

## Read this next

[Snapshots](snapshots.md), then [The compiled tier](compiled-tier.md).
