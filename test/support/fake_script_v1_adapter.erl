-module(fake_script_v1_adapter).
-moduledoc """
A `script_v1.combined` adapter whose guests are built from WAT.

The profile is proved before either interpreter exists, which is the point: a
failure here is unambiguously the profile's rather than QuickJS's. The guests
read the per-request marker out of `argv` exactly as a real bootstrap does, and
frame their result on stdout the same way.
""".

-behaviour(script_worker).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2]).

-define(PROLOGUE, "
  (import \"wasi_snapshot_preview1\" \"fd_write\"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import \"wasi_snapshot_preview1\" \"args_sizes_get\"
    (func $args_sizes_get (param i32 i32) (result i32)))
  (import \"wasi_snapshot_preview1\" \"args_get\"
    (func $args_get (param i32 i32) (result i32)))
  (import \"wasi_snapshot_preview1\" \"proc_exit\" (func $exit (param i32)))
  (memory 1)
  (export \"memory\" (memory 0))
  (data (i32.const 400) \"{\\\"ok\\\":{\\\"answer\\\":42}}\\n\")
  (data (i32.const 440) \"{\\\"ok\\\":{\\\"fake\\\":1}}\\n\")
  (data (i32.const 600) \"{\\\"error\\\":{\\\"code\\\":\\\"no_entry_point\\\",\\\"message\\\":\\\"no main\\\"}}\\n\")
  (data (i32.const 680) \"{\\\"error\\\":{\\\"code\\\":\\\"exception\\\",\\\"message\\\":\\\"boom\\\"}}\\n\")
  (data (i32.const 750) \"{\\\"error\\\":{\\\"code\\\":\\\"invented\\\",\\\"message\\\":\\\"x\\\"}}\\n\")
  (data (i32.const 470) \"not json at all\\n\")
  (data (i32.const 500) \"tenant output\\n\")
  (data (i32.const 530) \"deadbeefdeadbeefdeadbeefdeadbeef\")
  (data (i32.const 570) \"on stderr\\n\")
  (func $w (param $ptr i32) (param $len i32) (param $fd i32)
    (i32.store (i32.const 0) (local.get $ptr))
    (i32.store (i32.const 4) (local.get $len))
    (drop (call $fd_write (local.get $fd) (i32.const 0)
                          (i32.const 1) (i32.const 8))))
  (func $out (param $ptr i32) (param $len i32)
    (call $w (local.get $ptr) (local.get $len) (i32.const 1)))
  ;; The marker is argv[1], always 32 hex characters, so no length has to be
  ;; computed. A real bootstrap reads it the same way.
  (func $marker (result i32)
    (drop (call $args_sizes_get (i32.const 16) (i32.const 20)))
    (drop (call $args_get (i32.const 32) (i32.const 128)))
    (i32.load (i32.const 36)))
  (func $frame (param $ptr i32) (param $len i32)
    (call $out (call $marker) (i32.const 32))
    (call $out (local.get $ptr) (local.get $len)))").

wat(Shape) ->
    iolist_to_binary(["(module", ?PROLOGUE, "\n  (func (export \"_start\")",
                      "\n    (local $i i32)",
                      body(Shape), "\n    (call $exit (i32.const 0))))"]).

%% Ordinary: some output of the tenant's own, then the framed result.
body(ok) ->
    "
    (call $out (i32.const 500) (i32.const 14))
    (call $frame (i32.const 400) (i32.const 21))";
%% Tenant output containing a *different* 32-hex string, which must not be
%% mistaken for the delimiter.
body(decoy) ->
    "
    (call $out (i32.const 530) (i32.const 32))
    (call $frame (i32.const 400) (i32.const 21))";
%% The tenant echoes the real marker back with a result of its own. The last
%% occurrence wins, and the transport does not pretend to tell them apart.
body(echo_marker) ->
    "
    (call $frame (i32.const 440) (i32.const 18))
    (call $frame (i32.const 400) (i32.const 21))";
body(no_result) ->
    "
    (call $out (i32.const 500) (i32.const 14))";
body(no_entry_point) ->
    "
    (call $frame (i32.const 600) (i32.const 56))";
body(raised) ->
    "
    (call $frame (i32.const 680) (i32.const 48))";
body(invented_code) ->
    "
    (call $frame (i32.const 750) (i32.const 44))";
body(bad_result) ->
    "
    (call $frame (i32.const 470) (i32.const 16))";
%% Writes to the other descriptor, and writes **more than a tight combined
%% budget**, so a single shared number would stop it. Its own stdout stays
%% small: 32 bytes of marker and 14 of JSON.
body(noisy_stderr) ->
    "
    (local.set $i (i32.const 40))
    (loop $l
      (call $w (i32.const 570) (i32.const 10) (i32.const 2))
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (br_if $l (local.get $i)))
    (call $frame (i32.const 400) (i32.const 21))";
%% Enough tenant output to pass a combined bound before anything is framed.
body(flood) ->
    "
    (loop $l (call $out (i32.const 500) (i32.const 14)) (br $l))";
body(runaway) ->
    "
    (loop $l (br $l))".

-define(SHAPES, [ok, decoy, echo_marker, no_result, bad_result, noisy_stderr,
                 no_entry_point, raised, invented_code, flood, runaway]).

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
    Source = maps:get(source, Request, ~"export function main(c) {}"),
    {ok, #{min_timeout => 100, min_memory_pages => 1,
           request_bytes => byte_size(Context) + byte_size(Source),
           staged_bytes => byte_size(Context) + byte_size(Source),
           staged_files => 2,
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
            Marker = script_v1:marker(),
            case stage(Request, Env) of
                {error, E} ->
                    {error, E, #{marker => Marker}};
                ok ->
                    {ok, #{mode => command, module => M,
                           imports => #{bindings => wasi(Marker, Env)},
                           invoke => [{call, ~"_start", []}]},
                     #{marker => Marker}}
            end
    end.

%% One source and one context, staged rather than passed, because that is what
%% an interpreter expects to find.
stage(Request, Env) ->
    Stage = maps:get(stage, Env),
    Source = maps:get(source, Request, ~"export function main(c) {}"),
    Context = script_v1:encode_context(maps:get(context, Request, #{})),
    case Stage(ro, ~"main.src", Source) of
        {error, _} = E -> E;
        ok             -> Stage(ro, ~"context.json", Context)
    end.

wasi(Marker, Env) ->
    #{mounts := Mounts, channels := Chans} = Env,
    #{host_dir := Dir} = maps:get(ro, Mounts),
    Sink = fun(Which) ->
               C = maps:get(Which, Chans),
               fun(Data) -> script_worker:channel_write(C, Data) end
           end,
    wasi_preview1:imports(
      #{args => [~"qjs", Marker], env => #{},
        dirs => [{~"/", Dir, read}],
        clocks => [monotonic], random => strong,
        stdout => Sink(stdout), stderr => Sink(stderr)}).

decode(#{outcome := exited, exit := 0} = R, #{marker := Marker}) ->
    #{channels := #{stdout := Out, stderr := Err}} = R,
    case script_v1:decode_combined(Out, Marker) of
        {ok, #{result := Result, stdout := Printed}} ->
            {ok, #{result => Result, stdout => Printed, stderr => Err}};
        {error, Code, Msg} ->
            {error, script_v1:error(Code, Msg, #{stdout => Out, stderr => Err})}
    end;
decode(#{outcome := exited, exit := Code} = R, _State) ->
    #{channels := #{stdout := Out, stderr := Err}} = R,
    {error, worker_error:adapter(exit, ~"non-zero exit",
                                 #{code => Code, stdout => Out, stderr => Err})};
decode(#{outcome := trapped, error := undefined}, _State) ->
    {error, worker_error:adapter(adapter_failure, ~"trapped with no error", #{})};
decode(#{outcome := trapped, error := E}, _State) ->
    {error, worker_error:runtime(E)};
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
    #{base => #{echo => #{shape => ok, context => #{~"value" => 41}},
                failure => #{shape => bad_result},
                runaway => #{shape => runaway},
                state_change => #{shape => ok}},
      by_capability => #{files => #{shape => ok},
                         framed_stream => #{shape => flood}}}.

classify({ok, _Values}, _State) ->
    continue;
classify({error, Err}, _State) ->
    case wasi_preview1:exit_code(Err) of
        {ok, Code} -> {stop, {exited, Code}};
        error      -> {stop, trapped}
    end.
