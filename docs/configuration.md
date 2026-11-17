# Configuration

This page lists every setting in one place, with its default and the page
that explains it. Read it when you deploy the runtime, and when you tune it:
you can only change a default that you know about. There are four kinds of
setting: the application environment, for the whole node; the limits map,
for one instance; the instantiate options; and the worker options.

## Settings for production

Most nodes need only two settings. Put them in your release's `sys.config`:

```erlang
%% sys.config
[{wasm, [{scratch_roots, #{scratch => "/var/lib/myapp/wasm-scratch"}},
         {code_cache_dir, "/var/lib/myapp/wasm-code"}]}].
```

`scratch_roots` is where request files live. When a node restarts after a
crash, it cleans up there what the crashed node left behind. `code_cache_dir`
keeps compiled code across restarts. Make both directories writable only by
the node's user: see [Security](security.md).

## The application environment

Set these in `sys.config`, under `wasm`, or with
`application:set_env(wasm, Key, Value)` before the runtime reads them. The
module cache and the page budget read theirs when the application starts.

### Memory and modules

| key | default | what it controls | read |
| --- | ---: | --- | --- |
| `page_limit` | 16384 pages (1 GiB) | linear memory and object stores across every instance on the node. Change it while the node runs with `wasm_engine:set_page_limit/1` | [Memory](memory.md#the-node-page-budget) |
| `table_grow_limit` | 16,777,216 entries | the largest one table may become | [Memory](memory.md#the-node-page-budget) |
| `max_rec_groups` | 100,000 | distinct recursive type groups stored for the whole node; they are never freed | [Security](security.md#what-limits-bound) |
| `max_module_bytes` | 64 MiB | the size of one module's input, checked before it is decoded | [Security](security.md#what-limits-bound) |
| `max_module_loads_per_second` | 50 | new modules the module cache decodes in one second. Past it: `{error, {load_rate_exceeded, 50}}` | [Design principles](design-principles.md#modules-are-loaded-once) |
| `max_resident_modules` | 256 | modules the cache holds at once, counting those being decoded. Past it: `{error, {too_many_modules, 256}}` | [Design principles](design-principles.md#modules-are-loaded-once) |
| `max_resident_module_bytes` | 2 GiB | the memory the cached modules hold together. Past it: `{error, {module_cache_full, Bytes}}` | [Security](security.md#what-limits-bound) |

### Files and WASI

| key | default | what it controls | read |
| --- | ---: | --- | --- |
| `require_native_fs` | `false` | `true` refuses every directory grant when the file NIF is not loaded, so a guest gets no file system rather than the pure Erlang one | [WASI](wasi.md#symlinks-and-which-backend-you-have) |
| `scratch_roots` | unset | the directories for request files, as `#{RootId => Dir}`. Set, the reaper starts with the application and cleans what a crashed node left | [Worker configuration](worker-reference.md#per-node-for-the-reaper) |
| `reaper_options` | `#{}` | the reaper's limits: jobs, queue, retries, timeouts | [Worker configuration](worker-reference.md#per-node-for-the-reaper) |
| `worker_timeout` | 5000 ms | the deadline `wasm_instance_worker:call/3` uses, and its start function when `limits` has no `timeout` | [Using workers](worker.md#limit-the-work-and-the-time) |

### The compiled tier

| key | default | what it controls | read |
| --- | ---: | --- | --- |
| `code_cache_dir` | unset | where compiled code is kept across restarts. Unset, the tier compiles again at every start | [The compiled tier](compiled-tier.md) |
| `compile_max_heap_words` | unset, no ceiling | the most memory one compile may use, in words | [The compiled tier](compiled-tier.md#limit-the-memory-one-compile-may-use) |
| `compile_budget_heap_words` | unset, no budget | the most memory all compiles may use together, in words; works only with `compile_max_heap_words` | [The compiled tier](compiled-tier.md#limit-the-memory-all-compiles-may-use-together) |

### Snapshots

| key | default | what it controls | read |
| --- | ---: | --- | --- |
| `snapshot_dir` | unset | where images are kept between restarts. Unset, images live only in memory | [Snapshots](snapshots.md#keep-images-across-restarts) |
| `max_snapshot_bytes` | `infinity` | the memory all snapshot images keep, on the whole node | [Snapshots](snapshots.md) |
| `max_snapshot_dir_bytes` | 512 MiB | the disk `snapshot_dir` may hold | [Snapshots](snapshots.md#keep-images-across-restarts) |
| `max_snapshot_stored_bytes` | 256 MiB | the largest image file the runtime reads, as stored | `wasm_snapshot_file` |
| `max_snapshot_inflated_bytes` | 1 GiB | the largest image once decompressed | `wasm_snapshot_file` |
| `max_snapshot_decode_depth` | 64 | how deeply nested a value in an image file may be | `wasm_snapshot_file` |
| `max_snapshot_decode_nodes` | 16,000,000 | how many values one image file may hold | `wasm_snapshot_file` |

The last four protect the node from a damaged or planted image file. A
value that is not a positive integer refuses the read with
`snapshot_config_invalid`.

### Internal settings

These exist, but they are not supported API: they may change or go away in
any release. Leave them at their defaults.

| key | what it is |
| --- | --- |
| `compile_retry_seconds` | how long the compiled tier waits before it asks again for a compile that was lost; 60 s |
| `gc_alloc_threshold`, `gc_major_ratio`, `gc_min_major_size`, `gc_min_major_pages` | the collector's thresholds, described in [Garbage collection](gc.md#two-generations) |
| `compile_budget_words` | an old key, read only to log that it is ignored; use `compile_budget_heap_words` |
| `heap_hook`, `keeper_hook`, `build_hook`, `wait_claim_hook`, `poll_wait_cap_ms` | read only by test builds of the runtime |

## The limits map

Pass these to `wasm:instantiate/3` with the other options, or start from a
preset. A key you leave out takes the value in the first column.

| key | left out | `untrusted()` | `trusted()` | what it limits |
| --- | ---: | ---: | ---: | --- |
| `fuel` | `infinity` | 10,000,000 | `infinity` | work: charged at each call and each jump back to the start of a loop. Compiled code does not count it |
| `timeout` | none | 1000 ms | `infinity` | wall-clock time per call, in milliseconds. Only a worker can apply it, so a direct call ignores it; a worker without one uses its own default |
| `max_depth` | 1024 | 256 | 8192 | WebAssembly call depth |
| `max_memory_pages` | `infinity` | 256 (16 MiB) | `infinity` | every memory the instance can reach, imported ones included, and its share of the object store |
| `max_host_calls` | `infinity` | 10,000 | `infinity` | calls out through an import, per call |
| `max_heap_words` | none | 8,388,608 (64 MiB) | none | the owning process's own heap. A direct call ignores it; a worker applies it |

The presets are `wasm_limits:untrusted/0` and `wasm_limits:trusted/0`. A
value that cannot mean what it says, such as `#{fuel => -1}`, is refused
with `invalid_limits`. A worker merges your `limits` over `untrusted()` and
adds its own output limits; see
[Worker configuration](worker-reference.md#per-request-in-the-limits-map).
[Security](security.md#what-limits-bound) says what each limit bounds, and
`wasm_limits` what limits cannot do.

## Instantiate options

`wasm:instantiate/3` takes the limits above and these options in one map:

| key | default | what it does | read |
| --- | ---: | --- | --- |
| `profile` | none | `plugin` or `script`: sets the compile options below for that kind of workload. An option you set yourself wins | [The compiled tier](compiled-tier.md#choose-a-profile-instead-of-setting-each-option) |
| `compile` | `false` | `true` turns on the compiled tier for this instance | [The compiled tier](compiled-tier.md#turn-it-on) |
| `compile_after` | 32 | how many calls of the module before its hot functions compile | [The compiled tier](compiled-tier.md#turn-it-on) |
| `compile_quality` | `full` | `baseline` compiles about twice as fast and runs about 14% slower | [The compiled tier](compiled-tier.md#short-notes) |
| `link` | none | an instance to share a garbage-collected object store with | `wasm:instantiate/3` |
| `snapshotable` | `false` | `true` makes the instance capturable with `wasm:snapshot/1` | [Snapshots](snapshots.md#capture-one) |
| `snapshot_hooks` | `#{}` | what your imports hold, so a capture can check it | [Snapshots](snapshots.md#declare-what-your-imports-hold) |

`compile_shards`, `compile_sync`, `compile_whole`, `compile_force` and
`fuse` are also read from this map. They exist for tests and measurement,
are not supported API, and `compile_force` makes a failed compile raise. See
[Design principles](design-principles.md#options-say-what-you-know-never-how-to-do-it).

`wasm_component:instantiate/3` passes the same limits to every core module
of the component, and reads these options itself:

| key | default | what it does | read |
| --- | ---: | --- | --- |
| `loader` | `load` while the application runs, else `compile` | `load` builds core modules through the module cache; `compile` builds them inline, outside the load rate | `wasm_component:instantiate/3` |
| `resource_limit` | `infinity` | the most host resource handles live at once, and async calls waiting at once. Past it: a trap, `resource_limit_reached` | [Component internals](component-internals.md#resources-and-host-handles) |
| `resource_closer`, `resource_predrop` | none | functions the runtime calls when the guest drops a host resource | [Component internals](component-internals.md#resources-and-host-handles) |

The WASI hosts take their own options, such as directories, environment and
network: see [WASI](wasi.md), [WASI 0.2](wasi-0-2.md) and
[WASI 0.3](wasi-0-3.md).

## Worker options

`wasm_instance_worker:start_link/2` takes four:

| key | default | what it does |
| --- | ---: | --- |
| `imports` | `#{}` | the imports of the instance |
| `limits` | `#{}` | the limits map above; `timeout` is the deadline of the start function |
| `isolation` | `fresh` | `fresh` builds a new instance for every request; `reuse` keeps one |
| `name` | none | a label that `info/1` gives back; the worker is not registered under it |

`wasm_script_worker` has more, per request and per worker:
[Worker configuration](worker-reference.md) lists each one with its default.

## Read this next

[Worker configuration](worker-reference.md) for the worker settings,
[Security](security.md) for what the limits do not cover, and
[Tuning](tuning.md) once you have measured.
