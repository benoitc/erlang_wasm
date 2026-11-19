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
-define(NO_LOAD,
        <<"unsupported-operation: this host does not load a model of this "
          "format from bytes">>).
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
     a_command_without_the_grant_is_refused,
     the_host_serves_every_function_of_the_interface,
     every_tensor_type_round_trips,
     every_encoding_and_target_reaches_the_backend,
     every_error_code_reaches_the_guest,
     the_length_rule_holds_for_every_type,
     an_encoding_outside_the_grant_is_refused,
     a_backend_without_load_refuses_bytes,
     the_tensor_bound_is_the_grants].

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
    ?assertEqual({ok, ?NO_LOAD}, call(I, <<"load-bytes">>, {[], string}, [])),
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

%%% ------------------------------------------- vectors from the interface ---
%%
%% The specification has no test suite. What it has is the interface, in WIT,
%% and one rule about a tensor's data. These cases read the interface from
%% the copy of the upstream file the guest was built from, and expect what it
%% says: its functions, and the cases of each enum in their order. The guest
%% passes an enum by position, so a table of the host that disagrees with
%% the interface by one place fails here.

%% Every function, constructor, method and drop the interface declares has an
%% import, and the host has no import the interface lacks.
the_host_serves_every_function_of_the_interface(_Config) ->
    ?assertEqual(wit_fields(),
                 lists:sort(maps:keys(wasi_nn:imports(grant())))).

every_tensor_type_round_trips(Config) ->
    I = instance(Config),
    Types = wit_enum("tensor-type"),
    ?assertEqual(7, length(Types)),
    [?assertEqual({ok, #{<<"name">> => <<>>, <<"dimensions">> => [2, 3],
                         <<"ty">> => Type, <<"data">> => <<"abcdef">>}},
                  call(I, <<"tensor-echo">>, {[{list, u32}, u32, {list, u8}],
                                              ?OUTPUT},
                       [[2, 3], Index, <<"abcdef">>]))
     || {Index, Type} <- lists:enumerate(0, Types)],
    ?assertEqual([], wasm_component:host_live()),
    %% And the backend sees the atom the name spells, with the dimensions.
    [begin
         {ok, _} = call(I, <<"run-with">>,
                        {[string, {list, u32}, u32, {list, u8}],
                         {result, {list, ?OUTPUT}, string}},
                        [<<"echo">>, [2, 3], Index, <<"abcdef">>]),
         ?assertEqual([{nn, compute,
                        [{<<"input">>, #{dimensions => [2, 3],
                                         type => atom(Type),
                                         data => <<"abcdef">>}}]}],
                      [M || {nn, compute, _} = M <- drain()])
     end || {Index, Type} <- lists:enumerate(0, Types)].

%% Twenty-one calls: each format with each target. The backend must see the
%% atom the interface's name spells, and every part of the model in order.
every_encoding_and_target_reaches_the_backend(Config) ->
    Encodings = wit_enum("graph-encoding"),
    Targets = wit_enum("execution-target"),
    ?assertEqual({7, 3}, {length(Encodings), length(Targets)}),
    Grant = (classifier())#{encodings => [atom(E) || E <- Encodings]},
    I = instance(Config, Grant),
    [begin
         ?assertEqual({ok, <<"ok">>}, load_with(I, [<<1>>, <<2, 3>>], E, T)),
         ?assertEqual([{nn, load, atom(Encoding), atom(Target), [1, 2]}],
                      drain())
     end || {E, Encoding} <- lists:enumerate(0, Encodings),
            {T, Target} <- lists:enumerate(0, Targets)],
    ?assertEqual([], wasm_component:host_live()).

every_error_code_reaches_the_guest(Config) ->
    I = instance(Config),
    Codes = wit_enum("error-code"),
    ?assertEqual(9, length(Codes)),
    [?assertEqual({error, <<Code/binary, ": as asked">>},
                  run(I, <<"echo">>,
                      <<"code:", (atom_to_binary(atom(Code)))/binary>>))
     || Code <- Codes].

%% The one rule of the specification about data: its length is the product
%% of the dimensions times the size of an element. The first vector is the
%% specification's own example, a 2x2 tensor of `f32` in 16 bytes.
the_length_rule_holds_for_every_type(_Config) ->
    ?assertEqual(ok, wasi_nn:check_tensor(tensor([2, 2], fp32, 16))),
    Sizes = [{u8, 1}, {fp16, 2}, {bf16, 2}, {fp32, 4}, {i32, 4}, {fp64, 8},
             {i64, 8}],
    ?assertEqual(lists:sort([atom(T) || T <- wit_enum("tensor-type")]),
                 lists:sort([T || {T, _} <- Sizes])),
    [begin
         Bytes = Size * lists:foldl(fun erlang:'*'/2, 1, Dims),
         ?assertEqual(ok, wasi_nn:check_tensor(tensor(Dims, Type, Bytes))),
         ?assertMatch({error, {invalid_argument, _}},
                      wasi_nn:check_tensor(tensor(Dims, Type, Bytes + 1))),
         ?assertMatch({error, {invalid_argument, _}},
                      wasi_nn:check_tensor(tensor(Dims, Type, Bytes + Size)))
     end || {Type, Size} <- Sizes,
            Dims <- [[1], [7], [2, 2], [1, 3, 224, 224], [3, 0, 5], []]].

