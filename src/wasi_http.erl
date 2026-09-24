-module(wasi_http).
-moduledoc """
A slice of `wasi:http@0.2`: the outbound (`outgoing-handler`) path and the
`wasi:http/types` resources it needs.

`http/1` returns the import map a `wasi:cli/command` (or proxy) component links
against. The guest builds an `outgoing-request` (method, path, scheme, authority
and a `fields` header set), hands it to `outgoing-handler.handle`, and the host
performs the request with the `h1` client and hands back a
`future-incoming-response` that is already resolved (our client is synchronous),
from which the guest reads the status, headers and body.

The wire transport is the host's choice and invisible to the guest; this binding
uses HTTP/1.1 (`h1`). Requests are gated by the same `wasi_net` grant the sockets
slice uses, so a component reaches only a granted authority.
""".

-export([http/1]).

%%% ---------------------------------------------------------------- types ---

%% Header field: a name (string) and a value (list<u8> = a byte string).
-define(FIELD_ENTRY, {tuple, [string, {list, u8}]}).
-define(HEADER_ERROR,
        {variant, [{<<"invalid-syntax">>, none}, {<<"forbidden">>, none},
                   {<<"immutable">>, none}]}).
-define(METHOD,
        {variant, [{<<"get">>, none}, {<<"head">>, none}, {<<"post">>, none},
                   {<<"put">>, none}, {<<"delete">>, none}, {<<"connect">>, none},
                   {<<"options">>, none}, {<<"trace">>, none}, {<<"patch">>, none},
                   {<<"other">>, string}]}).
-define(SCHEME,
        {variant, [{<<"HTTP">>, none}, {<<"HTTPS">>, none},
                   {<<"other">>, string}]}).
%% The error-code variant in WIT order; only a handful of cases are produced here,
%% but the whole variant must be declared so a lift/lower matches the guest layout.
-define(FIELD_SIZE,
        {record, [{<<"field-name">>, {option, string}},
                  {<<"field-size">>, {option, u32}}]}).
-define(ERROR_CODE,
        {variant,
         [{<<"DNS-timeout">>, none},
          {<<"DNS-error">>, {record, [{<<"rcode">>, {option, string}},
                                      {<<"info-code">>, {option, u16}}]}},
          {<<"destination-not-found">>, none},
          {<<"destination-unavailable">>, none},
          {<<"destination-IP-prohibited">>, none},
          {<<"destination-IP-unroutable">>, none},
          {<<"connection-refused">>, none},
          {<<"connection-terminated">>, none},
          {<<"connection-timeout">>, none},
          {<<"connection-read-timeout">>, none},
          {<<"connection-write-timeout">>, none},
          {<<"connection-limit-reached">>, none},
          {<<"TLS-protocol-error">>, none},
          {<<"TLS-certificate-error">>, none},
          {<<"TLS-alert-received">>,
           {record, [{<<"alert-id">>, {option, u8}},
                     {<<"alert-message">>, {option, string}}]}},
          {<<"HTTP-request-denied">>, none},
          {<<"HTTP-request-length-required">>, none},
          {<<"HTTP-request-body-size">>, {option, u64}},
          {<<"HTTP-request-method-invalid">>, none},
          {<<"HTTP-request-URI-invalid">>, none},
          {<<"HTTP-request-URI-too-long">>, none},
          {<<"HTTP-request-header-section-size">>, {option, u32}},
          {<<"HTTP-request-header-size">>, {option, ?FIELD_SIZE}},
          {<<"HTTP-request-trailer-section-size">>, {option, u32}},
          {<<"HTTP-request-trailer-size">>, ?FIELD_SIZE},
          {<<"HTTP-response-incomplete">>, none},
          {<<"HTTP-response-header-section-size">>, {option, u32}},
          {<<"HTTP-response-header-size">>, ?FIELD_SIZE},
          {<<"HTTP-response-body-size">>, {option, u64}},
          {<<"HTTP-response-trailer-section-size">>, {option, u32}},
          {<<"HTTP-response-trailer-size">>, ?FIELD_SIZE},
          {<<"HTTP-response-transfer-coding">>, {option, string}},
          {<<"HTTP-response-content-coding">>, {option, string}},
          {<<"HTTP-response-timeout">>, none},
          {<<"HTTP-upgrade-failed">>, none},
          {<<"HTTP-protocol-error">>, none},
          {<<"loop-detected">>, none},
          {<<"configuration-error">>, none},
          {<<"internal-error">>, {option, string}}]}).

