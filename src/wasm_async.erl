-module(wasm_async).
-moduledoc """
Internal: the async Canonical ABI runtime (Component Model async, not a WASI
version).

The async ABI lets a component export or import an `async func` and carry typed
`future<T>`/`stream<T>` values, with structured concurrency built from tasks,
waitable-sets and subtasks. wit-bindgen's async support compiles even a
synchronous-looking `async fn echo(s) -> s` into a component that imports the async
built-ins (`task.return`, `context.get/set`, `waitable-set.*`, `stream.*`,
`waitable.join`, `task.cancel`) and exports an `[async-lift]` function with a
callback, so the whole substrate has to exist for any such component to link.

The BEAM makes the executor cheap: a task is the process running the call, a wait is
a selective `receive`, and readiness arrives as a message. `wasm_component_link`
binds each async canon built-in to `builtin/2` here (like the resource intrinsics),
and `wasm_component:call_async/4` drives an `[async-lift]` export: it calls the core
function, reads the returned status, and on a synchronous completion lifts the value
the guest handed back through `task.return`.

Milestone 1 scope: enough to run a wit-bindgen async export that completes
synchronously (`task.return` then `EXIT`), the callback never firing. The
per-run state (the current task's returned value and its context slots) lives in the
process dictionary, one live task per process, matching the host-resource contract
in `wasm_component`. Futures, streams and real waiting are milestone 2+, present here
as coherent linkable built-ins so a component that imports them instantiates.
""".

-export([builtin/2, begin_task/1, end_task/0, take_return/0]).

%% The callee (export) status low nibble, returned by an async-lift core function:
%% the task exited (its result is ready), yielded, or is waiting on a waitable-set.
-define(EXIT, 0).
-define(YIELD, 1).
-define(WAIT, 2).

-define(TASK_RETURN, {?MODULE, task_return}).
-define(TASK_INST, {?MODULE, task_instance}).
-define(CTX(Slot), {?MODULE, context, Slot}).
-define(NEXT, {?MODULE, next_handle}).

%%% --------------------------------------------------------------- task frame ---

-doc """
Start a task frame for the current process, clearing any prior return value and
context slots. `call_async` calls this before invoking an async export, passing the
instance that owns the guest memory the built-ins read and write (the lift core's
instance, which `Ctx` does not expose when that core imports its memory).
""".
-spec begin_task(wasm:instance()) -> ok.
begin_task(Inst) ->
    _ = erase(?TASK_RETURN),
    _ = [erase(K) || K <- get_keys(), is_context_key(K)],
    put(?TASK_INST, Inst),
    ok.

-doc "Tear the task frame down, clearing its return value and context slots.".
-spec end_task() -> ok.
end_task() ->
    _ = erase(?TASK_RETURN),
    _ = erase(?TASK_INST),
    _ = [erase(K) || K <- get_keys(), is_context_key(K)],
    ok.

-doc "The value the task handed back through `task.return`, or `undefined`.".
-spec take_return() -> {ok, term()} | undefined.
take_return() ->
    case erase(?TASK_RETURN) of
        undefined -> undefined;
        Value     -> {ok, Value}
    end.

is_context_key(?CTX(_)) -> true;
is_context_key(_)       -> false.

%%% ----------------------------------------------------------------- built-ins ---

-doc """
The core function a given async canon built-in binds to.

`Which` is the built-in name `wasm_component_link:canon/1` parsed; `Meta` carries
what the built-in needs (a `task.return` result descriptor and string encoding, a
`context.get/set` slot). Each returns a core function `fun(Ctx, Flats)` yielding
`{ok, Results}` or `{trap, Reason}`, the same shape the resource intrinsics use.
""".
-spec builtin(atom(), map()) -> function().
%% task.return: the guest hands back the task's result value. Lift it from the
%% caller's memory by the declared result type and stash it for `call_async`.
builtin(task_return, #{result := Result}) ->
    fun(_Ctx, Flats) ->
        Value = case Result of
                    none -> undefined;
                    _    -> Inst = task_instance(),
                            {Lifted, _} = wasm_canon:lift_params(Inst, [Result], Flats),
                            hd(Lifted)
                end,
        put(?TASK_RETURN, Value),
        {ok, []}
    end;
%% context.get/set: a task-local i32 slot wit-bindgen uses to stash its task state
%% pointer across the callback boundary.
builtin(context_get, #{slot := Slot}) ->
    fun(_Ctx, _Flats) -> {ok, [get_context(Slot)]} end;
builtin(context_set, #{slot := Slot}) ->
    fun(_Ctx, [Value]) -> put(?CTX(Slot), Value), {ok, []} end;
%% waitable-set: a set of pending events. With nothing awaited (the synchronous
%% path), a new set is a fresh handle and a poll reports no event (NONE = 0).
builtin(waitable_set_new, _Meta) ->
    fun(_Ctx, _Flats) -> {ok, [next_handle()]} end;
builtin(waitable_set_wait, _Meta) ->
    fun(_Ctx, _Flats) -> {ok, [0]} end;
builtin(waitable_set_poll, _Meta) ->
    fun(_Ctx, _Flats) -> {ok, [0]} end;
builtin(waitable_set_drop, _Meta) ->
    fun(_Ctx, _Flats) -> {ok, []} end;
builtin(waitable_join, _Meta) ->
    fun(_Ctx, _Flats) -> {ok, []} end;
%% stream: `new` mints a packed (readable, writable) handle pair; read/write report
%% no progress yet, drops and cancels are no-ops. Real streaming is milestone 2.
builtin(stream_new, _Meta) ->
    fun(_Ctx, _Flats) ->
        R = next_handle(),
        W = next_handle(),
        {ok, [(R bsl 32) bor W]}
    end;
builtin(future_new, _Meta) ->
    fun(_Ctx, _Flats) ->
        R = next_handle(),
        W = next_handle(),
        {ok, [(R bsl 32) bor W]}
    end;
builtin(Which, _Meta) when Which =:= stream_read; Which =:= stream_write;
                           Which =:= future_read; Which =:= future_write;
                           Which =:= stream_cancel_read; Which =:= stream_cancel_write;
                           Which =:= future_cancel_read; Which =:= future_cancel_write ->
    %% BLOCKED (0) as the return status: no progress made this call.
    fun(_Ctx, _Flats) -> {ok, [0]} end;
builtin(error_context_new, _Meta) ->
    fun(_Ctx, _Flats) -> {ok, [next_handle()]} end;
%% Everything else (drops, joins, cancels, yield, backpressure, task/subtask
%% lifecycle) has no return value and no effect the synchronous path depends on.
builtin(_Which, _Meta) ->
    fun(_Ctx, _Flats) -> {ok, []} end.

%%% -------------------------------------------------------------------- helpers ---

%% The memory-bearing instance for the running task (set by `call_async`), which the
%% built-ins read and write guest memory through.
task_instance() -> get(?TASK_INST).

get_context(Slot) ->
    case get(?CTX(Slot)) of
        undefined -> 0;
        Value     -> Value
    end.

next_handle() ->
    N = case get(?NEXT) of undefined -> 1; V -> V end,
    put(?NEXT, N + 1),
    N.
