-module(fake_component_stateful_adapter).
-moduledoc """
An adapter that runs the `statecore` component through the worker.

`statecore` increments a mutable global and returns the new value, so the result
shows whether the worker gave the request a fresh instance: a cold instance per
request returns 1 every time, a reused one would climb. Two requests both returning
1 is the isolation proof. The export is `bump: func() -> u32`.

A request is any map; the result is `#{value => N}`.
""".

-behaviour(wasm_worker_adapter).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2]).

-define(VERSION, ~"fake-component-stateful-1").
-define(RUN_SIG, {[], u32}).

artifact(Opts) ->
    Path = maps:get(path, Opts, default_path()),
    case file:read_file(Path) of
        {ok, Bin}       -> {ok, #{component => Bin}};
        {error, Reason} -> {error, wasm_worker_error:runtime(Reason)}
    end.

default_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..", "test",
                   "fixtures", "component", "statecore.component.wasm"]).

requirements(Request, _Artifact) when is_map(Request) ->
    {ok, #{min_timeout => 1000, min_memory_pages => 1,
           request_bytes => erlang:external_size(Request),
           staged_bytes => 0, staged_files => 0, mounts => #{}}};
requirements(_Request, _Artifact) ->
    {error, wasm_worker_error:adapter(adapter_failure, ~"request is not a map", #{})}.

prepare(_Request, #{component := Bin}, _Env) ->
    {ok, #{mode => reactor, runtime => component, module => Bin,
           imports => #{bindings => #{}, snapshot_hooks => #{},
                        compatibility_key => ?VERSION},
           invoke => [{call, ~"bump", ?RUN_SIG, []}]},
     undefined}.

decode(#{outcome := returned, values := [Value]}, _State) ->
    {ok, #{value => Value}};
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
