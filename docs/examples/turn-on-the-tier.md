# Turn on the compiled tier

This example translates a function that the module calls often into BEAM
code (code for the Erlang virtual machine). Every instance starts
**interpreted**: the runtime reads the guest's instructions one by one. The
**compiled tier** is off by default. When it is on, it compiles the functions
a module calls most, through Core Erlang, once the module has been called
enough times.

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

Turn on the tier, and call the function enough times to make it "hot"
(worth compiling):

```erlang
{ok, Inst} = wasm:instantiate(Mod, #{}, #{compile => true, fuel => infinity}),
[{ok, [500500]} = wasm:call(Inst, ~"sum", [1000]) || _ <- lists:seq(1, 40)],
ok = wasm_jit:await(Inst, 60000),
{ok, [500500]} = wasm:call(Inst, ~"sum", [1000]),
maps:with([compiled, entered], wasm_jit:counts()).
%% => #{compiled := 1, entered := 1}
```

**What happened.** After 32 calls (the default `compile_after`), the runtime
compiled the module in the background. `await/2` waited for the compile. The
next call ran the generated code, as `counts/0` shows.

`fuel => infinity` is required. Generated code cannot count fuel, so an
instance with a fuel limit stays interpreted, and no error tells you. Limit
compiled code by time instead, in a worker.

The tier helps a guest that runs for a long time, such as an interpreter. For
a small plugin it changes nothing measurable. Measure your own module;
[The compiled tier](../compiled-tier.md) has the numbers, and explains how to
keep compiled code across restarts.

**Clean up:**

```erlang
ok = wasm:destroy(Inst).
```

**Next:** [Run JavaScript](run-javascript.md).

## Read this next

The guide behind this example: [The compiled tier](../compiled-tier.md).
