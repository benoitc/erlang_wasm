-module(fake_script_v1_channel_adapter).
-moduledoc """
A `script_v1.channel` adapter whose guests are built from WAT.

The other transport. This one adds a host import, `worker.result(ptr, len)`,
bound to the kernel's result channel, which needs control of the guest's
imports and is therefore for guests we build rather than artifacts we fetch.

What it buys, and the reason both transports exist: stdout and the result are
genuinely separate descriptors, so they carry independent bounds, both are
enforced while streaming, and no delimiter is involved at all. Nothing here can
be imitated by a tenant printing the right bytes, because there are no bytes to
imitate.
""".

-behaviour(script_worker).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2]).

-define(PROLOGUE, "
  (import \"wasi_snapshot_preview1\" \"fd_write\"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import \"wasi_snapshot_preview1\" \"proc_exit\" (func $exit (param i32)))
  (import \"worker\" \"result\" (func $result (param i32 i32)))
  (memory 1)
  (export \"memory\" (memory 0))
  (data (i32.const 400) \"{\\\"ok\\\":{\\\"answer\\\":42}}\")
  (data (i32.const 440) \"not json at all\")
  (data (i32.const 500) \"tenant output\\n\")
  (func $out (param $ptr i32) (param $len i32)
    (i32.store (i32.const 0) (local.get $ptr))
    (i32.store (i32.const 4) (local.get $len))
    (drop (call $fd_write (i32.const 1) (i32.const 0)
                          (i32.const 1) (i32.const 8))))").

wat(Shape) ->
    iolist_to_binary(["(module", ?PROLOGUE, "\n  (func (export \"_start\")",
                      "\n    (local $i i32)", body(Shape),
                      "\n    (call $exit (i32.const 0))))"]).

body(ok) ->
    "
    (call $out (i32.const 500) (i32.const 14))
    (call $result (i32.const 400) (i32.const 20))";
body(no_result) ->
    "
    (call $out (i32.const 500) (i32.const 14))";
body(bad_result) ->
    "
    (call $result (i32.const 440) (i32.const 15))";
%% Floods stdout and still frames a result, which only a transport with two
%% descriptors can be asked to do.
body(flood_stdout) ->
    "
    (local.set $i (i32.const 400))
    (loop $l
      (call $out (i32.const 500) (i32.const 14))
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (br_if $l (local.get $i)))
    (call $result (i32.const 400) (i32.const 20))";
body(flood_result) ->
    "
    (loop $l (call $result (i32.const 400) (i32.const 20)) (br $l))";
body(runaway) ->
    "
    (loop $l (br $l))".

-define(SHAPES, [ok, no_result, bad_result, flood_stdout, flood_result,
                 runaway]).

artifact(_Opts) ->
    lists:foldl(fun(_S, {error, _} = E) -> E;
                   (S, {ok, Acc}) ->
                       case wasm:compile({wat, wat(S)}) of
                           {ok, M}    -> {ok, Acc#{S => M}};
                           {error, E} -> {error, worker_error:runtime(E)}
                       end
                end, {ok, #{}}, ?SHAPES).

requirements(Request, _Artifact) when is_map(Request) ->
    Context = script_v1:encode_context(maps:get(context, Request, #{})),
    {ok, #{min_timeout => 100, min_memory_pages => 1,
           request_bytes => byte_size(Context),
           staged_bytes => byte_size(Context), staged_files => 1,
           mounts => #{ro => #{guest_path => ~"/", mode => read}}}};
requirements(_Request, _Artifact) ->
    {error, worker_error:adapter(adapter_failure, ~"request is not a map", #{})}.

prepare(Request, Artifact, Env) ->
    Shape = maps:get(shape, Request, ok),
    case maps:find(Shape, Artifact) of
        error ->
            {error, worker_error:adapter(adapter_failure, ~"unknown shape",
                                         #{shape => Shape}), undefined};
        {ok, M} ->
            Context = script_v1:encode_context(maps:get(context, Request, #{})),
            case (maps:get(stage, Env))(ro, ~"context.json", Context) of
                {error, E} ->
                    {error, E, #{}};
                ok ->
                    {ok, #{mode => command, module => M,
                           imports => #{bindings => bindings(Env)},
                           invoke => [{call, ~"_start", []}]},
                     #{}}
            end
    end.

%% WASI plus one import of our own. The kernel handed the channels down without
%% knowing that one of them would become a host function rather than a stream.
bindings(Env) ->
    #{mounts := Mounts, channels := Chans} = Env,
    #{host_dir := Dir} = maps:get(ro, Mounts),
    Sink = fun(Which) ->
               C = maps:get(Which, Chans),
               fun(Data) -> script_worker:channel_write(C, Data) end
           end,
    Result = maps:get(result, Chans),
    Wasi = wasi_preview1:imports(
             #{args => [~"guest"], env => #{},
               dirs => [{~"/", Dir, read}],
               clocks => [monotonic], random => strong,
               stdout => Sink(stdout), stderr => Sink(stderr)}),
    Wasi#{{~"worker", ~"result"} =>
              fun(Ctx, [Ptr, Len]) ->
                  case wasm:read_memory(Ctx, Ptr, Len) of
                      {ok, Bytes} ->
                          script_worker:channel_write(Result, Bytes),
                          {ok, []};
                      {error, E} ->
                          {trap, E}
                  end
              end}.

decode(#{outcome := exited, exit := 0} = R, _State) ->
    #{channels := #{stdout := Out, stderr := Err, result := Res}} = R,
    case script_v1:decode_channel(Res) of
        {ok, Result} ->
            {ok, #{result => Result, stdout => Out, stderr => Err}};
        {error, Code, Msg} ->
            {error, script_v1:error(Code, Msg, #{stdout => Out, stderr => Err})}
    end;
decode(#{outcome := exited, exit := Code}, _State) ->
    {error, worker_error:adapter(exit, ~"non-zero exit", #{code => Code})};
decode(#{outcome := trapped, error := undefined}, _State) ->
    {error, worker_error:adapter(adapter_failure, ~"trapped with no error", #{})};
decode(#{outcome := trapped, error := E}, _State) ->
    {error, worker_error:runtime(E)};
decode(#{outcome := returned} = R, State) ->
    decode(R#{outcome := exited, exit := 0}, State).

cleanup(_State) -> ok.

capabilities(_Artifact) ->
    #{execution => command,
      input_channels => [files, custom_import],
      result_channels => [custom_import],
      snapshots => unsupported,
      wasi => true}.

conformance_fixtures(_Artifact) ->
    #{base => #{echo => #{shape => ok, context => #{~"value" => 41}},
                failure => #{shape => bad_result},
                runaway => #{shape => runaway},
                state_change => #{shape => ok}},
      by_capability => #{}}.

classify({ok, _Values}, _State) ->
    continue;
classify({error, Err}, _State) ->
    case wasi_preview1:exit_code(Err) of
        {ok, Code} -> {stop, {exited, Code}};
        error      -> {stop, trapped}
    end.
