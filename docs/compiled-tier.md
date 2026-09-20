# The compiled tier

Every instance starts **interpreted**. The compiled tier, off by default,
turns the functions a module calls most into BEAM code, through Core Erlang,
and runs that instead. These are the two **execution modes**: interpreted
always, compiled once a module is hot. Read this page before you turn it on.

**Do you need this?** Yes, if a guest runs long, such as an interpreter: it is
worth 8.4x on a language runtime. No, for a small plugin, where it is flat;
measure your own module before deciding.

For how the tier is built, and the options that exist only for the
conformance suites, see [Design notes](design-notes.md#the-compiled-tier-for-someone-changing-it).

## Turn it on

Per instance:

```erlang
{ok, I} = wasm:instantiate(M, Imports, #{compile => true}).
```

A module is compiled once it has been called `compile_after` times, 32 by
default, counted per module rather than per instance so a workload of
short-lived instances still gets hot. Every function the compiler can take
becomes a Core Erlang function in one generated BEAM module; everything else
stays interpreted, and the two call each other through the ordinary paths.

Locals become Core variables, so `local.set` is a new binding rather than a
tuple update. The operand stack is a compile-time list and does not exist at run
time. Control frames become Core functions and a branch becomes a tail call.

Wait for it when you want to, which tests and warm-up paths do:

```erlang
{ok, I} = wasm:instantiate(M, Imports, #{compile => true}),
ok = wasm_jit:await(I, 60000).
```

```erlang
wasm_jit:counts().    %% #{compiled => N, entered => M, reentered => K, cached => C}
```

## Keep what it compiled, or pay for it on every start

Turn this on at the same time. Without it a node recompiles from scratch every
time it starts, and for a reactor that is about 150 seconds and several
thousand interpreted requests before the tier arrives.

Set it as release configuration, so it is in force before anything is
instantiated:

```erlang
%% sys.config
[{wasm, [{code_cache_dir, "/var/lib/my_release/wasm"}]}].
```

**Reading a cache entry is executing it**, so the runtime checks the directory
before it trusts one and refuses it otherwise. What it requires:

- **absolute**, with no `.` or `..`, and owned by the user the node runs as
- **no group or other write bit**, on it or on any directory above it. `0700`
  and `0750` are the sensible choices; any mode without those bits is accepted,
  so a `0755` directory you own is fine
- **every directory above it owned by root or by you**, not merely unwritable
  by others: one owned by somebody else at `0755` is not group-writable and its
  owner can still replace what is beneath it
- **nothing on the path a symlink**
- **every parent must already exist.** The runtime creates the last component
  if it is missing, at `0700`, and creates nothing above it
- **not under `/tmp`**, which fails the mode rule on every ordinary system

A directory that does not qualify is refused, the cache is simply off, and the
log says so once. Nothing fails: a refused cache is a slower start, never an
error.

**Why this is opt-in when a release you control should almost always turn it
on.** A library cannot invent a safe place to keep executable artifacts. Where
a release keeps its state is your decision, and a default this code picked
would be a directory it could not vouch for. So it asks.

The entry itself carries a checksum, verified before the bytes are loaded, so
a file damaged by a crash or a bad disk is a miss rather than a broken start.
That catches **damage, not a hostile writer**: see [Security](security.md).

## What to do at startup

The cache spares a node the **compile**. It does not spare it the requests
before the compile is asked for, and it only helps a workload that executes the
same functions as the one that filled it. Both of those shape what a host has
to do.

1. **Configure an absolute, trusted, persistent `code_cache_dir`**, as above. A
   directory that does not qualify is refused and the node recompiles on every
   start.
2. **Load the guest with a stable content identity** -- `wasm:load/1` on
   committed bytes. A module built from text takes a fresh `reference()` every
   validation and is **never cached**.
3. **Run one fixed representative request at startup**, and do not vary it
   between deploys. Pinning it is what keeps the cache key stable; it is a rule
   of thumb rather than the mechanism, since what the key actually turns on is
   the set of functions a request executed.
4. **There is no supported way to wait until the tier is ready**, and no
   request count substitutes for one. See the limitation below.
5. **Admit traffic knowing early requests interpret.**

What it is worth, measured on a reactor worker:

| guest | cold start | warm start |
| --- | --- | --- |
| Lua | 47 s, 3,835 requests | **0.5 s, 44 requests** |
| QuickJS | 147 s, 6,412 requests | **1.5 s, 34 requests** |
| CPython | 319 s, 1,908 requests | **7.7 s, 33 requests** |

And what a *different* script gets from that warm cache: nothing. A second
script against a cache filled by the first paid the full cold cost again and
wrote a second entry, because it executed a different set of functions.

**The readiness limitation.** `wasm_jit:await/2` takes an instance, and a
worker destroys its instance after every request, so a worker host has nothing
supported to wait on. Waiting for the compile rather than serving through it is
worth a great deal -- on Lua it is 32 interpreted requests instead of 3,835,
for the same wall time -- which is why this is recorded as a gap rather than
left unsaid. `test/audit/PERF.md` has the measurements.

## Know what you will get

**Coverage is not speed, and there is no partial credit.** A single unsupported
instruction anywhere in a hot function keeps that whole function interpreted,
and a language runtime's execution concentrates in one or two functions. QuickJS
was worth 1.0x at 93% of functions compiled and **9.0x at 100%**, with nothing
in between.

Check what the subset leaves for a module of your own:

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/coverage.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run coverage main your.wasm
```

It reports the share of functions that compile and, for the rest, the first
instruction that refused each one. Expect the number to matter only when it
reaches 100 for the functions you actually execute.

What the subset covers today: i32 and i64 arithmetic including the trapping
division and remainder, comparisons, the conversions, locals, constants,
structured control with `br_table` and `select`, 32-bit memory loads and stores,
globals that are not shared cells, direct and indirect calls, bulk memory
(`memory.copy`, `fill`, `size`, `grow`, `init` and `data.drop`), the whole float
set, and the whole SIMD set. Not exceptions, not the GC types, and not
memory64.

**Exporting a mutable global costs you every function that reads it.** An
exported mutable global becomes a reference cell rather than a value, and a
function reading one is refused with `{unsupported, global_get_ref}`. That is
the "globals that are not shared cells" clause above, and it is easy to trip
without noticing, because nothing about the module looks different and the
interpreter answers correctly either way. It is worth checking against
`subset.erl` if your eligible-function count is lower than the instruction list
above suggests: a module that exports its mutable globals can lose every
eligible function to it, and removing only those exports puts them back.

**Only the functions your workload actually ran are compiled**, which for
QuickJS is 223 of 1666 and about 23 seconds of a core in the background. A
function left out is interpreted and can still call back into compiled code.

That is one shot: a function that first runs after the module was built stays
interpreted. So this suits long-lived instances of modules you run repeatedly,
and a workload whose hot set changes over time gets less from it.

**A very large hot set is compiled into several BEAM modules, not one.** Every
name a unit can use comes from a pool generated at startup, because nothing a
guest supplies may become an atom, and that pool is **4096** functions deep. A
hot set past it is split across as many as four units, automatically; below it
nothing is split, and you want it not to be, for two reasons. A call between
units is a crossing rather than a call, which costs: CPython allocates 217 M
words in one unit against 306 M in four. And **only a unit that ends its chain
is cached on disk**, so a split hot set is recompiled on every node.

Ask `wasm_jit:shard_count(NFuns, Limits)` what a given hot set would do, or
`wasm_jit:shards(Instance)` how many units it is actually resident in.

CPython 3.12 reaches 2,333 functions in a single `_start`, which is one unit and
an 80 MB artifact: 1,105 seconds to compile the first time, two seconds on the
next node to see it.

Past four units there is no split that fits, and the answer is a refusal rather
than silence:

    1> wasm_jit:counts().
    #{compiled => 0, entered => 0, reentered => 0, cached => 0,
      refused => 1, failed => 0, crashed => 0}
    2> wasm_jit:diagnostics().
    [{refused, {{sha256, <<...>>}, 3}, {limit, {too_many_functions, 16385}}}]

`counts/0` says how many, `diagnostics/0` says what: the reasons are normalised
to a bounded shape and the last few dozen are kept.

## What turns it off underneath you

**Every refusal means interpret**, and none of them is an error: a function
outside the subset, a slot pool with nothing free, another process already
compiling the same module, a finite fuel budget, a compile failure, or a
compiler over its heap ceiling.

**Metered execution is interpreted.** Fuel is charged at every loop back edge,
and charging it round a compiled loop gives back what compiling it bought, so an
invocation with a `fuel` limit does not use compiled code even when the module
is already compiled. That is per invocation: the same instance called without a
limit is compiled again.

**To cancel a running invocation, kill the process.** Compiled code carries no
deadline or interruption check, for the same reason: a test on every back edge
costs what compiling it bought.

Killing a caller inside compiled code is safe and costs nothing lasting. It does
leak the call lease, because that is given back in an `after` and an `after`
does not run for an untrappable kill, but a leaked lease no longer pins its
slot: generated code checks the slot generation it was built for against the one
its caller was promised, so reuse is safe whatever the counter says.
`wasm_jit_lifetime_SUITE` covers this, along with a compiler killed mid-flight,
an instance destroyed while it compiles, and more modules than slots.

Nothing derived from a module ever becomes an atom. Generated module names come
from a fixed pool of sixteen in `wasm_code_slots`, and function and frame names
from bounded pools in `wasm_core`, so the number of atoms the compiler can ever
create is a literal you can read in the source.

## What the cache keys on, and what bounds it

Set it as shown in [Keep what it compiled](#keep-what-it-compiled-or-pay-for-it-on-every-start)
above; this is the reference. QuickJS takes 0.2 seconds instead of 43.7 on the
second start.

A key covers everything that would make an artifact wrong if it changed: the
module's content hash, the ABI between generated code and `wasm_exec`, the OTP
release, the emulator flavour, the architecture, the quality asked for, the set
of functions compiled, and the slot it was built for. A module identified by a
`reference()` rather than a content hash is never cached, which is every module
built from text.

A **sharded** compile is never cached either, and that one is a real
limitation rather than an oversight: a sharded artifact embeds the module a
crossing re-enters through and where the other functions live, and the key
describes neither, so a cached shard could be adopted into a chain headed by a
different module. A guest large enough to split therefore recompiles on every
start.

The directory is bounded by total size, oldest first, and `wasm_code_cache:purge/0`
empties it. `purge/0` validates the directory like everything else, so it will
not follow a rejected path and delete files somewhere else.

## What a reactor gets, and what it costs to get there

A worker that restores a snapshot per request builds a **fresh instance every
time**, and an instance attempts adoption on its first call, so a reactor
reaches resident code on every request rather than on the one in 32 where a
hotness counter happens to fire.

What a whole request costs, per guest, interpreted against the tier once it is
resident. Both arms have the heap floor on, so this is the tier's own share and
not the floor's. Twelve paired samples, medians, all three guests in one
session:

| guest | interpreted | with the tier |
| --- | ---: | ---: |
| Lua | 11.4 ms | **4.4 ms** |
| QuickJS | 20.4 ms | **6.9 ms** |
| CPython | 93.1 ms | **37.6 ms** |

Throughput at fourteen workers rises about three quarters over the same guest
interpreted.

**Most of what is left is not the guest's code**, and how much depends entirely
on the size of the image being restored. The same requests, by phase, tier on:

| guest | accept | deliver + restore | invocation | reply |
| --- | ---: | ---: | ---: | ---: |
| Lua | 1.18 ms | 0.26 ms | 2.35 ms | 0.03 ms |
| QuickJS | 1.42 ms | 0.56 ms | 4.38 ms | 0.06 ms |
| CPython | 1.99 ms | **13.5 ms** | 20.7 ms | 0.86 ms |

The tier can only act on the invocation, and it does so evenly: 3.9x on Lua,
4.0x on QuickJS, 3.7x on CPython. What separates the guests is the restore --
0.26 ms for Lua's 196,608-byte memory against 13.5 ms for CPython's 41.9 MB --
and accepting a request, which is a fixed 1.2 to 2.0 ms and therefore a quarter
of a Lua request and 5% of a CPython one. `test/audit/PERF.md` has the full phase
tables and what is in each interval.

**Budget for the cold node, because that is where the cost now is.** The tier
arrives after a fixed amount of compiling, and a reactor request is roughly ten
times faster than a command one, so it takes ten times as many requests to get
there: about 150 s and several thousand requests on QuickJS, every one of them
interpreted. `code_cache_dir` above is what turns the second start into an
immediate one; without it every node start pays that window again.

## Bound what a compile may spend

The runtime runs `compile:forms/2` in a process it spawns itself, so a heap
ceiling can be put on the process that actually does the work:

```erlang
application:set_env(wasm, compile_max_heap_words, 2_000_000_000).
```

A compile over it is killed and **refused**, which means the guest interprets
and answers exactly as before, and `wasm_jit:diagnostics/0` says
`{limit, {compile_memory, Words}}`. Ask what is in force with
`wasm_jit:compile_limits/0`, which reports `max_heap_words => 0` when there is
none.

**Off by default**, because there is no number that is right for every guest:
QuickJS's compiler peaks around 2.5 GB, CPython's whole-module compile reached
33 GB, and CPython's *legitimate* 2,333-function compile sits between them, so
a ceiling low enough to catch the second refuses the third. Set it from a
measurement of your own module, and set it before you use `compile_whole` on a
large guest.

Three things it does not bound, and it is a ceiling rather than a guarantee:
Core generation, which happens on the calling process before the compiler is
spawned; anything that is not process heap, such as allocator memory and node
RSS; and the sum across concurrent compiles, since sixteen compilers may each
sit under it. `max_heap_size` is also checked only when a garbage collection
runs, so a compile can overshoot between collections.

A value that is not a whole number of words between `min_heap_size` and
`(1 bsl 59) - 1` is reported once through `logger` and ignored, rather than
turning the tier off for the life of the node.

## Bound what the whole node has in flight

The ceiling above bounds one compiler. Sixteen slots means up to sixteen of
them, so it is not a bound on the node:

```erlang
application:set_env(wasm, compile_budget_heap_words,
                    8_000_000_000 div erlang:system_info(wordsize)).
```

In heap words, the same unit as the ceiling, so the two compose. **It needs the
ceiling**: a compile reserves the ceiling it will be held to, so without one
there is nothing to aggregate, and a budget set alone is reported as 0 and said
once through `logger`. Divide by `Budget div Ceiling` to see how many compilers
it admits, or read `max_concurrent_compilers` from `wasm_jit:compile_limits/0`.

A request that does not fit beside what is already running is **refused**, so
the guest interprets and asks again at the next hot call. Nothing is queued: a
caller that waited would hold the unit IR it was admitted to compile for the
whole wait, which is the memory the budget exists to bound. A request larger
than the entire budget still compiles when nothing else is running, so a budget
set too low slows compilation instead of stopping it.

**What it bounds, and what it does not.** It bounds how many compiler workers
are admitted, each under the ceiling. It is steady-state capacity: a killed
compiler's reservation is released through a different monitor than the one that
kills it, so a replacement can briefly overlap it. And actual node memory is
that, plus each compiler's overshoot between collections, plus the coordinators,
which are not capped because under `compile_sync` the owner is your own process,
plus allocator carriers, which no in-VM bound covers. Leave headroom: on QuickJS
the coordinator added about 7% on top of its compiler.

Both are off by default.

**Sizing the ceiling.** Measure your own guest rather than copying a number:

```sh
erlc -I _build/default/lib -o bench/paths bench/paths/compileheap.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run compileheap main your.wasm 3
```

The `child` arm's `worker MB` is what one compiler of that guest peaks at. Take
that plus headroom as the ceiling. Predicting it from a module's size does not
work: peak memory per IR word spans 4.95 to 6.77 KB on one guest by estimator
choice alone, which is why the budget counts ceilings and not weights.

**Off by default, and the directory is as trusted as your release.** Loading a
`.beam` from it executes whatever is in that file, so it must not be writable by
anything you would not run as code.

Only modules with a content hash are cached, which means modules you loaded from
bytes. A module built from text takes a fresh identity every time it is
validated, so there is nothing stable to key on.

## Pick a profile instead of the knobs

`profile` names a workload. Everything it sets is an option you could set
yourself, and anything you do set wins.

```erlang
{ok, I} = wasm:instantiate(M, Imports, #{profile => plugin}).
```

| | `plugin` | `script` |
| --- | --- | --- |
| the shape | a module called many times through a long-lived instance | a program run end to end, usually an interpreter with a script |
| `compile` | `true` | `true` |
| `compile_quality` | `full` | `baseline` |
| `compile_after` | 32, the default | **1** |

**Why they differ, in numbers.** `full` is 75.0 to 76.8 milliseconds on QuickJS
against 86.1 to 87.7 at `baseline`, and costs 129.3 seconds against 58.1 to
compile the hot set. A plugin pays that once and wins on every call after it. A
script may be run a handful of times, so the cheaper compile wins unless it is
run thousands.

`compile_after => 1` matters more than it looks. A script is often a *single*
call -- `_start` and nothing else -- and the default threshold of 32 is never
reached, so nothing is ever compiled. The whole tier is invisible without it.

**Set `code_cache_dir` with `script`.** Otherwise the compile is paid at every
node start, and for a program run once per start the tier is a pure loss: 58
seconds to save 1.9. See `wasm_code_cache`.

An unrecognised profile is `{error, #{kind := unknown_profile}}`, not a crash.

## Short notes

- `full` is the default, which the profile table above says and this note used
  to contradict. `baseline` skips the OTP compiler's SSA optimiser and was the
  default while that optimiser bought nothing measurable; it buys something now,
  because the generator states value ranges the pass can use. QuickJS is **75.0
  to 76.8 ms at `full` against 86.1 to 87.7 at `baseline`**, and `full` costs
  129.3 seconds against 58.1 to compile the hot set. Ask for
  `#{compile_quality => baseline}` when the compile time matters more than the
  run. Figures in `test/audit/PERF.md`.
- Turning the tier on by default is a decision that has not been made. Every
  gate passes; the recommendation is still no, because it is 8.4x on one real
  workload and flat on another.
- The measurement record for all of this is `test/audit/PERF.md`, and the list
  of what was tried and reverted is `test/audit/ATTEMPTS.md`.
