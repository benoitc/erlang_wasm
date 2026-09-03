# The compiled tier

The runtime interprets by default. Turn the tier on and a module that gets hot
is compiled to Core Erlang, loaded as a BEAM module, and called instead of
interpreted. Read this before you enable it, and before you change anything in
`wasm_jit`, `wasm_core`, `wasm_code_slots` or `wasm_code_cache`.

It is worth 8.4x on a language runtime and flat on a plugin, which is why it is
opt-in. Decide with a measurement on your own module, not with this page.

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

## Know what you will get

**Coverage is not speed, and there is no partial credit.** A single unsupported
instruction anywhere in a hot function keeps that whole function interpreted,
and a language runtime's execution concentrates in one or two functions. QuickJS
was worth 1.0x at 93% of functions compiled and **9.0x at 100%**, with nothing
in between.

Check what the subset leaves for a module of your own:

```
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
above suggests: on a corpus of generated modules that exported everything, it
took 121 eligible functions to none, and removing only the global exports put
all 121 back.

**Only the functions your workload actually ran are compiled**, which for
QuickJS is 223 of 1666 and about 23 seconds of a core in the background. A
function left out is interpreted and can still call back into compiled code.

That is one shot: a function that first runs after the module was built stays
interpreted. So this suits long-lived instances of modules you run repeatedly,
and a workload whose hot set changes over time gets less from it.

**A large hot set is compiled into several BEAM modules, not one.** Every name a
unit can use comes from a pool generated at startup, because nothing a guest
supplies may become an atom, and that pool is 2048 functions deep. A hot set
past it is split across as many as four units, automatically; below it nothing
is split, because a call between units is a crossing rather than a call. Ask
`wasm_jit:shard_count(NFuns, Limits)` what a given hot set would do, or
`wasm_jit:shards(Instance)` how many units it is actually resident in.

CPython 3.12 reaches 2,333 functions in a single `_start`, so it splits in two.
Before that split happened it was refused outright, and silently:

    1> wasm_jit:counts().
    #{compiled => 0, entered => 0, reentered => 0, cached => 0,
      refused => 1, failed => 0, crashed => 0}
    2> wasm_jit:diagnostics().
    [{refused, {{sha256, <<...>>}, 3}, {limit, {too_many_functions, 8196}}}]

Past four units there is no split that fits and the answer is that refusal.
`counts/0` says how many, `diagnostics/0` says what: the reasons are normalised
to a bounded shape and the last few dozen are kept.

## What turns it off underneath you

**Every refusal means interpret**, and none of them is an error: a function
outside the subset, a slot pool with nothing free, another process already
compiling the same module, a finite fuel budget, or a compile failure.

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

## Cache the result across restarts

Compiling a module costs twenty to forty seconds of a core. Nothing waits for
it, but a node pays it on every start unless you keep the result:

```erlang
application:set_env(wasm, code_cache_dir, "/var/cache/my_app/wasm").
```

QuickJS then takes 0.2 seconds instead of 43.7 on the second start.

**Off by default, and the directory is as trusted as your release.** Loading a
`.beam` from it executes whatever is in that file, so it must not be writable by
anything you would not run as code.

Only modules with a content hash are cached, which means modules you loaded from
bytes. A module built from text takes a fresh identity every time it is
validated, so there is nothing stable to key on.

## The five modules, and what each decides

| module | decides |
| --- | --- |
| `wasm_jit` | when a module gets compiled and how a call reaches the result. Policy only. |
| `wasm_core` | what Core Erlang a function lowers to, and which functions it will take at all. |
| `wasm_code_slots` | which of sixteen module names the result may load into, and when that name may be reused. |
| `wasm_code_cache` | whether an artifact already exists on disk. |
| `wasm_jit_sup` | the processes that compile, so none of them is invisible. |

The compile runs in a supervised process that **owns** its slot reservation.
That is the whole lifetime argument: the reservation dies with its owner, so a
compiler that crashes or is killed costs nothing but the work.

## Read what it generated

If you change a lowering clause, look at the result rather than guessing:

```erlang
{ok, I} = wasm:instantiate(M, #{}, #{}),
io:format("~s~n", [wasm_jit:dump(I)]).       %% the whole unit
io:format("~s~n", [wasm_jit:dump(I, 12)]).   %% one function, by module index
```

`dump/1` builds the same unit the compiler builds and stops one step earlier, so
what you read is what would run. `wasm_core:module/6` calls
`wasm_core:forms/5` and compiles what it answers, and
`wasm_core_SUITE:the_core_you_can_read_is_the_core_that_is_compiled` holds the
two together.

## Three options that exist only for conformance

The defaults are what an embedder wants and are all wrong for a test that means
to check generated code, because each of them lets a test pass without any
generated code having run.

| option | what it changes |
| --- | --- |
| `compile_sync` | compile on the calling process, so the next call is already compiled |
| `compile_whole` | compile every eligible function, not only the ones that have run. Honoured on the background path as well as under `compile_sync`; it silently was not, and compiled what had run instead |
| `compile_force` | raise on a compile error instead of interpreting |

`wasm_spec_SUITE:compiled_phase` sets all three and then asserts
`wasm_jit:counts/0` moved, because even with all three a refusal still
interprets. That phase is what found `i32.shr_u` answering 4294967295 where the
specification says -1.

`compile_whole` is not a tuning knob. Compiling every function of QuickJS is 74
seconds against about 8 for the hot set. Specification modules are a few
functions each, which is why it is affordable there and nowhere else.

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
