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
| `wasm_component_types` | the signatures read from the component's whole type space (every type section, import and alias): lift checks, bridges, handle checks | `type_space/1` |
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

### How a component's shape picks its instantiate path

A component has one of three shapes, and each shape has its own path through
`wasm_component`:

| Shape | Recognised by | Path |
| --- | --- | --- |
| single core | one core, or every export lifts from the largest core and the host covers its imports | `start`: one `wasm:instantiate/3` |
| linked cores | the entry core imports from another core, or an export lifts from a core other than the largest | `link_in`, then `wasm_component_link:link/4` |
| composed | no top-level core (nested components, as `wac` emits) | `instantiate_composed` |

The entry core is the largest core, because a resource or WASI component
puts smaller shim and adapter cores next to the guest. If two cores have the
same size, the first one wins, so the choice is always the same.

The decision, with the private functions that make it:

```text
  instantiate/3
     |
  instantiate_decoded
     |-- no top-level core? -- yes --> instantiate_composed
     |                                   compose_step for each graph item;
     no                                  a nested component goes through
     |                                   instantiate/3 again
  validate_lifts/2
     |
  instantiate_valid
     |  resolve the entry core's imports: host map, then resource built-ins
     |
     |-- every import resolved, and on_entry? -- yes --> start
     |     on_entry: one core, or every export             one core,
     |     resolves on the entry core                      wasm:instantiate/3
     no
     |
  link_in --> wasm_component_link:link/4   every core, one shared store
```

`on_entry` is computed once by `prepare/1` and read from the prepared
component after that. The single-core and linked paths both end in
`with_export_map`, which records the per-export tables `call/4` reads. On
every path, `snapshotable => true` also keeps what the instance was built
from (`with_recipe`), so a restore can take the same path again.

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
   A component from `prepare/1` was decoded already: it carries what steps 3
   and 4 and the linker would compute from the bytes (the checked lifts, the
   resource info, the entry core's imports, the export map, encodings and
   bindings, the destructors, the parsed graph and, for an async component,
   the type space), and they are read instead of computed.
3. `wasm_component_link:validate_lifts/2`. Each `canon lift` declares a
   component type. The Canonical ABI computes a core signature from that type,
   and the core function must have exactly that signature. If it does not,
   the result is `{error, {invalid_lift_type, _}}`, before any start function
   runs.
4. `wasm_component_link:resource_info/2` reads each export's real signature,
   the resource types the component defines, the type each resource built-in
   acts on, and each destructor's export name.
5. Resolve the entry core's imports. `host_key` turns
   `wasi:io/streams@0.2.0` into `wasi:io/streams`, because the host map uses
   keys without a version. A `0.3.x` version is the exception: it becomes
   `@0.3` (`wasi:cli/stdout@0.3.0` into `wasi:cli/stdout@0.3`), and nothing
   else, so a 0.3 import never binds a 0.2 function. A host function you pass
   yourself wins over a resource built-in that the runtime adds
   automatically. An `{async_import, ...}` value is bound as the linker binds
   it.
6. Pick the path. If any import is still unresolved, the component goes to
   the linker. A component with several cores also goes to the linker when
   one of its functions is lifted from another core
   (`wasm_component_link:exports_resolve_on_entry/3`). For an interface's
   function, that counts only when the entry core exports a function of the
   same name, since a call by name would then reach the wrong one. This is
   decided once, when the component is prepared.
7. Build the cores with a new `wasm_resources` table set as current. So when a
   start function creates a handle, the handle belongs to this instance.
8. Record per-export string encodings (`export_encodings/1`) and the declared
   realloc and post-return (`export_bindings/1`) on the instance, for
   functions exported on their own and for an interface's functions.

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

### The host resource table

The host resource table holds every resource the host defines for a
component: what a host function returns as an `own` handle, such as a
stream, a file descriptor, a socket or an HTTP request. It lives in
`wasm_component` (`host_new/2`, `host_new/3`, `host_get/1`, `host_update/2`,
`host_drop/1`, `host_live/0`). Read this before you add a host resource or
change how one is freed or captured.

**Who uses it.** The WASI hosts: `wasi_preview2`, `wasi_p2_filesystem`,
`wasi_p2_sockets` and `wasi_http` for 0.2, and `wasi_p3_sockets` and
`wasi_p3_http` for 0.3. A method looks its handle up with `host_get/1`,
changes its state with `host_update/2`, and `[resource-drop]` calls
`host_drop/1`. Your own host imports can use it the same way.

**Where it lives.** In the process dictionary of the process that owns the
instance, because host functions run in that process. It is one map,
`Handle => {Tag, State}`, for the whole process: every component instance in
the process shares it.

