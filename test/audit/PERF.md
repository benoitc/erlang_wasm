# Where the 30x goes, and what would close it

Exploration only. No code was changed.

## Compiled-code lifetime, before any of it is generated

`src/wasm_code_slots.erl` is the mechanism the spike is not allowed to use
until it exists. A fixed pool of sixteen slots, each owning one **pre-interned
module name** written into the source, so the complete set of atoms this module
can ever create is decidable by reading it. Nothing derived from a user's
module becomes an atom: the atom table is node-wide and never reclaimed, so a
generated name taken from a module's own bytes is a permanent leak with the
sender holding the tap.

A slot is held by **leases**, and there are two kinds because an instance can
be destroyed while a call into it is still running. Releasing the instance's
lease must not let the code be replaced underneath that call, so a call holds
one of its own and reuse waits for the last of either.

Exhaustion answers `{error, no_slot}`, which means interpret this module
instead. A manager that could not say that would have to kill a caller or grow
the atom table, and both are worse than being slower.

### Where `soft_purge/1` actually helps, which is not where it looks

`code:purge/1` kills processes still running old code and is never called.
Reuse goes through `code:soft_purge/1` -- but **`soft_purge/1` can only see
*old* code**, which exists only once a name has been loaded twice. So it says
nothing at all about a process sitting in the generation that is current.

That makes the leases the primary guarantee and `soft_purge/1` the second: the
leases say nobody is in the current generation, and `soft_purge/1` catches
anyone still in the one before. The test walks both generations for exactly
this reason. Checking one of them proves nothing, and the first version of that
case asserted `false` where the answer is trivially `true`.

### The cases, named in the plan before the mechanism existed

An old instance still reaching its own code after a reuse was attempted; an
instance destroyed during a call; exhaustion answering `no_slot`; the same
module loaded and unloaded fifty times taking one slot rather than walking the
pool; a manager restart keeping the slots *and* rebuilding the monitors; a
holder that dies; 500 distinct modules generated and loaded with the atom table
growing by less than 100; and code still running never being purged.

Two mutations were tried against them. Releasing an instance lease dropping the
call's lease as well fails the case named for it. Handing out a slot without
`soft_purge/1` fails the two-generation case.

## Four defects, and one change that cost 75% for a reason nothing explains

### The gate was measuring 215 of 259 suites

`wasm_spec_SUITE` runs `wasm_spec_manifest:core/0` and logs whatever is left
over. 41 suites sat in that log, and they were not new proposals: `memory_copy1`,
`instance`, `linking0..3`, `imports0..4`, `load0..2`, `store0..2`, `traps0`.
`docs/features.md` said everything outside `core/0` was named as an out-of-scope
proposal, which was simply not true.

All 41 are core. Classifying them took the gate from 215 suites to 256, which is
every suite in the checkout, and turned up a real defect immediately.

**Cross-memory `memory.copy` never bounds-checked a zero-length copy.**
`wasm_memory:copy/5` answered `ok` for `Len = 0` before looking at either
address. The specification admits an address exactly at the end of a memory and
requires a trap one byte past it, whatever the length, and `memory_copy1.wast`
asserts both directions. The same-memory `copy/4` had it right, and `fill/4` and
`init/5` too, so this was one clause. A zero-length short-circuit reads as an
optimisation and is a hole.

**18 `assert_exception` commands had never run.** The harness skipped them as
belonging to an out-of-scope proposal, but exception handling is implemented and
has its own suite. So did the 4 `module_definition` commands, which are how
`instance.wast` checks that instantiation is generative -- core semantics, and
`wasm_wast` already parsed them. Both were gaps in `wasm_spec_runner`, not
missing features.

The gate now reads 65481 pass, 0 fail, **0 skip**, over 256 suites.

### Code-slot leases leaked a monitor each, and cost 5.8 us

`wasm_code_slots:drop/3` removed the ETS lease and left the monitor, so the
manager accumulated one monitor per lease it had ever handed out: 111 monitors
after 110 released leases. The fix needs a reverse index, because a `DOWN'
arrives with a reference and a release arrives with a lease and each has to find
the other.

The cost was the more interesting half. At 5.8 us a lease cannot be taken per
compiled call, and against a 1.4 us `call-fac-10` it cannot be taken per
outermost call either. So the two lease kinds now use two mechanisms, which is a
measurement rather than an inconsistency:

| | mechanism | cost |
| --- | --- | ---: |
| instance lease | `gen_server` call, monitored | 5.8 us |
| call lease | `atomics` counter per slot | **46.2 ns** |

That is the shape `wasm_heap` already uses for execution leases, and the reason
is the same: a lease on the call path costs more than the thing it guards. The
exposure it accepts is the same too. A process killed with `exit(Pid, kill)'
skips the `after' and leaves its count raised, so that slot is never reused
again; callers then interpret instead, which is the fallback the module exists
to provide, so it costs speed and never safety.

### `br_table` lowered to a tuple, and a branch change that had to be dropped

Two changes were planned here. One paid and one cost 75%.

**The one that paid.** `select_label/3` did `length/1` and then `lists:nth/2`,
two walks of the label list on every dispatch. Lowering the labels to a tuple in
`wasm_instance:ir_instr/2` makes both `tuple_size/1` and `element/2`, so a jump
table with a hundred entries costs what one with two costs.

| arm | before | after | change |
| --- | ---: | ---: | ---: |
| `br_table-32-labels-x10000` | 976 to 991 us | 615 to 639 us | **-36%** |
| `qjs-300k-js-iterations` | 108.0 ms | 93.8 ms | none |
| `loop.wasm` | 67.2 to 68.6 ns/iter | 65.6 to 65.8 | -3% |
| `call-fac-10` | 1193.0 ns | 1195.7 ns | none |
| `call_indirect` | 271.5 ns | 267.7 ns | none |
| `call-through-host-import` | 271.4 ns | 268.3 ns | none |

**The one that cost 75%.** `branch/3` calls `lists:nth(N + 1, Ctrl)` and then
`lists:nthtail(N + 1, Ctrl)`, walking the same cells twice. Replacing the pair
with one traversal returning `{Target, Rest}` is strictly less list work.

| | qjs, minimum of five interleaved passes |
| --- | ---: |
| `lists:nth` + `lists:nthtail` | 102.7 ms |
| one traversal returning a tuple | 181.8 ms |

Five pairs, every one of them, at a load average under 5. Reverted.

**This is the third time a small change to the dispatch path has cost about 70%
on real code and nothing on the loop**, after the operand-cache entry points and
the locals threading. The suspected mechanism is still unproven, and the honest
statement is the empirical one: `run/3` and the functions reached from it are a
regime where adding one call and one allocation to a hot path is not a small
change, and only QuickJS says so. `loop.wasm` was 3% *faster* with the
regression in place.

The rule that follows: **any change to `branch/3`, `run/3` or what they call has
to clear `bench/paths/realbench.erl` before it clears anything else.** The
synthetic loop cannot see this class of regression at all.

## The QuickJS arm was measuring a usage error

`bench/paths/realbench.erl` reports `qjs-300k-js-iterations` and did not run any
JavaScript. `_start` exits with `#{wasi_exit => 2}` and QuickJS prints its usage
message to stderr; the arm discarded the result of `wasm:call/3`, so it timed an
argument-parsing failure and labelled it 300,000 iterations.

**Pre-existing, and not caused by the compiler work**: the `391ea9a` tree, from
before any of it, fails identically.

What that does and does not invalidate:

- The **regression findings stand**. The arm is a deterministic workload that
  decodes a 1.8 MB module, instantiates it and interprets its way through
  startup, so a change that made it 70% slower really did make real compiler
  output 70% slower. That is what it caught three times, and it was right.
- The **label does not stand**. Every `qjs` figure in this document is startup
  and argument handling, not a compute-bound script, and the numbers are not
  comparable to anything that does run one.

The arm now asserts the call succeeded, so it can never quietly report a number
for a failed run again.

**Why it failed**: this is not a stock QuickJS. `qjs --help` answers
`qjs FILE [ARG ...]` and lists no `-e` at all, so every attempt to pass a script
on the command line was always going to print usage. The script is now written
out and handed over through a preopened directory, which is also the only way
this module gets a filesystem: no `dirs` means no filesystem, not the working
directory.

The difference that makes is the measure of how wrong the old number was.
Running the same 300,000 iterations for real takes **24,920 ms**, against the
109 ms the arm used to report for not running them. The arm is now 30,000
iterations so that it finishes.

### What the tier does to real compiler output

| | 30,000 JS iterations |
| --- | ---: |
| interpreted | 2610.7 ms |
| compiled | **1960.9 ms** |

**1.33x**, with `#{compiled => 918, entered => 2}` confirming generated code was
entered. Taken at a load average between 9 and 14, so read it as indicative.

That is a long way from the 26x the arithmetic loop gets, and the reason is not
mysterious: 55% of QuickJS functions compile, the other 45% cross back through
the interpreter on every call, and `call_indirect` -- which a bytecode
interpreter's dispatch loop is built out of -- is refused outright. The loop
measures what compiled code can do; this measures what a half-compiled module
does, and both are true.

**One number is withdrawn rather than recorded.** With the tier on this arm
measured 38.4 ms against 109.1 interpreted, and `wasm_jit:counts/0` answered
`#{compiled => 918, entered => 0}` for the same run -- generated code was never
entered at the outermost call, so a threefold speedup cannot be attributed to
it. It is unexplained, so it is not a result.

## `call_indirect` was 64% of the refusals

The first refusing instruction per function, before and after compiling
indirect calls:

| | plugin before | plugin after | qjs before | qjs after |
| --- | ---: | ---: | ---: | ---: |
| `call_indirect` | 20 | — | 481 | — |
| `memory.copy` | 16 | 16 | 43 | **107** |
| `memory.fill` | 2 | 2 | 0 | **31** |
| SIMD | 0 | 0 | ~57 | ~63 |
| **compilable** | **74.0%** | **87.3%** | **55.1%** | **76.6%** |

`memory.copy` more than doubling is not a regression: it is what was standing
behind `call_indirect` in functions that use both. Removing the top item reveals
the next one, which is the whole reason this histogram is kept per *first*
refusal and read as an ordering rather than as a census.

QuickJS came out at 76.6% against a prediction of about 84%, and the shortfall
is exactly that effect.

**Every indirect call crosses back into the interpreter**, including one whose
target was compiled alongside the caller, because the target is not known until
it runs. Turning that into a local call needs a per-module dispatcher and is
worth its own measurement.

The resolution is `wasm_exec:indirect_target/5`, which the interpreter already
used and which now takes the instance and the mutable half rather than a whole
`#st{}` -- generated code has the two and not the record. Reused rather than
restated, so `undefined_element`, `uninitialized_element` and the type mismatch
are one implementation. Dialyzer caught the first version fabricating a partial
`#st{}` to fit the old signature.

## Bulk memory finishes the plugin, and the tier gate fails

`memory.copy`, `fill`, `size`, `grow`, `init` and `data.drop`. The histogram,
same walk as above, now from `bench/paths/coverage.erl` so it is repeatable
rather than an ad-hoc script:

| | plugin before | plugin after | qjs before | qjs after |
| --- | ---: | ---: | ---: | ---: |
| `memory.copy` | 16 | — | 107 | — |
| `memory.fill` | 2 | — | 31 | — |
| `memory.size` | 1 | — | 1 | — |
| SIMD | 0 | 0 | ~63 | ~113 |
| f64 conversions and loads | 0 | 0 | ~90 | ~160 |
| **compilable** | **87.3%** | **100.0%** | **76.6%** | **83.0%** |

The plugin is finished: every one of its 150 functions compiles. QuickJS's
remaining 283 refusals are floats and SIMD and nothing else, which is items 3
and 4 of the plan and no surprises.

One implementation, as with the arithmetic: the interpreter's own bulk-memory
clauses were rewritten to call the same `wasm_exec:memory_*_at` helpers
generated code calls, so a bound or an operand width cannot be restated
differently on the two paths. `memory.copy` across two memories therefore gets
the fixed bounds check rather than a second copy of the broken one, and the
suite has a case for the zero-length copy at 65536 and at 65537 that pins it.

### The differential harness could pass without compiling anything

`wasm_core_SUITE` generated the module and compared it against the interpreter,
but never checked that the *exported* function was in the generated unit. A
case whose subject the generator quietly refused would compare the interpreter
against itself and pass. It now asserts membership. Nothing was actually
slipping through, but that is luck rather than design.

### The benchmark gate: the tier buys nothing on QuickJS, and costs 51 seconds

Tier off and on, `bench/paths/realbench.erl`, every run reported rather than the
minimum, `wasm_jit:counts/0` confirming generated code was entered:

| | run 1 | run 2 | run 3 |
| --- | ---: | ---: | ---: |
| tier off | 2097 ms | 12997 ms | 12623 ms |
| tier on | **53123 ms** | 12906 ms | 12447 ms |

**The 12-second figures here are an artefact and have been superseded.** They
are one process repeating the workload, which is a garbage collection effect and
not the cost of running QuickJS. See the section below: under a fresh process
per run it is 1.6 to 1.8 seconds either way. The conclusion of this section does
not change, and is stronger on the corrected numbers.

Generating and loading QuickJS's 1383 compilable functions takes **51 seconds**
and produces a 7.9 MB BEAM module; one function alone (index 112, 9577
instructions) takes 2.2 s. After that the compiled code is **indistinguishable
from the interpreter**. `entered` is 3, so this is not a fallback being
mislabelled -- the compiled code ran and was no faster.

Why it is no faster is not yet measured. The two candidates are that every
`call_indirect` crosses back into the interpreter, which is what a bytecode
dispatch loop is built out of, and that the 17% still refused are called from
the hot path so each of those calls crosses too. Both are worth measuring
before any more instructions are added.

**The tier must not be enabled by default for a module this size.** Nothing
here is a regression from the bulk-memory change: `0a833f3` measures the same,
53.1 s against 12.8 s.

The plugin arm is flat, 544-620 us off against 558-606 us on across three
interleaved passes, with all 150 functions compiled and generated code entered
1000 times. That arm instantiates and destroys per iteration and is dominated
by it, so it cannot show a per-call win either way. It needs replacing before
it can answer this question.

`bench/cross/loop.wasm` is unmoved at 2.58 ns/iteration against the recorded
2.59, so the synthetic compiled path still does what it did.

## Repeating QuickJS in one process is a garbage collection artefact

`bench/paths/matrix.erl` exists to answer this, and `msacc` answered it in one
run. Three iterations of QuickJS in one process:

| run | wall | reductions | msacc gc | msacc emulator |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 2064 ms | 795,826,525 | 310,082 | 1,737,230 |
| 2 | **13,444 ms** | 838,349,463 | **10,948,009** | 2,468,700 |
| 3 | 1744 ms | 794,660,136 | 25,445 | 1,691,691 |

Identical reductions, comparable emulator time, and **35x to 430x the collection
time**. The slow run does *fewer* collections (793 against 1218), so each one is
far more expensive: the signature of a large live set being swept rather than of
allocation churn. The interpreter's process heap peaks at 10 million words and
90 MB on this workload.

Over five iterations it is bimodal, not monotonic: 2299, 13096, 13026, 1721,
13021 ms. A run either spends about 25,000 units in collection or about
10,500,000. An explicit `erlang:garbage_collect/0` before each run does not
prevent it, so this is not leftover garbage from the previous iteration.

**A fresh process per run removes it**: 2002, 1628, 1660 ms, and runs 2 and 3
are within 2%. Collection time drops to 20,000 units.

### What this corrects

The earlier entry here called it node-global on the strength of an experiment
that ran in a fresh process and still measured slow. That was wrong. It is
per-process heap state, and the earlier experiment was measuring something else.

It also corrects the numbers. **QuickJS runs in about 1.6 to 1.8 seconds, not
12.5.** Every 12-second figure in this file was one process repeating the
workload, and is an artefact.

`realbench` now runs each iteration in a fresh process and reports every run
rather than a minimum. Under that protocol:

| qjs | run 1 | run 2 | run 3 |
| --- | ---: | ---: | ---: |
| tier off | 1974 ms | 1823 ms | 1645 ms |
| tier on | 54,023 ms (compiling) | 1730 ms | 1584 ms |

So the steady-state tier win on QuickJS is **4 to 6%, which is inside the
noise**, against 54 seconds paid once. The conclusion of the section above
stands and is now measured on numbers that can be trusted.

**The withdrawal of the 1.33x from `cbad77c` also stands.** That arm took a
minimum across a fast run and a slow one, so which arm looked faster was decided
by which run the minimum landed on.

### Still open

Why a run is bimodal rather than uniformly expensive. The heap is about the same
size either way, the reductions are within 5%, and a forced fullsweep beforehand
changes nothing. The likely direction is the interpreter's live set: a
10-million-word heap for a workload whose real live data is a 1.7 MB linear
memory is itself the defect, and the per-process lowered-IR cache
(`{wasm_ir, Id, Idx}` in `wasm_instance`) is the first place to look. Reducing
that heap would make the collector's choice stop mattering.

