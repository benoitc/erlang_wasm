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
WASI 0.2 host a component imports, `wasi_preview2`. Components work with or
without the `wasm` application started: when it runs, each core module goes
through its module cache, so the same bytes compile once per node; when it does
not, they are compiled inline, as `wasm:compile/1` does. Only the synchronous
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
`own<T>` (you hold it) or a `borrow<T>` (lent for one call). You construct one,
pass the handle back to call its methods, and drop it when you are done.

The handle you get is a small integer, an index into the instance's handle
table, not anything inside the guest. In a signature a resource type is
`{own, TypeIndex}` or `{borrow, TypeIndex}`; a plain `u32` works the same,
because the runtime checks every handle against the export's own signature:

```erlang
{ok, Handle} = wasm_component:call(Inst, ~"[constructor]counter", {[u32], {own, 0}}, [41]),
{ok, 42} = wasm_component:call(Inst, ~"[method]counter.increment", {[{borrow, 0}], u32}, [Handle]).
```

Drop a handle with `drop_resource/3`, naming the resource's destructor export.
It runs the destructor once and answers `ok`:

```erlang
ok = wasm_component:drop_resource(Inst, ~"[dtor]counter", Handle).
```

Every handle is checked before the guest runs. A check that fails answers
`{error, #{class := trap, kind := Kind, ctx := Ctx}}`, and the guest is not
called:

| What you passed | `kind` | `ctx` |
| --- | --- | --- |
| a handle already dropped, dropped twice, or never handed out | `resource_not_live` | `handle`, `operation` |
| a handle of one resource type where another is expected | `resource_wrong_type` | `handle`, `expected`, `actual` |

```erlang
{error, #{class := trap, kind := resource_not_live}} =
    wasm_component:drop_resource(Inst, ~"[dtor]counter", Handle).
```

- Each instance has its own table: a handle from one instance means nothing to
  another.
- `destroy/1` discards every handle the instance still holds. No destructor
  runs, because the guest's memory goes with the instance.
- When a resource passes between composed components, the component that
  receives an `own` gets a handle of its own. It can use the resource while it
  holds the handle, and dropping it runs the destructor in the component that
  defined the resource.

For a runnable version, see [Use a component resource](examples/use-a-component-resource.md).

## Notes

- One component instance is owned by the process that instantiated it; call it
  from that process and `destroy/1` it there.
- Malformed input is a value, never a crash: a truncated or ill-typed component
  returns `{error, _}` from `instantiate`, and a bad argument or guest trap
  returns `{error, _}` from `call/4`.
- Strings marshal as UTF-8 by default, and as UTF-16 or Latin-1+UTF-16 when the
  component's lift declares that encoding; you do not choose it.
