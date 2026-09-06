-module(compileheap).
-moduledoc """
Where a compile's memory is spent, and what a ceiling on it would cost.

`compile:forms/2` runs its passes in a process of its own, so a `max_heap_size`
set on the process `wasm_jit` spawns bounds a process that only waits:
`test/audit/PERF.md` records 0.34 GB of heap on our side of a compile whose node
reached 6.19 GB. The recorded alternative, `no_spawn_compiler_process` on that
same long-lived coordinator, moved the growth where a ceiling can see it and
cost 75% more compile time. Neither shipped.

This asks the question that experiment did not ask: what does it cost to run
`no_spawn_compiler_process` in a *fresh, disposable* process of our own, which
is the lifecycle OTP's own child already has? The coordinator holds the
instance, the whole unit IR and the Core term and lives through the compile; a
child that receives only the Core allocates, answers and exits.

    erlc -I _build/default/lib -o bench/paths bench/paths/compileheap.erl
    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run compileheap main <guest.wasm> [samples] [<ir-words> | fN | all]
    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run compileheap main validate

The three arms compile the *same* `Core` term, built once before any of them
runs, so nothing about lowering is inside any window:

  otp     `compile:forms/2` as `wasm_core:module/9` calls it today. OTP spawns.
  inline  `no_spawn_compiler_process` on the measuring process, which also
          holds the unit. This is the 293 s row, reproduced.
  child   the same option in a fresh process holding only the Core, under the
          `max_heap_size` map that would actually ship, at a size nothing here
          can reach.

## What each number is worth

**Wall time comes from a second, untraced run.** Tracing charges the arms
unequally, because they differ in how many processes exist and therefore in how
many collection events the instrument sees. `bench/paths/pyarms.erl` records the
same trap in its own words: "The traced wall is not the wall." The gate reads
the clean wall and nothing else.

**Peak heap is sampled, so it is a lower bound, always.** The quantity
`max_heap_size` compares against is `total_heap_size` and that is what is
sampled, but a peak between two samples is invisible, and so is the memory the
collector needs while collecting.

**Allocated words are per process**, from that process's own collection trace,
by `allocwords`'s estimator: reclaimed, plus ending live, minus starting live,
over a window a forced major collection closes at each end.

**The `otp` arm cannot have that window.** Its child is spawned inside
`compile:do_compile/2` and exits with its result, so nothing can force the
closing collection. What is reported for it is the reclaimed sum alone, marked
`lower`. The `inline` and `child` arms are complete, because both boundaries
are in code this module wrote.

## Proving the instrument before believing it

`main validate` checks the pid-keyed estimator against a known allocation
happening in two processes at once, which is exactly what `allocwords` cannot
do: its estimator pairs a start with the end after it, sound only when the
events come from one process, and `set_on_spawn` interleaves several into one
mailbox. Run it on the box before the numbers here are believed.
""".

-export([main/1, validate/0]).

-include_lib("wasm/include/wasm.hrl").
-include_lib("wasm/include/wasm_exec.hrl").

%% `procs' is what delivers the spawn event that names the process actually
%% running the compiler, `set_on_spawn' is what makes that process traced at
%% all, and `garbage_collection' is what the estimator counts. A child inherits
%% only the flags its parent carries, so dropping any of the three leaves the
%% collector with nothing: `[procs, set_on_spawn]' alone delivers spawn events
%% and zero collections.
%%
%% `monotonic_timestamp' is for the collection *time*, which no counter carries,
%% and it changes the message tag to `trace_ts' and appends a timestamp. A
%% harness matching `{trace, ...}' matches nothing at all.
-define(FLAGS, [procs, garbage_collection, set_on_spawn, monotonic_timestamp]).

-define(SAMPLE_MS, 50).
-define(TIMEOUT, 3600000).

%% The map that would ship, at a size nothing here can reach. The gate has to
%% measure the configuration an embedder would run, and
%% `include_shared_binaries' is acknowledged to have a cost, so measuring with
%% it off would price a configuration nobody uses.
-define(SIZE, (8 bsl 30)).

-define(ARMS, [otp, inline, child]).

