# The CPython artifact

What `test/fixtures/lang/python.wasm` is. Fetch it with
`scripts/fetch-python-fixture.sh`; it is not committed.

| | |
| --- | --- |
| project | [webassembly-language-runtimes](https://github.com/vmware-labs/webassembly-language-runtimes) |
| release | `python/3.12.0+20231211-040d5a6`, asset `python-3.12.0.wasm` |
| size | 26,267,204 bytes |
| SHA-256 | `e5dc5a398b07b54ea8fdb503bf68fb583d533f10ec3f930963e02b9505f7a763` |
| shape | **command**: one `_start`, no reactor exports |
| target | `wasm32-wasi`, Clang 16.0.0 |
| interpreter | `3.12.0 (tags/v3.12.0:0fb18b0, Dec 11 2023)` |

The checksum is also in `python.wasm.sha256`, which is what
`scripts/verify-fixtures.sh` reads. Nothing parses this page.

## This one proves the path and is not the dependency

The repository is heading for archival and this is its newest Python artifact,
from 2023. The real one is an upstream `wasm32-wasip1` build against the same
pinned WASI SDK as the quickjs-ng reactor. That matters beyond freshness: a
command-shaped artifact exports only `_start`, so it can never support the
initialized runtime snapshots of Phase 6, which need `init()` and `handle()`.

## What was confirmed by running it

| question | answer |
| --- | --- |
| standard library | **embedded**: `import json` works |
| `sys.path` | `/usr/local/lib/python3.12`, which is in no preopen |
| `importlib.util` | present |
| reading a staged file | works |
| `sys.stdout.write` | writes without a trailing newline |
| `sys.argv` under `-c` | `['-c']` |

The first two decided the mount count. `sys.path` names a directory that does
not exist in the sandbox and `import json` succeeds anyway, so the library is
inside the module: **one mount**, not two. An upstream build that ships
`python.wasm` beside a `Lib` directory would need that preopened read-only as a
second mount, and `requirements/2` is where that would be declared.

## What it costs

Load average 2.9 to 4.4, which is low for this box. One request through
`script_worker`, `py_adapter` and `script_v1.combined`, interpreted:

`fuel` is the fourth: the untrusted preset's 10,000,000 does not reach
CPython's first line, and 4,000,000,000 completes a request with room to spare.
1,000,000,000 was also enough.

| `max_heap_words` | one request |
| ---: | ---: |
| 16,777,216 | 48.3 s |
| 67,108,864 | 85.3 s |
| 268,435,456 | 84.5 s |

**Those are single runs, and the spread within one arm is about 40%**, so read
them as "16M is the one to use" and not as three comparable numbers. Repeated
and interleaved, a request costs **53 to 76 s**; `PERF.md` has that measurement
and the null experiment that bounds what can be claimed from it.

**A bigger ceiling is slower, not safer.** A larger `max_heap_size` lets the
heap grow before a collection, and the collection then costs more; the same
effect is recorded for QuickJS in `ATTEMPTS.md`. 16M words is what the suite
uses, and the default 8M **kills the runner**: CPython needs more than 64 MiB
of Erlang terms to start at all.

`PERF.md` records 15.7 s for a bare `wasm:call` on this artifact. The
difference is the rest of a request: staging three files, an interpreter
started with `-I -B -u`, `importlib`, `json`, and a JSON context parsed and a
result serialised.

## The kit passes, unmodified

All 30 applicable cases, the identical list the WAT adapters and QuickJS run,
in the `metered` configuration. **29 minutes**, which is why it is not in
`all/0`:

    rebar3 ct --suite=test/wasm_worker_lang_SUITE --group=python_metered

Getting there took four runs, and every failure was the *kit* assuming a fast
guest rather than the adapter being wrong. It hardcoded a 300 ms deadline
against an adapter asking for 60 s, a 10 s await against a 48 s request, ten
repetitions where three prove the same thing, and a 30 s worker timeout below
what `requirements/2` declares. Every wait is a multiple of what the adapter
says it needs now, which is what made a second language worth adding: the
first one hid all of it.

`python_compiled` is **not** run. The tier needs several hundred requests
*plus* a compile `PERF.md` measured at 567 s, which is hours rather than
minutes, and Phase 5 is where that measurement belongs.

# The CPython reactor

A second artifact, `test/fixtures/lang/py_reactor.wasm` and its standard
library beside it, because the one above exports only `_start` and can
therefore never be snapshotted. Build both with
`scripts/build-python-reactor.sh`; neither is committed.

| | |
| --- | --- |
| project | [CPython](https://github.com/python/cpython) |
| tag | `v3.14.7` |
| shim | `test/fixtures/lang/python_reactor/worker_reactor.c`, in this repository |
| toolchain | wasi-sdk 34.0, clang 23.1.0, `wasm32-wasip1` |
| size | 30,887,792 bytes |
| standard library | `test/fixtures/lang/py_reactor_lib`, 11 MB, 554 modules |
| shape | **reactor**: `_initialize`, `init`, `handle`, `ready` |
| transport | `script_v1.channel` |

## There is no checksum, and that is the honest answer

The artifact **embeds its own build directory**: one absolute path, from
CPython's path configuration, sits in its data section. A hash of it would pin
this machine rather than the recipe, so there is no `py_reactor.wasm.sha256`
and `scripts/verify-fixtures.sh` does not check it. The build script uses a
fixed directory under `_build/` rather than a temporary one, so two builds from
the same checkout do agree; two checkouts in different places do not.

For provenance rather than verification, the artifact this box built is
`b4a78ad5046df47d0c8422eca122aa660f83933b70fcf0736519dc0dd0bc5514`.

What keeps a broken build from passing quietly is not a checksum but the build
failing: `scripts/build-python-reactor.sh` stops on the first error, and the
suite group refuses to run without the artifact rather than skipping green.

## Why a shim

Upstream's `Tools/wasm/wasi` builds a command. The shim links CPython's own
`libpython3.14.a` with `-mexec-model=reactor` and exports `init()` and
`handle()` instead of `_start`.

It does **not** reconstruct the link line. `make -n python.wasm` names about
four hundred objects and five static libraries, and the script asks the
Makefile for that line, swaps `Programs/python.o` for the shim's object, and
runs it. A hand-written copy would rot at the next CPython release.

## Why `init` touches nothing a request supplies

Whatever `init()` does is in the image every request restores. So it reads no
argv, opens no file under the work directory, and evaluates no tenant source.
It does import `json`, `importlib.util` and `sys`, deliberately: that cost is
paid once into the image instead of once per request.

`ready()` exists because `init()`'s own return value never reaches the kernel,
which does not read guest values. Without it, an interpreter that failed to
start would be captured and restored into every request; the adapter's
`validate` asks `ready()` instead, and removing the standard library from the
initialisation imports is what proved the check works.

Path configuration is **stated, not computed**. Left to itself CPython walks
the filesystem looking for a prefix and a landmark, which inside a preopened
sandbox is a pile of failed `path_open` calls and a warning at the end of them.
The shim sets `module_search_paths` to `/lib/python3.14` and nothing else.

`script_v1.channel` rather than `combined`, for the same reason as the
JavaScript reactor: the combined transport learns its per-request marker from
argv, and a marker read during `init()` would be frozen into the image.

## Two mounts

`ro` is the kernel's, holding the tenant's staged `main.py` and
`context.json`. `/lib` is the adapter's own `dirs` entry, pointing at the
standard library the build produced; it is 11 MB of files the adapter ships,
not something to stage per request. The record above predicted exactly this
split, and it is the one an upstream build forces.

## The kit passes, unmodified

All 30 applicable cases, the identical list the WAT adapters and both
JavaScript adapters run:

    rebar3 ct --suite=test/wasm_worker_lang_SUITE --group=python_reactor

**About 80 minutes**, which is why it is not in `all/0` and not in CI. Every
case starts its own worker and every worker start is one interpreter start, so
the group costs roughly one capture per case rather than one per run.

`capture_timeout` has to be raised for it: the default is 60 s and a capture
here takes 83 to 90, so the group passes `180_000`. That is the same knowingly
raised ceiling as `fuel` and `max_heap_words`, and the adapter does not raise
it for you.
