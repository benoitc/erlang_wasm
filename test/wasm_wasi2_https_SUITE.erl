-module(wasm_wasi2_https_SUITE).
-moduledoc """
HTTPS through the `wasi:http` transports.

`wasi:tls` is not part of WASI 0.2; HTTPS is runtime-side - the guest sets
`scheme = https` and the runtime performs TLS beneath `wasi:http`. This checks the
transport bindings do that: a request with `scheme => <<"https">>` against a TLS echo
server (an ephemeral self-signed cert) connects over TLS and round-trips, with the
client trusting the self-signed server via `{verify, verify_none}`. A request that omits
`verify_none` must fail, proving the default posture verifies the peer.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() -> [h1_https_round_trips, h2_https_round_trips, verification_is_on_by_default].

%% The h1 binding connects over TLS and echoes the method/URI/body back.
h1_https_round_trips(_) ->
    round_trip(wasi_http_h1, h1, <<"body">>).

%% The h2 binding does the same over HTTP/2 (ALPN h2) with TLS. Empty body: the echo
%% server reads request bodies only over h1, so an h2 body is not round-tripped here.
h2_https_round_trips(_) ->
    round_trip(wasi_http_h2, h2, <<>>).

%% Without `verify_none` the client verifies the peer (verify_peer + system CAs), so the
%% self-signed test server is rejected - the request fails rather than connecting.
verification_is_on_by_default(_) ->
    {ok, Server} = wasi_http_server:start(h1, #{tls => true}),
    try
        {Host, Port} = split(wasi_http_server:address(Server)),
        Req = #{host => Host, port => Port, scheme => <<"https">>,
                method => <<"GET">>, path => <<"/">>, headers => [], body => <<>>},
        ?assertMatch({error, _}, wasi_http_h1:request(Req, 5000))
    after
        wasi_http_server:stop(Server)
    end.

round_trip(Binding, ServerTransport, ReqBody) ->
    {ok, Server} = wasi_http_server:start(ServerTransport, #{tls => true}),
    try
        {Host, Port} = split(wasi_http_server:address(Server)),
        Req = #{host => Host, port => Port, scheme => <<"https">>,
                tls => [{verify, verify_none}], method => <<"GET">>,
                path => <<"/some/path?q=1">>, headers => [], body => ReqBody},
        {ok, Status, Headers, Body} = Binding:request(Req, 5000),
        ?assertEqual(200, Status),
        ?assertEqual(<<"GET">>, header(<<"x-wasmtime-test-method">>, Headers)),
        ?assertEqual(<<"/some/path?q=1">>, header(<<"x-wasmtime-test-uri">>, Headers)),
        ?assertEqual(ReqBody, Body)
    after
        wasi_http_server:stop(Server)
    end.

split(Addr) ->
    [Host, PortBin] = binary:split(Addr, <<":">>),
    {Host, binary_to_integer(PortBin)}.

header(Name, Headers) ->
    case [V || {N, V} <- Headers, string:lowercase(N) =:= Name] of
        [V | _] -> V;
        []      -> undefined
    end.
