# wasi-nn

`wasi:nn` lets a component ask the host to run a machine-learning model. The
component does not contain the model or the engine: it names a model, hands
over input tensors, and gets output tensors back. The host runs the model
natively, so it is as fast as the engine you plug in. Read this page when
your component imports `wasi:nn`, or when you write the module that connects
an inference engine to the runtime.

The runtime has no inference engine of its own. You give it a **backend**: an
Erlang module that implements the `wasi_nn` behaviour and calls the engine.
One backend exists outside this project, for llama.cpp:
[`erllama_wasi_nn`](https://github.com/benoitc/erllama), in the erllama
repository. It is in progress and not yet published.

`wasi:nn` is a release candidate upstream (`0.2.0-rc-2024-10-28`), and so is
this part of the runtime: `wasi_nn`, its callbacks and the `nn` option may
change when the interface does, in a release that is not marked as breaking.

## Words used on this page

| word | meaning |
| --- | --- |
| **backend** | your module, which implements the `wasi_nn` callbacks and runs the model |
| **graph** | a loaded model, as the guest sees it |
| **execution context** | one inference session on a graph |
| **tensor** | a block of numbers: its dimensions, the type of its elements, and its raw bytes |
| **grant** | the `nn` option: the backend, and the model names a guest may load |

## Grant it to a component

Pass an `nn` key in the options of `wasi_preview2:command/1` or
`wasi_preview2:run_command/3`. `wasi_preview3:run_command/3` takes the same
key, for the 0.2 and the 0.3 commands it runs:

<!-- check: modules my_nn -->
```erlang
Grant = #{backend => my_nn,
          models => [~"default"],
          backend_opts => #{}},
{ok, #{stdout := Out}} =
    wasi_preview2:run_command(Bin, ~"a prompt", #{nn => Grant}).
```

| key | what it is | left out |
| --- | --- | --- |
| `backend` | the module that implements `wasi_nn` | required |
| `models` | the names this guest may pass to `load-by-name` | required |
| `encodings` | the model formats this guest may bring as bytes, with `load` | none: `load` is refused |
| `max_tensor_bytes` | how many bytes of tensors the host holds for this guest | 16 MiB |
| `backend_opts` | any term, handed to your backend unchanged | `undefined` |

Without the `nn` key the interface is absent, and a component that imports
`wasi:nn` is refused when you instantiate it.

A name that is not in `models` answers `not-found`, exactly as a name your
backend does not know. So a guest cannot find out which models you have.

`encodings` is a separate grant, because a model the guest brings is a file
of the guest's that a native engine parses. List only the formats your
backend reads: `openvino`, `onnx`, `tensorflow`, `pytorch`, `tensorflowlite`,
`ggml` or `autodetect`. For a format you do not list, or a backend with no
`load/4`, `load` answers `unsupported-operation`.

## Write a backend

A backend exports four functions, and a fifth if it loads a model from
bytes. This one answers its input unchanged:

<!-- check: modules my_nn -->
```erlang
-module(my_nn).
-behaviour(wasi_nn).
-export([load_by_name/2, init_execution_context/1, compute/2, close/1]).

load_by_name(Name, _BackendOpts) ->
    {ok, #{model => Name}}.

init_execution_context(Graph) ->
    {ok, Graph}.

compute(_Context, [{_Name, #{data := Data}} | _]) ->
    {ok, [{~"output", #{dimensions => [byte_size(Data)],
                        type => u8,
                        data => Data}}]};
compute(_Context, []) ->
    {error, {invalid_argument, ~"no input"}}.

close(_GraphOrContext) ->
    ok.
```

| callback | called when | answer |
| --- | --- | --- |
| `load_by_name(Name, BackendOpts)` | the guest loads a granted name | `{ok, Graph}` |
| `load(Parts, Encoding, Target, BackendOpts)`, optional | the guest brings a model in a granted format | `{ok, Graph}` |
| `init_execution_context(Graph)` | the guest starts a session | `{ok, Context}` |
| `compute(Context, Inputs)` | the guest runs the model | `{ok, Outputs}` |
| `close({graph, Graph})`, `close({context, Context})` | the guest drops it, or its instance is destroyed | `ok` |

`Graph` and `Context` are your own terms. The runtime keeps them and gives
them back; it does not look inside.

In `load/4`, `Parts` is a list of binaries, one for each part of the model
in the guest's order: an ONNX model is one part, an OpenVINO model is its
description and then its weights. `Encoding` is one of the atoms above and
`Target` is `cpu`, `gpu` or `tpu`, as the guest asked.

`Inputs` and `Outputs` are lists of `{Name, Tensor}`. A tensor is a map:

| key | value |
| --- | --- |
| `dimensions` | a list of sizes, such as `[1, 3, 224, 224]` |
| `type` | `fp16`, `fp32`, `fp64`, `bf16`, `u8`, `i32` or `i64` |
| `data` | a binary: the elements, as the engine lays them out |

The interface has one rule about a tensor: the length of `data` is the
product of the dimensions times the size of one element, so a 2 by 2 tensor
of `fp32` holds 16 bytes. The runtime does not apply it for you, because
guests that send text commonly send it as `u8` with dimensions `[1]`. A
backend whose model has fixed shapes applies it with `wasi_nn:check_tensor/1`:

<!-- check: modules my_onnx -->
```erlang
compute(Context, [{_Name, Tensor}]) ->
    case wasi_nn:check_tensor(Tensor) of
        ok -> my_onnx:infer(Context, Tensor);
        {error, _} = Refused -> Refused
    end.
```

It answers `{error, {invalid_argument, _}}`, which you can return as it is.

On failure, answer `{error, {Code, Message}}`. `Message` is a UTF-8 binary of
at most 1024 bytes, and `Code` is one of:

| code | use it when |
| --- | --- |
| `invalid_argument` | an input is wrong |
| `invalid_encoding` | the model format is not one you read |
| `timeout` | the engine took too long |
| `runtime_error` | the engine failed |
| `unsupported_operation` | you do not do this |
| `too_large` | the model or the input does not fit |
| `not_found` | you have no model of that name |
| `security` | the guest may not do this |
| `unknown` | anything else |

If a callback raises, or answers a term of another shape, the guest gets a
`runtime-error`. The call into the component does not fail.

## What the guest can do

| the guest calls | what happens |
| --- | --- |
| `graph.load-by-name(name)` | your `load_by_name/2`, if `name` is granted |
| `graph.load(bytes, encoding, target)` | your `load/4`, if the format is granted and you export it |
| `graph.init-execution-context()` | your `init_execution_context/1` |
| `graph-execution-context.compute(inputs)` | your `compute/2` |
| `tensor` constructor, `dimensions`, `ty`, `data` | answered by the runtime, which holds the tensor |
| `error.code`, `error.data` | the code and message you answered |

`compute` takes ownership of its input tensors: they are freed when the call
returns, whatever the answer.

## Limits

- **Tensor bytes.** The host holds every tensor. All the live tensors of one
  process may hold `max_tensor_bytes` together, 16 MiB unless you say. Over
  that, creating a tensor traps with `nn_tensor_limit_reached`, and a
  `compute` whose outputs do not fit answers `too-large`. Dropping a tensor
  gives its bytes back. One image of 224 by 224 as `fp32` is about 0.6 MiB;
  raise the bound for batches or large inputs.
- **Model bytes.** A model a guest brings with `load` passes through the
  guest's memory, so it is bounded by `max_memory_pages`. The host does not
  keep it: your backend does.
- **Handles.** A graph, a context, a tensor and an error are each one host
  resource. `resource_limit` bounds how many are live.
- **Time.** `compute` blocks until your backend answers. `fuel` does not
  count that time: fuel counts WebAssembly work. Bound it in your backend, or
  run the component in a worker with a timeout; see [Using workers](worker.md).
- **Snapshots.** A component that imports `wasi:nn` cannot be captured in a
  snapshot: `wasm_component:snapshot/2` answers `import_not_snapshottable`.
- **Streaming.** `compute` answers once, with every output. The interface
  has no way to return tokens as they are generated.

## Which engines fit

The behaviour does not assume a kind of model. Two shapes are tested:

| kind of engine | how a guest uses it | what your backend does |
| --- | --- | --- |
| a language model (GGUF and the like) | `load-by-name`, a `u8` tensor holding text, a `u8` tensor back | maps a name to a loaded model; ignores dimensions |
| a tensor model (ONNX, OpenVINO, PyTorch) | `load` with the model's bytes or `load-by-name`, typed tensors with real shapes | exports `load/4`; applies `check_tensor/1`; answers typed tensors |

To serve several engines to one guest, write a backend that looks at the
name or the format and calls the module that has the engine. The grant takes
one backend.

## Build the imports yourself

`wasi_preview2:command/1` does this for you. When you build your own import
map, merge `wasi_nn:imports/1` into it and pass the closer, so that a graph
the guest still holds is closed when you destroy the instance:

<!-- check: modules my_nn -->
```erlang
Imports = wasi_nn:imports(#{backend => my_nn, models => [~"default"]}),
Closer = fun wasi_nn:close_resource/1,
{ok, Inst} = wasm_component:instantiate(Bin, Imports,
                                        #{resource_closer => Closer}),
ok = wasm_component:destroy(Inst, Closer).
```

## How it is tested

The specification of `wasi:nn` has no test suite: the `test` directory of
its repository holds a placeholder. Two things stand in for one.

| what | where | what a pass shows |
| --- | --- | --- |
| vectors read from the interface | `wasm_wasi2_nn_SUITE` | the host has an import for every function of the upstream WIT file and no other; every case of every enum arrives as the name the file gives it, in its order; the data rule holds for every element type |
| wasmtime's `nn_wit_*` programs | `wasm_wasi2_nn_wasmtime_SUITE` | the host carries exactly what wasmtime's own guests send, for a model from bytes (ONNX, OpenVINO in two parts, PyTorch) and by name, and those guests read the answer |

Both run against backends that run no model. So they test the host and the
behaviour, and they do not test any engine: a backend has its own suite,
where it runs a real model.

Wasmtime's `nn_witx_*` programs are not run: they use the older form of the
interface, in the notes below.

## Notes

- The interface is `wasi:nn@0.2.0-rc-2024-10-28`, a release candidate. The
  host answers a component built against another candidate under the same
  names, and such a component fails at the first call whose shape differs.
- A core module that imports `wasi_ephemeral_nn`, the older form of the
  interface, is not supported.
- The names of the input and output tensors are an agreement between your
  backend and your guests. The interface does not define any.
