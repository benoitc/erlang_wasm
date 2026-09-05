-module(allocwords).
-moduledoc """
How many heap words one process allocated, from its own collection trace.

Use this instead of `erlang:statistics(garbage_collection)` for any question
about a single process. That counter is node-wide: it reported no change from a
`min_heap_size` floor while the process's own collections fell 51x, which is
what sent an investigation down the wrong path for an afternoon.

There is no per-process allocated-words counter, so this derives one. A
`gc_minor_end` or `gc_major_end` event carries `wordsize`, the memory that
collection reclaimed, so over a window bounded by a forced major at each end:

    reclaimed = sum of `wordsize' over the end events inside the window
    allocated = reclaimed + ending live words - starting live words

with live words being `heap_size' + `old_heap_size'. The opening major is the
boundary and is excluded, since what it reclaims belongs to whatever ran before;
the closing one is included.

Not by differencing consecutive `heap_size' values, which was the first draft
and is wrong: it miscounts heap fragments, message buffers and generational
movement, and a simple-list calibration passes anyway. `validate/0` is what
says the estimator works, in both of the forms it has to get right, and it
should be run on any machine before the numbers here are believed.

    erlc -o bench/paths bench/paths/allocwords.erl
    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run allocwords main
""".

-export([measure/1, measure/2, measure/3, validate/0, main/1]).

%% Timestamped, because a run's GC *time* is the number the plan gates on and
%% no counter carries it. Collections do not nest in one process, so a start
%% and the end after it are one collection.
-define(FLAGS, [garbage_collection, monotonic_timestamp]).

-doc "Run `F' in a fresh process and report what it allocated.".
-spec measure(fun(() -> term())) -> map().
measure(F) -> measure(F, 300000).

-doc """
As `measure/2`, with a setup that runs in the same process and outside the
window.

Some costs can only be moved out of a measurement by doing them first *in the
process that will be measured*: the interpreter's lowered-IR cache is keyed on
the instance and lives in the process dictionary, so pre-lowering has to happen
there. Tracing starts once `Setup` has returned, so nothing it allocates is
counted.
""".
-spec measure(fun(() -> term()), fun((term()) -> term()), timeout()) -> map().
measure(Setup, Body, Timeout) ->
    Parent = self(),
    Pid = spawn(fun() ->
                    receive go -> ok end,
                    S = Setup(),
                    %% Setup is done and untraced; ask for the window now.
                    Parent ! {ready, self()},
                    receive traced -> ok end,
                    erlang:garbage_collect(),
                    R = Body(S),
                    erlang:garbage_collect(),
                    Parent ! {done, self(), R}
                end),
    Pid ! go,
    receive {ready, Pid} -> ok after Timeout -> erlang:error(setup_timeout) end,
    erlang:trace(Pid, true, ?FLAGS),
    Pid ! traced,
    collect(Pid, Timeout).

