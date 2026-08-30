# Changelog

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
