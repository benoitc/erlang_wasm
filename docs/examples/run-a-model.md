# Run a model from a component

This example runs a component that asks the host for inference through
`wasi:nn`. The component does not hold a model: it names one, hands over a
tensor, and reads the tensor that comes back. The host hands the work to a
**backend**, an Erlang module of yours. The backend here runs no model. It
answers the text in upper case, so that you can see every step without an
inference engine.

**You need:** a checkout of this repository, which has the component in
`test/fixtures/component/` and the backend in `examples/`.

```erlang
{ok, _} = application:ensure_all_started(wasm).
```

## Who holds what

```text
  component                host (wasi_nn)                backend (nn_upper)
  ---------                --------------                ------------------
  load-by-name "echo" ---> is "echo" granted? ---------> load_by_name/2
                           keeps the graph  <----------- {ok, Graph}
  tensor(text)        ---> keeps the bytes, counts them
  compute(tensor)     ---> frees the input  -----------> compute/2
                           keeps the output <----------- {ok, [Output]}
  output.data()       <--- the bytes
  drops everything    ---> gives the bytes back -------> close/1
```

The component only ever holds handles: small numbers that name a graph or a
tensor the host keeps.

## Load the backend

A backend is a module with four functions. This one is `examples/nn_upper.erl`:

<!-- check: parse "the module is examples/nn_upper.erl, compiled below" -->
```erlang
-module(nn_upper).
-behaviour(wasi_nn).

-export([load_by_name/2, init_execution_context/1, compute/2, close/1]).

%% The guest asked for a model by a name you granted. Find it, or load it.
load_by_name(Name, _BackendOpts) ->
    {ok, #{model => Name}}.

%% One inference session on that model.
init_execution_context(Graph) ->
    {ok, Graph}.

%% Run the model. The input is a `u8` tensor holding text; so is the answer.
compute(_Context, [{_Name, #{type := u8, data := Text}} | _]) ->
    Reply = string:uppercase(Text),
    {ok, [{~"output", #{dimensions => [byte_size(Reply)],
                        type => u8,
                        data => Reply}}]};
compute(_Context, _Inputs) ->
    {error, {invalid_argument, ~"one u8 tensor of text is expected"}}.

%% The guest dropped a graph or a context: free what it holds.
close(_GraphOrContext) ->
    ok.
```

It is not part of the library, so compile and load it:

```erlang
{ok, nn_upper, Beam} = compile:file("examples/nn_upper.erl", [binary]),
{module, nn_upper} = code:load_binary(nn_upper, "examples/nn_upper.erl", Beam).
```

## Grant a model and run the component

`nncommand` is a command built by `rustc --target wasm32-wasip2`. It reads
stdin, loads the model named `echo`, runs it on what it read, and writes the
answer to stdout. The `nn` option names the backend and the models the
component may load:

```erlang
{ok, Guest} = file:read_file("test/fixtures/component/nncommand.component.wasm"),
Grant = #{backend => nn_upper, models => [~"echo"]},
wasi_preview2:run_command(Guest, ~"once upon a time", #{nn => Grant}).
%% => {ok, #{exit_code := 0, stdout := ~"ONCE UPON A TIME"}}
```

## Leave the model out of the grant

The component asks for `echo`. Grant another name, and the host answers
`not-found` without calling the backend. This component treats that as
fatal: it panics, which in WebAssembly is a trap, and you get the trap as an
error:

```erlang
Other = #{backend => nn_upper, models => [~"another"]},
wasi_preview2:run_command(Guest, ~"once upon a time", #{nn => Other}).
%% => {error, #{class := trap, kind := unreachable}}
```

A component that handles the error reads its code and message instead; see
[What the guest can do](../wasi-nn.md#what-the-guest-can-do).

Without the `nn` option at all, the component is refused before it runs,
because nothing supplies the `wasi:nn` imports:

```erlang
{error, _} = wasi_preview2:run_command(Guest, ~"once upon a time", #{}).
```

**What happened.** The component imported `wasi:nn`. The host answered every
import from Erlang and called your module for the three things only an
engine can do: find the model, start a session, run it.

- The grant decided which model names the component could load.
- The host held the tensors and counted their bytes; the component held
  handles.
- The backend saw plain Erlang terms: a name, and a map with `dimensions`,
  `type` and `data`.

To connect a real engine, keep the shape of `nn_upper` and call the engine
in `compute/2`.

## Read this next

This is the last example. Go on with [Hold modules and
instances](../embedding.md).
The guide behind this example: [wasi-nn](../wasi-nn.md).
