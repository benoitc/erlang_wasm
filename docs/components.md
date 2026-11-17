# Components

The WebAssembly Component Model lets you run a `.wasm` file that has *typed
interfaces*. A core module only has functions over numbers. A component
describes its imports and exports with strings, lists, records, variants and
results. The runtime converts these values between Erlang and the guest for
you, using the Canonical ABI. Read this page when your toolchain produces a
component (`cargo-component`, `wit-bindgen`, `componentize-py`, `jco`, or a
bundle built with `wac`), or when you want to connect several components.

**Do you need this?** Yes, if `wasm-tools print your.wasm` starts with
`(component ...)`, or your build targets `wasm32-wasip2`. No, for a core module
(`(module ...)`) of functions over the memory you give it: use
[Hold modules and instances](embedding.md) instead.

You use two modules: `wasm_component` to decode, instantiate and call, and
`wasi_preview2` for the WASI 0.2 host that a component imports. Components
work whether the `wasm` application is started or not. When it is started,
each core module goes through its module cache, so the same bytes are
compiled once per node. When it is not started, each core module is compiled
in the calling process, as `wasm:compile/1` does. The async Canonical ABI
(`async func`, `stream<T>`, `future<T>`) is supported: call an async export
with `wasm_component:call_async/4`. A component built for WASI 0.3, whose
interfaces use it, runs through `wasi_preview3`; see [WASI 0.3](wasi-0-3.md).

## The words on this page

| word | what it means here |
| --- | --- |
| **component** | a Component Model binary: core modules plus typed interfaces. `wasm-tools print` shows `(component ...)`. |
| **core module** | a plain WebAssembly module, `(module ...)`, whose functions take and return numbers. |
| **WIT** | the language that describes a component's interfaces and types. |
| **Canonical ABI** | the rules that copy a typed value (a string, a record, a handle) into a core module's memory and back. |
| **signature** | the types of a function's parameters and result. You pass it to `call/4`. |
| **descriptor** | an Erlang term that names one value type in a signature, such as `u32` or `{list, u8}`. |
| **resource** | an object that a component owns, which you reach through a handle. |
| **handle** | a small integer that names one resource in one instance. |
| **`own`**, **`borrow`** | `own` gives the resource to the receiver; `borrow` lends it for one call only. |
| **compose** | combine several components into one, so the imports of one are the exports of another. |

