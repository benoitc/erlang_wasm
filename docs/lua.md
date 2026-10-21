# Lua

This page shows you how to run Lua code that you receive at request time. The
code runs in a sandbox that can see one directory and nothing else. Read it to
decide whether your Lua code can run here, and when you build the artifact:
Lua needs two build flags that no other guest in this repository needs.

A few words used on this page:

- a **worker** is a process that runs one request at a time with a deadline;
- an **adapter** is the module that teaches a worker one language, here
  `wasm_lua`;
- the **tenant** is the person who writes the Lua code you run;
- a **runner** is the process that runs the guest for one request;
- a **heap floor** is a minimum heap size given to a process when it starts,
  so the Erlang garbage collector runs less often.

The [glossary](concepts.md#glossary) defines the others.

## Run one

> **Where these modules come from.** `wasm_lua` and the worker kernel it runs
> on (`wasm_script_worker`) are installed with the application. You supply
> the Lua artifact, the `.wasm` file.

```sh
scripts/build-lua-reactor.sh
```

<!-- check: run -->
<!-- check: needs lua_reactor -->
```erlang
{ok, W} = wasm_script_worker:start_link(
            wasm_lua,
            #{path => "test/fixtures/lang/lua_reactor.wasm",
              limits => wasm_lua:limits()}),
{ok, #{result := #{~"answer" := 42}}} =
    wasm_script_worker:run(W, #{source => <<"function main(c)"
                                       " return {answer = c.value + 1} end">>,
                           context => #{~"value" => 41}}).
```

The tenant defines a global `main`, because Lua has no export syntax:

```lua
function main(context)
    return {answer = context.value + 1}
end
```

A worker starts in about 75 ms. A request takes 30 ms, or **12.7 ms** with
the heap floor below. Here Lua is clearly faster than the other two guests.

## The runner's heap floor

`wasm_lua` gives every request runner a heap floor of 200,000 words by
default, so you do not need to set anything. It makes a request more than
twice as fast: **12.7 ms instead of 30.0 ms**, with 23 garbage collections
instead of 98.

Set the option yourself to change it, or pass `0` to turn it off:

<!-- check: run -->
<!-- check: fresh -->
<!-- check: needs lua_reactor -->
```erlang
{ok, W} = wasm_script_worker:start_link(
            wasm_lua,
            #{path => "test/fixtures/lang/lua_reactor.wasm",
              limits => wasm_lua:limits(),
              runner_min_heap_words => 0}).
```

Pass it next to `root`, not inside the map that `wasm_lua:limits/0` returns.
[How a heap floor works](tuning.md#how-a-heap-floor-works) explains why, and
how the number is rounded.

Above 200,000 words Lua gets no faster. The value is rounded up to 318,187
words, about 2.5 MB, held only while a request runs. The right value depends
on the guest, so a different build needs its own; [the tuning
guide](tuning.md) shows how to find it. `capture_min_heap_words` is for the
worker start, and it does not help here: the start takes only 75 ms.

## What you get

You get the language and its standard library, a JSON context in and a JSON
result out, and file access controlled by capabilities. The JSON encoder and
decoder are written in Lua and loaded when the interpreter starts. So they are
compiled once, into the image the worker saves after the start, and not once
per request.

In Lua, a table is both an array and an object, so the encoder must choose. A
table whose keys are exactly `1..n` becomes a JSON array. Any other table,
including an empty one, becomes a JSON object.

## What you do not get

**`os.execute` and `io.tmpfile`.** They exist, because Lua's standard library
refers to them, but they fail: there is no shell, and the only directory is
read-only. `os.tmpname` fails the same way.

**A network API.** It is not missing, it is **not granted**: without a `net`
key there is no network, whatever the artifact imports. A `wasi_net` rule
grants it; [the WASI guide](wasi.md) describes what you then get.

**Coroutines that live longer than a request.** `coroutine` works inside a
request. But a request is a fixed sequence of calls, and the instance is
destroyed when the request ends.

**`require` of a file on disk.** The tenant's code (a "chunk" in Lua) is
loaded from an absolute path, never through a search path. So it can only
load modules that the host put there.

## The build needs two flags, and one is required

Lua reports errors with `longjmp`. On WebAssembly, `longjmp` uses exception
handling, which needs these flags:

```text
-mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false
```

Without the second flag the module does not load, and you get
`#{kind => illegal_opcode, ctx => #{opcode => 6}}`. Opcode 6 is the old `try`
instruction from an earlier version of the proposal. LLVM still produces it by
default, but this runtime implements the standard `try_table`. Any other code
that uses `longjmp` has the same problem.

`test/fixtures/lang/LUA.md` has the rest of the build.

## Errors

An error in the tenant's code comes back as a value, in the same shape as for
every other language:

```erlang
{error, #{class := adapter, kind := adapter_failure,
          ctx := #{code := ~"exception"}}}
```

`code` is `~"no_entry_point"` when no global `main` is defined, and
`~"exception"` for any error the code raised, while loading or during the
call.

## Read this next

[Tuning](tuning.md), then [Snapshots](snapshots.md).
