-module(lbench).
-export([main/1, run/3, client/2, request/2]).
%% Requests per second through wasi_http_listener serving wasmtime's hello-world
%% component: 8 clients, each 300 keep-alive GETs on its own connection, after
%% a warm-up. Median of three samples. The module cache's load rate is raised:
%% every request loads its cores again (nothing holds them between requests),
%% and the default 50 loads a second caps this component near 12 requests a
%% second on any tree.
main([Fixture]) ->
    ok = application:load(wasm),
    ok = application:set_env(wasm, max_module_loads_per_second, 1000000),
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(Fixture),
    {ok, L} = wasi_http_listener:start(#{component => Bin, port => 0}),
    [_, P] = binary:split(wasi_http_listener:address(L), <<":">>),
    Port = binary_to_integer(P),
    _ = run(Port, 4, 50),
    Rs = [run(Port, 8, 300) || _ <- lists:seq(1, 3)],
    io:format("~.1f~n", [lists:nth(2, lists:sort(Rs))]),
    halt().

run(Port, Clients, N) ->
    Self = self(),
    T0 = erlang:monotonic_time(microsecond),
    Pids = [spawn_link(fun() -> client(Port, N), Self ! {done, self()} end)
            || _ <- lists:seq(1, Clients)],
    [receive {done, Pid} -> ok end || Pid <- Pids],
    Clients * N / ((erlang:monotonic_time(microsecond) - T0) / 1.0e6).

client(Port, N) ->
    {ok, S} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    lists:foldl(fun(_, Buf) -> request(S, Buf) end, <<>>, lists:seq(1, N)),
    gen_tcp:close(S).

%% One request, its response read to the end of its body; what follows stays
%% in the buffer.
request(S, Buf) ->
    ok = gen_tcp:send(S, <<"GET / HTTP/1.1\r\nhost: x\r\n\r\n">>),
    response(S, Buf).

response(S, Buf) ->
    case binary:split(Buf, <<"\r\n\r\n">>) of
        [Head, Rest] ->
            <<"HTTP/1.1 200", _/binary>> = Head,
            {match, [L]} = re:run(Head, "content-length: *([0-9]+)",
                                  [caseless, {capture, all_but_first, binary}]),
            body(S, Rest, binary_to_integer(L));
        [_] ->
            {ok, More} = gen_tcp:recv(S, 0, 10000),
            response(S, <<Buf/binary, More/binary>>)
    end.

body(_S, Rest, Len) when byte_size(Rest) >= Len ->
    <<_:Len/binary, After/binary>> = Rest,
    After;
body(S, Rest, Len) ->
    {ok, More} = gen_tcp:recv(S, 0, 10000),
    body(S, <<Rest/binary, More/binary>>, Len).
