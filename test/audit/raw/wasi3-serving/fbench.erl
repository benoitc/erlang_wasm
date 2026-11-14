-module(fbench).
-export([main/1]).
%% A 0.3 handler answering with a large body: wasmtime's echo handler, sent a
%% 4 MiB body over HTTP/1.1. Milliseconds from the end of the request to the
%% first byte of the response, and to its last; median of five. Reported, not
%% gated.
main([Fixture]) ->
    ok = application:load(wasm),
    ok = application:set_env(wasm, max_module_loads_per_second, 1000000),
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(Fixture),
    {ok, L} = wasi_http_listener:start(#{component => Bin, port => 0,
                                         max_body_bytes => 16777216,
                                         serve_opts => #{http_max_body_bytes => 16777216}}),
    [_, P] = binary:split(wasi_http_listener:address(L), <<":">>),
    Port = binary_to_integer(P),
    Body = binary:copy(<<"x">>, 4194304),
    _ = once(Port, Body),
    Rs = lists:sort([once(Port, Body) || _ <- lists:seq(1, 5)]),
    {First, Last} = lists:nth(3, Rs),
    io:format("~.1f ~.1f~n", [First, Last]),
    halt().

once(Port, Body) ->
    {ok, S} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    ok = gen_tcp:send(S, [<<"POST / HTTP/1.1\r\nhost: x\r\nconnection: close\r\n"
                            "content-length: ">>, integer_to_binary(byte_size(Body)),
                          <<"\r\n\r\n">>, Body]),
    T0 = erlang:monotonic_time(microsecond),
    {ok, _} = gen_tcp:recv(S, 0, 60000),
    T1 = erlang:monotonic_time(microsecond),
    drain(S),
    T2 = erlang:monotonic_time(microsecond),
    gen_tcp:close(S),
    {(T1 - T0) / 1000, (T2 - T0) / 1000}.

drain(S) ->
    case gen_tcp:recv(S, 0, 60000) of
        {ok, _} -> drain(S);
        {error, closed} -> ok
    end.
