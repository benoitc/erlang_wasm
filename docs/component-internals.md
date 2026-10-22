# Component internals

This page explains how the Component Model is implemented. It is for you
when you change that code, not when you use it. Read it before you change
decoding, linking, the Canonical ABI, resource handles or the async ABI, or
when you add a host import or a value type. To use components, read
[Components](components.md). This page does not repeat it.

## The words on this page

| word | what it means here |
| --- | --- |
| **core** | one core WebAssembly module inside a component, or an instance of it. |
| **lower** | convert an Erlang term into core values and guest memory, to pass it to the guest. |
| **lift** | convert core values and guest memory back into an Erlang term. A `canon lift` also declares a component export. |
| **flat value** | one core number (`i32`, `i64`, `f32`, `f64`) after a typed value is split into numbers. |
| **spill** | when a value has too many flat values, it is stored in guest memory and passed as one pointer. |
| **realloc** | the guest function the host calls to allocate guest memory for strings and lists. |
| **post-return** | a guest function the host calls after it reads a result, so the guest can free that memory. |
| **representation** (rep) | the guest's own value behind a resource handle, usually a pointer. |
| **shim**, **adapter** core | small helper cores that toolchains add next to the guest core, for example to turn preview 1 calls into preview 2. |
| **store** | the shared state that lets several cores use the same memory and tables. |
| **waitable** | something an async task can wait on: a subtask, a future or a stream end. |

