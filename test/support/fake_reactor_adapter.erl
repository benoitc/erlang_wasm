-module(fake_reactor_adapter).
-moduledoc """
A snapshot-capable adapter with no interpreter behind it.

The kernel's snapshot path -- capture at `start_link/2`, restore per request --
otherwise exists only where a QuickJS or CPython build does, and those live in
the integration job. This runs in the required one: a hand-emitted reactor,
committed, no network and no toolchain.

It is deliberately the smallest thing that can hold the claim. `handle` adds a
counter it bumps to a number `init` wrote into memory, so a restored instance
answering the same thing twice is the isolation claim and a rising number is
the defect.
""".

-behaviour(script_worker).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2,
         snapshot_capability/1]).
-export([captures/0, reset_captures/0]).

-define(VERSION, ~"fake-reactor-1").

%% `wasm:load/1` on committed bytes, never `wasm:compile({wat, ...})`: a
%% snapshot's provenance **is** the module-cache handle, and an inline module
%% has none. That is why this fixture is a binary while every other adapter in
%% this directory is WAT.
artifact(Opts) ->
    Path = maps:get(path, Opts, default_path()),
    {ok, Bytes} = file:read_file(Path),
    case wasm:load(Bytes) of
        {ok, M}    -> {ok, #{module => M, opts => Opts}};
        {error, E} -> {error, worker_error:runtime(E)}
    end.

default_path() ->
    filename:join([wasm_spec_runner:fixtures_dir(), "snapshot", "reactor.wasm"]).

requirements(Request, _Artifact) when is_map(Request) ->
    {ok, #{min_timeout => 50, min_memory_pages => 1,
           request_bytes => erlang:external_size(Request),
           staged_bytes => 0, staged_files => 0, mounts => #{}}};
requirements(_Request, _Artifact) ->
    {error, worker_error:adapter(adapter_failure, ~"request is not a map", #{})}.

prepare(Request, #{module := M}, _Env) ->
    Export = maps:get(call, Request, ~"handle"),
    {ok, #{mode => reactor, module => M, imports => import_set(),
           invoke => [{call, Export, []}]},
     %% The adapter state, which `decode/2' is handed back. A request asking
     %% for `probe => heap' gets the runner's own heap flags in its result;
     %% every other request gets exactly the shape it always got, because the
     %% kit's cases compare these.
     maps:get(probe, Request, undefined)}.

%% No imports at all, so `snapshot_hooks` is empty and every module in the
%% bindings trivially has one. The key still travels with them, because capture
%% and restore have to be matched against the same declaration.
import_set() ->
    #{bindings => #{}, snapshot_hooks => #{}, compatibility_key => ?VERSION}.

decode(#{outcome := returned, values := Values}, heap) ->
    {ok, #{values => Values, runner_heap => runner_heap()}};
decode(#{outcome := returned, values := Values}, _State) ->
    {ok, #{values => Values}};
decode(#{outcome := trapped, error := E}, _State) ->
    {error, worker_error:runtime(E)};
decode(#{outcome := exited, exit := Code}, _State) ->
    {error, worker_error:adapter(exit, ~"exited", #{code => Code})}.

cleanup(_State) -> ok.

%% Read from **inside the runner**, the only process that can answer it: the
%% flag is installed by `spawn_opt' at the runner's creation and the runner is
%% gone by the time a case could ask it anything. `decode/2' rather than
%% `prepare/3' so the answer is taken after the guest has run, which is what
%% says the floor held across the call and not merely at spawn.
%%
%% The number is the emulator's, not the one configured: a requested floor is
%% rounded **up** to a heap-size class, so a case asserts a lower bound.
runner_heap() ->
    {garbage_collection, GC} = process_info(self(), garbage_collection),
    proplists:get_value(min_heap_size, GC).

capabilities(_Artifact) ->
    #{execution => reactor,
      input_channels => [typed_args],
      result_channels => [typed_result],
      snapshots => #{version => ?VERSION},
      wasi => false}.

%% `init` is what an adapter would normally spend an interpreter start on, and
%% `spin` is what makes `capture_timeout` a setting a case can watch work.
snapshot_capability(#{module := M, opts := Opts}) ->
    #{version => ?VERSION,
      module => M,
      imports => import_set(),
      init => [{call, maps:get(init_call, Opts, ~"init"), []}],
      validate => validator(Opts),
      post_restore => fun post_restore/2}.

validator(Opts) ->
    case maps:get(validate, Opts, ready) of
        refuse ->
            fun(_) -> {error, worker_error:adapter(
                                adapter_failure, ~"refused on purpose", #{})}
            end;
        ready ->
            fun ready/1
    end.

%% Asking the guest whether it came up, rather than asking the module what it
%% exports: `init`'s own value never reaches the kernel, so without this a
%% runtime that failed to start would be captured and restored into every
%% request.
%% Counted so a suite can tell a **read** from a **capture** from outside.
%% Without it, a case asserting that two workers answer the same thing passes
%% whether the second one read the filed image or captured a fresh one, which
%% is a case that cannot fail.
-define(COUNT, {?MODULE, captures}).

captures() -> persistent_term:get(?COUNT, 0).

reset_captures() -> persistent_term:put(?COUNT, 0).

ready(Inst) ->
    persistent_term:put(?COUNT, captures() + 1),
    case wasm:call(Inst, ~"ready", [], #{fuel => infinity, timeout => infinity}) of
        {ok, [1]} -> ok;
        {ok, Got} -> {error, worker_error:adapter(
                               adapter_failure, ~"the runtime did not come up",
                               #{ready => Got})};
        {error, E} -> {error, worker_error:runtime(E)}
    end.

post_restore(_Inst, _Ctx) -> ok.

conformance_fixtures(_Artifact) ->
    #{base => #{echo => #{}, failure => #{call => ~"missing"},
                runaway => #{call => ~"spin"}, state_change => #{}},
      by_capability => #{}}.

classify({ok, _}, _State)    -> continue;
classify({error, _}, _State) -> {stop, trapped}.
