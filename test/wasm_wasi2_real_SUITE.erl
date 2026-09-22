-module(wasm_wasi2_real_SUITE).
-moduledoc """
A real, unmodified WASI 0.2 component runs through erlang_wasm, checked against
wasmtime.

`test/fixtures/component/realupper` is a normal Rust `fn main` (read stdin,
upper-case it, write stdout) built for `wasm32-wasip2`, so it is a real
`wasi:cli/command` component with no WIT and no bindings. `wasi_preview2:run_command/2`
runs it on our host; when `wasmtime` is on the path the same component is run
there too and the outputs must match. This is the correctness check for the
whole WASI 0.2 host: a real program behaves the same on erlang_wasm and the
reference runtime.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [a_real_command_uppercases_stdin,
     it_matches_wasmtime].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Path = fixture_path(),
    {ok, Bin} = file:read_file(Path),
    [{component, Bin}, {path, Path} | Config].

end_per_suite(_Config) -> ok.

inputs() ->
    [<<>>, <<"hello">>, <<"Hello, World!\n">>, <<"mixed 123 aBc\nsecond line\n">>,
     binary:copy(<<"abcdefghij ">>, 500)].

%% The real component upper-cases its input. A fixed expected value, so the case
%% means something even without wasmtime.
a_real_command_uppercases_stdin(Config) ->
    Bin = ?config(component, Config),
    [?assertEqual({ok, string:uppercase(In)}, wasi_preview2:run_command(Bin, In))
     || In <- inputs()].

%% Byte for byte, our output equals wasmtime's on the same component and input.
it_matches_wasmtime(Config) ->
    case os:find_executable("wasmtime") of
        false ->
            {skip, "wasmtime not on the path"};
        Wasmtime ->
            Bin = ?config(component, Config),
            Path = ?config(path, Config),
            [begin
                 {ok, Ours} = wasi_preview2:run_command(Bin, In),
                 Ref = run_on_wasmtime(Wasmtime, Path, In),
                 ?assertEqual(Ref, Ours)
             end || In <- inputs()]
    end.

%%% -------------------------------------------------------------- helpers ---

%% Run the component on wasmtime with In on stdin, returning its stdout. Uses a
%% temp file for stdin so end-of-input is clean.
run_on_wasmtime(Wasmtime, Path, In) ->
    Tmp = string:trim(os:cmd("mktemp")),
    ok = file:write_file(Tmp, In),
    Cmd = io_lib:format("~ts run ~ts < ~ts", [Wasmtime, Path, Tmp]),
    Out = os:cmd(lists:flatten(Cmd)),
    _ = file:delete(Tmp),
    unicode:characters_to_binary(Out).

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "realupper.component.wasm"]).
