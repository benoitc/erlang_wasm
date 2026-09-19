-module(phasing_adapter).
-moduledoc """
Time one worker request at its five adapter boundaries.

Use this when you want to know where a request's milliseconds go without
rebuilding the worker around them. It wraps a real adapter, forwards every
callback and records `erlang:monotonic_time(microsecond)` on each side, so the
request that is measured is the one a host actually sends: the real guardian,
the real mounts, the real channels, the real runner.

    {ok, W} = wasm_script_worker:start_link(
                phasing_adapter,
                #{root => scratch, path => "...", limits => L,
                  under => wasm_python, mode => timing}).

The measurement rides out in `decode/2`'s reply under `$phases`, so nothing is
messaged and no timing leaves the request it belongs to. `workerbench`'s
`strict_phase/2` strips it before validating the result.

## What the intervals are, and what they are not

`requirements/2` runs first, in the runner (`wasm_script_worker.erl:1479`), then
`prepare/3`, then the `post_restore` fun this wraps, then `classify/2`, then
`decode/2`. The gaps between them are the kernel's own work, and naming them is
the point:

| interval | contents |
| --- | --- |
| T1-T2  | request sizing and `requirements/2` |
| T2-T3  | policy checks, mount creation, environment construction |
| T3-T4  | encoding, the two stage operations, the import set |
| T4-T5  | `deliver/3`, `check_spec/1`, `wasm:restore/3`, `snapshot_info/1` |
| T5-T6  | the adapter's own `post_restore` check |
| T6-T7  | the invocation envelope |
| T7-T8  | classification |
| T8-T9  | `destroy` and the three channel reads |
| T9-T10 | the framed-result decode |

**T6-T7 is an envelope and not `handle()`.** T6 is taken inside `call_fun/2`
before `post_restore/3` returns, and T7 inside `invoke_loop/5`'s dispatch into
`classify/2`, so the interval wraps the guest call rather than bounding it: the
returns through `post_restore/3` and `start_instance/2`, the dispatch, all of
`wasm:call/5`. Isolating guest execution would need a boundary around
`wasm:call/5`, which no adapter can reach. Say envelope, not `handle()`.

T0 and T11 belong to the caller and are not here. `workerbench` takes them
around `submit/2` and `await/3` and joins them to this vector by the
`make_ref()` in it.

## The modes, and why the timed one is bare

One mode per worker, fixed at `start_link/2`. A timed request must carry
timestamps and nothing else: `process_info/2` allocates, a stashed instance
holds a live set, and a thousand function indices copied through runner,
guardian, worker and caller would be most of a small request.

| mode | what it adds |
| --- | --- |
| `timing`    | nothing. Timestamps and the sample reference. |
| `floor`     | `process_info(self(), garbage_collection)`, to prove the floor |
| `gc`        | the runner's pid, so a collector can filter its trace |
| `census`    | the executed-function eligibility census |
| `calibrate` | **test only**: a fixed sleep inside one named callback |

`calibrate` exists to catch a boundary wired to the wrong phase, and it is
refused unless the worker asked for it by name.
""".

-behaviour(wasm_worker_adapter).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2,
         snapshot_capability/1]).

-include_lib("wasm/include/wasm.hrl").
-include_lib("wasm/include/wasm_exec.hrl").

%% Every timestamp of one request, in the runner's process dictionary. The
%% runner is spawned per request and dies with it, so there is nothing to clear
%% between requests and nothing to leak into the next one.
-define(MARKS, {?MODULE, marks}).
-define(STASH, {?MODULE, instance}).
-define(CALLS, {?MODULE, classify_calls}).

-define(MODES, [timing, floor, gc, census, calibrate]).

%%% ------------------------------------------------------------- artifact ---

artifact(Opts) ->
    Under = maps:get(under, Opts),
    Mode = mode_of(Opts),
    Delay = maps:get(calibrate, Opts, none),
    case Under:artifact(Opts) of
        {ok, Inner} ->
            {ok, #{under => Under, mode => Mode, delay => Delay,
                   inner => Inner}};
        {error, _} = E ->
            E
    end.

