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
1.7 to 2.3 ms, which on a 6 ms QuickJS request is a quarter of it. It has not
been attacked because nothing yet needs it to be smaller.

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
