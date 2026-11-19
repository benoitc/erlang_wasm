-module(wasm_component_coop_threads_SUITE).
-moduledoc """
What a WASI 0.3 program built with wasi-libc's cooperative threads asks of
the host. That toolchain makes every pthread a Component Model thread, lifts
and lowers async functions without the async option, and keeps each thread's
stack pointer in a context slot.

The fixtures are `coopthreads` and `syncrun`, hand-written component text
under `test/fixtures/component/`. Each case failed before the change it
names: none of them ran on 0.10.2.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([a_run_lifted_without_async_is_called/1,
         an_async_import_lowered_without_async_blocks/1,
         a_suspending_import_lowered_without_async_blocks/1,
         a_blocking_import_reads_its_string/1,
         a_lift_in_a_core_without_memory_uses_the_memory/1,
         realloc_runs_with_slots_of_its_own/1,
         a_thread_calls_through_another_cores_table/1,
         each_thread_has_its_own_slots/1,
         a_waiting_thread_lets_another_run/1,
         a_thread_whose_event_came_runs_before_one_that_yields/1,
         a_thread_names_its_host_function/1,
         destroy_forgets_the_kept_host_functions/1]).

all() ->
    [a_run_lifted_without_async_is_called,
     an_async_import_lowered_without_async_blocks,
     a_suspending_import_lowered_without_async_blocks,
     a_blocking_import_reads_its_string,
     a_lift_in_a_core_without_memory_uses_the_memory,
     realloc_runs_with_slots_of_its_own,
     a_thread_calls_through_another_cores_table,
     each_thread_has_its_own_slots,
     a_waiting_thread_lets_another_run,
     a_thread_whose_event_came_runs_before_one_that_yields,
     a_thread_names_its_host_function,
     destroy_forgets_the_kept_host_functions].

-define(HOST, ~"local:coop/host").
%% The most words a thread may send its owner for one host call. A call that
%% names its function sends a few dozen; one that sends its context sends
%% the instance, thousands even for this fixture.
-define(MAX_CALL_WORDS, 200).

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Coop} = file:read_file(fixture("coopthreads")),
    {ok, Run} = file:read_file(fixture("syncrun")),
    [{coop, Coop}, {run, Run} | Config].

end_per_suite(_) -> ok.

init_per_testcase(Case, Config) when Case =:= a_run_lifted_without_async_is_called;
                                     Case =:= destroy_forgets_the_kept_host_functions ->
    Config;
init_per_testcase(_, Config) ->
    {ok, I} = wasm_component:instantiate(?config(coop, Config), imports(self()),
                                         #{loader => compile}),
    [{inst, I} | Config].

end_per_testcase(_, Config) ->
    case ?config(inst, Config) of
        undefined -> ok;
        I -> ok = wasm_component:destroy(I)
    end.

%%% --------------------------------------------------------------- cases ---

%% Fail-first: the runner called a 0.3 `run' in its async-lifted form only,
%% and answered `no_async_export'.
a_run_lifted_without_async_is_called(Config) ->
    ?assertMatch({ok, #{exit_code := 0}},
                 wasi_preview3:run_command(?config(run, Config), <<>>,
                                           #{compile => true})).

%% Fail-first: an async import was always bound in its async form, which
%% reads a return-area pointer the guest did not pass.
an_async_import_lowered_without_async_blocks(Config) ->
    ?assertEqual({ok, 42}, call(Config, ~"double", [21])).

%% The same for an import that completes later: the call returns once its
%% producer has said so.
a_suspending_import_lowered_without_async_blocks(Config) ->
    ?assertEqual({ok, 42}, call(Config, ~"later", [21])).

a_blocking_import_reads_its_string(Config) ->
    ?assertEqual({ok, 5}, call(Config, ~"len-hello", [])).

%% Fail-first: the built-ins of a call acted on the core its lift is in,
%% which here has no memory, so the string could not be read.
a_lift_in_a_core_without_memory_uses_the_memory(Config) ->
    ?assertEqual({ok, 5}, call(Config, ~"len-hello-wrapped", [])).

%% The guest sets its slot to 42 and calls an import whose result the host
%% allocates. Its `realloc' notes the slot it starts with and leaves it at
%% zero, as wasi-libc's does. Fail-first, twice: `context.get' trapped during
%% a `realloc' (`cannot_leave'); then `realloc' saw the caller's 42 and left
%% the caller a zero, which answers 42.
realloc_runs_with_slots_of_its_own(Config) ->
    ?assertEqual({ok, 42000}, call(Config, ~"realloc-slots", [])).

%% Fail-first: a thread is a process that knew its own core only, and the
%% call through the table of another trapped with `foreign_reference'.
a_thread_calls_through_another_cores_table(Config) ->
    ?assertEqual({ok, 1}, call(Config, ~"thread-note", [7])),
    ?assertEqual(7, receive {note, X} -> X after 1000 -> none end).

%% Fail-first: the slots were a task's, shared by its threads: the new
%% thread started with 11 and the first found 22 on its return (2211).
each_thread_has_its_own_slots(Config) ->
    ?assertEqual({ok, 1100}, call(Config, ~"thread-slots", [])).

%% Fail-first: `waitable-set.wait' on the implicit thread blocked the whole
%% instance, and with nothing to wake it the call trapped (`async_deadlock').
a_waiting_thread_lets_another_run(Config) ->
    ?assertEqual({ok, 99}, call(Config, ~"wait-for-thread", [])).

%% The other thread resolves the future, then yields a thousand times.
%% Fail-first: a thread that yields is always ready, and was picked before
%% the one whose event had come, every time (99000 + 1000).
a_thread_whose_event_came_runs_before_one_that_yields(Config) ->
    ?assertEqual({ok, 99001}, call(Config, ~"wait-beside-a-yielder", [])).

%% Fail-first: a host call from a thread sent its context, which holds the
%% instance, to the owner.
a_thread_names_its_host_function(Config) ->
    Collector = spawn_link(fun() -> collect(0) end),
    1 = erlang:trace(self(), true, [send, set_on_spawn, {tracer, Collector}]),
    Result = call(Config, ~"thread-note", [7]),
    _ = erlang:trace(self(), false, [send, set_on_spawn]),
    Collector ! {largest, self()},
    Largest = receive {largest, N} -> N after 5000 -> timeout end,
    ?assertEqual({ok, 1}, Result),
    ?assert(Largest > 0),
    ?assert(Largest < ?MAX_CALL_WORDS, #{words => Largest}).

%% The largest call a thread sent its owner, in words.
collect(Largest) ->
    receive
        {trace, _From, send, {fiber_call, _Ref, _Pid, Fun}, _To} ->
            collect(max(Largest, erts_debug:flat_size(Fun)));
        {largest, To} ->
            To ! {largest, Largest};
        _ ->
            collect(Largest)
    end.

%% Fail-first: nothing was kept, so nothing was forgotten; the case pins
%% that what is kept for an instance's threads goes with the instance.
destroy_forgets_the_kept_host_functions(Config) ->
    Before = kept(),
    {ok, I} = wasm_component:instantiate(?config(coop, Config), imports(self()),
                                         #{loader => compile}),
    ?assert(kept() > Before),
    ok = wasm_component:destroy(I),
    ?assertEqual(Before, kept()).

kept() ->
    length([K || {{wasm_async, owner_fun, _} = K, _} <- get()]).

%%% ------------------------------------------------------------- helpers ---

call(Config, Export, Args) ->
    Sig = {[u32 || _ <- Args], u32},
    wasm_component:call(?config(inst, Config), Export, Sig, Args).

imports(Test) ->
    Later = fun(#{owner := Owner, task_ref := Ref, handle := H}) ->
                    Owner ! {async_ready, Ref, H, subtask_complete}
            end,
    #{{?HOST, ~"double"} => {async_import, {[u32], u32}, fun([X]) -> X * 2 end},
      {?HOST, ~"later"} => {async_import, {[u32], u32}, fun([X]) -> X * 2 end,
                            {producer, Later}},
      {?HOST, ~"len"} => {async_import, {[string], u32},
                          fun([S]) -> byte_size(S) end},
      {?HOST, ~"name"} => wasm_component:import_fun({[], string},
                                                    fun([]) -> ~"guest" end),
      {?HOST, ~"note"} => wasm_component:import_fun({[u32], none},
                                                    fun([X]) -> Test ! {note, X}, ok end)}.

fixture(Name) ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..", "test", "fixtures",
                   "component", Name ++ ".component.wasm"]).
