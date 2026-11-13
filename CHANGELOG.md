# Changelog

## Unreleased

A pool of script workers can share one image, and sending an image no longer
copies its tables. Compiled code calls and does 32-bit arithmetic as fast as
plain Erlang.

- **A module's size is now limited.** Nothing bounded the size of a module
  given to `wasm:compile/1` or `wasm:load/1`: it was read, hashed and decoded
  in full whatever its size. A module larger than `max_module_bytes`, 64 MiB
  unless you set it, is now refused with `module_too_large` before any of
  that.
- **The HTTP listener now listens on this machine only, unless you say
  otherwise.** `wasi_http_listener:start/1` listened on every network
  interface while `address/1` reported `127.0.0.1`, so a listener started for
  local use was reachable from the network. It now listens on `127.0.0.1` by
  default and reports the address it really uses. To accept connections from
  other machines, pass `ip => {0, 0, 0, 0}`.
- **A guest can no longer make the host hold an HTTP body of any size.** A
  body a WASI component wrote without declaring `content-length` was kept in
  host memory with no limit, outside the component's own memory limits. Every
  HTTP body the host holds is now limited by `http_max_body_bytes`, 8 MiB
  unless you set it: a request a guest sends, a response a 0.2 handler
  writes, and a 0.3 handler's response.
- **A WASI program waiting on several timers now wakes for the first one
  only.** `poll_oneoff` reported every timer as fired once the shortest was
  due, so a program using a long timer as a timeout timed out at once. It now
  reports only the timers whose time has come, never wakes before a timer is
  due (a delay used to be rounded down to whole milliseconds), and waits the
  full time for a timer longer than a minute, where it used to stop after one
  minute.
- **Ending an async task no longer leaves messages in your mailbox.** When a
  task ended, the processes feeding its streams were stopped without waiting,
  and a message one of them was still sending could arrive afterwards and stay
  in the calling process's mailbox for good. A long-lived process calling
  async exports collected hundreds. The task now waits for them to stop first.
- **A module whose start function never returns no longer keeps a worker
  spinning.** `wasm_instance_worker` ran the start function with no deadline,
  so a module that looped there kept the worker busy for good, even after
  every caller had given up. The start now has a deadline: `timeout` in the
  worker's `limits`, or `worker_timeout`, five seconds unless you set it.
- **An instance made before the application stopped now says so.** After
  `application:stop(wasm)` and a new start, a call through such an instance's
  wasm tables or shared globals crashed with a bare `badarg`, because they
  went with the application. It now traps with `runtime_stopped`. The
  instance already could not grow, since its memory is no longer counted. If
  you stop and start `wasm`, make your instances again after the start.
- **A thread killed while waiting no longer leaves its entry behind after an
  engine restart.** A thread parked in `memory.atomic.wait` when the engine
  restarted, and killed afterwards, left its entry in the waiter table for
  good.
- **WASI 0.3 commands run.** `wasi_preview3:run_command/3` runs a component
  built for WASI 0.3 that uses `wasi:cli`, `wasi:clocks` and `wasi:random`:
  stdio through streams, async sleeps, the environment and exit codes. It runs
  0.2 commands too, and serves `wasi:filesystem`, `wasi:sockets` and `wasi:http`
  at 0.3 over the same mounts, network grant and HTTP transport.
  `wasi_preview3:run_serve/3` and the HTTP listener serve a 0.3 `wasi:http`
  handler as well as a 0.2 one. Middleware, a handler that imports another, is
  not supported yet.
  `resource_limit` now also bounds how many async calls a guest has waiting
  at once. A TCP connection stays open while its send or receive stream does,
  even after the guest drops the socket itself, as Rust guests do.
- **Prepare a component once for many instances.** `wasm_component:prepare/1`
  decodes, checks and parses a component once; pass what it returns wherever
  you pass the bytes. The HTTP listener does this when it starts, so a
  request no longer decodes the component again.
- **An async task can keep running after it returns its result.** Call it with
  `wasm_component:start_async/4`, which returns as soon as the task has a
  result. Read a returned stream with `wasm_async:host_read/3` while the guest
  writes it, and run what is left with `wasm_component:pump/2`. Several tasks
  can run in one instance. A host import can now give the guest a stream or a
  future of its own. `call_async/4` is unchanged.
- **A WASI 0.3 import no longer binds a WASI 0.2 function.** Versions were
  removed when matching imports to host functions, so `wasi:cli/stdout@0.3.0`
  reached the 0.2 `stdout`, whose functions differ. A 0.3 import now looks for a
  host key ending in `@0.3` and nothing else, so 0.2 and 0.3 hosts can serve one
  component side by side. 0.2 keys are unchanged.
- **Async host imports work on every component.** One with a single core module
  used to refuse an `{async_import, ...}` host function at instantiation.
- **The HTTP listener no longer fails after about 12 requests a second.** Each
  request loaded the component's core modules again, because nothing kept
  them loaded between requests, and those loads counted against the module
  cache's limit of 50 a second: past it, every request was answered 500. The
  listener now loads them once when it starts. `wasm_component:hold/1` does the
  same for your own server.
