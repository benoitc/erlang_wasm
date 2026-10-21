# Architecture

This page is the map of the runtime: what the eighty-six modules are, which
ones depend on which, and where to start reading. You need it before you change
anything, because every module explains itself and none of them explains the
shape of the whole.

Everything here is derived from the compiled modules rather than described from
memory, and `test/wasm_architecture_SUITE.erl` recomputes it on every test run.
If this page and the code disagree, that suite fails.

## Where to start reading

Read in this order. Each step is understandable with only the ones before it.

1. `wasm` is the front door. Every public operation is here, and each one is a
   few lines that delegate. Read it to learn the vocabulary: module, instance,
   extern, limits.
2. `wasm_decode` turns bytes into a `#module{}`. Start at `module/1` and follow
   one section.
3. `wasm_validate` decides whether that module is well typed.
   `wasm_validate_code` is where the operand stack lives.
4. `wasm_instance` turns a validated module into something executable. This is
   where imports get resolved and memories, tables and globals get created.
5. `wasm_exec` is the interpreter. Go to the `dispatch` section and read three
   or four instructions.
6. `wasm_jit` and `wasm_core` are the compiled tier. Read
   [the compiled tier](compiled-tier.md) first, then `wasm_jit:entry/3`.

`wasi_preview1` is a separate world sitting on top of all of it. You can ignore
it entirely unless you are working on WASI.

## Where things are

Each row is one part of the runtime: where a call enters it, the modules, what
configures it, where you extend it, the suites that cover it, and the page to
read. `test/` holds every suite named here.

