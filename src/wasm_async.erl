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

-export([builtin/2, begin_task/1, end_task/0, take_return/0,
         new_future_readable/2, new_stream_readable/2]).

%% The callee (export) status low nibble, returned by an async-lift core function:
%% the task exited (its result is ready), yielded, or is waiting on a waitable-set.
-define(EXIT, 0).
-define(YIELD, 1).
-define(WAIT, 2).

%% The stream/future read/write completion code (Canonical ABI `CopyResult`), in
%% the low 4 bits of the returned i32; a stream also packs the element count copied
%% in the high bits (`result | (progress << 4)`).
-define(COMPLETED, 0).
-define(DROPPED, 1).

-define(TASK_RETURN, {?MODULE, task_return}).
-define(TASK_INST, {?MODULE, task_instance}).
-define(CTX(Slot), {?MODULE, context, Slot}).
-define(WAITABLE(H), {?MODULE, waitable, H}).
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
    clear_frame(),
    put(?TASK_INST, Inst),
    ok.

-doc "Tear the task frame down, clearing its return value, context and waitables.".
-spec end_task() -> ok.
end_task() ->
    clear_frame(),
    _ = erase(?TASK_INST),
    ok.

clear_frame() ->
    _ = erase(?TASK_RETURN),
    _ = [erase(K) || K <- get_keys(), is_frame_key(K)],
    ok.

-doc "The value the task handed back through `task.return`, or `undefined`.".
-spec take_return() -> {ok, term()} | undefined.
take_return() ->
    case erase(?TASK_RETURN) of
        undefined -> undefined;
        Value     -> {ok, Value}
    end.

is_frame_key(?CTX(_))      -> true;
is_frame_key(?WAITABLE(_)) -> true;
is_frame_key(_)            -> false.

-doc """
Create the readable end of a future already holding `Value` (of descriptor `Desc`),
returning its handle. `call_async` hands this to a guest that reads a `future<T>`
parameter; the guest's `future.read` completes at once (no wait).
""".
-spec new_future_readable(wasm_canon:desc(), term()) -> non_neg_integer().
new_future_readable(Desc, Value) ->
    H = next_handle(),
    put(?WAITABLE(H), {future, Desc, ready, Value}),
    H.

-doc """
Create the readable end of a stream already holding `Elements` (a binary for a
`stream<u8>`) and closed, returning its handle. A guest reading the `stream<T>`
parameter drains it and then sees the writable end dropped.
""".
-spec new_stream_readable(wasm_canon:desc(), binary()) -> non_neg_integer().
new_stream_readable(Desc, Elements) ->
    H = next_handle(),
    put(?WAITABLE(H), {stream, Desc, Elements, closed}),
    H.

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
%% stream/future `new` mints a packed (readable, writable) handle pair. The guest
%% uses these for values it produces; reading them back (the write direction) is a
%% later milestone, so the ends are recorded but empty.
builtin(stream_new, _Meta) ->
    fun(_Ctx, _Flats) -> {ok, [new_pair(stream)]} end;
builtin(future_new, _Meta) ->
    fun(_Ctx, _Flats) -> {ok, [new_pair(future)]} end;
%% future.read(handle, ptr) -> CopyResult. A readable future holding a value stores
%% it at `ptr` and reports COMPLETED; a spent or empty future reports DROPPED.
builtin(future_read, _Meta) ->
    fun(_Ctx, [H, Ptr | _]) ->
        case get(?WAITABLE(H)) of
            {future, Desc, ready, Value} ->
                ok = wasm_canon:store_value(task_instance(), Desc, Ptr, Value),
                put(?WAITABLE(H), {future, Desc, taken, Value}),
                {ok, [?COMPLETED]};
            _ ->
                {ok, [?DROPPED]}
        end
    end;
%% stream.read(handle, ptr, count) -> result | (progress << 4). Copy up to `count`
%% elements into `ptr`, reporting COMPLETED with the count copied; once the readable
%% end is drained and its writer dropped, report DROPPED with zero progress.
builtin(stream_read, _Meta) ->
    fun(_Ctx, [H, Ptr, Count | _]) ->
        case get(?WAITABLE(H)) of
            {stream, Desc, Elements, State} ->
                {Copied, Rest} = take_elements(Desc, Elements, Count),
                ok = write_elements(task_instance(), Desc, Ptr, Copied),
                put(?WAITABLE(H), {stream, Desc, Rest, State}),
                {ok, [stream_status(count_elements(Desc, Copied), Rest, State)]};
            _ ->
                {ok, [(0 bsl 4) bor ?DROPPED]}
        end
    end;
builtin(Which, _Meta) when Which =:= stream_write; Which =:= future_write;
                           Which =:= stream_cancel_read; Which =:= stream_cancel_write;
                           Which =:= future_cancel_read; Which =:= future_cancel_write ->
    %% The write direction and cancellation report no progress yet (milestone 2+).
    fun(_Ctx, _Flats) -> {ok, [(0 bsl 4) bor ?COMPLETED]} end;
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

%% A fresh (readable, writable) end pair, recorded empty, returned packed as the ABI
%% wants (readable in the high 32 bits, writable in the low 32).
new_pair(Kind) ->
    R = next_handle(),
    W = next_handle(),
    put(?WAITABLE(R), {Kind, unknown, <<>>, open}),
    (R bsl 32) bor W.

%% Split up to `Count` elements off the front of a stream's buffer. `stream<u8>` is
%% a binary; a stream of any other element type is a list of terms.
take_elements(_Desc, Bin, Count) when is_binary(Bin) ->
    N = min(Count, byte_size(Bin)),
    <<Take:N/binary, Rest/binary>> = Bin,
    {Take, Rest};
take_elements(_Desc, List, Count) when is_list(List) ->
    N = min(Count, length(List)),
    {lists:sublist(List, N), lists:nthtail(N, List)}.

count_elements(_Desc, Bin) when is_binary(Bin) -> byte_size(Bin);
count_elements(_Desc, List) when is_list(List) -> length(List).

%% Write the copied elements at `Ptr`: a `stream<u8>` binary lands directly, any
%% other element type is stored one at a time at its natural stride.
write_elements(_Inst, _Desc, _Ptr, <<>>) -> ok;
write_elements(Inst, _Desc, Ptr, Bin) when is_binary(Bin) ->
    wasm:write_memory(Inst, Ptr, Bin);
write_elements(Inst, Desc, Ptr, List) when is_list(List) ->
    {Size, _} = wasm_canon:size_align(Desc),
    lists:foreach(fun({I, V}) ->
                      ok = wasm_canon:store_value(Inst, Desc, Ptr + I * Size, V)
                  end, lists:zip(lists:seq(0, length(List) - 1), List)),
    ok.

%% The stream.read status: COMPLETED with the count copied, unless the buffer is now
%% empty and the writer is closed, which is DROPPED (zero progress) so the guest ends.
stream_status(0, Rest, closed) when Rest =:= <<>>; Rest =:= [] ->
    (0 bsl 4) bor ?DROPPED;
stream_status(Copied, _Rest, _State) ->
    (Copied bsl 4) bor ?COMPLETED.

get_context(Slot) ->
    case get(?CTX(Slot)) of
        undefined -> 0;
        Value     -> Value
    end.

next_handle() ->
    N = case get(?NEXT) of undefined -> 1; V -> V end,
    put(?NEXT, N + 1),
    N.
