# Lua

Run Lua that arrives at request time, in a sandbox that gets one directory and
nothing else. You need this page when you are deciding whether what you want to
run can run here, and when you are building the artifact, since Lua needs two
build flags that nothing else in this repository does.

## Run one

```
scripts/build-lua-reactor.sh
```

```erlang
{ok, _} = worker_reaper:start_link(#{scratch => "/var/tmp/lua"}),
{ok, W} = script_worker:start_link(
            lua_reactor_adapter,
            #{path => "test/fixtures/lang/lua_reactor.wasm", root => scratch,
              limits => lua_reactor_adapter:limits()}),
{ok, #{result := #{~"answer" := 42}}} =
    script_worker:run(W, #{source => ~"function main(c)"
                                     " return {answer = c.value + 1} end",
                           context => #{~"value" => 41}}).
```

The tenant defines a global `main`, because Lua has no export syntax:

```lua
function main(context)
    return {answer = context.value + 1}
end
```

A worker starts in about 75 ms and a request costs about 25 ms, which is the
one place Lua is simply better than the other two guests here.

## What you get

The language and its standard library, a JSON context in and a JSON result out,
and capability-controlled file access. The JSON codec is written in Lua and
evaluated when the interpreter starts, so it is compiled once into the image
rather than once per request.

Tables are both arrays and objects in Lua, so the codec has to choose: a table
whose keys are exactly `1..n` encodes as an array, and anything else, including
an empty table, encodes as an object.

## What you do not get

**`os.execute` and `io.tmpfile`.** They exist, because Lua's standard library
references them, and they fail: there is no shell to run and one read-only
directory to write into. `os.tmpname` fails the same way.

**A network API.** Not unavailable, **ungranted**: an absent `net` key is no
network however much the artifact imports. `wasi_net` is what would grant it,
and what that gives you is described in [the WASI guide](wasi.md).

**Coroutines that outlive a request.** `coroutine` works inside one, but a
request is a finite sequence of calls and the instance goes when it ends.

**`require` of anything on disk.** The tenant's chunk is loaded by absolute
path, never by a search path, so nothing it writes can reach a module the host
did not put there.

## Building it needs two flags, and one of them is not optional

Lua signals errors with `longjmp`, which on WebAssembly is exception handling:

```
-mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false
```

Without the second the module will not load, with
`#{kind => illegal_opcode, ctx => #{opcode => 6}}`. Opcode 6 is the legacy
`try` from the superseded proposal, which LLVM still emits by default; this
runtime implements the standardised `try_table`. Anything else that unwinds
with `longjmp` will meet the same thing.

`test/fixtures/lang/LUA.md` has the rest of the build.

## Errors

A tenant error arrives as a value, in the same shape every other language uses:

```erlang
{error, #{class := adapter, kind := adapter_failure,
          ctx := #{code := ~"exception", ...}}}
```

`~"no_entry_point"` when no global `main` is defined, and `~"exception"` for
anything the chunk raised, at load time or during the call.
