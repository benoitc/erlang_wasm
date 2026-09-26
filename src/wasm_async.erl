-module(wasm_async).
-moduledoc """
Internal: the async Canonical ABI runtime (Component Model async, not a WASI
version).

The async ABI lets a component export or import an `async func` and carry typed
`future<T>`/`stream<T>` values, with structured concurrency built from tasks,
waitable-sets and subtasks. wit-bindgen compiles even a synchronous-looking async fn
into a component that imports the async built-ins (`task.return`, `context.get/set`,
`waitable-set.*`, `stream.*`/`future.*`, `waitable.join`) and exports an
`[async-lift]` function with a callback, so the whole substrate has to exist.

The BEAM makes the executor cheap: the process running the call is the task, a wait
is a selective `receive`, and readiness arrives as a message from a producer.
`wasm_component_link` binds each async canon built-in to `builtin/2` here, and
`wasm_component:call_async/4` drives an `[async-lift]` export: it calls the core
function, decodes the status, and on WAIT waits on the named waitable-set and re-enters
the guest through its callback until it returns EXIT.

The runtime separates three concerns (like wasmtime): a **pending operation** (a
blocked read records its destination), the **data state** a producer message ingests
into (a future's value, a stream's buffered bytes, a close - retained regardless of
whether a read is pending yet), and **event delivery** (an operation is deliverable
only when it has a pending read AND its data can satisfy it, at which point the copy
into guest memory happens and exactly one event is produced). A WAIT never manufactures
a completion; it delivers only from ingested state.

All per-task state lives in the process dictionary, one live task per process (matching
the host-resource contract in `wasm_component`). i32 sentinels are signed: BLOCKED is
`-1`, since the operand stack holds signed Erlang integers (see
[[i32-host-results-are-signed]]).
""".

-export([builtin/2, begin_task/2, end_task/0, take_return/0, task_ref/0, waits/0,
         new_future_readable/2, new_stream_readable/2,
         new_future_channel/1, new_stream_channel/1,
         register_producer/2, deliver_before/2, wait_on_set/1, take_produced/1]).

%% The callee (export/callback) status low nibble: exited (result ready), yielded, or
%% waiting on the waitable-set packed in the high bits (`code | (set << 4)`).
-define(EXIT, 0).
-define(YIELD, 1).
-define(WAIT, 2).

%% CopyResult (low 4 bits of a read/write return); a stream packs the element count in
%% the high bits (`result | (progress << 4)`). BLOCKED is a distinguished i32, held
%% signed (`-1`) because the operand stack is signed.
-define(COMPLETED, 0).
-define(DROPPED, 1).
-define(BLOCKED, -1).

%% EventCode delivered through the callback (param 0).
-define(EV_NONE, 0).
-define(EV_STREAM_READ, 2).
-define(EV_FUTURE_READ, 4).

%% How long `wait_on_set` blocks for a completion before giving up (a lost-wakeup
%% guard, not a normal path), and how many queued messages a poll drains at most.
-define(WAIT_BUDGET_MS, 5000).
-define(POLL_DRAIN, 1024).

-define(TASK_RETURN, {?MODULE, task_return}).
-define(TASK_INST, {?MODULE, task_instance}).
-define(TASK_REF, {?MODULE, task_ref}).
-define(WAIT_HOOK, {?MODULE, wait_hook}).
-define(WAITS, {?MODULE, waits}).
-define(PRODUCERS, {?MODULE, producers}).
-define(CTX(Slot), {?MODULE, context, Slot}).
-define(WAITABLE(H), {?MODULE, waitable, H}).
-define(WSET(Set), {?MODULE, wset, Set}).
-define(WSET_OF(H), {?MODULE, wset_of, H}).
-define(WRITER(W), {?MODULE, writer, W}).
-define(NEXT, {?MODULE, next_handle}).

%%% --------------------------------------------------------------- task frame ---

