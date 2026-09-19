# Pricing one path at a time

Each arm times one path in isolation, so a change can be charged to the thing
that caused it. Use it when you have changed something on a hot path and need a
number rather than an opinion, and to check a change against a threshold that
was written down before the numbers arrived.

## Run an arm

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/pathbench.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run pathbench main call
```

Start with `null`, which times an empty fun. Two arms that should be identical
and are not tell you what the box is doing to you before any of the rest means
anything.

```sh
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run pathbench main null
```

The arms: `null`, `decode`, `validate`, `compile_small`, `compile_big`,
`load_hit`, `inst_small`, `inst_plugin`, `inst_big`, `call`, `call_host`,
`call_indirect`, `br_table`, `memory`, `mem_create`, `grow`, `wasi_write`,
`worker`, `concurrency`.

## Compare against another commit

One arm per VM, several launches, minimum of five rounds. Build the other side
somewhere else rather than rebuilding in place, and interleave the launches so
a change in the box's load lands on both:

```sh
mkdir -p /tmp/base && git archive <commit> | tar -x -C /tmp/base
cp bench/paths/pathbench.erl /tmp/base/bench/paths/
(cd /tmp/base && rebar3 compile && erlc -o bench/paths \
    -pa _build/default/lib/wasm/ebin bench/paths/pathbench.erl)

for i in 1 2 3; do
  (cd /tmp/base && erl -noshell -pa _build/default/lib/wasm/ebin \
      -pa bench/paths -run pathbench main grow)
  erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
      -run pathbench main grow
