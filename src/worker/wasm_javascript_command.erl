-module(wasm_javascript_command).
-moduledoc """
Run JavaScript that arrives at request time, through the `script_v1` profile.

The interpreter is QuickJS compiled to WebAssembly, so there are two levels:
your code, this runtime, the engine, and then the script. Fetch the artifact
with `scripts/fetch-qjs-fixture.sh` and check what it is against
`test/fixtures/lang/QUICKJS.md`.

```erlang
{ok, W} = js_worker:start_link("test/fixtures/lang/qjs.wasm", #{root => scratch}),
{ok, #{result := #{~"answer" := 42}}} =
    js_worker:run(W, ~"export function main(c) { return {answer: c.value + 1}; }",
                  #{~"value" => 41}).
```

## What this adapter does, and where it stops

It stages three files into one read-only mount and runs the engine over them:
the profile's bootstrap, the tenant's source as `/main.js`, and the context as
`/context.json`. The bootstrap imports the source by **absolute path**, never
by a search path, so nothing the tenant writes can reach a module the host did
not put there.

`script_v1.combined` is the transport, because the artifact's imports are not
ours to change: the result arrives on stdout behind a per-request delimiter.
That transport authenticates nothing, and `wasm_script_v1` says so at length.

**Loaded through `wasm:load/1`, never `wasm:compile/1`.** The compiled tier
keys on the module's identity, and `wasm:compile/1` mints a fresh reference, so a
compiled artifact would be written under a key nothing can look up: measured
once as 410 functions compiled and an empty cache directory.
""".

-behaviour(wasm_script_worker).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2]).

-define(DEFAULT_SOURCE, ~"export function main(context) { return context; }").

artifact(Opts) ->
    case maps:find(path, Opts) of
        error ->
            {error, wasm_worker_error:adapter(adapter_failure,
                                         ~"no `path' to a QuickJS build", #{})};
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
    Path = filename:join([code:priv_dir(wasm), "script_v1", "boot.js"]),
    {ok, Bytes} = file:read_file(Path),
    Bytes.

requirements(Request, #{boot := Boot}) when is_map(Request) ->
    Source = maps:get(source, Request, ?DEFAULT_SOURCE),
    Context = wasm_script_v1:encode_context(maps:get(context, Request, #{})),
    Staged = byte_size(Boot) + byte_size(Source) + byte_size(Context),
    {ok, #{%% Starting a JavaScript engine is a quarter of a second before the
           %% script runs at all, so a request that cannot have that much left
           %% is refused rather than started and killed.
           min_timeout => 1_000,
           min_memory_pages => 64,
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
    case stage_all(Stage, [{~"_boot.js", Boot}, {~"main.js", Source},
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
      #{args => [~"qjs", ~"/_boot.js", Marker], env => #{},
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
          #{echo => #{source => ~"export function main(c) { return {answer: c.value + 1}; }",
                      context => #{~"value" => 41}},
            failure => #{source => ~"export function main(c) { throw new Error('boom'); }"},
            runaway => #{source => ~"export function main(c) { for (;;) {} }"},
            %% Mutating a global is exactly what a reused instance would leak,
            %% and a fresh one answers the same thing twice.
            state_change => #{source => state_change_source()}},
      by_capability => #{}}.

%% Adjacent sigils do not concatenate, and a source long enough to want two
%% lines is clearer as its own function anyway.
state_change_source() ->
    <<"export function main(c) {",
      "  globalThis.n = (globalThis.n || 0) + 1;",
      "  return {n: globalThis.n};",
      "}">>.

classify({ok, _Values}, _State) ->
    continue;
classify({error, Err}, _State) ->
    %% `proc_exit' becomes a trap carrying the status, and only this adapter
    %% knows that, which is why the kernel does not try to.
    case wasi_preview1:exit_code(Err) of
        {ok, Code} -> {stop, {exited, Code}};
        error      -> {stop, trapped}
    end.
