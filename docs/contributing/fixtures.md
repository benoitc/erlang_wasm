# Fixtures

A **fixture** is a file a suite loads instead of building: a WebAssembly
module, a component, a language runtime or an upstream test suite. This page
says, for each family, where it comes from, which suites read it, how you know
it is the right file, and what CI does with it. Use it when a suite skips for a
missing file, when you rebuild one, or when you move an upstream pin.

Fixtures come in three kinds:

- **committed**: small files in the repository, with their source and the
  script that rebuilds them beside them;
- **fetched**: somebody else's file, downloaded at a pinned commit or release;
- **built**: compiled on demand from a pinned source, and not committed.

A suite skips when a fetched or built fixture is missing. A skip is green, so
a run without the fixture proves nothing about what it covers.

## The families

| family | kind | how you get it | suites that read it | how it is checked | CI |
| --- | --- | --- | --- | --- | --- |
| `testsuite/`, the specification suite | fetched | `scripts/fetch-suites.sh` (`make suites`) | `wasm_spec_SUITE`, `wasm_wast_SUITE`, `wasm_wat_SUITE` | the pinned commit; `wasm_spec_SUITE` also requires every suite in `wasm_spec_manifest:core/0` and a floor of passing assertions | fetched by Tests on every run |
| `wasi-testsuite/`, the WASI suite | fetched | `scripts/fetch-suites.sh` | `wasi_conformance_SUITE`, `wasm_wasi2_testsuite_SUITE`, `wasm_wasi2_adapter_SUITE` | the pinned commit; `wasi_conformance_SUITE` and `wasm_wasi2_testsuite_SUITE` hold a failure baseline per directory | fetched by Tests on every run |
| `test/fixtures/lang/qjs.wasm` | fetched | `scripts/fetch-qjs-fixture.sh` | `wasm_lang_SUITE`, `wasm_worker_lang_SUITE`, `wasm_core_SUITE`, `wasm_annotate_SUITE`, `wasm_module_cache_SUITE`, `wasm_examples_SUITE`, `wasm_docs_SUITE` | `qjs.wasm.sha256`, by `scripts/verify-fixtures.sh`; `QUICKJS.md` records what it is | fetched by Tests and Integration |
| `test/fixtures/lang/python.wasm` | fetched | `scripts/fetch-python-fixture.sh` | `wasm_worker_lang_SUITE`, `wasm_docs_SUITE` | `python.wasm.sha256`, by `scripts/verify-fixtures.sh`; `PYTHON.md` | fetched by Integration |
| `test/fixtures/lang/qjs_reactor.wasm` | built | `scripts/build-quickjs-reactor.sh`, with WASI SDK 34 | `wasm_worker_lang_SUITE`, `wasm_docs_SUITE` | present, by `scripts/verify-fixtures.sh`; no checksum, because the bytes differ by host | built by Integration on every run |
| `test/fixtures/lang/lua_reactor.wasm` | built | `scripts/build-lua-reactor.sh`, with WASI SDK 34 | `wasm_worker_lang_SUITE`, `wasm_docs_SUITE` | present, by `scripts/verify-fixtures.sh`; the Lua source tarball by its SHA-256 in the script; `LUA.md` | built by Integration; the Lua source is cached |
| `test/fixtures/lang/py_reactor.wasm` and `py_reactor_lib/` | built | `scripts/build-python-reactor.sh`, about twenty minutes | the `python_reactor` groups of `wasm_worker_lang_SUITE` | none | not built |
| `test/fixtures/wasmtime-p2/` and `-p2-serve/` | built | `scripts/build-wasmtime-p2.sh` (`make p2-fixtures`), with Rust, `cargo` and `wasm-tools` | `wasm_wasi2_p2_SUITE`, `wasm_wasi2_async_SUITE`, `wasm_wasi2_serve_SUITE`, `wasm_wasi2_http_limits_SUITE` | the pinned wasmtime tag in the script | built by "wasmtime programs", cached |
| `test/fixtures/wasmtime-p3/` and `-p3-serve/` | built | the same script | `wasm_wasi3_p3_SUITE` | the same tag | the same job and cache |
| `test/fixtures/component/` | committed | `scripts/build-component-fixture.sh` (Rust and `wasm-tools`), `scripts/build-wat-component-fixtures.sh` (`wasm-tools`) | the `wasm_component_*` suites, most `wasm_wasi2_*` suites, `wasm_canon_prop_SUITE`, `wasm_recipe_SUITE` | committed; the preview 1 adapter is downloaded by the first script at a pinned wasmtime release | used as committed |
| `test/fixtures/snapshot/` | committed | `scripts/build-snapshot-fixtures.py` | `wasm_snapshot_SUITE`, `wasm_worker_kernel_SUITE`, `wasm_shared_pages_SUITE` | committed | used as committed |
| `test/fixtures/rust/` | committed | `scripts/build-rust-fixture.sh` | `wasm_rust_SUITE`, and `wasm_docs_SUITE` through the pages that run it | committed | used as committed |
| `test/fixtures/plugin/` | committed | `scripts/build-plugin-fixture.sh` | `wasm_examples_SUITE`, `wasm_core_SUITE`, `wasm_annotate_SUITE` | committed | used as committed |
| `test/fixtures/native/` | committed | `scripts/build-native-fixture.sh`, with a clang that targets wasm32 | `wasm_native_SUITE` | committed | used as committed |
| `test/fixtures/seeds/` | committed | no script: toolchain output kept as it is | `wasm_prop_SUITE`, `wasm_bench_SUITE`, `wasm_jit_bounds_SUITE`, `wasm_jit_lifetime_SUITE`, `wasm_module_cache_SUITE`, `wasm_annotate_SUITE` | committed | used as committed |
| `test/fixtures/wasi/` | committed | `hello.wasm` beside its source `hello.wat` | `wasi_SUITE` | committed | used as committed |

