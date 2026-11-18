# Upgrading

This page tells you what to change in your code when you move to a newer
release. Read it before each upgrade. The [changelog](../CHANGELOG.md) lists
everything that changed; this page lists only the changes that can break your
code, and what to write instead. Releases are newest first. A release that is
not on this page needs no change in your code.

## Unreleased

**Network and HTTP.**

| what changed | what to change |
| --- | --- |
| `wasi_http_listener:start/1` listens on `127.0.0.1` unless you say otherwise. It used to listen on every interface | to accept connections from other machines, add `ip => {0, 0, 0, 0}` to its options |
| the listener answers 408 to a request body that takes more than `request_timeout` (60 s), 413 to one over `max_body_bytes` (8 MiB), and 504 when the guest is still running at the deadline | pass larger `request_timeout` or `max_body_bytes` values to `wasi_http_listener:start/1` if your requests need them |
| every HTTP body the host holds is limited to 8 MiB, and a larger response a guest receives fails with `HTTP-response-body-size` | pass `http_max_body_bytes` to `wasi_preview2:command/1` and the other runners if your bodies are larger |
| a `wasi:http` request to a host name is checked against the addresses the name resolves to | add `resolve => allow` to the network grant of a guest that calls hosts by name |
| `fuel`, `max_depth`, `max_memory_pages`, `max_heap_words` and `max_host_calls` passed to `wasi_preview2:run_serve/3`, `run_command/3` or a listener's `serve_opts` now apply. They were ignored | check that the values you pass are large enough for your guest |
| `wasi_preview3:run_serve/3,4` answers `{ok, Status, Headers, Body, Trailers}` for a response that has trailers | add a clause for the 5-tuple; a response without trailers still gives the 4-tuple |

**Modules and the application.**

| what changed | what to change |
| --- | --- |
| a module larger than `max_module_bytes` (64 MiB) is refused with `module_too_large` | set `{wasm, [{max_module_bytes, Bytes}]}` if you load larger modules |
| the module cache holds at most `max_resident_module_bytes` (2 GiB); past it a new load answers `{error, {module_cache_full, Bytes}}` | unload modules you no longer use, or raise `max_resident_module_bytes` |
| after `application:stop(wasm)` and a new start, an instance made before the stop traps with `runtime_stopped` | make your instances again after the application starts |
| `wasm_instance_worker` runs the module's start function with a deadline: `timeout` in the worker's `limits`, or `worker_timeout` (5 s) | for a module whose start takes longer, set `limits => (wasm_limits:untrusted())#{timeout => Ms}` |
| in compiled code, a `call_stack_exhausted` trap has no `depth` in its `ctx` | match on the kind, not on `depth` |

**Components and adapters.**

| what changed | what to change |
| --- | --- |
| a WASI 0.3 import only binds a host key that ends in `@0.3`. It used to fall back to the 0.2 function of the same name | serve a 0.3 component with `wasi_preview3`, or name your own host keys with `@0.3`, such as `wasi:cli/stdout@0.3` |
| `wasm_component:call_async/4` answers `{error, async_backpressure}` while the instance holds backpressure | handle that answer, for example by calling again later |
| an adapter's `artifact/1` runs in a short-lived process, which exits after it returns | return values from `artifact/1`, not resources tied to that process, such as an ETS table or a link |

## 0.9.1

| what changed | what to change |
| --- | --- |
| `wasm_component:call/4` hands back an `own` resource as a small index into the instance's handle table, starting at 1. It used to be the guest's own representation | treat a handle as an opaque value: pass it back to the component, never read it as the guest's data |
| a handle that was dropped, never handed out, or is of another resource type answers a `resource_not_live` or `resource_wrong_type` trap | pass each handle only to the functions of its own resource type, and only while it is live |
| `wasm_component:drop_resource/3` answers the destructor's result: `ok`, or the trap it raised. It used to answer `ok` always | match `{error, _}` as well as `ok` |

## 0.9.0

| what changed | what to change |
| --- | --- |
| `wasm:restore/3` no longer takes `recycle`, and the worker option `recycle_idle` is gone. Both are ignored | remove them: `wasm:restore(Image, Bindings, #{recycle => true})` becomes `wasm:restore(Image, Bindings, #{})` |
| a restore or a memory write that the node page budget cannot afford is refused with `exhaustion` / `memory_limit`. A restore used to fail with `malformed` / `internal` | match the new class and kind |
| the node page budget counts the pages a memory has allocated, in whole chunks: a three-page memory counts four | if you were close to `wasm_engine:set_page_limit/1`, raise the limit |
| workers built on `py_reactor.wasm` need the new build | rebuild it with `scripts/build-python-reactor.sh`, which now needs binaryen's `wasm-opt`, or `WASM_OPT` set to it |
| the CPython standard library ships precompiled | after you edit a `.py` file of the library, rebuild the reactor |