- **HTTP requests from a guest now have a real deadline and a size limit.**
  The 30-second deadline restarted with every chunk of the response, so a
  server trickling bytes could keep a request open for ever; it now counts
  from the start of the request. `between-bytes-timeout` is applied, HTTP/2
  requests apply the connect and first-byte timeouts too, and a response
  body over 8 MiB fails with `HTTP-response-body-size`. Set the limit with
  `max_body_bytes`, or `http_max_body_bytes` on the runners.
- **The HTTP listener bounds every request.** A request body is read to its
  end within `request_timeout` (60 s by default), chunked or not: a chunked
  body used to reach the guest empty, and a stalled one reached it truncated.
  A body that does not arrive in time is answered 408, one over
  `max_body_bytes` (8 MiB) is answered 413, and a guest still running at the
  deadline is stopped and answered 504.
- **Execution limits reach the guest.** `fuel`, `max_depth`,
  `max_memory_pages`, `max_heap_words` and `max_host_calls` passed to
  `wasi_preview2:run_serve/3` or `run_command/3`, or in a listener's
  `serve_opts`, were ignored. They now apply, as `resource_limit` does.
- **Nothing the runtime starts outlives the process responsible for it.**
  Several helpers ran work in a child whose time limit lived in the process
  that started it, so killing that process left the work running with nothing
  to stop it: an async stream producer, a cleanup callback, an image capture
  whose `init()` never returned, and an artifact load. Each now dies with its
  owner. `wasm_instance_worker:call/4` also kills a worker that runs past its
  timeout even when the caller has died.
- **Killed processes no longer leave memory behind.** A process killed while
  loading a module could leave the module cached with nobody holding it,
  counted against `max_resident_modules` for the life of the node; one killed
  while waiting in `memory.atomic.wait` left its entry in the waiter table.
  Both are now removed.
- **The async component ABI is complete.** Streams and futures carry any
  element type, not only bytes; reads and writes can be cancelled; subtasks
  can be cancelled and dropped; error contexts keep their message; backpressure
  and `thread.yield` work; and an async export without a callback (the stackful
  form) runs instead of being refused. A guest that breaks the rules now traps
  where it used to get a quiet wrong answer: a second read of a future,
  cancelling a copy that is not pending, dropping a running subtask or an
  unwritten future. A stream between two ends of a component holds at most
  1024 elements, where it used to grow without limit. A wait no longer gives
  up after five seconds, and a wait nothing can end traps at once. While an
  instance holds backpressure, `call_async` returns
  `{error, async_backpressure}`.
- **An async task no longer takes your process's monitor messages.** Ending
  an async component call removed every `'DOWN'` message from the calling
  process's mailbox, including those of monitors the caller had set up
  itself.
- **Compiled calls and 32-bit arithmetic are much faster.** A call between
  compiled functions is now a plain local call, and 32-bit integer
  arithmetic compiles the way you would write it in Erlang. Recursive
  `fib(30)` runs 4.7 times faster and is level with Wasmtime; an arithmetic
  loop runs at the speed of plain Erlang. QuickJS and CPython guests are as
  fast as before or a little faster, and the compiled code is 6% smaller.
  Compiled code saved by an earlier release is compiled again once.
- **Compiled f64 arithmetic and calls through a table are faster.** f64
  addition, subtraction, multiplication, division and comparisons on ordinary
  numbers run inline: a floating-point loop is twice as fast. A call through
  a table to a function compiled alongside the caller is now a local call,
  and through a table that cannot change it needs no lookup at all:
  recursive `fib(30)` through a table went from 211 ms to 7.8 ms. 32-bit
  loads and block results also avoid needless conversions, and a QuickJS run
  is about 12% faster.
- **In compiled code, `max_depth` counts only calls that can recurse.** A
  chain of calls that cannot recurse is not counted, so compiled code can go
  deeper than `max_depth` by at most the number of functions compiled
  together. A runaway recursion still traps. A depth trap raised by compiled
  code no longer reports the depth.

- **An array of `v128` can be built from a data segment.** `array.new_data`
  and `array.init_data` on an array whose elements are vectors failed; they
  now read sixteen bytes per element, as the GC specification's latest tests
  require.
- **A pool of workers shares one image.** Workers started with the same
  adapter and the same options now hold one image instead of a copy each:
  one capture on a missing image, even when they start together, and one
  charge to `max_snapshot_bytes`. You set nothing for it. "Run a pool from one
  image" in `docs/worker.md` shows a supervised pool.
- **A table of functions travels as one binary.** An image's table holding
  only `null` and the module's own functions is packed at capture and at load,
  so handing an image to a request's runner copies a reference instead of the
  table. The snapshot file format is unchanged.
- **A malformed table in a snapshot file is `snapshot_corrupt`.** That is a
  table that decodes to neither a list nor whole 32-bit words.
- **An idle worker no longer keeps its module file.** `Adapter:artifact/1`
  runs in a short-lived process that hands its module claims to the worker,
  so the file it read (30 MB for CPython) is freed when that process exits.
  An adapter whose artifact holds a process-owned resource, such as an ETS
  table, must return values instead. `wasm_module_cache:claims/1` lists what
  a process holds.