-doc """
Start a task frame for the current process. `Inst` is the instance that owns the guest
memory the built-ins read and write (the lift core's, which `Ctx` does not expose when
that core imports its memory). `Opts` may carry `wait_hook => Pid`, notified each time
the task enters `wait_on_set` (so a test can release a producer only after the owner is
provably waiting). Mints a fresh task reference so a producer that outlives its call
cannot bleed messages into the next.
""".
-spec begin_task(wasm:instance(), map()) -> ok.
begin_task(Inst, Opts) ->
    clear_frame(),
    put(?TASK_INST, Inst),
    put(?TASK_REF, make_ref()),
    put(?WAITS, 0),
    put(?PRODUCERS, []),
    case maps:get(wait_hook, Opts, undefined) of
        undefined -> ok;
        Pid       -> put(?WAIT_HOOK, Pid)
    end,
    ok.

-doc "Tear the task frame down: stop producers, clear state, flush stale messages.".
-spec end_task() -> ok.
end_task() ->
    stop_producers(),
    Ref = get(?TASK_REF),
    clear_frame(),
    _ = erase(?TASK_INST),
    flush_stale(Ref),
    ok.

%% ?WAITS survives end_task (a test reads it right after the call); the next
%% begin_task resets it. Everything else per-task is a frame key.
clear_frame() ->
    _ = erase(?TASK_RETURN),
    _ = [erase(K) || K <- get_keys(), is_frame_key(K)],
    ok.

is_frame_key(?CTX(_))      -> true;
is_frame_key(?WAITABLE(_)) -> true;
is_frame_key(?WSET(_))     -> true;
is_frame_key(?WSET_OF(_))  -> true;
is_frame_key(?WRITER(_))   -> true;
is_frame_key(?TASK_REF)    -> true;
is_frame_key(?WAIT_HOOK)   -> true;
is_frame_key(?PRODUCERS)   -> true;
is_frame_key(_)            -> false.

-doc "The value the task handed back through `task.return`, or `undefined`.".
-spec take_return() -> {ok, term()} | undefined.
take_return() ->
    case erase(?TASK_RETURN) of
        undefined -> undefined;
        Value     -> {ok, Value}
    end.

-doc "The current task's reference (producers tag their messages with it).".
-spec task_ref() -> reference() | undefined.
task_ref() -> get(?TASK_REF).

-doc "How many times the task blocked in `wait_on_set` (reset per task).".
-spec waits() -> non_neg_integer().
waits() -> case get(?WAITS) of undefined -> 0; N -> N end.

%%% ---------------------------------------------------------- host-created ends ---

-doc """
Create the readable end of a future already holding `Value` (EAGER): the guest's
`future.read` completes at once, no wait. Used by `call_async` for a `future<T>`
parameter whose value is known up front.
""".
-spec new_future_readable(wasm_canon:desc(), term()) -> non_neg_integer().
new_future_readable(Desc, Value) ->
    H = next_handle(),
    put(?WAITABLE(H), {future, Desc, ready, Value}),
    H.

-doc "Create the readable end of an EAGER `stream<u8>` already holding `Elements`,closed.".
-spec new_stream_readable(wasm_canon:desc(), binary()) -> non_neg_integer().
new_stream_readable(Desc, Elements) ->
    H = next_handle(),
    put(?WAITABLE(H), {stream, Desc, Elements, closed}),
    H.

-doc """
Create the readable end of a CHANNEL future: no value yet, so `future.read` blocks
until a producer ingests `{value, V}` (via a message) and the executor delivers it.
""".
-spec new_future_channel(wasm_canon:desc()) -> non_neg_integer().
new_future_channel(Desc) ->
    H = next_handle(),
    put(?WAITABLE(H), {cfuture, Desc, none, idle}),
    H.

-doc """
Create the readable end of a CHANNEL `stream<u8>`: empty and open, so `stream.read`
blocks until a producer ingests `{data, Bin}` / `close` and the executor delivers.
""".
-spec new_stream_channel(wasm_canon:desc()) -> non_neg_integer().
new_stream_channel(Desc) ->
    H = next_handle(),
    put(?WAITABLE(H), {cstream, Desc, <<>>, open, idle}),
    H.

-doc """
Spawn and monitor a producer for the channel end `Handle`. `PFun` is called in the new
process with `#{owner, task_ref, handle}` and sends `{async_ready, TaskRef, Handle,
Info}` (`Info` = `{value,V} | {data,Bin} | close`) to the owner when it chooses.
""".
-spec register_producer(non_neg_integer(), fun((map()) -> any())) -> ok.
register_producer(Handle, PFun) ->
    Owner = self(),
    Ref = task_ref(),
    Ctx = #{owner => Owner, task_ref => Ref, handle => Handle},
    {Pid, Mon} = spawn_monitor(fun() -> PFun(Ctx) end),
    put(?PRODUCERS, [{Pid, Mon, Handle} | producers()]),
    ok.

