-module(wasi_nn_test_backend).
-moduledoc """
A `wasi_nn` backend for `wasm_wasi2_nn_SUITE`: it runs no model. `compute`
answers the input in upper case, or misbehaves when the input asks for it,
and every callback reports itself to the process named in the backend
options, so a case can assert what the host called and how often.
""".
-behaviour(wasi_nn).

-export([load_by_name/2, init_execution_context/1, compute/2, close/1]).

load_by_name(<<"crash">>, _Opts) ->
    error(boom);
load_by_name(<<"absent">>, _Opts) ->
    {error, {not_found, <<"the backend has no such model">>}};
load_by_name(Name, #{owner := Owner}) ->
    Owner ! {nn, load, Name},
    {ok, {Name, Owner}}.

init_execution_context({<<"no-context">>, _Owner}) ->
    {error, {too_large, <<"no room for a context">>}};
init_execution_context({Name, Owner}) ->
    {ok, {Name, Owner}}.

compute({_Name, Owner}, Inputs) ->
    Owner ! {nn, compute, Inputs},
    [{_First, #{dimensions := Dims, data := Data}} | _] = Inputs,
    case Data of
        <<"timeout">> ->
            {error, {timeout, <<"too slow">>}};
        <<"raise">> ->
            error(boom);
        <<"shape">> ->
            {ok, not_a_list};
        <<"type">> ->
            {ok, [{<<"output">>, #{dimensions => [1], type => f128,
                                   data => <<>>}}]};
        <<"code:", Code/binary>> ->
            {error, {binary_to_existing_atom(Code), <<"as asked">>}};
        <<"code">> ->
            {error, {no_such_code, <<"a code the interface lacks">>}};
        <<"big">> ->
            {ok, [{<<"output">>,
                   #{dimensions => [1], type => u8,
                     data => binary:copy(<<0>>, 17 * 1024 * 1024)}}]};
        _ ->
            {ok, [{<<"output">>,
                   #{dimensions => [byte_size(Data)], type => u8,
                     data => string:uppercase(Data)}},
                  {<<"shape">>,
                   #{dimensions => Dims ++ [2, 3], type => fp32,
                     data => <<1.5:32/float-little>>}}]}
    end.

close({Kind, {Name, Owner}}) ->
    Owner ! {nn, close, Kind, Name},
    ok.
