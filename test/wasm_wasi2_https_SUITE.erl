-module(wasm_wasi2_https_SUITE).
-moduledoc """
HTTPS through the `wasi:http` transports.

`wasi:tls` is not part of WASI 0.2; HTTPS is runtime-side - the guest sets
`scheme = https` and the runtime performs TLS beneath `wasi:http`. This checks the
transport bindings do that: a request with `scheme => <<"https">>` against a TLS echo
server (an ephemeral self-signed cert) connects over TLS and round-trips, with the
client trusting the self-signed server via `{verify, verify_none}`. A request that omits
`verify_none` must fail, proving the default posture verifies the peer.

The grant cases check what a request to a host name reaches: the grant is
checked against the addresses the name resolves to, the transport connects to
the address that passed, and a name with no `resolve` grant reaches nothing.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() -> [h1_https_round_trips, h2_https_round_trips, verification_is_on_by_default,
          a_guest_gets_over_https, a_named_host_is_checked_by_its_address,
          a_named_host_needs_the_resolve_grant,
          a_name_that_resolves_elsewhere_is_refused,
          the_transport_gets_the_checked_address].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

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

%% End to end: a real wasm32-wasip2 guest (`httpsget`) makes an outbound https GET
%% through wasi:http; the runtime performs TLS to the self-signed server and the guest
%% prints the 200 status. Exercises the full host path (scheme threading, 443 default,
%% the tls option) under a guest, not just the transport.
a_guest_gets_over_https(_) ->
    {ok, Server} = wasi_http_server:start(h1, #{tls => true}),
    try
        Addr = wasi_http_server:address(Server),
        {ok, Bin} = file:read_file(fixture_path("httpsget")),
        Grant = #{connect => [{tcp, <<"127.0.0.1">>, {0, 65535}}], resolve => allow},
        {ok, #{exit_code := Code, stdout := Out}} =
            wasi_preview2:run_command(Bin, <<>>,
                #{compile => true, network => Grant,
                  http_tls => [{verify, verify_none}],
                  env => [{<<"HTTPS_SERVER">>, Addr}]}),
        ?assertEqual(0, Code),
        ?assertEqual(<<"status=200\n">>, Out)
    after
        wasi_http_server:stop(Server)
    end.

%% A name is resolved and the connection goes to the address the grant
%% admitted: `localhost' resolves to 127.0.0.1, which the grant names.
a_named_host_is_checked_by_its_address(_) ->
    with_server(fun(Port) ->
        Grant = #{connect => [{tcp, <<"127.0.0.1">>, Port}], resolve => allow},
        {Code, Out} = get(<<"localhost">>, Port, Grant),
        ?assertEqual(0, Code),
        ?assertEqual(<<"status=200\n">>, Out)
    end).

%% Resolving a name is a capability of its own, as `sock_getaddrinfo' is in
%% preview 1: without `resolve', a name reaches nothing.
a_named_host_needs_the_resolve_grant(_) ->
    Grant = #{connect => [{tcp, <<"127.0.0.1">>, 8443}]},
    ?assertEqual(none, fake_get(<<"localhost:8443">>, Grant)).

%% The grant names 127.0.0.1 only, and the authority is a name that does not
%% resolve to it. A name used to be checked as if it were 127.0.0.1 and then
%% connected to as the name, so a loopback grant reached any host on the port.
a_name_that_resolves_elsewhere_is_refused(_) ->
    Grant = #{connect => [{tcp, <<"127.0.0.1">>, 8443}], resolve => allow},
    ?assertEqual(none, fake_get(<<"example.invalid:8443">>, Grant)).

%% What the transport is handed for an admitted name: the address the grant
%% checked, the name for TLS, and the authority as the Host header.
the_transport_gets_the_checked_address(_) ->
    Grant = #{connect => [{tcp, <<"127.0.0.1">>, 8443}], resolve => allow},
    Req = fake_get(<<"localhost:8443">>, Grant),
    ?assertMatch(#{address := {127, 0, 0, 1}, host := <<"localhost">>}, Req),
    ?assertEqual(<<"localhost:8443">>,
                 proplists:get_value(<<"host">>, maps:get(headers, Req))).

%% Run the guest against `fake_http_transport', and answer the request the
%% transport was asked to make, or `none' when the host refused before it.
fake_get(Authority, Grant) ->
    {ok, Bin} = file:read_file(fixture_path("httpsget")),
    _ = wasi_preview2:run_command(Bin, <<>>,
            #{compile => true, network => Grant,
              http_transport => fake_http_transport,
              env => [{<<"HTTPS_SERVER">>, Authority}]}),
    receive {fake_http_request, Req} -> Req
    after 0 -> none
    end.

with_server(Fun) ->
    {ok, Server} = wasi_http_server:start(h1, #{tls => true}),
    try
        {_, Port} = split(wasi_http_server:address(Server)),
        Fun(Port)
    after
        wasi_http_server:stop(Server)
    end.

get(Host, Port, Grant) ->
    {ok, Bin} = file:read_file(fixture_path("httpsget")),
    Authority = <<Host/binary, ":", (integer_to_binary(Port))/binary>>,
    {ok, #{exit_code := Code, stdout := Out}} =
        wasi_preview2:run_command(Bin, <<>>,
            #{compile => true, network => Grant,
              http_tls => [{verify, verify_none}],
              env => [{<<"HTTPS_SERVER">>, Authority}]}),
    {Code, Out}.

fixture_path(Name) ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..", "test",
                   "fixtures", "component", Name ++ ".component.wasm"]).

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
