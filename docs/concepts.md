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
process. The **image** is the stored copy, in memory or on disk. See
[Restore a snapshot](examples/restore-a-snapshot.md) and
[Snapshots](snapshots.md).

Snapshots cut the cost of **starting**; the compiled tier cuts the cost of
**running**. They solve different problems and work together or apart.
