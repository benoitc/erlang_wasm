-module(wasm_python_command).
-moduledoc """
Run Python that arrives at request time, through the `script_v1` profile.

The interpreter is upstream CPython compiled to WebAssembly. Fetch the artifact
with `scripts/fetch-python-fixture.sh` and check what it is against
`test/fixtures/lang/PYTHON.md`.

```erlang
{ok, W} = wasm_script_worker:start_link(
            wasm_python_command, #{path => "test/fixtures/lang/python.wasm"}),
{ok, #{result := #{~"answer" := 42}}} =
    wasm_script_worker:run(W, ~"def main(c):\n    return {'answer': c['value'] + 1}\n",
                           #{~"value" => 41}).
```

## Not Pyodide, and not MicroPython

Both of those target Emscripten and need JavaScript glue, a browser ABI and a
package loader WASI preview 1 does not provide. On a host whose engine is V8
that glue costs nothing; on the BEAM it is pure liability. Nothing here should
imply a Pyodide package runs unchanged.

## `-I -B -u`, and why each one

Isolated configuration, no `.pyc` writes, no output buffering. The third is a
bound: buffered output would arrive in one burst at the end and the streaming
limit would never see it.

`-I` implies `-P`, so the work directory is **not** on `sys.path`. The
bootstrap therefore loads the tenant's module through
`importlib.util.spec_from_file_location` against an explicit path rather than
putting a tenant-supplied directory on the import path.

## One mount, because this build embeds its library

Confirmed by running it: `sys.path` names `/usr/local/lib/python3.12`, which is
not in any preopen, and `import json` works anyway. An upstream WASI build that
ships `python.wasm` beside a `Lib` directory would need that directory
preopened read-only as a second mount, and `requirements/2` is where that would
be declared.
""".

-behaviour(wasm_worker_adapter).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2]).

-define(DEFAULT_SOURCE, <<"def main(context):\n    return context\n">>).

