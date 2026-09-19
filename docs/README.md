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

The pages are in the same groups the generated site uses.

## Start here

| | |
| --- | --- |
| [What it is for](introduction.md) | what you can do with it, and whether it fits |
| [Concepts](concepts.md) | the words every other page uses, defined once |
| [What you get](what-you-get.md) | what the library provides, and what you bring |
| [Getting started](getting-started.md) | an empty project to a running module |
| [Producing a module](guests.md) | building a `.wasm` this runtime can run, and choosing its shape |

## Examples

One task per page, each run as written by the test suite.

| | |
| --- | --- |
| [Call an export](examples/call-an-export.md) | build a module from text and call it |
| [Call Erlang from a guest](examples/call-erlang-from-a-guest.md) | give a guest a host function |
| [Pass bytes](examples/pass-bytes.md) | send a binary through linear memory and read it back |
| [Run a WASI command](examples/run-a-wasi-command.md) | a Rust program with one read-only directory |
| [Stop a runaway](examples/stop-a-runaway.md) | a fuel budget, and a deadline in a worker |
| [A plugin per request](examples/plugin-per-request.md) | a fresh instance for every request |
| [Restore a snapshot](examples/restore-a-snapshot.md) | start once, restore a fresh copy per request |
| [Turn on the compiled tier](examples/turn-on-the-tier.md) | compile a hot function to BEAM code |
| [Run JavaScript](examples/run-javascript.md) | a script through the worker kernel |
| [Run Python](examples/run-python.md) | the same, with CPython |

## Guides

You are running WebAssembly and want to know how.

| | |
| --- | --- |
| [Put it in an OTP application](otp.md) | loading at startup, ownership, supervision, shutdown |
| [Pass data in and out](passing-data.md) | numbers, bytes, strings and JSON |
| [Embedding](embedding.md) | holding modules and instances correctly |
| [Host functions](host-functions.md) | calling from WebAssembly into Erlang |
| [WASI](wasi.md) | running a `wasm32-wasip1` program, and its capabilities |
| [Streams](streams.md) | talking to a guest while it runs |
| [Using workers](worker.md) | running untrusted code one request at a time, with a deadline |
| [Hosting scripting languages](scripting.md) | JavaScript, Python and Lua, one request per sandbox |
| [Writing an adapter](worker-contract.md) | teaching the worker kernel another language |
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
| [Worker configuration](worker-reference.md) | every worker setting, with its default |
| [Features and conformance](features.md) | what is implemented, what it scores, what it costs |
| [Upgrading from 0.3](upgrading.md) | moving from copied examples to the installed workers |
| [Changelog](../CHANGELOG.md) | what changed, and what to set |

## Internals

You are changing the runtime rather than using it.

| | |
| --- | --- |
| [Architecture](architecture.md) | the module map, the layers, the path of a call |
| [Worker internals](worker-internals.md) | how the worker kernel and its reaper are built |
| [Adding an instruction](adding-an-instruction.md) | the change you will make most often |
| [Design notes](design-notes.md) | why it is built this way |

Two more things live outside `docs/` and are worth knowing about:
`test/audit/PERF.md` is the measurement record every performance claim cites,
and `test/audit/ATTEMPTS.md` is what was tried and reverted. Read the second
before proposing an optimisation.
