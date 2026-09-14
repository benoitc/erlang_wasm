# The Lua reactor

What `test/fixtures/lang/lua_reactor.wasm` is. Build it with
`scripts/build-lua-reactor.sh`; like every other language artifact here it is
not committed.

| | |
| --- | --- |
| project | [Lua](https://www.lua.org) |
| version | `5.4.9`, from lua.org |
| source SHA-256 | `2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6` (the tarball, which **is** fetched and so **is** checksummed) |
| shim | `test/fixtures/lang/lua_reactor/worker_reactor.c`, in this repository |
| toolchain | wasi-sdk 34.0, clang 23.1.0, `wasm32-wasip1` |
| size | 606,445 bytes |
| shape | **reactor**: `_initialize`, `init`, `handle`, `ready` |
| transport | `script_v1.channel` |
| standard library | inside the module: **one mount**, unlike CPython |

No checksum on the output, for the reason `QUICKJS.md` records: a built
artifact's hash pins the machine that produced it. The tarball it is built from
has one.

## Why this language is here

Not because anyone asked for Lua. It is the third guest, added **after** the
kernel, the profile and the snapshot mechanism were written, to find what two
guests had hidden between them. QuickJS and CPython are both large
interpreters; Lua's image holds about **77 KB** against their 211 KB and
7.4 MB, which is the small end where a mechanism that assumed bulk would show
it.

**It needed no change to any of them.** The kit's 30 cases passed unmodified on
the first run: no kernel change, no profile change, no change to the snapshot
mechanism, no new capability. That is the acceptance rule in
`docs/worker-contract.md` met by a language the code was not designed around,
and it is the only evidence for neutrality worth anything.

## The one thing it did need: two build flags, both about `longjmp`

Lua signals errors with `setjmp`/`longjmp`, and on WebAssembly that is
exception handling.

```
-mllvm -wasm-enable-sjlj
-mllvm -wasm-use-legacy-eh=false
```

The first is the one every guide mentions. **The second is the one that
matters here**, and without it the module does not load:

```
#{class => malformed, kind => illegal_opcode, ctx => #{opcode => 6}}
```

Opcode 6 is the **legacy** `try`, from the superseded exception-handling
proposal, which LLVM still emits by default. This runtime implements the
standardised encoding -- `try_table`, `throw`, `throw_ref` -- and
`docs/features.md` lists it as complete. So the flag is not a workaround for a
gap; it asks the compiler for the version that was standardised.

Anything else that unwinds with `longjmp` will meet this, so it is written here
rather than left in a build script.

## Two functions that exist and cannot work

`loslib.c` and `liolib.c` reference `system`, `tmpfile` and `L_tmpnam`, none of
which wasi-libc provides. The shim defines them to fail rather than leaving
them absent, so `os.execute` reports that there is no shell and `io.tmpfile`
raises. A worker guest should have neither: there is nothing to execute and one
read-only directory to write into.

`lua_tmpnam` is Lua's own documented hook, so `os.tmpname` is stubbed through
that rather than by patching the source.

## What it measured

Load average 8.29 before the run and 7.95 after, five workers, ten requests
each, minimums taken:

| | |
| --- | ---: |
| worker start, capture included | 75 ms |
| a request | 25 ms |
| image retained | 77,280 bytes |

For scale, the same measurement is 91,927 ms to start and 351 ms a request for
CPython. Lua is not competing with it; it is here to be different from it.
