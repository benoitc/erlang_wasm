# Tuning a worker host

This guide is for one symptom: your requests are slower than your guest is, and
the time is going somewhere you cannot name. Reach for it when a request costs
tens of milliseconds and the same call, measured on its own, costs single
digits. Most of the time the answer is garbage collection in the process the
kernel spawns per request, and the fix is one worker option. The rest of the
time it is the start rather than the request, which is a different guide.

**Do you need this?** Yes, when a request costs much more than the same work
measured on its own. No, until something is measurably slow.

Every number here was measured on this project; `test/audit/PERF.md` is where
each one lives, and `bench/paths/README.md` is the protocol they were taken
under.

## Find out where the time goes

Do this before changing any setting. Check the load average first, take
minimums rather than means, and never compare a number from one run against a
number from another.

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
whole node. `bench/paths/allocwords.erl` exists because that counter reported
no change while one process's collections fell 51x, which sent an
investigation down the wrong path for an afternoon.

To compare settings, run them in one emulator, interleaved, with the order
reversed on alternate rounds:

```sh
erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples \
    -pa bench/paths -run workerbench main floors qjs_reactor metered 10 0 100000 200000
```

That is the only comparison worth making on a machine that has other work on
it. Run the same arm against itself first: if the two halves of a null
experiment differ by more than a few per cent, the box is too busy to measure
on at all.

## Give the request runner a heap floor

<!-- check: modules my_adapter -->
```erlang
wasm_script_worker:start_link(my_adapter, #{root => scratch,
                                       runner_min_heap_words => 200_000}).
```

A request runner holds almost nothing on its own heap. The module is a cache
handle, the memories are `atomics` pages, a restored image's contents are
reference-counted binaries. The collector sizes a heap from the live set, so it
gives the runner the emulator's default 233 words and then collects through the
request dozens of times while the guest allocates hundreds of millions.

Sweeping QuickJS, ten requests per floor, all arms in one emulator:

| floor, words | request, min | collections | in |
| ---: | ---: | ---: | ---: |
| none | 56.0 ms | 98 | 35.0 ms |
| 50,000 | 48.1 ms | 71 | 29.6 ms |
| 100,000 | 45.8 ms | 67 | 25.9 ms |
| 130,000 | 22.4 ms | 49 | 3.0 ms |
| 200,000 | 21.1 ms | 34 | 2.9 ms |
| 400,000 | 21.3 ms | 25 | 3.0 ms |

The knee is sharp and it plateaus. **Past it a floor starts costing again**,
which is why a sweep has to go beyond the knee rather than stop at the first
improvement. CPython at 1,000,000, 2,000,000 and 4,000,000 words is 124, 124
and 145 ms, with the collections still falling, 43 to 29 to 19, and the time
spent in them rising, 8.3 to 12.6 ms. A heap too large for its live set means
each collection walks more.

**Find your own.** The right value is a property of the guest, not of this
runtime. The three measured here want a 5x spread:

| guest | no floor | its knee | there |
| --- | ---: | ---: | ---: |
| Lua | 30.0 ms | 200,000 words | 12.7 ms |
| QuickJS | 56.0 ms | 200,000 | 21.1 ms |
| CPython | 367.1 ms | 1,000,000 | 117.8 ms |

Sweep, take the knee, and stop. Two rules that came from getting it wrong:

- **Put the off setting in the sweep.** Without it there is nothing in the run
  to say the floors worked at all, which is how one CPython sweep here came
  back flat and had to be thrown away.
- **Go past the knee.** Otherwise you cannot tell a plateau from a peak, and
  the number you pick may be on the far side of it.

Two things to know before you set it:

- The emulator rounds the number **up** to a heap-size class, and the jump is
  large: 200,000 words becomes 318,187, and 1,000 becomes 1,598. That is
  2.4 MiB of ballast per concurrent runner, and it does not cost you memory on
  balance: see the scaling section below.
- The floor must fit under this worker's `max_heap_words` with room for that
  rounding. One that does not is refused with a warning and the process gets no
  floor, because `min_heap_size` above `max_heap_size` is a kill at spawn.
