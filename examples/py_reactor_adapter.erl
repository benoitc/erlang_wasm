-module(py_reactor_adapter).
-moduledoc """
Run Python from an image of an already-started interpreter.

The same profile and the same tenant contract as `py_adapter` -- `main(context)`,
JSON in and out -- over a **reactor** rather than a command, so CPython starts
once when the worker starts and every request restores that point.

This is the adapter the Python numbers exist for. Starting CPython inside every
request costs tens of seconds; restoring an image of a started one costs under
a second, and `test/audit/PERF.md` has both.

```erlang
{ok, _} = worker_reaper:start_link(#{scratch => "/var/tmp/py"}),
{ok, W} = script_worker:start_link(
            py_reactor_adapter,
            #{path => "test/fixtures/lang/py_reactor.wasm",
              lib  => "test/fixtures/lang/py_reactor_lib",
              root => scratch, limits => py_reactor_adapter:limits()}),
{ok, #{result := #{~"answer" := 42}}} =
    script_worker:run(W, #{source => ~"def main(c):\\n    return {'answer': c['value'] + 1}\\n",
                           context => #{~"value" => 41}}).
```

Build the artifact with `scripts/build-python-reactor.sh` and check what it is
against `test/fixtures/lang/PYTHON.md`.

## Two mounts, and only one of them is the kernel's

The tenant's source and context are staged into the `ro` mount the kernel
creates and removes. The standard library is not staged: it is 11 MB of files
the adapter ships, and it is preopened directly as `/lib` from wherever the
build put it. That is the adapter's own `dirs` entry rather than a mount,
because a mount is a directory the kernel owns and this one it does not.

Writing an adapter is writing host code, which is what makes that allowed.

## What an image of CPython freezes

The hash seed, drawn during interpreter startup, is in the image and is
therefore shared by every request that restores it. Re-seeding afterwards is
not available: dictionaries exist by then and string hashes are cached against
the old secret. Rotation means recapturing, which is one `init()`.
`docs/snapshots.md` says the same thing about every guest.
""".

-behaviour(script_worker).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2,
         snapshot_capability/1]).
-export([limits/0]).

-define(DEFAULT_SOURCE, ~"def main(context):\n    return context\n").
-define(VERSION, ~"py-reactor-1").

-doc """
What this guest needs, and every one of them is measured rather than rounded.

An interpreter does not start under the untrusted preset: `PYTHON.md` records
that its fuel ceiling does not reach CPython's first line, and that the default
heap bound kills the runner outright. A host raises these knowingly, which is
exactly why an adapter never raises one for you.
""".
-spec limits() -> map().
limits() ->
    #{timeout => 120_000, fuel => infinity, max_memory_pages => 8192,
      max_host_calls => 10_000_000, max_heap_words => 16 * 1024 * 1024}.

