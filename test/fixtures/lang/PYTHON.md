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
