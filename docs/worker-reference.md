# Worker configuration

This page lists every setting the workers take, with its default and what
it limits. Look here when a guide names a setting, and before you go to
production: you can only change a default that you know about.

Words used below: the **guardian** is the process that owns one request's
deadline and files; the **reaper** is the one process per node that cleans
up after requests; an **image** is a saved copy of a guest after start-up,
which each request restores. [Worker internals](worker-internals.md)
describes them.

## Per request, in the `limits` map

The `limits` map you pass to `wasm_script_worker:start_link/2` is merged
over `wasm_limits:untrusted/0`. So every limit of that preset still applies,
unless you change it:

| setting | default | what it limits |
| --- | ---: | --- |
| `timeout` | 5 s | one request, wall clock, enforced by the guardian |
| `max_output_bytes` | 1 MiB | stdout and stderr, each separately; also accepts `#{stdout := N, stderr := M}` |
| `max_result_bytes` | 1 MiB | the dedicated result channel |
| `max_combined_bytes` | 1 MiB | stdout **and** the result together, on `script_v1.combined`, where they share one descriptor |
| `max_request_bytes` | 1 MiB | the source plus the encoded context |
| `max_staged_bytes` | 8 MiB | everything the adapter stages, across all mounts |
| `max_staged_files` | 64 | how many files it stages |

An interpreter needs several of these raised. Raise them yourself: an
adapter never raises one for you. [Python](python.md) lists the four that
CPython needs, with the measured values.

`max_heap_words` in a limits map is applied by the process that owns the
instance, when it starts the request's runner (the process that runs the
request). A direct `wasm:call/3` does not apply it, even if you pass the
key.

## Per worker, in the options map

| setting | default | what it controls |
| --- | ---: | --- |
| `root` | `scratch` | which of the reaper's roots the worker's request directories go under |
| `trusted` | `false` | whether a `mode => write` mount is allowed at all |
| `capture_timeout` | 60 s | one snapshot capture and its hooks, at `start_link/2` or `prepare/2`, and nothing before it. CPython needs about 90 s and so must raise it |
| `runner_min_heap_words` | the adapter's | a heap floor for each request's runner: 200,000 words for `wasm_lua` and `wasm_javascript`, 1,500,000 for `wasm_python` on the compiled tier and 1,000,000 on the interpreter, none for an adapter without `defaults/1`. `0` turns it off; see [How a heap floor works](tuning.md#how-a-heap-floor-works) |
| `capture_min_heap_words` | the adapter's | the same, for the process that captures the snapshot. No shipped adapter sets one; see [How a heap floor works](tuning.md#how-a-heap-floor-works) |
| `restore_ahead` | `false` | restore the next request's instance while the worker waits; see [Tuning a worker host](tuning.md). Needs a snapshot capability and imports that are all functions. Each idle worker holds one restored instance: its page table (a list of the image's pages it reads), not a copy of the image |
| `prepared` | unset | an image from `wasm_script_worker:prepare/2`, to start from instead of loading or capturing one. The other options must equal the ones it was prepared with; see [Using workers](worker.md) |
| `compiled` | `false` | `true` runs requests in the compiled tier: it sets `fuel => infinity`, `compile => true`, `compile_after => 1` and `compile_quality => baseline` under your own `limits`. Only the deadline stops a runaway; see [Hosting scripting languages](scripting.md) |

`start_link/2,3` refuses to start in these cases:

- a `root` the reaper does not have: `{error, {unknown_root, Root, Known}}`;
- `compiled => true` with a finite `fuel` in `limits`:
  `{error, {bad_option, compiled, #{fuel => N}}}`;
- a `prepared` image made for other options, another adapter or another
  image: `{error, {bad_option, prepared, Why}}`, where `Why` is
  `options_differ`, `adapter_differs`, `image_differs` or `not_prepared`;
- a `prepared` image that every holder (a process that keeps the image
  alive) has released: the `snapshot_invalidated` error that
  `wasm:acquire/1` returns.

