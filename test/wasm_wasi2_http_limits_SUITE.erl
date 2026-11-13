-module(wasm_wasi2_http_limits_SUITE).
-moduledoc """
`wasi:http` deadlines and size limits, in both directions.

Outbound, a transport's timeout is the overall deadline for the whole
exchange, a guest's `between-bytes-timeout` bounds each pause in the body, and
a response body over `max_body_bytes` fails with `HTTP-response-body-size`.
Before, every body chunk started the full timeout again and no body was too
large.

Inbound, the listener reads a request body to its end, chunked or not, within
`request_timeout`, answers 408 or 413 without running the guest, answers 504
when the guest overruns, and passes execution limits to the guest. Before, a
chunked body arrived empty, a stalled one reached the guest truncated after a
60 s wait, and `fuel` was ignored.

The listener cases need the wasmtime serve reactors
(`scripts/build-wasmtime-p2.sh`) and are skipped without them.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(GET, <<"GET / HTTP/1.1\r\nhost: x\r\n\r\n">>).

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_group/2, end_per_group/2]).
-export([a_trickling_body_ends_at_the_deadline/1,
         a_guest_body_without_a_length_stops_at_the_ceiling/1,
         a_response_body_over_the_limit_fails/1,
         a_pause_between_bytes_ends_the_response/1,
         a_trickling_body_ends_at_the_deadline_over_h2/1,
         a_response_body_over_the_limit_fails_over_h2/1,
         a_declared_body_over_the_limit_is_413/1,
         a_chunked_body_is_read_and_limited/1,
         a_stalled_body_is_408/1,
         a_guest_past_the_deadline_is_504/1,
         fuel_reaches_the_guest/1]).

all() -> [{group, outbound}, {group, listener}].

groups() ->
    [{outbound, [], [a_trickling_body_ends_at_the_deadline,
                     a_guest_body_without_a_length_stops_at_the_ceiling,
                     a_response_body_over_the_limit_fails,
                     a_pause_between_bytes_ends_the_response,
                     a_trickling_body_ends_at_the_deadline_over_h2,
                     a_response_body_over_the_limit_fails_over_h2]},
     {listener, [], [a_declared_body_over_the_limit_is_413,
                     a_chunked_body_is_read_and_limited,
                     a_stalled_body_is_408,
                     a_guest_past_the_deadline_is_504,
                     fuel_reaches_the_guest]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, _} = application:ensure_all_started(h1),
    {ok, _} = application:ensure_all_started(h2),
    Config.

end_per_suite(_) -> ok.

init_per_group(listener, Config) ->
    case file:read_file(hello()) of
        {ok, Bin} -> [{component, Bin} | Config];
        {error, _} ->
            {skip, "no wasmtime serve fixtures: "
                   "run scripts/build-wasmtime-p2.sh"}
    end;
init_per_group(_, Config) -> Config.

end_per_group(_, _) -> ok.

%%% ------------------------------------------------------------ outbound ---

%% A server that sends a chunk every 30 ms for ever: the overall deadline of
%% 300 ms ends the exchange; it used to restart with every chunk.
%% A guest's outgoing body is host memory until it is sent. With no
%% content-length declared, nothing bounded it: every write was appended to a
%% binary the host held, without a network grant needed to build it. The
%% ceiling that bounds a body the host reads now bounds this one too.
a_guest_body_without_a_length_stops_at_the_ceiling(_) ->
    Res = wasm_resources:new_instance(),
    try
        wasm_resources:with_instance(Res, fun() ->
            B = wasi_http:outgoing_body([], 10),
            ?assertEqual(ok, wasi_http:append_body(B, <<"123456">>)),
            ?assertEqual({error, {http_body_size, 12}},
                         wasi_http:append_body(B, <<"789012">>)),
            %% A declared length under the ceiling still bounds the body.
            D = wasi_http:outgoing_body([{~"content-length", ~"4"}], 10),
            ?assertEqual({error, {http_body_size, 6}},
                         wasi_http:append_body(D, <<"123456">>))
        end)
    after
        wasm_resources:destroy_instance(Res)
    end.

a_trickling_body_ends_at_the_deadline(_) ->
    with_h1(fun trickle_h1/5, fun(Port) ->
        {Took, Got} = timed(fun() ->
                                    wasi_http_h1:request(req(Port, #{}), 300)
                            end),
        ?assertMatch({error, {<<"HTTP-response-timeout">>, none}}, Got),
        ?assert(Took < 2000)
    end).

a_response_body_over_the_limit_fails(_) ->
    with_h1(fun big_h1/5, fun(Port) ->
        ?assertMatch({error, {<<"HTTP-response-body-size">>, {some, 100}}},
                     wasi_http_h1:request(req(Port, #{max_body_bytes => 100}),
                                          5000))
    end).

%% One chunk, then a pause longer than the guest's between-bytes timeout.
a_pause_between_bytes_ends_the_response(_) ->
    with_h1(fun pause_h1/5, fun(Port) ->
        {Took, Got} = timed(fun() ->
                                    wasi_http_h1:request(
                                      req(Port,
                                          #{between_bytes_timeout => 100}),
                                      10000)
                            end),
        ?assertMatch({error, {<<"HTTP-response-timeout">>, none}}, Got),
        ?assert(Took < 2000)
    end).

a_trickling_body_ends_at_the_deadline_over_h2(_) ->
    with_h2(fun trickle_h2/5, fun(Port) ->
        {Took, Got} = timed(fun() ->
                                    wasi_http_h2:request(req(Port, #{}), 300)
                            end),
        ?assertMatch({error, {<<"HTTP-response-timeout">>, none}}, Got),
        ?assert(Took < 2000)
    end).

a_response_body_over_the_limit_fails_over_h2(_) ->
    with_h2(fun big_h2/5, fun(Port) ->
        ?assertMatch({error, {<<"HTTP-response-body-size">>, {some, 100}}},
                     wasi_http_h2:request(req(Port, #{max_body_bytes => 100}),
                                          5000))
    end).

%%% ------------------------------------------------------------ listener ---

a_declared_body_over_the_limit_is_413(Config) ->
    with_listener(Config, #{max_body_bytes => 100}, fun(Port) ->
        ?assertEqual(<<"413">>,
                     status(Port, [<<"POST / HTTP/1.1\r\nhost: x\r\n",
                                     "content-length: 1000\r\n\r\n">>]))
    end).

%% Chunked framing has no Content-Length; the body used to reach the guest
%% empty, so the guest answered 200 whatever its size.
a_chunked_body_is_read_and_limited(Config) ->
    with_listener(Config, #{max_body_bytes => 100}, fun(Port) ->
        Chunk = binary:copy(<<"x">>, 200),
        ?assertEqual(<<"413">>,
                     status(Port, [<<"POST / HTTP/1.1\r\nhost: x\r\n",
                                     "transfer-encoding: chunked\r\n\r\n">>,
                                   integer_to_binary(byte_size(Chunk), 16),
                                   <<"\r\n">>, Chunk, <<"\r\n0\r\n\r\n">>]))
    end).

%% Half the declared body, then silence: answered 408 at the deadline, before
%% the guest runs.
a_stalled_body_is_408(Config) ->
    with_listener(Config, #{request_timeout => 300}, fun(Port) ->
        {Took, St} = timed(fun() ->
                                   status(Port,
                                          [<<"POST / HTTP/1.1\r\nhost: x\r\n",
                                                   "content-length: 10\r\n\r\n",
                                                   "12345">>])
                           end),
        ?assertEqual(<<"408">>, St),
        ?assert(Took < 5000)
    end).

%% wasmtime's `sleep' guest never returns from `handle': answered 504 at the
%% deadline. The body of a GET is complete in the request's own packet, so
%% only the guest is late.
a_guest_past_the_deadline_is_504(_Config) ->
    {ok, Sleep} = file:read_file(serve_fixture("p2_cli_serve_sleep")),
    with_listener([{component, Sleep}], #{request_timeout => 300}, fun(Port) ->
        ?assertEqual(<<"504">>, status(Port, [?GET]))
    end).

%% `fuel' in `serve_opts' reaches the guest, which cannot finish on one unit.
fuel_reaches_the_guest(Config) ->
    with_listener(Config, #{serve_opts => #{fuel => 1}}, fun(Port) ->
        ?assertEqual(<<"500">>, status(Port, [?GET]))
    end),
    with_listener(Config, #{}, fun(Port) ->
        ?assertEqual(<<"200">>, status(Port, [?GET]))
    end).

%%% ------------------------------------------------------------- servers ---

trickle_h1(Conn, Sid, _M, _P, _H) ->
    ok = h1:send_response(Conn, Sid, 200, []),
    trickle(fun(D) -> h1:send_data(Conn, Sid, D, false) end).

big_h1(Conn, Sid, _M, _P, _H) ->
    ok = h1:send_response(Conn, Sid, 200, [{<<"content-length">>, <<"1000">>}]),
    ok = h1:send_data(Conn, Sid, binary:copy(<<"x">>, 1000), true).

pause_h1(Conn, Sid, _M, _P, _H) ->
    ok = h1:send_response(Conn, Sid, 200, []),
    ok = h1:send_data(Conn, Sid, <<"first">>, false),
    timer:sleep(1000),
    ok = h1:send_data(Conn, Sid, <<"late">>, true).

trickle_h2(Conn, Sid, _M, _P, _H) ->
    ok = h2:send_response(Conn, Sid, 200, []),
    trickle(fun(D) -> h2:send_data(Conn, Sid, D, false) end).

big_h2(Conn, Sid, _M, _P, _H) ->
    ok = h2:respond(Conn, Sid, 200, [], binary:copy(<<"x">>, 1000)).

trickle(Send) ->
    case Send(<<"x">>) of
        ok -> timer:sleep(30), trickle(Send);
        _ -> ok
    end.

%%% ------------------------------------------------------------- helpers ---

with_h1(Handler, Fun) ->
    {ok, S} = h1:start_server(0, #{handler => Handler}),
    try Fun(h1:server_port(S)) after h1:stop_server(S) end.

with_h2(Handler, Fun) ->
    {ok, S} = h2:start_server(0, #{handler => Handler, transport => tcp}),
    try Fun(h2:server_port(S)) after h2:stop_server(S) end.

with_listener(Config, Opts, Fun) ->
    {ok, L} = wasi_http_listener:start(
                Opts#{component => ?config(component, Config), port => 0}),
    [_, P] = binary:split(wasi_http_listener:address(L), <<":">>),
    try Fun(binary_to_integer(P)) after wasi_http_listener:stop(L) end.

req(Port, Extra) ->
    Extra#{host => <<"127.0.0.1">>, port => Port, method => <<"GET">>,
           path => <<"/">>, headers => [{<<"host">>, <<"127.0.0.1">>}],
           body => <<>>}.

%% The status line of the answer to raw request bytes.
status(Port, Bytes) ->
    {ok, S} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    try
        ok = gen_tcp:send(S, Bytes),
        {ok, <<"HTTP/1.1 ", St:3/binary, _/binary>>} =
            gen_tcp:recv(S, 0, 10000),
        St
    after
        gen_tcp:close(S)
    end.

timed(F) ->
    T0 = erlang:monotonic_time(millisecond),
    R = F(),
    {erlang:monotonic_time(millisecond) - T0, R}.

hello() -> serve_fixture("p2_cli_serve_hello_world").

serve_fixture(Name) ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..", "test",
                   "fixtures", "wasmtime-p2-serve", Name ++ ".component.wasm"]).
