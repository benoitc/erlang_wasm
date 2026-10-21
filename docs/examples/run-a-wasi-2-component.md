# Run a WASI 0.2 component

This example runs a program built by `rustc --target wasm32-wasip2`. The
program is a component, not a core module. It imports the **WASI 0.2**
interfaces (`wasi:cli`, `wasi:io`, `wasi:filesystem`), not the single
`wasi_snapshot_preview1` module. You run it with
`wasi_preview2:run_command/3`. You give it stdin, arguments and a preopened
directory (a host directory the guest may use) the same way as for a
Preview 1 command, and you get back its stdout, stderr and exit code.

**You need:** a checkout of this repository, which has the components in
`test/fixtures/component/`. You need nothing else: the files are already
components, so you do not need `wasm-tools` or an adapter.

```erlang
{ok, _} = application:ensure_all_started(wasm).
```

## Pass bytes through stdin and stdout

`realupper` reads stdin, converts it to upper case, and writes the result to
stdout. It needs no capabilities, so the options map is empty:

```erlang
{ok, Loud} = file:read_file("test/fixtures/component/realupper.component.wasm"),
wasi_preview2:run_command(Loud, <<"make me loud">>, #{}).
%% => {ok, #{exit_code := 0, stdout := <<"MAKE ME LOUD">>}}
```

## Grant a directory to read

Without `preopen`, the component has no filesystem at all. If you grant a
directory, the component sees it at its root `/`, exactly like a Preview 1
preopen. Put a file in a host directory:

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

A preopen is read-only unless you pass `writable => true`. `filewrite`
creates a file in the directory you grant. Read it from the host to check that
it was written:

```erlang
{ok, Writer} = file:read_file("test/fixtures/component/filewrite.component.wasm"),
{ok, #{exit_code := 0}} =
    wasi_preview2:run_command(Writer, <<>>, #{preopen => Dir, writable => true}),
file:read_file(filename:join(Dir, "out.txt")).
%% => {ok, <<"written by the guest\n">>}
```

**What happened.** Each component imported the WASI 0.2 interfaces. The host
answered every import from Erlang: the same host that answers Preview 1.

- The first component had no capabilities and only moved bytes.
- The second read a file through a read-only preopen, and could reach nothing
  outside it.
- The third wrote a file only because you passed `writable => true`.

The same rules apply as in [WASI](../wasi.md): if you leave out a key, the
component does not have that capability.

**Clean up:**

```erlang
ok = file:del_dir_r(Dir).
```

**Next:** [Stop a runaway](stop-a-runaway.md).

## Read this next

The guide behind this example: [Components](../components.md).