- **That check is not the whole of it.** It catches a floor too large to start
  under; it cannot catch a floor that starts fine and then leaves too little
  headroom under the ceiling for the work itself. `max_heap_words` bounds the
  peak and a floor raises the baseline the peak is measured from, so raise the
  two together. CPython captures at the 16 M words its adapter asks for, and
  with a 2 M capture floor it dies about three times in four. When that
  happens the error names `max_heap_words` and the floor rather than only
  saying `killed`.

`wasm_script_worker:runner_heap_words/2` answers what a given pair of options and
limits resolves to, so you can check a configuration without starting a worker.

## Give the capture a floor as well

<!-- check: modules my_adapter -->
```erlang
wasm_script_worker:start_link(my_adapter, #{root => scratch,
                                       capture_min_heap_words => 2_000_000}).
```

The same mechanism on the process that runs a snapshot capture, and on a guest
that takes a long time to start it is worth more than anything else in this
guide. A CPython worker start, interleaved, `snapshot_dir` unset so every arm
really captures:

| capture floor | worker start |
| ---: | ---: |
| none | 91.3 to 94.8 s |
| 2,000,000 words | **17.4 s** |

That is the same effect as the request floor, on a process whose live set is
small for the same reason, and it is larger because the work is longer. It only
applies where a capture happens: a worker reading its image from `snapshot_dir`
pays none of this, and neither does an adapter that declares no snapshot
capability.

## Do not reach for `+hms` first

The emulator's own heap settings, with the defaults they have here:

| setting | default | what it is |
| --- | ---: | --- |
| `+hms Size` | 233 words | initial heap for **every** process |
| `+hmbs Size` | 46,422 words | binary virtual heap, which also triggers collections |
| `+hmax Size` | 0, meaning off | default maximum heap |
| `+hmaxk` / `+hmaxel` | `true` / `true` | kill on breach, and log it |
| `+hmaxib` | `false` | whether shared binaries count toward the maximum |
| `fullsweep_after` | 65,535 | generations before a fullsweep, also `ERL_FULLSWEEP_AFTER` |

Three notes, each one a wrong knob that is easy to reach for:

- **`+hms` is the node, not the runner.** It sizes the guardian, the reaper's
  children, every process this runtime spawns and everything else in your
  release. `runner_min_heap_words` is the same idea scoped to the one process
  that needs it.
- **`+hmbs` is part of why the symptom exists.** The collector derives that
  threshold from the live set too, so a runner holding nothing keeps the
  default 46,422 and crosses it constantly.
- **`+hmaxib` is `false`**, which is the emulator's half of what
  `wasm_limits` says in prose: linear memory is off-heap and no heap bound can
  see it.

