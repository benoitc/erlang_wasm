# Architecture

This page is the map of the runtime: what the seventy-two modules are, which
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

```text
L10 wasm_javascript  wasm_javascript_command  wasm_python
    wasm_python_command  wasm_lua  wasm_adapter_conformance
L9  wasi  wasm_script_worker
L8  wasi_preview1  wasm_snapshot_store  wasm_instance_worker
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
    wasi_path  wasi_net  wasi_file_nif  wasm_worker_error  wasm_worker_adapter
    wasm_worker_fs
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
inside `wasm_memory`, and this is answered only by reading all seventy-two.

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
- `wasm_error` is at level 0 on purpose. Everything may build an error and
  nothing may ask the runtime a question while doing it.
- Adding a module means deciding its level. If it needs something above it, you
  are about to add a fourth cycle.
