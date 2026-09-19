# Pass bytes

This example sends a binary into a guest, lets it change the bytes in place,
and reads them back. Numbers pass through a call; everything else passes
through the guest's **linear memory**, its resizable byte array.

**You need:** nothing beyond the application.

```erlang
{ok, _} = application:ensure_all_started(wasm).
```

A guest that upper-cases ASCII in place:

```erlang
Src = ~"""
(module
  (memory (export "memory") 1)
  (func (export "upper") (param $p i32) (param $n i32) (local $c i32)
    (block $done
      (loop $next
        (br_if $done (i32.eqz (local.get $n)))
        (local.set $c (i32.load8_u (local.get $p)))
        (if (i32.and (i32.ge_u (local.get $c) (i32.const 97))
                     (i32.le_u (local.get $c) (i32.const 122)))
          (then (i32.store8 (local.get $p)
                            (i32.sub (local.get $c) (i32.const 32)))))
        (local.set $p (i32.add (local.get $p) (i32.const 1)))
        (local.set $n (i32.sub (local.get $n) (i32.const 1)))
        (br $next)))))
""",
{ok, Mod}  = wasm:compile({wat, Src}),
{ok, Inst} = wasm:instantiate(Mod, #{}).
```

Write, call, read:

```erlang
In = ~"hello, wasm",
ok = wasm:write_memory(Inst, 0, In),
{ok, []} = wasm:call(Inst, ~"upper", [0, byte_size(In)]),
wasm:read_memory(Inst, 0, byte_size(In)).
%% => {ok, ~"HELLO, WASM"}
```

**What happened.** You chose where the bytes went, address 0, and told the
guest where and how long. Real guests usually decide that themselves, with a
fixed buffer or an allocator they export; [Pass data in and
out](../passing-data.md) covers both, and JSON.

**Clean up:**

```erlang
ok = wasm:destroy(Inst).
```

**Next:** [Run a WASI command](run-a-wasi-command.md).
