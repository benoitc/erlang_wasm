-module(wasi_http_h1).
-moduledoc """
The HTTP/1.1 `wasi_http_transport` binding, over the `h1` client.

It opens a connection to the request's authority, sends the method, path, headers
and body, and collects the response into the abstract form `wasi_http` lifts back
to the guest. This is the default `wasi:http` transport; an h2 or h3 binding
implements the same behaviour.
""".

-behaviour(wasi_http_transport).

-export([request/2]).

-spec request(wasi_http_transport:request(), timeout()) ->
          wasi_http_transport:response().
request(#{host := Host, port := Port, method := Method, path := Path,
          headers := Headers, body := Body} = Req, Timeout) ->
    ConnectTimeout = maps:get(connect_timeout, Req, undefined),
    case h1:connect(Host, Port, connect_opts(ConnectTimeout)) of
        {ok, Conn} ->
            %% The h1 client connects asynchronously; wait for the socket so a
            %% connect timeout surfaces as connection-timeout, distinct from the
            %% response timeout `collect` reports, and from an outright refusal.
            Result =
                case h1:wait_connected(Conn, wait_timeout(ConnectTimeout)) of
                    ok             -> send(Conn, Method, Path, Headers, Body, Timeout);
                    {error, Reason} -> {error, connect_error(Reason)}
                end,
            _ = h1:close(Conn),
            Result;
        {error, Reason} ->
            {error, connect_error(Reason)}
    end.

send(Conn, Method, Path, Headers, Body, Timeout) ->
    case h1:request(Conn, Method, Path, Headers, Body) of
        {ok, Sid}  -> collect(Conn, Sid, Timeout);
        {error, _} -> {error, {<<"HTTP-protocol-error">>, none}}
    end.

connect_opts(undefined) -> #{};
connect_opts(Timeout)   -> #{connect_timeout => Timeout}.

wait_timeout(undefined) -> 30000;
wait_timeout(Timeout)   -> Timeout.

%% Map a connect failure to its wasi:http error-code: a timed-out connect is
%% connection-timeout, everything else (refused, unreachable, closed) is reported
%% as connection-refused.
connect_error(timeout) -> {<<"connection-timeout">>, none};
connect_error(etimedout) -> {<<"connection-timeout">>, none};
connect_error(_Other)  -> {<<"connection-refused">>, none}.

collect(Conn, Sid, Timeout) ->
    receive
        {h1, Conn, {response, Sid, Status, Headers}} ->
            collect_body(Conn, Sid, Status, Headers, <<>>, Timeout);
        {h1, Conn, {closed, _}} ->
            {error, {<<"HTTP-response-incomplete">>, none}}
    after Timeout ->
        {error, {<<"HTTP-response-timeout">>, none}}
    end.

collect_body(Conn, Sid, Status, Headers, Acc, Timeout) ->
    receive
        {h1, Conn, {data, Sid, Data, false}} ->
            collect_body(Conn, Sid, Status, Headers, <<Acc/binary, Data/binary>>, Timeout);
        {h1, Conn, {data, Sid, Data, true}} ->
            {ok, Status, header_pairs(Headers), <<Acc/binary, Data/binary>>};
        {h1, Conn, {trailers, Sid, _}} ->
            {ok, Status, header_pairs(Headers), Acc}
    after Timeout ->
        {error, {<<"HTTP-response-timeout">>, none}}
    end.

%% Real header fields only (drop any HTTP/1.1 pseudo-headers the client surfaces).
header_pairs(Headers) ->
    [{to_bin(N), to_bin(V)} || {N, V} <- Headers, is_field(N)].

is_field(N) -> binary:first(to_bin(N)) =/= $:.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> list_to_binary(L).
