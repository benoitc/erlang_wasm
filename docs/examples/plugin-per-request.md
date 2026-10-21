# A plugin per request

This example runs a plugin compiled from Rust, with a new instance for every
request. So nothing one request does is visible to the next. The plugin
cleans up an e-mail address (trims it and makes it lower case) in a buffer
that it exports.

**You need:** a checkout of this repository, which has the plugin in
`test/fixtures/plugin/`.

```erlang
{ok, _} = application:ensure_all_started(wasm),
{ok, Mod} = wasm:load_file("test/fixtures/plugin/plugin.wasm").
```

`load_file/1` decodes and validates the module once, and caches it by
content hash (a checksum of its bytes). Each request makes its own instance
from this one module:

```erlang
Normalise = fun(Input) ->
    {ok, Inst} = wasm:instantiate(Mod, wasi:imports(#{})),
    {ok, [Buf]} = wasm:call(Inst, ~"buffer", []),
    ok = wasm:write_memory(Inst, Buf, Input),
    Result = case wasm:call(Inst, ~"normalise", [byte_size(Input)]) of
                 {ok, [N]} when N >= 0 -> wasm:read_memory(Inst, Buf, N);
                 {ok, [_]}             -> {error, invalid}
             end,
    ok = wasm:destroy(Inst),
    Result
end,
Normalise(~"  User@Example.COM  ").
%% => {ok, ~"user@example.com"}
```

**What happened.** The plugin is built with Rust's standard library, so it
imports the few WASI functions that `std` requires. `wasi:imports(#{})`
supplies them and grants nothing else: no directory, no network. A new
instance per request is cheap, because the module is already decoded and
validated.

To also run each request under a deadline, give it to a worker instead; see
[Stop a runaway](stop-a-runaway.md).

**Next:** [Restore a snapshot](restore-a-snapshot.md).

## Read this next

The guide behind this example: [Using workers](../worker.md).
