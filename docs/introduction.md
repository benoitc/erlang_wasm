# What erlang_wasm is for

erlang_wasm runs WebAssembly inside your Erlang application. It is written in
Erlang itself, so you have no native engine to build or ship. Read this page
to decide whether it fits what you want to do, and where to start if it does.

## What you can do with it

| use | what it looks like |
| --- | --- |
| portable plugins | add behaviour to a running system without loading native code into the VM |
| language runtimes | run JavaScript, Python or Lua code that arrives with a request, each request in its own sandbox |
| rule evaluation | give rules explicit inputs, explicit permissions and a deadline |
| shared validators | run the same checks in several services and languages |
| small domain languages | compile a small business-specific language to WebAssembly and run it here |
| runtime research | study the whole machine, written in a high-level functional language |

## Is this the right runtime for you

Choose erlang_wasm when these points matter to your application:

- how long a request lives and what it may access are part of your product;
- you want to inspect or change how the runtime behaves;
- a release that is mostly Erlang is easier for you to operate;
- the measured speed is already enough for you.

If you need the fastest possible guest execution above all, a native engine
such as Wasmtime, embedded through a NIF (native code loaded into the Erlang
VM), is a better fit.

## Read this next

[Concepts](concepts.md) defines the words every other page uses. Then
[Getting started](getting-started.md) takes an empty project to a running
module. The index, [docs/README.md](README.md), lists every page by task.
