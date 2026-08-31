# Changelog

## Unreleased

### Changed

The supervision tree is one supervisor per subsystem. Five servers under one
`intensity => 5, period => 10` shared a budget, so losing the module cache
repeatedly could take the engine, the keeper and the code slots with it, and
the tables went too. Each subsystem now has its own supervisor and its own
`10 in 60`, and `wasm_store` owns the long-lived tables.

A wrong-typed call argument answers `{link, argument_type}` where it used to
answer `{malformed, internal}`. `malformed` is the decode class and an argument
is not a decode concern; the kind is new, the class has changed, and anything
matching on the old pair needs updating.

- **`max_memory_pages` now covers garbage-collected objects as well as linear
  memory.** A workload under a tight ceiling that allocates structs or arrays
  can be refused where it was not. The node page budget widens the same way, so
  `memory.grow` can return -1 because a guest filled the object store. Both were
  unbounded before: a guest filling a twenty-million element array took 1.8 GB
  with `max_heap_words` set, `process_flag(max_heap_size, ...)` set on the
  process running it, and `pages_in_use` reading zero throughout, because a
  struct or an array is a row in ETS and ETS is not process heap.

  `max_heap_words` is documented as what it always was: a ceiling on terms on
  the *caller's own heap*, applied by the caller. It never covered guest memory
  of either kind, and no longer reads as though it might.

### Fixed

- **`atomic.fence` was rejected as invalid.** The decoder and the interpreter
  both knew it and the validator had no clause, so every module carrying a
  fence failed to load. The specification suite does not exercise it.
- **A tree death leaked the node page budget permanently.** The counter lives
  in `persistent_term` and outlives the supervision tree; the registry that
  says who holds those pages does not. Pages charged when the tree died could
  never be released, and it accumulated across application restarts.
  `wasm_keeper` now reconciles the two when it starts.
- **A limits map that could not mean what it said was ignored.**
  `#{max_depth => lots}` failed open, because every integer sorts before every
  atom, so a guest could recurse a million frames under a ceiling the embedder
  believed it had set. `wasm_limits:validate/1` existed and nothing called it.
- **The compiled tier computed on ill-typed arguments.** `wasm_exec` checks
  arity and the tier never reaches it, so the same call answered differently
  depending on whether the function was hot; and a float passed for an `i32`
  was rejected by the interpreter and had `i32.add` run on it by the tier.
  Both are checked once now, before either engine is chosen.

## 0.1.1

`wasm:compile/1` takes the text format:

```erlang
{ok, M} = wasm:compile({wat, ~"(module (func (export \"f\") (result i32) i32.const 7))"}).
```

`load/1` still takes the binary format only: the cache is keyed on a content
hash, and a module built from text takes a fresh identity every time.

### Fixed

Seven lifecycle defects found by an audit of the previous release.

- A reader killed inside `wasm_heap:lease/1` or `unlease/2` stranded a count
  nothing could give back, and the object store never collected again.
- A keeper restart dropped every per-instance memory ceiling, so an instance
  created with `max_memory_pages` grew past it.
- A process calling instances it does not destroy kept one table array and one
  compiled entry per instance, without bound.
- `sock_send_to` leaked a socket when the send failed, and another when the
  guest's output pointer was out of bounds.
- `atomic.wait` reported a wakeup that never happened when the notifier died
  between claiming a waiter and sending to it.
- `wasm_engine`'s per-instance limits table had no callers and is gone.

## 0.1.0

First public release. The versions before it were developed in a private
repository and are not published; this is the whole runtime as one release.

The Hex package is `erlang_wasm`; the OTP application inside it is `wasm`.

```erlang
{deps, [{wasm, {pkg, erlang_wasm}}]}.
```

### What it does

A WebAssembly runtime written in Erlang/OTP. Decoding, validation,
instantiation, execution, linear memory and WASI preview 1 are implemented in
Erlang. The only native code is an optional file NIF that closes a
time-of-check-to-time-of-use window in WASI path resolution, and the runtime
falls back to a pure Erlang resolver when it is absent.

### Proposals

WebAssembly 1.0 core, bulk memory, reference types, multi-value, multiple
memories, memory64, SIMD, relaxed SIMD, tail calls, typed function references,
exception handling, garbage collection, threads and shared memories, sign
extension, and saturating float-to-int conversion.

Both formats are read: the binary format, and the text format as `.wat` modules
and `.wast` scripts.

### WASI

Forty-four preview 1 syscalls. Directories and sockets are granted by naming
what may be reached, with nothing reachable by default. See `docs/wasi.md` and
`docs/security.md`.

### The compiled tier

Hot functions are lowered to Core Erlang, compiled and loaded into a fixed pool
of sixteen pre-interned module names, so no atom is ever derived from a guest's
bytes. Off by default; see `docs/compiled-tier.md` for when it pays and when it
does not.

### Errors and limits

Nothing raises. A malformed binary, an ill-typed module, a trap and a resource
limit all come back as `{error, Error}` carrying a class, a machine-readable
kind, the specification's message text and context. Memory pages, tables and
globals are held by holder tokens whose owning process's death releases them,
so a killed worker cannot leak a page.

### Conformance

64,774 core specification assertions across 215 suites, with an empty skip
baseline, and 65,481 of them replayed through generated code. Seventy-two of
the 72 wasi-testsuite cases pass with the NIF, 68 without it. Neither suite is
vendored; `docs/features.md` says how to clone them.