## What the garbage collection is actually about: 1.4 billion words a run

The section above found that collection time explains QuickJS. This is what
collection is about, and the first answer was wrong.

### The wrong answer

The interpreter's process heap peaks at 10 million words on QuickJS. Broken
down at peak, before `destroy` erases anything:

| dictionary key | count | MB |
| --- | ---: | ---: |
| `wasm_ctx_cache` | 1 | 35.4 |
| `wasm_inst` | 1 | 35.2 |
| `wasm_ir` | 223 | 4.8 |

The first two share, so it is one copy of the decoded module, not two. And the
decoded module is 35.4 MB for a 1.8 MB binary, of which **25.5 MB is the bodies
of the 1443 functions out of 1666 that are never called**.

That looked like the whole story, and the obvious fix followed: keep each body
as a slice of the module binary, a sub-binary of about six words, and decode and
re-check it on first call. It works, and `#module{}` drops from 35.4 MB to
0.9 MB.

**It is a 10x regression.** Interleaved against the same commit:

| | run 1 | run 2 | run 3 |
| --- | ---: | ---: | ---: |
| before | 2231 ms | 12,698 ms | 1576 ms |
| after | 16,842 ms | 16,551 ms | 16,647 ms |

The heap fell from 10.1 million words to 1.2 million and the collection count
rose from 1218 to 7101. Reductions moved by 7%.

### The right answer

**The interpreter allocates 1.4 billion words per QuickJS run.** That is about
11 GB of garbage for 30,000 JavaScript iterations, or roughly 47,000 words per
iteration. Collection cost is governed by how often that allocation forces a
collection, which is set by the size of the heap, and not by the size of the
live set at all.

The 35 MB of decoded module was accidentally acting as a heap floor. Removing it
let the heap settle at 1.2 million words, and 1.4 billion words of allocation
through a 1.2-million-word heap is 7100 collections.

Setting `min_heap_size` explicitly says so directly:

| `min_heap_size` | run 1 | run 2 | run 3 | collections |
| --- | ---: | ---: | ---: | ---: |
| default, bodies shed | 16,727 ms | 16,605 ms | 16,842 ms | ~7100 |
| 4,000,000 words, shed | 2606 ms | 2284 ms | 4800 ms | ~350 |
| 16,000,000 words, shed | 2824 ms | 2937 ms | 3096 ms | ~85 |
| 4,000,000 words, not shed | 2765 ms | 2636 ms | 6139 ms | ~330 |

Three things fall out of that table. Heap sizing removes the bimodality whether
the bodies are shed or not, so it is the fix for the anomaly. Shedding plus a
sized heap is **better** than the same heap without it, so the two are
complementary rather than alternatives. And past about 4 million words a bigger
heap stops helping, because each collection costs more than the ones it saves.

`wasm.erl`'s `with_room/2` already does exactly this around module building, for
exactly this reason, with the numbers recorded next to it. What is missing is
the same treatment at the invocation boundary, and a policy for the size: a
fixed 32 MB minimum on every call would be absurd for a plugin making two
hundred small ones, so it has to be adaptive or opt-in.

### The regimes, measured

Chasing it further found the shape of the thing. Live set at the start of each
run, in one process, against wall time and the cost of a single collection:

| live before | wall | collections | units each |
| ---: | ---: | ---: | ---: |
| 5,157,867 | 2261 ms | 1208 | 227 |
| 6,189,440 | **13,553 ms** | 772 | **13,154** |
| 7,427,328 | **1726 ms** | 1181 | **20** |
| 6,189,440 | 12,708 ms | 782 | 13,218 |
| 7,427,328 | 1582 ms | 1181 | 18 |

**A larger live set is 8x faster.** That kills the "big live set is expensive"
reading outright. What alternates is the collector's mode: 1181 cheap
collections at about 20 units each, against 772 sweeps at 13,000. The process
oscillates between generational collection working and every collection being a
sweep, and the oscillation is deterministic run to run.

Nothing pins it to the fast side. `min_heap_size` at 7.5 or 10 million words
gives a stable 4 seconds, with few collections that are each expensive: a bigger
young generation means more survives each collection, so the old heap fills and
sweeps anyway. `fullsweep_after` at 0 gives a stable 4.3. Both are better than
the 12.7-second mode and worse than the 1.6-second one.

Shedding the bodies changes the picture, because it is the live set that makes a
sweep expensive:

| configuration | runs | collections | units each |
| --- | --- | ---: | ---: |
| shed, default heap | 17,324 / 17,023 / 17,242 | ~7100 | 2030 |
| shed, `min_heap_size` 2M | **1510 / 3713 / 1499 / 3845 / 1540** | ~690 | 11 to 2300 |
| shed, `min_heap_size` 4M | 2595 / 3708 / 3728 / 3694 | ~365 | 2900 |
| unshed, default heap | 1582 to 13,553 | 772 to 1208 | 18 to 13,218 |
| fresh process per run | 2002 / 1628 / 1660 | ~1420 | 14 |

**1499 ms is the fastest QuickJS number measured anywhere in this project**, and
it is shedding plus a 2-million-word floor. It still alternates with a
3.7-second mode, so it is not yet a configuration to ship.

The one thing that is reliably fast is **a fresh process per invocation**, at
1.63 seconds with collection at 1.3% of the run. That is what `realbench` does
now, and it is fast for the reason the others are not: a process that has never
run an invocation has no old heap to sweep.

### What this means for the plan

**Neither change ships alone.** Shedding without heap sizing is a 10x
regression. Heap sizing without shedding leaves 35 MB on the heap for nothing.
Together they are stable at about 2.4 seconds with 39x less memory, against a
bimodal 1.6 to 12.7 today. The shedding half is on the `lazy-bodies` branch
with its own round-trip test over all 1666 functions.

**Reducing the allocation rate is not the lever, and this was checked before
acting on it.** In a healthy run collection is 1.3% of the time: `msacc` reports
`gc=20557` against `emulator=1580743`. The synthetic loop allocates 42 words per
iteration, about 2.8 per instruction, which is already low because the bounded
operand cache took that win: the record update it removed was ten words per
instruction that touched the stack. There is no second -45% waiting there. The
allocation rate only matters through the collector's mode, and the mode is what
needs fixing.

**What is left is a choice about where an invocation runs**, and it is the
embedder's to make rather than a tuning constant:

- **A fresh process per invocation.** Reliable, 1.63 seconds, and the only
  configuration measured that does not oscillate. Costs a spawn and a copy of
  the results, which is nothing against a long invocation and everything against
  two hundred small ones.
- **Shedding plus a heap floor.** The fastest measured, 1.50 seconds, and 39x
  less memory, but still alternating with a 3.7-second mode.
- **A heap floor alone.** Stable at about 4 seconds. Worse than both, and the
  simplest.

None of these is free and none is obviously right for every embedder, so the
next step is a decision rather than a commit.

The plugin, at 150 functions and a 364,000-word heap, shows none of this: 1.2,
1.6 and 0.9 ms across repeated runs with 455 units of collection time. The
effect needs a real module to appear, which is why the synthetic loop never saw
it.

## The boundary was a one-way door, and the hot function is refused for floats

### The defect

`wasm_jit:entry/3` was called only at `Depth =:= 0` (`src/wasm.erl`), and
`wasm_exec` never consulted the code slot. There was no path from the
interpreter into compiled code, so the first refused function or the first
`call_indirect` dropped execution into the interpreter **permanently**, taking
the rest of the program with it including everything that had been compiled.
`entered => 3` across three runs was the fingerprint: one entry per run, never
re-entered.

`wasm.erl` argued against exactly this fix, on the grounds that a test inside
`do_call/4` is the kind of change that has cost 70% on QuickJS three times. It
was right about the risk and wrong about the conclusion. The risk is answered by
measuring the interpreted arm, which is unmoved.

### The fix

`#st.code` names the generated module, and is set only where a call lease is
already held for the whole invocation: `wasm_jit:compiled/3`'s not-compiled
fallback, and `call_out/5`. So no lease is taken per call, no slot can be reused
underneath one, and the tier-off cost is one element comparison on the call path
and nothing at all on the dispatch path. It is cleared when fuel is finite, so
a metered invocation cannot reach compiled code that does not charge fuel.

Generated `invoke/5` takes the caller's **depth** as its fifth argument, where
it used to take a limits map it ignored. Entering at zero from part way down a
call stack would let a recursion go the whole depth budget deeper at every
crossing. `?ABI` goes to 2.

An indirect call whose target is in this instance and compiled now dispatches
into generated code instead of crossing. The generator writes its own module
name in as a literal, because which module it is was decided at generation time
and a dispatch loop reaches this often enough that an `atomics` read to
rediscover it would be part of the cost being removed.

### It works, completely

| | interpreted calls per run |
| --- | ---: |
| tier off | 23,069 |
| tier on | **1,013** |

**95.6% of calls now reach compiled code**, against none below the outermost
invocation before. Re-entries fell from 20,760 to 11,454 across three runs when
indirect dispatch landed, which is the same thing seen from the other side:
an indirect call that used to cross and then re-enter now goes straight there.

### And it buys nothing, for a reason worth having

| qjs, fresh process per run | run 2 | run 3 |
| --- | ---: | ---: |
| tier off | 1798 ms | 1773 ms |
| tier on | 1909 ms | 1772 ms |

Tier-off makes 23,069 calls in 1773 ms. Tier-on makes 1,013 and takes the same
time. **Those 1,013 calls therefore carry essentially the whole run**, and every
one of them is a function the generator refused:

| func | calls | share of what is left | refused for |
| ---: | ---: | ---: | --- |
| 120 | 554 | 54.7% | `f64_convert_i32_u` |
| 54 | 121 | 11.9% | `f64_convert_i32_u` |
| 215 | 60 | 5.9% | `f64_convert_i64_s` |
| 545 | 59 | 5.8% | `f64_load` |
| 580 | 57 | 5.6% | `v128_const` |

JavaScript numbers are f64, so QuickJS's bytecode loop converts between integers
and doubles constantly, and **one refused conversion keeps the hottest function
in the module interpreted**. Compiled code runs 95.6% of the calls and 268,000
memory operations a run, which at 21 ns each is 5.6 ms of 1770: it is executing
the cold 95% of the program.

### What this settles

**A static coverage histogram is not a plan.** 83% of QuickJS compiles and it is
worth zero, because the share that matters is time and not functions. That is
what `PERF.md` meant by reading the refusal table as a ceiling, and this is the
first measurement that puts a number on the gap: 83% by function, about 0% by
time.

The next change is **floats**, and specifically the integer-to-double
conversions, not more coverage in general and not the memory path. `load_at` is
ten frames deep and it does not matter yet, because compiled code is not where
the loads are happening. Phase 3 was the wrong next step and this is why the
plan gated it behind measuring re-entry.

## Floats compile, and the tier is still not faster on QuickJS

### The change

Every float operation is in the subset now: arithmetic, comparisons, the
conversions, the reinterprets, `f32`/`f64` loads and stores, and float
constants (an immediate that may be a symbolic infinity or a NaN with a payload,
which `cerl:abstract/1` takes either way). All of them route to
`wasm_num_float` through `wasm_exec:op1/2` and `op2/3`, so the NaN payloads and
symbolic infinities have one implementation and the two paths cannot drift.

**Four are inlined instead**, and only four: `f64.convert_i32_s`,
`convert_i32_u`, `convert_i64_s` and `convert_i64_u`. They are *total*, so they
need none of `wasm_num_float`: `round_to(64, F)` is the identity, the signed
pair is `float/1`, and the unsigned pair is `float/1` of the value masked to its
width. The BEAM keeps a float unboxed inside a function and boxes it at a call
boundary, so calling out for these would allocate on every conversion in the
hottest function of the module. f32 is deliberately not inlined: every f32
result has to be rounded to single precision and Erlang has no native way.

| compilable functions | before | after |
| --- | ---: | ---: |
| Rust plugin | 100.0% | 100.0% |
| QuickJS | 83.0% | **93.0%** |

QuickJS's remaining 117 refusals are SIMD and nothing else.

### It does what it was meant to, and that is not what it looked like

Interpreted *calls* per QuickJS run, with the tier on:

| | interpreted calls |
| --- | ---: |
| tier off | 23,069 |
| two-way boundary | 1,013 |
| plus floats | **204** |

Every one of the 204 is refused for SIMD, and the run takes the same time it
always did: 1782 ms with the tier on against 1760 off.

**Counting calls was measuring the wrong thing, and it said the opposite of the
truth.** Counting the interpreter's dispatch instead, by call-count tracing on
`wasm_exec:run/3` rather than by inference:

| | wall | `wasm_exec:run/3` calls |
| --- | ---: | ---: |
| tier off | 2408 ms | 148,803,822 |
| tier on | 67,938 ms | **147,586,565** |

**The interpreter still executes 99.2% of every instruction with the tier on.**
Those 204 remaining entries average about 720,000 dispatches each: they are
functions entered rarely that loop enormously, which is exactly what a bytecode
interpreter's main loop is. A function entered once and a function entered once
that runs for a second are indistinguishable by call count, and that is the
mistake.

So the functions still interpreted are not the leftovers. **They are the
program.** And they are refused for SIMD.

Compiled code performs 283,000 memory operations a run and about 1.2 million
dispatches worth of work, which is the same 1% seen from two other directions.

### What this settles, again and harder

93% of QuickJS's functions compile and **about 1% of its executed instructions
do**. The gap between a static coverage count and a time-weighted one is not a
correction of a few points, it is two orders of magnitude, and it has now
mis-directed this plan twice: once into the memory path and once into believing
floats had finished the job.

**SIMD is not worth "about 4 points". It is worth essentially all of QuickJS**,
because one `v128.const` in the bytecode interpreter keeps the whole loop out of
compiled code, exactly as one `f64.convert_i32_u` did one level above it.

### The benchmark is sound, which had to be checked

Three defects have been found in this arm already, so before concluding anything
about the tier, whether it measures its workload at all:

| JavaScript iterations | run 1 | run 2 |
| ---: | ---: | ---: |
| 0 | 366 ms | 61 ms |
| 1000 | 116 ms | 116 ms |
| 30,000 | 1668 ms | 1664 ms |
| 300,000 | 16,751 ms | 16,892 ms |

It scales: 55.6 microseconds per JavaScript iteration, with startup at about
60 ms. The loop is the workload and the arm measures it.

### Ruling out the generator, which was the wrong suspect

Before blaming the generated code, three shapes were measured against the
interpreter on synthetic modules built for the purpose. A bytecode dispatch
loop, which is what QuickJS is and what `loop.wasm` is not:

| arms | locals | interpreted | compiled | ratio |
| ---: | ---: | ---: | ---: | ---: |
| 4 | 0 | 134.3 ns | 3.8 ns | 35.1x |
| 64 | 0 | 658.1 ns | 3.9 ns | 170.1x |
| 256 | 0 | 2305.3 ns | 4.4 ns | 519.4x |
| 256 | 64 | 2407.3 ns | 10.2 ns | 236.9x |

And with the work inside each arm grown, so the generated module grows while the
interpreted work per dispatch grows with it:

| instructions per arm | interpreted | compiled | ratio |
| ---: | ---: | ---: | ---: |
| 1 | 2365.8 ns | 10.0 ns | 235.7x |
| 32 | 3288.9 ns | 34.8 ns | 94.5x |
| 128 | 6912.0 ns | 134.2 ns | 51.5x |
| 512 | 18,374.3 ns | 530.6 ns | 34.6x |

**The generator handles this shape well.** A 256-arm dispatch with 64 locals runs
at 10 ns against the interpreter's 2400, and it is still 35x ahead at 131,000
instructions in a function. Neither the dispatch shape, nor the operand count,
nor code size explains QuickJS. Nothing was wrong with the generated code; it
simply was not running.

### A real cost, but not this one: the frame convention

Every control frame the generator emits is a Core function taking the locals and
the live operands as arguments, so a loop back edge copies all of them. The same
counted loop, with dead-but-live locals added:

| extra locals | interpreted | compiled | ratio |
| ---: | ---: | ---: | ---: |
| 0 | 40.4 ns | **3.4 ns** | 11.8x |
| 8 | 38.8 ns | 3.5 ns | 11.2x |
| 24 | 48.0 ns | 3.9 ns | 12.2x |
| 48 | 60.4 ns | 6.7 ns | 9.1x |
| 72 | 60.5 ns | 9.5 ns | 6.3x |
| 120 | 69.7 ns | **15.6 ns** | 4.5x |

**Compiled code is 4.6x slower at 120 locals than at none**, and its advantage
falls from 11.8x to 4.5x. `bench/paths/subset.erl` measured QuickJS's worst
function at 71 locals and 257 nesting levels, against `loop.wasm`'s three and
two, which is why the synthetic loop reports 12x and the real module reports 1x.

