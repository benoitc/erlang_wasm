# Producing a module

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

The cost of each option, measured on our test machine with the two examples:

| | compiled (`plugin_worker`) | interpreted (`qjs_worker`) |
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
`scripts/build-plugin-fixture.sh` builds the example plugin. Using
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

## Run the two examples

Both are in `examples/`, and they are **not** part of the application. They
are code for you to copy and change, not library modules to depend on. To try
them in place, build the two guests and compile the examples in a shell.

Build the guests. The plugin needs the Rust wasm target. The QuickJS build is
downloaded:

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
c("examples/qjs_worker.erl").
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
{ok, S} = qjs_worker:start_link("test/fixtures/lang/qjs.wasm").
qjs_worker:eval(S, ~"print(1 + 2);").
%% {ok,<<"3\n">>}
qjs_worker:eval(S, ~"for(;;){}").
%% {error,timeout}
qjs_worker:eval(S, ~"print(typeof globalThis.marker);").
%% {ok,<<"undefined\n">>}   nothing survives a request
```

To use either one in your own application, copy it and change the policy:

```sh
cp deps/wasm/examples/plugin_worker.erl src/my_plugin_worker.erl
```

The parts you will want to change are the timeout, the fuel, and the
capabilities you grant the instance. `plugin_worker` grants only the four
imports that Rust's standard library requires. `qjs_worker` grants one
directory that holds one script, and no network.

`wasm_examples_SUITE` runs everything above, so if a command on this page
stops working, the build fails.

## Next

- [worker.md](worker.md): running a guest under limits, and the path of a
  request
- [wasi.md](wasi.md): the capabilities you can grant a module
- [security.md](security.md): what those limits do and do not cover
- `examples/plugin_worker.erl` and `examples/qjs_worker.erl`: both forms,
  working, with the tests that run them
- `wasm_instance_worker`: the general worker, installed with the application
