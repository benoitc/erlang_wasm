# Concepts

This page defines the words every other page uses, in the order you meet them.
Read it once before the guides; each term links to the page that goes deeper.

## Who runs what

Four words carry the rest:

| word | what it is |
| --- | --- |
| **host** | Erlang/OTP: your application, the system providing resources and permissions |
| **guest** | the WebAssembly code, the program being run inside that system |
| **module** | a packaged program: validated code, plus what it imports and exports |
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

Decoding turns bytes into a module, validation checks its types and structure
before anything runs, instantiation builds state and links imports, and a call
runs an export. See [Getting started](getting-started.md).

## The guest asks, Erlang decides

An **export** is a guest function the host can call. An **import** is a named
operation provided by the host: the guest names an operation, the host
supplies what it does, and a missing import means the guest cannot do it at
all. That is what a **capability** is: a permission the host grants by
supplying an import. See [Host functions](host-functions.md).

**WASI** is a standard set of imported operations for files, clocks, random
data and networking. You grant each one by name: a directory, an address.
Anything not granted does not exist for the guest. See [WASI](wasi.md).

**Linear memory** is the guest's resizable byte array. Numbers pass through a
call directly; strings and binaries pass through memory. See
[Pass bytes](examples/pass-bytes.md).

## Guest errors are returned as values

Nothing raises. A malformed binary, a type error, a trap and an exhausted limit
all come back as `{error, #{class, kind, msg, ctx}}`, so a failing guest never
crashes the process that called it.

**Fuel** is a work budget, not a clock: the guest stops when it has done that
much work. **Limits** are the ceilings on one instance: fuel, memory pages,
call depth, heap size. See [Embedding](embedding.md).

## A process tracks each running instance

```text
acquire                       use                      release
accept, reserve capacity  --> call before a deadline --> cleanup must be proved
```

An **owner** is the process responsible for cleanup. Put an instance in a
process of its own, a **worker**, and a timeout can kill it: a call made
directly runs in your process and cannot be interrupted. A worker is not a
second engine; it is an ordinary process that owns an instance. See
[Stop a runaway](examples/stop-a-runaway.md) and [Workers](worker.md).

## Deadlines and cleanup stay outside the guest

To run code that arrives at request time, the **worker kernel**,
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

An **adapter** teaches the kernel one language: how to start it, pass it a
script and read the result. The shipped ones cover JavaScript, Python and Lua,
and `wasm_worker_adapter` is the behaviour for writing another. See
[Run JavaScript](examples/run-javascript.md) and
[The adapter contract](worker-contract.md).

A **command** runs once from `main` and exits. A **reactor** exports functions
and stays ready between calls. Snapshots and the fast language paths need a
reactor.

## Two execution modes

```text
start by interpreting              compile hot code later
validated wasm --> Core Erlang --> loaded BEAM module
```

Every instance starts **interpreted**. The **compiled tier**, off by default,
turns the functions a module calls most into BEAM code, through **Core
Erlang**, an intermediate language the Erlang compiler already understands. It
costs time before it pays off, and it cannot enforce a fuel budget. See
[Turn on the compiled tier](examples/turn-on-the-tier.md).

## Start once, restore a fresh copy per request

```text
initialized instance --capture--> image --restore--> fresh instance
                                  (memory, globals, tables)
```

A **snapshot** is a frozen copy of a guest after startup, used as a template.
Restoring it gives a fresh instance that skips startup, so an interpreter that
takes seconds to start costs milliseconds per request. It is not a paused
process. The **image** is the stored copy, in memory or on disk. A restore
does not copy it: every instance restored from one image reads its pages in
place and copies only the 4 KiB pages it writes. See
[Restore a snapshot](examples/restore-a-snapshot.md) and
[Snapshots](snapshots.md).

Snapshots cut the cost of **starting**; the compiled tier cuts the cost of
**running**. They solve different problems and work together or apart.

## Glossary

Every term the other pages use, with the page that explains it.