This is a real cost and a real lever, and it is **not** the explanation for
QuickJS: the dispatch table above shows compiled code winning by 35x to 237x on
the shape QuickJS actually has. It is worth having for its own sake and it is
not the next thing to do.

### What to do about it

Not next. SIMD is next, and for the reason above. When the frame convention does
come up, the question is whether locals have to be arguments at all. The alternative is the one the interpreter already
uses and that the bounded operand cache was built on: keep a bounded number in
arguments and spill the rest, so a branch copies a fixed small number rather than
all of them. `PERF.md` records that Erlang caps arity at 255 and real functions
exceed that in locals alone, so a version that passed everything was never
available; what this table says is that passing everything is not merely
unavailable at the top end, it is already the dominant cost at 48.

## SIMD, and the tier finally pays: 9.0x on QuickJS

The whole vector set, as a handful of generator clauses. Every vector
instruction was already shape-tagged by `wasm_instance:ir_instr/2` into
`simd_unary`, `simd_binary`, `simd_shift`, `simd_splat`, `simd_ternary`,
`simd_lane`, `simd_replace`, the four memory forms, `i8x16_shuffle` and
`v128_const`, so thirteen clauses cover the 240 opcodes the proposal lists. The
pure ones call `wasm_simd` directly, which is the function the interpreter
calls; the four that touch memory go through `wasm_exec` so the address width
and the bounds check keep one definition, and the interpreter's own clauses were
rewritten onto the same helpers.

| compilable functions | before | after |
| --- | ---: | ---: |
| Rust plugin | 100.0% | 100.0% |
| QuickJS | 93.0% | **100.0%** |

### The gate that matters

Coverage has mis-directed this plan twice, so the gate is the interpreter's
dispatch count:

| | wall | `wasm_exec:run/3` calls |
| --- | ---: | ---: |
| tier off | 2138 ms | 148,803,822 |
| tier on | (compiling) | **0** |

**Zero.** The interpreter executes not one instruction. And the steady state,
fresh process per run:

| qjs | run 1 | run 2 | run 3 |
| --- | ---: | ---: | ---: |
| tier off | 2045 ms | 1769 ms | 1796 ms |
| tier on | 107,650 ms (compiling) | **202 ms** | **196 ms** |

**9.0x**, with `reentered => 0` and `compiled => 1666`. This is the first time
the tier has moved a real module at all.

`bench/cross/loop.wasm` is unmoved at 2.51 ns/iteration, and the plugin arm is
flat at 535 to 587 microseconds either way, which is what it has always been:
that arm instantiates and destroys per iteration and is dominated by it.

### What the sequence says

Four changes, each of which looked finished and was not:

| | QuickJS functions | QuickJS execution | wall |
| --- | ---: | ---: | ---: |
| one-way boundary | 83% | ~0% | 1.0x |
| two-way boundary | 83% | ~1% | 1.0x |
| plus floats | 93% | ~1% | 1.0x |
| plus SIMD | **100%** | **100%** | **9.0x** |

Coverage moved 83, 83, 93, 100 and bought nothing until the last step. **The
tier was worth zero at 93% and 9x at 100%**, because a single unsupported
instruction anywhere in the hot function keeps that whole function interpreted,
and a bytecode interpreter is one function. There is no partial credit on a
module whose execution is concentrated the way a language runtime's is.

That is the argument for finishing a subset rather than growing it, and it is
not visible in any static count. It also retires the reading of
`bench/paths/subset.erl` that started all of this: floats and SIMD were "under a
percentage point" and "about four points" of QuickJS by function, and between
them they were the entire thing.

### What is now the cost

Compiling 1666 functions, paid once per module and inside the first call. That
is the remaining defect and it is `wasm_jit`'s, not the generator's.

**The OTP compiler's passes, priced on the real module:**

| options | compile | BEAM | steady state |
| --- | ---: | ---: | ---: |
| default | 119.9 s | 14.7 MB | 141 ms |
| `no_ssa_opt` | **45.9 s** | 15.4 MB | 155 ms |
| `no_ssa_opt` + type, bsm, postopt | 42.1 s | 15.8 MB | 154 ms |

**The SSA optimiser is 74 of the 120 seconds and buys 10% of run time.** While
compilation happens inside the first call that trade is obviously wrong, so
`baseline` is the default and `#{compile_quality => full}` asks for the other
one. It is the same reason V8 ships Liftoff and Wasmtime ships Winch: the first
thing a tier owes you is not to be slower than interpreting. The other three
passes together were worth a further 3.8 seconds and are left on.

Measured end to end, that is **107.6 seconds down to 46.5**, with the steady
state unmoved at 196 to 198 ms against 1850 to 2098 interpreted.

### And compilation moved off the call

A call no longer waits for it. What an embedder sees now, `compile_after => 1`
so the very first call triggers it:

| | wall | compiled code |
| --- | ---: | --- |
| call 1 | 1971 ms | not yet |
| calls 2 to 6 | 1724 to 1829 ms | not yet |
| (background compile) | 35.3 s | |
| warm call | **146 ms** | in use |

Every call runs at interpreter speed until the module is ready and then drops to
compiled speed. **Nothing is ever slower than interpreting**, which is the
property the tier lacked and the one that decides whether it can be on by
default.

The process that does the work also *owns* the slot reservation. That is what
makes it safe rather than merely asynchronous: if it dies the reservation dies
with it, and the generation token in `publish/1` already stops a compiler slow
enough to be overtaken from publishing over whatever replaced it. A caller could
not own it, because a caller returns long before the compile finishes and would
take the reservation with it. Nothing bounds the number of compilers except the
sixteen slots, which is the bound that matters: the seventeenth interprets.

An instance is asked for once, not once per hot call, through a third counter in
the `atomics` array it already carries. Asking copies the instance to the
process that will do the work, and on QuickJS that is 35 MB.

`wasm_jit:await/2` blocks until an instance will run compiled, for tests and for
embedders warming an instance before serving with it. `#{compile_sync => true}`
keeps the old behaviour for callers that would rather wait than measure
something half compiled.

### And it compiles what ran, not what exists

Which functions a workload uses is already recorded, for free and for a
different reason: a body is lowered on first call and the indices are kept so
that releasing the instance erases exactly those. Reading that record answers
"what does this workload run" without counting anything on the call path, where
a per-function counter would cost every call.

**QuickJS is 1666 functions and the workload reaches 223.** A function left out
is not a correctness question: `invoke/5` answers `not_compiled` and it is
interpreted, and since the boundary became two-way it can still call back in.
For this workload nothing is left out that matters, and `reentered => 0` says
so.

The record is read at the **end** of an invocation, and that is the whole point.
At the start it is empty, so an instance asking then compiles all 1666 because
it cannot yet know that 223 is the answer. Adopting stays at the start, because
an instance that waited until the end of its first call to adopt a module
somebody else already built would interpret that call for nothing, and for a
workload of one call per instance that means interpreting always.

### Two regressions this caused, and what they taught

**The plugin arm went from 684 microseconds to 64,386.** Adopting was written as
`claim_loading` followed by `abort` when nothing was resident, which is two
gen_server round trips on every hot call, and `compile_after => 1` makes every
call hot. On a three-microsecond call that is 320 microseconds of overhead.
Reading first with a match spec over sixteen rows and claiming only when
something is there fixes it.

**`bench/cross/loop.wasm` went from 2.51 nanoseconds an iteration to 4.66**, and
this one changed a decision. `no_ssa_opt` was measured at 10% on QuickJS and
adopted as the default on that basis. It costs **86% on tight arithmetic**,
which is what the SSA optimiser is actually for; 10% is what a bytecode
interpreter's dispatch loop happens to lose. So `full` is the default again, and
it is affordable now for the two reasons this section is about: nobody waits for
it, and it runs over 223 functions rather than 1666.

### Where it ends up

| | |
| --- | ---: |
| functions compiled | **223** of 1666 |
| background compile | **22.6 s**, at full optimisation |
| calls while it compiles | 1.7 to 2.0 s, interpreter speed |
| warm call | **150 ms** |

And under the benchmark protocol, warmed:

| qjs | run 1 | run 2 | run 3 |
| --- | ---: | ---: | ---: |
| tier off | 1922 ms | 2011 ms | 1924 ms |
| tier on | **223 ms** | **226 ms** | **217 ms** |

**8.8x**, against 107.6 seconds of blocking compilation four commits ago.
`loop.wasm` is unmoved at 2.77 ns/iteration and the plugin arm is flat at 687
against 702 microseconds, which is what it has always been.

### What is left

**One shot, and honestly so.** A function that becomes hot after the module is
built is never compiled, because there is one slot per module and no mapping
from a function to a shard. A workload with phases would want more than this.
Multiple shards per module is the change, and it is not urgent: nothing waits,
and what is compiled is already what ran.

## What linear memory costs, and the floor underneath it

With the tier running the whole of QuickJS, the memory path is back on the table
for the first time: it was 0.3% of a run when compiled code executed 1% of the
program, and it is now about a fifth of one. **1.9 million memory operations per
QuickJS run.**

Priced directly, in a tight loop, so the numbers are the path and not the
workload around it:

| | ns |
| --- | ---: |
| `atomics:get/2` alone | 5.14 |
| `atomics:put/3` alone | 6.13 |
| **`atomics` get then put, same word** | **19.13** |
| aligned 8-byte load, `wasm_memory` | 11.19 |
| i32 load, `wasm_memory` | 14.56 |
| i32 load, through `wasm_exec:load_at/5` | 21.26 |
| i32 store, `wasm_memory` | 33.33 |
| i32 store, through `wasm_exec:store_at/6` | 37.77 |

And in generated code, measured as the difference between the same counted loop
with and without one store and one load: **72.1 nanoseconds for the pair**,
against 3.29 for the loop itself.

### The floor

A four-byte store into a 64-bit `atomics` word is a read-modify-write, and
**get-then-put on one word costs 19.13 nanoseconds**, far more than the 11.3 the
two operations cost separately: the read-after-write dependency and the
barriers are most of it. That is the floor for a narrow store, and it is a
property of backing linear memory with `atomics` rather than of any code in this
project. An aligned 8-byte store escapes it, because `write/4` writes the word
whole; a 32-bit one cannot, because `atomics` arrays are 64-bit.

So the ceiling on this runtime's memory performance without a NIF is about **5
nanoseconds a load and 19 a store**, against 21.3 and 37.8 when this was
measured. The gap is address arithmetic, masking, the bounds check and the
dispatch on the operation.

Part of it needs no coupling at all and is taken below. Re-measured once that
part landed, minimum of five:

| | ns | above the floor under it |
| --- | ---: | ---: |
| `atomics:get` alone | 4.77 | |
| `atomics` get then put, one word | 9.59 | |
| `wasm_memory:load/3` | 13.76 | 9.0 |
| `wasm_exec:load_at/5` | 17.55 | 3.8 |
| `wasm_memory:store/4` | 32.67 | 23.1 |
| `wasm_exec:store_at/6` | 34.59 | 1.9 |

The wrapper is nearly gone: 3.8 nanoseconds on a load and 1.9 on a store. **What
is left is inside `wasm_memory`, and it is mostly the store**: 23 nanoseconds
above the read-modify-write floor, against 9 on a load. The bounds check, the
chunk index and the shift and mask account for it, and generating them inline
would be worth roughly 12% of a compiled QuickJS run, most of that on stores.

That is the coupled part, and it is a decision rather than a task for two
reasons.

It needs the generator to index `#mem{}`, which is a silent breakage waiting for
the next field: the way to make it defensible is a header of field indices
beside the record and a test asserting they agree, so a field addition fails a
test rather than corrupting memory.

And it needs the memory handle hoisted out of the loop to be worth much, which
needs invalidating it wherever the chunk tuple can change: `memory.grow` and any
call, since a callee can grow. That is ordinary compiler work and it is also
exactly the shape of change this project has got wrong four times by trusting a
synthetic loop over a real module.

### Done, and what it was worth

A load or a store is generated inline now, and **only the ordinary case**:
a private memory, so the page count and chunk tuple are in the handle rather
than published in a cell; the access in bounds; and the access not straddling
two 64-bit words. Anything else calls `wasm_exec`, which is unchanged and stays
the only path that can trap. That is what bounds the risk: the inline path
cannot reach a trap, cannot see a growing memory, and cannot handle a straddle,
and the guard is what says so.

The coupling is made loud rather than avoided. `include/wasm_memory.hrl` holds
the field indices, `wasm_memory:field_indices/0` answers the real ones, and
`wasm_core_SUITE` asserts they agree, so adding a field to `#mem{}` fails a test
instead of reading the wrong word.

One store plus one load in compiled code, five interleaved pairs on a box at
load average 39 to 104:

| pair | calling | inline |
| ---: | ---: | ---: |
| 1 | 73.24 ns | 62.61 ns |
| 2 | 106.52 | 71.06 |
| 3 | 168.11 | 60.27 |
| 4 | 62.24 | **35.17** |
| 5 | 62.36 | 46.42 |

**Inline wins all five.** Minimum of each arm, which is the statistic that
survives a loaded machine, is 62.24 against 35.17: **43% off a store and a
load**, or about 27 nanoseconds a pair. On the roughly 950,000 pairs a QuickJS
run performs that is about 26 milliseconds of 195, which is the 12% this section
predicted before it was written.

The noise floor deserves saying. The `arith` arm of the same benchmark contains
no memory access at all and so is untouched by the change, and it moved between
3.24 and 6.53 nanoseconds across these runs: about 35%. A single pair proves
nothing here. Five pairs agreeing in direction, and a minimum that moves by more
than the noise, is what the claim rests on.

### What was free of the coupling too

The 6.2 nanoseconds between `wasm_memory:load/3` and `wasm_exec:load_at/5` is
not part of the coupled prize. It is `load_spec/1` and its tuple match, a remote
call to `wasm_num:to_u32/1`, and the offset addition, and **the generator knows
every one of those answers when it emits the call**: the operation is a literal
at the call site, so its width and signedness follow, and the offset is an
immediate.

So the generator consults the table at generation time and emits the address
arithmetic as Core, and the wrapper takes a settled width, kind and address.
`wasm_exec:load_spec/1` is exported for the generator to read rather than copied
into it, so a width can still only be wrong in one place, and masking to the
width replaces `to_u32/1`: the same answer on a value already in range, which an
operand of this subset always is.

Interleaved, minimum of five, on a box at load average 12.9 which inflates every
absolute by about twice:

| | old | new |
| --- | ---: | ---: |
| load | 43.24, 42.28 ns | 39.87, 32.48 ns |
| store | 81.99, 83.81 ns | 74.60, 72.60 ns |

**15% off a load and 11% off a store**, which is about three and four
nanoseconds at the uninflated scale, or roughly 3% of a compiled QuickJS run.

The workload measurement could not resolve that: the same box gave 189, 200,
447, 507 and 573 milliseconds for the same arm within a few minutes. Measuring
what changed rather than what contains it is the answer to a loaded machine, and
the per-operation number is the honest one to quote here.

### What was free

`wasm_memory` inlined `size_pages/1` and `chunk/2` and nothing else, so
`mask/1`, `word/2`, `put_word/3`, `check_bounds/3`, `read/3` and `write/4` were
all calls on the hot path. Inlining them is a one-line change and worth **7% of
a load** (15.3 and 15.5 nanoseconds against 14.1 and 14.4, interleaved), and
about nothing on a store, where the read-modify-write dominates. Both paths get
it, since the interpreter calls the same functions.

## Closing over locals instead of passing them: reverted

Every control frame the generator emits takes all of the function's locals as
arguments, so a branch or a loop back edge copies all of them. A local only
needs to be a *parameter* if the frame's body might `local.set` it; otherwise
the binding is unchanged and Core can close over it, which is the treatment an
operand below the frame's base already gets. Passing only the reassigned ones is
a small, obviously-correct change, and the conformance suite and the
differential cases all pass with it.

On the synthetic loops it is dramatic. The same counted loop with dead locals
added:

| extra locals | compiled, before | compiled, after |
| ---: | ---: | ---: |
| 0 | 3.4 ns | 3.5 ns |
| 48 | 6.7 ns | 4.1 ns |
| 120 | **15.6 ns** | **3.4 ns** |

The scaling with local count disappears completely, and the advantage over the
interpreter at 120 locals goes from 4.5x to 20.6x. A 256-arm dispatch loop with
64 locals goes from 10.2 nanoseconds an iteration to 4.9.

**On QuickJS it is 2.7% slower.** Five interleaved pairs, run 2 and run 3 of
each:

| | ms |
| --- | --- |
| before | 194.8, 193.4, 197.2, 199.0, 200.0, 200.2 |
| after | 202.6, 203.5, 202.2, 204.4, 201.6, 202.1 |

### Why, and why the synthetic lied

What the change really does is move locals from a continuation's *parameters* to
its *free variables*. A `letrec` function with free variables is a closure, and
building one costs an allocation proportional to how many it captures. A frame
entered once amortises that to nothing, which is every one of these synthetic
loops. A frame entered constantly pays it every time, and QuickJS's hot function
nests 257 deep.