done
```

## Thresholds, and what they cost

A threshold chosen after seeing the result is not a threshold. These were set
before the resource model was written, in the plan that called for it, and the
measurement below is what it came out at.

| path | threshold | before | after | ratio |
| --- | --- | ---: | ---: | ---: |
| `memory.grow`, standalone | no more than 3x | 3320 ns | 8530 ns | 2.6x |
| `memory.grow`, exported | no more than 3x | 4670 ns | 8265 ns | 1.8x |
| `memory-new+free-1page` | none set | 2776 ns | 4154 ns | 1.5x |
| `call-fac-10` | untouched | 1414 ns | 1417 ns | 1.0x |
| `write_memory-64k` | untouched | 152.8 us | 154.8 us | 1.0x |

Creating, growing and releasing a memory became `wasm_keeper` transactions,
which is a synchronous round trip where there had been a lock-free counter
bump. About 3.8 us of the growth figure is that round trip. The rest of the
standalone arm is a second change in the same commit: a standalone memory is
now observable, so growing it publishes a chunk tuple as well as a size, which
an exported memory was already paying for and a standalone one was not.

Execution is untouched, which is the point of putting the transaction on the
lifecycle path and not on the access path. Missing the growth threshold would
have meant a lock per memory instead of a central process.

Those are the micro-arms. A real instantiate-and-destroy loop went the other
way, because the store used to keep every chunk tuple, table array and global
cell ever made. Ten thousand cycles of the 17-page Rust plugin, one live at a
time:

| | rows left in the store | live VM memory | us per instantiate |
| --- | ---: | ---: | ---: |
| before | 20,015 | 20.1 GB | 496 rising to 638 |
| after | 15 | 87 MB | 348 to 376, flat |

`pages_in_use` read 0 at both ends of both runs, which is what made this
invisible: the counter was right and the store was not. Instantiation got
faster because it stopped allocating on top of its own garbage.

### Execution leases, against the threshold recorded before them

The gate was fixed at **no more than 10% on a call against a linked or shared
object store**, and written down before the mechanism existed. Four interleaved
passes, minimum of each, `e0fb152` against the leases:

| arm | before | after | change |
| --- | ---: | ---: | ---: |
| `gc-call-alloc-linked` | 542.5 ns | 564.1 ns | +4.0% |
| `gc-call-pure-linked` | 157.8 ns | 165.8 ns | +5.1% |
| `gc-call-alloc-unlinked` | 542.6 ns | 587.6 ns | +8.3% |
| `gc-call-pure-unlinked` | 144.4 ns | 165.6 ns | **+14.7%** |

The arm the gate names passes at +4.0%. A lease is two `atomics`
read-modify-writes, about 21 ns, taken once per outermost call, so it lands
hardest on the shortest call: `pure` allocates nothing and exists only to price
the mechanism.

**The unlinked arms were supposed not to move at all, and they do.** The plan
had an instance alone in its process take no lease. That is not sound, and the
reason is a case the plan did not consider: a heap becomes shared when a second
instance links to it, which can happen while a call on that heap is already
running. That call took no lease, nothing can observe it, and the new instance
is then free to collect underneath it. So a lease is taken whenever the store
exists at all. A module declaring no struct and no array type has no store and
pays one comparison.

The alternative the plan named for missing the gate, moving leases off the call
path and making collection owner-only, gives up collecting a shared store
altogether. 21 ns is the cheaper trade.

### Keeping what a trap wrote

No threshold was set for this one. Every store mutation is recorded so the
invocation's catch can commit it, which is one process dictionary write per
mutation and one erase per top-level call. Four interleaved passes, minimum of
each, `f1bdedb` against the checkpoints, at a load average of 25 so read them
as indicative:

| arm | before | after | change |
| --- | ---: | ---: | ---: |
| `global.set-x1000` | 88.0 us | 96.8 us | +10.0% |
| `call-through-host-import` | 210.0 ns | 222.1 ns | +5.8% |
| `call-fac-10` | 1440.5 ns | 1432.0 ns | none |

About 8.8 ns per `global.set` and about 12 ns per top-level call. The
`global.set` arm does a thousand of them in one call and is the worst case on
purpose; `call-through-host-import` is a 210 ns call, which is why a fixed 12 ns
shows as 6% there and as nothing on a 1.4 us one.

The key those writes are made under is a bare reference rather than a
`{wasm_checkpoint, Id}` tuple. Building and hashing the tuple on every mutation
cost more than the write it was the key for: the same arm measured +20.3% that
way, against +10.0% now.

### The invocation budget

The plan asked for one thing here: that the charged edge did not get slower.
Fuel is charged at every loop back edge and every call, and it stays an
immutable field read; the budget is touched only at boundaries. Three
interleaved passes, minimum of each, `7a8b31e` against the budget, at a load
average between 24 and 51 so treat them as indicative:

| arm | before | after | change |
| --- | ---: | ---: | ---: |
| `call-fac-10` | 1489.2 ns | 1473.1 ns | none |
| `global.set-x1000` | 97.7 us | 94.5 us | none |
| `call-through-host-import` | 225.0 ns | 263.8 ns | +17.2% |

The charged edge is unchanged, which was the requirement. What moved is the
host-call boundary: two process dictionary operations per outermost invocation
and three per host call, to publish the fuel a nested call continues from,
count the call, and adopt whatever came back. About 39 ns on a 225 ns round
trip through an import that does nothing. A host function that does real work,
which is every WASI call, is measured in microseconds.

### Enforcing the page ceiling

A holder's total is kept as a running sum in the keeper rather than as an index
from holder to memories, because growth has to check every holder of the memory
being grown. Three interleaved passes, minimum of each, `36afdd0` against the
ceiling, at a load average of 6 to 10:

| arm | before | after | change |
| --- | ---: | ---: | ---: |
| `instantiate-fac` | 3438.5 ns | 3436.9 ns | none |
| `memory-new+free-1page` | 4455.1 ns | 4630.4 ns | +3.9% |

Instantiation is unchanged because a limits map without `max_memory_pages`
short-circuits before it reaches the keeper at all. What moved is creating and
releasing a memory, which now adds to and subtracts from a holder's total.

Recorded on an Apple M4 Pro, OTP 29, `a6be24d` against the resource model.

## Which fusion rules actually fire

A rule that never matches and a rule that matches and does not pay look
identical in a timing. `fusecount` tells them apart by walking the lowered IR
of an instance built with `fuse => true` against one built with `fuse =>
false`, so nothing is counted inside a timed run and the interpreter carries no
counters:

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/fusecount.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run fusecount main test/fixtures/lang/qjs.wasm
```

Add `show` after the path to print the IR, which is readable for a benchmark
loop and is not for anything else.

