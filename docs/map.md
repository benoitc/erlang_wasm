# Where things are

This page tells you where each part of erlang_wasm lives: every directory,
every module with what it does, and for each area of the runtime the module
where a call enters, what configures it, where you extend it, the suites that
test it and the page to read. Use it when you are about to change the runtime
and need to find the code, or when you have a behaviour and want its tests.

A module is **supported** when you may call it and rely on it; a change that
breaks it is in the changelog. An **extension point** is a behaviour:
callbacks your own module exports so the runtime can call them. Everything
else is **internal** and may change in any release.
[Start here](start-here.md#supported-api) has the full statement, including
the few internal functions a guide documents.

`wasm_architecture_SUITE` checks that every module appears on this page.

## The source tree

| directory | what it holds |
| --- | --- |
| `src/` | the core runtime: front end, instances, interpreter, memory, compiled tier, supervision |
| `src/component/` | the Component Model: decoding, linking, the Canonical ABI |
| `src/wasi/` | WASI preview 1, WASI 0.2, WASI 0.3, sockets and HTTP |
| `src/worker/` | the workers, the language adapters and request cleanup |
| `include/` | shared records and constants |
| `c_src/` | the optional file NIF, `wasi_file_nif.c` |
| `priv/script_v1/` | the boot scripts the shipped JavaScript and Python adapters load |
| `examples/` | `plugin_worker`, `qjs_worker` and `nn_upper`, three demonstrations to read and copy |
| `test/` | every Common Test suite, one `*_SUITE.erl` each |
| `test/support/` | what suites share: fake adapters, the conformance runners, `wasm_asm` |
| `test/fixtures/` | the WebAssembly files suites load; [Fixtures](contributing/fixtures.md) says where each comes from |
| `test/audit/` | the measurement record: `PERF.md`, `ATTEMPTS.md` and the reviews |
| `bench/` | the benchmark arms; `bench/paths/README.md` says what each measures |
| `scripts/` | build and fetch scripts for the NIF and the fixtures, and the dependency audit |
| `docs/` | the pages the documentation site is built from |

The folders under `src/` are for finding modules. They are not namespaces:
every module is prefixed `wasm_` or `wasi_`, and the build compiles them all
into one application.

### `src/`: the front end

| module | what it does | status |
| --- | --- | --- |
| `wasm_decode` | WebAssembly binary format decoder | internal |
| `wasm_decode_code` | instruction and expression decoding | internal |
| `wasm_decode_simd` | the `0xFD` opcode space: fixed-width SIMD | internal |
| `wasm_decode_gc` | the `0xFB` opcode space: garbage collection | internal |
| `wasm_decode_atomic` | the `0xFE` opcode space: threads | internal |
| `wasm_leb128` | LEB128 varint decoding, strict per the binary format | internal |
| `wasm_validate` | module-level validation | internal |
| `wasm_validate_code` | function body validation | internal |
| `wasm_validate_simd` | operand types for the `0xFD` vector opcode space | internal |
| `wasm_validate_atomic` | types and alignment for the `0xFE` opcode space | internal |
| `wasm_types` | type identity: when two declared types are the same type | internal |
| `wasm_wat` | the text format, parsed into the same `#module{}` the decoder produces | internal |
| `wasm_wat_lex` | tokens of the text format | internal |
| `wasm_wat_sexp` | tokens to a tree, and where your parenthesis is missing | internal |
| `wasm_wat_num` | numeric literals of the text format | internal |
| `wasm_wat_instr` | what immediate an instruction takes, by name | internal |
| `wasm_wast` | specification scripts: the `.wast` format the conformance suite uses | internal |

### `src/`: the runtime

| module | what it does | status |
| --- | --- | --- |
| `wasm` | the front door: every public operation on a module or an instance | supported |
| `wasm_limits` | resource limits, and what they do not cover | supported |
| `wasm_engine` | node-wide resource accounting, including the page budget | supported |
| `wasm_error` | structured errors and traps | supported |
| `wasm_instance` | instantiation: a validated module made executable | internal |
| `wasm_exec` | the interpreter | internal |
| `wasm_memory` | linear memory backed by chunked `atomics` arrays | internal; `new/1` supported |
| `wasm_table` | tables, with reference semantics | internal |
| `wasm_global` | mutable globals that two instances can share | internal |
| `wasm_heap` | the garbage-collected object store | internal |
| `wasm_keeper` | the authority on who still holds a shared resource | internal |
| `wasm_wait` | `memory.atomic.wait` and `memory.atomic.notify` | internal |
| `wasm_lifetime` | makes a spawned process die with the process responsible for it | internal |
| `wasm_module_cache` | compiled modules, cached node-wide and keyed by content hash | internal |
| `wasm_file_cache` | a directory of files, bounded by total size, oldest first | internal |
| `wasm_snapshot` | initialized runtime snapshots: an immutable copy of a started guest | internal |
| `wasm_snapshot_owner` | one process per snapshot, holding what a term cannot hold | internal |
| `wasm_snapshot_file` | the on-disk form of a snapshot | internal |
| `wasm_snapshot_store` | a directory of snapshot images, keyed by what makes one valid | internal; `purge/0` supported |

### `src/`: numerics

| module | what it does | status |
| --- | --- | --- |
| `wasm_num` | conversion between IEEE 754 bit patterns and the runtime float form | internal |
| `wasm_num_float` | floating-point arithmetic over that representation | internal |
| `wasm_num_trunc` | float to integer truncation, both families | internal |
| `wasm_simd` | fixed-width SIMD: `v128` values and the operations on them | internal |

### `src/`: the compiled tier

| module | what it does | status |
| --- | --- | --- |
| `wasm_jit` | when a module gets compiled, and how a call reaches the result | internal; a few functions supported |
| `wasm_core` | the Core Erlang back end: generates and compiles the forms | internal |
| `wasm_code_slots` | who still uses a piece of generated code, and when its slot is reused | internal |
| `wasm_code_cache` | compiled code kept on disk across node restarts | internal; `purge/0` supported |
| `wasm_jit_sup` | the processes that compile modules, under supervision | internal |

### `src/`: the application

| module | what it does | status |
| --- | --- | --- |
| `wasm_app` | application callback | internal |
| `wasm_sup` | root supervisor | internal |
| `wasm_subsup` | one subsystem, with a restart budget of its own | internal |
| `wasm_store` | owns every long-lived ETS table, and does nothing else | internal |

### `src/component/`

| module | what it does | status |
| --- | --- | --- |
| `wasm_component` | decode and run a component: the Component Model's entry point | supported |
| `wasm_component_link` | reads a component's wiring and builds its cores | internal |
| `wasm_component_types` | decodes a component's type section into value descriptors | internal |
| `wasm_canon` | the Canonical ABI lift and lower for component values | internal |
| `wasm_resources` | per-component-instance resource handle tables | internal |
| `wasm_async` | the async Canonical ABI runtime | internal; `host_read/3`, `host_sink/2` supported |
| `wasm_recipe` | builds a component from a recipe | internal |

### `src/wasi/`

| module | what it does | status |
| --- | --- | --- |
| `wasi` | runs a WASI command and gives back its exit status and output | supported |
| `wasi_preview1` | WASI preview 1, as an Erlang host interface | supported |
| `wasi_fs` | file access for WASI, over whichever backend is available | internal; `backend/0` supported |
| `wasi_path` | capability-scoped path resolution | internal |
| `wasi_file_nif` | optional native file access that closes the WASI path race | internal |
| `wasi_net` | the network capability | internal |
| `wasi_sock` | sockets, as WASI descriptors | internal |
| `wasi_preview2` | the WASI 0.2 host: the `wasi:*` interfaces a component imports | supported |
| `wasi_p2_filesystem` | the `wasi:filesystem` part of the WASI 0.2 host | internal |
| `wasi_p2_sockets` | the `wasi:sockets` part of the WASI 0.2 host | internal |
| `wasi_sock2` | the TCP backend for `wasi:sockets`, over OTP's `socket` module | internal |
| `wasi_nn` | the `wasi:nn` host, and the behaviour an inference backend implements | supported |
| `wasi_preview3` | the WASI 0.3 host | supported |
| `wasi_p3_filesystem` | `wasi:filesystem` at 0.3, over the same preopened descriptors | internal |
| `wasi_p3_sockets` | `wasi:sockets` at 0.3, the same sockets under the same grant | internal |
| `wasi_p3_http` | `wasi:http` at 0.3 | internal |
| `wasi_http` | the outbound path of `wasi:http@0.2` and its resources | supported |
| `wasi_http_listener` | a live HTTP server that serves a `wasi:http` component | supported |
| `wasi_http_transport` | the pluggable transport behind `wasi:http` | extension point |
| `wasi_http_h1` | the HTTP/1.1 transport, over the `h1` client | supported |
| `wasi_http_h2` | the HTTP/2 transport, over the `h2` client | supported |

### `src/worker/`

| module | what it does | status |
| --- | --- | --- |
| `wasm_instance_worker` | a worker owning one WebAssembly instance | supported |
| `wasm_script_worker` | the worker kernel: processes, deadlines, bounded streams, an adapter | supported |
| `wasm_worker_adapter` | the behaviour that teaches the kernel one language | extension point |
| `wasm_worker_error` | the worker's error type, and the closed set of its kinds | supported |
| `wasm_adapter_conformance` | the case list an adapter must pass, run from Common Test | supported |
| `wasm_javascript` | JavaScript from an image of an already-started engine | supported |
| `wasm_javascript_command` | JavaScript that arrives at request time | supported |
| `wasm_python` | Python from an image of an already-started interpreter | supported |
| `wasm_python_command` | Python that arrives at request time | supported |
| `wasm_lua` | Lua from an image of an already-started interpreter | supported |
| `wasm_script_v1` | the `script_v1` profile the shipped adapters speak | internal |
| `wasm_worker_fs` | the file operations a request makes, in the calling process | internal |
| `wasm_worker_images` | the images script workers share, node-wide | internal |
| `wasm_worker_reaper` | who cleans up after a request when its owner is gone | internal |
| `wasm_worker_sup` | supervises the reaper, so a worker needs nobody to start one | internal |
| `wasm_cleanup_manager` | the node-wide cleanup manager | internal |
| `wasm_cleanup_steward` | the per-request cleanup steward | internal |
| `wasm_cleanup_steward_sup` | the dynamic supervisor for cleanup stewards | internal |

## Find the area you are changing

Each row is one area of the runtime. **Enter at** is where a call comes in.
**Configured by** names the options and application settings that change its
behaviour. **Extend through** is where your own code plugs in, if anywhere.
Every suite named is a file in `test/`.

| area | enter at | modules | configured by | extend through | tests | read |
| --- | --- | --- | --- | --- | --- | --- |
| Binary decode | `wasm:compile/2` | `wasm_decode`, `wasm_decode_code`, `wasm_decode_simd`, `wasm_decode_gc`, `wasm_decode_atomic`, `wasm_leb128` | `max_module_bytes` | none | `wasm_spec_SUITE`, `wasm_decode_immediates_SUITE`, `wasm_decode_retain_SUITE`, `wasm_prop_SUITE` | [Adding an instruction](contributing/adding-an-instruction.md) |
| Validation and type identity | `wasm:compile/2`, `wasm:validate/1` | `wasm_validate`, `wasm_validate_code`, `wasm_validate_simd`, `wasm_validate_atomic`, `wasm_types` | `max_rec_groups` | none | `wasm_spec_SUITE`, `wasm_validate_scalar_SUITE`, `wasm_annotate_SUITE`, `wasm_prop_SUITE` | [Adding an instruction](contributing/adding-an-instruction.md) |
| Text format and wast | `wasm:compile({wat, Source})`, `wasm_wast:script/1` | `wasm_wat`, `wasm_wat_lex`, `wasm_wat_sexp`, `wasm_wat_num`, `wasm_wat_instr`, `wasm_wast` | none | none | `wasm_wat_SUITE`, `wasm_wat_lex_SUITE`, `wasm_wast_SUITE` | [Features and conformance](features.md#specification-test-suite) |
| Instantiate and link | `wasm:instantiate/3`, then `wasm_instance:new/3` | `wasm_instance`, `wasm_table`, `wasm_global` | instantiate options; `table_grow_limit` | host functions | `wasm_linking_SUITE`, `wasm_funcref_SUITE`, `wasm_scale_SUITE` | [Hold modules and instances](embedding.md), [Host functions](host-functions.md) |
| Interpreter | `wasm:call/3` | `wasm_exec`, `wasm_num`, `wasm_num_float`, `wasm_num_trunc`, `wasm_simd` | none | none | `wasm_spec_SUITE`, `wasm_num_SUITE`, `wasm_simd_SUITE`, `wasm_relaxed_simd_SUITE`, `wasm_tailcall_SUITE`, `wasm_exception_SUITE`, `wasm_native_SUITE` | [The path of a call](architecture.md#the-path-of-a-call) |
| Limits | the limits map of `wasm:instantiate/3`, or of one call | `wasm_limits`, `wasm_exec` | the limits map, or a `wasm_limits` preset | none | `wasm_budget_SUITE`, `wasm_trap_effects_SUITE` | [Hold modules and instances](embedding.md#set-limits) |
| The error model | every call that can fail | `wasm_error` | none | none | `wasm_trap_effects_SUITE`, `wasm_prop_SUITE`, `wasm_component_malformed_SUITE` | [Concepts](concepts.md#guest-errors-are-returned-as-values) |
| Threads and atomics | a shared memory from `wasm_memory:new/1`; `memory.atomic.wait` | `wasm_wait`, `wasm_decode_atomic`, `wasm_validate_atomic`, `wasm_memory` | none | none | `wasm_threads_SUITE`, `wasm_spec_SUITE` | [Features and conformance](features.md#threads) |
| GC proposal | the struct, array and `i31` instructions | `wasm_heap`, `wasm_decode_gc` | `gc_alloc_threshold` and the other settings in the GC page | none | `wasm_gc_SUITE`, `wasm_gc_collect_SUITE`, `wasm_gc_lease_SUITE`, `wasm_gc_roots_SUITE` | [Garbage collection](gc.md) |
| Memory and the page budget | `wasm_memory:new/1`, `wasm_memory:grow/2` | `wasm_memory`, `wasm_keeper`, `wasm_engine` | `wasm_engine:set_page_limit/1` | none | `wasm_resource_SUITE`, `wasm_shared_pages_SUITE`, `wasm_paged_memory_SUITE`, `wasm_memory64_SUITE` | [Memory](memory.md) |
| Compiled tier | `wasm_jit:entry/3`, `wasm_jit:after_call/2` | `wasm_jit`, `wasm_core`, `wasm_code_slots`, `wasm_code_cache`, `wasm_jit_sup` | `compile`, `profile`, `code_cache_dir` | none | `wasm_core_SUITE`, `wasm_core_prop_SUITE`, `wasm_jit_lifetime_SUITE`, `wasm_jit_bounds_SUITE`, `wasm_code_slots_SUITE`, `wasm_paged_memory_SUITE`, `wasm_spec_SUITE` | [The compiled tier](compiled-tier.md), [Compiled tier internals](compiled-tier-internals.md) |
| Snapshots | `wasm:snapshot/2`, `wasm:restore/3` | `wasm_snapshot`, `wasm_snapshot_owner`, `wasm_snapshot_file`, `wasm_snapshot_store` | `max_snapshot_bytes`, `snapshot_dir`, `max_snapshot_dir_bytes` | `snapshot_hooks` | `wasm_snapshot_SUITE`, `wasm_component_snapshot_SUITE` | [Snapshots](snapshots.md) |
| Module and file cache | `wasm:load/1` | `wasm_module_cache`, `wasm_file_cache` | `max_resident_modules`, `max_resident_module_bytes`, `max_module_loads_per_second` | none | `wasm_module_cache_SUITE`, `wasm_file_cache_SUITE` | [Hold modules and instances](embedding.md#load-modules-once-at-startup) |
| Application and supervision | `application:ensure_all_started(wasm)` | `wasm_app`, `wasm_sup`, `wasm_subsup`, `wasm_store`, `wasm_lifetime` | none | none | `wasm_lifetime_SUITE`, `wasm_worker_sup_SUITE`, `wasm_architecture_SUITE` | [The supervision tree](architecture.md#the-supervision-tree) |
| WASI preview 1 | `wasi_preview1:imports/1`, `wasi:run/2` | `wasi`, `wasi_preview1`, `wasi_fs`, `wasi_path`, `wasi_net`, `wasi_sock`, `wasi_file_nif` | the WASI options; `require_native_fs` | the optional file NIF | `wasi_SUITE`, `wasi_net_SUITE`, `wasi_net_escape_SUITE`, `wasi_sock_SUITE`, `wasi_sock_ext_SUITE`, `wasi_random_SUITE`, `wasi_nif_SUITE`, `wasi_nul_path_SUITE`, `wasi_conformance_SUITE`, `wasm_rust_SUITE` | [WASI preview 1](wasi.md), [Changing the NIF](contributing/nif.md) |
| Components | `wasm_component:instantiate/2`, `wasm_component:call/4` | `wasm_component`, `wasm_component_link`, `wasm_component_types`, `wasm_canon`, `wasm_resources`, `wasm_async`, `wasm_recipe` | the imports map | `wasm_component:import_fun/2` | `wasm_component_SUITE`, `wasm_component_link_SUITE`, `wasm_component_import_SUITE`, `wasm_component_iface_SUITE`, `wasm_component_resource_SUITE`, `wasm_component_string_SUITE`, `wasm_component_vectors_SUITE`, `wasm_component_version_SUITE`, `wasm_component_compose_SUITE`, `wasm_component_malformed_SUITE`, `wasm_component_async_SUITE`, `wasm_component_async_abi_SUITE`, `wasm_component_async_import_SUITE`, `wasm_component_async_tasks_SUITE`, `wasm_component_forward_SUITE`, `wasm_component_wast_SUITE`, `wasm_component_coop_threads_SUITE`, `wasm_canon_prop_SUITE`, `wasm_resources_SUITE`, `wasm_recipe_SUITE` | [Components](components.md), [Component internals](component-internals.md) |
| WASI 0.2 | `wasi_preview2:imports/0`, `wasi_preview2:run_command/2` | `wasi_preview2`, `wasi_p2_filesystem`, `wasi_p2_sockets`, `wasi_sock2` | the `wasi_preview2` options | none | `wasm_wasi2_clocks_SUITE`, `wasm_wasi2_env_SUITE`, `wasm_wasi2_fs_SUITE`, `wasm_wasi2_in_SUITE`, `wasm_wasi2_io_SUITE`, `wasm_wasi2_iofull_SUITE`, `wasm_wasi2_random_SUITE`, `wasm_wasi2_sockets_SUITE`, `wasm_wasi2_tcp_SUITE`, `wasm_wasi2_udp_SUITE`, `wasm_wasi2_real_SUITE`, `wasm_wasi2_conformance_SUITE`, `wasm_wasi2_adapter_SUITE`, `wasm_wasi2_testsuite_SUITE`, `wasm_wasi2_p2_SUITE`, `wasm_wasi2_async_SUITE` | [WASI 0.2](wasi-0-2.md) |
| WASI 0.3 | `wasi_preview3:run_command/3`, `wasi_preview3:run_serve/3` | `wasi_preview3`, `wasi_p3_filesystem`, `wasi_p3_sockets`, `wasi_p3_http` | the `wasi_preview3` options | none | `wasm_wasi3_p3_SUITE` | [WASI 0.3](wasi-0-3.md) |
| HTTP | `wasi_http:http/1`, `wasi_http_listener:start/1` | `wasi_http`, `wasi_http_listener`, `wasi_http_transport`, `wasi_http_h1`, `wasi_http_h2` | `http_transport` | the `wasi_http_transport` behaviour | `wasm_wasi2_http_SUITE`, `wasm_wasi2_https_SUITE`, `wasm_wasi2_http_limits_SUITE`, `wasm_wasi2_serve_SUITE` | [HTTP](http.md) |
| wasi-nn | `wasi_nn:imports/1`, the `nn` option of `wasi_preview2:command/1` | `wasi_nn` | `nn` | the `wasi_nn` behaviour | `wasm_wasi2_nn_SUITE`, `wasm_wasi2_nn_wasmtime_SUITE` | [wasi-nn](wasi-nn.md) |
| Instance workers | `wasm_instance_worker:start_link/1`, `wasm_instance_worker:call/3` | `wasm_instance_worker` | `worker_timeout` | none | `wasm_worker_SUITE` | [Using workers](worker.md) |
| Script workers | `wasm_script_worker:start_link/2`, `wasm_script_worker:run/2` | `wasm_script_worker`, `wasm_worker_adapter`, `wasm_worker_error`, `wasm_script_v1`, `wasm_worker_fs`, `wasm_worker_images` | worker options; `scratch_roots` | the `wasm_worker_adapter` behaviour | `wasm_worker_kernel_SUITE`, `wasm_component_worker_SUITE` | [Using workers](worker.md), [Worker internals](worker-internals.md), [Worker configuration](worker-reference.md) |
| Worker cleanup | internal: every script worker request goes through it | `wasm_cleanup_manager`, `wasm_cleanup_steward`, `wasm_cleanup_steward_sup`, `wasm_worker_reaper`, `wasm_worker_sup` | `reaper_options`, `scratch_roots` | none | `wasm_cleanup_manager_SUITE`, `wasm_cleanup_steward_SUITE`, `wasm_worker_sup_SUITE`, `wasm_worker_kernel_SUITE` | [Worker internals](worker-internals.md#cleanup-goes-through-a-steward), then `test/audit/CLEANUP_STEWARD.md` |
| Language adapters | `wasm_script_worker:start_link/2` with an adapter module | `wasm_javascript`, `wasm_javascript_command`, `wasm_python`, `wasm_python_command`, `wasm_lua`, `wasm_adapter_conformance` | the adapter's options | a new adapter, through `wasm_worker_adapter` | `wasm_worker_lang_SUITE`, `wasm_lang_SUITE` | [Hosting scripting languages](scripting.md), [Writing an adapter](worker-contract.md) |
| Build, packaging, the NIF | `rebar.config`, `scripts/` | `c_src/` | `WASM_NIF_SANITIZE`, `WASM_NIF_CFLAGS` | none | `wasm_package_SUITE`, `wasm_scripts_SUITE`, `wasi_nif_SUITE` | [Changing the NIF](contributing/nif.md) |
| These docs | `docs/`, the module docs, `examples/` | none | `rebar.config` `ex_doc` | none | `wasm_docs_SUITE`, `wasm_architecture_SUITE`, `wasm_examples_SUITE` | [CONTRIBUTING.md](../CONTRIBUTING.md) |
| Benchmarks and evidence | `bench/paths/`, `rebar3 bench` | none | none | none | `wasm_bench_SUITE`, `wasm_gc_bench_SUITE` (their `bench` group) | [Measuring](contributing/measuring.md), `test/audit/PERF.md` |

## Find the tests for a behaviour

Suites are named after what they test: `wasm_<area>_SUITE` for the runtime,
`wasi_<area>_SUITE` for WASI preview 1, `wasm_wasi2_<interface>_SUITE` for
WASI 0.2, `wasm_wasi3_p3_SUITE` for WASI 0.3 and `wasm_component_<topic>_SUITE`
for components. Each opens by saying what it covers.

1. Find the area in the table above and read its suites' headers.
2. To find every suite that calls a module, search `test/` for it:

   ```sh
   grep -l "wasm_heap:" test/*_SUITE.erl
   ```

3. To find the case for one rule, search for a word of it. Case names are
   sentences, such as `parent_traversal_is_refused`:

   ```sh
   grep -n "traversal" test/wasi_SUITE.erl
   ```

4. Run what you found, then the case alone:

   ```sh
   rebar3 ct --suite=test/wasi_SUITE --case=parent_traversal_is_refused
   ```

Some suites need a fixture or a tool and skip without it.
[Testing](contributing/testing.md) says which, and
[Fixtures](contributing/fixtures.md) how to get each one.

## Read this next

[Architecture](architecture.md) for how the modules depend on each other and
the path of one call, then the [recipe](contributing/recipes.md) for your
change.
