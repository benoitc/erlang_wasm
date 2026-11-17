-module(fake_component_snapshot_adapter).
-moduledoc """
The `statecore` component through the worker, started from a snapshot.

Its init bumps the mutable global twice before the capture, so a request
restored from the image answers 3 on its first `bump`, and every request does:
each starts from the image, never from the last request. `version` in the
options gives the image's init version and `key` its compatibility key, for
two pools that must not share.

A request is any map; the result is `#{value => N}`.
""".

-behaviour(wasm_worker_adapter).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2,
         snapshot_capability/1]).
-export([captures/0, reset_captures/0]).

-define(RUN_SIG, {[], u32}).
-define(COUNT, {?MODULE, captures}).

artifact(Opts) ->
    {ok, Bin} = file:read_file(filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                                              "test", "fixtures", "component",
                                              "statecore.component.wasm"])),
    {ok, #{component => Bin, version => maps:get(version, Opts, ~"fake-component-snapshot-1"),
           key => maps:get(key, Opts, ~"fake-component-snapshot-1")}}.

requirements(Request, _Artifact) when is_map(Request) ->
    {ok, #{min_timeout => 1000, min_memory_pages => 1,
           request_bytes => erlang:external_size(Request),
           staged_bytes => 0, staged_files => 0, mounts => #{}}};
requirements(_Request, _Artifact) ->
    {error, wasm_worker_error:adapter(adapter_failure, ~"request is not a map", #{})}.

prepare(_Request, #{component := Bin, key := Key}, _Env) ->
    {ok, #{mode => reactor, runtime => component, module => Bin,
           imports => import_set(Key),
           invoke => [{call, ~"bump", ?RUN_SIG, []}]},
     undefined}.

import_set(Key) ->
    #{bindings => #{}, snapshot_hooks => #{}, compatibility_key => Key}.

snapshot_capability(#{component := Bin, version := V, key := Key}) ->
    #{version => V, runtime => component, module => Bin,
      imports => import_set(Key),
      init => [{call, ~"bump", ?RUN_SIG, []}, {call, ~"bump", ?RUN_SIG, []}],
      validate => fun(_Inst) -> counted() end,
      post_restore => fun(_Inst, _Info) -> ok end}.

counted() ->
    persistent_term:put(?COUNT, captures() + 1),
    ok.

captures() -> persistent_term:get(?COUNT, 0).

reset_captures() -> persistent_term:put(?COUNT, 0).

decode(#{outcome := returned, values := [Value]}, _State) ->
    {ok, #{value => Value}};
decode(#{outcome := trapped, error := E}, _State) ->
    {error, wasm_worker_error:runtime(E)};
decode(#{outcome := exited, exit := Code}, _State) ->
    {error, wasm_worker_error:adapter(exit, ~"exited", #{code => Code})}.

cleanup(_State) -> ok.

capabilities(#{version := V}) ->
    #{execution => reactor,
      input_channels => [typed_args],
      result_channels => [typed_result],
      snapshots => #{version => V},
      wasi => false}.

conformance_fixtures(_Artifact) ->
    #{base => #{}, by_capability => #{}}.

classify({ok, _}, _State)    -> continue;
classify({error, _}, _State) -> {stop, trapped}.
