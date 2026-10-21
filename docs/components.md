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
[Embedding](embedding.md) instead.

You use two modules: `wasm_component` to decode, instantiate and call, and
`wasi_preview2` for the WASI 0.2 host that a component imports. Components
work whether the `wasm` application is started or not. When it is started,
each core module goes through its module cache, so the same bytes are
compiled once per node. When it is not started, each core module is compiled
in the calling process, as `wasm:compile/1` does. The async Canonical ABI
(`async func`, `stream<T>`, `future<T>`) is supported: call an async export
with `wasm_component:call_async/4`. The WASI 0.3 interfaces that use it are
not provided. A 0.2 component never needs them.

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
`none`. You must pass the signature because you cannot get the interface types
from the `.wasm` file through this call. The signature is the WIT function type,
written with the descriptors below.

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
| `{variant, [{Name, D \| none}]}` | `variant` | `{Name, Payload}` or `Name` |
| `{enum, [Name]}` | `enum` | a `Name` binary |
| `{option, D}` | `option<D>` | `{some, V}` or `none` |
| `{result, OkD \| none, ErrD \| none}` | `result<Ok, Err>` | `{ok, V}` / `{error, E}` |
| `{flags, [Name]}` | `flags` | a list of the set `Name`s |

So a guest exporting `run: func(input: list<u8>) -> result<list<u8>, string>` is
called with:

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

## Resources

A component may give you a *resource*: a handle to state that the component
owns. You cannot see inside it. You get it as an `own<T>` (you hold it) or as
a `borrow<T>` (lent for one call). You create one, pass the handle back to
call its methods, and drop it when you are done.

The handle is a small integer. It is an index into the instance's handle
table, not an address inside the guest. In a signature, a resource type is
`{own, TypeIndex}` or `{borrow, TypeIndex}`. A plain `u32` works the same,
because the runtime checks every handle against the export's own signature:

```erlang
{ok, Handle} = wasm_component:call(Inst, ~"[constructor]counter", {[u32], {own, 0}}, [41]),
{ok, 42} = wasm_component:call(Inst, ~"[method]counter.increment", {[{borrow, 0}], u32}, [Handle]).
```

Drop a handle with `drop_resource/3`, naming the resource's destructor export.
It runs the destructor once and returns `ok`:

```erlang
ok = wasm_component:drop_resource(Inst, ~"[dtor]counter", Handle).
```

Every handle is checked before the guest runs. If a check fails, the call
returns `{error, #{class := trap, kind := Kind, ctx := Ctx}}`, and the guest
is not called:

| What you passed | `kind` | `ctx` |
| --- | --- | --- |
| a handle already dropped, dropped twice, or never handed out | `resource_not_live` | `handle`, `operation` |
| a handle of one resource type where another is expected | `resource_wrong_type` | `handle`, `expected`, `actual` |

```erlang
{error, #{class := trap, kind := resource_not_live}} =
    wasm_component:drop_resource(Inst, ~"[dtor]counter", Handle).
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

## Notes

- The process that instantiated a component instance owns it. Call it from
  that process, and call `destroy/1` there.
- Malformed input is a value, never a crash: a truncated or ill-typed component
  returns `{error, _}` from `instantiate`, and a bad argument or guest trap
  returns `{error, _}` from `call/4`.
- Strings are passed as UTF-8 by default. They are passed as UTF-16 or as
  Latin-1+UTF-16 when the component declares that encoding. You do not choose
  it.

## Read this next

[Use a component resource](examples/use-a-component-resource.md), then
[Security](security.md).
