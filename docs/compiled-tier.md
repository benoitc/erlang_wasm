# The compiled tier

The compiled tier makes a guest run faster by turning its busiest functions
into BEAM code. It is off by default. Read this page before you turn it on:
it explains what it compiles, what it costs, and which limits apply.

**Do you need it?** Yes if a guest runs for a long time, like a language
interpreter: there it made QuickJS about 8 times faster. No for a small
plugin, where it changes nothing measurable. Measure your own module before
you decide.

## The words on this page

| word | what it means here |
| --- | --- |
| **interpreted** | the runtime reads the guest's instructions one by one and does what each says. Every instance starts like this. |
| **compiled** | the runtime has translated a guest function into BEAM code, which the Erlang VM runs directly. |
| **hot** | a module that has been called often enough to be worth compiling: 32 calls by default. |
| **hot set** | the functions a module actually ran. Only these are compiled. |
| **unit** | one generated BEAM module holding the compiled functions of one guest module. |
| **slot** | a place for one unit. A node has **16**. |
| **code cache** | a directory where compiled units are saved, so a restart can reuse them instead of compiling again. |
| **word** | the Erlang VM's unit of process memory: 8 bytes on a 64-bit system. |

## Turn it on

Per instance:

```erlang
{ok, I} = wasm:instantiate(M, Imports, #{compile => true}).
```

The instance starts interpreted. After the module has been called
`compile_after` times (32 by default, counted for the module, not for each
instance), the runtime compiles its hot set in the background. The call that
triggered it does not wait. A later call finds the compiled code and runs it.

A function the compiler cannot handle stays interpreted. Compiled and
interpreted functions can call each other, so a partly compiled module still
works.

To wait for the compile, in a test or at warm-up:

```erlang
{ok, I} = wasm:instantiate(M, Imports, #{compile => true}),
ok = wasm_jit:await(I, 60000).
```

To see what happened on the node:

```erlang
wasm_jit:counts().    %% #{compiled => N, entered => M, reentered => K, cached => C}
```

## How the pieces fit

```text
  wasm:call/3,4, the outermost call only
        |
        v
  wasm_jit:entry/3 ---- compiled code loaded? ---yes---> run it
        | no
        v
  run interpreted (wasm_exec), remembering which functions ran
        |
        v
  wasm_jit:after_call/2       decides what to compile, and when
        |
        v
  wasm_code_cache:lookup      saved in code_cache_dir? -----yes----+
        | no                                                       |
        v                                                          |
  wasm_core                   guest functions to Core Erlang       |
        |                                                          |
        v                                                          |
  compile:forms/2             the OTP compiler makes a BEAM module |
        |                     and saves it in the cache            |
        v                                                          |
  wasm_code_slots             loaded into one of the 16 slots <----+
```

The compile runs in a separate process, so the caller never waits for it.

## Keep compiled code across restarts

Without a code cache, a node compiles everything again every time it starts.
For a reactor worker that means about 150 seconds and several thousand slow,
interpreted requests before the compiled code arrives. Turn the cache on
together with the tier.

Set it in your release configuration, so it applies before anything is
instantiated:

```erlang
%% sys.config
[{wasm, [{code_cache_dir, "/var/lib/my_release/wasm"}]}].
```

**Loading a file from this directory runs the code in it.** So the runtime
only uses a directory that nobody else can write to, and refuses any other.
The directory must be:

- an **absolute path**, with no `.` or `..`, owned by the user the node runs as;
- **not writable by group or others**, and neither is any directory above it.
  `0700` and `0750` are good choices; `0755` is fine if you own it;
- under directories that are **all owned by root or by you**. A parent owned by
  someone else can be changed by that person, even at `0755`;
- free of **symbolic links** anywhere on the path;
- inside **parents that already exist**. The runtime creates the last directory
  if it is missing, at `0700`, and nothing above it;
- **not under `/tmp`**, which fails the rules above on any normal system.

