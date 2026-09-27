-module(wasm_python).
-moduledoc """
Run Python from an image of an already-started interpreter.

The same profile and the same tenant contract as `wasm_python_command` -- `main(context)`,
JSON in and out -- over a **reactor** rather than a command, so CPython starts
once when the worker starts and every request restores that point.

This is the adapter the Python numbers exist for. Starting CPython inside every
request costs tens of seconds; restoring an image of a started one costs under
a second, and `test/audit/PERF.md` has both.

```erlang
{ok, W} = wasm_script_worker:start_link(
            wasm_python,
            #{path => "test/fixtures/lang/py_reactor.wasm",
              lib  => "test/fixtures/lang/py_reactor_lib",
              root => scratch, limits => wasm_python:limits()}),
{ok, #{result := #{~"answer" := 42}}} =
    wasm_script_worker:run(W, #{source => ~"def main(c):\\n    return {'answer': c['value'] + 1}\\n",
                           context => #{~"value" => 41}}).
```

Build the artifact with `scripts/build-python-reactor.sh` and check what it is
against `test/fixtures/lang/PYTHON.md`.

## An entry set at capture

When the code does not change between requests, give it to the worker as
`entry` instead of sending it with each one. The capture runs it once, it hands
`worker.set_entry` the callable to run, and a request that carries no `source`
then calls that callable with its context: nothing is compiled or imported per
request.

```erlang
{ok, W} = wasm_script_worker:start_link(
            wasm_python,
            #{path => "test/fixtures/lang/py_reactor.wasm",
              lib  => "test/fixtures/lang/py_reactor_lib",
              entry => ~"import worker\nworker.set_entry(lambda c: {'answer': c['value'] + 1})\n",
              root => scratch, limits => wasm_python:limits()}),
{ok, #{result := #{~"answer" := 42}}} =
    wasm_script_worker:run(W, #{context => #{~"value" => 41}}).
```

The capture runs the entry as `/main.py` through the same path a request's
source takes, so a `main` it defines is called once, with `None`. A worker whose
entry does not call `worker.set_entry` does not start. A request that does carry
a `source` still runs it, on the same worker.

The context reaches the guest through the `worker.context` import in both
modes rather than only as a staged file, so it can be as large as
`max_request_bytes` allows.

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

-behaviour(wasm_worker_adapter).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2,
         snapshot_capability/1]).
-export([limits/0]).

-define(DEFAULT_SOURCE, ~"def main(context):\n    return context\n").
%% 2: the reactor imports `worker.context` and `worker.context_size`, so an
%% image of the first one cannot be restored with this adapter's bindings.
-define(VERSION, ~"py-reactor-2").

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
    case maps:get(entry, Opts, undefined) of
        Entry when Entry =:= undefined; is_binary(Entry) ->
            artifact_1(Opts, Entry);
        Other ->
            {error, wasm_worker_error:adapter(
                      adapter_failure, ~"`entry' is not a binary",
                      #{entry => Other})}
    end.

artifact_1(Opts, Entry) ->
    case {maps:find(path, Opts), maps:find(lib, Opts)} of
        {error, _} ->
            {error, wasm_worker_error:adapter(
                      adapter_failure, ~"no `path' to a CPython reactor", #{})};
        {_, error} ->
            {error, wasm_worker_error:adapter(
                      adapter_failure, ~"no `lib' with the standard library",
                      #{})};
        {{ok, Path}, {ok, Lib}} ->
            case load(Path, Lib) of
                {ok, A}        -> {ok, A#{entry => Entry}};
                {error, _} = E -> E
            end
    end.

load(Path, Lib) ->
    case filelib:is_dir(Lib) of
        false ->
            {error, wasm_worker_error:adapter(
                      adapter_failure, ~"the standard library is not there",
                      #{lib => iolist_to_binary(Lib)})};
        true ->
            read(Path, Lib)
    end.

read(Path, Lib) ->
    case file:read_file(Path) of
        {error, Why} ->
            {error, wasm_worker_error:adapter(
                      adapter_failure, ~"cannot read the interpreter",
                      #{path => iolist_to_binary(Path), reason => Why})};
        {ok, Bytes} ->
            %% `wasm:load/1', never `wasm:compile/1': a snapshot needs the cache
            %% handle as its provenance, and an inline module has none.
            case wasm:load(Bytes) of
                {ok, Module} -> {ok, #{module => Module, lib => Lib}};
                {error, E}   -> {error, wasm_worker_error:runtime(E)}
            end
    end.

requirements(Request, Artifact) when is_map(Request) ->
    Context = wasm_script_v1:encode_context(maps:get(context, Request, #{})),
    case mode(Request, Artifact) of
        call -> needs(Context, 0, 0);
        handle ->
            Source = maps:get(source, Request, ?DEFAULT_SOURCE),
            needs(Context, byte_size(Source) + byte_size(Context), 2)
    end;
requirements(_Request, _Artifact) ->
    {error, wasm_worker_error:adapter(adapter_failure, ~"request is not a map", #{})}.

%% A worker with an entry calls it for a request with no source of its own;
%% everything else runs its source through `handle()'.
mode(Request, #{entry := Entry}) when is_binary(Entry) ->
    case maps:is_key(source, Request) of
        true  -> handle;
        false -> call
    end;
mode(_Request, _Artifact) ->
    handle.

needs(Context, Staged, Files) ->
    {ok, #{%% About a third of a warm request is delivering the adapter state
           %% and restoring the image, and the whole request is about 35 ms.
           %% Both measured per phase, in `PERF.md`. The bucket cannot be split
           %% further from here: `deliver/3', `check_spec/1', `restore/3' and
           %% `snapshot_info/1' are inside it and no adapter sees their edges.
           min_timeout => 10_000,
           min_memory_pages => 1024,
           request_bytes => max(Staged, byte_size(Context)),
           staged_bytes => Staged, staged_files => Files,
           %% Kept in `call' mode although nothing is staged into it: the
           %% image's libc numbered its preopens at capture, `/' then `/lib',
           %% and a request has to present them in the same order.
           mounts => #{ro => #{guest_path => ~"/", mode => read}}}}.

prepare(Request, #{module := M, lib := Lib} = Artifact, Env) ->
    Context = wasm_script_v1:encode_context(maps:get(context, Request, #{})),
    Spec = fun(Export) ->
               %% `_initialize' and `init' are in the image, so a request is
               %% one call.
               #{mode => reactor, module => M,
                 imports => imports(Lib, Env, Context),
                 invoke => [{call, Export, []}]}
           end,
    case mode(Request, Artifact) of
        call ->
            {ok, Spec(~"call"), #{}};
        handle ->
            Stage = maps:get(stage, Env),
            Source = maps:get(source, Request, ?DEFAULT_SOURCE),
            case stage_all(Stage, [{~"main.py", Source},
                                   {~"context.json", Context}]) of
                {error, E} -> {error, E, #{}};
                ok         -> {ok, Spec(~"handle"), #{}}
            end
    end.

stage_all(_Stage, []) -> ok;
stage_all(Stage, [{Path, Bytes} | Rest]) ->
    case Stage(ro, Path, Bytes) of
        ok             -> stage_all(Stage, Rest);
        {error, _} = E -> E
    end.

imports(Lib, Env, Context) ->
    #{mounts := Mounts, channels := Chans} = Env,
    #{host_dir := Dir} = maps:get(ro, Mounts),
    Sink = fun(Which) ->
               C = maps:get(Which, Chans),
               fun(Data) -> wasm_script_worker:channel_write(C, Data) end
           end,
    import_set(wasi(Dir, Lib, Sink(stdout), Sink(stderr)),
               maps:get(result, Chans), Context).

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
import_set(Wasi, Result, Context) ->
    #{bindings => maps:merge(Wasi#{{~"worker", ~"result"} => result_import(Result)},
                             context_imports(Context)),
      snapshot_hooks => #{~"wasi_snapshot_preview1" =>
                              wasi_preview1:snapshot_hook(),
                          ~"worker" => stateless},
      compatibility_key => ?VERSION}.

%% The context, served to the guest per request: its size, then the bytes into
%% the buffer the guest sized. Answers how many bytes it wrote, and -1 for a
%% buffer outside the guest's memory.
context_imports(Context) ->
    Size = byte_size(Context),
    #{{~"worker", ~"context_size"} => fun(_Ctx, []) -> {ok, [Size]} end,
      {~"worker", ~"context"} =>
          fun(Ctx, [Ptr, Len]) ->
              N = max(0, min(Len, Size)),
              case wasm:write_memory(Ctx, Ptr band 16#FFFFFFFF,
                                     binary_part(Context, 0, N)) of
                  ok         -> {ok, [N]};
                  {error, _} -> {ok, [-1]}
              end
          end}.

%% A capture's result goes nowhere: an entry's capture runs `handle()' once,
%% and what it answers is not a request's.
result_import(undefined) ->
    fun(_Ctx, [_Ptr, _Len]) -> {ok, []} end;
result_import(Channel) ->
    fun(Ctx, [Ptr, Len]) ->
        case wasm:read_memory(Ctx, Ptr, Len) of
            {ok, Bytes} -> ok = wasm_script_worker:channel_write(Channel, Bytes),
                           {ok, []};
            {error, _}  -> {ok, []}
        end
    end.

decode(#{outcome := returned} = R, _State) ->
    #{channels := #{result := Res, stdout := Out, stderr := Err}} = R,
    case wasm_script_v1:decode_channel(Res) of
        {ok, Result} ->
            {ok, #{result => Result, stdout => Out, stderr => Err}};
        {error, Code, Msg} ->
            {error, wasm_script_v1:error(Code, Msg, #{stdout => Out, stderr => Err})}
    end;
decode(#{outcome := trapped, error := undefined}, _State) ->
    {error, wasm_worker_error:adapter(adapter_failure, ~"trapped with no error", #{})};
decode(#{outcome := trapped, error := E}, _State) ->
    {error, wasm_worker_error:runtime(E)};
decode(#{outcome := exited, exit := Code} = R, _State) ->
    #{channels := #{stdout := Out, stderr := Err}} = R,
    {error, wasm_worker_error:adapter(exit, ~"the interpreter exited",
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
snapshot_capability(#{module := M, lib := Lib} = Artifact) ->
    Base = [{call, ~"_initialize", []}, {call, ~"init", []}],
    case maps:get(entry, Artifact, undefined) of
        undefined ->
            #{version => ?VERSION,
              module => M,
              imports => init_imports(init_dir(), Lib),
              %% `_initialize' is the reactor's own libc setup and runs first;
              %% `init' is ours, and it is where the tens of seconds go.
              init => Base,
              validate => fun validate/1,
              post_restore => fun post_restore/2};
        Entry ->
            %% The entry is in the image, so it is in the version: two workers
            %% with different entries must never share a filed image.
            Hash = binary:encode_hex(crypto:hash(sha256, Entry), lowercase),
            #{version => <<?VERSION/binary, "+entry-", Hash/binary>>,
              module => M,
              imports => init_imports(entry_dir(Hash, Entry), Lib),
              init => Base ++ [{call, ~"handle", []}],
              validate => fun validate_entry/1,
              post_restore => fun post_restore/2}
    end.

init_imports(Dir, Lib) ->
    Quiet = fun(_) -> ok end,
    import_set(wasi(Dir, Lib, Quiet, Quiet), undefined, ~"null").

%% An empty directory, so the preopen exists and holds nothing. `init()' opens
%% no file under it, and a descriptor left open would refuse the capture.
init_dir() ->
    Dir = filename:join(["/tmp", "py_reactor_init"]),
    ok = filelib:ensure_path(Dir),
    Dir.

%% The capture's `/' for an entry: the entry as `main.py' and a null context.
%% In this user's cache rather than `/tmp', because what is in it runs in the
%% trusted capture, and named by the entry's hash so a restart finds the same
%% files instead of adding a directory per start.
entry_dir(Hash, Entry) ->
    Dir = filename:join([filename:basedir(user_cache, "erlang_wasm"),
                         "py_reactor_init", <<"entry-", Hash/binary>>]),
    ok = filelib:ensure_path(Dir),
    ok = put_file(filename:join(Dir, "main.py"), Entry),
    ok = put_file(filename:join(Dir, "context.json"), ~"null"),
    Dir.

put_file(Path, Bytes) ->
    Tmp = iolist_to_binary([Path, ".", integer_to_list(
                                         erlang:unique_integer([positive]))]),
    ok = file:write_file(Tmp, Bytes),
    file:rename(Tmp, Path).

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
            {error, wasm_worker_error:adapter(
                      adapter_failure, ~"the runtime did not come up",
                      #{ready => Other})};
        {error, E} ->
            {error, wasm_worker_error:runtime(E)}
    end.

%% Nothing to repair: the interpreter's state is guest-side and came back with
%% the image, and its host side is the fresh bindings this restore was given.
%% An entry's capture also has to have set it, or every request restored from
%% the image would answer `no_entry_point'.
validate_entry(Inst) ->
    case validate(Inst) of
        ok ->
            case wasm:call(Inst, ~"has_entry", [],
                           #{fuel => infinity, timeout => infinity}) of
                {ok, [1]} ->
                    ok;
                {ok, _} ->
                    {error, wasm_worker_error:adapter(
                              adapter_failure,
                              ~"the entry did not call worker.set_entry",
                              #{})};
                {error, E} ->
                    {error, wasm_worker_error:runtime(E)}
            end;
        {error, _} = E ->
            E
    end.

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
