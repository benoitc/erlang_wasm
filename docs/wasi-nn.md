# wasi-nn

`wasi:nn` lets a component ask the host to run a machine-learning model. The
component does not contain the model or the engine: it names a model, hands
over input tensors, and gets output tensors back. The host runs the model
natively, so it is as fast as the engine you plug in. Read this page when
your component imports `wasi:nn`, or when you write the module that connects
an inference engine to the runtime.

The runtime has no inference engine of its own. You give it a **backend**: an
Erlang module that implements the `wasi_nn` behaviour and calls the engine.

## Words used on this page

| word | meaning |
| --- | --- |
| **backend** | your module, which implements the `wasi_nn` callbacks and runs the model |
| **graph** | a loaded model, as the guest sees it |
| **execution context** | one inference session on a graph |
| **tensor** | a block of numbers: its dimensions, the type of its elements, and its raw bytes |
| **grant** | the `nn` option: the backend, and the model names a guest may load |

## Grant it to a component

Pass an `nn` key in the options of `wasi_preview2:command/1`,
`wasi_preview2:run_command/3` or the WASI 0.3 runners:

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
| `backend_opts` | any term, handed to your `load_by_name/2` unchanged | `undefined` |

Without the `nn` key the interface is absent, and a component that imports
`wasi:nn` is refused when you instantiate it.

A name that is not in `models` answers `not-found`, exactly as a name your
backend does not know. So a guest cannot find out which models you have.

## Write a backend

A backend exports four functions. This one answers its input unchanged:

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
| `init_execution_context(Graph)` | the guest starts a session | `{ok, Context}` |
| `compute(Context, Inputs)` | the guest runs the model | `{ok, Outputs}` |
| `close({graph, Graph})`, `close({context, Context})` | the guest drops it, or its instance is destroyed | `ok` |

`Graph` and `Context` are your own terms. The runtime keeps them and gives
them back; it does not look inside.

`Inputs` and `Outputs` are lists of `{Name, Tensor}`. A tensor is a map:

| key | value |
| --- | --- |
| `dimensions` | a list of sizes, such as `[1, 3, 224, 224]` |
| `type` | `fp16`, `fp32`, `fp64`, `bf16`, `u8`, `i32` or `i64` |
| `data` | a binary: the elements, as the engine lays them out |

The runtime does not check that `data` has the length `dimensions` implies.
Guests that send text commonly send it as `u8` with dimensions `[1]`, so
check what your engine needs in `compute/2`.

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
| `graph.load(bytes, encoding, target)` | `unsupported-operation`: a model is loaded by name |
| `graph.init-execution-context()` | your `init_execution_context/1` |
| `graph-execution-context.compute(inputs)` | your `compute/2` |
| `tensor` constructor, `dimensions`, `ty`, `data` | answered by the runtime, which holds the tensor |
| `error.code`, `error.data` | the code and message you answered |

`compute` takes ownership of its input tensors: they are freed when the call
returns, whatever the answer.

## Limits

- **Tensor bytes.** The host holds every tensor. All the live tensors of one
  process may hold 16 MiB together. Over that, creating a tensor traps with
  `nn_tensor_limit_reached`, and a `compute` whose outputs do not fit answers
  `too-large`. Dropping a tensor gives its bytes back.
- **Handles.** A graph, a context, a tensor and an error are each one host
  resource. `resource_limit` bounds how many are live.
- **Time.** `compute` blocks until your backend answers. `fuel` does not
  count that time: fuel counts WebAssembly work. Bound it in your backend, or
  run the component in a worker with a timeout; see [Using workers](worker.md).
- **Snapshots.** A component that imports `wasi:nn` cannot be captured in a
  snapshot.
- **Streaming.** `compute` answers once, with every output. The interface
  has no way to return tokens as they are generated.

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

## Notes

- The interface is `wasi:nn@0.2.0-rc-2024-10-28`, a release candidate. The
  host answers a component built against another candidate under the same
  names, and such a component fails at the first call whose shape differs.
- A core module that imports `wasi_ephemeral_nn`, the older form of the
  interface, is not supported.
- The names of the input and output tensors are an agreement between your
  backend and your guests. The interface does not define any.
