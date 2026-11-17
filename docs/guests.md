# Producing a guest module

This page shows you how to build a module that this runtime can run, and how
to choose between the two forms a guest can take. Read it before you write a
plugin, an extension point, or anything else where somebody else writes the
logic.

## Choose a form

WebAssembly cannot run JavaScript or Python source by itself: an interpreter
must read it. So you have two options. You compile the logic to WebAssembly
ahead of time. Or you put an interpreter inside the module and give it the
source code at run time.

```text
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

The cost of each option, measured on our test machine with a small Rust
plugin and with QuickJS:

| | compiled (the Rust plugin) | interpreted (a script on QuickJS) |
| --- | ---: | ---: |
| module | 46 KB | 1.8 MB |
| compile, once | 1.6 ms | 310 ms |
| instantiate, per request | 540 us | 3.2 ms |
| a trivial request | under 1 ms | 238 ms |

Most of the plugin's 540 us is spent filling with zeros the linear memory
that Rust's `std` declares. A module that declares one page instantiates in
about 2.6 us. QuickJS instantiates in only 3.2 ms because the runtime prepares
each function body for the interpreter (it "lowers" it) only when the function
is first called. Bodies that are never called are never lowered.

Choose A when the logic changes only when you deploy. Choose B when it must
change between deploys, or when the people who write it will not compile
anything. Both get the same capabilities and the same limits. They differ in
cost, and in who writes the code.

## Build with Rust, which needs nothing else

`rustup` installs the sysroot (the standard library built for the target),
so this is the shortest way to get a module:

```sh
rustup target add wasm32-wasip1
```

Build a **command** when the program has a `main` and runs once. The runtime
starts it through its `_start` export:

```sh
rustc --target wasm32-wasip1 -O -o hello.wasm hello.rs
```

Build a **reactor** when you want a plugin: it has no `main`, it exports
functions, and it keeps its state between calls.

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

Strip the module, and check which library code your functions bring in.
`scripts/build-plugin-fixture.sh` builds the plugin measured above. Using
`str::to_lowercase` instead of `to_ascii_lowercase` made it grow from 46 KB to
2 MB, because the Unicode case tables were included.

## Build with C or C++, which needs a sysroot

Apple clang, and the clang of most Linux distributions, cannot build for
`wasm32-wasi`, because they have no sysroot for it. Install
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

`scripts/build-native-fixture.sh` does this. It is enough for code that only
computes over linear memory.

## Build with threads

To *run* a module that uses shared memories, you need **no external
library**. The runtime implements the threads proposal itself. Each thread
(an "agent" in the specification) is an Erlang process, and all of them use
one shared memory. See the threads section of [features.md](features.md).

To *compile* such a module, you need something more. The guest needs atomic
instructions and a shared memory, so you need a sysroot that supports
threads:

```sh
rustup target add wasm32-wasip1-threads     # needs wasi-sdk for the sysroot
# or, for C:
$WASI_SDK/bin/clang --target=wasm32-wasi-threads -matomics -mbulk-memory ...
```

People often confuse the two. To be clear: *running* a threaded module needs
nothing outside this application.

## What the runtime will accept

The runtime accepts every proposal listed as complete in
[features.md](features.md). That is the whole core specification, plus SIMD,
relaxed SIMD, threads, garbage collection, tail calls, typed function
references, exception handling and memory64. If a module uses anything else,
validation refuses it and names the proposal.

A module with more than 256 functions is prepared in steps: each function body
is lowered the first time it is called, not at instantiation. So you pay only
for the part of the module that runs. You build the module the same way.

## Run what you built

Both forms run on workers that are installed with the application, so you
copy no code.

A compiled module (the first form) runs on `wasm_instance_worker`: one
instance in its own process, with limits and a deadline that kills it.

```erlang
{ok, Mod} = wasm:load_file("plugin.wasm"),
Opts = #{imports => Imports, limits => wasm_limits:untrusted()},
{ok, W} = wasm_instance_worker:start_link(Mod, Opts),
{ok, Results} = wasm_instance_worker:call(W, ~"handle", Args, 500),
ok = wasm_instance_worker:stop(W).
```

[Using workers](worker.md) explains each option. Grant only the imports the
module needs: a Rust plugin built for `wasm32-wasip1` needs four WASI
functions from its standard library.

An interpreter (the second form) runs on `wasm_script_worker`, with an
adapter for its language: `wasm_javascript`, `wasm_python` or `wasm_lua`.
Each request sends source code and gets its own fresh instance.
[Hosting scripting languages](scripting.md) shows how to start one.

## Read this next

- [Using workers](worker.md): running a compiled module under limits, and
  the path of a request
- [Hosting scripting languages](scripting.md): running scripts with
  `wasm_script_worker`
- [WASI preview 1](wasi.md): the capabilities you can grant a module
- [Security](security.md): what those limits do and do not cover
