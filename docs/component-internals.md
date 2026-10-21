# Component internals

How the Component Model is implemented, for you when you are changing it
rather than using it. Read it before you touch decoding, linking, the Canonical
ABI, resource handles or the async ABI, or when you add a host import or a value
type. To use components, read [Components](components.md); this page does not
repeat it.

## The modules

| Module | Decides | Read first |
| --- | --- | --- |
| `wasm_component` | which path a component takes, what a call does at the host boundary, the host handle table | `instantiate/3`, then `call/4` |
| `wasm_component_link` | how several cores wire to each other and to the host; which core implements each export | `link/4`, then its `step` clauses |
| `wasm_component_types` | the signatures read from the type section: lift checks, bridges, handle checks | `type_space/1` |
| `wasm_canon` | how a value crosses: flattening, memory layout, spill, string encodings, realloc | `lower_params/3`, `lift_result/3` |
| `wasm_resources` | who holds a guest resource handle, and when a use traps | the module doc, then `host_lend/3` |
| `wasm_async` | tasks, waitable-sets, futures and streams, async imports | `builtin/2`, `wait_on_set/1` |
| `wasm_recipe` | how a component is built from a Rust source directory | `steps/1` |
| `wasi_preview2` | the WASI 0.2 host a component imports | `imports/0` |

`wasm_recipe` is not on the runtime path. It turns a recipe map into `cargo`
and `wasm-tools` commands so an embedder (hornbeam) can build its components
without a shell script; nothing in `src/` calls it.

## From bytes to a running instance

`wasm_component:decode/1` checks the layer-1 preamble (`00 61 73 6d 0d 00 01
00`) and walks the top-level sections once. It keeps the core modules
(section 1), the export names (section 11, accumulated across sections) and the
raw section stream for later. The graph itself is parsed only when needed.

Three shapes come out of it:

| Shape | Recognised by | Path |
| --- | --- | --- |
| single core | one core, or every export lifts from the largest core and the host covers its imports | `start`: one `wasm:instantiate/3` |
| linked cores | the entry core imports from another core, or an export lifts from a core other than the largest | `wasm_component_link:link/4` |
| composed | no top-level core (nested components, as `wac` emits) | `instantiate_composed` |

The entry core is the largest one: a resource or WASI component embeds smaller
shim and adapter cores beside the guest. On a tie the earliest wins, so the
pick is stable.

```text
  component bytes
        |
   decode/1 ---------------------------- composed: no top-level core
        |                                       |
   validate_lifts/2  (reject a lift      instantiate each nested
        |             whose core type     component; wire its imports
        |             cannot match)       to siblings as bridges
        |                                       |
   resource_info/2, core_imports/1       dispatch map: export ->
        |                                 {sub-instance, export}
   single core?  -- yes --> wasm:instantiate/3 on the entry core
        |
        no
        |
   wasm_component_link:link/4
        |  fold the graph in order: core instances, aliases,
        |  canon lift / lower / resource.* / async built-ins
        v
   cores (one shared store)
        |
   canon (wasm_canon)      lift and lower at every boundary
        |
   resources (wasm_resources)   per-instance handle table
        |
   preview 2 host (wasi_preview2)   the {Interface, Field} imports
```

### `instantiate/3`

The steps, in order:

1. Split the options: `loader`, `resource_closer`, `resource_predrop` and
   `resource_limit` are read here; everything else is core instance limits.
2. Decode inside `wasm_error:capture/1`, so a malformed component is a value.
3. `wasm_component_link:validate_lifts/2`: each `canon lift` declares a
   component type, the Canonical ABI derives a core signature from it, and the
   core function must have exactly that signature. A mismatch is
   `{error, {invalid_lift_type, _}}` before any start function runs.
4. `wasm_component_link:resource_info/2` reads each export's real signature,
   the resource types the component defines, the type each resource built-in
   acts on, and each destructor's export name.
5. Resolve the entry core's imports. `strip_version` turns
   `wasi:io/streams@0.2.0` into `wasi:io/streams`, because the host map is keyed
   bare. An explicit host function wins over an automatic resource intrinsic.
