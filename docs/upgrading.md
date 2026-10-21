# Upgrading from 0.3

This page is for you if you copied modules from `examples/` in 0.3: the
worker, the worker kernel, the reaper or a language adapter (the
[glossary](concepts.md#glossary) defines each one). In 0.4 those modules are
part of the application, with `wasm_` names. Nothing you copied breaks: no
new module has the same name as a module in the 0.3 `examples/`, so your
copies still compile and run. Moving to the installed modules is optional,
and you can move one module at a time.

## Pick your case

| you copied | do this |
| --- | --- |
| `wasm_worker.erl`, unchanged | switch the calls to `wasm_instance_worker`, below, and delete your copy |
| `wasm_worker.erl`, changed | keep it, or move to `wasm_instance_worker` if its options now cover your change |
| the kernel: `script_worker`, `worker_reaper`, `script_v1`, `worker_error`, an adapter | switch with the table below when you are ready |

## Switch the simple worker

`wasm_instance_worker` has exactly the calls of the 0.3 example:
`start_link/1,2`, `call/3,4`, `stop/1` and `info/1`, with the same options and
the same return values. So you only rename the calls:

```sh
perl -pi -e 's/\bwasm_worker:/wasm_instance_worker:/g' $(grep -rlw wasm_worker src)
```

Then delete `src/wasm_worker.erl`. If your copy was renamed, as
`getting-started.md` used to suggest, put your module's name in place of
`wasm_worker` in that command.

## Switch the kernel

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

Limits and option keys are otherwise unchanged. The profile is still called
`script_v1` and the boot scripts are still in `priv/script_v1/`, so a guest
built for 0.3 needs nothing.

## Where scratch files go now

Without `scratch_roots`, the reaper keeps request files in a directory that
only this node uses, under the user cache directory. It removes that
directory when the node stops cleanly. If the node crashes, the next start
does not clean that directory, because the next start uses a new one. Set
`scratch_roots` in production. When a node restarts, it finds and cleans what
a crashed node left in the configured root. Only one node at a time may use a
configured root.

## Delete what you replaced

Remove the copies you no longer use, run your tests, and check that nothing
still names them:

```sh
grep -rlwE 'script_worker|worker_reaper|script_v1|qjs_adapter|py_adapter' src
```

## Read this next

The [changelog](../CHANGELOG.md).