%%% ------------------------------------------------- a model from bytes ---

%% Fail-first: without the `lists:member/2` check in `wasi_nn:load/6` the
%% backend loads a format the grant does not list.
an_encoding_outside_the_grant_is_refused(Config) ->
    I = instance(Config, (classifier())#{encodings => [onnx]}),
    ?assertEqual({ok, <<"ok">>}, load_with(I, [<<1>>], 1, 0)),
    ?assertMatch([{nn, load, onnx, cpu, [1]}], drain()),
    ?assertEqual({ok, ?NO_LOAD}, load_with(I, [<<1>>], 3, 0)),
    ?assertEqual([], drain()).

%% `wasi_nn_test_backend` exports no `load/4`.
a_backend_without_load_refuses_bytes(Config) ->
    I = instance(Config, (grant())#{encodings => [ggml]}),
    ?assertEqual({ok, ?NO_LOAD}, call(I, <<"load-bytes">>, {[], string}, [])),
    ?assertEqual([], wasm_component:host_live()).

%%% ------------------------------------------------------------ the bound ---

the_tensor_bound_is_the_grants(Config) ->
    Small = instance(Config, (grant())#{max_tensor_bytes => 3 * ?MIB}),
    ?assertEqual({ok, 2}, hold(Small, 2)),
    ?assertMatch({error, #{class := trap, kind := nn_tensor_limit_reached,
                           ctx := #{limit := 3145728}}},
                 hold(Small, 1)),
    ok = wasm_component:destroy(Small, fun wasi_preview2:close_resource/1),
    Large = instance(Config, (grant())#{max_tensor_bytes => 32 * ?MIB}),
    ?assertEqual({ok, 20}, hold(Large, 20)).

%%% -------------------------------------------------------------- helpers ---

classifier() ->
    #{backend => wasi_nn_classifier_backend, models => [],
      backend_opts => #{owner => self()}}.

load_with(I, Parts, Encoding, Target) ->
    call(I, <<"load-with">>, {[{list, {list, u8}}, u32, u32], string},
         [Parts, Encoding, Target]).

tensor(Dims, Type, Bytes) ->
    #{dimensions => Dims, type => Type, data => binary:copy(<<0>>, Bytes)}.

%% The atom a backend sees for a name of the interface: `FP32` is `fp32`,
%% `invalid-argument` is `invalid_argument`.
atom(Name) ->
    binary_to_atom(
      binary:replace(string:lowercase(Name), <<"-">>, <<"_">>, [global])).

%% The upstream interface, without its comments.
wit() ->
    {ok, Text} = file:read_file(
                   filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                                  "test", "fixtures", "component", "wasinn",
                                  "wit", "deps", "nn", "wasi-nn.wit"])),
    re:replace(Text, "//[^\n]*", "", [global, {return, binary}]).

%% The cases of an enum of the interface, in the order it declares them.
wit_enum(Name) ->
    {match, [Body]} = re:run(wit(), "enum\\s+" ++ Name ++ "\\s*\\{([^}]*)\\}",
                             [{capture, all_but_first, binary}]),
    [Case || Case <- re:split(Body, "[\\s,]+"), Case =/= <<>>].

%% Every import key the interface implies, sorted.
wit_fields() ->
    [_World | Interfaces] = re:split(wit(), "\\binterface\\s+"),
    lists:sort(lists:flatmap(fun interface_fields/1, Interfaces)).

interface_fields(Text) ->
    {match, [Name]} = re:run(Text, "^([a-z-]+)",
                             [{capture, all_but_first, binary}]),
    Iface = <<"wasi:nn/", Name/binary>>,
    Resources = matches(Text, "resource\\s+([a-z-]+)\\s*\\{([^}]*)\\}"),
    Rest = re:replace(Text, "(resource|enum)\\s+[a-z-]+\\s*\\{[^}]*\\}",
                      "", [global, {return, binary}]),
    [{Iface, F} || [F] <- matches(Rest, "([a-z-]+)\\s*:\\s*func")]
        ++ [{Iface, F} || [R, Body] <- Resources, F <- resource_fields(R, Body)].

resource_fields(R, Body) ->
    [<<"[resource-drop]", R/binary>>]
        ++ [<<"[constructor]", R/binary>>
            || re:run(Body, "constructor\\s*\\(") =/= nomatch]
        ++ [<<"[method]", R/binary, ".", M/binary>>
            || [M] <- matches(Body, "([a-z-]+)\\s*:\\s*func")].

matches(Text, Pattern) ->
    case re:run(Text, Pattern, [global, {capture, all_but_first, binary}]) of
        {match, Found} -> Found;
        nomatch -> []
    end.

grant() ->
    #{backend => wasi_nn_test_backend,
      models => [<<"echo">>, <<"absent">>, <<"crash">>, <<"no-context">>],
      backend_opts => #{owner => self()}}.

instance(Config) ->
    instance(Config, grant()).

instance(Config, Grant) ->
    {ok, I} = wasm_component:instantiate(
                ?config(component, Config),
                wasi_preview2:command(#{nn => Grant}),
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
    receive M when element(1, M) =:= nn -> [M | drain()]
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
