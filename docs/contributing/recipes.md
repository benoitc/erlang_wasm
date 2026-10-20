# Recipes

One section per kind of change: the files to open, the test that proves it,
and the page to update. Use it after [CONTRIBUTING.md](../../CONTRIBUTING.md),
when you know what you want to change and need to know where. Every recipe
ends with the required checks, which are not repeated here.

```text
pick the recipe -> read what it names -> test that fails -> change
      -> checks -> measure, if you claim speed -> record, document -> PR
```

## Add a WASI preview 1 syscall

1. Add its name to the `Fns` list in `wasi_preview1:imports/2`; that list is
   the import map.
2. Add a `handle/5` clause in `wasi_preview1`. It returns `{errno, E}`, or
   `{errno, E, State}` when it changed the per-instance state; an exception
   becomes `EIO`, never a crash.
3. Put filesystem work in `wasi_fs` and path resolution in `wasi_path`, so the
   sandbox checks stay in one place. Sockets go through `wasi_sock`, and every
   address decision through `wasi_net`.
4. Add a case to the `wasi_*` suite for that area, and one for the refusal: a
   missing capability must answer an errno, not succeed.
5. Add it to "Which syscalls are implemented" in [WASI](../wasi.md).

## Add a WASI 0.2 function or interface

1. Find the interface's builder in `wasi_preview2` (its module doc has a
   table), or add one returning a map keyed by `{Interface, Field}`.
2. Build each function with `wasm_component:import_fun/2`, giving its
   Canonical ABI signature; `wasm_canon` lifts and lowers the values.
3. Reuse the preview 1 internals (`wasi_fs`, `wasi_net`) rather than writing a
   second sandbox.
4. Merge it into `command/1` if a command component needs it.
5. Test it in the matching `wasm_wasi2_*` suite, and update
   [Components](../components.md) or [WASI](../wasi.md).

## Add an instruction or a proposal

[Adding an instruction](adding-an-instruction.md) has the four stages and
the files for each opcode space.

## Add a language adapter

1. Implement the `wasm_worker_adapter` behaviour: `artifact/1`,
   `requirements/2`, `prepare/3`, `decode/2`, `cleanup/1`, `capabilities/1`,
   `conformance_fixtures/1`, `classify/2`, and optionally
   `snapshot_capability/1` and `defaults/1`.
2. If the guest speaks the shared request protocol, build on `wasm_script_v1`
   as the shipped adapters do.
3. Write a suite that delegates to `wasm_adapter_conformance` and passes
   without changing the kernel. A kernel change needs its own generic case,
   exercised by the WAT adapters first.
4. Write the language's page next to [JavaScript](../javascript.md), and put
   any heap floor in [Tuning](../tuning.md).

[Writing an adapter](../worker-contract.md) is the contract in full.

## Add an option

1. Check it against the rule first: an option says what the embedder knows
   (a limit, a timeout, isolation, whether to compile), never how the runtime
   does it. A tactic that wins only sometimes is chosen from what the runtime
   can observe, or recorded in `test/audit/ATTEMPTS.md` with one default
   shipped.
2. A limit goes in `wasm_limits` and is checked in `wasm`; a worker option in
   `wasm_script_worker`, where a bad value is refused as `{bad_option, Key,
   Why}`.
3. Document it in [Worker configuration](../worker-reference.md) or
   [Embedding](../embedding.md), with its default.

## Change how memory or the page budget works

1. Read the module docs of `wasm_memory`, `wasm_keeper` and `wasm_engine`
   first: the keeper is the lifetime authority for anything two instances
   share, and every page is reserved before it is allocated.
2. Run the `wasm_resource_*`, `wasm_budget_SUITE`, `wasm_shared_pages_SUITE`
   and `wasm_paged_memory_SUITE` suites, and `wasm_snapshot_SUITE` if restored
   memories are involved.
3. Memory access is on the hot path: measure it with the
   [protocol](measuring.md), including `realbench` on QuickJS.

## Change the compiled tier

1. Policy (what compiles, and when) is in `wasm_jit`; the code generator is
   `wasm_core`; resident code is `wasm_code_slots`; the disk cache is
   `wasm_code_cache`. The `plugin` and `script` profiles are `defaults/1` in
   `wasm`.
2. If generated code changes shape (what it reads, what a continuation
   carries, which helper it calls), bump `ABI` in `wasm_jit` in the same
   commit and say what an older artifact would do wrong. Design notes,
   "Bump the ABI when generated code changes shape", has the history.
3. Gate cold compile time and generated code size as well as speed. A change
   that sped up calls once quadrupled compile time because no gate looked.
4. Run `realbench` on QuickJS, five interleaved pairs, both orderings.

## Change the interpreter's dispatch path

Anything in `run/3`, `branch/3` or `do_call/4` in `wasm_exec`. Three changes
there cost about 70% on QuickJS while the synthetic loop measured nothing. Run
`realbench` on QuickJS before you believe any other number; see
[Measuring](measuring.md).

## Add an HTTP transport

Implement the `wasi_http_transport` behaviour, one `request/2` callback, as
`wasi_http_h1` and `wasi_http_h2` do. A component gets it through the
`http_transport` option of `wasi_preview2:command/1`. Test it beside
`wasm_wasi2_http_SUITE`.

## Debug a trap

1. Read the error value: `class` says which stage failed, `kind` is
   machine-readable, `ctx` says where.
2. If the compiled tier is on, ask it: `wasm_jit:diagnostics/0` for what is
   resident and why, `wasm_jit:dump/1` for an instance's generated code.
3. Rerun with a `fuel` limit. Compiled code never runs under fuel, so the
   call is interpreted end to end: a trap that goes away is a generator bug.
4. Pin it with a case, in `wasm_trap_effects_SUITE` if the trap leaves state
   behind.

## Debug a worker request

1. Follow the request through its processes in
   [Worker internals](../worker-internals.md): worker, guardian, runner.
2. `wasm_script_worker:cleanup_requests/0` lists the requests whose cleanup
   is still owned, with the guardian holding each.
3. `bench/paths/phasing_adapter.erl` wraps a real adapter and times a request
   at each of its adapter boundaries.

## Add a module

1. Decide its level in [Architecture](../architecture.md) and add it to the
   level listing; a call upward means a new cycle, which
   `wasm_architecture_SUITE` refuses.
2. Open it with a `-moduledoc` saying what it is.
3. Add it to a group in the `ex_doc` section of `rebar.config`.

## Add a page

1. Write it task-oriented: what it is and when you need it, then steps.
2. Label every code block with its language; Erlang blocks are parsed and the
   modules they name must exist.
3. Add it to the `ex_doc` extras and groups in `rebar.config`, and to
   [the index](../README.md).

## Claim a speed-up

[Measuring](measuring.md): fix the gates first, measure, and add the result
to `test/audit/PERF.md` in the same commit. A dropped idea goes in
`test/audit/ATTEMPTS.md`.

## Cut a release

1. On a `release-X.Y.Z` branch, rename `## Unreleased` in `CHANGELOG.md`, add
   a short intro, bump `vsn` in `src/wasm.app.src`, and add upgrade notes to
   [Upgrading](../upgrading.md) if anything breaks.
2. Open a pull request; merge when CI is green.
3. Tag `main` with an annotated `X.Y.Z` tag, and create the GitHub release
   with the changelog section as its notes.
4. The maintainer publishes to hex with `make publish`.

## Read this next

[Testing](testing.md), then [Measuring](measuring.md) if your change claims
speed or memory.
