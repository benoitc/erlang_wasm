# Architecture

This page is the map of the runtime: what the forty-eight modules are, which
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

Nine of them. A module only calls downward, with three exceptions noted below.
Level 0 depends on nothing else in the project, so it is where you can start
and be certain of finishing.

```
L8  wasi
L7  wasi_preview1
L6  wasm  wasm_module_cache  wasm_jit_sup
L5  wasm_exec  wasm_core  wasm_jit
L4  wasm_instance  wasm_wat
L3  wasm_validate  wasm_wast  wasm_wat_instr  wasm_app
L2  wasm_decode  wasm_decode_code  wasm_decode_simd  wasm_decode_gc
    wasm_decode_atomic  wasm_memory  wasm_table  wasm_global  wasm_simd
    wasm_validate_code  wasm_wat_sexp  wasm_sup
L1  wasm_keeper  wasm_heap  wasm_types  wasm_num_float  wasm_num_trunc
    wasm_leb128  wasm_wait  wasm_wat_lex  wasm_wat_num  wasi_fs  wasi_sock
L0  wasm_error  wasm_num  wasm_limits  wasm_engine  wasm_code_slots
    wasm_code_cache  wasm_validate_simd  wasm_validate_atomic  wasi_path
    wasi_net  wasi_file_nif
```

Read it as three stacks that meet at the top. The **front end** goes
`wasm_leb128` to `wasm_decode` to `wasm_validate`, or `wasm_wat_lex` to
`wasm_wat` for the text format, and both produce the same `#module{}`. The
**runtime** goes `wasm_keeper` to `wasm_memory` and its siblings to
`wasm_instance` to `wasm_exec`. The **tier** goes `wasm_code_slots` to
`wasm_core` to `wasm_jit`. `wasm` sits over all three.

## The three cycles

There are exactly three, and each is one or two edges rather than a tangle.

**The decoder, five modules.** `wasm_decode_code` and the opcode-space modules
`wasm_decode_simd`, `wasm_decode_gc` and `wasm_decode_atomic` call each other. A
SIMD immediate can contain a memory argument and a GC instruction can contain a
block type, so this is the format's own recursion and not a layering slip.

**The tier, three modules.** Two edges, one function each. `wasm_core` calls
`wasm_exec:load_spec/1` and `store_spec/1` at generation time, so that the
interpreted and generated paths cannot describe a load differently.
`wasm_exec` calls `wasm_jit:reentered/0` on the way back into generated code.

**The facade and the cache, two modules.** `wasm_module_cache` calls
`wasm:compile/2` on a miss. One line.

Cycles are not forbidden here. What is forbidden is a fourth one appearing
because nobody noticed. A cycle is the one structural property you cannot
discover by reading a module: everything else about `wasm_memory` is answered
inside `wasm_memory`, and this is answered only by reading all forty-eight.

The margin is thinner than it looks. Adding one call from `wasm_error`, at
level 0, up into `wasm` collapses fourteen modules into a single component, and
nothing but the guard would have told you.

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
