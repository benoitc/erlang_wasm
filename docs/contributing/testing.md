# Testing

How to run the tests, what the fixtures are, and how to write a test that
proves your change. Use it before your first pull request, and whenever a
suite skips or fails and you need to know why.

Every test is Common Test, under `test/`. The suites and the module docs are
the authority on behaviour: when a page and a suite disagree, the suite wins.

## Run the suites

```sh
rebar3 ct                                         # everything
rebar3 ct --suite=test/wasm_spec_SUITE            # one suite
rebar3 ct --suite=test/wasi_SUITE --case=parent_traversal_is_refused
```

The upstream conformance suites are not vendored. Clone them once beside the
project; a suite that needs one skips when it is absent, so a run without them
proves nothing about conformance:

```sh
make suites
```

## Build the fixtures you need

Most suites build what they run from WAT at test time. A few need real
toolchain output, built by the scripts in `scripts/` and skipped when absent:

| Fixture | Script |
| --- | --- |
| QuickJS command and reactor | `scripts/fetch-qjs-fixture.sh`, `scripts/build-quickjs-reactor.sh` |
| CPython command and reactor | `scripts/fetch-python-fixture.sh`, `scripts/build-python-reactor.sh` |
| Lua reactor | `scripts/build-lua-reactor.sh` |
| Rust WASI programs | `scripts/build-rust-fixture.sh` |
| WASI 0.2 components | `scripts/build-component-fixture.sh`, `make p2-fixtures` |

`scripts/verify-fixtures.sh` checks what you have against the recorded
hashes.

## Test the documentation

`wasm_docs_SUITE` reads every fenced block in `README.md`, the unreleased
part of `CHANGELOG.md`, `docs/` and the module docs:

- every fence names its language, and a block in another language than
  Erlang is parsed by its own tool when that tool is installed;
- every Erlang block parses, and every module it names exists;
- `docs/getting-started.md` and every page in `docs/examples/` run as
  pasted, in a fresh node, in order.

A block that cannot run as written carries an HTML comment on the line before
its fence; the suite's header lists them (`<!-- check: parse "reason" -->`,
`<!-- check: needs qjs -->` and others). CI runs it strictly, with the
fixtures built:

```sh
WASM_DOCS_STRICT=1 WASM_DOCS_FIXTURES=qjs,python,qjs_reactor,lua_reactor \
  rebar3 ct --suite=test/wasm_docs_SUITE
```

`wasm_architecture_SUITE` checks the rest of the map: the module levels and
cycles in [Architecture](../architecture.md), that every function a module doc
names exists, and that every module and page is in the `ex_doc` config.

## Write a test that can fail

1. Write the case before the fix.
2. Run it against the code without the fix and watch it fail, for the reason
   you expect.
3. Then make the change and watch it pass.

Four tests in this repository passed vacuously before anyone noticed; the
header of `wasm_jit_lifetime_SUITE` and `test/audit/ATTEMPTS.md` say how.
Two shapes to avoid:

- a check over an empty set: `[] -- []` is `[]`, so assert the set is not
  empty first;
- a threshold loose enough to pass on the broken build.

Ask also what the new assertion forbids: a test that pins today's defect
stops someone fixing it.

## Use the test support

`test/support/` holds what suites share:

- `fake_*_adapter` modules, small adapters with one behaviour each, for
  driving the worker kernel without a real language;
- `wasm_spec_runner` and `wasm_spec_manifest`, the conformance harness;
- `wasm_asm`, for building a module from instructions in a test;
- `wasi_p2_runner`, `wasi_http_server` and the WASI test-suite runners.

## Run the benchmarks

The measurement suites keep their numbers in a `bench` group, so a plain
`rebar3 ct` runs only what can fail:

```sh
rebar3 bench
```

[Measuring](measuring.md) says how to turn a number into a claim.

## Read this next

[Measuring](measuring.md), if your change claims speed or memory.
