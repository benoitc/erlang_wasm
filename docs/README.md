# Documentation

Pick the row that matches what you want to do, then follow the index below.

| I want to | start with |
| --- | --- |
| call exported WebAssembly functions from Erlang | [Getting started](getting-started.md), then [Embedding](embedding.md) |
| run a program that has a `main` (a WASI command) | [WASI](wasi.md) |
| run WebAssembly I did not write | [Workers](worker.md), then [Security](security.md) |
| run JavaScript, Python or Lua source | [JavaScript](javascript.md), [Python](python.md), [Lua](lua.md) |
| stop paying interpreter startup on every request | [Snapshots](snapshots.md) |
| speed up a workload I have measured | [The compiled tier](compiled-tier.md) |

The pages are in the same five groups the generated site uses.

## Start here

| | |
| --- | --- |
| [Getting started](getting-started.md) | an empty project to a running module |
| [Producing a module](guests.md) | building a `.wasm` this runtime can run, and choosing its shape |

## Guides

You are running WebAssembly and want to know how.

| | |
| --- | --- |
| [Embedding](embedding.md) | holding modules and instances correctly |
| [Host functions](host-functions.md) | calling from WebAssembly into Erlang |
| [WASI](wasi.md) | running a `wasm32-wasip1` program, and its capabilities |
| [Streams](streams.md) | talking to a guest while it runs |
| [Workers](worker.md) | running untrusted code one request at a time |
| [The adapter contract](worker-contract.md) | teaching the worker kernel a language |
| [JavaScript](javascript.md) | QuickJS |
| [Python](python.md) | CPython |
| [Lua](lua.md) | Lua 5.4 |

## Operate

You have it working and want it fast, bounded and safe.

| | |
| --- | --- |
| [Snapshots](snapshots.md) | starting an interpreter once, not per request |
| [The compiled tier](compiled-tier.md) | compiling hot functions to BEAM code |
| [Tuning](tuning.md) | when requests are slower than you expected |
| [Security](security.md) | the threat model, and what is yours to hold |

## Reference

| | |
| --- | --- |
| [Features and conformance](features.md) | what is implemented, what it scores, what it costs |
| [Changelog](../CHANGELOG.md) | what changed, and what to set |

## Internals

You are changing the runtime rather than using it.

| | |
| --- | --- |
| [Architecture](architecture.md) | the module map, the layers, the path of a call |
| [Adding an instruction](adding-an-instruction.md) | the change you will make most often |
| [Design notes](design-notes.md) | why it is built this way |

Two more things live outside `docs/` and are worth knowing about:
`test/audit/PERF.md` is the measurement record every performance claim cites,
and `test/audit/ATTEMPTS.md` is what was tried and reverted. Read the second
before proposing an optimisation.
