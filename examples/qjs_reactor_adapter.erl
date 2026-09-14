-module(qjs_reactor_adapter).
-moduledoc """
Run JavaScript from an image of an already-started engine.

Same profile and the same tenant contract as `qjs_adapter` -- `main(context)`,
JSON in and out -- but over a **reactor** rather than a command, so the engine
starts once when the worker starts and every request restores that point
instead of reaching it again.

```erlang
{ok, _} = worker_reaper:start_link(#{scratch => "/var/tmp/w"}),
{ok, W} = script_worker:start_link(
            qjs_reactor_adapter,
            #{path => "test/fixtures/lang/qjs_reactor.wasm", root => scratch}),
{ok, #{result := #{~"answer" := 42}}} =
    script_worker:run(W, #{source => ~"export function main(c)"
                                     " { return {answer: c.value + 1}; }",
                           context => #{~"value" => 41}}).
```

Build the artifact with `scripts/build-quickjs-reactor.sh` and check what it is
against `test/fixtures/lang/QUICKJS.md`.

## Why this one can be snapshotted and `qjs_adapter` cannot

A command exports `_start`, and by the time `_start` returns the engine has
torn itself down: an image of that is an image of nothing worth restoring. The
reactor splits it in two, `init()` and `handle()`, and an image taken between
them is a started engine with no request in it.

## `script_v1.channel`, not `combined`

The combined transport learns its per-request delimiter from `argv`, and this
guest reads no argv at all: anything `init()` touched would be frozen into the
image and shared by every later request. So the result leaves over an import of
its own, `worker.result`, which is a genuinely separate channel with its own
bound and nothing to parse back out of stdout.

That import is also why nothing needs staging but the tenant's own two files:
the bootstrap is compiled into the artifact rather than written to disk.
""".

-behaviour(script_worker).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2,
         snapshot_capability/1]).

-define(DEFAULT_SOURCE, ~"export function main(context) { return context; }").
-define(VERSION, ~"qjs-reactor-1").

