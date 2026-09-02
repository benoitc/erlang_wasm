# WASI

WASI is how you run a program built for `wasm32-wasip1` (Rust, TinyGo, clang
with a WASI sysroot) and give it a filesystem, environment, clocks and sockets
that you choose. Read this when your guest is a real program rather than a bag
of exported functions, and when you need to decide exactly what it may reach.

Here WASI is an Erlang host interface, not an embedded WASI runtime. Every
syscall is an ordinary host function, so you can trace it, replace it, or refuse
it, and every capability decision is made in Erlang.

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

Leave a key out and the module does not have that capability. The syscall
returns `ENOTCAPABLE`, which is deliberately distinct from `EACCES`, so the
module can tell "you were not granted this" from "the operating system refused".

| key | grants | leaving it out means |
| --- | --- | --- |
| `args` | `env::args()` | zero arguments |
| `env` | environment variables | zero variables, **not** the host's |
| `dirs` | preopened directories | **no filesystem at all** |
| `clocks` | `[monotonic]`, `[realtime]`, or both | that clock returns `ENOTCAPABLE` |
| `random` | `strong`, or `{seed, N}` for reproducibility | `random_get` refused |
| `stdout`, `stderr` | a pid, fun, or io device | output discarded |
| `stdin` | a binary or a fun | end of file |
| `net` | sockets, to the addresses named | **no network at all** |

A `stdin` fun may block, and a `stdout` pid or fun receives every write as it
happens, which is all a long-running guest needs to exchange messages with you.
[streams.md](streams.md) has that recipe.

`dirs` is the one that surprises people. No `dirs` does not mean "the working
directory" or "read-only everywhere". It means the module has no filesystem, and
no descriptor to open anything relative to.

`{seed, N}` gives the same stream on every run for a given `N`, and a
*different* stream on each call within a run: the generator is seeded once per
instance and carried, not reseeded per call. It is never the default, because a
module that believes it has entropy and does not is worse off than one that is
told it has none.

## Preopen a directory

```erlang
dirs => [{~"/data",   "/srv/app/data",  read},
         {~"/scratch", "/tmp/app-1234", write}]
```

Each entry maps a guest path to a host path. The module finds them through
`fd_prestat_get` and `fd_prestat_dir_name`, and learns only the guest path; you
never expose the host path behind it.

`read` grants opening, reading, listing and stat. `write` adds creating,
renaming, unlinking and truncating. Requested rights are masked against what the
grant passes down, so a `read` preopen cannot yield a writable descriptor
whatever flags the module passes.

### What the sandbox refuses

Every escape technique below has its own test case. All are refused with
`ENOTCAPABLE` rather than `ENOENT`, so a module cannot use the error code to map
your directory layout:

| the module asks for | it gets |
| --- | --- |
| `note.txt`, `./note.txt` | opened |
| `../secret/key.txt` | refused |
| `/etc/passwd` | refused |
| `escape.txt`, a symlink out of the sandbox | refused |
| `outdir/key.txt`, through a symlinked directory | refused |
| `sub/../../secret/key.txt` | refused |
| `missing.txt` | `ENOENT` |

Verified against Rust's own `std::fs`, not only against hand-written probes.

### Check which backend you have

```erlang
wasi_fs:backend().        %% native | fallback
```

On `native`, the optional NIF built, and path resolution walks each component
with `openat(..., O_NOFOLLOW)`. The kernel resolves each name exactly once and
follows no symlink at any depth, which closes the time-of-check-to-time-of-use
window: swap a component for a symlink between the check and the open and it is
still refused.

On `fallback`, resolution uses `filelib:safe_relative_path/2`, which refuses
every escape above, and re-verifies after opening. The window is narrowed, not
closed, because Erlang exposes neither `openat` nor `O_NOFOLLOW`. Do not point a
preopen at a directory a hostile party can write to concurrently.

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

Notes worth having before you write your first grant:

- No `net` key is no network, and `#{net => #{}}` is the same thing. There is no
  default list, so a grant that names nothing grants nothing.
- `connect` and `listen` are separate and neither implies the other.
- `resolve` turns on `sock_getaddrinfo` and defaults to `deny`.
- A service name is matched against a fixed table (`http`, `https`, `ssh`,
  `domain`, `postgresql` and about twenty more), **not** against your
  `/etc/services`. A numeric port always works, and anything else is `EINVAL`.
  Looking the name up needed `binary_to_atom/2` on a string the guest chose,
  which is a node-wide unreclaimable allocation a guest must never be able to
  make. If you need a name the table does not have, pass the port.
- `max_sockets` caps how many descriptors an instance holds at once, and
  `timeout` bounds one blocking call.
