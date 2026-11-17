# Design notes

This page explains why the runtime is built the way it is, one subject per
section. Read a section before you change the thing it describes. You will
learn what was already tried, so you do not try it again.

This is not the measurement record. `test/audit/PERF.md` is the lab notebook,
in the order things were discovered, and `test/audit/ATTEMPTS.md` lists what
was tried and then reverted. Both files stay in that order, so neither is easy
to look things up in. This page is for looking things up, and it links to
them.

Some subjects have a page of their own, with their reasons beside them:
[Threads](features.md#threads), documented as a feature because what matters
about them is what is implemented; linear memory, restored memory and the
page budget, in [Memory](memory.md); the garbage collector, in
[Garbage collection](gc.md); why a request is three processes, in
[Worker internals](worker-internals.md); and the compiled tier, in
[its own guide](compiled-tier.md). The reasons behind the WASI sandboxes are
at the end of this page.

## The interpreter keeps its own control stack

`#st.frames` and `#st.ctrl` are plain lists, not the Erlang call stack. Erlang
cannot capture its own call stack as a value. So if the interpreter used the
Erlang stack, the runtime could not pause it, could not look into it from
outside, and could not limit its depth separately from Erlang's own stack.
`max_depth`, trap reports and the worker's cancellation all need these three
things.

`#st.stack` is a cons list with the top at the head, which measured faster than
any indexed structure.

## The mutable half of an instance is separate from the immutable half

`#inst{}` holds everything that comes from the module and is never written
while code runs. `#mut{}` holds what changes. A call reads the mutable half
once, passes it along as a value while it runs, and writes it back once at the
end. A tuple update costs a few nanoseconds; an ETS write costs forty.

The garbage-collected object store is in the *immutable* half. This looks
wrong, but it is on purpose: the handle to the store never changes, only the
objects it points to change.
While the store was a term inside `#mut{}`, committing it copied the whole heap
into ETS, at 1993 microseconds per mutating call at a hundred thousand objects.

## Generated code checks a stamp, and does not hold a lease

A slot that holds generated code may be reused when no process is running
inside it. The obvious way to know this is a lease for each call, and that was
tried. It failed when a caller was killed. A lease is given back in an `after`
block, and an `after` block does not run when a process is killed with
`kill`. So one killed process kept a slot busy until the node stopped.

So the check moved into the called code. Generated code is built for a stamp:
the module's content hash if it has one, otherwise the slot generation. It
refuses a caller that brings a different stamp. A killed caller now costs
nothing. Reuse is safe whatever the lease counter says, and `soft_purge`
decides, not the leases.

`wasm_code_slots_SUITE` found a bug in the first version of this. It was not
safe in the short time between taking a lease and entering the code.

## Sixteen fixed module names, and bounded name pools

The atom table is shared by the whole node, and atoms are never freed. So a
name made from a module's own bytes would be a leak that never goes away, and
a remote guest could make it grow. Generated module
names come from a pool of sixteen written out literally in `wasm_code_slots`,
and function and frame names from bounded pools in `wasm_core`. The number of
atoms the compiler can ever create is a literal you can read in the source, and
`wasm_core_SUITE` and `wasm_prop_SUITE` both assert the count does not move.

## Compile what ran, not what exists

QuickJS has 1666 functions, and a workload reaches about 223 of them.
Compiling all of them takes most of the time and most of the fifteen megabytes
of code space. A function that is left out still runs correctly: it is
interpreted. Compiled and interpreted code can call each other in both
directions, so it can still call compiled code.

The runtime compiles only once. A function that becomes hot later is never
compiled, because nothing asks for a second compile. The runtime decides which
unit holds which function before it generates anything. So adding a second
compile would only need a new rule for when to do it, not new code to track
functions. The measurements have not shown a need for one.

## What measuring the interpreter found

Two measurements shaped how the interpreter is changed and measured. An A/B
comparison of two versions that each use a lot of memory runs each version in
its own VM: run in turn in one VM, the CPU cache made fusion look 2x slower
when it was 1.14x faster. And a short call spent most of its time copying the
instance's state out of ETS and back, not executing, so each process now caches
the state it last saw; the superinstructions and the bulk memory fixes were
chosen from measured frequencies and costs in the same way. The runs are in
`test/audit/PERF.md`, sections "A benchmark that lied, and how it was caught
(from the design notes)" and "Where a call's time goes (from the design
notes)".

