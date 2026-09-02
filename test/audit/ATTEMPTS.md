# The compiled tier: what worked, what did not

A record of what was attempted while building the Core Erlang tier, what
survived and what was reverted or withdrawn. Read this before proposing an
optimisation for the tier or for `wasm_exec`, so you do not spend a day
rediscovering something already measured and thrown away. The numbers behind
every claim here are in `PERF.md`; this page is the index of decisions.

Covers `391ea9a` through `cbe1ecb`.

## What succeeded

**The tier itself.** WebAssembly lowered to Core Erlang, handed to
`compile:forms(_, [from_core, binary])`, loaded with `code:load_binary/3`, and
run alongside the interpreter. `bench/cross/loop.wasm` runs at **2.6
ns/iteration against the interpreter's 68.6**, and has held that across every
change since.

**Locals as Core variables and no run-time operand stack.** `local.set` is a new
binding rather than a tuple update; the operand stack is a compile-time list.
Control frames become Core functions and a branch becomes a tail call.

**Inlining the arithmetic.** Routing every operation through `wasm_exec:op2/3`
cost **12x**. The total operations are open-coded in Core with the wrap masks
inline; the partial ones (division, remainder, shifts) still route through
`wasm_exec` so that trapping behaviour has one implementation. 30.5
ns/iteration to 2.6.

**Direct calls**, taking coverage from 6% to 55% of QuickJS. A callee compiled
alongside the caller is a local apply, because BeamAsm compiles a remote call by
setting up an export entry in a register.

**Indirect calls**, 55% to 77%. `wasm_exec:indirect_target/5` is reused rather
than restated, so `undefined_element`, `uninitialized_element` and the type
mismatch stay one implementation.

**Bulk memory**, 77% to 83% of QuickJS and **100% of the Rust plugin**. The
interpreter's own clauses were rewritten to call the same helpers generated code
calls.

**Bounded atom pools.** Nothing derived from a module ever becomes an atom.
Module names come from a fixed pool of sixteen, function and frame names from
bounded pools, and `wasm_core_SUITE` asserts that naming every slot of every
pool creates no atoms.

**Four correctness and lifetime defects fixed**, including
`wasm_memory:copy/5` skipping its bounds check on a zero length.

**The instruments.** `bench/paths/subset.erl` (what a compiler could take),
`callcost.erl` (what the crossing costs), `coverage.erl` (what this compiler
does take, and what refuses the rest). Every one of them changed a plan.

## What failed and was reverted

**The leaf-function on-ramp.** The plan was to start with functions that do pure
integer arithmetic and make no calls. `subset.erl` priced it at **0.02% of
QuickJS by instruction**, 107 instructions out of 560,000. There is no cheap
on-ramp: a compiler that cannot call is worth nothing on real code. The
crossing became the first piece of work rather than the last.

**Parameter masking.** The one speculative optimisation in the plan. It
destroyed the sign: `i32.div_s(-10, 3)` answered 1431655762. Removed rather
than patched, because doing it correctly needs each parameter's declared width
and the generator does not carry it.

**Core variable names as tuples.** `{arg, 1}`, `{v, N}`, `{l, D, I}` all crash
`sys_core_fold`. Core variable names must be atoms or integers. Integers were
strictly better anyway: no atoms for variables at all.

**`frame_at/2`.** Strictly less list work, and it cost QuickJS **75%** (102.7 ms
to 181.8 across five interleaved pairs). Reverted. That was the third change to
the dispatch path that was obviously cheaper and measurably slower, which is why
`realbench` exists and why the synthetic loop is never the last word.

**Spinning call leases.** `wasm_code_slots:take/2` yielded until the exclusive
hold cleared. That terminates when the hold is one `soft_purge` and does not
when it is a whole compilation, so it deadlocked the suite. Made non-blocking,
answering `stale`. The test found a real design bug rather than a flaky test.

**Blocking on lifetime.** Code publication has to be atomic against a concurrent
compile of the same module. The first design let two processes reach it
together. Replaced with a slot transaction carrying a generation token:
`claim_loading/3` answers `{compile, Name, Token}` or `{resident, Name}` or
`loading`, and only the token holder may `publish/1`.

**Regenerating the spec manifest with `textwrap`.** It broke hyphenated atoms
(`skip-stack-guard-page` split across lines). Fixed with
`break_on_hyphens=False`, but the lesson is that generated Erlang source needs a
generator that knows it is Erlang.