6. Pick the path. Any import still unresolved sends the component to the
   linker; so does a multi-core component whose exports do not all resolve on
   the entry (`wasm_component_link:exports_resolve_on_entry/2`).
7. Build the cores with a fresh `wasm_resources` table current, so a start
   function that mints a handle mints it in this instance.
8. Record per-export string encodings (`export_encodings/1`) and the declared
   realloc and post-return (`export_bindings/1`) on the instance.

A failed build destroys the resource table it created.

### Linking several cores

`wasm_component_link:parse/1` turns the section stream into an ordered item
list. `link/4` folds over it, assigning indices per kind the way the
specification does: core instances, core funcs, memories, tables, globals,
component instances and component funcs.

- `{core_instance, {instantiate, Mod, Args}}`: build the core, taking each
  import namespace from the instance its `with` argument names, or from the host
  when there is none. Every core after the first is built with
  `#{link => Anchor}`, so all cores share one store and a memory or table of one
  serves another.
- `{core_alias, Sort, Inst, Name}`: pull an export out of a built instance with
  `wasm:extern/2`. A func alias also records which instance it came from, which
  becomes the export's call target.
- `canon lower`: bind a host function (from the imports map) as a core function,
  scoped to the lower's realloc and string encoding and run with the guest
  instance as its context.
- `canon lift`: add a component func; the encoding is checked here.
- `canon resource.new | rep | drop` and the async built-ins: see below.

The entry is the core that exports `wasi:cli/run...#run` (a command), else the
instance of the largest module (a reactor). A link that fails part way destroys
every core it built.

The preview1 adapter needs no special case. Its startup cycle (the guest core
imports adapter functions, and the adapter needs the guest's memory and
realloc) is broken inside the component: a shim core exports a table of
indirect-call stubs, and a fixup core fills that table once both sides exist.
The linker interprets those instances in graph order, and because the cores
share one store, the table the fixup fills is the table the guest calls
through.

### Composed components

`instantiate_composed` folds the graph with `compose_step`. Each nested
component is instantiated through `instantiate/3` again. When an instantiate
argument binds one of its imports to a sibling's interface export, it gets a
bridge for each function of that interface: an `import_fun/2` wrapper whose body
is `call/4` on the provider. Values cross as Erlang terms, each side in its own
memory. The signatures come from the nested component's own type section,
through `wasm_component_types:import_interfaces/1`.

`call/4` on a composed instance looks the export up in `dispatch` and calls the
sub-instance. An export backed only by an imported interface answers
`{error, {unresolved_export, Name}}`.

## A call

`wasm_component:call/4`, after dispatch, inside `wasm_error:capture/1`:

```text
  with_string_encoding(export's encoding)
    with_instance(res_id)                 resource table current
      target_for(Export)                  {CoreInstance, CoreName}
      handle_sig                          strict | loose | none
      with_loans                          give borrows back on exit
        lower_handles                     own -> guest, borrow -> rep
        with_realloc(declared realloc)
          wasm_canon:lower_params/3       terms -> flat core args
          wasm:call/3
          wasm_canon:lift_result/3        core results -> term
          run_post_return                 declared post-return
        lift_handles                      own result -> host
```

- **Target.** The linker's `export_targets` wins, because two cores can export
  the same name. Otherwise the export map renames to the core function, and the
  last fallback is the export's own name on whichever core has it.
- **Lowering.** Up to 16 flat values (`MAX_FLAT_PARAMS`) pass directly. Past
  that, the parameters are stored in guest memory as one tuple and a single
  pointer is passed. Strings and lists are placed through the realloc the lift
  declares, or the guest's `cabi_realloc` export when it declares none.
- **Lifting.** A result of one flat value comes from the core results; anything
  wider is read from the pointer the guest returned, after an alignment check.
- **Post-return.** It runs the function the lift declares, not
  `cabi_post_<export>` by name. A trap in it fails the call.

### Handles at the boundary

The export's real signature, from the component's type space, decides how
handles cross, whatever descriptors the caller passed. So `{[u32], u32}` for a
method is checked exactly like `{[{borrow, 0}], u32}`.

