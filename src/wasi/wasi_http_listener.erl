-module(wasi_http_listener).
-moduledoc """
A live HTTP server that serves a `wasi:http` reactor component.

Each request the server accepts is turned into an incoming request, handed to the
component's handler through `wasi_preview3:run_serve/3` (a 0.2
`wasi:http/incoming-handler` or a 0.3 `wasi:http/handler`), and answered with the
response the guest made. The wire protocol is pluggable, the same seam the outbound path uses: a
listener speaks HTTP/1.1 (`h1`) or cleartext HTTP/2 (`h2`), so one component serves
either.

This is modelled on the `barrel_mcp` HTTP listener: the wire library owns the
acceptor pool, framing and one process per request; this module is the translator
between that process and the component. The component is instantiated per request
(host resources are per-process, so each request is isolated), which keeps a slow
or trapping guest from touching any other. The listener keeps the component's core
modules loaded for its life, so instantiating per request does not load them again.

```erlang
{ok, L} = wasi_http_listener:start(#{port => 0, component => Bin}),
Addr = wasi_http_listener:address(L),
wasi_http_listener:stop(L).
```
""".

-export([start/1, stop/1, address/1]).

%% The handler runs in the wire library's per-request process; exported for clarity.
-export([serve_request/6]).

-type server() :: {module(), term(), binary(), pid()}.
-export_type([server/0]).

%% Defaults for `request_timeout' and `max_body_bytes'.
-define(REQUEST_TIMEOUT, 60000).
-define(MAX_BODY_BYTES, 8388608).

-doc """
Start a listener for one reactor component.

`Opts` carries the `component` (the reactor's bytes) and, optionally, the
`transport` (`h1`, the default, or `h2`), the `port` (0 for an ephemeral one), the
`scheme` reported to the guest (`http` by default), and `serve_opts` passed through
to `run_serve/3` (a `network` grant lets the reactor make its own outbound
requests, and execution limits such as `fuel` bound each request's guest).

Two limits bound each request:

- `request_timeout`, the most milliseconds from the request's arrival to its
  answer, body and guest included (60 s by default). A body not received in
  time is answered 408 and never reaches the guest; a guest still running is
  stopped and the request answered 504.
- `max_body_bytes`, the largest request body (8 MiB by default). A larger one
  is answered 413 and never reaches the guest.
""".
-spec start(#{component := binary(), transport => h1 | h2, port => inet:port_number(),
              scheme => binary(), serve_opts => map(),
              request_timeout => pos_integer(),
              max_body_bytes => pos_integer()}) ->
          {ok, server()} | {error, term()}.
