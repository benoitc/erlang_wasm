-module(pyarms).
-moduledoc """
The four CPython configurations, one emulator each, with what happened proved.

A wall time on its own cannot say which of the four ran, so every arm prints
the reply, `wasm_jit:counts/0`, the interpreted dispatch count and
`code:which/1` for the modules that would be swapped by a `-pa` in the wrong
order. An arm that did not do its work says so instead of reporting a number.

    erlc -I _build/default/lib -o bench/paths bench/paths/pyarms.erl
    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run pyarms main <guest.wasm> <script-dir> <arm> [cache-dir]

The arms:

  cold     one request, lowering inside the window. The baseline.
  pre      one request, every function lowered in the same process before the
           window opens, so the window holds no lowering at all.
  whole    as `adopted`, with `compile_whole => true`, so the unit is every
           eligible function rather than the ones the request ran. Its own
           timeout, because 11,447 functions at `full` quality take far longer
           than the ordinary arm ever does, and a timeout misread as a compiler
           defect is exactly the sort of thing this file exists to prevent. Give
           it a cache directory of its own and an empty one.
  adopted  a fresh instance that enters generated code on its *first* call.
           Reaching that today needs a priming instance to raise the ask,
           because `maybe_adopt/3` can only adopt what is already resident and
           only the compiler puts anything there. The priming call is outside
           the window and in its own process. The arm asserts `entered > 0`;
           without that it is not this arm.
  two      two requests to one instance. Subtracting `cold` gives the cost of a
           request after Python has started, which is the number a prewarmed
           pool would actually serve.
""".

-include_lib("wasm/include/wasm_exec.hrl").

-export([main/1]).

-define(REQ1, <<"{\"name\": \"ada\"}\n">>).
-define(REQ2, <<"{\"name\": \"bob\"}\n">>).

main([Guest, Dir, Arm]) -> main([Guest, Dir, Arm, "", "nocount", "auto"]);
main([Guest, Dir, Arm, Cache]) ->
    main([Guest, Dir, Arm, Cache, "nocount", "auto"]);
main([Guest, Dir, Arm, Cache, Count]) ->
    main([Guest, Dir, Arm, Cache, Count, "auto"]);
main([Guest, Dir, Arm, Cache, Count, Shards]) ->
    %% `auto' leaves `compile_shards' out of the map entirely, which is the
    %% configuration an acceptance run has to exercise: passing 1 would leave a
    %% large guest refused and make a one-shard assertion vacuous.
    persistent_term:put({?MODULE, shards},
                        case Shards of
                            "auto" -> auto;
                            N -> list_to_integer(N)
                        end),
    {ok, _} = application:ensure_all_started(wasm),
    Cache =:= "" orelse application:set_env(wasm, code_cache_dir, Cache),
    {ok, Bin} = file:read_file(Guest),
    io:format("arm ~s~nguest ~s ~w bytes~n",
              [Arm, hex(crypto:hash(sha256, Bin)), byte_size(Bin)]),
    io:format("load average ~s~n", [loadavg()]),
    [io:format("~-14w ~s~n", [M, code:which(M)])
     || M <- [wasm_exec, wasm_instance, wasm_jit]],
    run(list_to_atom(Arm), Bin, Dir, Count =:= "count"),
    init:stop().

%%% -------------------------------------------------------------------- arms ---

%% One arm is not like the others: `inwin` puts instantiation *inside* the
%% window, where every other arm has it in the setup. It exists because an
%% earlier measurement of lowering differed from this one by 20 M words and the
%% two harnesses disagreed about exactly this boundary.
%% Lowering priced on its own, with nothing else in the window at all. This is
%% the arm that settles what lowering costs, because it does not depend on
%% subtracting one large number from another.
run(loweronly, Bin, Dir, _Count) ->
    {ok, Mod} = wasm:compile(Bin),
    Res = allocwords:measure(
            fun() -> inst(Mod, Dir, [?REQ1], false) end,
            fun(I) ->
                N = lower_all(I),
                {0, {[{lowered, N}], not_counted, wasm_jit:counts(), 0}}
            end, 1800000),
    show(Res);
run(inwin, Bin, Dir, Count) ->
    {ok, Mod} = wasm:compile(Bin),
    wasm_jit:reset_counts(),
    Res = allocwords:measure(
            fun() -> ok end,
            fun(_) -> call(inst(Mod, Dir, [?REQ1], false), Count) end, 1800000),
    show(Res);
