# HTTP

`wasi:http` is the WASI 0.2 interface that a component uses to send HTTP
requests and to answer them. Read this page in three cases: a component you
run calls `wasi:http/outgoing-handler` to reach a server; a component exports
`wasi:http/incoming-handler` and you want it to serve requests; or you need a
wire protocol that the host does not include. The component only sees
requests and responses. The host chooses the wire protocol (HTTP/1.1 or
HTTP/2), does TLS, and decides which addresses the component may reach. For
running components in general, read [WASI 0.2](wasi-0-2.md) first.

The host side has these modules:

- `wasi_http`: the `wasi:http/types` resources and the outgoing handler.
- `wasi_http_transport`: the behaviour that a *transport* implements. A
  transport is the module that sends a request on the network.
- `wasi_http_h1` and `wasi_http_h2`: the two transports, for HTTP/1.1 and
  HTTP/2.
- `wasi_http_listener`: a server that accepts real connections.

## Let a component make requests

`wasi:http` is always in the import map that `wasi_preview2:command/1`
builds, so a component that imports it links with no options. The host
refuses its requests until you pass a `network` grant that names what it may
reach:

```erlang
{ok, Bin} = file:read_file("client.component.wasm"),
Grant = #{connect => [{tcp, ~"127.0.0.1", 8080}], resolve => allow},
{ok, #{exit_code := Code, stdout := Out}} =
    wasi_preview2:run_command(Bin, <<>>, #{network => Grant}).
```

It is the same grant that `wasi:sockets` uses, described in
[WASI](wasi.md). Before each request, the host splits the *authority* (the
`host:port` part of the URL) into a host and a port. Without a port, it uses
80 for `http` and 443 for `https`. Then it checks them against the `connect`
rules:

- An IP address is checked as it is.
- A host name needs `resolve => allow`. The host resolves the name once and
  checks each address it gets. The request goes to the first address the
  rules allow. The name is still sent as the Host header and as the TLS
  server name.
- If a name resolves to no address, the guest gets `DNS-error`. For any other
  refusal, the guest gets `HTTP-request-denied`.

As for sockets, grants name addresses, never host names. So grant the
addresses that you expect your host names to resolve to.

### What the guest gets back

The host sends the request when the guest first reads the response *future*
(a value that is ready later), after the guest has finished writing the body.
Failures reach the guest as `wasi:http` error codes:

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

The overall deadline is 30 seconds. You cannot change it. The guest can set
`connect-timeout` and `first-byte-timeout` in its `request-options`.
`wasi_http_h1` applies both. `wasi_http_h2` applies neither.
The host stores `between-bytes-timeout` and returns it when read, but does
not apply it.

The host enforces two limits on the request the guest builds. Headers larger
than 64 KiB in total cause a trap, because the WIT type `header-error` has no
case for this error. A body that declares a `content-length` and then writes
more bytes than that fails with `HTTP-request-body-size`.

## Make HTTPS requests

The guest sets the scheme to `HTTPS`, and the host does TLS. By default the host
checks the server's certificate against the system CA store, with the host name
from the authority. Pass `http_tls` to give your own `ssl` client options, for
example to trust a private CA:

```erlang
CaCerts = public_key:cacerts_get(),
#{network => Grant, http_tls => [{cacerts, CaCerts}]}.
```

`wasi_http_h1` merges these options with its defaults, one key at a time. So
the example still verifies the server, and replaces only the list of trusted
CAs.

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

Choose the transport with `http_transport`:

```erlang
#{network => Grant, http_transport => wasi_http_h2}
```

Over `https`, `wasi_http_h2` agrees on HTTP/2 with the server through ALPN.
Over `http`, it uses unencrypted HTTP/2 (h2c). The guest cannot tell which
transport answered.

If you build the import map yourself, `wasi_http:http/1` takes the same three
settings as `grant`, `transport` and `tls`:

```erlang
Http = wasi_http:http(#{grant     => Grant,
                        transport => wasi_http_h2,
                        tls       => []}).
```

## Serve one request

A *reactor* component (one that exports functions and stays ready, see the
[glossary](concepts.md#glossary)) can export `wasi:http/incoming-handler`.
Give it one request with `wasi_preview2:run_serve/3`, and you get back the
response it set:

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

Each call instantiates the component, calls its `handle` function, reads the
response from the *outparam* (the response-outparam resource where the guest
sets its answer), and destroys the instance. The third argument takes the
options of `wasi_preview2:command/1`. Pass `network` so the reactor can send
its own requests, and `compile => true` to use the
[compiled tier](compiled-tier.md).

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

- The listener creates a new instance for each request. So a slow guest, or
  a guest that traps, affects only its own request.
- A trap, a link failure or an error result is answered with a 500 and the
  body `wasi:http reactor error`. The socket is not dropped.
- The request body is read only when `content-length` is set and non-zero,
  and for at most 60 seconds. A chunked request reaches the guest with an
  empty body.
- The response gets a `content-length` unless the guest set one or a
  `transfer-encoding`.
- `address/1` returns `127.0.0.1:Port`. The listener passes no bind address to
  the network library, so with `h1` it listens on every interface. If that is
  a problem, block the port with a firewall or put a proxy in front.

## Write a transport

A transport is a module implementing `wasi_http_transport`: one callback,
`request/2`, which sends one request and waits for the response. This
example logs each request and passes it to the HTTP/1.1 transport:

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

`wasm_wasi2_http_SUITE` calls the `request/2` of each transport directly,
against an echo server. Test your transport the same way before a guest uses
it.

## Read this next

[WASI 0.2](wasi-0-2.md) for the other interfaces and grants, or
[Security](security.md) for what the sandbox does not cover.
