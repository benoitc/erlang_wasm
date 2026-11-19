-module(wasi_nn).
-moduledoc """
The `wasi:nn` host: a component asks the host to run a model, and a backend
you name runs it natively.

`imports/1` builds the `wasi:nn/tensor`, `wasi:nn/graph`, `wasi:nn/inference`
and `wasi:nn/errors` imports of `wasi:nn@0.2.0-rc-2024-10-28`. The runtime
holds no inference engine: a backend is a module that implements this
module's callbacks, and it lives in another application.

Read it when you write a backend, or when you change what a guest may load.
The guide is `docs/wasi-nn.md`.

What the module itself decides:

- A guest loads a model by name, and only a name in the grant's `models`.
  Any other name answers `not-found`.
- A guest brings a model as bytes, with `load`, only in a format the grant's
  `encodings` lists and only when the backend has the optional `load`
  callback. Otherwise `load` answers `unsupported-operation`.
- A tensor is held by the host. The bytes of every live tensor of one
  process are counted, and the grant's `max_tensor_bytes` is the bound,
  16 MiB when left out. Over it, the tensor constructor traps with
  `nn_tensor_limit_reached` and `compute` answers `too-large`.
- `compute` takes ownership of its input tensors, as the interface says, and
  frees them whatever the backend answers.
- A backend that raises, or answers a term of another shape, gives the guest
  a `runtime-error`. Nothing a guest or a backend supplies makes an import
  raise, except the trap above.

It never calls `wasi_preview2`, which calls it.
""".

-export([imports/1, close_resource/1, check_tensor/1]).

-export_type([grant/0, tensor/0, tensor_type/0, error/0, error_code/0,
              encoding/0, target/0]).

-doc """
The `nn` grant: the backend module, the model names this guest may load, the
model formats it may bring as bytes, the bound on the tensor bytes the host
holds for it, and a term handed to the backend unchanged.
""".
-type grant() :: #{backend := module(),
                   models := [binary()],
                   encodings => [encoding()],
                   max_tensor_bytes => pos_integer(),
                   backend_opts => term()}.

-doc "The format of a model a guest brings as bytes.".
-type encoding() :: openvino | onnx | tensorflow | pytorch | tensorflowlite
                  | ggml | autodetect.

-doc "Where the guest asks for the model to run.".
-type target() :: cpu | gpu | tpu.

-doc "The element type of a tensor.".
-type tensor_type() :: fp16 | fp32 | fp64 | bf16 | u8 | i32 | i64.

-doc """
A tensor: its dimensions, its element type and its raw bytes. The runtime
does not check the dimensions against the length of the data; a backend
checks what it needs.
""".
-type tensor() :: #{dimensions := [non_neg_integer()],
                    type := tensor_type(),
                    data := binary()}.

-doc "An error code of `wasi:nn/errors`.".
-type error_code() :: invalid_argument | invalid_encoding | timeout
                    | runtime_error | unsupported_operation | too_large
                    | not_found | security | unknown.

-doc "What a backend answers on failure: a code and a message in UTF-8.".
-type error() :: {error_code(), Message :: binary()}.

-doc "Load the model the guest calls `Name`. `Name` is in the grant.".
-callback load_by_name(Name :: binary(), BackendOpts :: term()) ->
    {ok, Graph :: term()} | {error, error()}.

-doc """
Load a model the guest brings as bytes: one binary for each part of the
model, in the guest's order. Optional. It is called only for an encoding in
the grant's `encodings`.
""".
-callback load(Builders :: [binary()], encoding(), target(),
               BackendOpts :: term()) ->
    {ok, Graph :: term()} | {error, error()}.

-doc "Start one inference session on a graph.".
-callback init_execution_context(Graph :: term()) ->
    {ok, Context :: term()} | {error, error()}.

-doc """
Run the model on named input tensors and answer named output tensors. The
call may block; the instance waits for it.
""".
-callback compute(Context :: term(), [{Name :: binary(), tensor()}]) ->
    {ok, [{Name :: binary(), tensor()}]} | {error, error()}.

-doc """
The guest dropped a graph or a context, or its instance was destroyed. Called
once for each.
""".
-callback close({graph | context, term()}) -> ok.

-optional_callbacks([load/4]).

