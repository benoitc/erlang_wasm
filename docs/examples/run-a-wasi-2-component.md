# Run a WASI 0.2 component

This example runs a program built by `rustc --target wasm32-wasip2`: a component,
not a core module, that imports the **WASI 0.2** worlds (`wasi:cli`,
`wasi:io`, `wasi:filesystem`) rather than the flat `wasi_snapshot_preview1`
imports. You run it with `wasi_preview2:run_command/3`, handing it stdin, arguments
and a preopened directory the same way you grant a Preview 1 command, and get its
stdout, stderr and exit code back.

**You need:** a checkout of this repository, which has the components in
`test/fixtures/component/`. Nothing else: the fixtures are already components, so
no `wasm-tools` and no adapter are involved.

```erlang
{ok, _} = application:ensure_all_started(wasm).
```

## Pass bytes through stdin and stdout

`realupper` reads stdin, upper-cases it, and writes the result to stdout. It needs
no capabilities, so the options map is empty:

```erlang
{ok, Loud} = file:read_file("test/fixtures/component/realupper.component.wasm"),
wasi_preview2:run_command(Loud, <<"make me loud">>, #{}).
%% => {ok, #{exit_code := 0, stdout := <<"MAKE ME LOUD">>}}
```

## Grant a directory to read

Leave `preopen` out and the component has no filesystem at all. Grant one and the
component sees it at the guest root, exactly like a Preview 1 preopen. Place a file
in a host directory:

```erlang
Dir = filename:join(filename:basedir(user_cache, "erlang_wasm"), "wasi2-example"),
ok = filelib:ensure_path(Dir),
ok = file:write_file(filename:join(Dir, "note.txt"), ~"from the host").
```

`realcat` opens the file named in its arguments and writes it to stdout:

```erlang
{ok, Reader} = file:read_file("test/fixtures/component/realcat.component.wasm"),
wasi_preview2:run_command(Reader, <<>>,
                          #{args => [~"realcat", ~"note.txt"], preopen => Dir}).
%% => {ok, #{exit_code := 0, stdout := <<"from the host">>}}
```

## Grant a directory to write

A preopen is read-only unless you pass `writable => true`. `filewrite` creates a
file in the directory you grant; read it back from the host to prove it landed:

```erlang
{ok, Writer} = file:read_file("test/fixtures/component/filewrite.component.wasm"),
{ok, #{exit_code := 0}} =
    wasi_preview2:run_command(Writer, <<>>, #{preopen => Dir, writable => true}),
file:read_file(filename:join(Dir, "out.txt")).
%% => {ok, <<"written by the guest\n">>}
```

**What happened.** Each component imported the WASI 0.2 worlds; the host answered
every import from Erlang, the same host that answers Preview 1. The first saw no
capabilities and only moved bytes; the second read a file over a `read` preopen and
could reach nothing outside it; the third wrote one only because you passed
`writable => true`. The same grant rules apply as in [WASI](../wasi.md): a key you
leave out is a capability the component does not have.

**Clean up:**

```erlang
ok = file:del_dir_r(Dir).
```

**Next:** [Stop a runaway](stop-a-runaway.md).