run(Arm, Bin, Dir, Count) ->
    {Mod, Reqs, Setup, Compile} = shape(Arm, Bin, Dir),
    wasm_jit:reset_counts(),
    Res = allocwords:measure(
            fun() -> I = inst(Mod, Dir, Reqs, Compile), Setup(I), I end,
            fun(I) -> call(I, Count) end, 1800000),
    show(Res),
    %% The traced wall is not the wall. A `load/1` arm emits about 35,000 GC
    %% events and a compiled one a few hundred, so the instrument charges the
    %% arms unequally; this repetition carries no tracing at all.
    {T, R} = clean(Mod, Dir, Reqs, Setup, Compile),
    io:format("clean wall        ~w ms, replies ~p~n", [T, R]),
    io:format("jit after         ~p~n", [wasm_jit:counts()]).

shape(cold, Bin, _Dir) ->
    {ok, Mod} = wasm:compile(Bin),
    {Mod, [?REQ1], fun(_) -> ok end, false};

shape(two, Bin, _Dir) ->
    {ok, Mod} = wasm:compile(Bin),
    {Mod, [?REQ1, ?REQ2], fun(_) -> ok end, false};

%% Lowering moved out of the window rather than removed from the run: the IR
%% cache is keyed on the instance and lives in the process dictionary, so the
%% only place this can happen is the measured process, before tracing starts.
shape(pre, Bin, _Dir) ->
    {ok, Mod} = wasm:compile(Bin),
    {Mod, [?REQ1], fun(I) -> lower_all(I) end, false};

shape(whole, Bin, Dir) ->
    persistent_term:put({?MODULE, whole}, true),
    shape(adopted, Bin, Dir);
shape(adopted, Bin, Dir) ->
    %% On the heap like `compile/1`, and named like `load/1`. Without the
    %% identity `wasm_code_cache:key/6` refuses the module and nothing compiled
    %% is ever kept.
    {ok, Mod} = wasm:compile(Bin,
                             #{identity => {sha256, crypto:hash(sha256, Bin)}}),
    prime(Mod, Dir),
    {Mod, [?REQ1], fun(_) -> ok end, true}.

clean(Mod, Dir, Reqs, Setup, Compile) ->
    Parent = self(),
    P = spawn(fun() ->
                  I = inst(Mod, Dir, Reqs, Compile),
                  Setup(I),
                  {T, {Lines, _, _, _}} = call(I, false),
                  Parent ! {clean, self(), T, Lines}
              end),
    receive {clean, P, T, L} -> {T, L} after 1800000 -> erlang:error(clean_timeout) end.

%%% ----------------------------------------------------------------- priming ---

%% One full interpreted call, only to raise the ask that lets the compiler fill
%% a slot -- from the disk cache when it is warm. Nothing here is measured.
%%
%% In this process rather than a spawned one, which costs nothing and removes a
%% variable: compiling QuickJS takes 165 seconds, so a wait that is too short
%% reads exactly like an ask that went nowhere.
prime(Mod, Dir) ->
    I = inst(Mod, Dir, [?REQ1], true),
    {T, {R, _, _, _}} = call(I, false),
    io:format("priming call ~w ms, reply ~p~n", [T, R]),
    %% Four hours for the whole module, an hour otherwise. Both are ceilings
    %% rather than expectations, and the wait reports as it goes so a long
    %% compile is visibly a long compile and not a hang.
    Ceiling = case persistent_term:get({?MODULE, whole}, false) of
                  true -> 4 * 3600;
                  false -> 3600
              end,
    io:format("waiting for the compiler, up to ~w s~n", [Ceiling]),
    W = wait_compiled(Ceiling, 0),
    io:format("compiled after ~w s, ~p~n", [W, wasm_jit:counts()]).

%% Long, and reported as it waits. Compiling CPython from cold took more than
%% ten minutes on this box, and a deadline shorter than that reads as "the ask
%% never reached the compiler" when the compiler is in fact running. The
%% children count is what tells those two apart.
wait_compiled(0, _) -> erlang:error(never_compiled);
wait_compiled(N, Sec) ->
    case wasm_jit:counts() of
        #{compiled := C} when C > 0 -> Sec;
        _ ->
            Sec rem 30 =:= 0 andalso
                io:format("  ~w s ~p workers ~p~n",
                          [Sec, wasm_jit:counts(),
                           proplists:get_value(
                             active,
                             supervisor:count_children(wasm_jit_sup))]),
            timer:sleep(1000),
            wait_compiled(N - 1, Sec + 1)
    end.

%%% ------------------------------------------------------------------ guests ---

inst(Mod, Dir, Reqs, Compile) ->
    put(reqs, Reqs),
    Wasi = #{args => argv(Dir),
             dirs => [{~"/app", Dir, read}],
             stdin => fun(_) -> next() end,
             stdout => fun(D) -> line(D) end,
             stderr => fun(_) -> ok end},
    Limits = case Compile of
                 true ->
                     Base0 = #{max_memory_pages => 4096, compile => true,
                               compile_after => 1},
                     Base = case persistent_term:get({?MODULE, whole}, false) of
                                true -> Base0#{compile_whole => true};
                                false -> Base0
                            end,
                     case persistent_term:get({?MODULE, shards}, auto) of
                         auto -> Base;
                         N -> Base#{compile_shards => N}
                     end;
                 false -> #{max_memory_pages => 4096}
             end,
    {ok, I} = wasm:instantiate(Mod, wasi_preview1:imports(Wasi), Limits),
    I.

