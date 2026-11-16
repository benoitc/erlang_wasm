#!/usr/bin/env escript
%% Rewrite, in a component binary, each canon section holding exactly one
%% `stream.drop-readable' (0x13) or `future.drop-readable' (0x1a) into the same
%% section with `stream.forward' (0x2e) or `future.forward' (0x2f), which have
%% the same operand. wasm-tools cannot write the forwards yet; the fixture's
%% text puts each placeholder alone in its section, so nothing else changes.
%% Usage: forward-opcodes.escript File
main([File]) ->
    {ok, <<Pre:8/binary, Secs/binary>>} = file:read_file(File),
    {Out, N} = walk(Secs, <<>>, 0),
    2 = N,
    ok = file:write_file(File, <<Pre/binary, Out/binary>>).

walk(<<>>, Acc, N) -> {Acc, N};
walk(<<Id, Rest0/binary>>, Acc, N) ->
    {Size, Rest1} = leb(Rest0, 0, 0),
    <<Content:Size/binary, Rest/binary>> = Rest1,
    {Content1, N1} = case {Id, Content} of
                         {8, <<1, 16#13, T>>} when T < 128 -> {<<1, 16#2E, T>>, N + 1};
                         {8, <<1, 16#1A, T>>} when T < 128 -> {<<1, 16#2F, T>>, N + 1};
                         _ -> {Content, N}
                     end,
    walk(Rest, <<Acc/binary, Id, (enc(Size))/binary, Content1/binary>>, N1).

leb(<<B, R/binary>>, Shift, V) when B < 128 -> {V bor (B bsl Shift), R};
leb(<<B, R/binary>>, Shift, V) -> leb(R, Shift + 7, V bor ((B band 127) bsl Shift)).

enc(V) when V < 128 -> <<V>>;
enc(V) -> <<(V band 127 bor 128), (enc(V bsr 7))/binary>>.