Over 560,000 instructions of QuickJS, every rule fires and fusion removes 22.1%
of dispatches; over the 46 KB Rust plugin, 24.1%. Over `bench/cross/loop.wat`,
which is what the cross-runtime arm times, only two of the nine fire:

| module | instructions | after fusion | removed |
| --- | ---: | ---: | ---: |
| `loop.wasm` | 24 | 18 | 25.0% |
| `plugin.wasm` | 13,931 | 10,569 | 24.1% |
| `qjs.wasm` | 559,987 | 435,991 | 22.1% |

**So the benchmark loop is not a sample of the rules.** Seven of the nine were
chosen from real clang and Rust output and the loop exercises none of them. A
fusion change has to be counted on a real module and timed on the loop, and the
two answer different questions.

### What `fc183c1` actually did

`fc183c1` added four rules and measured -1.3%, and there was no way at the time
to say whether they had run. Counted against `54761de`, on the loop, exactly
one of the four fires: `lg_const_add_set` replaces the `lg_const_add`,
`local.set` pair the older rules left. The loop body goes from 16 dispatches
per iteration to 15.

| | dispatches per iteration | ns/iteration |
| --- | ---: | ---: |
| `54761de` | 16 | 111.6 |
| `fc183c1` | 15 | 108.8 |

**6.25% fewer dispatches bought 2.5% of the time**, consistently in that
direction across three interleaved passes but inside the run-to-run spread of
either arm. So the rules do fire, the change is a small real win rather than
the nothing it looked like, and dispatch count is worth about a third of its
face value on this loop. The rest of the time is in the operand traffic around
the dispatch, which is what a bounded top-of-stack cache is aimed at and what
another peephole rule is not.

## Compiling one function instead of interpreting it

`corespike` answers a feasibility question and no others: what would a
compiler get, if wasm IR were turned into Core Erlang and handed to the
compiler and JIT that are already here?

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/corespike.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths -pa bench/cross \
    -run corespike main bench/cross/loop.wasm
```

It asserts the same checksum as the interpreter at five sizes before it reports
a time, because a faster answer to a different computation is not a result.
**2.59 ns/iteration against the interpreter's 60.5**, which is faster than
wasm3 and slower than V8.

It is in `bench/` and not `src/` on purpose. It loads one literal module name,
once, never unloads or purges, and covers only blocks, loops and the i32
arithmetic this loop uses; anything else raises `{unsupported, Instr}`. See
`test/audit/PERF.md` for the list of what a real compiler would have to handle
first.

## How much of a module a compiler could take

`corespike` reports 2.59 ns/iteration on a subset. `subset` says how much of a
real module has that shape, by walking the lowered IR of every function and
sorting each instruction into a category. A compiler supporting a set of
categories can take exactly the functions whose categories fit inside it, so
the table is a direct answer to "what does the next restriction buy".

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/subset.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run subset main test/fixtures/lang/qjs.wasm why
```

**The subset `corespike` covers is 0.5% of QuickJS by function and 0.02% by
instruction**, and 4.7% and 0.04% of the Rust plugin. Adding restrictions back,
by share of instructions:

| compiler supports | qjs funcs | qjs instrs | plugin funcs | plugin instrs |
| --- | ---: | ---: | ---: | ---: |
| i32, control, locals | 0.5% | 0.0% | 4.7% | 0.0% |
| + i64, div/rem | 1.1% | 0.0% | 4.7% | 0.0% |
| + memory | 8.2% | 2.4% | 16.0% | 22.7% |
| + globals, floats | 10.3% | 3.2% | 16.7% | 22.8% |
| + calls | 94.1% | 73.8% | 100% | 100% |

The remaining 5.9% of QuickJS is SIMD, and nothing in either module uses
tables, the GC types or atomics.

**So there is no cheap on-ramp.** A compiler that cannot call is worth nothing
on real code: leaf functions doing pure integer arithmetic are 107 instructions
out of 560,000. The compiled-to-interpreted boundary is not the last piece of
the project, it is the first, and the cost of crossing it in both directions is
what decides whether the rest is worth building. Memory is the second: it
alone takes the plugin from nothing to 22.7%.