## Table representation

Tables are `array`, not flat tuples. A tuple reads in O(1) time. That looks
right, because `call_indirect` reads the table on every dynamic call. But with
a tuple, every write copies the whole table. Measured on a 10,000-element
table:

| operation | tuple + `setelement` | `array` |
| --- | ---: | ---: |
| bulk fill of 10,000 | 33,858 us | 248 us |
| 1,000 scattered writes | 3,779 us | 17 us |
| 1,000,000 reads | 1,916 us | 5,316 us |

Reads get 2.8x slower, but an indirect call also does a type check, a fuel
charge and frame setup, so 3.4 ns is a few percent of the operation. Writes get
222x faster, and the sequential-`setelement` bulk operations were O(n squared),
which for untrusted code is a denial-of-service vector rather than a slow path.
Luerl reaches the same conclusion for Lua's integer-keyed table part.

## Float representation, and why there is no NIF

Erlang floats are native IEEE 754 doubles, but they cannot hold NaN or
Infinity. Every route in is closed: arithmetic and `math:*` raise `badarith`,
and `binary_to_term`, `list_to_float`, `erlang:float/1` and `<<F:64/float>>`
matching all reject those bit patterns. So floats are hybrid: Erlang floats for
finite values, and `infinity` / `neg_infinity` / `{nan, Sign, Payload}` for
the rest.

The obvious response is to push float arithmetic into C. Measured, f64 add,
1,000,000 operations:

| approach | ns/op | can represent NaN/Inf? |
| --- | ---: | --- |
| hybrid Erlang (used here) | **8.9** | yes |
| C NIF, bit patterns | 13.1 | yes |
| binary re-encode per op | 27.1 | yes |
| C NIF, raw doubles | 9.2 | **no** |

The NIF loses. `enif_make_double` rejects non-finite values too, so a
NaN-capable NIF has to return the raw 64-bit pattern, and every such pattern
exceeds 2^59 and is therefore a heap bignum allocated on every operation. The
raw-double NIF avoids that but cannot implement WebAssembly f64 at all. Pure
Erlang wins here on measurement, not on principle.

## A snapshot is a copy of state, not of an instance

`wasm:snapshot/1` does not freeze an instance. It copies the state the guest
can see: the 64 KiB pages of each memory that hold data, the table contents
and the globals. `restore/3` puts that state into a **fresh** instance, built
from the same module with **fresh imports**. Nothing from the host side is
copied. You, the embedder, supply file descriptors, sockets, clocks and random
sources again.

This is why you can safely give a restored instance to a different tenant. It
is also why capture refuses an image that holds a `funcref` into another
instance, or any `externref`. These point to something on this node that a
restore cannot create again. So capture refuses them, at a time when the error
can still be explained.

Two facts matter before you change the restore path. First, a restore writes
nothing into memory. It puts a page table over the image, in an instance built
without its active data segments, because the image already holds what those
segments wrote. Second, the restore takes the module from the handle the image
kept, not from an argument. So no argument can put one module's bytes over
another module's layout.

## WASI

