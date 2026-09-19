-module(fake_command_adapter).
-moduledoc """
A worker adapter in command mode, over WASI, with streams.

Writes known bytes to stdout and stderr, exits with a chosen code, optionally
loops for ever, and optionally prints without bound. It declares one read-only
mount and stages a file into it, so the mount and `stage/3` machinery is
exercised by an adapter that has one.

Paired with `fake_typed_adapter`, which has none of that, these two are what
the kernel suite runs the identical base case list against.
""".

-behaviour(wasm_script_worker).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2]).

%% One small module per behaviour, rather than one module branching on a value
%% it would have to be told somehow. A WASI command has no host import to be
%% told through, and inventing one would make it not a WASI command.
-define(PROLOGUE, "
  (import \"wasi_snapshot_preview1\" \"fd_write\"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import \"wasi_snapshot_preview1\" \"proc_exit\" (func $exit (param i32)))
  (import \"wasi_snapshot_preview1\" \"path_open\"
    (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (memory 1)
  (export \"memory\" (memory 0))
  (data (i32.const 64) \"hello\")
  (data (i32.const 80) \"err\")
  (data (i32.const 200) \"out.txt\")
  (data (i32.const 220) \"../.journal\")
  (data (i32.const 240) \"input.txt\")
  (func $try (param $fd i32) (param $p i32) (param $l i32) (param $o i32)
             (param $r i64) (result i32)
    (call $path_open (local.get $fd) (i32.const 0) (local.get $p) (local.get $l)
                     (local.get $o) (local.get $r) (local.get $r)
                     (i32.const 0) (i32.const 300)))
  (func $out (param $ptr i32) (param $len i32) (param $fd i32)
    (i32.store (i32.const 0) (local.get $ptr))
    (i32.store (i32.const 4) (local.get $len))
    (drop (call $fd_write (local.get $fd) (i32.const 0)
                          (i32.const 1) (i32.const 8))))").

wat(echo) ->
    iolist_to_binary(["(module", ?PROLOGUE, "
  (func (export \"_start\")
    (call $out (i32.const 64) (i32.const 5) (i32.const 1))
    (call $out (i32.const 80) (i32.const 3) (i32.const 2))
    (call $exit (i32.const 0))))"]);
wat(failure) ->
    iolist_to_binary(["(module", ?PROLOGUE, "
  (func (export \"_start\")
    (call $out (i32.const 80) (i32.const 3) (i32.const 2))
    (call $exit (i32.const 3))))"]);
wat(trap) ->
    iolist_to_binary(["(module", ?PROLOGUE, "
  (func (export \"_start\") (unreachable)))"]);
%% What a *guest* can do with the preopens it was given, which is the claim
%% mounts exist to make and the only way to check it is from inside.
wat(probe) ->
    iolist_to_binary(["(module", ?PROLOGUE, "
  (func (export \"_start\")
    ;; create a file in the read-only mount
    (i32.store8 (i32.const 100)
      (call $try (i32.const 3) (i32.const 200) (i32.const 7) (i32.const 1)
                 (i64.const 1088)))
    ;; climb out of it
    (i32.store8 (i32.const 101)
      (call $try (i32.const 3) (i32.const 220) (i32.const 11) (i32.const 0)
                 (i64.const 2)))
    ;; read what was staged into it
    (i32.store8 (i32.const 102)
      (call $try (i32.const 3) (i32.const 240) (i32.const 9) (i32.const 0)
                 (i64.const 2)))
    ;; create a file in whatever fd 4 is, if anything
    (i32.store8 (i32.const 103)
      (call $try (i32.const 4) (i32.const 200) (i32.const 7) (i32.const 1)
                 (i64.const 1088)))
    (call $out (i32.const 100) (i32.const 4) (i32.const 1))
    (call $exit (i32.const 0))))"]);
wat(grow) ->
    iolist_to_binary(["(module", ?PROLOGUE, "
  (func (export \"_start\")
    (i32.store8 (i32.const 100) (memory.grow (i32.const 16)))
    (call $out (i32.const 100) (i32.const 1) (i32.const 1))
    (call $exit (i32.const 0))))"]);
wat(runaway) ->
    iolist_to_binary(["(module", ?PROLOGUE, "
  (func (export \"_start\") (loop $l (br $l))))"]);
wat(flood) ->
    iolist_to_binary(["(module", ?PROLOGUE, "
  (func (export \"_start\")
    (loop $l (call $out (i32.const 64) (i32.const 5) (i32.const 1)) (br $l))))"]).

-define(SHAPES, [echo, failure, trap, runaway, flood, probe, grow]).

artifact(_Opts) ->
    lists:foldl(fun(_Shape, {error, _} = E) -> E;
                   (Shape, {ok, Acc}) ->
                       case wasm:compile({wat, wat(Shape)}) of
                           {ok, M}    -> {ok, Acc#{Shape => M}};
                           {error, E} -> {error, wasm_worker_error:runtime(E)}
                       end
                end, {ok, #{}}, ?SHAPES).

%% All of them, including the staged file, because `requirements/2` is the
%% callback that has the artifact and `prepare/3` cannot add a mount
%% afterwards: the kernel creates and preopens them before `prepare/3` runs,
%% which is what lets it own them.
requirements(Request, _Artifact) when is_map(Request) ->
    Staged = maps:get(stage, Request, <<>>),
    Mounts = case maps:get(write_mount, Request, false) of
                 false -> #{ro => #{guest_path => ~"/", mode => read}};
                 true  -> #{ro => #{guest_path => ~"/", mode => read},
                            rw => #{guest_path => ~"/out", mode => write}}
             end,
    {ok, #{min_timeout => 100, min_memory_pages => 1,
           request_bytes => erlang:external_size(Request),
           staged_bytes => byte_size(Staged),
           staged_files => case Staged of <<>> -> 0; _ -> 1 end,
           mounts => Mounts}};
requirements(_Request, _Artifact) ->
    {error, wasm_worker_error:adapter(adapter_failure, ~"request is not a map", #{})}.

prepare(Request, Artifact, Env) ->
    Shape = maps:get(shape, Request, echo),
    case maps:find(Shape, Artifact) of
        error ->
            {error, wasm_worker_error:adapter(adapter_failure, ~"unknown shape",
                                         #{shape => Shape}), undefined};
        {ok, M} ->
            case prepare_files(Request, Env) of
                {error, E} ->
                    {error, E, #{shape => Shape}};
                {ok, Probe} ->
                    Once = {call, ~"_start", []},
                    Invoke = case maps:get(twice, Request, false) of
                                 true  -> [Once, Once];
                                 false -> [Once]
                             end,
                    %% Host bookkeeping, reported only for the shape that
                    %% asks about it. A result that carried the request
                    %% directory would differ between two identical requests
                    %% and make an isolation comparison impossible.
                    Dirs = case Shape of
                               probe -> #{N => maps:get(host_dir, Mt)
                                          || N := Mt <- maps:get(mounts, Env)};
                               _     -> #{}
                           end,
                    {ok, #{mode => command, module => M,
                           imports => #{bindings => wasi(Env)},
                           invoke => Invoke},
                     (state_of(Request, Shape))#{probe => Probe,
                                                 mount_dirs => Dirs}}
            end
    end.

prepare_files(Request, Env) ->
    ok = register_marker(Request, Env),
    ok = wedge(Request, Env),
    case stage_input(Request, Env) of
        {error, _} = E -> E;
        ok             -> stage_probe(Request, Env)
    end.

%% Leaves something inside the request tree that cannot be removed, so cleanup
%% genuinely fails rather than being told it did. A read-only directory is the
%% portable way to make `file:del_dir_r/1' fail without needing root.
wedge(Request, Env) ->
    case maps:get(wedge_cleanup, Request, false) of
        false ->
            ok;
        true ->
            #{host_dir := Dir} = maps:get(ro, maps:get(mounts, Env)),
            Locked = filename:join(Dir, "locked"),
            ok = filelib:ensure_path(Locked),
            ok = file:write_file(filename:join(Locked, "keep"), ~"x"),
            ok = file:change_mode(Locked, 8#500)
    end.

%% The kit drives `stage/3' through this rather than reaching into the kernel,
%% because staging is the adapter's call to make and the bound is the kernel's
%% to enforce.
%% Every write is attempted and each outcome reported, rather than stopping at
%% the first error. Accounting is per request, so a case that needs to see a
%% refund has to do all of its staging inside one.
stage_probe(Request, Env) ->
    case maps:get(stage_probe, Request, undefined) of
        undefined ->
            {ok, []};
        {Mount, Writes} ->
            Stage = maps:get(stage, Env),
            {ok, [outcome(Stage(Mount, Path, Data)) || {Path, Data} <- Writes]}
    end.

outcome(ok)                    -> ok;
outcome({error, #{kind := K}}) -> K.

register_marker(Request, Env) ->
    case maps:get(cleanup_marker, Request, undefined) of
        undefined ->
            ok;
        Path ->
            Register = maps:get(register, maps:get(cleanup, Env)),
            Action = filename:join(filename:dirname(Path), "action-marker"),
            %% Records *when* it ran, not merely that it did: the contract is
            %% that a transferred action runs after `cleanup/1', and only when
            %% `cleanup/1' failed.
            {ok, _Token} =
                Register(fun() ->
                             Note = case filelib:is_file(Path) of
                                        true  -> ~"after-cleanup";
                                        false -> ~"before-cleanup"
                                    end,
                             file:write_file(Action, Note)
                         end),
            ok
    end.

stage_input(Request, Env) ->
    case maps:get(stage, Request, <<>>) of
        <<>> -> ok;
        Data -> (maps:get(stage, Env))(ro, ~"input.txt", Data)
    end.

%% The channels are bound wherever this guest expects them, which for a WASI
%% command is the stdio config. The kernel never knew what they were for.
wasi(Env) ->
    #{mounts := Mounts, channels := Chans} = Env,
    Sink = fun(Which) ->
               C = maps:get(Which, Chans),
               fun(Data) -> wasm_script_worker:channel_write(C, Data) end
           end,
    Dirs = [{maps:get(guest_path, M), maps:get(host_dir, M), maps:get(mode, M)}
            || Name <- lists:sort(maps:keys(Mounts)),
               M <- [maps:get(Name, Mounts)]],
    wasi_preview1:imports(
      #{args => [~"fake"], env => #{},
        dirs => Dirs,
        clocks => [monotonic],
        random => strong,
        stdout => Sink(stdout), stderr => Sink(stderr)}).

decode(#{outcome := exited, exit := 0} = R, State) ->
    {ok, (streams(R))#{probe => maps:get(probe, State, []),
                       mount_dirs => maps:get(mount_dirs, State, #{})}};
decode(#{outcome := exited, exit := Code} = R, _State) ->
    {error, wasm_worker_error:adapter(exit, ~"non-zero exit",
                                 maps:merge(#{code => Code}, streams(R)))};
decode(#{outcome := returned} = R, _State) ->
    {ok, streams(R)};
decode(#{outcome := trapped, error := undefined}, _State) ->
    {error, wasm_worker_error:adapter(adapter_failure, ~"trapped with no error", #{})};
decode(#{outcome := trapped, error := E}, _State) ->
    {error, wasm_worker_error:runtime(E)}.

streams(#{channels := #{stdout := Out, stderr := Err}, truncated := T}) ->
    #{stdout => Out, stderr => Err, truncated => T}.

%% Writes its marker so the kit can see it ran, and fails on request so the
%% kit can see what runs only when it does.
state_of(Request, Shape) ->
    #{shape => Shape,
      keep_going => maps:get(keep_going, Request, false),
      cleanup_marker => maps:get(cleanup_marker, Request, undefined),
      fail_cleanup => maps:get(fail_cleanup, Request, false)}.

cleanup(#{cleanup_marker := Path, fail_cleanup := Fail}) when Path =/= undefined ->
    ok = file:write_file(Path, ~"done"),
    case Fail of
        true  -> error(deliberate_cleanup_failure);
        false -> ok
    end;
cleanup(_State) -> ok.

capabilities(_Artifact) ->
    #{execution => command,
      input_channels => [stdin, files],
      result_channels => [framed_stream],
      snapshots => unsupported,
      wasi => true}.

conformance_fixtures(_Artifact) ->
    #{base => #{echo => #{shape => echo},
                failure => #{shape => failure},
                runaway => #{shape => runaway},
                state_change => #{shape => echo}},
      %% What this adapter knows how to be asked. The kit reads the keys, not
      %% the values: each one names a group of cases and carries the request
      %% shape only this adapter could have built.
      by_capability => #{stage_probe => #{shape => echo},
                         cleanup_marker => #{shape => failure},
                         guest_probe => #{shape => probe, stage => ~"staged"},
                         memory_grow => #{shape => grow},
                         classify_stop => #{shape => failure, twice => true},
                         classify_continue => #{shape => failure, twice => true,
                                                keep_going => true},
                         invoke_once => #{shape => echo},
                         invoke_twice => #{shape => echo, twice => true},
                         framed_stream => #{shape => flood}}}.

%% `proc_exit' becomes a trap carrying the status, so only this adapter can
%% tell it from any other trap. That is exactly why the kernel does not try.
classify({ok, _Values}, _State) ->
    continue;
classify({error, _Err}, #{keep_going := true}) ->
    %% The same trap, answered differently. Nothing the kernel can see decides
    %% this, which is the point.
    continue;
classify({error, Err}, _State) ->
    case wasi_preview1:exit_code(Err) of
        {ok, Code} -> {stop, {exited, Code}};
        error      -> {stop, trapped}
    end.