The synthetic's win is not even the win it appears to be. Its extra locals are
written before the loop and read after it, so they are genuinely live across it:
a real liveness analysis would pass them too. What made them cheap was becoming
free variables of a closure created once, not becoming unnecessary.

So there is no free lunch in this direction. Parameters cost per branch; free
variables cost per frame entry; which is cheaper depends on the ratio, and on
real compiler output with deep nesting it is parameters.

**This is the fourth change in this project that was obviously better on
`bench/cross/loop.wasm` and worse on QuickJS**, after `frame_at/2` and two
others that cost about 70%. This one costs 2.7%, and it is the first where the
mechanism is understood rather than merely measured. The rule stands: the
synthetic loop is never the last word.

## The lifetime gate, and the defect it found

Before the tier could reasonably be on by default, one gate item was unmet:
atom-slot, code-lifetime and killed-process handling verified under load.
`test/wasm_jit_lifetime_SUITE` is that verification, and writing it found a real
defect on the first run.

### A killed caller pinned its slot for ever

A call lease is taken around every entry into generated code and given back in
an `after`. **An `after` does not run when a process is killed untrappably**, and
`exit(Pid, kill)` is how an embedder stops a runaway invocation on this runtime:
there is no interruption check on a compiled loop, deliberately, because a check
on every back edge costs what compiling the loop bought.

So the lease counter is permanently incremented, and `reusable/1` claimed a slot
with `compare_exchange(counter, 0, ?EXCL)`, which from a non-zero counter fails
for ever. **Sixteen killed callers, one per slot, and nothing could be compiled
again for the life of the node.**

The test that finds it has to pin **every** slot. One pinned slot proves nothing,
because the next module simply takes a different one; the first version of this
case passed with and without a fix for exactly that reason.

### The obvious repair is unsound, and the existing suite said so

Asking `code:soft_purge/1` whether anybody is really inside, and treating it as
the authority when the counter disagrees, looks right and is not.
`wasm_code_slots_SUITE` has a case that takes a call lease without running any
code and asserts the slot cannot then be claimed, and that case fails.

It is describing a real window. `wasm_jit:compiled/3` takes the lease and *then*
calls `Mod:invoke`, and in between the process holds a lease but is not yet in
the code. Reuse there means the caller invokes the new module with the old
module's function index: **the wrong function runs**, and answers rather than
failing.

`soft_purge/1` is worse than merely blind to that window. It purges code already
marked *old*, so with nothing old it answers `true` whoever is running the
current code. It was never evidence that nobody is inside, and a second test
written to assert the converse failed for exactly that reason.

### The fix: check the generation in the callee

Stop trying to exclude reuse. Generated code carries the **slot generation** it
was built for and compares it with the one its caller was promised when it took
its lease, which is atomic with the call in a way no lease can be. A caller that
was overtaken holds an older generation and is answered `stale`, which means
interpret.

The generation and not the module's identity, because an identity may be a
`reference()` and a reference is not a literal. A generation is an integer that
only increases for a slot.

`invoke/5` becomes `invoke/6` and `?ABI` goes to 3. The name and the generation
travel as literals wherever generated code needs them, so `call_out/7` and
`indirect_out/9` cost no lookup: the caller *is* the generated module and knew
both when it was built.

Then the counter stops carrying correctness. It becomes a hint about whether a
slot is busy, a leaked one is harmless, and `take_exclusive/1` repairs a stuck
one so a killed caller costs nothing. **`bench/paths/realbench.erl` measures
198 to 204 ms on QuickJS with the check in, which is where it was without it.**

### What the suite covers

| | |
| --- | --- |
| a compiler killed mid-flight | leaves no slot reserved |
| the instance destroyed while it compiles | harmless |
| a caller killed inside generated code | slot still usable |
| every slot pinned by a leaked lease | still recovers |
| 24 processes compiling at once | all answer identically |
| more modules than slots | the ones that miss interpret, and answer |
| a metered invocation | never reaches generated code |

The last one is the resource-control answer, and it is a refusal rather than a
mechanism. Fuel is charged at every loop back edge, and charging it round a
compiled loop gives back what compiling it bought, so a metered invocation is
interpreted outright. That holds even for an instance whose module is already
compiled and adopted, and it is per invocation: the same instance called without
a limit is compiled again.

**Cancellation is killing the process**, which is what BEAM is for and why
compiled code carries no epoch or deadline check. That is now a tested property
rather than an assumption, and the defect above is what it costs to make it
true.

## The gate on the tier, item by item

| gate | |
| --- | --- |
| stable QuickJS measurement | met: fresh process per run, `matrix.erl` |
| no synchronous compilation pause | met: nothing waits, `wasm_jit:after_call/2` |
| at least 1.5x steady state on QuickJS | met: **8.4x** |
| no plugin regression | met: 687 against 702 microseconds |
| no interpreter regression | met: `loop.wasm` 2.57 ns/iteration |
| bounded compilation memory and BEAM size | met: 223 functions of 1666 |
| forced-compiled conformance green | met |
| lifetime handling under load | met: `wasm_jit_lifetime_SUITE`, and it found a defect that is now fixed |

**Every item is met.** 8.4x on QuickJS, nothing waiting on compilation, no
regression on the plugin or the interpreter, conformance green with the tier
forced, 223 functions compiled of 1666, and a killed caller no longer costs a
slot.

Turning `compile => true` on by default is now a decision about defaults rather
than about readiness, and it is left as one: it changes what an embedder gets
without asking, it spends a core for twenty-odd seconds per module, and the
workloads that gain are the ones running a real language runtime rather than a
plugin. `bench/paths/tiered.erl` is the instrument for deciding it on a workload
of your own.

## Should the tier be on by default? No, and the plugin says why

Every gate item is met, so the question is now about defaults rather than
readiness, and the measurements answer it.

| workload | tier off | tier on | what compiling costs |
| --- | ---: | ---: | ---: |
| QuickJS | ~1800 ms | **~200 ms** | 223 functions, ~22 s of a core |
| Rust plugin | 687 us | 702 us | 150 functions, seconds of a core |

**The tier is 8.4x on a language runtime and nothing on a plugin**, and a default
cannot tell which it has. Turning it on would spend tens of seconds of a core
per module on a guess, and for the plugin shape the guess is wrong: two hundred
calls of three microseconds do not repay it, and the arm is flat.

So `compile => true` stays opt-in. That is not a gate failing; it is the gate
passing and the answer still being no. What an embedder needs instead is the
means to decide, which is `bench/paths/tiered.erl` on their own module: if the
interpreter's dispatch count goes to nearly zero and the module is long-lived,
turn it on.

The default that *would* be defensible is a policy this runtime does not have:
compile when a module has been called enough times to have repaid the cost.
`compile_after` is a count and not a budget, and making it one means measuring
what a compile cost and what a call saves, per module. That is a real design and
it is not this.

## Compiled code, cached: 43.7 seconds to 0.2

Compiling a module is off the calling process and nothing waits for it, so it
was never a latency problem. It was still twenty to forty seconds of a core
every time a node started. On disk it is paid once.

| | wall | |
| --- | ---: | --- |
| cold | **43.7 s** | 149 functions compiled |
| after a restart | **0.2 s** | answered from the cache |

The restart is simulated by throwing the slots away, which is what a fresh node
has: no resident code and no memory of having compiled anything. The artifact is
4.7 MB and survives it.

### What had to change first

An artifact used to bake in the **slot generation**, which increments on every
claim, so a cached one could never be valid. Generated code is built for the
module's **content hash** now, which is what the check wanted to say all along
-- "am I the code for the module you meant" -- and is stable across loads and
across nodes. The generation remains the fallback for a module identified by a
`reference()`, which is every module built from text; those are never cached, so
nothing is lost.

That change caught a bug the moment it was tested. `cerl:abstract/1` on a binary
produces a *constructed* binary, which cannot be a Core pattern, so matching on
one made every module with a content hash fail to compile. Comparing with `=:=`
works for a binary and an integer alike. It had passed until then only because
every earlier test used a text module, whose stamp is an integer.

### Slot affinity

A module's name is part of its BEAM file, so a cached artifact is only usable in
the slot it was compiled for. Slots are handed out by preference now: a module's
home slot is `phash2` of its key, and any free slot will still do. Without it a
cache hit would depend on which slot happened to be free at the time.

Two cases in `wasm_code_slots_SUITE` were asserting the pool is handed out in
order and had to be told which key they meant. That is the affinity working, not
a regression.

### What it does not do

No sharing between nodes, no signature, no compression, and **off unless a
directory is configured**:

```erlang
application:set_env(wasm, code_cache_dir, "/var/cache/my_app/wasm").
```

Reading a `.beam` from disk and loading it is executing whatever is in that
file, so that directory is as trusted as the code in the release. Wasmtime's
cache is opt-in for the same reason.

The key covers everything that would make an artifact wrong: the content hash,
the ABI between generated code and `wasm_exec`, the OTP release, the emulator
flavour, the architecture, the compile quality, the set of functions compiled,
and the slot. Eviction is by total size, least recently used first.

## The compiled tier: 2.6 ns/iteration, and what the safety property cost

The spike is now a tier. `bench/cross/loop.wasm`, one module, instantiated with
and without `#{compile => true}`, minimum of five, same checksum:

| | ns/iteration |
| --- | ---: |
| interpreted | 68.6 |
| compiled | **2.6** |

That is **26x**, and it is the spike's own 2.59 reached through the real path:
`can_compile/2`, the slot transaction, a lease per call, and generated code
loaded into a pooled module name.

### Routing every operation through `wasm_exec` cost 12x

The design said one implementation of every operation, so compiled and
interpreted arithmetic cannot diverge and the conformance suite checks both at
once. Taken literally -- *every* operation a call to `wasm_exec:op2/3` -- that
came out at **30.5 ns/iteration**, better than the interpreter's 68.2 and eleven
times worse than the spike.

So the rule is narrower than "route everything": the **total** operations are
inlined, and everything else keeps the single implementation. Total means it
cannot trap and does not depend on a representation decision -- addition wraps,
division does not. Division, remainder and every conversion still go through
`wasm_exec`, which is where the semantics are actually difficult and where a
second implementation would eventually be wrong.

| | ns/iteration |
| --- | ---: |
| every operation through `wasm_exec` | 30.5 |
| total operations inlined | **2.6** |

The interpreted arm did not move: 68.2 before, 68.6 after.

### Coverage, by the oracle rather than by the analysis

| | before calls | with calls |
| --- | ---: | ---: |
| Rust plugin | 13.3% | **74.0%** |
| QuickJS | 6.1% | **55.1%** |

Nothing at all is refused by a bound on either module, which is what the arity
and nesting measurements predicted. The remainder is `call_indirect`, floats,
SIMD, tables and the GC types, all of which are interpreted.

## The Core Erlang spike: 2.59 ns/iteration

The gate was 10 ns and this clears it by four times. The same loop, the same
checksum at five sizes, compiled from wasm IR to Core Erlang, through
`compile:forms(_, [from_core])` and `code:load_binary/3`:

| runtime | kind | ns/iteration |
| --- | --- | ---: |
| wasmtime | JIT, C | 0.77 |
| node (V8) | JIT, C++ | 1.68 |
| **erlang_wasm, compiled** | **JIT, BEAM** | **2.59** |
| wasm3 | interpreter, C | 4.15 |
| erlang_wasm, interpreted | interpreter, BEAM | 60.54 |

**Compiled BEAM code beats the C interpreter this project has been measured
against all along**, and lands between V8 and wasm3. It is 23x the interpreter
after all of the interpreter work.

868 bytes of BEAM, and `r2` of 0.99999 across five sizes, so it is running the
loop and not being folded away.

### Why it is this fast

Three things, and none of them is code generation:

- **The operand stack does not exist at run time.** It is a compile-time list
  of Core variables and literals. That is what the validator's heights make
  sound and why Phase 1 came first: knowing the stack shape statically is
  exactly what lets the stack be compiled away rather than interpreted.
- **Locals are Core variables, not a tuple.** Core is single-assignment, so a
  `local.set` is a new binding and there is no `setelement` and no record
  update. The bounded cache spent Phase 2 getting locals into arguments; here
  they start there.
- **Every control frame is a Core function taking the locals, and a branch is a
  tail call.** The BEAM already compiles that shape well, which is the whole
  argument for targeting the existing compiler rather than writing a back end.

Wrapping is branch-free: masking to 32 bits, flipping the sign bit and
subtracting it, three BIFs and no test. Values stay signed exactly as the
interpreter holds them, which is why the checksums match rather than merely
looking plausible.

### What it does not do, which is nearly everything

The spike is `bench/paths/corespike.erl` and it lives in `bench/` deliberately.
It loads one literal, pre-interned module name, once, and never unloads or
purges. No user input reaches a generated name. It covers blocks and loops with
no label operands and the i32 arithmetic the loop uses, and raises
`{unsupported, Instr}` on anything else rather than skipping it quietly.

Absent, and each one is a materially different path in the interpreter today:
compiled-to-interpreted and interpreted-to-compiled calls, lazily lowered
functions, direct calls, `call_indirect`, `call_ref`, tail calls, calls into a
foreign instance, host calls, traps, fuel, host re-entry, exceptions, store
mutation and checkpointing, memory, and code-slot reuse.

**So this says the direction is worth a project. It does not say anything here
is landable**, and the lifetime work that would make generated code safe is a
phase of its own that has not started.

### The subset that spike covers is 0.02% of QuickJS

`bench/paths/subset.erl` walks the lowered IR of every function in a module and
sorts each instruction into a category, so that "a compiler supporting these
categories can take these functions" is a count rather than a guess. Run on
QuickJS and on the Rust plugin, by share of instructions:

| compiler supports | qjs funcs | qjs instrs | plugin funcs | plugin instrs |
| --- | ---: | ---: | ---: | ---: |
| i32, control, locals | 0.5% | 0.02% | 4.7% | 0.04% |
| + i64, div/rem | 1.1% | 0.03% | 4.7% | 0.04% |
| + memory | 8.2% | 2.4% | 16.0% | 22.7% |
| + globals, floats | 10.3% | 3.2% | 16.7% | 22.8% |
| + calls | 94.1% | 73.8% | 100% | 100% |

**This kills the incremental plan I had.** The reasoning was: start with leaf
functions of pure integer arithmetic, where none of the hard boundary cases
arise, and fall back to the interpreter everywhere else. That subset is 8 of
QuickJS's 1666 functions and 107 of its 560,000 instructions. It would have
been several hundred lines to reach a feature that never fires.

So the ordering inverts. **Calls are the first thing a back end needs, not the
last**, and memory is the second: memory alone takes the plugin from nothing to
22.7%. Everything in the absent list above that concerns crossing between
compiled and interpreted code has to work before the first function is worth
compiling.

That makes the next measurement obvious and much cheaper than the project it
decides: **what does a call cost in each direction?** Compiled to interpreted,
interpreted to compiled, against interpreted to interpreted. Real compiler
output is call-heavy, so if crossing costs more than the compiled body saves,
the back end loses on exactly the code it exists for, and no amount of code
generation fixes it.

The remaining 5.9% of QuickJS is SIMD. Neither module uses tables, the GC types
or atomics, so those can wait regardless.

Static counts weight every instruction equally and a loop body is not equal, so
read the table as a ceiling on coverage rather than as a share of run time.

### The boundary costs the same as the interpreter's own call

`bench/paths/callcost.erl` prices the crossing the section above says has to
come first. Inside the interpreter a call is a trampoline through `#st.frames`
with no Erlang frame and no state rebuilt; a compiled function cannot use it,
because its continuation is a Core Erlang frame, and has to make a nested
invocation through `wasm_exec:call/5`. Three passes at load average 4.5:

| | ns per call |
| --- | ---: |
| interpreted call, trampolined | 43.5 to 44.7 |
| nested invocation, the floor | 37.4 to 43.4 |

**Level, which was not the expected answer.** The nested path rebuilds a state
and publishes fuel on return, and still comes out even, because it skips the
`call` dispatch and the operand-stack traffic the trampoline pays instead.

That settles the question the coverage table raised. The boundary is about
40 ns; the body it replaces runs about 25x faster, 68 ns against 2.59. A
compiled function breaks even once its interpreted body would have cost more
than the crossing, which is roughly six instructions, and QuickJS functions
average 336. A compiled function calling a compiled one is an ordinary Erlang
call, and at 94% coverage that is most calls.

Not priced, each of which only adds: the caller's own state threaded into the
crossing, the interpreter's side of an interpreted-to-compiled call, and the
try/catch a trap unwinds through.

## The rule the cache turned out to have: consumers are free, entry points are not

Measured three times now, twice by accident:

| change | QuickJS |
| --- | ---: |
| memory and global **consumers** in the cache | 107.3 to 105.6 ms |
| `lg_load` as an **entry point** | 105.6 to **175.7 ms** |
| the locals threading, which made *leaving* dearer | 106.0 to **179.6 ms** |
| entering on `i64_const` | worth 40% on its own |