If the directory does not qualify, the runtime logs it once and works without
a cache. Nothing fails: you only lose the faster start.

**Why it is off by default.** A library cannot choose a safe place to store
code it will later run. Where your release keeps its state is your decision,
so the runtime asks you for it.

Each saved file carries a checksum, checked before loading, so a file damaged
by a crash or a bad disk is ignored and compiled again. A checksum does not
stop someone who can write to the directory: see [Security](security.md).

## What to do at startup

The cache saves the **compile**. It does not save the requests that run
interpreted before the compile starts, and it only helps when the node runs
the same functions as the run that filled it.

1. **Set an absolute, private, persistent `code_cache_dir`**, as above.
2. **Load the guest from its bytes**, with `wasm:load/1`. A module built from
   the text format gets a new identity each time it is validated and is
   **never cached**.
3. **Run the same representative request at every start.** The cache key
   includes the set of functions that ran, so a different first request makes
   a different key.
4. **There is no supported way to wait until compiled code is ready** in a
   worker host; see the limitation below.
5. **Accept traffic knowing the first requests run interpreted.**

What it is worth on a reactor worker:

| guest | first start | next start, cache filled |
| --- | --- | --- |
| Lua | 47 s, 3,835 requests | **0.5 s, 44 requests** |
| QuickJS | 147 s, 6,412 requests | **1.5 s, 34 requests** |
| CPython | 319 s, 1,908 requests | **7.7 s, 33 requests** |

A *different* script gets nothing from that cache: it runs different
functions, so it pays the full first-start cost and saves a second entry.

**The readiness limitation.** `wasm_jit:await/2` waits on an instance, and a
worker destroys its instance after every request, so a worker host has nothing
to wait on. Waiting would help: on Lua it would mean 32 interpreted requests
instead of 3,835. This is a known gap; `test/audit/PERF.md` has the numbers.

## What gets compiled

**A function is compiled whole or not at all.** One unsupported instruction
anywhere in a function keeps the whole function interpreted. A language
runtime spends almost all its time in one or two functions, so the speed-up
jumps rather than grows: QuickJS ran at the same speed with 93% of its
functions compiled and **9 times faster at 100%**.

Check a module of your own:

```sh
erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/coverage.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run coverage main your.wasm
```

It reports how many functions compile and, for each one that does not, the
first instruction that stopped it. What matters is reaching 100% for the
functions you actually run.

The compiler handles: i32 and i64 arithmetic, including division and
remainder that trap, comparisons, conversions, locals, constants, blocks,
loops, branches (including `br_table`) and `select`, 32-bit memory loads and
stores, globals that are not exported mutable globals, direct and indirect
calls, bulk memory (`memory.copy`, `fill`, `size`, `grow`, `init`,
`data.drop`), all float instructions and all SIMD instructions. It does not
handle exceptions, the garbage-collected types, or 64-bit memories.

**Exporting a mutable global stops every function that reads it from
compiling.** An exported mutable global is stored as a shared cell instead of
a plain value, and a function that reads one is refused with
`{unsupported, global_get_ref}`. Nothing in the module looks different and the
interpreter gives the right answer, so this is easy to miss. If fewer
functions compile than you expect, check for exported mutable globals:
removing the exports brings the functions back.

**Only the hot set is compiled.** For QuickJS that is 223 of its 1,666
functions, about 23 seconds of one core in the background. The hot set is
taken once: a function that first runs after the compile stays interpreted.
The tier suits long-lived instances of modules you run again and again, and
helps less when the busy functions change over time.

**A large hot set is split into two units.** One unit holds at most 4,096
functions, because each function needs a name and names come from a fixed
pool made at startup (nothing a guest supplies may become an atom). A hot set
of 4,097 to 8,192 functions is split into two units, automatically. Splitting
has two costs: a call from one unit into the other is slower than a call
inside a unit, and **a split module is never saved in the code cache**, so it
is compiled again on every start. CPython 3.12 runs 2,333 functions in one
`_start`, which fits in one unit: 1,105 seconds to compile the first time, two
seconds on the next start with the cache.

