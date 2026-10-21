# Use a component resource

This example uses a component that exposes a **resource**: a handle to state
that the component owns. You cannot see inside the handle. You create a
resource, call its methods with the handle, and drop it when you are done.
The example then passes the same kind of resource between two components that
are combined into one. Both are real components in this repository, so you
have nothing to build.

**You need:** a checkout of this repository, which has the components in
`test/fixtures/component/`.

```erlang
{ok, _} = application:ensure_all_started(wasm).
```

## Construct, use and drop

`counter` exports a `counter` resource with a constructor and two methods,
`increment` and `get`. The constructor returns a handle, and you pass the
handle back to call a method. The export names start with the interface name,
so define a small function that adds that prefix:

```erlang
{ok, CounterBytes} = file:read_file("test/fixtures/component/counter.component.wasm"),
{ok, C} = wasm_component:instantiate(CounterBytes),
Q = fun(Name) -> <<"example:counter/counters#", Name/binary>> end,
{ok, H} = wasm_component:call(C, Q(~"make-counter"), {[u32], u32}, [5]),
H.
%% => 1
```

`H` is the handle: a position in the instance's handle table, not anything
inside the guest. Add 3 to the counter and read it back. The handle is still
valid, so both calls succeed:

```erlang
{ok, 8} = wasm_component:call(C, Q(~"[method]counter.increment"), {[u32, u32], u32}, [H, 3]),
wasm_component:call(C, Q(~"[method]counter.get"), {[u32], u32}, [H]).
%% => {ok, 8}
```

Drop the handle to free the resource. This runs its destructor:

```erlang
wasm_component:drop_resource(C, Q(~"[dtor]counter"), H).
%% => ok
```

The handle is now used up. If you drop it again, or call a method with it,
the runtime refuses before the guest runs, with a trap that you can match
on:

```erlang
{error, #{class := trap, kind := resource_not_live}} =
    wasm_component:call(C, Q(~"[method]counter.get"), {[u32], u32}, [H]),
wasm_component:drop_resource(C, Q(~"[dtor]counter"), H).
%% => {error, #{class := trap, kind := resource_not_live, ctx := #{handle := 1, operation := drop}}}
```

If you pass a handle of one resource type where another type is expected,
you get `resource_wrong_type` in the same way. Destroy the instance when you
are done:

```erlang
wasm_component:destroy(C).
%% => ok
```

## A resource across composed components

`composed_counter` is two components connected with the `wac` tool. One
defines the `counter` resource, and the other uses it. Calling `run` creates a
counter in the first component and increments it from the second, so the
resource passes from one component to the other. Each component has its own
handle table. The second gets its own handle, and dropping that handle runs
the destructor in the first.

```erlang
{ok, Composed} = file:read_file("test/fixtures/component/composed_counter.component.wasm"),
{ok, CC} = wasm_component:instantiate(Composed, wasi_preview2:command(#{}), #{loader => compile}),
wasm_component:call(CC, ~"run", {[], u32}, []).
%% => {ok, 42}
```

```erlang
wasm_component:destroy(CC).
%% => ok
```

**What happened.** The first component owned a resource and gave you a
handle to it: a position in its handle table. You called methods with the
handle and dropped it. The runtime ran the destructor, and refused the used
handle after that. The combined pair passed a resource from one component to
the other, each with its own handle table. So the runtime catches a handle
that was dropped, reused or of the wrong type, instead of silently accepting
it.

**Next:** [Components](../components.md).

## Read this next

The guide behind this example: [Components](../components.md).
