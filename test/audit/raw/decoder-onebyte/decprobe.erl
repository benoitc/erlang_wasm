-module(decprobe).
%% PR B step 0: which opcodes carry the one-byte calls to wasm_leb128:u32/1
%% and s32/1 while a guest is decoded. Untimed.
-export([main/1]).

%% Opcodes whose first immediate is read with u32 (index, depth, memarg flags)
%% or s32 (i32.const).
u32_ops() ->
    [16#08, 16#0C, 16#0D, 16#10, 16#12, 16#14, 16#15, 16#D2, 16#D5, 16#D6,
     16#20, 16#21, 16#22, 16#23, 16#24, 16#25, 16#26 | lists:seq(16#28, 16#3E)].

main([Guest]) ->
    {ok, Bin} = file:read_file(filename:join(["test", "fixtures", "lang",
                                              Guest ++ ".wasm"])),
    Self = self(),
    T = spawn(fun() -> tally(Self, #{}) end),
    [{module, _} = code:ensure_loaded(M) || M <- [wasm_decode_code, wasm_leb128]],
    1 = erlang:trace_pattern({wasm_decode_code, instr, 2}, true, [local]),
    1 = erlang:trace_pattern({wasm_leb128, u32, 1}, true, [global]),
    1 = erlang:trace_pattern({wasm_leb128, s32, 1}, true, [global]),
    {Pid, Ref} = spawn_monitor(fun() ->
        _ = erlang:trace(self(), true, [call, {tracer, T}]),
        {ok, _} = wasm_decode:module(Bin),
        _ = erlang:trace(self(), false, [call])
    end),
    receive {'DOWN', Ref, process, Pid, normal} -> ok end,
    R2 = erlang:trace_delivered(all),
    receive {trace_delivered, all, R2} -> ok end,
    T ! done,
    C = receive {tally, X} -> X end,
    OneU = maps:get({u32, one}, C, 0), OneS = maps:get({s32, one}, C, 0),
    Total = OneU + OneS,
    Ops = lists:reverse(lists:keysort(2, [{Op, N} || {{op, Op}, N} <- maps:to_list(C)])),
    io:format("~p.~n", [#{guest => Guest,
        u32 => {maps:get({u32, all}, C, 0), one_byte, OneU},
        s32 => {maps:get({s32, all}, C, 0), one_byte, OneS},
        by_opcode_one_byte =>
            [{io_lib:format("0x~2.16.0B", [Op]), N, round(1000 * N / Total) / 10}
             || {Op, N} <- lists:sublist(Ops, 15)]}]),
    halt().

tally(Owner, Acc) ->
    receive
        {trace, _, call, {wasm_leb128, F, [B]}} ->
            K = case B of <<0:1, _:7, _/binary>> -> one; _ -> multi end,
            tally(Owner, bump({F, K}, bump({F, all}, Acc)));
        {trace, _, call, {wasm_decode_code, instr, [Op, <<0:1, _:7, _/binary>>]}} ->
            case lists:member(Op, [16#41 | u32_ops()]) of
                true -> tally(Owner, bump({op, Op}, Acc));
                false -> tally(Owner, Acc)
            end;
        done -> Owner ! {tally, Acc};
        _ -> tally(Owner, Acc)
    end.

bump(K, M) -> maps:update_with(K, fun(N) -> N + 1 end, 1, M).