start(#{component := Component} = Opts) ->
    Transport = maps:get(transport, Opts, h1),
    Scheme = maps:get(scheme, Opts, <<"http">>),
    ServeOpts = maps:get(serve_opts, Opts, #{}),
    MaxBody = maps:get(max_body_bytes, Opts, ?MAX_BODY_BYTES),
    Config = #{component => Component, scheme => Scheme,
               serve_opts => ServeOpts, max_body_bytes => MaxBody,
               request_timeout => maps:get(request_timeout, Opts,
                                           ?REQUEST_TIMEOUT)},
    {ok, _} = application:ensure_all_started(Transport),
    Handler = fun(Conn, Id, Method, Path, Headers) ->
                  serve_request(Transport, Conn, Id, Method, Path,
                                Config#{headers => Headers})
              end,
    %% h2 serves over TLS by default; a reactor endpoint runs cleartext (h2c).
    %% Either library answers a body over the ceiling with 413 itself.
    Extra0 = case Transport of h2 -> #{transport => tcp}; _ -> #{} end,
    Extra = Extra0#{max_body_size => MaxBody},
    Holder = holder(Component),
    case Transport:start_server(maps:get(port, Opts, 0), Extra#{handler => Handler}) of
        {ok, Ref} ->
            Addr = iolist_to_binary(["127.0.0.1:",
                                     integer_to_binary(Transport:server_port(Ref))]),
            {ok, {Transport, Ref, Addr, Holder}};
        {error, _} = E ->
            exit(Holder, kill),
            E
    end.

%% Each request instantiates the component in its own process. Nothing else
%% held its core modules, so each request loaded them again and counted
%% against the module cache's load rate: past it, every request was a 500.
%% This process holds them for the listener's life, and dies with the process
%% that started the listener.
holder(Component) ->
    Owner = self(),
    Ref = make_ref(),
    Pid = spawn(fun() ->
                        ok = wasm_lifetime:bind(Owner),
                        Owner ! {Ref, wasm_component:hold(Component)},
                        receive stop -> ok end
                end),
    %% Loaded before the first request, so none of them races the hold.
    receive {Ref, _} -> Pid after 30000 -> Pid end.

-doc "The `host:port` the listener is bound to.".
-spec address(server()) -> binary().
address({_Transport, _Ref, Addr, _Holder}) -> Addr.

-doc "Stop a listener and close its socket.".
-spec stop(server()) -> ok.
stop({Transport, Ref, _Addr, Holder}) ->
    _ = Transport:stop_server(Ref),
    Holder ! stop,
    ok.

%% @private Runs in the wire library's per-request process. Collect the body, serve
%% it through the component, and answer once. Nothing here raises: a guest that
%% traps or a component that fails to link becomes a 500, never a dropped socket.
serve_request(Transport, Conn, Id, Method, Path, Config) ->
    #{component := Component, scheme := Scheme, serve_opts := ServeOpts,
      headers := Headers, request_timeout := Timeout} = Config,
    %% Fixed when the request arrives: the body and the guest share it.
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    case read_body(Transport, Conn, Id, Config, Deadline) of
        {ok, Body} ->
            Request = #{method => Method, path => Path, scheme => Scheme,
                        authority => authority(Headers), headers => Headers,
                        body => Body},
            case run(Component, Request, ServeOpts, Deadline) of
                {ok, Status, RespHeaders, RespBody} ->
                    answer(Transport, Conn, Id, Status, RespHeaders, RespBody);
                timeout ->
                    answer(Transport, Conn, Id, 504, [],
                           <<"wasi:http reactor timed out">>);
                {error, _Reason} ->
                    answer(Transport, Conn, Id, 500, [],
                           <<"wasi:http reactor error">>)
            end;
        timeout ->
            answer(Transport, Conn, Id, 408, [], <<"request body timed out">>);
        too_large ->
            answer(Transport, Conn, Id, 413, [], <<"request body too large">>);
        gone ->
            ok
    end.

%% The guest runs in a child bound to this process, which holds the deadline:
%% a guest that never returns is stopped at it, and a request process killed
%% by the wire library takes the guest with it.
run(Component, Request, ServeOpts, Deadline) ->
    Parent = self(),
    {Pid, Mon} = spawn_monitor(
                   fun() ->
                           ok = wasm_lifetime:bind(Parent),
                           Parent ! {served, self(),
                                     try wasi_preview3:run_serve(
                                           Component, Request, ServeOpts)
                                     catch _:Reason -> {error, Reason}
                                     end}
                   end),
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {served, Pid, Result} ->
            erlang:demonitor(Mon, [flush]),
            Result;
        {'DOWN', Mon, process, Pid, Reason} ->
            {error, Reason}
    after Left ->
        exit(Pid, kill),
        erlang:demonitor(Mon, [flush]),
        timeout
    end.

answer(Transport, Conn, Id, Status, Headers, Body) ->
    Hdrs = ensure_length(Headers, byte_size(Body)),
    _ = Transport:send_response(Conn, Id, Status, Hdrs),
    _ = Transport:send_data(Conn, Id, Body, true),
    ok.

%% Read the request body to its end, chunked or not: both libraries end every
%% request, a bodyless one included, with a final data frame. Only this
%% request's frames are taken from the mailbox; anything else stays there.
%% Answers `{ok, Body}', `timeout', `too_large', or `gone' when the peer reset
%% the request or left.
read_body(Transport, Conn, Id, #{max_body_bytes := Max, headers := Headers},
          Deadline) ->
    case content_length(Headers) of
        N when is_integer(N), N > Max -> too_large;
        _ -> read_body(Transport, Conn, Id, <<>>, Max, Deadline)
    end.

read_body(h1, Conn, Id, Acc, Max, Deadline) ->
    receive
        {h1_stream, Id, {data, Data, End}} ->
            more(h1, Conn, Id, <<Acc/binary, Data/binary>>, End, Max, Deadline);
        {h1_stream, Id, {trailers, _}} -> {ok, Acc};
        {h1_stream, Id, {stream_reset, _}} -> gone
    after left(Deadline) -> timeout
    end;
read_body(h2, Conn, Id, Acc, Max, Deadline) ->
    receive
        {h2, Conn, {data, Id, Data, End}} ->
            more(h2, Conn, Id, <<Acc/binary, Data/binary>>, End, Max, Deadline);
        {h2, Conn, {trailers, Id, _}} -> {ok, Acc};
        {h2, Conn, {stream_reset, Id, _}} -> gone;
        {h2, Conn, {closed, _}} -> gone
    after left(Deadline) -> timeout
    end.

more(_Transport, _Conn, _Id, Body, _End, Max, _Deadline)
  when byte_size(Body) > Max ->
    too_large;
more(_Transport, _Conn, _Id, Body, true, _Max, _Deadline) ->
    {ok, Body};
more(Transport, Conn, Id, Body, false, Max, Deadline) ->
    read_body(Transport, Conn, Id, Body, Max, Deadline).

left(Deadline) -> max(0, Deadline - erlang:monotonic_time(millisecond)).

%% The declared length, or `undefined' when there is none or it is not a
%% number (the wire library has already refused a malformed one).
content_length(Headers) ->
    case header(<<"content-length">>, Headers) of
        undefined -> undefined;
        V         -> try binary_to_integer(V) catch _:_ -> undefined end
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
