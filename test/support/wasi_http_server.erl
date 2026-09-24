-module(wasi_http_server).
-moduledoc """
The HTTP echo server the wasmtime `p2_http_outbound_*` programs make requests
against (they read its address from the `HTTP_SERVER` environment variable).

It answers every request 200, echoing the request method and URI back in the
`x-wasmtime-test-method` and `x-wasmtime-test-uri` headers and the request body in
the response body, which is what those programs assert.

The transport backend is pluggable: `start/1` takes the module to serve on (`h1`
by default, or `h2`), and the two share a server API (`start_server`,
`send_response`, `send_data`, `server_port`, `stop_server`), so the same echo
handler serves either wire protocol.
""".

-export([start/0, start/1, stop/1, address/1]).

-type server() :: {module(), term()}.

-spec start() -> {ok, server()}.
start() ->
    start(h1).

-spec start(module()) -> {ok, server()}.
start(Transport) ->
    {ok, _} = application:ensure_all_started(Transport),
    Handler = fun(Conn, Id, Method, Path, Headers) ->
                  handle(Transport, Conn, Id, Method, Path, Headers)
              end,
    %% h2 serves over TLS by default; cleartext (h2c) is what the tests use.
    Extra = case Transport of h2 -> #{transport => tcp}; _ -> #{} end,
    {ok, Ref} = Transport:start_server(0, Extra#{handler => Handler}),
    {ok, {Transport, Ref}}.

-spec address(server()) -> binary().
address({Transport, Ref}) ->
    iolist_to_binary(["127.0.0.1:", integer_to_binary(Transport:server_port(Ref))]).

-spec stop(server()) -> ok.
stop({Transport, Ref}) ->
    _ = Transport:stop_server(Ref),
    ok.

%% Echo the method and URI as headers, and the request body as the response body.
%% A request with a body (content-length) is read to completion first.
handle(Transport, Conn, Id, Method, Path, Headers) ->
    Body = case content_length(Headers) of
               0 -> <<>>;
               _ -> collect_body(Id, <<>>)
           end,
    Transport:send_response(Conn, Id, 200,
                            [{<<"x-wasmtime-test-method">>, Method},
                             {<<"x-wasmtime-test-uri">>, Path},
                             {<<"content-length">>, integer_to_binary(byte_size(Body))}]),
    Transport:send_data(Conn, Id, Body, true).

content_length(Headers) ->
    case [V || {N, V} <- Headers, string:lowercase(N) =:= <<"content-length">>] of
        [V | _] -> binary_to_integer(V);
        []      -> 0
    end.

collect_body(Id, Acc) ->
    receive
        {h1_stream, Id, {data, Data, false}} ->
            collect_body(Id, <<Acc/binary, Data/binary>>);
        {h1_stream, Id, {data, Data, true}} ->
            <<Acc/binary, Data/binary>>;
        {h1_stream, Id, {trailers, _}} ->
            Acc
    after 5000 ->
        Acc
    end.