artifact(Opts) ->
    case maps:find(path, Opts) of
        error ->
            {error, wasm_worker_error:adapter(adapter_failure,
                                         ~"no `path' to a CPython build", #{})};
        {ok, Path} ->
            load(Path)
    end.

load(Path) ->
    case file:read_file(Path) of
        {error, Why} ->
            {error, wasm_worker_error:adapter(adapter_failure, ~"cannot read the engine",
                                         #{path => iolist_to_binary(Path),
                                           reason => Why})};
        {ok, Bytes} ->
            case wasm:load(Bytes) of
                {ok, Module} -> {ok, #{module => Module, boot => boot()}};
                {error, E}   -> {error, wasm_worker_error:runtime(E)}
            end
    end.

%% Read once, at `start_link', rather than per request: it is the same bytes
%% every time and staging is what costs, not reading.
boot() ->
    Path = filename:join([code:priv_dir(wasm), "script_v1", "boot.py"]),
    {ok, Bytes} = file:read_file(Path),
    Bytes.

requirements(Request, #{boot := Boot}) when is_map(Request) ->
    Source = maps:get(source, Request, ?DEFAULT_SOURCE),
    Context = wasm_script_v1:encode_context(maps:get(context, Request, #{})),
    Staged = byte_size(Boot) + byte_size(Source) + byte_size(Context),
    {ok, #{%% Starting CPython is tens of seconds, not milliseconds, and a
           %% request that cannot have that much left is refused rather than
           %% started and killed. `PYTHON.md` records what it was measured at.
           min_timeout => 60_000,
           min_memory_pages => 512,
           request_bytes => byte_size(Source) + byte_size(Context),
           staged_bytes => Staged, staged_files => 3,
           mounts => #{ro => #{guest_path => ~"/", mode => read}}}};
requirements(_Request, _Artifact) ->
    {error, wasm_worker_error:adapter(adapter_failure, ~"request is not a map", #{})}.

prepare(Request, #{module := M, boot := Boot}, Env) ->
    Marker = wasm_script_v1:marker(),
    Stage = maps:get(stage, Env),
    Source = maps:get(source, Request, ?DEFAULT_SOURCE),
    Context = wasm_script_v1:encode_context(maps:get(context, Request, #{})),
    case stage_all(Stage, [{~"_boot.py", Boot}, {~"main.py", Source},
                           {~"context.json", Context}]) of
        {error, E} ->
            {error, E, #{marker => Marker}};
        ok ->
            {ok, #{mode => command, module => M,
                   imports => #{bindings => wasi(Marker, Env)},
                   invoke => [{call, ~"_start", []}]},
             #{marker => Marker}}
    end.

stage_all(_Stage, []) -> ok;
stage_all(Stage, [{Path, Bytes} | Rest]) ->
    case Stage(ro, Path, Bytes) of
        ok             -> stage_all(Stage, Rest);
        {error, _} = E -> E
    end.

%% The engine is given one directory and nothing else: no network, because an
%% absent `net' key is no network at all however much the engine imports, and
%% only a monotonic clock, because `default_config/0' would otherwise open
%% `realtime' and the untrusted preset is what takes it away.
wasi(Marker, Env) ->
    #{mounts := Mounts, channels := Chans} = Env,
    #{host_dir := Dir} = maps:get(ro, Mounts),
    Sink = fun(Which) ->
               C = maps:get(Which, Chans),
               fun(Data) -> wasm_script_worker:channel_write(C, Data) end
           end,
    wasi_preview1:imports(
      #{args => [~"python", ~"-I", ~"-B", ~"-u", ~"/_boot.py", Marker],
        env => #{},
        dirs => [{~"/", Dir, read}],
        clocks => [monotonic], random => strong,
        stdout => Sink(stdout), stderr => Sink(stderr)}).

decode(#{outcome := exited, exit := 0} = R, #{marker := Marker}) ->
    #{channels := #{stdout := Out, stderr := Err}} = R,
    case wasm_script_v1:decode_combined(Out, Marker) of
        {ok, #{result := Result, stdout := Printed}} ->
            {ok, #{result => Result, stdout => Printed, stderr => Err}};
        {error, Code, Msg} ->
            {error, wasm_script_v1:error(Code, Msg, #{stdout => Out, stderr => Err})}
    end;
decode(#{outcome := exited, exit := Code} = R, _State) ->
    #{channels := #{stdout := Out, stderr := Err}} = R,
    {error, wasm_worker_error:adapter(exit, ~"the engine exited non-zero",
                                 #{code => Code, stdout => Out, stderr => Err})};
decode(#{outcome := trapped, error := undefined}, _State) ->
    {error, wasm_worker_error:adapter(adapter_failure, ~"trapped with no error", #{})};
decode(#{outcome := trapped, error := E}, _State) ->
    {error, wasm_worker_error:runtime(E)};
decode(#{outcome := returned} = R, State) ->
    decode(R#{outcome := exited, exit := 0}, State).

cleanup(_State) -> ok.

capabilities(_Artifact) ->
    #{execution => command,
      input_channels => [files],
      result_channels => [framed_stream],
      snapshots => unsupported,
      wasi => true}.

conformance_fixtures(_Artifact) ->
    #{base =>
          #{echo => #{source => <<"def main(c):\n    return {'answer': c['value'] + 1}\n">>,
                      context => #{~"value" => 41}},
            failure => #{source => <<"def main(c):\n    raise ValueError('boom')\n">>},
            runaway => #{source => <<"def main(c):\n    while True:\n        pass\n">>},
            %% Mutating a global is exactly what a reused instance would leak,
            %% and a fresh one answers the same thing twice.
            state_change => #{source => state_change_source()}},
      by_capability => #{}}.

%% Adjacent sigils do not concatenate, and a source long enough to want two
%% lines is clearer as its own function anyway.
state_change_source() ->
    <<"import builtins\n",
      "def main(c):\n",
      "    builtins.n = getattr(builtins, 'n', 0) + 1\n",
      "    return {'n': builtins.n}\n">>.

classify({ok, _Values}, _State) ->
    continue;
classify({error, Err}, _State) ->
    %% `proc_exit' becomes a trap carrying the status, and only this adapter
    %% knows that, which is why the kernel does not try to.
    case wasi_preview1:exit_code(Err) of
        {ok, Code} -> {stop, {exited, Code}};
        error      -> {stop, trapped}
    end.