- **A `wasi:http` request to a host name is checked against the addresses the
  name resolves to.** Before, a name was checked as if it were `127.0.0.1` and
  then connected to by name, so a grant for a loopback port admitted any host
  on that port. A name now also needs `resolve => allow` in the grant, as
  socket name lookups already did. Literal addresses are unchanged.

## 0.9.2

Compiled code is smaller, compiles faster and runs faster. Nothing to set; the
code cache is rebuilt once.

- **Compiled code is less than half the size and compiles four times faster.**
  A memory access in generated code now keeps one compare inline and calls a
  shared function for the rest, where 0.9.0 and 0.9.1 repeated the whole page
  lookup at every access. A cold compile of the hot set takes about a quarter
  of the time: CPython 104 s against 415 s, QuickJS 69 s against 271 s, Lua
  23 s against 102 s. Peak memory during the compile is 28 to 51% of what it
  was.
- **Compiled requests are faster.** A compiled script request's p50 is 12 to
  33% lower: CPython 10.5 ms against 15.3 ms, QuickJS 4.8 ms against 6.6 ms,
  Lua 2.7 ms against 3.0 ms, CPython with an `entry` 2.1 ms against 2.7 ms.
  Interpreted requests, restore time and how many instances fit in a page
  budget are unchanged.
- **Generated code is ABI 15.** A code cache written by an earlier release is
  ignored and rebuilt on the first compile. Nothing to set.

## 0.9.1

Component resource handles the host holds are checked, and components run
without the `wasm` application. One breaking change: a host-held handle is now
an index, not the guest's representation.

- **Breaking: a resource handle the host holds is a small index.**
  `wasm_component:call/4` hands back an `own` as an index into the instance's
  handle table, starting at 1, instead of the guest's representation, and checks
  every handle it is given against the export's signature. A handle that was
  dropped, dropped twice, never handed out, or is of another resource type
  answers a `resource_not_live` or `resource_wrong_type` trap, and the guest is
  not called. `drop_resource/3` answers the destructor's result or that trap
  instead of always `ok`. Drop any code that treats a handle as the guest's
  representation.
- **Components run without the `wasm` application.**
  `wasm_component:instantiate/2,3` compiles inline when the module cache is not
  running, instead of answering `cache_unavailable`. With the application
  started nothing changes.

## 0.9.0

A restore shares its snapshot's image instead of copying it, script requests
are faster by default, a worker can run compiled with one option, a loaded
module no longer keeps its whole input file in memory, and the CPython reactor
ships stripped with its standard library precompiled. Workers built on
`py_reactor.wasm` need the new build. Drop `recycle` from `wasm:restore/3` calls
and `recycle_idle` from worker options; both are now ignored.

- **Restored memory shares its image.** A restore no longer copies the
  image: the memory reads the image's pages in place and copies a 4 KiB page
  on its first write. A restore costs a page table and a request the pages it
  writes: a CPython restore is 0.79 ms instead of 12.0, and a node holds 124
  CPython instances under `page_limit` 4096 instead of 6. Loading a snapshot
  file costs what it did.
- **Restore recycling is removed.** `wasm:restore/3` no longer takes `recycle`,
  and the worker option `recycle_idle` is gone. Nothing replaces them: every
  restore now shares the image.
- **Compiled code reaches restored memory through a translation cache.** A
  compiled request's guest time is 12% to 49% higher than with a copied image;
  whether the whole request is faster depends on how much of it the restore
  was (a CPython request with an `entry`: 5.4 ms to 3.0 ms; a compiled QuickJS
  script request: 6.5 ms to 7.7 ms). Generated code is ABI 14, so the compiled
  tier's disk cache is rebuilt once.
- **The node page budget counts allocated pages.** A restored memory charges
  its page table and the pages it writes; any memory charges its growth in
  whole chunks, so a three-page memory counts four. `max_memory_pages` still
  bounds the size a guest sees.
- **A write can now be refused for want of budget**, with `exhaustion` /
  `memory_limit`, leaving every byte as it was. A restore that cannot be
  afforded is refused the same way; it used to surface as `malformed` /
  `internal`.
- **The snapshot budget charges whole pages**: 64 KiB for each page that holds
  data and 8 bytes per page of address space, held while the image or any
  memory restored from it remains.
- **A snapshot file is checked against its module before it is built.** One
  with runs out of order or overlapping, or memories outside the module's
  limits, is refused by name; one over the budget, or mapping more than 2^20
  pages in one memory, is refused as `exhaustion` / `snapshot_budget`.
- **Default heap floors.** A new optional adapter callback, `defaults/1`, is
  given the worker's resolved limits and answers `runner_min_heap_words` and
  `capture_min_heap_words` when the caller did not set them. `wasm_lua` and
  `wasm_javascript` default the runner floor to 200,000 words; `wasm_python`
  to 1,500,000 on the compiled tier (`compile => true`, `fuel => infinity`)
  and 1,000,000 otherwise. Pass the option to change it, or `0` to turn it
  off. A floor is held only while a request executes; `docs/tuning.md` has
  what it costs a pool and how `+MMmcs` affects RSS. No adapter sets a
  capture floor.
- **Lowered code is shared per module.** A module loaded through the module
  cache publishes its validation context, function table and the function
  bodies requests reach, once per node, so a request in a fresh runner no
  longer lowers them again. Nothing to set.
