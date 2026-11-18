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

`wasm:load/1` does the first two steps once per node and keeps the result in
the **module cache**. So load a module when your application starts, not for
each request: the cache refuses new modules past a **load rate** and a
**resident cap** (see the [glossary](#glossary)). See
[Getting started](getting-started.md) and
[Modules are loaded once](design-principles.md#modules-are-loaded-once).

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
[WASI preview 1](wasi.md).

**Linear memory** is the guest's byte array. The guest can make it larger
while it runs. Numbers pass directly as call arguments. Strings and binaries
pass through memory. See [Pass bytes](examples/pass-bytes.md).

## Guest errors are returned as values

Nothing a guest does makes a call raise an exception. A malformed binary, a
module that fails validation, a trap and a limit that runs out all come back
as `{error, Error}`. So a guest that fails never crashes the process that
called it. `Error` is a map with four keys:

| key | what it holds |
| --- | --- |
| `class` | one of five atoms: `malformed`, `invalid`, `link`, `trap`, `exhaustion` |
| `kind` | an atom that names this failure, such as `out_of_fuel`; your code matches on it |
| `msg` | the message the WebAssembly specification gives, as a binary |
| `ctx` | a map of details for diagnosis, such as the index of the function |

This is what a call that ran out of fuel returns:

```erlang
{error, #{class => exhaustion, kind => out_of_fuel,
          msg => ~"out of fuel", ctx => #{func => 0}}}
```

`wasm:format_error/1` turns the map into one line of text for your logs:

```text
exhaustion: out of fuel (out_of_fuel) #{func => 0}
```

Match on `class` and `kind`, never on `msg`:

```erlang
case wasm:call(Inst, ~"run", []) of
    {ok, Results} ->
        {done, Results};
    {error, #{kind := out_of_fuel}} ->
        too_much_work;
    {error, #{class := trap} = E} ->
        logger:warning("guest trapped: ~ts", [wasm:format_error(E)]),
        trapped;
    {error, E} ->
        {failed, wasm:format_error(E)}
end.
```

`wasm_script_worker` answers with the same map shape, with classes of its
own (`worker`, `adapter` and `runtime`), listed in `wasm_worker_error`. A few mistakes in
your own code do raise, such as a malformed network grant.
[Design principles](design-principles.md#failures-are-values-at-the-guest-boundary)
lists them.

## Limits, fuel and deadlines

**Limits** are the maximum values for one instance: fuel, call depth, memory
pages, host calls, heap size and a deadline. Start from
`wasm_limits:untrusted/0`. [Configuration](configuration.md#the-limits-map)
lists each one with its default.

**Fuel** is a budget of work, not of time: the guest stops after it has done
that much work. A host function that blocks uses no fuel, and compiled code
does not count it.

The BEAM shares the CPUs between processes by itself. Each **scheduler**, one
thread per CPU core, runs a process for a fixed number of **reductions**
(units of work the BEAM counts), then switches to another process. So a guest
that loops forever does not stop your other processes, but nothing stops the
guest either. A **deadline** does that. See
[Limit the work and the time](worker.md#limit-the-work-and-the-time).

## Put an instance in its own process

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

The **image** is what a snapshot saves: the guest's memory, globals and
tables, kept in memory or in a file. A restore does not copy the image. Every
instance restored from one image reads its pages in the image, and copies a
4 KiB page only when it writes to it. See
[Restore a snapshot](examples/restore-a-snapshot.md) and
[Snapshots](snapshots.md).

Every restore starts from the same bytes. So a random seed or a clock time
that the guest read before the capture is the same in every request. See
[Snapshots are deterministic](design-principles.md#snapshots-are-deterministic).

Snapshots reduce the cost of **starting** a guest. The compiled tier reduces
the cost of **running** it. They solve different problems, and you can use
them together or apart.

## The life of a request

```text
acquire                       use                      release
accept, reserve capacity  --> call before a deadline --> cleanup must be proved
```

Each request goes through three steps. First it is accepted and its resources
are reserved. Then the guest is called and must finish before a deadline.
Last, everything the request used must be cleaned up, and the runtime keeps
track of that cleanup until it is done. See
[Worker internals](worker-internals.md).

## Glossary

Every term the other pages use, with the page that explains it. The Erlang
terms come first, for readers new to Erlang. The words that only the
internals pages use come last.

### Erlang terms

| term | meaning | read |
| --- | --- | --- |
| **atom** | a named constant, such as `ok` or `trap`. The node keeps every atom forever and has a fixed maximum, so the runtime never turns guest data into atoms | [Design principles](design-principles.md#guest-data-never-becomes-an-atom) |
| **behaviour** | an Erlang interface: the list of callback functions a module must export to play a given role | [Writing an adapter](worker-contract.md) |
| **BEAM** | the Erlang virtual machine, which runs Erlang code; "BEAM code" is code compiled for it | [Architecture](architecture.md) |
| **ETS table** | an in-memory table that belongs to one process and is deleted when that process exits | [Hold modules and instances](embedding.md) |
| **heap** | the memory of one Erlang process, where its data lives; each process has its own | [Tuning](tuning.md) |
| **link**, **trap exits** | a link connects two processes so that when one exits, the other is told or exits too; a process that traps exits receives a message instead of exiting | [Hold modules and instances](embedding.md) |
| **mailbox** | the queue of messages a process has received; it handles them one at a time | [Using workers](worker.md) |
| **NIF** | a "native implemented function": C code loaded into the BEAM and called like an Erlang function | [Design principles](design-principles.md#pure-erlang-not-a-binding) |
| **node** | one running BEAM, with all its processes | [Architecture](architecture.md) |
| **OTP application** | a packaged Erlang component that starts and stops as a unit; this runtime is the application `wasm` | [Hold modules and instances](embedding.md) |
| **process** | a lightweight Erlang thread with its own memory and mailbox; it can be killed without affecting the others | [Using workers](worker.md) |
| **reduction** | the unit of work the BEAM counts to share the CPU: a process runs for a fixed number of reductions, then another process gets its turn. It is not a time limit | [Limits, fuel and deadlines](#limits-fuel-and-deadlines) |
| **scheduler** | one BEAM thread that runs processes, usually one per CPU core; it switches between processes so that no process keeps a core | [Limits, fuel and deadlines](#limits-fuel-and-deadlines) |
| **supervisor**, **supervision tree** | a process that starts other processes and restarts them when they crash; supervisors nested inside each other form a tree | [Hold modules and instances](embedding.md) |
| **word** | the BEAM's unit of process memory: 8 bytes on a 64-bit system | [The compiled tier](compiled-tier.md) |

### Runtime terms

| term | meaning | read |
| --- | --- | --- |
| **adapter** | a module that teaches the worker kernel one language, by implementing `wasm_worker_adapter` | [Writing an adapter](worker-contract.md) |
| **async ABI** | the Canonical ABI's `async func`, `stream` and `future`; called with `wasm_component:call_async/4` | [Components](components.md) |
| **`baseline`, `full`** | the two compile levels: `full` code runs faster, `baseline` code compiles faster | [The compiled tier](compiled-tier.md) |
| **Canonical ABI** | the rules for how a component-level value (a string, a record, a handle) is stored in a core module's memory and read back | [Components](components.md) |
| **capability** | a permission granted by supplying an import, such as a directory or an address | [WASI preview 1](wasi.md) |
| **class**, **kind** | the two fields that classify an error: one of five classes (`malformed`, `invalid`, `link`, `trap`, `exhaustion`) and a kind your code can match on | [above](#guest-errors-are-returned-as-values) |
| **code cache** | compiled BEAM modules saved on disk under `code_cache_dir`, so a restart does not compile them again | [The compiled tier](compiled-tier.md) |
| **command**, **reactor** | a guest that runs `main` once and exits, compared with one that exports functions and stays ready | [Producing a guest module](guests.md) |
| **compiled tier** | translating the functions a guest runs most into BEAM code, through Core Erlang | [The compiled tier](compiled-tier.md) |
| **component** | a Component Model binary: core modules plus typed interfaces, instantiated with `wasm_component` | [Components](components.md) |
| **content hash** | a checksum of a module's bytes; two identical files have the same hash, so the runtime can reuse its work | [Hold modules and instances](embedding.md) |
| **Core Erlang** | an intermediate language inside the Erlang compiler; the compiled tier generates it | [The compiled tier](compiled-tier.md) |
| **deadline** | the wall-clock time a call may take; the process that owns the instance kills it when the time passes | [Using workers](worker.md) |
| **export**, **import** | a guest function the host can call, and an operation the host supplies to the guest | [above](#the-guest-asks-erlang-decides) |
| **fuel** | a work budget: the guest stops after it has done that much work; compiled code does not count it | [above](#limits-fuel-and-deadlines) |
| **guardian** | the process that owns one worker request: its deadline, its files and its runner | [Worker internals](worker-internals.md) |
| **host**, **guest** | Erlang, and the WebAssembly code it runs | [above](#who-runs-what) |
| **image** | what a snapshot saves: the guest's memory, globals and tables, in memory or in a file. A restore reads it without copying it, and workers with the same adapter and options share one | [Snapshots](snapshots.md) |
| **interpreted** | run by the interpreter, which reads the guest's instructions one by one | [The compiled tier](compiled-tier.md) |
| **lift**, **lower** | for a component: to **lower** is to turn an Erlang value into what the core code reads (numbers, and bytes in its memory); to **lift** is to turn the core code's result back into an Erlang value. `wasm_component:call/4` does both, following the signature you give it | [Components](components.md), [Component internals](component-internals.md) |
| **limits** | the maximum values for one instance: fuel, memory pages, call depth, host calls, heap and a deadline; start from `wasm_limits:untrusted/0` or `trusted/0` | [Configuration](configuration.md#the-limits-map) |
| **linear memory** | the guest's byte array, which it can grow; measured in pages of 64 KiB | [Memory](memory.md) |
| **load rate** | how many new modules the module cache decodes in one second: 50 unless you set `max_module_loads_per_second`. Past it, `wasm:load/1` answers `{error, {load_rate_exceeded, 50}}`. Loading bytes that are already in the cache is not counted | [Modules are loaded once](design-principles.md#modules-are-loaded-once) |
| **module**, **instance** | validated code, and one running copy of it with its own state | [above](#who-runs-what) |
| **module cache** | one decoded and validated copy of each module per node, found by its content hash | [Hold modules and instances](embedding.md) |
| **owner** | the process responsible for an instance or an image; when it exits, what it holds is released | [Hold modules and instances](embedding.md) |
| **page** | a linear-memory page is 64 KiB; a snapshot image is copied in smaller pages of 4 KiB | [Memory](memory.md) |
| **page budget** | the maximum number of linear-memory pages for the whole node, kept by `wasm_engine` | [Memory](memory.md) |
| **preview 1**, **0.2**, **0.3** | the WASI versions: preview 1 for core modules, 0.2 and 0.3 for components | [WASI preview 1](wasi.md), [WASI 0.3](wasi-0-3.md) |
| **profile** | the `profile` option of `wasm:instantiate/3`: `plugin` or `script`, one name that sets the compile options for a kind of workload. Two other uses of the word are different things: `script_v1` is the protocol the shipped adapters speak, and the relaxed SIMD "deterministic profile" is a term from the specification | [The compiled tier](compiled-tier.md) |
| **reaper** | the process, one per node, that removes what finished requests left on disk | [Worker configuration](worker-reference.md) |
| **resident cap** | the most the module cache holds at once: 256 modules (`max_resident_modules`) and 2 GiB (`max_resident_module_bytes`). Past it, a load answers `{error, {too_many_modules, 256}}` or `{error, {module_cache_full, Bytes}}` | [Configuration](configuration.md) |
| **resource**, **`own`**, **`borrow`** | a component-level object behind a handle; `own` gives it away, `borrow` lends it for one call | [Components](components.md) |
| **`resource_limit`** | an option of `wasm_component:instantiate/3`: the most host resource handles a component may hold at once, and the most async calls it may have waiting. Past it, the call traps with `resource_limit_reached`. There is no limit unless you set one | [Component internals](component-internals.md#resources-and-host-handles), [WASI 0.3](wasi-0-3.md) |
| **restore ahead** | a worker restoring the next request's instance while it waits for that request | [Tuning](tuning.md) |
| **runner** | the process that runs the guest for one request | [Worker internals](worker-internals.md) |
| **snapshot** | a saved copy of a guest after it started, restored as a fresh instance for each request | [Snapshots](snapshots.md) |
| **subtask** | an async call from one component into another that waited before it returned: the caller goes on, and the subtask tells it later that it has returned | [Components](components.md#compose-components) |
| **trap** | the guest stopped on an error that the specification defines, such as `unreachable`; returned as a value | [Getting started](getting-started.md) |
| **WASI** | the standard imports for files, clocks, random data and networking | [WASI preview 1](wasi.md) |
| **worker**, **worker kernel** | a process that owns an instance; `wasm_script_worker` runs one request at a time with a deadline | [Using workers](worker.md) |

### Words from the internals pages

You do not need these to use the runtime. They are here so that the
internals pages read without surprises.

| term | meaning | read |
| --- | --- | --- |
| **ABI** (generated code) | the rules that compiled code and the interpreter both follow to work together; a code cache written under different rules is refused | [The compiled tier](compiled-tier.md) |
| **arena** | where a restored memory keeps its own copies of the pages it wrote | [Memory](memory.md) |
| **`atomics`** | an OTP module for arrays of integers that can be changed in place; linear memory is built from them | [Memory](memory.md) |
| **chunk** | one `atomics` array of linear memory; memory grows by adding chunks | [Memory](memory.md) |
| **cleanup steward** | the process, one per request, that is responsible for that request's cleanup, together with the reaper | [Worker internals](worker-internals.md) |
| **keeper**, **holder** | `wasm_keeper` records which processes hold each memory, table or image (the holders), and frees it when the last holder is gone | [Memory](memory.md) |
| **lease** | a word used in three internal places: an instance's hold on a slot of compiled code, a running call's shared hold on a garbage-collected object store, and the counters that let a snapshot capture prove that no call is running. You never take or give back a lease yourself; `snapshotable => true` only creates the last kind | [Architecture](architecture.md), [Garbage collection](gc.md), [Snapshots](snapshots.md) |
| **page table** | for each restored memory, one entry per 4 KiB page, saying whether the page is still the image's or a copy in the arena | [Memory](memory.md) |
| **translation cache** | two entries in compiled code that remember where recently used memory pages are, so most memory accesses skip the page table | [The compiled tier](compiled-tier.md) |

## Read this next

[Design principles](design-principles.md) to see why the API looks the way
it does, [Getting started](getting-started.md) to run a module, or
[Configuration](configuration.md) for every setting.