| Part | Enter at | Modules | Configured by | Extend through | Tests | Read |
| --- | --- | --- | --- | --- | --- | --- |
| Decode and validate | `wasm:compile/2` | `wasm_decode*`, `wasm_validate*`, `wasm_wat*`, `wasm_types` | none | none | `wasm_spec_SUITE`, `wasm_wat_SUITE`, `wasm_prop_SUITE` | [Adding an instruction](contributing/adding-an-instruction.md) |
| Instantiate and link | `wasm:instantiate/3`, then `wasm_instance:new/3` | `wasm_instance`, `wasm_table`, `wasm_global`, `wasm_heap` | instantiate options; `table_grow_limit` | host functions | `wasm_linking_SUITE`, `wasm_funcref_SUITE`, the `wasm_gc_*` suites | [Embedding](embedding.md), [Host functions](host-functions.md) |
| Execute, with limits | `wasm:call/3` | `wasm_exec`, `wasm_error`, `wasm_limits`, `wasm_num*`, `wasm_wait` | the limits map | none | `wasm_trap_effects_SUITE`, `wasm_budget_SUITE` | [The path of a call](#the-path-of-a-call) |
| Memory and the page budget | `wasm_memory:new/1`, `wasm_memory:grow/2` | `wasm_memory`, `wasm_keeper`, `wasm_engine` | `wasm_engine:set_page_limit/1` | none | `wasm_resource_SUITE`, `wasm_shared_pages_SUITE`, `wasm_paged_memory_SUITE` | [Memory](memory.md) |
| Compiled tier | `wasm_jit:entry/3`, `wasm_jit:after_call/2` | `wasm_jit`, `wasm_core`, `wasm_code_slots`, `wasm_code_cache` | `compile`, `profile`, `code_cache_dir` | none | `wasm_core_SUITE`, the `wasm_jit_*` suites | [The compiled tier](compiled-tier.md) |
| Snapshots | `wasm:snapshot/2`, `wasm:restore/3` | `wasm_snapshot`, `wasm_snapshot_owner`, `wasm_snapshot_file`, `wasm_snapshot_store` | `max_snapshot_bytes` | `snapshot_hooks` | `wasm_snapshot_SUITE` | [Snapshots](snapshots.md) |
| Module cache | `wasm:load/1` | `wasm_module_cache` | `max_resident_modules` | none | `wasm_module_cache_SUITE` | [Put it in an OTP application](otp.md) |
| WASI preview 1 | `wasi_preview1:imports/1` | `wasi_preview1`, `wasi_fs`, `wasi_path`, `wasi_net`, `wasi_sock`, `wasi_file_nif` | the WASI options | the optional file NIF | the `wasi_*` suites | [WASI](wasi.md) |
| Components and WASI 0.2 | `wasm_component:instantiate/2`, `wasm_component:call/4` | `wasm_component`, `wasm_component_link`, `wasm_component_types`, `wasm_canon`, `wasm_async`, `wasm_resources`, `wasi_preview2`, `wasi_sock2` | the imports map | `wasm_component:import_fun/2` | the `wasm_component_*` and `wasm_wasi2_*` suites | [Components](components.md), [WASI 0.2](wasi-0-2.md), [Component internals](component-internals.md) |
| HTTP | `wasi_http:http/1`, `wasi_http_listener:start/1` | `wasi_http`, `wasi_http_h1`, `wasi_http_h2`, `wasi_http_listener` | `http_transport` | the `wasi_http_transport` behaviour | `wasm_wasi2_http_SUITE`, `wasm_wasi2_https_SUITE` | [HTTP](http.md) |
| Script workers | `wasm_script_worker:start_link/2`, `wasm_script_worker:run/2` | `wasm_script_worker`, the adapters, `wasm_worker_reaper`, `wasm_cleanup_manager`, `wasm_cleanup_steward` | worker options; `scratch_roots`, `reaper_options` | the `wasm_worker_adapter` behaviour | the `wasm_worker_*` and `wasm_cleanup_*` suites | [Using workers](worker.md), [Worker internals](worker-internals.md) |
| Build, packaging, the NIF | `rebar.config`, `scripts/` | `c_src/` | `WASM_NIF_SANITIZE` | none | `wasm_package_SUITE`, `wasm_scripts_SUITE` | [Changing the NIF](contributing/nif.md) |
| These docs | `docs/`, the module docs | none | `rebar.config` `ex_doc` | none | `wasm_docs_SUITE`, `wasm_architecture_SUITE` | [CONTRIBUTING.md](../CONTRIBUTING.md) |
| Benchmarks and evidence | `bench/paths/` | none | none | none | `wasm_bench_SUITE` | `test/audit/PERF.md` |

## The supervision tree

What `application:ensure_all_started(wasm)` starts. Each subsystem has its own
supervisor, so one that keeps crashing uses up its own restart budget and not
its neighbours'; `wasm_sup` says why.

```text
wasm_sup                one_for_one
  +-- wasm_store_sup    the long-lived ETS tables          wasm_store
  +-- wasm_engine_sup   the node-wide page budget          wasm_engine
  +-- wasm_keeper_sup   who holds each shared resource     wasm_keeper
  +-- wasm_code_sup     generated code, the compilers      wasm_code_slots, wasm_jit_sup
  +-- wasm_cache_sup    modules by content hash            wasm_module_cache
  +-- wasm_worker_sup   request cleanup for workers        wasm_cleanup_steward_sup,
                                                           wasm_cleanup_manager,
                                                           wasm_worker_reaper
```

There is no instance supervisor. An instance belongs to the process that made
it, and your application decides what shape those processes take.

## The layers

This is a map for changing the runtime, not for using it: a level says which
modules a module may call, and nothing about what you do with them. If you are
running WebAssembly rather than changing the runtime, start at
[Getting started](getting-started.md) instead.

Eleven of them, derived rather than drawn: a module sits one level above the
highest thing it calls, and the three cycles below each occupy a single level
together. So a module only ever calls **downward**, and level 0 depends on
nothing else in the project, which is where you can start and be certain of
finishing. The worker modules, in `src/worker/`, sit on top of the runtime
they use: the adapters at L10, the kernel below them.

The folders follow the same split. `src/` is the core runtime: the front
end, instances, the interpreter, memory, snapshots and the compiled tier.
`src/component/` is the Component Model, `src/wasi/` is WASI preview 1 and
0.2 with HTTP, and `src/worker/` is the workers. A folder is for finding a
module, not a namespace: names stay `wasm_*` and `wasi_*`.

```text
L10 wasm_javascript  wasm_javascript_command  wasm_python
    wasm_python_command  wasm_lua  wasm_adapter_conformance
L9  wasi  wasm_script_worker  wasi_preview2  wasi_http  wasi_http_transport  wasi_http_h1  wasi_http_h2  wasi_http_listener
L8  wasi_preview1  wasm_snapshot_store  wasm_instance_worker
    wasm_component  wasm_component_link  wasm_canon  wasm_async  wasm_component_types
L7  wasm  wasm_module_cache  wasm_snapshot_owner  wasm_jit_sup
L6  wasm_exec  wasm_core  wasm_jit  wasm_snapshot
L5  wasm_instance  wasm_wat
L4  wasm_validate  wasm_wat_instr
L3  wasm_memory  wasm_table  wasm_global  wasm_heap  wasm_store
    wasm_validate_code  wasm_wast  wasm_worker_sup
L2  wasm_decode  wasm_decode_code  wasm_decode_simd  wasm_decode_gc
    wasm_decode_atomic  wasm_keeper  wasm_simd  wasm_types  wasm_wait
    wasm_wat_sexp  wasm_app  wasm_cleanup_manager  wasm_cleanup_steward
L1  wasm_code_cache  wasm_engine  wasm_leb128  wasm_num_float
    wasm_num_trunc  wasm_sup  wasm_wat_lex  wasm_wat_num  wasi_fs  wasi_sock
    wasm_worker_reaper  wasm_script_v1  wasm_cleanup_steward_sup
L0  wasm_error  wasm_num  wasm_limits  wasm_code_slots  wasm_file_cache
    wasm_snapshot_file  wasm_subsup  wasm_validate_simd  wasm_validate_atomic
    wasi_path  wasi_net  wasi_sock2  wasi_file_nif  wasm_worker_error
    wasm_worker_adapter  wasm_recipe  wasm_worker_fs  wasm_resources
```

`test/wasm_architecture_SUITE.erl` asserts that this block names every module
in the application and nothing else. It was added after seven modules went
missing from it -- the four snapshot ones, `wasm_file_cache`, `wasm_store` and
`wasm_subsup` -- while the cycles below were kept current by hand.

Read it as three stacks that meet at the top. The **front end** goes
`wasm_leb128` to `wasm_decode` to `wasm_validate`, or `wasm_wat_lex` to
`wasm_wat` for the text format, and both produce the same `#module{}`. The
**runtime** goes `wasm_keeper` to `wasm_memory` and its siblings to
`wasm_instance` to `wasm_exec`. The **tier** goes `wasm_code_slots` to
`wasm_core` to `wasm_jit`. `wasm` sits over all three, and the snapshot
modules hang off the runtime at three different heights: `wasm_snapshot_file`
at the bottom because a file format needs nothing, `wasm_snapshot` in the
middle because it copies instance state, `wasm_snapshot_owner` at the top
because it holds a module claim, which is why it is in a cycle with the facade.

```text
      script workers: wasm_script_worker, wasm_instance_worker, adapters
                                  |
      WASI and components: wasi_preview1, wasm_component, wasi_preview2,
                           wasi_http
                                  |
                                wasm                the facade
                                  |
          +-----------------------+-----------------------+
          |                       |                       |
      front end               runtime                   tier
      wasm_wat                wasm_exec                 wasm_jit
      wasm_validate           wasm_instance             wasm_core
      wasm_decode             wasm_memory, siblings     wasm_code_slots
      wasm_leb128             wasm_keeper
          |                       ^                       |
          +------ #module{} ------+----- compiled code ---+
```

The front end hands the runtime a `#module{}`, and the tier hands it compiled
functions to run in place of interpreted ones. The layers above `wasm` are
built on it, and the level listing above says which lower modules each may
also call directly.

## The three cycles

There are exactly three, and each is a few edges rather than a tangle.

**The decoder, five modules.** `wasm_decode_code` and the opcode-space modules
`wasm_decode_simd`, `wasm_decode_gc` and `wasm_decode_atomic` call each other. A
SIMD immediate can contain a memory argument and a GC instruction can contain a
block type, so this is the format's own recursion and not a layering slip.

**The tier, three modules.** Two edges, one function each. `wasm_core` calls
`wasm_exec:load_spec/1` and `store_spec/1` at generation time, so that the
interpreted and generated paths cannot describe a load differently.
`wasm_exec` calls `wasm_jit:reentered/0` on the way back into generated code.

**The facade, the cache and the snapshot owner, three modules.**
`wasm_module_cache` calls `wasm:compile/2` on a miss. One line, and for a long
time that was the whole of it.

`wasm_snapshot_owner` joined it deliberately. An initialized runtime snapshot
holds a module's layout, so it needs a claim on that module that outlives the
process which captured it, and a claim is given back by the process that holds
it. Anything long-lived enough to do that calls the cache, and the cache calls
the facade, so there is no arrangement that avoids the cycle: only a choice of
which module is in it. The choice was the fifty lines whose entire purpose is
holding a claim, rather than `wasm_snapshot`, which is the mechanism -- what a
capture copies and what a restore lays over -- and stays out of it.

Cycles are not forbidden here. What is forbidden is a fourth one appearing
because nobody noticed. A cycle is the one structural property you cannot
discover by reading a module: everything else about `wasm_memory` is answered
inside `wasm_memory`, and this is answered only by reading all eighty-six.

The margin is thinner than it looks. Adding one call from `wasm_error`, at
level 0, up into `wasm` collapses fourteen modules into a single component, and
nothing but the guard would have told you.

## The path of a call

One `wasm:call/3` end to end, so you can put a breakpoint anywhere on it. Every
hop names the function you would stop in.

```text
wasm:call/3                      check per-call limits, if any were given
  wasm:call_1/4                  wasm_instance:export_kind/2 resolves the name
                                 to a function index, then checks the arguments
  wasm:invoke_with/5             enter/0 counts depth **per process**, not per
                                 instance, because a host import may call back
  wasm:leased_invoke/6           only at depth 0, and only on a snapshotable
                                 instance: wasm_instance:enter_call/1 refuses
                                 while a capture or a destroy is in progress
  wasm:invoke_at/6               takes the heap lease, opens the fuel budget,
                                 reads #mut{} once
     wasm_jit:entry/3            depth 0 only. Answers a compiled entry point
                                 if a slot is resident, otherwise the one it
                                 was given
  wasm_exec:call/5               the interpreter: dispatch in run/3, control
                                 flow in branch/3, calls in do_call/4
  wasm:settle/2                  values out, or an error value
```

Three things about that shape are deliberate and easy to undo by accident.

**The tier is entered once, at the outermost invocation.** Not inside
`do_call/4`, where a "is this callee compiled?" test would sit on the
interpreter's hot path. Three separate changes to `run/3` and `branch/3` have
each cost about 70% on QuickJS while the synthetic loop measured nothing;
`test/audit/PERF.md` has them.

**Depth is per process.** A host function may call back into the instance that
called it, so the count cannot live on the instance.

**The lease is the outermost frame's.** Nested calls are already inside one,
and taking a second would be two atomic operations per re-entry for nothing.

A request through the worker kernel arrives at this path by a longer road:
`wasm_script_worker` spawns a runner per request, the adapter's `prepare/3` builds
the import set, and a reactor restores an image before `handle` is called. That
road is drawn in [Worker internals](worker-internals.md), and its cost is broken down
phase by phase in `test/audit/PERF.md`.

## Reading the graph yourself

```erlang
{ok, S} = xref:start(arch),
{ok, _} = xref:add_directory(S, "_build/default/lib/wasm/ebin", [{warnings, false}]),
{ok, Calls} = xref:q(S, "XC"),
{ok, Mods} = xref:q(S, "AM"),
xref:stop(S).
```

Then build a `digraph` from `Calls` restricted to `Mods` and ask
`digraph_utils:strong_components/1`. `test/wasm_architecture_SUITE.erl` does
exactly this.

Do not derive the graph by grepping the sources. Module documentation refers to
other modules as `` `wasm_exec:call/3` `` and a grep counts every one of those as
a dependency; on this tree that turns three cycles into one component of
fourteen modules and a completely wrong picture.

## Short notes

- Level 0 is a good place to make a change: nothing in the project depends on
  its internals, so the blast radius is what its callers use.
- `wasm_keeper` is the lifetime authority for anything two instances can share.
  If you are adding a resource with a lifetime, it goes through there.
  That includes a snapshot's image, which every memory restored from it holds,
  and each memory's charged pages: its page table, growth chunks and arena.
- `wasm_error` is at level 0 on purpose. Everything may build an error and
  nothing may ask the runtime a question while doing it.
- Adding a module means deciding its level. If it needs something above it, you
  are about to add a fourth cycle.

## Read this next

The page for the part you are changing: [Worker
internals](worker-internals.md), [The compiled tier](compiled-tier.md) or
[Snapshots](snapshots.md); then [Design notes](design-notes.md) for the why.
