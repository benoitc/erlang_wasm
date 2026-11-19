# Contributing

This page is for you if you are changing erlang_wasm rather than using it. It
says where to start reading, what every change must pass, what CI runs, and
the rules a reviewer will hold you to. Read it once before your first pull
request; after that, the [recipe](docs/contributing/recipes.md) for your
change is usually enough.

## Find your way in

1. [Where things are](docs/map.md): every directory and module, and for each
   area of the runtime its entry point, configuration and suites. Find the row
   for what you are changing.
2. [Architecture](docs/architecture.md): which modules may call which, the
   supervision tree, and the path of one call.
3. The internals page for your area, if it has one:
   [Memory](docs/memory.md), [Garbage collection](docs/gc.md),
   [The compiled tier](docs/compiled-tier.md),
   [Worker internals](docs/worker-internals.md) or
   [Component internals](docs/component-internals.md).
4. The [recipe](docs/contributing/recipes.md) for your kind of change: the
   files to open, the test that proves it and the page to update.
5. The module docs of what you are about to touch. Every module opens by
   saying what it is, and the large ones have a table of where things are.

[Concepts](docs/concepts.md) defines the words these pages use.

## The shape of a change

```text
  pick the recipe for your change
        |
  read the modules and pages it names
        |
  write a test, and watch it fail on the code as it is
        |
  make the change
        |
  run the required checks
        |
  does it claim speed? --no-------------------------------+
        | yes                                             |
  write the gate down first, then measure                 |
        |                                                 |
  gate passes? --no--> stop: find where and why,          |
        | yes          report, ask before reverting       |
        |                                                 |
  record it in PERF.md, or in ATTEMPTS.md if dropped      |
        |                                                 |
  update the page the recipe names  <---------------------+
        |
  open the pull request
```

A gate is fixed before the numbers arrive and is never moved after them. A
change that measured worse and was dropped still goes in `ATTEMPTS.md`, so the
next person does not try it again.

## Run the checks

Every change passes these before it is committed or reviewed:

```sh
rebar3 compile      # warnings_as_errors is on
rebar3 lint         # elvis
rebar3 xref
rebar3 dialyzer
rebar3 ct           # every suite under test/
```

Two shortcuts run part of that list:

- `make check` runs `rebar3 lint`, `rebar3 xref`, `rebar3 dialyzer` and
  `rebar3 ct`, in that order. `rebar3 ct` compiles first.
- `rebar3 check`, an alias in `rebar.config`, runs `rebar3 xref`,
  `rebar3 dialyzer` and `rebar3 ct --cover`. It does not run the linter, so
  run `rebar3 lint` beside it.

The upstream conformance suites are not vendored, and the suites that need
them skip without them. Fetch them once, at the pinned commits:

```sh
make suites
```

The benchmarks are not among the checks. `wasm_bench_SUITE` and
`wasm_gc_bench_SUITE` keep their measurements in a `bench` group, so
`rebar3 ct` runs only what can fail and `rebar3 bench` runs the numbers.

[Testing](docs/contributing/testing.md) says which suites skip without which
fixture, and [Fixtures](docs/contributing/fixtures.md) how to get each one.

## What CI runs

CI runs the checks as separate jobs, and adds the fixtures a working copy
usually lacks. `.github/workflows/ci.yml` runs on every pull request to `main`
and every push to it; each job after Compile waits for Compile.

