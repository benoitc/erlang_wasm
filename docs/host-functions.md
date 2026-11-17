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
is one of:

| value | what the runtime does |
| --- | --- |
| `fun(Ctx, Args) -> Result` | calls the fun |
| `{Module, Function}`, two atoms | calls `Module:Function(Ctx, Args)` |
| an export of another instance, from `wasm:extern/2` | calls that instance's function; see [Link modules together](embedding.md#link-modules-together) |

`Args` is the list of the guest's arguments, and `Ctx` is the context, in
[Use the context](#use-the-context).

The `{Module, Function}` form names an exported function of arity 2. It always
calls the loaded version of `Module`, so when you upgrade your code, instances
that already exist call the new version:

<!-- check: modules my_host -->
```erlang
-module(my_host).
-export([now/2]).

now(_Ctx, []) ->
    {ok, [erlang:system_time(millisecond)]}.
```

```erlang
Imports = #{{~"env", ~"now"} => {my_host, now}}.
```

A fun or a `{Module, Function}` carries no WebAssembly type, so it takes the
type the module declares for the import. An export of another instance does
carry one, and a different type is refused when you instantiate, with
`{error, #{kind := incompatible_import_type}}`. Any other value is refused
with `{error, #{kind := bad_import}}`. A key the module imports and you do not
supply is refused with `{error, #{kind := unknown_import}}`.

Return one of:

| you return | what happens |
| --- | --- |
| `{ok, Results}` | the runtime checks the number of results against the import's type, and the guest continues |
| `{trap, Reason}` | the call traps (stops with an error); the code that called `wasm:call/3` gets `{error, _}` |
| you raise an exception | the runtime catches it and turns it into a trap with the class, reason and stack trace |

The last row is on purpose. An exception in your import never reaches the
process that made the call. So a faulty import cannot crash code that only
called a module.

## Use the context

`Ctx` is a map the runtime builds for each call of your function. It holds
the instance that called you and that instance's state at the moment of the
call. Use it in two ways:

- pass it to `wasm:read_memory/3`, `wasm:write_memory/3` and
  `wasm:memory_size/1`, which take a context as well as an instance;
- take the instance from it, `maps:get(instance, Ctx)`, to call back into the
  instance (see [Expect re-entrancy](#expect-re-entrancy)) or to pin a
  reference with `wasm:pin/2`.

The other keys belong to the runtime. Do not read them or keep the map after
your function returns.

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

Every read and write checks its bounds. Out of bounds, it returns
`{error, #{class := trap, kind := out_of_bounds_memory_access}}`; return
`{trap, Reason}`, or let the match fail, to stop the call. So a module cannot
use your host function to read outside its own sandbox.

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
re-entrancy:

```erlang
fun(Ctx, []) ->
    {ok, [X]} = wasm:call(maps:get(instance, Ctx), ~"seven", []),
    {ok, [X + 1]}
end
```

`max_depth` limits how deep these nested calls go, and the nested call uses
the fuel and the host-call count of the outer call; it does not get new ones.
The nested call sees the same state, because it is the same instance. Nested
calls are not isolated from each other: the state may have changed when your
function gets control back.

## Keep the import set small

Limits apply to WebAssembly code, not to the Erlang code you supply. A host
function that reads any file, allocates without limit, or blocks forever is
outside every limit the runtime enforces. If you run untrusted modules, the
imports you give them are part of your sandbox, and the runtime cannot check
that part for you.

WASI is a good example of how to do this. See [wasi.md](wasi.md) and
`wasi_preview1`: every capability is granted explicitly, and a capability you
do not grant is refused.

## Where imports are dispatched and tested

This part is for you if you change the runtime.

- `resolve_import`, in `wasm_instance`, turns each value in the imports map
  into a host function when the module is instantiated, and refuses the ones
  above.
- `call_host`, in `wasm_exec`, calls it: it builds `Ctx`, counts the call
  against `max_host_calls`, checks the number of results, and turns
  `{trap, Reason}` and exceptions into a trap with the kind `host_error`.

| what | suite |
| --- | --- |
| import types: a fun on trust, another instance's export checked, the wrong kind refused | `wasm_linking_SUITE` |
| `max_host_calls`, and fuel and depth across a call back in | `wasm_budget_SUITE` |
| what the guest wrote before a host call survives a trap | `wasm_trap_effects_SUITE` |
| an exception in a host function becomes a trap, and the worker lives | `wasm_worker_SUITE` |
| host functions of a component, `wasm_component:import_fun/2` | `wasm_component_import_SUITE` |

## Read this next

[WASI preview 1](wasi.md), the standard set of host functions, or
[Streams](streams.md) to talk to a guest while it runs.
