-module(wasi_http_listener).
-moduledoc """
A live HTTP server that serves a `wasi:http` reactor component.

Each request the server accepts is turned into an `incoming-request`, handed to the
component's `wasi:http/incoming-handler#handle` through
`wasi_preview2:run_serve/3`, and answered with the response the guest set on its
outparam. The wire protocol is pluggable, the same seam the outbound path uses: a
listener speaks HTTP/1.1 (`h1`) or cleartext HTTP/2 (`h2`), so one component serves
either.

This is modelled on the `barrel_mcp` HTTP listener: the wire library owns the
acceptor pool, framing and one process per request; this module is the translator
between that process and the component. The component is instantiated per request
(host resources are per-process, so each request is isolated), which keeps a slow
or trapping guest from touching any other.

```erlang
{ok, L} = wasi_http_listener:start(#{port => 0, component => Bin}),
Addr = wasi_http_listener:address(L),
wasi_http_listener:stop(L).
```
""".

-export([start/1, stop/1, address/1]).

%% The handler runs in the wire library's per-request process; exported for clarity.
-export([serve_request/6]).

-type server() :: {module(), term(), binary()}.
-export_type([server/0]).

-define(BODY_TIMEOUT, 60000).

-doc """
Start a listener for one reactor component.

`Opts` carries the `component` (the reactor's bytes) and, optionally, the
`transport` (`h1`, the default, or `h2`), the `port` (0 for an ephemeral one), the
`scheme` reported to the guest (`http` by default), and `serve_opts` passed through
to `run_serve/3` (a `network` grant lets the reactor make its own outbound
requests).
""".
-spec start(#{component := binary(), transport => h1 | h2, port => inet:port_number(),
              scheme => binary(), serve_opts => map()}) ->
          {ok, server()} | {error, term()}.
start(#{component := Component} = Opts) ->
    Transport = maps:get(transport, Opts, h1),
    Scheme = maps:get(scheme, Opts, <<"http">>),
    ServeOpts = maps:get(serve_opts, Opts, #{}),
    {ok, _} = application:ensure_all_started(Transport),
    Handler = fun(Conn, Id, Method, Path, Headers) ->
                  serve_request(Transport, Conn, Id, Method, Path,
                                #{component => Component, scheme => Scheme,
                                  serve_opts => ServeOpts, headers => Headers})
              end,
    %% h2 serves over TLS by default; a reactor endpoint runs cleartext (h2c).
    Extra = case Transport of h2 -> #{transport => tcp}; _ -> #{} end,
    case Transport:start_server(maps:get(port, Opts, 0), Extra#{handler => Handler}) of
        {ok, Ref} ->
            Addr = iolist_to_binary(["127.0.0.1:",
                                     integer_to_binary(Transport:server_port(Ref))]),
            {ok, {Transport, Ref, Addr}};
        {error, _} = E ->
            E
    end.

-doc "The `host:port` the listener is bound to.".
-spec address(server()) -> binary().
address({_Transport, _Ref, Addr}) -> Addr.

-doc "Stop a listener and close its socket.".
-spec stop(server()) -> ok.
stop({Transport, Ref, _Addr}) ->
    _ = Transport:stop_server(Ref),
    ok.

%% @private Runs in the wire library's per-request process. Collect the body, serve
%% it through the component, and answer once. Nothing here raises: a guest that
%% traps or a component that fails to link becomes a 500, never a dropped socket.
serve_request(Transport, Conn, Id, Method, Path, Config) ->
    #{component := Component, scheme := Scheme,
      serve_opts := ServeOpts, headers := Headers} = Config,
    Body = read_body(Transport, Conn, Id, Headers),
    Request = #{method => Method, path => Path, scheme => Scheme,
                authority => authority(Headers), headers => Headers, body => Body},
    case run(Component, Request, ServeOpts) of
        {ok, Status, RespHeaders, RespBody} ->
            answer(Transport, Conn, Id, Status, RespHeaders, RespBody);
        {error, _Reason} ->
            answer(Transport, Conn, Id, 500, [], <<"wasi:http reactor error">>)
    end.

run(Component, Request, ServeOpts) ->
    try wasi_preview2:run_serve(Component, Request, ServeOpts)
    catch _:Reason -> {error, Reason}
    end.

answer(Transport, Conn, Id, Status, Headers, Body) ->
    Hdrs = ensure_length(Headers, byte_size(Body)),
    _ = Transport:send_response(Conn, Id, Status, Hdrs),
    _ = Transport:send_data(Conn, Id, Body, true),
    ok.

%% Read the request body to completion when the request declares one; the wire
%% library delivers body frames to this process, tagged by stream id (h1) or by
%% connection and stream id (h2).
read_body(Transport, Conn, Id, Headers) ->
    case content_length(Headers) of
        0 -> <<>>;
        _ -> read_body(Transport, Conn, Id, <<>>, ?BODY_TIMEOUT)
    end.

read_body(Transport, Conn, Id, Acc, Timeout) ->
    receive
        Msg ->
            case body_frame(Transport, Conn, Id, Msg) of
                {data, Data, false} ->
                    read_body(Transport, Conn, Id, <<Acc/binary, Data/binary>>, Timeout);
                {data, Data, true}  -> <<Acc/binary, Data/binary>>;
                done                -> Acc;
                other               -> read_body(Transport, Conn, Id, Acc, Timeout)
            end
    after Timeout ->
        Acc
    end.

body_frame(h1, _Conn, Id, {h1_stream, Id, {data, Data, End}}) -> {data, Data, End};
body_frame(h1, _Conn, Id, {h1_stream, Id, {trailers, _}})     -> done;
body_frame(h2, Conn, Id, {h2, Conn, {data, Id, Data, Fin}})   -> {data, Data, Fin};
body_frame(h2, Conn, Id, {h2, Conn, {trailers, Id, _}})       -> done;
body_frame(_, _, _, _)                                        -> other.

content_length(Headers) ->
    case header(<<"content-length">>, Headers) of
        undefined -> 0;
        V         -> try binary_to_integer(V) catch _:_ -> 0 end
    end.

authority(Headers) ->
    case header(<<"host">>, Headers) of
        undefined -> <<>>;
        V         -> V
    end.

header(Name, Headers) ->
    case [V || {N, V} <- Headers, string:lowercase(N) =:= Name] of
        [V | _] -> V;
        []      -> undefined
    end.

%% A fixed content-length keeps h1 from falling back to chunked framing.
ensure_length(Headers, Len) ->
    Has = lists:any(fun({N, _}) ->
                        L = string:lowercase(N),
                        L =:= <<"content-length">> orelse L =:= <<"transfer-encoding">>
                    end, Headers),
    case Has of
        true  -> Headers;
        false -> [{<<"content-length">>, integer_to_binary(Len)} | Headers]
    end.
