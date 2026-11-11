-module(wasm_async).
-moduledoc """
The async Canonical ABI runtime (Component Model async, not a WASI
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
`-1`, since the operand stack holds signed Erlang integers.
""".

-export([builtin/2, begin_task/2, end_task/0, take_return/0, task_ref/0, waits/0,
         new_future_readable/2, new_stream_readable/2,
         new_future_channel/1, new_stream_channel/1,
         register_producer/2, deliver_before/2, wait_on_set/1, take_produced/1,
         async_lower/2, async_lower/3, backpressure/1]).

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
-define(CANCELLED, 2).
-define(BLOCKED, -1).

%% Caller-side subtask status (low 4 bits of an async-lowered call's return, packed
%% `state | (subtask << 4)`): the callee has started (will complete later) or already
%% returned.
-define(SUBTASK_STARTED, 1).
-define(SUBTASK_RETURNED, 2).
-define(SUBTASK_CANCELLED, 4).                 % CANCELLED_BEFORE_RETURNED

%% EventCode delivered through the callback (param 0).
-define(EV_NONE, 0).
-define(EV_SUBTASK, 1).
-define(EV_STREAM_READ, 2).
-define(EV_STREAM_WRITE, 3).
-define(EV_FUTURE_READ, 4).
-define(EV_FUTURE_WRITE, 5).

%% How many queued messages a poll drains at most.
-define(POLL_DRAIN, 1024).

%% How many elements a stream holds between a writer and a reader that has not
%% taken them; a write past it waits for room. A copy moves at most `MAX_COPY'
%% elements, the specification's limit on a copy's progress.
-define(STREAM_BUFFER, 1024).
-define(MAX_COPY, 16#FFFFFFF).

%% `backpressure.inc' traps at 2^16, as the specification has it.
-define(BACKPRESSURE_MAX, 65536).

-define(TASK_RETURN, {?MODULE, task_return}).
-define(TASK_INST, {?MODULE, task_instance}).
-define(TASK_REF, {?MODULE, task_ref}).
-define(WAIT_HOOK, {?MODULE, wait_hook}).
-define(WAITS, {?MODULE, waits}).
-define(OUTER, {?MODULE, outer}).
%% The tag on a producer's monitor: its `DOWN' arrives as `{?DOWN(Ref), ...}'.
-define(DOWN(Ref), {?MODULE, down, Ref}).
-define(PRODUCERS, {?MODULE, producers}).
-define(CTX(Slot), {?MODULE, context, Slot}).
-define(WAITABLE(H), {?MODULE, waitable, H}).
-define(WSET(Set), {?MODULE, wset, Set}).
-define(WSET_OF(H), {?MODULE, wset_of, H}).
-define(ERRCTX(H), {?MODULE, error_context, H}).
-define(BACKPRESSURE(Inst), {?MODULE, backpressure, Inst}).
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
    %% A task started inside another, from a host function the outer task
    %% called, sets the outer frame aside rather than clearing it: clearing
    %% it lost the outer producers, and nothing stopped them afterwards.
    save_outer(),
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
    restore_outer(),
    ok.

%% The enclosing task's frame, on a stack in the process dictionary.
save_outer() ->
    case get(?TASK_REF) of
        undefined -> ok;
        _ ->
            Frame = [{K, V} || {K, V} <- get(),
                               is_frame_key(K) orelse K =:= ?TASK_INST
                                   orelse K =:= ?TASK_RETURN],
            put(?OUTER, [Frame | outer()])
    end.

restore_outer() ->
    case outer() of
        [] -> ok;
        [Frame | Rest] ->
            [put(K, V) || {K, V} <- Frame],
            case Rest of
                [] -> erase(?OUTER);
                _ -> put(?OUTER, Rest)
            end,
            ok
    end.

outer() ->
    case get(?OUTER) of
        undefined -> [];
        L -> L
    end.

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
is_frame_key(?ERRCTX(_))   -> true;
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
    new_reader(future, Desc, [Value], closed).

-doc """
Create the readable end of an EAGER `stream<T>` already holding `Elements`, its writer
already dropped. A `stream<u8>` takes a binary, any other element type a list.
""".
-spec new_stream_readable(wasm_canon:desc(), binary() | [term()]) -> non_neg_integer().
new_stream_readable(Desc, Elements) ->
    new_reader(stream, Desc, Elements, closed).

-doc """
Create the readable end of a CHANNEL future: no value yet, so `future.read` blocks
until a producer ingests `{value, V}` (via a message) and the executor delivers it.
""".
-spec new_future_channel(wasm_canon:desc()) -> non_neg_integer().
new_future_channel(Desc) ->
    new_reader(future, Desc, [], open).

-doc """
Create the readable end of a CHANNEL `stream<T>`: empty and open, so `stream.read`
blocks until a producer ingests `{data, Elements}` / `close` and the executor
delivers.
""".
-spec new_stream_channel(wasm_canon:desc()) -> non_neg_integer().
new_stream_channel(Desc) ->
    new_reader(stream, Desc, empty(Desc), open).

new_reader(Kind, Desc, Buf, Writer) ->
    H = next_handle(),
    put(?WAITABLE(H), #{'end' => read, kind => Kind, elem => Desc, buf => Buf,
                        writer => Writer, state => idle, host => false,
                        peer => undefined}),
    H.

-doc """
Spawn and monitor a producer for the channel end `Handle`. `PFun` is called in the new
process with `#{owner, task_ref, handle}` and sends `{async_ready, TaskRef, Handle,
Info}` (`Info` = `{value,V} | {data,Elements} | close`) to the owner when it chooses.
""".
-spec register_producer(non_neg_integer(), fun((map()) -> any())) -> ok.
register_producer(Handle, PFun) ->
    Owner = self(),
    Ref = task_ref(),
    Ctx = #{owner => Owner, task_ref => Ref, handle => Handle},
    %% Bound to the owner: `end_task/0' stops producers, but an owner that is
    %% killed never runs it. The monitor is tagged with the task, so a
    %% producer's `DOWN' can be told from every other in the caller's mailbox:
    %% this runs in the embedder's own process, whose monitors are not ours.
    {Pid, Mon} = spawn_opt(fun() ->
                                   ok = wasm_lifetime:bind(Owner),
                                   PFun(Ctx)
                           end, [{monitor, [{tag, ?DOWN(Ref)}]}]),
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