**Dialyzer, twice.** The `compiler` application was not in the PLT, giving 46
false `Unknown function cerl:c_atom/1`. Then it caught a fabricated partial
`#st{}` built to fit `indirect_target/4`'s old signature, with `locals`, `fuel`
and `max_depth` undefined. The right fix was to change the signature.

**A function-to-module tuple in `#st.code`, for sharding.** To compile one wasm
module into several generated ones, the interpreter has to know which one holds
a given function. The obvious shape is a tuple indexed by function number, read
in `wasm_exec:do_call/4` instead of calling in to be told `{error,
not_compiled}` -- strictly less work on the path it replaced, and it removes a
cross-module call.

It cost **8% of a QuickJS run**, and the whole shape was built twice to find
out where: once with the tuple looked up in the process dictionary at the
crossing, once with it emitted as a literal into the generated code so there is
no lookup at all. Both measured the same 8%, so it is neither. Base-first and
head-first orderings both showed it, so it is not the running order either.
Generated code grew by 22 KB of 10.9 MB, so it is not size.

That leaves `do_call/4` itself, and this is the fourth time an extra call on
that path has cost far more than what it does: see the operand-cache entry
points, the threaded locals, and the `branch/3` traversal. The mechanism is
still unproven and `run/3`'s two hundred clauses are still the suspect.

**Reverted, and the design changed rather than the measurement.** Shards do not
need the interpreter to know where anything lives: shard 1's `invoke/6` can
call shard 2's by name, as a literal, when it is handed an index it does not
hold. The chain costs one call per miss *inside generated code*, and
`wasm_exec` is untouched. That is what to build.

**Chaining shards in generated code, instead of a tuple in the interpreter.**
After the tuple in `#st.code` cost 8%, the same problem was solved without
touching `wasm_exec` at all: each generated unit names the next as a literal and
hands over any index it does not hold. It works and it is tested, and one
mistake in it is worth keeping. The chain runs one way, so a crossing back into
the interpreter has to name the **head** of the chain rather than the unit it
left; naming itself meant a caller that re-entered in the middle could only
reach what was below it, and one call in five was silently interpreted.

The test for it had to be written three times. Identical answers prove nothing,
because a chain that does not chain falls back to the interpreter and answers
the same; asserting `entered` moved was what made it fail when the chain was
broken. Then the first version of that assertion was itself wrong, because
`compile_sync` builds at the *end* of an invocation and the call that triggers
it is interpreted.

**Still off by default.** It works on the calling process and fails through the
background compiler, two different ways, and neither reproduces from a harness
that skips the interpreted first instance. `PERF.md` has both.

## Numbers that were withdrawn

**The QuickJS benchmark arm never ran any JavaScript.** For its entire
existence it exited with `wasi_exit => 2`, a WASI usage error, and the result
was discarded rather than asserted. It was timing an argument-parsing failure
and calling it 300,000 JavaScript iterations. This build takes a file and
nothing else, so the script now goes through a preopened directory. The real
run was 24,920 ms against the 109 ms it used to report. As a deterministic
workload it still detected regressions, so what it caught was real; the label
was not.

**A 38.4 ms against 109.1 ms improvement**, measured with the tier on while
`wasm_jit:counts/0` said `entered => 0`. Unexplained, so never recorded.

**"1.33x faster with the compiled tier"** from `cbad77c`. That arm took
`best(2, ...)`, and the two runs were not draws from one distribution: repeating
QuickJS in one process is bimodal on collection time. The minimum landed on a
fast run for one arm and a slow one for the other. `realbench` now runs each
iteration in a fresh process and reports every run.

**Coverage predictions are systematically optimistic.** `call_indirect` was
predicted to take QuickJS to about 84% and took it to 76.6%, because
`memory.copy` refusals went 43 to 107 and `memory.fill` 0 to 31: they were
standing behind `call_indirect` in functions using both. The histogram counts
the *first* refusing instruction per function, so it is an ordering and not a
census. Do not predict the next number by summing rows.

## The four changes that made the tier pay, in order

Worth reading as a sequence, because each looked finished and was not.

**The boundary was a one-way door.** `wasm_jit:entry/3` ran only at depth zero
and `wasm_exec` never consulted the code slot, so the first refused function or
the first `call_indirect` dropped the whole program into the interpreter
permanently. Making it two-way took interpreted calls per QuickJS run from
23,069 to 1,013, and bought **nothing**.

**Floats.** 83% to 93% of functions. Bought nothing.