A hot set of **more than 8,192 functions is refused**: the module stays
interpreted, and the reason is recorded:

```text
1> wasm_jit:counts().
#{compiled => 0, entered => 0, reentered => 0, cached => 0,
  refused => 1, failed => 0, crashed => 0}
2> wasm_jit:diagnostics().
[{refused, {{sha256, <<...>>}, 3}, {limit, {too_many_functions, 9000}}}]
```

`counts/0` says how many compiles were refused; `diagnostics/0` keeps the
last few dozen reasons. To check ahead of time how many units a hot set needs,
call `wasm_jit:shard_count(NumberOfFunctions, Limits)`; to see how many units
an instance's module is loaded in, call `wasm_jit:shards(Instance)`.

## When compiled code is not used

**Every refusal falls back to interpreting**, and none of them is an error.
The runtime interprets when a function uses an unsupported instruction, when
all 16 slots are taken, when another process is already compiling the same
module, when the call has a fuel limit, when the compile fails, or when the
compiler goes over its memory ceiling.

**A call with a fuel limit is always interpreted.** Fuel is counted at every
loop, and counting it inside compiled code would cost what compiling saved.
So a call made with a `fuel` limit runs interpreted even when the module is
compiled. This is per call: the same instance called without a fuel limit
uses its compiled code.

**To stop a call that runs too long, kill its process.** Compiled code has no
built-in deadline check, for the same reason. Killing a process in the middle
of compiled code is safe and leaves nothing broken behind:
`wasm_jit_lifetime_SUITE` tests it, along with a compiler killed mid-compile,
an instance destroyed while it compiles, and more modules than slots.

## The node-wide limit: 16 compiled units at a time

A node has **16 slots**, and each loaded unit takes one. In practice:

- **16 different guest modules** can have compiled code loaded at the same
  time; a module split in two units counts twice.
- **Any number of instances** can use that code: all instances of one module
  share its unit and its slot.
- A 17th module is **not refused for good**: it runs interpreted, and is
  compiled on a later call once a slot is free.
- A slot becomes free when no instance of its module exists and no call is
  running in its code.
- **At most 16 compiles run at once**, one per slot being filled.

The number is fixed because each slot has a module name written into the
runtime's source (`wasm_code_0` to `wasm_code_15`). Generated code never gets
a new name, so a guest can never fill the node's atom table, which is never
cleaned.

## Limit the memory one compile may use

The OTP compiler can use a lot of memory on a large guest: about 2.5 GB for
QuickJS's hot set, and 33 GB once for CPython's whole module. You can put a
**ceiling** on each compile:

```erlang
application:set_env(wasm, compile_max_heap_words, 250_000_000).  %% 2 GB
```

The value is in words (8 bytes each on a 64-bit system), so 250,000,000 words
is 2 GB. A compile that goes over it is stopped, the module stays
interpreted, and `wasm_jit:diagnostics/0` records
`{limit, {compile_memory, Words}}`. `wasm_jit:compile_limits/0` shows the
value in force; `max_heap_words => 0` means no ceiling.

**It is off by default** because no single number suits every guest. Measure
your own guest and set the ceiling a little above what it needs; see
"Sizing the ceiling" below.

What the ceiling does not cover:

- the first step of a compile, turning guest functions into Core Erlang,
  which happens before the compiler process starts;
- memory outside the compiler process's heap, such as the VM's allocators;
- the total of several compiles: up to 16 can run at once, each under its own
  ceiling. Use the budget below for that.

The VM checks the ceiling when it collects garbage, so a compile can go a
little over it between two collections.

A value that is not a whole number of words between `min_heap_size` and
`(1 bsl 59) - 1` is logged once and ignored; the tier keeps working.

## Limit the memory all compiles may use together