- **New worker option `compiled`.** `compiled => true` sets `fuel =>
  infinity`, `compile => true`, `compile_after => 1` and `compile_quality =>
  baseline` under your own `limits`. With a finite `fuel` the start fails with
  `{bad_option, compiled, #{fuel => N}}`; that combination used to interpret
  without a word. Metered stays the default.
- **`wasm:restore/3` expands `profile`** as `wasm:instantiate/3` does. A
  restored instance under `profile => script` used to keep the default compile
  threshold of 32.
- **A decoded module owns its bytes.** Data segments, names and the custom
  sections it keeps are copied out of the input, and `.debug_*` sections are
  dropped, so the input binary is freed when the caller lets go of it. A
  module used to pin the whole file: 31 MB for the CPython reactor.
- **Fixed:** the per-process function cache ignored `fuse`, so an unfused
  instance could hand its bodies to a fused one in the same process.
- `bench/paths/` gains `gap.erl`, `guestprof.erl`, `lowbench.erl` and
  `retainbench.erl`; reqbench's QuickJS and Lua arms now run at infinite fuel,
  and so reach the compiled tier.
- **`scripts/build-python-reactor.sh` strips the DWARF** with
  `wasm-opt --strip-debug`: 7.4 MB instead of 30.9, at the same request
  speed. The build now needs binaryen's `wasm-opt`, or `WASM_OPT` set to it.
- **The standard library ships precompiled**, as unchecked hash-based `.pyc`
  files compiled by the build's own host interpreter. A module a request
  imports that is not in the image loads instead of compiling from source.
  Editing a `.py` under the library has no effect until you rebuild it.
- **The reactor freezes its image out of the cyclic collector.** `init()`, and
  an entry's capture, end with `gc.collect()` and `gc.freeze()`, so a request
  no longer pays for a collection over objects every request shares. Objects
  from the image are never collected and `gc.get_objects()` does not list
  them. See `docs/python.md`.

## 0.8.2

Component resource handling is completed: ownership moves correctly across a
composed call, destructors run, and misuse is caught.

- **Resource ownership moves across a composed call.** When one component hands a
  resource to another, the handle moves with it: a lent resource is reachable in
  the callee only for that call, an owned one passes over, and a returned one
  passes back. A resource is live in one component at a time, so using one that
  was handed away traps.
- **Destructors run on drop.** Dropping the handle that owns a resource runs the
  resource's destructor, exactly once.
- **Wrong-type handles trap.** Reading a handle as a resource type other than its
  own traps instead of returning a representation.
- **A Component Model resource guide and example.** `docs/components.md` spells
  out the resource rules, with a runnable walk-through in
  `docs/examples/use-a-component-resource.md`.

## 0.8.1

A component's own resource handles are tracked per instance, so misusing one is
caught instead of silently ignored.

- **Resource handle liveness.** A component that hands out a resource (a handle
  to something it owns, like a counter or an open file) now has each instance
  track its live handles. Dropping one twice, or using one after dropping it,
  fails cleanly rather than passing silently. Handles that belong to the host (a
  WASI stream or socket) and resources passed between composed components are
  unaffected.
- **A Component Model guide.** `docs/components.md` covers running and composing
  components, and the typed signatures `wasm_component:call/4` takes.

## 0.8.0

The synchronous WebAssembly Component Model and WASI 0.2 (preview 2). A component
binary decodes, instantiates and runs against a preview-2 host, composed
components wire together, and the Canonical ABI marshals values both ways.
`wasm_component` and `wasi_preview2` are the entry points; nothing new to
configure.

- **Run a component.** `wasm_component:instantiate/1,2,3` and
  `wasm_component:call/4` decode a component, instantiate its core modules and
  call an export through the Canonical ABI, lifting and lowering `list`,
  `record`, `tuple`, `variant`, `enum`, `result`, `option`, `flags`, `string`
  and the numeric, `char` and `bool` types. Strings marshal as utf8, utf16 or
  latin1+utf16 per the lift's declared encoding.
- **Composition.** A `wac`-composed component whose nested components import and
  export each other's interfaces instantiates and runs: values cross the
  boundary by copy, each side keeping its own memory.
- **Resources.** `own` and `borrow` handles cross the host boundary, and the
  guest and host resource tables are torn down on destroy.
- **WASI 0.2 host (`wasi_preview2`).** cli, clocks, random, filesystem, sockets
  and http, with the io streams and poll. `wasi_preview2:command/1` runs a
  command component and `run_serve/3` an incoming-handler component.
- **Conformance hardening.** A `canon lift` whose core function has the wrong
  type is rejected at instantiate, and an export resolves to the core its lift
  names rather than the largest by size. A declared realloc and post-return are
  honoured and a trapping post-return fails the call; a by-memory value at an
  unaligned pointer traps; a core-less component instantiates. The wasi-io
  output stream enforces its write permit and stays closed once closed, and a
  blocking read waits for data instead of reporting a false end-of-stream.

## 0.7.0

A script worker recycles its restores whether or not it restores ahead, with
the memory it keeps between requests counted and bounded.

