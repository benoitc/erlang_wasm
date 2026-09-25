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

**Raising `max_heap_size` to find a collection problem.** Three values, 1M, 4M
and 16M words, on the request runner, and none of them moved anything; the
conclusion drawn was that the runner's heap was not where the missing 26 ms of
a worker request went. It was, and this experiment could not have said so.
`max_heap_size` is a **ceiling**: the collector never sizes a heap from it, so
no value of it changes a collection count. The flag that matters is
`min_heap_size`, and with it the same request goes from 56.0 ms to 21.1 ms.
Recorded because the measurement looked clean, swept three values, and pointed
away from the answer.

**`+hms` standing in for a per-process floor.** The same finding was first
taken with the node-wide flag, which sizes the guardian, the reaper's children
and every other process in the emulator. It reproduces the effect and does not
measure the change that ships. Worth the distinction: `PERF.md` records a floor
set in place recovering a third of what the same floor set at `spawn_opt`
recovered, so where a heap floor is applied is a first-order question and the
two experiments are not interchangeable.

**A benchmark sweep with no control arm.** A CPython floor sweep over 400,000
to 4,000,000 words came back flat, 223 collections at every floor, including
the 400,000 that two other runs put at 97. It had no zero-floor arm in it, so
there was nothing in the run itself to say whether the floors were working at
all. A sweep of settings needs the off setting in it for the same reason a
comparison needs a null experiment.

**Looked for three times since, with the zero arm added, and not found.** The
three runs agree with each other to within 12% and give the ordinary curve at
every floor: 223 to 225 collections unfloored, then 97 to 99, 43, 29 and 19.
So the flat run stays what it was, a single unexplained result from a run that
could not check itself, and the entry stays as the reason to include a control
rather than as an open question. It is not worth a fourth run.

**A heap floor made a ceiling that had always been enough stop being enough.**
`capture_min_heap_words` at 2 M words with CPython's own
`py_reactor_adapter:limits/0`, whose `max_heap_words` is 16 M, kills the
capture about three times in four. The resolver's headroom check passes,
because that check is about the emulator rounding a floor up at *spawn*; what
kills it is that `max_heap_words` bounds the peak while a floor raises the
baseline the peak is measured from. Raising the ceiling to 32 M fixed it, three
runs for three.

Recorded for the failure's shape rather than its cause. It presented as
`killed` and nothing else, intermittently, after a ninety-second start, which
is close to the worst way a configuration error can arrive: the first three
attempts read as a flaky box and the fourth passed. `capture_elsewhere/2` now
answers `max_heap_words` and the floor in the error context when a capture dies
of `killed`, so the next person reads it instead of guessing.

**Three docs code blocks that had never been run.** `docs/javascript.md`,
`docs/lua.md` and `docs/python.md` each built a guest's source with
`~"one" "two"`, and adjacent sigils do not concatenate: it is a syntax error,
so all three examples failed to compile as printed. `<<"one" "two">>` is the
form that works and is what `wasm_wat_SUITE` already uses. Nothing catches
this, which is the point: the blocks were correct-looking prose for months.

**"The tier never engages on a reactor" was wrong, and the mistake was
measuring a background compile in requests instead of seconds.** The first
version of this entry reported `entered => 0` over 3000 requests through the
worker kernel and traced it to `compile/4` answering `retry` with no counter
and no diagnostic, which is true and is not the reason.

The reason is that **a reactor request is 21 ms against the command path's
~200**, so a given request count buys a tenth of the wall time, and the
compile of 264 QuickJS functions takes about 150 s whichever path asked for it.
3000 reactor requests is about two and a half minutes of *requests* but the
node exits when they finish. `the_tier_enters_a_compiled_worker` enters at
request 353 on the command path for the same reason in reverse: 353 requests
there is 76 s.

Every intermediate observation was real and every conclusion from it was
wrong:

