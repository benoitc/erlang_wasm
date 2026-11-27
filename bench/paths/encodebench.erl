-module(encodebench).
-moduledoc """
What encoding a module costs, next to what decoding it costs.

Use this for a change to `wasm_encode` or the opcode-space encoders. One
launch reads a `.wasm` file, compiles it once with `wasm:compile/1`, and then
times, each in a fresh process and in the order given:

- `decode`: `wasm_decode:module/1` on the file's bytes, the decoder alone;
- `encode`: `wasm:encode/1` on the compiled module, which is what a caller
  holding a module calls, the stripping of the validator's annotations
  included;
- `encode_decoded`: `wasm_encode:module/1` on the decoded record, the encoder
  alone.

    rebar3 compile
    erlc -o bench/paths -pa _build/default/lib/wasm/ebin bench/paths/encodebench.erl
    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run encodebench main test/fixtures/lang/qjs.wasm 5 decode_first

`ROUNDS` rounds are run and the lowest of each is printed, in microseconds,
with the 5-minute load average at both ends and the size of the encoded
bytes. `decode_first` or `encode_first` says which is timed first in each
round; run both, in fresh emulators, alternately.
""".
-export([main/1]).

-include_lib("wasm/include/wasm.hrl").

main([File, Rounds0, Order]) ->
    L0 = load(),
    {ok, Bin} = file:read_file(File),
    {ok, Compiled} = wasm:compile(Bin),
    {ok, Decoded} = wasm_decode:module(Bin),
    {ok, Encoded} = wasm:encode(Compiled),
    %% The same bytes from either record, or the timings measure two things.
    {ok, Encoded} = wasm_encode:module(Decoded),
    Arms = case Order of
               "decode_first" -> [decode, encode, encode_decoded];
               "encode_first" -> [encode, encode_decoded, decode]
           end,
    Work = #{decode => fun() -> {ok, _} = wasm_decode:module(Bin) end,
             encode => fun() -> {ok, _} = wasm:encode(Compiled) end,
             encode_decoded => fun() -> {ok, _} = wasm_encode:module(Decoded) end},
    Rounds = list_to_integer(Rounds0),
    Times = [[{A, timed(maps:get(A, Work))} || A <- Arms]
             || _ <- lists:seq(1, Rounds)],
    Min = maps:from_list([{A, lists:min([T || R <- Times, {A2, T} <- R, A2 =:= A])}
                          || A <- Arms]),
    io:format("~p.~n", [Min#{file => list_to_binary(filename:basename(File)),
                             order => list_to_atom(Order),
                             bytes_in => byte_size(Bin),
                             bytes_out => byte_size(Encoded),
                             load_start => L0, load_end => load()}]),
    erlang:halt(0).

%% One call in a process of its own, so no call inherits another's heap.
timed(Fun) ->
    Self = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        T0 = erlang:monotonic_time(),
        Fun(),
        T1 = erlang:monotonic_time(),
        Self ! {self(), T1 - T0}
    end),
    receive
        {Pid, T} ->
            demonitor(Ref, [flush]),
            erlang:convert_time_unit(T, native, microsecond);
        {'DOWN', Ref, process, Pid, Why} ->
            erlang:error({round_died, Why})
    end.

%% The 5-minute load average: `sysctl' prints `{ 1min 5min 15min }'.
load() ->
    [_, L | _] = string:lexemes(os:cmd("sysctl -n vm.loadavg"), " {}"),
    list_to_float(L).