Read a process's values back with `erlang:process_info(Pid,
garbage_collection)`. Read the node's with `erlang:system_info(min_heap_size)`,
which answers the tuple `{min_heap_size, 233}` rather than an integer.

## What the runtime already sizes for you

Do not set these again or fight them:

- `wasm:compile/1` floors its own heap at two words per input byte. That is
  what takes QuickJS from 244 ms to 55.
- `max_heap_words` in a limits map, applied at `spawn_opt` by whoever owns the
  instance. See [Worker internals](worker-internals.md).
- `compile_max_heap_words` bounds a compiler process. See [the compiled tier
  guide](compiled-tier.md).

## When the cost is the start, not the request

None of the above helps a guest that takes ninety seconds to come up and a
third of a second to answer. Two different settings do:

- `snapshot_dir` files an initialized image, which takes a CPython worker start
  from 104 s to 998 ms. See [the snapshots guide](snapshots.md).
- `code_cache_dir` keeps generated code across restarts. See [the compiled
  tier guide](compiled-tier.md).

## How it scales, and what it costs

A floor is paid per concurrent runner, so the question a host actually has is
whether it still pays with many of them. It does, and by the same factor
throughout. QuickJS, 25 requests per worker, on 14 cores about 70% idle:

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

Peak process memory was measured at fourteen workers only: 204 MB unfloored
against 129 floored on QuickJS, 556 against 398 on CPython.

Two things to take from both tables. **The floor is worth a constant factor at
every worker count**, 2.4x on QuickJS and about 3x on CPython, so it does not
wash out under concurrency. And **the scaling is sublinear in both arms
alike**: 7.1x without the floor against 6.8x with it on QuickJS, 4.4x against
4.3x on CPython. What a floor moves is the height of the curve, not its shape.

Do not read the ceilings as the runtime's. These runs had roughly 10 and 8 of
14 cores actually free, which is most of why the curves flatten where they do.
The floor comparison survives that because both arms met the same machine in
the same minute; an absolute scaling limit would not.

**It costs less memory, not more**, which is the opposite of what a
per-runner ballast suggests. Fourteen workers peak at 129 MB with the floor
against 204 without. That comparison is unfair to the floor twice over -- the
floored arm finishes in 1164 ms against 2775, so it is sampled less often, and
the ballast it adds is 34 MB that the unfloored arm never pays. Rerun with the
request counts chosen to make the two arms the same length, 1156 ms against
1130, it is 122 MB against 195 to 210. The garbage a floor stops accumulating
is simply larger than the heap it reserves.

Run your own with the `throughput` mode, and read the caveat in
`bench/paths/README.md` first: a scaling curve cannot be made self-controlling
by interleaving the way a latency sweep can, so it needs a quiet machine and
there is no trick that substitutes for one.

## Serve many callers from a pool

Use this when a pool of workers answers fewer requests a second than its
worker count and a single request's time predict. Measure with
`bench/paths/reqbench.erl`, which drives a pool with many callers and samples
the queues of the node-wide processes a request can wait on:

```sh
REQBENCH_WARM=240 erl -noshell -pa _build/test/lib/wasm/ebin -pa bench/paths \
    -run reqbench main py 14 64 10 ""
```

CPython reactor, 14 workers, 64 callers, the compiled tier warm, on a 14-core
machine at a load average of 10 to 30:

| | requests a second | `file_server_2` queue, max / mean | reaper queue, max / mean |
| --- | ---: | ---: | ---: |
| 0.4.3 | 173 | 12 / 4.4 | 22 / 2.6 |
| 0.5.0 | 202 to 218 | 0 / 0 | 3 to 7 / under 0.1 |

The keeper and code-slot queues stay at 2 or below in both. Interleaved on the
same machine while other work loaded it, 0.4.3 gave 99 to 179 requests a second
and 0.5.0 gave 167 to 211, and the busier the disk the wider the gap: a request
no longer waits for another request's file system calls. `test/audit/PERF.md`
has every run.

With those queues at 0 to 2, what is left is CPU: a restore writes the image
into memory one word at a time and allocates about 42 MB of pages, and the
guest runs. On this machine 10 of the 14 cores are performance cores, so 14
workers do not get 14 times one request's rate.

### Restore the next instance ahead

<!-- check: modules my_adapter -->
```erlang
wasm_script_worker:start_link(my_adapter, #{root => scratch,
                                            restore_ahead => true}).
