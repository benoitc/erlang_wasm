-module(copybench).
-moduledoc """
What one `memory.copy` costs, by direction and alignment.

Use this for a change to `wasm_memory:copy/4`. One launch copies `LEN` bytes
from `SRC` to `DST` in a three-page memory filled with a pattern, once per
round in a fresh process, checks the result against the same copy made on a
binary, and prints the lowest time and the reductions of that round:

    rebar3 compile
    erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/copybench.erl
    ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \\
        -run copybench main 8 0 65536 5

`8 0 65536` overlaps from above with the two aligned alike, `65537 0 65536`
is clear of the source and aligned differently, `65536 0 65536` is the
aligned forward copy every other case is compared with.
""".
-export([main/1]).

main([D0, S0, L0, Rounds]) ->
    L5 = load(),
    {ok, _} = application:ensure_all_started(wasm),
    [D, S, Len] = [list_to_integer(X) || X <- [D0, S0, L0]],
    Rs = [one(D, S, Len) || _ <- lists:seq(1, list_to_integer(Rounds))],
    {Us, Reds} = lists:min(Rs),
    io:format("~p.~n", [#{dst => D, src => S, len => Len, copy_us => Us,
                          reductions => Reds, load_start => L5,
                          load_end => load()}]),
    halt().

%% The 5-minute load average: `sysctl' prints `{ 1min 5min 15min }'.
load() ->
    [_, L | _] = string:lexemes(os:cmd("sysctl -n vm.loadavg"), " {}"),
    list_to_float(L).

one(D, S, Len) ->
    Self = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        {ok, M} = wasm_memory:new(3),
        Bin = binary:copy(list_to_binary(lists:seq(0, 250)), 784),
        Pattern = binary:part(Bin, 0, 3 * 65536),
        ok = wasm_memory:store_bytes(M, 0, Pattern),
        R0 = reds(),
        T0 = erlang:monotonic_time(),
        ok = wasm_memory:copy(M, D, S, Len),
        T1 = erlang:monotonic_time(),
        R1 = reds(),
        Want = binary:part(Pattern, S, Len),
        Want = wasm_memory:load_bytes(M, D, Len),
        ok = wasm_memory:free(M),
        Self ! {self(), erlang:convert_time_unit(T1 - T0, native, microsecond),
                R1 - R0}
    end),
    receive
        {Pid, Us, Reds} -> demonitor(Ref, [flush]), {Us, Reds};
        {'DOWN', Ref, process, Pid, Why} -> erlang:error({copy_died, Why})
    end.

reds() -> element(2, process_info(self(), reductions)).