| seen | read as | actually |
| --- | --- | --- |
| `compile/4` answers `retry` | the compile was lost | `claim_loading` said `loading`: the first compiler was still working |
| `counts/0` all zero, `diagnostics/0` empty | nothing happened | `retry` bumps no counter by design, and a compile in flight is not an outcome |
| a direct probe entered at request 70 | the kernel was at fault | the probe called `ready`, a trivial export, so it compiled almost nothing |

The last row is the one worth keeping. A probe written to isolate a component
has to run the *same work*, and `ready` against `handle` is not the same work
by two orders of magnitude. It made a 150-second compile look like a
one-second one and turned "slow" into "broken".

What made it visible in the end was dumping `wasm_code_slots`'s own table and
`supervisor:count_children(wasm_jit_sup)`: one slot `{loading, Key}` and one
live compiler says "in progress" where every counter says "nothing happened".
`workerbench`'s `tier` mode now waits on a **wall-clock** deadline, driving
requests while it waits, because the tier advances when calls happen.

**~~And the answer the corrected measurement gives is still no.~~** It was, and
for a reason that has since been fixed. The tier entered at request 3295 and
then 31 requests in 32 kept interpreting, because adoption was gated behind the
same `hot/2` counter that triggers compilation and a reactor builds a fresh
instance per request. `wasm_jit:maybe_adopt/3` now asks about residency first
and consults the threshold only when nothing is resident; `PERF.md` has the
three-guest measurement.

**Two ways of fixing it that were rejected before the one that shipped**, both
recorded because each is the obvious first idea:

- **`compile_after => 1` as the default.** It would have made adoption
  immediate by making the threshold trivial, and broken the other thing the
  threshold does: compilation would start from a single unrepresentative first
  request, so `wanted/2` would compile whatever that request happened to touch.
  It would also have re-checked residency, and with it `claim_loading/3`, on
  every call while a compile was still in flight. The two decisions had to be
  separated, not collapsed.
- **Adopting inside `wasm:restore/3`.** Tempting because restore already holds
  the module handle, and wrong because it pays a manager round trip for every
  instance including those that never make a call. `entry/3` reaches the same
  answer on the first call and charges only instances that do.

**And one measurement design that was rejected**: pricing the added residency
lookup off the prewarm population. Prewarm contains the background compiler,
and the two revisions do not even reach residency after the same number of
requests, so the samples are not comparable. A no-compilation control arm --
tier on, `compile_after` above every call the arm makes -- prices the lookup
and nothing else, and put it at 0.15%.

**A sharded compile cannot be cached without a bigger key, and is not.**
`wasm_code_cache:key/6` carries the module's identity, the ABI, the slot, the
quality, the function set and the stamp. A sharded artifact also embeds `Head`,
the module a crossing re-enters through, and `Elsewhere`, which says where the
other functions live, and the key describes neither. A cached shard could
therefore be adopted into a chain headed by a different module than the one
compiled into it, so `cached/6` only looks for a single-unit compile.

`no_shard_of_a_sharded_compile_is_cached` is what holds that, and it was itself
watched to fail on a parent where the *last* shard was cached: `build/8` passed
`tl(Mods) ++ [undefined]`, so the final shard had no `Next` and took the
cacheable branch.

It is a real warm-start cost and not only a safety note: a guest large enough
to split across units recompiles on every node start however warm the cache is.
Closing it means **extending the key to cover `Head` and `Elsewhere`**, which is
a change to what a cache entry means rather than a missing argument, and it
belongs with the cold-start work rather than with the directory's trust model.

**~~An image is unreadable on a node that has not interned `funcref`.~~**
Found, diagnosed and fixed. Recorded because the shape of it is general and the
symptom was silent.

Every `coldnode` arm for CPython exited on the harness's guard --
`{worker_captured_rather_than_loaded, 104035, 20000}` -- with a 2.6 MB image
for that exact configuration already filed where the worker was looking. Not
the key: it computes to exactly the filename on disk. The load refused:

```erlang
#{kind => snapshot_unknown_atom, class => malformed,
  msg  => <<"the image names an atom this node does not have">>,
  ctx  => #{name => <<"funcref">>}}
```

