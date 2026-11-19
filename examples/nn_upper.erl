-module(nn_upper).
-moduledoc """
The smallest `wasi_nn` backend: it runs no model, and answers its input in
upper case.

It is here to read and copy when you connect an inference engine to a
component that imports `wasi:nn`. Each callback is where a real backend
calls its engine. `docs/examples/run-a-model.md` runs it, and
`docs/wasi-nn.md` is the guide.
""".
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
