# erlang_wasm

A WebAssembly runtime implemented in Erlang/OTP.

Decoding, validation, instantiation, execution, linear memory and WASI are all
implemented here. This is not a binding to Wasmtime, Wasmer, WAMR or wasm3. The
only native code is an optional 200-line file NIF that closes one specific
security window, and the runtime works without it.

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

Nothing raises. A malformed binary, an ill-typed module, a trap and a resource
limit all come back as `{error, Error}` carrying a class, a machine-readable
kind, the specification's message text, and context.

## Status

Runs unmodified real-toolchain output: a Rust `wasm32-wasip1` `std` binary
through `_start`, and `clang -O2` freestanding modules.

**All 64,774 core specification assertions pass**, across 215 suites, with an
empty baseline. Not implemented is refused explicitly rather than approximated.

Implemented: WebAssembly 1.0 core, bulk memory, reference types, multi-value,
multiple memories, memory64, SIMD, tail calls, typed function references,
exception handling, garbage collection, relaxed SIMD, threads and shared
memories, sign extension, saturating
float-to-int, and 44 WASI preview 1 syscalls with capability-based filesystem
and network access.

It reads both formats: the binary one and the text format, `.wat` modules and
`.wast` scripts alike.

Sockets are granted the way directories are: by naming what may be reached, with
nothing reachable by default. See [docs/wasi.md](docs/wasi.md) and
[docs/security.md](docs/security.md).

## Two ways to use it

```erlang
%% compiled: logic fixed at build time, one level of interpretation
{ok, W} = plugin_worker:start_link("plugin.wasm"),
{ok, ~"user@example.com"} = plugin_worker:normalise(W, ~"  User@Example.COM  ").

%% interpreted: logic arrives as text, two levels
{ok, S} = script_worker:start_link("qjs.wasm"),
{ok, ~"3\n"} = script_worker:eval(S, ~"print(1 + 2);").
```

Both are in `examples/`, both run untrusted code under a timeout with nothing
surviving a request. [docs/guests.md](docs/guests.md) has the commands to build
the guests, run both from `rebar3 shell`, and decide which shape you want.

## Why it is built this way

The design follows from measurements on the BEAM rather than from how C
runtimes are built. Five results shaped it:

**A cons-list walk beats a flattened instruction stream.** Same program, 2.4M
instructions: walking a nested AST measured 3.7 ns per instruction, while the
bytecode-plus-program-counter shape every C interpreter uses measured 5.6 ns.
`element/2` with a runtime index is bounds-checked; matching a list head is a
dereference the compiler turns into a jump table. WebAssembly control flow is
structured, so blocks nest and there is no program counter at all.

**Erlang cannot represent NaN or Infinity as a float.** `0.0/0.0` raises
`badarith`, and `<<F:64/float>>` does not even match those bit patterns. Floats
use a hybrid representation. A C NIF was measured as an alternative and was
*slower*: a NaN-capable NIF must return raw bit patterns, and every such pattern
is a heap bignum.

**A `v128` is a binary, not a 128-bit integer.** Bit syntax truncates each
field to its declared width, so lane wrapping is free, and the vector is built
in one allocation. `i32x4.add` measured 11.8 ns against 126 ns for the integer
form; `i8x16.add` 14.6 ns against 610 ns.

**Garbage-collected objects cannot ride on BEAM garbage collection.** They are
mutable and cyclic, and the BEAM's only traced mutable container holds
integers. So they live in a store this runtime owns and this runtime collects,
which is affordable only because the interpreter owns all execution state
explicitly: between calls the operand stack is empty, so the roots are
enumerable without stack maps or safe points.

**The collector is generational, and the generation is free.** Object ids come
from a counter and are never reused, so the objects allocated since the last
collection are exactly an id range: the nursery needs no bookkeeping. A minor
collection after a thousand allocations costs 0.083 ms whether the live set is a
thousand objects or a hundred thousand, where tracing all of the latter costs
14.9 ms.

**`atomics` makes linear memory viable without native code.** A store costs
6 ns against 1201 ns for rebuilding an immutable binary. Memory is chunked
`atomics` arrays sized to the memory, so growth appends instead of copying.

The full reasoning, including the trade-offs rejected and the benchmark that
lied, is in the module documentation and [docs/features.md](docs/features.md).

## Sandboxing

WASI capabilities are explicit, and an absent capability is refused rather than
silently granted:

```erlang
{ok, Exit, Stdout, _} =
    wasi:run(Mod, #{args => [~"prog"],
                    dirs => [{~"/data", "/srv/data", read}]}).
```

No `dirs` means no filesystem at all, not one rooted at the working directory.
Every filesystem escape technique has its own test case, verified against
Rust's own `std::fs`. [docs/security.md](docs/security.md) states what the
sandbox does *not* cover, which is the more useful half.

For untrusted code, put the instance in a process so a runaway module can be
killed on a timeout. The runtime ships no process wrapper: process architecture
belongs to your application, and [docs/worker.md](docs/worker.md) documents the
pattern with a tested example in `examples/wasm_worker.erl`.

## Documentation

- [Getting started](docs/getting-started.md)
- [Producing a module](docs/guests.md): which shape to build, and how
- [Embedding](docs/embedding.md): lifetime, ownership, limits
- [Host functions](docs/host-functions.md)
- [WASI](docs/wasi.md): capabilities and preopens
- [Workers](docs/worker.md): request isolation, timeouts, pools
- [Streams](docs/streams.md): talk to a guest while it runs
- [The compiled tier](docs/compiled-tier.md): what `compile => true` buys, and when
- [Security](docs/security.md): the threat model
- [Features and conformance](docs/features.md)

For changing the runtime rather than using it:

- [Architecture](docs/architecture.md): the layers, the cycles, where to start reading
- [Adding an instruction](docs/adding-an-instruction.md): the files, per opcode space
- [Design notes](docs/design-notes.md): why it is built this way

## Building

```sh
rebar3 compile
rebar3 ct         # tests, including the specification suite
rebar3 dialyzer
rebar3 bench      # benchmarks
```

A C compiler is optional. Without one, the WASI path resolver falls back to
pure Erlang and the residual race is documented.

The conformance suite runs from the upstream sources, read directly. Clone it
beside the project and `rebar3 ct` picks it up:

```sh
git clone --depth 1 https://github.com/WebAssembly/testsuite.git
```

Nothing is generated and no other tool is needed. Without the checkout the
conformance suite skips with that message and everything else still runs.

## Licence

Apache-2.0.
