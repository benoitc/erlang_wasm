# erlang_wasm

A WebAssembly runtime written in Erlang/OTP.

This project implements every part itself: decoding, validation,
instantiation, execution, linear memory and WASI. It is not a binding to
Wasmtime, Wasmer, WAMR or wasm3. The only native code is an optional file NIF
of 900 lines. It closes one specific security gap, and the runtime works
without it.

```erlang
{ok, Mod}  = wasm:load_file("plugin.wasm"),
{ok, Inst} = wasm:instantiate(Mod, #{
    {~"env", ~"log"} =>
        fun(Ctx, [Ptr, Len]) ->
            {ok, Bin} = wasm:read_memory(Ctx, Ptr, Len),
            logger:info("~ts", [Bin]),
            {ok, []}
        end}),
{ok, [Result]} = wasm:call(Inst, ~"run", [42]).
```

Nothing raises an exception. A malformed binary, a module with type errors, a
trap and a resource limit all return `{error, Error}`. The error carries a
class, a kind your code can match on, the message text from the
specification, and context.

## Where to start

| You want to | start with |
| --- | --- |
| run WebAssembly from Erlang | [Getting started](docs/getting-started.md), then the guide for your case |
| understand how it works | [Architecture](docs/architecture.md) |
| change it | [CONTRIBUTING.md](CONTRIBUTING.md) |

[docs/README.md](docs/README.md) gives the reading order for each case, and
lists every page by task.

## Status

The runtime runs real compiler output without changes: a Rust
`wasm32-wasip1` binary that uses `std`, started through `_start`, and
freestanding modules built with `clang -O2`.

**All 65,481 assertions of the core specification tests pass**, across 256
suites, with no known failures. A feature that is not implemented is refused
with an error. It is never approximated.

Implemented: WebAssembly 1.0 core, bulk memory, reference types, multi-value,
multiple memories, memory64, SIMD, tail calls, typed function references,
exception handling, garbage collection, relaxed SIMD, threads and shared
memories, sign extension, saturating float-to-int, and 45 WASI preview 1
system calls. File and network access are capability-based: the guest can
reach only what you grant.

The Component Model works too: components with resources, composition and the
async Canonical ABI, on a WASI 0.2 host with filesystem, sockets and
`wasi:http`. See [docs/components.md](docs/components.md).

The runtime reads both formats: the binary format, and the text format
(`.wat` modules and `.wast` scripts).

You grant sockets the same way as directories: you name what the guest may
reach. By default it can reach nothing. See [docs/wasi.md](docs/wasi.md) and
[docs/security.md](docs/security.md).

## A plugin or a script

```erlang
%% a prebuilt plugin: logic compiled to .wasm ahead of time
{ok, W} = plugin_worker:start_link("plugin.wasm"),
{ok, ~"user@example.com"} = plugin_worker:normalise(W, ~"  User@Example.COM  ").

%% a script: logic arrives as text, run by an interpreter inside the guest
{ok, S} = qjs_worker:start_link("qjs.wasm"),
{ok, ~"3\n"} = qjs_worker:eval(S, ~"print(1 + 2);").
```

Both examples are in `examples/`. Both run untrusted code under a timeout, and
no state is kept from one request to the next.
[docs/guests.md](docs/guests.md) has the commands to build the guests and to
run both from `rebar3 shell`. It also helps you choose between the two.

## Sandboxing

You grant each WASI capability explicitly. A capability you do not grant is
refused:

```erlang
{ok, Exit, Stdout, _} =
    wasi:run(Mod, #{args => [~"prog"],
                    dirs => [{~"/data", "/srv/data", read}]}).
```

Without `dirs`, the guest has no filesystem at all. It does not get one rooted
at the working directory. Each known way to escape the filesystem sandbox has
its own test case, checked against the behaviour of Rust's `std::fs`.
[docs/security.md](docs/security.md) lists what the sandbox does *not*
protect against. That list is the more useful part.

For untrusted code, run the instance in its own process, so you can kill a
module that runs too long. `wasm_instance_worker` is that process: one
instance, a deadline, and a kill when the deadline passes.
[docs/worker.md](docs/worker.md) says when you need it, and how to put a pool
of them in your own supervision tree.

## Documentation

