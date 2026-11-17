# Start here

This page helps you decide whether erlang_wasm fits what you want to do, and
if it does, which module you use and which page to read. Read it first. It
ends with the list of modules you may call and rely on; everything else is
internal.

erlang_wasm runs WebAssembly inside your Erlang application. It is written in
Erlang itself, so you have no native engine to build or ship.

## Is it for you

| use | what it looks like |
| --- | --- |
| portable plugins | add behaviour to a running system without loading native code into the VM |
| language runtimes | run JavaScript, Python or Lua code that arrives with a request, each request in its own sandbox |
| rule evaluation | give rules explicit inputs, explicit permissions and a deadline |
| shared validators | run the same checks in several services and languages |
| small domain languages | compile a small business-specific language to WebAssembly and run it here |
| runtime research | study the whole machine, written in a high-level functional language |

Choose erlang_wasm when these points matter to your application:

- how long a request lives and what it may access are part of your product;
- you want to inspect or change how the runtime behaves;
- a release that is mostly Erlang is easier for you to operate;
- the measured speed is already enough for you.

If you need the fastest possible guest execution above all, a native engine
such as Wasmtime, embedded through a NIF (native code loaded into the Erlang
VM), is a better fit.

## What do you have

Find the row for what you have. It names the module you call and the page
that shows you how.

| you have | you use | read |
| --- | --- | --- |
| a core `.wasm` module | `wasm`, and `wasi_preview1` if it imports WASI | [Getting started](getting-started.md) |
| a program with a `main` (a WASI command) | `wasi` | [WASI](wasi.md) |
| a WASI 0.2 or 0.3 component | `wasm_component`, `wasi_preview2`, `wasi_preview3` | [Components](components.md), [WASI 0.2](wasi-0-2.md), [WASI 0.3](wasi-0-3.md) |
| untrusted code, one instance per request | `wasm_instance_worker` | [Using workers](worker.md) |
| a script (JavaScript, Python, Lua) sent with each request | `wasm_script_worker` and an adapter | [Hosting scripting languages](scripting.md) |
| an HTTP handler component | `wasi_http_listener` | [HTTP](http.md) |
| a change to make in the runtime | [CONTRIBUTING.md](../CONTRIBUTING.md) | [Where things are](map.md), [Architecture](architecture.md) |

The library gives you the modules. You bring the guest: the `.wasm` file, or
for a script the language runtime file and the source code. You also bring
the values for the limits, and the supervision. You do not need anything in
`examples/`: it holds two demonstrations, `plugin_worker` and `qjs_worker`,
for you to read and copy.

## Read in this order

Pick the path for what you do. Stop when your question is answered.

**You use it** to run WebAssembly from your code:

1. [Concepts](concepts.md): the words every other page uses.
2. [Getting started](getting-started.md): an empty project to a running
   module.
3. [Producing a module](guests.md): building a `.wasm` this runtime can run.
4. The [examples](examples/call-an-export.md), one task per page.
5. [Embedding](embedding.md), [Host functions](host-functions.md) and
   [Pass data in and out](passing-data.md).
6. The guide for your case, from the table above.

**You operate it** in production, and want it bounded, fast and safe:

1. [Using workers](worker.md): untrusted code with a deadline.
2. [Put it in an OTP application](otp.md): loading, ownership, supervision.
3. [Worker configuration](worker-reference.md): every setting, with its
   default.
4. [Security](security.md): what the sandbox covers, and what is yours.
5. [Snapshots](snapshots.md), [The compiled tier](compiled-tier.md) and
   [Tuning](tuning.md), once you have measured.
6. [Upgrading from 0.3](upgrading.md) and the [Changelog](../CHANGELOG.md)
   before each upgrade.

**You change it**:

1. [CONTRIBUTING.md](../CONTRIBUTING.md): the checks and the rules.
2. [Where things are](map.md): every module, and the suites for each area.
3. [Architecture](architecture.md): how the modules depend on each other,
   and the path of a call.
4. The internals page for your area: [Memory](memory.md),
   [Garbage collection](gc.md), [Worker internals](worker-internals.md) or
   [Component internals](component-internals.md).
5. [Recipes](contributing/recipes.md): the files, the test and the page for
   each kind of change.
6. [Testing](contributing/testing.md) and
   [Measuring](contributing/measuring.md).
7. [Design notes](design-notes.md): why it is built this way.

## Supported API

A **supported** module is one you may call and rely on: when it changes in
a way that breaks your code, the changelog says so. The guides tell you to
call these modules and no others.

| area | supported modules |
| --- | --- |
| load, run and limit modules | `wasm`, `wasi`, `wasi_preview1`, `wasm_limits`, `wasm_engine`, `wasm_error` |
| components | `wasm_component`, `wasi_preview2`, `wasi_preview3` |
| HTTP | `wasi_http`, `wasi_http_listener`, and the transports `wasi_http_h1` and `wasi_http_h2` |
| workers | `wasm_instance_worker`, `wasm_script_worker`, `wasm_worker_error` |
| language adapters | `wasm_javascript`, `wasm_javascript_command`, `wasm_python`, `wasm_python_command`, `wasm_lua` |

An **extension point** is a behaviour: a list of callbacks your own module
exports so that the runtime can use it. These are supported too:

| behaviour | what your module does | page |
| --- | --- | --- |
| `wasm_worker_adapter` | teaches the worker kernel another language; check it with the test kit `wasm_adapter_conformance` | [Writing an adapter](worker-contract.md) |
| `wasi_http_transport` | sends the outbound HTTP requests of a component | [HTTP](http.md) |

A few internal modules have one or two functions that a guide documents.
Those functions are supported; the rest of the module is not:

| function | what it is for | page |
| --- | --- | --- |
| `wasm_jit:await/2`, `counts/0`, `diagnostics/0`, `shards/1`, `shard_count/2` | waiting for and inspecting the compiled tier | [The compiled tier](compiled-tier.md) |
| `wasm_async:host_read/3`, `host_sink/2` | reading a stream that a component returns | [Components](components.md) |
| `wasm_memory:new/1` | a shared memory for threads | [Features and conformance](features.md) |
| `wasi_fs:backend/0` | which file backend you got | [WASI](wasi.md) |
| `wasm_snapshot_store:purge/0` | emptying the snapshot directory | [Snapshots](snapshots.md) |
| `wasm_code_cache:purge/0` | emptying the compiled code directory | [The compiled tier](compiled-tier.md) |

Everything else is **internal**. The site lists those modules under groups
whose names start with "Internals". They may change in any release, without
a note.

## Settings you may want in production

```erlang
%% sys.config
[{wasm, [{scratch_roots, #{scratch => "/var/lib/myapp/wasm-scratch"}},
         {code_cache_dir, "/var/lib/myapp/wasm-code"}]}].
```

`scratch_roots` is where request files live. When a node restarts after a
crash, it cleans up there what the crashed node left behind. `code_cache_dir`
keeps compiled code across restarts. [Worker configuration](worker-reference.md)
lists every other setting.

## Read this next

[Concepts](concepts.md), then [Getting started](getting-started.md).