| Mode | When | Checks |
| --- | --- | --- |
| `strict` | the type space gives the export's signature | type and liveness, for types this component defines |
| `loose` | no signature, but the component defines a resource | liveness only, every handle |
| `none` | no signature and no defined resource, or the instance is destroyed | nothing |

| Direction | Kind | `wasm_resources` call | The guest gets |
| --- | --- | --- | --- |
| argument | `own` | `host_give/3` | the handle |
| argument | `borrow` | `host_lend/3`, undone by `host_unlend/2` | the representation |
| result | `own` | `host_receive/3` | (the host now holds it) |

A handle of a type another component defines (a WASI stream) passes through
untouched. Loans are returned when the call ends, traps, or fails a check part
way through lowering.

## Resources and host handles

There are two tables, and they answer different questions.

**`wasm_resources`: resources the guest defines.** One table per component
instance, in the process dictionary of the process that owns the instance.
Handles start at 1 and are never reused while the instance lives. Each entry is
`{Rt, Rep, Owner}`, with `Owner` one of `guest`, `host` or `{lent, N}`.

- The guest side (`new/2`, `rep/2`, `drop/2`) acts on the current instance,
  the one `with_instance/2` set. With none current they pass the value through.
- The host side (`host_*`) names the instance explicitly.
- A failed check throws `resource_not_live`, `resource_wrong_type` or
  `resource_borrowed` through `wasm_error:trap/2`.
- The guest reaches the table through the resource built-ins. On the
  single-core path they are core imports named `[resource-new]...`,
  `[resource-rep]...` and `[resource-drop]...`, bound in `resource_imports`. On
  the linked path they are `canon resource.*` items bound in `step`.
- A guest drop of a defined resource runs `<iface>#[dtor]<res>` with the
  representation. `drop_resource/3` does the same for a host-held handle.
- Across composed components, an `own` the provider returns stays in the
  provider's table and the consumer gets an `imported` entry whose
  representation is `{remote, ProviderId, Handle, Release}`. Dropping it runs
  `Release`, which drops it in the provider.
- `destroy/1` discards the table. No destructor runs.

**Host handles: resources the host defines.** `host_new/2`, `host_get/1`,
`host_update/2` and `host_drop/1` keep `{Tag, State}` in a per-process map,
separate from the guest table. WASI 0.2 streams, files, sockets and HTTP
objects live here. A host function mints one when it returns an `own`, and the
`[resource-drop]` the host map provides removes it.

```erlang
Imports = #{{~"example:store/kv", ~"[constructor]bucket"} =>
                wasm_component:import_fun(
                  {[], handle},
                  fun([]) -> wasm_component:host_new(bucket, #{}) end)}.
```

- `resource_limit` in the `instantiate/3` options caps how many are live; past
  it, `host_new/2` traps `resource_limit_reached`.
- On the linked path a dropped host resource runs `resource_predrop` (which may
  veto with a trap) and then `resource_closer`, so an OS handle closes at once.
- `destroy/2` sweeps every live host handle in the process with its closer.
  That is why the contract is one live instance per process.

## The async ABI

`wasm_async` runs the async Canonical ABI with the BEAM as its executor: the
process running the call is the task, a wait is a selective `receive`, and a
producer signals readiness with a message. All task state is in the process
dictionary, one task per process.

`wasm_component:call_async/4`:

1. Find `[async-lift]<export>` (or `[async-lift]<export>#<fn>`) on any core,
   and its `[callback]<lift>`.
2. `wasm_async:begin_task/2`, then lower the arguments. A `future`/`stream`
   argument becomes the readable end of a waitable: filled at once, queued with
   `{ready_before, V}`, or fed by `{producer, Fun}`.
3. Call the lift and decode its status, `code | (set << 4)`: EXIT takes the
   `task.return` value, YIELD re-enters the callback with no event, WAIT calls
   `wasm_async:wait_on_set/1` and re-enters the callback with the event.
4. `wasm_async:end_task/0` stops producers and flushes stale messages.

The loop is bounded by a turn budget. A lift with no callback (the stackful
form) answers `{error, async_stackful_unsupported}`.