Static counts weight every instruction equally, which a loop body is not. Read
the table as a ceiling on coverage, not as a share of run time.

## The measurement protocol, and why it is not optional

Read this before taking any number from this directory.

`matrix.erl` is the instrument. It runs a workload several times and records,
per run, wall and CPU time, reductions, collections and words reclaimed, the
process heap, node memory by category, and the microstate accounting delta.

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/matrix.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run matrix main qjs same 5
```

Workloads are `qjs`, `plugin`, `memloop` and `arith`. The last two are the same
counted loop with and without memory traffic, so a difference that shows in one
and not the other says whether memory access is where time went.

Modes are `same` (every iteration in the calling process), `fresh` (a new
process each time) and `helper` (build in one process, run in another).

**The rule: one process per run.** Repeating QuickJS in a single process is
bimodal, about 1.7 seconds or about 13, decided by whether the collector handles
the interpreter's 10-million-word heap cheaply. Reductions are identical and the
output is byte identical; only collection time moves, by up to 430x. A fresh
process per run takes the spread to 1.02x. `realbench` does this now.

**And never take a minimum across runs.** A minimum assumes the runs are draws
from one distribution. Under the old protocol they were not, and the 1.33x once
reported for the compiled tier was a minimum landing on a fast run for one arm
and a slow run for the other.

`msacc` is the instrument that settles this class of question in one run,
because it says whether lost time went to collection, to the emulator, to a port
or NIF, or to auxiliary work. Reach for it before theorising.

## Is the tier actually running the program

`tiered.erl` counts the interpreter's own dispatch, tier off and tier on, by
call-count tracing `wasm_exec:run/3`.

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/tiered.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run tiered main qjs
```

**This is the gate on any change that adds instructions to the subset, and
coverage is not.** The share of *functions* that compile has pointed the wrong
way twice: QuickJS reached 93% compiled while about 1% of its executed
instructions were, because one unsupported instruction anywhere in the hot
function keeps that whole function interpreted, and a bytecode interpreter is
one function.

Counting function *entries* is no better and is how the mistake was actually
made: with the tier on, QuickJS entered 204 functions interpreted against
23,069, and each of those 204 ran a loop of about 720,000 instructions. A
function entered once and a function entered once that runs for a second are
indistinguishable by call count.

The wall times it prints are not a speedup: tracing charges the arm that
dispatches 148 million times and charges nothing to the arm that dispatches
none. Take speed from `realbench`.

## What the generator actually refuses today

`subset` answers what a compiler *could* take. `coverage` answers what this one
does, by asking `wasm_core:can_compile/2` about every function, so it reports
the decision the tier will make at run time rather than a model of it.

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/coverage.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run coverage main test/fixtures/lang/qjs.wasm
```

Run it before and after every change that adds an instruction to
`wasm_core:supported/1`, and put both histograms in `test/audit/PERF.md`. A
change that adds an instruction and does not move coverage has not paid for
itself.

Refusals are tallied by the *first* refusing instruction in each function, which
makes the histogram an ordering and not a census: removing the top entry
uncovers whatever stood behind it. Predicting the next coverage number by
summing rows overshoots, and has, by 7 points.

Today: 100% of the Rust plugin and 83% of QuickJS, whose remainder is floats and
SIMD.

## What a call costs, and what it would cost a compiled function

`subset` says the boundary is the first thing a back end needs. `callcost`
prices it, before any of it is written:

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/callcost.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths -pa bench/cross \
    -run callcost main
```

Inside the interpreter a call is a trampoline: `enter/5` stashes the caller's
continuation in `#st.frames` and tail-calls `run/3`, so no Erlang frame is used
and no state is rebuilt. A compiled function cannot do that, because its
continuation is a Core Erlang frame. It has to make a nested invocation through
`wasm_exec:call/5`, which is what `foreign_call` already does for a call into
another instance, so the floor can be timed from Erlang with no compiler.

Three passes on a two-function module whose loops differ in exactly one thing,
whether the accumulator is incremented by a call or in line:

| | ns per call |
| --- | ---: |
| interpreted call, trampolined | 43.5 to 44.7 |
| nested invocation, the floor | 37.4 to 43.4 |

