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

-export([start/0, start/1, start/2, stop/1, address/1]).

-type server() :: {module(), term()}.

-spec start() -> {ok, server()}.
start() ->
    start(h1).

-spec start(module()) -> {ok, server()}.
start(Transport) ->
    start(Transport, #{}).

%% `#{tls => true}` serves over TLS with an ephemeral self-signed cert, for exercising
%% the https client path; the client trusts it with `{verify, verify_none}`.
-spec start(module(), #{tls => boolean()}) -> {ok, server()}.
start(Transport, Opts) ->
    {ok, _} = application:ensure_all_started(Transport),
    Handler = fun(Conn, Id, Method, Path, Headers) ->
                  handle(Transport, Conn, Id, Method, Path, Headers)
              end,
    Extra = transport_opts(Transport, maps:get(tls, Opts, false)),
    {ok, Ref} = Transport:start_server(0, Extra#{handler => Handler}),
    {ok, {Transport, Ref}}.

%% Cleartext by default (h2 serves TLS by default, so force h2c); a TLS server carries
%% a self-signed cert/key generated at startup.
transport_opts(_Transport, true) ->
    {ok, _} = application:ensure_all_started(ssl),
    Data = public_key:pkix_test_data(#{root => [{key, {rsa, 2048, 65537}}],
                                       peer => [{key, {rsa, 2048, 65537}}]}),
    ServerConfig = case Data of
                       #{server_config := SC} -> SC;
                       L when is_list(L)      -> L
                   end,
    CertDER = proplists:get_value(cert, ServerConfig),
    {KeyType, KeyDER} = proplists:get_value(key, ServerConfig),
    %% The h1/h2 server takes cert/key as PEM file paths (certfile/keyfile), so write
    %% the ephemeral self-signed material to temp files.
    CertFile = write_pem([{'Certificate', CertDER, not_encrypted}]),
    KeyFile = write_pem([{KeyType, KeyDER, not_encrypted}]),
    %% Do not ask the client for a certificate (this echo server authenticates no one).
    #{transport => ssl, cert => CertFile, key => KeyFile, verify => verify_none};
transport_opts(h2, false) ->
    #{transport => tcp};
transport_opts(_Transport, false) ->
    #{}.

write_pem(Entries) ->
    Dir = case os:getenv("TMPDIR") of false -> "/tmp"; D -> D end,
    Path = filename:join(Dir, "wasi_https_" ++
               integer_to_list(erlang:unique_integer([positive])) ++ ".pem"),
    ok = file:write_file(Path, public_key:pem_encode(Entries)),
    list_to_binary(Path).

-spec address(server()) -> binary().
address({Transport, Ref}) ->
    iolist_to_binary(["127.0.0.1:", integer_to_binary(Transport:server_port(Ref))]).

-spec stop(server()) -> ok.
stop({Transport, Ref}) ->
    _ = Transport:stop_server(Ref),
    ok.

%% A CONNECT never gets a response: like a real server, it waits for the tunnel
%% data the client is meant to send and answers nothing, so the client's first-byte
%% timeout fires (what p2_http_outbound_request_invalid_version asserts).
handle(_Transport, _Conn, _Id, <<"CONNECT">>, _Path, _Headers) ->
    receive after 10000 -> ok end;
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
