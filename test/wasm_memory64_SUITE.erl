%% @doc memory64: the rules that are easy to get wrong, each named.
%%
%% Like `wasm_num_SUITE', this duplicates coverage the specification fixtures
%% already give. That is deliberate. The fixtures are generated, not checked in,
%% so a fresh clone skips them entirely; and when they do run they say *what*
%% broke, not why the code is shaped the way it is. Every case here is a rule
%% that was got wrong once while implementing the proposal.
-module(wasm_memory64_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("wasm/include/wasm.hrl").

all() ->
    [limits_flags_are_a_bit_set,
     addresses_above_4gb_trap_instead_of_wrapping,
     memory_size_and_grow_are_i64,
     table_grow_stops_at_the_declared_maximum,
     an_i32_memory_does_not_satisfy_an_i64_import,
     bulk_operand_types_follow_the_memory,
     memory_copy_works_between_two_memories,
     a_zero_length_copy_between_memories_still_checks_bounds].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

%%% ------------------------------------------------------------------ rule ---

%% The limits flags byte is a *bit set*, not an enumeration of whole bytes.
%%
%% Bit 0 is "has maximum", bit 1 is "shared" and bit 2 is "64-bit index type",
%% so a 64-bit memory with a maximum encodes as 0x05. Matching whole bytes
%% happened to work while only 0x00 and 0x01 existed and silently rejected every
%% memory64 module the moment bit 2 appeared.
limits_flags_are_a_bit_set(_Config) ->
    Cases = [{16#00, i32, undefined},
             {16#01, i32, 7},
             {16#04, i64, undefined},
             {16#05, i64, 7}],
    [begin
         Mem = memory_section(Flags, 1, Max),
         {ok, #module{mems = [#memtype{limits = L}]}} = wasm_decode:module(Mem),
         ?assertEqual(IdxType, L#limits.index_type),
         ?assertEqual(Max, L#limits.max),
         ?assertEqual(1, L#limits.min)
     end || {Flags, IdxType, Max} <- Cases].

%% An address that does not fit in 32 bits must be carried through as-is.
%%
%% The interpreter used to narrow every effective address with `to_u32/1'. On a
%% 64-bit memory that turns 2^32 into 0, so an access far past the end of a
%% one-page memory read byte zero and returned a value instead of trapping. This
%% is the whole point of the proposal being more than a decoder change.
addresses_above_4gb_trap_instead_of_wrapping(_Config) ->
    {ok, Inst} = instantiate(load_module()),
    %% In range, to prove the module works at all.
    ?assertMatch({ok, [0]}, wasm:call(Inst, ~"load", [0])),
    [?assertMatch({error, #{class := trap, kind := out_of_bounds_memory_access}},
                  wasm:call(Inst, ~"load", [Addr]))
     || Addr <- [16#1_0000_0000, 16#1_0000_0004, 16#FFFF_FFFF_FFFF_0000]],
    ok = wasm:destroy(Inst).

%% `memory.size' and `memory.grow' count pages in the memory's own index type,
%% so on a 64-bit memory they are i64 in and i64 out.
memory_size_and_grow_are_i64(_Config) ->
    {ok, Inst} = instantiate(grow_module()),
    ?assertMatch({ok, [1]}, wasm:call(Inst, ~"size", [])),
    ?assertMatch({ok, [1]}, wasm:call(Inst, ~"grow", [1])),
    ?assertMatch({ok, [2]}, wasm:call(Inst, ~"size", [])),
    %% Refusal is -1, not a trap, and a delta too large to fit in 32 bits must
    %% be refused rather than truncated into a plausible one.
    ?assertMatch({ok, [-1]}, wasm:call(Inst, ~"grow", [16#1_0000_0000])),
    ?assertMatch({ok, [2]}, wasm:call(Inst, ~"size", [])),
    ok = wasm:destroy(Inst).

%%% ------------------------------------------------------------------ rule ---

%% A table refuses to grow past the maximum it was *declared* with.
%%
%% The limit used to be the node-wide ceiling, so `table.grow' on a table
%% declared `(table 0 2 externref)' happily grew it to 5. The declaration now
%% travels inside the table handle rather than being passed in at each call,
%% because a table imported from another module is bounded by the defining
%% module's maximum, which the importer cannot see.
table_grow_stops_at_the_declared_maximum(_Config) ->
    T = wasm_table:new(#limits{min = 0, max = 2}, null),
    ?assertMatch({ok, 0}, wasm_table:grow(T, 2, null)),
    ?assertEqual(2, wasm_table:size(T)),
    ?assertEqual({error, exceeds_max}, wasm_table:grow(T, 1, null)),
    ?assertEqual(2, wasm_table:size(T)),
    %% An undeclared maximum still has a ceiling, just the index type's.
    U = wasm_table:new(#limits{min = 0, index_type = i64}, null),
    ?assertEqual({error, exceeds_max},
                 wasm_table:grow(U, 16#FFFF_FFFF_FFFF_FFFF, null)).

%% Index types must match exactly across an import boundary.
%%
%% "At least as permissive" is the rule for the minimum and maximum, but not for
%% the index type: a 32-bit memory handed to a module that declared a 64-bit one
%% would truncate every address that module computes.
an_i32_memory_does_not_satisfy_an_i64_import(_Config) ->
    {ok, Mod} = wasm:load(import_module()),
    {ok, Narrow} = wasm_memory:new(#limits{min = 1, index_type = i32}),
    ?assertMatch({error, #{class := link, kind := incompatible_import_type,
                           ctx := #{reason := index_type_mismatch}}},
                 wasm:instantiate(Mod, #{{~"env", ~"mem"} => Narrow})),
    %% The same memory declared the right way round links.
    {ok, Wide} = wasm_memory:new(#limits{min = 1, index_type = i64}),
    {ok, Inst} = wasm:instantiate(Mod, #{{~"env", ~"mem"} => Wide}),
    ok = wasm:destroy(Inst),
    ok = wasm:unload(Mod).

%% `memory.init' takes its destination in the memory's index type and its
%% source offset and length in i32, whatever the memory is.
%%
%% The validator popped these in the wrong order, which no test could see while
%% every operand was i32. Rejecting a valid module is the visible half; the
%% other half is that it accepted ill-typed ones.
bulk_operand_types_follow_the_memory(_Config) ->
    {ok, Inst} = instantiate(init_module()),
    {ok, []} = wasm:call(Inst, ~"init", []),
    ?assertMatch({ok, [16#DE]}, wasm:call(Inst, ~"load8", [0])),
    ?assertMatch({ok, [16#AD]}, wasm:call(Inst, ~"load8", [1])),
    ok = wasm:destroy(Inst).

%% `memory.copy` naming two different memories must copy between them.
%%
%% Not a memory64 rule, but the instruction only ever had a same-memory clause,
%% so every cross-memory copy raised a `function_clause` from inside the
%% interpreter. No specification suite covers it: the multiple-memories fixtures
%% do not, and the memory64 ones only use one memory at a time.
memory_copy_works_between_two_memories(_Config) ->
    {ok, Inst} = instantiate(two_memory_module()),
    {ok, []} = wasm:call(Inst, ~"copy", []),
    ?assertMatch({ok, [16#DE]}, wasm:call(Inst, ~"load8", [0])),
    ?assertMatch({ok, [16#AD]}, wasm:call(Inst, ~"load8", [1])),
    ok = wasm:destroy(Inst).

%% A zero-length copy is bounds-checked like any other.
%%
%% Returning early on a length of zero looks harmless and is not: the
%% specification admits an address exactly at the end of a memory and requires a
%% trap one byte beyond it, whatever the length. The same-memory path checked
%% first and the cross-memory path did not, so `memory.copy $a $b' with a length
%% of zero accepted an address anywhere at all.
a_zero_length_copy_between_memories_still_checks_bounds(_Config) ->
    {ok, Inst} = instantiate(param_copy_module()),
    End = 65536,                                % both memories are one page
    ?assertMatch({ok, []}, wasm:call(Inst, ~"copy", [End, 0, 0])),
    ?assertMatch({ok, []}, wasm:call(Inst, ~"copy", [0, End, 0])),
    [?assertMatch({error, #{class := trap, kind := out_of_bounds_memory_access}},
                  wasm:call(Inst, ~"copy", Args))
     || Args <- [[End + 1, 0, 0], [0, End + 1, 0]]],
    ok = wasm:destroy(Inst).

%%% --------------------------------------------------------- module builder ---

%% Hand-assembled through `wasm_asm', so the suite has no toolchain dependency
%% and each byte is visible next to the rule it exercises.

instantiate(Bin) ->
    {ok, Mod} = wasm:load(Bin),
    wasm:instantiate(Mod, #{}).

-define(I32, 16#7F).
-define(I64, 16#7E).

%% (memory i64 1) (func (export "load") (param i64) (result i32) local.get 0
%%                                                               i32.load)
load_module() ->
    wasm_asm:module(
      [wasm_asm:type_section([{[?I64], [?I32]}]),
       wasm_asm:func_section([0]),
       wasm_asm:memory_section(16#04, 1, undefined),
       wasm_asm:export_section([{~"load", 0, 0}]),
       wasm_asm:code_section([<<16#20, 0, 16#28, 2, 0, 16#0B>>])]).

%% (memory i64 1 4) with memory.size and memory.grow exported.
grow_module() ->
    wasm_asm:module(
      [wasm_asm:type_section([{[], [?I64]}, {[?I64], [?I64]}]),
       wasm_asm:func_section([0, 1]),
       wasm_asm:memory_section(16#05, 1, 4),
       wasm_asm:export_section([{~"size", 0, 0}, {~"grow", 0, 1}]),
       wasm_asm:code_section([<<16#3F, 0, 16#0B>>,                 % memory.size
                              <<16#20, 0, 16#40, 0, 16#0B>>])]).   % memory.grow

%% (import "env" "mem" (memory i64 1))
import_module() ->
    wasm_asm:module([wasm_asm:import_section([{~"env", ~"mem", 16#04, 1}])]).

%% A passive data segment copied into a 64-bit memory: the destination is i64,
%% the source offset and length stay i32.
init_module() ->
    wasm_asm:module(
      [wasm_asm:type_section([{[], []}, {[?I64], [?I32]}]),
       wasm_asm:func_section([0, 1]),
       wasm_asm:memory_section(16#04, 1, undefined),
       wasm_asm:export_section([{~"init", 0, 0}, {~"load8", 0, 1}]),
       wasm_asm:data_count_section(1),
       wasm_asm:code_section([<<16#42, 0,                 % i64.const 0   (dst)
                                16#41, 0,                 % i32.const 0   (src)
                                16#41, 2,                 % i32.const 2   (len)
                                16#FC, 8, 0, 0,           % memory.init 0 0
                                16#0B>>,
                              <<16#20, 0, 16#2D, 0, 0, 16#0B>>]),   % i32.load8_u
       wasm_asm:data_section([<<16#DE, 16#AD>>])]).

%% Two 32-bit memories, the second seeded by an active data segment, and a
%% `memory.copy 0 1' between them.
two_memory_module() ->
    wasm_asm:module(
      [wasm_asm:type_section([{[], []}, {[?I32], [?I32]}]),
       wasm_asm:func_section([0, 1]),
       wasm_asm:section(5, [wasm_asm:uleb(2),
                            wasm_asm:limits(16#00, 1, undefined),
                            wasm_asm:limits(16#00, 1, undefined)]),
       wasm_asm:export_section([{~"copy", 0, 0}, {~"load8", 0, 1}]),
       wasm_asm:code_section([<<16#41, 0,                 % i32.const 0   (dst)
                                16#41, 0,                 % i32.const 0   (src)
                                16#41, 2,                 % i32.const 2   (len)
                                16#FC, 10, 0, 1,          % memory.copy 0 1
                                16#0B>>,
                              <<16#20, 0, 16#2D, 0, 0, 16#0B>>]),   % i32.load8_u
       %% Active segment into memory 1: mode 2 carries an explicit index.
       wasm_asm:section(11, [wasm_asm:uleb(1), 2, wasm_asm:uleb(1),
                             <<16#41, 0, 16#0B>>, wasm_asm:uleb(2),
                             <<16#DE, 16#AD>>])]).

%% Two one-page memories and `memory.copy 0 1' taking its three operands as
%% parameters, so a case can put an address exactly at the end or one past it.
param_copy_module() ->
    wasm_asm:module(
      [wasm_asm:type_section([{[?I32, ?I32, ?I32], []}]),
       wasm_asm:func_section([0]),
       wasm_asm:section(5, [wasm_asm:uleb(2),
                            wasm_asm:limits(16#00, 1, undefined),
                            wasm_asm:limits(16#00, 1, undefined)]),
       wasm_asm:export_section([{~"copy", 0, 0}]),
       wasm_asm:code_section([<<16#20, 0,                 % local.get 0  (dst)
                                16#20, 1,                 % local.get 1  (src)
                                16#20, 2,                 % local.get 2  (len)
                                16#FC, 10, 0, 1,          % memory.copy 0 1
                                16#0B>>])]).

memory_section(Flags, Min, Max) ->
    wasm_asm:module([wasm_asm:memory_section(Flags, Min, Max)]).
