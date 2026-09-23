-module(wasm_wasi2_adapter_SUITE).
-moduledoc """
Run an official wasi-testsuite program through the preview1->preview2 adapter.

The committed `wasi_snapshot_preview1.command.wasm` (a wasmtime release) turns a
`wasm32-wasip1` program into a preview2 command component: many core modules (the
guest, the adapter, a shim table and a fixup that fills it) linked by the
component graph. `wasm_component` reads that graph and runs it. Each case is
adapted with `wasm-tools`, run on erlang_wasm and, when present, on wasmtime, and
the exit codes must agree.

Skips when `wasm-tools`, the adapter, or the wasi-testsuite checkout is absent, so
the suite is silent on a machine that has not run `make suites`.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% Self-contained wasip1 programs: they assert internally and exit 0 on success,
%% needing no preopen or arguments.
cases() ->
    ["big_random_buf", "clock_time_get", "sched_yield"].

all() ->
    [an_adapted_program_runs,
     it_matches_wasmtime].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    case {os:find_executable("wasm-tools"), filelib:is_regular(adapter()),
          filelib:is_dir(testsuite_dir())} of
        {false, _, _} -> {skip, "wasm-tools not on the path"};
        {_, false, _} -> {skip, "adapter fixture missing"};
        {_, _, false} -> {skip, "wasi-testsuite not checked out (make suites)"};
        {WasmTools, true, true} -> [{wasm_tools, WasmTools} | Config]
    end.

end_per_suite(_Config) -> ok.

%% Every case adapts and runs on erlang_wasm, exiting 0 (success).
an_adapted_program_runs(Config) ->
    [begin
         Component = adapt(Config, C),
         {ok, #{exit_code := Code}} =
             wasi_preview2:run_command(Component, <<>>,
                                       #{stub => true, args => [list_to_binary(C)]}),
         ?assertEqual(0, Code)
     end || C <- cases()].

%% erlang_wasm and wasmtime agree on the exit status (zero vs non-zero).
it_matches_wasmtime(Config) ->
    case os:find_executable("wasmtime") of
        false ->
            {skip, "wasmtime not on the path"};
        Wasmtime ->
            [begin
                 Component = adapt(Config, C),
                 Path = filename:join(?config(priv_dir, Config), C ++ ".component.wasm"),
                 ok = file:write_file(Path, Component),
                 {ok, #{exit_code := Ours}} =
                     wasi_preview2:run_command(Component, <<>>,
                                               #{stub => true, args => [list_to_binary(C)]}),
                 Ref = wasmtime_exit(Wasmtime, Path),
                 ?assertEqual(Ref =:= 0, Ours =:= 0)
             end || C <- cases()]
    end.

%%% -------------------------------------------------------------- helpers ---

%% Adapt one wasip1 test into a preview2 component with wasm-tools.
adapt(Config, Case) ->
    WasmTools = ?config(wasm_tools, Config),
    In = filename:join(testsuite_dir(), Case ++ ".wasm"),
    Out = filename:join(?config(priv_dir, Config), Case ++ ".adapted.wasm"),
    Cmd = io_lib:format("~ts component new ~ts --adapt wasi_snapshot_preview1=~ts -o ~ts",
                        [WasmTools, In, adapter(), Out]),
    _ = os:cmd(lists:flatten(Cmd)),
    {ok, Bin} = file:read_file(Out),
    Bin.

wasmtime_exit(Wasmtime, Path) ->
    Port = open_port({spawn, lists:flatten(io_lib:format("~ts run ~ts", [Wasmtime, Path]))},
                     [exit_status, binary]),
    wait_exit(Port).

wait_exit(Port) ->
    receive
        {Port, {exit_status, Code}} -> Code;
        {Port, {data, _}}           -> wait_exit(Port)
    end.

adapter() ->
    filename:join(fixture_dir(), "wasi_snapshot_preview1.command.wasm").

fixture_dir() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component"]).

testsuite_dir() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "wasi-testsuite", "tests", "rust", "testsuite", "wasm32-wasip1"]).
