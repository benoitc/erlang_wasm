# Getting started

This page takes you from an empty project to a WebAssembly module running in
your shell, and then to a module that calls Erlang. Start here if you have
never used the runtime. The other pages assume you have done this once. You
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

Start it before you do anything else. The application owns the module cache
(compiled modules, kept for reuse) and the node's page budget (the limit on
guest memory for the whole node).

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

`compile/1` turns the text into a module. `instantiate/2` gives you an
instance: a running copy of the module. `call/3` calls one of its exported
functions. You can paste this into `rebar3 shell` as it is.

## Load a module from a file

A module built by a real compiler comes as a `.wasm` file. The bytes below
are the same `add` module, as `wat2wasm` writes it, so you can try this
without a compiler. With your own module, skip the first line:

<!-- check: fresh -->
```erlang
ok = file:write_file("add.wasm", <<0,97,115,109,1,0,0,0,1,7,1,96,2,127,127,1,127,3,2,1,0,7,7,1,3,97,100,100,0,0,10,9,1,7,0,32,0,32,1,106,11>>),
{ok, Mod}  = wasm:load_file("add.wasm"),
{ok, Inst} = wasm:instantiate(Mod, #{}),
{ok, [7]}  = wasm:call(Inst, ~"add", [3, 4]),
ok         = wasm:destroy(Inst),
ok         = file:delete("add.wasm").
```

You load a module once and instantiate it as often as you like.
`load_file/1` decodes and validates the bytes, and keeps the result in a cache
under its content hash (a checksum of the bytes). So loading the same file
again takes microseconds instead of milliseconds. Each `instantiate/2` gives
you a new instance that shares nothing with the others.

`compile/1`, used above, does not use that cache. This is correct for text: a
module built from text gets a new identity every time, so the cache has no
stable key for it. Use `load_file/1` for a module you instantiate many times.

Each section of this page starts from a clean shell. If you paste them all
into one shell, run `f().` between sections, so that you can bind names like
`Mod` and `Inst` again.

## Give it something to call

Imports are plain Erlang functions. You give them in a map, with the module
name and field name that the WebAssembly module asks for as the key. This
module imports `env.log`. It calls it with the address and the length of a
string in its memory:

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

Return `{ok, Results}` to continue, or `{trap, Reason}` to stop the call. If
your function raises an exception, the runtime turns it into a trap. The
exception does not reach your process. See
[host-functions.md](host-functions.md).

## Run a WASI program

If the module was built with `rustc --target wasm32-wasip1`, TinyGo, or a
clang with WASI support, give it to `wasi:run/2`. The repository has one,
built from Rust, in `test/fixtures/rust/`:

<!-- check: fresh -->
```erlang
{ok, Mod} = wasm:load_file("test/fixtures/rust/wasi_demo.wasm"),
{ok, Exit, Stdout, Stderr} =
    wasi:run(Mod, #{args => [~"hello", ~"--verbose"],
                    env  => #{~"MODE" => ~"production"},
                    dirs => [{~"/data", "/srv/app/data", read}]}),
io:format("~ts", [Stdout]).
```

`Exit` is the program's exit status. This program prints its arguments, then
tries to read a file under `/data`. Here `/srv/app/data` does not exist, so it
reports that and exits with 7.

You grant network access the same way as a directory: you name what the
program may reach:

```erlang
wasi:run(Mod, #{net => #{connect => [{tcp, ~"10.0.0.0/8", 443}]}}).
```

You grant each capability (each permission) explicitly, and nothing is
granted by default. Without `dirs`, the module has no filesystem at all. It
does not get your working directory. Without `net`, it has no network. See
[wasi.md](wasi.md).

## Handle failure

Nothing raises an exception: errors come back as values, so you match on
them. A trap is the guest stopping on an error, such as the `unreachable`
instruction. This module's `run` always traps:

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

Every error has one of five classes:

- `malformed`: the binary is broken;
- `invalid`: the module fails validation;
- `link`: instantiation fails;
- `trap`: the guest traps while it runs;
- `exhaustion`: a limit is reached.

## Run untrusted code

Set limits, and put the instance in its own process, so that you can kill a
module that runs too long. `wasm_instance_worker` is that process. It comes
with the application:

<!-- check: fresh -->
```erlang
Src = ~"""
(module
  (func (export "handle") (param i32) (result i32)
    local.get 0 i32.const 1 i32.add))
""",
{ok, Mod} = wasm:compile({wat, Src}),
{ok, W}   = wasm_instance_worker:start_link(Mod, #{limits => wasm_limits:untrusted(),
                                                   isolation => fresh}),
{ok, [42]} = wasm_instance_worker:call(W, ~"handle", [41], 500).
```

The last argument is the timeout in milliseconds. When it passes, the worker
is killed, so the work really stops. It does not keep running with nobody
waiting for it. `isolation => fresh` destroys and rebuilds the instance after
every request, so no state is kept from one request to the next. Read
[worker.md](worker.md) to learn why only a separate process makes the timeout
work, and [security.md](security.md) for what limits do not cover.

## Next

- [embedding.md](embedding.md): instance lifetime, ownership, and limits
- [host-functions.md](host-functions.md): calling Erlang from WebAssembly
- [guests.md](guests.md): producing a module, and which form you want
- [wasi.md](wasi.md): capabilities, preopened directories, sockets
- [worker.md](worker.md): request isolation, timeouts, pools
- [security.md](security.md): the threat model, stated plainly
- [features.md](features.md): what is implemented, and what is not
