# Getting started

This page gets you from an empty project to a WebAssembly module running in your
shell, then to calling Erlang from inside it. Start here if you have never used
the runtime; everything else in the docs assumes you have done this once. You
need Erlang/OTP 29 or later and `rebar3`. A C compiler is optional.

## Add the dependency

```erlang
%% rebar.config
%% The OTP application is `wasm`; the Hex package is `erlang_wasm`.
{deps, [{wasm, {pkg, erlang_wasm}}]}.
```

Start it from your application's `applications` list, or by hand in the shell:

```erlang
{ok, _} = application:ensure_all_started(wasm).
```

Start it before you do anything else. The application owns the module cache and
the node's page budget.

## Run your first module

You do not need a `.wasm` file or any toolchain to start. The runtime reads the
WebAssembly text format itself:

```erlang
Src = ~"""
(module
  (func (export "add") (param i32 i32) (result i32)
    local.get 0 local.get 1 i32.add))
""",
{ok, Mod}  = wasm:compile({wat, Src}),
{ok, Inst} = wasm:instantiate(Mod, #{}),
{ok, [7]}  = wasm:call(Inst, ~"add", [3, 4]),
ok         = wasm:destroy(Inst).
```

`compile/1` turns the text into a module, `instantiate/2` gives you a running
instance of it, and `call/3` calls one of its exported functions. Paste it into
`rebar3 shell` as it is.

## Load a module from a file

A module built by a real toolchain arrives as a `.wasm` file. The bytes below
are the same `add` module as `wat2wasm` writes it, so you can try this without
a toolchain; with your own module, skip the first line:

<!-- check: fresh -->
```erlang
ok = file:write_file("add.wasm", <<0,97,115,109,1,0,0,0,1,7,1,96,2,127,127,1,127,3,2,1,0,7,7,1,3,97,100,100,0,0,10,9,1,7,0,32,0,32,1,106,11>>),
{ok, Mod}  = wasm:load_file("add.wasm"),
{ok, Inst} = wasm:instantiate(Mod, #{}),
{ok, [7]}  = wasm:call(Inst, ~"add", [3, 4]),
ok         = wasm:destroy(Inst),
ok         = file:delete("add.wasm").
```

You load once and instantiate as often as you like. `load_file/1` decodes and
validates the bytes and caches the result by content hash, so loading the same
file again costs microseconds instead of milliseconds. Each `instantiate/2`
gives you a fresh instance that shares nothing with the others.

`compile/1`, used above, skips that cache, which is right for text: a module
built from text takes a fresh identity every time, so there is nothing stable
to cache it against. Use `load_file/1` for a module you instantiate
repeatedly.

Each section of this page starts from a clean shell. If you paste them all
into one, run `f().` between sections so names like `Mod` and `Inst` can be
bound again.

## Give it something to call

Imports are plain Erlang functions. Key them by the module and field name the
WebAssembly module asks for. This module imports `env.log` and calls it with a
pointer and a length into its memory:

<!-- check: fresh -->
```erlang
Src = ~"""
(module
  (import "env" "log" (func $log (param i32 i32)))
  (memory 1)
  (data (i32.const 0) "hello from wasm")
  (func (export "run") (call $log (i32.const 0) (i32.const 15))))
""",
{ok, Mod} = wasm:compile({wat, Src}),
Imports = #{{~"env", ~"log"} =>
                fun(Ctx, [Ptr, Len]) ->
                    {ok, Bin} = wasm:read_memory(Ctx, Ptr, Len),
                    logger:notice("wasm says: ~ts", [Bin]),
                    {ok, []}                    % no results
                end},
{ok, Inst} = wasm:instantiate(Mod, Imports),
{ok, []}   = wasm:call(Inst, ~"run", []).
```

Return `{ok, Results}` to continue or `{trap, Reason}` to stop the invocation.
If your function raises, the runtime turns that into a trap instead of letting
it escape into your process. See [host-functions.md](host-functions.md).

