-module(lbench).
-export([main/1]).
%% Requests per second through wasi_http_listener: 8 clients, each 300
%% keep-alive GETs on its own connection, after a warm-up; median of three
%% samples. A response is read to its end whether it carries a length or is
%% chunked, since a 0.3 response is now streamed.
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

request(S, Buf) ->
    ok = gen_tcp:send(S, <<"GET / HTTP/1.1\r\nhost: x\r\n\r\n">>),
    response(S, Buf).

response(S, Buf) ->
    case binary:split(Buf, <<"\r\n\r\n">>) of
        [Head, Rest] ->
            <<"HTTP/1.1 200", _/binary>> = Head,
            case re:run(Head, "content-length: *([0-9]+)",
                        [caseless, {capture, all_but_first, binary}]) of
                {match, [L]} -> body(S, Rest, binary_to_integer(L));
                nomatch -> chunks(S, Rest)
            end;
        [_] -> response(S, <<Buf/binary, (more(S))/binary>>)
    end.

body(_S, Rest, Len) when byte_size(Rest) >= Len ->
    <<_:Len/binary, After/binary>> = Rest,
    After;
body(S, Rest, Len) -> body(S, <<Rest/binary, (more(S))/binary>>, Len).

chunks(S, Buf) ->
    case binary:split(Buf, <<"\r\n">>) of
        [Size, Rest] ->
            case binary_to_integer(hd(binary:split(Size, <<";">>)), 16) of
                0 -> trailer(S, Rest);
                N when byte_size(Rest) >= N + 2 ->
                    <<_:N/binary, "\r\n", After/binary>> = Rest,
                    chunks(S, After);
                _ -> chunks(S, <<Buf/binary, (more(S))/binary>>)
            end;
        [_] -> chunks(S, <<Buf/binary, (more(S))/binary>>)
    end.

trailer(_S, <<"\r\n", After/binary>>) -> After;
trailer(S, Buf) ->
    case binary:split(Buf, <<"\r\n\r\n">>) of
        [_, After] -> After;
        [_] -> trailer(S, <<Buf/binary, (more(S))/binary>>)
    end.

more(S) ->
    {ok, B} = gen_tcp:recv(S, 0, 10000),
    B.
