# Embedding the runtime

This page tells you how to keep a module and an instance correctly: what each
one costs, how long it lives, and which process owns it. Read it when your
first `wasm:call/3` works and you are deciding where instances go in your
supervision tree (the supervisors that start and restart your processes).

**Do you need this?** Yes, once your first call works and you are deciding
where instances live and for how long. No, for a first try: start with
[Getting started](getting-started.md).

Start the application before any of this. It owns the page budget (the limit
on guest memory for the node) and the module cache:

```erlang
{ok, _} = application:ensure_all_started(wasm).
```

## Where the runtime sits

`erlang_wasm` is the engine. There is no other engine inside it. The only
thing you choose is what goes in the innermost box:

```text
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

Your guest can be a plugin you compiled, or a whole language runtime, such as
QuickJS, that runs scripts of its own. The engine treats both as ordinary
modules. [guests.md](guests.md) explains how to build either one.

## Load once, instantiate many

```erlang
{ok, Mod} = wasm:load_file("plugin.wasm"),      % once, at startup
{ok, A}   = wasm:instantiate(Mod, Imports),     % per request, per tenant
{ok, B}   = wasm:instantiate(Mod, Imports).     % A and B share nothing
```

A module and an instance are different things, and the difference tells you
where to put each one:

| | module | instance |
| --- | --- | --- |
| what | decoded, validated code | running state: memory, globals, tables |
| can change | no | yes |
| shared | yes, by the whole node, cached by content hash (a checksum of its bytes) | no, owned by one process |
| cost | 1.6 ms to compile a 46 KB plugin and 310 ms for a 1.8 MB QuickJS build, 18 us to load either again | 540 us for that plugin and 3.2 ms for QuickJS, plus its declared memory |

Use `wasm:compile/1` only for work you do once: it does not use the cache. If
you instantiate a module more than once, use `load/1`.

`compile/1` also takes the text format, which is always a case of work you do
once:

```erlang
{ok, Mod} = wasm:compile({wat, ~"(module (func (export \"f\") (result i32) i32.const 7))"}).
```

`load/1` takes only bytes. The cache uses the content hash as its key, and a
module built from text gets a new identity each time it is validated. So the
cache would have no stable key for it.

## Know who owns the instance

An instance belongs to the process that created it, like a port or an ETS
table (an in-memory table owned by one process):

| event | effect |
| --- | --- |
| owner alive | the handle is valid; you may pass it to other processes |
| **two processes call at the same time** | **unsafe**: both read and change the same state, and the last write wins |
| trap | the call stops; the instance stays valid and you can use it |
| fuel or call depth runs out | the same: the call stops, and you can still use the instance |
| `destroy/1` | frees pages and state; calling it twice is harmless |
| owner exits | pages are freed automatically |

The row about two processes is the one that causes bugs. If more than one
process needs to call an instance, put the instance inside a process. Its
mailbox then handles the calls one at a time. [worker.md](worker.md)
describes this.

If you forget `destroy/1`, nothing leaks. `wasm_keeper` monitors the owner
process and frees its pages when it exits, however it exits, even when it is
killed.

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

Start from `wasm_limits:untrusted/0` or `wasm_limits:trusted/0`, and raise
the values you need.

`fuel` limits work, not time. The runtime takes fuel at each call and each
time a loop jumps back to its start. Code that runs forever must do one of
these again and again, so fuel always stops a loop that never ends. It does
not stop a host function that blocks. To limit real time, you need a timeout,
and a timeout needs a separate process.

## Move bytes in and out

```erlang
{ok, Bin} = wasm:read_memory(Inst, Ptr, Len),
ok        = wasm:write_memory(Inst, Ptr, <<"data">>),
{ok, Pages} = wasm:memory_size(Inst).
```

Plan for about the declared memory per instance: a module that declares one
64 KiB page uses about 64 KB, plus the process you put it in. Large copies run
at about 0.5 GB/s, because the runtime builds the bytes from 64-bit words.

Set a maximum for all linear memory on the node:

```erlang
wasm_engine:set_page_limit(16384),          % 1 GiB
#{pages_in_use := N} = wasm_engine:stats().
```

Set this. Linear memory is stored outside the process heap, and
`max_heap_size` does not see it, so nothing else limits it. The budget counts
what is allocated, not what a guest could address: a memory's chunks (the
arrays it is made of), and, for a memory restored from an image, its page
table and the pages it has written.

The budget also counts the store of garbage-collected objects. That store is
measured after the fact, not requested in advance, so `pages_in_use` can be a
little above the limit. It is the sum of what is held, and it includes pages
already used even if they went over the limit. While the node is over the
limit, every new allocation on the node is refused.

## Link modules together

Use an export of one instance as an import of another:

```erlang
{ok, LogFn} = wasm:extern(Lib, ~"log"),
{ok, App}   = wasm:instantiate(AppMod, #{{~"lib", ~"log"} => LogFn}).
```

Imported memories and tables are shared, not copied, so both instances see
the same bytes and the same table entries. A `funcref` (a reference to a
function) remembers the instance that defined it. So when one module writes a
reference into a shared table, a call through it runs that module's function,
with that module's memory and globals.

## Read this next

[Put it in an OTP application](otp.md), then [Tuning](tuning.md).
