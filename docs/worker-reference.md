# Worker configuration

Every setting the workers take, with its default and what it bounds. Look here
when a guide names a setting, or before production, since a default nobody can
find is a default nobody can change.

## Per request, in the `limits` map

What you hand `wasm_script_worker:start_link/2` as `limits` merges over
`wasm_limits:untrusted/0`, so everything that preset bounds still applies:

| setting | default | what it bounds |
| --- | ---: | --- |
| `timeout` | 5 s | one request, wall clock, enforced by the guardian |
| `max_output_bytes` | 1 MiB | stdout and stderr, each separately; also accepts `#{stdout := N, stderr := M}` |
| `max_result_bytes` | 1 MiB | the dedicated result channel |
| `max_combined_bytes` | 1 MiB | stdout **and** the result together, on `script_v1.combined`, where they share one descriptor |
| `max_request_bytes` | 1 MiB | the source plus the encoded context |
| `max_staged_bytes` | 8 MiB | everything the adapter stages, across all mounts |
| `max_staged_files` | 64 | how many files it stages |

An interpreter needs several of these raised knowingly, and an adapter never
raises one for you: [Python](python.md) has the four CPython needs and what
each was measured at.

`max_heap_words` in a limits map is applied by the process that owns the
instance, when it spawns the request's runner; a direct `wasm:call/3` does not
get it by passing the key.

## Per worker, in the options map

| setting | default | what it bounds |
| --- | ---: | --- |
| `root` | `scratch` | which of the reaper's roots the worker's request directories go under |
| `trusted` | `false` | whether a `mode => write` mount is allowed at all |
| `capture_timeout` | 60 s | one snapshot capture and its hooks, at `start_link/2`. CPython needs about 90 s and so must raise it |
| `runner_min_heap_words` | none | a heap floor for each request's runner; see [Hosting scripting languages](scripting.md) |
| `capture_min_heap_words` | none | the same, for the process that captures the snapshot |

`start_link/2,3` refuses a `root` the reaper does not have, with
`{error, {unknown_root, Root, Known}}`.

## Per node, for the reaper

The reaper cleans up after requests, after they have been answered. Configure
it in the `wasm` application environment:

| setting | default | what it bounds |
| --- | ---: | --- |
| `scratch_roots` | unset | the directories request files go in, as `#{RootId => Dir}`. Set, the reaper starts with the application and recovers what a crashed node left; unset, it uses a directory of this node's own, removed at a clean shutdown. One node per directory |
| `reaper_options` | `#{}` | the settings below, as a map; an unknown key refuses the start |

Inside `reaper_options`:

| setting | default | what it bounds |
| --- | ---: | --- |
| `max_cleanup_jobs` | 8 | cleanup jobs running at once |
| `cleanup_queue_len` | 256 | jobs waiting; with the above, what **admission** counts against |
| `cleanup_retries` | 3 | attempts after the first failure |
| `cleanup_backoff` | 1 s, 4 s, 16 s | between those attempts |
| `cleanup_timeout` | 30 s | **one callback**, not one job |
| `cleanup_job_deadline` | 120 s | the whole job, every callback and action together |
| `max_cleanup_actions` | 64 | actions an adapter may register per request |
| `max_cleanup_operations_per_request` | 256 | cleanup operations (register, withdraw, transfer) one request may run |

The last three are different bounds on purpose: a job with eight actions and a
`cleanup/1` could otherwise spend nine callback timeouts, and an adapter in a
loop could register actions until the reaper's memory was the bound.

When the requests the reaper holds reach `max_cleanup_jobs +
cleanup_queue_len`, `submit` answers `{error, #{kind => cleanup_saturated}}`:
a refusal you can retry, rather than a leak you cannot see.
`wasm_script_worker:cleanup_stats/0` shows how close you are.

## Node-wide

Also in the `wasm` application environment:

| setting | default | what it bounds |
| --- | ---: | --- |
| `worker_timeout` | 5 s | the deadline `wasm_instance_worker:call/3` uses when you give none |
| `max_snapshot_bytes` | `infinity` | what every snapshot image **retains** in memory, across the node. `infinity` means unbounded, not off |
| `snapshot_dir` | unset | where images are kept between restarts. Unset means images live only in memory |
| `max_snapshot_dir_bytes` | 512 MiB | how much **disk** that directory may hold. An image file is 35 KB for Lua and 2.7 MB for CPython |
| `code_cache_dir` | unset | where compiled code is kept. Unset means the compiled tier recompiles on every start |
| `page_limit` | see `wasm_engine` | linear memory pages across every instance on the node |

The snapshot directory is trimmed **when an image is filed and at no other
time**, so a directory over its cap stays over it until the next capture, and
lowering the setting shrinks nothing by itself; `wasm_snapshot_store:purge/0`
empties it now. `max_snapshot_bytes` and `max_snapshot_dir_bytes` bound
different things for the same image, memory and disk; [Snapshots](snapshots.md)
has the sizes side by side.