| job | what it runs | what it needs | what skips there |
| --- | --- | --- | --- |
| Compile | `rebar3 compile`, then checks that `priv/wasi_file_nif.so` was built | a C compiler | nothing: the NIF must build, not fall back |
| Tests | `scripts/fetch-suites.sh`, `scripts/fetch-qjs-fixture.sh`, then `rebar3 ct` | both upstream suites and `qjs.wasm` | the suites that need wasmtime's programs, the reactors, the Python groups, or `wasm-tools` and `wasmtime` on the path |
| Integration | fetches `qjs.wasm` and `python.wasm`, builds the QuickJS and Lua reactors with the pinned WASI SDK 34, runs `scripts/verify-fixtures.sh`, then `wasm_worker_lang_SUITE` and `wasm_docs_SUITE` with `WASM_DOCS_STRICT=1` and `WASM_DOCS_FIXTURES=qjs,python,qjs_reactor,lua_reactor` | the WASI SDK, `luac` (installed by the job) | the `python_*` groups, which are not in `all/0`; a missing or mismatched fixture fails the verify step |
| wasmtime programs | restores wasmtime's programs from the cache, or builds them with `scripts/build-wasmtime-p2.sh`; runs `wasm_wasi2_p2_SUITE`, `wasm_wasi2_serve_SUITE`, `wasm_wasi2_http_limits_SUITE`, `wasm_wasi3_p3_SUITE` and `wasm_wasi2_nn_wasmtime_SUITE` with `WASM_REQUIRE_WASMTIME_FIXTURES=1`; then `slow_programs` alone with `WASM_RUN_SLOW_PROGRAMS=1`, within 20 minutes | Rust 1.97.1 and `wasm-tools` 1.256.0 on a cache miss | nothing: a missing program fails |
| Lint | `rebar3 lint` | | |
| Docs | `rebar3 ex_doc`, failing on any `warning:` or doclet error in its output, and when `doc/index.html` is missing | | |
| Xref | `rebar3 xref` | | |
| Dialyzer | `rebar3 dialyzer`, with the PLT cached on `rebar.lock` | | |
| NIF checks | `wasi_nif_SUITE` and `wasi_SUITE` twice: on the check build (`WASM_NIF_CFLAGS=-DWASM_NIF_STACK_CHECK -O0 -fno-inline`) and under AddressSanitizer (`WASM_NIF_SANITIZE=address`) | gcc's `libasan` | |
| NIF under ThreadSanitizer, `tsan.yml` | builds OTP 29.1.2's emulator with ThreadSanitizer, then `wasi_nif_SUITE` and `wasi_SUITE` with `WASM_NIF_SANITIZE=thread`; fails on a report with a NIF frame | the instrumented emulator, cached | runs only for pull requests that touch `c_src/`, `scripts/build-nif.sh` or the workflow, every Monday, and by hand |
| Locked dependencies, `audit.yml` | `scripts/audit-deps.sh`: every package in `rebar.lock` against the OSV database and hex.pm's retired releases | `curl`, `jq` | runs on pull requests, every Monday, and by hand |

Facts the jobs depend on:

- **wasmtime's programs are cached on their script.** The cache key is the
  hash of `scripts/build-wasmtime-p2.sh`, which names the wasmtime tag. A
  change to the script rebuilds them; nothing else does.
- **One 0.3 program is slow.** `p3_sockets_tcp_streams` takes about seven
  minutes, past the 60 s bound for each program, so it runs in a step of its
  own. A plain `rebar3 ct` skips it. To run it, or the whole job, locally:

  ```sh
  scripts/build-wasmtime-p2.sh
  WASM_REQUIRE_WASMTIME_FIXTURES=1 rebar3 ct --suite=test/wasm_wasi3_p3_SUITE
  WASM_REQUIRE_WASMTIME_FIXTURES=1 WASM_RUN_SLOW_PROGRAMS=1 \
    rebar3 ct --suite=test/wasm_wasi3_p3_SUITE --case=slow_programs
  ```

- **`rebar.lock` is committed.** Every job keys its build cache on its hash.
- **The Docs job reads the output.** `rebar3 ex_doc` exits 0 whatever it
  warns about, so the job fails on the words in its log. Run it before you
  push a page or a module doc.
