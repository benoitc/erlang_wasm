-module(wasm_wasi2_http_SUITE).
-moduledoc """
The `wasi:http` transport is pluggable: the same request goes over HTTP/1.1
(`wasi_http_h1`) or HTTP/2 (`wasi_http_h2`), against the matching echo server.

This checks each binding directly, a round-trip through `wasi_http_transport` and
`wasi_http_server`, so a transport works before it is wired under a guest. The
end-to-end guest path over h1 is covered by `wasm_wasi2_p2_SUITE`.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() -> [h1_binding_round_trips, h2_binding_round_trips].

%% The h1 binding echoes the method and URI back through the h1 server.
h1_binding_round_trips(_) ->
    round_trip(wasi_http_h1, h1).

%% The h2 binding does the same over HTTP/2 (cleartext), a different transport
%% behind the same behaviour.
h2_binding_round_trips(_) ->
    round_trip(wasi_http_h2, h2).

round_trip(Binding, ServerTransport) ->
    {ok, Server} = wasi_http_server:start(ServerTransport),
    try
        {Host, Port} = split(wasi_http_server:address(Server)),
        Req = #{host => Host, port => Port, method => <<"GET">>,
                path => <<"/some/path?q=1">>, headers => [], body => <<>>},
        {ok, Status, Headers, Body} = Binding:request(Req, 5000),
        ?assertEqual(200, Status),
        ?assertEqual(<<"GET">>, header(<<"x-wasmtime-test-method">>, Headers)),
        ?assertEqual(<<"/some/path?q=1">>, header(<<"x-wasmtime-test-uri">>, Headers)),
        ?assertEqual(<<>>, Body)
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
