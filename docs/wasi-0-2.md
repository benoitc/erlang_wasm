# WASI 0.2

WASI 0.2 (`wasm32-wasip2`) is the Component Model form of WASI: the guest
ships as a *component* and imports typed interfaces such as `wasi:cli`,
`wasi:io`, `wasi:filesystem`, `wasi:clocks`, `wasi:sockets`, `wasi:random` and
`wasi:http`. Read this when your toolchain targets `wasm32-wasip2` or emits a
component and you need to run it, decide what it may reach, and know which
interfaces the host answers. For a core module built for `wasm32-wasip1`, read
[WASI](wasi.md) instead.

The host is `wasi_preview2`. It answers every import from Erlang, over the same
internals as Preview 1: paths go through `wasi_fs`, address decisions through
`wasi_net`, randomness through `crypto:strong_rand_bytes/1`. The sandbox and
grant rules in [WASI](wasi.md) hold unchanged.

## Run a command component

Pass the component bytes, the bytes to feed its stdin, and an options map. You
get back the exit code and everything it wrote:

```erlang
{ok, Bin} = file:read_file("app.component.wasm"),
{ok, #{exit_code := Code, stdout := Out, stderr := Err}} =
    wasi_preview2:run_command(Bin, <<"input bytes">>,
                              #{args     => [~"app", ~"--flag"],
                                env      => [{~"MODE", ~"prod"}],
                                preopen  => "/srv/app/data",
                                writable => false}).
```

`run_command/3` instantiates the component with `command/1`, calls its
`wasi:cli/run` export, collects stdout and stderr, and destroys the instance on
every path. A component without a `wasi:cli/run` export returns
`{error, no_run_export}`. Pass `compile => true` to load its core modules
through the compiled tier.

The exit code is 0 when `run` returns `ok` and 1 when it returns `err`.
`wasi:cli/exit.exit` maps the same way; `exit-with-code` reports the code it
was given. A trap that is not an exit is `{error, Reason}`.

## Grant capabilities

The options are grants, plus two that configure outbound HTTP. Leave a grant
out and the component does not have that capability.

| key | grants | left out |
| --- | --- | --- |
| `args` | the command line, `argv[0]` included | zero arguments |
| `env` | variables, as `{Name, Value}` binaries | none, never the node's |
| `initial_cwd` | the `initial-cwd` answer | `none` |
| `preopen` | one host directory, at guest `/` | **no filesystem** |
| `writable` | `true` makes `preopen` writable | read-only |
| `preopens` | mounts, as `{Name, HostDir, Writable}` | `preopen`, if any |
| `network` | `wasi:sockets` and outbound `wasi:http` | no network |
| `http_transport` | the module that performs outbound HTTP | `wasi_http_h1` |
| `http_tls` | `ssl` client options for `https` | verify against system CAs |

`args` is returned verbatim: nothing is prepended.

`run_command/3` supplies stdin from its second argument and collects stdout and
stderr itself. When you build the imports with `command/1` directly, `stdin` is
a binary, and `stdout` and `stderr` are `fun((binary()) -> ok)` sinks; both
default to discarding.

### Mount directories

One directory at the root:

```erlang
#{preopen => "/srv/app/data", writable => true}
```

Several, each with its own writability:

```erlang
#{preopens => [{~"/data", "/srv/app/data", false},
               {~"/scratch", "/tmp/app-1234", true}]}
```

When `preopens` is present, `preopen` and `writable` are ignored. A write
intent on a read-only mount is refused with the `read-only` error code. The
guest path goes to `wasi_fs:open/3`, the call Preview 1 makes, so the escapes
listed in [WASI](wasi.md) are refused here too.

### Grant a network

`network` takes the same grant as the Preview 1 `net` key: `connect` and
`listen` rules of `{Proto, Addr, Port}`, `resolve`, `max_sockets` and
`timeout`. Two more keys, `tcp` and `udp`, are booleans that permit creating
that transport at all; both default to `true`.