- A malformed rule raises `{bad_net_grant, _}` where you build the import map,
  rather than failing closed later. A sandbox that silently refuses everything
  looks exactly like one that works.

### Listen

Name one address and one port and you have described a socket the host can open,
so it does. The listener arrives as a preopened descriptor after the
directories, and the module accepts on it without ever naming an address:

```erlang
{ok, Inst} = wasm:instantiate(Mod, wasi:imports(
    #{net => #{listen => [{tcp, ~"127.0.0.1", 8080}]}})),
%% fd 3 is listening. sock_accept on it works; nothing else was granted.
```

Name a range or a CIDR and nothing is opened. That is permission for the module
to bind within it itself.

### Connect

```erlang
net => #{connect => [{tcp, ~"93.184.216.0/24", 443}], resolve => allow}
```

The module opens a socket with `sock_open`, then calls `sock_connect` with an
address. That address is checked against your grant and the same address is
handed to the operating system, so nothing in between can change the
destination.

Three behaviours to know:

- **Grants name addresses, never names.** You cannot write a rule that says
  `example.com`. A name would have to be resolved to be checked and resolved
  again to be used, and the two answers can differ. `sock_getaddrinfo` is a
  separate capability and what it returns carries no authority: a module may
  learn an address it cannot reach, and `sock_connect` refuses it then.
- **`::ffff:127.0.0.1` is `127.0.0.1`.** IPv4-mapped addresses are folded before
  the check and the folded form is what gets connected to, so the mapped
  notation cannot walk past an IPv4 rule. The deprecated IPv4-compatible block
  (`::1.2.3.4`) is left alone, because `::0.0.0.1` and `::1` are the same
  address; it needs an IPv6 rule.
- **Binding is checked against `listen`.** Binding claims a local address, and
  that is what `listen` grants, so a client wanting a specific source port needs
  a `listen` rule for it. A loopback grant does not permit binding `0.0.0.0`.

### Which socket calls you get

Preview 1 standardised four: `sock_accept`, `sock_recv`, `sock_send` and
`sock_shutdown`. All four assume the socket already exists, which is why a
listener has to come from the host. Sockets also work through `fd_read`,
`fd_write`, `fd_close` and `fd_fdstat_get`, which is the path Rust's
`TcpStream` takes.

Everything a client needs is an **extension**, defined by WasmEdge and bound
under the same `wasi_snapshot_preview1` module name: `sock_open`, `sock_bind`,
`sock_listen`, `sock_connect`, `sock_send_to`, `sock_recv_from`,
`sock_getlocaladdr`, `sock_getpeeraddr`, `sock_getsockopt`, `sock_setsockopt`
and `sock_getaddrinfo`. It is not part of the specification and its structure
layouts can change upstream. Reach it from Rust with the
`wasmedge_wasi_socket` crate.

The extension's `sock_accept` takes two arguments where Preview 1's takes three.
Both are implemented, so a module compiled against either one links.

### Poll for readiness

`poll_oneoff` handles socket read and write subscriptions, and clocks. A read
subscription reports how many bytes are waiting and sets
`EVENTRWFLAGS_FD_READWRITE_HANGUP` when the peer has closed, so your module can
tell "nothing yet" from "nothing ever again". Bytes found by a poll are kept for
the next read rather than consumed.

Set `FDFLAGS_NONBLOCK` through `fd_fdstat_set_flags` to make reads return
`EAGAIN` instead of waiting. It applies to sockets; files ignore it.

For what socket support does not protect you against, see
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

That is enough for Rust's `std::fs`, `std::env`, `thread::sleep`, and buffered
I/O. Plus the eleven socket extension calls listed above, which are WasmEdge's
rather than the specification's.

## The preopen is a directory, not a name

On the **native** backend a preopen is opened once, when the capability is
granted, and every guest path is resolved relative to that descriptor. Replace
or rename the host directory afterwards and the instance keeps reading the
directory it was given, which is the point: a capability is a thing, not a
name.

It was a name. The root was resolved again on every open, so swapping the
directory underneath a running instance redirected every path it held.

On the **fallback** backend it is still a name, because resolving by name is
what that backend does. If the host directory can be replaced by anyone but
you, that is a reason to want the NIF built.

## Symlinks, and which backend you have

A symlink is followed only when the caller passes
`LOOKUPFLAGS_SYMLINK_FOLLOW`, which is what Preview 1 says and what both
backends now do. Without it, opening a link is `ELOOP`. Components before the
last are followed either way: that is what a path means.

On the **native** backend a followed link is read and its text walked under the
same rules as a literal path, one component at a time with
`openat(O_NOFOLLOW)`, with a budget of eight so a cycle is an error rather than
a hang. A link that leaves the preopen is refused for the same reason a `..`
that climbs past the root is: the walk counts depth and will not go above zero.