-doc """
How far the guest instance `Inst` has raised backpressure (`backpressure.inc` less
`backpressure.dec`). While it is above zero the instance takes no new async call.
""".
-spec backpressure(wasm:instance()) -> non_neg_integer().
backpressure(Inst) ->
    case get(?BACKPRESSURE(Inst)) of undefined -> 0; N -> N end.

%%% ----------------------------------------------------------------- built-ins ---

-doc """
The core function a given async canon built-in binds to. Each returns
`fun(Ctx, Flats) -> {ok, Results} | {trap, Reason}` (the resource-intrinsic contract).
`Meta` carries what the built-in's encoding declares: `elem`, the element type of a
stream or future built-in, and `async`, whether a copy may return BLOCKED rather than
wait in place.
""".
-spec builtin(atom(), map()) -> function().
%% task.return: lift the result from the caller's memory and stash it for call_async.
builtin(task_return, #{result := Result}) ->
    fun(_Ctx, Flats) ->
        put(?TASK_RETURN, task_return_value(Result, Flats)),
        {ok, []}
    end;
%% The runtime never asks a task to cancel, and the specification traps a
%% `task.cancel' that answers no request.
builtin(task_cancel, _Meta) ->
    fun(_Ctx, _Flats) -> {trap, task_cancel_not_requested} end;
%% context.get/set: a task-local i32 slot wit-bindgen uses for its task pointer.
builtin(context_get, #{slot := Slot}) ->
    fun(_Ctx, _Flats) -> {ok, [get_context(Slot)]} end;
builtin(context_set, #{slot := Slot}) ->
    fun(_Ctx, [Value | _]) -> put(?CTX(Slot), Value), {ok, []} end;
%% thread.yield: let producers run, take what they sent, and report that the
%% task is not cancelled (0).
builtin(yield, _Meta) ->
    fun(_Ctx, _Flats) ->
        erlang:yield(),
        ingest_available(task_ref(), ?POLL_DRAIN),
        {ok, [0]}
    end;
builtin(backpressure_inc, _Meta) ->
    fun(_Ctx, _Flats) ->
        Key = ?BACKPRESSURE(task_instance()),
        case backpressure(task_instance()) + 1 of
            ?BACKPRESSURE_MAX -> {trap, backpressure_overflow};
            N -> put(Key, N), {ok, []}
        end
    end;
builtin(backpressure_dec, _Meta) ->
    fun(_Ctx, _Flats) ->
        case backpressure(task_instance()) of
            0 -> {trap, backpressure_underflow};
            1 -> erase(?BACKPRESSURE(task_instance())), {ok, []};
            N -> put(?BACKPRESSURE(task_instance()), N - 1), {ok, []}
        end
    end;
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
    fun(_Ctx, [Set, Ptr | _]) -> wait_write(Set, Ptr, nonblocking) end;
%% waitable-set.wait(set, ptr): blocks until a member is deliverable, writes its
%% payload at ptr, returns the event code. A producer that fails, or a wait nothing
%% can ever end, traps.
builtin(waitable_set_wait, _Meta) ->
    fun(_Ctx, [Set, Ptr | _]) -> wait_write(Set, Ptr, blocking) end;
%% stream/future `new` mints a packed pair: reader in the LOW 32 bits, writer in the
%% high (per the ABI).
builtin(stream_new, Meta) ->
    fun(_Ctx, _Flats) -> {ok, [new_pair(stream, elem(Meta))]} end;
builtin(future_new, Meta) ->
    fun(_Ctx, _Flats) -> {ok, [new_pair(future, elem(Meta))]} end;
builtin(future_read, Meta) ->
    fun(_Ctx, [H, Ptr | _]) -> copy(read, future, Meta, H, Ptr, 1) end;
builtin(stream_read, Meta) ->
    fun(_Ctx, [H, Ptr, Count | _]) -> copy(read, stream, Meta, H, Ptr, Count) end;
builtin(future_write, Meta) ->
    fun(_Ctx, [W, Ptr | _]) -> copy(write, future, Meta, W, Ptr, 1) end;
builtin(stream_write, Meta) ->
    fun(_Ctx, [W, Ptr, Count | _]) -> copy(write, stream, Meta, W, Ptr, Count) end;
builtin(stream_cancel_read, _Meta) ->
    fun(_Ctx, [H | _]) -> cancel_copy(read, stream, H) end;
builtin(stream_cancel_write, _Meta) ->
    fun(_Ctx, [H | _]) -> cancel_copy(write, stream, H) end;
builtin(future_cancel_read, _Meta) ->
    fun(_Ctx, [H | _]) -> cancel_copy(read, future, H) end;
builtin(future_cancel_write, _Meta) ->
    fun(_Ctx, [H | _]) -> cancel_copy(write, future, H) end;
builtin(stream_drop_readable, _Meta) ->
    fun(_Ctx, [H | _]) -> drop_end(read, stream, H) end;
builtin(stream_drop_writable, _Meta) ->
    fun(_Ctx, [H | _]) -> drop_end(write, stream, H) end;
builtin(future_drop_readable, _Meta) ->
    fun(_Ctx, [H | _]) -> drop_end(read, future, H) end;
builtin(future_drop_writable, _Meta) ->
    fun(_Ctx, [H | _]) -> drop_end(write, future, H) end;
builtin(subtask_cancel, _Meta) ->
    fun(_Ctx, [H | _]) -> subtask_cancel(H) end;
builtin(subtask_drop, _Meta) ->
    fun(_Ctx, [H | _]) -> subtask_drop(H) end;
%% error-context.new(ptr, len): keep the guest's message under a fresh handle.
builtin(error_context_new, _Meta) ->
    fun(_Ctx, [Ptr, Len | _]) ->
        {[Msg], _} = wasm_canon:lift_params(task_instance(), [string], [Ptr, Len]),
        H = next_handle(),
        put(?ERRCTX(H), Msg),
        {ok, [H]}
    end;
%% error-context.debug-message(handle, ptr): the message, lowered as a string (through
%% the built-in's realloc) at ptr.
builtin(error_context_debug_message, _Meta) ->
    fun(_Ctx, [H, Ptr | _]) ->
        case get(?ERRCTX(H)) of
            undefined -> {trap, unknown_error_context};
            Msg ->
                ok = wasm_canon:store_value(task_instance(), string, Ptr, Msg),
                {ok, []}
        end
    end;
builtin(error_context_drop, _Meta) ->
    fun(_Ctx, [H | _]) ->
        case erase(?ERRCTX(H)) of
            undefined -> {trap, unknown_error_context};
            _ -> {ok, []}
        end
    end;
builtin(Which, _Meta) ->
    fun(_Ctx, _Flats) -> {trap, {unsupported_async_builtin, Which}} end.

elem(Meta) -> maps:get(elem, Meta, u8).

%% The value the guest returned through `task.return`. A resolved descriptor is lifted
%% normally; a result that is still an unresolved canon type index (a `future<T>`/
%% `stream<T>` or resource the guest returns) is an i32 handle, captured directly - the
%% caller reads the produced value from that handle, and from then on the host is its
%% reader. A `none` result is `undefined`.
task_return_value(none, _Flats) ->
    undefined;
task_return_value({type, _Idx}, [Handle | _]) ->
    H = Handle band 16#FFFFFFFF,
    hand_to_host(H),
    H;
task_return_value({type, _Idx}, []) ->
    undefined;
task_return_value(Result, Flats) ->
    {Lifted, _} = wasm_canon:lift_params(task_instance(), [Result], Flats),
    hd(Lifted).

%% The host reads a returned stream to its end, so a guest writing to it never
%% waits for room.
hand_to_host(H) ->
    case get(?WAITABLE(H)) of
        #{'end' := read} = R -> put(?WAITABLE(H), R#{host => true}), refill(H);
        _ -> ok
    end.

%%% ------------------------------------------------------------------ copies ---

%% `stream.read`/`write', `future.read`/`write': the end must be of the right kind
%% and idle (a second read of a future, or a read after the end, traps). A copy that
%% cannot complete now records itself and returns BLOCKED, or, for a built-in
%% declared without `async', waits in place for its own event. What producers
%% have sent but a wait has not yet taken in does not count: a copy sees the
%% state the last wait left.
copy(Dir, Kind, Meta, H, Ptr, Count) ->
    case get(?WAITABLE(H)) of
        #{'end' := Dir, kind := Kind, state := idle} = E ->
            case start_copy(Dir, Kind, H, E, Ptr, Count) of
                blocked when map_get(async, Meta) =:= false -> wait_own(H);
                blocked -> {ok, [?BLOCKED]};
                Payload -> {ok, [Payload]}
            end;
        #{'end' := Dir, kind := Kind} -> {trap, copy_not_idle};
        undefined -> {trap, unknown_waitable};
        _ -> {trap, wrong_end}
    end.

start_copy(read, Kind, H, #{buf := Buf, writer := Writer} = R, Ptr, Count) ->
    case is_empty(Buf) of
        false ->
            put(?WAITABLE(H), R#{state => {copying, Ptr, Count}}),
            {event, _, _, Payload} = try_deliver(H),
            Payload;
        true when Writer =:= closed ->
            put(?WAITABLE(H), R#{state => done}),
            result(Kind, ?DROPPED, 0);
        true ->
            put(?WAITABLE(H), R#{state => {copying, Ptr, Count}}),
            blocked
    end;
start_copy(write, Kind, W, #{reader := RH} = Wr, Ptr, Count) ->
    case get(?WAITABLE(RH)) of
        #{'end' := read} = R when Kind =:= future ->
            Value = load_elems(maps:get(elem, Wr), Ptr, 1, future),
            put(?WAITABLE(RH), R#{buf => [Value], writer => closed}),
            put(?WAITABLE(W), Wr#{state => done}),
            ?COMPLETED;
        #{'end' := read} = R ->
            case min(Count, room(R)) of
                0 when Count > 0 ->
                    put(?WAITABLE(W), Wr#{state => {copying, Ptr, Count}}),
                    blocked;
                N ->
                    append(RH, R, load_elems(maps:get(elem, Wr), Ptr, N, stream)),
                    result(stream, ?COMPLETED, N)
            end;
        _ ->
            put(?WAITABLE(W), Wr#{state => done}),
            result(Kind, ?DROPPED, 0)
    end.

%% How many more elements the reader's buffer takes: a host reader takes all.
room(#{host := true}) -> ?MAX_COPY;
room(#{buf := Buf}) -> max(0, ?STREAM_BUFFER - len(Buf)).

append(RH, R, Items) ->
    put(?WAITABLE(RH), R#{buf => cat(maps:get(buf, R), Items)}).

%% After a reader takes elements, move what a waiting writer still holds into the
%% room made, and give the writer its STREAM_WRITE event.
refill(RH) ->
    case get(?WAITABLE(RH)) of
        #{peer := W} = R when W =/= undefined ->
            case get(?WAITABLE(W)) of
                #{state := {copying, Ptr, Count}, elem := D} = Wr ->
                    case min(Count, room(R)) of
                        0 -> ok;
                        N ->
                            append(RH, R, load_elems(D, Ptr, N, stream)),
                            put(?WAITABLE(W),
                                Wr#{state => idle,
                                    pending => result(stream, ?COMPLETED, N)})
                    end;
                _ -> ok
            end;
        _ -> ok
    end.

%% `{stream,future}.cancel-{read,write}': only a pending copy can be cancelled. If
%% what it waited for has already arrived, the copy completes and its result is
%% returned; otherwise it ends with CANCELLED and nothing copied.
cancel_copy(Dir, Kind, H) ->
    ingest_available(task_ref(), ?POLL_DRAIN),
    case get(?WAITABLE(H)) of
        #{'end' := Dir, kind := Kind, state := {copying, _, _}} = E ->
            case try_deliver(H) of
                {event, _, _, Payload} -> {ok, [Payload]};
                none ->
                    put(?WAITABLE(H), E#{state => idle}),
                    {ok, [result(Kind, ?CANCELLED, 0)]}
            end;
        #{'end' := Dir, kind := Kind} -> {trap, no_copy_to_cancel};
        undefined -> {trap, unknown_waitable};
        _ -> {trap, wrong_end}
    end.

%% Dropping an end while it copies traps, and so does dropping a future's writer
%% before it has written. A dropped reader leaves its writer's copies DROPPED; a
%% dropped writer lets its reader see the end.
drop_end(Dir, Kind, H) ->
    case get(?WAITABLE(H)) of
        #{'end' := Dir, kind := Kind, state := {copying, _, _}} ->
            {trap, drop_while_copying};
        #{'end' := write, kind := future, state := State} when State =/= done ->
            {trap, future_dropped_before_write};
        #{'end' := Dir, kind := Kind} = E ->
            forget_waitable(H),
            ok = detach(E),
            {ok, []};
        undefined -> {trap, unknown_waitable};
        _ -> {trap, wrong_end}
    end.

detach(#{'end' := read, peer := W}) when W =/= undefined ->
    update(W, fun(Wr) -> Wr#{reader => undefined} end);
detach(#{'end' := write, reader := RH}) when RH =/= undefined ->
    update(RH, fun(R) -> R#{writer => closed, peer => undefined} end);
detach(_) ->
    ok.

update(H, Fun) ->
    case get(?WAITABLE(H)) of
        undefined -> ok;
        E -> put(?WAITABLE(H), Fun(E)), ok
    end.

forget_waitable(H) ->
    join(H, 0),
    _ = erase(?WSET_OF(H)),
    _ = erase(?WAITABLE(H)),
    ok.

%% The packed copy result: a stream carries its progress in the high bits.
result(stream, Code, N) -> Code bor (N bsl 4);
result(future, Code, _N) -> Code.

%%% --------------------------------------------------------------- subtasks ---

%% `subtask.cancel': a subtask whose result has already been delivered, or one
%% already cancelled, or one in a waitable-set, traps. One that has returned but
%% not been told is told now (RETURNED); one still running is stopped
%% (CANCELLED_BEFORE_RETURNED).
subtask_cancel(H) ->
    ingest_available(task_ref(), ?POLL_DRAIN),
    case {get(?WAITABLE(H)), get(?WSET_OF(H))} of
        {#{'end' := subtask}, Set} when Set =/= undefined ->
            {trap, subtask_in_waitable_set};
        {#{'end' := subtask, state := ready}, _} ->
            {event, _, _, State} = try_deliver(H),
            {ok, [State]};
        {#{'end' := subtask, state := awaiting} = S, _} ->
            stop_producer(H),
            put(?WAITABLE(H), S#{state => cancelled}),
            {ok, [?SUBTASK_CANCELLED]};
        {#{'end' := subtask}, _} ->
            {trap, subtask_already_resolved};
        {undefined, _} ->
            {trap, unknown_waitable};
        _ ->
            {trap, wrong_end}
    end.

%% `subtask.drop': only once the subtask has resolved and the guest knows it.
subtask_drop(H) ->
    case get(?WAITABLE(H)) of
        #{'end' := subtask, state := State} when State =:= returned;
                                                  State =:= cancelled ->
            forget_waitable(H),
            {ok, []};
        #{'end' := subtask} -> {trap, subtask_not_resolved};
        undefined -> {trap, unknown_waitable};
        _ -> {trap, wrong_end}
    end.

-doc """
The core function an async-lowered import (`canon lower` with the async option) binds
to. The guest calls it with the lowered arguments plus a return-area pointer, expecting
a subtask status back. `Sig` is the import's `{Params, Result}`; `Fun` the host
implementation. This synchronous form runs the host function inline, writes its result
into the return area, and reports RETURNED at once, with no subtask handle (as the
specification has it for a call that has already resolved).

The three-argument form is the suspending case: the host function's result is computed
but delivered later. The lowered call records a pending subtask, spawns a producer
(`PFun`, given the subtask handle) that signals completion when it chooses, and reports
the subtask STARTED, so the guest suspends. When the completion arrives the executor
writes the result into the return area and delivers a SUBTASK event to resume the guest.
""".
-spec async_lower({[wasm_canon:desc()], wasm_canon:desc() | none},
                  fun(([term()]) -> term())) -> function().
async_lower({Params, Result}, Fun) ->
    fun(_Ctx, Flats) ->
        Inst = task_instance(),
        {Terms, Rest} = wasm_canon:lift_params(Inst, Params, Flats),
        Value = Fun(Terms),
        write_return_area(Inst, Result, Rest, Value),
        {ok, [?SUBTASK_RETURNED]}
    end.

-spec async_lower({[wasm_canon:desc()], wasm_canon:desc() | none},
                  fun(([term()]) -> term()), fun((map()) -> any())) -> function().
async_lower({Params, Result}, Fun, PFun) ->
    fun(_Ctx, Flats) ->
        Inst = task_instance(),
        {Terms, Rest} = wasm_canon:lift_params(Inst, Params, Flats),
        Value = Fun(Terms),
        RetPtr = case Rest of [P | _] -> P; [] -> undefined end,
        H = next_handle(),
        put(?WAITABLE(H), #{'end' => subtask, result => Result, ret_ptr => RetPtr,
                            value => Value, state => awaiting}),
        ok = register_producer(H, PFun),
        {ok, [(H bsl 4) bor ?SUBTASK_STARTED]}
    end.

write_return_area(_Inst, none, _Rest, _Value)      -> ok;
write_return_area(_Inst, _Result, [undefined | _], _V) -> ok;
write_return_area(Inst, Result, [RetPtr | _], V)   -> wasm_canon:store_value(Inst, Result, RetPtr, V);
write_return_area(_Inst, _Result, [], _Value)      -> ok.

-doc """
The value a guest producer wrote to a future/stream it returned: the future's value,
or every element a stream received (a binary for `stream<u8>`, else a list).
`call_async` reads this from the returned handle before the task frame is torn down.
""".
-spec take_produced(non_neg_integer()) -> {ok, term()} | error.
take_produced(H) ->
    case get(?WAITABLE(H)) of
        #{'end' := read, kind := future, buf := [V]} -> {ok, V};
        #{'end' := read, kind := stream, buf := Buf} -> {ok, Buf};
        _ -> error
    end.

%%% ------------------------------------------------------- wait (executor) side ---

-doc """
Block the task until a member of waitable-set `Set` has a deliverable completion, then
perform the copy into guest memory and return `{event, EventCode, Waitable, ReturnCode}`
for the executor to hand to the callback. `{error, Reason}` when a producer fails
without supplying what a pending copy needs, or when nothing is left that could end
the wait. Called by `wasm_component:call_async/4` on a WAIT status.
""".
-spec wait_on_set(non_neg_integer()) ->
          {event, non_neg_integer(), non_neg_integer(), integer()} | {error, term()}.
wait_on_set(Set) ->
    bump_waits(),
    fire_wait_hook(Set),
    case wait_core(fun() -> deliver_first(Set) end, blocking) of
        {event, _, _, _} = Event -> Event;
        {error, _} = Error -> Error
    end.

%% A guest waitable-set.wait/poll: run the core, write the two payload words at Ptr,
%% return the event code (0 = NONE). A failure traps.
wait_write(_Set, Ptr, _Mode) when Ptr rem 4 =/= 0 ->
    {trap, unaligned_event_pointer};
wait_write(Set, Ptr, Mode) ->
    case wait_core(fun() -> deliver_first(Set) end, Mode) of
        {event, EC, E1, E2} ->
            ok = wasm:write_memory(task_instance(), Ptr,
                                   <<E1:32/little, (E2 band 16#FFFFFFFF):32/little>>),
            {ok, [EC]};
        none ->
            ok = wasm:write_memory(task_instance(), Ptr, <<0:64>>),
            {ok, [?EV_NONE]};
        {error, Reason} ->
            {trap, Reason}
    end.

%% A copy declared without `async' waits for its own end's event and returns its
%% payload, as the built-in's result.
wait_own(H) ->
    case wait_core(fun() -> try_deliver(H) end, blocking) of
        {event, _, _, Payload} -> {ok, [Payload]};
        {error, Reason} -> {trap, Reason}
    end.

%% Ingest what is already queued and deliver if `Ready' finds an event; otherwise
%% block for the next producer message, or report `none' when non-blocking.
wait_core(Ready, Mode) ->
    Ref = task_ref(),
    ingest_available(Ref, ?POLL_DRAIN),
    case Ready() of
        {event, _, _, _} = Event -> Event;
        none when Mode =:= nonblocking -> none;
        none -> block_wait(Ready, Ref)
    end.

%% Every completion comes from a producer; with none left, nothing can end the
%% wait, which would otherwise hang the task for ever.
block_wait(Ready, Ref) ->
    case producers() of
        [] -> {error, async_deadlock};
        _ ->
            receive
                {async_ready, Ref, H, Info} ->
                    ingest(H, Info),
                    again(Ready, Ref);
                {?DOWN(Ref), _Mon, process, Pid, Reason} ->
                    on_producer_down(Pid, Reason, Ready, Ref)
            end
    end.

again(Ready, Ref) ->
    case Ready() of
        {event, _, _, _} = Event -> Event;
        none -> block_wait(Ready, Ref)
    end.

%% A monitored producer died. Its data messages (ordered before the DOWN) are already
%% ingested; if a copy is now deliverable, deliver it. A producer that ended normally
%% after sending all it had is done; one that failed with a copy still waiting on it
%% fails the wait.
on_producer_down(Pid, Reason, Ready, Ref) ->
    {value, {Pid, _Mon, H}} = lists:keysearch(Pid, 1, producers()),
    forget_producer(Pid),
    ingest_available(Ref, ?POLL_DRAIN),
    case Ready() of
        {event, _, _, _} = Event -> Event;
        none when Reason =:= normal -> block_wait(Ready, Ref);
        none -> failed(H, Reason, Ready, Ref)
    end.

%% A failed producer is fatal only to a copy that still needs it.
failed(H, Reason, Ready, Ref) ->
    case get(?WAITABLE(H)) of
        #{state := {copying, _, _}} -> {error, {producer_failed, Reason}};
        #{'end' := subtask, state := awaiting} -> {error, {producer_failed, Reason}};
        _ -> block_wait(Ready, Ref)
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
    update(H, fun(#{'end' := read, kind := future, buf := []} = R) ->
                      R#{buf => [V], writer => closed};
                 (E) -> E
              end);
ingest(H, {data, Items}) ->
    update(H, fun(#{'end' := read, kind := stream, buf := Buf} = R) ->
                      R#{buf => cat(Buf, Items)};
                 (E) -> E
              end);
ingest(H, close) ->
    update(H, fun(#{'end' := read} = R) -> R#{writer => closed};
                 (E) -> E
              end);
ingest(H, subtask_complete) ->
    update(H, fun(#{'end' := subtask, state := awaiting} = S) -> S#{state => ready};
                 (E) -> E
              end).

%% Find the first member of `Set` with a pending copy its state can satisfy, perform
%% the copy, and return one event.
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
        #{'end' := read, state := {copying, Ptr, Count}} = R ->
            deliver_read(H, R, Ptr, Count);
        #{'end' := write, pending := Payload} = W ->
            put(?WAITABLE(H), maps:remove(pending, W)),
            {event, write_event(W), H, Payload};
        #{'end' := write, state := {copying, _, _}, reader := undefined,
          kind := Kind} = W ->
            put(?WAITABLE(H), W#{state => done}),
            {event, write_event(W), H, result(Kind, ?DROPPED, 0)};
        #{'end' := subtask, state := ready, result := Result, ret_ptr := RetPtr,
          value := Value} = S ->
            write_return_area(task_instance(), Result, [RetPtr], Value),
            put(?WAITABLE(H), S#{state => returned}),
            {event, ?EV_SUBTASK, H, ?SUBTASK_RETURNED};
        _ ->
            none
    end.

deliver_read(H, #{kind := Kind, elem := D, buf := Buf, writer := Writer} = R,
             Ptr, Count) ->
    case is_empty(Buf) of
        false ->
            {Taken, Rest, N} = take(Buf, Count),
            ok = store_elems(D, Ptr, Taken, Kind),
            Next = case Kind of future -> done; stream -> idle end,
            put(?WAITABLE(H), R#{buf => Rest, state => Next}),
            refill(H),
            {event, read_event(Kind), H, result(Kind, ?COMPLETED, N)};
        true when Writer =:= closed ->
            put(?WAITABLE(H), R#{state => done}),
            {event, read_event(Kind), H, result(Kind, ?DROPPED, 0)};
        true ->
            none
    end.

read_event(future) -> ?EV_FUTURE_READ;
read_event(stream) -> ?EV_STREAM_READ.

write_event(#{kind := future}) -> ?EV_FUTURE_WRITE;
write_event(#{kind := stream}) -> ?EV_STREAM_WRITE.

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

forget_producer(Pid) ->
    put(?PRODUCERS, lists:keydelete(Pid, 1, producers())),
    ok.

%% Stop the producer feeding `H' (a cancelled subtask's), and drop what it sent.
stop_producer(H) ->
    case lists:keytake(H, 3, producers()) of
        {value, {Pid, Mon, H}, Rest} ->
            erlang:demonitor(Mon, [flush]),
            exit(Pid, kill),
            put(?PRODUCERS, Rest),
            ok;
        false ->
            ok
    end.

stop_producers() ->
    lists:foreach(fun({Pid, Mon, _H}) ->
                      erlang:demonitor(Mon, [flush]),
                      exit(Pid, kill)
                  end, producers()),
    ok.

%% Drop any completion or producer `DOWN' left over for this task after
%% teardown. Only this task's: the caller's own monitors stay in its mailbox.
flush_stale(Ref) ->
    receive
        {async_ready, Ref, _, _}          -> flush_stale(Ref);
        {?DOWN(Ref), _, process, _, _}    -> flush_stale(Ref)
    after 0 ->
        ok
    end.

%%% ------------------------------------------------------------------ buffers ---

%% A `stream<u8>' buffer is a binary, any other a list of values.
empty(u8) -> <<>>;
empty(_) -> [].

is_empty(<<>>) -> true;
is_empty([]) -> true;
is_empty(_) -> false.

len(Bin) when is_binary(Bin) -> byte_size(Bin);
len(L) -> length(L).

cat(Buf, Items) when is_binary(Buf), is_binary(Items) -> <<Buf/binary, Items/binary>>;
cat(Buf, Items) when is_binary(Buf) -> <<Buf/binary, (list_to_binary(Items))/binary>>;
cat(Buf, Items) when is_binary(Items) -> Buf ++ binary_to_list(Items);
cat(Buf, Items) -> Buf ++ Items.

take(Bin, Count) when is_binary(Bin) ->
    N = min(Count, byte_size(Bin)),
    <<Taken:N/binary, Rest/binary>> = Bin,
    {Taken, Rest, N};
take(L, Count) ->
    N = min(Count, length(L)),
    {Taken, Rest} = lists:split(N, L),
    {Taken, Rest, N}.

%% Elements to and from guest memory, each at its element size. A future holds one
%% value (`none' for a `future' with no payload type).
store_elems(none, _Ptr, _Items, _Kind) -> ok;
store_elems(D, Ptr, [V], future) -> wasm_canon:store_value(task_instance(), D, Ptr, V);
store_elems(_D, _Ptr, <<>>, stream) -> ok;
store_elems(u8, Ptr, Bin, stream) -> wasm:write_memory(task_instance(), Ptr, Bin);
store_elems(D, Ptr, Items, stream) ->
    {Size, _} = wasm_canon:size_align(D),
    Inst = task_instance(),
    _ = lists:foldl(fun(V, P) -> ok = wasm_canon:store_value(Inst, D, P, V), P + Size end,
                    Ptr, Items),
    ok.

load_elems(none, _Ptr, _N, future) -> undefined;
load_elems(D, Ptr, 1, future) -> wasm_canon:load_value(task_instance(), D, Ptr);
load_elems(_D, _Ptr, 0, stream) -> [];
load_elems(u8, Ptr, N, stream) ->
    {ok, Bin} = wasm:read_memory(task_instance(), Ptr, N),
    Bin;
load_elems(D, Ptr, N, stream) ->
    {Size, _} = wasm_canon:size_align(D),
    Inst = task_instance(),
    [wasm_canon:load_value(Inst, D, Ptr + I * Size) || I <- lists:seq(0, N - 1)].

%%% -------------------------------------------------------------------- helpers ---

task_instance() -> get(?TASK_INST).

%% A fresh (readable, writable) pair, reader in the LOW 32 bits, writer in the high.
%% Each end knows the other: a guest writes to the writer and keeps or returns the
%% reader.
new_pair(Kind, Elem) ->
    R = new_reader(Kind, Elem, case Kind of future -> []; stream -> empty(Elem) end,
                   open),
    W = next_handle(),
    put(?WAITABLE(W), #{'end' => write, kind => Kind, elem => Elem, reader => R,
                        state => idle}),
    update(R, fun(E) -> E#{peer => W} end),
    (W bsl 32) bor R.

get_context(Slot) ->
    case get(?CTX(Slot)) of undefined -> 0; Value -> Value end.

next_handle() ->
    N = case get(?NEXT) of undefined -> 1; V -> V end,
    put(?NEXT, N + 1),
    N.