**SIMD.** 93% to 100%, and **9.0x**. One `v128.const` in the bytecode
interpreter had been keeping the hot function, and therefore the whole program,
out of compiled code.

**Compile economics.** 107 seconds inside the first call, to 22 seconds on
another process compiling only the 223 functions that ran. Nothing waits for it
now.

| | functions compiled | execution compiled | wall |
| --- | ---: | ---: | ---: |
| one-way boundary | 83% | ~0% | 1.0x |
| two-way boundary | 83% | ~1% | 1.0x |
| plus floats | 93% | ~1% | 1.0x |
| plus SIMD | **100%** | **100%** | **9.0x** |

**There is no partial credit.** One unsupported instruction anywhere in a hot
function keeps that whole function interpreted, and a language runtime's
execution concentrates in one or two functions. Finishing a subset is worth more
than growing it, and no static count can see that.

## Two defects the tests found

**A killed caller pinned its slot for ever.** A call lease is given back in an
`after`, which does not run for an untrappable kill, and killing a process is
how a runaway invocation is stopped here. Sixteen killed callers and nothing
could be compiled again for the life of the node. Found by
`wasm_jit_lifetime_SUITE` on its first run.

**And the obvious repair was unsound**, which `wasm_code_slots_SUITE` said
before it shipped. Treating `code:soft_purge/1` as the authority breaks the
window between taking a lease and entering the code, where reuse means running
the new module's function at the old module's index. `soft_purge` is also blind
to it twice over: it purges only code already marked old, so with nothing old it
answers `true` whoever is running. The fix was to stop excluding reuse and check
the slot generation inside the callee, which is atomic with the call in a way no
lease can be.

## What is failing now

**~~The tier buys nothing on QuickJS.~~** Fixed, in the four changes above. It is
8.4x, and the interpreter executes none of the program.

**~~The first QuickJS run in a node is 6.6x faster than every run after it.~~**
Solved, and it was not node-global. Repeating the workload in one process is
bimodal on collection time, about 1.7 s or about 13 s, against identical
reductions and byte-identical output. `msacc` settled it in one run by showing
collection rather than emulator time. A fresh process per run takes the spread
to 1.02x, and QuickJS actually runs in 1.6 to 1.8 s. Every 12-second figure
taken before this was an artefact. Still open: why it is bimodal, and why the
interpreter needs a 10-million-word heap for a workload whose live data is a
1.7 MB linear memory.

**The differential harness could pass without compiling its subject.** It
generated the module and compared it against the interpreter but never checked
that the exported function was in the generated unit, so a case the generator
quietly refused would have compared the interpreter against itself. Nothing was
slipping through, but that was luck. It asserts membership now.

**Shedding function bodies to shrink the heap.** The interpreter's process heap
peaks at 10 million words on QuickJS, and 25.5 MB of that is the decoded bodies
of the 1443 functions out of 1666 that are never called. Holding each body as a
slice of the module binary instead, and decoding it on first call, takes
`#module{}` from 35.4 MB to 0.9 MB. **It is a 10x regression**: 16.6 s against
1.6 s. The 35 MB was accidentally acting as a heap floor, and the real number is
that the interpreter allocates **1.4 billion words per run**, so collection cost
is set by heap size and not by live-set size. With `min_heap_size` at 4 million
words it is 2.3 to 2.6 s, better than the same heap without shedding. The work
is on the `lazy-bodies` branch; neither half ships alone.

**Closing over locals instead of passing them.** A control frame only needs a
local as a parameter if its body might reassign it; otherwise Core can close
over it. Correct, and it removes the scaling with local count entirely on the
synthetic loops: 15.6 nanoseconds an iteration at 120 locals down to 3.4, and a
256-arm dispatch loop from 10.2 to 4.9. **2.7% slower on QuickJS**, across five
interleaved pairs. It moves locals from a continuation's parameters to its free
variables, and a `letrec` with free variables is a closure: a frame entered once
amortises that away, a frame entered constantly pays it, and real compiler
output nests 257 deep. The fourth time the synthetic loop has disagreed with the
real module, and the first where the mechanism is understood.

## Open, and each a decision rather than a task

**~~The rest of the memory path.~~** Done. A load or a store is generated inline
for the ordinary case -- in bounds against this handle's own view, not
straddling a word -- and everything else still calls `wasm_exec`, which is
unchanged and remains the only path that can trap. It also required a *private*
memory for a while, which meant it never ran at all; see below. 43% off a store and a load, five interleaved pairs
agreeing in direction. The coupling is a header of field indices with a test
asserting they match the record, so adding a field fails a test rather than
reading the wrong word.