On the **fallback** backend `filelib:safe_relative_path/2` does the same job
lexically and by resolution. It resolves a path's *parent* and then acts on the
last component by name, so it can name a link without following it: `readlink`,
stating a link and unlinking one all work. What it cannot do is set a link's own
timestamps, or a timestamp finer than a second, because Erlang exposes neither.

```erlang
wasi_fs:backend().   %% native | fallback
```

Check it if your guests rely on symlinks: the answer decides which twelve
behaviours you have.

## Check it against the official suite

The suites in `test/wasi_*_SUITE.erl` are this project's own reading of Preview
1. `wasi-testsuite` is somebody else's, and it is the only thing here that can
tell you a capability behaves to the letter rather than to our understanding of
it.

```sh
git clone --depth 1 --branch prod/testsuite-base \
    https://github.com/WebAssembly/wasi-testsuite.git
rebar3 ct --suite=test/wasi_conformance_SUITE
```

All 72 cases pass on the native backend, and 68 of 72 on the fallback. The four
are things Erlang does not expose: `file:write_file_info/3` takes whole seconds
so a nanosecond timestamp cannot be set, it follows symlinks so a link's own
times cannot be set, and `file:make_link/2` is `link()`, which follows on
darwin. The conformance suite's baseline names each one.

The suite skips without a checkout, so it costs nothing to leave in a run.

## What is refused on purpose

- `RIFLAGS_RECV_PEEK` returns `ENOTSUP`. Peeking needs a socket that can
  un-read, and consuming what the module asked to leave is silent data loss.
- Socket options outside `SOL_SOCKET`, and those that cannot be honoured, return
  `ENOPROTOOPT`. A module that believes it set a timeout and did not finds out
  at the worst possible moment.

## Get the exit status

`proc_exit` unwinds by trapping, since that is the only way to unwind a
WebAssembly stack. `wasi:run/2` turns that back into a status code. If you call
`_start` yourself, do it like this:

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

## Run the NIF under a sanitizer

The optional file NIF is the only C in the project, and it is where a memory
error would be invisible from Erlang. Use this when you change
`c_src/wasi_file_nif.c`.

```sh
./scripts/sanitize.sh                      # the NIF suite
./scripts/sanitize.sh test/wasi_SUITE      # any suite
```

That builds the NIF with AddressSanitizer inside a Linux container and runs the
suite against it. A sanitizer has to be in the process before anything it
watches, and Linux is where you can arrange that without rebuilding the
emulator: `LD_PRELOAD` survives the exec from `erl` to the emulator there.

To do it by hand, or in an image of your own:

```sh
WASM_NIF_SANITIZE=address rebar3 compile
LD_PRELOAD=$(gcc -print-file-name=libasan.so) \
  ASAN_OPTIONS=detect_leaks=0 rebar3 ct --suite=test/wasi_nif_SUITE
```

## What each sanitizer will and will not find

**AddressSanitizer will not find every defect this NIF can have.** It watches
memory. Closing a descriptor while another thread reads it is not a memory
error: the read succeeds, against whatever file the kernel handed that number
to next. ThreadSanitizer is what sees that one, because the race is on the
descriptor field itself.

**ThreadSanitizer cannot be preloaded.** Unlike AddressSanitizer it needs the
whole program instrumented, and preloading it into a stock emulator segfaults
it outright rather than reporting anything. That means an emulator built with
it:

```sh
git clone --depth 1 https://github.com/erlang/otp && cd otp
export ERL_TOP=$PWD
./otp_build configure CFLAGS="-fsanitize=thread -fPIE" LDFLAGS="-fsanitize=thread"
make
```

Expect noise. ERTS is full of deliberate lock-free code that ThreadSanitizer
reports, so a suppression file comes before the output is worth reading. This
route is described rather than demonstrated: it has not been run here.

**Neither of them replaces the test.** `wasi_nif_SUITE` reproduces the
close-against-read race with no sanitizer at all, by asserting that no read
ever returns a byte belonging to another file. That is the cheaper check, it is
wired into `rebar3 ct`, and it is the one that caught the defect. Sanitizers
are for what a test cannot phrase.

## Short notes

- On macOS none of this works natively. `DYLD_INSERT_LIBRARIES` is stripped
  when the `erl` launcher execs the emulator, so an instrumented library gets
  you `Interceptors are not working`: the runtime arrived through `dlopen`,
  after the fact. Use the container.
- Leak detection is off in the script on purpose. The emulator holds
  allocations for its whole life by design, so it reports pages of them and
  none of them are the NIF.
- `WASM_SANITIZE_IMAGE` picks a different base image if you need a particular
  OTP version.

