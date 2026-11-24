-module(listbench).
-moduledoc """
What passing a `list<u32>` to a component and back costs.

Use this for a change to how `wasm_canon` lifts or lowers lists. It calls the
`echo-list-u32` export of the vectors fixture, which takes a list and returns
it, so one call lowers the list into the guest and lifts it back out:

    rebar3 compile
    erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/listbench.erl
    ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \\
        -run listbench main time 4096 5
    ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \\
        -run listbench main count 4096

`time N ROUNDS` makes one round trip of an `N`-element list per round, each in
a fresh process, checks the answer, and prints the lowest of the rounds in
microseconds with the 5-minute load average at the start and the end. `count
N` makes one round trip with `wasm:read_memory/3` and `wasm:write_memory/3`
call-counted: a read of exactly eight bytes is the result's pointer and
length, everything else is list data. That holds for any list but one of two
elements, whose data is eight bytes too.
""".
-export([main/1]).

-define(EXPORT, <<"echo-list-u32">>).
-define(SIG, {[{list, u32}], {list, u32}}).

main(["time", N0, Rounds0]) ->
    L0 = load(),
    N = list_to_integer(N0),
    Inst = instance(),
    List = list(N),
    Us = [one_round(Inst, List) || _ <- lists:seq(1, list_to_integer(Rounds0))],
    report(#{n => N, round_us => lists:min(Us), load_start => L0});
main(["count", N0]) ->
    N = list_to_integer(N0),
    Inst = instance(),
    List = list(N),
    Self = self(),
    Tracer = spawn(fun() -> tally(Self, #{}) end),
    [1 = erlang:trace_pattern(MFA, true, [global])
     || MFA <- [{wasm, read_memory, 3}, {wasm, write_memory, 3}]],
    _ = erlang:trace(self(), true, [call, {tracer, Tracer}]),
    {ok, List} = wasm_component:call(Inst, ?EXPORT, ?SIG, [List]),
    _ = erlang:trace(self(), false, [call]),
    Ref = erlang:trace_delivered(self()),
    receive {trace_delivered, _, Ref} -> ok end,
    Tracer ! {done, self()},
    report(receive {tally, T} -> T#{n => N} end).

report(R) ->
    io:format("~p.~n", [R#{load_end => load()}]),
    erlang:halt(0).

%% The 5-minute load average: `sysctl' prints `{ 1min 5min 15min }'.
load() ->
    [_, L | _] = string:lexemes(os:cmd("sysctl -n vm.loadavg"), " {}"),
    list_to_float(L).

instance() ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(filename:join(["test", "fixtures", "component",
                                              "vectors.component.wasm"])),
    {ok, Inst} = wasm_component:instantiate(Bin),
    Inst.

%% Values across the whole u32 range, so no encoding is special-cased away.
list(N) -> [(I * 2654435761) band 16#FFFFFFFF || I <- lists:seq(1, N)].

one_round(Inst, List) ->
    Self = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        T0 = erlang:monotonic_time(),
        {ok, List} = wasm_component:call(Inst, ?EXPORT, ?SIG, [List]),
        T1 = erlang:monotonic_time(),
        Self ! {self(), T1 - T0}
    end),
    receive
        {Pid, T} ->
            demonitor(Ref, [flush]),
            erlang:convert_time_unit(T, native, microsecond);
        {'DOWN', Ref, process, Pid, Why} -> erlang:error({round_died, Why})
    end.

tally(Owner, Acc) ->
    receive
        {trace, _, call, {wasm, read_memory, [_, _, 8]}} ->
            tally(Owner, bump(descriptor_reads, Acc));
        {trace, _, call, {wasm, read_memory, [_, _, Len]}} ->
            tally(Owner, bump(data_read_bytes, Len, bump(data_reads, Acc)));
        {trace, _, call, {wasm, write_memory, [_, _, Bin]}} ->
            tally(Owner, bump(write_bytes, byte_size(Bin), bump(writes, Acc)));
        {done, Owner} -> Owner ! {tally, Acc};
        _ -> tally(Owner, Acc)
    end.

bump(K, M) -> bump(K, 1, M).
bump(K, N, M) -> maps:update_with(K, fun(X) -> X + N end, N, M).