A **consumer** fires only when the cache is already holding something, so it
can remove a spill and can never add one. An **entry point** costs every time
the next instruction is one the cache does not hold, and in real compiler
output that is most of the time: a load's result usually feeds a call, a
different load, or an instruction the cache never learned.

The cost is far larger than an extra function call should be, and the same
magnitude every time -- around 70%. The likely mechanism is not arithmetic at
all: `run/3` is roughly two hundred clauses and `run1/4` is another region, and
an entry point that spills immediately makes execution bounce between the two
on nearly every instruction. Whatever the cause, the rule is empirical and
holds:

**Add consumers freely. Measure every entry point on `realbench` before
believing it.**

`{i32_load}` and `{global_get}` in `run1/4` and `{i32_store}` in `run2/5` are
consumers and are landed: -1.6% on QuickJS, the loop unchanged. Modest, because
the cache is rarely holding an address when a load arrives -- most loads come
from the fused `lg_load`, which is in `run/3` and must stay there.

## The synthetic loop lied, and a real module said so

`fb22b06` was -45% on `bench/cross/loop.wat` and **+40% on QuickJS running
JavaScript**. Both numbers are real. The loop is fifteen instructions of i32
arithmetic chosen to be easy to reason about; QuickJS is what clang actually
emits, and the cache holds a minority of the instruction set.

`bench/paths/realbench.erl` exists so that never goes unnoticed again. It runs
a compute-bound script through QuickJS, which is this interpreter running a
JavaScript engine, and it is the arm any interpreter change has to clear.

Interleaved, minimum of two, load average 6:

| | QuickJS, 300k JS iterations | loop, ns/iteration |
| --- | ---: | ---: |
| `16ded2c`, no cache | 131.5 ms | 107.5 |
| `73ccf16`, K=2 and lookahead | 106.6 ms | 65.2 |
| `fb22b06`, locals threaded | **179.6 ms** | **58.5** |
| landed here | 106.0 ms | 69.1 |

### What went wrong, and it is not what it looked like

The first suspicion was the guard chain: with i64 in, run1 walked forty-two
atom comparisons before the fallback. Replacing it with one type test and a
jump table on the atom changed nothing measurable. Recorded because it was
wrong and the code kept the jump table anyway, which is the better shape.

The second was the cache *entry* points, and that one is half right. Entering
on `i64_const` was worth 40% on its own in one configuration -- QuickJS is full
of i64 constants followed by loads, stores and calls, none of which the cache
holds, so each one entered and immediately paid an extra call to spill itself
back. That entry point is gone.

The cause in `fb22b06` is the locals threading. It made the family cheap to
*stay in* and more expensive to *leave*: every exit through `runl` or a branch
writes the locals back, an update that did not exist before. The loop stays
inside for fifteen instructions and pays once; QuickJS enters and leaves
constantly and pays every time. **So it is reverted**, and the loop gives back
9 ns for QuickJS getting 74 ms.

### What is landed

The cache with two operand slots, the constant lookahead, i64 through a jump
table, and the loop back edge that allocates nothing. **-19% on QuickJS and
-36% on the loop**, with `call-fac-10` 1213 to 1186 ns.

The locals threading is not wrong, it is mis-sited: locals belong in arguments,
and the Core Erlang spike gets that for free because Core is single-assignment.
Doing it in the interpreter means paying at every boundary, and real code is
mostly boundaries.

## The bounded operand cache

The largest win in this project, and the first that came from a named technique
rather than from a profile: **-45% off the loop**, on the same size ladder both
sides, top size 10,000,000, checksums equal.

| | ns/iteration |
| --- | ---: |
| `16ded2c` | 109.46 |
| bounded cache | **60.01** |

Under the cross-runtime protocol this runtime goes from 115.58 to 60.54 ns and
the gap to wasm3 from **28x to 15x**. Calls got faster too: `call-fac-10` 1249
to 1139 ns.

### What the cost actually was

Not the cons cell, which is two words. **The record update.**
`St#st{stack = [V | S]}` copies a nine-field record, ten words, and every
instruction that touched the stack or a local did one. Counting dispatches had
already said the same thing from the other side: `fc183c1` removed 6.25% of the
dispatches and bought 2.5% of the time, so the time was in what a dispatch
does, not in reaching it.

The top one or two operands, and the locals tuple, now live in arguments.
`run/3` is unchanged and remains the spill area; `runl/4`, `run1/5` and
`run2/6` hold zero, one and two operands with the locals threaded alongside.
While any of them is running, `#st.locals` is stale and the argument is
authoritative; every way out writes it back. Anything not in their clause lists
spills and hands back, which is what made this landable a piece at a time
rather than all at once.

This is wasm3's technique and deliberately not more of it. wasm3 caches one
integer and one float register in its calling convention, not the whole stack;
Erlang caps arity at 255 and real functions exceed that in locals alone, so the
version that passed everything was never available to copy.

### What each piece was worth

| | ns/iteration | against base |
| --- | ---: | ---: |
| `16ded2c` | 99.93 | — |
| K=1 | 87.77 | -12.2% |
| K=2 | 76.08 | -23.9% |
| plus constant lookahead | 65.22 | -34.7% |

(Top size 1,000,000 for those four; the later rows were measured at 10,000,000,
which is why the absolute numbers differ. The comparison within a column is
what matters.)

The plan asked for K=1 and K=2 separately because one number could not say
whether the second slot earned its place. It does, and it is worth as much as
the first. So is the constant lookahead, which is one clause pair: a constant
feeding an operation is *one* operand and not two, so reading the next
instruction keeps both slots and skips a dispatch. Without it a constant was
what forced the cache to shift, and on this loop that was four of the fifteen
instructions.

The last three took it from -34.7% to -45%:

- **The locals threaded as an argument.** Three of the loop's remaining record
  updates were locals writes, and locals lived in the record.
- **The loop back edge inside the cache.** `branch/3` wrote back a stack it
  already held. The frame's saved tail now appears twice in the head, once
  bound and once as the pattern the stack must match, so a parameterless loop
  with fuel off allocates nothing at all on the edge.
- **`if` taken from the slot.** The condition is exactly what is cached, so
  neither the spill nor the pop on the other side happens.

### The i64 regression, which the call arm caught

The first version handled i32 only, and `call-fac-10` went **+10% slower**.
`fac` is i64: every `local.get` and `i64.const` entered the cache, found no
clause, and paid an extra call to spill itself back. A cache that covers half
the type space is worse than no cache for the other half. With i64 in, the same
arm is 8.8% faster than before any of this.

That is the argument for measuring a path the change was not aimed at. The loop
was 39% faster at the moment calls were 10% slower.

**The gate was 40% and this clears it at 45%.** `call_indirect` and
`call-through-host-import` are unchanged. Conformance and all 332 tests pass.

## The instrument, before any of the numbers

Three ways a measurement here went wrong, all now closed:

- **Two sizes subtracted by hand.** Replaced by five sizes and a least-squares
  slope with r2 reported, in `bench/cross/loop_erl.erl`, plus warmup inside the
  measured process and repeated samples with the spread printed next to each
  minimum.
- **The JIT taken on trust.** `jit = erlang:system_info(emu_flavor)` is now a
  failing match at the top of both cross-runtime entry points. An
  interpreter-only build used to produce numbers nothing questioned.
- **A fusion change that could not be told from a no-op.**
  `bench/paths/fusecount.erl` counts which rules fire by walking the lowered
  IR, never inside a timed run.

`bench/cross/xrun.erl` puts all four runtimes through that one implementation,
each with a size ladder calibrated until it spends 400 ms on iterations. That
last part is not a detail: a ladder sized for this interpreter left node fitting
at r2 `0.11`, which is the fit reporting process spawn instead of the loop.

Re-measured that way, at load average 4.5 to 5.3, three runs, minimum of each:

| runtime | kind | ns/iteration |
| --- | --- | ---: |
| wasmtime | JIT | 0.77 |
| node (V8) | JIT | 1.56 |
| wasm3 | interpreter, C | 4.10 |
| erlang_wasm | interpreter, BEAM | 115.58 |

**28x to the like-for-like arm, not 30x**, and the older figures in this
document were taken the old way. Where one of them is quoted below, it is the
number that was recorded at the time and it is not comparable with these.

## What carrying the stack heights costs, and what it uncovered

The validator now returns each body annotated with the operand-stack height at
every instruction, tagged `{validated, Annotated}` on `#func.body`. Execution,
instantiation and cache hits are untouched, which is the part that had to hold.
Compilation of a large module got **faster**, which was not the expectation.

Interleaved passes against `b9dbacf`, minimum of each, load average 5:

| arm | before | after | change |
| --- | ---: | ---: | ---: |
| `call-fac-10` | 1224 ns | 1206 ns | none |
| `instantiate-qjs-lazy` | 3.04 ms | 2.91 ms | none |
| `load-cache-hit` | 17.6 us | 17.5 us | none |
| `compile-plugin-46k` | 1512 us | 1770 us | +17% |
| `compile-qjs-1.8m` | 282 ms | 162 ms | **-42%** |

The module itself is larger, held once and shared by every instance of it:

| fixture | decoded | validated before | validated after |
| --- | ---: | ---: | ---: |
| `plugin.wasm`, 46 KB | 0.6 MB | 0.6 MB | 0.9 MB |
| `qjs.wasm`, 1.8 MB | 22.3 MB | 22.3 MB | 35.4 MB |

### The annotation cost 16 ms of work and 200 ms of collection

A pair per instruction is three words, and QuickJS has 559,987 of them, so the
annotation is 1.7 M words of new live data grown incrementally in the
validating process, which the collector then copies again at every collection
along the way. Validating the same module in a fresh process each time,
minimum of three:

| heap | before | after |
| --- | ---: | ---: |
| default (233 words) | 27.6 ms | 243.8 ms |
| `min_heap_size` set in place | 28.9 ms | 149.0 ms |
| set in place, then collected | 28.9 ms | 141.2 ms |
| two words per input byte, then collected | — | **55.0 ms** |
| 4 M words at spawn | 34.2 ms | 50.5 ms |
| spawn with 4 M and copy the result home | 89.3 ms | 130.3 ms |

`min_heap_size` takes effect at the next collection, so setting it from inside
the call recovers only a third: by then the thrashing has happened. Collecting
immediately after setting it makes the new size real and recovers three
quarters. Validating elsewhere and copying the answer home costs more than it
saves.

`wasm:compile/1` now sizes the heap that way, at two words per input byte, for
modules above 16 KB. **That is why compiling QuickJS is 42% faster than before
any of this**: the collector was doing the same wasted work on the unannotated
module and nothing had made it visible. The annotation did not cause that
inefficiency, it exposed it.

What is left is +17% on a 46 KB module, where the fixed cost of a collection is
a larger share, and +59% on the module's size in memory. Runtime is unchanged,
which is the order these are traded in.

If the memory is judged too high, the alternative worth trying is a flat one:
keep `{validated, ...}` and the idempotence, but hold the body term unchanged,
shared with the decoded module, beside a binary of heights in pre-order. That
is around 1.1 MB rather than 13.1 MB and allocates no term per instruction. It
is *not* the side structure the plan rejected, which was a second nested
instruction tree that could drift from the first; a flat index derives its
positions from the one tree there is.

## The BEAM is not the limit

The same loop, three ways:

| | ns/iteration |
| --- | ---: |
| Erlang doing the arithmetic directly | **2.6** |
| wasm3 (interpreter, C) | 4.3 |
| erlang_wasm | 131 |

The BEAM computes this loop *faster than wasm3 interprets it*. So none of the
gap is the language or the platform. All of it is interpretation overhead, and
that is the good news: it is ours to remove.

Cost per iteration: **65.4 reductions**, about three BEAM function calls for
every WebAssembly instruction, on a body of roughly 21 instructions.

## What each instruction costs

Marginal cost, measured by building the same loop with K copies of a snippet
and with 2K and taking the difference, so loop overhead cancels:

| snippet | ns per instruction |
| --- | ---: |
| `nop` | **1.43** |
| `i32.const` | 2.6 |
| `local.get` | 2.95 |
| `i32.add` | ~3.3 |
| `f64.add` | 7.9 |
| `local.set` | **~9.25** |
| `i64.add` | ~12 |
| `i32.load` | ~21 |
| `call` (empty function) | 18.1 |
| `i32.ge_u` | **~30** |

`nop` is the floor of the current design: match the list head, tail call, touch
nothing. 1.43 ns times 21 instructions is 30 ns per iteration before any work
happens at all.

## Three things stand out

### 1. Comparisons convert an atom to a string, per comparison

`wasm_exec:int_relop/4` is:

```erlang
int_relop(Op, A, B, W) ->
    case atom_to_list(Op) of
        [_, _, _, _ | "eq"] -> b(A =:= B);
        ...
        [_, _, _, _ | "ge_u"] -> b(u(A, W) >= u(B, W))
    end.
```

Every integer comparison allocates a list from the atom's text and then walks
up to ten string patterns. Measured against the same answers matched on the
atom directly:

| | as written | direct clauses |
| --- | ---: | ---: |
| `i32.ge_u` | 25.3 ns | **5.1 ns** |
| `i32.eq` | 17.1 ns | **2.1 ns** |

Five to eight times, on instructions that appear in every loop bound and every
branch. `int_unop/3` (clz, ctz, popcnt) has the same shape, and so do
`wasm_simd:extend_shape/1` and `extmul_shape/1`.

This is a defect rather than a design trade-off, it is confined to three
functions, and nothing else has to change for it.

### 2. `local.set` copies the locals tuple

At ~9.25 ns it is the third most expensive thing in the table and by far the
most common of the expensive ones. `setelement/3` copies the whole locals
tuple on every set, so the cost grows with the number of locals in the
function, and real compiler output has tens of them.

### 3. Dispatch count, not dispatch cost, is the ceiling

Fusion already exists and already pays. On this loop:

```
fuse => false   157.1 ns/iter
fuse => true    125.3 ns/iter      -20%
```

That is with five superinstructions, none of which fires often here. The set
stops at the producing end (`local.get, i32.const, i32.add`) and never fuses
the consuming end, so `i32.add, local.set` and
`local.get, local.get, i32.add, local.set` stay four dispatches, four record
updates and three cons cells.

## Done: the comparison defect

Fixed. `int_relop/4` and `int_unop/3` match on the opcode atom now, one clause
each, and the compiler turns that into a jump table.

Measured on the cross-runtime loop, three interleaved passes, minimum of each,
with both sides returning the same checksum:

| | ns per iteration |
| --- | ---: |
| before | 148.6 |
| after | **124.8** |

**-16% for a change that touches two functions.** `call-fac-10` moved with it,
1489 to 1249 ns. The gap to wasm3 goes from 34.6x to 29.0x, which is the honest
way to say it: this was free money and there is not much more of it lying
around.

The same defect is still in `wasm_simd:extend_shape/1` and `extmul_shape/1`.
Those are SIMD shape decisions rather than per-instruction dispatch, so they
are worth less, but they are the same three lines.

## Done, and now settled: extending fusion

Four rules added, chosen from 45,810 instructions of real Rust and clang
output rather than from the benchmark loop: `local.get local.get i32.store`
(667 occurrences), `local.get i32.load local.tee` (542), and
`local.get i32.const i32.add` followed by `local.set` (304) or `local.tee`
(253).

Rebuilding that table first was worth it. The candidates guessed from the loop
were `{i32_add, local_set}` and `{lg_lg, i32_add}`, and neither appears in the
top adjacencies of real output at all. What the table showed is that the
valuable extensions are not new pairs but the *consumers* of the rules already
there, which the greedy left-to-right match leaves stranded: a new pair mostly
steals instructions an existing rule already fuses, so a pair's own frequency
says little.

It first measured -1.3% against a threshold of 20%, and what was *not*
established was why: whether the rules fired on the loop at all. The probe
written to check that was wrong and the question was left open.

**It is now answered, by `bench/paths/fusecount.erl`.** That walks the lowered
IR of an instance built with `fuse => true` against one built with
`fuse => false`, so nothing is counted inside a timed run. On the loop, one of
the four fires: `lg_const_add_set` takes the `lg_const_add`, `local.set` pair
the older rules left stranded. On real modules all nine fire, and fusion
removes 22.1% of the dispatches in QuickJS and 24.1% in the Rust plugin.

Re-measured against `54761de` under the Phase 0 protocol, three interleaved
passes, minimum of each:

| | dispatches per loop iteration | ns/iteration |
| --- | ---: | ---: |
| `54761de` | 16 | 111.6 |
| `fc183c1` | 15 | 108.8 |

**So it is a small real win, not a nothing: 6.25% fewer dispatches for 2.5% of
the time.** It stays. The threshold it misses was the right threshold and the
change is kept on the strength of the real-module counts, which is a different
argument from the one the threshold was testing.