-spec measure(fun(() -> term()), timeout()) -> map().
measure(F, Timeout) ->
    Parent = self(),
    Pid = spawn(fun() ->
                    receive go -> ok end,
                    %% The opening boundary. Its own event is dropped below.
                    erlang:garbage_collect(),
                    R = F(),
                    %% The closing boundary, with `R' still referenced, so a
                    %% result the caller keeps counts as live and not as
                    %% reclaimed.
                    erlang:garbage_collect(),
                    Parent ! {done, self(), R}
                end),
    erlang:trace(Pid, true, ?FLAGS),
    Pid ! go,
    collect(Pid, Timeout).

collect(Pid, Timeout) ->
    Result = receive {done, Pid, R} -> R
             after Timeout -> erlang:error(measure_timeout)
             end,
    %% Calling `trace_delivered/1' is not the barrier; waiting for its message
    %% is. Draining with `after 0' drops events still in flight.
    Ref = erlang:trace_delivered(Pid),
    receive {trace_delivered, Pid, Ref} -> ok end,
    %% No untrace: the process has already exited, and tracing a dead pid is a
    %% badarg rather than a no-op.
    Events = drain(),
    %% The opening forced major is the boundary in the timing too, not only in
    %% the words: drop its pair before summing.
    report([{K, I} || {K, I, _} <- Events,
                      K =:= gc_minor_end orelse K =:= gc_major_end],
           us(gc_time(drop_pair(Events))), Result).

%% One collection is a start and the end that follows it.
gc_time(Events) -> gc_time(Events, 0).

gc_time([{S, _, T0}, {E, _, T1} | Rest], Acc)
  when (S =:= gc_minor_start orelse S =:= gc_major_start) andalso
       (E =:= gc_minor_end orelse E =:= gc_major_end) ->
    gc_time(Rest, Acc + (T1 - T0));
gc_time([_ | Rest], Acc) -> gc_time(Rest, Acc);
gc_time([], Acc) -> Acc.

drop_pair([_, _ | Rest]) -> Rest;
drop_pair(_) -> [].

us(T) -> erlang:convert_time_unit(T, native, microsecond).

report([], _GcUs, Result) ->
    #{allocated => 0, reclaimed => 0, collections => 0, result => Result,
      note => no_collections};
report([{_, Open} | Rest], GcUs, Result) ->
    Live0 = live(Open),
    Live1 = case Rest of [] -> Live0; _ -> live(element(2, lists:last(Rest))) end,
    Reclaimed = lists:sum([w(I, wordsize) || {_, I} <- Rest]),
    #{allocated => Reclaimed + Live1 - Live0,
      reclaimed => Reclaimed,
      live_before => Live0,
      live_after => Live1,
      collections => length(Rest),
      minor => length([x || {gc_minor_end, _} <- Rest]),
      major => length([x || {gc_major_end, _} <- Rest]),
      gc_us => GcUs,
      %% Zero at both boundaries or the accounting has to explain them.
      mbuf => {w(Open, mbuf_size), case Rest of
                                       [] -> w(Open, mbuf_size);
                                       _ -> w(element(2, lists:last(Rest)),
                                              mbuf_size)
                                   end},
      result => Result}.

live(I) -> w(I, heap_size) + w(I, old_heap_size).

w(Info, Key) -> proplists:get_value(Key, Info, 0).

drain() -> drain([]).

drain(Acc) ->
    receive {trace_ts, _, Kind, Info, Ts} -> drain([{Kind, Info, Ts} | Acc])
    after 0 -> lists:reverse(Acc)
    end.

%%% ---------------------------------------------------------------- proving ---

-doc """
Prove the estimator against a known allocation, in both of its forms.

A list of N cons cells is 2N heap words. Retaining it through the closing
collection exercises the live-set half of the formula; discarding it first
exercises the reclaimed half. Both have to come out at about 2N once the fixed
harness overhead is taken off, because the two halves are only sound together.
""".
-spec validate() -> ok | {error, term()}.
validate() ->
    #{allocated := Overhead} = measure(fun() -> ok end),
    io:format("harness overhead ~w words~n~n", [Overhead]),
    io:format("~10s ~14s ~14s ~10s ~10s~n",
              ["N", "want", "retained", "discarded", "worst"]),
    Rows = [row(N, Overhead) || N <- [100000, 1000000, 4000000]],
    io:format("~n"),
    case [R || {_, _, _, _, Err} = R <- Rows, Err > 0.05] of
        [] -> io:format("estimator agrees within 5%~n"), ok;
        Bad -> io:format("estimator is wrong: ~p~n", [Bad]), {error, Bad}
    end.

row(N, Overhead) ->
    Want = 2 * N,
    %% Returned, so it is still referenced at the closing collection.
    #{allocated := Kept} = measure(fun() -> lists:duplicate(N, 0) end),
    %% Built, summed and dropped, so the closing collection reclaims it.
    #{allocated := Gone} = measure(fun() ->
                                       L = lists:duplicate(N, 0),
                                       lists:sum(L)
                                   end),
    K = Kept - Overhead,
    G = Gone - Overhead,
    Err = lists:max([abs(K - Want) / Want, abs(G - Want) / Want]),
    io:format("~10w ~14w ~14w ~10w ~9.1f%~n", [N, Want, K, G, Err * 100]),
    {N, Want, K, G, Err}.

main(_) ->
    case validate() of
        ok -> init:stop();
        {error, _} -> init:stop(1)
    end.
