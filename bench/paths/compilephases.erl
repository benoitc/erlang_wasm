-module(compilephases).
-moduledoc """
What decoding and validating a binary module cost, phase by phase.

Use this to price a change to `wasm_decode` or `wasm_validate` on real
guests. One launch measures one guest on one build:

    rebar3 compile
    erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/compilephases.erl
    ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \\
        -run compilephases main time qjs 5
    ERL_LIBS=_build/default/lib erl -noshell -pa bench/paths \\
        -run compilephases main alloc python

`time` runs decode then validate in a fresh process per round and prints the
minimum of each phase over the rounds, in microseconds. `alloc` prints the
words each whole phase allocates, from `tprof`'s `call_memory` with only a
wrapper around the phase traced, so the count includes everything it calls.
Tracing a helper as well would move its words out of the wrapper's count,
which is why per-helper counts never come from this mode.

The guests are `qjs` (`test/fixtures/lang/qjs.wasm`) and `python`
(`test/fixtures/lang/python.wasm`). Compare two builds with fresh launches,
interleaved, as `docs/contributing/measuring.md` describes.
""".
-export([main/1, decode/1, validate/1]).

main(["time", Guest, Rounds]) ->
    L0 = load(),
    Bin = fixture(Guest),
    Rs = [one_round(Bin) || _ <- lists:seq(1, list_to_integer(Rounds))],
    report(#{guest => Guest, load_start => L0,
             decode_us => lists:min([D || {D, _} <- Rs]),
             validate_us => lists:min([V || {_, V} <- Rs])});
main(["alloc", Guest]) ->
    Bin = fixture(Guest),
    {ok, M} = wasm_decode:module(Bin),
    report(#{guest => Guest,
             decode_words => words(decode, fun() -> ?MODULE:decode(Bin) end),
             validate_words => words(validate,
                                     fun() -> ?MODULE:validate(M) end)}).

%% The traced entries. Each calls its phase in a position that is not a tail
%% call, so the phase's whole run, callees included, is charged to it:
%% `wasm_validate:module/1' tail-calls its worker, and tracing it directly
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

%% Both phases in a process of their own, so no round inherits another's heap.
one_round(Bin) ->
    Self = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        T0 = erlang:monotonic_time(),
        {ok, M} = wasm_decode:module(Bin),
        T1 = erlang:monotonic_time(),
        {ok, _} = wasm_validate:module(M),
        T2 = erlang:monotonic_time(),
        Self ! {self(), us(T1 - T0), us(T2 - T1)}
    end),
    receive
        {Pid, D, V} -> demonitor(Ref, [flush]), {D, V};
        {'DOWN', Ref, process, Pid, Why} -> erlang:error({round_died, Why})
    end.

us(T) -> erlang:convert_time_unit(T, native, microsecond).

words(Phase, F) ->
    {_, Raw} = tprof:profile(F, #{type => call_memory,
                                  pattern => [{?MODULE, Phase, 1}],
                                  report => return}),
    #{all := {call_memory, Total, _}} = tprof:inspect(Raw, total, measurement),
    Total.
