-module(wasm_wasi2_nn_SUITE).
-moduledoc """
A component that imports `wasi:nn` runs against `wasi_nn`, with
`wasi_nn_test_backend` in the place of an inference engine.

The guest is `test/fixtures/component/wasinn` (see
`scripts/build-component-fixture.sh`). Its entry core module imports only
what the host supplies, so a drop reaches the `[resource-drop]` import of
`wasi_nn`. The last cases run `nncommand`, a `wasi:cli/command` built for
`wasm32-wasip2`: its cores are linked, so a drop goes through the instance's
`resource_closer`, and they go through `wasi_preview2:run_command/3`, which
is what an embedder calls.

The cases cover what the host decides on its own: which names a guest may
load, the bound on tensor bytes and that a drop gives bytes back, that
`compute` frees its inputs, that a forged handle is an error the guest
reads, that a backend which fails does not fail the call, and that a graph
and a context are closed once.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(MIB, 1024 * 1024).
-define(OUTPUT,
        {record, [{<<"name">>, string}, {<<"dimensions">>, {list, u32}},
                  {<<"ty">>, string}, {<<"data">>, {list, u8}}]}).

all() ->
    [a_model_runs_and_its_outputs_come_back,
     the_backend_gets_the_named_input,
     nothing_is_left_live_after_a_run,
     a_name_outside_the_grant_is_not_found,
     the_backend_may_refuse_a_granted_name,
     without_the_option_the_import_is_missing,
     loading_from_bytes_is_refused,
     tensor_bytes_are_bounded,
     a_dropped_tensor_gives_its_bytes_back,
     compute_frees_its_inputs,
     a_tensor_passed_twice_is_freed_once,
     a_dropped_tensor_is_an_invalid_argument,
     a_graph_is_not_a_tensor_and_stays_live,
     a_tensor_is_not_an_execution_context,
     an_output_over_the_bound_is_too_large,
     a_backend_error_reaches_the_guest,
     a_backend_that_raises_is_a_runtime_error,
     a_backend_answer_of_the_wrong_shape_is_a_runtime_error,
     an_unknown_error_code_reads_unknown,
     a_context_the_backend_refuses_is_reported,
     a_graph_and_a_context_are_closed_once_on_drop,
     destroy_gives_the_bytes_back,
     destroy_without_the_closer_does_not_shrink_the_bound,
     the_imports_work_without_the_command_host,
     a_command_runs_a_model,
     a_command_closes_what_it_dropped_and_what_it_kept,
     a_command_without_the_grant_is_refused].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture_path()),
    [{component, Bin} | Config].

end_per_suite(_Config) -> ok.

%% Every case runs in a process of its own, so the host table and the byte
%% counter, which live in the process dictionary, start empty.
init_per_testcase(_Case, Config) -> Config.

end_per_testcase(_Case, _Config) -> ok.

%%% ------------------------------------------------------------ the path ---

a_model_runs_and_its_outputs_come_back(Config) ->
    I = instance(Config),
    ?assertEqual(
       {ok, [#{<<"name">> => <<"output">>, <<"dimensions">> => [5],
               <<"ty">> => <<"U8">>, <<"data">> => <<"HELLO">>},
             #{<<"name">> => <<"shape">>, <<"dimensions">> => [1, 2, 3],
               <<"ty">> => <<"FP32">>,
               <<"data">> => <<1.5:32/float-little>>}]},
       run(I, <<"echo">>, <<"hello">>)).

the_backend_gets_the_named_input(Config) ->
    I = instance(Config),
    {ok, _} = run(I, <<"echo">>, <<"hello">>),
    ?assertEqual([{nn, load, <<"echo">>},
                  {nn, compute, [{<<"input">>,
                                  #{dimensions => [1], type => u8,
                                    data => <<"hello">>}}]}],
                 [M || M <- drain(), element(2, M) =/= close]).

%% The guest drops the graph, the context, the outputs and nothing else is
%% minted: the input went to `compute`. Fail-first: without the drop of the
%% inputs in `wasi_nn:take_inputs/1` the input tensor stays here.
nothing_is_left_live_after_a_run(Config) ->
    I = instance(Config),
    {ok, _} = run(I, <<"echo">>, <<"hello">>),
    ?assertEqual([], wasm_component:host_live()),
    ?assertEqual({error, <<"timeout: too slow">>},
                 run(I, <<"echo">>, <<"timeout">>)),
    ?assertEqual([], wasm_component:host_live()).

%%% ----------------------------------------------------------- the grant ---

%% Fail-first: without the `lists:member/2` check in
%% `wasi_nn:load_by_name/4` the backend loads `secret`.
a_name_outside_the_grant_is_not_found(Config) ->
    I = instance(Config),
    ?assertEqual({error, <<"not-found: no such model">>},
                 run(I, <<"secret">>, <<"hello">>)),
    ?assertEqual([], drain()).

the_backend_may_refuse_a_granted_name(Config) ->
    I = instance(Config),
    ?assertEqual({error, <<"not-found: the backend has no such model">>},
                 run(I, <<"absent">>, <<"hello">>)),
    ?assertEqual({error, <<"runtime-error: the backend failed">>},
                 run(I, <<"crash">>, <<"hello">>)).

without_the_option_the_import_is_missing(Config) ->
    ?assertMatch({error, _},
                 wasm_component:instantiate(?config(component, Config),
                                            wasi_preview2:command(#{}),
                                            #{})).

loading_from_bytes_is_refused(Config) ->
    I = instance(Config),
    ?assertEqual({ok, <<"unsupported-operation: load a model by name">>},
                 call(I, <<"load-bytes">>, {[], string}, [])),
    ?assertEqual([], wasm_component:host_live()).

%%% ----------------------------------------------------------- the bound ---

%% Fifteen tensors of 1 MiB fit under 16 MiB; with the four bytes each
%% dimension counts for, the sixteenth does not.
tensor_bytes_are_bounded(Config) ->
    I = instance(Config),
    ?assertEqual({ok, 15}, hold(I, 15)),
    ?assertMatch({error, #{class := trap, kind := nn_tensor_limit_reached}},
                 hold(I, 1)).

%% Fail-first: without the `nn_tensor` clause of `wasi_nn:close_resource/1`
%% the second fifteen are refused, unless `reserve/1` counts again; with
%% the count removed too, they are.
a_dropped_tensor_gives_its_bytes_back(Config) ->
    I = instance(Config),
    ?assertEqual({ok, 15}, hold(I, 15)),
    {ok, undefined} = call(I, <<"release">>, {[], none}, []),
    ?assertEqual([], wasm_component:host_live()),
    ?assertEqual({ok, 15}, hold(I, 15)).

%% Each run hands `compute` a 6 MiB input; three of them are over the bound
%% unless the input is freed.
compute_frees_its_inputs(Config) ->
    I = instance(Config),
    Input = binary:copy(<<"a">>, 6 * ?MIB),
    [?assertMatch({ok, [_, _]}, run(I, <<"echo">>, Input))
     || _ <- lists:seq(1, 3)],
    {ok, undefined} = call(I, <<"release">>, {[], none}, []).

%% Fourteen held, then one tensor of 1 MiB given to `compute` twice in one
%% call: fourteen are live after it, so one more fits and a second does not.
%% Fail-first: without the `lists:usort/1` in `wasi_nn:take_inputs/1` the
%% tensor's bytes are given back twice and the second fits too.
a_tensor_passed_twice_is_freed_once(Config) ->
    I = instance(Config),
    ?assertEqual({ok, 14}, hold(I, 14)),
    ?assertEqual({ok, <<"ok: 2">>}, misuse(I, 2, ?MIB)),
    ?assertMatch([{nn, compute, [{<<"a">>, T}, {<<"b">>, T}]}],
                 [M || {nn, compute, _} = M <- drain()]),
    ?assertEqual({ok, 15}, hold(I, 1)),
    ?assertMatch({error, #{class := trap, kind := nn_tensor_limit_reached}},
                 hold(I, 1)).

%%% ------------------------------------------------------ forged handles ---

a_dropped_tensor_is_an_invalid_argument(Config) ->
    I = instance(Config),
    ?assertEqual({ok, <<"invalid-argument: not a tensor">>},
                 misuse(I, 0, 16)),
    ?assertEqual([], [M || {nn, compute, _} = M <- drain()]),
    ?assertEqual([], wasm_component:host_live()).

%% The graph the guest passed as a tensor is still the guest's: it is closed
%% once, when the guest drops it, and not by `compute`.
a_graph_is_not_a_tensor_and_stays_live(Config) ->
    I = instance(Config),
    ?assertEqual({ok, <<"invalid-argument: not a tensor">>},
                 misuse(I, 1, 16)),
    ?assertEqual([{nn, close, graph, <<"echo">>}],
                 [M || {nn, close, graph, _} = M <- drain()]),
    ?assertEqual([], wasm_component:host_live()).

%% The input is a real tensor, so it is freed although the call is refused:
%% the 6 MiB input would be over the bound the third time.
a_tensor_is_not_an_execution_context(Config) ->
    I = instance(Config),
    [?assertEqual(
        {ok, <<"invalid-argument: not an execution context">>},
        misuse(I, 3, 6 * ?MIB))
     || _ <- lists:seq(1, 3)],
    ?assertEqual([], [M || {nn, compute, _} = M <- drain()]).

%%% --------------------------------------------------------- the backend ---

an_output_over_the_bound_is_too_large(Config) ->
    I = instance(Config),
    ?assertEqual(
       {error, <<"too-large: the outputs are over the tensor bound">>},
       run(I, <<"echo">>, <<"big">>)),
    ?assertEqual([], wasm_component:host_live()).

a_backend_error_reaches_the_guest(Config) ->
    I = instance(Config),
    ?assertEqual({error, <<"timeout: too slow">>},
                 run(I, <<"echo">>, <<"timeout">>)).

a_backend_that_raises_is_a_runtime_error(Config) ->
    I = instance(Config),
    ?assertEqual({error, <<"runtime-error: the backend failed">>},
                 run(I, <<"echo">>, <<"raise">>)),
    ?assertMatch({ok, [_, _]}, run(I, <<"echo">>, <<"hello">>)).

a_backend_answer_of_the_wrong_shape_is_a_runtime_error(Config) ->
    I = instance(Config),
    Wrong = {error, <<"runtime-error: the backend gave an answer of the "
                      "wrong shape">>},
    ?assertEqual(Wrong, run(I, <<"echo">>, <<"shape">>)),
    ?assertEqual(Wrong, run(I, <<"echo">>, <<"type">>)).

an_unknown_error_code_reads_unknown(Config) ->
    I = instance(Config),
    ?assertEqual({error, <<"unknown: a code the interface lacks">>},
                 run(I, <<"echo">>, <<"code">>)).

a_context_the_backend_refuses_is_reported(Config) ->
    I = instance(Config),
    ?assertEqual({error, <<"too-large: no room for a context">>},
                 run(I, <<"no-context">>, <<"hello">>)),
    ?assertEqual([], wasm_component:host_live()).

%%% ---------------------------------------------------------------- close ---

%% Fail-first: without the `nn_*` clause of
%% `wasi_preview2:close_resource/1` no close arrives.
a_graph_and_a_context_are_closed_once_on_drop(Config) ->
    I = instance(Config),
    {ok, _} = run(I, <<"echo">>, <<"hello">>),
    ?assertEqual([{nn, close, context, <<"echo">>},
                  {nn, close, graph, <<"echo">>}],
                 lists:sort([M || {nn, close, _, _} = M <- drain()])).

%% Tensors the guest still holds when its instance is destroyed are counted
%% out by the closer, so the next instance of the process starts at zero.
destroy_gives_the_bytes_back(Config) ->
    I = instance(Config),
    ?assertEqual({ok, 15}, hold(I, 15)),
    ok = wasm_component:destroy(I, fun wasi_preview2:close_resource/1),
    ?assertEqual([], wasm_component:host_live()),
    I2 = instance(Config),
    ?assertEqual({ok, 15}, hold(I2, 15)).

%% An instance destroyed without the closer leaves the counter above the
%% truth. Fail-first: without the count in `wasi_nn:reserve/1` the next
%% instance of the process is refused its first tensor.
destroy_without_the_closer_does_not_shrink_the_bound(Config) ->
    I = instance(Config),
    ?assertEqual({ok, 15}, hold(I, 15)),
    ok = wasm_component:destroy(I),
    I2 = instance(Config),
    ?assertEqual({ok, 15}, hold(I2, 15)),
    ?assertMatch({error, #{class := trap, kind := nn_tensor_limit_reached}},
                 hold(I2, 1)).

%% An embedder that builds its own imports uses `wasi_nn` directly.
the_imports_work_without_the_command_host(Config) ->
    {ok, I} = wasm_component:instantiate(
                ?config(component, Config), wasi_nn:imports(grant()),
                #{resource_closer => fun wasi_nn:close_resource/1}),
    ?assertMatch({ok, [#{<<"data">> := <<"HELLO">>}, _]},
                 run(I, <<"echo">>, <<"hello">>)),
    ?assertEqual({ok, 15}, hold(I, 15)),
    {ok, undefined} = call(I, <<"release">>, {[], none}, []),
    ?assertEqual({ok, 15}, hold(I, 15)),
    ?assertEqual(2, length([M || {nn, close, _, _} = M <- drain()])).

%%% ---------------------------------------------------------- a command ---

a_command_runs_a_model(_Config) ->
    ?assertMatch({ok, #{stdout := <<"HELLO">>, exit_code := 0}},
                 wasi_preview2:run_command(command(), <<"hello">>,
                                           #{nn => grant()})),
    ?assertEqual([], wasm_component:host_live()).

%% The command drops one graph and its context, and keeps a second graph
%% until its instance is destroyed. Each is closed once. Fail-first: without
%% the `nn_*` clause of `wasi_preview2:close_resource/1` no close arrives.
a_command_closes_what_it_dropped_and_what_it_kept(_Config) ->
    {ok, _} = wasi_preview2:run_command(command(), <<"hello">>,
                                        #{nn => grant()}),
    ?assertEqual([{nn, close, context, <<"echo">>},
                  {nn, close, graph, <<"echo">>},
                  {nn, close, graph, <<"echo">>}],
                 lists:sort([M || {nn, close, _, _} = M <- drain()])).

a_command_without_the_grant_is_refused(_Config) ->
    ?assertMatch({error, _},
                 wasi_preview2:run_command(command(), <<"hello">>, #{})),
    ?assertEqual([], drain()).

%%% -------------------------------------------------------------- helpers ---

grant() ->
    #{backend => wasi_nn_test_backend,
      models => [<<"echo">>, <<"absent">>, <<"crash">>, <<"no-context">>],
      backend_opts => #{owner => self()}}.

instance(Config) ->
    {ok, I} = wasm_component:instantiate(
                ?config(component, Config),
                wasi_preview2:command(#{nn => grant()}),
                #{resource_closer => fun wasi_preview2:close_resource/1}),
    I.

run(I, Model, Input) ->
    {ok, Result} = call(I, <<"run">>,
                        {[string, {list, u8}],
                         {result, {list, ?OUTPUT}, string}},
                        [Model, Input]),
    Result.

%% Make `Count` more tensors of 1 MiB and keep them.
hold(I, Count) ->
    call(I, <<"hold">>, {[u32, u32], u32}, [Count, ?MIB]).

misuse(I, Kind, Size) ->
    call(I, <<"misuse">>, {[string, u32, u32], string},
         [<<"echo">>, Kind, Size]).

call(I, Name, Sig, Args) ->
    wasm_component:call(I, Name, Sig, Args).

drain() ->
    receive {nn, _, _} = M -> [M | drain()];
            {nn, _, _, _} = M -> [M | drain()]
    after 0 -> []
    end.

command() ->
    {ok, Bin} = file:read_file(fixture_path("nncommand")),
    Bin.

fixture_path() ->
    fixture_path("wasinn").

fixture_path(Name) ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component",
                   Name ++ ".component.wasm"]).