-define(TENSOR, <<"wasi:nn/tensor">>).
-define(GRAPH, <<"wasi:nn/graph">>).
-define(INFERENCE, <<"wasi:nn/inference">>).
-define(ERRORS, <<"wasi:nn/errors">>).

%% The enums of the interface, in WIT order: the discriminant is the index.
-define(TENSOR_TYPE,
        {enum, [<<"FP16">>, <<"FP32">>, <<"FP64">>, <<"BF16">>, <<"U8">>,
                <<"I32">>, <<"I64">>]}).
-define(ENCODING,
        {enum, [<<"openvino">>, <<"onnx">>, <<"tensorflow">>, <<"pytorch">>,
                <<"tensorflowlite">>, <<"ggml">>, <<"autodetect">>]}).
-define(TARGET, {enum, [<<"cpu">>, <<"gpu">>, <<"tpu">>]}).
-define(ERROR_CODE,
        {enum, [<<"invalid-argument">>, <<"invalid-encoding">>,
                <<"timeout">>, <<"runtime-error">>,
                <<"unsupported-operation">>, <<"too-large">>,
                <<"not-found">>, <<"security">>, <<"unknown">>]}).
-define(NAMED_TENSORS, {list, {tuple, [string, handle]}}).
%% `result<T, error>`, where both arms are handles of host resources.
-define(HANDLE_RESULT, {result, handle, handle}).

