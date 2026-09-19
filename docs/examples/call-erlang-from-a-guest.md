# Call Erlang from a guest

This example gives a guest one Erlang function to call. The guest hands it a
name; the function writes a greeting back into the guest's memory.

**You need:** nothing beyond the application.

```erlang
{ok, _} = application:ensure_all_started(wasm).
```

The guest imports `env.greet` and exposes its memory:

```erlang
Src = ~"""
(module
  (import "env" "greet" (func $greet (param i32 i32) (result i32)))
  (memory (export "memory") 1)
  (func (export "run") (param i32 i32) (result i32)
    (call $greet (local.get 0) (local.get 1))))
""",
{ok, Mod} = wasm:compile({wat, Src}).
```

The host function reads the name, writes the reply at address 1024 and returns
its length:

```erlang
Greet = fun(Ctx, [Ptr, Len]) ->
            {ok, Who} = wasm:read_memory(Ctx, Ptr, Len),
            Reply = <<"hello, ", Who/binary, "!">>,
            ok = wasm:write_memory(Ctx, 1024, Reply),
            {ok, [byte_size(Reply)]}
        end,
{ok, Inst} = wasm:instantiate(Mod, #{{~"env", ~"greet"} => Greet}).
```

Call it with a name:

```erlang
ok = wasm:write_memory(Inst, 0, ~"erlang"),
{ok, [N]} = wasm:call(Inst, ~"run", [0, 6]),
wasm:read_memory(Inst, 1024, N).
%% => {ok, ~"hello, erlang!"}
```

**What happened.** The guest named an operation, `env.greet`; the host
supplied what it does. That is a **capability**: had you left `Greet` out, the
module would not have instantiated at all. The function answers `{ok,
Results}`; `{trap, Reason}` would stop the call instead.

**Clean up:**

```erlang
ok = wasm:destroy(Inst).
```

**Next:** [Pass bytes](pass-bytes.md), or [Host functions](../host-functions.md)
for the rest of the contract.
