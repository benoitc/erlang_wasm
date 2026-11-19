-module(wasm_wasi2_nn_wasmtime_SUITE).
-moduledoc """
Wasmtime's own `wasi:nn` test programs, run against `wasi_nn`.

The specification of `wasi:nn` ships no test: its `test/README.md` is a
placeholder. Wasmtime's `nn_wit_*` programs are the tests implementations
share. Each is a `wasi:cli/command` that loads a model, classifies an image
and exits 0; three of them assert the class the model must rank first. They
are built by `scripts/build-wasmtime-p2.sh` into
`test/fixtures/wasmtime-nn/`, and this suite skips without them.

What they prove here, and what they do not. The backend is
`wasi_nn_classifier_backend`, which runs no model: it ranks first the class
this suite tells it to. So a pass shows that the host carries exactly what
wasmtime's guests send (the model's parts, its format, the target, a named
`fp32` tensor of `[1, 3, 224, 224]`) and that the guest reads the answer. It
does not show that any engine classifies an image. The model files are
placeholders for the same reason, and the input tensors are zeros of the
size wasmtime's are.

Each program reads its files from a directory mounted as `fixture`, as in
wasmtime's own runner (`crates/wasi-nn/tests/exec/wit.rs`).
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% `[1, 3, 224, 224]' elements of four bytes.
-define(INPUT_BYTES, 602112).

all() ->
    [onnx_from_bytes,
     openvino_from_two_parts,
     pytorch_from_bytes,
     openvino_by_name,
     winml_by_name,
     a_program_fails_on_the_wrong_class,
     a_program_fails_without_the_encoding,
     a_program_fails_without_the_name].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    case filelib:wildcard(filename:join(dir(), "nn_wit_*.component.wasm")) of
        [] ->
            wasi_p2_runner:missing_fixtures("no wasmtime wasi-nn programs");
        _ ->
            Dir = filename:join(?config(priv_dir, Config), "fixture"),
            ok = filelib:ensure_path(Dir),
            [ok = file:write_file(filename:join(Dir, Name), Bytes)
             || {Name, Bytes} <- files()],
            [{fixture, Dir} | Config]
    end.

end_per_suite(_Config) -> ok.

%% What the programs read. The sizes of the model parts are told apart in
%% the cases, to see each part arrive in order.
files() ->
    Tensor = binary:copy(<<0>>, ?INPUT_BYTES),
    [{"model.onnx", binary:copy(<<1>>, 11)},
     {"model.xml", binary:copy(<<2>>, 22)},
     {"model.bin", binary:copy(<<3>>, 33)},
     {"model.pt", binary:copy(<<4>>, 44)},
     {"000000062808.rgb", Tensor},
     {"tensor.bgr", Tensor},
     {"kitten.tensor", Tensor}].

%%% ----------------------------------------------------------- the cases ---

%% The program asserts class 963 first.
onnx_from_bytes(Config) ->
    ok = passes(Config, "nn_wit_image_classification_onnx",
                #{encodings => [onnx], classes => #{onnx => 963}}),
    ?assertEqual([{nn, load, onnx, cpu, [11]}, input()], drain()).

openvino_from_two_parts(Config) ->
    ok = passes(Config, "nn_wit_image_classification_openvino",
                #{encodings => [openvino]}),
    ?assertEqual([{nn, load, openvino, cpu, [22, 33]}, input()], drain()).

%% The program asserts class 281 first, after a softmax of its own.
pytorch_from_bytes(Config) ->
    ok = passes(Config, "nn_wit_image_classification_pytorch",
                #{encodings => [pytorch], classes => #{pytorch => 281}}),
    ?assertEqual([{nn, load, pytorch, cpu, [44]}, input()], drain()).

openvino_by_name(Config) ->
    ok = passes(Config, "nn_wit_image_classification_openvino_named",
                #{models => [<<"fixtures">>]}),
    ?assertEqual([{nn, load_by_name, <<"fixtures">>}, input()], drain()).

%% The program asserts class 284 first.
winml_by_name(Config) ->
    ok = passes(Config, "nn_wit_image_classification_winml_named",
                #{models => [<<"mobilenet">>],
                  classes => #{<<"mobilenet">> => 284}}),
    ?assertEqual([{nn, load_by_name, <<"mobilenet">>}, input()], drain()).

%% The three cases below are why a pass above means something: the same
%% programs fail when the answer or the grant is wrong.
a_program_fails_on_the_wrong_class(Config) ->
    ok = fails(Config, "nn_wit_image_classification_onnx",
               #{encodings => [onnx], classes => #{onnx => 962}}).

a_program_fails_without_the_encoding(Config) ->
    ok = fails(Config, "nn_wit_image_classification_onnx",
               #{encodings => [pytorch], classes => #{onnx => 963}}),
    ?assertEqual([], drain()).

a_program_fails_without_the_name(Config) ->
    ok = fails(Config, "nn_wit_image_classification_winml_named",
               #{models => [<<"fixtures">>],
                 classes => #{<<"mobilenet">> => 284}}),
    ?assertEqual([], drain()).

%%% -------------------------------------------------------------- helpers ---

input() ->
    {nn, compute, <<"input">>, [1, 3, 224, 224], fp32, ?INPUT_BYTES}.

passes(Config, Program, Spec) ->
    case run(Config, Program, Spec) of
        {ok, #{exit_code := 0}} -> ok;
        Other -> ct:fail({Program, Other})
    end.

fails(Config, Program, Spec) ->
    case run(Config, Program, Spec) of
        {ok, #{exit_code := 0}} -> ct:fail({Program, passed});
        _ -> ok
    end.

run(Config, Program, Spec) ->
    {ok, Bin} = file:read_file(
                  filename:join(dir(), Program ++ ".component.wasm")),
    Grant = #{backend => wasi_nn_classifier_backend,
              models => maps:get(models, Spec, []),
              encodings => maps:get(encodings, Spec, []),
              backend_opts => #{owner => self(),
                                classes => maps:get(classes, Spec, #{})}},
    wasi_preview2:run_command(
      Bin, <<>>,
      #{nn => Grant, compile => true,
        preopens => [{<<"fixture">>, ?config(fixture, Config), false}]}).

drain() ->
    receive M when element(1, M) =:= nn -> [M | drain()]
    after 0 -> []
    end.

dir() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "wasmtime-nn"]).