The two upstream suites live beside the project, in `testsuite/` and
`wasi-testsuite/` at its root, and git ignores both. `WASM_TESTSUITE` and
`WASI_TESTSUITE` point the runners at a checkout somewhere else.

## Get the fixtures for a run

Fetch the two upstream suites and the QuickJS command, which is what CI's
Tests job has:

```sh
scripts/fetch-suites.sh
scripts/fetch-qjs-fixture.sh
```

Add the language runtimes the Integration job has, and check them:

```sh
scripts/fetch-python-fixture.sh
WASI_SDK="$HOME/.local/opt/wasi-sdk-34.0-arm64-macos" \
  scripts/build-quickjs-reactor.sh
WASI_SDK="$HOME/.local/opt/wasi-sdk-34.0-arm64-macos" \
  scripts/build-lua-reactor.sh
scripts/verify-fixtures.sh
```

`WASI_SDK` defaults to the path above, so you can leave it out when your SDK
is there.

Build wasmtime's programs, once; it takes a Rust toolchain and the better
part of half an hour:

```sh
make p2-fixtures
```

## Rebuild a committed fixture

1. Change its source beside it, for example `test/fixtures/rust/main.rs`.
2. Run its script from the table, for example
   `scripts/build-rust-fixture.sh`.
3. Run the suites that read it, and commit the source and the built file
   together.

## Bump an upstream pin

### The specification and WASI suites

`scripts/fetch-suites.sh` names one commit for each suite. It checks a
checkout you already have against its commit, through
`scripts/checkout-pin.sh`: one at another commit is moved to the pin and the
move is printed, and the script stops, without touching anything, if you
changed tracked files in it. So you never need to delete a checkout to move a
pin:

1. Change the commit in `scripts/fetch-suites.sh`.
2. Fetch:

   ```sh
   scripts/fetch-suites.sh
   ```

3. Run `wasm_spec_SUITE`. A new upstream file is logged as unclassified by
   `core_suites_present`; classify it in `test/support/wasm_spec_manifest.erl`,
   in `core/0` or as an out-of-scope proposal. Never move a suite out of
   `core/0` to make a build pass.
4. If the failure counts moved, update the baselines in
   `test/wasm_spec_SUITE.erl`. A count that went down must be lowered too:
   the suite fails on a baseline left too high. If more assertions now pass,
   raise `EXECUTE_PASS_FLOOR`.
5. Run `wasi_conformance_SUITE` and `wasm_wasi2_testsuite_SUITE` and update
   their `baseline/0` the same way.
6. Commit the script and the baselines together. CI fetches at the new
   commit on its next run.

### wasmtime's programs

`scripts/build-wasmtime-p2.sh` clones wasmtime at the tag in its `tag=` line
into `.wasmtime-src/` (or `WASMTIME_P2_SRC`). A checkout already there is
checked against the tag the same way, so it is moved to a new tag for you.
The built programs are not: a program the old tag had and the new one dropped
would stay behind, so delete them when you change the tag:

1. Change `tag=` in `scripts/build-wasmtime-p2.sh`.
2. Delete the built programs, then build:

   ```sh
   rm -rf test/fixtures/wasmtime-p2* test/fixtures/wasmtime-p3*
   scripts/build-wasmtime-p2.sh
   ```

3. Run the suites with the fixtures required, so a missing program fails
   instead of skipping:

   ```sh
   S=test/wasm_wasi2_p2_SUITE,test/wasm_wasi2_serve_SUITE
   S=$S,test/wasm_wasi2_http_limits_SUITE,test/wasm_wasi3_p3_SUITE
   WASM_REQUIRE_WASMTIME_FIXTURES=1 rebar3 ct --suite=$S
   ```

4. Update the per-group baseline in `wasm_wasi2_p2_SUITE` if the counts moved.

CI caches the built programs under a key made from the hash of
`scripts/build-wasmtime-p2.sh`. Changing the script, the tag included, builds
them again on the next run; nothing else does.

## Notes

- `test/fixtures/lang/*.wasm` is ignored by git; the `.sha256` files and the
  `QUICKJS.md`, `PYTHON.md` and `LUA.md` records are tracked.
- The reactors have no checksum on purpose: the same SDK emits different
  bytes on macOS and on Linux, so a hash would pin a machine, not a recipe.
  Their check is the pinned tag, the pinned SDK and the build failing loudly.
- `scripts/build-wat-component-fixtures.sh` also converts wasmtime's
  component threading scripts into `test/fixtures/component/wast-threading/`,
  from the checkout `scripts/build-wasmtime-p2.sh` makes.

## Read this next

[Testing](testing.md), for which suites skip without which fixture and the
environment variables that change it.