%% The bytes every live tensor of one process may hold together, when the
%% grant does not say.
-define(MAX_TENSOR_BYTES, 16 * 1024 * 1024).
%% The live tensor bytes of this process. It is never below the truth, and
%% `reserve/1' counts again before it refuses.
-define(BYTES, {?MODULE, tensor_bytes}).
%% The longest error message handed to a guest.
-define(MAX_MESSAGE_BYTES, 1024).

-doc """
The `wasi:nn` imports for one grant.

Merge the map into the imports you instantiate a component with, and pass
`resource_closer => fun wasi_nn:close_resource/1` in the options of
`wasm_component:instantiate/3`, and the same fun to
`wasm_component:destroy/2`. `wasi_preview2:command/1` does both when its
options hold an `nn` key.
""".
-spec imports(grant()) -> #{{binary(), binary()} => fun()}.
imports(#{backend := Backend, models := Models} = Grant)
  when is_atom(Backend), is_list(Models) ->
    BackendOpts = maps:get(backend_opts, Grant, undefined),
    Encodings = maps:get(encodings, Grant, []),
    Max = maps:get(max_tensor_bytes, Grant, ?MAX_TENSOR_BYTES),
    Fun = fun wasm_component:import_fun/2,
    #{{?TENSOR, <<"[constructor]tensor">>} =>
          Fun({[{list, u32}, ?TENSOR_TYPE, {list, u8}], handle},
              fun([Dims, Type, Data]) ->
                  new_tensor(Dims, Type, Data, Max)
              end),
      {?TENSOR, <<"[method]tensor.dimensions">>} =>
          Fun({[handle], {list, u32}},
              fun([H]) -> maps:get(dimensions, tensor(H)) end),
      {?TENSOR, <<"[method]tensor.ty">>} =>
          Fun({[handle], ?TENSOR_TYPE},
              fun([H]) -> type_name(maps:get(type, tensor(H))) end),
      {?TENSOR, <<"[method]tensor.data">>} =>
          Fun({[handle], {list, u8}},
              fun([H]) -> maps:get(data, tensor(H)) end),
      {?TENSOR, <<"[resource-drop]tensor">>} => drop_fun(),
      {?GRAPH, <<"load">>} =>
          Fun({[{list, {list, u8}}, ?ENCODING, ?TARGET], ?HANDLE_RESULT},
              fun([Builders, Encoding, Target]) ->
                  load(Backend, Encodings, BackendOpts, Builders,
                       encoding_atom(Encoding), target_atom(Target))
              end),
      {?GRAPH, <<"load-by-name">>} =>
          Fun({[string], ?HANDLE_RESULT},
              fun([Name]) ->
                  load_by_name(Backend, Models, BackendOpts, Name)
              end),
      {?GRAPH, <<"[method]graph.init-execution-context">>} =>
          Fun({[handle], ?HANDLE_RESULT},
              fun([H]) -> init_execution_context(H) end),
      {?GRAPH, <<"[resource-drop]graph">>} => drop_fun(),
      {?INFERENCE, <<"[method]graph-execution-context.compute">>} =>
          Fun({[handle, ?NAMED_TENSORS],
               {result, ?NAMED_TENSORS, handle}},
              fun([H, Inputs]) -> compute(H, Inputs, Max) end),
      {?INFERENCE, <<"[resource-drop]graph-execution-context">>} =>
          drop_fun(),
      {?ERRORS, <<"[method]error.code">>} =>
          Fun({[handle], ?ERROR_CODE},
              fun([H]) -> element(1, nn_error(H)) end),
      {?ERRORS, <<"[method]error.data">>} =>
          Fun({[handle], string},
              fun([H]) -> element(2, nn_error(H)) end),
      {?ERRORS, <<"[resource-drop]error">>} => drop_fun()}.

-doc """
Free what is behind one host resource of this module: the bytes of a tensor,
or a backend's graph or context. Any other resource is left alone, so the
fun can be chained with another closer.
""".
-spec close_resource({atom(), term()}) -> ok.
close_resource({nn_tensor, Tensor}) ->
    release(tensor_bytes(Tensor));
close_resource({nn_graph, {Backend, Graph}}) ->
    close(Backend, {graph, Graph});
close_resource({nn_context, {Backend, Context}}) ->
    close(Backend, {context, Context});
close_resource(_Other) ->
    ok.

-doc """
Check a tensor against the rule of the interface: the length of the data is
the product of the dimensions times the size of one element. A backend for a
model with fixed shapes calls it on each input; the host does not, because
guests that send text commonly send it with dimensions `[1]`.
""".
-spec check_tensor(tensor()) -> ok | {error, error()}.
check_tensor(#{dimensions := Dims, type := Type, data := Data}) ->
    Expected = lists:foldl(fun(D, Product) -> D * Product end,
                           element_bytes(Type), Dims),
    case byte_size(Data) of
        Expected ->
            ok;
        _ ->
            {error, {invalid_argument,
                     <<"the data length does not match the dimensions">>}}
    end.

element_bytes(u8)   -> 1;
element_bytes(fp16) -> 2;
element_bytes(bf16) -> 2;
element_bytes(fp32) -> 4;
element_bytes(i32)  -> 4;
element_bytes(fp64) -> 8;
element_bytes(i64)  -> 8.

%%% -------------------------------------------------------------- tensors ---

%% A constructor has no error arm, so the bound is a trap, as the bound on
%% host handles is.
new_tensor(Dims, Type, Data, Max) ->
    Tensor = #{dimensions => Dims, type => type_atom(Type), data => Data},
    case reserve(tensor_bytes(Tensor), Max) of
        ok ->
            wasm_component:host_new(nn_tensor, Tensor);
        full ->
            wasm_error:trap(nn_tensor_limit_reached, #{limit => Max})
    end.

%% The tensor behind a handle a method was called on. The methods of a tensor
%% have no error arm, and the binding only calls them on a handle it holds,
%% so anything else is the guest's fault.
tensor(Handle) ->
    case wasm_component:host_get(Handle) of
        {ok, {nn_tensor, Tensor}} -> Tensor;
        _ -> wasm_error:trap(resource_not_live, #{handle => Handle})
    end.

nn_error(Handle) ->
    case wasm_component:host_get(Handle) of
        {ok, {nn_error, Error}} -> Error;
        _ -> wasm_error:trap(resource_not_live, #{handle => Handle})
    end.

tensor_bytes(#{dimensions := Dims, data := Data}) ->
    byte_size(Data) + 4 * length(Dims).

reserve(Bytes, Max) ->
    case live_bytes() + Bytes =< Max of
        true ->
            put(?BYTES, live_bytes() + Bytes),
            ok;
        false ->
            %% The counter is above the truth when an instance of this
            %% process was destroyed without the closer. Count before
            %% refusing.
            Counted = count_bytes(),
            case Counted + Bytes =< Max of
                true  -> put(?BYTES, Counted + Bytes), ok;
                false -> put(?BYTES, Counted), full
            end
    end.

release(Bytes) ->
    put(?BYTES, max(0, live_bytes() - Bytes)),
    ok.

live_bytes() ->
    case get(?BYTES) of
        undefined -> 0;
        Bytes -> Bytes
    end.

count_bytes() ->
    lists:foldl(
      fun(Handle, Sum) ->
          case wasm_component:host_get(Handle) of
              {ok, {nn_tensor, Tensor}} -> Sum + tensor_bytes(Tensor);
              _ -> Sum
          end
      end, 0, wasm_component:host_live()).

%%% --------------------------------------------------- graphs and contexts ---

%% A name outside the grant answers as a name the backend does not know, so
%% a guest cannot learn which models exist.
load_by_name(Backend, Models, BackendOpts, Name) ->
    case lists:member(Name, Models) of
        true ->
            case call(Backend, load_by_name, [Name, BackendOpts]) of
                {ok, Graph} ->
                    {ok, wasm_component:host_new(nn_graph,
                                                 {Backend, Graph})};
                {error, Error} ->
                    failure(Error)
            end;
        false ->
            failure({not_found, <<"no such model">>})
    end.

%% A model as bytes is the guest's own file read by a native engine, so it
%% takes a grant of its own: the format must be listed, and the backend must
%% be able to load one.
load(Backend, Encodings, BackendOpts, Builders, Encoding, Target) ->
    _ = code:ensure_loaded(Backend),
    case lists:member(Encoding, Encodings)
        andalso erlang:function_exported(Backend, load, 4) of
        true ->
            Args = [Builders, Encoding, Target, BackendOpts],
            case call(Backend, load, Args) of
                {ok, Graph} ->
                    {ok, wasm_component:host_new(nn_graph,
                                                 {Backend, Graph})};
                {error, Error} ->
                    failure(Error)
            end;
        false ->
            failure({unsupported_operation,
                     <<"this host does not load a model of this format "
                       "from bytes">>})
    end.

init_execution_context(Handle) ->
    case wasm_component:host_get(Handle) of
        {ok, {nn_graph, {Backend, Graph}}} ->
            case call(Backend, init_execution_context, [Graph]) of
                {ok, Context} ->
                    {ok, wasm_component:host_new(nn_context,
                                                 {Backend, Context})};
                {error, Error} ->
                    failure(Error)
            end;
        _ ->
            failure({invalid_argument, <<"not a graph">>})
    end.

%% The inputs are `own' handles: the guest gave the tensors away, so they are
%% freed here whatever happens next.
compute(Handle, Inputs, Max) ->
    Taken = take_inputs(Inputs),
    case wasm_component:host_get(Handle) of
        {ok, {nn_context, {Backend, Context}}} ->
            case Taken of
                {ok, Named} -> run(Backend, Context, Named, Max);
                error -> failure({invalid_argument, <<"not a tensor">>})
            end;
        _ ->
            failure({invalid_argument, <<"not an execution context">>})
    end.

