# Turn on the compiled tier

This example turns a function the module calls often into BEAM code. Every
instance starts **interpreted**; the **compiled tier**, off by default,
compiles what a module calls most, through Core Erlang, once it has been
called enough.

**You need:** nothing beyond the application.

```erlang
{ok, _} = application:ensure_all_started(wasm),
Src = ~"""
(module
  (func (export "sum") (param $n i32) (result i32) (local $acc i32)
    (block $done
      (loop $next
        (br_if $done (i32.eqz (local.get $n)))
        (local.set $acc (i32.add (local.get $acc) (local.get $n)))
        (local.set $n (i32.sub (local.get $n) (i32.const 1)))
        (br $next)))
    (local.get $acc)))
""",
{ok, Mod} = wasm:compile({wat, Src}).
```

Ask for the tier, and call it enough to get it hot:

```erlang
{ok, Inst} = wasm:instantiate(Mod, #{}, #{compile => true, fuel => infinity}),
[{ok, [500500]} = wasm:call(Inst, ~"sum", [1000]) || _ <- lists:seq(1, 40)],
ok = wasm_jit:await(Inst, 60000),
{ok, [500500]} = wasm:call(Inst, ~"sum", [1000]),
maps:with([compiled, entered], wasm_jit:counts()).
%% => #{compiled := 1, entered := 1}
```

**What happened.** After 32 calls, the default `compile_after`, the module was
compiled in the background; `await/2` waited for that, and the call after it
entered the generated code, which `counts/0` shows. `fuel => infinity` is required: generated code
cannot count fuel, so an instance with a fuel ceiling silently stays
interpreted. Bound compiled code by time instead, in a worker.

It is worth it for a guest that runs long, such as an interpreter, and flat
for a small plugin. Measure your own; [The compiled tier](../compiled-tier.md)
has the numbers, and how to keep compiled code across restarts.

**Clean up:**

```erlang
ok = wasm:destroy(Inst).
```

**Next:** [Run JavaScript](run-javascript.md).