call(I, Count) ->
    %% Dispatch counted rather than assumed: an arm that entered generated code
    %% and one that did not are otherwise told apart only by a wall time.
    %%
    %% `ensure_loaded/1` first, and it is not decoration. `trace_pattern/3` on a
    %% module the emulator has not loaded matches nothing and answers 0, and
    %% `trace_info/2` then reads `undefined`, which prints as a missing count
    %% rather than as a failure. Counting also charges the interpreting arm and
    %% not the compiled one, so it is off unless asked for and never carries the
    %% wall time.
    Count andalso begin
        {module, _} = code:ensure_loaded(wasm_exec),
        1 = erlang:trace_pattern({wasm_exec, run, 3}, true, [call_count]),
        ok
    end,
    T0 = erlang:monotonic_time(millisecond),
    _ = wasm:call(I, ~"_start", []),
    T = erlang:monotonic_time(millisecond) - T0,
    N = case Count of
            true ->
                {call_count, C} = erlang:trace_info({wasm_exec, run, 3},
                                                    call_count),
                _ = erlang:trace_pattern({wasm_exec, run, 3}, false,
                                         [call_count]),
                C;
            false -> not_counted
        end,
    Lines = lists:reverse(case get(lines) of undefined -> []; L -> L end),
    %% Before the destroy: the shard count is read from the resident chain, and
    %% releasing the lease is what can take it away.
    Shards = wasm_jit:shards(I),
    ok = wasm:destroy(I),
    {T, {Lines, N, wasm_jit:counts(), Shards}}.

%% Every function, not the reached set: the window is what has to hold no
%% lowering, and lowering more than the request needs only moves more of it out.
lower_all(I) ->
    T0 = erlang:monotonic_time(millisecond),
    Fns = [F || F <- tuple_to_list(I#inst.funcs), is_record(F, fn)],
    N = length([wasm_instance:body_of(F, I) || F <- Fns]),
    io:format("pre-lowered ~w functions in ~w ms~n",
              [N, erlang:monotonic_time(millisecond) - T0]),
    N.

%%% ------------------------------------------------------------------ output ---

show(#{result := {T, {Lines, N, Counts, Shards}}} = R) ->
    io:format("~nwall              ~w ms~n", [T]),
    io:format("allocated         ~w words~n", [maps:get(allocated, R, 0)]),
    io:format("reclaimed         ~w words~n", [maps:get(reclaimed, R, 0)]),
    io:format("live before/after ~w / ~w words~n",
              [maps:get(live_before, R, 0), maps:get(live_after, R, 0)]),
    io:format("collections       ~w minor, ~w major~n",
              [maps:get(minor, R, 0), maps:get(major, R, 0)]),
    io:format("gc time           ~w ms (~.1f% of wall)~n",
              [maps:get(gc_us, R, 0) div 1000,
               case T of 0 -> 0.0; _ -> maps:get(gc_us, R, 0) / (T * 10) end]),
    io:format("dispatches        ~w~n", [N]),
    io:format("jit               ~p~n", [Counts]),
    io:format("shards resident   ~w~n", [Shards]),
    io:format("diagnostics       ~p~n", [wasm_jit:diagnostics()]),
    io:format("mbuf              ~p~n", [maps:get(mbuf, R, undefined)]),
    io:format("replies           ~p~n", [Lines]).

%%% ------------------------------------------------------------------ plumbing ---

next() ->
    case get(reqs) of
        [] -> eof;
        undefined -> eof;
        [H | T] -> put(reqs, T), {ok, H}
    end.

line(Data) ->
    B = <<(case get(buf) of undefined -> <<>>; X -> X end)/binary,
          (iolist_to_binary(Data))/binary>>,
    put(buf, take(B)),
    ok.

take(B) ->
    case binary:split(B, ~"\n") of
        [L, Rest] ->
            put(lines, [L | case get(lines) of undefined -> []; X -> X end]),
            take(Rest);
        [_] -> B
    end.

argv(Dir) ->
    case filelib:is_regular(filename:join(Dir, "worker.py")) of
        true -> [~"python", ~"-u", ~"/app/worker.py"];
        false -> [~"qjs", ~"/app/worker.js"]
    end.

hex(B) -> string:lowercase(binary:encode_hex(B)).

loadavg() ->
    string:trim(os:cmd("uptime | sed 's/.*averages*: //'")).