**How long an entry lives.** Until `host_drop/1`, or until
`wasm_component:destroy/1,2`, which removes every live entry in the process
and, with `destroy/2`, closes each one with the closer you pass first. Nothing
else frees an entry, except the process exiting. So run one live component
instance per process, and destroy it from that process: the worker kernel
does this with one instance per runner.

**The handle counter.** Handles start at 1 and each `host_new/2` takes the
next one. The counter is never reset, not even by `destroy`, so a handle is
never given twice in one process. It is separate from the counter of
`wasm_resources`, so a guest handle and a host handle can have the same
number; the handle's resource type decides which table it is looked up in.

**The limit.** `resource_limit` in the `instantiate/3` options sets how many
entries may be live in the process at once. Each `instantiate/3` sets it
again. Above it, `host_new/2` traps with `resource_limit_reached`, so a guest
that never drops what it opens cannot use up the host's memory.

**Snapshots.** `wasm_component:snapshot/2` keeps a host entry only when the
host said where it came from and it has not changed since:

1. `host_new/3` records an origin with the entry, such as `{stdio, stdout}`
   or `{preopen, Name}`. WASI 0.2 gives one to its stdio streams and its
   preopened directories, and to nothing else.
2. At capture, an entry with no origin, or whose state differs from the
   state it was made with, refuses the snapshot with
   `host_resource_not_snapshottable`. The image keeps each other entry as
   `{Handle, Tag, Origin}`, and the counter.
3. `wasm_component:restore/3` calls the `host_remake` fun you pass (for
   example `wasi_preview2:host_remake/1`) with each origin, and puts the new
   entry under the same handle, because the guest still holds that number.
   It then raises the counter to at least the captured value. An image with
   entries and no `host_remake` fails with `host_remake_missing`.

## The async ABI

`wasm_async` runs the async Canonical ABI on the BEAM's own scheduling. The
process that owns the instance runs its tasks. A wait is a selective
`receive`. A producer sends a message when its value is ready. All task state
is in the process dictionary.

A *frame* holds the handles, sets, producers and pending tasks of the
instance's calls. A call that finds a frame open with work in it, pending tasks
or ends the host holds, joins it. Otherwise it opens its own, and a call made
from inside a host function sets the outer frame aside, as before. Ending a
call tears the frame down only when nothing is pending and the host holds no
end; `destroy/1` tears it down whatever is left.

A task can resolve (`task.return`) before it finishes. `start_async/5` returns
at that point and records the task's callback, status, budget and context
slots. `pump/2` and the host-end calls give pending tasks their turns:

1. Take in what producers have sent.
2. Give a callback turn to the first task that can take an event, restoring
   its own context slots first.
3. Otherwise wait for a producer. With no producer left, nothing can change:
   `pump/2` answers `idle`, and a host read or write answers
   `{error, async_deadlock}`.

The host's ends: `host_reader/1` (the default for a started call's returned
stream) reads with the same 1024-element bound as two guest ends;
`host_sink/2` passes each write on as it happens; `host_stream/1` and
`host_future/1` make a pair whose writer the host keeps. `on_end/2` gives a
readable end the host made a hook, run once when the guest drops it or the
task's frame ends with it open; `wasi_p3_sockets` closes a connection that
way once its last stream is gone. The host-end calls that run tasks answer
`{error, reentrant}` inside a guest call.

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
4. `wasm_async:end_task/0` ends the frame when no task has work left: every
   sink still open is told the stream ended, every `on_end` hook runs, then
   the producers stop and old messages are removed.

The loop stops after a maximum number of turns. A lift with no callback (the
stackful form) is one call: the core function runs the whole task, waits
inside `waitable-set.wait` or a copy declared without `async`, and hands its
result to `task.return`.

Each stream or future end is idle, copying or done, as the specification has
it. The element type comes from the type the built-in names, and each element
is lifted and lowered at its size; a `stream<u8>` stays a binary.

- A copy declared `async` that cannot complete returns BLOCKED and is
  delivered later as an event; one declared without `async` waits in place.
- A second read of a future, a cancel with no copy pending, and dropping an
  end while it copies trap. So does dropping a future's writer before it has
  written.
- A stream holds at most 1024 elements between a writer and a reader that has
  not taken them. A write past that blocks until the reader makes room. A
  stream the guest returned has the host as its reader, which takes each write
  whole: limit such a guest with `fuel` or a timeout, as you would any loop.
- A wait that no producer can end traps with `async_deadlock`; there is no
  time limit. A producer that fails while a copy needs it traps the wait.
- `subtask.cancel` stops a host import's producer at once. A stackful
  callee is asked instead: the call answers BLOCKED, the callee's next
  cancellable yield, suspend or switch returns 1, and its `task.cancel`
  resolves the subtask as cancelled. `task.cancel` traps when nothing asked.
  `subtask.drop` needs the subtask resolved.
