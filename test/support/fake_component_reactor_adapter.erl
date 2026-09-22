-module(fake_component_reactor_adapter).
-moduledoc """
An adapter that calls a component's typed export per request.

Unlike the command adapter (which calls `wasi:cli/run.run` and reads stdout),
this passes typed input to a component function and lifts its typed result: the
reactor/service shape. It runs the `echo` fixture, whose export is
`run: func(list<u8>) -> result<list<u8>, string>` (it upper-cases non-empty
input and refuses empty input), so a request's bytes come back through the
Canonical ABI, ok or error arm. This proves the worker runs any component
signature, not only a command.

A request is `#{input => binary()}`; the result is `#{output => binary()}`.
""".

-behaviour(wasm_worker_adapter).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2]).

-define(VERSION, ~"fake-component-reactor-1").
-define(RUN_SIG, {[{list, u8}], {result, {list, u8}, string}}).

artifact(Opts) ->
    Path = maps:get(path, Opts, default_path()),
    case file:read_file(Path) of
        {ok, Bin}       -> {ok, #{component => Bin}};
        {error, Reason} -> {error, wasm_worker_error:runtime(Reason)}
    end.

default_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..", "test",
                   "fixtures", "component", "echo.component.wasm"]).

requirements(Request, _Artifact) when is_map(Request) ->
    {ok, #{min_timeout => 1000, min_memory_pages => 1,
           request_bytes => erlang:external_size(Request),
           staged_bytes => 0, staged_files => 0, mounts => #{}}};
requirements(_Request, _Artifact) ->
    {error, wasm_worker_error:adapter(adapter_failure, ~"request is not a map", #{})}.

prepare(Request, #{component := Bin}, _Env) ->
    Input = maps:get(input, Request, <<>>),
    {ok, #{mode => reactor, runtime => component, module => Bin,
           imports => #{bindings => #{}, snapshot_hooks => #{},
                        compatibility_key => ?VERSION},
           invoke => [{call, ~"run", ?RUN_SIG, [Input]}]},
     undefined}.

decode(#{outcome := returned, values := [{ok, Output}]}, _State) ->
    {ok, #{output => Output}};
decode(#{outcome := returned, values := [{error, Message}]}, _State) ->
    {error, wasm_worker_error:adapter(adapter_failure, ~"the service refused",
                                      #{message => Message})};
decode(#{outcome := trapped, error := E}, _State) ->
    {error, wasm_worker_error:runtime(E)};
decode(#{outcome := exited, exit := Code}, _State) ->
    {error, wasm_worker_error:adapter(exit, ~"exited", #{code => Code})}.

cleanup(_State) -> ok.

capabilities(_Artifact) ->
    #{execution => reactor,
      input_channels => [typed_args],
      result_channels => [typed_result],
      snapshots => unsupported,
      wasi => false}.

conformance_fixtures(_Artifact) ->
    #{base => #{}, by_capability => #{}}.

classify({ok, _}, _State)    -> continue;
classify({error, _}, _State) -> {stop, trapped}.