The number that matters for what comes next is the ratio. A dispatch removed is
worth about a third of its share of the time, so the remaining two thirds are
in the operand traffic around the dispatch and not in the dispatch itself.
**Peephole fusion cannot reach the interpreter's cost**; every remaining rule
buys the same discounted third. That is the measured case for a bounded
top-of-stack cache, and the measured case against another round of rules.

Correctness is not in question: 324 tests and the conformance suite pass.

## What to do, in order

**~~First, the comparison defect.~~** Done, above. The two `wasm_simd` shape
functions still have it.

**Then, extend fusion through the consuming end.** Add
`{i32_add, local_set}`, `{lg_lg, i32_add}` and the
`local.get local.get <binop> local.set` triple. This loop's 21 instructions
would collapse to roughly 8. Each removed dispatch takes a record update and a
cons cell with it, so the saving is well above the 1.43 ns floor per
instruction. The frequency table in `wasm_instance` was built from real
compiler output and should be rebuilt the same way before choosing the set.

**Then, look again at `i32.load` (21 ns) and `call` (18 ns).** Both are common
in real modules and both are far above the neighbours in the table. Neither has
been investigated yet; they may hold something as simple as the comparison
defect.

**Only then, the structural change.** Stop threading `#st{}` through every
clause and pass the hot fields (stack, locals) as arguments to `run/N`, where
the BEAM keeps them in registers instead of rebuilding a nine-field record per
instruction. This touches most of `wasm_exec`, and the measurements suggest it
is worth 1 to 1.5 ns per instruction rather than the large multiple one might
assume, because allocation on the BEAM is a pointer bump.

## What is honestly reachable

Dispatch alone is 1.43 ns and the body is 21 instructions. Fusion to ~8
instructions at ~3 ns each puts the iteration near 25 ns, which would be **5x
faster than today and about 6x slower than wasm3**. Parity with a C interpreter
is not reachable this way, and would need either a NIF for the dispatch loop,
which the project rejects for good measured reasons, or compilation to BEAM
bytecode, which is a different project.

The comparison defect and the fusion work are worth doing on their own terms.
The rest is a decision about how much of the runtime's shape to spend on it.

## The inline memory path had never run, and what was left underneath it

Measured against wasmtime 47.0.2 and wasm3 on the same box, same bytes, same
checksums, with startup subtracted by timing two values of `n`.

The compiled tier is not uniformly behind. Arithmetic is 3.33 ns an iteration
and a call is 6.3 ns, both **faster than wasm3** (4.8 and 9.2) and 4.6x and 7x
Cranelift. One `i32.store` and one `i32.load` per iteration was 125.9 ns
against wasm3's 4.3. The memory path was the whole gap.

**The fast path was guarded on something no real module satisfies.**
`wasm_core:ordinary/4` required `pages_ref` and `chunks_ref` to be `undefined`,
which is a *private* memory. `wasm_validate:shared_mems/1` publishes a memory
that is imported **or exported**, and every toolchain exports its memory so the
host can read strings out of it. Both fixtures in this repository are
published, so neither had ever taken the path. Call-count tracing: two million
iterations, two million calls to `wasm_exec:load_at/5`.

Dropping the two tests is safe for the reason the slow path already relies on.
`wasm_memory:chunk/2` prefers the handle's own chunk tuple and consults the
published cell only beyond it, because growth appends chunks and never moves
one. In bounds against this handle's own `pages` means covered by this handle's
own `chunks`, whoever grew it since; past that, the bounds test fails and the
helper reads the published count or traps. Staleness is always conservative.

The guard also composed its tests with `erlang:and/2`, which is strict, so all
four ran after the first had failed.

| | ns per store and load |
| --- | ---: |
| before | 125.9 |
| guard fixed, short-circuited | 57.5 |
| aligned splice folded | 48.5 |

Clean numbers without the tracing overhead: 29.0 ns, against wasm3's 3.8. From
about 30x wasm3 on this path to about 7.6x.

### Two that were not worth doing, and why

**Hoisting the memory handle: 1.15 ns.** `PERF.md` had this as the open item
and the estimate was tens of nanoseconds. Hand-written Erlang doing the same
accesses with the handle, `shift` and the byte limit bound once outside the
loop ran at 33.04 ns against 34.19 refetching all of them per access. BeamAsm
compiles `element/2` on a known-size tuple to about one instruction; five of
them are not 30 ns. **Do not do this**: it is an invasive dataflow change to
the generator for three percent.

**One `atomics` slot per i32 is not available.** A 32-bit store into a 64-bit
word is read-modify-write, and the floor for a store and a load is 22.7 ns
against 10.35 for one slot per 32-bit word. It costs 2x the footprint, which
would be arguable, but it is blocked outright: `wasm_memory:update_word/4`
CAS-loops on a whole 64-bit `atomics` element, and that is what makes
`i64.atomic.rmw` atomic. Split across two slots it could not be. The threads
proposal passes 297 assertions today and this would break them.

What the aligned splice recovered instead is 6.3 of that 16 ns at no cost: for
an aligned access `Bit` is 0 or 32, so the keep-mask and the shift are literals
the compiler folds rather than `bsl`, `bnot`, `bsl` at run time.

### What is left on the memory path

A store is 17.8 ns of which 10 is two `atomics` operations, and a load is 6.7
of which 5 is one. The representation is most of what remains, and changing it
is the item above.

## Instantiation and the call boundary, which nobody had measured

With the memory path fixed, the remaining distance to wasmtime turned out not
to be in steady-state execution at all. Instantiation was 317 us for a 46 KB
plugin and 2.0 ms for QuickJS against wasmtime's single-digit microseconds, and
a host call 373 ns against 10 to 20. For the plugin-per-request shape
`docs/worker.md` describes, those two are the whole cost.

Decode and validate, by contrast, is fine: 125 ms for QuickJS's 1.84 MB, which
is roughly what Cranelift takes to compile the same module to machine code.

### A module's functions were built once per instance

`compile_fn/4` reads a `#func{}`, the validation context and an index, and all
three belong to the module: the index counts *declared* function imports, not
the imports an embedder supplied. So nothing in the resulting `#fn{}` differs
between two instances, and instantiation was lowering every body again. eprof
put `ir/2`, `ir_instr/2`, `fuse/1` and `unann/1` at about 85% of it.

One entry compared with `=:=` against the last module seen, which is the cache
`wasm_validate:cached_context/1` already keeps in the same call path and whose
comment records the same lesson. **317 us to 75.**

The second of the two tests it came with matters more than the first. Without a
case that instantiates two *different* modules in one process and calls both,
the cache key can be deleted entirely and every other test in the tree passes.

### The compiled entry was rebuilt on every call

| | ns of a 373 ns call |
| --- | ---: |
| `lease_call/2` + `release_call/1` | 108.4 |
| `wasm_instance:mut/1`, a cache *hit* | 28.5 |
| `wasm_jit:entry/3`, allocating a closure | 24.8 |
| `open_budget` + `close_budget` | 17.9 |
| `export_kind` | 14.2 |

`compiled/3` walked the slot list, built the slot key, resolved the lease
counter and allocated a closure per call, all of it fixed while an instance
keeps its slot. Cached under a bare reference on `#inst{}`, invalidated by one
`atomics:get` on the slot.

The lease also drops its `ets:lookup` when the stamp is a content hash. The row
check is for a caller overtaken by a slot reuse, and generated code already
refuses a stamp that is not its own, so another module's code cannot be entered
by mistake. A `reference()` identity has no stamp but the generation and keeps
`lease_call/2`. **373 ns to 304.**

### Bulk memory resolved the chunk per word

`copy_fwd/4` and `fill_loop/5` called `word/2` and `put_word/3` for every eight
bytes, each recomputing the chunk, the shift and the index. The chunk changes
only when a run crosses one. **A 4 KB `memory.copy`: 12.5 us to 5.1**, which is
the floor two `atomics` operations per word puts underneath it, against wasm3's
100 ns for a `memcpy`.

### Lazy chunk allocation: not done, and why

Two `atomics:new(131072)` at 35.4 us each is 68 us of the plugin's 317, and it
is proportional to *declared* rather than used memory, so allocating a chunk on
first touch looks obvious.

A memory handle is an immutable record inside `#mut{}`, so allocating one means
publishing a new handle, and `wasm_exec:store_at/6` answers `ok`. Stores never
touch `#mut{}` on purpose: that is what makes `Mut1 =:= Mut` in
`wasm:invoke_at/6` a pointer comparison, and skipping that write-back is
already measured at 177 ns of a 386 ns call.

So the options are a mutable side channel for the chunk tuple, which is the ETS
cell at 37 ns a read, or threading a new `#mut{}` out of every store, which
gives back more than the 68 us buys. Either way every load and store also pays
a comparison against the unallocated marker. An instance serves many calls;
paying per access to save once at instantiation is the wrong direction.

### Where it stands

| | ours | wasm3 | wasmtime |
| --- | ---: | ---: | ---: |
| arithmetic, per iteration | 3.33 ns | 4.8 | 0.73 |
| a call | 6.3 ns | 9.2 | 0.85 |
| a store and a load | 29.5 ns | 3.8 | 0.22 |
| 4 KB `memory.copy` | 5.1 us | 0.1 | 0.45 |
| instantiate and destroy | 79 us | | single-digit |
| a host call | 304 ns | | 10 to 20 |

Arithmetic and calls are faster than wasm3 and will not move much: 4.6x and 7x
Cranelift is about what generating BEAM rather than machine code costs. What is
left is the `atomics` representation, and `ATTEMPTS.md` records why the two
ways out of it are closed.

## Head to head with erlang-wasmtime

The comparisons above put `wasmtime` numbers next to ours, but they came from
the `wasmtime` CLI. This section runs the *Erlang binding*,
`~/Projects/erlang-wasmtime` (Wasmtime 48 through a NIF), on the same box, in
the same beam, over the same `.wasm` bytes. Harness: `vs.erl` and `vsq2.erl` in
the session scratchpad. Load average about 5, minimum of three passes.

Both arms compile eagerly: theirs is Cranelift, ours is `compile_whole` with
`compile_sync`, so neither is being timed while a compiler runs beside it.

### Steady state, where our tier covers the code

| | erlang_wasm | erlang-wasmtime | ratio |
| --- | ---: | ---: | ---: |
| arithmetic, per iteration | 3.38 ns | 1.01 ns | 3.3x |
| store and load, per iteration | 29.5 ns | 0.51 ns | 58x |
| `fib(30)`, whole call | 25.4 ms | 4.3 ms | 5.9x |
| 4 KB `memory.copy` | 5074 ns | 53 ns | 95x |

Arithmetic at 3.3x is the honest cost of emitting BEAM instead of machine code,
and it is the number that will not move much. The other three are all the
`atomics` memory representation, which is what `ATTEMPTS.md` records two closed
exits from. Note that Cranelift can forward the store to the load in the `mem`
loop, so 0.51 ns is not a claim that a wasm store costs half a nanosecond.

### The boundary, where we win

| | erlang_wasm | erlang-wasmtime |
| --- | ---: | ---: |
| Erlang to guest, one exported call | 483 ns | 5814 ns |
| compile and instantiate a 46 KB plugin | 3630 us | 4336 us |

**A call from Erlang into the guest is 12x cheaper here**, and the reason is
architectural rather than a slow path chosen by the harness. `wasmtime.erl`'s
`do_call/4` has no synchronous variant: every call is `enqueued` and the result
comes back as a message, because their `docs/design.md` gives each instance one
OS thread that owns the store. That buys them preemption, fuel and a timeout;
it costs a thread handoff per call. We run the guest on the calling process, so
a call is a BEAM call.

Compile plus instantiate is a tie for a small module. Their compile is
Cranelift codegen; ours is parsing, validation and Core Erlang generation for
all 150 functions.

### QuickJS, where the tier does not cover the code

Our own `test/fixtures/lang/qjs.wasm` cannot run on Wasmtime at all: it is a
WasmEdge build whose `sock_accept` takes three parameters where WASI preview 1
takes two, and Wasmtime binds its own before an import map is consulted. The
cross-runtime run therefore uses a plain wasi-sdk QuickJS, same script, same
preopened directory, one run per fresh OS process:

| qjs-wasi.wasm, 30k JS iterations | erlang_wasm | erlang-wasmtime |
| --- | ---: | ---: |
| module compile | 143 ms | 87 ms |
| instantiate, run, destroy | 16,900 ms | 1.9 ms |

That is four orders of magnitude, and none of it is the compiled tier. It is
the interpreter: generating this build's compilable functions takes six
minutes, and a 17-second run never waits for it.

### QuickJS again, once it is compiled

The number above answers "what does it cost to run a module you just handed
me". The other question is what the code costs once it exists, and for that the
tier has to be allowed to finish. Instance 1 takes `compile_whole` with
`compile_sync` and pays whole-module generation; instances 2 and after adopt
the code already in the slot, so their runs are execution and nothing else.

| qjs-wasi.wasm, 30k JS iterations | erlang_wasm | erlang-wasmtime | ratio |
| --- | ---: | ---: | ---: |
| instantiate | 0.63 ms | 0.15 ms | 4.2x |
| `_start`, the whole JS run | 109 ms | 0.99 ms | 110x |

**The tier is worth 155x on this workload**: the same call is 16,900 ms
interpreted and 109 ms compiled. What is left against Cranelift is 110x, which
is a long way from the 3.3x the arithmetic loop shows, and the difference is
what QuickJS does that the loop does not: `atomics` memory on every bytecode
dispatch, and f64 boxing, because JavaScript numbers are f64 and QuickJS's
interpreter converts on every operation.

Whole-module generation for this build cost **378 seconds**. That is the number
that decides whether the tier is reachable at all for a module this size, and
it is a compilation-throughput problem rather than an instruction-selection
one.

**The gap is not one number.** Where the tier compiles the code we are within
one order of magnitude of Cranelift on arithmetic and ahead of it at the Erlang
boundary. On a bytecode interpreter compiled to wasm it is two orders. Where
the tier cannot finish in time, there is no tier.

## Where the tier's compile time goes

Measured to answer "get hot code compiled sooner". QuickJS, the 223-function
hot set the default policy actually compiles, box at load 7 to 30 where noted.

### The SSA optimiser buys nothing and costs 68 seconds

| quality | compile, 223 funcs | warm `_start` | speedup |
| --- | ---: | ---: | ---: |
| `baseline` | **54.8 s** | 141.1 ms | 13.1x |
| `full` | **123.1 s** | 142.1 ms | 13.0x |

This default has been both ways. It went to `full` because the optimiser was
measured at 10% on QuickJS and **86% on a tight arithmetic loop**, 2.51 ns an
iteration against 4.66. That is no longer reproducible: the same loop over five
interleaved pairs is **3.35 ns either way**, memory access is 28.58 against
28.42 ns, and bulk copy is 102.1 ms against 102.0. The generator changed
underneath the trade, and whatever the optimiser was recovering `wasm_core` no
longer leaves for it. `baseline` is the default again.

### It is all the OTP compiler

| | |
| --- | ---: |
| lowering wasm IR to Core (`wasm_core:forms/5`) | **362.8 ms** |
| `compile:forms/2` on that Core | **53,928.9 ms** |
| | **99.3% compiler** |

223 functions produce **10.9 MB** of BEAM. Nothing about the front end is worth
optimising for this; the whole cost is what the OTP compiler does with what it
is handed.

### Cost is linear in what is generated, and I was wrong about why

Compiling prefixes of the hot set:

| funcs | compile | BEAM |
| ---: | ---: | ---: |
| 16 | 30.0 s | 6212 KB |
| 32 | 40.0 s | 8647 KB |
| 64 | 43.2 s | 9556 KB |
| 128 | 47.0 s | 10395 KB |
| 223 | 49.5 s | 10883 KB |

**Sixteen functions already cost 30 seconds**, and 207 more add 65%. My first
reading of that was that a few tiny functions explode: function 45 reports "24
instructions" and generates 1.9 MB. That was wrong, and the mistake was mine:
`length(IR)` counts *top-level* terms and a whole function nests inside one
`block`, so it measures nothing. Flattened, function 45 is 98,191 words.

Per function, against the real size:

| idx | bytes | ms | vars | ir words | bytes/word |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 45 | 1,897,524 | 8403 | 60 | 98,191 | 19.3 |
| 158 | 1,559,744 | 9373 | 37 | 98,262 | 15.9 |
| 46 | 1,018,748 | 4345 | 32 | 61,554 | 16.6 |
| 48 | 473,760 | 1812 | 16 | 32,590 | 14.5 |
| 80 | 107,176 | 320 | 9 | 8,071 | 13.3 |

**Bytes per IR word is 11 to 19 whatever the function looks like**, and barely
moves with the number of locals, so the locals-as-arguments shape is not
exploding either. There is no pathology. Code size is linear in IR size,
compile time is linear in code size, and the first sixteen cost thirty seconds
because they are the big ones.

### What that means for compiling sooner