- **Every script worker recycles its restores**, not only one with
  `restore_ahead`. A worker keeps the memory its last request's instance left
  and the next restore rewrites only the chunks that request wrote: a CPython
  pool without `restore_ahead` answers about 1.4x the requests. The kept
  memory counts in the node's page budget.
- **New worker option `recycle_idle`**, milliseconds an idle worker keeps that
  memory (default `30_000`). `0` keeps none.

## 0.6.0

A CPython worker can run code set once at capture instead of compiling a source
on every request, and a worker restoring ahead rewrites only the memory the last
request wrote. Workers built on `py_reactor.wasm` need the new build.

- **New `wasm_python` option `entry`.** Python source the capture runs once;
  it hands `worker.set_entry` a callable, and a request with no `source` calls
  it with the context. Nothing is compiled or imported per request: the
  guest's call went from 40 ms to 2 ms for the same request. A request with a
  `source` still runs it. See `docs/python.md`.
- **The CPython reactor defines its request runner once**, in `init()`, so
  `handle()` no longer compiles it per request.
- **A restore can recycle the last instance's memory.** `wasm:restore/3`
  takes `recycle => true`: the destroyed instance of the same image in the same
  process gives the next restore its memory, and only the 64 KiB chunks it
  wrote are rewritten. A CPython restore goes from 12 ms to 3.9 ms, and a
  `restore_ahead` worker, which recycles on its own, answers about 1.7x the
  requests it did. A memory restored this way marks each chunk it writes,
  about 4 ns a store in generated code; everything else pays a field test.
  Generated code is ABI 5, so the compiled tier's disk cache is rebuilt once.
- **A restore no longer evaluates the element segments** the image
  overwrites.
- **The context reaches the CPython reactor through a `worker.context`
  import.** The reactor imports `worker.context` and `worker.context_size`,
  so an adapter of your own over `py_reactor.wasm` has to bind both; images
  of the previous build are not restored (version `py-reactor-2`).

## 0.5.0

Requests on a pool of script workers no longer wait on one another in
node-wide processes. Nothing in your code changes. One new worker option.

- **New worker option `restore_ahead`.** With a captured image, the worker
  restores the next request's instance while it waits, so a request starts at
  the guest's own work: a CPython request's deliver and restore goes from
  15 ms to 38 us when an instance is waiting. Every request still gets a
  fresh instance. It holds one instance's memory per idle worker, needs
  imports that are all functions, and helps only when workers have idle time
  between requests; see `docs/tuning.md`.
- **File operations on the request path are raw.** Staging, mounts, request
  directories, cleanup and WASI path resolution no longer go through
  `file_server_2`, which a request called about 34 times.
- **The reaper does no file I/O of its own.** Journal records are written by
  writer processes and are no longer synced; a start removes every request
  directory no record names, which covers a record lost to a host crash.
  `DOWN` handling is O(1) and the operator view (`cleanup_stats/0`,
  `cleanup_requests/0`) is refreshed at most every 50 ms.
- **Fewer keeper and code-slot calls per instance**: four keeper calls where
  there were six, and two code-slot calls where there were seven for a module
  compiled as one unit.
- **`wasm_jit:counts/0`'s `entered` and `reentered`** are counted per
  scheduler, without a shared word on the call path.

## 0.4.3

Packaging and clock fixes. Nothing in your code changes, and there is nothing
new to set. If you install from hex.pm and use the command adapters, this is
the first version that works.

- **The hex package now ships `priv/script_v1`.** The `files` list in
  `wasm.app.src` replaces the plugin's default and had left `priv/` out, so
  0.4.1 and 0.4.2 on hex.pm have no `boot.py` or `boot.js` and
  `wasm_python_command` and `wasm_javascript_command` fail at start unless
  erlang_wasm comes from a git checkout. This release carries the files.
- **`scripts/build-python-reactor.sh` can be run again.** A second run found
  `python.wasm` up to date, got make's "is up to date" line instead of the
  link command, and failed in `sh`. The link line now comes from
  `scripts/python-link-line.sh`, which asks make with `-W Programs/python.o`
  and refuses anything that is not the link command.
- **The WASI monotonic clock counts from node start.** It handed the guest
  BEAM's own monotonic time, which is negative, and as a u64 that wrapped to
  about 1.8e19: `time.monotonic()` in the Python reactor raised
  `OverflowError`, and asyncio, `perf_counter` and timeouts went with it. It
  is now nanoseconds since the node started, never negative and never
  decreasing. Nothing to set.
- **A clock id that is not a clock here says so.** `clock_time_get` and
  `clock_res_get` answered `ENOTCAPABLE` to every id but the two clocks,
  which told a guest asking for CPU time that the host had withheld it. The
  CPU time ids now answer `ENOTSUP` and an id outside the four the
  specification defines answers `EINVAL`. A clock that exists and was not
  granted still answers `ENOTCAPABLE`.
- **`poll_oneoff` honours an absolute deadline.** A clock subscription with
  the ABSTIME flag set was dropped from the wait, so the call returned at
  once and `clock_nanosleep(TIMER_ABSTIME)` did not sleep. It now waits
  until that clock reads the deadline.

## 0.4.2