| term | meaning | read |
| --- | --- | --- |
| **ABI** (generated code) | the contract between compiled code and the interpreter; a code cache written under another ABI is refused | [The compiled tier](compiled-tier.md) |
| **adapter** | a module teaching the worker kernel one language, implementing `wasm_worker_adapter` | [Writing an adapter](worker-contract.md) |
| **arena** | where a restored memory keeps its private copies of the pages it wrote | [Memory](memory.md) |
| **async ABI** | the Canonical ABI's `async func`, `stream` and `future`; called with `wasm_component:call_async/4` | [Components](components.md) |
| **`baseline`, `full`** | the two compile qualities: `full` runs faster, `baseline` compiles faster | [The compiled tier](compiled-tier.md) |
| **Canonical ABI** | how a component-level value (a string, a record, a handle) crosses into a core module's memory and back | [Components](components.md) |
| **capability** | a permission granted by supplying an import, such as a directory or an address | [WASI](wasi.md) |
| **chunk** | one `atomics` array of linear memory; memory grows by adding chunks | [Memory](memory.md) |
| **class**, **kind** | the two fields that classify an error: one of five classes (`malformed`, `invalid`, `link`, `trap`, `exhaustion`) and a machine-readable kind | [Getting started](getting-started.md) |
| **cleanup steward** | the per-request process that owns a request's cleanup with the reaper | [Worker internals](worker-internals.md) |
| **code cache** | compiled BEAM modules kept on disk under `code_cache_dir`, so a restart does not compile again | [The compiled tier](compiled-tier.md) |
| **command**, **reactor** | a guest that runs `main` once and exits, against one that exports functions and stays ready | [Producing a module](guests.md) |
| **compiled tier** | compiling the functions a guest runs most into BEAM code, through Core Erlang | [The compiled tier](compiled-tier.md) |
| **component** | a Component Model binary: core modules plus typed interfaces, instantiated with `wasm_component` | [Components](components.md) |
| **fuel** | a work budget: the guest stops when it has done that much work; compiled code does not run under it | [Embedding](embedding.md) |
| **guardian** | the process that owns one worker request: its deadline, its files and its runner | [Worker internals](worker-internals.md) |
| **host**, **guest** | Erlang, and the WebAssembly code it runs | above |
| **image** | the stored copy of a snapshot, in memory or in a file; restores read it in place | [Snapshots](snapshots.md) |
| **keeper**, **holder** | `wasm_keeper` records which processes hold each memory, table or image, and frees it when the last holder is gone | [Memory](memory.md) |
| **limits** | the ceilings on one instance: fuel, memory pages, call depth, heap; start from `wasm_limits:untrusted/0` or `trusted/0` | [Embedding](embedding.md) |
| **module**, **instance** | validated code, and one running copy of it with its own state | above |
| **module cache** | one compiled copy of each module per node, keyed by content hash | [Put it in an OTP application](otp.md) |
| **owner** | the process responsible for an instance or an image; when it exits, what it holds is released | [Embedding](embedding.md) |
| **page budget** | the node-wide ceiling on linear-memory pages, held by `wasm_engine` | [Memory](memory.md) |
| **page table** | per restored memory, one entry for each 4 KiB page: still the image's, or a private copy in the arena | [Memory](memory.md) |
| **preview 1**, **0.2**, **0.3** | the WASI generations: preview 1 for core modules, 0.2 for components; 0.3 is not provided | [WASI](wasi.md), [Components](components.md) |
| **profile** | `plugin` or `script`: one name that sets the compile options for a kind of workload | [The compiled tier](compiled-tier.md) |
| **reaper** | the node-wide process that removes what finished requests left on disk | [Worker internals](worker-internals.md) |
| **resource**, **`own`**, **`borrow`** | a component-level object behind a handle; `own` passes it, `borrow` lends it for one call | [Components](components.md) |
| **restore ahead** | a worker restoring the next request's instance while it waits | [Tuning](tuning.md) |
| **runner** | the process that runs the guest for one request | [Worker internals](worker-internals.md) |
| **snapshot** | a frozen copy of a guest after startup, restored as a fresh instance per request | [Snapshots](snapshots.md) |
| **trap** | the guest stopped on an error the specification defines, returned as a value | [Getting started](getting-started.md) |
| **translation cache** | two entries in compiled code remembering where recent memory pages live, so most accesses skip the page table | [The compiled tier](compiled-tier.md) |
| **WASI** | the standard imports for files, clocks, randomness and networking | [WASI](wasi.md) |
| **worker**, **worker kernel** | a process owning an instance; `wasm_script_worker` runs one request at a time with a deadline | [Using workers](worker.md) |

## Read this next

[Getting started](getting-started.md) to run a module, or
[Architecture](architecture.md) to see how the runtime is built.
