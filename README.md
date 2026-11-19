# erlang_wasm

A WebAssembly runtime written in Erlang/OTP.

It decodes, validates and runs WebAssembly itself, with linear memory, the
Component Model, WASI 0.1 (preview 1), 0.2 and 0.3, and `wasi:nn` for a
backend you supply. It is not a binding
to Wasmtime, Wasmer, WAMR or wasm3. Workers run untrusted guests one request
at a time, each in its own processes with a deadline. The only native code is
an optional file NIF, and the runtime works without it.

**New here? Read [Start here](docs/start-here.md).** It tells you which
module and which page fit what you have.

## A first example

This runs a JavaScript function sent with a request, in a sandbox, through
the installed worker and its QuickJS adapter. `scripts/fetch-qjs-fixture.sh`
downloads `qjs.wasm`:

<!-- check: needs qjs -->
```erlang
{ok, W} = wasm_script_worker:start_link(
            wasm_javascript_command, #{path => "test/fixtures/lang/qjs.wasm"}),
{ok, #{result := #{~"answer" := 42}}} =
    wasm_script_worker:run(W, ~"export function main(c) { return {answer: c.value + 1}; }",
                           #{~"value" => 41}).
```

To load and call a module you compiled yourself, follow
[Getting started](docs/getting-started.md). It needs no file and no
toolchain.

## Status

All 65,481 assertions of the core specification tests pass, across 256
suites, with no known failures. A feature that is not implemented is refused
with an error, never approximated. The runtime runs real compiler output
unchanged, such as a Rust `wasm32-wasip1` binary that uses `std`.
[Features and conformance](docs/features.md) lists what is implemented.

## Build and test

```sh
rebar3 compile
rebar3 ct                  # every suite under test/
scripts/fetch-suites.sh    # the upstream conformance suites, else they skip
make check                 # the checks a change must pass
```

A C compiler is optional. Without one, the WASI path resolver uses pure
Erlang, and [Security](docs/security.md) describes the small race that
remains. [CONTRIBUTING.md](CONTRIBUTING.md) has the rest.

## Why it is built this way

The design comes from measurements on the BEAM (the Erlang virtual machine),
not from how C runtimes are built. In short: the interpreter walks nested
lists instead of a flat bytecode array, linear memory is `atomics` arrays,
floats that Erlang cannot hold (NaN, Infinity) get their own form, garbage
collected objects live in a store the runtime collects itself, and each
untrusted instance runs in its own process. Errors from a guest come back as
values, and guest data never becomes an atom.
[Design principles](docs/design-principles.md) states these rules and where
they show in the API; [Design notes](docs/design-notes.md) gives the reasons
behind the internals. The measurements are in `test/audit/PERF.md`, under
"The six results behind the design".

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