**They are the same, which was not the expected answer.** The nested path
rebuilds a state and publishes fuel on return, and it still comes out level,
because it skips the `call` dispatch and the operand-stack traffic the
trampoline pays instead.

So the boundary is about 40 ns and the compiled body it replaces runs about 25x
faster: `corespike`'s loop is 68 ns interpreted and 2.59 ns compiled. A
compiled function breaks even once its interpreted body would have cost more
than the boundary, which is about six instructions. QuickJS functions average
336. And a compiled function calling a compiled one is an ordinary Erlang call
at a couple of ns, which is 94% of the calls once the coverage above holds.

Three things this does not price, each of which only adds: the caller's own
state threaded into the crossing, the interpreter's side of an
interpreted-to-compiled call, and the try/catch a trap has to unwind through.

### What the generator's limits have to be

`subset` also reports the shapes a code generator is bounded by, so the limits
come from the two real modules rather than from a guess. A generated control
continuation carries the frame's locals plus whatever operands are live across
its boundary, so its arity is bounded by params plus locals plus the operand
height the validator already recorded.

| | plugin max | plugin p99 | qjs max | qjs p99 |
| --- | ---: | ---: | ---: | ---: |
| params + locals | 15 | 12 | 63 | 30 |
| operand height | 8 | 7 | 12 | 10 |
| bound on continuation arity | 20 | 18 | **71** | 37 |
| control frames per function | 118 | 41 | **1016** | 165 |
| control nesting | 18 | 9 | **257** | 30 |
| compilable functions | 150 | | 1666 | |

**Arity is not the constraint it looked like.** The worst function in QuickJS
would generate a continuation of 71 arguments against the BEAM's limit of 255,
so a bound anywhere above about 128 costs no coverage at all. The decoder's
one-million-local ceiling and a `nparams =< 254` test are both theoretical.

What is real is the **atom pools**, since a Core function identifier has to be
an atom. One name per compiled function needs to cover 1666. One name per
control frame does *not* need to cover 1016: `letrec` scoping means sibling
frames can reuse a name, so what has to be covered is the nesting depth, 257.

## Changing the dispatch path: check QuickJS first

Three separate changes to `run/3`, `branch/3` or what they call have now cost
about 70% on real compiler output while measuring nothing, or an improvement, on
`bench/cross/loop.wat`. The most recent was replacing `lists:nth/2` plus
`lists:nthtail/2` in `branch/3` with a single traversal, which is strictly less
list work and cost QuickJS 75%.

