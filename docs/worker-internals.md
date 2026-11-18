# Worker internals

This page explains how the worker kernel is built. Read it when you want to
change the kernel. To use it, read [Hosting scripting
languages](scripting.md). For every setting, read [Worker
configuration](worker-reference.md). Short definitions of the terms are in
the [glossary](concepts.md#glossary).

## The modules

Three of the processes a request uses (the worker, the guardian and the
runner) are written in one module, `wasm_script_worker`. Its module doc has a
table of where each one's entry and loop are.

| module | what it is |
| --- | --- |
| `wasm_script_worker`, the **worker** part | the API and the `gen_server`. It accepts one request at a time, fixes its deadline and never blocks. |
| `wasm_script_worker`, the **guardian** part | one process per request. It traps exits, owns the mounts and the deadline, starts the runner and hands cleanup on. |
| `wasm_script_worker`, the **runner** part | one process per request (or the worker's own runner with `restore_ahead`). The only process that touches the tenant's data: it instantiates or restores, invokes, decodes and destroys. |
| `wasm_worker_adapter` | the behaviour an adapter implements, and the types its callbacks use. |
| `wasm_script_v1` | the `script_v1` profile the shipped adapters share: one source, a JSON context, `main(context)`, a JSON result. The kernel knows none of it. |
| `wasm_worker_fs` | the file operations of a request, done in the calling process instead of through `file_server_2`, which every request on the node would otherwise wait for. |
| `wasm_worker_images` | the images script workers share: one per adapter, options and store key, for the whole node. |
| `wasm_worker_error` | the worker's own error type and the closed set of kinds it can carry. |
| `wasm_instance_worker` | the simple worker: one instance, one process, a deadline. It does not use the kernel. |
| `wasm_worker_reaper` | one per node. It keeps the record of every request's cleanup, writes the journal and runs cleanup jobs when a request's owners are gone. |
| `wasm_cleanup_steward` | one per request. It carries the guardian's cleanup operations to the reaper without blocking, and keeps a numbered list of them (the ledger). |
| `wasm_cleanup_steward_sup` | the supervisor of the stewards. Its children are temporary. |
| `wasm_cleanup_manager` | one per node. It does no filesystem work. It keeps the operator view, decides whether a reaper can still be reached, and runs local cleanup when none can. |
| `wasm_worker_sup` | supervises the steward supervisor, the manager and the reaper, and builds the reaper's child spec. |
| `wasm_adapter_conformance` | the kit of cases every adapter must pass. |

All of these except `wasm_script_worker`, `wasm_worker_adapter`,
`wasm_worker_error`, `wasm_instance_worker` and `wasm_adapter_conformance` are
internal: they may change in any release.

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

- the **cleanup steward**, one per request, sends every cleanup operation to
  the reaper: reserve the request, register an action, withdraw it, or hand
  ownership over. It keeps a numbered list (a ledger) of these operations.
  The guardian starts it through `wasm_cleanup_steward_sup:start_steward/1`
  and monitors it;
- the **cleanup manager**, one per node, keeps the operator view, tells a
  steward whether a reaper can still be reached, and runs a request's
  cleanup itself, in a replacement steward, when no reaper can.

The whole picture, with who supervises, links and monitors whom:

```text
  your supervisor                 wasm_worker_sup, rest_for_one,
       |                          children started in this order:
       v                            1. wasm_cleanup_steward_sup
  worker (gen_server)                  (simple_one_for_one, temporary)
       | spawn_monitor              2. wasm_cleanup_manager
       v                            3. wasm_worker_reaper
  guardian
   traps exits, monitors the worker
       |
       |-- start_steward/1 ------> steward, one per request
       |   then monitors it          a child of wasm_cleanup_steward_sup
       |-- each operation ------>    numbers it in the ledger
       |                             pins one reaper and monitors it
       | spawn_opt                       |
       | [link, monitor]                 | reserve, then send_request
       v                                 v
  runner                          wasm_worker_reaper
   instantiate or restore,          monitors the guardian and the
   invoke, decode, destroy          steward of each request
                                    writes the journal on disk
                                    starts a cleanup job, spawn_opt
                                    [link, monitor], once the request
                                    is finished or both owners are gone:
                                      Adapter:cleanup/1, the actions,
                                      the request directory
                                         |
                                         | its operator view, by message
                                         v
                                  wasm_cleanup_manager
                                    monitors the reaper it tracks
                                    serves the operator view
                                    runs local cleanup in a replacement
                                    steward when no reaper can
```

With this split, a slow or restarting reaper cannot block a request or
lose its cleanup:

- **The guardian never waits.** It forwards each operation to the steward
  and goes back to its deadline loop. It keeps its own copy of every action
  until the reaper owns the cleanup.
- **The steward never waits either.** It sends with
  `gen_server:send_request/2` and handles each answer when it arrives. It
  numbers each operation, so the reaper recognises an operation sent twice.
  Only `reserve`, which runs at setup before the runner starts, is a plain
  call.
- **A reaper restart loses nothing.** The steward remembers which reaper it
  reserved with. When that reaper dies, its pending operations wait. The new
  reaper takes over the request when it scans its journal (its record on
  disk). The steward then gives it the ledger and sends the operations again.
  If no reaper comes back, the operation fails; it does not wait forever.
- **Cleanup is bounded.** The reaper refuses a reservation when it already
  holds `max_cleanup_jobs + cleanup_queue_len` requests, and runs at most
  `max_cleanup_jobs` cleanup jobs at once.

`wasm_worker_sup` starts the steward supervisor, the manager and the
reaper, in that order, with `rest_for_one`. So a manager restart also
restarts the reaper. `wasm_script_worker:cleanup_requests/0` lists the
requests whose cleanup is not finished.

### Who owns what while the cleanup migration is in progress

The cleanup work is moving from the reaper to the manager in stages, and
the move is not finished. The design record, `test/audit/CLEANUP_STEWARD.md`,
describes where it is going: the manager admits each request, grants every
cleanup job and holds the operator view. This table says what the code does
today. Change it when the code changes.

| job | owned today by | what the other side has |
| --- | --- | --- |
| refusing a request when cleanup is full | `wasm_worker_reaper`: `reserve/4` answers `cleanup_saturated` at `max_cleanup_jobs + cleanup_queue_len` requests | the manager computes the same number (`wasm_cleanup_manager:capacity/0`) and has `admit/1` and `release/1`, but nothing in `src/` calls them yet; only `wasm_cleanup_manager_SUITE` does |
| how many cleanup jobs run at once | the reaper, for its own jobs | the manager, for local cleanup and for an action past the per-request operation limit; the two counts are separate, each up to `max_cleanup_jobs` |
| the operator view | the reaper computes it | the manager serves the copy the reaper last pushed: `wasm_script_worker:cleanup_stats/0` and `cleanup_requests/0` read it, so they answer while the reaper is busy with its journal. Between a reaper's death and its replacement's first push they answer an empty view. `wasm_worker_reaper:stats/0` and `requests/0` still ask the reaper and wait for it; the conformance kit uses them |
| the journal | the reaper | nothing |
| starting a request's steward | the guardian | the manager starts only replacement stewards, for local cleanup |
| whether a reaper can be reached | the manager: `wasm_cleanup_manager:reaper/0`, which may start one through `wasm_worker_sup:ensure_reaper/0` | a steward asks it when its pinned reaper is gone |

The full protocol, with its state machines and the rules it keeps, is in
`test/audit/CLEANUP_STEWARD.md`.

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
hand. For them, `wasm_worker_sup:suspend_reaper/0` stops the supervised
reaper and prevents a worker start from starting another one, until
`wasm_worker_sup:resume_reaper/0`.

## Why `max_heap_words` is applied at spawn

`max_heap_words` in a limits map is set with `spawn_opt` when the runner is
created. It is not set with `process_flag` inside the runner: the closure and
the request are copied onto the new heap before such a call could run. If
you call the guest inline, passing the key does nothing.

## Why a reactor uses compiled code from its first request

A reactor makes a new instance for each request. If an instance could adopt
compiled code only on a call where the tier's hotness counter fires, one call
in 32, then 31 requests in 32 would run interpreted while the compiled code was
already loaded. So `wasm_jit`'s `maybe_adopt` first looks for loaded code, and
reads the counter only when there is none: an instance uses compiled code from
its first call. The measurements are in `test/audit/PERF.md`, section "Where a
QuickJS request actually goes", under "Adoption, separated from the compile
threshold".

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
- **One image per adapter, options and store key.** `wasm_worker_images`
  keeps the live images node-wide. A worker whose adapter, options and store
  key match a live image takes a hold on it. Workers that start while the
  first one loads or captures it wait for that build; a build that fails, or
  a builder that dies, passes to the next worker waiting. The registry holds
  no image: it watches each image's owner and forgets the image when the
  owner exits, after its last holder. Each worker restores the shared image
  with its own capability, so its bindings stay its own.

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
- **A worker on a shared image still loads its own artifact** this way. It
  shares only the image.

## Where to add things

**A new worker option.** Check it when the worker starts, on the `init/1`
path of `wasm_script_worker` (as `compiled` is checked), and refuse a bad
value with `{bad_option, Key, Why}`. Document it in
[Worker configuration](worker-reference.md) with its default. Every option is
part of the key `wasm_worker_images` shares an image under, so two workers
with different values never share one. A limit for the guest itself belongs
in the `limits` map, which the runner passes to the runtime; a limit for the
kernel (a deadline, a byte count) is a worker option.

**A new adapter callback.** Declare it in `wasm_worker_adapter` and add it
to `-optional_callbacks`, or every adapter that exists breaks. Call it
through `call_back/3` in `wasm_script_worker`, which turns an exception into
an error value. Add a case for it to `wasm_adapter_conformance`, so every
adapter is checked against it. Document it in
[Writing an adapter](worker-contract.md).

**A cleanup step.** Something a request leaves behind is registered as an
action through the guardian, so the steward and the reaper own it. Do not
delete it in the runner or the guardian on the way out: a killed process runs
no cleanup code. The action must be idempotent and safe to run twice at the
same time, because a reaper can die after it ran and before it recorded it. A
new kind of operation for the reaper also needs a journal record and a case in
`wasm_cleanup_steward_SUITE`; read `test/audit/CLEANUP_STEWARD.md` first.

## The tests

| suite | covers |
| --- | --- |
| `wasm_worker_kernel_SUITE` | the kernel through two adapters built from WAT at test time. It never skips, so it is the required gate. Its cases live in `wasm_adapter_conformance` |
| `wasm_worker_lang_SUITE` | the same kit against real QuickJS and Lua builds, metered, compiled and restored; skips without them. The Python groups run only by hand |
| `wasm_component_worker_SUITE` | a real component through the kernel |
| `wasm_worker_SUITE` | `wasm_instance_worker` against the sandboxing claims: loops, recursion, memory growth, a crashing host function, state between requests |
| `wasm_cleanup_steward_SUITE` | the guardian keeps its deadline while the reaper is slow, stuck or restarting |
| `wasm_cleanup_manager_SUITE` | the manager's capacity accounting |
| `wasm_worker_sup_SUITE` | the reaper as part of the application: configured roots, restarts, the created root |
| `wasm_lifetime_SUITE` | no helper process outlives the process responsible for it |
| `wasm_lang_SUITE` | QuickJS running real scripts |

Run the kernel gate and the cleanup suites:

```sh
for s in wasm_worker_kernel_SUITE wasm_cleanup_steward_SUITE \
         wasm_cleanup_manager_SUITE wasm_worker_sup_SUITE \
         wasm_lifetime_SUITE wasm_worker_SUITE; do
    rebar3 ct --suite="test/$s" || break
done
```

## Read this next

[Design notes](design-notes.md), then the adapter recipe in
[Recipes](contributing/recipes.md). `test/audit/CLEANUP_STEWARD.md` is the
design record of the cleanup protocol.
