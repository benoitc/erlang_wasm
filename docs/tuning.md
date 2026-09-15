# Tuning a worker host

This guide is for one symptom: your requests are slower than your guest is, and
the time is going somewhere you cannot name. Reach for it when a request costs
tens of milliseconds and the same call, measured on its own, costs single
digits. Most of the time the answer is garbage collection in the process the
kernel spawns per request, and the fix is one worker option. The rest of the
time it is the start rather than the request, which is a different guide.

Every number here was measured on this project; `test/audit/PERF.md` is where
each one lives, and `bench/paths/README.md` is the protocol they were taken
under.

## Find out where the time goes

Do this before changing any setting. Check the load average first, take
minimums rather than means, and never compare a number from one run against a
number from another.

```erlang
%% one process's own allocation and collection time
allocwords:measure(fun() -> script_worker:run(W, Req) end).
```

```
%% the floors and ceilings a process actually got
erlang:process_info(Pid, garbage_collection).
```

**Do not use `erlang:statistics(garbage_collection)` for this.** It counts the
whole node. `bench/paths/allocwords.erl` exists because that counter reported
no change while one process's collections fell 51x, which sent an
investigation down the wrong path for an afternoon.

To compare settings, run them in one emulator, interleaved, with the order
reversed on alternate rounds:

```
erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples \
    -pa bench/paths -run workerbench main floors qjs_reactor 10 0 100000 200000
```

That is the only comparison worth making on a machine that has other work on
it. Run the same arm against itself first: if the two halves of a null
experiment differ by more than a few per cent, the box is too busy to measure
on at all.

## Give the request runner a heap floor

```erlang
script_worker:start_link(my_adapter, #{root => scratch,
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

The knee is sharp and it plateaus. Past it you are buying memory and nothing
else.

**Find your own.** The right value is a property of the guest, not of this
runtime. The three measured here want a 5x spread:

| guest | no floor | its knee | there |
| --- | ---: | ---: | ---: |
| Lua | 30.0 ms | 200,000 words | 12.7 ms |
| QuickJS | 56.0 ms | 200,000 | 21.1 ms |
| CPython | 367.1 ms | 1,000,000 | 117.8 ms |

Sweep, take the knee, and stop. Put the off setting in the sweep: without it
there is nothing in the run to say the floors worked at all, which is how one
CPython sweep here came back flat and had to be thrown away.

Two things to know before you set it:

- The emulator rounds the number **up** to a heap-size class, and the jump is
  large: 200,000 words becomes 318,187, and 1,000 becomes 1,598. That is
  2.4 MiB per concurrent runner at the QuickJS figure.
- The floor must fit under this worker's `max_heap_words` with room for that
  rounding. One that does not is refused with a warning and the runner gets no
  floor, because `min_heap_size` above `max_heap_size` is a kill at spawn.

`script_worker:runner_heap_words/2` answers what a given pair of options and
limits resolves to, so you can check a configuration without starting a worker.

## Give the capture a floor as well

```erlang
script_worker:start_link(my_adapter, #{root => scratch,
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
  instance. See [the worker guide](worker.md).
- `compile_max_heap_words` bounds a compiler process. See [the compiled tier
  guide](compiled-tier.md).

## When the cost is the start, not the request

None of the above helps a guest that takes ninety seconds to come up and a
third of a second to answer. Two different settings do:

- `snapshot_dir` files an initialized image, which takes a CPython worker start
  from 104 s to 998 ms. See [the snapshots guide](snapshots.md).
- `code_cache_dir` keeps generated code across restarts. See [the compiled
  tier guide](compiled-tier.md).

## What this project has not measured

Said plainly rather than filled with general advice, because a claim here cites
`test/audit/PERF.md` and there is nothing to cite: allocator flags (`+M*`),
scheduler binding (`+sbt`), scheduler counts and dirty schedulers have no
measurement in this tree. Neither does the shape of the concurrency curve
across worker counts. If you measure any of them, that file is where the
numbers go.
