# The QuickJS artifact

What `test/fixtures/lang/qjs.wasm` is, so that a reader does not have to infer
it from a URL. Fetch it with `scripts/fetch-qjs-fixture.sh`; it is not
committed.

| | |
| --- | --- |
| project | [wasmedge-quickjs](https://github.com/second-state/wasmedge-quickjs) |
| release | `v0.5.0-alpha`, asset `wasmedge_quickjs.wasm` |
| size | 1,840,749 bytes |
| SHA-256 | `b8451261a244b7bc62ae95acb43882044aed2f3d5f08355889252b418ec89231` |
| shape | **command**: one `_start`, no reactor exports |
| target | `wasm32-wasi` |

The checksum is also in `qjs.wasm.sha256`, which is what
`scripts/verify-fixtures.sh` reads. Nothing parses this page: a build that
grepped a Markdown table for a hash would break when somebody reflowed a
paragraph.

## It is an alpha from somebody else's toolchain

That is fine to measure against and is not a long-term dependency. The
replacement is quickjs-ng built against the same pinned WASI SDK as CPython,
which is also what a reactor build would come from, and a reactor is what
Phase 6 snapshots need. This artifact exports only `_start`, so it can never
support them.

## What was confirmed by running it

Not inferred from the project's documentation. These are the answers the
adapter is written against:

| question | answer |
| --- | --- |
| `export function main` parses | yes, as an ES module |
| `import('/main.js')` by absolute preopened path | **works** |
| `import {main} from '/main.js'` | also works |
| `std` module | present: `loadFile`, `open`, `out`, `err`, `printf`, ... |
| `os` module | **absent**: `could not load module filename 'os'` |
| `scriptArgs` | **not defined** |
| `args` | defined, and it is argv **without** argv[0] |
| `std.out.puts` | writes without a trailing newline |
| tenant exceptions | catchable, with `.message` |

Two of those decided the bootstrap. The marker is read from `args[1]` rather
than `scriptArgs[1]`, and output is written with `std.out.puts` rather than
`print`, which would append a newline inside the framed result.

And the first one settles a question the plan left open: because absolute
module paths resolve, `script_v1` works here exactly as documented, and the
separate non-module profile it held in reserve is not needed.

## What it bundles

The WasmEdge build carries extensions of its own. `docs/javascript.md` promises
none of them, and the conformance fixtures use none: a script that relies on
them is relying on this artifact rather than on the profile.

# The QuickJS reactor

A second artifact, `test/fixtures/lang/qjs_reactor.wasm`, because the one above
exports only `_start` and can therefore never be snapshotted. Build it with
`scripts/build-quickjs-reactor.sh`; like the other two it is not committed.

| | |
| --- | --- |
| project | [quickjs-ng](https://github.com/quickjs-ng/quickjs) |
| tag | `v0.16.2` |
| shim | `test/fixtures/lang/qjs_reactor/worker_reactor.c`, in this repository |
| toolchain | wasi-sdk 34.0, clang 23.1.0, `wasm32-wasip1` |
| flags | `-mexec-model=reactor -O2 -D_GNU_SOURCE`, plus the WASI signal and process-clock emulation quickjs-ng's own CMake sets |
| size | 1,351,069 bytes on arm64 macOS; **host-dependent**, see below |
| shape | **reactor**: `_initialize`, `init`, `handle`, `ready` |
| transport | `script_v1.channel` |

The build is byte-identical **on one host** for a given tag, SDK and flag set,
verified by building twice from a fresh clone.

**It is not identical across hosts, and there is no checksum because of that.**
The question was left open here and CI answered it on the first run:

| host | size | |
| --- | ---: | --- |
| arm64 macOS | 1,351,069 | `7813fe2025c33b9e72645e696bfc8f14ecbc4a660a5d642b90af542473dbbabb` |
| x86-64 Linux | 1,528,288 | `b77fb610d5cd51e61400474c6d7c959d889a60089360adb74bc9b0dd1b2827a2` |

Same pinned tag, same pinned wasi-sdk 34, 177 KB of different content. So a
recorded hash pins the machine that produced it rather than the recipe, which
is the same conclusion `PYTHON.md` reaches about the CPython reactor for a
different reason.

The rule that falls out: **a fetched artifact has a checksum, a built one has a
build.** Integrity here is the pinned tag, the pinned SDK and
`scripts/build-quickjs-reactor.sh` failing loudly rather than producing
something wrong. `scripts/verify-fixtures.sh` still requires the file to be
*present*, because a suite that skips is green and a green run that proved
nothing is worse than a red one.

## Why a shim rather than the published reactor

quickjs-ng ships `qjs-wasi-reactor.wasm`, and its exports were read off
`qjs-wasi-reactor.c` at the pinned tag rather than guessed:

    qjs_init  qjs_init_argv  qjs_get_context  qjs_destroy

plus the engine's C API through `-Wl,--export-dynamic`. That cannot be driven
from here. `qjs_get_context()` returns a `JSContext *` that a later `JS_Eval`
must receive as an argument, along with guest pointers something has to
allocate in linear memory between the two calls -- and the kernel's `invoke` is
`[{call, Name, Args}]` with every argument fixed before execution begins and
only the last call's values kept. Result-to-argument dataflow and an
instance-aware step between invocations are exactly what it does not have, and
adding them would be new kernel surface for one artifact's ABI.

So `worker_reactor.c` links quickjs-ng's library and keeps the context, the
guest pointers, evaluation and result framing on its own side, behind the two
calls the kernel can make.

## What the artifact exports and imports

Confirmed by decoding it, not by reading the build:

| export | |
| --- | --- |
| `memory` | the linear memory |
| `_initialize` | the reactor's own libc setup, called before `init` |
| `init` | runtime, context, `std` and `os` modules, the `__worker_result` global |
| `handle` | one request: read the staged source and context, run `main`, frame the result |
| `ready` | whether the engine came up, for the adapter's `validate` |

It imports `worker.result` and 21 `wasi_snapshot_preview1` functions. Both
modules need a `snapshot_hooks` entry or a capture is refused: `worker` holds
nothing and says `stateless`, and WASI supplies
`wasi_preview1:snapshot_hook/0`.

## Why `init` touches nothing a request supplies

Whatever `init()` does is in the image that every request restores, so it reads
no argv, opens no file and evaluates no tenant source. That is also what keeps
the instance snapshot-eligible: the WASI hook allows exactly stdio and the
preopens, and a descriptor opened during initialisation would refuse the
capture.

It is why this artifact uses `script_v1.channel` rather than `combined`. The
combined transport learns its per-request marker from `argv`, and a marker read
during `init()` would be frozen into the image and shared by every later
request.

## What it measured

One node, load average 5.07 checked before the run, the source and context
staged into a read-only mount:

| | |
| --- | --- |
| instantiate | 10.4 ms |
| `init()` | 60.6 ms |
| capture | 2.4 ms, 393,216 bytes |
| restore | 6.6 and 6.3 ms |
| `handle()` after a restore | 37.6 and 23.1 ms |
| cold: instantiate, `_initialize`, `init`, `handle` | 111.8 ms |

Single runs, so read them as an order of magnitude and not as a comparison;
`PERF.md` is where a measurement with a null experiment behind it goes. Two
requests restored from one image each saw `seen: null`, so neither observed the
global the other set.
