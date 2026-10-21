# Documentation

This is the index. Start with the row that matches why you are here and read
its pages in order; every page ends by saying what to read next.

| You want to | read, in order |
| --- | --- |
| run WebAssembly from Erlang | [What it is for](introduction.md), [Concepts](concepts.md), [Getting started](getting-started.md), then the guide for your case below |
| understand how it works | [Concepts](concepts.md), [Architecture](architecture.md), the page for the part you care about under [Internals](#internals), then [Design notes](design-notes.md) for the why |
| change it | [CONTRIBUTING.md](../CONTRIBUTING.md), the [recipe](contributing/recipes.md) for your change, then [Testing](contributing/testing.md) and [Measuring](contributing/measuring.md) |

```text
  Orientation      Start here: what it is for, concepts, getting started
       |
  Using it         Examples, Guides, Operate, Reference
       |
  How it works     Internals: architecture, memory, workers, design notes
       |
  Contributing     CONTRIBUTING.md, recipes, testing, measuring
```

Each layer assumes the one above it. Stop at the layer that answers your
question; most readers never need the last two.

If you already know the task:

| I want to | start with |
| --- | --- |
| call exported WebAssembly functions from Erlang | [Getting started](getting-started.md), then [Embedding](embedding.md) |
| run a program that has a `main` (a WASI command) | [WASI](wasi.md) |
| run a Component Model component with typed interfaces | [Components](components.md) |
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
| [Use a component resource](examples/use-a-component-resource.md) | construct, use and drop a resource, and pass one between composed components |
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
| [Components](components.md) | running and composing Component Model components, and their typed signatures |
| [WASI 0.2](wasi-0-2.md) | the interfaces a component imports, and how to grant each |
| [HTTP](http.md) | outbound requests from a component, and serving one |
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
| [Memory](memory.md) | linear memory, restored images, the keeper and the page budget |
| [Garbage collection](gc.md) | the GC proposal's heap, roots and collector |
| [Worker internals](worker-internals.md) | how the worker kernel and its reaper are built |
| [Component internals](component-internals.md) | how a component becomes core instances and calls |
| [Design notes](design-notes.md) | why it is built this way |

## Contributing

You are about to change it.

| | |
| --- | --- |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | the checks, the rules, where things live |
| [Recipes](contributing/recipes.md) | one section per kind of change: the files, the test, the page |
| [Adding an instruction](contributing/adding-an-instruction.md) | the change you will make most often |
| [Testing](contributing/testing.md) | running the suites, the fixtures, a test that can fail |
| [Measuring](contributing/measuring.md) | turning a number into a claim |
| [Changing the NIF](contributing/nif.md) | running the file NIF under a sanitizer |

`test/audit/PERF.md` is the measurement record every performance claim cites,
and `test/audit/ATTEMPTS.md` is what was tried and dropped. Read the second
before proposing an optimisation.
