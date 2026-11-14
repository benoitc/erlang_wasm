-module(wasi_p3_http).
-moduledoc """
`wasi:http` at 0.3: `fields`, `request`, `request-options` and `response`
resources, `client.send`, and the incoming requests a `wasi:http/handler`
export serves.

Requests go out through the same transport and grant as 0.2
(`wasi_http:perform/4`). What changes is the shape: a request or response carries its
body as a stream and its trailers as a future, and `send` is an async call. A
collector process takes the body as the guest writes it, so the exchange runs
outside the guest's process while the guest keeps writing.
""".

-export([http/1, incoming_request/1, take_response/2]).

-define(TYPES, ~"wasi:http/types@0.3").
-define(CLIENT, ~"wasi:http/client@0.3").
-define(ERROR, (wasi_http:error_code())).
-define(METHOD,
        {variant, [{M, none} || M <- ?METHODS] ++ [{~"other", string}]}).
-define(METHODS, [~"get", ~"head", ~"post", ~"put", ~"delete", ~"connect",
                  ~"options", ~"trace", ~"patch"]).
-define(SCHEME, {variant, [{~"HTTP", none}, {~"HTTPS", none}, {~"other", string}]}).
-define(HEADER_ERROR,
        {variant, [{~"invalid-syntax", none}, {~"forbidden", none},
                   {~"immutable", none}, {~"size-exceeded", none},
                   {~"other", {option, string}}]}).
-define(OPTIONS_ERROR,
        {variant, [{~"not-supported", none}, {~"immutable", none},
                   {~"other", {option, string}}]}).
-define(ENTRY, {tuple, [string, {list, u8}]}).
-define(TRAILERS, {future, {result, {option, handle}, ?ERROR}}).
-define(STATUS, {future, {result, none, ?ERROR}}).
-define(UNIT, {result, none, none}).

-type host() :: #{{binary(), binary()} => term()}.

