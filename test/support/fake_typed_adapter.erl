-module(fake_typed_adapter).
-moduledoc """
A worker adapter with **no WASI at all**, and the point of the kernel suite.

Reactor mode, typed arguments in, a typed result out, one custom import, and no
JSON, no source file, no stdin, no stdout and no preopens. It stages nothing.

A kernel that passes `fake_command_adapter` and fails this one is a WASI script
runner, and that failure would be invisible in every other test.
""".

-behaviour(wasm_script_worker).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2]).

-define(WAT, <<"
(module
  (import \"host\" \"input\" (func $input (result i32)))
  (import \"host\" \"emit\" (func $emit))
  (global $state (mut i32) (i32.const 0))
  (func (export \"init\"))
  (func (export \"handle\") (result i32)
    (global.set $state (i32.add (global.get $state) (i32.const 1)))
    (i32.add (call $input) (global.get $state)))
  (func (export \"add\") (param i32 i32) (result i32)
    (i32.add (local.get 0) (local.get 1)))
  (func (export \"boom\") (result i32) (unreachable))
  (func (export \"emit\") (result i32) (loop $l (call $emit) (br $l)) (i32.const 0))
  (func (export \"spin\") (result i32) (loop $l (br $l)) (i32.const 0))
)">>).

artifact(_Opts) ->
    case wasm:compile({wat, ?WAT}) of
        {ok, M}    -> {ok, #{module => M}};
        {error, E} -> {error, wasm_worker_error:runtime(E)}
    end.

%% Zero memory pages is legitimate: this adapter has no memory, and a
%% requirement of "none" has to be expressible or the contract would assume
%% linear memory exists.
requirements(Request, _Artifact) when is_map(Request) ->
    {ok, #{min_timeout => 50, min_memory_pages => 0,
           request_bytes => erlang:external_size(Request),
           staged_bytes => 0, staged_files => 0, mounts => #{}}};
requirements(_Request, _Artifact) ->
    {error, wasm_worker_error:adapter(adapter_failure, ~"request is not a map", #{})}.

prepare(Request, #{module := M}, Env) ->
    ok = register_marker(Request, Env),
    ok = register_slow(Request, Env),
    case register_many(Request, Env) of
        {error, E} ->
            {error, E, undefined};
        ok ->
            ok = maybe_kill_reaper(Request),
            prepare_spec(Request, M, Env)
    end.

prepare_spec(Request, M, Env) ->
    Input = maps:get(input, Request, 41),
    Result = maps:get(result, maps:get(channels, Env)),
    Bindings = #{{~"host", ~"input"} => fun(_Ctx, []) -> {ok, [Input]} end,
                 %% Bound wherever this guest expects it. The kernel handed the
                 %% channel down without knowing what it was for.
                 {~"host", ~"emit"} =>
                     fun(_Ctx, []) ->
                         wasm_script_worker:channel_write(Result, ~"chunk"),
                         {ok, []}
                     end},
    case invocations(Request) of
        {error, E} ->
            {error, E, undefined};
        {ok, Invoke} ->
            {ok, #{mode => reactor, module => M,
                   imports => #{bindings => Bindings},
                   invoke => Invoke},
             state_of(Request)}
    end.

%% Registered before the guest runs, so the conformance kit can see that
%% cleanup happened whichever way the request ended.
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

%% Actions that each take real time, so a case can tell the per-callback bound
%% from the whole-job one. They run LIFO, and each records that it got to run.
register_slow(Request, Env) ->
    case maps:get(slow_actions, Request, undefined) of
        undefined ->
            ok;
        {N, Sleep, Dir} ->
            Register = maps:get(register, maps:get(cleanup, Env)),
            lists:foreach(
              fun(I) ->
                  Path = filename:join(Dir, "slow-" ++ integer_to_list(I)),
                  {ok, _} = Register(fun() ->
                                         timer:sleep(Sleep),
                                         file:write_file(Path, ~"ran")
                                     end)
              end, lists:seq(1, N)),
            ok
    end.

%% The adapter-controlled action list has a ceiling, or an adapter in a loop
%% registers until the reaper's memory is the bound.
register_many(Request, Env) ->
    case maps:get(register_n, Request, 0) of
        0 ->
            ok;
        N ->
            Register = maps:get(register, maps:get(cleanup, Env)),
            lists:foldl(
              fun(_, {error, _} = E) -> E;
                 (_, ok) ->
                     case Register(fun() -> ok end) of
                         {ok, _}         -> ok;
                         {error, Err, _} -> {error, Err}
                     end
              end, ok, lists:seq(1, N))
    end.

%% Kills the registry *after* `register' succeeded and before the kernel can
%% transfer, which is the window the mirror exists for and the only way to
%% reach it deterministically.
maybe_kill_reaper(Request) ->
    case maps:get(kill_reaper_in_prepare, Request, false) of
        false -> ok;
        true  -> try wasm_worker_reaper:stop() catch _:_ -> ok end, ok
    end.

invocations(#{op := add, args := [A, B]}) -> {ok, [{call, ~"add", [A, B]}]};
invocations(#{op := failure})             -> {ok, [{call, ~"boom", []}]};
invocations(#{op := emit})                -> {ok, [{call, ~"emit", []}]};
invocations(#{op := runaway})             -> {ok, [{call, ~"spin", []}]};
invocations(#{op := state_change})        -> {ok, [{call, ~"handle", []},
                                                   {call, ~"handle", []}]};
invocations(#{op := echo})                -> {ok, [{call, ~"init", []},
                                                   {call, ~"handle", []}]};
invocations(#{op := nothing})             -> {ok, []};
invocations(_)                            -> {ok, [{call, ~"init", []},
                                                   {call, ~"handle", []}]}.

%% The result is the typed value the last invocation returned. No stdout is
%% read, because there is none.
decode(#{outcome := returned, values := Values}, _State) ->
    {ok, Values};
decode(#{outcome := trapped, error := undefined}, _State) ->
    {error, wasm_worker_error:adapter(adapter_failure, ~"trapped with no error", #{})};
decode(#{outcome := trapped, error := E}, _State) ->
    {error, wasm_worker_error:runtime(E)};
decode(#{outcome := exited, exit := Code}, _State) ->
    {error, wasm_worker_error:adapter(exit, ~"exited", #{code => Code})}.

%% Writes its marker so the kit can see it ran, and fails on request so the
%% kit can see what runs only when it does.
state_of(Request) ->
    #{op => maps:get(op, Request, echo),
      cleanup_marker => maps:get(cleanup_marker, Request, undefined),
      sleep_cleanup => maps:get(sleep_cleanup, Request, 0),
      fail_cleanup => maps:get(fail_cleanup, Request, false)}.

cleanup(#{cleanup_marker := Path, fail_cleanup := Fail} = S)
  when Path =/= undefined ->
    timer:sleep(maps:get(sleep_cleanup, S, 0)),
    %% Idempotent by construction: the same bytes whichever attempt writes
    %% them, which is what a replayed cleanup has to be.
    ok = file:write_file(Path, ~"done"),
    case Fail of
        true  -> error(deliberate_cleanup_failure);
        hang  -> timer:sleep(infinity);
        false -> ok
    end;
cleanup(_State) -> ok.

capabilities(_Artifact) ->
    #{execution => reactor,
      input_channels => [typed_args, custom_import],
      result_channels => [typed_result],
      snapshots => unsupported,
      wasi => false}.

conformance_fixtures(_Artifact) ->
    #{base => #{echo => #{op => echo, input => 41},
                failure => #{op => failure},
                runaway => #{op => runaway},
                state_change => #{op => state_change}},
      by_capability => #{typed_args => #{op => add, args => [2, 3]},
                         typed_result => #{op => add, args => [20, 22]},
                         custom_import => #{op => echo, input => 7},
                         %% The hooks the kit needs to reach the cleanup and
                         %% bound paths: registering many actions, a slow
                         %% callback, a result channel to fill.
                         adapter_hooks => #{op => echo},
                         cleanup_marker => #{op => failure},
                         no_wasi => #{op => echo},
                         empty_invoke => #{op => nothing}}}.

%% Run the whole sequence, and let a trap stop it. Nothing here knows what a
%% WASI exit is, because there is no WASI.
classify({ok, _Values}, _State)  -> continue;
classify({error, _Err}, _State)  -> {stop, trapped}.