Words used by both pages, such as resource and handle, are in
[Components](components.md) and in the [glossary](concepts.md#glossary).

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

The runtime does not use `wasm_recipe`. It turns a recipe map into `cargo`
and `wasm-tools` commands, so that an embedder (hornbeam) can build its
components without a shell script. Nothing in `src/` calls it.

## From bytes to a running instance

`wasm_component:decode/1` checks the layer-1 header (`00 61 73 6d 0d 00 01
00`) and reads the top-level sections once. It keeps the core modules
(section 1), the export names (section 11, collected from every such section)
and the raw sections for later. It parses the graph of instances only when it
is needed.

A component then has one of three shapes:

| Shape | Recognised by | Path |
| --- | --- | --- |
| single core | one core, or every export lifts from the largest core and the host covers its imports | `start`: one `wasm:instantiate/3` |
| linked cores | the entry core imports from another core, or an export lifts from a core other than the largest | `wasm_component_link:link/4` |
| composed | no top-level core (nested components, as `wac` emits) | `instantiate_composed` |

The entry core is the largest core, because a resource or WASI component
puts smaller shim and adapter cores next to the guest. If two cores have the
same size, the first one wins, so the choice is always the same.

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

1. Split the options. `loader`, `resource_closer`, `resource_predrop` and
   `resource_limit` are read here. All other options are limits for the core
   instances.
2. Decode inside `wasm_error:capture/1`, so a malformed component is a value.
3. `wasm_component_link:validate_lifts/2`. Each `canon lift` declares a
   component type. The Canonical ABI computes a core signature from that type,
   and the core function must have exactly that signature. If it does not,
   the result is `{error, {invalid_lift_type, _}}`, before any start function
   runs.
4. `wasm_component_link:resource_info/2` reads each export's real signature,
   the resource types the component defines, the type each resource built-in
   acts on, and each destructor's export name.
5. Resolve the entry core's imports. `strip_version` turns
   `wasi:io/streams@0.2.0` into `wasi:io/streams`, because the host map uses
   keys without a version. A host function you pass yourself wins over a
   resource built-in that the runtime adds automatically.
6. Pick the path. If any import is still unresolved, the component goes to
   the linker. A component with several cores also goes to the linker when
   some of its exports are not on the entry core
   (`wasm_component_link:exports_resolve_on_entry/2`).
7. Build the cores with a new `wasm_resources` table set as current. So when a
   start function creates a handle, the handle belongs to this instance.
8. Record per-export string encodings (`export_encodings/1`) and the declared
   realloc and post-return (`export_bindings/1`) on the instance.

A failed build destroys the resource table it created.

### Linking several cores

`wasm_component_link:parse/1` turns the sections into an ordered list of
items. `link/4` goes through the list in order. It numbers each kind of item
separately, as the specification does: core instances, core funcs, memories,
tables, globals, component instances and component funcs.

- `{core_instance, {instantiate, Mod, Args}}`: build the core. Each import
  namespace comes from the instance that its `with` argument names, or from
  the host if there is none. Every core after the first is built with
  `#{link => Anchor}`. So all cores share one store, and one core can use the
  memory or table of another.
- `{core_alias, Sort, Inst, Name}`: take an export out of a built instance
  with `wasm:extern/2`. A func alias also records its instance. That instance
  becomes the call target of the export.
- `canon lower`: make a host function (from the imports map) into a core
  function. It uses the realloc and string encoding of that `canon lower`, and
  runs with the guest instance as its context.
- `canon lift`: add a component func. The encoding is checked here.
- `canon resource.new | rep | drop` and the async built-ins: see below.

The entry is the core that exports `wasi:cli/run...#run` (a command).
Otherwise it is the instance of the largest module (a reactor). If a link
fails in the middle, it destroys every core it built.

The preview1 adapter needs no special code. It has a startup cycle: the guest
core imports adapter functions, and the adapter needs the guest's memory and
realloc. The component itself breaks this cycle. A shim core exports a table
of placeholder functions for indirect calls, and a fixup core fills that table
when both sides exist. The linker builds those instances in graph order.
Because the cores share one store, the guest calls through the same table that
the fixup core filled.

### Composed components

`instantiate_composed` goes through the graph with `compose_step`. Each nested
component is instantiated by calling `instantiate/3` again. An instantiate
argument can connect one of its imports to an interface that another nested
component exports. Then each function of that interface gets a *bridge*: an
`import_fun/2` wrapper that calls `call/4` on the component that provides it.
Values pass as Erlang terms, and each side keeps its own memory. The signatures
come from the nested component's own type section, through
`wasm_component_types:import_interfaces/1`.

`call/4` on a composed instance looks the export up in `dispatch` and calls the
sub-instance. If an export only comes from an imported interface, the call
returns `{error, {unresolved_export, Name}}`.

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

- **Target.** The linker's `export_targets` is used first, because two cores
  can export the same name. Next, the export map gives the core function's
  name. Last, the runtime uses the export's own name on the core that has it.
- **Lowering.** Up to 16 flat values (`MAX_FLAT_PARAMS`) are passed directly.
  With more, the parameters are stored in guest memory as one tuple, and one
  pointer is passed. Strings and lists are written into memory allocated by
  the realloc that the lift declares. If it declares none, the guest's
  `cabi_realloc` export is used.
- **Lifting.** A result of one flat value comes from the core results. A
  larger result is read from the pointer that the guest returned, after an
  alignment check.
- **Post-return.** The runtime runs the function that the lift declares. It
  does not look for `cabi_post_<export>` by name. A trap in it fails the call.

### Handles at the boundary

The export's real signature, from the component's type space, decides how
handles are passed. The descriptors the caller passed do not change this. So
`{[u32], u32}` for a method is checked exactly like `{[{borrow, 0}], u32}`.

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

A handle of a type that another component defines (a WASI stream, for
example) is passed without change. Lent handles are given back when the call
ends, when it traps, or when a check fails during lowering.

## Resources and host handles

There are two tables, for two kinds of resource.

**`wasm_resources`: resources the guest defines.** One table per component
instance, in the process dictionary of the process that owns the instance.
Handles start at 1 and are never reused while the instance lives. Each entry is
`{Rt, Rep, Owner}`, with `Owner` one of `guest`, `host` or `{lent, N}`.

- The guest side (`new/2`, `rep/2`, `drop/2`) acts on the current instance,
  the one that `with_instance/2` set. When no instance is current, they
  return the value unchanged.
- The host side (`host_*`) names the instance explicitly.
- A failed check throws `resource_not_live`, `resource_wrong_type` or
  `resource_borrowed` through `wasm_error:trap/2`.
- The guest reaches the table through the resource built-ins. On the
  single-core path they are core imports named `[resource-new]...`,
  `[resource-rep]...` and `[resource-drop]...`, bound in `resource_imports`. On
  the linked path they are `canon resource.*` items bound in `step`.
- A guest drop of a defined resource runs `<iface>#[dtor]<res>` with the
  representation. `drop_resource/3` does the same for a host-held handle.
- Between composed components, an `own` that the provider returns stays in
  the provider's table. The consumer gets an `imported` entry whose
  representation is `{remote, ProviderId, Handle, Release}`. Dropping it runs
  `Release`, which drops the resource in the provider.
- `destroy/1` discards the table. No destructor runs.

**Host handles: resources the host defines.** `host_new/2`, `host_get/1`,
`host_update/2` and `host_drop/1` keep `{Tag, State}` in a per-process map,
separate from the guest table. WASI 0.2 streams, files, sockets and HTTP
objects live here. A host function creates one when it returns an `own`. The
`[resource-drop]` function in the host map removes it.

```erlang
Imports = #{{~"example:store/kv", ~"[constructor]bucket"} =>
                wasm_component:import_fun(
                  {[], handle},
                  fun([]) -> wasm_component:host_new(bucket, #{}) end)}.
```

- `resource_limit` in the `instantiate/3` options limits how many host
  handles can be live. Above it, `host_new/2` traps with
  `resource_limit_reached`.
- On the linked path, dropping a host resource runs `resource_predrop` (which
  can refuse the drop with a trap) and then `resource_closer`. So an
  operating system handle is closed at once.
- `destroy/2` closes every live host handle in the process with its closer.
  This is why the rule is one live instance per process.

## The async ABI

`wasm_async` runs the async Canonical ABI on the BEAM's own scheduling. The
process that runs the call is the task. A wait is a selective `receive`. A
producer sends a message when its value is ready. All task state is in the
process dictionary, and there is one task per process.

`wasm_component:call_async/4`:

1. Find `[async-lift]<export>` (or `[async-lift]<export>#<fn>`) on any core,
   and its `[callback]<lift>`.
2. `wasm_async:begin_task/2`, then lower the arguments. A `future` or
   `stream` argument becomes the readable end of a waitable. It is filled at
   once, queued with `{ready_before, V}`, or fed by `{producer, Fun}`.
3. Call the lift and decode its status, `code | (set << 4)`. EXIT takes the
   `task.return` value. YIELD calls the callback again with no event. WAIT
   calls `wasm_async:wait_on_set/1` and calls the callback again with the
   event.
4. `wasm_async:end_task/0` stops producers and removes old messages.

The loop stops after a maximum number of turns. A lift with no callback (the
stackful form) returns `{error, async_stackful_unsupported}`.

On the import side, the linker binds each async canon built-in with
`wasm_async:builtin/2`. An imports map value of `{async_import, Sig, Fun}`
becomes `wasm_async:async_lower/2` (completes at once);
`{async_import, Sig, Fun, {producer, PFun}}` becomes `wasm_async:async_lower/3`
(the subtask starts, and completes when the producer reports it is done).

## Where to add things

**A host import.** Wrap a typed function with `wasm_component:import_fun/2`
and use the key `{Interface, Field}`, without the version. The wrapper lifts
the guest's flat arguments, calls your fun with terms, and lowers the result.
It passes the result through memory when it is larger than one flat value.

```erlang
Clock = #{{~"example:host/clock", ~"now"} =>
              wasm_component:import_fun({[], u64},
                                        fun([]) -> erlang:system_time() end)},
Imports = maps:merge(wasi_preview2:imports(), Clock).
```

A WASI interface belongs in `wasi_preview2`, merged into what its `imports/0`
returns. If the import returns a resource, create it with `host_new/2` and also
provide its `[resource-drop]`.

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

Then run the full `rebar3 ct`. The `wasm_wasi2_*` suites test the same code
with real WASI 0.2 programs. The wasmtime fixtures skip unless
`scripts/build-wasmtime-p2.sh` has built them.

## Read this next

[Components](components.md) for the caller's side, [WASI 0.2](wasi-0-2.md) for
the host a component imports, and [Architecture](architecture.md) for where
these modules sit in the whole.