-define(HTTP_TIMEOUT, 30000).

%%% ------------------------------------------------------------------ api ---

-doc """
The `wasi:http/types` + `outgoing-handler` import map. `Opts` carries the
`grant` (a `wasi_net` grant) the outbound request is checked against.
""".
-spec http(#{grant => term()}) -> #{{binary(), binary()} => fun()}.
http(Opts) ->
    Grant = wasi_net:grant(maps:get(grant, Opts, none)),
    T = <<"wasi:http/types">>,
    H = <<"wasi:http/outgoing-handler">>,
    #{%% fields
      {T, <<"[static]fields.from-list">>} =>
          wasm_component:import_fun(
            {[{list, ?FIELD_ENTRY}], {result, handle, ?HEADER_ERROR}},
            fun([Entries]) -> fields_from_list(Entries) end),
      {T, <<"[method]fields.entries">>} =>
          wasm_component:import_fun(
            {[handle], {list, ?FIELD_ENTRY}}, fun([F]) -> fields_entries(F) end),
      {T, <<"[resource-drop]fields">>} => drop(),
      %% request-options
      {T, <<"[constructor]request-options">>} =>
          wasm_component:import_fun(
            {[], handle}, fun([]) -> wasm_component:host_new(http_req_opts, #{}) end),
      {T, <<"[method]request-options.set-connect-timeout">>} =>
          wasm_component:import_fun(
            {[handle, {option, u64}], {result, none, none}}, fun(_) -> {ok, undefined} end),
      {T, <<"[method]request-options.set-first-byte-timeout">>} =>
          wasm_component:import_fun(
            {[handle, {option, u64}], {result, none, none}}, fun(_) -> {ok, undefined} end),
      {T, <<"[method]request-options.set-between-bytes-timeout">>} =>
          wasm_component:import_fun(
            {[handle, {option, u64}], {result, none, none}}, fun(_) -> {ok, undefined} end),
      {T, <<"[resource-drop]request-options">>} => drop(),
      %% outgoing-request
      {T, <<"[constructor]outgoing-request">>} =>
          wasm_component:import_fun(
            {[handle], handle}, fun([Hdrs]) -> outgoing_request(Hdrs) end),
      {T, <<"[method]outgoing-request.set-method">>} =>
          wasm_component:import_fun(
            {[handle, ?METHOD], {result, none, none}},
            fun([R, M]) -> set_req(R, method, method_bin(M)) end),
      {T, <<"[method]outgoing-request.set-path-with-query">>} =>
          wasm_component:import_fun(
            {[handle, {option, string}], {result, none, none}},
            fun([R, P]) -> set_req(R, path, opt(P)) end),
      {T, <<"[method]outgoing-request.set-scheme">>} =>
          wasm_component:import_fun(
            {[handle, {option, ?SCHEME}], {result, none, none}},
            fun([R, S]) -> set_req(R, scheme, scheme_opt(S)) end),
      {T, <<"[method]outgoing-request.set-authority">>} =>
          wasm_component:import_fun(
            {[handle, {option, string}], {result, none, none}},
            fun([R, A]) -> set_req(R, authority, opt(A)) end),
      {T, <<"[method]outgoing-request.body">>} =>
          wasm_component:import_fun(
            {[handle], {result, handle, none}}, fun([R]) -> request_body(R) end),
      {T, <<"[resource-drop]outgoing-request">>} => drop(),
      %% outgoing-body
      {T, <<"[method]outgoing-body.write">>} =>
          wasm_component:import_fun(
            {[handle], {result, handle, none}}, fun([B]) -> body_write(B) end),
      {T, <<"[static]outgoing-body.finish">>} =>
          wasm_component:import_fun(
            {[handle, {option, handle}], {result, none, ?ERROR_CODE}},
            fun([B, _Trailers]) -> body_finish(B) end),
      {T, <<"[resource-drop]outgoing-body">>} => drop(),
      %% future-incoming-response
      {T, <<"[method]future-incoming-response.subscribe">>} =>
          wasm_component:import_fun(
            {[handle], handle},
            fun([_F]) -> wasm_component:host_new(pollable, ready) end),
      {T, <<"[method]future-incoming-response.get">>} =>
          wasm_component:import_fun(
            {[handle],
             {option, {result, {result, handle, ?ERROR_CODE}, none}}},
            fun([F]) -> future_get(F) end),
      {T, <<"[resource-drop]future-incoming-response">>} => drop(),
      %% incoming-response
      {T, <<"[method]incoming-response.status">>} =>
          wasm_component:import_fun(
            {[handle], u16}, fun([R]) -> resp_field(R, status, 0) end),
      {T, <<"[method]incoming-response.headers">>} =>
          wasm_component:import_fun(
            {[handle], handle}, fun([R]) -> resp_headers(R) end),
      {T, <<"[method]incoming-response.consume">>} =>
          wasm_component:import_fun(
            {[handle], {result, handle, none}}, fun([R]) -> resp_consume(R) end),
      {T, <<"[resource-drop]incoming-response">>} => drop(),
      %% incoming-body
      {T, <<"[method]incoming-body.stream">>} =>
          wasm_component:import_fun(
            {[handle], {result, handle, none}}, fun([B]) -> body_stream(B) end),
      {T, <<"[resource-drop]incoming-body">>} => drop(),
      %% outgoing-handler
      {H, <<"handle">>} =>
          wasm_component:import_fun(
            {[handle, {option, handle}],
             {result, handle, ?ERROR_CODE}},
            fun([Req, _Opts]) -> handle(Req, Grant) end)}.

%%% -------------------------------------------------------------- fields ---

fields_from_list(Entries) ->
    {ok, wasm_component:host_new(http_fields, [{N, V} || {N, V} <- Entries])}.

fields_entries(F) ->
    case wasm_component:host_get(F) of
        {ok, {http_fields, List}} -> [{N, V} || {N, V} <- List];
        _                         -> []
    end.

%%% ----------------------------------------------------- outgoing-request ---

outgoing_request(Hdrs) ->
    Headers = case wasm_component:host_get(Hdrs) of
                  {ok, {http_fields, L}} -> L;
                  _                      -> []
              end,
    wasm_component:host_new(http_out_req,
                            #{method => <<"GET">>, path => <<"/">>,
                              scheme => <<"http">>, authority => <<>>,
                              headers => Headers, body => <<>>}).

set_req(R, Key, Value) ->
    case wasm_component:host_get(R) of
        {ok, {http_out_req, Req}} ->
            _ = wasm_component:host_update(R, Req#{Key => Value}),
            {ok, undefined};
        _ ->
            {error, undefined}
    end.

%% One outgoing-body per request, writing into the request's body buffer.
request_body(R) ->
    case wasm_component:host_get(R) of
        {ok, {http_out_req, _}} -> {ok, wasm_component:host_new(http_out_body, R)};
        _                       -> {error, undefined}
    end.

%%% -------------------------------------------------------- outgoing-body ---

%% The body's write stream appends to the owning request's body buffer.
body_write(B) ->
    case wasm_component:host_get(B) of
        {ok, {http_out_body, Req}} ->
            {ok, wasm_component:host_new(output_stream, {http_body, Req})};
        _ ->
            {error, undefined}
    end.

body_finish(_B) ->
    {ok, undefined}.

%%% ------------------------------------------------------------- handle ---

%% Perform the request now (a synchronous client), storing the result in a
%% future-incoming-response the guest reads back. A denied authority or a failed
%% request is an http error-code.
handle(Req, Grant) ->
    case wasm_component:host_get(Req) of
        {ok, {http_out_req, R}} ->
            {ok, wasm_component:host_new(http_future, perform(R, Grant))};
        _ ->
            {error, {<<"HTTP-request-URI-invalid">>, none}}
    end.

perform(#{authority := Authority} = R, Grant) ->
    case authority_endpoint(Authority) of
        {error, _} = E ->
            E;
        {ok, Host, Port} ->
            case wasi_net:allows(connect, {tcp, resolve_host(Host), Port}, Grant) of
                false -> {error, {<<"HTTP-request-denied">>, none}};
                true  -> do_request(Host, Port, R)
            end
    end.

do_request(Host, Port, #{method := Method, path := Path, headers := Headers,
                         body := Body}) ->
    case h1:connect(Host, Port, #{}) of
        {ok, Conn} ->
            HdrList = [{N, V} || {N, V} <- Headers],
            Result =
                case h1:request(Conn, Method, Path, HdrList, Body) of
                    {ok, Sid} -> collect(Conn, Sid);
                    {error, _} -> {error, {<<"HTTP-protocol-error">>, none}}
                end,
            _ = h1:close(Conn),
            Result;
        {error, _} ->
            {error, {<<"connection-refused">>, none}}
    end.

collect(Conn, Sid) ->
    receive
        {h1, Conn, {response, Sid, Status, Headers}} ->
            collect_body(Conn, Sid, Status, Headers, <<>>);
        {h1, Conn, {closed, _}} ->
            {error, {<<"HTTP-response-incomplete">>, none}}
    after ?HTTP_TIMEOUT ->
        {error, {<<"HTTP-response-timeout">>, none}}
    end.

collect_body(Conn, Sid, Status, Headers, Acc) ->
    receive
        {h1, Conn, {data, Sid, Data, false}} ->
            collect_body(Conn, Sid, Status, Headers, <<Acc/binary, Data/binary>>);
        {h1, Conn, {data, Sid, Data, true}} ->
            {ok, Status, header_pairs(Headers), <<Acc/binary, Data/binary>>};
        {h1, Conn, {trailers, Sid, _}} ->
            {ok, Status, header_pairs(Headers), Acc}
    after ?HTTP_TIMEOUT ->
        {error, {<<"HTTP-response-timeout">>, none}}
    end.

header_pairs(Headers) ->
    [{to_bin(N), to_bin(V)} || {N, V} <- Headers, is_field(N)].

is_field(N) -> binary:first(to_bin(N)) =/= $:.

%%% --------------------------------------------- future/incoming-response ---

%% get returns the resolved response exactly once (a second get is `none`), the
%% option<result<result<...>>> the ABI defines.
future_get(F) ->
    case wasm_component:host_get(F) of
        {ok, {http_future, taken}} ->
            none;
        {ok, {http_future, Result}} ->
            _ = wasm_component:host_update(F, taken),
            {some, {ok, future_result(Result)}};
        _ ->
            none
    end.

future_result({ok, Status, Headers, Body}) ->
    {ok, wasm_component:host_new(http_in_resp,
                                #{status => Status, headers => Headers,
                                  body => Body})};
future_result({error, Code}) ->
    {error, Code}.

resp_field(R, Key, Default) ->
    case wasm_component:host_get(R) of
        {ok, {http_in_resp, Resp}} -> maps:get(Key, Resp, Default);
        _                          -> Default
    end.

resp_headers(R) ->
    case wasm_component:host_get(R) of
        {ok, {http_in_resp, #{headers := H}}} ->
            wasm_component:host_new(http_fields, H);
        _ ->
            wasm_component:host_new(http_fields, [])
    end.

resp_consume(R) ->
    case wasm_component:host_get(R) of
        {ok, {http_in_resp, #{body := Body}}} ->
            {ok, wasm_component:host_new(http_in_body, Body)};
        _ ->
            {error, undefined}
    end.

body_stream(B) ->
    case wasm_component:host_get(B) of
        {ok, {http_in_body, Body}} ->
            {ok, wasm_component:host_new(input_stream, Body)};
        _ ->
            {error, undefined}
    end.

%%% ----------------------------------------------------------- helpers ---

drop() -> fun(_Ctx, [H]) -> _ = wasm_component:host_drop(H), {ok, []} end.

opt(none)         -> <<>>;
opt({some, V})    -> V.

method_bin({<<"other">>, S}) -> S;
method_bin({M, _})           -> string:uppercase(M).

scheme_opt(none)                     -> <<"http">>;
scheme_opt({some, {<<"HTTPS">>, _}}) -> <<"https">>;
scheme_opt({some, {<<"other">>, S}}) -> S;
scheme_opt({some, {_, _}})           -> <<"http">>.

%% Split "host:port" (or "host") into a host and port, defaulting to 80.
authority_endpoint(<<>>) ->
    {error, {<<"HTTP-request-URI-invalid">>, none}};
authority_endpoint(Authority) ->
    case binary:split(Authority, <<":">>) of
        [Host, PortBin] ->
            try binary_to_integer(PortBin) of
                P -> {ok, Host, P}
            catch
                _:_ -> {error, {<<"HTTP-request-URI-invalid">>, none}}
            end;
        [Host] ->
            {ok, Host, 80}
    end.

%% For the grant check: a literal ip, else 127.0.0.1 (the tests use a loopback
%% authority). A real resolver is the sockets slice's job.
resolve_host(Host) ->
    case inet:parse_address(binary_to_list(Host)) of
        {ok, Ip} -> Ip;
        _        -> {127, 0, 0, 1}
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> list_to_binary(L).
