# Pass data in and out

This page shows how values cross between Erlang and a guest: numbers through
a call, everything else through the guest's memory. Read it when your first
call works with integers and your next one needs a string, a binary or JSON.

## Numbers go through the call

A WebAssembly function takes and returns numbers only: `i32`, `i64`, `f32`
and `f64`. They map onto Erlang terms directly:

| WebAssembly | Erlang |
| --- | --- |
| `i32`, `i64` | an integer, signed |
| `f32`, `f64` | a float |
| a NaN or an infinity | `{nan, Sign, Payload}`, `infinity` or `neg_infinity`, because an Erlang float cannot hold one; pass the same atoms in |

<!-- check: run -->
```erlang
Src = ~"""
(module
  (func (export "half") (param f64) (result f64)
    local.get 0 f64.const 0.5 f64.mul)
  (func (export "minus_one") (result i32) i32.const -1))
""",
{ok, Mod}  = wasm:compile({wat, Src}),
{ok, Inst} = wasm:instantiate(Mod, #{}),
{ok, [1.5]} = wasm:call(Inst, ~"half", [3.0]),
{ok, [-1]}  = wasm:call(Inst, ~"minus_one", []).
```

## Everything else goes through memory

A guest's **linear memory** is its resizable byte array. To pass a string or a
binary, write the bytes into it and pass the address and the length; to get
bytes back, read them from where the guest says it put them.

<!-- check: fresh -->
<!-- check: run -->
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
{ok, Inst} = wasm:instantiate(Mod, #{}),
In = ~"hello, wasm",
ok = wasm:write_memory(Inst, 0, In),
{ok, []} = wasm:call(Inst, ~"upper", [0, byte_size(In)]),
{ok, ~"HELLO, WASM"} = wasm:read_memory(Inst, 0, byte_size(In)).
```

Strings are UTF-8 binaries on both sides: an Erlang `~"..."` is already the
bytes a guest reads.

## Decide who owns the buffer

Where the bytes go is an agreement between you and the guest. Three are common:

| the guest | you |
| --- | --- |
| exports a fixed buffer, as `buffer()` in [A plugin per request](examples/plugin-per-request.md) | write there, and pass only the length |
| exports an allocator, `alloc(Len) -> Ptr` | call it, write at `Ptr`, pass `Ptr` and `Len` |
| writes its answer where you asked | pass an output address, read after the call |

A guest built by Rust or C usually exports an allocator; a small hand-written
one usually has a fixed buffer.

## Inside a host function, use the context

A host function receives a context rather than the instance, and reads and
writes the calling instance's memory through it. That is how a guest hands
you a string:

<!-- check: fresh -->
<!-- check: run -->
```erlang
Src = ~"""
(module
  (import "env" "log" (func $log (param i32 i32)))
  (memory 1)
  (data (i32.const 0) "from the guest")
  (func (export "run") (call $log (i32.const 0) (i32.const 14))))
""",
{ok, Mod} = wasm:compile({wat, Src}),
Log = fun(Ctx, [Ptr, Len]) ->
          {ok, Bin} = wasm:read_memory(Ctx, Ptr, Len),
          logger:notice("guest says: ~ts", [Bin]),
          {ok, []}
      end,
{ok, Inst} = wasm:instantiate(Mod, #{{~"env", ~"log"} => Log}),
{ok, []}   = wasm:call(Inst, ~"run", []).
```

## JSON is bytes too

Encode on one side, decode on the other, and pass the bytes as above:

```erlang
Bytes = iolist_to_binary(json:encode(#{~"value" => 41})),
%% ... write Bytes into the guest, and read its answer back as Out ...
#{~"answer" := 42} = json:decode(Out).
```

The language workers do exactly this for you: `wasm_script_worker:run/3` takes
an Erlang term as the context and gives the script's result back as one. See
[Run JavaScript](examples/run-javascript.md).
