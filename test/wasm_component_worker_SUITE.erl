-module(wasm_component_worker_SUITE).
-moduledoc """
A real component runs through the hardened worker kernel.

`fake_component_adapter` returns a `runtime => component` spec, so the worker
instantiates a real `wasi:cli/command` component (the `realupper` fixture),
calls `wasi:cli/run.run` through the Canonical ABI, and hands the tenant what it
wrote to stdout. This is the byte-in/byte-out worker use case: submit bytes, get
bytes, with the worker's deadlines, limits and cleanup. The output is checked
against a fixed value and, when present, against wasmtime.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [a_real_command_runs_through_the_worker,
     it_matches_wasmtime_through_the_worker,
     a_file_is_processed_over_a_mount].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

init_per_testcase(TC, Config) ->
    process_flag(trap_exit, true),
    Root = filename:join([?config(priv_dir, Config), atom_to_list(TC), "root"]),
    ok = filelib:ensure_path(Root),
    {ok, Reaper} = wasm_worker_reaper:start_link(#{scratch => Root}),
    {ok, W} = wasm_script_worker:start_link(fake_component_adapter, #{root => scratch}),
    [{reaper, Reaper}, {worker, W} | Config].

end_per_testcase(_TC, Config) ->
    try wasm_script_worker:stop(?config(worker, Config)) catch _:_ -> ok end,
    try wasm_worker_reaper:stop() catch _:_ -> ok end,
    ok.

inputs() ->
    [<<>>, <<"hello">>, <<"Through the worker!\n">>, binary:copy(<<"abc ">>, 400)].

%% Submit bytes, get the upper-cased bytes back through the worker.
a_real_command_runs_through_the_worker(Config) ->
    W = ?config(worker, Config),
    [begin
         {ok, #{stdout := Out}} = wasm_script_worker:run(W, #{stdin => In}),
         ?assertEqual(string:uppercase(In), Out)
     end || In <- inputs()].

%% The worker's output equals wasmtime's for the same component and input.
it_matches_wasmtime_through_the_worker(Config) ->
    case os:find_executable("wasmtime") of
        false ->
            {skip, "wasmtime not on the path"};
        Wasmtime ->
            W = ?config(worker, Config),
            Path = fixture_path(),
            [begin
                 {ok, #{stdout := Out}} = wasm_script_worker:run(W, #{stdin => In}),
                 ?assertEqual(run_on_wasmtime(Wasmtime, Path, In), Out)
             end || In <- inputs()]
    end.

%% A file staged into a read mount is read by the component and its contents come
%% back: the worker's mount is wired to the command's preopen. Uses the realcat
%% fixture (reads a file, writes stdout).
a_file_is_processed_over_a_mount(_Config) ->
    {ok, W} = wasm_script_worker:start_link(
                fake_component_adapter, #{root => scratch, path => realcat_path()}),
    try
        [begin
             {ok, #{stdout := Out}} = wasm_script_worker:run(W, #{file => Content}),
             ?assertEqual(Content, Out)
         end || Content <- [<<"mount contents\n">>, <<>>, binary:copy(<<"x">>, 1000)]]
    after
        wasm_script_worker:stop(W)
    end.

%%% -------------------------------------------------------------- helpers ---

realcat_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "realcat.component.wasm"]).

run_on_wasmtime(Wasmtime, Path, In) ->
    Tmp = string:trim(os:cmd("mktemp")),
    ok = file:write_file(Tmp, In),
    Out = os:cmd(lists:flatten(io_lib:format("~ts run ~ts < ~ts", [Wasmtime, Path, Tmp]))),
    _ = file:delete(Tmp),
    unicode:characters_to_binary(Out).

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "realupper.component.wasm"]).
