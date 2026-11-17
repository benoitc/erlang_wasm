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

The upstream conformance suites are not vendored. Fetch them once beside the
project, at the commits `scripts/fetch-suites.sh` names; to move to newer
ones, change the commits there. A suite that needs one skips when it is
absent, so a run without them proves nothing about conformance:

```sh
make suites
```

## Find the suites for an area

[Where things are](../map.md) has a row for each area of the runtime, with
the suites that test it. Suites are named after what they cover, and each
opens by saying what that is; the map's last section shows how to search
`test/` for the suites that call a module.

## The suites behind the feature page

These are the suites behind the claims in
[Features and conformance](../features.md), and the properties they hold:

| Suite | What it covers |
| --- | --- |
| `wasm_spec_SUITE` | the official suite, gated per suite against a baseline |
| `wasm_prop_SUITE` | totality, atom safety, memory model equivalence, LEB128 round trip |
| `wasm_bench_SUITE` | the benchmark tables in `test/audit/PERF.md`, plus the responsiveness assertion |
| `wasm_worker_SUITE` | limits actually bound, tested through `wasm_instance_worker` |
| `wasi_SUITE` | WASI syscalls, and one case per filesystem escape technique |
| `wasi_nif_SUITE` | the native backend, including the symlink-swap race |
| `wasi_net_SUITE` | the network grant on its own, with no sockets in it |
| `wasi_sock_SUITE` | the four standard socket calls, and readiness |
| `wasi_sock_ext_SUITE` | the client extension, layouts built byte by byte |
| `wasi_net_escape_SUITE` | one case per network escape route |
| `wasm_num_SUITE` | numeric edge cases, each naming the rule it enforces |
| `wasm_native_SUITE` | a `clang -O2` module: recursion, memory, indirect calls |
| `wasm_rust_SUITE` | a real Rust `std` binary through `_start`, sandbox included |
| `wasm_lang_SUITE` | a real 1.8 MB QuickJS build, evaluating JavaScript |
| `wasm_scale_SUITE` | what only breaks at size: big tables, deferred lowering |
| `wasm_examples_SUITE` | both worked examples, run as their documentation says |

The main properties:

- **Totality.** No binary, however hostile, produces anything but `{ok, _}` or a
  structured `{error, _}`. Verified over random binaries and over valid modules
  mutated at the byte level.
- **No atom creation.** Decoding arbitrary input never moves the atom count. The
  atom table is node-wide and never reclaimed, so one
  `binary_to_atom` on module data would let a remote module crash the node.
- **Memory equivalence.** Random sequences of store, fill, copy and grow against
  the `atomics` backend agree byte for byte with a plain binary model. The same
  property will validate the optional native backend when it arrives.

## Get the fixtures

Most suites build what they run from WAT at test time. The rest read a
fixture: a committed file, or one you fetch or build. [Fixtures](fixtures.md)
lists every family with its script, the suites that read it and how it is
checked. `scripts/verify-fixtures.sh` checks the language runtimes you have
against their recorded hashes.

## Know what skips

A suite that cannot find what it needs skips, and a skip is green. Before you
read a green run as proof, check the log for skips. These are the suites that
need something a fresh clone does not have:

| suite | needs | without it |
| --- | --- | --- |
| `wasm_spec_SUITE` | `testsuite/` | skips |
| `wasm_wast_SUITE`, `wasm_wat_SUITE` | `testsuite/` for one case each; two `wasm_wat_SUITE` cases also need `wasm-tools` | those cases skip |
| `wasi_conformance_SUITE` | `wasi-testsuite/` | skips |
| `wasm_wasi2_testsuite_SUITE` | `wasi-testsuite/` and `wasm-tools` | skips |
| `wasm_wasi2_adapter_SUITE` | `wasi-testsuite/` and `wasm-tools`; one case also needs `wasmtime` | skips |
| `wasm_lang_SUITE` | `test/fixtures/lang/qjs.wasm` | skips |
| `wasm_core_SUITE`, `wasm_annotate_SUITE`, `wasm_examples_SUITE` | `qjs.wasm` for some cases | those cases skip |
| `wasm_module_cache_SUITE` | `qjs.wasm` for one case | that case **fails** |
| `wasm_worker_lang_SUITE` | `qjs.wasm`, then `qjs_reactor.wasm` and `lua_reactor.wasm` for their groups | skips, or the group skips |
| `wasm_worker_lang_SUITE`, the `python_*` groups | `python.wasm` or `py_reactor.wasm`; not in `all/0`, so run them with `--group` | not run |
| `wasm_wasi2_p2_SUITE`, `wasm_wasi2_serve_SUITE`, `wasm_wasi2_http_limits_SUITE`, `wasm_wasi3_p3_SUITE` | wasmtime's programs | skips; fails with `WASM_REQUIRE_WASMTIME_FIXTURES` set |
| `wasm_wasi2_async_SUITE` | wasmtime's `p2_cli_invoke_async` program | skips, whatever the variables say |
| `wasm_wasi3_p3_SUITE`, `slow_programs` | `WASM_RUN_SLOW_PROGRAMS=1` | that case skips |
| `wasm_wasi2_conformance_SUITE`, `wasm_wasi2_real_SUITE`, `wasm_component_worker_SUITE` | `wasmtime` on the path, for the cases that compare with it | those cases skip |
| `wasm_recipe_SUITE` | `cargo` and `wasm-tools`, for one case | that case skips |
| `wasm_scripts_SUITE` | `make` | skips |
| `wasi_nif_SUITE` | the file NIF built | the cases about the native backend skip |
| `wasm_docs_SUITE` | each block's checker tool and fixture | that block skips; fails under `WASM_DOCS_STRICT=1` |

## Set the test environment

These variables change what a suite runs or where it looks. None is needed
for a plain `rebar3 ct`.

| variable | what it does | default |
| --- | --- | --- |
| `WASM_TESTSUITE` | where the specification suite checkout is | `testsuite/`, found by walking up from the working directory |
| `WASI_TESTSUITE` | where the WASI suite checkout is | `wasi-testsuite/`, found the same way |
| `WASM_SPEC_MAX_FAILURES` | how many failures `wasm_spec_SUITE` keeps for each suite; set it to 1000 to see them all | 25 |
| `WASM_REQUIRE_WASMTIME_FIXTURES` | makes a missing wasmtime program fail `wasm_wasi2_p2_SUITE`, `wasm_wasi2_serve_SUITE`, `wasm_wasi2_http_limits_SUITE` and `wasm_wasi3_p3_SUITE` instead of skipping; any value but empty or `0` | unset: they skip |
| `WASM_RUN_SLOW_PROGRAMS` | `1` runs `wasm_wasi3_p3_SUITE`'s `slow_programs` case, about seven minutes | unset: skipped |
| `WASM_DOCS_STRICT` | `1` makes `wasm_docs_SUITE` fail on a missing checker tool, and run every block whose fixture is declared | unset: those blocks skip |
| `WASM_DOCS_FIXTURES` | the fixtures you declare present, by id, comma separated: `qjs`, `python`, `qjs_reactor`, `lua_reactor`, `python_reactor` | none |
| `WASM_BENCH_FULL` | adds the one-million sizes to `wasm_gc_bench_SUITE`'s `bench` group | unset |
| `TMPDIR` | where the WASI 0.2 and 0.3 runners and the test HTTP server put their scratch files | `/tmp` |

The build reads a few more. `rebar3 ct` recompiles, so set them for the test
run too:

| variable | what it does | default |
| --- | --- | --- |
| `WASM_NIF_SANITIZE` | builds the NIF under a sanitizer: `address` or `thread` | unset |
| `WASM_NIF_CFLAGS` | extra C flags for the NIF, as in CI's check build | none |

The fixture scripts read their own: `WASI_SDK`, `QUICKJS_NG_TAG`,
`LUA_VERSION`, `CPYTHON_TAG`, `CPYTHON_XY` and `WASMTIME_P2_SRC`. Each
script's header says what it does with them.

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

`wasm_architecture_SUITE` checks the maps: the module levels and cycles in
[Architecture](../architecture.md), that every module is named in
[Where things are](../map.md), that every function a module doc names
exists, and that every module and page is in the `ex_doc` config.

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