**Multiple shards per module.** Compilation is one shot: a function that first
runs after the module was built stays interpreted. Needs a function-index to
slot mapping that single-slot adoption does not have, and a phased workload to
measure, which does not exist as a fixture.

**The interpreter's heap.** Repeating a real module in one process is bimodal on
collection time. A fresh process per invocation is reliably fast; shedding
function bodies plus a heap floor was the fastest measured and still alternates.
Which to adopt depends on how an embedder runs invocations, and the `lazy-bodies`
branch holds the shedding half.

**The artifact cache.** Where it lives, what evicts it, and what it trusts are
the questions, not the code.

**Turning the tier on by default.** Every gate item passes and the answer is
still no: 8.4x on a language runtime, flat on a plugin, and tens of seconds of a
core spent on a guess a default cannot make.

## The memory path, measured against wasmtime and wasm3

**~~The compiled tier is 60x slower than wasmtime.~~** Not uniformly. Arithmetic
is 3.33 ns an iteration and a call 6.3 ns, both faster than wasm3 and 4.6x and
7x Cranelift. Memory was 125.9 ns a store-and-load against wasm3's 4.3, and it
was the whole gap.

**The inline memory path had never executed.** Its guard required a *private*
memory and `shared_mems/1` publishes anything imported or exported, which every
toolchain's memory is. Fixed, with the short-circuiting guard: 125.9 to 48.5 ns
traced, 29.0 clean. QuickJS 208 ms to 168.

**Hoisting the memory handle is worth 1.15 ns, not tens.** It was the standing
open item here. Hand-written Erlang with the handle and its fields bound once
outside the loop: 33.04 ns against 34.19 refetching per access. `element/2` on a
known tuple is about one instruction. Removed from the list rather than done.

**One `atomics` slot per i32 is blocked, not declined.** It would take the store
floor from 22.7 ns to 10.35 at 2x the footprint, and `update_word/4` CAS-loops
on a whole 64-bit element to make `i64.atomic.rmw` atomic. Two slots cannot do
that. The aligned splice took 6.3 of the 16 ns without the trade.

## Instantiation and the call boundary

**A module's functions were built once per instance.** `compile_fn/4` depends
only on the module and its cached validation context, and instantiation lowered
every body again: about 85% of it. One entry keyed on the module, the same cache
`wasm_validate:cached_context/1` keeps. 317 us to 75.

**The compiled entry was rebuilt on every call**, and its lease did an
`ets:lookup` to re-check a slot key that the stamp inside generated code already
covers. Cached per instance under a bare reference; the row lookup stays only
for a `reference()` identity, which needs the generation. 373 ns to 304.

**Bulk memory resolved the chunk per eight bytes.** 4 KB `memory.copy` 12.5 us
to 5.1, which is the two-`atomics`-per-word floor.

**Lazy chunk allocation is not available.** 68 us of the plugin's instantiation
is allocating chunks, but a memory handle is immutable inside `#mut{}` and
`store_at/6` answers `ok`: publishing a newly allocated chunk means threading a
new `#mut{}` out of every store, which gives back more than it buys, or reading
the ETS cell at 37 ns per access. Stores not touching `#mut{}` is what makes the
`Mut1 =:= Mut` skip worth 177 ns of a 386 ns call.

## Rules these attempts produced

Measure the coverage of a restriction before designing around lifting it.
`subset.erl` killed one plan outright and halved a pool bound in another.

Run `realbench` on QuickJS and the plugin for anything touching the dispatch
path. The synthetic loop has said nothing while a change cost 70% or 75% three
times.

Assert that a benchmark arm did the work. One that cannot fail will report a
number for a run that did not happen, and did, for as long as it existed.

Assert that generated code was entered. Every failure in this design falls back
to the interpreter, so a green run and a good number prove nothing on their own.
That is what `wasm_jit:counts/0` is for.

Run each iteration in a fresh process, and never take a minimum across runs.
Repeating in one process is bimodal by 7x on collection time alone.

A live set and an allocation rate are different problems and look identical from
the outside. Both show up as collection time. Measure words reclaimed per run
before deciding which one you have: 1.4 billion of them said the answer was
allocation, after a 35 MB live set had made a convincing case for the other.

Count what executes, not what exists and not what is entered. Coverage said 93%
while 1% of instructions ran, and function-entry counts said the opposite of the
truth because a function entered once that loops for a second looks like a
function entered once. `bench/paths/tiered.erl` counts dispatches.