On the import side, the linker binds each async canon built-in with
`wasm_async:builtin/2`. An imports map value of `{async_import, Sig, Fun}`
becomes `wasm_async:async_lower/2` (completes at once);
`{async_import, Sig, Fun, {producer, PFun}}` becomes `wasm_async:async_lower/3`
(the subtask starts, and completes when the producer says so).

## Where to add things

**A host import.** Wrap a typed function with `wasm_component:import_fun/2`
and key it `{Interface, Field}`, without the version. It lifts the guest's flat
arguments, calls your fun with terms, and lowers the result, by memory when the
result is wider than one flat value.

```erlang
Clock = #{{~"example:host/clock", ~"now"} =>
              wasm_component:import_fun({[], u64},
                                        fun([]) -> erlang:system_time() end)},
Imports = maps:merge(wasi_preview2:imports(), Clock).
```

A WASI interface belongs in `wasi_preview2`, merged into what its `imports/0`
returns. If the import returns a resource, mint it with `host_new/2` and provide
its `[resource-drop]` too.

**A canonical type.** Every layer has to agree on it:

1. `wasm_canon`: add it to `desc()`, then to `flat_types/1`, `size_align/1`
   and the private lower, lift, store and load clauses.
2. `wasm_component_types`: decode its type byte in `valtype`, so lift
   validation, bridges and handle checks see it.
3. `wasm_component`: if it can contain a handle, add a `walk` clause.
4. Add a case to `wasm_component_vectors_SUITE` (the `vectors` fixture is
   rebuilt by `scripts/build-component-fixture.sh`) and a generator to
   `wasm_canon_prop_SUITE`.

### The tests

| Suite | Covers |
| --- | --- |
| `wasm_component_SUITE` | decode, instantiate, call, the ok and error arms of a `result` |
| `wasm_component_vectors_SUITE` | lift and lower of every WIT type at edge values, spill, bad discriminants |
| `wasm_canon_prop_SUITE` | generated values round-trip through the Canonical ABI |
| `wasm_component_string_SUITE` | the utf16 and latin1+utf16 encodings |
| `wasm_component_import_SUITE` | host imports by `{Interface, Field}`, `import_fun/2`, a missing import |
| `wasm_component_version_SUITE` | a versioned import resolves to a bare host key |
| `wasm_component_link_SUITE` | core-to-core linking, teardown, named link errors |
| `wasm_component_compose_SUITE` | nested components, bridges, `wac` output with a string and a resource |
| `wasm_component_resource_SUITE` | handle checks, destructors, `drop_resource/3`, destroy |
| `wasm_resources_SUITE` | the handle table directly |
| `wasm_component_async_SUITE` | futures, streams, producers, suspend and resume |
| `wasm_component_async_import_SUITE` | async host imports, immediate and suspending |
| `wasm_wasi2_async_SUITE` | `call_async/4` against wasmtime's async fixture |
| `wasm_component_malformed_SUITE` | truncation and corruption are values |
| `wasm_component_worker_SUITE` | a component through the worker kernel |
| `wasm_recipe_SUITE` | the build plan, and one gated real build |

Run the component suites:

```sh
for s in wasm_component_SUITE \
         wasm_component_vectors_SUITE \
         wasm_canon_prop_SUITE \
         wasm_component_string_SUITE \
         wasm_component_import_SUITE \
         wasm_component_version_SUITE \
         wasm_component_link_SUITE \
         wasm_component_compose_SUITE \
         wasm_component_resource_SUITE \
         wasm_resources_SUITE \
         wasm_component_async_SUITE \
         wasm_component_async_import_SUITE \
         wasm_component_malformed_SUITE; do
    rebar3 ct --suite="test/$s" || break
done
```

Then the full `rebar3 ct`: the `wasm_wasi2_*` suites exercise the same code
through real WASI 0.2 programs, and the wasmtime fixtures skip unless
`scripts/build-wasmtime-p2.sh` has built them.

## Read this next

[Components](components.md) for the caller's side, [WASI 0.2](wasi-0-2.md) for
the host a component imports, and [Architecture](architecture.md) for where
these modules sit in the whole.
