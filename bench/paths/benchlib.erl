-module(benchlib).
-moduledoc """
The two things every arm in this directory needs.

`in_process/1` is not a convenience. Repeating a real module in one process
makes its runs bimodal on collection time, about 1.7 seconds or about 13 for
QuickJS against identical reductions and byte-identical output, so every arm
runs each iteration in a fresh process. It was copied into three tools before it
was here.
""".
-export([in_process/1, in_process/2]).

-doc "Run `F` in a fresh process and answer what it answered.".
-spec in_process(fun(() -> term())) -> term().
in_process(F) -> in_process([], F).

-doc """
As `in_process/1`, carrying the named process-dictionary keys into the child.

A spawned process inherits no dictionary, and the arms keep their options
there. Without this a child instantiates with `undefined` options and the arm
dies, which is the better failure but still a failure.
""".
-spec in_process([atom()], fun(() -> term())) -> term().
in_process(Keys, F) ->
    Self = self(),
    Ref = make_ref(),
    Carried = [{K, get(K)} || K <- Keys],
    {P, Mon} = spawn_monitor(fun() ->
                                     [put(K, V) || {K, V} <- Carried],
                                     Self ! {Ref, F()}
                             end),
    receive
        {Ref, R} -> demonitor(Mon, [flush]), R;
        {'DOWN', Mon, process, P, Why} -> erlang:error({run_died, Why})
    end.
