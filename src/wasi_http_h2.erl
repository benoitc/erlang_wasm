-module(wasi_http_h2).
-moduledoc """
The HTTP/2 `wasi_http_transport` binding, over the `h2` client.

Same shape as `wasi_http_h1`: `h2` mirrors `h1`'s client API and event protocol,
so the request and response handling is identical bar the wire version. Selecting
it with `wasi_http:http(#{transport => wasi_http_h2})` makes the host speak HTTP/2
to the peer; the guest cannot tell the difference.
""".

-behaviour(wasi_http_transport).

-export([request/2]).

-spec request(wasi_http_transport:request(), timeout()) ->
          wasi_http_transport:response().
request(#{host := Host, port := Port, method := Method, path := Path,
          headers := Headers, body := Body}, Timeout) ->
    case h2:connect(Host, Port, #{transport => tcp}) of
        {ok, Conn} ->
            Result =
                case h2:request(Conn, Method, Path, Headers, Body) of
                    {ok, Sid}  -> collect(Conn, Sid, Timeout);
                    {error, _} -> {error, {<<"HTTP-protocol-error">>, none}}
                end,
            _ = h2:close(Conn),
            Result;
        {error, _} ->
            {error, {<<"connection-refused">>, none}}
    end.

collect(Conn, Sid, Timeout) ->
    receive
        {h2, Conn, {response, Sid, Status, Headers}} ->
            collect_body(Conn, Sid, Status, Headers, <<>>, Timeout);
        {h2, Conn, {closed, _}} ->
            {error, {<<"HTTP-response-incomplete">>, none}}
    after Timeout ->
        {error, {<<"HTTP-response-timeout">>, none}}
    end.

collect_body(Conn, Sid, Status, Headers, Acc, Timeout) ->
    receive
        {h2, Conn, {data, Sid, Data, false}} ->
            collect_body(Conn, Sid, Status, Headers, <<Acc/binary, Data/binary>>, Timeout);
        {h2, Conn, {data, Sid, Data, true}} ->
            {ok, Status, header_pairs(Headers), <<Acc/binary, Data/binary>>};
        {h2, Conn, {trailers, Sid, _}} ->
            {ok, Status, header_pairs(Headers), Acc}
    after Timeout ->
        {error, {<<"HTTP-response-timeout">>, none}}
    end.

header_pairs(Headers) ->
    [{to_bin(N), to_bin(V)} || {N, V} <- Headers, is_field(N)].

is_field(N) -> binary:first(to_bin(N)) =/= $:.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> list_to_binary(L).
