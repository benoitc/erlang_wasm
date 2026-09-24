-module(wasm_wasi2_serve_SUITE).
-moduledoc """
wasmtime's `p2_cli_serve_*` reactor programs served through
`wasi_preview2:run_serve/3` (the `wasi:http/incoming-handler` path).

Each program exports `wasi:http/incoming-handler`: the host synthesizes an
incoming-request, calls the guest's `handle`, and reads back the response the guest
set on the response-outparam. These are the reactor counterparts of the command
components `wasm_wasi2_p2_SUITE` runs; they assert through the response they build,
so each case here names the response its program is expected to produce.

Skipped without the built fixtures: run `scripts/build-wasmtime-p2.sh`, which puts
the serve reactors in `test/fixtures/wasmtime-p2-serve` (not vendored).
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() -> [hello_world, with_print, authority_and_scheme, live_over_h1].

init_per_suite(Config) ->
    case filelib:is_dir(dir()) of
        false ->
            {skip, "no wasmtime serve fixtures: run scripts/build-wasmtime-p2.sh"};
        true ->
            {ok, _} = application:ensure_all_started(wasm),
            Config
    end.

end_per_suite(_Config) -> ok.

%% The canonical reactor: a 200 with a fixed body.
hello_world(_) ->
    {ok, Status, _Headers, Body} = serve("p2_cli_serve_hello_world", request()),
    ?assertEqual(200, Status),
    ?assertEqual(<<"Hello, WASI!">>, Body).

%% Printing to stdout/stderr during `handle` does not disturb the response.
with_print(_) ->
    {ok, Status, _Headers, Body} = serve("p2_cli_serve_with_print", request()),
    ?assertEqual(200, Status),
    ?assertEqual(<<>>, Body).

%% The program asserts the request authority and scheme the host synthesized, so a
%% 200 back means the incoming-request carried `localhost` over `http`.
authority_and_scheme(_) ->
    {ok, Status, _Headers, _Body} = serve("p2_cli_serve_authority_and_scheme", request()),
    ?assertEqual(200, Status).

%% The reactor served over a live HTTP/1.1 listener: a real client request reaches
%% the guest and its response comes back on the wire.
live_over_h1(_) ->
    {ok, Bin} = file:read_file(filename:join(dir(), "p2_cli_serve_hello_world.component.wasm")),
    {ok, Listener} = wasi_http_listener:start(#{component => Bin, port => 0}),
    try
        {Host, Port} = split(wasi_http_listener:address(Listener)),
        Req = #{host => Host, port => Port, method => <<"GET">>,
                path => <<"/">>, headers => [], body => <<>>},
        {ok, Status, _Headers, Body} = wasi_http_h1:request(Req, 5000),
        ?assertEqual(200, Status),
        ?assertEqual(<<"Hello, WASI!">>, Body)
    after
        wasi_http_listener:stop(Listener)
    end.

split(Addr) ->
    [Host, PortBin] = binary:split(Addr, <<":">>),
    {Host, binary_to_integer(PortBin)}.

%% A GET / over http from localhost, the request every case here serves.
request() ->
    #{method => <<"GET">>, path => <<"/">>, scheme => <<"http">>,
      authority => <<"localhost">>, headers => [], body => <<>>}.

serve(Name, Request) ->
    {ok, Bin} = file:read_file(filename:join(dir(), Name ++ ".component.wasm")),
    wasi_preview2:run_serve(Bin, Request, #{compile => true}).

dir() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "wasmtime-p2-serve"]).