artifact(Opts) ->
    case {maps:find(path, Opts), maps:find(lib, Opts)} of
        {error, _} ->
            {error, worker_error:adapter(
                      adapter_failure, ~"no `path' to a CPython reactor", #{})};
        {_, error} ->
            {error, worker_error:adapter(
                      adapter_failure, ~"no `lib' with the standard library",
                      #{})};
        {{ok, Path}, {ok, Lib}} ->
            load(Path, Lib)
    end.

load(Path, Lib) ->
    case filelib:is_dir(Lib) of
        false ->
            {error, worker_error:adapter(
                      adapter_failure, ~"the standard library is not there",
                      #{lib => iolist_to_binary(Lib)})};
        true ->
            read(Path, Lib)
    end.

read(Path, Lib) ->
    case file:read_file(Path) of
        {error, Why} ->
            {error, worker_error:adapter(
                      adapter_failure, ~"cannot read the interpreter",
                      #{path => iolist_to_binary(Path), reason => Why})};
        {ok, Bytes} ->
            %% `wasm:load/1', never `wasm:compile/1': a snapshot needs the cache
            %% handle as its provenance, and an inline module has none.
            case wasm:load(Bytes) of
                {ok, Module} -> {ok, #{module => Module, lib => Lib}};
                {error, E}   -> {error, worker_error:runtime(E)}
            end
    end.

requirements(Request, _Artifact) when is_map(Request) ->
    Source = maps:get(source, Request, ?DEFAULT_SOURCE),
    Context = script_v1:encode_context(maps:get(context, Request, #{})),
    Staged = byte_size(Source) + byte_size(Context),
    {ok, #{%% About a third of a warm request is delivering the adapter state
           %% and restoring the image, and the whole request is about 35 ms.
           %% Both measured per phase, in `PERF.md`. The bucket cannot be split
           %% further from here: `deliver/3', `check_spec/1', `restore/3' and
           %% `snapshot_info/1' are inside it and no adapter sees their edges.
           min_timeout => 10_000,
           min_memory_pages => 1024,
           request_bytes => Staged,
           staged_bytes => Staged, staged_files => 2,
           mounts => #{ro => #{guest_path => ~"/", mode => read}}}};
requirements(_Request, _Artifact) ->
    {error, worker_error:adapter(adapter_failure, ~"request is not a map", #{})}.

prepare(Request, #{module := M, lib := Lib}, Env) ->
    Stage = maps:get(stage, Env),
    Source = maps:get(source, Request, ?DEFAULT_SOURCE),
    Context = script_v1:encode_context(maps:get(context, Request, #{})),
    case stage_all(Stage, [{~"main.py", Source}, {~"context.json", Context}]) of
        {error, E} ->
            {error, E, #{}};
        ok ->
            %% `_initialize' and `init' are in the image, so a request is one
            %% call.
            {ok, #{mode => reactor, module => M,
                   imports => imports(Lib, Env),
                   invoke => [{call, ~"handle", []}]},
             #{}}
    end.

stage_all(_Stage, []) -> ok;
stage_all(Stage, [{Path, Bytes} | Rest]) ->
    case Stage(ro, Path, Bytes) of
        ok             -> stage_all(Stage, Rest);
        {error, _} = E -> E
    end.

imports(Lib, Env) ->
    #{mounts := Mounts, channels := Chans} = Env,
    #{host_dir := Dir} = maps:get(ro, Mounts),
    Sink = fun(Which) ->
               C = maps:get(Which, Chans),
               fun(Data) -> script_worker:channel_write(C, Data) end
           end,
    import_set(wasi(Dir, Lib, Sink(stdout), Sink(stderr)),
               maps:get(result, Chans)).

%% Two directories and nothing else: the request's own, and the standard
%% library the interpreter is useless without. No network, because an absent
%% `net' key is no network however much the artifact imports, and only a
%% monotonic clock, because `default_config/0' would otherwise open `realtime'.
wasi(Dir, Lib, Out, Err) ->
    wasi_preview1:imports(
      #{args => [~"python"], env => #{},
        dirs => [{~"/", Dir, read}, {~"/lib", Lib, read}],
        clocks => [monotonic], random => strong,
        stdout => Out, stderr => Err}).

%% Every import module needs a hook or the capture is refused: silence means
%% no. `worker' holds nothing on the guest side and says so.
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
    {error, worker_error:adapter(exit, ~"the interpreter exited",
                                 #{code => Code, stdout => Out, stderr => Err})}.

cleanup(_State) -> ok.

capabilities(_Artifact) ->
    #{execution => reactor,
      input_channels => [files],
      result_channels => [custom_import],
      snapshots => #{version => ?VERSION},
      wasi => true}.

-doc """
Capture the interpreter once, between `init()` and any request.

The initialisation bindings are **trusted** and deliberately barren: an empty
work directory, the standard library, and stdio going nowhere. Whatever
`init()` touches is in the image every request restores, so the less it touches
the less is shared.
""".
snapshot_capability(#{module := M, lib := Lib}) ->
    #{version => ?VERSION,
      module => M,
      imports => init_imports(Lib),
      %% `_initialize' is the reactor's own libc setup and runs first; `init'
      %% is ours, and it is where the tens of seconds go.
      init => [{call, ~"_initialize", []}, {call, ~"init", []}],
      validate => fun validate/1,
      post_restore => fun post_restore/2}.

init_imports(Lib) ->
    Quiet = fun(_) -> ok end,
    import_set(wasi(init_dir(), Lib, Quiet, Quiet), undefined).

%% An empty directory, so the preopen exists and holds nothing. `init()' opens
%% no file under it, and a descriptor left open would refuse the capture.
init_dir() ->
    Dir = filename:join(["/tmp", "py_reactor_init"]),
    ok = filelib:ensure_path(Dir),
    Dir.

% Asking the runtime whether it is up, rather than asking the module what it
% exports: `init()`'s own return value never reaches the kernel, which does
% not read guest values, so without this a half-started interpreter would be
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

%% Nothing to repair: the interpreter's state is guest-side and came back with
%% the image, and its host side is the fresh bindings this restore was given.
post_restore(_Inst, _Ctx) -> ok.

conformance_fixtures(_Artifact) ->
    #{base =>
          #{echo => #{source => ~"def main(c):\n    return {'answer': c['value'] + 1}\n",
                      context => #{~"value" => 41}},
            failure => #{source => ~"def main(c):\n    raise ValueError('boom')\n"},
            runaway => #{source => ~"def main(c):\n    while True:\n        pass\n"},
            state_change => #{source => state_change_source()}},
      by_capability => #{}}.

%% Mutating module-level state is exactly what a reused interpreter would leak,
%% and a restored one answers the same thing every time.
state_change_source() ->
    <<"n = 0\n",
      "def main(c):\n",
      "    global n\n",
      "    n += 1\n",
      "    return {'n': n}\n">>.

%% `handle()' returns rather than calling `proc_exit', so the ordinary case is
%% a return and there is no exit status to read out of a trap.
classify({ok, _Values}, _State) -> continue;
classify({error, _Err}, _State) -> {stop, trapped}.
