-module(wasm_component_async_abi_SUITE).
-moduledoc """
The async Canonical ABI built-ins, one behaviour per case.

The fixture is hand-written component text (`test/fixtures/component/asyncabi/`),
so each export calls exactly the built-in under test; its exports are stackful
lifts, which this suite also covers. Each case failed before the built-in was
implemented: cancellation answered COMPLETED, error contexts kept no message,
`task.cancel` and dropping an unresolved subtask did nothing, a second future
read answered DROPPED, `stream.write` buffered without bound, payloads were bytes
whatever their type, a wait gave up after 5 s, and a stackful lift was refused.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([a_stackful_lift_reads_a_typed_stream/1,
         a_future_of_a_tuple_is_read/1,
         a_stream_the_guest_makes_carries_its_type/1,
         cancelling_a_blocked_read_returns_cancelled/1,
         cancelling_an_idle_read_traps/1,
         a_second_future_read_traps/1,
         dropping_an_unwritten_future_traps/1,
         a_write_waits_for_room/1,
         a_stream_the_host_reads_takes_every_write/1,
         an_error_context_keeps_its_message/1,
         dropping_an_error_context_twice_traps/1,
         task_cancel_traps/1,
         yield_reports_not_cancelled/1,
         backpressure_refuses_the_next_call/1,
         balanced_backpressure_lets_calls_in/1,
         backpressure_below_zero_traps/1,
         a_wait_nothing_can_end_traps/1,
         a_wait_has_no_time_limit/1,
         a_failed_producer_traps_the_wait/1,
         cancelling_a_running_subtask_stops_it/1,
         dropping_a_running_subtask_traps/1]).

all() ->
    [a_stackful_lift_reads_a_typed_stream,
     a_future_of_a_tuple_is_read,
     a_stream_the_guest_makes_carries_its_type,
     cancelling_a_blocked_read_returns_cancelled,
     cancelling_an_idle_read_traps,
     a_second_future_read_traps,
     dropping_an_unwritten_future_traps,
     a_write_waits_for_room,
     a_stream_the_host_reads_takes_every_write,
     an_error_context_keeps_its_message,
     dropping_an_error_context_twice_traps,
     task_cancel_traps,
     yield_reports_not_cancelled,
     backpressure_refuses_the_next_call,
     balanced_backpressure_lets_calls_in,
     backpressure_below_zero_traps,
     a_wait_nothing_can_end_traps,
     a_wait_has_no_time_limit,
     a_failed_producer_traps_the_wait,
     cancelling_a_running_subtask_stops_it,
     dropping_a_running_subtask_traps].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture()),
    [{component, Bin} | Config].

end_per_suite(_) -> ok.

%% An instance belongs to the process that made it; the case runs in this one.
init_per_testcase(_, Config) ->
    Test = self(),
    %% `compute' starts and never finishes: it reports its producer and hangs.
    PFun = fun(_) -> Test ! {computing, self()}, receive after infinity -> ok end end,
    Imports = #{{~"local:abi/host", ~"compute"} =>
                    {async_import, {[u32], u32}, fun([X]) -> X end, {producer, PFun}}},
    {ok, Inst} = wasm_component:instantiate(?config(component, Config), Imports),
    [{inst, Inst} | Config].

end_per_testcase(_, Config) ->
    ok = wasm_component:destroy(?config(inst, Config)).

%%% --------------------------------------------------------------- cases ---

a_stackful_lift_reads_a_typed_stream(Config) ->
    ?assertEqual({ok, 25}, call(Config, ~"sum32", {[{stream, u32}], u32},
                                [[1, 2, 3, 4, 5, 10]])),
    ?assertEqual({ok, 4000000000},
                 call(Config, ~"sum32", {[{stream, u32}], u32}, [[4000000000]])).

a_future_of_a_tuple_is_read(Config) ->
    ?assertEqual({ok, 107}, call(Config, ~"point", {[{future, {tuple, [u32, u8]}}], u32},
                                 [{100, 7}])).

%% `stream.new' names `stream<u32>': the writes are three u32s, not twelve bytes.
a_stream_the_guest_makes_carries_its_type(Config) ->
    ?assertEqual({ok, [1, 256, 4294967295]},
                 call(Config, ~"ints", {[], {stream, u32}}, [])).

%% Nothing is ever sent, so the read blocks; cancelling it reports CANCELLED (2)
%% with nothing copied.
cancelling_a_blocked_read_returns_cancelled(Config) ->
    ?assertEqual({ok, 2}, call(Config, ~"cancel-read", {[{stream, u8}], u32},
                               [{producer, fun(_) -> receive after infinity -> ok end end}])).

cancelling_an_idle_read_traps(Config) ->
    traps(no_copy_to_cancel, call(Config, ~"cancel-idle", {[], u32}, [])).

a_second_future_read_traps(Config) ->
    traps(copy_not_idle, call(Config, ~"read-twice", {[{future, u32}], u32}, [5])).

dropping_an_unwritten_future_traps(Config) ->
    traps(future_dropped_before_write, call(Config, ~"drop-unwritten", {[], u32}, [])).

%% Nobody reads the stream: the first write fills the buffer (1024 of 5000), the
%% second has no room and blocks, and cancelling it reports CANCELLED.
a_write_waits_for_room(Config) ->
    ?assertEqual({ok, (1024 bsl 8) bor (1 bsl 4) bor 2},
                 call(Config, ~"bounded", {[], u32}, [])).

%% Once the guest has returned the stream, the host is its reader and takes
%% each write whole (the guest checks it completed all 5000).
a_stream_the_host_reads_takes_every_write(Config) ->
    {ok, Bytes} = call(Config, ~"big", {[], {stream, u8}}, []),
    ?assertEqual(5000, byte_size(Bytes)).

%% "boom" comes back through `debug-message': length 4, first byte $b.
an_error_context_keeps_its_message(Config) ->
    ?assertEqual({ok, (4 bsl 8) bor $b}, call(Config, ~"error-message", {[], u32}, [])).

dropping_an_error_context_twice_traps(Config) ->
    traps(unknown_error_context, call(Config, ~"error-drop-twice", {[], u32}, [])).

task_cancel_traps(Config) ->
    traps(task_cancel_not_requested, call(Config, ~"task-cancel", {[], u32}, [])).

yield_reports_not_cancelled(Config) ->
    ?assertEqual({ok, 0}, call(Config, ~"yield", {[], u32}, [])).

backpressure_refuses_the_next_call(Config) ->
    ?assertEqual({ok, 1}, call(Config, ~"bp-raise", {[], u32}, [])),
    ?assertEqual({error, async_backpressure}, call(Config, ~"yield", {[], u32}, [])).

balanced_backpressure_lets_calls_in(Config) ->
    ?assertEqual({ok, 1}, call(Config, ~"bp-balance", {[], u32}, [])),
    ?assertEqual({ok, 0}, call(Config, ~"yield", {[], u32}, [])).

backpressure_below_zero_traps(Config) ->
    traps(backpressure_underflow, call(Config, ~"bp-under", {[], u32}, [])).

%% An empty set with no producer: the wait used to give up after 5 s and answer
%% NONE; now it traps at once.
a_wait_nothing_can_end_traps(Config) ->
    {Took, Res} = timer:tc(fun() -> call(Config, ~"deadlock", {[], u32}, []) end,
                           millisecond),
    traps(async_deadlock, Res),
    ?assert(Took < 4000).

%% A producer that sends after six seconds: the wait used to end at five.
a_wait_has_no_time_limit(Config) ->
    PFun = fun(#{owner := O, task_ref := R, handle := H}) ->
                   timer:sleep(6000),
                   O ! {async_ready, R, H, {data, [7]}},
                   O ! {async_ready, R, H, close}
           end,
    ?assertEqual({ok, 7}, call(Config, ~"sum32", {[{stream, u32}], u32},
                               [{producer, PFun}])).

a_failed_producer_traps_the_wait(Config) ->
    traps(producer_failed, call(Config, ~"sum32", {[{stream, u32}], u32},
                                [{producer, fun(_) -> exit(boom) end}])).

%% `compute' never finishes; cancelling it reports CANCELLED_BEFORE_RETURNED
%% (4) and lets the subtask be dropped (the guest drops it before returning). Its
%% producer is stopped, often before it can say who it is.
cancelling_a_running_subtask_stops_it(Config) ->
    ?assertEqual({ok, 4}, call(Config, ~"cancel-subtask", {[u32], u32}, [1])),
    receive {computing, P} -> ?assertNot(is_process_alive(P)) after 100 -> ok end.

dropping_a_running_subtask_traps(Config) ->
    traps(subtask_not_resolved, call(Config, ~"drop-running", {[u32], u32}, [1])).

%%% ------------------------------------------------------------- helpers ---

call(Config, Export, Sig, Args) ->
    wasm_component:call_async(?config(inst, Config), Export, Sig, Args).

%% The call failed, and `Reason' is why.
traps(Reason, {error, E}) ->
    ?assert(mentions(Reason, E), {Reason, E});
traps(Reason, Other) ->
    ct:fail({expected_trap, Reason, Other}).

mentions(A, A) -> true;
mentions(A, T) when is_tuple(T) -> mentions(A, tuple_to_list(T));
mentions(A, M) when is_map(M) -> mentions(A, maps:to_list(M));
mentions(A, [H | T]) -> mentions(A, H) orelse mentions(A, T);
mentions(_, _) -> false.

fixture() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..", "test", "fixtures",
                   "component", "asyncabi.component.wasm"]).
