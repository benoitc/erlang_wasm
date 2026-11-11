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
    %% `Timeout' is the overall deadline, fixed now: every wait below takes
    %% what is left of it, so a body that keeps trickling cannot extend it.
    Deadline = wasi_http_transport:deadline(Timeout),
    ConnectTimeout = maps:get(connect_timeout, Req, undefined),
    Scheme = maps:get(scheme, Req, <<"http">>),
    Tls = maps:get(tls, Req, []),
    Target = maps:get(address, Req, Host),
    %% The ceiling is enforced here, in `collect_body/7', not by h1's
    %% `max_body_size': on a client h1 stops the connection over it, and the
    %% connection is linked to this process, which is the guest's.
    Opts = connect_opts(ConnectTimeout, Scheme,
                        wasi_http_transport:tls_opts(Host, Tls)),
    case h1:connect(Target, Port, Opts) of
        {ok, Conn} ->
            %% The h1 client connects asynchronously; wait for the socket so a
            %% connect timeout surfaces as connection-timeout, distinct from the
            %% response timeout `collect` reports, and from an outright refusal.
            %% Wait for the response line no longer than the first-byte timeout, so
            %% a peer that accepts the connection but never answers (a server stuck
            %% on a CONNECT it will not tunnel) is reported as connection-read-timeout
            %% rather than stalling on the overall deadline.
            Result =
                case h1:wait_connected(
                       Conn, wasi_http_transport:within(
                               wait_timeout(ConnectTimeout), Deadline)) of
                    ok ->
                        send(Conn, Method, Path, Headers, Body, Req, Deadline);
                    {error, Reason} -> {error, connect_error(Reason)}
                end,
            _ = h1:close(Conn),
            Result;
        {error, Reason} ->
            {error, connect_error(Reason)}
    end.

send(Conn, Method, Path, Headers, Body, Req, Deadline) ->
    case h1:request(Conn, Method, Path, Headers, Body) of
        {ok, Sid}  -> collect(Conn, Sid, Req, Deadline);
        {error, _} -> {error, {<<"HTTP-protocol-error">>, none}}
    end.

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
%% between bytes within the between-bytes timeout, and all of it within the
%% overall deadline. No response line in time is connection-read-timeout; any
%% later stall, or the deadline, is HTTP-response-timeout.
collect(Conn, Sid, Req, Deadline) ->
    FirstByte = maps:get(first_byte_timeout, Req, undefined),
    receive
        {h1, Conn, {response, Sid, Status, Headers}} ->
            collect_body(Conn, Sid, Status, Headers, <<>>, Req, Deadline);
        {h1, Conn, {closed, Reason}} ->
            {error, closed_error(Reason, Req)}
    after wasi_http_transport:within(FirstByte, Deadline) ->
        {error, {<<"connection-read-timeout">>, none}}
    end.

collect_body(Conn, Sid, Status, Headers, Acc, Req, Deadline) ->
    Between = maps:get(between_bytes_timeout, Req, undefined),
    receive
        {h1, Conn, {data, Sid, Data, End}} ->
            Body = <<Acc/binary, Data/binary>>,
            case {wasi_http_transport:over_limit(byte_size(Body), Req), End} of
                {true, _} -> {error, body_size_error(Req)};
                {false, true} -> {ok, Status, header_pairs(Headers), Body};
                {false, false} ->
                    collect_body(Conn, Sid, Status, Headers, Body, Req,
                                 Deadline)
            end;
        {h1, Conn, {trailers, Sid, _}} ->
            {ok, Status, header_pairs(Headers), Acc};
        {h1, Conn, {closed, Reason}} ->
            {error, closed_error(Reason, Req)}
    after wasi_http_transport:within(Between, Deadline) ->
        {error, {<<"HTTP-response-timeout">>, none}}
    end.

%% The connection stopped before the response was complete.
closed_error(_Reason, _Req) -> {<<"HTTP-response-incomplete">>, none}.

body_size_error(Req) ->
    {<<"HTTP-response-body-size">>,
     case maps:find(max_body_bytes, Req) of
         {ok, Max} -> {some, Max};
         error -> none
     end}.

%% Real header fields only (drop any HTTP/1.1 pseudo-headers the client surfaces).
header_pairs(Headers) ->
    [{to_bin(N), to_bin(V)} || {N, V} <- Headers, is_field(N)].

is_field(N) -> binary:first(to_bin(N)) =/= $:.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> list_to_binary(L).