### Prepare one image for a pool

`wasm_script_worker:prepare(Adapter, Opts)` runs the same steps as a worker
start, in a temporary process. It loads the artifact (the WebAssembly
module the adapter runs) and looks for the image in the snapshot store. If the image is
not there, it captures it and saves it in the store.

It returns `{ok, Prepared}`, and the caller holds the image. On failure it
returns the error that `start_link/2` would have returned. An adapter without
snapshots returns `{error, #{class := worker, kind := unsupported}}`.

`wasm_script_worker:release_prepared(Prepared)` releases the caller's hold
and always returns `ok`. Workers started from the image keep their own
hold.

The limits are the same as for a normal start: `capture_timeout` limits the
capture only. Loading the artifact and reading the store happen before it,
and no setting limits them.

## Per node, for the reaper

The reaper cleans up after each request, once the request has been
answered. Configure it in the `wasm` application environment:

| setting | default | what it controls |
| --- | ---: | --- |
| `scratch_roots` | unset | the directories for request files, as `#{RootId => Dir}`. If set, the reaper starts with the application and cleans up what a crashed node left. If unset, it uses a directory that only this node uses, removed at a clean shutdown. Only one node may use each directory |
| `reaper_options` | `#{}` | the settings below, as a map; an unknown key refuses the start |

Inside `reaper_options`:

| setting | default | what it limits |
| --- | ---: | --- |
| `max_cleanup_jobs` | 8 | cleanup jobs running at once |
| `cleanup_queue_len` | 256 | jobs waiting. With `max_cleanup_jobs`, this sets how many requests the reaper accepts (**admission**) |
| `cleanup_retries` | 3 | attempts after the first failure |
| `cleanup_backoff` | 1 s, 4 s, 16 s | between those attempts |
| `cleanup_timeout` | 30 s | **one callback**, not one job |
| `cleanup_job_deadline` | 120 s | the whole job, every callback and action together |
| `max_cleanup_actions` | 64 | actions an adapter may register per request |
| `max_cleanup_operations_per_request` | 256 | cleanup operations (register, withdraw, transfer) one request may run |

The last three are separate limits on purpose. Without them, a job with
eight actions and a `cleanup/1` could use nine callback timeouts, and an
adapter stuck in a loop could register actions until the reaper ran out of
memory.

When the reaper holds `max_cleanup_jobs + cleanup_queue_len` requests,
`submit` returns `{error, #{kind => cleanup_saturated}}`. You can retry it
later. This is better than a leak you cannot see.
`wasm_script_worker:cleanup_stats/0` shows how close you are to the limit.

## Node-wide

Also in the `wasm` application environment:

| setting | default | what it controls |
| --- | ---: | --- |
| `worker_timeout` | 5 s | the deadline `wasm_instance_worker:call/3` uses when you give none |
| `max_snapshot_bytes` | `infinity` | the memory that all snapshot images **keep**, on the whole node. `infinity` means no limit; snapshots still work |
| `snapshot_dir` | unset | where images are kept between restarts. Unset means images live only in memory |
| `max_snapshot_dir_bytes` | 512 MiB | how much **disk** that directory may hold. An image file is 35 KB for Lua and 2.7 MB for CPython |
| `code_cache_dir` | unset | where compiled code is kept. Unset means the compiled tier recompiles on every start |
| `page_limit` | see `wasm_engine` | linear memory pages across every instance on the node |

The runtime removes old files from the snapshot directory **only when it
saves a new image**. So a directory over its limit stays over it until the
next capture, and lowering the setting removes nothing by itself.
`wasm_snapshot_store:purge/0` empties the directory at once.

`max_snapshot_bytes` limits memory and `max_snapshot_dir_bytes` limits disk,
for the same images. [Snapshots](snapshots.md) shows both sizes side by
side.

## Read this next

[Tuning](tuning.md).
