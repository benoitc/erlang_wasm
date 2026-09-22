-module(fake_component_adapter).
-moduledoc """
An adapter that runs a real `wasi:cli/command` component through the worker.

It proves the kernel's component runtime: `prepare/3` returns a spec with
`runtime => component`, the component binary as its module, the WASI command
imports (stdin from the request, stdout captured), and an invoke that names the
`wasi:cli/run.run` export with its Canonical ABI signature. No
`snapshot_capability/1`, so the worker runs the cold no-image path (component
snapshot with live resources is deferred).

A request is `#{stdin => binary()}`; the result is `#{stdout => binary()}`.
""".

-behaviour(wasm_worker_adapter).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2]).

-define(VERSION, ~"fake-component-1").
-define(RUN_SIG, {[], {result, none, none}}).

artifact(Opts) ->
    Path = maps:get(path, Opts, default_path()),
    case file:read_file(Path) of
        {ok, Bin}       -> {ok, #{component => Bin}};
        {error, Reason} -> {error, wasm_worker_error:runtime(Reason)}
    end.

default_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..", "test",
                   "fixtures", "component", "realupper.component.wasm"]).

requirements(Request, _Artifact) when is_map(Request) ->
    {ok, #{min_timeout => 1000, min_memory_pages => 1,
           request_bytes => erlang:external_size(Request),
           staged_bytes => 0, staged_files => 0, mounts => #{}}};
requirements(_Request, _Artifact) ->
    {error, wasm_worker_error:adapter(adapter_failure, ~"request is not a map", #{})}.

prepare(Request, #{component := Bin}, _Env) ->
    Stdin = maps:get(stdin, Request, <<>>),
    Collector = ets:new(component_stdout, [public, ordered_set]),
    Sink = fun(Bytes) ->
               ets:insert(Collector, {erlang:unique_integer([monotonic]), Bytes}),
               ok
           end,
    Imports = wasi_preview2:command(#{stdin => Stdin, stdout => Sink}),
    RunExport = run_export(Bin),
    {ok, #{mode => command, runtime => component, module => Bin,
           imports => #{bindings => Imports, snapshot_hooks => #{},
                        compatibility_key => ?VERSION},
           invoke => [{call, RunExport, ?RUN_SIG, []}]},
     #{collector => Collector}}.

%% The command's run export, e.g. wasi:cli/run@0.2.0#run, read from the
%% component's exported interface (its version is whatever the toolchain
%% emitted). Decode names the exports without instantiating.
run_export(Bin) ->
    {ok, Decoded} = wasm_component:decode(Bin),
    Exports = maps:get(exports, Decoded),
    [Interface | _] = [E || E <- Exports,
                            binary:match(E, ~"wasi:cli/run") =/= nomatch],
    <<Interface/binary, "#run">>.

decode(#{outcome := returned}, #{collector := Collector}) ->
    {ok, #{stdout => collect(Collector)}};
decode(#{outcome := trapped, error := E}, _State) ->
    {error, wasm_worker_error:runtime(E)};
decode(#{outcome := exited, exit := Code}, _State) ->
    {error, wasm_worker_error:adapter(exit, ~"exited", #{code => Code})}.

collect(Collector) ->
    Bytes = iolist_to_binary([B || {_Seq, B} <- ets:tab2list(Collector)]),
    Bytes.

cleanup(#{collector := Collector}) ->
    try ets:delete(Collector) catch _:_ -> ok end,
    ok.

capabilities(_Artifact) ->
    #{execution => command,
      input_channels => [typed_args],
      result_channels => [typed_result],
      snapshots => unsupported,
      wasi => true}.

conformance_fixtures(_Artifact) ->
    #{base => #{}, by_capability => #{}}.

classify({ok, _}, _State)    -> continue;
classify({error, _}, _State) -> {stop, trapped}.