**Sharding for early partial delivery is worth much less than it looks.** A
16-function first shard is 55% of the whole cost, because the functions worth
compiling are the expensive ones to compile. Choosing a first shard by *IR
words* rather than by count would compile quickly and would compile the wrong
functions, which is [[compiled-tier-coverage-not-speed]] over again.

**Sharding for parallelism is the lever.** The units are independent BEAM
modules and `compile:forms/2` is 99.3% of the work, so N shards compile on N
schedulers. Four functions are about 19 seconds of the 54, and this box has 14
cores.

The remaining front is bytes per IR word. Twelve to nineteen bytes of BEAM per
word of wasm IR is what sets the floor under all of it, and nothing here has
looked at why.

### A tuple in `#st.code` costs 8%, twice, for reasons still unexplained

Sharding needs the interpreter to know which generated module holds a function.
A tuple indexed by function number, read in `wasm_exec:do_call/4`, replaces a
cross-module call that returned `{error, not_compiled}`: strictly less work.

`realbench` on qjs with the tier on, five interleaved pairs, run 3 of each:

| | base | with the tuple |
| --- | ---: | ---: |
| 1 | 181.7 | 201.2 |
| 2 | 182.8 | 192.8 |
| 3 | 191.1 | 203.7 |
| 4 | 186.3 | 200.2 |
| 5 | 188.5 | 200.0 |

No overlap. Built a second time with the tuple as a *literal* in the generated
code so the crossing does no lookup at all: 193.8, 201.0 against 178.6 base,
and head ran **first** in those, so it is not the ordering. Generated code grew
22 KB of 10,905, so it is not size. The literal is shared, as expected.

Reverted. It is the fourth time an extra call on `do_call`/`branch`/`run` has
cost multiples of what it does, and the mechanism is still unproven.

**The design changes instead.** Shards can chain in generated code: shard 1's
`invoke/6` calls shard 2's by name when handed an index it does not hold, and
the interpreter is not involved at all.

### Shards work on the calling process and fail off it

One wasm module compiled into several generated ones, each answering for the
functions it holds and handing anything else to the next by name. QuickJS's
223-function hot set, `#{compile_shards => 4}`:

| | funcs | warm `_start` | speedup |
| --- | ---: | ---: | ---: |
| one unit | 223 | 174.4 ms | 13.2x |
| four units, `compile_sync` | 223 | 157.2 ms | 11.8x |

Correct, and every function accounted for. Through the **background** compiler
the same options fail, twice over and differently each time: once with 223
functions lowered, 16.3 seconds spent and **nothing published**, once with a
shard raising out of `invoke/6` on a later instance's first call. A harness
that skips the interpreted first instance does not reproduce either, in six
attempts.

The thread to pull is that `spawn_compile/2` re-lowers every body **in the
compiler process**, where the fusion decision the calling process made is not
set. That has been true for the single-unit path all along and is apparently
survivable there.

So the mechanism is in and the policy is not: `auto` is one unit until this is
understood. No wall-clock number for parallel compilation yet, because the
arrangement that would produce it is the one that fails.

### Shards: 3.8x to compile, 1.5x to run

The failure above was not the fusion decision. Publishing shard one is what
makes the whole chain adoptable -- `wasm_jit:await/2` returns on it and the
next instance calls straight in -- and the loop was loading and publishing each
unit in turn. In the window between shard one going live and shard four being
loaded, the chain reached a module that did not exist and generated code raised
`undef`, which arrived as an internal error on somebody else's first call.
Only off the calling process, because nothing else was racing that loop.

Every unit is loaded before any is published now. QuickJS's 223-function hot
set, background compiler:

| | compile | warm `_start` | speedup |
| --- | ---: | ---: | ---: |
| one unit | 57.8 s | 174.4 ms | 13.2x |
| four units | **15.2 s** | **268.5 ms** | 7.5x |

**3.8x faster to compile and 1.5x slower to run**, and the second half was not
inherent. `wasm_core:forms/7` built `Known` from its own unit only, so a call to
a function in another unit crossed back into the interpreter and re-entered
through the head of the chain. Which unit holds which function is decided before
anything is generated, so it can be a direct call instead, and now is:

| | compile | warm `_start` | speedup |
| --- | ---: | ---: | ---: |
| one unit | 55.6 s | 133.0 ms | 13.9x |
| four units | **15.5 s** | **154.4 ms** | 14.6x |

**3.6x faster to compile and about 16% slower to run.** What is left is that a
call between units is a cross-module call through `wasm_exec:shard_call/8`
where a call within one is a local `apply`, and that is inherent to their being
separate BEAM modules.

**The default stays one unit**, because the trade depends on something the
runtime cannot know: forty seconds saved against twenty-one milliseconds a run
is about nineteen hundred invocations to break even. A worker that serves one
module all day should not split. Something that compiles a module to run it a
few times should. So it is `compile_shards` and it is the embedder's call.
## The cost model: what generated code actually pays for

