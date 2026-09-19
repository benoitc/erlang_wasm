# Call an export

This example builds a module from text, makes an instance of it and calls one
of its functions. It is the smallest complete use of the runtime.

**You need:** nothing beyond the application.

```erlang
{ok, _} = application:ensure_all_started(wasm).
```

The guest, in the WebAssembly text format:

```erlang
Src = ~"""
(module
  (func (export "add") (param i32 i32) (result i32)
    local.get 0 local.get 1 i32.add))
""".
```

Build it, run it:

```erlang
{ok, Mod}  = wasm:compile({wat, Src}),
{ok, Inst} = wasm:instantiate(Mod, #{}),
wasm:call(Inst, ~"add", [3, 4]).
%% => {ok, [7]}
```

**What happened.** `compile/1` decoded and validated the text into a
**module**. `instantiate/2` made an **instance**, a running copy with its own
state; the empty map is its imports. `call/3` ran the exported `add` and
answered with the list of its results.

**Clean up:**

```erlang
ok = wasm:destroy(Inst).
```

**Next:** [Call Erlang from a guest](call-erlang-from-a-guest.md).
