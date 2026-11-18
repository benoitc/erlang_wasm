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

How the tier's modules work, what generated code looks like and when to bump
its ABI is in [Compiled tier internals](compiled-tier-internals.md).

## Read this next

[CONTRIBUTING.md](../CONTRIBUTING.md) and the
[recipes](contributing/recipes.md), when you are ready to change something.