-doc """
`wasi:http` at 0.3. `Opts` is as for `wasi_http:http/1`: the `network` grant,
the `http_transport` and `http_tls`, and `http_max_body_bytes`.
""".
-spec http(map()) -> host().
http(Opts) ->
    Grant = wasi_net:grant(maps:get(network, Opts, none)),
    Transport = maps:get(http_transport, Opts, wasi_http_h1),
    Tls = maps:get(http_tls, Opts, []),
    MaxBody = maps:get(http_max_body_bytes, Opts, 8388608),
    F = fun(Name, Sig, Fun) -> {{?TYPES, Name}, wasm_component:import_fun(Sig, Fun)} end,
    Drop = fun(Res) ->
                   {{?TYPES, <<"[resource-drop]", Res/binary>>},
                    fun(_Ctx, [H]) -> _ = wasm_component:host_drop(H), {ok, []} end}
           end,
    maps:from_list(
      [Drop(~"fields"), Drop(~"request"), Drop(~"response"), Drop(~"request-options"),
       F(~"[constructor]fields", {[], handle}, fun([]) -> new_fields([], true) end),
       F(~"[static]fields.from-list", {[{list, ?ENTRY}], {result, handle, ?HEADER_ERROR}},
         fun([Entries]) -> from_list(Entries) end),
       F(~"[method]fields.get", {[handle, string], {list, {list, u8}}},
         fun([H, N]) -> [V || {K, V} <- entries(H), same(K, N)] end),
       F(~"[method]fields.has", {[handle, string], bool},
         fun([H, N]) -> lists:any(fun({K, _}) -> same(K, N) end, entries(H)) end),
       F(~"[method]fields.set", {[handle, string, {list, {list, u8}}],
                                 {result, none, ?HEADER_ERROR}},
         fun([H, N, Vs]) -> set(H, N, Vs) end),
       F(~"[method]fields.delete", {[handle, string], {result, none, ?HEADER_ERROR}},
         fun([H, N]) -> mutate(H, N, <<>>, fun(Es) -> drop_name(Es, N) end) end),
       F(~"[method]fields.get-and-delete",
         {[handle, string], {result, {list, {list, u8}}, ?HEADER_ERROR}},
         fun([H, N]) ->
                 Vs = [V || {K, V} <- entries(H), same(K, N)],
                 case mutate(H, N, <<>>, fun(Es) -> drop_name(Es, N) end) of
                     {ok, _} -> {ok, Vs};
                     E -> E
                 end
         end),
       F(~"[method]fields.append", {[handle, string, {list, u8}],
                                    {result, none, ?HEADER_ERROR}},
         fun([H, N, V]) -> mutate(H, N, V, fun(Es) -> Es ++ [{N, V}] end) end),
       F(~"[method]fields.copy-all", {[handle], {list, ?ENTRY}}, fun([H]) -> entries(H) end),
       F(~"[method]fields.clone", {[handle], handle},
         fun([H]) -> new_fields(entries(H), true) end),
       %% request
       F(~"[static]request.new",
         {[handle, {option, {stream, u8}}, ?TRAILERS, {option, handle}],
          {tuple, [handle, ?STATUS]}},
         fun([Hs, Body, Trailers, Options]) ->
                 new_message(request, Hs, Body, Trailers,
                             #{method => {~"get", undefined}, path => none,
                               scheme => none, authority => none, options => Options})
         end),
       F(~"[method]request.get-method", {[handle], ?METHOD}, fun([R]) -> get(R, method) end),
       F(~"[method]request.set-method", {[handle, ?METHOD], ?UNIT},
         fun([R, M]) -> set_valid(R, method, M, valid_method(M)) end),
       F(~"[method]request.get-path-with-query", {[handle], {option, string}},
         fun([R]) -> get(R, path) end),
       F(~"[method]request.set-path-with-query", {[handle, {option, string}], ?UNIT},
         fun([R, P]) -> set_valid(R, path, P, valid_path(P)) end),
       F(~"[method]request.get-scheme", {[handle], {option, ?SCHEME}},
         fun([R]) -> get(R, scheme) end),
       F(~"[method]request.set-scheme", {[handle, {option, ?SCHEME}], ?UNIT},
         fun([R, S]) -> set_valid(R, scheme, S, valid_scheme(S)) end),
       F(~"[method]request.get-authority", {[handle], {option, string}},
         fun([R]) -> get(R, authority) end),
       F(~"[method]request.set-authority", {[handle, {option, string}], ?UNIT},
         fun([R, A]) -> set_valid(R, authority, A, valid_authority(A)) end),
       F(~"[method]request.get-options", {[handle], {option, handle}},
         fun([R]) -> get(R, options) end),
       F(~"[method]request.get-headers", {[handle], handle},
         fun([R]) -> new_fields(get(R, headers), false) end),
       F(~"[static]request.consume-body",
         {[handle, ?STATUS], {tuple, [{stream, u8}, ?TRAILERS]}},
         fun([R, _Res]) -> consume_body(R) end),
       %% request-options
       F(~"[constructor]request-options", {[], handle},
         fun([]) -> wasm_component:host_new(p3_http_opts, #{}) end),
       F(~"[method]request-options.clone", {[handle], handle},
         fun([O]) -> wasm_component:host_new(p3_http_opts, opts(O)) end)]
      ++ lists:append(
           [[F(<<"[method]request-options.get-", Name/binary>>, {[handle], {option, u64}},
               fun([O]) -> case opts(O) of #{Key := V} -> {some, V}; _ -> none end end),
             F(<<"[method]request-options.set-", Name/binary>>,
               {[handle, {option, u64}], {result, none, ?OPTIONS_ERROR}},
               fun([O, V]) -> set_opt(O, Key, V) end)]
            || {Name, Key} <- [{~"connect-timeout", connect_timeout},
                               {~"first-byte-timeout", first_byte_timeout},
                               {~"between-bytes-timeout", between_bytes_timeout}]])
      ++ [%% response
          F(~"[static]response.new",
            {[handle, {option, {stream, u8}}, ?TRAILERS], {tuple, [handle, ?STATUS]}},
            fun([Hs, Body, Trailers]) ->
                    new_message(response, Hs, Body, Trailers, #{status => 200})
            end),
          F(~"[method]response.get-status-code", {[handle], u16},
            fun([R]) -> get(R, status) end),
          F(~"[method]response.set-status-code", {[handle, u16], ?UNIT},
            fun([R, S]) -> set_valid(R, status, S, S >= 100 andalso S =< 999) end),
          F(~"[method]response.get-headers", {[handle], handle},
            fun([R]) -> new_fields(get(R, headers), false) end),
          F(~"[static]response.consume-body",
            {[handle, ?STATUS], {tuple, [{stream, u8}, ?TRAILERS]}},
            fun([R, _Res]) -> consume_body(R) end),
          {{?CLIENT, ~"send"},
           {async_import, {[handle], {result, handle, ?ERROR}},
            fun([R]) -> start_send(R, MaxBody) end,
            {producer, fun(Ctx) -> send(Ctx, Grant, Transport, Tls) end}}}]).

%%% -------------------------------------------------------------- fields ---

new_fields(Entries, Mutable) ->
    wasm_component:host_new(p3_http_fields, #{entries => Entries, mutable => Mutable}).

entries(H) ->
    case wasm_component:host_get(H) of
        {ok, {p3_http_fields, #{entries := Es}}} -> Es;
        _ -> []
    end.

from_list(Entries) ->
    case [E || {N, V} <- Entries, E <- [wasi_http:field_error(N, V)], E =/= none] of
        [] -> {ok, new_fields(Entries, true)};
        [E | _] -> {error, E}
    end.

set(H, N, Vs) ->
    case [E || V <- [<<>> | Vs], E <- [wasi_http:field_error(N, V)], E =/= none] of
        [] -> mutate(H, N, <<>>, fun(Es) -> drop_name(Es, N) ++ [{N, V} || V <- Vs] end);
        [E | _] -> {error, E}
    end.

%% A change to a fields the host made immutable (a message's headers) is
%% refused; so is a forbidden or malformed name.
mutate(H, N, V, Fun) ->
    case wasm_component:host_get(H) of
        {ok, {p3_http_fields, #{mutable := false}}} -> {error, {~"immutable", undefined}};
        {ok, {p3_http_fields, #{entries := Es} = M}} ->
            case wasi_http:field_error(N, V) of
                none ->
                    _ = wasm_component:host_update(H, M#{entries => Fun(Es)}),
                    {ok, undefined};
                E -> {error, E}
            end;
        _ -> {error, {~"other", none}}
    end.

drop_name(Es, N) -> [{K, V} || {K, V} <- Es, not same(K, N)].

same(A, B) -> string:lowercase(A) =:= string:lowercase(B).

%%% ------------------------------------------------------------ messages ---

%% A request or response: the headers are the fields' entries, taken now (the
%% fields handle is the guest's to drop); the body is the guest's stream, or
%% none; the trailers its future. The future handed back reports how sending
%% the body went.
new_message(Kind, Hs, Body, Trailers, Extra) ->
    {R, W} = wasm_async:host_future({result, none, ?ERROR}),
    H = wasm_component:host_new(
          tag(Kind),
          Extra#{headers => entries(Hs), body => Body, trailers => Trailers,
                 sent => W}),
    {H, R}.

tag(request) -> p3_http_request;
tag(response) -> p3_http_response.

message(H) ->
    case wasm_component:host_get(H) of
        {ok, {Tag, M}} when Tag =:= p3_http_request; Tag =:= p3_http_response -> {Tag, M};
        _ -> error
    end.

get(H, Key) ->
    {_, M} = message(H),
    maps:get(Key, M).

set_valid(H, Key, V, true) ->
    {_, M} = message(H),
    _ = wasm_component:host_update(H, M#{Key => V}),
    {ok, undefined};
set_valid(_H, _Key, _V, false) ->
    {error, undefined}.

valid_method({~"other", M}) -> wasi_http:field_error(M, <<>>) =:= none;
valid_method(_) -> true.

valid_path(none) -> true;
valid_path({some, P}) -> not lists:any(fun(C) -> C =< $\s end, binary_to_list(P)).

%% A URI scheme: a letter, then letters, digits, `+', `-' and `.'.
valid_scheme({some, {~"other", <<C, Rest/binary>>}}) when C >= $a, C =< $z;
                                                      C >= $A, C =< $Z ->
    lists:all(fun(X) -> (X >= $a andalso X =< $z) orelse (X >= $A andalso X =< $Z)
                            orelse (X >= $0 andalso X =< $9)
                            orelse X =:= $+ orelse X =:= $- orelse X =:= $.
              end, binary_to_list(Rest));
valid_scheme({some, {~"other", _}}) -> false;
valid_scheme(_) -> true.

valid_authority(none) -> true;
valid_authority({some, A}) ->
    case binary:match(A, [<<"/">>, <<"?">>, <<"#">>, <<"@">>]) of
        nomatch -> valid_host_port(A);
        _ -> false
    end.

%% `host[:port]' or `[ipv6][:port]', with no whitespace or control bytes and a
%% port that fits in 16 bits.
valid_host_port(<<"[", Rest/binary>>) ->
    case binary:split(Rest, <<"]">>) of
        [V6, <<>>] -> ipv6(V6);
        [V6, <<":", Port/binary>>] -> ipv6(V6) andalso valid_port(Port);
        _ -> false
    end;
valid_host_port(A) ->
    case binary:split(A, <<":">>, [global]) of
        [Host] -> valid_host(Host);
        [Host, Port] -> valid_host(Host) andalso valid_port(Port);
        _ -> false
    end.

ipv6(V6) -> element(1, inet:parse_ipv6strict_address(binary_to_list(V6))) =:= ok.

valid_host(<<>>) -> false;
valid_host(H) -> not lists:any(fun(C) -> C =< $\s orelse C >= 127 end, binary_to_list(H)).

valid_port(<<>>) -> false;
valid_port(P) ->
    try binary_to_integer(P) of N -> N >= 0 andalso N =< 65535
    catch _:_ -> false
    end.

%% The body and trailers of a message, which is consumed. A body the host
%% made (an incoming request, a response from `send') is already a stream; a
%% message the guest made gives back the stream it was given.
consume_body(H) ->
    {_, #{body := Body, trailers := Trailers}} = message(H),
    _ = wasm_component:host_drop(H),
    Stream = case Body of
                 {some, S} -> S;
                 {bytes, Bin} -> feed(Bin);
                 none -> feed(<<>>)
             end,
    {Stream, case Trailers of
                 {fields, Es} -> trailers(Es);
                 T -> T
             end}.

%% A stream the guest reads: a producer sends `Bin' and ends it.
feed(Bin) ->
    R = wasm_async:new_stream_channel(u8),
    ok = wasm_async:register_producer(
           R, fun(#{owner := O, task_ref := Ref, handle := H}) ->
                      O ! {async_ready, Ref, H, {data, Bin}},
                      O ! {async_ready, Ref, H, close}
              end),
    R.

no_trailers() ->
    resolved_trailers({ok, none}).

%% The trailers a request arrived with, which the guest may read but not
%% change, as it may not change its headers.
trailers([]) -> no_trailers();
trailers(Entries) -> resolved_trailers({ok, {some, new_fields(Entries, false)}}).

resolved_trailers(Value) ->
    {R, W} = wasm_async:host_future({result, {option, handle}, ?ERROR}),
    ok = wasm_async:host_future_resolve(W, Value),
    R.

%%% ------------------------------------------------------------- options ---

opts(O) ->
    case wasm_component:host_get(O) of
        {ok, {p3_http_opts, M}} -> M;
        _ -> #{}
    end.

set_opt(O, Key, none) ->
    _ = wasm_component:host_update(O, maps:remove(Key, opts(O))),
    {ok, undefined};
set_opt(O, Key, {some, V}) ->
    _ = wasm_component:host_update(O, (opts(O))#{Key => V}),
    {ok, undefined}.

%%% ---------------------------------------------------------------- send ---

%% The request is the host's now. Its body is collected by a process the guest
%% writes to as it goes; the exchange runs in the subtask's producer.
start_send(R, MaxBody) ->
    case message(R) of
        {p3_http_request, M} ->
            _ = wasm_component:host_drop(R),
            case target(M, MaxBody) of
                {ok, Target} ->
                    Collector = collector(maps:get(body, M), declared_length(M),
                                          MaxBody),
                    #{target => Target, collector => Collector, sent => maps:get(sent, M)};
                {error, E} ->
                    ok = wasm_async:host_future_resolve(maps:get(sent, M), {error, E}),
                    {returned, {error, E}}
            end;
        _ ->
            {returned, {error, {~"internal-error", {some, ~"not a request"}}}}
    end.

target(#{path := none}, _) -> {error, {~"HTTP-request-URI-invalid", undefined}};
target(#{authority := none}, _) -> {error, {~"HTTP-request-URI-invalid", undefined}};
target(#{method := Method, path := {some, Path}, authority := {some, Auth},
         scheme := Scheme, headers := Headers, options := Options}, MaxBody) ->
    S = case Scheme of
            none -> ~"http";
            {some, {~"HTTP", _}} -> ~"http";
            {some, {~"HTTPS", _}} -> ~"https";
            {some, {~"other", Other}} -> Other
        end,
    Map = #{method => method_name(Method), path => Path, authority => Auth,
            scheme => S, headers => Headers, max_body_bytes => MaxBody,
            timeouts => timeouts(Options)},
    case wasi_http:request_error(Map) of
        none -> {ok, Map};
        E -> {error, E}
    end.

method_name({~"other", M}) -> M;
method_name({M, _}) -> string:uppercase(M).

timeouts(none) ->
    #{connect_timeout => undefined, first_byte_timeout => undefined,
      between_bytes_timeout => undefined};
timeouts({some, O}) ->
    M = opts(O),
    #{connect_timeout => maps:get(connect_timeout, M, undefined),
      first_byte_timeout => maps:get(first_byte_timeout, M, undefined),
      between_bytes_timeout => maps:get(between_bytes_timeout, M, undefined)}.

%% The Content-Length the request declares, or none.
declared_length(#{headers := Headers}) ->
    case [V || {K, V} <- Headers, same(K, ~"content-length")] of
        [V | _] ->
            try binary_to_integer(V) of N when N >= 0 -> N
            catch _:_ -> none
            end;
        [] -> none
    end.

%% A process that keeps what the guest writes to the body, and hands it over
%% once the guest has ended the stream. A body that does not match the length
%% the request declares is never sent: a write that would go past it is
%% refused whole, and a body that ends short is an error.
collector(none, _Declared, _MaxBody) ->
    collector_with(<<>>, done);
%% An incoming request sent on as it came: its body was never made a stream.
collector({bytes, Bin}, _Declared, _MaxBody) ->
    collector_with(Bin, done);
%% The body is host memory until it is sent. A declared content-length bounds
%% it, and without one nothing did; `MaxBody' bounds it either way.
collector({some, S}, Declared, MaxBody) ->
    Pid = collector_with(<<>>, open),
    Total = counters:new(1, []),
    Sink = fun(eof) -> Pid ! eof, ok;
              (B) ->
                   N = counters:get(Total, 1) + byte_size(B),
                   case Declared =/= none andalso N > Declared
                       orelse N > MaxBody of
                       true -> Pid ! {too_long, N}, closed;
                       false -> ok = counters:put(Total, 1, N), Pid ! {body, B}, ok
                   end
           end,
    ok = wasm_async:host_sink(S, Sink),
    Pid ! {declared, Declared},
    Pid.

collector_with(Acc, State) ->
    Owner = self(),
    spawn(fun() -> ok = wasm_lifetime:bind(Owner), collect(Acc, State, none) end).

collect(Acc, open, Declared) ->
    receive
        {declared, D} -> collect(Acc, open, D);
        {body, B} -> collect(<<Acc/binary, B/binary>>, open, Declared);
        {too_long, N} -> collect(Acc, {error, body_size(N)}, Declared);
        eof when Declared =/= none, byte_size(Acc) < Declared ->
            collect(Acc, {error, body_size(byte_size(Acc))}, Declared);
        eof -> collect(Acc, done, Declared)
    end;
collect(Acc, done, _Declared) ->
    receive {get, From} -> From ! {body, Acc} end;
collect(_Acc, {error, E}, _Declared) ->
    receive {get, From} -> From ! {error, E} end.

body_size(N) -> {~"HTTP-request-body-size", {some, N}}.

%% The exchange, in the subtask's producer: wait for the whole body, send the
%% request, and hand the owner a fun that makes the response resources.
send(#{owner := O, task_ref := Ref, handle := H,
       value := #{target := Target, collector := C, sent := Sent}}, Grant, Transport, Tls) ->
    %% A connection the transport links to this process ends as a message.
    process_flag(trap_exit, true),
    C ! {get, self()},
    Result = receive
                 {body, B} -> wasi_http:perform(Target#{body => B}, Grant, Transport, Tls);
                 {error, E} -> {error, E}
             end,
    Make = fun() -> response(Result, Sent) end,
    O ! {async_ready, Ref, H, {subtask_complete, {in_owner, Make}}}.

response({ok, Status, Headers, Body}, Sent) ->
    ok = wasm_async:host_future_resolve(Sent, {ok, undefined}),
    {ok, wasm_component:host_new(
           p3_http_response,
           #{status => Status, headers => Headers, body => {some, feed(Body)},
             trailers => no_trailers(), sent => undefined})};
response({error, E}, Sent) ->
    _ = wasm_async:host_future_resolve(Sent, {error, E}),
    {error, E}.

%%% --------------------------------------------------------------- serve ---

-doc """
An incoming request for a 0.3 handler: `Request` as for
`wasi_preview2:run_serve/3`, the body fed to the guest as a stream, and its
`trailers`, a header list (none by default), resolving the request's trailers
future.
""".
-spec incoming_request(map()) -> non_neg_integer().
incoming_request(Request) ->
    #{method := Method, path := Path} = Request,
    Scheme = case maps:get(scheme, Request, ~"http") of
                 ~"https" -> {~"HTTPS", undefined};
                 _ -> {~"HTTP", undefined}
             end,
    wasm_component:host_new(
      p3_http_request,
      #{method => method_variant(Method), path => {some, Path},
        scheme => {some, Scheme},
        authority => {some, maps:get(authority, Request, ~"localhost")},
        %% A header the guest may not set (host, connection and the like) does
        %% not reach it either, so it cannot be forwarded on.
        headers => [{N, V} || {N, V} <- maps:get(headers, Request, []),
                              not forbidden(N, V)],
        %% Made into a stream and a future when the guest consumes the body,
        %% inside its task: a stream made before the task starts is cleared
        %% when the task's frame opens.
        body => {bytes, maps:get(body, Request, <<>>)},
        trailers => {fields, [{N, V} || {N, V} <- maps:get(trailers, Request, []),
                                        not forbidden(N, V)]},
        options => none, sent => undefined}).

forbidden(N, V) ->
    case wasi_http:field_error(N, V) of
        {~"forbidden", _} -> true;
        _ -> false
    end.

method_variant(M) ->
    L = string:lowercase(M),
    case lists:member(L, ?METHODS) of
        true -> {L, undefined};
        false -> {~"other", M}
    end.

-doc """
The status, headers, whole body and trailers of the response a handler
returned, running its task while it writes the body and then resolves the
trailers. A response without trailers answers the 4-tuple.
""".
-spec take_response(non_neg_integer(), pos_integer()) ->
          {ok, non_neg_integer(), [{binary(), binary()}], binary()} |
          {ok, non_neg_integer(), [{binary(), binary()}], binary(),
           [{binary(), binary()}]} |
          {error, term()}.
take_response(R, MaxBody) ->
    case message(R) of
        {p3_http_response, #{status := Status, headers := Headers, body := Body,
                             trailers := Trailers, sent := Sent}} ->
            case read_body(Body, MaxBody) of
                {ok, Bin} ->
                    case read_trailers(Trailers) of
                        {ok, Ts} ->
                            _ = Sent =/= undefined andalso
                                wasm_async:host_future_resolve(Sent, {ok, undefined}),
                            case Ts of
                                [] -> {ok, Status, Headers, Bin};
                                _ -> {ok, Status, Headers, Bin, Ts}
                            end;
                        {error, _} = E -> E
                    end;
                {error, _} = E -> E
            end;
        _ -> {error, not_a_response}
    end.

%% The response's trailers, once the guest resolves their future: a future it
%% dropped unresolved is no trailers, an error ends the response with it.
read_trailers(T) ->
    ok = wasm_async:host_reader(T),
    case wasm_async:host_future_await(T, 60000) of
        {ok, {ok, none}} -> {ok, []};
        {ok, {ok, {some, H}}} ->
            Es = entries(H),
            _ = wasm_component:host_drop(H),
            {ok, Es};
        {ok, {error, E}} -> {error, E};
        {error, dropped} -> {ok, []};
        {error, _} = E -> E
    end.

read_body(none, _MaxBody) -> {ok, <<>>};
read_body({some, S}, MaxBody) ->
    ok = wasm_async:host_reader(S),
    read_all(S, <<>>, MaxBody).

%% A served response body is read whole before it is answered, so it is held
%% by the host: past `MaxBody' the reading stops and the request fails.
read_all(S, Acc, MaxBody) ->
    case wasm_async:host_read(S, 65536, 60000) of
        {ok, B} when byte_size(Acc) + byte_size(B) > MaxBody ->
            {error, {~"HTTP-response-body-size",
                     {some, byte_size(Acc) + byte_size(B)}}};
        {ok, B} -> read_all(S, <<Acc/binary, B/binary>>, MaxBody);
        eof -> {ok, Acc};
        {error, _} = E -> E
    end.
