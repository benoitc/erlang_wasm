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
     a_file_is_processed_over_a_mount,
     a_typed_service_export_is_called_per_request,
     the_multi_core_linker_runs_through_the_worker,
     each_request_gets_a_fresh_component_instance].

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

%% The worker calls a component's typed export (list<u8> -> result<list<u8>,
%% string>) with typed input per request and lifts the typed result: the
%% reactor/service shape, not a command. The echo service returns its input.
a_typed_service_export_is_called_per_request(_Config) ->
    {ok, W} = wasm_script_worker:start_link(
                fake_component_reactor_adapter, #{root => scratch}),
    try
        %% The service upper-cases non-empty input; it comes back through the
        %% typed ok arm.
        [begin
             {ok, #{output := Out}} = wasm_script_worker:run(W, #{input => In}),
             ?assertEqual(string:uppercase(In), Out)
         end || In <- [<<"service request">>, binary:copy(<<1, 2, 3>>, 200)]],
        %% The echo service refuses empty input: the typed error arm crosses back
        %% as the adapter's error.
        ?assertMatch({error, _}, wasm_script_worker:run(W, #{input => <<>>}))
    after
        wasm_script_worker:stop(W)
    end.

%% The worker runs `twocore`, whose entry core imports a function from a second
%% core. Only the graph linker can wire that, so a result of 42 proves the linker
%% ran inside the worker's per-request runner, not only in an inline test.
the_multi_core_linker_runs_through_the_worker(_Config) ->
    {ok, W} = wasm_script_worker:start_link(
                fake_component_multicore_adapter, #{root => scratch}),
    try
        ?assertEqual({ok, #{value => 42}}, wasm_script_worker:run(W, #{})),
        ?assertEqual({ok, #{value => 42}}, wasm_script_worker:run(W, #{}))
    after
        wasm_script_worker:stop(W)
    end.

%% Each request gets a fresh instance, so instance state never bleeds between
%% requests. `statecore` increments a mutable global and returns it: a fresh
%% instance returns 1 every time, a reused one would return 2 on the second call.
each_request_gets_a_fresh_component_instance(_Config) ->
    {ok, W} = wasm_script_worker:start_link(
                fake_component_stateful_adapter, #{root => scratch}),
    try
        ?assertEqual({ok, #{value => 1}}, wasm_script_worker:run(W, #{})),
        ?assertEqual({ok, #{value => 1}}, wasm_script_worker:run(W, #{})),
        ?assertEqual({ok, #{value => 1}}, wasm_script_worker:run(W, #{}))
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