- **The upstream suites are fetched at pinned commits.**
  [Fixtures](docs/contributing/fixtures.md#bump-an-upstream-pin) says how to
  move a pin.

## The rules

- **A test must fail without your change.** Run every new case against the
  commit before the fix and watch it fail. Four tests in this repository
  passed vacuously before anyone noticed; `wasm_jit_lifetime_SUITE` and
  `test/audit/ATTEMPTS.md` record how.
- **Nothing raises.** Malformed input, ill-typed modules, traps and exhausted
  limits are values carrying a class, a kind, the specification's message and
  context.
- **Nothing a guest supplies becomes an atom.** The atom table is node-wide and
  never reclaimed, so a guest that can make one atom per call leaks for the
  life of the node. `wasm_prop_SUITE` checks both halves.
- **Measure before you claim.** A performance claim cites
  `test/audit/PERF.md`, added in the same commit. Read
  `test/audit/ATTEMPTS.md` before proposing an optimisation: several obvious
  ones are there with the numbers that killed them.
  [Measuring](docs/contributing/measuring.md) has the protocol.
- **A failed gate is diagnosed, not redefined.** Gates are written down before
  the numbers arrive. When one fails, find where and why, and report it; do
  not move the gate or revert silently.
- **Options say what the embedder knows**: limits, timeouts, isolation,
  whether to compile. Never an implementation tactic such as a cache shape, a
  page layout, a chunk size or a collection strategy. When a tactic wins only
  for some workloads, pick it from what the runtime can observe, or record the
  trade-off in `ATTEMPTS.md` and ship one default.
- **Use documented OTP APIs only.** A behaviour that holds only through an
  undocumented call can change under an upgrade without notice; remove the
  need for it instead. The measured exceptions are listed, with their
  reasons, in `wasm_architecture_SUITE`, which fails on any other call.
- **No new module cycle.** `wasm_architecture_SUITE` pins the three that
  exist; a new cross-module call can add a fourth.

## Write code that reads like the code around it

- 80 columns, kept by review. There is no formatter: `erlfmt` would rewrite
  16,252 lines across 51 files, and it moves the aligned trailing comments
  that explain most of this code above the lines they annotate. Do not run it.
- Elvis must pass. A per-module ignore goes in `rebar.config` with a one-line
  reason, the way every ignore already there is written.
- Every module opens with a `-moduledoc` saying what it is. A new module also
  needs a level in [Architecture](docs/architecture.md), a line in
  [Where things are](docs/map.md) and a group in the `ex_doc` section of
  `rebar.config`; all three are checked.
- Do not use the em-dash character in code, docs or messages.

## Write documentation the same way

Pages are task-oriented: second person, one paragraph saying what the page is
and when you need it, then steps with little prose between code blocks.
`wasm_docs_SUITE` checks every code block in `README.md`, `docs/` and the
module docs: each fence names its language, Erlang parses and every module it
names exists, and `docs/getting-started.md` and `docs/examples/` run as pasted.
A block that cannot be checked as written carries an HTML comment saying why;
the suite's header lists them. A new page goes in the `ex_doc` extras and in
a `groups_for_extras` group, and in a reading path of
[Start here](docs/start-here.md) if a reader needs it on the way.

## Commit and open a pull request

- Branch from `main`.
- One pull request per feature or defect family: one branch, one commit per
  step or per defect. Do not split a feature across several pull requests,
  even a large one; stack the steps as commits instead.
- A commit message is one imperative subject line, with a body only for the
  reason that is not obvious. No restating of the diff, no attribution
  trailers.
- A pull request description is plain English, for a reader who does not know
  the code: what was wrong and why it matters, then what changes, in everyday
  words. Explain a project term the first time you use it. Do not list the
  tests or describe the diff. End with the breaking changes, or say there are
  none.

## Where the evidence lives

| File | What it holds |
| --- | --- |
| `test/audit/PERF.md` | every measured figure a claim cites |
| `test/audit/ATTEMPTS.md` | what was tried and dropped, with its numbers |
| `test/audit/README.md` | a guide to the rest of `test/audit/` |
| `bench/paths/README.md` | what each benchmark arm measures |

## Read this next

- [Where things are](docs/map.md) and [Architecture](docs/architecture.md),
  to find the code.
- [Recipes](docs/contributing/recipes.md), for your kind of change.
- [Testing](docs/contributing/testing.md) and
  [Fixtures](docs/contributing/fixtures.md), to run what proves it.
- [Measuring](docs/contributing/measuring.md), if it claims speed or memory.
- [Changing the NIF](docs/contributing/nif.md), if it touches `c_src/`.
