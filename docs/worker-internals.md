# Worker internals

This page explains how the worker kernel is built. Read it when you want to
change the kernel. To use it, read [Hosting scripting
languages](scripting.md). For every setting, read [Worker
configuration](worker-reference.md). Short definitions of the terms are in
the [glossary](concepts.md#glossary).

## A request is three processes, not one

The worker kernel uses three processes for each request. Each one must
survive different failures:

- the **runner** is the only process that touches the tenant's data. It
  creates the instance, calls the guest, decodes the result, and then exits.
  It is started with `[link, monitor]`: the monitor sends a `DOWN` message
  with the exit reason, and the link kills the runner if the guardian dies;
- the **guardian** traps exits. It owns the mounts (the directories the guest
  can see) and the deadline. A `cancel` acts on this process;
- the **worker** is the API. It runs one request at a time.

One request, in order:

```text
caller          worker            guardian             runner
  |                |                  |                    |
  | run/2: submit  |                  |                    |
  |--------------->| fix the deadline |                    |
  |                | spawn_monitor -->| trap exits,        |
  |                |                  | monitor the worker |
  |                |                  | steward reserve:   |
  |                |                  | request directory  |
  |                |<- guardian_ready |                    |
  |<-- {ok, Ref} --|                  | spawn_opt          |
  | await          |                  | [link, monitor] -->|
  |--------------->|                  |                    | requirements
  |                |                  |<----- mounts ------| (made here)
  |                |                  |                    | prepare
  |                |                  |                    | instantiate
  |                |                  |                    |  or restore
  |                |                  |                    | invoke
  |                |                  |                    | decode
  |                |                  |                    | destroy
  |                |                  |<----- result ------|
  |                |                  | kill, await DOWN   x
  |                |<- guardian_done -|
  |<-- outcome ----|                  | steward complete:
  |                |                  | cleanup to the reaper
```

`run/2` is `submit/2` then `await/3`: two calls on the worker. So the worker
never waits for a request to finish. The guardian waits until the deadline
the worker set. Three things kill the runner, all in the same way: the
deadline, a `cancel`, or the death of the worker. The caller gets the
outcome before cleanup starts, so a slow cleanup never delays an answer.

With `restore_ahead => true`, the runner in this diagram is the worker's
own long-lived runner. It started before the request and has already
restored an instance. The guardian links to it, monitors it and sends it the
request. When the result arrives, the guardian unlinks it instead of killing
it. The runner then restores the instance for the next request.

A request can leave things behind: a directory, a staged file, a
registered cleanup action. The guardian owns all of them. When the request
ends, it hands them to the **reaper**, one process per node that cleans up.

The reaper is a process, not an ETS table with the worker as `heir`.
`wasm_worker_reaper` gives two reasons:

- `heir` acts when the table's *owner* dies. A table owned by the worker
  survives only when the worker dies, which is the one case where it is not
  needed;
- if cleanup waited for the worker's next request, files would stay as long
  as the worker is idle. For a tenant with little traffic, that time has no
  limit.

This design costs a little time, and it was measured. Accepting a request
takes 1.2 to 2.0 ms for any guest: the reservation, the request directory,
the output channels and starting the runner. That is a quarter of a Lua
request and 5% of a CPython one. Nobody has tried to make it smaller,
because nothing needs it yet.

## Cleanup goes through a steward

The guardian never talks to the reaper directly. Two more processes sit
between them:

- the **cleanup manager**, one per node, accepts each request and starts its
  steward;
- the **cleanup steward**, one per request, sends every cleanup operation to
  the reaper: register an action, withdraw it, or hand ownership over. It
  keeps a list (a ledger) of these operations.

```text
guardian --operations--> steward --send_request--> reaper (journal on disk)
                            ^
cleanup manager ------------+  admits the request, bounds how many
                               hold cleanup state, starts the steward
```

With this split, a slow or restarting reaper cannot block a request or
lose its cleanup:

- **The manager limits cleanup.** It accepts a request before the steward
  starts, only if there is room. The room is computed from the reaper's
  settings. So cleanup state cannot grow without limit while the reaper is
  slow or gone. The manager does no filesystem work.
- **The steward never waits.** It sends with `gen_server:send_request/2` and
  handles each answer when it arrives. It numbers each operation, so the
  reaper recognises an operation sent twice.
- **A reaper restart loses nothing.** The steward remembers which reaper it
  reserved with. When that reaper dies, its pending operations wait. The new
  reaper takes over the request when it scans its journal (its record on
  disk). The steward then gives it the ledger and sends the operations again.
  If no reaper comes back, the operation fails; it does not wait forever.

`wasm_worker_sup` starts the steward supervisor, the manager and the
reaper, in that order, with `rest_for_one`. So a manager restart also
restarts the reaper. `wasm_script_worker:cleanup_requests/0` lists the
requests whose cleanup is not finished. The full protocol, with its state
machines and the rules it keeps, is in `test/audit/CLEANUP_STEWARD.md`.

## The reaper is supervised, and knows which roots are its own

A **root** is a directory where request files go. `wasm_worker_sup` starts
the reaper. Only `reaper_spec/0` builds its child spec, so the application
start and a worker's first start always agree on the roots.

With `scratch_roots` configured, the reaper starts with the application. At
that moment a restarted node cleans up what a crashed node left. Each
journal record names the run of the node that wrote it (its incarnation). A
record from another run is an orphan, and the reaper removes its directory.
This is also why only one node at a time may use a configured root.

Without `scratch_roots`, the first `wasm_script_worker:start_link/2,3`
starts the reaper with one root, `scratch`. Its directory name contains the
node name, the OS process and a unique integer, so two running nodes never
share it. The path is fixed in the child spec, so after a reaper crash the
supervisor restarts it on the same directory and journal.

The list of roots the reaper created itself is a separate start argument.
Only the supervisor passes it; it is not a key in `reaper_options`. So no
configuration can mark one of your directories for deletion. A created root
is removed at a clean shutdown, and only when no reservation is left and its
journal is empty.

Several cases in `wasm_adapter_conformance` stop and restart a reaper by
hand. For them, `suspend_reaper/0` stops the supervised reaper and prevents a
worker start from starting another one, until `resume_reaper/0`.

## Why `max_heap_words` is applied at spawn

`max_heap_words` in a limits map is set with `spawn_opt` when the runner is
created. It is not set with `process_flag` inside the runner: the closure and
the request are copied onto the new heap before such a call could run. If
you call the guest inline, passing the key does nothing.

## Why reactors were slow to adopt compiled code

Until 0.3.0, a new instance could start using compiled code only on a call
where the tier's hotness counter fired: one call in 32. A reactor makes a new
instance for each request. So 31 requests in 32 ran interpreted, even though
the compiled code was already loaded. Now `wasm_jit`'s `maybe_adopt` first
looks for loaded code, and reads the counter only when there is none. An
instance uses compiled code from its first call. `test/audit/PERF.md` has the
numbers before and after.

## Why a request's memory is a page table over the worker's image

The runner restores the worker's image. The restored memory reads the
image's pages where they are, without copying them. So a request allocates
only two things: a page table (one entry per 4 KiB page, saying where that
page is) and the pages it writes. Those written pages live in the memory's
arena. When the runner exits, the arena goes back to the node and the image
stays with the worker.

Nothing has to pass from one request to the next. This is why the kernel no
longer reuses the memory of a destroyed instance. Reuse needed one process
to restore every request and a mark on every memory write, and workers
could not share it.

Two things a change here has to keep:

- **The image lives longer than every memory restored from it.** The
  keeper (`wasm_keeper`) records which processes hold each image. It counts
  each restored memory as a holder. So when a worker stops while a runner is
  still finishing, the pages the runner reads are not freed.
- **One image per pool, when the pool prepares it.** `prepare/2` loads or
  captures the image once, in its own process. Every worker started with
  `prepared` takes a hold on that one image. A worker started without it
  loads its own copy, so fifty such workers on one file hold fifty copies.

## Why sending an image copies almost nothing

An image is an Erlang term. A send or a spawn copies it into the process
that receives it, and the worker sends it to each request's runner. The
image's memory pages are binaries, and a copy shares a binary by reference
instead of copying its bytes.

Its tables used to be lists of `{funcref, Instance, Index}` tuples. A copy
does not share those, so every request copied them. Now a table that holds
only `null` and the instance's own functions is packed into one binary, with
a 32-bit word per entry. This happens at capture, and at load, where the file
decoder builds the words directly instead of a list first. A restore writes
the words straight into the new instance's table
(`wasm_table:init_funcrefs/3`). A table that holds anything else stays a
list, and the file stores lists as before.

For CPython, this reduces the copied image from 55,372 words to 1,747, and
a spawn that carries the image from 174 us to 5 us. `test/audit/PERF.md`,
section "One image for a pool", has the rest.

## Why the artifact is loaded in a process of its own

`Adapter:artifact/1` reads the module file: 30 MB for CPython. After it
starts, a worker does so little that the garbage collector rarely runs in
it. So when the worker called `artifact/1` itself, every idle worker kept a
reference to that file that it no longer used.

The kernel now calls `artifact/1` in a short-lived process. A **claim** is a
process's hold on a loaded module in the module cache. Before the
short-lived process exits, it lists its claims (`wasm_module_cache:claims/1`)
and takes each one again for the worker (`wasm_module_cache:claim_for/2`).
So the module always has a claim. Then the process exits, and the file
memory is freed with it. If the adapter raises an exception, the worker
raises it again, so a failed start looks the same as before.

Two things a change here has to keep:

- **Only claims pass to the worker.** Anything else the adapter tied to the
  calling process, such as an ETS table or a link, ends with that process.
  [Writing an adapter](worker-contract.md) says so too.
- **`prepare/2` runs the same steps.** In one temporary process, it loads the
  artifact, looks up the image, and captures it if it is not found. The
  process waits until the caller holds the image, then exits. A worker
  started from the result still loads its own artifact this way. It shares
  only the image.

## Read this next

[Design notes](design-notes.md), then the adapter recipe in
[Recipes](contributing/recipes.md).
