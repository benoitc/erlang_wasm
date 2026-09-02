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

-export([measure/1, measure/2, validate/0, main/1]).

-doc "Run `F' in a fresh process and report what it allocated.".
-spec measure(fun(() -> term())) -> map().
measure(F) -> measure(F, 300000).

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
    erlang:trace(Pid, true, [garbage_collection]),
    Pid ! go,
    Result = receive {done, Pid, R} -> R
             after Timeout -> erlang:error(measure_timeout)
             end,
    %% Calling `trace_delivered/1' is not the barrier; waiting for its message
    %% is. Draining with `after 0' drops events still in flight.
    Ref = erlang:trace_delivered(Pid),
    receive {trace_delivered, Pid, Ref} -> ok end,
    %% No untrace: the process has already exited, and tracing a dead pid is a
    %% badarg rather than a no-op.
    Ends = [I || {trace, _, K, I} <- drain(),
                 K =:= gc_minor_end orelse K =:= gc_major_end],
    report(Ends, Result).

report([], Result) ->
    #{allocated => 0, reclaimed => 0, collections => 0, result => Result,
      note => no_collections};
report([Open | Rest], Result) ->
    Live0 = live(Open),
    Live1 = case Rest of [] -> Live0; _ -> live(lists:last(Rest)) end,
    Reclaimed = lists:sum([w(I, wordsize) || I <- Rest]),
    #{allocated => Reclaimed + Live1 - Live0,
      reclaimed => Reclaimed,
      live_before => Live0,
      live_after => Live1,
      collections => length(Rest),
      %% Zero at both boundaries or the accounting has to explain them.
      mbuf => {w(Open, mbuf_size), case Rest of
                                       [] -> w(Open, mbuf_size);
                                       _ -> w(lists:last(Rest), mbuf_size)
                                   end},
      result => Result}.

live(I) -> w(I, heap_size) + w(I, old_heap_size).

w(Info, Key) -> proplists:get_value(Key, Info, 0).

drain() -> drain([]).

drain(Acc) ->
    receive {trace, _, _, _} = T -> drain([T | Acc])
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
