# A plugin per request

This example runs a plugin compiled from Rust with a fresh instance for every
request, so nothing one request does is visible to the next. The plugin
normalises an e-mail address in a buffer it exports.

**You need:** a checkout of this repository, which has the plugin in
`test/fixtures/plugin/`.

```erlang
{ok, _} = application:ensure_all_started(wasm),
{ok, Mod} = wasm:load_file("test/fixtures/plugin/plugin.wasm").
```

`load_file/1` decodes and validates once, and caches by content hash. Each
request makes its own instance from the one module:

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

**What happened.** The plugin is a module built by Rust's standard library, so
it imports the few WASI functions `std` insists on; `wasi:imports(#{})`
supplies them and grants nothing else: no directory, no network. Making an
instance per request is cheap because the module is already decoded and
validated.

To run it under a deadline too, give each request to a worker instead; see
[Stop a runaway](stop-a-runaway.md).

**Next:** [Restore a snapshot](restore-a-snapshot.md).
