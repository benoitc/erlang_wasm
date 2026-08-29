# Host functions

A host function is how WebAssembly calls into your Erlang. It is an ordinary
Erlang function: no registration step, no interface definition language. Read
this when your module needs to do anything you have not granted it through WASI,
or when you are deciding what a module you do not trust is allowed to reach.

## Write one

```erlang
Imports = #{{~"env", ~"now"} => fun(_Ctx, []) ->
                                     {ok, [erlang:system_time(millisecond)]}
                                 end}.
```

Key it by `{ModuleName, FieldName}`, matching what the module imports. The value
is `fun(Ctx, Args) -> Result` or an `{Module, Function}` tuple.

Return one of:

| you return | what happens |
| --- | --- |
| `{ok, Results}` | arity is checked against the import signature, execution continues |
| `{trap, Reason}` | the invocation traps; your caller of `wasm:call/3` gets `{error, _}` |
| you raise | caught and converted to a trap carrying the class, reason and stacktrace |

That last row is deliberate. An exception in your import does not escape into
the process that made the call, so an embedder's import cannot destabilise a
caller who merely invoked a module.

## Read and write memory

WebAssembly hands you pointers, not data. Use the context to reach the
instance's memory:

```erlang
fun(Ctx, [Ptr, Len]) ->
    {ok, Bin} = wasm:read_memory(Ctx, Ptr, Len),
    ok = do_something(Bin),
    {ok, []}
end
```

To return data, the module has to give you somewhere to put it, usually by
exporting an allocator:

```erlang
fun(Ctx, [OutPtr, OutLen]) ->
    Data = payload(),
    case byte_size(Data) =< OutLen of
        true ->
            ok = wasm:write_memory(Ctx, OutPtr, Data),
            {ok, [byte_size(Data)]};
        false ->
            {ok, [-1]}                    % conventional "too small" signal
    end
end
```

Reads and writes are bounds-checked and trap if they leave the memory, so a
module cannot use your host function to read outside its own sandbox.

## Block, if you have to

Your host function may send a message, wait for a reply, or query a database.
Nothing prevents it, and the instance is simply busy meanwhile. Two consequences
you should plan for:

- `fuel` does not bound it. Fuel counts WebAssembly work, and a host call that
  waits ten seconds consumes none. Wall-clock bounding needs a timeout, which
  needs a process; see [worker.md](worker.md).
- The caller blocks too, if the call is inline. An inline `wasm:call/3` runs in
  your process, so a blocking import blocks you.

## Expect re-entrancy

Your host function may call back into the same instance. `max_depth` bounds how
deep that goes, and the nested call sees the same instance state, because it is
the same instance. Nested calls are not isolated from each other, so do not
assume the state you left is the state you return to.

## Keep the import set small

Limits constrain WebAssembly, not the Erlang you supply. A host function that
reads any file, allocates without bound, or blocks forever sits outside every
limit the runtime enforces. If you run untrusted modules, the import set you
hand them is part of your sandbox, and it is the part the runtime cannot check
for you.

WASI is the worked example of doing this properly. See [wasi.md](wasi.md) and
`wasi_preview1`, where every capability is explicit and absence means refusal.