So run `realbench` before believing anything else:

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/realbench.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run realbench main qjs
```

Interleave it against the previous commit, five pairs, and compare minimums.
The loop cannot see this class of regression, and neither can any of the call
arms.

## Where a compile's memory is spent, and what a ceiling would cost

`PERF.md` records that a `max_heap_size` ceiling on the process `wasm_jit`
spawns sees 0.34 GB of a compile whose node reaches 6.19 GB, because
`compile:forms/2` runs its passes in a process of its own, and that moving the
work onto that same long-lived coordinator with `no_spawn_compiler_process`
costs 75% more compile time. `compileheap` asks the question that experiment did
not: what does the same option cost in a *fresh, disposable* process of our own,
which is the lifecycle OTP's own child already has?

```sh
erlc -I _build/default/lib -o bench/paths bench/paths/compileheap.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run compileheap main test/fixtures/lang/qjs.wasm 5
```

Prove the instrument first. It groups collection events by pid, which
`allocwords` does not and cannot, since its estimator pairs a start with the end
after it and that is sound only within one process:

```sh
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run compileheap main validate
```

Three arms compile the same `Core`, built once before any of them: `otp` as
`wasm_core:module/9` calls it today, `inline` with
`no_spawn_compiler_process` on the measuring process, and `child` with the same
option in a fresh process under the `max_heap_size` map that would ship. The
gate is one ordered rule on `R = child min / otp min`, from the **clean,
untraced** walls: `R =< 1.10` ships, `1.10 < R =< 1.20` ships opt-in, `R > 1.20`
stops.

Four things it will not let you get wrong, each of which cost a draft:

- **The wall it gates on is untraced.** The arms differ in how many processes
  exist and so in how many collection events the instrument sees, which is the
  same trap `pyarms` records as "the traced wall is not the wall".
- **`[procs, set_on_spawn]` delivers zero collection events.** A child inherits
  only the flags its parent carries, so the trace needs
  `[procs, garbage_collection, set_on_spawn, monotonic_timestamp]`, and that
  last flag makes every message a `trace_ts` tuple with a timestamp appended.
  A harness matching `{trace, ...}` matches nothing and silently finds no child.
- **The `otp` arm's allocation is a floor, printed with a `>`.** Its compiler is
  spawned inside `compile:do_compile/2` and exits with its result, so no closing
  collection can be forced and the final live set is unmeasured.
- **The sampled peak is a lower bound**, always: a peak between two 50 ms
  samples is invisible, and so is the memory the collector needs while
  collecting. Never size a ceiling by it.

## Short notes

- The box matters more than most of these differences. Taken here at load
  average 12 to 14; the same box at 30 moved control arms by 17% between runs.
- `grow` deliberately runs 200 growths and not 3000. Each one appends a chunk
  and rebuilds the chunk tuple, so a long run measures the O(n) rebuild rather
  than the round trip the arm exists to price.
- Take a per-iteration cost as the slope between two sizes where you can. A
  single arm's absolute number includes whatever setup the fun does.

## Pricing a request rather than a path

`workerbench` is the one arm here that does not time a path inside the runtime.
It times what a host sees: a request arriving at a `wasm_script_worker`, an instance
made for it, and the latency changing underneath when generated code lands.

```sh
erlc -o bench/paths -pa _build/test/lib/wasm/ebin \
     -pa _build/test/lib/wasm/examples bench/paths/workerbench.erl
erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples \
    -pa bench/paths -run workerbench main qjs compiled warm 500 \
        "$PWD/_build/bench-cache"
```

**Not `/tmp`.** The cache validates its directory now, and `/tmp` fails twice
over: it is a symlink to `private/tmp` on macOS, and `/private/tmp` is
`drwxrwxrwt`. A run pointed there gets no cache at all and says so once in the
log -- which, before this was written down, is exactly the shape of a warm arm
that quietly measures a cold one. Use an absolute path you own with no group or
other write bit; `_build` is gitignored and convenient.

Three cache arms, and the third is the one that matters:

| arm | `code_cache_dir` | what it answers |
| --- | --- | --- |
| `adoption` | unset | does request *n* adopt what *n-1* compiled, with no disk involved? |
| `cold` | an empty directory | what a first-ever start costs |
| `warm` | that directory, after a cold run | what a restart costs |

`adoption` sets **no** directory rather than an empty one, so the disk cache
cannot be credited for same-node adoption. Tell `warm` apart by
`wasm_jit:counts/0` saying `cached => 1`, not by a wall time: the first two
arms are indistinguishable by latency and differ only in what they prove.

Run the null arm first here as everywhere else. It came out at 16% on the
minimum for a 60-request QuickJS arm, and a CPython arm varies by a third
within itself, which is the difference between a measurement worth printing and
one that is not.

### Sweeping a heap floor

The same module's `floors` mode answers a different question: what
`runner_min_heap_words` is worth on a guest. It is the shape to copy for any
per-worker setting, because it makes the comparison self-controlling.

```sh
erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples \
    -pa bench/paths \
    -run workerbench main floors qjs_reactor metered 10 0 100000 200000
```

One worker per floor, all in **one** emulator, round robin with the order
reversed on alternate rounds, and each request traced for `garbage_collection`
on the processes it creates. Two rules it exists to enforce:

- **Put the off setting in the sweep.** Without a zero arm there is nothing in
  the run to say the setting did anything at all. A CPython sweep without one
  came back flat and had to be thrown away; `ATTEMPTS.md` has it.
- **Never compare across runs.** The floors are compared against each other
  under whatever load the box has, which is the only comparison this machine
  supports.

### Does a reactor ever reach the compiled tier

```sh
erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples \
    -pa bench/paths \
    -run workerbench main tier qjs_reactor 3000 200000
