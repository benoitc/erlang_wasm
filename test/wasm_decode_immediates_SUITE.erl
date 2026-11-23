%% @doc The instructions whose one-byte immediates the decoder reads inline.
%%
%% For each, every encoding of interest is decoded through
%% `wasm_decode_code:instrs/1' and compared with what the general readers in
%% `wasm_leb128' give for the same bytes: the one-byte values at the edges of
%% their range, a two-byte value, a needlessly long encoding of a small value,
%% and a truncated one. A fast clause that disagrees with the general reader on
%% any of them, in value or in error, fails here.
-module(wasm_decode_immediates_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() -> [indices, signed_constant, memory_arguments].

%% Unsigned: an index or a branch depth.
indices(_Config) ->
    [unsigned(Byte, Name) || {Byte, Name} <- [{16#20, local_get},
                                               {16#21, local_set},
                                               {16#22, local_tee},
                                               {16#0D, br_if}]].

unsigned(Byte, Name) ->
    [?assertEqual({Byte, Imm, expect(fun wasm_leb128:u32/1, Imm, Name)},
                  {Byte, Imm, decode(<<Byte, Imm/binary, 16#0B>>)})
     || Imm <- [<<0>>, <<16#3F>>, <<16#40>>, <<16#7F>>, <<16#80, 16#01>>,
                <<16#80, 16#00>>, <<16#FF, 16#FF, 16#FF, 16#FF, 16#0F>>]],
    ?assertEqual({Byte, truncated, leb(u32, <<16#80>>)},
                 {Byte, truncated, dec(<<Byte, 16#80>>)}).

%% Signed: bit 6 of a one-byte encoding is the sign.
signed_constant(_Config) ->
    ?assertEqual([{i32_const, -64}], decode(<<16#41, 16#40, 16#0B>>)),
    ?assertEqual([{i32_const, -1}], decode(<<16#41, 16#7F, 16#0B>>)),
    ?assertEqual([{i32_const, 63}], decode(<<16#41, 16#3F, 16#0B>>)),
    [?assertEqual({Imm, expect(fun wasm_leb128:s32/1, Imm, i32_const)},
                  {Imm, decode(<<16#41, Imm/binary, 16#0B>>)})
     || Imm <- [<<0>>, <<16#3F>>, <<16#40>>, <<16#7F>>, <<16#C0, 16#00>>,
                <<16#FF, 16#7F>>, <<16#80, 16#80, 16#80, 16#80, 16#78>>]],
    ?assertEqual(leb(s32, <<16#C0>>), dec(<<16#41, 16#C0>>)).

%% Flags then offset. The inline clause takes both as one byte with no memory
%% index; everything else must decode as `mem_arg/2' does.
memory_arguments(_Config) ->
    [memarg(Byte, Op) || {Byte, Op} <- [{16#28, i32_load}, {16#36, i32_store}]].

memarg(Byte, Op) ->
    Cases = [{<<2, 0>>, {2, 0, 0}},
             {<<0, 16#7F>>, {0, 127, 0}},
             {<<16#3F, 5>>, {63, 5, 0}},
             {<<2, 16#80, 16#01>>, {2, 128, 0}},
             {<<16#82, 16#00, 4>>, {2, 4, 0}},
             {<<16#42, 1, 8>>, {2, 8, 1}}],
    [?assertEqual({Byte, Imm, [{Op, Arg}]},
                  {Byte, Imm, decode(<<Byte, Imm/binary, 16#0B>>)})
     || {Imm, Arg} <- Cases],
    %% Flags of 128 and above are malformed, as before.
    ?assertMatch({throw, {error, #{kind := malformed_memop_flags}}},
                 dec(<<Byte, 16#80, 16#01, 0, 16#0B>>)),
    %% A flags byte with no offset after it.
    ?assertEqual(leb(u64, <<>>), dec(<<Byte, 2>>)).

%%% ------------------------------------------------------------- helpers ---

decode(Bin) ->
    {Is, end_, <<>>} = wasm_decode_code:instrs(Bin),
    Is.

%% The instruction the general reader says these bytes hold.
expect(Read, Imm, Name) ->
    {V, <<>>} = Read(Imm),
    [{Name, V}].

%% What the general reader, or the whole decoder, answers or raises for these
%% bytes, as a value, so the two can be compared.
leb(Read, Bin) -> raised(fun() -> wasm_leb128:Read(Bin) end).

dec(Bin) -> raised(fun() -> wasm_decode_code:instrs(Bin) end).

%% Whatever a decode raises, as a value, so two can be compared.
raised(F) ->
    try F() of
        R -> {returned, R}
    catch
        Class:Reason -> {Class, normalise(Reason)}
    end.

normalise({wasm_error, E}) -> {error, E};
normalise(#{kind := _} = E) -> {error, E};
normalise(R) -> R.
