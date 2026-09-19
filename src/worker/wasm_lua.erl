-module(wasm_lua).
-moduledoc """
Run Lua from an image of an already-started interpreter.

The third language through the same profile, and the one that exists to be
unlike the other two. QuickJS and CPython are large interpreters whose images
run to hundreds of kilobytes and megabytes; Lua's holds about 77 KB, which is
where a mechanism that quietly assumed bulk would show it.

```erlang
{ok, W} = wasm_script_worker:start_link(
            wasm_lua,
            #{path => "test/fixtures/lang/lua_reactor.wasm",
              limits => wasm_lua:limits()}),
{ok, #{result := #{~"answer" := 42}}} =
    wasm_script_worker:run(W, #{source => <<"function main(c)"
                                             " return {answer = c.value + 1} end">>,
                           context => #{~"value" => 41}}).
```

The tenant writes a global `main`, because Lua has no module export syntax:

```lua
function main(context)
    return {answer = context.value + 1}
end
```

Build the artifact with `scripts/build-lua-reactor.sh` and check what it is
against `test/fixtures/lang/LUA.md`.

## What it demonstrates

Nothing in the kernel, the profile or the snapshot mechanism changed to admit
it. That is the acceptance rule in `docs/worker-contract.md` applied to a
language chosen after all three were written, and it is the only form of
evidence for neutrality that is worth anything.

The one thing it did need was a **build flag**: Lua signals errors with
`longjmp`, which on WebAssembly is exception handling, and LLVM still emits the
superseded encoding by default. `LUA.md` has it.
""".

-behaviour(wasm_script_worker).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2,
         snapshot_capability/1]).
-export([limits/0]).

-define(DEFAULT_SOURCE, ~"function main(context) return context end").
-define(VERSION, ~"lua-reactor-1").

-doc "What this guest needs. Modest, which is the point of it being here.".
-spec limits() -> map().
limits() ->
    #{timeout => 10_000, fuel => infinity, max_memory_pages => 1024,
      max_host_calls => 1_000_000, max_heap_words => 4 * 1024 * 1024}.

artifact(Opts) ->
    case maps:find(path, Opts) of
        error ->
            {error, wasm_worker_error:adapter(
                      adapter_failure, ~"no `path' to a Lua reactor", #{})};
        {ok, Path} ->
            load(Path)
    end.

load(Path) ->
    case file:read_file(Path) of
        {error, Why} ->
            {error, wasm_worker_error:adapter(
                      adapter_failure, ~"cannot read the interpreter",
                      #{path => iolist_to_binary(Path), reason => Why})};
        {ok, Bytes} ->
            %% `wasm:load/1', never `wasm:compile/1': a snapshot's provenance
            %% is the module-cache handle, and an inline module has none.
            case wasm:load(Bytes) of
                {ok, Module} -> {ok, #{module => Module}};
                {error, E}   -> {error, wasm_worker_error:runtime(E)}
            end
    end.

requirements(Request, _Artifact) when is_map(Request) ->
    Source = maps:get(source, Request, ?DEFAULT_SOURCE),
    Context = wasm_script_v1:encode_context(maps:get(context, Request, #{})),
    Staged = byte_size(Source) + byte_size(Context),
    {ok, #{min_timeout => 250,
           min_memory_pages => 16,
           request_bytes => Staged,
           staged_bytes => Staged, staged_files => 2,
           mounts => #{ro => #{guest_path => ~"/", mode => read}}}};
requirements(_Request, _Artifact) ->
    {error, wasm_worker_error:adapter(adapter_failure, ~"request is not a map", #{})}.

prepare(Request, #{module := M}, Env) ->
    Stage = maps:get(stage, Env),
    Source = maps:get(source, Request, ?DEFAULT_SOURCE),
    Context = wasm_script_v1:encode_context(maps:get(context, Request, #{})),
    case stage_all(Stage, [{~"main.lua", Source}, {~"context.json", Context}]) of
        {error, E} ->
            {error, E, #{}};
        ok ->
            {ok, #{mode => reactor, module => M, imports => imports(Env),
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
    Sink = fun(Which) ->
               C = maps:get(Which, Chans),
               fun(Data) -> wasm_script_worker:channel_write(C, Data) end
           end,
    import_set(wasi(Dir, Sink(stdout), Sink(stderr)), maps:get(result, Chans)).

%% One directory and nothing else. Lua's standard library is inside the module,
%% so unlike CPython there is no second mount.
wasi(Dir, Out, Err) ->
    wasi_preview1:imports(
      #{args => [~"lua"], env => #{},
        dirs => [{~"/", Dir, read}],
        clocks => [monotonic], random => strong,
        stdout => Out, stderr => Err}).

import_set(Wasi, Result) ->
    #{bindings => Wasi#{{~"worker", ~"result"} => result_import(Result)},
      snapshot_hooks => #{~"wasi_snapshot_preview1" =>
                              wasi_preview1:snapshot_hook(),
                          ~"worker" => stateless},
      compatibility_key => ?VERSION}.

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

snapshot_capability(#{module := M}) ->
    #{version => ?VERSION,
      module => M,
      imports => init_imports(),
      init => [{call, ~"_initialize", []}, {call, ~"init", []}],
      validate => fun validate/1,
      post_restore => fun post_restore/2}.

init_imports() ->
    Quiet = fun(_) -> ok end,
    import_set(wasi(init_dir(), Quiet, Quiet), undefined).

init_dir() ->
    Dir = filename:join(["/tmp", "lua_reactor_init"]),
    ok = filelib:ensure_path(Dir),
    Dir.

%% Asking the runtime whether it is up, rather than asking the module what it
%% exports: `init()`'s own return value never reaches the kernel.
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

post_restore(_Inst, _Ctx) -> ok.

conformance_fixtures(_Artifact) ->
    #{base =>
          #{echo => #{source => ~"function main(c) return {answer = c.value + 1} end",
                      context => #{~"value" => 41}},
            failure => #{source => ~"function main(c) error('boom') end"},
            runaway => #{source => ~"function main(c) while true do end end"},
            state_change => #{source => state_change_source()}},
      by_capability => #{}}.

%% A global the guest bumps, which is exactly what a reused interpreter would
%% leak and a restored one cannot.
state_change_source() ->
    <<"n = (n or 0) + 1\n",
      "function main(c) return {n = n} end">>.

classify({ok, _Values}, _State) -> continue;
classify({error, _Err}, _State) -> {stop, trapped}.
