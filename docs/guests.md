# Producing a module

This page shows you how to build something this runtime can run, and how to
choose between the two shapes a guest can take. Read it before you write a
plugin, an extension point, or anything else where somebody else supplies the
logic.

## Choose a shape

To run JavaScript or Python, something has to interpret JavaScript or Python,
and WebAssembly does not. So you either compile the logic ahead of time, or you
ship an interpreter inside the module and feed it source at run time.

```
OPTION A - compile to wasm                OPTION B - interpret inside wasm

  logic written in Rust, C, TinyGo          logic written in JavaScript
          │                                         │
     compiled once                          sent as text, per request
          ▼                                         ▼
  ┌───────────────────┐                   ┌───────────────────────────┐
  │ plugin.wasm 46 KB │                   │ qjs.wasm 1.8 MB           │
  └───────────────────┘                   │   interpreting the script │
          ▲                               └───────────────────────────┘
   erlang_wasm interprets                            ▲
   the plugin directly                   erlang_wasm interprets QuickJS,
                                         which interprets the script

  ONE level of interpretation            TWO levels, stacked
```

What that costs, measured on this machine with the two worked examples:

| | compiled (`plugin_worker`) | interpreted (`script_worker`) |
| --- | ---: | ---: |
| module | 46 KB | 1.8 MB |
| compile, once | 1.6 ms | 310 ms |
| instantiate, per request | 540 us | 3.2 ms |
| a trivial request | under 1 ms | 238 ms |

Most of the plugin's 540 us is zeroing the linear memory Rust's `std` declares;
a module declaring one page instantiates in about 2.6 us. The QuickJS figure is
what progressive lowering bought: it instantiates in 3.2 ms because the bodies
it never calls are never lowered.

Choose A when the logic changes at deploy time. Choose B when it has to change
without one, or when whoever writes it will not compile anything. Both get the
same capabilities and the same limits; they differ in cost and in who writes the
code.

## Build with Rust, which needs nothing else

`rustup` ships the sysroot, so this is your shortest path to a module:

```sh
rustup target add wasm32-wasip1
```

Build a **command** when the program has a `main` and runs once, entered through
`_start`:

```sh
rustc --target wasm32-wasip1 -O -o hello.wasm hello.rs
```

Build a **reactor** when you want a plugin: no `main`, exported functions, state
kept between calls.

```rust
static mut BUF: [u8; 4096] = [0; 4096];

#[no_mangle]
pub extern "C" fn buffer() -> u32 { &raw const BUF as u32 }

#[no_mangle]
pub extern "C" fn normalise(len: u32) -> i32 { /* ... */ 0 }
```

```sh
rustc --target wasm32-wasip1 -O --crate-type=cdylib -o plugin.wasm plugin.rs
wasm-tools strip plugin.wasm -o plugin.wasm
```

Strip it, and watch what you pull in. `scripts/build-plugin-fixture.sh` builds
the example plugin; using `str::to_lowercase` instead of `to_ascii_lowercase`
took it from 46 KB to 2 MB, because the Unicode case tables came with it.

## Build with C or C++, which needs a sysroot

Apple clang and most distribution clangs cannot target `wasm32-wasi`, because
they have no sysroot for it. Install
[wasi-sdk](https://github.com/WebAssembly/wasi-sdk) and use its clang:

```sh
$WASI_SDK/bin/clang --target=wasm32-wasi -O2 -o plugin.wasm plugin.c
```

Without a sysroot you can still build freestanding modules, which have no
standard library and no WASI at all:

```sh
clang --target=wasm32 -O2 -nostdlib -Wl,--no-entry -Wl,--export-dynamic \
      -o real.wasm real.c
```

That is what `scripts/build-native-fixture.sh` does, and it is enough for pure
computation over linear memory.

## Build with threads

Running a module that uses shared memories needs **no external library**. The
runtime implements the proposal natively, and agents are Erlang processes over
one shared memory; see the threads section of [features.md](features.md).

*Compiling* one is the part with a prerequisite. The guest needs atomics and a
shared memory, which means a threads-capable sysroot:

```sh
rustup target add wasm32-wasip1-threads     # needs wasi-sdk for the sysroot
# or, for C:
$WASI_SDK/bin/clang --target=wasm32-wasi-threads -matomics -mbulk-memory ...
```

The two are often confused, so to be clear: nothing about *running* a threaded
module requires anything outside this application.

## What the runtime will accept

Every proposal listed as complete in [features.md](features.md), which is all of
the core specification plus SIMD, relaxed SIMD, threads, garbage collection,
tail calls, typed function references, exception handling and memory64. Use
anything else and validation refuses the module and names the proposal.

Large modules are handled progressively: above 256 functions, bodies are lowered
the first time they are called rather than at instantiation, so a module costs
what is used of it. Nothing about producing the module changes.

## Run the two examples

Both live in `examples/` and are **not** part of the application, the same as
`examples/wasm_worker.erl`: they are worked code to copy and change, not library
modules to depend on. To try them where they are, build the two fixtures and
compile them into a shell.

Build the guests. The plugin needs the Rust wasm target; the QuickJS build is
fetched:

```sh
rustup target add wasm32-wasip1
./scripts/build-plugin-fixture.sh      # -> test/fixtures/plugin/plugin.wasm
./scripts/fetch-qjs-fixture.sh         # -> test/fixtures/lang/qjs.wasm
```

Start a shell and compile the examples into it:

```sh
rebar3 shell
```

```erlang
c("examples/plugin_worker.erl").
c("examples/script_worker.erl").
```

Try the compiled plugin:

```erlang
{ok, W} = plugin_worker:start_link("test/fixtures/plugin/plugin.wasm").
plugin_worker:normalise(W, ~"  User@Example.COM  ").
%% {ok,<<"user@example.com">>}
plugin_worker:normalise(W, ~"nonsense").
%% {error,invalid}
plugin_worker:hang(W).
%% {error,timeout}           the runaway is killed; W is still usable
```

Then the scripting sandbox:

```erlang
{ok, S} = script_worker:start_link("test/fixtures/lang/qjs.wasm").
script_worker:eval(S, ~"print(1 + 2);").
%% {ok,<<"3\n">>}
script_worker:eval(S, ~"for(;;){}").
%% {error,timeout}
script_worker:eval(S, ~"print(typeof globalThis.marker);").
%% {ok,<<"undefined\n">>}   nothing survives a request
```

To use either one in your own application, copy it and change the policy:

```sh
cp deps/wasm/examples/plugin_worker.erl src/my_plugin_worker.erl
```

The parts worth changing are the timeout, the fuel, and what capabilities you
grant the instance. `plugin_worker` grants none beyond the four imports Rust's
standard library insists on; `script_worker` grants one directory holding one
script, and no network.

`wasm_examples_SUITE` runs everything above, so if a command here stops working
the build tells you.

## Next

- [worker.md](worker.md): running one under limits, with the request path
- [wasi.md](wasi.md): the capabilities you can grant a module
- [security.md](security.md): what those limits do and do not cover
- `examples/plugin_worker.erl` and `examples/script_worker.erl`: both shapes,
  working, with the tests that run them
- `examples/wasm_worker.erl`: the general worker pattern, pool and all
