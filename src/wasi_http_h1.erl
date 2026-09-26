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
    Scheme = maps:get(scheme, Req, <<"http">>),
    Tls = maps:get(tls, Req, []),
    case h1:connect(Host, Port, connect_opts(ConnectTimeout, Scheme, Tls)) of
        {ok, Conn} ->
            %% The h1 client connects asynchronously; wait for the socket so a
            %% connect timeout surfaces as connection-timeout, distinct from the
            %% response timeout `collect` reports, and from an outright refusal.
            %% Wait for the response line no longer than the first-byte timeout, so
            %% a peer that accepts the connection but never answers (a server stuck
            %% on a CONNECT it will not tunnel) is reported as connection-read-timeout
            %% rather than stalling on the overall deadline.
            FirstByte = first_byte(maps:get(first_byte_timeout, Req, undefined), Timeout),
            Result =
                case h1:wait_connected(Conn, wait_timeout(ConnectTimeout)) of
                    ok             -> send(Conn, Method, Path, Headers, Body, FirstByte, Timeout);
                    {error, Reason} -> {error, connect_error(Reason)}
                end,
            _ = h1:close(Conn),
            Result;
        {error, Reason} ->
            {error, connect_error(Reason)}
    end.

send(Conn, Method, Path, Headers, Body, FirstByte, Timeout) ->
    case h1:request(Conn, Method, Path, Headers, Body) of
        {ok, Sid}  -> collect(Conn, Sid, FirstByte, Timeout);
        {error, _} -> {error, {<<"HTTP-protocol-error">>, none}}
    end.

first_byte(undefined, Default) -> Default;
first_byte(Timeout, _Default)  -> Timeout.

%% Connection options for the h1 client. An `https` scheme selects the TLS transport;
%% with no caller-supplied `tls` options the client uses its secure defaults (verify the
%% peer against the system CA store, with hostname/SNI from the authority). Supplied
%% `tls` options (e.g. `{verify, verify_none}` for a self-signed test server) are passed
%% through as `ssl_opts`. An `http` scheme stays cleartext.
connect_opts(Timeout, Scheme, Tls) ->
    Base = case Timeout of undefined -> #{}; _ -> #{connect_timeout => Timeout} end,
    case Scheme of
        <<"https">> when Tls =:= [] -> Base#{transport => ssl};
        <<"https">>                 -> Base#{transport => ssl, ssl_opts => Tls};
        _                           -> Base
    end.

wait_timeout(undefined) -> 30000;
wait_timeout(Timeout)   -> Timeout.

%% Map a connect failure to its wasi:http error-code: a timed-out connect is
%% connection-timeout, everything else (refused, unreachable, closed) is reported
%% as connection-refused.
connect_error(timeout) -> {<<"connection-timeout">>, none};
connect_error(etimedout) -> {<<"connection-timeout">>, none};
connect_error(_Other)  -> {<<"connection-refused">>, none}.

%% Wait for the response line within the first-byte timeout, then read the body
%% within the overall deadline. A first-byte timeout is connection-read-timeout;
%% a stall mid-body stays HTTP-response-timeout.
collect(Conn, Sid, FirstByte, Timeout) ->
    receive
        {h1, Conn, {response, Sid, Status, Headers}} ->
            collect_body(Conn, Sid, Status, Headers, <<>>, Timeout);
        {h1, Conn, {closed, _}} ->
            {error, {<<"HTTP-response-incomplete">>, none}}
    after FirstByte ->
        {error, {<<"connection-read-timeout">>, none}}
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
