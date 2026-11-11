-module(wasm_component_async_tasks_SUITE).
-moduledoc """
Tasks that outlive the call that started them, and the host's ends of their
streams and futures.

`wasm_component:start_async/5` returns once a task resolves; the task keeps
running in the instance, and `pump/2` or the `wasm_async` host-end calls give
it its turns. The fixture's `body` hands back a stream and then writes 3000
bytes to it, so it resolves long before it finishes. Before, a call ran its
task to the end, every stream and future died with the call, and a host
import could neither take nor give one.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([a_task_resolves_and_keeps_writing/1,
         two_tasks_interleave_with_their_own_state/1,
         pump_stops_when_only_the_host_can_help/1,
         a_sink_takes_writes_as_they_come/1,
         destroy_ends_a_pending_task/1,
         an_import_gives_the_guest_a_stream/1,
         an_import_gives_the_guest_a_future/1,
         a_host_end_call_inside_an_import_is_refused/1,
         call_async_still_runs_to_the_end/1,
         a_call_that_ends_leaves_a_pending_task_alone/1,
         a_sink_on_an_ended_stream_gets_the_end/1]).

all() ->
    [a_task_resolves_and_keeps_writing,
     two_tasks_interleave_with_their_own_state,
     pump_stops_when_only_the_host_can_help,
     a_sink_takes_writes_as_they_come,
     destroy_ends_a_pending_task,
     an_import_gives_the_guest_a_stream,
     an_import_gives_the_guest_a_future,
     a_host_end_call_inside_an_import_is_refused,
     call_async_still_runs_to_the_end,
     a_call_that_ends_leaves_a_pending_task_alone,
     a_sink_on_an_ended_stream_gets_the_end].

-define(BODY, {[], {stream, u8}}).

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture()),
    [{component, Bin} | Config].

end_per_suite(_) -> ok.

%% Compiled in the case's own process: per-case loads through the module
%% cache would count against its load rate.
init_per_testcase(_, Config) ->
    {ok, I} = wasm_component:instantiate(?config(component, Config), imports(),
                                         #{loader => compile}),
    [{inst, I} | Config].

end_per_testcase(_, Config) ->
    ok = wasm_component:destroy(?config(inst, Config)).

%%% --------------------------------------------------------------- cases ---

a_task_resolves_and_keeps_writing(Config) ->
    {ok, H} = wasm_component:start_async(inst(Config), ~"body", ?BODY, []),
    ?assertEqual(1, length(wasm_async:pending())),
    Bytes = read_all(H),
    ?assertEqual(binary:copy(<<1>>, 3000), Bytes),
    ?assertEqual({finished, 0}, wasm_component:pump(inst(Config), 1000)).

%% Each task keeps its state behind its own context slot and writes its own
%% byte; reading the two streams in turn runs both.
two_tasks_interleave_with_their_own_state(Config) ->
    {ok, A} = wasm_component:start_async(inst(Config), ~"body", ?BODY, []),
    {ok, B} = wasm_component:start_async(inst(Config), ~"body", ?BODY, []),
    ?assertEqual(2, length(wasm_async:pending())),
    {BytesA, BytesB} = read_both(A, B, <<>>, <<>>),
    ?assertEqual(binary:copy(<<1>>, 3000), BytesA),
    ?assertEqual(binary:copy(<<2>>, 3000), BytesB).

%% The writer filled the 1024 bytes of room and waits for the host to read:
%% `pump' answers at once instead of waiting out its timeout.
pump_stops_when_only_the_host_can_help(Config) ->
    {ok, H} = wasm_component:start_async(inst(Config), ~"body", ?BODY, []),
    {Took, Res} = timer:tc(fun() -> wasm_component:pump(inst(Config), 5000) end,
                           millisecond),
    ?assertEqual({idle, 1}, Res),
    ?assert(Took < 1000),
    ?assertEqual(3000, byte_size(read_all(H))).

a_sink_takes_writes_as_they_come(Config) ->
    Test = self(),
    {ok, H} = wasm_component:start_async(inst(Config), ~"body", ?BODY, []),
    ok = wasm_async:host_sink(H, fun(eof) -> Test ! eof, ok;
                                    (B) -> Test ! {bytes, B}, ok
                                 end),
    ?assertEqual({finished, 0}, wasm_component:pump(inst(Config), 5000)),
    ?assertEqual(3000, byte_size(collect(<<>>))),
    %% Told once the guest dropped its writer.
    receive eof -> ok after 0 -> ct:fail(no_eof) end.

destroy_ends_a_pending_task(Config) ->
    {ok, _H} = wasm_component:start_async(inst(Config), ~"body", ?BODY, []),
    ?assertEqual(1, length(wasm_async:pending())),
    ok = wasm_component:destroy(inst(Config)),
    ?assertEqual([], wasm_async:pending()).

%% `feed' makes a stream, writes 1..5 to it and ends it.
an_import_gives_the_guest_a_stream(Config) ->
    ?assertEqual({ok, 15},
                 wasm_component:call_async(inst(Config), ~"sum-feed", {[], u32}, [])).

an_import_gives_the_guest_a_future(Config) ->
    ?assertEqual({ok, 42},
                 wasm_component:call_async(inst(Config), ~"take-future", {[], u32}, [])).

%% Host-end calls run tasks, which must not start inside a guest call.
a_host_end_call_inside_an_import_is_refused(Config) ->
    ?assertEqual({ok, 1},
                 wasm_component:call_async(inst(Config), ~"reenter", {[], u32}, [])).

%% Unchanged: a call that runs its task to the end reads the stream whole.
call_async_still_runs_to_the_end(Config) ->
    ?assertEqual({ok, binary:copy(<<1>>, 3000)},
                 wasm_component:call_async(inst(Config), ~"body", ?BODY, [])).

%% A second call runs to its end while the first task is pending; ending it
%% tears down only its own state, so the first stream still reads whole.
a_call_that_ends_leaves_a_pending_task_alone(Config) ->
    {ok, H} = wasm_component:start_async(inst(Config), ~"body", ?BODY, []),
    ?assertEqual({ok, 42},
                 wasm_component:call_async(inst(Config), ~"take-future", {[], u32}, [])),
    ?assertEqual(1, length(wasm_async:pending())),
    ?assertEqual(binary:copy(<<1>>, 3000), read_all(H)).

%% The guest wrote "abc" and ended the stream before the host took it: the
%% sink gets the bytes, then the end (it used to wait for an end that had
%% already happened). `take' answers bytes * 10 + 1 once it saw the end.
a_sink_on_an_ended_stream_gets_the_end(Config) ->
    ?assertEqual({ok, 31},
                 wasm_component:call_async(inst(Config), ~"ended", {[], u32}, [])).

%%% ------------------------------------------------------------- helpers ---

inst(Config) -> ?config(inst, Config).

imports() ->
    Host = ~"local:tasks/host",
    #{{Host, ~"feed"} =>
          wasm_component:import_fun(
            {[], {stream, u8}},
            fun([]) ->
                    {R, W} = wasm_async:host_stream(u8),
                    ok = wasm_async:host_write(W, <<1, 2, 3, 4, 5>>, 0),
                    ok = wasm_async:host_close(W),
                    R
            end),
      {Host, ~"fut"} =>
          wasm_component:import_fun(
            {[], {future, u32}},
            fun([]) ->
                    {R, W} = wasm_async:host_future(u32),
                    ok = wasm_async:host_future_resolve(W, 42),
                    R
            end),
      {Host, ~"take"} =>
          wasm_component:import_fun(
            {[{stream, u8}], u32},
            fun([S]) ->
                    Got = counters:new(2, []),
                    ok = wasm_async:host_sink(
                           S, fun(eof) -> counters:put(Got, 2, 1), ok;
                                 (B) -> counters:add(Got, 1, byte_size(B)), ok
                              end),
                    counters:get(Got, 1) * 10 + counters:get(Got, 2)
            end),
      {Host, ~"reenter"} =>
          wasm_component:import_fun(
            {[], u32},
            fun([]) ->
                    case wasm_async:pump(0) of
                        {error, reentrant} -> 1;
                        _ -> 0
                    end
            end)}.

read_all(H) -> read_all(H, <<>>).

read_all(H, Acc) ->
    case wasm_async:host_read(H, 700, 5000) of
        {ok, B} -> read_all(H, <<Acc/binary, B/binary>>);
        eof -> Acc
    end.

read_both(A, B, AccA, AccB) ->
    case {next(A), next(B)} of
        {eof, eof} -> {AccA, AccB};
        {X, Y} -> read_both(A, B, <<AccA/binary, X/binary>>, <<AccB/binary, Y/binary>>)
    end.

next(H) ->
    case wasm_async:host_read(H, 500, 5000) of
        {ok, B} -> B;
        eof -> eof
    end.

collect(Acc) ->
    receive {bytes, B} -> collect(<<Acc/binary, B/binary>>)
    after 0 -> Acc
    end.

fixture() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..", "test", "fixtures",
                   "component", "asynctasks.component.wasm"]).
