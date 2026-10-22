# Concepts

This page defines the words every other page uses, in the order you meet them.
Read it once before the guides. Each term links to the page that explains it
in more detail. If you are new to Erlang, the [glossary](#glossary) at the end
also defines the Erlang words, such as process, supervisor and atom.

## Who runs what

Four words explain the rest:

| word | what it is |
| --- | --- |
| **host** | Erlang/OTP: your application, which provides resources and permissions |
| **guest** | the WebAssembly code: the program that runs inside the host |
| **module** | a packaged program: validated code, plus the list of what it imports and exports |
| **instance** | a running copy: one module with its own memory and state |

The host creates an instance from a module and supplies the guest's imports.

```text
your application (the host)
  |
  +-- module          loaded once, shared, never changes
        |
        +-- instance  one running copy: its own memory, globals, tables
              |
              +-- guest code, calling back into the host through imports
```

## Four steps from bytes to a result

```text
decode        validate        instantiate                 run
bytes ------> module -------> checked code + imports ---> state ---> result
```

1. **Decode** turns bytes into a module.
2. **Validate** checks the module's types and structure before anything runs.
3. **Instantiate** builds the instance's state and connects its imports.
4. **Run**: a call runs one of the instance's exported functions.

See [Getting started](getting-started.md).

## The guest asks, Erlang decides

An **export** is a guest function that the host can call.

An **import** is an operation that the host provides. The guest names the
operation, and the host supplies the code that does it. If the host does not
supply an import, the guest cannot do that operation at all. So an import is
a **capability**: a permission that the host grants by supplying the import.
See [Host functions](host-functions.md).

**WASI** is a standard set of imports for files, clocks, random data and
networking. You grant each one by name, for example a directory or a network
address. Anything you do not grant does not exist for the guest. See
[WASI](wasi.md).

**Linear memory** is the guest's byte array. The guest can make it larger
while it runs. Numbers pass directly as call arguments. Strings and binaries
pass through memory. See [Pass bytes](examples/pass-bytes.md).

## Guest errors are returned as values

Nothing raises an exception. A malformed binary, a type error, a trap and a
limit that runs out all return `{error, #{class, kind, msg, ctx}}`. So a guest
that fails never crashes the process that called it.

**Fuel** is a budget of work, not of time: the guest stops after it has done
that much work. **Limits** are the maximum values for one instance: fuel,
memory pages, call depth and heap size. See [Embedding](embedding.md).

## A process tracks each running instance

```text
acquire                       use                      release
accept, reserve capacity  --> call before a deadline --> cleanup must be proved
```

Each request goes through three steps. First it is accepted and its resources
are reserved. Then the guest is called and must finish before a deadline.
Last, everything the request used must be cleaned up, and the runtime keeps
track of that cleanup until it is done.

An **owner** is the process responsible for cleanup. Put an instance in a
process of its own, a **worker**, and a timeout can kill it. A call made
directly runs in your own process, and nothing can interrupt it. A worker is
not a second engine. It is an ordinary process that owns an instance. See
[Stop a runaway](examples/stop-a-runaway.md) and [Workers](worker.md).

## Deadlines and cleanup stay outside the guest

To run code that arrives with a request, the **worker kernel**,
`wasm_script_worker`, gives each request its own processes:

```text
caller ---message---> worker (the API, one request at a time)
                        |
                        +-- guardian   enforces the deadline, owns the files
                        |     |
                        |     +-- runner   executes the one request
                        |
                        +-- reaper     node-wide: cleans up after requests
```

An **adapter** teaches the kernel one language: how to start it, how to give
it a script, and how to read the result. The included adapters cover
JavaScript, Python and Lua. To write one for another language, implement the
behaviour `wasm_worker_adapter`. See
[Run JavaScript](examples/run-javascript.md) and
[The adapter contract](worker-contract.md).

A **command** is a guest that runs `main` once and exits. A **reactor** is a
guest that exports functions and stays ready between calls. Snapshots and the
fast language paths need a reactor.

## Two execution modes

```text
start by interpreting              compile hot code later
validated wasm --> Core Erlang --> loaded BEAM module
```

Every instance starts **interpreted**: the runtime reads the guest's
instructions one by one and does what each says. The **compiled tier** is off
by default. When you turn it on, it translates the functions that a module
calls most into BEAM code. It does this through **Core Erlang**, an
intermediate language that the Erlang compiler already reads. The compile
takes time before the guest runs faster, and compiled code cannot count fuel.
See [Turn on the compiled tier](examples/turn-on-the-tier.md).

## Start once, restore a fresh copy per request

```text
initialized instance --capture--> image --restore--> fresh instance
                                  (memory, globals, tables)
```

A **snapshot** is a saved copy of a guest after it has started, used as a
template. Restoring it gives a fresh instance that does not need to start
again. So an interpreter that takes seconds to start costs only milliseconds
per request. A snapshot is not a paused process.

The **image** is the stored copy, in memory or on disk. A restore does not
copy the image. Every instance restored from one image reads its pages in the
image, and copies a 4 KiB page only when it writes to it. See
[Restore a snapshot](examples/restore-a-snapshot.md) and
[Snapshots](snapshots.md).

Snapshots reduce the cost of **starting** a guest. The compiled tier reduces
the cost of **running** it. They solve different problems, and you can use
them together or apart.

## Glossary

Every term the other pages use, with the page that explains it. The Erlang
terms come first, for readers new to Erlang.

### Erlang terms

| term | meaning | read |
| --- | --- | --- |
| **atom** | a named constant, such as `ok` or `trap`. The node keeps every atom forever and has a fixed maximum, so the runtime never turns guest data into atoms | [Security](security.md) |
| **behaviour** | an Erlang interface: the list of callback functions a module must export to play a given role | [Writing an adapter](worker-contract.md) |
| **BEAM** | the Erlang virtual machine, which runs Erlang code; "BEAM code" is code compiled for it | [Architecture](architecture.md) |
| **ETS table** | an in-memory table that belongs to one process and is deleted when that process exits | [Embedding](embedding.md) |
| **heap** | the memory of one Erlang process, where its data lives; each process has its own | [Tuning](tuning.md) |
| **link**, **trap exits** | a link connects two processes so that when one exits, the other is told or exits too; a process that traps exits receives a message instead of exiting | [Put it in an OTP application](otp.md) |
| **mailbox** | the queue of messages a process has received; it handles them one at a time | [Using workers](worker.md) |
| **NIF** | a "native implemented function": C code loaded into the BEAM and called like an Erlang function | [Architecture](architecture.md) |
| **node** | one running BEAM, with all its processes | [Architecture](architecture.md) |
| **OTP application** | a packaged Erlang component that starts and stops as a unit; this runtime is the application `wasm` | [Put it in an OTP application](otp.md) |
| **process** | a lightweight Erlang thread with its own memory and mailbox; it can be killed without affecting the others | [Using workers](worker.md) |
| **supervisor**, **supervision tree** | a process that starts other processes and restarts them when they crash; supervisors nested inside each other form a tree | [Put it in an OTP application](otp.md) |
| **word** | the BEAM's unit of process memory: 8 bytes on a 64-bit system | [The compiled tier](compiled-tier.md) |

### Runtime terms

| term | meaning | read |
| --- | --- | --- |
| **ABI** (generated code) | the rules that compiled code and the interpreter both follow to work together; a code cache written under different rules is refused | [The compiled tier](compiled-tier.md) |
| **adapter** | a module that teaches the worker kernel one language, by implementing `wasm_worker_adapter` | [Writing an adapter](worker-contract.md) |
| **arena** | where a restored memory keeps its own copies of the pages it wrote | [Memory](memory.md) |
| **async ABI** | the Canonical ABI's `async func`, `stream` and `future`; called with `wasm_component:call_async/4` | [Components](components.md) |
| **`atomics`** | an OTP module for arrays of integers that can be changed in place; linear memory is built from them | [Memory](memory.md) |
| **`baseline`, `full`** | the two compile levels: `full` code runs faster, `baseline` code compiles faster | [The compiled tier](compiled-tier.md) |
| **Canonical ABI** | the rules for how a component-level value (a string, a record, a handle) is stored in a core module's memory and read back | [Components](components.md) |
| **capability** | a permission granted by supplying an import, such as a directory or an address | [WASI](wasi.md) |
| **chunk** | one `atomics` array of linear memory; memory grows by adding chunks | [Memory](memory.md) |
| **class**, **kind** | the two fields that classify an error: one of five classes (`malformed`, `invalid`, `link`, `trap`, `exhaustion`) and a kind your code can match on | [Getting started](getting-started.md) |
| **cleanup steward** | the process, one per request, that is responsible for that request's cleanup, together with the reaper | [Worker internals](worker-internals.md) |
| **code cache** | compiled BEAM modules saved on disk under `code_cache_dir`, so a restart does not compile them again | [The compiled tier](compiled-tier.md) |
| **command**, **reactor** | a guest that runs `main` once and exits, compared with one that exports functions and stays ready | [Producing a module](guests.md) |
| **compiled tier** | translating the functions a guest runs most into BEAM code, through Core Erlang | [The compiled tier](compiled-tier.md) |
| **component** | a Component Model binary: core modules plus typed interfaces, instantiated with `wasm_component` | [Components](components.md) |
| **content hash** | a checksum of a module's bytes; two identical files have the same hash, so the runtime can reuse its work | [Embedding](embedding.md) |
| **Core Erlang** | an intermediate language inside the Erlang compiler; the compiled tier generates it | [The compiled tier](compiled-tier.md) |
| **export**, **import** | a guest function the host can call, and an operation the host supplies to the guest | above |
| **fuel** | a work budget: the guest stops after it has done that much work; compiled code does not count it | [Embedding](embedding.md) |
| **guardian** | the process that owns one worker request: its deadline, its files and its runner | [Worker internals](worker-internals.md) |
| **host**, **guest** | Erlang, and the WebAssembly code it runs | above |
| **image** | the stored copy of a snapshot, in memory or in a file; restores read it without copying it | [Snapshots](snapshots.md) |
| **interpreted** | run by the interpreter, which reads the guest's instructions one by one | [The compiled tier](compiled-tier.md) |
| **keeper**, **holder** | `wasm_keeper` records which processes hold each memory, table or image (the holders), and frees it when the last holder is gone | [Memory](memory.md) |
| **limits** | the maximum values for one instance: fuel, memory pages, call depth, heap; start from `wasm_limits:untrusted/0` or `trusted/0` | [Embedding](embedding.md) |
| **linear memory** | the guest's byte array, which it can grow; measured in pages of 64 KiB | [Memory](memory.md) |
| **module**, **instance** | validated code, and one running copy of it with its own state | above |
| **module cache** | one compiled copy of each module per node, found by its content hash | [Put it in an OTP application](otp.md) |
| **owner** | the process responsible for an instance or an image; when it exits, what it holds is released | [Embedding](embedding.md) |
| **page** | a linear-memory page is 64 KiB; a snapshot image is copied in smaller pages of 4 KiB | [Memory](memory.md) |
| **page budget** | the maximum number of linear-memory pages for the whole node, kept by `wasm_engine` | [Memory](memory.md) |
| **page table** | for each restored memory, one entry per 4 KiB page, saying whether the page is still the image's or a copy in the arena | [Memory](memory.md) |
| **preview 1**, **0.2**, **0.3** | the WASI versions: preview 1 for core modules, 0.2 for components; 0.3 is not provided | [WASI](wasi.md), [Components](components.md) |
| **profile** | `plugin` or `script`: one name that sets the compile options for a kind of workload | [The compiled tier](compiled-tier.md) |
| **reaper** | the process, one per node, that removes what finished requests left on disk | [Worker internals](worker-internals.md) |
| **resource**, **`own`**, **`borrow`** | a component-level object behind a handle; `own` gives it away, `borrow` lends it for one call | [Components](components.md) |
| **restore ahead** | a worker restoring the next request's instance while it waits for that request | [Tuning](tuning.md) |
| **runner** | the process that runs the guest for one request | [Worker internals](worker-internals.md) |
| **snapshot** | a saved copy of a guest after it started, restored as a fresh instance for each request | [Snapshots](snapshots.md) |
| **trap** | the guest stopped on an error that the specification defines, such as `unreachable`; returned as a value | [Getting started](getting-started.md) |
| **translation cache** | two entries in compiled code that remember where recently used memory pages are, so most memory accesses skip the page table | [The compiled tier](compiled-tier.md) |
| **WASI** | the standard imports for files, clocks, random data and networking | [WASI](wasi.md) |
| **worker**, **worker kernel** | a process that owns an instance; `wasm_script_worker` runs one request at a time with a deadline | [Using workers](worker.md) |

## Read this next

[Getting started](getting-started.md) to run a module, or
[Architecture](architecture.md) to see how the runtime is built.