`wasm_snapshot_file` decodes atoms with `binary_to_existing_atom/2` so nothing
in a file can mint one, which is right. CPython's captured tables hold
`funcref`. And on a node that had just started the application that atom did
not exist -- `binary_to_existing_atom(<<"funcref">>, utf8)` raised `badarg`
straight after `application:ensure_all_started(wasm)`.

**So whether an image loaded depended on which modules the emulator happened to
have loaded**, because loading a module is what interns its literals and Erlang
loads lazily. Nothing about it was specific to CPython: any image whose tables
hold a `funcref` was exposed, and QuickJS and Lua loaded only because something
had interned it first. `lookup/2` turns every failure into a miss, by design,
so the whole thing presented as a silent hundred-second capture.

`own_atoms/0` now lists the six atoms an image's own values can contain, as
literals in that module, so they exist from the moment the decoder is loaded --
which is before it can decode anything. The set is exactly what
`wasm_snapshot:admissible/2` admits. An atom a *hook* kept still has to exist
already, because that one really does come from outside. Worker start:
**104,035 ms to 1,134 ms**.

**The test needed a node of its own, and the first version of it was vacuous.**
In the suite's node everything is loaded long before a case runs, so the
property cannot be asked there; `every_atom_an_image_holds_exists_once_the_
decoder_is_loaded` starts a `peer` with `standard_io` (a named peer wants
distribution, and the suite is `nonode@nohost`), loads only the decoder, and
checks each name. The first attempt read the list *from `own_atoms/0`*, so
deleting `funcref` from the fix deleted it from the test in the same motion and
the case went on passing. It carries its own literal list now, and asserts the
two agree.

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
the questions, not the code. **What evicts it is now answered**: oldest first
past a total size, in `wasm_file_cache`, shared with the snapshot image store
which had no cap at all until that was lifted out. Where it lives and what it
trusts are still open.

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

**Measuring lowering with the sizing instrument still in the window.** The
experiment that reported lowering at 39% of a QuickJS request had the isolation
right and the build wrong: the cold arm ran an instrumented `wasm_instance`
whose `body_of/2` called `erts_debug:size/1` on every lowered body, and the
pre-lowered arm ran the same call in its setup, where nothing is counted. The
difference between the arms was the instrument, not the runtime.

`erts_debug:size/1` allocates 172 words for every word of term it walks:
34,490,334 words a call on a 200,000-word list. On 725,535 words of retained IR
that is the whole 20.6 M the experiment attributed to lowering. Clean, lowering
is 764,533 words, 2.7%.

Nothing in the run looked wrong. Both arms produced the right reply, the
estimator validates to 0.0%, the pre-lowering demonstrably happened, and the
two numbers were 20 M apart. A subtraction between two arms is only as clean as
the code they *both* load: a module reached through `-pa` is part of the
measurement. `bench/paths/pyarms.erl` prints `code:which/1` for `wasm_exec`,
`wasm_instance` and `wasm_jit` on every arm, and reproduces both the wrong and
the right numbers by that path alone.

**`erlang:trace_pattern/3` on a module the emulator has not loaded matches
nothing.** It answers 0 rather than an error, and `trace_info/2` then reads
`undefined`, so a dispatch count comes back as a missing value instead of a
failure. `bench/paths/tiered.erl` never hit this because it warms the workload
first; anything that sets the pattern before the first call has to
`code:ensure_loaded/1` and match the 1 that `trace_pattern/3` returns.

**A trace pattern set on a module the emulator has not loaded, twice in one
session.** The second time it produced a whole wrong mechanism. Probing why a
compilation never happened, `erlang:trace_pattern({wasm_jit, compile, 4}, MS,
[local])` answered **0** because `wasm_jit` was not yet loaded, so `compile/4`
never appeared in the trace and the conclusion was "the worker never received
its work, so the ask dies with the process that raised it". That went into
`PERF.md` as a finding.