artifact(Opts) ->
    case maps:find(path, Opts) of
        error ->
            {error, worker_error:adapter(
                      adapter_failure, ~"no `path' to a QuickJS reactor", #{})};
        {ok, Path} ->
            load(Path)
    end.

load(Path) ->
    case file:read_file(Path) of
        {error, Why} ->
            {error, worker_error:adapter(adapter_failure, ~"cannot read the engine",
                                         #{path => iolist_to_binary(Path),
                                           reason => Why})};
        {ok, Bytes} ->
            %% `wasm:load/1', never `wasm:compile/1': a snapshot needs the cache
            %% handle as its provenance, and an inline module has none.
            case wasm:load(Bytes) of
                {ok, Module} -> {ok, #{module => Module}};
                {error, E}   -> {error, worker_error:runtime(E)}
            end
    end.

requirements(Request, _Artifact) when is_map(Request) ->
    Source = maps:get(source, Request, ?DEFAULT_SOURCE),
    Context = script_v1:encode_context(maps:get(context, Request, #{})),
    Staged = byte_size(Source) + byte_size(Context),
    {ok, #{%% A restore lands on a started engine, so what a request has left
           %% to do is read two files and run one function. The command adapter
           %% asks for a second because it starts the engine first.
           min_timeout => 500,
           min_memory_pages => 64,
           request_bytes => Staged,
           staged_bytes => Staged, staged_files => 2,
           mounts => #{ro => #{guest_path => ~"/", mode => read}}}};
requirements(_Request, _Artifact) ->
    {error, worker_error:adapter(adapter_failure, ~"request is not a map", #{})}.

prepare(Request, #{module := M}, Env) ->
    Stage = maps:get(stage, Env),
    Source = maps:get(source, Request, ?DEFAULT_SOURCE),
    Context = script_v1:encode_context(maps:get(context, Request, #{})),
    case stage_all(Stage, [{~"main.js", Source}, {~"context.json", Context}]) of
        {error, E} ->
            {error, E, #{}};
        ok ->
            %% `_initialize' and `init' are in the image, so the request's own
            %% work is one call.
            {ok, #{mode => reactor, module => M,
                   imports => imports(Env),
                   invoke => [{call, ~"handle", []}]},
             #{}}
    end.

stage_all(_Stage, []) -> ok;
stage_all(Stage, [{Path, Bytes} | Rest]) ->
    case Stage(ro, Path, Bytes) of
        ok             -> stage_all(Stage, Rest);
        {error, _} = E -> E
    end.

imports(Env) ->
    #{mounts := Mounts, channels := Chans} = Env,
    #{host_dir := Dir} = maps:get(ro, Mounts),
    import_set(wasi(Dir, Chans), maps:get(result, Chans)).

%% One directory and nothing else: no network, because an absent `net' key is
%% no network however much the engine imports, and only a monotonic clock,
%% because `default_config/0' would otherwise open `realtime'.
wasi(Dir, Chans) ->
    Sink = fun(Which) ->
               C = maps:get(Which, Chans),
               fun(Data) -> script_worker:channel_write(C, Data) end
           end,
    wasi_preview1:imports(
      #{args => [~"qjs"], env => #{},
        dirs => [{~"/", Dir, read}],
        clocks => [monotonic], random => strong,
        stdout => Sink(stdout), stderr => Sink(stderr)}).

%% Every import module needs a hook or the capture is refused: silence means
%% no. `worker` holds nothing on the guest side and says so.
import_set(Wasi, Result) ->
    #{bindings => Wasi#{{~"worker", ~"result"} => result_import(Result)},
      snapshot_hooks => #{~"wasi_snapshot_preview1" =>
                              wasi_preview1:snapshot_hook(),
                          ~"worker" => stateless},
      compatibility_key => ?VERSION}.

result_import(Channel) ->
    fun(Ctx, [Ptr, Len]) ->
        case wasm:read_memory(Ctx, Ptr, Len) of
            {ok, Bytes} -> ok = script_worker:channel_write(Channel, Bytes),
                           {ok, []};
            {error, _}  -> {ok, []}
        end
    end.

decode(#{outcome := returned} = R, _State) ->
    #{channels := #{result := Res, stdout := Out, stderr := Err}} = R,
    case script_v1:decode_channel(Res) of
        {ok, Result} ->
            {ok, #{result => Result, stdout => Out, stderr => Err}};
        {error, Code, Msg} ->
            {error, script_v1:error(Code, Msg, #{stdout => Out, stderr => Err})}
    end;
decode(#{outcome := trapped, error := undefined}, _State) ->
    {error, worker_error:adapter(adapter_failure, ~"trapped with no error", #{})};
decode(#{outcome := trapped, error := E}, _State) ->
    {error, worker_error:runtime(E)};
decode(#{outcome := exited, exit := Code} = R, _State) ->
    #{channels := #{stdout := Out, stderr := Err}} = R,
    {error, worker_error:adapter(exit, ~"the engine exited", #{code => Code,
                                                              stdout => Out,
                                                              stderr => Err})}.

cleanup(_State) -> ok.

capabilities(_Artifact) ->
    #{execution => reactor,
      input_channels => [files],
      result_channels => [custom_import],
      snapshots => #{version => ?VERSION},
      wasi => true}.

-doc """
Capture the engine once, between `init()` and any request.

The initialisation bindings are **trusted** and deliberately barren: an empty
directory, no clock a request could read a time from, and stdio going nowhere.
Whatever `init()` touches is in the image that every request restores, so the
less it touches the less is shared.
""".
snapshot_capability(#{module := M}) ->
    #{version => ?VERSION,
      module => M,
      imports => init_imports(),
      %% `_initialize' is the reactor's own libc setup and runs first; `init'
      %% is ours.
      init => [{call, ~"_initialize", []}, {call, ~"init", []}],
      validate => fun validate/1,
      post_restore => fun post_restore/2}.

init_imports() ->
    Dir = init_dir(),
    Wasi = wasi_preview1:imports(
             #{args => [~"qjs"], env => #{},
               dirs => [{~"/", Dir, read}],
               clocks => [monotonic], random => strong,
               stdout => fun(_) -> ok end, stderr => fun(_) -> ok end}),
    import_set(Wasi, undefined).

%% An empty directory, so the preopen exists and holds nothing. `init()' opens
%% no file, and a descriptor it left open would refuse the capture anyway.
init_dir() ->
    Dir = filename:join(["/tmp", "qjs_reactor_init"]),
    ok = filelib:ensure_path(Dir),
    Dir.

% Asking the runtime whether it is up, rather than asking the module what it
% exports: `init()`'s own return value never reaches the kernel, which does
% not read guest values, so without this a half-started engine would be
% captured and restored into every request. Proved by removing the standard
% library from the initialisation imports and watching the capture refuse.
validate(Inst) ->
    Unbounded = #{fuel => infinity, timeout => infinity},
    case wasm:call(Inst, ~"ready", [], Unbounded) of
        {ok, [1]} ->
            ok;
        {ok, Other} ->
            {error, worker_error:adapter(
                      adapter_failure, ~"the runtime did not come up",
                      #{ready => Other})};
        {error, E} ->
            {error, worker_error:runtime(E)}
    end.

%% Nothing to repair: the engine's whole state is guest-side and came back with
%% the image, and its host side is the fresh bindings this restore was given.
post_restore(_Inst, _Ctx) -> ok.

conformance_fixtures(_Artifact) ->
    #{base =>
          #{echo => #{source => ~"export function main(c) { return {answer: c.value + 1}; }",
                      context => #{~"value" => 41}},
            failure => #{source => ~"export function main(c) { throw new Error('boom'); }"},
            runaway => #{source => ~"export function main(c) { for (;;) {} }"},
            state_change => #{source => state_change_source()}},
      by_capability => #{}}.

state_change_source() ->
    <<"export function main(c) {",
      "  globalThis.n = (globalThis.n || 0) + 1;",
      "  return {n: globalThis.n};",
      "}">>.

%% `handle()' returns rather than calling `proc_exit', so the ordinary case is
%% a return and there is no exit status to read out of a trap.
classify({ok, _Values}, _State) -> continue;
classify({error, _Err}, _State) -> {stop, trapped}.
