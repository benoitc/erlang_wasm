-module(wasi_http_server).
-moduledoc """
The HTTP echo server the wasmtime `p2_http_outbound_*` programs make requests
against (they read its address from the `HTTP_SERVER` environment variable).

It answers every request 200, echoing the request method and URI back in the
`x-wasmtime-test-method` and `x-wasmtime-test-uri` headers and the request body in
the response body, which is what those programs assert. It runs on `h1` (HTTP/1.1),
the same stack `wasi_http` uses for the client side.
""".

-export([start/0, stop/1, address/1]).

-spec start() -> {ok, term()}.
start() ->
    {ok, _} = application:ensure_all_started(h1),
    h1:start_server(0, #{handler => fun handle/5}).

-spec address(term()) -> binary().
address(Server) ->
    iolist_to_binary(["127.0.0.1:", integer_to_binary(h1:server_port(Server))]).

-spec stop(term()) -> ok.
stop(Server) ->
    _ = h1:stop_server(Server),
    ok.

%% Echo the method and URI as headers, and the request body as the response body.
handle(Conn, Id, Method, Path, _Headers) ->
    Body = collect_body(Id, <<>>),
    h1:send_response(Conn, Id, 200,
                     [{<<"x-wasmtime-test-method">>, Method},
                      {<<"x-wasmtime-test-uri">>, Path},
                      {<<"content-length">>, integer_to_binary(byte_size(Body))}]),
    h1:send_data(Conn, Id, Body, true).

collect_body(Id, Acc) ->
    receive
        {h1_stream, Id, {data, Data, false}} ->
            collect_body(Id, <<Acc/binary, Data/binary>>);
        {h1_stream, Id, {data, Data, true}} ->
            <<Acc/binary, Data/binary>>;
        {h1_stream, Id, {trailers, _}} ->
            Acc
    after 0 ->
        Acc
    end.
