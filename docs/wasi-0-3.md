# WASI 0.3

This page is about running a WASI 0.3 component: one that imports `wasi:cli`,
`wasi:clocks`, `wasi:random`, `wasi:filesystem`, `wasi:sockets` or `wasi:http`
at version `0.3.x`. WASI 0.3 drops `wasi:io`.
Data moves through the Component Model's own streams and futures, and a slow
call is an `async func`. You need this page when a toolchain builds your
program for 0.3, such as Rust's `wasip3` crate or a target that names
`wasi:cli/command@0.3.0`.

## Run a 0.3 command

`wasi_preview3:run_command/3` runs a 0.2 or a 0.3 command, with the same
options and result as `wasi_preview2:run_command/3`:

```erlang
{ok, #{stdout := Out, exit_code := 0}} =
    wasi_preview3:run_command(Bin, <<>>, #{args => [~"prog"]}).
```

A 0.3 program built through the wasip1 adapter imports 0.2 interfaces as well.
`wasi_preview3:command/1` is both hosts in one imports map, and this runner
uses it.

## Serve a 0.3 handler

`wasi_preview3:run_serve/3` serves one request through a 0.2 or a 0.3 handler,
with the same request map and result as `wasi_preview2:run_serve/3`.
`wasi_http_listener` serves through `run_serve/4`, with its imports built once,
so a listener takes either kind:

```erlang
{ok, 200, _Headers, Body} =
    wasi_preview3:run_serve(Bin, #{method => ~"GET", path => ~"/",
                                   scheme => ~"http", authority => ~"localhost",
                                   headers => [], body => <<>>}, #{}).
```

A 0.3 request and response can carry *trailers*: header fields sent after the
body. Give the request's as `trailers`, a list of `{Name, Value}` pairs. A
handler that sets trailers on its response answers a 5-tuple:

```erlang
{ok, 200, _Headers, Body, [{~"fizz", ~"buzz"}]} =
    wasi_preview3:run_serve(Bin, #{method => ~"POST", path => ~"/",
                                   scheme => ~"http", authority => ~"localhost",
                                   headers => [], body => ~"hello",
                                   trailers => [{~"fizz", ~"buzz"}]}, #{}).
```

A response without trailers answers the 4-tuple, as before. The listener
passes the trailers a client sends to the handler, and sends the handler's
back: over HTTP/2 as a last `HEADERS` frame, over HTTP/1.1 after the last
chunk of a chunked body.

## What is there

| package | at 0.3 |
| --- | --- |
| `wasi:cli` | stdin, stdout and stderr through streams, the environment, exit, terminals (none) |
| `wasi:clocks` | the monotonic clock with async `wait-for` and `wait-until`, the system clock, a UTC timezone |
| `wasi:random` | the same functions as 0.2 |
| `wasi:filesystem` | the same mounts as 0.2: reads, writes, appends and directory listings through streams, every other call async |
| `wasi:sockets` | TCP and UDP under the same `network` grant as 0.2: a connection's data through `send` and `receive` streams, `listen` as a stream of accepted sockets, async `connect` and UDP `send` and `receive`, async name lookup |
| `wasi:http` | `fields`, `request`, `request-options` and `response`; `client.send` through the same transport and grant as 0.2; a `wasi:http/handler` export served by `run_serve/3` and the listener. Not yet: middleware (a handler that imports another) |

## Notes

- stdout and stderr take each write as the guest makes it.
- A file takes at most 64 KiB from one write. A larger write is short, and the
  guest writes the rest, as the specification allows.
- `read-via-stream` reads the file from its offset when the guest asks for the
  stream, so a large file is held in memory while the guest reads it.
- Mount files with `preopen`, `writable` and `preopens`, as for 0.2.
- Every HTTP body the host holds is limited by `http_max_body_bytes`, 8 MiB
  by default: a request body the guest sends, and a handler's response body,
  which fails with `HTTP-response-body-size` past it.
- A request body must match its `content-length`: a write that would go past
  it is refused, and one that ends short fails with `HTTP-request-body-size`.
- A handler's response body is read whole before the answer is sent. What
  the guest still does after that gets at most 5 seconds, then the instance
  is destroyed.
- Grant the network with `network`, as for 0.2. Without it, creating a socket
  is refused with `access-denied`.
- A TCP connection stays open while its `send` or `receive` stream is open,
  even after the guest drops the socket.
- Binding, connecting and listening are one call each. `connect` and `listen`
  on a socket that is not bound bind it to any address first, and so does a
  UDP `send` with an address.
- A wait that is already over, such as `wait-until(now)`, completes at once.
- `resource_limit` also bounds the async calls a guest has waiting at once.
  Past it, the call traps with `resource_limit_reached`.
- A 0.3 import is matched to host functions keyed `Interface@0.3`, never to
  the 0.2 ones of the same name. See [Versioned
  imports](wasi-0-2.md#versioned-imports).

## Read this next

[Components](components.md) for async exports and the host's ends of streams,
and [WASI 0.2](wasi-0-2.md) for the options both runners share.
