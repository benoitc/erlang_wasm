%% @doc What only goes wrong at size.
%%
%% Every other module in this repository is small, and that is exactly why a
%% real 1.8 MB one aborted the emulator the first time it was tried: a function
%% reference carried its whole instance, a table held a thousand of them, and
%% `ets:insert' copies without preserving sharing. Nineteen gigabytes from a
%% file under two megabytes.
%%
%% The cost was table entries times module size, so it needed both to be large
%% before it showed. These cases make both large, from text, so they run
%% anywhere with nothing to download.
-module(wasm_scale_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("wasm_exec.hrl").

all() ->
    [a_big_table_does_not_multiply_the_instance,
     table_size_does_not_drive_memory,
     a_large_module_defers_its_lowering,
     a_deferred_body_runs_the_same,
     a_caller_that_never_instantiates_is_still_swept].

%%% --------------------------------------------------------------- fixtures ---

%% A module with `Funcs' functions of some bulk each, and a table of `Entries'
%% references to one of them. Kept under the deferral threshold so the instance
%% really does hold lowered code, which is what made the original defect bite.
source(Funcs, Entries) ->
    Bodies = [io_lib:format("(func $f~p (result i32) ~s (i32.const ~p))",
                            [N, filler(), N])
              || N <- lists:seq(1, Funcs)],
    Elems = lists:duplicate(Entries, " $f1"),
    iolist_to_binary(
      ["(module (table ", integer_to_list(Entries), " funcref)\n",
       "(elem (i32.const 0)", Elems, ")\n",
       Bodies,
       "(func (export \"go\") (result i32) (call $f1))\n",
       "(func (export \"ind\") (param i32) (result i32)\n",
       "  (call_indirect (type 0) (local.get 0))))"]).

%% Enough instructions that a lowered body is worth something, so that copying
%% one per table entry would be unmistakable.
filler() ->
    lists:duplicate(200, "(drop (i32.const 1)) ").

compiled(Funcs, Entries) ->
    {ok, Parsed} = wasm_wat:module(source(Funcs, Entries)),
    {ok, Mod} = wasm_validate:module(Parsed),
    Mod.

%% ETS memory attributable to one instantiation, in bytes. Taken as a delta
%% around it, with the instance released afterwards so the measurement does not
%% accumulate across cases.
ets_cost(Mod) ->
    _ = erlang:garbage_collect(),
    Before = erlang:memory(ets),
    {ok, Inst} = wasm:instantiate(Mod, #{}),
    After = erlang:memory(ets),
    ok = wasm:destroy(Inst),
    After - Before.

%%% ------------------------------------------------------------------ cases ---

%% The case that would have caught it. Before the fix this instantiation wrote
%% one copy of the instance per table entry; the emulator aborted trying to
%% allocate the result.
a_big_table_does_not_multiply_the_instance(_Config) ->
    Mod = compiled(200, 1024),
    Cost = ets_cost(Mod),
    ct:pal("1024 entries over 200 functions: ~p KB of ETS", [Cost div 1024]),
    %% Generous: the instance is a few hundred kilobytes, so a per-entry copy
    %% would be hundreds of megabytes. Anything near the bound is the defect
    %% back, not drift.
    ?assert(Cost < 16 * 1024 * 1024).

%% The property behind it, stated as scaling rather than as a bound: sixteen
%% times the table must not cost sixteen times the module. A reference is a
%% small term now, so the difference is the entries themselves.
table_size_does_not_drive_memory(_Config) ->
    Small = ets_cost(compiled(200, 64)),
    Large = ets_cost(compiled(200, 1024)),
    ct:pal("64 entries: ~p KB, 1024 entries: ~p KB", [Small div 1024, Large div 1024]),
    %% 960 extra references, each a three-element tuple. Even at a hundred
    %% bytes apiece that is under 100 KB, where copying the instance again
    %% would be measured in hundreds of megabytes.
    ?assert(Large - Small < 4 * 1024 * 1024).

%% Above the threshold a module keeps its bodies undecoded until something
%% calls them, which is what makes a real language runtime instantiable at all.
a_large_module_defers_its_lowering(_Config) ->
    Deferred = compiled(300, 8),
    Eager = compiled(8, 8),
    ?assert(lowered_later(Deferred)),
    ?assertNot(lowered_later(Eager)).

%% Reaches into the instance rather than timing it, because a timing test for
%% this on a loaded box proves nothing.
lowered_later(Mod) ->
    {ok, Inst} = wasm:instantiate(Mod, #{}),
    Deferred = lists:any(fun(#fn{body = {lazy, _}}) -> true;
                            (_) -> false
                         end, tuple_to_list(Inst#inst.funcs)),
    ok = wasm:destroy(Inst),
    Deferred.

%% Lowered bodies and instance state are cached per process, and the process
%% doing the caching is whichever one *calls*, which need not be the one that
%% instantiated. The sweep that empties those caches used to be reachable only
%% from `remember/1', which a pure caller never reaches, so a long-lived caller
%% grew by a module's worth of lowered code per instance, for instances that
%% had already been destroyed, with nothing that would ever free it.
a_caller_that_never_instantiates_is_still_swept(_Config) ->
    Mod = compiled(300, 8),
    Self = self(),
    Caller = spawn_link(fun caller/0),
    Rounds = 4 * 128,          % several sweep intervals
    [begin
         {ok, I} = wasm:instantiate(Mod, #{}),
         Caller ! {call, I, Self},
         receive done -> ok after 30000 -> ct:fail(slow) end,
         ok = wasm:destroy(I)
     end || _ <- lists:seq(1, Rounds)],
    Ir = ir_entries(Caller),
    %% Each round lowers a handful of bodies, so leaking would leave one set
    %% per round. Bounded by the sweep interval instead, which is a fraction of
    %% the rounds, is the property.
    ?assert(Ir < Rounds, {ir_entries, Ir, rounds, Rounds}).

%% What the caller holds when nothing sweeps it: the control for the case
%% above, so a bound that passes for the wrong reason is visible.
ir_entries(Pid) ->
    {dictionary, D} = process_info(Pid, dictionary),
    length([1 || {{wasm_ir, _, _}, _} <- D]).

caller() ->
    receive
        {call, I, From} ->
            {ok, [1]} = wasm:call(I, ~"go", []),
            {ok, [1]} = wasm:call(I, ~"ind", [0]),
            From ! done,
            caller()
    end.

%% Deferring is an implementation detail and must stay one: the answer, the
%% traps and the indirect calls are the same either way.
a_deferred_body_runs_the_same(_Config) ->
    Deferred = compiled(300, 8),
    Eager = compiled(8, 8),
    [begin
         {ok, I} = wasm:instantiate(Mod, #{}),
         ?assertEqual({ok, [1]}, wasm:call(I, ~"go", [])),
         ?assertEqual({ok, [1]}, wasm:call(I, ~"ind", [0])),
         %% Twice, so the second call takes the cached path.
         ?assertEqual({ok, [1]}, wasm:call(I, ~"go", [])),
         ?assertMatch({error, _}, wasm:call(I, ~"ind", [8])),
         ok = wasm:destroy(I)
     end || Mod <- [Deferred, Eager]].