Security and liveness fixes from a guest-reachable audit of 0.4.1. Fix forward,
no separate advisory. Nothing in your code changes; the new settings below all
have safe defaults.

- **WASI path resolution no longer escapes a preopen.** A symlink whose target
  climbed out of the preopen (`link -> .`, then `path_open("link/../secret")`)
  read outside it; `fstatat` and `utimensat` with FOLLOW resolved the last
  component in the kernel; and `fd_readdir` could be walked without a bound. It
  now streams with a persistent handle and an opaque cursor, bounded by
  `readdir_batch_bytes`.
- **A cyclic supertype no longer hangs validation.** `wasm_types:is_subtype/4`
  looped forever on a recursive type because it kept no visited set; a self- or
  forward-referencing supertype is now rejected.
- **A hostile snapshot image is refused, not restored.** Restore reapplies the
  module-eligibility rules capture used, bounds the decode
  (`max_snapshot_inflated_bytes`, `max_snapshot_decode_nodes`), and encodes
  losslessly or refuses.
- **The snapshot byte counter cannot be raced.** A legacy counter is seeded
  behind a version marker and read through a `trusted | legacy | missing`
  accessor, so a restored image cannot start accounting from a forged value.
- **A cancelled or timed-out request no longer stalls five seconds.** The
  guardian stopped re-waiting a runner `DOWN` it had already consumed.
- **A slow or dead cleanup reaper no longer stalls the request deadline.** A
  per-request cleanup steward carries cleanup to the reaper without blocking the
  guardian, a node-wide cleanup manager bounds it and serves the operator view
  even while the reaper is busy, and a request survives a reaper restart with its
  cleanup state intact. New settings, all defaulted:
  `max_cleanup_operations_per_request`, `max_cleanup_jobs`, `cleanup_queue_len`,
  `cleanup_timeout`, `cleanup_job_deadline`, `max_cleanup_actions`.

## 0.4.1

Documentation only; no code change beyond one module doc.

- Every figure in `README.md` and `docs/` now cites a run in
  `test/audit/PERF.md`. Nineteen were stale, mixed two runs, or had no
  measurement at all: the specification gate (65,481 assertions over 256
  suites), the WASI syscall count (45), the tier's per-guest numbers, the cost
  of accepting a request, and the compile and instantiate costs of the
  committed fixtures.
- The CPython guide quotes the current reactor numbers: 88 ms a request, and
  91 to 95 s for a capturing `start_link/2`.

## 0.4.0

**The workers ship with the application.** Running JavaScript, Python or Lua
now needs the dependency and a runtime artifact, and nothing copied from
`examples/`. Nothing breaks: the new modules take names no 0.3 example used,
so code you copied keeps working. [Upgrading from 0.3](docs/upgrading.md)
maps each copied module to its installed one.

- `wasm_script_worker` is the worker kernel; `run/3` takes a source and a
  context. `wasm_worker_adapter` is the behaviour an adapter implements.
- The adapters are `wasm_javascript`, `wasm_javascript_command`,
  `wasm_python`, `wasm_python_command` and `wasm_lua`.
- `wasm_instance_worker` is the 0.3 `examples/wasm_worker.erl`, with the same
  calls.
- The application starts the reaper. Set `scratch_roots` so a restarted node
  cleans up what a crashed one left, and `reaper_options` for the cleanup
  limits. `wasm_script_worker:cleanup_stats/0` and `cleanup_requests/0` show
  what it holds.
- The guides open with what you want to do, and ten example pages run as
  written. Every code block in `README.md`, `docs/` and the module docs is
  checked on every test run, and `getting-started.md` runs as pasted.

## 0.3.0

This release is about running other people's code: safely, and fast enough to
be worth doing.

Three parts, meant to be used together.

- A **worker** runs one untrusted request at a time, in its own process, with
  its own deadline and its own limits.
- **Snapshots** let a language like Python start once, when the worker starts,
  instead of starting again on every request.
- The **compiled tier** now works for a worker like that. It did not before.

Together they take a CPython request from about a minute to 35 ms.

### Run untrusted code, one request at a time

`script_worker` is the worker. It knows about modules, imports, deadlines and
output limits. It knows nothing about WASI, or JSON, or what your guest calls
its entry point. That part is an **adapter**: one module per language.

```erlang
{ok, _} = worker_reaper:start_link(#{scratch => "/var/tmp/w"}),
{ok, W} = script_worker:start_link(my_adapter, #{root => scratch}),
{ok, R} = script_worker:run(W, Request).
```

Three languages come with adapters already. `js_worker` and `python_worker`
take a function written by whoever is sending the request. Lua is
`lua_reactor_adapter`.

Every language needs its own limits, and an adapter will never raise one for
you. Python will not even start until you raise several of them. The Python
guide lists them.

Read next: [workers](docs/worker.md) to run one,
[the adapter contract](docs/worker-contract.md) to write one, and
[JavaScript](docs/javascript.md), [Python](docs/python.md) or
[Lua](docs/lua.md) for a language.

Smaller things: `max_output_bytes` now accepts separate bounds for stdout and
stderr. `t:wasm:extern/0` names the type `extern/2` returns.

### Start an interpreter once, not once per request

