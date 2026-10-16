# Worker internals

How the worker kernel is built, for someone changing it rather than using it.
To use it, read [Hosting scripting languages](scripting.md); for every
setting, [Worker configuration](worker-reference.md).

## A request is three processes, not one

The worker kernel gives each request a **worker**, a **guardian** and a
**runner**, and the split is about who can be trusted to survive what.

The runner is the only process that touches tenant data: it instantiates,
invokes, decodes and dies. It is spawned `[link, monitor]` so that the monitor
delivers a `DOWN` carrying the exit reason, and the link kills it if the
guardian goes. The guardian traps exits, owns the mounts and the deadline, and
is the process a `cancel` acts on. The worker is the API and holds the single
in-flight slot.

Everything a request can leak -- a directory, a staged file, a registered
cleanup action -- is owned by the guardian and handed to a node-wide **reaper**
when the request ends. That reaper is a process and not an ETS table with the
worker as `heir`, for two reasons `wasm_worker_reaper` states: `heir` fires when the
*owner* dies, so a worker-owned table survives exactly the failure it is not
needed for; and deferring the sweep to the worker's next request leaks for as
long as that worker is idle, which for a lightly used tenant has no bound.

The cost of that shape is measurable and small. Accepting a request -- the
reservation, the request directory, the channels and the runner spawn -- is
1.2 to 2.0 ms whatever the guest, which is a quarter of a Lua request and 5% of
a CPython one. It has not been attacked because nothing yet needs it to be
smaller.

## The reaper is supervised, and knows which roots are its own

`wasm_worker_sup` starts the reaper, and `reaper_spec/0` is the only place its
child spec is built, so boot and a worker's first start can never disagree on
its roots. With `scratch_roots` configured it starts at boot, which is when a
restarted node recovers what a crashed one left: every journal record names
its node's incarnation, and a record from another incarnation is an orphan
whose directory is removed. That is also why a configured root must belong to
one node at a time.

Without `scratch_roots`, the first `wasm_script_worker:start_link/2,3` starts
the reaper with one root, `scratch`, in a directory named for the node, the OS
process and a unique integer, so no two live nodes can share it. The path is
fixed in the child spec, so a supervised restart after a reaper crash comes
back to the same directory and its journal. Which roots the reaper generated
is a separate start argument that only the supervisor passes, not a key in
`reaper_options`, so no configuration can mark a directory for deletion; a
generated root is removed at a clean shutdown only when no reservation is left
and its journal is empty.

`wasm_adapter_conformance` stops and restarts a reaper by hand in several
cases, so `suspend_reaper/0` takes the supervised one away, and stops lazy
start from bringing another up, until `resume_reaper/0`.

## Why `max_heap_words` is applied at spawn

`max_heap_words` in a limits map is set with `spawn_opt` when the runner is
created, not with `process_flag` inside it, because the closure and the
request are copied onto the new heap before an in-process call would run. An
inline caller does not get it by passing the key.

## Why reactors were slow to adopt compiled code

Until 0.3.0 a new instance could adopt compiled code only on a call where the
tier's hotness counter fired, one call in 32. A reactor builds a fresh
instance per request, so 31 requests in 32 ran interpreted with the compiled
code already resident beside them. `wasm_jit`'s `maybe_adopt` now looks for
resident code first and consults the counter only when there is none, so an
instance adopts on its first call; `test/audit/PERF.md` has the before and
after.

## Why a request's memory is a page table over the worker's image

The runner restores the worker's image and the restored memory reads the
image's pages in place, so a request allocates a page table and the 4 KiB
pages it writes, and nothing else. When the runner exits, its arena goes back
to the node and the image stays with the worker. There is no state to carry
from one request to the next, which is why the kernel no longer recycles a
destroyed instance's memory: that needed one process to restore every request
and a mark on every store, and it shared nothing between workers.

Two things a change here has to keep:

- **The image outlives every memory restored from it.** The keeper counts each
  restored memory as a holder of the image, so a worker that stops while a
  runner is still finishing does not free pages the runner reads.
- **One image per store key, not per worker.** Workers with the same store
  key share one generation of the image, a load or capture of it, held through
  its owner and published in `persistent_term`. See "How workers share one
  image" below.

## How workers share one image

A worker starting on store key K asks `wasm_snapshot_registry` for it:

```text
worker --acquire(K, Deadline)--> wasm_snapshot_registry
  {ok, G, Owner}  -> wasm_snapshot_owner:acquire/3, read the publication
  parked          -> the same answer, or retry, when the loader reports
  {load, Token}   -> spawn a guard; the guard links the load process, and
                     the capturer when the load needs one
                     load: store lookup, or capture and save; owner,
                           wasm_keeper:publish/2, then {loaded, G, Owner}
                     worker: take a hold, report loaded/5, then done
```

What keeps it correct, and what a change here has to keep:

- **The keeper alone puts and erases a publication**, `{wasm_snapshot, G}`,
  and puts one only for a generation it holds a live row for. It erases it when
  the owner goes, for any reason, and at its own start erases any it has no row
  for. `wasm_app:stop/1` erases them all.
- **A generation stops being restorable through a flag, not a message.** The
  image carries a one-element `atomics` array its owner sets to 0 when its last
  holder goes, and the keeper does when the owner dies. `wasm:restore/3` reads
  it, and the keeper reads it again when it admits the restored memory.
- **One deadline**, `capture_timeout` from the moment the worker starts
  acquiring its image. The guard kills every task of the load at it, or when
  the worker dies, whatever the task is blocked in. The owner is not a task: it
  must outlive the load, and before the handoff it ends with its first holder.
- **Reports carry the loader's token**, so a loader from before a registry
  restart is refused and asks again. The registry never calls an owner; a
  worker takes its own hold, within its own time.
