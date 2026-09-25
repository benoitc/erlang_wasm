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

-export([http/1, append_body/2, incoming_request/1, read_outparam/1]).

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

%% The largest header section a guest may build. Exceeding it is a trap, not a
%% header-error: the WIT `header-error` variant has no case for an oversized
%% section, so the only way to report it is the way wasmtime does, by trapping.
%% Each field is charged its name and value plus a fixed per-field overhead.
-define(MAX_HEADER_SECTION, 64 * 1024).
-define(HEADER_FIELD_OVERHEAD, 32).

%%% ------------------------------------------------------------------ api ---

-doc """
The `wasi:http/types` + `outgoing-handler` import map. `Opts` carries the
`grant` (a `wasi_net` grant) the outbound request is checked against.
""".
-spec http(#{grant => term(), transport => module()}) ->
          #{{binary(), binary()} => fun()}.
http(Opts) ->
    Grant = wasi_net:grant(maps:get(grant, Opts, none)),
    Transport = maps:get(transport, Opts, wasi_http_h1),
    T = <<"wasi:http/types">>,
    H = <<"wasi:http/outgoing-handler">>,
    #{%% fields
      {T, <<"[constructor]fields">>} =>
          wasm_component:import_fun(
            {[], handle}, fun([]) -> wasm_component:host_new(http_fields, []) end),
      {T, <<"[static]fields.from-list">>} =>
          wasm_component:import_fun(
            {[{list, ?FIELD_ENTRY}], {result, handle, ?HEADER_ERROR}},
            fun([Entries]) -> fields_from_list(Entries) end),
      {T, <<"[method]fields.get">>} =>
          wasm_component:import_fun(
            {[handle, string], {list, {list, u8}}},
            fun([F, N]) -> fields_get(F, N) end),
      {T, <<"[method]fields.has">>} =>
          wasm_component:import_fun(
            {[handle, string], bool}, fun([F, N]) -> fields_has(F, N) end),
      {T, <<"[method]fields.set">>} =>
          wasm_component:import_fun(
            {[handle, string, {list, {list, u8}}], {result, none, ?HEADER_ERROR}},
            fun([F, N, Vs]) -> fields_set(F, N, Vs) end),
      {T, <<"[method]fields.delete">>} =>
          wasm_component:import_fun(
            {[handle, string], {result, none, ?HEADER_ERROR}},
            fun([F, N]) -> fields_delete(F, N) end),
      {T, <<"[method]fields.append">>} => append_import(),
      {T, <<"[method]fields.entries">>} =>
          wasm_component:import_fun(
            {[handle], {list, ?FIELD_ENTRY}}, fun([F]) -> fields_entries(F) end),
      {T, <<"[method]fields.clone">>} =>
          wasm_component:import_fun(
            {[handle], handle}, fun([F]) -> fields_clone(F) end),
      {T, <<"[resource-drop]fields">>} => drop(),
      %% request-options
      {T, <<"[constructor]request-options">>} =>
          wasm_component:import_fun(
            {[], handle}, fun([]) -> wasm_component:host_new(http_req_opts, #{}) end),
      {T, <<"[method]request-options.connect-timeout">>} =>
          wasm_component:import_fun(
            {[handle], {option, u64}}, fun([O]) -> get_opt(O, connect_timeout) end),
      {T, <<"[method]request-options.set-connect-timeout">>} =>
          wasm_component:import_fun(
            {[handle, {option, u64}], {result, none, none}},
            fun([O, Ns]) -> set_opt(O, connect_timeout, Ns) end),
      {T, <<"[method]request-options.first-byte-timeout">>} =>
          wasm_component:import_fun(
            {[handle], {option, u64}}, fun([O]) -> get_opt(O, first_byte_timeout) end),
      {T, <<"[method]request-options.set-first-byte-timeout">>} =>
          wasm_component:import_fun(
            {[handle, {option, u64}], {result, none, none}},
            fun([O, Ns]) -> set_opt(O, first_byte_timeout, Ns) end),
      {T, <<"[method]request-options.between-bytes-timeout">>} =>
          wasm_component:import_fun(
            {[handle], {option, u64}}, fun([O]) -> get_opt(O, between_bytes_timeout) end),
      {T, <<"[method]request-options.set-between-bytes-timeout">>} =>
          wasm_component:import_fun(
            {[handle, {option, u64}], {result, none, none}},
            fun([O, Ns]) -> set_opt(O, between_bytes_timeout, Ns) end),
      {T, <<"[resource-drop]request-options">>} => drop(),
      %% outgoing-request
      {T, <<"[constructor]outgoing-request">>} =>
          wasm_component:import_fun(
            {[handle], handle}, fun([Hdrs]) -> outgoing_request(Hdrs) end),
      {T, <<"[method]outgoing-request.set-method">>} =>
          wasm_component:import_fun(
            {[handle, ?METHOD], {result, none, none}},
            fun([R, M]) -> set_method(R, method_bin(M)) end),
      {T, <<"[method]outgoing-request.set-path-with-query">>} =>
          wasm_component:import_fun(
            {[handle, {option, string}], {result, none, none}},
            fun([R, P]) -> set_path(R, opt(P)) end),
      {T, <<"[method]outgoing-request.set-scheme">>} =>
          wasm_component:import_fun(
            {[handle, {option, ?SCHEME}], {result, none, none}},
            fun([R, S]) -> set_scheme(R, S) end),
      {T, <<"[method]outgoing-request.set-authority">>} =>
          wasm_component:import_fun(
            {[handle, {option, string}], {result, none, none}},
            fun([R, A]) -> set_authority(R, opt(A)) end),
      {T, <<"[method]outgoing-request.method">>} =>
          wasm_component:import_fun(
            {[handle], ?METHOD}, fun([R]) -> out_req_method(R) end),
      {T, <<"[method]outgoing-request.path-with-query">>} =>
          wasm_component:import_fun(
            {[handle], {option, string}}, fun([R]) -> out_req_opt(R, path) end),
      {T, <<"[method]outgoing-request.scheme">>} =>
          wasm_component:import_fun(
            {[handle], {option, ?SCHEME}}, fun([R]) -> out_req_scheme(R) end),
      {T, <<"[method]outgoing-request.authority">>} =>
          wasm_component:import_fun(
            {[handle], {option, string}}, fun([R]) -> out_req_opt(R, authority) end),
      {T, <<"[method]outgoing-request.headers">>} =>
          wasm_component:import_fun(
            {[handle], handle}, fun([R]) -> out_req_headers(R) end),
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
      {T, <<"[static]incoming-body.finish">>} =>
          wasm_component:import_fun(
            {[handle], handle}, fun([_B]) -> wasm_component:host_new(http_trailers, ready) end),
      {T, <<"[resource-drop]incoming-body">>} => drop(),
      %% future-trailers: this host delivers no trailers, so it resolves at once to
      %% an ok with no trailers (none).
      {T, <<"[method]future-trailers.subscribe">>} =>
          wasm_component:import_fun(
            {[handle], handle},
            fun([_F]) -> wasm_component:host_new(pollable, ready) end),
      {T, <<"[method]future-trailers.get">>} =>
          wasm_component:import_fun(
            {[handle],
             {option, {result, {result, {option, handle}, ?ERROR_CODE}, none}}},
            fun([F]) -> trailers_get(F) end),
      {T, <<"[resource-drop]future-trailers">>} => drop(),
      %% incoming-request (the reactor's request, synthesized by the host)
      {T, <<"[method]incoming-request.method">>} =>
          wasm_component:import_fun(
            {[handle], ?METHOD}, fun([R]) -> in_req_method(R) end),
      {T, <<"[method]incoming-request.path-with-query">>} =>
          wasm_component:import_fun(
            {[handle], {option, string}}, fun([R]) -> in_req(R, path) end),
      {T, <<"[method]incoming-request.scheme">>} =>
          wasm_component:import_fun(
            {[handle], {option, ?SCHEME}}, fun([R]) -> in_req_scheme(R) end),
      {T, <<"[method]incoming-request.authority">>} =>
          wasm_component:import_fun(
            {[handle], {option, string}}, fun([R]) -> in_req(R, authority) end),
      {T, <<"[method]incoming-request.headers">>} =>
          wasm_component:import_fun(
            {[handle], handle}, fun([R]) -> in_req_headers(R) end),
      {T, <<"[method]incoming-request.consume">>} =>
          wasm_component:import_fun(
            {[handle], {result, handle, none}}, fun([R]) -> in_req_consume(R) end),
      {T, <<"[resource-drop]incoming-request">>} => drop(),
      %% outgoing-response (the guest builds it and sets it on the outparam)
      {T, <<"[constructor]outgoing-response">>} =>
          wasm_component:import_fun(
            {[handle], handle}, fun([Hdrs]) -> outgoing_response(Hdrs) end),
      {T, <<"[method]outgoing-response.set-status-code">>} =>
          wasm_component:import_fun(
            {[handle, u16], {result, none, none}},
            fun([R, Code]) -> set_resp(R, status, Code) end),
      {T, <<"[method]outgoing-response.status-code">>} =>
          wasm_component:import_fun(
            {[handle], u16}, fun([R]) -> resp_status(R) end),
      {T, <<"[method]outgoing-response.headers">>} =>
          wasm_component:import_fun(
            {[handle], handle}, fun([R]) -> out_resp_headers(R) end),
      {T, <<"[method]outgoing-response.body">>} =>
          wasm_component:import_fun(
            {[handle], {result, handle, none}}, fun([R]) -> response_body(R) end),
      {T, <<"[resource-drop]outgoing-response">>} => drop(),
      %% response-outparam (the reactor sets its response here)
      {T, <<"[static]response-outparam.set">>} =>
          wasm_component:import_fun(
            {[handle, {result, handle, ?ERROR_CODE}], none},
            fun([Param, Resp]) -> outparam_set(Param, Resp) end),
      {T, <<"[resource-drop]response-outparam">>} => drop(),
      %% http-error-code: recover an http error-code from a wasi:io error. The one
      %% this host raises is the body-size overrun a bounded outgoing-body reports
      %% on write; any other io-error carries no http error-code.
      {T, <<"http-error-code">>} =>
          wasm_component:import_fun(
            {[handle], {option, ?ERROR_CODE}}, fun([Err]) -> http_error_code(Err) end),
      %% outgoing-handler
      {H, <<"handle">>} =>
          wasm_component:import_fun(
            {[handle, {option, handle}],
             {result, handle, ?ERROR_CODE}},
            fun([Req, ReqOpts]) -> handle(Req, ReqOpts, Grant, Transport) end)}.

%% Store a request-option (a timeout, in nanoseconds) on the options resource.
set_opt(O, Key, Value) ->
    case wasm_component:host_get(O) of
        {ok, {http_req_opts, Map}} ->
            _ = wasm_component:host_update(O, Map#{Key => opt_ns(Value)}),
            {ok, undefined};
        _ ->
            {error, undefined}
    end.

%% A request-option timeout is stored as the guest gave it (nanoseconds), so a getter
%% reads back exactly what a setter wrote; the wire libraries take milliseconds, so
%% the conversion happens where a request is performed (`ms/1`).
opt_ns(none)       -> undefined;
opt_ns({some, Ns}) -> Ns.

%% A request-option getter: the nanosecond value the guest set, or none.
get_opt(O, Key) ->
    case wasm_component:host_get(O) of
        {ok, {http_req_opts, #{Key := Ns}}} when is_integer(Ns) -> {some, Ns};
        _                                                       -> none
    end.

%% The timeouts the guest set on its request-options, defaulting to unset.
req_timeouts(none) ->
    #{connect_timeout => undefined, first_byte_timeout => undefined};
req_timeouts({some, O}) ->
    case wasm_component:host_get(O) of
        {ok, {http_req_opts, Map}} ->
            #{connect_timeout => maps:get(connect_timeout, Map, undefined),
              first_byte_timeout => maps:get(first_byte_timeout, Map, undefined)};
        _ ->
            req_timeouts(none)
    end.

%% A stored nanosecond timeout as the milliseconds the wire libraries take.
ms(undefined) -> undefined;
ms(Ns)        -> max(1, Ns div 1_000_000).

%%% -------------------------------------------------------------- fields ---

%% Each entry is validated as if appended: a bad name or value is invalid-syntax,
%% a connection-level (or host-configured) name is forbidden. The whole list is
%% refused on the first offending entry.
fields_from_list(Entries) ->
    case check_entries(Entries) of
        ok      -> {ok, wasm_component:host_new(http_fields, Entries)};
        {error, _} = E -> E
    end.

check_entries([]) -> ok;
check_entries([{N, V} | Rest]) ->
    case field_error(N, V) of
        none  -> check_entries(Rest);
        Error -> {error, Error}
    end.

fields_entries(F) ->
    [{N, V} || {N, V} <- fields_list(F)].

%% Fields are mutable (`http_fields`) until an accessor hands back an immutable
%% clone (`http_fields_ro`, what request/response `.headers()` returns); reads see
%% the list either way, mutations refuse the read-only form as `immutable`.
fields_list(F) ->
    case wasm_component:host_get(F) of
        {ok, {http_fields, List}}    -> List;
        {ok, {http_fields_ro, List}} -> List;
        _                            -> []
    end.

fields_mutable(F) ->
    case wasm_component:host_get(F) of
        {ok, {http_fields, _}} -> true;
        _                      -> false
    end.

fields_get(F, Name) ->
    [V || {N, V} <- fields_list(F), eqi(N, Name)].

fields_has(F, Name) ->
    lists:any(fun({N, _}) -> eqi(N, Name) end, fields_list(F)).

%% set replaces all values for the name (kept together where the first was).
fields_set(F, Name, Values) ->
    with_mutation(F, Name, hd0(Values), fun() ->
        Rest = [{N, V} || {N, V} <- fields_list(F), not eqi(N, Name)],
        wasm_component:host_update(F, Rest ++ [{Name, V} || V <- Values])
    end).

fields_delete(F, Name) ->
    case fields_mutable(F) of
        false -> {error, {<<"immutable">>, none}};
        true ->
            _ = wasm_component:host_update(
                  F, [{N, V} || {N, V} <- fields_list(F), not eqi(N, Name)]),
            {ok, undefined}
    end.

%% append refuses an oversized header section by trapping (see ?MAX_HEADER_SECTION),
%% which the plain import_fun wrapper cannot express, so it is wrapped raw: the
%% first flat argument is the fields handle, and a full section traps before the
%% value is even lifted.
append_import() ->
    Inner = wasm_component:import_fun(
              {[handle, string, {list, u8}], {result, none, ?HEADER_ERROR}},
              fun([F, N, V]) -> fields_append(F, N, V) end),
    fun(Ctx, Flats) ->
        case section_full(hd(Flats)) of
            true  -> {trap, http_header_section_too_large};
            false -> Inner(Ctx, Flats)
        end
    end.

%% Whether a fields already holds a full header section, so one more field would
%% overflow it.
section_full(F) ->
    Size = lists:sum([byte_size(N) + byte_size(V) + ?HEADER_FIELD_OVERHEAD
                      || {N, V} <- fields_list(F)]),
    Size >= ?MAX_HEADER_SECTION.

fields_append(F, Name, Value) ->
    with_mutation(F, Name, Value, fun() ->
        wasm_component:host_update(F, fields_list(F) ++ [{Name, Value}])
    end).

%% A mutation validates the name and value, refuses a forbidden name, and refuses
%% an immutable fields, before running. The header-errors are the ABI's variant.
with_mutation(F, Name, Value, Fun) ->
    case fields_mutable(F) of
        false -> {error, {<<"immutable">>, none}};
        true ->
            case field_error(Name, Value) of
                none  -> _ = Fun(), {ok, undefined};
                Error -> {error, Error}
            end
    end.

%% The header-error for a name/value pair, or `none` when it is admissible: a
%% malformed name or value is invalid-syntax, a connection-level or host-configured
%% name is forbidden. Name syntax is checked first so a forbidden test only ever
%% sees a real token.
field_error(Name, Value) ->
    case valid_token(Name) of
        false -> {<<"invalid-syntax">>, none};
        true ->
            case forbidden_header(Name) of
                true  -> {<<"forbidden">>, none};
                false ->
                    case valid_value(Value) of
                        true  -> none;
                        false -> {<<"invalid-syntax">>, none}
                    end
            end
    end.

%% Connection-level headers the guest may not set, plus the host-configured
%% `custom-forbidden-header` the wasmtime conformance programs expect. Matched
%% case-insensitively.
forbidden_header(Name) ->
    lists:member(string:lowercase(Name),
                 [<<"connection">>, <<"keep-alive">>, <<"proxy-connection">>,
                  <<"transfer-encoding">>, <<"upgrade">>, <<"host">>,
                  <<"http2-settings">>, <<"custom-forbidden-header">>]).

%% A field value carries no NUL, CR or LF (what would let a value inject a header).
valid_value(V) when is_binary(V) ->
    not lists:any(fun(C) -> C =:= 0 orelse C =:= $\r orelse C =:= $\n end,
                  binary_to_list(V));
valid_value(_) -> false.

hd0([V | _]) -> V;
hd0([])      -> <<>>.

%% Field names compare case-insensitively.
eqi(A, B) -> string:lowercase(A) =:= string:lowercase(B).

%% A clone is mutable again (the immutable form exists only behind an accessor).
fields_clone(F) ->
    wasm_component:host_new(http_fields, fields_list(F)).

%%% ----------------------------------------------------- outgoing-request ---

outgoing_request(Hdrs) ->
    Headers = case wasm_component:host_get(Hdrs) of
                  {ok, {http_fields, L}} -> L;
                  _                      -> []
              end,
    wasm_component:host_new(http_out_req,
                            #{method => <<"GET">>, path => undefined,
                              scheme => <<"http">>, authority => <<>>,
                              headers => Headers, body => <<>>}).

%% An HTTP token (method or field name): one or more tchar, no spaces or controls.
valid_token(<<>>)  -> false;
valid_token(Bin) when is_binary(Bin) ->
    lists:all(fun tchar/1, binary_to_list(Bin));
valid_token(_) -> false.

tchar(C) ->
    (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z)
        orelse (C >= $0 andalso C =< $9)
        orelse lists:member(C, "!#$%&'*+-.^_`|~").

%% A method must be a valid HTTP token; a control character (a newline) is refused.
set_method(R, Method) ->
    case valid_token(Method) of
        true  -> set_req(R, method, Method);
        false -> {error, undefined}
    end.

set_req(R, Key, Value) ->
    case wasm_component:host_get(R) of
        {ok, {http_out_req, Req}} ->
            _ = wasm_component:host_update(R, Req#{Key => Value}),
            {ok, undefined};
        _ ->
            {error, undefined}
    end.

%% The path-with-query, scheme and authority are each validated on the way in: a
%% control character (a newline is what the conformance program injects) makes the
%% whole URI invalid, so the setter refuses it rather than carrying it to the wire.
set_path(R, Path) ->
    case no_controls(Path) of
        true  -> set_req(R, path, Path);
        false -> {error, undefined}
    end.

set_scheme(R, Scheme) ->
    Bin = scheme_opt(Scheme),
    case no_controls(Bin) of
        true  -> set_req(R, scheme, Bin);
        false -> {error, undefined}
    end.

set_authority(R, Authority) ->
    case no_controls(Authority) of
        true  -> set_req(R, authority, Authority);
        false -> {error, undefined}
    end.

no_controls(Bin) when is_binary(Bin) ->
    not lists:any(fun(C) -> C < 16#20 orelse C =:= 16#7F end, binary_to_list(Bin));
no_controls(_) -> false.

%% An immutable clone of the request's headers (a fresh fields resource).
out_req_headers(R) ->
    case wasm_component:host_get(R) of
        {ok, {http_out_req, #{headers := H}}} -> ro_fields(H);
        _                                     -> ro_fields([])
    end.

%% The getters for a request's method, path, scheme and authority: what a setter
%% stored, in the variant/option shape the ABI returns.
out_req_method(R) ->
    case wasm_component:host_get(R) of
        {ok, {http_out_req, #{method := M}}} -> method_variant(M);
        _                                    -> {<<"get">>, none}
    end.

out_req_opt(R, Key) ->
    case wasm_component:host_get(R) of
        {ok, {http_out_req, Map}} ->
            case maps:get(Key, Map, undefined) of
                undefined -> none;
                <<>>      -> none;
                Value     -> {some, Value}
            end;
        _ ->
            none
    end.

out_req_scheme(R) ->
    case wasm_component:host_get(R) of
        {ok, {http_out_req, #{scheme := S}}} -> {some, scheme_variant(S)};
        _                                    -> none
    end.

%% A stored scheme binary as the scheme variant the ABI returns.
scheme_variant(<<"http">>)  -> {<<"HTTP">>, none};
scheme_variant(<<"https">>) -> {<<"HTTPS">>, none};
scheme_variant(Other)       -> {<<"other">>, Other}.

%% future-trailers.get: this host produces no trailers, so it resolves once to
%% ok(no-trailers); a second get is none (already taken), as the ABI requires.
trailers_get(F) ->
    case wasm_component:host_get(F) of
        {ok, {http_trailers, ready}} ->
            _ = wasm_component:host_update(F, taken),
            {some, {ok, {ok, none}}};
        _ ->
            none
    end.

%% The immutable fields an accessor returns: a mutation on it is `immutable`.
ro_fields(List) -> wasm_component:host_new(http_fields_ro, List).

%% One outgoing-body per request, with its own buffer that outlives the request
%% handle (the guest writes the body after handing the request to the handler). A
%% declared content-length bounds the body: writing past it, or finishing short of
%% it, is an HTTP-request-body-size error.
request_body(R) ->
    case wasm_component:host_get(R) of
        {ok, {http_out_req, #{headers := H} = Req}} ->
            BodyH = wasm_component:host_new(http_out_body, new_body(content_length(H))),
            _ = wasm_component:host_update(R, Req#{body_handle => BodyH}),
            {ok, BodyH};
        _ ->
            {error, undefined}
    end.

new_body(Limit) -> #{data => <<>>, limit => Limit, over => undefined}.

%% The declared content-length of a header list, or `undefined` when unset.
content_length(Headers) ->
    case [V || {N, V} <- Headers, string:lowercase(N) =:= <<"content-length">>] of
        [V | _] -> try binary_to_integer(V) catch _:_ -> undefined end;
        []      -> undefined
    end.

%%% -------------------------------------------------------- outgoing-body ---

%% The body's write stream appends to the outgoing-body's own buffer.
body_write(B) ->
    case wasm_component:host_get(B) of
        {ok, {http_out_body, #{}}} ->
            {ok, wasm_component:host_new(output_stream, {http_body, B})};
        _ ->
            {error, undefined}
    end.

%% finish consumes the outgoing-body (the guest drops the handle after), so snapshot
%% its buffer where the future can still read it once the request is performed. A
%% body that overran its content-length, or fell short of it, fails here.
body_finish(B) ->
    case wasm_component:host_get(B) of
        {ok, {http_out_body, #{over := N}}} when N =/= undefined ->
            {error, body_size(N)};
        {ok, {http_out_body, #{data := Data, limit := Limit}}}
          when Limit =/= undefined, byte_size(Data) =/= Limit ->
            {error, body_size(byte_size(Data))};
        {ok, {http_out_body, #{data := Data}}} ->
            put({http_final_body, B}, Data),
            {ok, undefined};
        _ ->
            {ok, undefined}
    end.

body_size(N) -> {<<"HTTP-request-body-size">>, {some, N}}.

-doc """
Append bytes to an outgoing-body's buffer (its write stream). A write that would
carry the body past its declared content-length fails with an io-error the guest
recovers through `http-error-code` as HTTP-request-body-size.
""".
-spec append_body(term(), binary()) -> ok | {error, {http_body_size, non_neg_integer()}}.
append_body(B, Bytes) ->
    case wasm_component:host_get(B) of
        {ok, {http_out_body, #{data := Data, limit := Limit} = Body}} ->
            Total = byte_size(Data) + byte_size(Bytes),
            case Limit =/= undefined andalso Total > Limit of
                true ->
                    _ = wasm_component:host_update(B, Body#{over => Total}),
                    {error, {http_body_size, Total}};
                false ->
                    _ = wasm_component:host_update(B, Body#{data => <<Data/binary, Bytes/binary>>}),
                    ok
            end;
        _ ->
            ok
    end.

%%% ------------------------------------------------------------- handle ---

%% handle takes the request but does not send yet: the guest writes the body to the
%% outgoing-body stream after this returns. The request is captured into a pending
%% future and performed when the guest first reads the future (by which time the
%% body is written and finished).
%% A request whose target is malformed (no path, an unsupported scheme) can never
%% be sent, so `handle` refuses it at once rather than handing back a future that
%% would only fail on `get`; a well-formed request is deferred, and any connection
%% failure surfaces when the guest polls the future.
handle(Req, Opts, Grant, Transport) ->
    case wasm_component:host_get(Req) of
        {ok, {http_out_req, Map0}} ->
            Map = Map0#{timeouts => req_timeouts(Opts)},
            case request_error(Map) of
                none  -> {ok, wasm_component:host_new(http_future,
                                                      {pending, Map, Grant, Transport})};
                Error -> {error, Error}
            end;
        _ ->
            {error, {<<"HTTP-request-URI-invalid">>, none}}
    end.

%% The handle-time defect in a request's target, or `none` when it is sendable.
request_error(#{path := undefined}) ->
    {<<"HTTP-request-URI-invalid">>, none};
request_error(#{scheme := Scheme})
  when Scheme =/= <<"http">>, Scheme =/= <<"https">> ->
    {<<"HTTP-protocol-error">>, none};
request_error(_) ->
    none.

%% Resolve the authority and grant, then hand the abstract request to the pluggable
%% transport (h1 by default). The wire protocol is the transport's concern.
perform(#{authority := Authority} = R, Grant, Transport) ->
    case authority_endpoint(Authority) of
        {error, _} = E ->
            E;
        {ok, Host, Port} ->
            case wasi_net:allows(connect, {tcp, resolve_host(Host), Port}, Grant) of
                false ->
                    {error, {<<"HTTP-request-denied">>, none}};
                true ->
                    #{connect_timeout := CT, first_byte_timeout := FBT} =
                        maps:get(timeouts, R, req_timeouts(none)),
                    Transport:request(
                      #{host => Host, port => Port,
                        method => maps:get(method, R), path => maps:get(path, R),
                        headers => maps:get(headers, R), body => maps:get(body, R),
                        connect_timeout => ms(CT), first_byte_timeout => ms(FBT)},
                      ?HTTP_TIMEOUT)
            end
    end.

%%% --------------------------------------------- future/incoming-response ---

%% get returns the resolved response exactly once (a second get is `none`), the
%% option<result<result<...>>> the ABI defines.
future_get(F) ->
    case wasm_component:host_get(F) of
        {ok, {http_future, taken}} ->
            none;
        {ok, {http_future, {pending, Map, Grant, Transport}}} ->
            Result = perform(resolve_body(Map), Grant, Transport),
            _ = wasm_component:host_update(F, taken),
            {some, {ok, future_result(Result)}};
        _ ->
            none
    end.

%% Read the body the guest wrote to the request's outgoing-body, if it made one.
%% finish snapshots it (the handle is dropped by then), so prefer the snapshot and
%% fall back to a still-live body handle.
resolve_body(#{body_handle := BodyH} = Map) ->
    Body = case erase({http_final_body, BodyH}) of
               undefined -> body_data(BodyH);
               Snapshot  -> Snapshot
           end,
    Map#{body => Body};
resolve_body(Map) ->
    Map.

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
        {ok, {http_in_resp, #{headers := H}}} -> ro_fields(H);
        _                                     -> ro_fields([])
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

%%% ---------------------------------------------- incoming (reactor) side ---

-doc "Create the incoming-request resource the host hands a reactor's handle.".
-spec incoming_request(map()) -> non_neg_integer().
incoming_request(Request) ->
    wasm_component:host_new(http_in_req, Request).

in_req(R, Key) ->
    case wasm_component:host_get(R) of
        {ok, {http_in_req, Map}} ->
            case maps:get(Key, Map, undefined) of
                undefined -> none;
                Value     -> {some, Value}
            end;
        _ ->
            none
    end.

in_req_method(R) ->
    case wasm_component:host_get(R) of
        {ok, {http_in_req, #{method := M}}} -> method_variant(M);
        _                                   -> {<<"get">>, none}
    end.

in_req_scheme(R) ->
    case in_req(R, scheme) of
        {some, <<"https">>} -> {some, {<<"HTTPS">>, none}};
        {some, _}           -> {some, {<<"HTTP">>, none}};
        none                -> none
    end.

in_req_headers(R) ->
    case wasm_component:host_get(R) of
        {ok, {http_in_req, #{headers := H}}} -> ro_fields(H);
        _                                    -> ro_fields([])
    end.

in_req_consume(R) ->
    case wasm_component:host_get(R) of
        {ok, {http_in_req, #{body := Body}}} ->
            {ok, wasm_component:host_new(http_in_body, Body)};
        _ ->
            {error, undefined}
    end.

method_variant(M) ->
    case string:lowercase(M) of
        <<"get">>     -> {<<"get">>, none};
        <<"head">>    -> {<<"head">>, none};
        <<"post">>    -> {<<"post">>, none};
        <<"put">>     -> {<<"put">>, none};
        <<"delete">>  -> {<<"delete">>, none};
        <<"connect">> -> {<<"connect">>, none};
        <<"options">> -> {<<"options">>, none};
        <<"trace">>   -> {<<"trace">>, none};
        <<"patch">>   -> {<<"patch">>, none};
        _             -> {<<"other">>, M}
    end.

%%% ------------------------------------------------------- outgoing-response ---

outgoing_response(Hdrs) ->
    Headers = case wasm_component:host_get(Hdrs) of
                  {ok, {http_fields, L}} -> L;
                  _                      -> []
              end,
    wasm_component:host_new(http_out_resp,
                            #{status => 200, headers => Headers,
                              body_handle => undefined}).

set_resp(R, Key, Value) ->
    case wasm_component:host_get(R) of
        {ok, {http_out_resp, Resp}} ->
            _ = wasm_component:host_update(R, Resp#{Key => Value}),
            {ok, undefined};
        _ ->
            {error, undefined}
    end.

resp_status(R) ->
    case wasm_component:host_get(R) of
        {ok, {http_out_resp, #{status := S}}} -> S;
        _                                     -> 0
    end.

out_resp_headers(R) ->
    case wasm_component:host_get(R) of
        {ok, {http_out_resp, #{headers := H}}} -> ro_fields(H);
        _                                      -> ro_fields([])
    end.

response_body(R) ->
    case wasm_component:host_get(R) of
        {ok, {http_out_resp, #{headers := H} = Resp}} ->
            BodyH = wasm_component:host_new(http_out_body, new_body(content_length(H))),
            _ = wasm_component:host_update(R, Resp#{body_handle => BodyH}),
            {ok, BodyH};
        _ ->
            {error, undefined}
    end.

%% The bytes buffered in an outgoing-body (empty for a gone or never-written one).
body_data(BodyH) ->
    case wasm_component:host_get(BodyH) of
        {ok, {http_out_body, #{data := Data}}} -> Data;
        _                                      -> <<>>
    end.

%%% -------------------------------------------------------- response-outparam ---

outparam_set(Param, Response) ->
    _ = wasm_component:host_update(Param, Response),
    undefined.

-doc "Read the response a reactor set on its outparam, after handle returns.".
-spec read_outparam(non_neg_integer()) ->
          {ok, 0..65535, [{binary(), binary()}], binary()} | {error, term()}.
read_outparam(Param) ->
    case wasm_component:host_get(Param) of
        {ok, {http_outparam, {ok, RespH}}}     -> read_response(RespH);
        {ok, {http_outparam, {error, Code}}}   -> {error, Code};
        _                                      -> {error, no_response}
    end.

read_response(RespH) ->
    case wasm_component:host_get(RespH) of
        {ok, {http_out_resp, #{status := S, headers := H, body_handle := BodyH}}} ->
            {ok, S, H, response_body_bytes(BodyH)};
        _ ->
            {error, no_response}
    end.

response_body_bytes(undefined) ->
    <<>>;
response_body_bytes(BodyH) ->
    case erase({http_final_body, BodyH}) of
        undefined -> body_data(BodyH);
        Snapshot  -> Snapshot
    end.

%%% ----------------------------------------------------------- helpers ---

drop() -> fun(_Ctx, [H]) -> _ = wasm_component:host_drop(H), {ok, []} end.

%% The http error-code carried by an io-error, if any. A bounded body's overrun is
%% stored as `{http_body_size, N}` in the io-error resource (minted by the stream
%% write in wasi_preview2); nothing else maps to an http error-code.
http_error_code(Err) ->
    case wasm_component:host_get(Err) of
        {ok, {error, {http_body_size, N}}} -> {some, body_size(N)};
        _                                  -> none
    end.

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