With `code:ensure_loaded/1` first and the pattern's return matched against 1,
the same arm shows `compile/4` entered and the compiler still running at 45
seconds. The real answer was that QuickJS takes 165 seconds to compile and the
watch had been given 60, and that CPython threw `{limit, too_many_functions}`.

Match the 1. `trace_pattern/3` returning 0 and `trace_info/2` reading
`undefined` are the same shape as a runtime that does nothing, and a trace that
matches nothing will confirm any story told about it.

**Pointing `compile_whole` at CPython.** With the name pool at 4096 the
four-unit ceiling is 16,384, so CPython's 11,447 eligible functions are no
longer refused and the compiler starts on all of them. It reached **33 GB
resident on a 48 GB box in eleven minutes**, with 66 MB of memory free, 0% CPU
because it was paging rather than compiling, and nothing published. Killed.

The ceiling bounds the *names* a unit may use. It says nothing about whether
`compile:forms/2` can build what is under it, and for a 25 MB guest it cannot.
`docs/compiled-tier.md` already called the option affordable only on
specification modules; this is the number behind that sentence.

Compiling what ran, which every default does, is 2,333 functions, 1,105 seconds
and a fraction of the memory.

**A `max_heap_size` fuse on the compiler.** The plan was to cap whatever runs
`compile:forms/2` so a guest nobody anticipated dies as a killed compiler rather
than as a paging node. Measured on QuickJS at one unit, the process `wasm_jit`
spawns peaks at **0.34 GB of heap** while the node reaches 6.19 GB: the work is
not there. `compile:forms/2` spawns a process of its own by default and runs
everything in it, and nothing we set reaches that child.

`no_spawn_compiler_process` moves the work into our process, where the cap can
see it -- 4.16 GB -- and costs **293 seconds against 167**, on the same box at
the same load. The child was never collecting: it allocates, returns the binary
and exits, and a dying process frees its heap for free. Living through the
allocation means paying for the collections.

A fuse that sees 0.34 GB of a 6 GB compile is not a fuse, and 75% of compile
time is too much to buy one. Neither shipped. What is left open is bounding
compile memory at all, and the obstacle is not the number: it is that the memory
is spent in a process only the OTP compiler can configure.

## Reusing a destroyed instance's memory for the next restore

**Handing the next restore the page chunks the last request's instance used,
zeroing only what that request wrote.** Not built, because the second half has
no cheap implementation. Measured on a CPython restore (42 MB of linear memory,
43 chunks of 1 MiB):

| | alone | 14 at once |
| --- | ---: | ---: |
| whole restore | 12 ms | 22 ms |
| allocating and first touching 43 fresh chunks | 4.0 to 4.4 ms | 11.1 ms |
| the same with `+MMmcs 30 +MMamcbf 1000000` | 2.4 ms | 5.2 ms |

eprof puts nearly all of the rest in `wasm_memory:scatter_run/3`, one
`atomics:put/3` per 64-bit word of the image's non-zero runs, 924k of them.
That part a reused chunk still has to do.

What a reused chunk also needs is every word the request wrote outside those
runs set back to zero, and nothing records which those are. Without a record
the only safe reset is all of it: 5.2M `atomics:put/3` calls, about 60 ms, five
times the allocation it would replace. A record means a write barrier, one
more operation on every guest store, on the path where three smaller changes
have cost about 70% on QuickJS. Guessing is not an option either way: a word a
reset misses is one tenant's data in the next tenant's memory.

What was done instead: `restore_ahead` takes the restore off the request's
path when the worker has idle time (14.8 ms of deliver and restore becomes
38 us), and `docs/tuning.md` gives the allocator setting that halves the
allocation under concurrency. A write barrier would be worth revisiting only
with a design that costs the store path nothing measurable on QuickJS.

**Reading the request's context from a host call instead of a staged file.**
Not built. With staging raw, the stage phase of a CPython request is 0.67 ms of
52, and a host call would change each adapter's guest side for that.
