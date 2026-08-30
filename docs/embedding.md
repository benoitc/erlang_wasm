# Embedding the runtime

This page tells you how to hold a module and an instance correctly: what each
one costs you, how long it lives, and which process owns it. Read it when you
are past your first `wasm:call/3` and are deciding where instances live in your
supervision tree.

Have the application running before any of this. It owns the page budget and the
module cache:

```erlang
{ok, _} = application:ensure_all_started(wasm).
```

## Where the runtime sits

`erlang_wasm` is the engine. There is no second one, and the only thing you
choose is what goes in the innermost box:

```
┌─────────────────────────────────────────────────────┐
│ your BEAM application                               │
│                                                     │
│   ┌───────────────────────────────────────────┐     │
│   │ a worker process, with limits             │     │
│   │                                           │     │
│   │   ┌─────────────────────────────────┐     │     │
│   │   │ erlang_wasm                     │     │     │
│   │   │ decode -> validate -> interpret │     │     │
│   │   │ fuel, depth, pages, WASI        │     │     │
│   │   │                                 │     │     │
│   │   │   ┌───────────────────────┐     │     │     │
│   │   │   │  a .wasm module       │     │     │     │
│   │   │   │  the guest workload   │     │     │     │
│   │   │   └───────────────────────┘     │     │     │
│   │   └─────────────────────────────────┘     │     │
│   └───────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────┘
```

Your guest can be a plugin you compiled, or a whole language runtime such as
QuickJS that interprets scripts of its own. The engine treats both as ordinary
modules. [guests.md](guests.md) covers producing either.

## Load once, instantiate many

```erlang
{ok, Mod} = wasm:load_file("plugin.wasm"),      % once, at startup
{ok, A}   = wasm:instantiate(Mod, Imports),     % per request, per tenant
{ok, B}   = wasm:instantiate(Mod, Imports).     % A and B share nothing
```

A module and an instance are different things, and the difference decides where
you put each one:

| | module | instance |
| --- | --- | --- |
| what | decoded, validated code | running state: memory, globals, tables |
| mutable | no | yes |
| shared | yes, node-wide, cached by content hash | no, owned by one process |
| cost | ~45 ms to compile, ~16 us to load again | ~15 us, plus its declared memory |

Use `wasm:compile/1` only for one-shot work; it skips the cache. If you
instantiate more than once, use `load/1`.

`compile/1` also takes the text format, which is the one-shot case by
construction:

```erlang
{ok, Mod} = wasm:compile({wat, ~"(module (func (export \"f\") (result i32) i32.const 7))"}).
```

`load/1` takes bytes only. The cache is keyed on a content hash and a module
built from text takes a fresh identity every time it is validated, so there
would be nothing stable to key on.

## Know who owns the instance

An instance belongs to the process that created it, like a port or an ETS table:

| event | effect |
| --- | --- |
| owner alive | handle valid; you may pass it to other processes |
| **two processes calling at once** | **unsound**: both read-modify-write the same state, last writer wins |
| trap | invocation aborts, instance stays valid and usable |
| fuel or depth exhaustion | same: invocation aborts, instance still usable |
| `destroy/1` | releases pages and state; idempotent |
| owner exits | pages released automatically |

The concurrency row is the one that bites you. If more than one process needs to
call an instance, put the instance inside a process and let its mailbox
serialise the calls. That is what [worker.md](worker.md) describes.

Forgetting `destroy/1` is untidy but not a leak. `wasm_keeper` monitors the
owning process and reclaims its pages when it exits, however it exits, kill
included.

## Set limits

Per instance:

```erlang
{ok, Inst} = wasm:instantiate(Mod, Imports, #{fuel => 10_000_000,
                                              max_depth => 256}).
```

Or per call, which is usually what you want for a request:

```erlang
{ok, R} = wasm:call(Inst, ~"handle", [Req], #{fuel => 1_000_000}).
```

Start from `wasm_limits:untrusted/0` or `wasm_limits:trusted/0` and raise what
you need.

`fuel` bounds work, not time. It is charged at calls and loop back-edges, which
every unbounded execution has to pass through, so it reliably stops a runaway
loop. It does not stop a host function that blocks. For wall-clock bounding you
need a timeout, and a timeout needs a process.

## Move bytes in and out

```erlang
{ok, Bin} = wasm:read_memory(Inst, Ptr, Len),
ok        = wasm:write_memory(Inst, Ptr, <<"data">>),
{ok, Pages} = wasm:memory_size(Inst).
```

Budget roughly the declared memory per instance: a module declaring one 64 KiB
page costs about 64 KB, plus about 11 KB if you put it in a process. Bulk
transfers run at roughly 0.5 GB/s, because bytes are assembled from 64-bit
words.

Cap total linear memory for the node:

```erlang
wasm_engine:set_page_limit(16384),          % 1 GiB
#{pages_in_use := N} = wasm_engine:stats().
```

Set this. Linear memory is off-heap and invisible to `max_heap_size`, so nothing
else bounds it.

## Link modules together

Make one instance's export another's import:

```erlang
{ok, LogFn} = wasm:extern(Lib, ~"log"),
{ok, App}   = wasm:instantiate(AppMod, #{{~"lib", ~"log"} => LogFn}).
```

Imported memories and tables are shared by reference, so both instances see the
same bytes and the same table entries. A `funcref` carries the instance that
defined it, so a reference one module writes into a shared table calls that
module's function, against that module's memory and globals.