```

The worker restores the next instance while it waits, so a request that finds
one ready skips the restore. CPython, one request at a time, a pause between
requests, median of 60 in one emulator:

| phase | per request | `restore_ahead` |
| --- | ---: | ---: |
| deliver and restore | 14.8 ms | 0.04 ms |
| the guest's own call | 28.3 ms | 28.3 ms |
| whole request, first to last callback | 46.4 ms | 30.0 ms |

It needs idle time between a worker's requests. A pool that hands the next
request to the worker that just answered gives it none, so rotate idle workers
(first in, first out). At full load it adds no throughput: the restore still
runs, only earlier. Each idle worker holds one restored instance.

### Keep freed memory segments

A restore allocates its linear memory fresh, and with many workers restoring
at once the operating system's page mapping becomes a cost of its own. Letting
the emulator cache more freed segments halves it:

```sh
erl +MMmcs 30 +MMamcbf 1000000 ...
```

| 43 chunks of 1 MiB, allocated and touched | alone | 14 at once |
| --- | ---: | ---: |
| default | 4.0 ms | 11.1 ms |
| `+MMmcs 30 +MMamcbf 1000000` | 2.4 ms | 5.2 ms |

End to end on the pool above that was worth about 3%.

## Stop compiling the same Python on every request

Use this when a CPython worker always runs the same code and only the context
changes. Sent as a `source`, that code is compiled and imported again on every
request; given to the worker as `entry`, it runs once, at the capture, and a
request calls a function that is already in the image.
[Python](python.md) shows how.

The same agent request, a dispatch to a trivial `init`, the compiled tier on,
the three workers alternating in one emulator, 40 requests each:

| path | the guest's call, median | minimum | whole request, median |
| --- | ---: | ---: | ---: |
| `handle()`, the 0.5.0 reactor | 59.1 ms | 46.8 ms | 88.4 ms |
| `handle()`, this reactor | 40.4 ms | 30.9 ms | 70.0 ms |
| `call()`, an `entry` | 2.1 ms | 1.8 ms | 19.9 ms |

The rest of a request, about 18 ms, is the restore and the kernel around it,
which `restore_ahead` above takes off the request's path. These were taken
while another job loaded the machine (load average 250 to 275), so read the
gaps rather than the absolute times; `test/audit/PERF.md` has the runs.

## Rewrite only what a request wrote

A script worker restores the same image for every request, and a request
writes a few percent of it: 44 of the 640 chunks of 64 KiB in a CPython
request. So every restore recycles: the next instance takes the last one's
memory and only the chunks it wrote are rewritten. Nothing to set.
[Snapshots](snapshots.md) has the option for a host that restores by hand.

Without `restore_ahead` the worker keeps that memory between requests, and
`recycle_idle` bounds how long an idle worker does. While kept it counts in the
node's page budget: up to about 40 MB per idle CPython worker, for at most
`recycle_idle`. A node at its budget keeps nothing. Set it to `0`
for a worker that should hold nothing between requests:

<!-- check: modules my_adapter -->
```erlang
{ok, W} = wasm_script_worker:start_link(my_adapter, #{root => scratch,
                                                      recycle_idle => 0}).
```

On CPython, 14 workers without `restore_ahead`, recycling took a pool from
about 240 to about 340 requests a second at 64 callers, and one caller's median
from 28 to 20 ms. `test/audit/PERF.md` has the runs.

A CPython restore, median, in a runner-sized process:

| restore | per restore |
| --- | ---: |
| into fresh memory | 12.0 ms |
| recycled, 64 KiB chunks | 3.9 ms |
| recycled, 256 KiB chunks | 6.1 ms |
| recycled, 1 MiB chunks | 7.5 ms |

Smaller chunks rewrite less of what a request touched, which is why 64 KiB is
what a recycling restore uses.

It costs every store a mark, so the chunks it wrote are known. Measured in
generated code on a loop of stores, and on the guest's own call in the same
CPython request:

| | before | recycling |
| --- | ---: | ---: |
| a store in generated code | 12.3 ns | 16.7 ns |
| a store, memory not recycled | 12.3 ns | 12.6 ns |
| `handle()`, the guest's call | 26.3 ms | 30.4 ms |
| `call()`, the guest's call | 2.3 ms | 2.5 ms |

A request that compiles its source on every call, as `handle()` does, is the
store-heavy case and pays about 4 ms; the restore saves about 8. With the entry
`call()` runs, the mark is 0.15 ms.

What it did to throughput, CPython, 14 workers, 64 callers, `restore_ahead` on,
the three builds interleaved twice on a machine with other load on it (load
average 57 to 98):

| build | requests a second |
| --- | ---: |
| 0.5.0 | 128 to 156 |
| 0.6.0 without recycling | 201 to 275 |
| 0.6.0 | 368 to 466 |

## What this project has not measured

Said plainly rather than filled with general advice, because a claim here cites
`test/audit/PERF.md` and there is nothing to cite: allocator flags other than
the segment cache above, scheduler binding (`+sbt`), scheduler counts and dirty
schedulers have no measurement in this tree. If you measure any of them, that
file is where the numbers go.
