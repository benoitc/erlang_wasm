# Documentation and maintainability review, 2026-11-17

This review checks the documentation and the source tree of `main` at
`cc3a93f` from a human reader's point of view. It asks whether a developer
can understand the project progressively, find where to make a change, and
validate it. It changed no source code. It is the plan the next release waits
on: the maintainer decides which findings must be fixed before the release
and which can wait. The next review updates this file rather than starting
again.

**How it was done.** Every guide, contributor page, internals page, the
README, AGENTS.md, CONTRIBUTING.md and the audit index were read in full. The
13 largest or most central modules were read for their moduledoc, sections
and exports. About 60 cited function names were checked against `src/`.
Measurements come from a script over `src/` (lines, exports, top-level
functions, the longest functions), and fan-in from grepping callers.

**The numbers.** 94 modules, about 59,700 lines. 101 suites, about 34,300
lines. 36 guides, 5 contributor pages and 12 examples, about 11,000 lines.

## What it found, in short

- **The material is good; the paths through it are not.** Some pages are
  models for the rest: `architecture.md`'s "Where things are" table and "The
  path of a call", `component-internals.md`, `adding-an-instruction.md` and
  `getting-started.md`. But a newcomer meets three different starting points.
  A contributor meets three more (AGENTS.md, CONTRIBUTING.md and
  `docs/contributing/`), and they do not link to each other.