%% Only a handle that names a tensor is taken: a guest that passes another
%% resource as a tensor keeps it, and reads `invalid-argument'.
take_inputs(Inputs) ->
    Found = [{Name, H, wasm_component:host_get(H)} || {Name, H} <- Inputs],
    Handles = [H || {_Name, H, {ok, {nn_tensor, _Tensor}}} <- Found],
    lists:foreach(fun drop/1, lists:usort(Handles)),
    case length(Handles) =:= length(Inputs) of
        true ->
            {ok, [{Name, T} || {Name, _H, {ok, {nn_tensor, T}}} <- Found]};
        false ->
            error
    end.

run(Backend, Context, Named, Max) ->
    case call(Backend, compute, [Context, Named]) of
        {ok, Outputs} ->
            case valid_outputs(Outputs) of
                true  -> keep_outputs(Outputs, Max);
                false -> failure(bad_answer())
            end;
        {error, Error} ->
            failure(Error)
    end.

keep_outputs(Outputs, Max) ->
    Bytes = lists:sum([tensor_bytes(T) || {_Name, T} <- Outputs]),
    case reserve(Bytes, Max) of
        ok ->
            {ok, [{Name, wasm_component:host_new(nn_tensor, T)}
                  || {Name, T} <- Outputs]};
        full ->
            failure({too_large, <<"the outputs are over the tensor bound">>})
    end.

valid_outputs(Outputs) when is_list(Outputs) ->
    lists:all(fun valid_output/1, Outputs);
valid_outputs(_Other) ->
    false.

valid_output({Name, #{dimensions := Dims, type := Type, data := Data} = T})
  when is_binary(Name), is_list(Dims), is_binary(Data), map_size(T) =:= 3 ->
    is_utf8(Name) andalso is_type(Type)
        andalso lists:all(fun is_u32/1, Dims);
valid_output(_Other) ->
    false.

is_u32(N) -> is_integer(N) andalso N >= 0 andalso N =< 16#FFFFFFFF.

%%% ---------------------------------------------------------------- drops ---

%% A component with one core module drops through this import. A linked one
%% drops through the instance's `resource_closer', which is
%% `close_resource/1'. Each path closes once.
drop_fun() ->
    fun(_Ctx, [Handle]) -> drop(Handle), {ok, []} end.

drop(Handle) ->
    case wasm_component:host_get(Handle) of
        {ok, Resource} -> ok = close_resource(Resource);
        error -> ok
    end,
    wasm_component:host_drop(Handle).

%%% -------------------------------------------------------------- backend ---

%% Call the backend. A raise, or an answer of another shape, is an error the
%% guest reads; it does not reach the caller of the import.
call(Backend, Function, Args) ->
    try apply(Backend, Function, Args) of
        {ok, _Value} = Ok -> Ok;
        {error, {Code, Message}} when is_atom(Code), is_binary(Message) ->
            {error, {Code, Message}};
        _Other -> {error, bad_answer()}
    catch
        _Class:_Reason -> {error, {runtime_error, <<"the backend failed">>}}
    end.

close(Backend, Resource) ->
    try Backend:close(Resource) of
        _ -> ok
    catch
        _Class:_Reason -> ok
    end.

bad_answer() ->
    {runtime_error, <<"the backend gave an answer of the wrong shape">>}.

%% The error arm of a result: a new `error' resource the guest reads and
%% drops.
failure({Code, Message}) ->
    {error, wasm_component:host_new(nn_error,
                                    {code_name(Code), message(Message)})}.

