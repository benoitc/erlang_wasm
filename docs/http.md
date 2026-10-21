# HTTP

`wasi:http` is the WASI 0.2 interface a component uses to make HTTP requests
and to answer them. Read this when a component you run calls
`wasi:http/outgoing-handler` to reach a server, when it exports
`wasi:http/incoming-handler` and you want to serve requests with it, or when
you need a wire protocol the host does not ship. The component sees abstract
HTTP; the host picks the wire protocol, performs TLS, and decides which
addresses are reachable. For running components in general, read
[WASI 0.2](wasi-0-2.md) first.

The host side is `wasi_http` (the `wasi:http/types` resources and the
outgoing handler), `wasi_http_transport` (the behaviour a wire binding
implements), `wasi_http_h1` and `wasi_http_h2` (the two bindings), and
`wasi_http_listener` (a live server).

## Let a component make requests

`wasi:http` is always in the import map `wasi_preview2:command/1` builds, so a
component that imports it links with no options. Its requests are refused
until you pass a `network` grant naming what it may reach:

```erlang
{ok, Bin} = file:read_file("client.component.wasm"),
Grant = #{connect => [{tcp, ~"127.0.0.1", 8080}], resolve => allow},
{ok, #{exit_code := Code, stdout := Out}} =
    wasi_preview2:run_command(Bin, <<>>, #{network => Grant}).
```

The grant is the one `wasi:sockets` uses, described in
[WASI](wasi.md). Before each request the host splits the authority into a host
and a port (80 for `http`, 443 for `https` when the port is omitted) and
checks it against the `connect` rules:

- A literal address is checked as itself.
- A name needs `resolve => allow`. The host resolves it once and checks each
  address it resolves to; the request goes to the first one the rules admit,
  and the name is still sent as the Host header and the TLS server name.
- A name that resolves to nothing is `DNS-error`. Anything else refused comes
  back to the guest as `HTTP-request-denied`.

Grants name addresses, never host names, as they do for sockets, so grant the
addresses the names you expect resolve to.

### What the guest gets back

The request is performed when the guest first reads the response future, after
it has finished writing the body. Failures arrive as `wasi:http` error codes:

| the host sees | the guest gets |
| --- | --- |
| no path, or an empty or malformed authority | `HTTP-request-URI-invalid` |
| a scheme other than `http` or `https` | `HTTP-protocol-error` |
| the grant refuses the address | `HTTP-request-denied` |
| the connect times out (`wasi_http_h1`) | `connection-timeout` |
| any other connect failure | `connection-refused` |
| no response line within the first-byte timeout | `connection-read-timeout` |
| the body stalls past the overall deadline | `HTTP-response-timeout` |
| the server closes before responding | `HTTP-response-incomplete` |

The overall deadline is 30 seconds and is not an option. The guest can set
`connect-timeout` and `first-byte-timeout` on its `request-options`;
`wasi_http_h1` applies both, and `wasi_http_h2` applies neither.
`between-bytes-timeout` is stored and read back but not applied.

Two limits are enforced on what the guest builds. A header section larger
than 64 KiB traps, because the WIT `header-error` has no case for it. A body
that declares `content-length` and writes more than that fails with
`HTTP-request-body-size`.

## Make HTTPS requests

The guest sets the scheme to `HTTPS`; the host performs TLS. By default the
peer is verified against the system CA store, with the host name from the
authority. Pass `http_tls` to give your own `ssl` client options, for example
to trust a private CA:

```erlang
CaCerts = public_key:cacerts_get(),
#{network => Grant, http_tls => [{cacerts, CaCerts}]}.
```

`wasi_http_h1` merges these over its defaults key by key, so the example keeps
peer verification and replaces only the trust store.

Against a test server with a self-signed certificate, this is what
`wasm_wasi2_https_SUITE` passes:

```erlang
wasi_preview2:run_command(Bin, <<>>,
                          #{network  => Grant,
                            http_tls => [{verify, verify_none}],
                            env      => [{~"HTTPS_SERVER", Addr}]}).
```

Without `http_tls` a self-signed server is refused.

## Speak HTTP/2

Pick the binding with `http_transport`:

```erlang
#{network => Grant, http_transport => wasi_http_h2}
```