- **History is mixed into guides.** About a third of `features.md`,
  `design-notes.md`, `tuning.md` and `bench/paths/README.md` is measurement
  history or archaeology ("what the harness was not checking", "measured
  before images were shared"). It belongs in `test/audit/`.
- **Tests are hard to find from behaviour.** 35 of the 101 suites are named
  in no document, and no page maps an area to its suites.
- **Some boundaries are clear only in the code.** Which modules are supported
  API is stated nowhere: all 94 are published on hexdocs, internals included.
  The error model ("nothing raises") is stated more strongly than the code
  behaves. The cleanup subsystem is half way through a migration.
- **Three modules carry unrelated responsibilities:** `wasm_component`,
  `wasm_instance` and, to a lesser degree, `wasm_script_worker`. Two have
  unhelpful names: `wasm_core` (the code generator) and `wasm_component_link`
  (also the decoder). The biggest modules by size, `wasm_exec`, `wasm_core`
  and `wasi_preview1`, are mostly dispatch tables and are coherent.
- **Some facts are stale or misleading.** A dozen are listed under section 0,
  and two of them affect the published docs.

## 0. Stale or misleading facts (fix first, small)

| where | what is wrong |
| --- | --- |
| `README.md:36,111` | links `docs/README.md`, which is not in the ex_doc extras (`rebar.config:73-77`), so the link is probably dead on hexdocs |
| `README.md:69-84`, `docs/guests.md:195-199` | present `plugin_worker` and `qjs_worker` from `examples/` as the way to run guests; the installed API is `wasm_script_worker` and its adapters (`what-you-get.md`, `upgrading.md`) |
| `README.md:187-189` | says the reasoning is in `features.md`; it is in `design-notes.md` |
| `docs/embedding.md:147` | "nothing else limits it": there is a node default of 16384 pages, 1 GiB (`wasm_engine.erl:64`) |
| `docs/worker-reference.md:99-110` | "Node-wide" settings leave out `max_module_bytes`, `max_module_loads_per_second`, `max_resident_modules`, `max_resident_module_bytes`, `require_native_fs`, `scratch_roots`, `table_grow_limit`, `max_rec_groups` |
| `test/audit/README.md:16`, `UPSTREAM-OTP.md:10` | cite `wasm_core:reap/2`, which does not exist |
| `scripts/build-nif.sh:15` | points to "the sanitizer section of docs/wasi.md"; it moved to `docs/contributing/nif.md` |
| `design-notes.md:465,473` vs `compiled-tier.md:201-206,252,435` | "four units" against "two units" (`MAX_SHARDS` is 4, `wasm_jit.erl:151`); see question Q8 |
| `Makefile:42-43` | says `p2-fixtures` builds 0.2 programs only; the script builds the 0.3 ones too |
| `Makefile:8` | says its checks are the same as CI's; CI also runs Integration, Docs, NIF checks, wasmtime programs, tsan and audit |
| `test/audit/README.md:97` | says ThreadSanitizer was not done; `tsan.yml` exists now (true for the 0.3.0 audit only) |
| `AGENTS.md:17-45` | the source map leaves out ten modules (`wasm_app`, `wasm_sup`, `wasm_subsup`, `wasm_store`, `wasm_limits`, `wasm_file_cache`, `wasm_worker_images`, `wasm_cleanup_manager`, `wasm_cleanup_steward`, `wasm_cleanup_steward_sup`); nothing checks it |
| `src/wasm_instance.erl:1658` | "standing in for the process that will own this state at milestone M6": see Q5 |
| `component-internals.md:429` | says a WASI interface goes in `wasi_preview2`; it ignores the `wasi_p2_*` split and the 0.3 hosts |
| "Nothing raises" (README:23, concepts:66, getting-started:144, security:47) | overstated: `{bad_net_grant, _}` raises (`wasi_net.erl:108`), and several errors are bare tuples (`{load_rate_exceeded, N}`, `{module_cache_full, Max}`, `{error, no_run_export}`); see Q3 |
| `concepts.md`, `memory.md:17`, `snapshots.md:22` | "image" has two definitions; "profile" has two (compile options, and `script_v1`); "lease" means three things (snapshot capture, GC read lease, cleanup job) |

## 1. The recommended structure

The documentation becomes a path in five parts. A reader goes only as far as
they need, and each part ends by pointing at the next.

```text
 1 Orientation         README.md  ->  docs/start-here.md
   "is this for me, what do I use"     (one decision diagram, reading paths)
          |
 2 Concepts            concepts.md (glossary + mental model)
   "the words and why"  design-principles.md (new)
          |
 3 Use it              getting-started.md, examples/, task guides
   "do my task"         (embedding, WASI 0.1/0.2/0.3, components, HTTP,
                        workers, languages, snapshots, security, operate)
                        configuration.md (new, every setting in one table)
          |
 4 How it works        architecture.md (the map) -> one internals page
   "before you change"  per subsystem: runtime, compiled tier, memory, gc,
                        components, workers
          |
 5 Contribute          CONTRIBUTING.md (the contributor front door)
   "change it safely"   recipes.md ("If you want to..."), testing.md
                        (area -> suites), measuring.md, nif.md, fixtures.md

 Records, not guides:  test/audit/ (PERF, ATTEMPTS, reviews, design records)
```

The rules that keep it this way:

- A guide says what it is, when you need it, how (code), and what to read
  next. It does not carry history or measurement tables; it links to the
  record in `test/audit/` for the number behind a claim.
- An internals page follows `component-internals.md`'s shape: the terms, the
  modules and the function to read first, the flow, where to add a thing,
  and the tests.
- Each fact has one home, and other pages link to it. The protocol for a
  measurement lives in `measuring.md`, the "fuel is work, not time" rule in
  `concepts.md`, the page budget in `memory.md`, and the settings in
  `configuration.md`.
- hexdocs and GitHub show the same front door and the same reading path.

## 2. The starting point for a new developer

`README.md` stays the front door on both GitHub and hexdocs, and becomes
short. It has the pitch, one quick example with the installed API, the status
line, and the build commands, then one link: **docs/start-here.md**.

`start-here.md` replaces `docs/README.md` (which hexdocs cannot show,
`rebar.config:73-77`), `introduction.md` and `what-you-get.md`. It opens
with a decision diagram from what you have to what you use:

```text
 What do you have?
 a core .wasm module ............ wasm, wasi_preview1      -> getting-started
 a WASI 0.2 / 0.3 component ..... wasm_component,
                                  wasi_preview2/3          -> components, wasi-0-2
 untrusted code, one per request  wasm_instance_worker     -> worker
 a script (JS, Python, Lua) ..... wasm_script_worker
                                  + an adapter             -> scripting
 an HTTP handler component ...... wasi_http_listener       -> http
 you want to change the runtime   CONTRIBUTING.md          -> architecture
```

Then it gives one reading path per reader: user, operator and contributor.

## 3. Audience and purpose of each document

For each document: its intent; the reader; what the reader understands
after it; where it points next; the level of detail.

**Orientation**

- `README.md`: decide whether this is for you. Any visitor. After it you know
  what the project is, its status, and where to go. Next: `start-here.md`.
  Detail: one screen.
- `docs/start-here.md` (new): choose your entry point and reading path. A
  first-time user or contributor. After it you know which module and which
  guide fit your case. Next: `getting-started.md`, `concepts.md` or
  `CONTRIBUTING.md`. Detail: short, mostly the diagram and three paths.

**Concepts**

- `concepts.md`: the vocabulary and the mental model (module, instance,
  store, limits, fuel, the error value, image, worker, adapter, component,
  core). A user before their first real program. After it the guides read
  without surprises. Next: `design-principles.md`, `getting-started.md`.
  Detail: one definition per term, user-level only, linking to internals
  pages instead of explaining them.
- `docs/design-principles.md` (new): why the project is built this way. A
  user deciding whether to rely on it, and every contributor. After it you
  know the principles that explain the API: pure Erlang and why, a process
  per untrusted instance, failure as values at the guest boundary, options
  that express semantics and never tactics, guest data never becoming an
  atom, modules loaded once (the module cache's caps and rate), deterministic
  snapshots. Next: `architecture.md`, `security.md`. Detail: one short
  section per principle, each with the reason and where it shows in the API.

**Use it**

- `getting-started.md`, `examples/`: keep. In the examples, keep one "next"
  form (both a `**Next:**` line and a "Read this next" section exist today),
  make the chain reach every example, and use the installed workers.
- `embedding.md` + `otp.md` -> **one page, "Hold modules and instances"**:
  where modules and instances live in your supervision tree, ownership,
  `pin/release` (moved from `gc.md:445-468`, a user API with a leak
  consequence). A user writing a long-running service. Next:
  `host-functions.md`, `configuration.md`.
- `passing-data.md`, `host-functions.md`: keep. host-functions adds
  `{Module, Function}`, the meaning of `Ctx`, and where imports are
  dispatched and tested.
- `wasi.md`: retitle "WASI preview 1", keep the task part, move the syscall
  list and conformance to `features.md` and the NIF part to `nif.md`, and
  explain the backend once.
- `wasi-0-2.md`, `wasi-0-3.md`: keep. Add a table that translates preview 1
  options to 0.2 and 0.3 options (`dirs` vs `preopens`, `net` vs `network`,
  `env` as a map vs a list, `compile` vs `loader`). 0.3 also needs "do you
  need this", its host modules, its suite, and `resource_limit`.
- `components.md`: keep. Add export naming (`iface#func`, `[method]`,
  `[constructor]`), `wasm_component:exports/1`, and one worked example from
  WIT to the descriptor to `call/4`. Link `component-internals.md`.
- `http.md`, `security.md`: keep. In security, put the "Run untrusted code"
  checklist first, say that a snapshot freezes random seeds and clocks across
  tenants, and put "Reporting" last.
- `streams.md`: retitle "Talk to a running guest (stdin and stdout)". The
  word "streams" clashes with the Component Model's `stream<T>`.
- `snapshots.md` (476 lines): split. The guide opens with the raw API.
  The adapter path moves to `worker-contract.md`, the refusal tables go to a
  reference section, and the 0.8 comparison is removed.
- Workers: `worker.md` covers `wasm_instance_worker` only, and its
  `restore_ahead` and pool sections move to `scripting.md` or
  `worker-reference.md`. `scripting.md`, `worker-contract.md`,
  `worker-reference.md`, `javascript.md`, `python.md` and `lua.md`: keep.
- `compiled-tier.md`: keep as the operator guide (when to turn it on, what
  it costs), and drop the tables that predate shared restore (394-416).
- `tuning.md` (534 lines): rewrite to about 150 lines as "Tuning a worker
  host". The history (420-427, 452) and the tables go to `PERF.md`, and the
  repository-only bench tools are named as such.
- `docs/configuration.md` (new): every setting in one table, split into app
  env, instantiate options, worker options and limits, with each default and
  the guide that explains it. An operator. Next: the guide for each setting.
- `features.md` (717 lines): keep lines 1-80 as "Features and conformance".
  Move the rest (harness history, benchmarks, threads internals) to
  `test/audit/`, `contributing/testing.md` or `design-notes.md`.
- `upgrading.md`: rename it "Upgrading", one section per breaking version
  (it covers 0.3 only and the app is 0.9.2), or fold it into the CHANGELOG
  (Q10).

**How it works**

- `architecture.md`: keep as the map, and add the areas it lacks: WASI 0.3,
  HTTP serving, threads, GC, SIMD, the text format, the error model, the
  application tree and worker cleanup. Make the tests column name suites, not
  "the `wasi_*` suites". A contributor. After it you know which modules own
  an area and what to read first. Next: the internals page of that area.
- `component-internals.md`: keep (the model). Add the four suites missing
  from its tests table, and correct the WASI placement (0.2 split, 0.3).
- `worker-internals.md`: rewrite in part. Add a module table (worker,
  guardian and runner inside `wasm_script_worker`, `wasm_script_v1`,
  `wasm_worker_fs`, `wasm_worker_images`, `wasm_worker_error`,
  `wasm_instance_worker`, the cleanup modules), a tests table, and a "where
  to add" section. Remove the 0.3.0 history (159-167). Bring
  `test/audit/CLEANUP_STEWARD.md` here, or link it as the design record.
- `docs/compiled-tier-internals.md` (new): from `design-notes.md:410-698`,
  in the shape of `component-internals.md`: the lifecycle, the four modules
  and their names (see M6), the ABI bump rule, the tests.
- `memory.md`, `gc.md`: keep as internals. In gc.md, give the two "What it
  costs" / "What this cost" sections distinct titles, and move the user API
  out (see above).
- `design-notes.md` (703 lines): keep the rationale only (the control stack,
  the `#inst` / `#mut` split, stamps, atom pools, tables, floats,
  snapshots). Move "A benchmark that lied" and "Where a call's time goes" to
  `PERF.md` or `ATTEMPTS.md`, remove the four "Moved to" stubs, cut the WASI
  section down to its "why", and move the compiled-tier part out (above).

**Contribute**

- `CONTRIBUTING.md`: the contributor front door. Add a table of CI jobs
  (what each runs, which fixtures it needs, what skips without them), the
  wasmtime-programs facts now only in AGENTS.md, and a link to every page
  below.
- `AGENTS.md`: make it thin. Keep the agent-only rules and replace the source
  map with a link to `architecture.md` (or have `wasm_architecture_SUITE`
  check it, Q6). Link CONTRIBUTING and recipes. Its "take minimums" contradicts
  `measuring.md:56-57`; keep one statement, in measuring.md.
- `recipes.md`: keep and extend (section 11).
- `testing.md`: add the area-to-suites map (section 7), a table of test
  environment variables (`WASM_TESTSUITE`, `WASM_SPEC_MAX_FAILURES`,
  `WASM_REQUIRE_WASMTIME_FIXTURES`, `WASM_RUN_SLOW_PROGRAMS`, ...), and the
  check commands (`make check` against the undocumented `rebar3 check`
  alias, Q7).
- `docs/contributing/fixtures.md` (new): for each fixture family, the
  script that builds it, the suite that uses it, how it is verified
  (`.sha256`, `verify-fixtures.sh`), and how to bump an upstream pin.
  Note the trap: `fetch-suites.sh` returns early when the directory exists.
- `measuring.md`, `nif.md`, `adding-an-instruction.md`: keep. measuring.md
  becomes the only statement of the protocol, and the other pages link to it.

**Records**

- `test/audit/`: keep as the record. Label `REVIEW.md` as the 0.3.0 archive,
  clean "What is failing now" in `ATTEMPTS.md` (only solved items remain),
  and move the results sections of `bench/paths/README.md` (1070 lines) into
  `PERF.md`, keeping the arms table and protocol there.

## 4. Existing documents: the verdicts

| document | verdict | reason |
| --- | --- | --- |
| README.md | rewrite | front door; drop the examples API and the 50 lines of per-instruction timings (139-189) |
| docs/README.md | replace by start-here.md | hexdocs cannot show it; three starting points disagree |
| introduction.md | merge into start-here | 35 lines, too thin to stand alone |
| what-you-get.md | merge | dependency into getting-started, runtime fetch into scripting, sys.config into configuration |
| concepts.md | keep, fix | glossary sends users into internals pages; acquire/use/release section comes too early |
| getting-started.md | keep | the best page |
| guests.md | keep, fix | title and file name disagree; drop the examples workflow |
| examples/* | keep, fix | one "next" form; chain reaches every page |
| otp.md, embedding.md | merge | same trigger, overlapping ownership sections |
| passing-data.md, host-functions.md | keep, extend | add where imports are dispatched and tested |
| wasi.md | trim, retitle | preview 1 only; reference parts to features and nif |
| wasi-0-2.md, wasi-0-3.md | keep, extend | options translation table; 0.3 "do you need this" |
| components.md | keep, extend | export naming, worked example |
| http.md | keep | |
| streams.md | retitle | name clash with `stream<T>` |
| memory.md, gc.md | keep | internals; move pin/release to a user guide |
| snapshots.md | split | raw API first; adapter path to worker-contract |
| security.md | reorder | checklist first |
| tuning.md | rewrite short | mostly history and tables |
| features.md | split | lines 81-717 are records |
| upgrading.md | rename, extend or fold | covers 0.3 only |
| worker.md | move sections out | half of it is about the script worker |
| scripting, worker-contract, worker-reference, javascript, python, lua | keep | |
| compiled-tier.md | keep, trim | operator guide |
| architecture.md | keep, extend | the map |
| component-internals.md | keep, fix | the model internals page |
| worker-internals.md | rewrite in part | no module or tests table |
| design-notes.md | split | rationale, history and internals mixed |
| CONTRIBUTING.md | keep, extend | contributor front door |
| AGENTS.md | make thin | duplicates CONTRIBUTING; unchecked map |
| contributing/recipes, testing | extend | missing workflows and the suite map |
| contributing/measuring, nif, adding-an-instruction | keep | |
| test/audit/README.md | keep, fix | stale lines |
| bench/paths/README.md | trim | results to PERF.md |

## 5. Missing documents

`docs/start-here.md`, `docs/design-principles.md`, `docs/configuration.md`,
`docs/compiled-tier-internals.md`, `docs/contributing/fixtures.md`, and a
"Supported API" statement (a section of `start-here.md` or `architecture.md`,
see M12 and Q1).

## 6. Concepts that need a dedicated explanation

- **The error model**: what returns a value, what can raise, how a kind is
  chosen, and `wasm_error:capture/1` at the boundary. Today a user doc says
  "nothing raises", and only an elvis comment in `rebar.config` explains the
  internal throw-and-capture.
- **The module cache**: loaded once into `persistent_term`, capped, and
  limited to 50 loads a second. That limit is why "load once at startup" is a
  rule, and a request path that loads per request fails under load. Today it
  is only in the moduledoc.
- **Images and snapshots**: one definition, then core and component images,
  then the worker path.
- **The page budget and who frees memory** (keeper holders, arenas, images):
  a diagram in `memory.md`.
- **Leases, claims and holders**: three similar words in three subsystems.
- **Components for Erlang users**: lift and lower, the descriptors, export
  naming, the host resource table, subtasks.
- **The worker processes**: worker, guardian, runner, steward, manager and
  reaper, and why there are this many.
- **Fuel, reductions and deadlines**: work against time, with the BEAM
  scheduler explained once.

## 7. Navigation guide: area to modules to tests

This is the skeleton for `architecture.md` and `testing.md`. It names real
modules and suites.

| area | main modules | entry point | tests | doc |
| --- | --- | --- | --- | --- |
| Binary decode | `wasm_decode(_code/_simd/_gc/_atomic)`, `wasm_leb128` | `wasm:compile/2` | `wasm_spec_SUITE`, `wasm_decode_retain_SUITE`, `wasm_prop_SUITE` | adding-an-instruction |
| Validation | `wasm_validate(_code/_simd/_atomic)`, `wasm_types` | `wasm:compile/2` | `wasm_spec_SUITE` | adding-an-instruction |
| Text format, wast | `wasm_wat(_lex/_sexp/_num/_instr)`, `wasm_wast` | `wasm:compile({wat, _})` | `wasm_wat_SUITE`, `wasm_wat_lex_SUITE`, `wasm_wast_SUITE`, `wasm_annotate_SUITE` | none yet |
| Instantiate, link | `wasm_instance`, `wasm_table`, `wasm_global` | `wasm:instantiate/3` | `wasm_linking_SUITE`, `wasm_funcref_SUITE` | embedding, host-functions |
| Interpreter | `wasm_exec`, `wasm_num*`, `wasm_simd` | `wasm:call/3` | `wasm_spec_SUITE`, `wasm_num_SUITE`, `wasm_simd_SUITE`, `wasm_tailcall_SUITE`, `wasm_exception_SUITE` | architecture, "The path of a call" |
| Limits, errors | `wasm_limits`, `wasm_error` | the limits map | `wasm_budget_SUITE`, `wasm_trap_effects_SUITE`, `wasm_prop_SUITE` | none for `wasm_error` |
| Threads, atomics | `wasm_wait`, `wasm_decode_atomic`, `wasm_validate_atomic` | `memory.atomic.*` | `wasm_threads_SUITE` | features, Threads |
| GC proposal | `wasm_heap`, `wasm_decode_gc` | struct and array instructions | `wasm_gc_*_SUITE` | gc.md |
| Memory, page budget | `wasm_memory`, `wasm_keeper`, `wasm_engine` | `wasm_memory:new/1` | `wasm_resource_SUITE`, `wasm_shared_pages_SUITE`, `wasm_paged_memory_SUITE`, `wasm_memory64_SUITE` | memory.md |
| Compiled tier | `wasm_jit`, `wasm_core`, `wasm_code_slots`, `wasm_code_cache`, `wasm_jit_sup` | `wasm_jit:entry/3` | `wasm_core_SUITE`, `wasm_core_prop_SUITE`, `wasm_jit_lifetime_SUITE`, `wasm_jit_bounds_SUITE`, `wasm_code_slots_SUITE` | compiled-tier, new internals page |
| Snapshots | `wasm_snapshot(_owner/_file/_store)` | `wasm:snapshot/2`, `wasm:restore/3` | `wasm_snapshot_SUITE`, `wasm_component_snapshot_SUITE` | snapshots.md |
| Module and file cache | `wasm_module_cache`, `wasm_file_cache` | `wasm:load/1` | `wasm_module_cache_SUITE`, `wasm_file_cache_SUITE` | otp.md (to merge) |
| Application tree | `wasm_app`, `wasm_sup`, `wasm_subsup`, `wasm_store`, `wasm_lifetime` | application start | `wasm_lifetime_SUITE`, `wasm_worker_sup_SUITE`, `wasm_architecture_SUITE` | architecture |
| WASI preview 1 | `wasi_preview1`, `wasi_fs`, `wasi_path`, `wasi_net`, `wasi_sock`, `wasi_file_nif` | `wasi_preview1:imports/1` | `wasi_*_SUITE`, `wasi_nif_SUITE`, `wasi_net_escape_SUITE` | wasi.md, nif.md |
| Components | `wasm_component(_link/_types)`, `wasm_canon`, `wasm_resources`, `wasm_async`, `wasm_recipe` | `wasm_component:instantiate/2,3` | `wasm_component_*_SUITE`, `wasm_canon_prop_SUITE` | components, component-internals |
| WASI 0.2 | `wasi_preview2`, `wasi_p2_*`, `wasi_sock2` | `wasi_preview2:imports/0` | `wasm_wasi2_*_SUITE` (need the wasmtime fixtures) | wasi-0-2.md |
| WASI 0.3 | `wasi_preview3`, `wasi_p3_*` | `wasi_preview3:command/1` | `wasm_wasi3_p3_SUITE` | wasi-0-3.md |
| HTTP | `wasi_http(_h1/_h2/_listener/_transport)` | `wasi_http_listener:start/1` | `wasm_wasi2_http*_SUITE`, `wasm_wasi2_serve_SUITE` | http.md |
| Worker kernel | `wasm_script_worker`, `wasm_worker_adapter`, `wasm_script_v1`, `wasm_worker_fs`, `wasm_worker_images` | `wasm_script_worker:run/2` | `wasm_worker_kernel_SUITE`, `wasm_worker_SUITE`, `wasm_component_worker_SUITE` | worker-internals |
| Worker cleanup | `wasm_cleanup_manager`, `wasm_cleanup_steward(_sup)`, `wasm_worker_reaper` | internal | `wasm_cleanup_*_SUITE`, `wasm_worker_sup_SUITE` | CLEANUP_STEWARD.md |
| Language adapters | `wasm_javascript(_command)`, `wasm_python(_command)`, `wasm_lua`, `wasm_adapter_conformance` | `wasm_script_worker:start_link(Adapter, _)` | `wasm_worker_lang_SUITE`, `wasm_lang_SUITE` | worker-contract, the language pages |

## 8. Modules and subsystems that need better documentation

- `wasm_component`: its "To / Use" table leaves out snapshots, `prepare`,
  `start_async`, `pump`, `hold` and `source`; lines 1-840 have no section
  banner.
- `wasm_async`: no "Where things are" table; its 48 exports are in two
  unlabelled groups; all state lives in the process dictionary (235 calls
  over 36 keys, declared at 90-160) and nothing says why.
- `wasm` (the facade): one "calls" banner covers lines 456-1343, which hold
  the call protocol, GC root collection, destroy and snapshots; three
  `-doc false` internal entry points live on the public module.
- `wasm_jit`: one "compiling" banner covers lines 542-1332.
- `wasm_core`: "Inline memory access" (2343-3049, 706 lines, about 60
  functions) has no sub-banners.
- `wasm_exec`: the moduledoc is excellent. It should also say that about 24
  of its 33 exports are the ABI for generated code, and why the module stays
  one piece (the reason is now only in a `rebar.config` comment).
- The worker cleanup modules: which module owns capacity and the operator
  view while the migration is in progress (M8).
- `wasm_error`: no page, although 36 modules call it.

## 9. Modules hard to understand, with measurements

Lines are total and non-comment; exports; top-level functions.

| module | size | finding | primary problem |
| --- | --- | --- | --- |
| **M1** `wasm_component` | 2159 / 1620, 28 exports, 129 fns | facade, nested composition (541-615), async bridging, snapshots (840-1388, 548 lines), host boundary (1388-1949) and the host resource table, a per-process utility that WASI hosts call about 300 times. Its fan-in of 13 files comes mostly from that utility | module organisation |
| **M2** `wasm_instance` | 2096 / 1378, 49 exports in 14 groups | instantiation plus IR lowering and the peephole pass (774-998), snapshot capture leases (441-774), the per-instance ETS state, the name registry, compiled-tier bookkeeping, thread state commit. It has become the record-accessor hub for every subsystem (fan-in 11 modules, 17 suites) | module organisation |
| **M3** `wasm_async` | 2702 / 2167, 48 exports, 210 fns | 13 related sections (task frame, built-ins, copies, subtasks, the executor 1151-1441, fibers, cooperative threads 1909-2355, host ends), all sharing a process-dictionary frame | navigation |
| **M4** `wasm_script_worker` | 2264 / 1596, 22 exports, 139 fns | the code of three processes (server 501-1116, guardian 1202-1547, runner 1796-2033) plus restore-ahead, mounts and channels; the moduledoc table already solves navigation | module organisation (low) |
| **M5** `wasm_component_link` | 1793 / 1352 | the name hides that it is also the component decoder that `wasm_component:decode` uses; export names are parsed twice (`wasm_component:export_names` and `comp_export`) | naming |
| **M6** `wasm_core` | 3049 / 1920, 17 exports, 157 fns | "core" reads as "the core runtime" and clashes with the Component Model's "core module"; it is the code generator. `module/4..10` and `forms/5..8`: only `module/10` is used by `wasm_jit` | naming, then module organisation |
| **M7** the compiled tier as a whole | `wasm_jit` 1548, `wasm_core`, `wasm_code_slots` 1019, `wasm_code_cache` 504 | you cannot tell from the names which one decides, generates, holds slots or caches on disk; "jit" names what the docs call "the compiled tier" | naming |
| **M8** cleanup and lifetime | `wasm_worker_reaper` 1698 / 1190, `wasm_cleanup_manager`, `wasm_cleanup_steward(_sup)`, `wasm_lifetime` 55, `wasm_keeper` | five metaphors and two prefixes for related jobs. Capacity and the operator view exist in both the reaper and the manager (the manager's moduledoc says they "arrive with the stages that route the guardian through the manager"). This is a migration in progress, not a defect | architecture |
| **M9** sockets | `wasi_sock`, `wasi_sock2`, `wasi_net` | `wasi_sock2` breaks the `wasi_p2_*` / `wasi_p3_*` convention and is used by 0.3 as well | naming |
| **M10** `wasi_preview1` | 2543 / 1748, 6 exports | the `handle/5` dispatch is fine, but sockets take about 660 lines (26%), including the non-standard WasmEdge extension (808) | module organisation (minor) |
| **M11** `wasm` facade | 1400 / 920, 34 exports | navigation only (see section 8); 48 suites call it | navigation |
| **M12** public vs internal API | all 94 modules on hexdocs | no `-moduledoc false` anywhere; only the "Workers" group is marked supported; internals like `wasm_exec` (31 `-doc`), `wasm_instance` (40) and `wasm_async` (47) are published as if they were API | documentation, navigation |

Coherent despite size, leave as they are: `wasm_exec` (2569 lines; the
interpreter and the generated-code ABI belong together, and
`AGENTS.md` warns that `run/3` is performance critical), `wasm_keeper`
(1526; one authority, `handle_call` is a dispatch), `wasm_heap` (1476; facets
of one store), `wasm_validate_code` and the decoders (dispatch tables).

## 10. Unusually large functions

Most of the longest functions are opcode or call dispatch tables, one clause
per case, and are readable. Those that are single long clauses or
deeply nested are worth a look when someone next changes them:

| function | approx. lines | kind |
| --- | --- | --- |
| `wasi_preview1:handle/5` | 815 | dispatch, fine |
| `wasm_exec:run/3` | 646 | the interpreter loop, fine; do not touch without realbench |
| `wasm_validate_code:instr` | 550 | dispatch, fine |
| `wasm_core:instr` | 448 | dispatch, fine |
| `wasi_p2_sockets:sockets/1`, `wasi_http:http/1`, `wasi_p2_filesystem:filesystem/1`, `wasi_preview2:io` | 222, 219, 146, 109 | one function returning the whole import table of an interface; readable, but a reader looking for one method must scroll; a per-method index in the moduledoc would help |
| `wasm_keeper:handle_call/3` | 202 | dispatch, fine |
| `wasm_async:builtin_1/2` | 161 | dispatch, fine |
| `wasm_component_link:step/2` | 134 | a long dispatch over link steps |
| `wasm_instance:build/6` (209) | at least 80 | single clause |
| `wasm_script_worker:loop/1` (1330) | about 75 | a receive dispatch |
| `wasm:invoke_at/6` (554) | at least 69, 3 levels | mostly comments; the call protocol |
| `wasm_core:dispatch_fn/4` (1721), `invoke_fn/4` (805) | about 66 each | verbose `cerl` construction |
| `wasm_jit:generate_1/5` (803) | about 65 | single clause |
| `wasm_async:owner_side/1` (1729) | short, 5 levels deep | the deepest nesting found |

## 11. Contributor workflows ("If you want to...")

`recipes.md` already covers: a preview 1 syscall, a 0.2 interface, an
instruction, an adapter, an option, memory, the tier, dispatch, an HTTP
transport, debugging a trap or a worker request, a module, a page, a speed
claim, a release. Add, each pointing to real places:

- **Add a WASI 0.3 interface**: `wasi_preview3`, `wasi_p3_*`,
  `wasm_wasi3_p3_SUITE`, and the rule for keeping 0.2 and 0.3 in step.
- **Add a canonical or async built-in**: the opcode in
  `wasm_component_link:canon/1`, the behaviour in `wasm_async:builtin_1/2`,
  `scripts/build-wat-component-fixtures.sh`,
  `wasm_component_async_abi_SUITE`, `wasm_component_wast_SUITE`.
- **Change the worker kernel**: the three processes in
  `wasm_script_worker`, `wasm_adapter_conformance`, the fake adapters in
  `test/support/`, `CLEANUP_STEWARD.md` (today one sentence,
  `recipes.md:56-57`).
- **Change the snapshot format**: `wasm_snapshot_file` (`format_version/0`,
  `image_abi/0`, bumped by hand like `wasm_jit`'s `?ABI`),
  `wasm_snapshot_SUITE`.
- **Add or change an error value**: `wasm_error` (`malformed/2`,
  `capture/1`, `add_context/2`), how to choose class and kind,
  `wasm_prop_SUITE`.
- **Bump an upstream pin**: `scripts/fetch-suites.sh` (delete the directory
  first, or the change does nothing), `wasm_spec_manifest:core/0`, the
  baselines in `wasm_spec_SUITE`; `scripts/build-wasmtime-p2.sh` and its CI
  cache key.
- **Rebuild or verify a fixture**: `test/fixtures/lang/*.md`, the `.sha256`
  files, `scripts/verify-fixtures.sh`, `build-snapshot-fixtures.py`.
- **Move to a new OTP release**: the `no_ssa_opt` note
  (`design-notes.md:556-561`), `UPSTREAM-OTP.md`, `OTP` in `ci.yml:12`, the
  tag in `nif.md:70`.
- **Add or upgrade a dependency**: `rebar.lock` (the CI cache key),
  `scripts/audit-deps.sh` and the audit workflow, the h1/h2 libraries.
- **Debug a WASI capability refusal**, and **debug a failing CI job** (which
  jobs skip without fixtures, which fail).
- **Add an application setting** (not a limit): app env against instantiate
  options, and where `configuration.md` lists it.
- **Replace an implementation behind a boundary** (a WASI backend, an HTTP
  transport, a worker adapter): the behaviours that exist
  (`wasm_worker_adapter`, the HTTP transport, the `wasi_fs` backend) and their
  conformance tests.

## 12. Diagrams and examples that would help most

1. The "what do I use" decision diagram (start-here).
2. The compiled-tier lifecycle: interpreted, hot, compiling, loaded in a
   slot, released, with the stamp and purge rule.
3. Memory ownership: images, page table, arenas, keeper holders, and who
   frees what.
4. One view of the worker with its cleanup and supervision: worker, guardian,
   runner, steward, manager, reaper.
5. How a component's shape picks its instantiate path: single core, linked
   cores, composed.
6. The `wasm` application's own process tree beside a user's pool (otp page).
7. CI jobs, the fixtures each needs, and what skips without them.
8. Script to fixture to suite.
9. Worked examples: WIT to descriptor to `call/4`; an error value matched on
   its kind; the preview 1 to 0.2 options translation.

## 13. Questions for the maintainer

1. **Supported API.** Which modules and exports are the supported core and
   component API? Should internals get `-moduledoc false`, or a hexdocs group
   named "Internal"?
2. **Where the plan lives.** Is `test/audit/` the right home for this review
   and the next ones, and should design records (`CLEANUP_STEWARD.md`,
   `REVIEW.md`) stay there or move to `docs/`?
3. **The error promise.** Should "nothing raises" become "guest input never
   raises", or should the raising and bare-tuple cases become error values?
4. **Cleanup migration.** Will `wasm_cleanup_manager` take over the reaper's
   capacity, operator view and journal? What is the end state?
5. **Milestone M6** (`wasm_instance.erl:1658`): what is it, and is it still
   planned?
6. **AGENTS.md.** Should it shrink to agent rules plus links, and should
   `wasm_architecture_SUITE` check its source map?
7. **The check command.** `make check` or `rebar3 check` (which has no lint)?
8. **Compile units.** Is it four (`MAX_SHARDS`) or two? The docs disagree.
9. **`test/sys.config`** is named in `rebar.config:50` but is not in the
   tree. Intended?
10. **Upgrading notes.** One section per breaking version, or fold them into
    the CHANGELOG?
11. **`wasm_recipe`** is in `src/` but nothing in the runtime calls it, only
    its suite. Does it stay?
12. **The host resource table.** Should it move out of `wasm_component`
    (into `wasm_resources` or its own module)? And why does composition live
    in `wasm_component` while core linking lives in `wasm_component_link`?
13. **Names.** Are renames acceptable (`wasm_core` to a name that says code
    generation, `wasi_sock2` to the `wasi_p2_*` convention)? Each would be a
    breaking change for anyone calling them, even though they are internal.
14. **`wasm_core:module/4..9`.** Are the shorter arities kept only for
    tests?
15. **`wasm_lifetime`.** Is it a rule that every spawned helper process goes
    through it?

## 14. Suggested order

Each step is one pull request, one at a time, each merged before the next.

1. **Stale and misleading facts** (section 0). Small, no structure change,
   and two of them are visible on hexdocs. *Suggested as release-blocking.*
2. **Front doors**: the short README with the installed API,
   `start-here.md` replacing `docs/README.md`, `introduction.md` and
   `what-you-get.md`, CONTRIBUTING as the contributor door, AGENTS.md thin
   (after Q6). *Suggested as release-blocking, because hexdocs is published
   with the release.*
3. **Navigation**: the extended map in `architecture.md`, the area-to-suites
   map and environment variables in `testing.md`, and `configuration.md`.
4. **Concepts**: `design-principles.md`, the error model (after Q3), the
   module cache, one definition each for image, profile and lease.
5. **Move the records out of the guides**: `features.md`,
   `design-notes.md`, `tuning.md`, `bench/paths/README.md` results, the
   history paragraphs.
6. **Split and merge the guides**: snapshots, wasi, embedding with otp,
   worker with scripting, streams retitled.
7. **Internals pages**: `compiled-tier-internals.md`, the worker-internals
   rewrite, component-internals fixes, and the moduledoc tables and section
   banners for `wasm_component`, `wasm_async`, `wasm`, `wasm_jit` and
   `wasm_core`.
8. **Recipes** (section 11) and `fixtures.md`.
9. **Only then, code organisation**, each its own pull request and only on
   the maintainer's decision: the host resource table out of
   `wasm_component` (M1), IR lowering out of `wasm_instance` (M2), renames
   (M5-M7, M9), the cleanup migration end state (M8). Steps 1-8 make the
   boundaries visible first, so each of these is a smaller, safer change.

## What this release fixed

The maintainer chose to fix the documentation in full before the release,
in one pull request with one commit per step. No runtime behaviour changed:
every source file the pull request touches has the same code tokens as
before, only its docs and comments differ.

| step | what was done |
| --- | --- |
| 0, stale facts | all fixed, except the "milestone M6" comment (Q5) |
| 1-2, structure and front door | `README.md` is one screen with the installed API; `docs/start-here.md` replaces `docs/README.md`, `introduction.md` and `what-you-get.md`, with the decision table, three reading paths and the Supported API; internal modules are in hexdocs groups named "Internals: ..." (Q1) |
| 3, audiences | as proposed |
| 4, verdicts | as proposed; `otp.md` merged into `embedding.md`; `upgrading.md` is "Upgrading", one section per breaking release (Q10) |
| 5, missing documents | `start-here.md`, `design-principles.md`, `configuration.md`, `compiled-tier-internals.md`, `map.md`, `contributing/fixtures.md`, and `test/audit/CONFORMANCE.md` for the conformance history |
| 6, concepts | the error model is stated precisely in `design-principles.md`, with the host-side exceptions listed (Q3); one definition each for image, profile and lease |
| 7, navigation | `docs/map.md` holds the source map and the area table; `wasm_architecture_SUITE` now fails when a module is missing from it; AGENTS.md links to it (Q6) |
| 8, module docs | "Where things are" tables for `wasm_component` and `wasm_async`, banners in `wasm`, `wasm_jit`, `wasm_core`, `wasm_component`; `wasm_exec` and `wasm_error` say what they are for |
| 9-10, hard modules, large functions | documented, not changed: code organisation is left for later (step 14.9) |
| 11, recipes | all added |
| 12, diagrams | all drawn except the CI jobs and the script-to-fixture graphs, which became tables in CONTRIBUTING and `fixtures.md` |
| 14, order | steps 1-8 done; step 9 (code organisation) left open |

Q8 is answered from the code: an automatic split makes at most two units
(4,096 functions a unit, requests over 8,192 refused); four (`MAX_SHARDS`)
is reached only through the `compile_shards` limit.

### Still open

Questions Q2, Q4, Q5, Q7, Q9 and Q11 to Q15 above are still open. Writing
the documentation found these as well, none of them changed:

- **A tactic in the limits map.** `compile_shards` forces how a compile is
  split (`wasm_jit.erl`, `shard_count`), against the rule that options never
  select a tactic. It is not part of the supported API.
- **`compile` against `loader`.** `wasm_component:instantiate/3` takes
  `loader => load | compile` and picks the module cache only while the
  application runs. The `run_command` and `run_serve` runners of
  `wasi_preview2` and `wasi_preview3` take `compile => boolean()` and answer
  `cache_unavailable` without the application. The docs state both.
- **The cleanup migration.** `wasm_cleanup_manager:admit/1` and `release/1`
  are called by nothing in `src/`; the reaper refuses with
  `cleanup_saturated`. `CLEANUP_STEWARD.md` has the manager granting every
  job slot; the code has two separate counts (Q4).
- **Why `wasm_async` keeps its state in the process dictionary.** Nothing
  says why. The docs now give the reason the code implies: the built-ins
  are host functions in the owning process and return only results.
- **Errors.** A bare `~"unit"` passed for a variant answers `malformed`,
  `internal`, with a stack trace, not a kind of its own.
  `wasm_script_worker:stop/1` exits `noproc` on a dead worker, unlike `run`,
  `submit`, `await` and `cancel`.
- **Tests.** No suite tests the `{Module, Function}` host import form.
  `wasm_wasi2_async_SUITE` never runs in CI (it needs
  `p2_cli_invoke_async`, and its skip ignores
  `WASM_REQUIRE_WASMTIME_FIXTURES`). One case of `wasm_module_cache_SUITE`
  fails instead of skipping on a clone without `qjs.wasm`. The Tests job
  installs neither `wasm-tools` nor `wasmtime`, so the cases that need them
  skip there. The `python_metered` and `python_compiled` groups of
  `wasm_worker_lang_SUITE` are not in `all/0`.
- **Exports nothing calls.** `wasm_exec:check_depth/2`, `table_func/3` and
  `init_state/4` are exported, but only `wasm_exec` itself calls them.
- **Settings.** The `gc_*` thresholds are documented in `gc.md` but marked
  internal in `configuration.md`, because no option may select a collection
  strategy. The snapshot file ceilings are explained only in
  `wasm_snapshot_file`, an internal module. A snapshot format bump breaks the
  committed `pager-0.8.0.img` fixture; the recipe says to update both and
  note it in Upgrading.

## Before 0.10.1

Reviewed on `main` at `b0d4a6f`, 2026-11-18. Since 0.10.0 two pull requests
merged: #126 refuses a NUL byte in every WASI path, and #127 checks an
existing upstream checkout against its pin. Both changed the docs they
touch (`security.md`, `fixtures.md`, the pin recipe). The check found two
gaps, both fixed in the release:

- `docs/map.md` did not name the new `wasi_nul_path_SUITE`.
- `docs/contributing/testing.md` said `wasm_scripts_SUITE` needs `make`
  only; its new cases need `git`, and `wasi_nul_path_SUITE`'s native group
  needs the NIF.

Nothing else is new. The open items above are unchanged.

## Before the release after 0.10.1

Reviewed on `main` at `9e7f556`, 2026-11-19. Since 0.10.1 six pull requests
merged, all from one code review: #129 (three validation defects), #130 (one
graph parse per prepare), #132 (a race in the conformance kit), #133 (shared
staging and decoding in the adapters), #134 (linear text parsing, real
queues) and #135 (documented OTP APIs). No module was added or removed: 94
modules, about 60,200 lines, 102 suites.

**What is already right.** Every function these PRs removed or renamed is
gone from the docs: `parse_types/1`, `derive/1`, `current/2`, the adapters'
own `stage_all/2`. The moduledocs that name functions pass
`wasm_architecture_SUITE`. `wasm_script_v1` documents its new shared steps
and stays internal, so `worker-contract.md`, written for adapters outside
this repository, rightly does not mention them. The rule on OTP APIs is now
stated once with its two exceptions (AGENTS.md), enforced by
`only_documented_otp_calls_are_made`, and pointed to from CONTRIBUTING.md
and the upgrade recipe. The new fixtures `latelift` and `latedtor` come from
`scripts/build-wat-component-fixtures.sh`, which `fixtures.md` already
names for that directory.

**Found, small, fixed in this release.**

- `docs/component-internals.md:34` says `wasm_component_types` holds "the
  signatures read from the type section". Reading one type section was the
  defect #129 fixed: lifts and destructors are now resolved in the whole type
  space (every type section, import and alias). The line should say so.
- `test/audit/PERF.md`, "Documented OTP APIs", says CPython's whole module
  "did not reach `split/2` in the probe". The reason is known: it defines
  10,586 functions, over the 8,192 at which a compile is refused before
  anything is lowered (`compiled-tier-internals.md`, "The compile limits").
  The record should say that, not leave it as a gap.

**Found, a question for the maintainer.**

- **Q16. Where gates are measured.** `measuring.md` asks for a load average
  below 8. This machine ran at 30 to 190 through this cycle. Three gates
  could not be resolved and were recorded as they stood: instantiation in
  #130 (null run up to 1.09), one waiter on the cleanup manager in #134 (null
  run 1.07, pairs up to 1.45), and `prim_file` in #135 (null run 0.65 to
  1.16). Each record says so, and nothing was redefined. Should gates move to
  a quieter machine or a CI runner, so that a 3% gate can pass or fail on
  its own numbers?

  *Answered:* yes, gates run on a quieter machine from now on. None of the
  three needs a re-run for this release. #130 changed preparation, whose
  gates passed in both runs; instantiation reads the same prepared data as
  before. #134 adds one `queue:in/2` and one `queue:out/1`, nanoseconds, to
  a path that starts a process. #135 kept `prim_file`, so nothing changed;
  a quieter run matters only if moving to `file` comes up again.

**Grew, no new finding.** `wasm_component_link` (1,792 to 1,847 lines) now
has readers that take either the bytes or a parsed graph (`parsed()`),
which is what lets `prepare/1` parse once. This adds to M5: the module is
the component decoder as well as the linker, and the name still does not
say so. `wasm_script_v1` grew from 230 to 307 lines with the shared steps,
which is where they belong. The other touched modules changed by under 50
lines each.

**Still open, unchanged.** Every item under "Still open" above, and questions
Q2, Q4, Q5, Q7, Q9 and Q11 to Q15. The CPython groups of
`wasm_worker_lang_SUITE` are still outside `all/0`; this cycle ran them by
hand for #133, and all 91 cases passed.

## Before the release after 0.10.2

Reviewed on `main` at `cc125d6`, 2026-11-19. Since 0.10.2 three pull requests
merged: #138 (`wasi:nn`: the host and the backend behaviour), #139 (WASI 0.3
components built with cooperative threads) and #140 (`wasi:nn`: a model from
bytes under a grant, and tests from the interface and from wasmtime). One
module was added, `wasi_nn`: 95 modules, about 61,000 lines, 105 suites.

**What is already right.** `wasi_nn` has its level in `architecture.md`, its
row and its area in `map.md`, an `ex_doc` group, a line in the supported API
and in the extension points of `start-here.md`, a grant row and an interface
row in `wasi-0-2.md`, a paragraph in `security.md`, a recipe, and a guide of
its own, `wasi-nn.md`, which defines its five words before it uses them, says
which engines fit, and says what its tests do not prove. The two new suites
are in `testing.md`, `fixtures.md`, `CONTRIBUTING.md` and the CI job.
Cooperative threads are in `component-internals.md`, `features.md` and
`map.md`. The changelog has both under "Unreleased", in plain words.

**Found, small.** N1 to N4 are pages a reader looks at first and that do not
know `wasi:nn` exists. N5 and N6 are claims of the guide no test backs.

- **N1. `features.md` has no row for `wasi:nn`.** It is the page that says
  what is implemented and how each part is checked. It needs a row, and a
  short section like the one for preview 1: what is served, what is not
  (a model loaded by the host from a path, streaming, the older
  `wasi_ephemeral_nn` form), and the two suites.
- **N2. `README.md` does not mention it.** The second paragraph lists the
  Component Model and WASI 0.1, 0.2 and 0.3. A reader looking for inference
  finds nothing. One clause, and no more: the README is an entry, not a list.
- **N3. The module doc of `wasi_preview2` has a table of interfaces without
  `wasi:nn`.** `recipes.md` sends a contributor to that table.
- **N4. `component-internals.md` names "who uses" the host resource table
  and leaves `wasi_nn` out**, and its "Where to add things" says a host
  import that returns a resource must provide its `[resource-drop]`. That is
  half of it. A component whose entry core imports only host names drops
  through that import; a linked one, which is every `wasm32-wasip2` build,
  drops through `canon resource.drop`, which calls the instance's
  `resource_closer`. A host module must free in both. `wasi_nn` was written
  from this page and missed the second route until a test found it. The page
  should say it in the place a contributor reads.
- **N5. The guide says the `nn` option works with "the WASI 0.3 runners".**
  It should: `wasi_preview3:command/1` merges the 0.2 map, and its runner
  uses the 0.2 closer. No case runs a 0.3 component that imports `wasi:nn`.
  Either add one case or say "0.2" until one exists.
- **N6. The guide says a component that imports `wasi:nn` cannot be captured
  in a snapshot.** That follows from `snapshot_hooks/0` not declaring the
  interface, and from the handles having no origin. No case asserts it, and
  the table of refusals in `snapshots.md` names files and sockets only. One
  case, and one more example in that table.

**Found, worth doing but not small.**

- **N7. The guide's code is parsed, never run.** Its three Erlang blocks bind
  a `Bin` the reader does not have. Every other feature a user starts from
  has a page under `docs/examples/` that `wasm_docs_SUITE` executes. An
  example page, "Run a model from a component", can run for real: the
  `nncommand` component is committed, and a ten-line backend written on the
  page stands in for an engine. It is also where a diagram belongs: guest,
  host, backend, and which of the three holds the tensor.
- **N8. `start-here.md` has no path for it.** The table "what you have, what
  to read" sends a reader with a component to `components.md` and
  `wasi-0-2.md`. A reader who has a model and wants a guest to call it has
  no row.

**Found, questions for the maintainer.**

- **Q17. Which version.** `wasi:nn` is a new interface and a new behaviour,
  and nothing breaks. By the rule the changelog has followed, that is
  0.11.0, not 0.10.3. Confirm.
- **Q18. Naming a backend.** The guide tells a reader to bring a backend and
  names none. `erllama_wasi_nn` exists (erllama, pull request 81, not
  merged, and not on Hex until this release is). Name it in the guide now,
  as "the backend for llama.cpp", or wait until it is published?
- **Q19. The interface is a release candidate.** The host serves
  `wasi:nn@0.2.0-rc-2024-10-28` and answers any other candidate under the
  same names. The guide says so in its notes. Should `wasi_nn` be marked
  as able to change in the supported API table until the interface is
  stable, so that a change upstream is not a breaking release here?

**Decided, 2026-11-19.** N1 to N6 and N8 are fixed before the release, in
the pull request that carries this section. N7, the example page that runs,
waits. Q17: the release is 0.11.0. Q18: the guide names `erllama_wasi_nn`,
links to its repository and says it is in progress. Q19: `wasi_nn` is marked
a release candidate in the supported API table, the extension points, the
guide, `features.md`, the module doc and the changelog.

N5 was settled by a case, `the_wasi_3_runner_takes_the_grant`: the 0.3
runner serves the grant to the commands it runs. No 0.3 guest that imports
`wasi:nn` exists, and the guide now says which runner takes the key and no
more. N6 by `a_component_that_imports_nn_is_not_captured`.

**N7, done after the release.** `docs/examples/run-a-model.md` is an
example page `wasm_docs_SUITE` runs: it loads `examples/nn_upper.erl`, the
smallest backend, grants a model to the committed `nncommand` component and
shows the answer, then shows what a missing grant does. It has the diagram
of who holds what. `wasm_examples_SUITE` compiles the backend, runs it, and
fails when the page and the file differ. Nothing from this section is open.

**Grew, no new finding.** `wasm_async` went from 2,743 to 2,953 lines with
the cooperative threads of #139: it is still the largest module after
`wasm_exec`, and the open item on why it keeps its state in the process
dictionary stands. `wasi_nn` is 525 lines with one responsibility, of which
about 130 are the module doc, the types and the callbacks; it needs no
split. `wasm_wasi2_nn_SUITE` is 544 lines, of which the last 60 parse the
upstream WIT file; if a second suite needs that parser it moves to
`test/support/`.

**Still open, unchanged.** Every item under "Still open" above, and questions
Q2, Q4, Q5, Q7, Q9 and Q11 to Q15.

**Suggested order.** N3 and N4 first: they are a few lines each and N4 is
the one that cost time. Then N1 and N2. Then N5 and N6, a case each. N7 and
N8 together, since the example page is what the new row points to. Nothing
here needs a source change outside module docs and tests.

## Before 0.11.1

Reviewed on `main` at `9126c8f`, 2026-11-19. Since 0.11.0 one pull request
merged, #143: the example page for `wasi:nn` that N7 asked for, with
`examples/nn_upper.erl` and two cases in `wasm_examples_SUITE`. Nothing in
`src/` changed: 95 modules, 105 suites.

**What is already right.** The page is in the example chain (it follows
"Use a component resource" and is now the last), in both lists of
`rebar.config`, and linked from the top of the guide. `start-here.md` and
`map.md` say `examples/` holds three demonstrations, and `features.md` says
the third is a backend and not a guest. The page states what the component
does when its model is not granted as the suite observed it: a trap, not an
exit code.

**Found.** Nothing new.

**Still open, unchanged.** Every item under "Still open" above, and questions
Q2, Q4, Q5, Q7, Q9 and Q11 to Q15. The three blocks of `wasi-nn.md` itself
are still parsed and not run; the example page is where a reader runs them.

## Before the release after 0.11.1

Reviewed on `main` at `6b1e578`, 2026-11-26. Since 0.11.1 ten pull requests
merged, from an outside performance review of ab4e636: #145 (where a cold
compile spends its time, no source change), #146 (leaving hand-picked
functions uncompiled, recorded only), #147 (one validator clause per scalar
instruction), #148 (one-byte immediates in the decoder loop), #149 (a 64 KiB
translation-cache entry on memory with no image, ABI 16 to 17), #150
(a misaligned flat list refused), #151 (`list<u32>` in blocks), #152
(`memory.copy` by words and blocks), #153 (the NIF build skipped when
nothing changed) and #154 (WAT type declarations in linear time). Still 95
modules, about 61,200 lines; 107 suites, two more:
`wasm_validate_scalar_SUITE` and `wasm_decode_immediates_SUITE`.

**What is already right.** Every change has its `PERF.md` section with the
gates written before measuring, its raw files, and, where something was
dropped or rejected, an `ATTEMPTS.md` entry. The two new suites are in the
decode and validation rows of `map.md`. `compiled-tier-internals.md`
describes the cache as it now is: `cached/9`, `tag_bindings/3`, a block of
64 KiB or 4 KiB, one shift passed to the miss functions. `nif.md` has a
section on when the library is rebuilt. Each new arm has its own section in
`bench/paths/README.md`. No page describes the old behaviour: the 4 KiB
pages the docs still name are the page table of a restored memory, which is
still 4 KiB. Every changelog entry says what changed for a user, and the
generated-code ABI change says that cached code is compiled again once. No
module grew out of proportion: the largest change is `wasm_memory`, 1,339 to
1,411 lines.

**Found, small.**

- **P1. `memory.md` says less than it should about the cache.** Its
  paragraph says the cache holds "page translations" for restored memory.
  It now covers a 64 KiB block on a memory with no image, which is most
  memories and where the speed-up is. One sentence, and the link it already
  has.
- **P2. The table of arms at the top of `bench/paths/README.md` has no row
  for `ssaprofile`, `compilephases`, `listbench` or `copybench`.** Each has a
  section further down; a reader looking for an arm starts at the table.
- **P3. `watbench` has a row and no section.** Every other arm added this
  cycle has one, with the commands; its own module doc has them, and the
  section should say that `corpus` needs `wasm_wat_SUITE` on the path to
  include the suite's inputs, which silently changes the input count if it is
  missing.
- **P4. The WAT entry in the changelog describes the implementation.**
  "builds the type list in linear time and looks up inline function
  signatures by their first matching type" is how, not what it means. The
  rule is plain words and no implementation: "Parsing a text module with
  thousands of type declarations no longer slows down with the square of
  their number; ordinary modules parse as fast as before."

**Found, worth doing before the release.** The measuring protocol learned
four things this cycle that live only in `PERF.md` sections, where the next
contributor will not look first.

- **M1. Which load average, and waiting on the one you check.**
  `measuring.md` says "start below 8, and redo a run that ends above it". It
  does not say which average. The harnesses record the 5-minute one; a driver
  that waited on the 1-minute one launched short runs while the 5-minute one
  was still near 25, and every one of them was discarded. One sentence:
  name the 5-minute average and say the driver waits on the value it checks.
- **M2. Time the public call.** `wasm:compile/1` sets a heap floor before it
  decodes; an arm that called the decoder and validator directly reported a
  69% validation slowdown that the public call does not have, and an 18 to
  28% validation gain that is 3 to 4% through it (#147's record carries the
  correction). The rule: time the call a user makes, and take phase times
  from inside that same call, never minimums from different rounds added
  together.
- **M3. The gate rule every change here used is not written down in the
  guide.** Six pairs per ordering, a null set first between 0.95 and 1.05,
  three failed nulls make a result inconclusive, the decision on the median
  of the paired ratios in each ordering, one-sided limits, and a pair that
  gives up on load rerun under the same rule before a verdict. It is in
  `bench/paths/README.md` under `revision_set` and in every `PERF.md`
  section, not in `measuring.md`, which is the page AGENTS.md calls "the only
  statement of it".
- **M4. Check a driver's acceptance test before a long run.** Two driver
  bugs this cycle threw away hours: a crash check that matched the compile
  counters' `failed => 0` in every healthy run, and a pattern that lost its
  escape. Each was caught by feeding the check one healthy, one failed and
  one hot record. One line in `measuring.md`.

**Found, a record that lives outside the repository.** The plan behind these
pull requests deferred four pieces of work, each with what would reopen it.
Only one is in the repository (`ATTEMPTS.md`, "Leaving QuickJS's parser out
of the compiled set"):

- **D1.** Choosing the compiled set by exclusive interpreted work, with the
  gates already written: frozen selector, cold compile at most 0.90 on a
  declared target, warm and profiled-interpreted execution at most 1.03,
  first request to first compiled response at most 1.03.
- **D2.** Placing shards by call edges and caching a whole shard set (reopen
  with a profile showing cut edges take more than 5% of warm time).
- **D3.** Looking up a cached artifact before `unit/2` prepares the compile
  (reopen if that preparation is more than 10% of a restart's time to the
  first compiled call).
- **D4.** Compiling functions that become hot after the first compile (needs
  a two-phase guest).

They belong in `ATTEMPTS.md`, "Open, and each a decision rather than a task".
D4 was already there as "Multiple shards per module"; it gains its reopening
condition rather than a second entry.

**Questions for the maintainer.**

- **Q20. Which version.** Nothing in the supported API changed. Cached
  compiled code is rebuilt once (ABI 17), and a guest that passes a
  misaligned list as flat values now traps, as the Canonical ABI requires,
  where it was read. By the changelog's rule so far, performance and fixes
  are a patch: 0.11.2. Confirm, or 0.12.0 because of the refusal.
- **Q21. An Upgrading note for the refusal?** Upgrading has one section per
  breaking release. If a refusal of a guest that broke the ABI counts as
  breaking, it needs a section; if not, the changelog entry is enough.

**Still open, unchanged.** Every item under "Still open" above, and
questions Q2, Q4, Q5, Q7, Q9 and Q11 to Q15.

**Decided, 2026-11-26.** P1 to P4, M1 to M4 and D1 to D4 are fixed before the
release, in the pull request that carries this section. Q20: the release is
0.11.2. Q21: the changelog entry is enough; no Upgrading section.

**Suggested order.** P1 to P4 and M1 to M4 together: they are documentation
only, in `memory.md`, `measuring.md`, `bench/paths/README.md` and the
changelog. D1 to D4 in the same pull request, in `ATTEMPTS.md`. Then the
release, once Q20 and Q21 are answered.

## Before 0.12.0

Reviewed on `main` at `34e5e34`, 2026-11-26. Since 0.11.2 one pull request
merged: #157, the actor API (`wasm_actor`, `wasm_actor_registry`,
`docs/actors.md`) and a fix to `wasm_component:prepare/1` that brought a
linker fix with it. Now 97 modules, about 61,700 lines; 108 suites, one more:
`wasm_actor_SUITE`.

**What is already right.** The guide is task-shaped: the contract, how to
start one under a supervisor, what `ok` from a send promises and what it does
not, what to do with `full` and `closed`, and what a trap does. The module
doc says the same in reference form. Both new modules have their level in
`architecture.md`, a line in `map.md` and an `ex_doc` group; `wasm_sup` and
`architecture.md` draw the new subsystem in the supervision tree; the actor
table is in `wasm_store`'s list; the fixture has its source, its build step
and its row in `fixtures.md`; `start-here.md` has a row for the case. The
changelog says there is nothing to upgrade. Sizes are in proportion:
`wasm_actor` is 375 lines and 61 clauses beside `wasm_instance_worker`'s 281
and 29, and the registry is 70.

**Found, small.**

- **P5. Only two pages lead to actors.** A reader reaches `actors.md` from
  the table in `start-here.md` or from `map.md`. The pages where someone
  decides how to hold an instance do not mention it: `worker.md`, "Decide
  whether you need one" (a guest that keeps its state between messages is
  the case a worker does not cover), `concepts.md`, "Put an instance in its
  own process" and the glossary, `components.md`, "Instantiate one component
  many times" and "Read this next", and the README's first paragraph, which
  names workers. One sentence or link each. Primary problem: navigation.
- **P6. `recipes.md` has no recipe for actors.** The Workers line lists the
  adapter, the kernel and a worker request. A recipe would name the two
  modules, the suite and the page, and the three rules a change must keep:
  the name is registered only after the queue exists, the counter goes up
  before the capacity check, and a restarted registry watches every row
  again. Primary problem: navigation.
- **P7. One sentence of the changelog claims more than was shown.** The fix
  entry ends "each function such a component exports is matched to the
  cleanup and allocator its own definition names". The suites show it for
  components that `prepare/1` used to refuse, which took the name-based path
  on 0.11.2 and were right there. No component is shown that 0.11.2 matched
  wrongly. Either drop the sentence or keep it with that scope (see Q22).
  Primary problem: documentation.
- **P8. `components.md` says `prepare/1` returns the errors `instantiate`
  would.** A comment in `prepare/1` says a built-in its parser does not know
  still fails the prepare, while the unprepared path tolerates a graph it
  cannot read in several places (`validate_lifts/3`, `async_builtins/1`).
  Whether the unprepared path then succeeds on such a component has not been
  checked. See Q23. Primary problem: documentation.

**Found, in the code.**

- **C1. The component function index space is rebuilt by eight separate
  folds.** `alias_step/2`, `cfe_step/2`, `lb_step/2`, `lift_types/1`,
  `index_step/2`, `step/2` and `export_funcs_step/2` in
  `wasm_component_link` (1,902 lines, 341 clauses), and `compose_step/2` in
  `wasm_component`, each count the same items in the same order. That is how
  a function export came to be counted in none of them: the fix touched
  seven. The instance index space has the same shape and is counted in two
  of the folds that track instances (`export_funcs_step/2` and
  `compose_step/2`); `step/2` counts only imported instances in `n_pi`. No
  page says what the index spaces are: `component-internals.md` does not
  use the words. Recommended now: a short section there on the rule (every
  import, alias, definition and export takes the next index of its sort, in
  section order) and the folds that apply it. Later: one pass that builds
  every index space once, which the readers then share. Primary problem:
  code complexity.
- **C2. `wasm_actor` restates the value shapes `wasm_canon` lowers.**
  `fits/2` and `plain/1` (about 70 lines) decide what a send accepts. If
  `wasm_canon` changes a shape, for example to accept a list for
  `list<u8>`, the send check and the lowering disagree and nothing fails.
  Two ways to close it: move the check into `wasm_canon` beside the lowering
  it describes, or add a property case that generates values for each
  descriptor and asserts that `fits/2` and a successful lowering agree.
  See Q24. Primary problem: module organisation.

**Release evidence.** The full suite on `08e0b98`, the commit #157 merged:
1,750 passed, 2 skipped (`WASM_DOCS_STRICT` and `WASM_RUN_SLOW_PROGRAMS` not
set). All ten CI jobs passed on it; the Tests job was first cancelled at five
minutes with no failing case and passed when rerun (1,551 passed, the same
201 skips as `main`). Each new case failed on a planted defect, the
page-count case once the instance's builder outlives the actor. `wasm_demo`,
cloned fresh and pinned to `08e0b98`, ran `actor_demo()` as expected and
passed 13 of 14 in `make test` with no C or WebAssembly toolchain on the
path. The one failure is `py_test_`, whose first CPython request misses its
240 s bound without the file NIF; it fails the same way on the demo's `main`
with Hex 0.10.1, and passes in 66 s with the NIF built.

**Questions for the maintainer.**

- **Q22. The second sentence of the fix entry.** Drop it, or keep it scoped
  to components that `prepare/1` used to refuse?
- **Q23. `prepare/1` and an unknown built-in.** Is failing the prepare where
  the unprepared path might succeed intended? If so, `components.md` should
  say so; if not, `prepare/1` should take the unreadable graph as the
  unprepared path does.
- **Q24. Where the actor's value check lives.** In `wasm_canon`, or in
  `wasm_actor` with a property case that ties it to the lowering?
- **Q25. C1 now or later.** The section in `component-internals.md` before
  the release, and the single index-space pass recorded as open work?

**Decided before this review.** The release is 0.12.0: a new supported API,
nothing removed or changed. By Q21's rule there is no Upgrading section. The
demo's `py_test_` timeout without the NIF is a release-specific exception;
its 240 s bound stays until a run without the NIF measures what CPython
needs.

**Still open, unchanged.** Every item under "Still open" above, and
questions Q2, Q4, Q5, Q7, Q9 and Q11 to Q15.

**Suggested order.** P5, P6 and the C1 section together, documentation
only. P7 and P8 once Q22 and Q23 are answered. C2 and the single
index-space pass are code changes for a pull request of their own, after
the release unless you say otherwise. Then the version bump and the release
section of the changelog.

**Decided, 2026-11-26.** P5, P6, P7, P8 and the documentation part of C1
are fixed before the bump, in the pull request that carries this section;
the release pull request follows it. P5: a link at each of the four entry
points. P6: the recipe carries the three rules, with the reason a full queue
takes messages again (a refused send gives its reservation back, and the
actor frees a slot when it takes a message out).

- Q22: the cleanup and allocator sentence is dropped. The entry announces
  what a user gets: a component that uses WIT interface types can be
  prepared before it is instantiated.
- Q23: `prepare/1` keeps refusing a canonical built-in it does not know,
  as its source says. `components.md` no longer claims the same errors as
  `instantiate`: preparing checks the component first and can report
  `unsupported_canon_builtin`, and instantiation still resolves host
  imports and can report more. Whether the unprepared path succeeds on such
  a built-in stays unverified and is not claimed.
- Q24: admission stays in `wasm_actor`. After the release, a property case
  with one direction: given a working instance and enough memory, every
  message `send/2` admits lowers for its type. Refusal of invalid messages
  is tested apart. The two must not be required to accept the same inputs:
  admission range-checks a `u8`, where flat lowering masks the integer.
- Q25: the rule is documented now in `component-internals.md`, with a
  worked example of an export taking an index and moving the next
  definition's, the component and core spaces told apart, and the three
  different instance counts recorded.

**Open after 0.12.0.**

- **O1.** One pass that builds every component and core index space once,
  shared by the readers of the graph, and the instance space counted the
  same way by all of them (C1).
- **O2.** The directional property case for actor admission (Q24).
