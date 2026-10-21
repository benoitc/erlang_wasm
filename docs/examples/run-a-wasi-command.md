# Run a WASI command

This example runs a program built by `rustc --target wasm32-wasip1`. It has
a `main`, reads its arguments, a file and the clock, and writes to stdout.
**WASI** is the standard set of operations that such a program imports. You
grant each one by name.

**You need:** a checkout of this repository, which has the program in
`test/fixtures/rust/`.

```erlang
{ok, _} = application:ensure_all_started(wasm).
```

Give it one directory, read-only, with one file in it:

```erlang
Dir = filename:join(filename:basedir(user_cache, "erlang_wasm"), "wasi-example"),
ok = filelib:ensure_path(Dir),
ok = file:write_file(filename:join(Dir, "note.txt"), ~"from the host").
```

Run it:

```erlang
{ok, Mod} = wasm:load_file("test/fixtures/rust/wasi_demo.wasm"),
{ok, Exit, Stdout, _Stderr} =
    wasi:run(Mod, #{args => [~"demo"],
                    dirs => [{~"/data", Dir, read}]}),
io:format("~ts", [Stdout]),
Exit.
%% => 7
```

**What happened.** The program saw `/data`, read `note.txt` from it and
listed the directory. When it tried to write there, it was refused, because
the grant said `read`. It could not reach anything outside `/data`. It exits
with status 7 on purpose, so that you can see the status come back.

Without `dirs`, the program has no filesystem at all. It does not get your
working directory. Without `net`, it has no network. See
[WASI](../wasi.md).

**Clean up:**

```erlang
ok = file:del_dir_r(Dir).
```

**Next:** [Run a WASI 0.2 component](run-a-wasi-2-component.md).

## Read this next

The guide behind this example: [WASI](../wasi.md).