`wasi_http_h2` negotiates HTTP/2 with ALPN over `https`, and speaks cleartext
HTTP/2 (h2c) over `http`. The guest cannot tell which binding answered.

If you build the import map yourself, `wasi_http:http/1` takes the same three
settings as `grant`, `transport` and `tls`:

```erlang
Http = wasi_http:http(#{grant     => Grant,
                        transport => wasi_http_h2,
                        tls       => []}).
```

## Serve one request

A reactor component exports `wasi:http/incoming-handler`. Hand it one request
with `wasi_preview2:run_serve/3` and get back the response it set:

```erlang
{ok, Bin} = file:read_file("hello.component.wasm"),
Request = #{method    => ~"GET",
            path      => ~"/",
            scheme    => ~"http",
            authority => ~"localhost",
            headers   => [],
            body      => <<>>},
{ok, Status, Headers, Body} = wasi_preview2:run_serve(Bin, Request, #{}).
```

Each call instantiates the component, calls its `handle`, reads the response
off the outparam, and destroys the instance. The third argument takes the
`wasi_preview2:command/1` options: pass `network` so the reactor can make its
own outbound requests, and `compile => true` to use the compiled tier.

The other results:

| result | means |
| --- | --- |
| `{error, no_incoming_handler}` | no `wasi:http/incoming-handler` export |
| `{error, no_response}` | `handle` returned without setting the outparam |
| `{error, Code}` | the guest set an error code on the outparam |

## Run a live server

`wasi_http_listener` accepts connections and serves each request through
`run_serve/3`:

```erlang
{ok, L} = wasi_http_listener:start(#{component => Bin, port => 8080}),
Addr = wasi_http_listener:address(L),
ok = wasi_http_listener:stop(L).
```

| option | meaning | default |
| --- | --- | --- |
| `component` | the reactor's bytes | required |
| `port` | the port to listen on; `0` picks one | `0` |
| `transport` | `h1`, or `h2` for cleartext HTTP/2 | `h1` |
| `scheme` | the scheme the guest is told | `~"http"` |
| `serve_opts` | the options passed to `run_serve/3` | `#{}` |

Notes on how it behaves:

- The component is instantiated per request, so a slow or trapping guest
  affects only its own request.
- A trap, a link failure or an error result is answered with a 500 and the
  body `wasi:http reactor error`. The socket is not dropped.
- The request body is read only when `content-length` is set and non-zero,
  and for at most 60 seconds. A chunked request reaches the guest with an
  empty body.
- The response gets a `content-length` unless the guest set one or a
  `transfer-encoding`.
- `address/1` returns `127.0.0.1:Port`. The listener passes no bind address to
  the wire library, so with `h1` it listens on every interface. Firewall the
  port, or put a proxy in front, if that matters.

## Write a transport

A transport is a module implementing `wasi_http_transport`: one callback,
`request/2`, which performs one request synchronously. This one logs each
request and hands it to the HTTP/1.1 binding:

<!-- check: modules my_http_transport -->
```erlang
-module(my_http_transport).
-behaviour(wasi_http_transport).
-export([request/2]).

request(#{host := Host, port := Port, method := Method,
          path := Path} = Req, Timeout) ->
    logger:info("wasi:http ~s ~s:~p~s", [Method, Host, Port, Path]),
    wasi_http_h1:request(Req, Timeout).
```

The request map carries `host`, `port`, `method`, `path`, `headers` and
`body`, plus `scheme`, `tls`, `connect_timeout` and `first_byte_timeout`
(milliseconds, or `undefined` when the guest set none). `Timeout` is the
overall deadline. Return `{ok, Status, Headers, Body}` with binary header
pairs, or `{error, {ErrorCodeName, Payload}}` naming a `wasi:http` error code,
such as `{error, {~"connection-refused", none}}`. Then select it:

```erlang
#{network => Grant, http_transport => my_http_transport}
```

`wasm_wasi2_http_SUITE` calls each binding's `request/2` directly against an
echo server, which is how to test yours before a guest uses it.

## Read this next

[WASI 0.2](wasi-0-2.md) for the other interfaces and grants, or
[Security](security.md) for what the sandbox does not cover.
