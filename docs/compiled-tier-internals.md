# Compiled tier internals

This page explains how the compiled tier is built. It is for you when you
change it, not when you use it. Read it before you change when a module is
compiled, what code is generated for a function, how a slot is reused or what
the code cache stores. To use the tier, read
[The compiled tier](compiled-tier.md). This page does not repeat it. Why
generated code checks a stamp, why module names are fixed and why only the
functions that ran are compiled is in [Design
notes](design-notes.md#generated-code-checks-a-stamp-and-does-not-hold-a-lease).

## The words on this page

| word | what it means here |
| --- | --- |
| **unit** | one generated BEAM module. It holds the compiled functions of one guest module, or of part of one. |
| **shard** | the code's word for one unit of a guest module that was split into several units. |
| **slot** | one of the 16 places a unit can be loaded into. Each slot has a fixed module name, `wasm_code_0` to `wasm_code_15`. |
| **key** | how the tier names a guest module: its content hash (or, for a module built from text, a reference) together with the ABI. |
| **generation** | a counter of a slot, increased each time the slot is reserved. |
| **stamp** | the value a unit is built for. A caller must give the same value to enter it. It is the module's content hash, or the slot generation for a module that has no hash. |
| **reservation** | a slot held by one compiler only, from the moment it claims the slot until it publishes the unit or gives up. |
| **publish** | make a loaded unit visible, so that calls can reach it. |
| **adopt** | an instance records that a slot holds the code of its module, and uses it from then on. |
| **lease** | a mark that says "this code is in use". An **instance lease** is held by each instance that may run the code. A **call lease** is held for the time of one call into it. |
| **purge** | remove the old code of a module name from the Erlang VM. The tier only uses `code:soft_purge/1`, which refuses while a process still runs that code. It never uses `code:purge/1`, which kills such a process. |
| **hot** | a guest module that has been called `compile_after` times (32 by default), counted for the module, not for each instance. |
| **hot set** | the functions a module actually ran. Only these are compiled. |
| **IR** | the instruction list `wasm_instance` makes from each guest function. The generator reads it. |
| **Core Erlang** | the intermediate language of the OTP compiler. The generator writes it, and `compile:forms/2` turns it into BEAM code. |
| **quality** | `full` or `baseline`: whether the OTP compiler runs its optimisation pass. |
| **ABI** | the version number of the shape of generated code, `ABI` in `wasm_jit`. It is part of every key. |

## The modules

The names are older than the guides, so they do not say what each module
does. Here is what each one decides:

| module | decides | read first |
| --- | --- | --- |
| `wasm_jit` | when a module gets compiled and how a call reaches the result. Policy only. It is not a JIT in the usual sense: it compiles the whole hot set in the background, not one function while it runs. | `entry/3`, `after_call/2`, then `compile/4` |
| `wasm_core` | what Core Erlang a function lowers to, which functions it will take at all, and the process the OTP compiler runs in. "Core" means Core Erlang: this module is the code generator, not the core of the runtime and not a Component Model core module. | `can_compile/2`, `forms/5`, `module/10` |
| `wasm_code_slots` | which of sixteen module names the result may load into, who still uses each one, and when that name may be reused. It also keeps the tier's tables: call counts, diagnostics, the compile budget. | its module doc, then `claim_loading/3` |
| `wasm_code_cache` | whether an artifact already exists on disk, and whether a directory is safe to keep artifacts in. | `key/6`, `lookup/1` |
| `wasm_jit_sup` | the processes that compile, so none of them is invisible. | its module doc |

`wasm_code_slots` and `wasm_jit_sup` run under `wasm_code_sup`, which is
`rest_for_one`: when the slot manager restarts, the compilers that reserved
its slots stop with it.

The compile runs in a supervised process that **owns** its slot reservation.
This is all that keeps the reservation safe: the reservation ends when its
owner ends. So a compiler that crashes or is killed loses only its work.

## The life of a module in the tier

```text
  interpreted        every instance starts here
      |  each outermost call goes through wasm_jit:entry/3:
      |    is this module's code already in a slot? -> adopt it, go to
      |    "in a slot"; otherwise count the call for the module
      v
  hot                the count reached compile_after
      |  at the end of that call, wasm_jit:after_call/2 asks once;
      |  the ask stands for compile_retry_seconds, so the next hot
      |  calls do not ask again
      v
  sent               a new process under wasm_jit_sup receives the
      |              instance and the list of functions that ran
      v
  compiling          claim_loading: reserve a free slot, Token = {Name, Gen}
      |                no free slot, or another process compiles this
      |                module -> give up; the module stays interpreted
      |              more than 8,192 functions -> refused
      |              wasm_code_cache lookup -> found: use the file
      |              not found: take room in the budget, wasm_core
      |                writes Core Erlang, compile:forms/2 makes BEAM,
      |                the cache stores it
      v
  in a slot          code:load_binary into wasm_code_N, publish(Token),
      |              the instance takes an instance lease
      |  each call: take a call lease, call Name:invoke(..., Stamp)
      |    the unit compares Stamp with the one it was built for
      |      same      -> run the compiled code
      |      different -> {error, stale}: interpret this call
      v
  released           wasm:destroy/1 calls wasm_jit:release/1, which
      |              gives the instance lease back; a holder that dies
      |              gives its lease back through a monitor
      |  the code stays loaded, and a new instance can still adopt it
      v
  reused             another module may take the slot only when no
                     lease is left, its call counter can be made
                     exclusive, and code:soft_purge/1 succeeds, which
                     means no process still runs the old code
```

Every arrow that leaves the line ends in the interpreter, and none of them is
an error. `wasm_jit:counts/0` counts each outcome and
`wasm_jit:diagnostics/0` keeps the last reasons.

The stamp is what makes reuse safe. A call lease is given back in an `after`
block, and an `after` block does not run when a process is killed with
`kill`. So a lease can stay counted for ever, and the slot manager may repair
such a counter. A caller that chose a slot just before it was refilled holds
the old stamp, and the new unit refuses it. That check is part of the call
itself, so no lease is needed for safety.

`wasm_code_slots` prefers a module's own slot, computed from its key, when that
slot is free. A cached artifact names its slot in its BEAM file, so it can only
be loaded into the slot it was built for; this preference is what lets the
cache hit after a restart.

## The compile limits

- **One unit holds at most 4,096 functions**, the depth of the name pool in
  `wasm_core` (`wasm_core:limits/0`).
- **A request over 8,192 functions is refused** before anything is lowered,
  with `{too_many_functions, N}` (`MAX_COMPILE_FUNS` in `wasm_jit`), whatever
  `compile_whole` asks.
- **So the automatic split makes at most two units.**
  `wasm_jit:shard_count/2` asks for `ceil(N / 4096)` units.
- **Four units is a hard cap** (`MAX_SHARDS` in `wasm_jit`). Only a split
  forced with the `compile_shards` instance option reaches it.
- **Memory is bounded by the VM, not by a count.** `compile_max_heap_words`
  sets `max_heap_size` on the process that runs the OTP compiler, and
  `compile_budget_heap_words` limits the sum of those ceilings over the
  compiles that run at once. Both are off by default.
  `wasm_jit:compile_limits/0` shows the values in force.

Neither count promises that everything under it will compile. A unit that is
split is never saved in the code cache: a unit names the next one as a literal,
and the key does not describe that link.

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
That run is why a request over 8,192 functions is now refused, as described in
[the compile limits](#the-compile-limits).

## The translation cache

Generated code reaches memory 0 through a cache of two entries, passed through
every continuation. In a restored memory, low addresses are found through a
page table, and reading the page table on every access is what made it slow.
Read `wasm_core`'s private `cached/9` before you change the code generated for
a memory access.

- An entry is a block number, the array that block lives in and the word
  index of its first word. A block is 64 KiB on a memory with no image and
  4 KiB on a restored one, where untouched pages sit in a table of 4 KiB
  slots. A function that accesses memory 0 picks the size once, when it is
  entered (`tag_bindings/3`); a memory never gains or loses an image, so the
  choice holds for the whole call. Only translations to an array are cached:
  a private slot or a growth chunk. An untouched image page is read from its
  binary and never cached.
- A hit is one compare per entry, with no bounds test: a block that was in
  bounds stays in bounds, because a memory is a whole number of 64 KiB pages
  and never shrinks. A hit on the second entry swaps the two, so the
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
- It takes the state, the address, the value for a store, the six cache
  values and the block's shift and mask, and returns
  `{Result, P1, A1, B1, P2, A2, B2}` on every path.
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

## Values a multi-value `let` must not leave unused

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

## How a compiled function calls another

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

## How compiled code holds an i32

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

## f64 arithmetic inline

f64 `add`, `sub`, `mul`, `div` and the six comparisons are Erlang float
operations when both operands are floats of a size whose result cannot
overflow: below 2^1022 for a sum, below 2^511 for a product, a divisor of at
least 1.0. The BEAM raises `badarith` on overflow rather than answering
infinity, and these bounds keep that out of reach. Anything else, including
NaN and the infinities (atoms and tuples, never floats), calls `wasm_exec`.
On two such floats `wasm_num_float` computes the same thing, so the answer is
the same bit for bit; inside a function the floats also stay unboxed.

## How a call through a table finds its target

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

## Bump the ABI when generated code changes shape

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

Nothing derives the number, so nothing reminds you. Three other version
numbers are bumped by hand the same way, and each one answers a different
change:

| number | where | bump it when | an old file is |
| --- | --- | --- | --- |
| `ABI` | `wasm_jit` | generated code changes shape, as above | a cache miss, compiled again |
| `FORMAT` | `wasm_code_cache` | the frame around a cached artifact changes | a cache miss |
| `IMAGE_ABI` | `wasm_snapshot_file`, read with `wasm_snapshot_file:image_abi/0` | the value representation in a snapshot image, or its set of parts, changes | refused with `snapshot_abi_mismatch` |
| `FORMAT` | `wasm_snapshot_file`, read with `wasm_snapshot_file:format_version/0` | the file layout of a snapshot (its header or sections) changes | refused with `snapshot_format_unknown` |

The snapshot numbers are not about generated code: an image holds guest
state, not compiled functions. They are here because the rule is the same. A
worker treats a refused image as "no image" and captures a new one.

## Where to add things

**An instruction the tier compiles.** Follow
[Adding an instruction](contributing/adding-an-instruction.md). The tier's
part is `wasm_core:supported/1` (which says it may be compiled) and, for an
inline form, the generator's clauses. An operation you add to
`wasm_core:ops/0` also needs its operand types in `wasm_core_prop_SUITE`;
`every_supported_operation_is_generated` fails until you add them.

**A helper that generated code calls.** Export it from `wasm_exec`, which is
the ABI between generated code and the runtime, and bump `ABI`.

**A new reason to refuse a compile.** Make it a value, `{limit, Why}` or
`{unsupported, Why}`, never an exception: `wasm_jit` counts either as a
refusal and the module stays interpreted. `wasm_jit:normalize_reason/1` must
keep it bounded, because `wasm_jit:diagnostics/0` stores it.

**A new compile setting.** Read it once per compile, as
`compile_max_heap_words` is read in `generate_1`, and report it in
`wasm_jit:compile_limits/0`. Document it in
[Configuration](configuration.md). An option says what the embedder knows (a
limit, a timeout); it never selects how code is generated.

**Something new in the cache key.** Add it to `wasm_code_cache:key/6`. An
artifact saved under the old key is then a miss, so no ABI bump is needed for
that alone.

**A new module name.** Do not. The sixteen slot names in `wasm_code_slots`
and the name pools in `wasm_core` are literals so that the set of atoms the
tier can make is fixed. `wasm_core_SUITE` and `wasm_prop_SUITE` fail if it
moves.

## The tests

| suite | covers |
| --- | --- |
| `wasm_core_SUITE` | the name pools and the atom count, generated code against the interpreter, the call conventions, i32 forms, f64 and table calls, `dump/1` |
| `wasm_core_prop_SUITE` | generated programs over `wasm_core:ops/0`, compiled and interpreted, values and traps compared |
| `wasm_code_slots_SUITE` | leases, reuse, soft purge, a manager restart, the atom table with many modules |
| `wasm_jit_lifetime_SUITE` | killed compilers and callers, destroyed instances, more modules than slots, the cache directory rules, profiles, the depth limit |
| `wasm_jit_bounds_SUITE` | splitting into units, the 8,192 refusal, the heap ceiling and the budget, the diagnostics ring |
| `wasm_spec_SUITE` | the specification suite through generated code, in `compiled_phase` and `unfused_compiled_phase` |
| `wasm_paged_memory_SUITE` | compiled memory accesses over an image, and the size of an access site |
| `wasm_file_cache_SUITE` | the eviction that the code cache and the snapshot store share |

Run them:

```sh
for s in wasm_core_SUITE wasm_core_prop_SUITE wasm_code_slots_SUITE \
         wasm_jit_lifetime_SUITE wasm_jit_bounds_SUITE \
         wasm_paged_memory_SUITE wasm_file_cache_SUITE; do
    rebar3 ct --suite="test/$s" || break
done
```

Some `wasm_core_SUITE` cases need the QuickJS build and skip without it
(`scripts/fetch-qjs-fixture.sh`). A change on the call path also needs
`realbench` on QuickJS; see [Measuring](contributing/measuring.md).

## Read this next

[The compiled tier](compiled-tier.md) for the user's side,
[Memory](memory.md) for the page table that compiled accesses read, and
[Design notes](design-notes.md) for the reasons behind the stamp and the fixed
names.
