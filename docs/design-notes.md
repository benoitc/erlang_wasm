# Design notes

Why the runtime is built the way it is, indexed by subject. Read a section when
you are about to change the thing it describes, so you find out what was already
tried before you try it again.

This is not the measurement record. `test/audit/PERF.md` is the lab notebook,
ordered by when each thing was discovered, and `test/audit/ATTEMPTS.md` lists
what was tried and reverted. Both are worth keeping in that order and neither is
a reference. This page is the reference, and it links into them.

[Threads](features.md#threads) are documented as a feature rather than here,
because what matters about them is what is implemented. So is the compiled
tier, in [its own guide](compiled-tier.md), linear memory and the page budget,
in [Memory](memory.md), and the garbage collector, in
[Garbage collection](gc.md). The WASI sandboxes are at the end of this page.

## Linear memory is chunked atomics arrays

Linear memory is a tuple of `atomics` arrays, sized per memory, so a store
mutates in place and growth appends a chunk; a NIF was declined to keep the
sandbox boundary in Erlang. Moved to [Memory](memory.md).

## A restored memory shares its image

A restored memory reads its snapshot image through a page table with one entry
per 4 KiB page, and copies a page into a private arena slot on its first write.
The keeper records logical and charged pages apart. Moved to
[Memory](memory.md).

## The interpreter keeps its own control stack

`#st.frames` and `#st.ctrl` are explicit lists rather than the Erlang call
stack. Erlang has no first-class continuations, so an implicit stack could not
be suspended, inspected from outside, or bounded independently of Erlang's own
stack growth. Those three are what `max_depth`, trap reporting and the worker's
cancellation all rest on.

`#st.stack` is a cons list with the top at the head, which measured faster than
any indexed structure.

## The mutable half of an instance is separate from the immutable half

`#inst{}` is everything derived from the module and never written during
execution; `#mut{}` is what changes. A call reads the mutable half once, threads
it functionally through execution, and writes it back once at the end. A tuple
update is a few nanoseconds and an ETS write is forty.

The garbage-collected object store sits in the *immutable* half, which looks
wrong and is the point: the handle is immutable and only what it names changes.
While the store was a term inside `#mut{}`, committing it copied the whole heap
into ETS, at 1993 microseconds per mutating call at a hundred thousand objects.

## Generated code checks a stamp, and does not hold a lease

A slot holding generated code may be reused once nobody is inside it. The
obvious way to know that is a lease per call, and it was tried: a killed caller
leaks its lease, because a lease is given back in an `after` and an `after` does
not run for an untrappable kill, so one killed process pinned a slot for the
life of the node.

So the check moved into the callee. Generated code is built for a stamp, the
module's content hash where it has one and the slot generation otherwise, and it
refuses a caller that presents a different one. A killed caller now costs
nothing: reuse is safe whatever the lease counter says, and `soft_purge` is the
authority rather than the leases.

`wasm_code_slots_SUITE` caught the first version of this, which was unsound in
the window between taking a lease and entering the code.

## Sixteen fixed module names, and bounded name pools

The atom table is node-wide and never reclaimed, so any name derived from a
module's own bytes is a permanent leak with a remote tap on it. Generated module
names come from a pool of sixteen written out literally in `wasm_code_slots`,
and function and frame names from bounded pools in `wasm_core`. The number of
atoms the compiler can ever create is a literal you can read in the source, and
`wasm_core_SUITE` and `wasm_prop_SUITE` both assert the count does not move.

## Compile what ran, not what exists

QuickJS is 1666 functions and a workload reaches about 223 of them. Compiling
all of them is most of the time and most of the fifteen megabytes of code space.
A function left out is not a correctness question: it is interpreted, and since
the boundary became two-way it can still call back into compiled code.

One shot, and honestly so. A function that becomes hot afterwards is never
compiled, because nothing asks for a recompile. Which unit holds which function
is decided before anything is generated, so a second cut is a policy question
rather than a missing mapping, and the measurements have not asked for one.

## A benchmark that lied, and how it was caught

Interleaving two arms in one VM cancels load drift, so it was used for every
A/B here. On a memory-heavy workload it reported that superinstructions made
things **2x slower**, reproducibly (0.49x across three runs).

The control experiment settled it: with *all fusions disabled*, so both arms
ran byte-identical code, the same harness still reported 0.38x. The harness was
wrong, not the runtime. Alternating between two instances alternates between
two 1 MiB linear memories and thrashes the CPU cache; the same instance
measured twice in a row ran at 1560 us against 2200 us when alternating.

Interleaving is the right tool for load drift and the wrong tool when each arm
carries a large private working set. Those A/Bs are run one arm per VM instead,
several launches, minimum taken. Re-measured that way, fusion is **1.14x
faster** on the same workload, not 2x slower.

The lesson is kept here because a benchmark that produces a confident, stable,
reproducible, wrong number is more dangerous than a noisy one, and the only
thing that caught it was running the null experiment.

## Where a call's time goes

Decomposing `wasm:call/3` on a trivial exported function showed that execution
was the smallest part of it:

| stage | cost |
| --- | ---: |
| export name lookup | 26 ns |
| instance state read (ETS) | 105 ns |
| **interpreter execution** | **~45 ns** |
| instance state write-back (ETS) | 185 ns |

Marshalling the instance's mutable state in and out of ETS dominated a short
call. Two changes followed:

- **Skip the write-back when nothing changed.** A function that only reads
  threads the same `#mut{}` term straight through, so `=:=` is a pointer
  comparison and the ETS write disappears entirely. Most compute functions
  mutate no globals, tables or memory size.
- **Build the locals tuple in one pass.** `lists:split` then `lists:reverse`
  then `++ Defaults` walks the arguments three times and allocates three lists.
  Popping top-first into an accumulator seeded with the defaults produces the
  same tuple in one pass. Interleaved A/B over 7 rounds: **32.7 ns to 17.6 ns,
  1.86x**, consistent in every round.
- **Precompute the `{func, N}` control frame** at instantiation instead of
  allocating one per call.

### Removing the state read

That state read turned out to be term-copy cost, not table overhead: the same
`ets:lookup_element` returning an atom costs 30 ns, a big nested term 175 ns,
and the real Rust module's state 398 ns. Meanwhile a process dictionary read
costs 9 ns regardless of size, because it does not copy.

So each process caches the state it last saw together with a version counter
held in an `atomics` slot. A hit is an `atomics:get` plus a dictionary lookup;
any process's write bumps the counter and invalidates every other cache. That
coherence property is asserted in both directions by
`wasm_worker_SUITE:state_stays_coherent_across_processes/1`.

Interleaved A/B on the real Rust module: **398.5 ns to 18.8 ns, 21x**, stable
across all seven rounds (399-407 against 19-20).

### Superinstructions

Chosen from measured frequencies over ~25,000 instructions of real Rust and
clang output rather than from intuition. `local.get` alone is 28.3% of the
stream and `i32.const` a further 17.6%. The fused sequences are
`local.get,i32.const,i32.add` (address arithmetic), `local.get,i32.load`,
`local.get,local.get`, `local.get,i32.const`, and `i32.eqz,br_if`.

Only straight-line runs are fused. `br_if,local.get` is a frequent adjacency
but must never be merged, because the `local.get` runs only when the branch is
not taken.

Removes 23.9% of static instructions on the clang fixture; worth roughly
1.02x to 1.14x of wall clock depending on workload. Fusion can be disabled with
`wasm:instantiate(M, Imports, #{fuse => false})`, which is how it was measured
and how a suspected fusion bug would be isolated.

### Bulk memory, and where a NIF *is* justified

The float experiment found a NIF losing to pure Erlang. Bulk memory is the
opposite, and measuring it first found two defects worth fixing before any
native code:

| operation, 64 KiB | before | after | ceiling (`binary:copy`) |
| --- | ---: | ---: | ---: |
| `load_bytes` | 1437 us | **122 us** | 5.5 us |
| `memory.copy`, disjoint | 5424 us | **257 us** | 5.5 us |
| `memory.fill` | 145 us | 145 us | 5.5 us |

`memory.copy` was testing only `Dst =< Src` to decide whether it needed a
backward copy, so every high-to-low copy took the byte-at-a-time path even when
the ranges were disjoint. `load_bytes` was building 8192 small binaries and
joining them instead of accumulating into one.

Even after a 21x and an 11.8x fix, bulk memory remains 26x to 47x off the
memcpy ceiling, and that gap is irreducible in Erlang: the bytes have to be
assembled from 64-bit atomic words one at a time. This, unlike float
arithmetic, is where the optional native backend earns its place, and the
memory-model property test will validate it for free when it arrives.

## Table representation

Tables are `array`, not flat tuples. A tuple gives O(1) reads, which looks
right because `call_indirect` reads on every dynamic call, but it makes every
write copy the whole table. Measured on a 10,000-element table:

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
finite values, `infinity` / `neg_infinity` / `{nan, Sign, Payload}` for the rest.

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

## A request is three processes, not one

Moved to [Worker internals](worker-internals.md), beside the rest of how the
worker kernel is built.

## A snapshot is a copy of state, not of an instance

`wasm:snapshot/1` does not freeze an instance. It copies the guest-visible
state -- the 64 KiB pages of each memory that hold data, the table contents,
the globals -- and `restore/3` lays that over a **fresh** instance built from
the same module with **fresh imports**. Nothing of the host side travels: file descriptors,
sockets, clocks and random providers are the embedder's to supply again.

That is what makes a restored instance safe to hand a different tenant. It is
also why capture refuses an image holding a `funcref` into another instance or
any `externref`: those name something on this node that a restore has no way to
recreate, so the refusal is at capture, where it can still be explained.

Two consequences worth knowing before changing the restore path. A restore
writes nothing into memory: it lays a page table over the image, onto an
instance built without its active data segments applied, because the image
already holds what they wrote. And the module is taken from the
handle the image retained rather than passed in, so there is no argument that
could lay one module's bytes over another's layout.

## Garbage collection

Structs and arrays live in an ETS store the runtime owns and collects itself,
because the interpreter's explicit state makes the roots enumerable. Two
generations keep the pause proportional to what was just allocated. Moved to
[Garbage collection](gc.md), with the costs and the roots that were missed.

## WASI

WASI is an Erlang host interface, not an embedded runtime: each syscall is an
ordinary host function, so it can be traced, replaced or refused.

```erlang
Wasi = #{ stdout => self(),
          dirs   => [{<<"/data">>, "/srv/app/data", read}],
          env    => #{<<"MODE">> => <<"production">>},
          args   => [<<"prog">>],
          clocks => [monotonic],
          random => strong,
          net    => #{connect => [{tcp, <<"10.0.0.0/8">>, 443}]} },
{ok, Inst} = wasm:instantiate(Mod, wasi_preview1:imports(Wasi)).
```

An absent key is an absent capability and the syscall returns `ENOTCAPABLE`.
No `dirs` means no filesystem at all, not one rooted at the working directory.
No `net` means no network at all, not one restricted to somewhere sensible.
No `env` means zero variables rather than the host's. `ENOTCAPABLE` is kept
distinct from `EACCES` so a module can tell "not granted" from "the OS
refused".

Implemented, 45 of them: `args_*`, `environ_*`, `clock_res_get`,
`clock_time_get`, `random_get`, `fd_write`, `fd_read`, `fd_close`, `fd_seek`,
`fd_tell`, `fd_fdstat_get`, `fd_fdstat_set_flags`, `fd_fdstat_set_rights`,
`fd_prestat_get`,
`fd_prestat_dir_name`, `fd_filestat_get`, `fd_filestat_set_size`,
`fd_filestat_set_times`, `fd_sync`, `fd_datasync`, `fd_pread`, `fd_pwrite`,
`fd_readdir`, `fd_advise`, `fd_allocate`, `fd_renumber`, `path_open`,
`path_filestat_get`, `path_filestat_set_times`, `path_create_directory`,
`path_unlink_file`, `path_remove_directory`, `path_rename`, `path_symlink`,
`path_readlink`, `path_link`, `proc_exit`, `sched_yield`, `poll_oneoff`
(clocks and socket readiness; a file still returns `ENOSYS` rather than a
guess), `sock_accept`, `sock_recv`, `sock_send`, `sock_shutdown`.

Plus eleven socket extension calls, which are WasmEdge's rather than the
specification's: `sock_open`, `sock_bind`, `sock_listen`, `sock_connect`,
`sock_send_to`, `sock_recv_from`, `sock_getlocaladdr`, `sock_getpeeraddr`,
`sock_getsockopt`, `sock_setsockopt`, `sock_getaddrinfo`.

### Path sandboxing

Every escape technique gets its own test case, and all must fail with
`ENOTCAPABLE` rather than `ENOENT`, so the error code cannot be used to probe
the host's directory layout:

| attempt | result |
| --- | --- |
| `note.txt`, `./note.txt` | opened |
| `../secret/key.txt` | `ENOTCAPABLE` |
| `/etc/passwd` | `ENOTCAPABLE` |
| `escape.txt` (symlink out of the sandbox) | `ENOTCAPABLE` |
| `sub/../../secret/key.txt` | `ENOTCAPABLE` |
| `missing.txt` | `ENOENT` |

Resolution uses `filelib:safe_relative_path/2`, which already handles lexical
traversal *and* symlink escapes, rather than a hand-rolled sanitiser. Requested
rights are masked against what the preopen passes down, so a `read` grant
cannot yield a writable descriptor whatever flags the module passes.

**The time-of-check to time-of-use window.** Resolving a path and then opening
it leaves a gap in which a component can be swapped for a symlink. Erlang's
`file` module exposes neither `openat` nor `O_NOFOLLOW`, so closing it needed
the project's one NIF: a six-function capability-safe file API that walks each
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

```erlang
net => #{connect     => [{tcp, <<"10.0.0.0/8">>, {8000, 8099}}],
         listen      => [{tcp, <<"127.0.0.1">>, 8080}],
         resolve     => allow,
         max_sockets => 32,
         timeout     => 30000}
```

**Grants name addresses, never names.** There is no rule that says
`example.com`. A name has to be resolved to be checked and resolved again to be
used, and the two answers can differ; `sock_connect` hands the operating system
the same tuple it checked, so nothing in between can move the target. That is
the difference between removing the window and narrowing it.

Every route out gets a case in `wasi_net_escape_SUITE`:

| attempt | result |
| --- | --- |
| a granted address and port | connected |
| the granted address, another port | `ENOTCAPABLE` |
| `::ffff:127.0.0.1` under a `127.0.0.0/8` grant | connected, over IPv4 |
| `::ffff:10.0.0.1` under a `127.0.0.0/8` grant | `ENOTCAPABLE` |
| `::127.0.0.1` under a `127.0.0.0/8` grant | `ENOTCAPABLE`, it is IPv6 |
| binding `0.0.0.0` under a loopback `listen` grant | `ENOTCAPABLE` |
| connecting to an address `sock_getaddrinfo` returned | checked as an address |
| a socket descriptor from another instance | `EBADF` |
| any socket call with no `net` key | `ENOTCAPABLE` or `EBADF` |

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
That is the whole lifetime argument: the reservation dies with its owner, so a
compiler that crashes or is killed costs nothing but the work.

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
| `compile_whole` | compile every eligible function, not only the ones that have run. Honoured on the background path as well as under `compile_sync`; it silently was not, and compiled what had run instead |
| `compile_force` | raise on a compile error instead of interpreting |

`wasm_spec_SUITE:compiled_phase` sets all three and then asserts
`wasm_jit:counts/0` moved, because even with all three a refusal still
interprets. That phase is what found `i32.shr_u` answering 4294967295 where the
specification says -1.

`compile_whole` is not a tuning knob. Compiling every function of QuickJS measured 107 s in the run that first
moved it, against 15.2 s for the 223-function hot set in four units.
Specification modules are a few
functions each, which is why it is affordable there and nowhere else.

**Nowhere else is meant literally.** Pointed at CPython 3.12, whose 11,447
functions are eligible module-wide and so are not refused by the four-unit
ceiling -- a single request only ever *reaches* 971 of them -- it
reached 33 GB resident on a 48 GB machine in eleven minutes, published nothing,
and spent that time paging rather than compiling. The ceiling bounds the names a
unit can use; it is not a promise that everything under it will compile.


### The translation cache

Generated code reaches memory 0 through a two-entry cache carried through every
continuation, because a restored memory's low addresses resolve through a page
table and resolving one on every access is what made the page table expensive.
Read `wasm_core`'s private `cached/8` before you change how an access is lowered.

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

Only the first entry's hit is emitted at the access. A site is the straddle
test with its call to the helper, one compare against the first cached page
with the load or store under it, and an `apply` for everything else. What it
applies is a function of the generated module, one per access shape the
module uses, built by `wasm_core`'s private `miss_fn/1`:

- It holds the second entry's hit with its swap, the bounds test, the page
  table, the growth chunks, the read of an untouched image page and the call
  to the helper.
- It takes the state, the address, the value for a store and the six cache
  values, and answers `{Result, P1, A1, B1, P2, A2, B2}` on every path.
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

Keep the miss path out of line. The cache starts empty in every function, so
31 to 50% of a real guest's accesses miss, and the miss path is hot code and
not a rare branch. Emitted at every access it made generated code 2.3 to 2.5
times as large, four times as slow to compile and 1.1 to 1.5 times as slow to
run.
`wasm_paged_memory_SUITE` has a case that fails if a site grows back, and
`test/audit/PERF.md`, "The miss path out of line", has the gates it was held
to. A cache of one entry was measured beside it: no slower to call, but under
the 10% of compile time the rule written beforehand asked for, so two stay.

A write that can publish arena chunks, from the host, a bulk or vector
instruction or `wasm:write_memory/3`, answers a refreshed memory handle, so the
code after it reads the new pages inline rather than through the helper.

### Values a multi-value `let` must not leave unused

An access answers its result and the cache after it. As a Core value list that
is seven values, and as a tuple it is an allocation on every access, about 5 ns
a store. The out-of-line function always answers the tuple, and the site takes
it apart into the list; the first entry's hit, inline, builds the list
directly. The value list is used only where it is safe, because of a defect in
the OTP compiler: under `no_ssa_opt`, which is the `baseline` quality and so
what `compiled => true` asks for, a value of a multi-value `let` that nothing
uses gets a zero-length live interval and can share a register with a value
that is used. At the join, the unused copy can overwrite the used one. Real
guests crashed on it, the instance state replaced by a cache word.

So `wasm_core`'s private `answer/3` orders every list so that no unused value
follows a used one, and falls back to a tuple where a load's paths disagree
about what they use. The comment above it lists why each ordering holds. Present on OTP 29.0.3
through 29.1.1 and on OTP master as of October 2026, and reported upstream;
recheck it when you move to a newer OTP, before simplifying the ordering.

### Bump the ABI when generated code changes shape

`wasm_jit`'s `ABI` is part of every cache key, so a node never enters an
artifact built against a different memory handle or frame shape. Bump it in the
same commit as any change to what generated code reads, how many values a
continuation carries, or which helper it calls, and add a line to the history
above the define saying what an older artifact would do wrong. ABI 14 is the
two-entry cache; 13 belonged to the deferred mmap prototype and is skipped.
ABI 15 is the miss path out of line: an older artifact would still be right,
and the number moved so that its larger code is rebuilt and not loaded.

## Read this next

[CONTRIBUTING.md](../CONTRIBUTING.md) and the
[recipes](contributing/recipes.md), when you are ready to change something.
