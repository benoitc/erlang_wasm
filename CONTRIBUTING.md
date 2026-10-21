# Contributing

This page is for you if you are changing erlang_wasm rather than using it. It
says what every change must pass, the rules a reviewer will hold you to, and
where to look for the change you have in mind. Read it once before your first
pull request; after that, the [recipe](docs/contributing/recipes.md) for your
change is usually enough.

## Find your way in

1. Read [Concepts](docs/concepts.md) for the vocabulary, then
   [Architecture](docs/architecture.md): its "Where things are" table names
   the modules, configuration, tests and page for each part of the runtime.
2. Pick the [recipe](docs/contributing/recipes.md) that matches your change. It
   names the files to open, the test that proves the change and the page to
   update.
3. Read the module docs of what you are about to touch. Every module opens by
   saying what it is, and the large ones have a table of where things are.

## Run the checks

Every change passes these before it is committed or reviewed:

```sh
rebar3 compile      # warnings_as_errors is on
rebar3 lint         # elvis
rebar3 xref
rebar3 dialyzer
rebar3 ct           # every suite under test/
```

`make check` runs the last four. The conformance suites are not vendored;
clone them first or the suites that need them skip:

```sh
make suites
```

[Testing](docs/contributing/testing.md) has the rest: running one suite, the
fixtures, and how the documentation is tested.

## The rules

- **A test must fail without your change.** Run every new case against the
  commit before the fix and watch it fail. Four tests in this repository
  passed vacuously before anyone noticed.
- **Nothing raises.** Malformed input, ill-typed modules, traps and exhausted
  limits are values carrying a class, a kind, the specification's message and
  context.
- **Nothing a guest supplies becomes an atom.** The atom table is node-wide and
  never reclaimed.
- **Measure before you claim.** A performance claim cites
  `test/audit/PERF.md`, added in the same commit. Read
  `test/audit/ATTEMPTS.md` before proposing an optimisation: several obvious
  ones are there with the numbers that killed them.
  [Measuring](docs/contributing/measuring.md) has the protocol.
- **A failed gate is diagnosed, not redefined.** Gates are written down before
  the numbers arrive. When one fails, find where and why, and report it; do
  not move the gate or revert silently.
- **Options say what the embedder knows**: limits, timeouts, isolation,
  whether to compile. Never an implementation tactic such as a cache shape or
  a chunk size. Pick the tactic from what the runtime can observe, or ship one
  default.
- **Use documented OTP APIs only.**
- **No new module cycle.** `wasm_architecture_SUITE` pins the three that
  exist; a new cross-module call can add a fourth.

## Write code that reads like the code around it

- 80 columns, kept by review. There is no formatter: `erlfmt` would move the
  aligned trailing comments that explain most of this code.
- Elvis must pass. A per-module ignore goes in `rebar.config` with a one-line
  reason.
- Every module opens with a `-moduledoc` saying what it is. A new module also
  needs a level in [Architecture](docs/architecture.md) and a group in the
  `ex_doc` section of `rebar.config`; both are checked.
- Do not use the em-dash character in code, docs or messages.

## Write documentation the same way

Pages are task-oriented: second person, one paragraph saying what the page is
and when you need it, then steps with little prose between code blocks.
`wasm_docs_SUITE` checks every code block in `README.md`, `docs/` and the
module docs: each fence names its language, Erlang parses and every module it
names exists, and `docs/getting-started.md` and `docs/examples/` run as pasted.
A new page goes in the `ex_doc` extras and in [the index](docs/README.md).

## Commit and open a pull request

- Branch from `main`.
- One imperative subject line; a body only for the reason that is not obvious.
  No restating of the diff, no attribution trailers.
- A pull request says what was wrong and why it matters, the solution in a few
  lines, and any breaking change. The reviewer reads the source for the rest.
- A family of related fixes is one branch and one pull request, one commit per
  fix.

## Where the evidence lives

| File | What it holds |
| --- | --- |
| `test/audit/PERF.md` | every measured figure a claim cites |
| `test/audit/ATTEMPTS.md` | what was tried and dropped, with its numbers |
| `test/audit/README.md` | a guide to the rest of `test/audit/` |
| `bench/paths/README.md` | what each benchmark arm measures |

## Read this next

The [recipe](docs/contributing/recipes.md) for your change, then
[Testing](docs/contributing/testing.md).