```erlang
#{network => #{connect => [{tcp, ~"10.0.0.0/8", {8000, 8099}}],
               listen  => [{tcp, ~"127.0.0.1", 8080}],
               resolve => allow,
               udp     => false}}
```

Without `network` the component gets no `wasi:sockets` imports, so a component
that imports none still links. `ip-name-lookup` resolves only when the grant
says `resolve => allow`. Sockets go through `wasi_sock2`, over OTP's `socket`
module, so a TCP socket can be bound before it connects or listens and can
report the port it was given.

## Which interfaces are provided

| interface | built by |
| --- | --- |
| `wasi:random` (`random`, `insecure`, `insecure-seed`) | `random/0` |
| `wasi:clocks` (`monotonic-clock`, `wall-clock`) | `clocks/0` |
| `wasi:cli/environment` | `environment/0`, `environment/3` |
| `wasi:io` streams, `error` and `poll` | `io/0`, `io/1` |
| `wasi:cli` stdio, exit, terminals (no tty) | `command/1` |
| `wasi:filesystem`, read-only or writable per mount | `filesystem/1` |
| `wasi:sockets`: TCP, UDP, name lookup | `sockets/1` |
| `wasi:http` types and `outgoing-handler` | `wasi_http:http/1` |
| one `wasi:http/incoming-handler` request | `run_serve/3` |

`command/1` merges all of these under the grants in its options. Hand that map
to `wasm_component:instantiate/2` when you want the instance yourself:

```erlang
Imports = wasi_preview2:command(#{args    => [~"app"],
                                  preopen => "/srv/app/data"}),
{ok, Inst} = wasm_component:instantiate(Bin, Imports).
```

`imports/0` is the smaller map of the stateless interfaces (random, clocks,
environment, io), for a component that needs nothing else.

`wasi:filesystem` and `wasi:http` are always present in `command/1`, so a
component that imports them links with no mount and no network. It then sees
no directories, and its HTTP requests are denied.

## Versioned imports

A component imports versioned ids such as `wasi:io/streams@0.2.0`. The host is
keyed by the bare id (`wasi:io/streams`), and `wasm_component` strips the
`@version` suffix when it resolves an import. One host answers every `0.2.x`
component. Write a key in your own import map without the version too: the
lookup uses the stripped id, so a versioned key never matches.

## Call a typed export

A component that exports functions rather than a command is instantiated and
called by name, with its signature (see
[Pass data in and out](passing-data.md)):

```erlang
{ok, Inst} = wasm_component:instantiate(Bin),
{ok, Result} = wasm_component:call(Inst, ~"run",
                                   {[{list, u8}], {list, u8}}, [~"hi"]),
ok = wasm_component:destroy(Inst).
```

## Check it against the conformance suites

```sh
rebar3 ct --suite=test/wasm_wasi2_conformance_SUITE
rebar3 ct --suite=test/wasm_wasi2_testsuite_SUITE
```

The first runs unmodified `wasm32-wasip2` Rust programs and, when `wasmtime` is
on the path, compares their output with it. The second runs the official
`wasi-testsuite` cases through the preview 1 to preview 2 adapter, and skips
without a checkout, `wasm-tools` or the adapter. Its baseline is a
known-failing count per directory, and the suite header says why each is
there.

## What is not provided

WASI 0.3, the interfaces built on the async Canonical ABI's `stream` and
`future`. A 0.2 component never needs them. The async ABI itself is supported;
see [Components](components.md).

## Short notes

- `stdout` and `stderr` never reach the node's own standard output unless you
  pass a sink that writes there.
- The environment is only what you pass. The node's real environment is never
  read.
- `wasi:cli/terminal-*` report no terminal, so a guest writes plainly.

## Read this next

[Run a WASI 0.2 component](examples/run-a-wasi-2-component.md), the runnable
version of this page, or [HTTP](http.md) for `wasi:http`.