%% IR words, which is what the compile's cost tracks. On QuickJS this selects
%% 10 functions, 385 K IR words and 17.2 M Core words, which compiles in about
%% 87 seconds and produces 7.06 MB of BEAM: the same order as the 10.9 MB
%% `PERF.md` records for that guest's 223-function hot set, at a runtime that
%% permits the 45 compiles a five-sample gate needs. See `build/2`.
-define(WORDS, 400000).

main(["validate"]) ->
    case validate() of
        ok -> init:stop();
        {error, _} -> init:stop(1)
    end;
main([Path]) ->
    main([Path, "5"]);
main([Path, N]) ->
    main([Path, N, integer_to_list(?WORDS)]);
main([Path, N, Funs]) ->
    {ok, _} = application:ensure_all_started(wasm),
    where(),
    io:format("load before  ~s~n", [load()]),
    {ok, Bin} = file:read_file(Path),
    {ok, Mod} = wasm:load(Bin),
    {ok, Inst} = wasm:instantiate(Mod, wasi_preview1:imports(#{}), #{}),
    {Unit, Core} = build(Inst, limit(Funs)),
    %% The IR figure is the sum over the functions' own IR, which is the
    %% quantity `wasm_jit:split/2' packs shards by and the one the budget
    %% counts. `flat_size(Unit)' is a different and larger number, because a
    %% unit entry carries the whole `#fn{}' beside its IR, and reporting that
    %% one as "IR words" is how the first draft of this harness came to select
    %% four times the unit it meant to.
    IrWords = lists:sum([erts_debug:flat_size(IR) || {_P, _I, _F, IR} <- Unit]),
    io:format("unit         ~w functions, IR ~w words, unit ~w words, "
              "Core ~w words~n",
              [length(Unit), IrWords, erts_debug:flat_size(Unit),
               erts_debug:flat_size(Core)]),
    Rows = rounds(Core, {Inst, Unit}, list_to_integer(N)),
    io:format("~nload after   ~s~n", [load()]),
    report(Rows, length(Unit), IrWords),
    %% `-run' does not halt the node when the function returns, and a harness
    %% that prints its whole report and then sits there looks exactly like one
    %% that hung.
    init:stop().

%%% ------------------------------------------------------------ the unit ---

limit("all") -> all;
limit([$f | N]) -> {funs, list_to_integer(N)};
limit(N) -> {words, list_to_integer(N)}.

%% By IR words rather than by function count, because words are what the cost
%% tracks: `src/wasm_jit.erl' sizes shards by `erts_debug:flat_size/1' of the
%% IR for exactly this reason, and the first 402 QuickJS functions by index
%% carry 8.07 M words where the whole module carries 12.0 M. A count is a poor
%% handle on a compile whose functions differ by three orders of magnitude.
take(all, L) -> L;
take({funs, N}, L) -> lists:sublist(L, N);
take({words, Budget}, L) -> upto(Budget, L, []).

upto(_Left, [], Acc) -> lists:reverse(Acc);
upto(Left, [{_F, IR} = H | T], Acc) ->
    case erts_debug:flat_size(IR) of
        %% Always at least one, so a budget under the first function still
        %% builds a unit rather than an empty one.
        W when W > Left, Acc =/= [] -> lists:reverse(Acc);
        W -> upto(Left - W, T, [H | Acc])
    end.

%% `wasm_jit:unit/2` with an empty executed list, which is how it reads "every
%% eligible function", then cut to `Limit`. Reproduced here rather than
%% exported, because a bench harness reaching into a private selector is the
%% harness's problem and not the runtime's.
%%
%% **The prefix is chosen for scale, not for realism.** It is a deterministic
%% prefix of the eligible list and it is not any workload's hot set, which it
%% does not claim to be. What the gate needs is that all three arms compile the
%% identical term, and any deterministic selection gives that; what the *size*
%% has to give is a compile far enough above fixed costs for a ratio to mean
%% something, without being the shape that pages the box.
%%
%% Pass `all` for every eligible function, which for QuickJS is 1,666 of them,
%% 12.0 M IR words and 106.0 M Core words. That is the `compile_whole` shape,
%% it reached 5 GB resident in its first minute on a 48 GB box, and it is not
%% what the tier compiles for anyone. `fN` cuts by function count instead, and
%% is mostly useful for showing why counting functions is the wrong handle:
%% QuickJS's first 402 by index carry 8.07 M of the module's 12.0 M words.
build(Inst, Limit) ->
    Fns = [F || F <- tuple_to_list(Inst#inst.funcs), is_record(F, fn)],
    Lowered = [{F, wasm_instance:compiler_ir(F, Inst)} || F <- Fns],
    Eligible = take(Limit,
                    [{F, IR} || {F, IR} <- Lowered,
                                element(1, wasm_core:can_compile(F, IR)) =:= ok]),
    Unit = [{Pos, F#fn.idx, F, IR}
            || {Pos, {F, IR}} <- lists:enumerate(0, Eligible)],
    %% Zero for the stamp, and a name nothing loads: this unit is compiled
    %% three times and never entered.
    {ok, Core} = wasm_core:forms(compileheap_unit, Unit, sigs(Inst),
                                 tsigs(Inst), 0),
    {Unit, Core}.

sigs(Inst) ->
    maps:from_list(
      [{Idx, sig(F)}
       || {Idx, F} <- lists:enumerate(0, tuple_to_list(Inst#inst.funcs))]).

tsigs(Inst) ->
    maps:from_list(
      [{Idx, S}
       || {Idx, T} <- lists:enumerate(0, tuple_to_list(Inst#inst.types)),
          S <- [tsig(T)], S =/= undefined]).

tsig(#functype{params = P, results = R}) -> {length(P), length(R)};
tsig(#subtype{body = #functype{params = P, results = R}}) ->
    {length(P), length(R)};
tsig(_) -> undefined.

sig(#fn{nparams = NP, nresults = NR}) -> {NP, NR};
sig(#hostfn{nparams = NP, nresults = NR}) -> {NP, NR}.

copts() -> [from_core, binary, return_errors].

%%% ---------------------------------------------------------------- arms ---

%% `Bound' says whether this run may force the collections the estimator's
%% window needs. The clean run says no, so what it times is the shape that
%% would ship and not the shape that can be accounted for.
run(otp, Core, _Bound) ->
    {compile:forms(Core, copts()), []};
run(inline, Core, _Bound) ->
    {compile:forms(Core, [no_spawn_compiler_process | copts()]), []};
run(child, Core, Bound) ->
    Owner = self(),
    {Pid, Ref} =
        spawn_opt(fun () ->
                      Bound andalso erlang:garbage_collect(),
                      R = compile:forms(
                            Core, [no_spawn_compiler_process | copts()]),
                      %% Closing boundary with `R' still referenced, so the
                      %% artifact counts as live and not as reclaimed.
                      Bound andalso erlang:garbage_collect(),
                      Owner ! {result, self(), R}
                  end,
                  [monitor,
                   {max_heap_size, #{size => ?SIZE, kill => true,
                                     error_logger => false,
                                     include_shared_binaries => true}}]),
    %% By message rather than by exit reason, which is what lets the child
    %% force its closing collection before it dies. The artifact is a refcounted
    %% binary either way, so what crosses is a header.
    receive
        {result, Pid, R} ->
            demonitor(Ref, [flush]),
            {R, [Pid]};
        {'DOWN', Ref, process, Pid, Why} ->
            {{error, {compiler_died, Why}}, [Pid]}
    after ?TIMEOUT ->
            erlang:error({arm_timeout, child})
    end.

%%% --------------------------------------------------------- instrumented ---

%% `Live' is what the real coordinator holds for the whole compile: the
%% instance and the unit IR, beside the Core it is compiling. It is referenced
%% *after* the compile so it cannot be collected during it, and that is the
%% whole point of passing it.
%%
%% Without it the `inline' arm does not reproduce the row it exists to
%% reproduce. Measured on one QuickJS function with the runner holding only the
%% Core, `inline' was 18.7 s against `otp' 18.6, where `PERF.md' has 293 s
%% against 167. The recorded cost was never the option; it was collecting a
%% live set this size on every pass.
instrumented(Arm, Core, Live) ->
    Owner = self(),
    Runner = spawn(fun () ->
                       receive go -> ok end,
                       erlang:garbage_collect(),
                       {R, Bounded} = run(Arm, Core, true),
                       erlang:garbage_collect(),
                       Owner ! {done, self(), R, Bounded, held(Live)}
                   end),
    %% Matched against 1. A trace that installed nothing answers 0 and then
    %% confirms whatever story you had, which `PERF.md' records as a trap this
    %% project has already fallen into once.
    1 = erlang:trace(Runner, true, ?FLAGS),
    Runner ! go,
    %% Seeded from the clock, never from zero. `erlang:monotonic_time/1' has an
    %% arbitrary origin and on this box reads about -576,460,751,902 ms, so a
    %% zero seed makes `Now - Last >= ?SAMPLE_MS' false for the next eighteen
    %% thousand years and every peak comes out 0.0 MB.
    watch(Runner, #{Runner => 0}, [], erlang:monotonic_time(millisecond)).

%% The sampler is driven by the clock and not by the mailbox being empty.
%% Leaving it to `after ?SAMPLE_MS' looks right and is not: a compile floods
%% this mailbox with collection events, every one of them matches a clause, and
%% the timeout then never fires for as long as the compile is busiest. The
%% sampler would starve exactly where the peak is.
watch(Runner, Peaks0, Evs, Last0) ->
    {Last, Peaks} = maybe_sample(Last0, Peaks0),
    receive
        {trace_ts, _P, spawn, Child, _MFA, _Ts} ->
            watch(Runner, Peaks#{Child => 0}, Evs, Last);
        {trace_ts, _, _, _, _, _} ->
            watch(Runner, Peaks, Evs, Last);
        {trace_ts, P, Kind, Info, Ts} when Kind =:= gc_minor_start;
                                           Kind =:= gc_minor_end;
                                           Kind =:= gc_major_start;
                                           Kind =:= gc_major_end ->
            watch(Runner, Peaks, [{P, Kind, Info, Ts} | Evs], Last);
        {trace_ts, _, _, _, _} ->
            watch(Runner, Peaks, Evs, Last);
        {done, Runner, R, Bounded, _Held} ->
            finish(Runner, Peaks, Evs, R, Bounded)
    after ?SAMPLE_MS ->
            watch(Runner, Peaks, Evs, Last)
    end.

maybe_sample(Last, Peaks) ->
    Now = erlang:monotonic_time(millisecond),
    case Now - Last >= ?SAMPLE_MS of
        true -> {Now, sample(Peaks)};
        false -> {Last, Peaks}
    end.

sample(Peaks) ->
    maps:map(fun (P, Max) ->
                 case process_info(P, total_heap_size) of
                     {total_heap_size, S} when S > Max -> S;
                     _ -> Max
                 end
             end, Peaks).

finish(Runner, Peaks, Evs, Result, Bounded) ->
    %% Waiting for the message, not calling `trace_delivered/1', is the
    %% barrier. `all' rather than `Runner': the children have exited and their
    %% events are what this whole collector exists for.
    Ref = erlang:trace_delivered(all),
    receive {trace_delivered, all, Ref} -> ok end,
    All = lists:reverse(drain(Evs)),
    Complete = [Runner | Bounded],
    %% Every pid that produced an event, not only the ones a `spawn' event
    %% named. Trace messages are asynchronous and the runner reports `done'
    %% once its child has already exited, so a child's spawn event can arrive
    %% after that and its collections would then be dropped from the accounting
    %% while still being counted in nothing at all.
    Pids = lists:usort(maps:keys(Peaks) ++ Bounded ++
                           [P || {P, _, _, _} <- All]),
    Per = #{P => per_pid([E || {Q, _, _, _} = E <- All, Q =:= P],
                         lists:member(P, Complete))
            || P <- Pids},
    #{runner => Runner,
      peaks => Peaks,
      per_pid => Per,
      result => Result}.

drain(Acc) ->
    receive
        {trace_ts, _P, spawn, _Child, _MFA, _Ts} -> drain(Acc);
        {trace_ts, _, _, _, _, _} -> drain(Acc);
        {trace_ts, P, Kind, Info, Ts} when Kind =:= gc_minor_start;
                                           Kind =:= gc_minor_end;
                                           Kind =:= gc_major_start;
                                           Kind =:= gc_major_end ->
            drain([{P, Kind, Info, Ts} | Acc]);
        {trace_ts, _, _, _, _} -> drain(Acc)
    after 0 -> Acc
    end.

%%% ------------------------------------------------------- the estimator ---

%% One process's events, in order. `allocwords`'s arithmetic, with the
%% bookkeeping replaced: that module pairs a start with the end that follows it
%% and says in its own moduledoc why that is sound, "Collections do not nest in
%% one process". They do interleave across processes, which is what this
%% grouping is for, and it is the whole of the difference.
per_pid(Evs, Complete) ->
    Ends = [{K, I} || {_P, K, I, _T} <- Evs,
                      K =:= gc_minor_end orelse K =:= gc_major_end],
    per_pid_1(Ends, Complete, us(gc_time(Evs, Complete))).

per_pid_1([], _Complete, _GcUs) ->
    #{collections => 0, note => no_collections};
per_pid_1(Ends, false, GcUs) ->
    %% No forced boundary at either end, so the starting and ending live sets
    %% are unknown and only what was reclaimed can be summed. A floor, and
    %% labelled one wherever it is printed.
    #{allocated => undefined,
      reclaimed => lists:sum([w(I, wordsize) || {_, I} <- Ends]),
      collections => length(Ends),
      major => length([x || {gc_major_end, _} <- Ends]),
      gc_us => GcUs,
      note => lower};
per_pid_1([{_, Open} | Rest], true, GcUs) ->
    %% The opening forced major is the boundary, so its own reclamation belongs
    %% to whatever ran before this window and is dropped.
    Live0 = live(Open),
    Live1 = case Rest of
                [] -> Live0;
                _ -> live(element(2, lists:last(Rest)))
            end,
    Reclaimed = lists:sum([w(I, wordsize) || {_, I} <- Rest]),
    #{allocated => Reclaimed + Live1 - Live0,
      reclaimed => Reclaimed,
      live_before => Live0,
      live_after => Live1,
      collections => length(Rest),
      major => length([x || {gc_major_end, _} <- Rest]),
      gc_us => GcUs,
      note => complete}.

%% A start and the end after it, within one process. The opening forced pair is
%% dropped for the same reason its words are.
gc_time(Evs, true) -> gc_time_1(drop_pair(Evs), 0);
gc_time(Evs, false) -> gc_time_1(Evs, 0).

gc_time_1([{P, S, _, T0}, {P, E, _, T1} | Rest], Acc)
  when (S =:= gc_minor_start orelse S =:= gc_major_start) andalso
       (E =:= gc_minor_end orelse E =:= gc_major_end) ->
    gc_time_1(Rest, Acc + (T1 - T0));
gc_time_1([_ | Rest], Acc) -> gc_time_1(Rest, Acc);
gc_time_1([], Acc) -> Acc.

drop_pair([_, _ | Rest]) -> Rest;
drop_pair(_) -> [].

us(T) -> erlang:convert_time_unit(T, native, microsecond).

live(I) -> w(I, heap_size) + w(I, old_heap_size).

w(Info, Key) -> proplists:get_value(Key, Info, 0).

%%% --------------------------------------------------------------- clean ---

%% The number the gate reads. One fresh process, no tracing, no sampler, and
%% the arm in the shape that would ship.
clean(Arm, Core, Live) ->
    Owner = self(),
    Pid = spawn(fun () ->
                    {T, {R, _}} = timer:tc(fun () -> run(Arm, Core, false) end),
                    Owner ! {clean, self(), T, R, held(Live)}
                end),
    receive
        {clean, Pid, T, R, _Held} -> {T, R}
    after ?TIMEOUT -> erlang:error({clean_timeout, Arm})
    end.

%% Touch it, cheaply, so it is live from the closure to here and the collector
%% has to copy it on every pass in between. A comment saying "kept alive" over
%% an unused variable is not the same thing: the compiler is entitled to drop
%% one, and this is the arm's whole independent variable.
held({Inst, Unit}) -> {element(1, Inst), length(Unit)}.

%%% ------------------------------------------------------------- rounds ---

%% Interleaved, not batched, and in both orderings, so a drift in the box's
%% load lands on every arm rather than on whichever ran last.
rounds(Core, Live, N) ->
    lists:append([round_(Core, Live, I, N) || I <- lists:seq(1, N)]).

%% The instrumented run happens once per arm and the clean run twice, once in
%% each order. The gate reads clean walls only, so that is what needs the
%% ordering; the memory figures do not, and an instrumented compile is the more
%% expensive of the two. Doing both twice was 12 compiles a sample where 9 say
%% the same thing.
round_(Core, Live, I, N) ->
    io:format("~nsample ~w/~w  load ~s~n", [I, N, load()]),
    %% Bound, not written as one `++' expression: Erlang does not specify the
    %% evaluation order of its operands and evaluates them right to left here,
    %% so the reversed pass ran first and the log read backwards.
    Forward = [one(Arm, Core, Live) || Arm <- ?ARMS],
    Reversed = [clean_only(Arm, Core, Live) || Arm <- lists:reverse(?ARMS)],
    Forward ++ Reversed.

one(Arm, Core, Live) ->
    #{result := R} = M = instrumented(Arm, Core, Live),
    {CleanUs, CleanR} = clean(Arm, Core, Live),
    Row = M#{arm => Arm,
             clean_us => CleanUs,
             bytes => byte_size(bin_of(R)),
             md5 => md5(bin_of(R)),
             clean_md5 => md5(bin_of(CleanR))},
    io:format("  ~-7w clean ~7.1f s  runner ~8.1f MB  worker ~8.1f MB  ~s~n",
              [Arm, CleanUs / 1000000, runner_peak(Row), worker_peak(Row),
               note_of(Row)]),
    Row.

clean_only(Arm, Core, Live) ->
    {CleanUs, CleanR} = clean(Arm, Core, Live),
    Row = #{arm => Arm, clean_us => CleanUs,
            bytes => byte_size(bin_of(CleanR)),
            md5 => md5(bin_of(CleanR)),
            clean_md5 => md5(bin_of(CleanR))},
    io:format("  ~-7w clean ~7.1f s  (reversed order)~n",
              [Arm, CleanUs / 1000000]),
    Row.

bin_of({ok, _Name, Bin}) -> Bin;
bin_of(Other) -> erlang:error({compile_failed, Other}).

md5(Bin) ->
    {ok, {_Mod, MD5}} = beam_lib:md5(Bin),
    MD5.

%% Reported apart, because the whole finding this harness exists to test is that
%% they are different numbers: `PERF.md' has 0.34 GB on the process `wasm_jit'
%% spawns against 6.19 GB on the node. `runner' is the process holding the unit
%% and waiting; `worker' is whatever actually ran the compiler, which is a child
%% in two arms and the runner itself in the third.
runner_peak(#{peaks := Peaks, runner := Runner}) ->
    mb(map_get(Runner, Peaks)).

worker_peak(#{peaks := Peaks, runner := Runner}) ->
    case [V || {P, V} <- maps:to_list(Peaks), P =/= Runner] of
        [] -> mb(map_get(Runner, Peaks));
        Vs -> mb(lists:max(Vs))
    end.

mb(Words) -> Words * erlang:system_info(wordsize) / 1048576.

note_of(#{per_pid := Per, runner := Runner}) ->
    case [N || {P, #{note := N}} <- maps:to_list(Per), P =/= Runner] of
        [] -> "one process";
        Ns -> lists:flatten(io_lib:format("child ~w", [Ns]))
    end.

%%% -------------------------------------------------------------- report ---

report(Rows, Funs, IrWords) ->
    io:format("~n~-8s ~9s ~9s ~9s ~11s ~11s ~13s ~7s~n",
              ["arm", "min s", "med s", "max s", "runner MB", "worker MB",
               "alloc Mw", "colls"]),
    Summ = [{A, summarise([R || R <- Rows, map_get(arm, R) =:= A])}
            || A <- ?ARMS],
    [io:format("~-8w ~9.1f ~9.1f ~9.1f ~11.1f ~11.1f ~13s ~7w~n",
               [A, map_get(min, S), map_get(med, S), map_get(max, S),
                map_get(runner, S), map_get(worker, S), alloc_str(S),
                map_get(colls, S)])
     || {A, S} <- Summ],
    io:format("~nalloc Mw is the compiling process's own allocation. A `>'~n"
              "is a floor: that arm's compiler is OTP's own child, which is~n"
              "spawned inside `do_compile/2' and exits with its result, so~n"
              "no closing collection can be forced and the final live set is~n"
              "unmeasured. Never compare a floor against a closed window.~n"),
    md5s(Rows),
    spread(Summ),
    ratio(Summ),
    per_word(Summ, Funs, IrWords).

summarise(Rows) ->
    Ws = lists:sort([map_get(clean_us, R) / 1000000 || R <- Rows]),
    %% Only the rows that carry a trace. A clean-only row has no memory in it
    %% and must not be averaged in as a zero.
    Ms = [R || R <- Rows, is_map_key(per_pid, R)],
    #{min => hd(Ws),
      med => lists:nth(1 + length(Ws) div 2, Ws),
      max => lists:last(Ws),
      runner => lists:max([runner_peak(R) || R <- Ms]),
      worker => lists:max([worker_peak(R) || R <- Ms]),
      alloc => biggest([worker_alloc(R) || R <- Ms]),
      floor => biggest([worker_floor(R) || R <- Ms]),
      colls => lists:sum([colls(R) || R <- Ms]) div length(Ms)}.

%% `lists:max/1' is the wrong tool here and was the first version of it: an
%% atom sorts above every number in Erlang term order, so one `undefined' in
%% the list wins and a perfectly good measurement disappears.
biggest(Vals) ->
    case [V || V <- Vals, is_integer(V)] of
        [] -> undefined;
        Ns -> lists:max(Ns)
    end.

alloc_str(#{alloc := undefined, floor := undefined}) -> "none";
alloc_str(#{alloc := undefined, floor := F}) ->
    lists:flatten(io_lib:format("> ~.1f", [F / 1000000]));
alloc_str(#{alloc := A}) ->
    lists:flatten(io_lib:format("~.1f", [A / 1000000])).

%% The process that ran the compiler, which is a child in two arms and the
%% runner itself in the third, and only when its window is closed at both ends.
worker_alloc(Row) -> from_worker(Row, allocated, complete).

%% What the same process reclaimed, which is all an unbounded window can say.
worker_floor(Row) -> from_worker(Row, reclaimed, lower).

from_worker(#{per_pid := Per, runner := Runner}, Key, Note) ->
    Ms = case [M || {P, M} <- maps:to_list(Per), P =/= Runner] of
             [] -> [map_get(Runner, Per)];
             Cs -> Cs
         end,
    biggest([maps:get(Key, M, undefined)
             || M <- Ms, maps:get(note, M, none) =:= Note]).

colls(#{per_pid := Per}) ->
    lists:sum([maps:get(collections, M, 0) || M <- maps:values(Per)]).

%% Same work, same output. The `no_spawn_compiler_process' atom lands in the
%% `compile_info' chunk, so `inline' and `child' are a few bytes larger than
%% `otp' and the md5 is identical for all three. An md5 that differs means the
%% arms did not compile the same thing and no timing below means anything.
md5s(Rows) ->
    Set = lists:usort([map_get(md5, R) || R <- Rows] ++
                      [map_get(clean_md5, R) || R <- Rows]),
    Sizes = lists:usort([{map_get(arm, R), map_get(bytes, R)} || R <- Rows]),
    io:format("~nmd5          ~s (~w distinct)~n",
              [case Set of [_] -> "identical across every arm and run";
                           _ -> "DIFFERENT, the arms did not do the same work"
               end, length(Set)]),
    io:format("bytes        ~p~n", [Sizes]).

%% Before any of the numbers are read: an arm whose own samples disagree by
%% more than a fifth is measuring the box, not the arm.
spread([]) -> ok;
spread(Summ) ->
    Bad = [{A, Min, Max} || {A, #{min := Min, max := Max}} <- Summ,
                            Min > 0, (Max - Min) / Min > 0.20],
    case Bad of
        [] -> io:format("spread       within 20% on every arm~n");
        _ -> io:format("spread       TOO WIDE ~p, redo the run~n", [Bad])
    end.

%% The gate. One ordered rule on one ratio, from the clean walls, so no result
%% matches two branches and none is unclassified.
ratio(Summ) ->
    {_, #{min := Otp}} = lists:keyfind(otp, 1, Summ),
    {_, #{min := Child}} = lists:keyfind(child, 1, Summ),
    R = Child / Otp,
    io:format("~nR            ~.3f  (child min / otp min)~n", [R]),
    io:format("verdict      ~s~n",
              [if R =< 1.10 -> "R =< 1.10, the ceiling is free: ship it";
                  R =< 1.20 -> "1.10 < R =< 1.20: ship opt-in, record the cost";
                  true -> "R > 1.20: stop, record the second negative result"
               end]).

%% What `src/wasm_jit.erl' cites without a source. Only from an arm whose
%% window is closed at both ends.
per_word(Summ, Funs, IrWords) ->
    case lists:keyfind(child, 1, Summ) of
        {child, #{alloc := A}} when is_integer(A), IrWords > 0 ->
            io:format("per IR word  ~.2f KB allocated in the compiler, over "
                      "~w functions and ~w IR words~n",
                      [A * erlang:system_info(wordsize) / IrWords / 1024,
                       Funs, IrWords]);
        _ ->
            io:format("per IR word  not available: the child arm has no "
                      "closed window~n")
    end.

%%% ------------------------------------------------------------- context ---

where() ->
    [io:format("~-12s ~s~n", [M, code:which(M)])
     || M <- [wasm_core, wasm_jit, compile]],
    io:format("~-12s ~s / erts ~s~n",
              [otp, erlang:system_info(otp_release),
               erlang:system_info(version)]).

load() ->
    string:trim(lists:last(string:split(os:cmd("uptime"), "average", trailing))).

%%% ------------------------------------------------------------- proving ---

-doc """
Prove the pid-keyed estimator where `allocwords` cannot follow it.

Two processes allocate a known amount at the same time, with their collections
interleaved in one tracer mailbox. A list of N cons cells is 2N heap words, so
each process's own figure has to come out at about 2N once the fixed per-process
overhead is taken off. `allocwords:validate/0` proves the arithmetic; this
proves that grouping by pid keeps it true when the events are interleaved,
which is the only thing this module changed.
""".
-spec validate() -> ok | {error, term()}.
validate() ->
    Overhead = pair_alloc(0, 0),
    io:format("harness overhead ~p words~n~n", [Overhead]),
    io:format("~10s ~14s ~16s ~16s ~10s~n",
              ["N", "want", "runner", "child", "worst"]),
    Rows = [vrow(N, Overhead) || N <- [200000, 1000000, 3000000]],
    io:format("~n"),
    case [R || {_, _, _, _, E} = R <- Rows, E > 0.05] of
        [] -> io:format("pid-keyed estimator agrees within 5%~n"), ok;
        Bad -> io:format("pid-keyed estimator is wrong: ~p~n", [Bad]),
               {error, Bad}
    end.

vrow(N, {ORunner, OChild}) ->
    Want = 2 * N,
    {Runner, Child} = pair_alloc(N, N),
    R = Runner - ORunner,
    C = Child - OChild,
    Err = lists:max([abs(R - Want) / Want, abs(C - Want) / Want]),
    io:format("~10w ~14w ~16w ~16w ~9.1f%~n", [N, Want, R, C, Err * 100]),
    {N, Want, R, C, Err}.

%% Both processes hold their list through their own closing collection, so both
%% exercise the live-set half of the formula, and both collect while the other
%% is collecting, which is the interleaving under test.
pair_alloc(NRunner, NChild) ->
    Owner = self(),
    Runner =
        spawn(fun () ->
                  receive go -> ok end,
                  erlang:garbage_collect(),
                  Me = self(),
                  _ = spawn(fun () ->
                                  erlang:garbage_collect(),
                                  L = lists:duplicate(NChild, 0),
                                  erlang:garbage_collect(),
                                  Me ! {kid, self(), length(L)}
                              end),
                  Mine = lists:duplicate(NRunner, 0),
                  KidPid = receive {kid, K, _} -> K end,
                  erlang:garbage_collect(),
                  Owner ! {done, self(), length(Mine), [KidPid]}
              end),
    1 = erlang:trace(Runner, true, ?FLAGS),
    Runner ! go,
    #{runner := R, per_pid := Per} = watch(Runner, #{Runner => 0}, [], 0),
    Others = [M || {P, M} <- maps:to_list(Per), P =/= R],
    {maps:get(allocated, map_get(R, Per), 0),
     lists:max([maps:get(allocated, M, 0) || M <- Others] ++ [0])}.