Starting CPython takes about a minute and a half. Doing that per request is not
an option, and keeping one interpreter alive across requests leaks one caller's
state into the next.

So capture it once, and give every request a fresh copy:

```erlang
{ok, Image} = wasm:snapshot(Init),
{ok, Fresh} = wasm:restore(Image, FreshImports, #{}).
```

The copy is genuinely fresh. Globals, memory and tables come from the image,
but the imports are the ones you pass in now, so one request cannot reach
another's files or sockets.

The instance you capture has to be created with `snapshotable => true`, and a
restore refuses an image that does not match the module it is handed.
`wasm:save_snapshot/2` and `load_snapshot/2` put an image on disk.
`max_snapshot_bytes` caps what one node keeps in memory.

Read next: [snapshots](docs/snapshots.md).

### Compiling hot code, and why it helps now

Turn it on with `compile => true` and `fuel => infinity`. Those two go
together: leaving a fuel limit in place quietly keeps you on the interpreter.
Point `code_cache_dir` at a directory you own, and a restart reuses what was
compiled last time. That is minutes of work turned into seconds.

What changed:

- **A fresh instance uses compiled code immediately.** It used to wait for a
  function to be called 32 times. A worker that builds a new instance per
  request almost never got there, so 31 requests in 32 ran interpreted next to
  compiled code that was sitting right there.
- **Restoring a snapshot is three times faster.** It used to write out the
  module's initial data and then blank it again, even though the image was
  about to overwrite all of it. A CPython request went from 64 ms to 35 ms.
- **A compile can be given a memory cap, and can be interrupted.**
  `compile_max_heap_words` caps a single compile. `compile_budget_heap_words`
  caps the whole machine: divide it by the cap and that is how many compiles
  run at once. A guest that does not get a slot keeps interpreting and tries
  again later. Both are off unless you turn them on.
- **The compiled-code cache is checked, not trusted.** It verifies the
  directory and every file it reads, and quietly recompiles if anything looks
  wrong. It will not read through a symlink or out of a world-writable
  directory.

Read next: [the compiled tier](docs/compiled-tier.md).

### If requests are slower than you expect, set a heap floor

A restored instance holds almost nothing on the Erlang heap, so the runtime
gives its process a tiny one and then collects garbage hundreds of times during
a single call.

`runner_min_heap_words` fixes it. The right value depends on the guest:
200,000 for QuickJS and Lua, 1,000,000 for CPython. Going higher than that
makes things worse, not better. `capture_min_heap_words` does the same for the
snapshot.

Read next: [tuning](docs/tuning.md).

### Breaking

`script_worker` used to be the QuickJS worker. It is called `qjs_worker` now
and behaves exactly as it did. The old name now belongs to the
language-neutral worker described above.

## 0.2.2

Documentation only. No code changed.

### Documentation

A guide for talking to a guest while it runs, [Streams](docs/streams.md). You
need it when the module you are running is a server rather than a function: a
script with its own read loop, a language runtime answering one request at a
time, or a program whose output you want as it is produced.

There is no new API for this, which is the point of the page. A `stdin`
capability may be a fun and a fun is allowed to block, so `fd_read` waits until
you answer; a `stdout` capability may be a pid, which receives
`{wasi_output, RunnerPid, Bytes}` per write. Both were one table cell each in
the WASI guide, so the recipe was not findable. The WASI and Workers guides now
point at it, and it states the two things that bite: the fun blocks the process
running the call, so the process feeding the guest has to be a different one,
and it needs an `after` or a guest parked on a read holds a worker for ever.

The README says that the project is developed with strong AI assistance, and
what that process is: humans lead the architecture, semantics, testing and
benchmarking, generated code is a proposal rather than evidence, and changes
are validated against the specification suite, real toolchain output and
repeatable benchmarks.

## 0.2.1

### Changed

`array.copy` and `array.fill` do less work per element. Over ten thousand
elements, a copied element costs 7.0 reductions where it cost 19.9, and a
filled one 6.0 where it cost 7.8.

`array.copy` built three lists per copy and read the array's length from the
object table once per element, re-answering what the range check had already
answered. The loop lives in `wasm_heap` now, beside the accounting it has to go
through: it reads the source array's default once rather than per element, and
decides an overlapping copy by direction instead of taking a snapshot of the
source. A partial `array.fill` counts down rather than walking a list of the
indices it is about to use.

Behaviour does not change, including the rule that an overlapping `array.copy`
behaves as though an intermediate copy were taken.

## 0.2.0

### Changed

The supervision tree is one supervisor per subsystem. Five servers under one
`intensity => 5, period => 10` shared a budget, so losing the module cache
repeatedly could take the engine, the keeper and the code slots with it, and
the tables went too. Each subsystem now has its own supervisor and its own
`10 in 60`, and `wasm_store` owns the long-lived tables.

A wrong-typed call argument answers `{link, argument_type}` where it used to
answer `{malformed, internal}`. `malformed` is the decode class and an argument
is not a decode concern; the kind is new, the class has changed, and anything
matching on the old pair needs updating.