The ceiling limits one compile. With 16 slots, up to 16 compiles can run at
once, so the node could use 16 times the ceiling. The **budget** limits the
total:

```erlang
application:set_env(wasm, compile_budget_heap_words, 1_000_000_000).  %% 8 GB
```

The budget is also in words. **It works only together with a ceiling**: each
compile reserves its ceiling from the budget when it starts and gives it back
when it ends. Without a ceiling there is nothing to reserve, so a budget set
alone is ignored (reported as 0) and logged once.

How many compiles may run at once is the budget divided by the ceiling,
written `Budget div Ceiling` (whole-number division), but never fewer than 4
and never more than 16. With the two values above:

```text
1_000_000_000 div 250_000_000 = 4 compiles at once
```

`wasm_jit:compile_limits/0` shows the result as `max_concurrent_compilers`.

When a compile would go over the budget, it does not start: the module stays
interpreted and asks again on a later call. Compiles are not queued, because
a waiting compile would keep its input in memory, which is what the budget is
there to limit. A compile larger than the whole budget still runs when no
other compile is running, so a budget set too low slows compiling down
instead of stopping it.

The budget is a target, not a hard limit. Real memory use can be a little
higher: a stopped compile may still be finishing when the next one starts,
each compiler can go over its ceiling between collections, the process that
starts each compile is not counted (about 7% more on QuickJS), and the VM's
own allocators are outside it. Leave some room.

Both the ceiling and the budget are off by default.

**Sizing the ceiling.** Measure your own guest:

```sh
erlc -I _build/default/lib -o bench/paths bench/paths/compileheap.erl
erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \
    -run compileheap main your.wasm 3
```

The `worker MB` of the `child` line is the most one compile of that guest
used. Set the ceiling a little above it. You cannot predict it from the
module's size: on one guest it ranged from 4.95 to 6.77 KB per word of the
compiler's input, depending only on how it was measured.

## Choose a profile instead of setting each option

A `profile` sets the compile options for a kind of workload. Anything you set
yourself wins.

```erlang
{ok, I} = wasm:instantiate(M, Imports, #{profile => plugin}).
```

| | `plugin` | `script` |
| --- | --- | --- |
| for | a module called many times through an instance that lives long | a program run from start to end, usually an interpreter running a script |
| `compile` | `true` | `true` |
| `compile_quality` | `full` | `baseline` |
| `compile_after` | 32, the default | **1** |

`full` makes faster code; `baseline` compiles faster. On QuickJS, `full` runs
in 75.0 to 76.8 ms against 86.1 to 87.7 ms for `baseline`, but takes 129.3
seconds to compile against 58.1. A plugin compiles once and gains on every
call after, so `full` is worth it. A script may run only a few times, so the
quicker compile wins unless it runs thousands of times.

`compile_after => 1` matters for scripts. A script is often a single call,
`_start`, so the default of 32 calls is never reached and nothing would ever
be compiled.

**Set `code_cache_dir` when you use `script`.** Otherwise the compile is paid
again at every start, and for a program that runs once per start that is a
loss: 58 seconds spent to save 1.9.

An unknown profile returns `{error, #{kind := unknown_profile}}`.

## What a reactor gets from it

A worker that restores a snapshot for each request makes a **new instance
every time**. A new instance looks for compiled code on its first call, so
each request uses the compiled code once it exists.

A whole request, interpreted against compiled, with the heap floor on in both
cases. Medians of twelve paired runs:

| guest | interpreted | compiled |
| --- | ---: | ---: |
| Lua | 11.4 ms | **4.4 ms** |
| QuickJS | 20.4 ms | **6.9 ms** |
| CPython | 93.1 ms | **37.6 ms** |

With fourteen workers, requests per second rise by about three quarters.

**The rest of a request is not the guest's code.** The same requests, split
into steps, compiled:

