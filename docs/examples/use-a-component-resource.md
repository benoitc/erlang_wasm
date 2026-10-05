# Use a component resource

This example uses a component that exposes a **resource**: an opaque handle to
state the component owns. You construct one, call its methods with the handle, and
drop it when you are done. It then shows the same resource crossing between two
composed components. Both are real components in this repository, so there is
nothing to build.

**You need:** a checkout of this repository, which has the components in
`test/fixtures/component/`.

```erlang
{ok, _} = application:ensure_all_started(wasm).
```

## Construct, use and drop

`counter` exports a `counter` resource with a constructor and `increment` and
`get` methods. The constructor returns a handle; you pass it back to call a
method. The export names are interface-qualified, so bind a small prefix:

```erlang
{ok, CounterBytes} = file:read_file("test/fixtures/component/counter.component.wasm"),
{ok, C} = wasm_component:instantiate(CounterBytes),
Q = fun(Name) -> <<"example:counter/counters#", Name/binary>> end,
{ok, H} = wasm_component:call(C, Q(~"make-counter"), {[u32], u32}, [5]),
H.
%% => 1
```

`H` is the handle: an index into the instance's handle table, not anything
inside the guest. Increment the counter by 3 and read it back; the handle is
live, so both calls succeed:

```erlang
{ok, 8} = wasm_component:call(C, Q(~"[method]counter.increment"), {[u32, u32], u32}, [H, 3]),
wasm_component:call(C, Q(~"[method]counter.get"), {[u32], u32}, [H]).
%% => {ok, 8}
```

Drop the handle to free the resource, which runs its destructor:

```erlang
wasm_component:drop_resource(C, Q(~"[dtor]counter"), H).
%% => ok
```

The handle is now spent. Dropping it again, or calling a method with it, is
refused before the guest runs, as a trap you can match on:

```erlang
{error, #{class := trap, kind := resource_not_live}} =
    wasm_component:call(C, Q(~"[method]counter.get"), {[u32], u32}, [H]),
wasm_component:drop_resource(C, Q(~"[dtor]counter"), H).
%% => {error, #{class := trap, kind := resource_not_live, ctx := #{handle := 1, operation := drop}}}
```

A handle of one resource type passed where another is expected answers
`resource_wrong_type` the same way. Destroy the instance when you are done:

```erlang
wasm_component:destroy(C).
%% => ok
```

## A resource across composed components

`composed_counter` is two components wired together with `wac`: one defines the
`counter` resource, the other uses it. Calling `run` creates a counter in the
first and increments it from the second, so the resource crosses the component
boundary. Each component has its own handle table: the second gets a handle of
its own, and dropping it runs the destructor in the first.

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

**What happened.** The first component owned a resource and handed you a handle
to it, an index into its handle table. You called methods with the handle and
dropped it; the runtime ran the destructor, and refused the spent handle after
that. The composed pair passed a resource from one component to another, each
with its own handle table, so a dropped, reused or wrong-type handle is caught
rather than quietly accepted.

**Next:** [Components](../components.md).
