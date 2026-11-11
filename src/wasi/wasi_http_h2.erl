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
          headers := Headers, body := Body} = Req, Timeout) ->
    %% The overall deadline, fixed now, as in `wasi_http_h1'.
    Deadline = wasi_http_transport:deadline(Timeout),
    case h2:connect(maps:get(address, Req, Host), Port,
                    h2_connect_opts(Req, Deadline)) of
        {ok, Conn} ->
            Result =
                case h2:request(Conn, Method, Path, Headers, Body) of
                    {ok, Sid}  -> collect(Conn, Sid, Req, Deadline);
                    {error, _} -> {error, {<<"HTTP-protocol-error">>, none}}
                end,
            _ = h2:close(Conn),
            Result;
        {error, Reason} ->
            {error, connect_error(Reason)}
    end.

connect_error(timeout) -> {<<"connection-timeout">>, none};
connect_error(etimedout) -> {<<"connection-timeout">>, none};
connect_error({_, timeout}) -> {<<"connection-timeout">>, none};
connect_error(_) -> {<<"connection-refused">>, none}.

%% `https` negotiates TLS with ALPN `h2` (the h2 client handles ALPN); `http` is h2c
%% (cleartext). Supplied `tls` options pass through as `ssl_opts` (e.g. verify_none for
%% a self-signed test server); none means the client's secure defaults.
%% The connect timeout is the guest's, within the deadline, and the body
%% ceiling is the library's own `max_body_size', which cancels a response over
%% it as it arrives.
h2_connect_opts(Req, Deadline) ->
    Base0 = #{connect_timeout =>
                  wasi_http_transport:within(
                    maps:get(connect_timeout, Req, undefined), Deadline)},
    Base = case maps:find(max_body_bytes, Req) of
               {ok, Max} -> Base0#{max_body_size => Max};
               error -> Base0
           end,
    case maps:get(scheme, Req, <<"http">>) of
        <<"https">> ->
            case wasi_http_transport:tls_opts(maps:get(host, Req),
                                              maps:get(tls, Req, [])) of
                []  -> Base#{transport => ssl};
                Tls -> Base#{transport => ssl, ssl_opts => Tls}
            end;
        _ ->
            Base#{transport => tcp}
    end.

%% The waits are `wasi_http_h1''s: the first byte, then between bytes, all
%% within the overall deadline.
collect(Conn, Sid, Req, Deadline) ->
    FirstByte = maps:get(first_byte_timeout, Req, undefined),
    receive
        {h2, Conn, {response, Sid, Status, Headers}} ->
            collect_body(Conn, Sid, Status, Headers, <<>>, Req, Deadline);
        {h2, Conn, {stream_reset, Sid, Why}} ->
            {error, reset_error(Why, Req)};
        {h2, Conn, {closed, _}} ->
            {error, {<<"HTTP-response-incomplete">>, none}}
    after wasi_http_transport:within(FirstByte, Deadline) ->
        {error, {<<"connection-read-timeout">>, none}}
    end.

collect_body(Conn, Sid, Status, Headers, Acc, Req, Deadline) ->
    Between = maps:get(between_bytes_timeout, Req, undefined),
    receive
        {h2, Conn, {data, Sid, Data, End}} ->
            Body = <<Acc/binary, Data/binary>>,
            case {wasi_http_transport:over_limit(byte_size(Body), Req), End} of
                {true, _} -> {error, body_size_error(Req)};
                {false, true} -> {ok, Status, header_pairs(Headers), Body};
                {false, false} ->
                    collect_body(Conn, Sid, Status, Headers, Body, Req,
                                 Deadline)
            end;
        {h2, Conn, {trailers, Sid, _}} ->
            {ok, Status, header_pairs(Headers), Acc};
        {h2, Conn, {stream_reset, Sid, Why}} ->
            {error, reset_error(Why, Req)};
        {h2, Conn, {closed, _}} ->
            {error, {<<"HTTP-response-incomplete">>, none}}
    after wasi_http_transport:within(Between, Deadline) ->
        {error, {<<"HTTP-response-timeout">>, none}}
    end.

%% `body_too_large' is h2's own `max_body_size' cancelling the response.
reset_error(body_too_large, Req) -> body_size_error(Req);
reset_error(_, _Req) -> {<<"HTTP-response-incomplete">>, none}.

body_size_error(Req) ->
    {<<"HTTP-response-body-size">>,
     case maps:find(max_body_bytes, Req) of
         {ok, Max} -> {some, Max};
         error -> none
     end}.

header_pairs(Headers) ->
    [{to_bin(N), to_bin(V)} || {N, V} <- Headers, is_field(N)].

is_field(N) -> binary:first(to_bin(N)) =/= $:.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> list_to_binary(L).