Reach for `msacc` before theorising about a timing anomaly. It partitions the
time into collection, emulator, port and auxiliary work in a single run, and it
answered in one run a question that four hand-built experiments had got wrong.

Reuse the interpreter's implementation rather than restating it in the
generator. Every trap, bound and width then has one definition, and the
conformance suite checks both paths at once.

Check the load average first. This box swings between 4 and 84.

State which run in the emulator a number came from. The first wasm run in a
fresh emulator and the fourth are 2.4x apart on identical work, because the
first one pays 183 major collections where the others pay one. A fresh process
per iteration is not enough on its own; `benchlib:in_process/1' gives you that
and not this.

## Block accounting for bulk array operations

**Charging a whole chunk of a bulk operation with one `wrote/2' instead of one
per element.** Measured before designing it, and the measurement is why it did
not get designed. Removing the per-element charge *entirely* is worth exactly
**1.0 reduction an element** on all three arms (`array.fill' sparse and dense
6.0 to 5.0, `array.copy' 7.0 to 6.0) and nothing at all in reclaimed words. In
time that is `atomics:add_get' at **4.8 ns net** against the two ETS operations
beside it at about 36 ns each, so the counter is about 6% of an element.

That 1.0 is a ceiling, not a saving: a chunk scheme still has per-chunk work.
And the version that just calls `wrote(H, Words)' once per chunk is wrong three
ways, none of which the interval size fixes:

- **`Extra' is checked and never reserved.** `wasm_keeper:ceilings/6' says so
  itself. Two callers can have chunks approved against the same pre-write
  measurement and then both write them. Per-element charging bounds each
  unreserved approval at 12 words; a chunk raises it to the chunk.
- **A chunk overestimates a dense overwrite.** A fill over rows that already
  exist adds little or no ETS memory, and a chunk-sized `Extra' asks the keeper
  to refuse as though all of it were new. That is a false refusal the current
  path does not have, and the dense arm exists to keep it visible.
- **A chunk size does not place a reconcile.** `crossed/2' depends on the
  counter's phase, so a chunk no larger than the interval does not guarantee a
  crossing inside it. A block scheme has to say how it aligns to the counter,
  not only how big it is.

The only correct shape is a keeper reserve, commit and abort for prospective
heap words, which changes the keeper's protocol. It is worth 6% of a bulk
element, so it waits for a reason better than that.

Measure the null before designing the optimisation. Deleting the thing you
mean to make cheaper takes one edit and bounds the whole design's value.

**Avoiding `uns(64, _)` in `i64.shr_u` with a case on the shift count.** Two of
the three cases genuinely do not need the mask: a non-negative value shifts
arithmetically, and a negative one shifted by six or more is
`(A bsr Sh) + 2^(64-Sh)` exactly, with both the addend and the answer inside
the immediate range. It is correct -- 187 pairs across every boundary agree
with the interpreter, with generated code entered 187 times -- and it is **two
to three times slower** than the mask it replaces: shift by 1 went 30.16 to
63.73, shift by 47 went 0.61 to 1.15, and the signed control did not move.

The three-clause case is what costs it. `wrap(64, bsr(uns(64, A), Sh))` is
branch-free, and the SSA type pass evidently does better with it than with
anything guarded. That is the same lesson as `wrap_sum/2` read backwards: a
guard helps when it *tells* the compiler a range it could not infer, and hurts
when it hides one it could.

The measurement that justified trying was also wrong, which is the other half
of this entry. See below.

A per-instruction snippet measures nothing unless the optimiser cannot remove
it, and there are four separate ways it can. `perinstr` reported 0.00 for ten
new rows twice running -- `(drop ...)` is dead code, a loop-invariant operand
is hoisted out of the loop, forty independent `local.set $t` are thirty-nine
dead stores -- and then, worse, reported a *number* for a row that was still
loop-invariant: the counter was xored into bits 0 to 17 and the instruction
under test shifted them away. That version read 0.74 signed against 30.71
unsigned and the 43x was reported as a finding. The honest pair is 26.05
against 30.16.

Accumulate into the local you read, and vary a part of the operand the
instruction keeps. `run_case/3` flags anything under 0.05 ns, which catches the
first three failures and not the fourth; the fourth is caught only by reading
each unsigned row against its signed twin, which is why they are laid out in
pairs. Four rows already in that file trip the flag.