```

A metered and a compiled worker over the same reactor artifact, alternating in
one emulator, with the heap floor on in both halves. The floor is not optional:
the tier's 8.4x was measured against an unfloored interpreter, and measuring it
against one again would credit the tier with what the floor already does.

**Read `wasm_jit:counts/0`, never the wall time.** An arm where the tier is off
and an arm where it is on and slow are the same number of milliseconds; only
`entered` tells them apart. That is `adopt.erl`'s rule for the command path.

**And give it wall-clock time, not a request count.** The tier arrives after a
fixed amount of compiling, and a reactor request is ten times faster than a
command one, so the same request count buys a tenth of the time the compiler
needs: 3000 requests here is not the 76 s that 353 requests is on the command
path. The mode waits on a deadline, driving requests while it waits, because
the tier advances when calls happen and not when time passes. `ATTEMPTS.md`
records the run that read a slow compile as no compile at all.

The `floors` and `throughput` modes take the config as an argument too, so
either can be run `compiled` rather than `metered`.

### Measuring from a node that has arrived

`steady` is the mode for questions about a node in its final state rather than
on its way there: module compiled, compiler gone, counters zeroed. It has three
arms, because three gates need different setups.

```sh
erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples \
    -pa bench/paths \
    -run workerbench main steady qjs_reactor latency 200 200000
```

- **latency**: one compiled and one metered worker, alternating. Answers the
  compiled median against the metered median in the same emulator.
- **throughput**: compiled workers at 1, 2, 4, 8 and 14, with a metered control
  at each count. **Normalise before comparing revisions.** The metered control
  ranged from 182 to 331 req/s across five runs of the same thing, so a raw
  rate comparison is mostly box.
- **control**: the tier on so every call pays the residency lookup, and a
  `compile_after` above every call the arm makes so no compile ever starts. It
  prices one thing. Its end state is the *opposite* of the other two and is
  asserted separately: nothing resident, counts zero.

**Wait for quiescence, do not infer it from residency.** `publish/1` makes a
slot resident before the compiler bumps `compiled` and takes its own lease, so
a harness that resets counters the moment residency appears races all three.
`steady` waits for the target's lease count to reach zero and the compiler
children to go, then reads and asserts a non-zero compiled count before
resetting. Without that assertion a comparison can read 0 on both sides and
agree vacuously.

**Find the target by hash, not by key.** The JIT's slot key is
`{identity, ?ABI}` and `?ABI` is private to `wasm_jit`, so a benchmark that
spelled it would go stale at the next ABI bump. `wasm_code_slots:resident/0`
answers `{Name, Key, LeaseCount}`; match the artifact's own hash inside `Key`.

To compare revisions, copy this file into the older tree and compile it there,
as the cross-commit protocol above does with `pathbench.erl` -- the older tree
does not contain this mode. The reactor `.wasm` fixtures are built rather than
committed, so copy those across too or the older arm cannot start.

### What a cold node pays, and whether a cache spares it

`coldnode` measures the window before the tier is running, which for a reactor
nothing had measured.

```sh
erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples \
    -pa bench/paths \
    -run workerbench main coldnode lua_reactor "$PWD/_build/c1" cold serve w
```

The arguments are the guest, an **absolute trusted** cache directory, `cold` or
`warm`, `serve` or `wait`, and `w` or `b`.

Four things it does that are not optional, each because getting one wrong
produces a plausible number:

- **The snapshot is prepared outside the timed arm, and the arm checks it was
  loaded.** Setting `snapshot_dir` proves nothing: a worker that finds no image
  captures instead, silently. The first CPython run here exited with
  `{worker_captured_rather_than_loaded, 108990, 20000}` rather than quietly
  reporting a hundred and nine seconds of somebody else's work.
- **The clock starts after the worker is up**, so the snapshot is reported
  apart from the compile rather than inside it.
- **The number of shards is recorded.** `cached/6` skips the lookup entirely
  for a sharded compile, so a sharded arm reports `cached = 0` for a reason
  that has nothing to do with the cache.
- **The slot is recorded**, because it is in the cache key: two arms in
  different slots miss each other whatever else matches.

To ask whether a *different* script hits a warm cache, use **two emulators over
two clones** of the same seeded directory -- one running `w`, one running `b`.
One emulator cannot answer it: whichever runs first becomes resident and the
second adopts its code without ever consulting the cache.

### Scaling, where interleaving does not save you

The `throughput` mode sweeps worker counts and reports requests per second,
with and without a heap floor, sampling peak process memory as it goes.

```sh
erl -noshell -pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples \
    -pa bench/paths \
    -run workerbench main throughput qjs_reactor metered 25 200000 1 2 4 8 14
