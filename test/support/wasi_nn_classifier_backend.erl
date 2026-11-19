-module(wasi_nn_classifier_backend).
-moduledoc """
A second `wasi_nn` backend for the suites, shaped like an engine for tensor
models: it loads a model from bytes, checks the input against the rule of
the interface with `wasi_nn:check_tensor/1`, and answers 1001 class scores
as `fp32`. It runs no model: the class it ranks first comes from the backend
options, by the format of the model or by its name.

Every callback reports itself to the process named in the backend options.
""".
-behaviour(wasi_nn).

-export([load/4, load_by_name/2, init_execution_context/1, compute/2,
         close/1]).

-define(CLASSES, 1001).
-define(SHAPE, [1, 3, 224, 224]).

load([], _Encoding, _Target, _Opts) ->
    {error, {invalid_argument, <<"no model">>}};
load(Builders, Encoding, Target, #{owner := Owner} = Opts) ->
    Owner ! {nn, load, Encoding, Target, [byte_size(B) || B <- Builders]},
    {ok, #{owner => Owner, class => class(Encoding, Opts)}}.

load_by_name(Name, #{owner := Owner} = Opts) ->
    Owner ! {nn, load_by_name, Name},
    {ok, #{owner => Owner, class => class(Name, Opts)}}.

init_execution_context(Graph) ->
    {ok, Graph}.

compute(#{owner := Owner, class := Class},
        [{Name, #{dimensions := Dims, type := Type} = Tensor}]) ->
    Owner ! {nn, compute, Name, Dims, Type,
             byte_size(maps:get(data, Tensor))},
    case {wasi_nn:check_tensor(Tensor), Dims, Type} of
        {ok, ?SHAPE, fp32} ->
            {ok, [{<<"output">>, #{dimensions => [1, ?CLASSES],
                                   type => fp32,
                                   data => scores(Class)}}]};
        {ok, _, _} ->
            {error, {invalid_argument, <<"not the shape of the model">>}};
        {{error, _} = Error, _, _} ->
            Error
    end;
compute(_Context, _Inputs) ->
    {error, {invalid_argument, <<"one input is expected">>}}.

close(_Resource) ->
    ok.

class(Key, Opts) ->
    maps:get(Key, maps:get(classes, Opts, #{}), 0).

scores(Class) ->
    << <<(score(I, Class)):32/float-little>>
       || I <- lists:seq(0, ?CLASSES - 1) >>.

score(Class, Class) -> 9.0;
score(_I, _Class)   -> 0.0.