Built because the alternative was guessing. Two things it killed on the first
day: that boxing dominates (a compiled run reclaims 3,989,087 words against the
interpreter's 1,432,733,751, GC at 0.0% by `msacc`), and that `call_indirect`
matters for QuickJS (5,145 of them in a run).

### Prices

`bench/paths/perinstr.erl` builds the same loop with K copies of a snippet and
with 2K and takes the difference, so loop overhead cancels. It priced the
*interpreter* until now; `-run perinstr main on` prices generated code.

| snippet | interpreted | **compiled** |
| --- | ---: | ---: |
| `nop`, `i32.const`, `local.get`, `local.set` | 1.9 to 11.1 | **~0** |
| `i32.add` | 14.45 | **1.26** |
| `i32.mul` | 15.05 | 2.45 |
| `i32.shl` | 14.92 | 1.95 |
| `global.get` | 7.43 | 1.65 |
| `call` (empty) | 19.63 | 3.77 |
| `f64.convert_i32_u` | 32.52 | 4.73 |
| `i32.load` | 25.75 | 9.35 |
| `global.set` | 23.84 | 15.80 |
| `i32.store` | 36.53 | 22.25 |
| **`i64.add`** | 29.11 | **26.40** |
| **`i64.shl`** | 29.56 | **24.99** |
| **`f64.load`** | 51.12 | **35.91** |
| **`i64.load`** | 48.70 | **39.51** |
| **`call_indirect`** | 78.47 | **63.22** |
| `memory.copy`, 64 bytes | 123.59 | 319.41 |

The operand stack and locals really are compiled away: `nop` and `local.get`
cost nothing at all. i32 arithmetic is 1 to 2.5 ns. What stands out is that
**an `i64` operation is 21x its `i32` twin** -- 26.40 against 1.26 -- and that
`memory.copy` is *worse* compiled than interpreted.

### Counts

The interpreter never runs, so `run/3` cannot be counted. What can be counted
is every function the generator emits a call to; `wasm_core`'s `call_op/2`
names them. One QuickJS run, `call_count` tracing:

| escape | calls |
| --- | ---: |
| **`op1/2`** | **1,317,284** |
| `check_depth/2` | 23,085 |
| `set_global_at/4` | 9,552 |
| `indirect_out/9` | 5,145 |
| `global_at/2` | 4,800 |
| `load_at/5` | 4,543 |
| `store_at/6` | 2,259 |
| everything else | under 1,000 each |

`check_depth/2` is one per call, so **the whole run makes about 23,000 wasm
calls** and `call_indirect` at 5,145 cannot matter however expensive it is.
`load_at`/`store_at` are only the slow path; the fast one is inlined and
invisible here.

`op1/2` is two orders of magnitude above everything else, and four operations
are all of it:

| op | calls | share |
| --- | ---: | ---: |
| `i32_eqz` | 581,201 | 44% |
| `i32_wrap_i64` | 521,684 | 40% |
| `i64_extend_i32_u` | 154,285 | 12% |
| `i64_eqz` | 60,031 | 5% |

### The first thing it found

Every one of those four is pure arithmetic with no trap and no state, and every
one was a cross-module call because `wasm_core:inline1/1` covered only four f64
conversions. Inlining them is the interpreter's own definition written in Core:
`wasm_num:wrap_s32/1` is `wrap(32, _)`, `wasm_num:to_u32/1` over the i32 domain
is `uns(32, _)`, and `i64.extend_i32_s` is the identity because an i32 is
already held signed.

**`op1/2` disappears from the escape table entirely**, and the constructs
themselves, priced the same differential way on both trees:

| | before | after |
| --- | ---: | ---: |
| `i32.eqz` into a local | 9.96 | **0.13** |
| `i32.eqz` in a `br_if` | 2.82 | **1.91** |
| `i32.wrap_i64` | 2.95 | **0.77** |
| `i64.extend_i32_u` | 2.56 | **0.19** |
| `i32.add`, the control | 1.26 | 1.31 |

End to end, QuickJS warmed and timed five times per process, four alternating
pairs in both orderings once the box was quiet:

| | runs (ms) | min |
| --- | --- | ---: |
| before | 125.8, 122.3, 121.6, 122.6 | 121.6 |
| after | 119.7, 118.7, 115.4, 115.9 | **115.4** |

**About 5%**, and the two sets do not overlap: 1,317,284 cross-module calls at
roughly 4.5 nanoseconds each. `bench/cross/loop.wasm` is unmoved at 3.38
against 3.35 ns an iteration, which it should be -- it has no unary escape in
it. The plugin arm cannot resolve the change: twelve interleaved pairs in both
orderings spread from 146 to 198 microseconds, and every construct the change
touches got faster while the control did not move.

### What it says to do next

- **`i64` operations at 21x their `i32` twins.** `wrap(64, _)` masks with
  `16#FFFFFFFFFFFFFFFF`, which is past the 60-bit immediate range, so every
  64-bit wrap is bignum arithmetic on values that are usually small. This is
  the largest single lever the model has found and it is pure code generation.
- **`memory.copy` slower compiled than interpreted**, at 5 ns a byte.
- **`i32.store` at 22.25 against `i32.load` at 9.35**, which is the
  read-modify-write the `atomics` representation forces and what the NIF
  question is about.
- **`call_indirect` and boxing are not worth touching for this workload**, and
  the model is what says so.

### What the model found next: 60 bits is the whole story

Three changes, one cause. A BEAM immediate holds 60 bits, so any literal at or
above 2^59 is a bignum, and the generator was reaching for `2^64-1` and `2^63`
on paths that almost never need them.

| construct | before | after |
| --- | ---: | ---: |
| `i64.add` | 26.40 | **0.48** |
| `i64.load` | 39.81 | **7.79** |
| `i64.store` | 22.55 | **9.58** |
| `f64.load` | 35.91 | **25.18** |
| `f64.store` | 29.21 | **14.08** |
| `i32.add`, the control | 1.26 | 1.29 |

- **`i64.add` and `i64.sub`.** `wrap(64, _)` masks with `2^64-1` and folds with
  `2^63`. An i64 is always held in `[-2^63, 2^63)`, so a sum lands in
  `(-2^64, 2^64)` and one comparison decides it. Two tiers, because comparing
  against `2^63` is itself bignum work: 26.40 with the mask, 12.30 with one
  range test, **0.48** with an immediate-bounded test first.
- **The full-word load.** `ordinary/6` only takes the fast path when the access
  fits in one word, so for eight bytes the shift and the mask are both
  identities -- but `mask(8)` is `2^64-1` and the compiler cannot see through
  it. An aligned `i64.load` is one `atomics:get`; it now costs less than
  `i32.load`, which is the right way round.
- **The full-word store.** Same shape: the read, the splice and the mask are
  all unnecessary when the value fills the word.

End to end on QuickJS, warmed and timed five times per process, alternating
against the branch point:

| | ms |
| --- | ---: |
| before | 124.4 |
| after `op1` inlining | 115.4 |
| after the `i64` load | 92.4 |
| after the `i64` store | **85.4** |

**31%.** `bench/cross/loop.wasm` is unmoved at 3.38 ns an iteration and the
i32 memory loop is unmoved at 28.68 against 28.89 interleaved, both of which
they should be: neither change touches a path they take.

### And a method correction

The opcode census run against the interpreter reports 132,583,392 `block`
entries a run, more than every other opcode combined, because QuickJS's
bytecode dispatch is a `br_table` inside a deep nest of them and the
interpreter re-enters the whole nest per dispatch. **That count does not
transfer to compiled code**, where a control frame is a function and a branch
is a tail call, so the nest is not executed at all. An empty `block` does cost
1.32 ns compiled and eight nested cost 2.11 each, but they are entered once
rather than 240 times per dispatch.

Data operations do transfer, and those are what the table above is weighted by.
Control flow has to be counted in compiled code or not at all.

### The narrow store, and where the floor actually is

A four-byte store into a 64-bit `atomics` word is a read, a splice and a write,
and the splice reached for `16#FFFFFFFF00000000` as its keep-mask. That literal
is a bignum, so it took the whole expression off the immediate path for the
sake of a constant -- even when the half of the word not being written is zero,
which is most of a grown memory and any value that fits in the half being
written.

The bits above the field are kept by shifting them out and back and the bits
below by a mask that is small because the offset is at most 32, so nothing in
the common case is a bignum. The literal-offset list also covered only 0 and
32, which is where an i32 lands; every byte and 16-bit store fell to the
dynamic form that builds its mask and both shifts at run time. It covers every
offset the width can naturally sit at now.

| | before | after |
| --- | ---: | ---: |
| `i32.store` | 22.16 | **13.77** |
| `i32.store8` | 22.13 | **14.41** |
| `i64.store` | 22.55 | **9.49** |
| `f64.store` | 29.21 | **15.67** |
| `i32.load`, untouched | 8.80 | 8.80 |

**Neither benchmark can show this.** QuickJS is i64-heavy -- 488,629 `i64.store`
against 92,022 `i32.store` -- and its i64 path was already fixed, so it sits at
87.6 ms against 124.7 either way. The plugin arm calls a trivial `capacity` two
hundred times, is not memory-heavy at all, and spans 161 to 216 microseconds
over four interleaved pairs. The construct prices are the evidence, and the
change cannot cost anything: it is strictly fewer and cheaper operations on
every path it touches.

`wasm_core_SUITE:every_memory_access_agrees_with_the_interpreter` is what says
it is correct, and it walks every load and store against boundary patterns.

**This is close to the floor for the representation.** `PERF.md` put that at
about 19 nanoseconds a store when `atomics` get-then-put on one word cost
19.13; that pair is 9.59 now and a four-byte store is 13.77. What is left is
the address arithmetic and the bounds check. Going below it means changing the
representation, and the two ways to do that -- a 32-bit lane layout, or a NIF --
are both profile decisions, because a lane layout would make i32 cheaper and
i64 dearer and QuickJS is i64-heavy while a Rust plugin is not.

## The NIF floors, measured

The gate Phase 0 existed for. A dozen lines of C on a *regular* scheduler --
every NIF this project ships is dirty-scheduled I/O and says nothing about
this -- timed by the same differential method, dedicated loops, no fun
indirection.

| operation | ns |
| --- | ---: |
| **a NIF call that does nothing** | **7.80** |
| NIF read, 4 bytes from NIF-owned memory | 6.0 to 8.7 |
| NIF write, 4 bytes | 9.21 |
| `atomics:get/2` | **4.66 to 4.93** |
| `atomics:put/3` | 5.77 |
| `atomics` get then put, one word | 9.77 |
| binary view, fixed offset | 9.10 to 11.57 |
| binary match at a varying offset | 8.95 |
| `binary_part/3` at a varying offset | 17.50 |
| empty loop, the control | 0.63 |

### A per-operation memory NIF is not worth building

**`atomics` is the fastest read primitive on this runtime.** A NIF call costs
more than an `atomics:get` before it has read anything, so a per-operation NIF
read is a regression however good the C is. The resource-backed binary, which
was the one design that could have avoided the call entirely, is slower still:
8.95 nanoseconds at a varying offset against 4.93.

A NIF *write* does win, because a four-byte store is a read-modify-write:
9.21 against the 13.77 a generated `i32.store` costs. But priced against what
the two workloads actually execute, that is under a millisecond of QuickJS's
87.6, because it does 488,629 `i64.store` -- already 9.49 -- against 92,022
narrow ones.

**And this answer is a consequence of doing the pure-Erlang work first.**
Before the immediate-path changes an `i32.store` was 22.16 nanoseconds and a
NIF write at 9.21 would have been a 2.4x win worth building. Keeping the
generated code inside BEAM immediates took the case away.

### What a NIF is still for

Bulk. `memory.copy` runs at about 1.8 nanoseconds a byte through generated
code, where a NIF is one 7.80-nanosecond call plus `memcpy`. That is two orders
of magnitude on a copy of any size, and it applies to `memory.fill`,
`memory.init` and the `read_memory`/`write_memory` embedder API as much as to
`memory.copy`.

QuickJS makes 953 bulk calls a run and will not notice. A memcpy-heavy Rust
plugin is a different workload, which is what the profiles are for.

## Telling the JIT what validation already proved

Since OTP 25 the JIT emits better arithmetic when the compiler knows a value's
range: an addition drops from ten instructions to four, a comparison from
eleven to four, a tuple test from five to three. That range comes from the SSA
type pass, which `no_ssa_opt` turns off.

This morning `full` bought nothing -- QuickJS 141.1 ms against 142.1 -- and it
was demoted for costing 123.1 seconds against 54.8 to compile. That measurement
was correct. It is no longer true, and what changed is the code handed to the
pass rather than the pass itself.

The immediate-path work above is written as *guards*: `wrap_sum/2` tests
`W >= -2^63, W < 2^63`, `decode_word/2` tests `W =< 2^59-1`. A guard is how a
range gets stated, and stating it is all the type pass ever needed. The
generator had been proving every value's width in validation and throwing it
away.

`wrap(32, _)` was then given the same shape deliberately, through `inline_w/1`.
Its constants were immediates already so the branch-free form cost nothing to
*run*; what it cost was the information. It is faster both ways:

| | before | after |
| --- | ---: | ---: |
| `i32.add` | 1.29 | **0.76** |

QuickJS, warmed and timed five times per process:

| quality | ms |
| --- | ---: |
| `baseline` | 86.1 to 87.7 |
| **`full`** | **75.0 to 76.8** |

So `full` is the default again. It still costs **129.3 seconds against 58.1**
to compile the hot set, and that is what `compile_shards` is for.

### Where the branch ends up

Against its branch point, everything measured moved and nothing regressed:

| | before | after |
| --- | ---: | ---: |
| QuickJS, warm | 124.7 ms | **76.5** |
| `bench/cross/loop.wasm` | 3.35 ns/iter | **2.98** |
| the i32 memory loop | 28.42 ns/iter | **25.28** |
| `i64.add` | 26.40 ns | 0.48 |
| `i64.load` | 39.81 | 7.79 |
| `i64.store` | 22.55 | 9.49 |
| `i32.store` | 22.16 | 13.77 |
| `i32.add` | 1.26 | 0.76 |

**39% on QuickJS**, and the whole of it is one idea: a BEAM immediate holds 60
bits, and generated code should stay inside them and say so.

## What a bulk NIF would be worth, before building one

The one NIF shape the floors left standing. Priced before writing any C.

### Bulk through generated code today

| | ns | ns per byte |
| --- | ---: | ---: |
| `memory.copy`, 8 bytes | 40.92 | 5.11 |
| `memory.copy`, 64 bytes | 117.34 | 1.83 |
| `memory.copy`, 1024 bytes | 1290.70 | 1.26 |
| `memory.fill`, 1024 bytes | 756.54 | 0.74 |
| `wasm:write_memory/3`, 64 KB | 87,000 | 1.33 |
| `wasm:read_memory/3`, 64 KB | 110,000 | 1.68 |
| `wasm:write_memory/3`, 1 MB | 1,580,000 | 1.51 |

A NIF is one 7.80-nanosecond call plus `memcpy`, so about 0.05 nanoseconds a
byte once it is moving.

### And what the workload actually moves

A QuickJS run makes 953 `memory.copy` calls totalling **18,437 bytes** and 117
`memory.fill` calls totalling 14,539: an average of 19 and 124 bytes. That is
**0.04 milliseconds of an 80.8-millisecond run, or 0.05%**.

**So the guest side is not the case.** `bulk.wasm` shows 95x against wasmtime
because it exists to isolate the operation, not because real programs spend
time there.

### Where it is the case

The embedder boundary. `docs/worker.md`'s pattern hands a request body in and
takes a response out on every call, and that is `read_memory`/`write_memory` at
1.0 to 1.8 nanoseconds a byte:

| round trip | today | with a NIF |
| --- | ---: | ---: |
| 64 KB in and out | ~197 us | ~7 us |
| 1 MB in and out | ~3.5 ms | ~55 us |

A plugin call is about 690 microseconds, so a 64 KB round trip spends roughly a
quarter of a request copying buffers, and a NIF removes almost all of it.

**The recommendation is therefore narrow.** Not `memory.copy`: a NIF there is
9 to 19x on an operation nothing measurable spends time in. The embedder's
`read_memory`/`write_memory`, where the buffers are large and the caller is
Erlang rather than the guest, and only for an embedder that passes large ones.
The plugin arm passes a handful of bytes and would not notice either.

### The bulk NIF cannot be built, and did not need to be

`erl_nif.h` has **no atomics API at all** -- zero mentions. A NIF cannot reach
the memory an `atomics` array holds, so the narrow bulk NIF recommended above
is not implementable without moving linear memory into NIF-owned buffers. That
is the whole layout change, and it would make every per-operation access slower:
a NIF call is 7.80 nanoseconds against `atomics:get`'s 4.66.

**So no NIF shape survives.** Per-operation reads lose to `atomics`, the
resource-backed binary loses to `atomics`, guest-side bulk is 0.05% of a run,
and the embedder boundary cannot be reached from C without giving up the
representation.

What the boundary needed was the treatment the access path already had. Both
`scatter/3` and `collect/4` resolved the chunk once per *word*, and
`put_word/3` masked with `16#FFFFFFFFFFFFFFFF` on a value that came out of a
64-bit binary field and was already in range.

| | before | after |
| --- | ---: | ---: |
| `write_memory`, 64 KB | 87 us | **56** |
| `read_memory`, 64 KB | 110 us | **68** |
| `write_memory`, 1 MB | 1580 us | **1147** |
| `read_memory`, 1 MB | 1908 us | **1178** |

**A 64 KB round trip is 124 microseconds against 197**, which is about 11% of a
690-microsecond plugin call.

Two things this cost to learn, both worth keeping:

- **Returning a binary tail from a loop costs a sub-binary per iteration.** The
  first version of `scatter_run/4` returned its remainder so the caller could
  continue, and that defeats the match-context optimisation: a 64 KB write went
  to 133 microseconds, *worse* than the 87 it started at. Splitting once per run
  with `split_binary/2` and letting the loop consume its binary to exhaustion is
  what makes it 56.
- **The append was the read's cost, not the read.** `atomics:get` is 4.66
  nanoseconds a word and the loop measured nearly twice that; four words per
  append rather than one closed most of it.

## The second audit's fixes, held against QuickJS

Nothing in that branch is meant to move a number. Two of the fixes touch code
a call passes through anyway -- `wasm_heap:lease/1` and `unlease/2` on the
outermost invocation, and `wasm_jit:cached_entry/3` on the entry path -- and
this project has had three changes on the dispatch path cost about 70% while
the synthetic loop measured nothing, so "it should be free" is not evidence.

Five interleaved pairs on `qjs.wasm` with the tier on, minimum of three runs
each, orderings alternated. Load average rose from 9 to 20 across the run,
which is why the ordering matters more than the totals.

| pair | order | base | branch |
| ---: | --- | ---: | ---: |
| 1 | base first | 131.8 ms | 135.2 ms |
| 2 | **branch first** | 133.8 ms | 133.0 ms |
| 3 | base first | 128.6 ms | 138.4 ms |
| 4 | **branch first** | 135.8 ms | 136.9 ms |
| 5 | base first | 132.0 ms | 133.5 ms |

**Read it by the ordering, not by the totals.** Whichever arm runs *second*
loses, in every pair: the branch loses all three base-first pairs and the two
branch-first pairs are a tie, one each. That is the shape a rising load average
produces and not the shape a code change produces, and it is exactly why the
protocol in `bench/paths/README.md` says to run both orderings.

There is also no mechanism. QuickJS declares no struct or array type, so
`lease/1` answers `false` on its first comparison and none of the heap change
is reached; and `wasm_jit:counts/0` reports `entered => 3` for the whole run,
so `cached_entry/3` runs three times against 30,000 JavaScript iterations.

Worth re-running on a quiet box before the next performance claim leans on it.

## The stress run's fixes, held against QuickJS

Two of these touch code every embedder call passes through: `wasm:call/4` now
checks the limits map when it is not empty, and `call_1/4` checks argument arity
and types before either engine is chosen. Neither is per-instruction, but this
project has had three changes near the dispatch path cost about 70% while the
synthetic loop measured nothing, so the protocol applies whatever the shape of
the change.

Five interleaved pairs on `qjs.wasm` against `f8d4f13`, minimum of three runs
per launch, orderings alternated. Load average 10.4 to 10.9 throughout, which is
below the 12 to 14 the rest of this file was taken at.

| pair | order | base | branch |
| ---: | --- | ---: | ---: |
| 1 | base first | 1679.3 ms | 1843.2 ms |
| 2 | **branch first** | 1672.9 ms | 1717.1 ms |
| 3 | base first | 1653.8 ms | 1659.8 ms |
| 4 | **branch first** | 2760.5 ms | 1692.8 ms |
| 5 | base first | 1694.2 ms | 1660.7 ms |

Minimums: base 1653.8 ms, branch 1659.8 ms, a difference of 0.36%.

**This establishes no large regression, not no regression.** The base arm's own
spread across the five launches is 1653.8 to 2760.5 ms, which is sixty-seven
per cent, and the difference being measured is well inside it. Pair 4's base is
plainly an outlier; the ordering does not explain the rest, since the branch
wins one base-first pair and loses one branch-first pair.

The mechanism agrees. `wasm:call/3` reaches the limits check as a clause head on
an empty map and does no work, and the argument check runs once per embedder
call: this workload makes one, then runs 30,000 JavaScript iterations inside it.

Worth re-running on a quiet box before any claim leans on the 0.36%.

## Charging the object store, and two versions that were too expensive

Garbage-collected objects are ETS rows, so neither `max_heap_size` nor the page
budget could see them: a guest filled a twenty-million element array and took
1.8 GB with every limit reading zero. Charging the heap against the node page
budget puts a check on the allocation and array-write paths, which is exactly
where this project has been bitten before, so it was priced three times.

`wasm_gc_bench_SUITE`, `allocation_throughput` and `bulk_array_ops`, against
`05720c4`.

| version of the check | struct.new | array.fill part, 100 |
| --- | ---: | ---: |
| base, no charge | 171.9 ns/object | 84.6 ns/element |
| `application:get_env/3` per operation | 234.9 (+37%) | 120.0 (+42%) |
| interval cached in an `atomics` slot | 200.6 (+17%) | 92.9 (+10%) |
| `band` against a literal mask | 181.4 (+5.5%) | 92.9 (+10%) |

The first two are the finding. `application:get_env/3` is an ETS lookup, and
`gc_alloc_threshold` beside it gets away with being read from the environment
only because `should_collect/1` asks once per outermost call; this is asked once
per *allocation*. Caching it in the counter array removed the lookup and still
cost 17%, because it is another read on a path whose whole body is one
`ets:insert`. A power-of-two constant needs no read at all, and the allocation
path already has the id in hand, so `Id band 16#FFF` replaces both.

**The third row, priced properly.** Timing could not resolve it: ten interleaved
pairs of `allocation_throughput` gave base 189.4 to 244.7 ns and branch 185.9 to
274.1, a 29% and 47% spread against a difference of a few per cent, and the
minimum said -1.8% while the median said +8.8%. The null experiment settled that
it was noise and not the change: removing the hook from `new_struct/3` entirely
and repeating gave 182.0 / 186.3, 211.2 / 222.4 and 216.0 / **170.0**, the arm
with nothing in it winning a pair by 21%. Load average was 21 to 26, and starting
at 4.6 did not help because running all ten arms twice a pair drives it there.

So the instrument was wrong. Reductions are a *count*, immune to whatever else
the box is doing, and they are what this change should be measured in:

| operation | base | branch | added |
| --- | ---: | ---: | ---: |
| `struct.new` | 68.11 reductions | 70.09 | **+1.98, +2.9%** |
| `array.set` | 44.10 reductions | 47.24 | **+3.14, +7.1%** |

Identical to two decimal places across three runs on both trees, at load 5.8,
and exactly what the code adds: a call, a `band` and a compare on the allocation
path; an `atomics:add_get`, a `band` and a compare on the write path. Dropping
the `ok =` match beside the write changed nothing, so those three are
irreducible for what they do.

Read it as work and not as time. Reductions overstate a BIF's share, and the
dominant cost of both operations is an `ets:insert` the VM charges lightly and
the clock does not. What can be said is that the added work is small, bounded,
attributable instruction by instruction, and does not scale with heap size.

The reconcile itself is not on the path: `ets:info(memory)` on both tables is
1.78 microseconds for the pair, once per 4096 operations.

## Giving the collector a byte-side trigger

`major_due/1` and `should_collect/1` both counted objects, so a store of few
large objects was never collected at all: four rounds of a fifty thousand
element array left all four, sixteen megabytes, with one reachable. Making both
rules see bytes as well as rows means collections that never used to happen now
do, and that is work.

Reductions, the instrument the section above settles on, against `67a4e83`:

| operation | before | after | added |
| --- | ---: | ---: | ---: |
| `struct.new` | 70.09 | 80.10 | **+10.01, +14.3%** |
| `array.set` | 47.24 | 50.26 | **+3.02, +6.4%** |

Both workloads allocate twenty thousand objects in one call and keep none, so
before this they leaked two megabytes a call and collected nothing. The added
reductions are the collector doing the work it was skipping, not overhead around
it: the triggers are two `atomics:get` each and they run once per outermost
call, not per allocation, so at twenty thousand allocations a call their share
rounds to nothing.

Nothing was added to a collection itself. `major/3` and `minor/3` are untouched;
`collect/2` gains two `atomics:put`. What changed is how often a major is due,
which is the whole point, and what it buys is a bound: the same workload's store
now oscillates between one and two arrays instead of growing without end.

The trade is explicit. A workload that allocates heavily and keeps nothing pays
about fourteen per cent more work to stop leaking.

**A stable live set is not free, and the claim that it was is withdrawn.** Both
triggers are read once per outermost call, and the benchmark above does twenty
thousand operations *inside* one call, which amortises a per-call check to
nothing and cannot say anything about it. A review pointed that out and it was
right.

Measured properly -- a hundred thousand short calls on a GC instance whose live
set is one struct:

| tree | per short call |
| --- | ---: |
| before the charge | 171.461 reductions |
| charge only | 173.465 |
| charge, byte triggers and the review fixes | 176.310 |

So **+2.8%** per call on a stable live set, not nothing. What it buys is that the
store cannot grow without bound, which it previously could. The two environment
lookups the review found on that path are gone: `gc_major_ratio` and
`gc_min_major_pages` are read where collections are decided and the answer is
kept in an `atomics` slot, so the per-call check is two `atomics:get` and a
comparison.

## One reconcile cadence for writes and allocations

A second review found that a refused allocation left its row and then went 4095
allocations unchecked: the allocation path rode the id it had already taken,
`Id band ?RECONCILE_MASK`, and a refusal rewinds `?WRITES`, which that path never
read. Allocations now count on `?WRITES` like every other mutation, which costs
the `atomics:add_get` the id trick existed to avoid.

Reductions, against `401b91c`, three runs each, identical to three decimals:

| operation | before | after | added |
| --- | ---: | ---: | ---: |
| `struct.new` | 61.103 reductions | 62.128 | **+1.025, +1.7%** |
| `array.new_default` | 57.129 | 58.132 | **+1.003, +1.8%** |

One reduction, which is the one BIF call. The measurement that argued for the id
trick priced *reading `gc_alloc_threshold` from the environment* at 37%, an ETS
lookup rather than an atomic; it does not transfer, and the number above is what
the alternative actually costs.

## The reconcile counter counts words, not operations

A third review found that the interval bounds *bytes* only while every row is
the same size, and a struct row is as wide as its type declares. Nothing caps a
struct's field count, so one `struct.new_default` of a hundred thousand fields
was one mutation on the cadence and an 800 KB row, admitted whole at a one-page
ceiling. The counter now takes each row's word cost and `?RECONCILE_MASK` goes
from 4,095 operations to 65,535 words, which is half a megabyte of overshoot
against the 370 KB the old constant was chosen for.

Reductions against `16c109e`, two runs each, stable to three decimals:

| operation | before | after | change |
| --- | ---: | ---: | ---: |
| `struct.new` | 62.094 -- 62.127 | 62.096 | flat |
| `array.new_default` | 58.094 | 58.089 | flat |
| `array.set` | 48.042 | 48.040 | flat |
| a call returning a reference | 150.539 | 155.018 | **+4.48, +2.9%** |

Flat where the work is, because a five-word struct row now reconciles every
13,107 allocations where operations reconciled every 4,096, and an element row
at twelve words every 5,461 where it was 4,096. Fewer reconciles paid for the
`tuple_size` and the changed comparison.

The last row is the one that moved, and it is reconcile *timing* rather than
work added to the call: nothing on that path gained an instruction. Charging the
row size at the old 4,095 constant cost 161.6 on the same measurement and
charging one word cost 150.5, so the figure tracks how often the store is
measured and not what a call does. It is 2.9% on a call that returns a fresh
reference and holds it, which is the shape that keeps the store growing.
