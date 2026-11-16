-module(wasm_component_wast_SUITE).
-moduledoc """
wasmtime's test scripts for the Component Model's cooperative thread
built-ins, run against `wasm_component`.

`test/fixtures/component/wast-threading/` holds each script as the JSON
command list `wasm-tools json-from-wast` makes, and one binary per component
(see its README). Every command of every script must pass: there is no
baseline.

An `invoke` goes through `wasm_component:call_async/4`, as wasmtime's own
runner calls every export from an async store. Its signature comes from the
command: the argument types and the expected result. An `assert_trap` names
wasmtime's message; `trap_reason/1` maps each one to the reason this runtime
gives the same trap.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([drop_subtask_on_separate_thread/1, many_threads_indexed/1,
         stackful_cancellation/1, subtask_drop_multithreaded/1,
         suspend_trap/1, thread_new_indirect_multi_table/1,
         threading_builtins/1, threading_trap_in_post_return/1,
         yield_cancellable/1]).

all() ->
    [drop_subtask_on_separate_thread, many_threads_indexed,
     stackful_cancellation, subtask_drop_multithreaded, suspend_trap,
     thread_new_indirect_multi_table, threading_builtins,
     threading_trap_in_post_return, yield_cancellable].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) ->
    ok.

drop_subtask_on_separate_thread(_) -> script("drop-subtask-on-separate-thread").
many_threads_indexed(_) -> script("many-threads-indexed").
stackful_cancellation(_) -> script("stackful-cancellation").
subtask_drop_multithreaded(_) -> script("subtask-drop-multithreaded").
suspend_trap(_) -> script("suspend-trap").
thread_new_indirect_multi_table(_) -> script("thread-new-indirect-multi-table").
threading_builtins(_) -> script("threading-builtins").
threading_trap_in_post_return(_) -> script("threading-trap-in-post-return").
yield_cancellable(_) -> script("yield-cancellable").

%%% ------------------------------------------------------------- runner ---

%% wasmtime's message for a trap, and the reason this runtime gives it.
trap_reason(<<"cannot leave component instance">>) -> cannot_leave;
trap_reason(<<"cannot resume thread which is not suspended">>) -> thread_not_suspended;
trap_reason(<<"uninitialized">>) -> uninitialized_element.

%% A component's instances live in the process that made them, so the whole
%% script runs in one process, under a deadline.
script(Name) ->
    {ok, Json} = file:read_file(filename:join(dir(), Name ++ ".json")),
    #{<<"commands">> := Commands} = json:decode(Json),
    {Pid, Mon} = spawn_monitor(fun() -> exit({done, run(Commands, #{})}) end),
    receive
        {'DOWN', Mon, process, Pid, {done, Failures}} ->
            ?assertEqual([], Failures);
        {'DOWN', Mon, process, Pid, Other} ->
            ct:fail({script_crashed, Other})
    after 60000 ->
        exit(Pid, kill),
        ct:fail(script_timed_out)
    end.

run([], _State) ->
    [];
run([Command | Rest], State) ->
    case step(Command, State) of
        {ok, State1} -> run(Rest, State1);
        {failed, Why, State1} ->
            [{maps:get(<<"line">>, Command), Why} | run(Rest, State1)]
    end.

step(#{<<"type">> := <<"module">>, <<"filename">> := File}, State) ->
    case instantiate(File) of
        {ok, Inst} -> {ok, State#{current => Inst}};
        Error -> {failed, {instantiate, Error}, maps:remove(current, State)}
    end;
step(#{<<"type">> := <<"module_definition">>, <<"name">> := Def,
       <<"filename">> := File}, State) ->
    {ok, State#{{def, Def} => File}};
step(#{<<"type">> := <<"module_instance">>, <<"module">> := Def}, State) ->
    case instantiate(maps:get({def, Def}, State)) of
        {ok, Inst} -> {ok, State#{current => Inst}};
        Error -> {failed, {instantiate, Error}, maps:remove(current, State)}
    end;
step(#{<<"type">> := <<"assert_return">>, <<"action">> := Action,
       <<"expected">> := Expected}, State) ->
    Want = case [value(E) || E <- Expected] of
               [] -> ok;
               [V] -> {ok, V}
           end,
    case invoke(Action, Expected, State) of
        Want -> {ok, State};
        {ok, ok} when Want =:= ok -> {ok, State};
        Got -> {failed, {assert_return, Want, Got}, State}
    end;
step(#{<<"type">> := <<"assert_trap">>, <<"action">> := Action,
       <<"text">> := Text}, State) ->
    Want = trap_reason(Text),
    case invoke(Action, [], State) of
        {error, #{class := trap} = E} ->
            case reason(E) of
                Want -> {ok, State};
                Other -> {failed, {assert_trap, Want, Other}, State}
            end;
        Got -> {failed, {assert_trap, Want, Got}, State}
    end.

instantiate(File) ->
    {ok, Bin} = file:read_file(filename:join(dir(), File)),
    wasm_component:instantiate(Bin, #{}).

invoke(_Action, _Expected, State) when not is_map_key(current, State) ->
    {error, no_instance};
invoke(#{<<"field">> := Field, <<"args">> := Args}, Expected,
       #{current := Inst}) ->
    Params = [desc(A) || A <- Args],
    Result = case Expected of
                 [] -> none;
                 [E] -> desc(E)
             end,
    wasm_component:call_async(Inst, Field, {Params, Result},
                              [value(A) || A <- Args]).

desc(#{<<"type">> := <<"u32">>}) -> u32;
desc(#{<<"type">> := <<"string">>}) -> string.

value(#{<<"type">> := <<"u32">>, <<"value">> := V}) -> binary_to_integer(V);
value(#{<<"type">> := <<"string">>, <<"value">> := V}) -> V.

%% A built-in's trap carries its reason in the context; a trap of the core
%% engine is its kind.
reason(#{kind := host_error, ctx := #{reason := R}}) -> R;
reason(#{kind := Kind}) -> Kind.

dir() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..", "test", "fixtures",
                   "component", "wast-threading"]).
