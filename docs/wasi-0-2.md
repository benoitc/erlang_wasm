# WASI 0.2

WASI 0.2 (`wasm32-wasip2`) is the version of WASI for the Component Model.
The guest is a *component*: a binary that holds core WebAssembly modules and
describes typed interfaces (see [Components](components.md)). It imports
interfaces such as `wasi:cli`, `wasi:io`, `wasi:filesystem`, `wasi:clocks`,
`wasi:sockets`, `wasi:random` and `wasi:http`. Read this page when your
toolchain targets `wasm32-wasip2` or produces a component. It shows how to run
the component, how to decide what it may reach, and which interfaces the host
provides. For a core module built for `wasm32-wasip1`, read [WASI](wasi.md)
instead.

The host is `wasi_preview2`. It answers every import from Erlang, with the
same code as Preview 1: paths go through `wasi_fs`, address checks through
`wasi_net`, and random bytes come from `crypto:strong_rand_bytes/1`. The
sandbox and grant rules in [WASI](wasi.md) apply here without change.

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
`wasi:cli/run` export and collects stdout and stderr. It always destroys the
instance, also on errors. A component without a `wasi:cli/run` export returns
`{error, no_run_export}`. Pass `compile => true` to load its core modules
through the compiled tier.

The exit code is 0 when `run` returns `ok` and 1 when it returns `err`.
`wasi:cli/exit.exit` works the same way. `exit-with-code` reports the code
it was given. A trap that is not an exit is `{error, Reason}`.

## Grant capabilities

The options are grants, plus two options for outgoing HTTP. If you leave a
grant out, the component does not get that capability.

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

`args` is returned exactly as you pass it. Nothing is added in front.

`run_command/3` supplies stdin from its second argument and collects stdout and
stderr itself. When you build the imports with `command/1` yourself, `stdin` is
a binary, and `stdout` and `stderr` are funs of type `fun((binary()) -> ok)`
that receive the output. By default, output is thrown away.

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

When `preopens` is present, `preopen` and `writable` are ignored. An attempt
to write on a read-only mount fails with the `read-only` error code. The guest
path goes to `wasi_fs:open/3`, the same call Preview 1 uses, so the escapes
listed in [WASI](wasi.md) are refused here too.

### Grant a network

`network` takes the same grant as the Preview 1 `net` key: `connect` and
`listen` rules of `{Proto, Addr, Port}`, `resolve`, `max_sockets` and `timeout`.
Two more keys, `tcp` and `udp`, are booleans. `false` forbids creating any
socket of that kind. Both default to `true`.

```erlang
#{network => #{connect => [{tcp, ~"10.0.0.0/8", {8000, 8099}}],
               listen  => [{tcp, ~"127.0.0.1", 8080}],
               resolve => allow,
               udp     => false}}
```

Without `network`, the component gets no `wasi:sockets` imports. A component
that does not import them still links. `ip-name-lookup` resolves names only
when the grant says `resolve => allow`. Sockets go through `wasi_sock2`, which
uses OTP's `socket` module. So a TCP socket can be bound before it connects or
listens, and can report the port it was given.

## Which interfaces are provided

| interface | built by |
| --- | --- |
| `wasi:random` (`random`, `insecure`, `insecure-seed`) | `random/0` |
| `wasi:clocks` (`monotonic-clock`, `wall-clock`) | `clocks/0` |
| `wasi:cli/environment` | `environment/0`, `environment/3` |
| `wasi:io` streams, `error` and `poll` | `io/0`, `io/1` |
| `wasi:cli` stdio, exit, terminals (no tty) | `command/1` |
| `wasi:filesystem`, read-only or writable per mount | `filesystem/1`, in `wasi_p2_filesystem` |
| `wasi:sockets`: TCP, UDP, name lookup | `sockets/1`, in `wasi_p2_sockets` |
| `wasi:http` types and `outgoing-handler` | `wasi_http:http/1` |
| one `wasi:http/incoming-handler` request | `run_serve/3` |

`command/1` puts all of these in one import map, limited by the grants in its
options. Pass that map to `wasm_component:instantiate/2` when you want to
manage the instance yourself:

```erlang
Imports = wasi_preview2:command(#{args    => [~"app"],
                                  preopen => "/srv/app/data"}),
{ok, Inst} = wasm_component:instantiate(Bin, Imports).
```

`imports/0` is a smaller map with only the interfaces that keep no state
(random, clocks, environment, io). Use it for a component that needs nothing
else.

`wasi:filesystem` and `wasi:http` are always present in `command/1`, so a
component that imports them links with no mount and no network. It then sees
no directories, and its HTTP requests are denied.

## Versioned imports

A component imports names with a version, such as `wasi:io/streams@0.2.0`. The
host uses the name without the version (`wasi:io/streams`) as its key.
`wasm_component` removes the `@version` suffix when it looks up an import. So
one host answers every `0.2.x` component. In your own import map, also write
keys without the version. The lookup uses the name without the version, so a
key with a version never matches.

## Call a typed export

A component that exports functions, not a command, is instantiated and then
called by function name, with the function's type (see
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

The first suite runs unmodified `wasm32-wasip2` Rust programs. When
`wasmtime` is on the path, it also compares their output with wasmtime's
output. The second suite runs the official `wasi-testsuite` cases through the
adapter that turns a preview 1 module into a preview 2 component. It skips if
the checkout, `wasm-tools` or the adapter is missing. Its baseline lists how
many cases are known to fail in each directory. The suite header explains each
one.

## What is not provided

WASI 0.3 is not provided. Its interfaces use `stream` and `future` from the
async Canonical ABI (see the [glossary](concepts.md#glossary)). A 0.2
component never needs them. The async ABI itself is supported; see
[Components](components.md).

## Short notes

- `stdout` and `stderr` never reach the node's own standard output unless you
  pass a sink that writes there.
- The environment is only what you pass. The node's real environment is never
  read.
- `wasi:cli/terminal-*` report no terminal, so a guest writes plain text
  without terminal codes.

## Read this next

[Run a WASI 0.2 component](examples/run-a-wasi-2-component.md), the runnable
version of this page, or [HTTP](http.md) for `wasi:http`.
