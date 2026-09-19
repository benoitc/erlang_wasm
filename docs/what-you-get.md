# What you get, and what you bring

This page says which parts come with the `erlang_wasm` dependency and which
are yours to supply. Read it before your first worker, so you know what to
install and what to write.

## The split

| to do this | the library provides | you provide |
| --- | --- | --- |
| load and call WebAssembly | `wasm` | the `.wasm` guest |
| run a WASI command | `wasi` | the command module |
| bound what a guest may use | `wasm_limits`, `wasm_engine` | the values |
| run a guest in a process with a deadline | `wasm_instance_worker` | supervision and options |
| run JavaScript, Python or Lua | `wasm_script_worker` and the adapters `wasm_javascript`, `wasm_python`, `wasm_lua` (and their `_command` variants) | the language runtime artifact, and the source |
| run another language | the behaviour `wasm_worker_adapter`, the kernel, and the kit `wasm_adapter_conformance` | the adapter, and its guest |

Nothing in `examples/` is needed: it holds demonstrations, `plugin_worker` and
`qjs_worker`, to read and copy from.

## Add the dependency

```erlang
%% rebar.config
%% The OTP application is `wasm`; the Hex package is `erlang_wasm`.
{deps, [{wasm, {pkg, erlang_wasm}}]}.
```

## Get a language runtime

The interpreters are other people's builds, fetched or built rather than
shipped:

| language | artifact | how |
| --- | --- | --- |
| JavaScript | `qjs.wasm`, a QuickJS command | `scripts/fetch-qjs-fixture.sh` |
| JavaScript, fast path | `qjs_reactor.wasm` | `scripts/build-quickjs-reactor.sh`, needs the WASI SDK |
| Python | `python.wasm`, a CPython command | `scripts/fetch-python-fixture.sh` |
| Python, fast path | `py_reactor.wasm` and its standard library | `scripts/build-python-reactor.sh`, about twenty minutes |
| Lua | `lua_reactor.wasm` | `scripts/build-lua-reactor.sh`, needs the WASI SDK |

The scripts are in the repository and in the Hex package, under `scripts/`.

## Settings you may want in production

```erlang
%% sys.config
[{wasm, [{scratch_roots, #{scratch => "/var/lib/myapp/wasm-scratch"}},
         {code_cache_dir, "/var/lib/myapp/wasm-code"}]}].
```

`scratch_roots` is where request files live, and where a restarted node cleans
up what a crashed one left. `code_cache_dir` keeps compiled code across
restarts. [Workers](worker.md) lists every other setting.
