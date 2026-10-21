# Host functions

A host function lets WebAssembly call your Erlang code. It is an ordinary
Erlang function: you do not register it, and you do not describe it in an
interface language. Read this page when your module needs to do something you
have not granted through WASI, or when you decide what an untrusted module may
reach.

## Write one

```erlang
Imports = #{{~"env", ~"now"} => fun(_Ctx, []) ->
                                     {ok, [erlang:system_time(millisecond)]}
                                 end}.
```

The key is `{ModuleName, FieldName}`, the names the module imports. The value
is `fun(Ctx, Args) -> Result` or an `{Module, Function}` tuple.

Return one of:

| you return | what happens |
| --- | --- |
| `{ok, Results}` | the runtime checks the number of results against the import's type, and the guest continues |
| `{trap, Reason}` | the call traps (stops with an error); the code that called `wasm:call/3` gets `{error, _}` |
| you raise an exception | the runtime catches it and turns it into a trap with the class, reason and stack trace |

The last row is on purpose. An exception in your import never reaches the
process that made the call. So a faulty import cannot crash code that only
called a module.

## Read and write memory

WebAssembly gives you addresses in its memory, not the data itself. Use the
context to read the instance's memory:

```erlang
fun(Ctx, [Ptr, Len]) ->
    {ok, Bin} = wasm:read_memory(Ctx, Ptr, Len),
    ok = do_something(Bin),
    {ok, []}
end
```

To return data, the module must give you a place to write it, usually by
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

Every read and write checks its bounds, and traps if it goes outside the
memory. So a module cannot use your host function to read outside its own
sandbox.

## Block, if you have to

Your host function may send a message, wait for a reply, or query a
database. Nothing prevents this, and the instance just waits until it
returns. Plan for two effects:

- `fuel` does not limit it. Fuel counts WebAssembly work, and a host call that
  waits ten seconds uses none. To limit real time, you need a timeout, and a
  timeout needs a separate process; see [worker.md](worker.md).
- The caller waits too, if it called the instance directly. A direct
  `wasm:call/3` runs in your process, so an import that blocks also blocks
  you.

## Expect re-entrancy

Your host function may call back into the same instance. This is called
re-entrancy. `max_depth` limits how deep these nested calls go. The nested
call sees the same state, because it is the same instance. Nested calls are
not isolated from each other: the state may have changed when your function
gets control back.

## Keep the import set small

Limits apply to WebAssembly code, not to the Erlang code you supply. A host
function that reads any file, allocates without limit, or blocks forever is
outside every limit the runtime enforces. If you run untrusted modules, the
imports you give them are part of your sandbox, and the runtime cannot check
that part for you.

WASI is a good example of how to do this. See [wasi.md](wasi.md) and
`wasi_preview1`: every capability is granted explicitly, and a capability you
do not grant is refused.

## Read this next

[WASI](wasi.md), the standard set of host functions, or [Streams](streams.md)
to talk to a guest while it runs.