More terms are in the [glossary](concepts.md#glossary).

## Run a component

Instantiate the bytes, and call an export by name with its signature. When
you are done, destroy the instance to free its resources:

```erlang
{ok, Bin} = file:read_file("echo.component.wasm"),
{ok, Inst} = wasm_component:instantiate(Bin),
{ok, Upper} = wasm_component:call(Inst, ~"run", {[{list, u8}], {list, u8}}, [~"hello"]),
ok = wasm_component:destroy(Inst).
```

The third argument is the export's signature as `{Params, Result}`: `Params` is
a list of one descriptor per parameter, and `Result` is one descriptor or
`none`. The signature is the WIT function type, written with the descriptors
below. You write it by hand because the runtime reads types out of the binary
only where it must, to connect composed components and to check resource
handles; a direct call takes its value types from you.

## Name an export

The second argument of `call/4` is the export's name. `exports/1` lists the
names at the top of a component: its own functions, and the interfaces it
exports:

<!-- check: run -->
```erlang
{ok, CounterBytes} = file:read_file("test/fixtures/component/counter.component.wasm"),
{ok, C} = wasm_component:instantiate(CounterBytes),
wasm_component:exports(C).
%% => [~"example:counter/counters"]
```

A function inside an exported interface is named by the interface, then `#`,
then the function. A resource's functions carry a prefix in brackets:

| in the WIT | the name you pass |
| --- | --- |
| `export run: func()`, a function of the world | `~"run"` |
| `make-counter`, in the exported interface `example:counter/counters` | `~"example:counter/counters#make-counter"` |
| the `constructor` of resource `counter` | `~"example:counter/counters#[constructor]counter"` |
| the method `increment` of `counter` | `~"example:counter/counters#[method]counter.increment"` |
| a static function `from-list` of resource `fields` | `~"Interface#[static]fields.from-list"` |
| the destructor of `counter`, for `drop_resource/3` | `~"example:counter/counters#[dtor]counter"` |

Write the interface name exactly as `exports/1` lists it, with its version
when it has one, such as `wasi:cli/run@0.2.0#run`.

## Describe the signature

A descriptor names one Component Model value type. Use these in the parameter
list and in the result of `call/4`:

| descriptor | WIT type | Erlang value |
| --- | --- | --- |
| `u8` `u16` `u32` `u64` `s8` `s16` `s32` `s64` | the fixed-width integers | an integer |
| `f32` `f64` | `float32` `float64` | a float |
| `bool` | `bool` | `true` / `false` |
| `char` | `char` | a code point integer |
| `string` | `string` | a binary (UTF-8) |
| `{list, D}` | `list<D>` | a list of `D` values (a binary for `{list, u8}`) |
| `{record, [{Name, D}]}` | `record` | a map `#{Name => value}` |
| `{tuple, [D]}` | `tuple<...>` | a tuple |
| `{variant, [{Name, D \| none}]}` | `variant` | `{Name, Payload}`; `{Name, undefined}` for a case with no payload |
| `{enum, [Name]}` | `enum` | a `Name` binary |
| `{option, D}` | `option<D>` | `{some, V}` or `none` |
| `{result, OkD \| none, ErrD \| none}` | `result<Ok, Err>` | `{ok, V}` / `{error, E}` |
| `{flags, [Name]}` | `flags` | a list of the set `Name`s |

## From WIT to a call

Take one function from its WIT to a call. The `vectors` component in
`test/fixtures/component/` declares, in its `wit/vectors.wit`:

```text
record point { x: s32, y: s32 }
export echo-point: func(v: point) -> point;
```

1. Write each type as a descriptor. `point` is a record of two `s32` fields:
   `{record, [{~"x", s32}, {~"y", s32}]}`.
2. Write the signature: one parameter of type `point`, and a result of type
   `point`, so `{[Point], Point}`.
3. Pass the record as a map with the field names as binaries, and call:

<!-- check: run -->
```erlang
{ok, VBytes} = file:read_file("test/fixtures/component/vectors.component.wasm"),
{ok, V} = wasm_component:instantiate(VBytes),
Point = {record, [{~"x", s32}, {~"y", s32}]},
R = wasm_component:call(V, ~"echo-point", {[Point], Point}, [#{~"x" => 3, ~"y" => -4}]),
ok = wasm_component:destroy(V),
R.
%% => {ok, #{~"x" := 3, ~"y" := -4}}
```

`echo-point` is a function of the world, not of an interface, so its name has
no `#`. `wasm_component_vectors_SUITE` makes the same call, and one for every
other descriptor in the table.

A guest exporting `run: func(input: list<u8>) -> result<list<u8>, string>` is
called the same way:

```erlang
Sig = {[{list, u8}], {result, {list, u8}, string}},
{ok, {ok, Output}} = wasm_component:call(Inst, ~"run", Sig, [~"data"]).
```

A `result` comes back as `{ok, V}` when the guest returns ok, and as
`{error, E}` when it returns an error. So when a guest rejects its input, you
get a value, not a trap:

```erlang
{ok, {error, Reason}} = wasm_component:call(Inst, ~"run", Sig, [~""]).
```

## Supply the imports it needs

A component may import interfaces. Anything built for `wasm32-wasip2`
imports WASI. You instantiate such a component with a map of host functions,
with keys of the form `{InterfaceName, FieldName}`. The WASI 0.2 host builds
that map for you:

```erlang
{ok, Inst} = wasm_component:instantiate(Bin, wasi_preview2:imports()),
{ok, _} = wasm_component:call(Inst, ~"run", {[], u32}, []).
```

If you leave a capability out of the host options, the guest cannot reach it,
as in Preview 1. To run a command component (one with a `main`) with a
directory, stdin and arguments, see [WASI 0.2](wasi-0-2.md) and the example
[Run a WASI 0.2 component](examples/run-a-wasi-2-component.md).

## Compose components

`wac plug` and `wasm-tools compose` build one component from several others.
You run it like any other component. The runtime instantiates the inner
components and connects their imports and exports inside the one instance.
When one inner component calls another, the values are copied. Each side
keeps its own memory.

```erlang
{ok, Bin} = file:read_file("composed.component.wasm"),
{ok, Inst} = wasm_component:instantiate(Bin),
{ok, Greeting} = wasm_component:call(Inst, ~"run", {[], string}, []),
ok = wasm_component:destroy(Inst).
```

An inner component can call another's `async func` export, such as a
`wasi:http` middleware that imports `wasi:http/handler` and forwards each
request to the handler composed with it. The two pass streams and futures to
each other: the ends are shared, not copied, so what one writes the other
reads. Call the composed component's async exports with `call_async/4` or
`start_async/4`, as for any component.

Notes:

- The called component runs until it returns its result or waits. If it
  returns, the call completes at once. If it waits first, the call is a
  *subtask*: the caller goes on, and the subtask reports that it has returned
  once the called component returns. What the called component does after it
  returns, such as writing a response body, runs with the caller's other
  tasks.
- A called component lifted without a callback (a stackful lift) runs its
  whole call on one stack. Called from another component, it gets a process
  of its own for that call, so it can wait for what its caller does next. A
  call into it while it waits starts once it returns.
- A component may not read and write the same stream or future when its
  elements are not numbers, as the specification requires for now. Doing so
  traps with `intra_component_copy`. A middleware that hands its own future
  back to itself through the handler it calls does this.

## Resources

A component may give you a *resource*: a handle to state that the component
owns. You cannot see inside it. You get it as an `own<T>` (you hold it) or as
a `borrow<T>` (lent for one call). You create one, pass the handle back to
call its methods, and drop it when you are done.

The handle is a small integer. It is an index into the instance's handle
table, not an address inside the guest. In a signature, a resource type is
`{own, TypeIndex}` or `{borrow, TypeIndex}`. `TypeIndex` is the resource
type's position in the component's type list (the numbered types the binary
declares). The runtime checks each handle against the type the component
itself declares for that export, not against the number you write. So `0`
works for any resource, and so does a plain `u32`.

With the `counter` component from [Name an export](#name-an-export), create a
counter and add 1 to it. A method takes the handle as its first parameter:

<!-- check: run -->
```erlang
Q = fun(Name) -> <<"example:counter/counters#", Name/binary>> end,
{ok, Handle} = wasm_component:call(C, Q(~"[constructor]counter"), {[u32], {own, 0}}, [41]),
wasm_component:call(C, Q(~"[method]counter.increment"), {[{borrow, 0}, u32], u32}, [Handle, 1]).
%% => {ok, 42}
```

Drop a handle with `drop_resource/3`, naming the resource's destructor export.
It runs the destructor once and returns `ok`:

<!-- check: run -->
```erlang
wasm_component:drop_resource(C, Q(~"[dtor]counter"), Handle).
%% => ok
```

Every handle is checked before the guest runs. If a check fails, the call
returns `{error, #{class := trap, kind := Kind, ctx := Ctx}}`, and the guest
is not called:

| What you passed | `kind` | `ctx` |
| --- | --- | --- |
| a handle already dropped, dropped twice, or never handed out | `resource_not_live` | `handle`, `operation` |
| a handle of one resource type where another is expected | `resource_wrong_type` | `handle`, `expected`, `actual` |

<!-- check: run -->
```erlang
{error, #{class := trap, kind := resource_not_live}} =
    wasm_component:drop_resource(C, Q(~"[dtor]counter"), Handle),
wasm_component:destroy(C).
%% => ok
```

- Each instance has its own table. A handle from one instance means nothing
  in another.
- `destroy/1` discards every handle the instance still holds. No destructor
  runs, because the guest's memory goes with the instance.
- When a resource passes between composed components, the component that
  receives an `own` gets its own new handle. It can use the resource while it
  holds the handle, and dropping it runs the destructor in the component that
  defined the resource.

For a runnable version, see [Use a component
resource](examples/use-a-component-resource.md).

## Async exports

An `async func` export is called with `call_async/4`. It runs the task to its
end and returns the result:

```erlang
{ok, Sum} = wasm_component:call_async(I, ~"sum-stream",
                                      {[{stream, u8}], u32}, [<<1, 2, 3>>]).
```

Some tasks hand back their result and keep running. A `wasi:http` handler
returns its response, then writes the body. Use `start_async/4` for these. It
returns as soon as the task has a result, and the task keeps running in the
instance. A `stream` or `future` in the result is your end of it: read it, and
the task runs while you wait.

```erlang
{ok, Body} = wasm_component:start_async(I, ~"body", {[], {stream, u8}}, []),
{ok, Chunk} = wasm_async:host_read(Body, 65536, 5000).
```

- `wasm_async:host_read/3` answers `{ok, Bytes}`, then `eof` once the guest
  has finished writing.
- `wasm_async:host_sink/2` takes every write as it happens instead, for a
  destination such as stdout.
- `wasm_component:pump(Inst, Timeout)` runs pending tasks without reading.
  It answers `{finished, 0}`, `{idle, N}` when the `N` tasks left wait for
  you, `{timeout, N}`, or `{error, Reason}` when a task traps.
- `destroy/1` stops tasks still running.

A host import can give the guest a stream or a future of its own:
`wasm_async:host_stream/1` and `host_future/1` return the guest's end and
yours.

## Instantiate one component many times

Each instantiation from bytes decodes the component, checks it and parses its
sections again. When you instantiate the same component many times, as a
server does per request, prepare it once and pass the result instead of the
bytes:

```erlang
{ok, Bin} = file:read_file("echo.component.wasm"),
{ok, Prepared} = wasm_component:prepare(Bin),
{ok, Inst} = wasm_component:instantiate(Prepared),
ok = wasm_component:destroy(Inst).
```

`prepare/1` returns the same errors `instantiate` would. `hold/1` and the WASI
runners take a prepared component too, and the HTTP listener prepares its
component when it starts.

## Notes

- The process that instantiated a component instance owns it. Call it from
  that process, and call `destroy/1` there.
- Malformed input is a value, never a crash: a truncated or ill-typed component
  returns `{error, _}` from `instantiate`, and a bad argument or guest trap
  returns `{error, _}` from `call/4`.
- Strings are passed as UTF-8 by default. They are passed as UTF-16 or as
  Latin-1+UTF-16 when the component declares that encoding. You do not choose
  it.
- `instantiate/3` takes `loader => compile` to build the core modules in the
  calling process, or `loader => load` for the module cache. Leave it out and
  it picks the cache while the `wasm` application runs. The WASI runners spell
  the same choice `compile => true`, and do not pick by themselves; see
  [Options from preview 1](wasi-0-2.md#options-from-preview-1).

## Read this next

[Use a component resource](examples/use-a-component-resource.md), then
[Security](security.md). To change the Component Model code itself, read
[Component internals](component-internals.md).
