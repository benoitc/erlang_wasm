# Documentation

Nineteen pages, in the three groups the generated site uses. Start at
[Getting started](getting-started.md) if you are new, or
[Architecture](architecture.md) if you are here to change something.

## Guides

You are running WebAssembly and want to know how.

| | |
| --- | --- |
| [Getting started](getting-started.md) | an empty project to a running module |
| [Guests](guests.md) | producing a `.wasm` this runtime can run |
| [Embedding](embedding.md) | holding modules and instances correctly |
| [Host functions](host-functions.md) | calling from WebAssembly into Erlang |
| [WASI](wasi.md) | running a `wasm32-wasip1` program, and its capabilities |
| [Streams](streams.md) | talking to a guest while it runs |
| [Workers](worker.md) | running untrusted code one request at a time |
| [The adapter contract](worker-contract.md) | teaching the worker kernel a language |
| [JavaScript](javascript.md) | QuickJS |
| [Python](python.md) | CPython |
| [Lua](lua.md) | Lua 5.4 |
| [Snapshots](snapshots.md) | starting an interpreter once, not per request |
| [The compiled tier](compiled-tier.md) | compiling hot functions to Core Erlang |
| [Tuning](tuning.md) | when requests are slower than you expected |

## Reference

| | |
| --- | --- |
| [Features and conformance](features.md) | what is implemented, what it scores, what it costs |
| [Security](security.md) | the threat model, and what is yours to hold |
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
