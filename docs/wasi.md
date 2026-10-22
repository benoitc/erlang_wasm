# WASI

WASI lets you run a program built for `wasm32-wasip1` (Rust, TinyGo, clang
with a WASI sysroot). You give it the files, environment, clocks and sockets
that you choose. Read this page when your guest is a complete program, not
only a set of exported functions, and when you must decide what it may reach.

**Do you need this?** Yes, if your guest was built for WASI (it has a `main`,
or it reads files or the clock), or if you give it access to anything. No, if
the module only computes over the memory you give it.

In this project, WASI is written in Erlang. It is not a separate WASI runtime
inside the node. Every syscall is an ordinary host function, so you can trace
it, replace it or refuse it. Erlang code makes every decision about what the
guest may do.

This page is WASI Preview 1 (`wasm32-wasip1`). For WASI 0.2 (`wasm32-wasip2`,
the Component Model), read [WASI 0.2](wasi-0-2.md), or go straight to
[Run a WASI 0.2 component](examples/run-a-wasi-2-component.md).

## The words on this page

| word | what it means here |
| --- | --- |
| **syscall** | a WASI function the guest imports, such as `fd_read` or `path_open`. Here each one is an Erlang host function. |
| **capability** | a permission you give the guest, such as a directory or a network address. See the [glossary](concepts.md#glossary). |
| **grant** | the map entry that gives one capability, such as `dirs` or `net`. |
| **preopen** | a directory you open for the guest before it starts. The guest can only open files relative to one. |
| **descriptor** (fd) | a small number the guest uses to name an open file, directory or socket. |
| **backend** | how the host resolves file paths: `native` (with the optional file NIF) or `fallback` (pure Erlang). |
| **NIF** | native code loaded into the Erlang VM. Here only one small, optional file NIF exists. |
| **symlink** | a symbolic link: a file whose content is the path of another file. |

## Run a command

```erlang
{ok, Mod} = wasm:load_file("hello.wasm"),
{ok, Exit, Stdout, Stderr} =
    wasi:run(Mod, #{args   => [~"prog", ~"--verbose"],
                    env    => #{~"MODE" => ~"production"},
                    dirs   => [{~"/data", "/srv/app/data", read}],
                    clocks => [monotonic],
                    random => strong}).
```

For finer control, build the imports yourself and drive the instance:

```erlang
{ok, Inst} = wasm:instantiate(Mod, wasi_preview1:imports(Config)),
Result = wasm:call(Inst, ~"_start", []).
```

## Grant capabilities

If you leave a key out, the module does not get that capability. The
syscall then returns `ENOTCAPABLE`. This error is different from `EACCES` on
purpose. The module can tell "you did not get this permission" apart from "the
operating system refused".

| key | grants | leaving it out means |
| --- | --- | --- |
| `args` | `env::args()` | zero arguments |
| `env` | environment variables | zero variables, **not** the host's |
| `dirs` | preopened directories | **no filesystem at all** |
| `clocks` | `[monotonic]`, `[realtime]`, or both; `monotonic` counts nanoseconds since the node started | that clock returns `ENOTCAPABLE` |
| `random` | `strong`, or `{seed, N}` for reproducibility | `random_get` refused |
| `stdout`, `stderr` | a pid, fun, or io device | output discarded |
| `stdin` | a binary or a fun | end of file |
| `net` | sockets, to the addresses named | **no network at all** |

A `stdin` fun may block. A `stdout` pid or fun receives each write at the
moment it happens. With these two, a guest that runs for a long time can
exchange messages with you. [streams.md](streams.md) shows how.

`dirs` often surprises people. Without `dirs`, the module does not get the
working directory, and it does not get read-only access. It gets no
filesystem at all, and no descriptor to open anything from.

`{seed, N}` gives the same random bytes on every run for the same `N`. Inside
one run, each call gets *different* bytes: the generator is seeded once per
instance and keeps its state between calls. A seed is never the default. A
module that believes its random bytes are unpredictable when they are not is
in a worse position than a module that is told it has no randomness.

## Preopen a directory

```erlang
dirs => [{~"/data",   "/srv/app/data",  read},
         {~"/scratch", "/tmp/app-1234", write}]
```

Each entry maps a guest path to a host path. The module finds the entries
with `fd_prestat_get` and `fd_prestat_dir_name`. It learns only the guest
path. The host path stays hidden.

`read` allows opening, reading, listing and stat. `write` also allows
creating, renaming, unlinking and truncating. The host removes any right the
grant does not include from what the module asks for. So a `read` preopen
never gives a writable descriptor, whatever flags the module passes.

### What the sandbox refuses

Each way to escape below has its own test case. The host refuses each one
with `ENOTCAPABLE`, not `ENOENT`. So a module cannot use the error code to
learn how your directories are laid out:

| the module asks for | it gets |
| --- | --- |
| `note.txt`, `./note.txt` | opened |
| `../secret/key.txt` | refused |
| `/etc/passwd` | refused |
| `escape.txt`, a symlink out of the sandbox | refused |
| `outdir/key.txt`, through a symlinked directory | refused |
| `sub/../../secret/key.txt` | refused |
| `missing.txt` | `ENOENT` |

These cases were checked with Rust's own `std::fs`, not only with
hand-written test programs.

### Check which backend you have

```erlang
wasi_fs:backend().        %% native | fallback
```

`native` means the optional NIF was built. The host opens a path one
component at a time with `openat(..., O_NOFOLLOW)`. The kernel resolves each
name exactly once and follows no symlink at any depth. This closes the
time-of-check-to-time-of-use window (a race where an attacker changes a path
between the check and the open). If someone replaces a component with a
symlink between the check and the open, the open is still refused.

`fallback` means the NIF is not there. The host checks paths with
`filelib:safe_relative_path/2`, which refuses every escape above, and checks
again after opening. This makes the window smaller but does not close it,
because Erlang gives access to neither `openat` nor `O_NOFOLLOW`. Do not use a
preopen on a directory that a hostile party can write to at the same time.

## Grant a network

Name what may be reached, the way you name a directory:

```erlang
net => #{connect     => [{tcp, ~"10.0.0.0/8", {8000, 8099}}],
         listen      => [{tcp, ~"127.0.0.1", 8080}],
         resolve     => allow,
         max_sockets => 32,
         timeout     => 30000}
```

Write a rule as `{Proto, Addr, Port}`. `Proto` is `tcp` or `udp`, `Addr` is an
IP tuple, a binary address or a binary CIDR, and `Port` is a number, a
`{Lo, Hi}` range, or `any`.

Read these notes before you write your first grant:

- Without a `net` key there is no network. `#{net => #{}}` is the same. There
  is no default list, so a grant that names nothing allows nothing.
- `connect` and `listen` are separate. One does not include the other.
- `resolve` turns on `sock_getaddrinfo`. Its default is `deny`.
- A service name is looked up in a fixed table (`http`, `https`, `ssh`,
  `domain`, `postgresql` and about twenty more), **not** in your
  `/etc/services`. A numeric port always works. Any other name gives
  `EINVAL`. The system lookup needed `binary_to_atom/2` on a string the guest
  chose. Atoms are never freed and are shared by the whole node, so a guest
  must never be able to create one. If the table does not have your name, pass
  the port number.
- `max_sockets` limits how many socket descriptors one instance holds at the
  same time. `timeout` limits how long one blocking call may wait.
- A malformed rule raises `{bad_net_grant, _}` when you build the import map.
  It does not fail later by refusing everything. A sandbox that silently
  refuses everything looks exactly like one that works.

### Listen

If you name one address and one port, the host can open that socket, so it
does. The listening socket appears as a preopened descriptor after the
directories. The module accepts connections on it without naming an address:

```erlang
{ok, Inst} = wasm:instantiate(Mod, wasi:imports(
    #{net => #{listen => [{tcp, ~"127.0.0.1", 8080}]}})),
%% fd 3 is listening. sock_accept on it works; nothing else was granted.
```

If you name a range or a CIDR, the host opens nothing. The rule only allows
the module to bind an address inside it.

### Connect

```erlang
net => #{connect => [{tcp, ~"93.184.216.0/24", 443}], resolve => allow}
```

The module opens a socket with `sock_open`, then calls `sock_connect` with an
address. The host checks that address against your grant. Then it gives the
same address to the operating system. Nothing between the check and the
connect can change the destination.

Three behaviours to know:

- **Grants name addresses, never host names.** You cannot write a rule that
  says `example.com`. The host would have to resolve the name once to check
  it, and again to use it, and the two answers can differ.
  `sock_getaddrinfo` is a separate capability, and its answer gives no
  permission. A module may learn an address that it cannot reach.
  `sock_connect` then refuses that address.
- **`::ffff:127.0.0.1` is `127.0.0.1`.** The host converts an IPv4-mapped
  address to plain IPv4 before the check, and connects to the converted
  address. So the mapped form cannot get past an IPv4 rule. The old,
  deprecated IPv4-compatible form (`::1.2.3.4`) is not converted, because
  `::0.0.0.1` and `::1` are the same address. It needs an IPv6 rule.
- **Binding is checked against `listen`.** Binding takes a local address, and
  `listen` is the grant for local addresses. So a client that wants a specific
  source port needs a `listen` rule for it. A loopback grant does not allow
  binding `0.0.0.0`.

### Which socket calls you get

Preview 1 defines four socket calls: `sock_accept`, `sock_recv`, `sock_send`
and `sock_shutdown`. All four need a socket that already exists. This is why a
listening socket has to come from the host. Sockets also work with `fd_read`,
`fd_write`, `fd_close` and `fd_fdstat_get`. Rust's `TcpStream` uses these.

Every other call a client needs is an **extension**. WasmEdge defined these
calls, and they use the same `wasi_snapshot_preview1` module name:
`sock_open`, `sock_bind`, `sock_listen`, `sock_connect`, `sock_send_to`,
`sock_recv_from`, `sock_getlocaladdr`, `sock_getpeeraddr`,
`sock_getsockopt`, `sock_setsockopt` and `sock_getaddrinfo`. They are not
part of the specification, and WasmEdge may change their data layouts. From
Rust, use them through the `wasmedge_wasi_socket` crate.

The extension's `sock_accept` takes two arguments. Preview 1's takes three.
Both are implemented, so a module built against either one links.

### Poll for readiness

`poll_oneoff` waits for sockets to be readable or writable, and for clocks. A
read subscription reports how many bytes are waiting. It sets
`EVENTRWFLAGS_FD_READWRITE_HANGUP` when the peer has closed the connection.
So your module can tell "nothing yet" from "nothing ever again". Bytes that a
poll finds are kept for the next read. The poll does not consume them.

Set `FDFLAGS_NONBLOCK` through `fd_fdstat_set_flags` to make reads return
`EAGAIN` instead of waiting. It applies to sockets; files ignore it.

For the risks that socket support does not protect you from, see
[security.md](security.md).

## Which syscalls are implemented

45 of them: `args_*`, `environ_*`, `clock_res_get`, `clock_time_get`,
`random_get`, `fd_read`, `fd_write`, `fd_pread`, `fd_pwrite`, `fd_seek`,
`fd_tell`, `fd_close`, `fd_fdstat_get`, `fd_fdstat_set_flags`,
`fd_filestat_get`, `fd_filestat_set_size`, `fd_filestat_set_times`,
`fd_fdstat_set_rights`, `fd_readdir`, `fd_prestat_get`,
`fd_prestat_dir_name`, `fd_sync`,
`fd_datasync`, `fd_advise`, `fd_allocate`, `fd_renumber`, `path_open`,
`path_filestat_get`, `path_filestat_set_times`, `path_create_directory`,
`path_remove_directory`, `path_unlink_file`, `path_rename`, `path_symlink`,
`path_readlink`, `path_link`, `proc_exit`, `sched_yield`, `poll_oneoff`,
`sock_accept`, `sock_recv`, `sock_send`, `sock_shutdown`.

That is enough for Rust's `std::fs`, `std::env`, `thread::sleep` and
buffered I/O. The eleven socket extension calls listed above are also
implemented. They come from WasmEdge, not from the specification.

## The preopen is a directory, not a name

On the **native** backend, the host opens a preopen once, when you grant it.
It resolves every guest path relative to that open directory. If you replace
or rename the host directory later, the instance keeps reading the directory
it was given. This is intended: a capability is a specific directory, not a
name.

Earlier versions used the name. They resolved the root again on every open,
so replacing the directory while an instance ran changed where every path
pointed.

On the **fallback** backend, a preopen is still a name, because that backend
always resolves by name. If anyone other than you can replace the host
directory, build the NIF.

## Symlinks, and which backend you have

The host follows a symlink in the last component only when the caller passes
`LOOKUPFLAGS_SYMLINK_FOLLOW`. Preview 1 says this, and both backends do it.
Without the flag, opening a link gives `ELOOP`. Links in the other components
are always followed, as in any normal path.

On the **native** backend, the host reads a followed link and walks its text
under the same rules as a literal path: one component at a time with
`openat(O_NOFOLLOW)`. It follows at most eight links, so a cycle is an error,
not a hang. A link that leaves the preopen is refused, like a `..` that climbs
above the root: the walk counts the depth and never goes below the root.

On the **fallback** backend, `filelib:safe_relative_path/2` does the same job,
by checking the text and by resolving. It resolves the *parent* of a path and
then acts on the last component by name. So it can name a link without
following it: `readlink`, stat on a link and unlink of a link all work. It
cannot set a link's own timestamps, or a timestamp finer than one second,
because Erlang gives access to neither.

```erlang
wasi_fs:backend().   %% native | fallback
```

Check it if your guests use symlinks. Only the native backend can set a
link's own timestamps, or a timestamp finer than one second.

## WASI 0.2

A component built for `wasm32-wasip2` is answered by a different host,
`wasi_preview2`. Its grants, interfaces and `wasi:http` are in
[WASI 0.2](wasi-0-2.md) and [HTTP](http.md).

## Check it against the official suite

The suites in `test/wasi_*_SUITE.erl` test this project's own reading of
Preview 1. `wasi-testsuite` is written by other people. It is the only test
here that can show a capability follows the specification exactly, and not
only our understanding of it.

```sh
git clone --depth 1 --branch prod/testsuite-base \
    https://github.com/WebAssembly/wasi-testsuite.git
rebar3 ct --suite=test/wasi_conformance_SUITE
```

All 72 cases pass on the native backend, and 68 of 72 on the fallback. The
four failures need things Erlang does not give access to.
`file:write_file_info/3` takes whole seconds, so it cannot set a nanosecond
timestamp. It also follows symlinks, so it cannot set a link's own times. And
`file:make_link/2` calls `link()`, which follows symlinks on darwin. The
conformance suite's baseline lists each one.

Without a checkout the suite skips, so you can keep it in every run.

## What is refused on purpose

- `RIFLAGS_RECV_PEEK` returns `ENOTSUP`. Peeking needs a socket that can put
  data back. Consuming data that the module asked to keep would lose it
  without any error.
- Socket options outside `SOL_SOCKET`, and options the host cannot apply,
  return `ENOPROTOOPT`. Otherwise a module could believe it set a timeout when
  it did not, and find out at the worst moment.

## Get the exit status

`proc_exit` stops the guest with a trap (a guest error returned as a value),
because a trap is the only way to unwind a WebAssembly stack. `wasi:run/2`
turns that trap back into an exit status. If you call `_start` yourself, do
it like this:

```erlang
case wasm:call(Inst, ~"_start", []) of
    {ok, _} -> 0;                              % returned without exiting
    {error, E} ->
        case wasi_preview1:exit_code(E) of
            {ok, Code} -> Code;
            error -> {trapped, E}              % a real trap, not an exit
        end
end.
```

## Change the NIF

If you change `c_src/`, read [The file NIF](contributing/nif.md). It shows how
to run the NIF under a sanitizer, and what each sanitizer can find.

## Read this next

[WASI 0.2](wasi-0-2.md), for components, or [Security](security.md) for what
the sandbox does not cover.
