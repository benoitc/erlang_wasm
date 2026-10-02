# Components

The WebAssembly Component Model is how you run a `.wasm` that ships *typed
interfaces* rather than a core module of bare numeric functions. A component
declares what it imports and exports in terms of strings, lists, records,
variants and results, and the runtime marshals those values across the boundary
for you through the Canonical ABI. Read this when your toolchain emits a
component (`cargo-component`, `wit-bindgen`, `componentize-py`, `jco`, or a
`wac`-composed bundle), or when you want to plug several components together.

**Do you need this?** Yes, if `wasm-tools print your.wasm` starts with
`(component ...)`, or your build targets `wasm32-wasip2`. No, for a core module
(`(module ...)`) of functions over the memory you give it: use
[Embedding](embedding.md) instead.

The entry points are `wasm_component` (decode, instantiate, call) and, for the
WASI 0.2 host a component imports, `wasi_preview2`. Only the synchronous
Component Model is implemented; the async ABI (`stream`, `future`, WASI 0.3) is
not, and a 0.2 component never needs it.

## Run a component

Instantiate the bytes, call an export by name with its signature, and destroy
the instance when you are done so its resources are freed:

```erlang
{ok, Bin} = file:read_file("echo.component.wasm"),
{ok, Inst} = wasm_component:instantiate(Bin),
{ok, Upper} = wasm_component:call(Inst, ~"run", {[{list, u8}], {list, u8}}, [~"hello"]),
ok = wasm_component:destroy(Inst).
```

The third argument is the export's signature as `{Params, Result}`: `Params` is
a list of one descriptor per parameter, and `Result` is one descriptor or
`none`. You pass the signature because a `.wasm` does not carry its interface
types in a form the caller names here; it is the WIT function type, written as
the descriptors below.

## Describe the signature

A descriptor names a component-model value type. Use these in the parameter list
and the result of `call/4`:

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

A `result` lifts as `{ok, V}` on the ok arm and `{error, E}` on the error arm, so
a guest that rejects its input comes back as a value, not a trap:

```erlang
{ok, {error, Reason}} = wasm_component:call(Inst, ~"run", Sig, [~""]).
```

## Supply the imports it needs

A component that imports interfaces (anything built for `wasm32-wasip2` imports
WASI) is instantiated with a map of host functions, keyed
`{InterfaceName, FieldName}`. The WASI 0.2 host builds that map for you:

```erlang
{ok, Inst} = wasm_component:instantiate(Bin, wasi_preview2:imports()),
{ok, _} = wasm_component:call(Inst, ~"run", {[], u32}, []).
```

Leave a capability out of the host options and the guest cannot reach it, the
same posture as Preview 1. For running a command component (one with a `main`)
with a directory, stdin and arguments, see the WASI 0.2 section of
[WASI](wasi.md) and the worked [Run a WASI 0.2 component](examples/run-a-wasi-2-component.md).

## Compose components

A component composed from several others (what `wac plug` or `wasm-tools
compose` produces) has no work for you to do differently: its nested components
are instantiated and their imports and exports are wired together inside the
one instance. Values cross a cross-component call by copy, each side keeping its
own memory.

```erlang
{ok, Bin} = file:read_file("composed.component.wasm"),
{ok, Inst} = wasm_component:instantiate(Bin),
{ok, Greeting} = wasm_component:call(Inst, ~"run", {[], string}, []),
ok = wasm_component:destroy(Inst).
```

## Resources

A component may hand out a *resource*: an opaque handle to state it owns, as an
`own<T>` (you hold it) or a `borrow<T>` (lent for one call). Handles cross the
boundary as the integers the component mints; you pass them back to call a
method, and `wasm_component:destroy/1` tears down what an instance still holds.
A resource type appears in a signature as `{own, TypeIndex}` or
`{borrow, TypeIndex}`, which marshal as a handle integer:

```erlang
{ok, Handle} = wasm_component:call(Inst, ~"[constructor]counter", {[u32], {own, 0}}, [41]),
{ok, 42} = wasm_component:call(Inst, ~"[method]counter.increment", {[{borrow, 0}], u32}, [Handle]).
```

Each component instance has its own handle table and the handles in it are
checked, so resource misuse is caught rather than silently accepted:

- Dropping a handle runs the resource's destructor, once, and frees the handle.
- Dropping a handle twice, or calling a method on one after it was dropped,
  traps.
- A handle of one resource type passed where another type is expected traps.
- When a resource is passed between composed components, ownership moves with it:
  it is live in one component at a time, and using one a component has handed away
  traps. A borrowed handle is reachable in the callee only for that call.

For a runnable version, see [Use a component resource](examples/use-a-component-resource.md).

## Notes

- One component instance is owned by the process that instantiated it; call it
  from that process and `destroy/1` it there.
- Malformed input is a value, never a crash: a truncated or ill-typed component
  returns `{error, _}` from `instantiate`, and a bad argument or guest trap
  returns `{error, _}` from `call/4`.
- Strings marshal as UTF-8 by default, and as UTF-16 or Latin-1+UTF-16 when the
  component's lift declares that encoding; you do not choose it.
