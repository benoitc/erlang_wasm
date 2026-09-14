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