[docs/README.md](docs/README.md) is the index: where to start for each kind
of reader, then every page by task. [docs/concepts.md](docs/concepts.md)
defines the words the other pages use.

## Building

```sh
rebar3 compile
rebar3 ct         # tests, including the specification suite
rebar3 dialyzer
rebar3 bench      # benchmarks
```

A C compiler is optional. Without one, the WASI path resolver uses pure
Erlang. A small race condition then remains, and the documentation describes
it.

The conformance tests are read directly from the upstream sources. Clone them
next to the project and `rebar3 ct` finds them:

```sh
git clone --depth 1 https://github.com/WebAssembly/testsuite.git
```

Nothing is generated and you need no other tool. Without the clone, the
conformance suite is skipped with a message, and every other test still runs.

## Why it is built this way

The design comes from measurements on the BEAM (the Erlang virtual machine),
not from the way C runtimes are built. Six results shaped it.

**Walking a nested list is faster than a flat instruction array.** We ran the
same program of 2.4 million instructions both ways. Walking a nested tree of
lists took 3.7 ns per instruction. A flat array of bytecode with a program
counter, the design every C interpreter uses, took 5.6 ns. In Erlang,
`element/2` with an index known only at run time checks its bounds each time.
Matching the head of a list is a pointer read, and the compiler turns it into
a jump table. WebAssembly control flow is structured: blocks nest, so the
interpreter needs no program counter at all.

**An Erlang float cannot be NaN or Infinity.** `0.0/0.0` raises `badarith`,
and `<<F:64/float>>` does not match those bit patterns. So the runtime stores
floats in a mixed form: an Erlang float when possible, a tuple or atom
otherwise. We measured a C NIF as an alternative, and it was *slower*. A NIF
that handles NaN must return the raw bit pattern, and each one is a big
integer allocated on the heap.

**A `v128` is a binary, not a 128-bit integer.** Binary syntax cuts each field
to its declared width, so the overflow of each lane is handled with no extra
work, and the vector is built in one allocation. `i32x4.add` took 11.8 ns, and
126 ns as an integer. `i8x16.add` took 14.6 ns, and 610 ns as an integer.

**Garbage-collected objects cannot use the BEAM garbage collector.** These
objects can change and can point to each other in cycles. The only mutable
container the BEAM collector traces holds integers. So the objects live in a
store that this runtime owns and collects itself. This is affordable only
because the interpreter keeps all execution state in plain data. Between two
calls, the operand stack is empty, so the runtime can list every root without
stack maps or safe points.

**The collector is generational, and the generations cost nothing to track.**
Object ids come from a counter and are never reused. So the objects created
since the last collection are exactly a range of ids, and the young
generation needs no bookkeeping. After a thousand allocations, a minor
collection takes 0.083 ms, whether a thousand or a hundred thousand objects
are alive. Tracing a hundred thousand objects takes 14.9 ms.

**`atomics` arrays make linear memory possible without native code.** A store
takes 6 ns. Rebuilding an immutable binary takes 1201 ns. Memory is a set of
`atomics` arrays sized to the memory, so growing it adds arrays and copies
nothing. A memory restored from a snapshot reads the image's pages where they
are, and copies a 4 KiB page only the first time the guest writes to it. So a
CPython restore takes 0.8 ms instead of 12.

The full reasoning, with the options we rejected and the benchmark that gave
a wrong result, is in the module documentation and in
[docs/features.md](docs/features.md).

## AI-assisted development

This software is developed with **strong assistance from GPT 5.6, Claude Opus
5, and Fable**. Humans lead the architecture, semantics, testing, benchmarking
and debugging.

We say this openly because it shaped how the project was built. If you are
not comfortable using code developed with AI, this software may not be for
you.

We do not simply accept what an agent writes. Humans define the design, the
architecture, the expected behaviour and the rules for correctness. AI agents
are used a lot for implementation, refactoring, writing tests, analysing code
and trying other approaches.

Generated code is a proposal. It is not proof that the code is correct. We
check changes with the WebAssembly specification test suite, with real
compiler output, by comparing results against established runtimes where we
can, and with benchmarks we can repeat. When a result is unexpected, we
investigate it. We do not accept it because an agent produced code that looks
right.

## Licence

Apache-2.0.