```

**This is the one arm here that cannot be made self-controlling.** A latency
sweep interleaves its arms and is readable against whatever else the box is
doing. A scaling curve needs idle cores and no trick substitutes for them: run
it on a busy box and you measure the box. So the mode prints `top`'s idle
percentage as well as the load average, at both ends, because a one-minute
load average decays for fifteen minutes after the previous arm and says nothing
about now.

What survives a busy box is the *comparison* between two arms of the same
count, since both met the same machine in the same minute. What does not is the
absolute ceiling: read a flattening curve as this machine's free cores until
you have run it somewhere quiet.

One trap in the memory column. A floored arm finishes sooner, so it is sampled
fewer times and its peak is the worse estimate of the two. That bias runs
against the floor, so a *lower* floored number is safe to believe and a higher
one is not; when it mattered, `PERF.md` re-ran the two arms with request counts
chosen to make them the same length.

### Where a request's milliseconds go

`phases` decomposes one request at the five adapter boundaries, using the real
worker rather than a reconstruction of it: `bench/paths/phasing_adapter.erl`
wraps the real adapter and timestamps both sides of every callback.

```sh
erlc -Werror -o bench/paths -pa _build/test/lib/wasm/ebin \
     -pa _build/test/lib/wasm/examples \
     bench/paths/phasing_adapter.erl bench/paths/workerbench.erl

erl_paths=(-pa _build/test/lib/wasm/ebin -pa _build/test/lib/wasm/examples
           -pa _build/test/lib/wasm/test/support -pa bench/paths)

erl -noshell "${erl_paths[@]}" -run workerbench main phases smoke
erl -noshell "${erl_paths[@]}" -run workerbench main phases seed  py_reactor
erl -noshell "${erl_paths[@]}" -run workerbench main phases null  py_reactor compiled
erl -noshell "${erl_paths[@]}" -run workerbench main phases pairs py_reactor \
    interpreted compiled
```

An array, not a scalar: zsh does not word-split an unquoted `$P`, so a single
`-pa a -pa b` string reaches `erl` as one argument and the module is "not
found". That cost a run here.

Order matters, and `set -e` is part of the procedure. `smoke` and `calibrate`
gate the instrument; `seed` fills the cache and the image directory and writes
the manifests; `null` runs before `overhead` and both before `pairs`, because a
failed null invalidates every timing run after it. An arm that fails a gate
writes its record and halts the emulator non-zero.

**Re-seed after any harness change.** Every arm asserts a code manifest -- the
runtime, kernel, adapter and harness BEAMs by content, plus HEAD and a diff
hash -- against what the seed recorded, because these runs happen from a
worktree that is still being edited and a git SHA names the parent commit
rather than the code that was loaded. It caught a recompile between a seed and
its arm on the first day it existed.

Three rules this mode adds to the protocol above:

- **The window is silent.** Validation, phase assembly, gate arithmetic,
  counter reads and printing all wait until the twelve samples are done.
  Printing per sample puts a gap between requests and changes the cleanup
  overlap the controls are there to measure.
- **The residual is an assertion.** The intervals are contiguous, so they sum
  to the total identically; a non-zero residual is an assembly bug and fails
  the sample. It is never reported as an unexplained cost.
- **Small phases need the overhead arm.** `overhead` prices the wrapper against
  the real adapter and reports the median of the paired *differences*. Phases
  under it are below probe resolution and are not values of the uninstrumented
  request. Taking a difference of medians instead read 3.6 ms of "overhead"
  that was the box moving inside one arm.

`calibrate` injects a known sleep into one named callback and requires it to
appear in that interval and nowhere else. Run all five: injecting into one
proves that boundary and leaves a swap among the other four invisible.