WASI is an Erlang host interface, not an embedded runtime: each syscall is an
ordinary host function, so it can be traced, replaced or refused.
[WASI preview 1](wasi.md) is the guide: the options and what each sandbox
refuses. [Features](features.md#wasi-preview-1) lists the syscalls. This
section keeps the reasons.

An absent key is an absent capability and the syscall returns `ENOTCAPABLE`,
except `clocks` and `random`, which default to both clocks and strong
randomness.
No `dirs` means no filesystem at all, not one rooted at the working directory.
No `net` means no network at all, not one restricted to somewhere sensible.
No `env` means zero variables rather than the host's. `ENOTCAPABLE` is kept
distinct from `EACCES` so a module can tell "not granted" from "the OS
refused".

### Path sandboxing

Every escape fails with `ENOTCAPABLE` rather than `ENOENT`, so the error code
cannot be used to probe the host's directory layout. The cases are in
[What the sandbox refuses](wasi.md#what-the-sandbox-refuses).

Resolution uses `filelib:safe_relative_path/2`, which already handles lexical
traversal *and* symlink escapes, rather than a hand-rolled sanitiser. Requested
rights are masked against what the preopen passes down, so a `read` grant
cannot yield a writable descriptor whatever flags the module passes.

**The time-of-check to time-of-use window.** Resolving a path and then opening
it leaves a gap in which a component can be swapped for a symlink. Erlang's
`file` module exposes neither `openat` nor `O_NOFOLLOW`, so closing it needed
the project's one NIF: a small capability-safe file API that walks each
path component `openat(..., O_NOFOLLOW)` relative to the previous directory
descriptor, so no name is resolved twice and no symlink is followed.

It is optional. Without a C compiler the build falls back to the pure-Erlang
resolver and the window is narrowed by re-verification rather than closed; in
that configuration, do not point a preopen at a directory a hostile party can
write to concurrently. `wasi_nif_SUITE` swaps a component for a symlink between
resolve and open and asserts the native path refuses it.

### Network sandboxing

A `net` grant names what may be reached. `connect` and `listen` are separate
capabilities, `resolve` is a third, and none implies another.

**Grants name addresses, never names.** There is no rule that says
`example.com`. A name has to be resolved to be checked and resolved again to be
used, and the two answers can differ; `sock_connect` hands the operating system
the same tuple it checked, so nothing in between can move the target. That is
the difference between removing the window and narrowing it.

Every route out has a case in `wasi_net_escape_SUITE`, listed in
[What the network grant refuses](wasi.md#what-the-network-grant-refuses).

The refusal is the same whether or not something is listening on the port, for
the reason path escapes answer `ENOTCAPABLE` rather than `ENOENT`: an errno that
varied with the host would be a port scanner.

`::ffff:127.0.0.1` reaching the same host as `127.0.0.1` is the case a tuple
comparison misses, so mapped addresses are folded before the check and the
folded form is what gets connected to. The deprecated `::a.b.c.d` block is
deliberately not folded, because `::0.0.0.1` and `::1` are one address and
folding it would make loopback ambiguous.

Preview 1 standardised four socket calls and all four assume the socket already
exists, so a `listen` rule naming one address and one port is opened by the host
and handed in as a preopened descriptor: a module using only standardised calls
never names an address at all. What socket support does **not** cover is
enumerated in [docs/security.md](security.md), and two of those statements are
asserted by tests so the document fails with them.

## The compiled tier, for someone changing it

What follows was in [the compiled tier guide](compiled-tier.md), and is for
changing `wasm_jit`, `wasm_core`, `wasm_code_slots` or `wasm_code_cache`
rather than using them.

### The five modules, and what each decides

| module | decides |
| --- | --- |
| `wasm_jit` | when a module gets compiled and how a call reaches the result. Policy only. |
| `wasm_core` | what Core Erlang a function lowers to, which functions it will take at all, and the process the OTP compiler runs in. |
| `wasm_code_slots` | which of sixteen module names the result may load into, and when that name may be reused. |
| `wasm_code_cache` | whether an artifact already exists on disk. |
| `wasm_jit_sup` | the processes that compile, so none of them is invisible. |

The compile runs in a supervised process that **owns** its slot reservation.
This is all that keeps the reservation safe: the reservation ends when its
owner ends. So a compiler that crashes or is killed loses only its work.

### Read what it generated

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

### Three options that exist only for conformance

The defaults are what an embedder wants and are all wrong for a test that means
to check generated code, because each of them lets a test pass without any
generated code having run.

| option | what it changes |
| --- | --- |
| `compile_sync` | compile on the calling process, so the next call is already compiled |
| `compile_whole` | compile every eligible function, not only the ones that have run. Applies to background compiles as well as under `compile_sync`; an earlier version ignored it there without any error, and compiled only what had run |
| `compile_force` | raise on a compile error instead of interpreting |

`wasm_spec_SUITE:compiled_phase` sets all three and then asserts
`wasm_jit:counts/0` moved, because even with all three a refusal still
interprets. That phase is what found `i32.shr_u` answering 4294967295 where the
specification says -1.

`compile_whole` is not a setting for speed. Compiling every function of
QuickJS took 107 s in the first run that measured it, against 15.2 s for the
223-function hot set forced into four units with `compile_shards => 4`.
Specification modules have only a few functions each, so it is affordable
there and nowhere else.

**Nowhere else means nowhere else.** CPython 3.12 has 11,447 eligible
functions, although one request only *reaches* 971 of them. With
`compile_whole` it used 33 GB of memory on a 48 GB machine in eleven minutes,
produced nothing, and spent that time swapping to disk instead of compiling.
That run is why a request over 8,192 functions is now refused with
`{too_many_functions, N}`, whatever `compile_whole` asks. One unit holds at
most 4,096 functions, the depth of the name pool, so a request the runtime
accepts splits into at most two units on its own. Four units (`MAX_SHARDS` in
`wasm_jit`) is a hard cap that only a forced split reaches. Neither limit
promises that everything under it will compile.


### The translation cache

Generated code reaches memory 0 through a cache of two entries, passed through
every continuation. In a restored memory, low addresses are found through a
page table, and reading the page table on every access is what made it slow.
Read `wasm_core`'s private `cached/8` before you change the code generated for
a memory access.

- An entry is a 4 KiB page number, the array that page lives in and the word
  index of its first word. Only translations to an array are cached: a private
  slot or a growth chunk. An untouched image page is read from its binary and
  never cached.
- A hit is one compare per entry, with no bounds test: a page that was in
  bounds stays in bounds. A hit on the second entry swaps the two, so the
  pair stays in least-recently-used order. Two entries, not one, because guests
  alternate between two pages often enough that one entry missed on nearly
  half their array accesses.
- A miss is the ordinary access, which puts its translation first when it ends
  on an array.
- Nothing invalidates an entry. A page table entry goes from 0 to a slot once
  and growth only appends chunks, so a cached translation is right whatever
  another holder does.

Only the hit on the first entry is generated at the access itself. Each access
site has three parts: the test for an access that crosses a page boundary,
with its call to the helper; one compare against the first cached page, with
the load or store under it; and an `apply` for every other case. The `apply`
calls a function of the generated module. There is one such function for each
access shape the module uses, built by `wasm_core`'s private `miss_fn/1`:

- It holds the second entry's hit with its swap, the bounds test, the page
  table, the growth chunks, the read of an untouched image page and the call
  to the helper.
- It takes the state, the address, the value for a store and the six cache
  values, and returns `{Result, P1, A1, B1, P2, A2, B2}` on every path.
- A shape is a direction, a width and a kind, twenty at most, and each has a
  literal name: `wasm_m_load_4_i32_u`, `wasm_m_store_8_int`. Nothing a guest
  supplies names one.

To see it, dump a module with one load and look for the `apply`:

```erlang
{ok, M} = wasm:compile({wat, ~"(module (memory 1)
  (func (export \"f\") (param i32) (result i32) local.get 0 i32.load))"}),
{ok, I} = wasm:instantiate(M, #{}, #{}),
io:format("~s~n", [wasm_jit:dump(I)]).
```

Keep the miss path in its own function, not at each access. The cache starts
empty in every function, so 31 to 50% of a real guest's accesses miss. The
miss path runs often; it is not a rare branch. When it was generated at every
access, generated code was 2.3 to 2.5 times as large, four times as slow to
compile and 1.1 to 1.5 times as slow to run.
`wasm_paged_memory_SUITE` has a case that fails if a site grows back, and
`test/audit/PERF.md`, "The miss path out of line", has the gates it was held
to. A cache of one entry was also measured. Calls were not slower, but it did
not save the 10% of compile time that the rule, written before measuring,
required. So the cache keeps two entries.

Some writes can publish arena chunks: a write from the host, a bulk or vector
instruction, or `wasm:write_memory/3`. They return an updated memory handle,
so the code after them reads the new pages directly instead of through the
helper.

### Values a multi-value `let` must not leave unused

An access returns its result and the cache after it. As a Core value list
that is seven values. As a tuple it is an allocation on every access, about
5 ns for each store. The out-of-line function always returns the tuple, and
the access site takes it apart into the list. The hit on the first entry,
generated at the site, builds the list directly. The value list is used only
where it is safe, because of a defect in the OTP compiler. Under `no_ssa_opt`
(the `baseline` quality, which a worker's `compiled => true` asks for), a value
of a multi-value `let` that nothing uses can share a register with a value
that is used, because the compiler thinks it is live for zero instructions.
Where the paths join, the unused copy can overwrite the used one. Real guests
crashed on it: the instance state was replaced by a cache word.

So `wasm_core`'s private `answer/3` orders every list so that no unused value
comes after a used one. Where the paths of a load disagree about which values
they use, it returns a tuple instead. The comment above it explains why each
ordering is safe. The defect is present on OTP 29.0.3 through 29.1.1 and on
OTP master as of October 2026, and it is reported upstream. Check it again
when you move to a newer OTP, before you simplify the ordering.

### How a compiled function calls another

Inside one compiled unit, a call is a local Erlang call, and each function
is called one of three ways, decided for the whole unit when it is built:

| kind | when | called as |
| --- | --- | --- |
| pure | touches nothing and calls nothing | `f(Args)` |
| calls-only | touches no memory, global or table, and calls only pure or calls-only functions of the unit | `f(Left, Args)` |
| stateful | anything else | `f(Inst, Mut, Left, Args)`, which also returns the new `Mut` |

A function that reaches a stateful one, directly or through any chain of
calls, is stateful itself, because it must hand the callee the instance and
take its state back. So are a function that makes a `call_indirect` and one
that calls outside the unit (another shard, or a function the compiler
refused). A set of functions that call each other is decided together: the
generator starts from every candidate and removes any that calls something
else, until nothing changes.

`Left` is the number of calls left before the depth limit. `invoke/6`
computes it once, when the call enters generated code: the instance's
`max_depth` minus the caller's depth.

Only a call that can recurse counts. The generator groups the unit's
functions into strongly connected components: functions that can reach each
other through direct calls. A call to a function of the caller's own group
(a call to itself included), a `call_indirect` and a call that leaves the
unit check `Left =< 1` against a literal and pass `Left - 1`. Past it,
`wasm_exec:depth_exhausted/0` raises the interpreter's error, without the
depth in its context. Any other call passes `Left` on unchanged, with no
test.

That still bounds the stack. An uncounted call goes from one group to a
different one, and the groups cannot call each other in a loop, so a stack
holds at most one uncounted frame per group. A compiled call can therefore go
deeper than `max_depth` by at most the number of functions in the unit. A
recursion is counted exactly. A function with one result returns the bare
value; `invoke/6` puts it back in the list callers outside generated code
expect.

`invoke/6` also tests that the depth and the limit are non-negative integers
before it dispatches. They always are, and saying so in a guard lets the
Erlang compiler's type pass carry the type of `Left` into every function of
the unit, so counting down and comparing compile without the generic number
checks.

A block, loop or `if` that is the last instruction of its body, and whose
exit takes exactly its results, gets no continuation function: its branches
go straight to that exit. A function such as `fib`, which ends with an `if`,
would otherwise make one extra local call on every invocation.

### How compiled code holds an i32

The interpreter holds an i32 *signed*, between -2^31 and 2^31 - 1. Wrapping a
sum back into that range takes two comparisons and a branch. Compiled code
holds most i32 values *unsigned* instead, between 0 and 2^32 - 1, which is
how you would write 32-bit arithmetic in Erlang: wrapping is one `band`, and
the `band` also tells the Erlang compiler the value's range.

The generator calls the two forms `canon` (signed, the interpreter's) and
`u32` (unsigned). Which form a value is in is a property of the Core variable
that holds it; a literal is always `canon`.

| held `u32` | held `canon` |
| --- | --- |
| i32 locals and parameters | i64, f32, f64, v128 and references |
| i32 results of a function in the unit | signed i32 loads (`load8_s`, `load16_s`) |
| i32 parameters and results of a block, loop or `if` | anything a `wasm_exec` helper returns |
| results of inline i32 operations and unsigned i32 loads | |

A block's types come from the compiler's own IR: `wasm_instance:compiler_ir/2`
appends each frame's parameter and result types, which the interpreter's IR
does not carry.

Every boundary takes `canon`: `invoke/6`'s callers, the `wasm_exec` helpers,
globals, memory, calls to another shard, to the interpreter or to a host, and
SIMD lanes. A value changes form at most once on its way there:

- `canon` to `u32`: `V band 16#FFFFFFFF`.
- `u32` to `canon`: `V - 2^32` when `V >= 2^31`, otherwise `V`.

Operations work on `u32` directly: `add`, `sub`, `mul` and `shl` mask their
result, `and`, `or`, `xor` and `shr_u` need nothing, and a signed comparison
flips the top bit of both operands (`bxor 2^31`) and compares them unsigned.
Division, remainder, rotates and conversions go through `wasm_exec` in
`canon`, as before. A memory address is taken in `u32` as it is, and an i32
store writes either form, because every store masks to its width.

### f64 arithmetic inline

f64 `add`, `sub`, `mul`, `div` and the six comparisons are Erlang float
operations when both operands are floats of a size whose result cannot
overflow: below 2^1022 for a sum, below 2^511 for a product, a divisor of at
least 1.0. The BEAM raises `badarith` on overflow rather than answering
infinity, and these bounds keep that out of reach. Anything else, including
NaN and the infinities (atoms and tuples, never floats), calls `wasm_exec`.
On two such floats `wasm_num_float` computes the same thing, so the answer is
the same bit for bit; inside a function the floats also stay unboxed.

### How a call through a table finds its target

A `call_indirect` whose signature some function of the unit has goes through
a dispatcher local to the generated module, one per signature
(`wasm_i_<results>/<4 + params>`), shared by every site. A target in the unit
is a local call in its own convention; any other target crosses as before.

Where the target comes from depends on the table:

- **A static table** cannot change after instantiation: not imported or
  exported, no initialiser, never written by any instruction of the module,
  and filled only by active segments at constant offsets. Its contents are
  then a property of the module: validation records the candidates in
  `#ctx.table_candidates`, and the tier drops any a function writes
  (`static_tables/2` in `wasm_jit`), so the site reads the target from a
  literal holding, per slot, the unit function whose type is exactly the
  call's. Nothing is looked up or checked at run time.
- **Any other table** is resolved by `wasm_exec:indirect_index/5`, which
  reads the table once and checks the exact type before the supertypes.

A slot the literal cannot settle (empty, another type, a subtype, a function
outside the unit) and a target in another instance go to
`wasm_exec:indirect_out/9`, which traps or calls exactly as the interpreter
does.

### Bump the ABI when generated code changes shape

`wasm_jit`'s `ABI` is part of every cache key, so a node never enters an
artifact built against a different memory handle or frame shape. Bump it in the
same commit as any change to what generated code reads, how many values a
continuation carries, or which helper it calls, and add a line to the history
above the define saying what an older artifact would do wrong. ABI 14 is the
two-entry cache; 13 belonged to the deferred mmap prototype and is skipped.
ABI 15 is the miss path out of line: an older artifact would still be right,
and the number moved so that its larger code is rebuilt and not loaded. ABI
16 is the call convention above and the unsigned i32: every function's
arity, return shape and i32 representation changed.

## Read this next

[CONTRIBUTING.md](../CONTRIBUTING.md) and the
[recipes](contributing/recipes.md), when you are ready to change something.