## 0.6.0

| what changed | what to change |
| --- | --- |
| workers built on `py_reactor.wasm` need the new build | rebuild it with `scripts/build-python-reactor.sh` |
| the CPython reactor imports `worker.context` and `worker.context_size` | an adapter of your own over `py_reactor.wasm` must bind both imports |
| images of the previous reactor build are not restored | nothing: the worker captures a new image the first time |

## From 0.3 to 0.4

This section is for you if you copied modules from `examples/` in 0.3: the
worker, the worker kernel, the reaper or a language adapter (the
[glossary](concepts.md#glossary) defines each one). In 0.4 those modules are
part of the application, with `wasm_` names. Nothing you copied breaks: no
new module has the same name as a module in the 0.3 `examples/`, so your
copies still compile and run. Moving to the installed modules is optional,
and you can move one module at a time.

### Pick your case

| you copied | do this |
| --- | --- |
| `wasm_worker.erl`, unchanged | switch the calls to `wasm_instance_worker`, below, and delete your copy |
| `wasm_worker.erl`, changed | keep it, or move to `wasm_instance_worker` if its options now cover your change |
| the kernel: `script_worker`, `worker_reaper`, `script_v1`, `worker_error`, an adapter | switch with the table below when you are ready |

### Switch the simple worker

`wasm_instance_worker` has exactly the calls of the 0.3 example:
`start_link/1,2`, `call/3,4`, `stop/1` and `info/1`, with the same options and
the same return values. So you only rename the calls:

```sh
perl -pi -e 's/\bwasm_worker:/wasm_instance_worker:/g' $(grep -rlw wasm_worker src)
```

Then delete `src/wasm_worker.erl`. If your copy was renamed, as
`getting-started.md` used to suggest, put your module's name in place of
`wasm_worker` in that command.

### Switch the kernel

| 0.3, copied | 0.4, installed |
| --- | --- |
| `worker_reaper:start_link(#{scratch => Dir})` in your supervision tree | remove it: the application runs the reaper. To keep recovery across node restarts, set `{wasm, [{scratch_roots, #{scratch => Dir}}]}` |
| `worker_reaper:start_link(Roots, Settings)` | `{wasm, [{scratch_roots, Roots}, {reaper_options, Settings}]}` |
| `script_worker:start_link(Adapter, #{root => scratch, ...})` | `wasm_script_worker:start_link(Adapter, #{...})`; `root` defaults to `scratch` |
| `js_worker:run(W, Src, Ctx)`, `python_worker:run(W, Src, Ctx)` | `wasm_script_worker:run(W, Src, Ctx)` |
| `qjs_adapter`, `qjs_reactor_adapter` | `wasm_javascript_command`, `wasm_javascript` |
| `py_adapter`, `py_reactor_adapter` | `wasm_python_command`, `wasm_python` |
| `lua_reactor_adapter` | `wasm_lua` |
| `-behaviour(script_worker)` in your own adapter | `-behaviour(wasm_worker_adapter)`; the callbacks are unchanged |
| `worker_error:runtime(E)` and the other constructors | `wasm_worker_error:runtime(E)` |
| `worker_reaper:stats/0`, `requests/0` | `wasm_script_worker:cleanup_stats/0`, `cleanup_requests/0` |

Limits and option keys are otherwise unchanged. The script profile the shipped
adapters speak (one source, a JSON context, `main(context)`, a JSON result; not
the compile `profile` option) is still called `script_v1`, and the boot scripts
are still in `priv/script_v1/`, so a guest built for 0.3 needs nothing.

### Where scratch files go now

Without `scratch_roots`, the reaper keeps request files in a directory that
only this node uses, under the user cache directory. It removes that
directory when the node stops cleanly. If the node crashes, the next start
does not clean that directory, because the next start uses a new one. Set
`scratch_roots` in production. When a node restarts, it finds and cleans what
a crashed node left in the configured root. Only one node at a time may use a
configured root.

### Delete what you replaced

Remove the copies you no longer use, run your tests, and check that nothing
still names them:

```sh
grep -rlwE 'script_worker|worker_reaper|script_v1|qjs_adapter|py_adapter' src
```

## Read this next

The [changelog](../CHANGELOG.md).