## Run a WASI program

If the module was built with `rustc --target wasm32-wasip1`, TinyGo, or a
WASI-enabled clang, hand it to `wasi:run/2`. The repository has one, built from
Rust, in `test/fixtures/rust/`:

<!-- check: fresh -->
```erlang
{ok, Mod} = wasm:load_file("test/fixtures/rust/wasi_demo.wasm"),
{ok, Exit, Stdout, Stderr} =
    wasi:run(Mod, #{args => [~"hello", ~"--verbose"],
                    env  => #{~"MODE" => ~"production"},
                    dirs => [{~"/data", "/srv/app/data", read}]}),
io:format("~ts", [Stdout]).
```

`Exit` is the program's exit status. This one prints what it was given, then
tries to read a file under `/data`; `/srv/app/data` does not exist here, so it
reports that and exits with 7.

Grant a network the same way you grant a directory, by naming what may be
reached:

```erlang
wasi:run(Mod, #{net => #{connect => [{tcp, ~"10.0.0.0/8", 443}]}}).
```

Capabilities are explicit and nothing is implied. Leave out `dirs` and the
module has no filesystem at all, not one rooted at your working directory. Leave
out `net` and it has no network. See [wasi.md](wasi.md).

## Handle failure

Nothing raises. Match on the error. This module's `run` always traps:

<!-- check: fresh -->
```erlang
{ok, Mod}  = wasm:compile({wat, ~"(module (func (export \"run\") (param i32) unreachable))"}),
{ok, Inst} = wasm:instantiate(Mod, #{}),
Arg = 1,
case wasm:call(Inst, ~"run", [Arg]) of
    {ok, Results} ->
        Results;
    {error, #{class := trap, kind := unreachable}} ->
        module_hit_unreachable;
    {error, #{class := exhaustion, kind := out_of_fuel}} ->
        module_ran_too_long;
    {error, E} ->
        logger:warning("~s", [wasm:format_error(E)]),
        failed
end.
%% => module_hit_unreachable
```

You get one of five classes: `malformed` for a bad binary, `invalid` for a
module that fails validation, `link` when instantiation fails, `trap` when
execution traps, and `exhaustion` when a limit is hit.

## Run untrusted code

Set limits, and put the instance in a process so you can kill a runaway module
on a timeout. Copy `examples/wasm_worker.erl` into your own application first.
It is a worked example rather than a library module, precisely so you can change
its timeout, restart and isolation policies:

```sh
cp deps/wasm/examples/wasm_worker.erl src/my_wasm_worker.erl
perl -pi -e 's/^-module\(wasm_worker\)\./-module(my_wasm_worker)./' src/my_wasm_worker.erl
```

The second line renames the module inside the file to match its new name;
without it the copy still calls itself `wasm_worker` and `my_wasm_worker:...`
is undefined.

<!-- check: parse "runs once the worker is copied into your project" -->
<!-- check: modules my_wasm_worker -->
```erlang
{ok, W} = my_wasm_worker:start_link(Mod, #{limits => wasm_limits:untrusted(),
                                           isolation => fresh}),
{ok, R} = my_wasm_worker:call(W, ~"handle", [Request], 500).
```

`isolation => fresh` destroys and rebuilds the instance after every request, so
no state survives one. Read [worker.md](worker.md) for why the process boundary
is what makes the timeout real, and [security.md](security.md) for what limits
do not cover.

## Next

- [embedding.md](embedding.md): instance lifetime, ownership, and limits
- [host-functions.md](host-functions.md): calling Erlang from WebAssembly
- [guests.md](guests.md): producing a module, and which shape you want
- [wasi.md](wasi.md): capabilities, preopened directories, sockets
- [worker.md](worker.md): request isolation, timeouts, pools
- [security.md](security.md): the threat model, stated plainly
- [features.md](features.md): what is implemented, and what is not
