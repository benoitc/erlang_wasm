-module(wasi_http_transport).
-moduledoc """
The pluggable transport behind `wasi:http`.

`wasi:http` exposes abstract HTTP semantics and leaves the wire protocol to the
host, so the client backend is a behaviour: one module per binding. `wasi_http`
performs a guest's outbound request through the configured transport (default
`wasi_http_h1`, HTTP/1.1), and a different binding (h2, h3) can be swapped in
without the interface changing. The request and response are the abstract form the
`wasi:http/types` resources carry; the binding turns them into wire bytes.

When the request carries an `address`, the binding connects to it and not to
`host`: `wasi_http` resolved the name and checked that address against the
guest's grant, and resolving it again could reach one it did not check. `host`
stays the name, for TLS.
""".

-type request() :: #{host := binary(), port := inet:port_number(),
                     method := binary(), path := binary(),
                     headers := [{binary(), binary()}], body := binary(),
                     address => inet:ip_address(),
                     scheme => binary(),
                     tls => [ssl:tls_client_option()],
                     connect_timeout => timeout() | undefined,
                     first_byte_timeout => timeout() | undefined,
                     between_bytes_timeout => timeout() | undefined,
                     max_body_bytes => pos_integer()}.
-type response() :: {ok, StatusCode :: 0..65535,
                     Headers :: [{binary(), binary()}], Body :: binary()}
                  | {error, ErrorCode :: term()}.

-export_type([request/0, response/0]).
-export([tls_opts/2, deadline/1, within/2, over_limit/2]).

%% Perform one request and return the response (or an http error-code value). The
%% call is synchronous: `wasi_http` runs it when the guest reads the future.
%% The timeout is the overall deadline for the whole exchange, connect to last
%% byte, not a wait that starts again with each message.
-callback request(request(), timeout()) -> response().

-doc "The monotonic millisecond at which `Timeout` from now runs out.".
-spec deadline(timeout()) -> integer() | infinity.
deadline(infinity) -> infinity;
deadline(Timeout) -> erlang:monotonic_time(millisecond) + Timeout.

-doc """
How long one wait may last: `Wait` (a step's own timeout, or `undefined` for
none), never past `Deadline`. Zero once the deadline has passed.
""".
-spec within(timeout() | undefined, integer() | infinity) -> timeout().
within(Wait, infinity) when Wait =:= undefined -> infinity;
within(Wait, infinity) -> Wait;
within(Wait, Deadline) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    case Wait of
        undefined -> Left;
        infinity -> Left;
        _ -> min(Wait, Left)
    end.

-doc "Whether a body of `Size` bytes is over the request's `max_body_bytes`.".
-spec over_limit(non_neg_integer(), request()) -> boolean().
over_limit(Size, Req) ->
    Size > maps:get(max_body_bytes, Req, infinity).

-doc """
The TLS options for a request to `Host`, naming it as the server.

A binding that connects to the request's `address` loses the name the peer's
certificate is checked against, so the name is given to TLS explicitly, unless
the options already carry one or `Host` is itself an address.
""".
-spec tls_opts(binary(), [ssl:tls_client_option()]) ->
          [ssl:tls_client_option()].
tls_opts(Host, Tls) ->
    Named = lists:keymember(server_name_indication, 1, Tls),
    case inet:parse_address(binary_to_list(Host)) of
        {ok, _}    -> Tls;
        {error, _} when Named -> Tls;
        {error, _} -> [{server_name_indication, binary_to_list(Host)} | Tls]
    end.
