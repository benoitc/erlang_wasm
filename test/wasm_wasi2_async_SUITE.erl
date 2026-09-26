-module(wasm_wasi2_async_SUITE).
-moduledoc """
The async Canonical ABI, driven by wasmtime's `p2_cli_invoke_async` component.

That component exports `echo: async func(string) -> string` (lifted with a callback)
and imports the async built-ins wit-bindgen emits: `task.return`, `context.get/set`,
`waitable-set.*`, `stream.*`, `waitable.join`, `task.cancel`. Its `main` is empty, so
the command runner (`wasm_wasi2_p2_SUITE`) only proves the component instantiates;
this suite is the real oracle: it invokes the async export through
`wasm_component:call_async/4` and asserts the echoed value, which cannot pass unless
the async lift runs, `task.return` captures the result, and the EXIT status is read.

Skipped without the built fixture: run `scripts/build-wasmtime-p2.sh` (the p2
fixtures are not vendored).
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() -> [echoes_a_string, echoes_empty, echoes_unicode, echoes_repeatedly].

init_per_suite(Config) ->
    case filelib:is_regular(fixture()) of
        false ->
            {skip, "no wasmtime p2 fixtures: run scripts/build-wasmtime-p2.sh"};
        true ->
            {ok, _} = application:ensure_all_started(wasm),
            Config
    end.

end_per_suite(_Config) -> ok.

%% A plain ascii string comes back unchanged: the async lift ran to task.return.
echoes_a_string(_) ->
    ?assertEqual({ok, <<"hello async">>}, echo(<<"hello async">>)).

%% The empty string round-trips (a zero-length result through task.return).
echoes_empty(_) ->
    ?assertEqual({ok, <<>>}, echo(<<>>)).

%% Multi-byte UTF-8 survives the lower/lift round trip byte for byte.
echoes_unicode(_) ->
    S = <<"jabberwocky "/utf8, 240, 159, 144, 137>>,
    ?assertEqual({ok, S}, echo(S)).

%% Several calls on one instance each return their own input, so the task frame is
%% reset per call and no result leaks from the previous one.
echoes_repeatedly(_) ->
    {ok, I} = instance(),
    try
        [?assertEqual({ok, S},
                      wasm_component:call_async(I, <<"echo">>, sig(), [S]))
         || S <- [<<"one">>, <<"two">>, <<"three">>]]
    after
        wasm_component:destroy(I, fun wasi_preview2:close_resource/1)
    end.

%%% ------------------------------------------------------------------ helpers ---

echo(Str) ->
    {ok, I} = instance(),
    try
        wasm_component:call_async(I, <<"echo">>, sig(), [Str])
    after
        wasm_component:destroy(I, fun wasi_preview2:close_resource/1)
    end.

sig() -> {[string], string}.

instance() ->
    {ok, Bin} = file:read_file(fixture()),
    Imports = wasi_preview2:command(#{stdin => <<>>,
                                      stdout => fun(_) -> ok end,
                                      stderr => fun(_) -> ok end}),
    wasm_component:instantiate(Bin, Imports,
                               #{loader => compile,
                                 resource_closer => fun wasi_preview2:close_resource/1}).

fixture() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..", "test",
                   "fixtures", "wasmtime-p2", "p2_cli_invoke_async.component.wasm"]).