-doc """
Queue a completion for `Handle` in the owner's own mailbox before the guest runs, so a
later `wait_on_set` finds it without blocking (the before-WAIT / retained-readiness
case). `Info` is as for `register_producer/2`.
""".
-spec deliver_before(non_neg_integer(), term()) -> ok.
deliver_before(Handle, Info) ->
    self() ! {async_ready, task_ref(), Handle, Info},
    ok.

%%% ----------------------------------------------------------------- built-ins ---

-doc """
The core function a given async canon built-in binds to. Each returns
`fun(Ctx, Flats) -> {ok, Results} | {trap, Reason}` (the resource-intrinsic contract).
""".
-spec builtin(atom(), map()) -> function().
%% task.return: lift the result from the caller's memory and stash it for call_async.
builtin(task_return, #{result := Result}) ->
    fun(_Ctx, Flats) ->
        put(?TASK_RETURN, task_return_value(Result, Flats)),
        {ok, []}
    end;
%% context.get/set: a task-local i32 slot wit-bindgen uses for its task pointer.
builtin(context_get, #{slot := Slot}) ->
    fun(_Ctx, _Flats) -> {ok, [get_context(Slot)]} end;
builtin(context_set, #{slot := Slot}) ->
    fun(_Ctx, [Value | _]) -> put(?CTX(Slot), Value), {ok, []} end;
%% waitable-set: a set of waitables the guest waits on. Membership is guest-controlled.
builtin(waitable_set_new, _Meta) ->
    fun(_Ctx, _Flats) -> H = next_handle(), put(?WSET(H), []), {ok, [H]} end;
builtin(waitable_join, _Meta) ->
    fun(_Ctx, [W, Set | _]) -> join(W, Set), {ok, []} end;
builtin(waitable_set_drop, _Meta) ->
    fun(_Ctx, [Set | _]) ->
        case get(?WSET(Set)) of
            [_ | _] -> {trap, waitable_set_not_empty};
            _       -> erase(?WSET(Set)), {ok, []}
        end
    end;
%% waitable-set.poll(set, ptr): non-blocking. Deliver one ready event (writing its two
%% payload words at ptr, returning the event code) else NONE.
builtin(waitable_set_poll, _Meta) ->
    fun(_Ctx, [Set, Ptr | _]) -> {ok, [wait_write(Set, Ptr, nonblocking)]} end;
%% waitable-set.wait(set, ptr): the guest built-in (stackful driver); blocks until a
%% member is deliverable, writes its payload at ptr, returns the event code.
builtin(waitable_set_wait, _Meta) ->
    fun(_Ctx, [Set, Ptr | _]) -> {ok, [wait_write(Set, Ptr, blocking)]} end;
%% stream/future `new` mints a packed pair: reader in the LOW 32 bits, writer in the
%% high (per the ABI). The write direction is a later milestone; the ends record empty.
builtin(stream_new, _Meta) ->
    fun(_Ctx, _Flats) -> {ok, [new_pair(cstream)]} end;
builtin(future_new, _Meta) ->
    fun(_Ctx, _Flats) -> {ok, [new_pair(cfuture)]} end;
%% future.read(handle, ptr): a ready value is copied at once (COMPLETED); a channel
%% future with no value yet blocks (BLOCKED); a spent one is DROPPED.
builtin(future_read, _Meta) ->
    fun(_Ctx, [H, Ptr | _]) -> {ok, [future_read(H, Ptr)]} end;
%% stream.read(handle, ptr, count): serve buffered bytes at once, else block on a
%% channel that is still open, else DROPPED when drained and closed.
builtin(stream_read, _Meta) ->
    fun(_Ctx, [H, Ptr, Count | _]) -> {ok, [stream_read(H, Ptr, Count)]} end;
%% future.write(writer, ptr): a guest producer writes the one value; the host buffers
%% it on the paired reader channel (so a read completes) and reports COMPLETED.
builtin(future_write, _Meta) ->
    fun(_Ctx, [W, Ptr | _]) -> {ok, [future_write(W, Ptr)]} end;
%% stream.write(writer, ptr, count): buffer `count` bytes on the reader channel,
%% reporting COMPLETED with the count written.
builtin(stream_write, _Meta) ->
    fun(_Ctx, [W, Ptr, Count | _]) -> {ok, [stream_write(W, Ptr, Count)]} end;
%% drop-readable: validate then erase the readable end. drop-writable: close the paired
%% reader channel (so its consumer sees end-of-stream) and forget the writer.
builtin(Which, _Meta) when Which =:= future_drop_readable;
                           Which =:= stream_drop_readable ->
    fun(_Ctx, [H | _]) -> drop_waitable(Which, H) end;
builtin(Which, _Meta) when Which =:= future_drop_writable;
                           Which =:= stream_drop_writable ->
    fun(_Ctx, [W | _]) -> drop_writer(W) end;
builtin(Which, _Meta) when Which =:= stream_cancel_read; Which =:= stream_cancel_write;
                           Which =:= future_cancel_read; Which =:= future_cancel_write ->
    %% Cancellation is a later milestone.
    fun(_Ctx, _Flats) -> {ok, [(0 bsl 4) bor ?COMPLETED]} end;
builtin(error_context_new, _Meta) ->
    fun(_Ctx, _Flats) -> {ok, [next_handle()]} end;
%% Everything else (task/subtask lifecycle, yield, backpressure, error-context
%% debug/drop) has no return value and no effect the read path depends on.
builtin(_Which, _Meta) ->
    fun(_Ctx, _Flats) -> {ok, []} end.

%% The value the guest returned through `task.return`. A resolved descriptor is lifted
%% normally; a result that is still an unresolved canon type index (a `future<T>`/
%% `stream<T>` or resource the guest returns) is an i32 handle, captured directly - the
%% caller reads the produced value from that handle. A `none` result is `undefined`.
task_return_value(none, _Flats) ->
    undefined;
task_return_value({type, _Idx}, [Handle | _]) ->
    Handle band 16#FFFFFFFF;
task_return_value({type, _Idx}, []) ->
    undefined;
task_return_value(Result, Flats) ->
    {Lifted, _} = wasm_canon:lift_params(task_instance(), [Result], Flats),
    hd(Lifted).

%%% -------------------------------------------------------- read (guest) side ---

future_read(H, Ptr) ->
    case get(?WAITABLE(H)) of
        {future, Desc, ready, Value} ->
            ok = wasm_canon:store_value(task_instance(), Desc, Ptr, Value),
            put(?WAITABLE(H), {future, Desc, taken, Value}),
            ?COMPLETED;
        {cfuture, Desc, {value, Value}, idle} ->
            ok = wasm_canon:store_value(task_instance(), Desc, Ptr, Value),
            put(?WAITABLE(H), {cfuture, Desc, taken, idle}),
            ?COMPLETED;
        {cfuture, Desc, Data, idle} ->
            put(?WAITABLE(H), {cfuture, Desc, Data, {reading, Ptr}}),
            ?BLOCKED;
        _ ->
            ?DROPPED
    end.

stream_read(H, Ptr, Count) ->
    case get(?WAITABLE(H)) of
        {stream, Desc, Bin, State} ->
            {Copied, Rest} = take_bytes(Bin, Count),
            ok = write_bytes(Ptr, Copied),
            put(?WAITABLE(H), {stream, Desc, Rest, State}),
            stream_status(byte_size(Copied), Rest, State);
        {cstream, Desc, Buffer, Open, idle} when Buffer =/= <<>> ->
            {Copied, Rest} = take_bytes(Buffer, Count),
            ok = write_bytes(Ptr, Copied),
            put(?WAITABLE(H), {cstream, Desc, Rest, Open, idle}),
            (byte_size(Copied) bsl 4) bor ?COMPLETED;
        {cstream, Desc, <<>>, open, idle} ->
            put(?WAITABLE(H), {cstream, Desc, <<>>, open, {reading, Ptr, Count}}),
            ?BLOCKED;
        {cstream, _Desc, <<>>, closed, idle} ->
            (0 bsl 4) bor ?DROPPED;
        _ ->
            (0 bsl 4) bor ?DROPPED
    end.

stream_status(0, <<>>, closed) -> (0 bsl 4) bor ?DROPPED;
stream_status(Copied, _Rest, _State) -> (Copied bsl 4) bor ?COMPLETED.

%% Drop the readable/writable end of a future/stream: reject an unknown handle, the
%% wrong end kind, or a drop while a read is still outstanding.
drop_waitable(Which, H) ->
    case get(?WAITABLE(H)) of
        undefined ->
            {trap, unknown_waitable};
        Record ->
            case drop_ok(Which, Record) of
                reading   -> {trap, drop_while_reading};
                wrong_end -> {trap, wrong_end};
                ok        -> forget_waitable(H), {ok, []}
            end
    end.

%% A readable-drop accepts a future/stream readable end; an outstanding `{reading,...}`
%% blocks it (the wrong-end kind is a trap).
drop_ok(future_drop_readable, {future, _, _, _})       -> ok;
drop_ok(future_drop_readable, {cfuture, _, _, {reading, _}}) -> reading;
drop_ok(future_drop_readable, {cfuture, _, _, _})      -> ok;
drop_ok(stream_drop_readable, {stream, _, _, _})       -> ok;
drop_ok(stream_drop_readable, {cstream, _, _, _, {reading, _, _}}) -> reading;
drop_ok(stream_drop_readable, {cstream, _, _, _, _})   -> ok;
drop_ok(_, _)                                          -> wrong_end.

forget_waitable(H) ->
    join(H, 0),
    _ = erase(?WSET_OF(H)),
    _ = erase(?WAITABLE(H)),
    ok.

%% Dropping a writer closes its paired reader channel (so the consumer sees the end)
%% and forgets the writer. An unknown writer traps.
drop_writer(W) ->
    case get(?WRITER(W)) of
        undefined ->
            {trap, unknown_waitable};
        R ->
            case get(?WAITABLE(R)) of
                {cstream, D, Buf, _Open, RS} -> put(?WAITABLE(R), {cstream, D, Buf, closed, RS});
                _                            -> ok
            end,
            _ = erase(?WRITER(W)),
            {ok, []}
    end.

%%% -------------------------------------------------- write (producer) side ---

%% A guest producer writes the one future value at `Ptr`; buffer it on the paired
%% reader channel so the host's later read sees it. The payload is `u8`.
future_write(W, Ptr) ->
    R = get(?WRITER(W)),
    case get(?WAITABLE(R)) of
        {cfuture, D, _Data, RS} ->
            {ok, <<V>>} = wasm:read_memory(task_instance(), Ptr, 1),
            put(?WAITABLE(R), {cfuture, D, {value, V}, RS}),
            ?COMPLETED;
        _ ->
            ?DROPPED
    end.

%% A guest producer writes `Count` bytes at `Ptr`; append them to the reader channel's
%% buffer, reporting COMPLETED with the count written.
stream_write(W, Ptr, Count) ->
    case get(?WRITER(W)) of
        undefined -> (0 bsl 4) bor ?DROPPED;
        R ->
            case get(?WAITABLE(R)) of
                {cstream, D, Buf, Open, RS} ->
                    {ok, Bytes} = wasm:read_memory(task_instance(), Ptr, Count),
                    put(?WAITABLE(R), {cstream, D, <<Buf/binary, Bytes/binary>>, Open, RS}),
                    (Count bsl 4) bor ?COMPLETED;
                _ ->
                    (0 bsl 4) bor ?DROPPED
            end
    end.

-doc """
The value a guest producer wrote to a future/stream it returned: the future's value,
or all the bytes a `stream<u8>` accumulated. `call_async` reads this from the returned
handle before the task frame is torn down.
""".
-spec take_produced(non_neg_integer()) -> {ok, term()} | error.
take_produced(H) ->
    case get(?WAITABLE(H)) of
        {cfuture, _D, {value, V}, _} -> {ok, V};
        {cstream, _D, Buffer, _, _}  -> {ok, Buffer};
        _                            -> error
    end.

%%% ------------------------------------------------------- wait (executor) side ---

-doc """
Block the task until a member of waitable-set `Set` has a deliverable completion, then
perform the copy into guest memory and return `{event, EventCode, Waitable, ReturnCode}`
for the executor to hand to the callback. `{error, Reason}` on a producer failure or a
lost-wakeup timeout. Called by `wasm_component:call_async/4` on a WAIT status.
""".
-spec wait_on_set(non_neg_integer()) ->
          {event, non_neg_integer(), non_neg_integer(), integer()} | {error, term()}.
wait_on_set(Set) ->
    bump_waits(),
    fire_wait_hook(Set),
    case wait_core(Set, blocking) of
        {?EV_NONE, _, _}   -> {error, async_wait_timeout};
        {EC, E1, E2}       -> {event, EC, E1, E2};
        {error, _} = Error -> Error
    end.

%% A guest waitable-set.wait/poll: run the core, write the two payload words at Ptr,
%% return the event code (0 = NONE). An error surfaces as a trap to the caller path.
wait_write(Set, Ptr, Mode) ->
    case wait_core(Set, Mode) of
        {EC, E1, E2} ->
            ok = wasm:write_memory(task_instance(), Ptr, <<E1:32/little, E2:32/little>>),
            EC;
        {error, _} ->
            ?EV_NONE
    end.

%% Ingest what is already queued, deliver one event if a set member is ready; otherwise
%% block (with an absolute deadline) for the next producer message, or report NONE when
%% non-blocking.
wait_core(Set, Mode) ->
    Ref = task_ref(),
    ingest_available(Ref, ?POLL_DRAIN),
    case deliver_first(Set) of
        {event, EC, E1, E2} ->
            {EC, E1, E2};
        none when Mode =:= nonblocking ->
            {?EV_NONE, 0, 0};
        none ->
            block_wait(Set, Ref, erlang:monotonic_time(millisecond) + ?WAIT_BUDGET_MS)
    end.

block_wait(Set, Ref, Deadline) ->
    Timeout = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {async_ready, Ref, H, Info} ->
            ingest(H, Info),
            case deliver_first(Set) of
                {event, EC, E1, E2} -> {EC, E1, E2};
                none                -> block_wait(Set, Ref, Deadline)
            end;
        {'DOWN', _Mon, process, Pid, Reason} ->
            on_producer_down(Pid, Reason, Set, Ref, Deadline)
    after Timeout ->
        {error, async_wait_timeout}
    end.

%% A monitored producer died. Its data messages (ordered before the DOWN) are already
%% ingested; if the set is now deliverable, deliver it, else the producer failed to
%% supply what a pending read needs.
on_producer_down(Pid, Reason, Set, Ref, Deadline) ->
    case is_producer(Pid) of
        false ->
            block_wait(Set, Ref, Deadline);
        true ->
            forget_producer(Pid),
            ingest_available(Ref, ?POLL_DRAIN),
            case deliver_first(Set) of
                {event, EC, E1, E2} -> {EC, E1, E2};
                none                -> {error, {producer_failed, Reason}}
            end
    end.

%% Drain up to N already-queued completion messages into data state (no blocking).
ingest_available(_Ref, 0) -> ok;
ingest_available(Ref, N) ->
    receive
        {async_ready, Ref, H, Info} -> ingest(H, Info), ingest_available(Ref, N - 1)
    after 0 ->
        ok
    end.

%% Apply a producer message to a waitable's data state. No delivery here.
ingest(H, {value, V}) ->
    case get(?WAITABLE(H)) of
        {cfuture, D, none, RS}  -> put(?WAITABLE(H), {cfuture, D, {value, V}, RS});
        _                       -> ok
    end;
ingest(H, {data, Bin}) ->
    case get(?WAITABLE(H)) of
        {cstream, D, Buf, Open, RS} ->
            put(?WAITABLE(H), {cstream, D, <<Buf/binary, Bin/binary>>, Open, RS});
        _ ->
            ok
    end;
ingest(H, close) ->
    case get(?WAITABLE(H)) of
        {cstream, D, Buf, _Open, RS} -> put(?WAITABLE(H), {cstream, D, Buf, closed, RS});
        _                            -> ok
    end.

%% Find the first member of `Set` with a pending read its state can satisfy, perform
%% the copy into guest memory, clear the read, and return one event.
deliver_first(Set) ->
    deliver_scan(members(Set)).

deliver_scan([]) -> none;
deliver_scan([H | Rest]) ->
    case try_deliver(H) of
        none  -> deliver_scan(Rest);
        Event -> Event
    end.

try_deliver(H) ->
    case get(?WAITABLE(H)) of
        {cfuture, D, {value, V}, {reading, Ptr}} ->
            ok = wasm_canon:store_value(task_instance(), D, Ptr, V),
            put(?WAITABLE(H), {cfuture, D, taken, idle}),
            {event, ?EV_FUTURE_READ, H, ?COMPLETED};
        {cstream, D, Buffer, Open, {reading, Ptr, Count}} when Buffer =/= <<>> ->
            {Copied, Rest} = take_bytes(Buffer, Count),
            ok = write_bytes(Ptr, Copied),
            put(?WAITABLE(H), {cstream, D, Rest, Open, idle}),
            {event, ?EV_STREAM_READ, H, (byte_size(Copied) bsl 4) bor ?COMPLETED};
        {cstream, D, <<>>, closed, {reading, _Ptr, _Count}} ->
            put(?WAITABLE(H), {cstream, D, <<>>, closed, idle}),
            {event, ?EV_STREAM_READ, H, (0 bsl 4) bor ?DROPPED};
        _ ->
            none
    end.

fire_wait_hook(Set) ->
    case get(?WAIT_HOOK) of
        undefined -> ok;
        Pid       -> Pid ! {async_wait, task_ref(), Set}, ok
    end.

bump_waits() -> put(?WAITS, waits() + 1), ok.

%%% --------------------------------------------------------- waitable-set state ---

%% Transfer `W` into `Set`: remove it from its previous set first (a waitable is in at
%% most one set); `Set == 0` just removes it.
join(W, Set) ->
    case get(?WSET_OF(W)) of
        undefined -> ok;
        Old       -> put(?WSET(Old), lists:delete(W, members(Old)))
    end,
    case Set of
        0 -> erase(?WSET_OF(W));
        _ -> put(?WSET(Set), lists:usort([W | members(Set)])),
             put(?WSET_OF(W), Set)
    end,
    ok.

members(Set) -> case get(?WSET(Set)) of undefined -> []; L -> L end.

%%% -------------------------------------------------------------- producers ---

producers() -> case get(?PRODUCERS) of undefined -> []; L -> L end.

is_producer(Pid) -> lists:keymember(Pid, 1, producers()).

forget_producer(Pid) ->
    put(?PRODUCERS, lists:keydelete(Pid, 1, producers())),
    ok.

stop_producers() ->
    lists:foreach(fun({Pid, Mon, _H}) ->
                      erlang:demonitor(Mon, [flush]),
                      exit(Pid, kill)
                  end, producers()),
    ok.

%% Drop any completion / DOWN messages left over for this task ref after teardown.
flush_stale(Ref) ->
    receive
        {async_ready, Ref, _, _}     -> flush_stale(Ref);
        {'DOWN', _, process, _, _}   -> flush_stale(Ref)
    after 0 ->
        ok
    end.

%%% -------------------------------------------------------------------- helpers ---

task_instance() -> get(?TASK_INST).

%% A fresh (readable, writable) pair, reader in the LOW 32 bits, writer in the high.
%% The writer records which reader channel it feeds (a guest producer writes to the
%% writer and returns the reader; the host reads the reader). Payloads are `u8`: a
%% guest-created future/stream via `new()` does not carry its element type here (that
%% needs canon type-index resolution, a later milestone).
new_pair(cfuture) ->
    R = next_handle(), W = next_handle(),
    put(?WAITABLE(R), {cfuture, u8, none, idle}),
    put(?WRITER(W), R),
    (W bsl 32) bor R;
new_pair(cstream) ->
    R = next_handle(), W = next_handle(),
    put(?WAITABLE(R), {cstream, u8, <<>>, open, idle}),
    put(?WRITER(W), R),
    (W bsl 32) bor R.

take_bytes(Bin, Count) ->
    N = min(Count, byte_size(Bin)),
    <<Take:N/binary, Rest/binary>> = Bin,
    {Take, Rest}.

write_bytes(_Ptr, <<>>) -> ok;
write_bytes(Ptr, Bin)   -> wasm:write_memory(task_instance(), Ptr, Bin).

get_context(Slot) ->
    case get(?CTX(Slot)) of undefined -> 0; Value -> Value end.

next_handle() ->
    N = case get(?NEXT) of undefined -> 1; V -> V end,
    put(?NEXT, N + 1),
    N.