message(Message) when byte_size(Message) =< ?MAX_MESSAGE_BYTES ->
    case is_utf8(Message) of
        true  -> Message;
        false -> <<"error">>
    end;
message(_TooLong) ->
    <<"error">>.

is_utf8(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Bin -> true;
        _ -> false
    end.

%%% ---------------------------------------------------------------- names ---

%% Fixed tables in both directions: a name a guest sends is an index into
%% the enum above, and no text becomes an atom.
type_atom(<<"FP16">>) -> fp16;
type_atom(<<"FP32">>) -> fp32;
type_atom(<<"FP64">>) -> fp64;
type_atom(<<"BF16">>) -> bf16;
type_atom(<<"U8">>)   -> u8;
type_atom(<<"I32">>)  -> i32;
type_atom(<<"I64">>)  -> i64.

type_name(fp16) -> <<"FP16">>;
type_name(fp32) -> <<"FP32">>;
type_name(fp64) -> <<"FP64">>;
type_name(bf16) -> <<"BF16">>;
type_name(u8)   -> <<"U8">>;
type_name(i32)  -> <<"I32">>;
type_name(i64)  -> <<"I64">>.

encoding_atom(<<"openvino">>)       -> openvino;
encoding_atom(<<"onnx">>)           -> onnx;
encoding_atom(<<"tensorflow">>)     -> tensorflow;
encoding_atom(<<"pytorch">>)        -> pytorch;
encoding_atom(<<"tensorflowlite">>) -> tensorflowlite;
encoding_atom(<<"ggml">>)           -> ggml;
encoding_atom(<<"autodetect">>)     -> autodetect.

target_atom(<<"cpu">>) -> cpu;
target_atom(<<"gpu">>) -> gpu;
target_atom(<<"tpu">>) -> tpu.

is_type(Type) ->
    lists:member(Type, [fp16, fp32, fp64, bf16, u8, i32, i64]).

code_name(invalid_argument)      -> <<"invalid-argument">>;
code_name(invalid_encoding)      -> <<"invalid-encoding">>;
code_name(timeout)               -> <<"timeout">>;
code_name(runtime_error)         -> <<"runtime-error">>;
code_name(unsupported_operation) -> <<"unsupported-operation">>;
code_name(too_large)             -> <<"too-large">>;
code_name(not_found)             -> <<"not-found">>;
code_name(security)              -> <<"security">>;
code_name(_Other)                -> <<"unknown">>.