| guest | accept the request | deliver and restore | run the guest | reply |
| --- | ---: | ---: | ---: | ---: |
| Lua | 1.18 ms | 0.26 ms | 2.35 ms | 0.03 ms |
| QuickJS | 1.42 ms | 0.56 ms | 4.38 ms | 0.06 ms |
| CPython | 1.99 ms | **13.5 ms** | 20.7 ms | 0.86 ms |

Compiling only speeds up "run the guest", by about 4 times for all three. The
difference between guests is the restore, which depends on the size of the
snapshot, and accepting the request, which costs 1.2 to 2.0 ms whatever the
guest. These steps were measured when a restore still copied the snapshot;
a restore now shares it instead, and a CPython restore takes 0.79 ms instead
of 12.0. [Snapshots](snapshots.md) has the numbers.

**Plan for the first start.** Compiled code arrives after a fixed amount of
compiling, and a reactor request is about ten times faster than a command, so
about ten times as many requests run interpreted before it: about 150 seconds
and several thousand requests on QuickJS. `code_cache_dir` is what makes the
next start immediate.

## What the cache key covers

A saved unit is used only if everything that could make it wrong is the same:
the module's content, the version of the generated-code format (the **ABI**),
the OTP release, the emulator type, the machine architecture, the compile
quality, the set of functions compiled, and the slot it was built for.

Two kinds of module are never saved:

- a module with no content hash, which means every module built from the text
  format;
- a module split into two units. A split unit refers to the other unit, and
  the key does not describe that link, so a saved one could be joined to the
  wrong partner. A guest large enough to split is compiled again on every
  start.

The cache keeps at most 512 MB and removes the oldest files first.
`wasm_code_cache:purge/0` empties it, and checks the directory first like any
other use, so it never deletes files somewhere else.

## What a memory access costs

Compiled code reads and writes the guest's memory through a small cache of
the two pages it used last, so most accesses skip the page table that a
restored memory uses. One load at address `A`, in page `P`:

```text
  the access, inline in the compiled function
    crosses two words? -------------yes---> wasm_exec:load_at, slow path
    P is the first cached page? ---yes---> read it, done
        | no
        v
  a helper function inside the compiled module
    P is the second cached page? --yes---> read it, swap the two
    outside the memory? ------------yes---> slow path, which traps
    above the snapshot's pages? ----yes---> memory added by growth
        |
        v
  the page table entry for P
    not written yet --------------> read the snapshot's page, not cached
    written ----------------------> read the private copy, cache it
```

A hit costs one comparison. A write to a page that was never written goes to
the slow path, which first makes a private copy of the page. [Memory](memory.md)
describes the page table, and
[Design notes](design-notes.md#the-translation-cache) the cache.

## Short notes

- `full` is the default quality. `baseline` skips one optimisation pass of the
  OTP compiler: it compiles about twice as fast and runs about 14% slower.
  Ask for `#{compile_quality => baseline}` when compile time matters more than
  run time.
- The tier is off by default on purpose: it made one real workload 8 times
  faster and another not faster at all.
- **A restored memory costs compiled code a lookup** when the two-page cache
  misses. A memory that was not restored pays one comparison.
- **A memory access compiles to one comparison and a call.** Putting the
  whole lookup at every access instead made the code more than twice as big
  and the compile four times slower; `test/audit/PERF.md`, "The miss path out
  of line", has the numbers.
- **Generated code uses format version (ABI) 15.** Units saved by an earlier
  release are ignored and compiled again once. Nothing to set.
- **`baseline` avoids an OTP compiler bug.** Without its optimisation pass,
  OTP 29.0.3 to at least 29.1.1 can overwrite a value it still needs in one
  rare code shape. The generator avoids that shape; [Design
  notes](design-notes.md) says what to check when you upgrade OTP.
- Every figure on this page comes from `test/audit/PERF.md`; what was tried
  and dropped is in `test/audit/ATTEMPTS.md`.

## Read this next

[Tuning](tuning.md), or [Design notes](design-notes.md) for why the tier is
built this way.
