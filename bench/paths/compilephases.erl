-module(compilephases).
-moduledoc """
What `wasm:compile/1` costs on a real guest, in total and phase by phase.

Use this to price a change to `wasm_decode` or `wasm_validate`. One launch
measures one guest on one build:

    rebar3 compile
    erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/compilephases.erl
    ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \\
        -run compilephases main time qjs 5
    ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \\
        -run compilephases main peak qjs
    ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \\
        -run compilephases main alloc python

`time` makes one complete `wasm:compile/1` call per round, in a fresh
process, so the heap policy `wasm:compile/1` applies is part of what is
timed. The decode and validation times come from that same call: the call and
return of `wasm_decode:module/1` and `wasm_validate:module/1` are traced with
timestamps. It prints the round with the lowest total, with that round's own
phases, never minima taken from different rounds.

`peak` makes one call with the compiling process's collections traced and
prints the largest heap, young and old together, it held at any of them, in
words.

`alloc` prints the words each phase allocates when called directly, from
`tprof`'s `call_memory` with only a wrapper around the phase traced, so the
count includes everything it calls. Tracing a helper as well would move its
words out of the wrapper's count, which is why per-helper counts never come
from this mode.

The guests are `qjs` (`test/fixtures/lang/qjs.wasm`) and `python`
(`test/fixtures/lang/python.wasm`). Compare two builds with fresh launches,
interleaved, as `docs/contributing/measuring.md` describes.

An earlier version of `time` called the two phases directly. That skips the
heap floor `wasm:compile/1` sets for any module over 16 KiB, and it reported a
validation slowdown that the public call does not have.
""".
-export([main/1, decode/1, validate/1]).

-define(PHASES, [{wasm_decode, module, 1}, {wasm_validate, module, 1}]).

main(["time", Guest, Rounds]) ->
    L0 = load(),
    Bin = fixture(Guest),
    trace_phases(),
    Rs = [one_round(Bin) || _ <- lists:seq(1, list_to_integer(Rounds))],
    {Total, Decode, Validate} = lists:min(Rs),
    report(#{guest => Guest, load_start => L0, total_us => Total,
             decode_us => Decode, validate_us => Validate});
main(["peak", Guest]) ->
    report(#{guest => Guest, peak_heap_words => peak(fixture(Guest))});
main(["alloc", Guest]) ->
    Bin = fixture(Guest),
    {ok, M} = wasm_decode:module(Bin),
    report(#{guest => Guest,
             decode_words => words(decode, fun() -> ?MODULE:decode(Bin) end),
             validate_words => words(validate,
                                     fun() -> ?MODULE:validate(M) end)}).

%% The traced entries for `alloc'. Each calls its phase in a position that is
%% not a tail call, so the phase's whole run, callees included, is charged to
%% it: `wasm_validate:module/1' tail-calls its worker, and tracing it directly
%% charges nothing at all.
decode(Bin) ->
    {ok, _} = R = wasm_decode:module(Bin),
    R.

validate(M) ->
    {ok, _} = R = wasm_validate:module(M),
    R.

report(R) ->
    io:format("~p.~n", [R#{load_end => load()}]),
    erlang:halt(0).

%% The 5-minute load average: `sysctl' prints `{ 1min 5min 15min }'. macOS
%% only, as the harness that drives this is.
load() ->
    [_, L | _] = string:lexemes(os:cmd("sysctl -n vm.loadavg"), " {}"),
    list_to_float(L).

fixture(Guest) ->
    {ok, B} = file:read_file(filename:join(["test", "fixtures", "lang",
                                            Guest ++ ".wasm"])),
    B.

%%% -------------------------------------------------------------- time ---

%% `return_trace' keeps the phase's frame, so a phase that tail-calls its
%% worker still reports its return.
trace_phases() ->
    [{module, _} = code:ensure_loaded(M) || {M, _, _} <- ?PHASES],
    [1 = erlang:trace_pattern(MFA, [{'_', [], [{return_trace}]}], [global])
     || MFA <- ?PHASES],
    ok.

%% One `wasm:compile/1' call in a process of its own, so no round inherits
%% another's heap. Answers {Total, Decode, Validate} in microseconds.
one_round(Bin) ->
    Self = self(),
    Tracer = spawn(fun() -> stamps(#{}) end),
    {Pid, Ref} = spawn_monitor(fun() ->
        receive go -> ok end,
        T0 = erlang:monotonic_time(),
        {ok, _} = wasm:compile(Bin),
        T1 = erlang:monotonic_time(),
        Self ! {self(), T1 - T0}
    end),
    _ = erlang:trace(Pid, true, [call, monotonic_timestamp,
                                 {tracer, Tracer}]),
    Pid ! go,
    Total = receive
                {Pid, T} -> demonitor(Ref, [flush]), T;
                {'DOWN', Ref, process, Pid, Why} ->
                    erlang:error({round_died, Why})
            end,
    Delivered = erlang:trace_delivered(Pid),
    receive {trace_delivered, Pid, Delivered} -> ok end,
    Tracer ! {done, self()},
    #{{wasm_decode, module, 1} := D, {wasm_validate, module, 1} := V} =
        receive {stamps, S} -> S end,
    {us(Total), us(D), us(V)}.

%% Call and return timestamps per phase, turned into a duration on return.
stamps(Acc) ->
    receive
        {trace_ts, _, call, {M, F, Args}, Ts} ->
            stamps(Acc#{{M, F, length(Args)} => {start, Ts}});
        {trace_ts, _, return_from, MFA, _, Ts} ->
            {start, T0} = maps:get(MFA, Acc),
            stamps(Acc#{MFA => Ts - T0});
        {done, Owner} -> Owner ! {stamps, Acc};
        _ -> stamps(Acc)
    end.

us(T) -> erlang:convert_time_unit(T, native, microsecond).

%%% -------------------------------------------------------------- peak ---

%% The largest heap the compiling process held at the end of any collection
%% during the call: young plus old heap block sizes, in words.
peak(Bin) ->
    Self = self(),
    Tracer = spawn(fun() -> heaps(0) end),
    {Pid, Ref} = spawn_monitor(fun() ->
        receive go -> ok end,
        {ok, _} = wasm:compile(Bin),
        Self ! {self(), done}
    end),
    _ = erlang:trace(Pid, true, [garbage_collection, {tracer, Tracer}]),
    Pid ! go,
    receive
        {Pid, done} -> demonitor(Ref, [flush]);
        {'DOWN', Ref, process, Pid, Why} -> erlang:error({peak_died, Why})
    end,
    Delivered = erlang:trace_delivered(Pid),
    receive {trace_delivered, Pid, Delivered} -> ok end,
    Tracer ! {done, self()},
    receive {peak, P} -> P end.

heaps(Max) ->
    receive
        {trace, _, Event, Info} when Event =:= gc_minor_end;
                                     Event =:= gc_major_end ->
            Words = proplists:get_value(heap_block_size, Info, 0)
                + proplists:get_value(old_heap_block_size, Info, 0),
            heaps(max(Max, Words));
        {done, Owner} -> Owner ! {peak, Max};
        _ -> heaps(Max)
    end.

%%% ------------------------------------------------------------- alloc ---

words(Phase, F) ->
    {_, Raw} = tprof:profile(F, #{type => call_memory,
                                  pattern => [{?MODULE, Phase, 1}],
                                  report => return}),
    #{all := {call_memory, Total, _}} = tprof:inspect(Raw, total, measurement),
    Total.