- **`max_memory_pages` now covers garbage-collected objects as well as linear
  memory.** A workload under a tight ceiling that allocates structs or arrays
  can be refused where it was not. The node page budget widens the same way, so
  `memory.grow` can return -1 because a guest filled the object store. Both were
  unbounded before: a guest filling a twenty-million element array took 1.8 GB
  with `max_heap_words` set, `process_flag(max_heap_size, ...)` set on the
  process running it, and `pages_in_use` reading zero throughout, because a
  struct or an array is a row in ETS and ETS is not process heap.

  `max_heap_words` is documented as what it always was: a ceiling on terms on
  the *caller's own heap*, applied by the caller. It never covered guest memory
  of either kind, and no longer reads as though it might.

### Fixed

- **A store of few large objects was never collected.** Every rule in
  `wasm_heap` counted objects: `major_due/1` compared a row count against a
  floor of 4096, so a workload replacing one large array per call never got a
  major collection, and a minor one leaves the old generation alone by design.
  Four rounds of a fifty thousand element array left all four, sixteen
  megabytes, with one reachable. Both `major_due/1` and `should_collect/1` now
  read bytes as well as rows, with a `gc_min_major_pages` floor. A workload that
  allocates heavily and keeps nothing does about 14% more work and stops
  leaking; one with a stable live set is unaffected.

- **`atomic.fence` was rejected as invalid.** The decoder and the interpreter
  both knew it and the validator had no clause, so every module carrying a
  fence failed to load. The specification suite does not exercise it.
- **A tree death leaked the node page budget permanently.** The counter lives
  in `persistent_term` and outlives the supervision tree; the registry that
  says who holds those pages does not. Pages charged when the tree died could
  never be released, and it accumulated across application restarts.
  `wasm_keeper` now reconciles the two when it starts.
- **A limits map that could not mean what it said was ignored.**
  `#{max_depth => lots}` failed open, because every integer sorts before every
  atom, so a guest could recurse a million frames under a ceiling the embedder
  believed it had set. `wasm_limits:validate/1` existed and nothing called it.
- **The compiled tier computed on ill-typed arguments.** `wasm_exec` checks
  arity and the tier never reaches it, so the same call answered differently
  depending on whether the function was hot; and a float passed for an `i32`
  was rejected by the interpreter and had `i32.add` run on it by the tier.
  Both are checked once now, before either engine is chosen.

## 0.1.1

`wasm:compile/1` takes the text format:

```erlang
{ok, M} = wasm:compile({wat, ~"(module (func (export \"f\") (result i32) i32.const 7))"}).
```

`load/1` still takes the binary format only: the cache is keyed on a content
hash, and a module built from text takes a fresh identity every time.

### Fixed

Seven lifecycle defects found by an audit of the previous release.

- A reader killed inside `wasm_heap:lease/1` or `unlease/2` stranded a count
  nothing could give back, and the object store never collected again.
- A keeper restart dropped every per-instance memory ceiling, so an instance
  created with `max_memory_pages` grew past it.
- A process calling instances it does not destroy kept one table array and one
  compiled entry per instance, without bound.
- `sock_send_to` leaked a socket when the send failed, and another when the
  guest's output pointer was out of bounds.
- `atomic.wait` reported a wakeup that never happened when the notifier died
  between claiming a waiter and sending to it.
- `wasm_engine`'s per-instance limits table had no callers and is gone.

## 0.1.0

First public release. The versions before it were developed in a private
repository and are not published; this is the whole runtime as one release.

The Hex package is `erlang_wasm`; the OTP application inside it is `wasm`.

```erlang
{deps, [{wasm, {pkg, erlang_wasm}}]}.
```

### What it does

A WebAssembly runtime written in Erlang/OTP. Decoding, validation,
instantiation, execution, linear memory and WASI preview 1 are implemented in
Erlang. The only native code is an optional file NIF that closes a
time-of-check-to-time-of-use window in WASI path resolution, and the runtime
falls back to a pure Erlang resolver when it is absent.

### Proposals

WebAssembly 1.0 core, bulk memory, reference types, multi-value, multiple
memories, memory64, SIMD, relaxed SIMD, tail calls, typed function references,
exception handling, garbage collection, threads and shared memories, sign
extension, and saturating float-to-int conversion.

Both formats are read: the binary format, and the text format as `.wat` modules
and `.wast` scripts.

### WASI

Forty-four preview 1 syscalls. Directories and sockets are granted by naming
what may be reached, with nothing reachable by default. See `docs/wasi.md` and
`docs/security.md`.

### The compiled tier

Hot functions are lowered to Core Erlang, compiled and loaded into a fixed pool
of sixteen pre-interned module names, so no atom is ever derived from a guest's
bytes. Off by default; see `docs/compiled-tier.md` for when it pays and when it
does not.

### Errors and limits

Nothing raises. A malformed binary, an ill-typed module, a trap and a resource
limit all come back as `{error, Error}` carrying a class, a machine-readable
kind, the specification's message text and context. Memory pages, tables and
globals are held by holder tokens whose owning process's death releases them,
so a killed worker cannot leak a page.

### Conformance

64,774 core specification assertions across 215 suites, with an empty skip
baseline, and 65,481 of them replayed through generated code. Seventy-two of
the 72 wasi-testsuite cases pass with the NIF, 68 without it. Neither suite is
vendored; `docs/features.md` says how to clone them.
