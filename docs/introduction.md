# What erlang_wasm is for

erlang_wasm runs WebAssembly inside your Erlang application, written in Erlang
itself: no native engine to build or ship. Read this page to decide whether it
fits what you want to do, and where to start if it does.

## What you can do with it

| use | what it looks like |
| --- | --- |
| portable plugins | add behaviour to a running system without loading native code into the VM |
| language runtimes | run JavaScript, Python or Lua that arrives at request time, one request per sandbox |
| rule evaluation | give rules explicit inputs, explicit permissions and a deadline |
| shared validators | run the same checks in several services and languages |
| small domain languages | compile a focused business language to WebAssembly and run it here |
| runtime research | inspect the whole machine in a high-level functional language |

## Is this the right runtime for you

Choose erlang_wasm when what must be true is about your application: request
lifetime and permissions are part of your product, you want to inspect or
change how the runtime behaves, a release that stays mostly Erlang makes
operations easier, and measured speed already meets your needs.

If the fastest possible guest execution is your main need, a native engine
such as Wasmtime, embedded through a NIF, fits better.

## Read this next

[Concepts](concepts.md) defines the words every other page uses, then
[Getting started](getting-started.md) takes an empty project to a running
module. The index, [docs/README.md](README.md), lists every page by task.