%% A mode is named or it is `timing'. `calibrate' is not reachable by accident:
%% it needs both the mode and a `{Callback, Millis}' to inject, so a command
%% that produces a number cannot select it by fumbling one option.
mode_of(Opts) ->
    case maps:get(mode, Opts, timing) of
        M when is_atom(M) ->
            lists:member(M, ?MODES) orelse erlang:error({bad_mode, M}),
            M =:= calibrate andalso
                (is_tuple(maps:get(calibrate, Opts, none)) orelse
                 erlang:error(calibrate_without_injection)),
            M
    end.

%%% ------------------------------------------------------------ callbacks ---

requirements(Request, #{under := Under, inner := Inner} = A) ->
    %% First callback in the runner, so this is where the vector starts and
    %% where the sample gets its identity. A `make_ref()' rather than anything
    %% taken from the request: adding a field to the request would change the
    %% workload and fall outside the request hash, and adding the runner's pid
    %% would put a pid in a mode that promises not to carry one.
    put(?MARKS, #{ref => make_ref(), t1 => now_us()}),
    put(?CALLS, 0),
    R = under(A, requirements, fun() -> Under:requirements(Request, Inner) end),
    mark(t2),
    R.

prepare(Request, #{under := Under, inner := Inner} = A, Env) ->
    mark(t3),
    R = under(A, prepare, fun() -> Under:prepare(Request, Inner, Env) end),
    mark(t4),
    %% The state has to carry the artifact: `classify/2' and `decode/2' are
    %% given a state and never an artifact, and the census needs to know which
    %% mode it is in from inside them.
    case R of
        {ok, Spec, State} -> {ok, Spec, {?MODULE, A, State}};
        {error, E, State} -> {error, E, {?MODULE, A, State}};
        Other             -> Other
    end.

classify(IR, {?MODULE, #{under := Under} = A, State}) ->
    mark(t7),
    put(?CALLS, get(?CALLS) + 1),
    try
        %% The census runs here and nowhere else. The instance is alive until
        %% the destroy that follows this call, and `wasm_instance:forget_ir/1'
        %% erases exactly the keys it reads.
        census(A),
        under(A, classify, fun() -> Under:classify(IR, State) end)
    after
        erase(?STASH),
        mark(t8)
    end.

decode(Result, {?MODULE, #{under := Under} = A, State}) ->
    mark(t9),
    undefined = get(?STASH),                      % never past `classify/2'
    Out = under(A, decode, fun() -> Under:decode(Result, State) end),
    mark(t10),
    attach(A, Out).

%% Runs in the reaper's cleanup job, which is a different process: whatever the
%% wrapper put in the dictionary died with the runner.
cleanup({?MODULE, #{under := Under}, State}) -> Under:cleanup(State).

capabilities(#{under := Under, inner := Inner}) -> Under:capabilities(Inner).

conformance_fixtures(#{under := Under, inner := Inner}) ->
    Under:conformance_fixtures(Inner).

%%% ------------------------------------------------------------- snapshot ---

%% The `post_restore' fun is the only boundary the kernel does not reach
%% through a callback, and it is the one that brackets the restore. Wrapping
%% the fun is what makes T5 and T6 exist at all.
snapshot_capability(#{under := Under, inner := Inner} = A) ->
    case erlang:function_exported(Under, snapshot_capability, 1) of
        false ->
            unsupported;
        true ->
            case Under:snapshot_capability(Inner) of
                unsupported ->
                    unsupported;
                #{post_restore := F} = Cap ->
                    Cap#{post_restore => fun(Inst, Ctx) ->
                                             wrapped_restore(A, F, Inst, Ctx)
                                         end}
            end
    end.

wrapped_restore(#{mode := Mode} = A, F, Inst, Ctx) ->
    mark(t5),
    R = under(A, post_restore, fun() -> F(Inst, Ctx) end),
    %% Stashed only in `census' mode, and only when the restore was accepted:
    %% a refused one destroys the instance, and holding it would keep a live
    %% set the runner is supposed to have dropped.
    case {Mode, R} of
        {census, ok} -> put(?STASH, Inst);
        _            -> ok
    end,
    mark(t6),
    R.

%%% --------------------------------------------------------------- census ---

%% Which of the functions this request actually ran the compiled tier could
%% take. `wasm_instance:executed/1' answers the reached set from this process's
%% own dictionary, which is what `wasm_jit:wanted/2' builds a unit from, and
%% `wasm_core:can_compile/2' is the same verdict the tier reaches at run time.
%%
%% It is a census and not an attribution: the indices carry no entry counts and
%% no instruction weights, so this says which reached functions are ineligible
%% and cannot say how much of the execution they are.
census(#{mode := census}) ->
    Inst = get(?STASH),
    Inst =/= undefined orelse erlang:error(census_without_instance),
    Executed = wasm_instance:executed(Inst),
    Executed =/= [] orelse erlang:error(census_reached_nothing),
    put(?MARKS, maps:put(census, tally(Executed, Inst), get(?MARKS))),
    ok;
census(_A) ->
    ok.

%% Indices matched against `#fn.idx' and not against a position in the tuple,
%% which is how `wasm_jit:unit/2' selects the same set: the tuple holds imports
%% too, so a position is not an index.
%%
%% Disjoint and exhaustive over every matched index, and an index that matches
%% no function is an error rather than a row: a census that quietly matched
%% nothing would read as a clean answer.
tally(Executed, #inst{funcs = Funcs} = Inst) ->
    Fns = maps:from_list([{F#fn.idx, F} || F <- tuple_to_list(Funcs),
                                           is_record(F, fn)]),
    lists:foldl(
      fun(Idx, Acc) ->
          Fn = maps:get(Idx, Fns, undefined),
          Fn =/= undefined orelse erlang:error({census_unknown_index, Idx}),
          IR = wasm_instance:compiler_ir(Fn, Inst),
          case wasm_core:can_compile(Fn, IR) of
              {ok, _} ->
                  bump(ok, Acc);
              {unsupported, I} ->
                  note(unsupported, key(I), Idx, bump(unsupported, Acc));
              {limit, R} ->
                  note(limit, R, Idx, bump(limit, Acc))
          end
      end,
      #{reached => length(Executed), ok => 0, unsupported => 0, limit => 0,
        why => #{}},
      Executed).

bump(K, Acc) -> maps:update_with(K, fun(N) -> N + 1 end, Acc).

%% Bounded on purpose: the reason histogram is the finding and the index list
%% is a candidate list, so it keeps the first few of each rather than every
%% index of a guest with eleven thousand functions.
note(Class, Reason, Idx, Acc) ->
    Why = maps:get(why, Acc),
    Key = {Class, Reason},
    {N, Some} = maps:get(Key, Why, {0, []}),
    Kept = case length(Some) < 8 of
               true  -> Some ++ [Idx];
               false -> Some
           end,
    maps:put(why, maps:put(Key, {N + 1, Kept}, Why), Acc).

key(I) when is_tuple(I) -> element(1, I);
key(I) when is_atom(I)  -> I.

%%% ---------------------------------------------------------------- marks ---

now_us() -> erlang:monotonic_time(microsecond).

mark(K) -> put(?MARKS, maps:put(K, now_us(), get(?MARKS))).

%% The injected sleep, and the only place it can happen. `calibrate' names one
%% callback, so a delay that shows up in a second interval is a boundary wired
%% to the wrong phase, which is the whole reason this exists.
under(#{mode := calibrate, delay := {Which, Ms}}, Which, F) ->
    timer:sleep(Ms),
    F();
under(_A, _Which, F) ->
    F().

%% What rides out with the reply. `timing' carries the vector and the
%% reference; every other mode adds exactly what it is for.
attach(#{mode := Mode}, {ok, Map}) when is_map(Map) ->
    {ok, maps:put('$phases', payload(Mode, get(?MARKS)), Map)};
attach(_A, Other) ->
    %% An error outcome is not a sample. It fails validation and the arm stops,
    %% which is the point: a failed request is faster than a working one.
    Other.

payload(Mode, Marks) ->
    Vector = maps:with([ref, t1, t2, t3, t4, t5, t6, t7, t8, t9, t10], Marks),
    Census = maps:with([census], Marks),
    maps:merge(maps:merge(Vector, Census),
               (extra(Mode))#{mode => Mode,
                              classify_calls => get(?CALLS)}).

%% `process_info/2' allocates and enlarges the reply, and a stashed pid is a
%% term the timed mode promises not to carry. Each is here because its own mode
%% asked for it, and nowhere else.
extra(floor) ->
    {garbage_collection, GC} = process_info(self(), garbage_collection),
    #{gc => maps:from_list(GC)};
extra(gc) ->
    #{runner => self()};
extra(_) ->
    #{}.