- `thread.yield` in a stackful callee lets its caller run, as any wait does.
- `stream.forward` turns the readable end into a sink that hands each write
  on to the writable end's reader, and ends it when it ends; both handles
  leave the guest. Forwarding a stream into its own writable end, or into one
  nobody reads, drops both. `future.forward` does the same for one value.
- Every async and thread built-in traps with `cannot_leave` while its
  instance runs a `realloc` or a `post-return`, as the specification's
  `may_leave` has it.
- `backpressure.inc` and `dec` count per instance. A task runs in its caller's
  process, so a call that arrives while the count is above zero returns
  `{error, async_backpressure}` instead of waiting for ever.
- A trap's reason is in the error's `ctx`, under `reason`.

### Cooperative threads

A component instance's threads take turns; one runs at a time. A thread is
suspended (only another thread resumes it), ready (the scheduler may run it),
waiting (for an event) or running. Each instance has its own threads table,
numbered from 1; `thread.index` gives the running thread's number.

```text
 owner process (holds the frame, runs the scheduler)
   |  T1, the task's implicit thread, runs here or in a fiber
   |
   |  T1 calls thread.suspend-then-resume(2)
   |    -> T1 suspended; the built-in runs the scheduler in place
   |    -> T2 starts: a process of its own, calling its built-ins here
   |
   +--> T2 calls thread.yield-then-resume(1)
            -> T2 ready, its call unanswered; T1 picked: the built-in returns
```

- A task's implicit thread runs where the task runs, in the owner or in a
  fiber. When it stops, the built-in it called runs the other threads, and
  returns once the scheduler picks it again.
- An explicit thread, from `thread.new-indirect`, is a process that calls
  its start function and calls its built-ins through the owner, as a fiber
  does. It stops by waiting for the answer to one of them.
- Ready threads run oldest first; a waiting thread runs once its event has
  come.
- When nothing can run, a fiber's task gives its caller the turn, as a wait
  does, and goes on once one of its threads can. A synchronous call traps
  with `async_deadlock`.
- An instance's globals are read once per call and written back at its end.
  A switch commits the running thread's state first, and the thread that
  resumes reloads it, so every thread sees the others' writes.
- `wasm_component:destroy/1` stops the instance's threads.

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

A small, stateless WASI 0.2 interface belongs in `wasi_preview2`, merged into
what its `imports/0` returns. A larger one has a module of its own, as
`wasi_p2_filesystem`, `wasi_p2_sockets` and `wasi_http` do, and
`wasi_preview2:command/1` merges its map. A WASI 0.3 interface goes in
`wasi_preview3`, or in a module beside `wasi_p3_filesystem`, `wasi_p3_sockets`
and `wasi_p3_http`, merged by `wasi_preview3:command/1`. Its interface names
keep the version, as in `~"wasi:sockets/types@0.3"`. If the import returns a
resource, create it with `host_new/2` and also provide its `[resource-drop]`.

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
| `wasm_component_version_SUITE` | a versioned import resolves to a bare host key, a 0.3 import to its own, an async import off the linker |
| `wasm_component_link_SUITE` | core-to-core linking, teardown, named link errors |
| `wasm_component_compose_SUITE` | nested components, bridges, `wac` output with a string and a resource |
| `wasm_component_resource_SUITE` | handle checks, destructors, `drop_resource/3`, destroy |
| `wasm_resources_SUITE` | the handle table directly |
| `wasm_component_async_SUITE` | futures, streams, producers, suspend and resume |
| `wasm_component_async_import_SUITE` | async host imports, immediate and suspending |
| `wasm_component_async_abi_SUITE` | each async built-in and trap, stackful lifts, typed payloads |
| `wasm_component_async_tasks_SUITE` | tasks that outlive their call, two at once, the host's ends, `on_end` on drop and at teardown |
| `wasm_wasi2_async_SUITE` | `call_async/4` against wasmtime's async fixture |
| `wasm_component_malformed_SUITE` | truncation and corruption are values |
| `wasm_component_iface_SUITE` | an interface's functions called as their `canon lift` declares: post-return, string encoding and realloc |
| `wasm_component_forward_SUITE` | `stream.forward` and `future.forward` |
| `wasm_component_wast_SUITE` | wasmtime's test scripts for the cooperative thread built-ins |
| `wasm_component_snapshot_SUITE` | `snapshot/2` and `restore/3` of a component, with one core and with linked cores |
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
         wasm_component_async_abi_SUITE \
         wasm_component_async_tasks_SUITE \
         wasm_component_malformed_SUITE \
         wasm_component_iface_SUITE \
         wasm_component_forward_SUITE \
         wasm_component_wast_SUITE \
         wasm_component_snapshot_SUITE; do
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
