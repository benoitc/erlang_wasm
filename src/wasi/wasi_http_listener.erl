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
`transport` (`h1`, the default, or `h2`), the `ip` to listen on (`{127, 0, 0,
1}` by default, so only this machine can connect; `{0, 0, 0, 0}` listens on
every interface), the `port` (0 for an ephemeral one), the
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
-spec start(#{component := binary(), transport => h1 | h2,
              ip => inet:ip_address(), port => inet:port_number(),
              scheme => binary(), serve_opts => map(),
              request_timeout => pos_integer(),
              max_body_bytes => pos_integer()}) ->
          {ok, server()} | {error, term()}.
start(#{component := Component} = Opts) ->
    Transport = maps:get(transport, Opts, h1),
    Scheme = maps:get(scheme, Opts, <<"http">>),
    ServeOpts = maps:get(serve_opts, Opts, #{}),
    MaxBody = maps:get(max_body_bytes, Opts, ?MAX_BODY_BYTES),
    %% Decoded and parsed once, as the imports are built once; a component
    %% that does not prepare fails each request as its bytes would.
    Prepared = case wasm_component:prepare(Component) of
                   {ok, P} -> P;
                   {error, _} -> Component
               end,
    Config = #{component => Prepared, scheme => Scheme,
               %% Built once: nothing in them belongs to one request.
               imports => wasi_preview3:serve_imports(Component, ServeOpts),
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
    %% Loopback unless told otherwise: with no address both libraries listened
    %% on every interface, while `address/1' said 127.0.0.1.
    IP = maps:get(ip, Opts, {127, 0, 0, 1}),
    Extra = Extra0#{max_body_size => MaxBody, ip => IP},
    Holder = holder(Prepared),
    case Transport:start_server(maps:get(port, Opts, 0), Extra#{handler => Handler}) of
        {ok, Ref} ->
            Addr = iolist_to_binary([host(IP), ":",
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

%% The address as a URL authority writes it: an IPv6 one in brackets.
host({_, _, _, _} = IP) -> inet:ntoa(IP);
host(IP) -> ["[", inet:ntoa(IP), "]"].

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
      imports := Imports,
      headers := Headers, request_timeout := Timeout} = Config,
    %% Fixed when the request arrives: the body and the guest share it.
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    case read_body(Transport, Conn, Id, Config, Deadline) of
        {ok, Body, Trailers} ->
            Request = #{method => Method, path => Path, scheme => Scheme,
                        authority => authority(Headers),
                        headers => fields(Headers), body => Body,
                        trailers => fields(Trailers)},
            Out = {Transport, Conn, Id},
            case run(Component, Request, ServeOpts, Imports, Deadline, Out) of
                streamed ->
                    ok;
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
%%
%% A 0.3 response is streamed: the child sends its head, then each chunk the
%% guest writes, then its end, and this process writes them out. The child
%% waits for each chunk to be written before it reads the next, so one chunk
%% at a time is in flight and a slow client slows the guest. Once the head is
%% out, a failure can no longer be answered with a status: the stream is
%% reset instead. Answers `streamed' once a streamed response has ended,
%% whichever way, or the whole result of a 0.2 handler.
run(Component, Request, ServeOpts, Imports, Deadline, Out) ->
    Parent = self(),
    Emit = fun(Event) ->
                   Parent ! {stream, self(), Event},
                   case Event of
                       {chunk, _} -> receive {written, Parent} -> ok end;
                       _ -> ok
                   end
           end,
    {Pid, Mon} = spawn_monitor(
                   fun() ->
                           ok = wasm_lifetime:bind(Parent),
                           Parent ! {served, self(),
                                     try wasi_preview3:run_serve_stream(
                                           Component, Request, ServeOpts, Imports,
                                           Emit)
                                     catch _:Reason -> {error, Reason}
                                     end}
                   end),
    wait(Pid, Mon, Deadline, Out, none).

%% `Head' is `none' until the head is written, then the framing it set.
wait(Pid, Mon, Deadline, {Transport, Conn, Id} = Out, Head) ->
    receive
        {stream, Pid, {head, Status, Headers}} ->
            _ = Transport:send_response(Conn, Id, Status, Headers),
            wait(Pid, Mon, Deadline, Out, framing(Transport, Headers));
        {stream, Pid, {chunk, Bin}} ->
            case send_chunk(Transport, Conn, Id, Bin, Deadline) of
                ok ->
                    Pid ! {written, self()},
                    wait(Pid, Mon, Deadline, Out, Head);
                {error, _} ->
                    exit(Pid, kill),
                    erlang:demonitor(Mon, [flush]),
                    served(gone, Out, Head)
            end;
        {stream, Pid, {done, Trailers}} ->
            _ = finish(Out, Head, Trailers),
            wait(Pid, Mon, Deadline, Out, done);
        {served, Pid, Result} ->
            erlang:demonitor(Mon, [flush]),
            served(Result, Out, Head);
        {'DOWN', Mon, process, Pid, Reason} ->
            served({error, Reason}, Out, Head)
    after left(Deadline) ->
        exit(Pid, kill),
        erlang:demonitor(Mon, [flush]),
        served(timeout, Out, Head)
    end.

%% A chunk waits for the client to take it: h2 holds data the client's window
%% has no room for up to a cap, and past it refuses more unless asked to wait.
%% A client that takes nothing before the deadline, or has gone, ends the
%% response.
send_chunk(h2, Conn, Id, Bin, Deadline) ->
    catch_send(fun() -> h2:send_data(Conn, Id, Bin, false, #{block => left(Deadline)}) end);
send_chunk(Transport, Conn, Id, Bin, _Deadline) ->
    catch_send(fun() -> Transport:send_data(Conn, Id, Bin, false) end).

catch_send(Send) ->
    try Send() of
        ok -> ok;
        {error, _} = E -> E
    catch exit:Reason -> {error, Reason}
    end.

served(Result, _Out, none) -> Result;
served(_Result, _Out, done) -> streamed;
%% The head is out but the response did not end: the client must not take
%% what it got for the whole response.
served(_Result, {Transport, Conn, Id}, _Framing) ->
    _ = Transport:cancel(Conn, Id),
    streamed.

%% h1 can send trailers only after a chunked body: a response that declared
%% its length is sent with that length, and its trailers are dropped.
framing(h1, Headers) ->
    case content_length(Headers) of
        undefined -> chunked;
        _ -> length
    end;
framing(_, _Headers) -> frames.

finish({Transport, Conn, Id}, Framing, Trailers) when Trailers =:= [];
                                                     Framing =:= length ->
    Transport:send_data(Conn, Id, <<>>, true);
finish({Transport, Conn, Id}, _Framing, Trailers) ->
    Transport:send_trailers(Conn, Id, Trailers).

answer(Transport, Conn, Id, Status, Headers, Body) ->
    Hdrs = ensure_length(Headers, byte_size(Body)),
    _ = Transport:send_response(Conn, Id, Status, Hdrs),
    _ = Transport:send_data(Conn, Id, Body, true),
    ok.

%% Read the request body to its end, chunked or not: both libraries end every
%% request, a bodyless one included, with a final data frame. Only this
%% request's frames are taken from the mailbox; anything else stays there.
%% Answers `{ok, Body, Trailers}', `timeout', `too_large', or `gone' when the
%% peer reset the request or left. Trailers end the body.
read_body(Transport, Conn, Id, #{max_body_bytes := Max, headers := Headers},
          Deadline) ->
    case content_length(Headers) of
        N when is_integer(N), N > Max -> too_large;
        _ ->
            ok = take_stream(Transport, Conn, Id),
            read_body(Transport, Conn, Id, <<>>, Max, Deadline)
    end.

%% h2 holds a stream's events until a process asks for them, and its server
%% does not ask for the request process: without this, the body never came
%% and every h2 request ended at the deadline. h1 sends them here already.
take_stream(h2, Conn, Id) ->
    case h2:set_stream_handler(Conn, Id, self()) of
        ok -> ok;
        {error, _} -> ok
    end;
take_stream(_, _Conn, _Id) ->
    ok.

read_body(h1, Conn, Id, Acc, Max, Deadline) ->
    receive
        {h1_stream, Id, {data, Data, End}} ->
            more(h1, Conn, Id, <<Acc/binary, Data/binary>>, End, Max, Deadline);
        {h1_stream, Id, {trailers, Trailers}} -> {ok, Acc, Trailers};
        {h1_stream, Id, {stream_reset, _}} -> gone
    after left(Deadline) -> timeout
    end;
read_body(h2, Conn, Id, Acc, Max, Deadline) ->
    receive
        {h2, Conn, {data, Id, Data, End}} ->
            more(h2, Conn, Id, <<Acc/binary, Data/binary>>, End, Max, Deadline);
        {h2, Conn, {trailers, Id, Trailers}} -> {ok, Acc, Trailers};
        {h2, Conn, {stream_reset, Id, _}} -> gone;
        {h2, Conn, {closed, _}} -> gone
    after left(Deadline) -> timeout
    end.

more(_Transport, _Conn, _Id, Body, _End, Max, _Deadline)
  when byte_size(Body) > Max ->
    too_large;
more(_Transport, _Conn, _Id, Body, true, _Max, _Deadline) ->
    {ok, Body, []};
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

%% h2 gives the authority as `:authority', h1 as `host'.
authority(Headers) ->
    case header(<<":authority">>, Headers) of
        undefined ->
            case header(<<"host">>, Headers) of
                undefined -> <<>>;
                V         -> V
            end;
        V -> V
    end.

%% The request's fields, without h2's pseudo-headers: the method, path,
%% scheme and authority reach the guest as themselves, and a pseudo-header
%% the guest echoed would be a malformed response.
fields(Headers) ->
    [{N, V} || {N, V} <- Headers, not is_pseudo(N)].

is_pseudo(<<":", _/binary>>) -> true;
is_pseudo(_) -> false.

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
