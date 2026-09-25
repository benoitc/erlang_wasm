-module(wasi_http_transport).
-moduledoc """
The pluggable transport behind `wasi:http`.

`wasi:http` exposes abstract HTTP semantics and leaves the wire protocol to the
host, so the client backend is a behaviour: one module per binding. `wasi_http`
performs a guest's outbound request through the configured transport (default
`wasi_http_h1`, HTTP/1.1), and a different binding (h2, h3) can be swapped in
without the interface changing. The request and response are the abstract form the
`wasi:http/types` resources carry; the binding turns them into wire bytes.
""".

-type request() :: #{host := binary(), port := inet:port_number(),
                     method := binary(), path := binary(),
                     headers := [{binary(), binary()}], body := binary(),
                     connect_timeout => timeout() | undefined}.
-type response() :: {ok, StatusCode :: 0..65535,
                     Headers :: [{binary(), binary()}], Body :: binary()}
                  | {error, ErrorCode :: term()}.

-export_type([request/0, response/0]).

%% Perform one request and return the response (or an http error-code value). The
%% call is synchronous: `wasi_http` runs it when the guest reads the future.
-callback request(request(), timeout()) -> response().
