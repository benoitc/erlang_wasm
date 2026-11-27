-module(wasm_encode_SUITE).
-moduledoc """
`wasm_encode`: a `#module{}` back to the binary format, one encoding per
module.

The bytes are an identity, so most of these cases pin bytes rather than only
a round trip. The golden vectors in `test/fixtures/encode/` were written by
`wasm-tools parse` followed by `wasm-tools strip --all`, not by this encoder,
and the encoder must give the same bytes for the same text. A change in what
it writes fails them, which is the point: anyone who names a module by its
digest sees the change.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("wasm.hrl").

all() ->
    [golden_vectors_hold,
     committed_modules_round_trip,
     a_validated_module_encodes_as_decoded,
     sections_keep_their_order_and_empty_ones_are_left_out,
     custom_sections_come_last_in_their_order,
     data_count_is_written_exactly_when_set,
     rec_groups_and_subtypes_take_their_short_forms,
     reference_types_take_their_short_forms,
     locals_are_written_in_runs,
     a_memory_argument_names_only_another_memory,
     an_if_writes_else_only_when_it_has_one,
     integers_take_their_shortest_form,
     what_cannot_be_encoded_is_an_error_value].

%%% ------------------------------------------------------------- golden ---

%% Each `.wat' beside its `.wasm': the text, encoded, is those bytes, and the
%% bytes decode to the record the text parses to.
golden_vectors_hold(_) ->
    Pairs = golden(),
    ?assert(length(Pairs) >= 2),
    [begin
         {ok, M} = wasm_wat:module(Wat),
         ?assertEqual({Name, {ok, Expected}}, {Name, wasm_encode:module(M)}),
         ?assertEqual({Name, {ok, M}}, {Name, wasm_decode:module(Expected)})
     end || {Name, Wat, Expected} <- Pairs].

%% Real toolchain output decodes, encodes and decodes to the same record, and
%% encoding that record again gives the same bytes.
committed_modules_round_trip(_) ->
    Files = lists:append([filelib:wildcard(filename:join([fixtures(), D, "*.wasm"]))
                          || D <- ["seeds", "rust", "plugin", "native", "encode"]]),
    ?assert(length(Files) >= 8),
    [round_trip(F) || F <- Files].

round_trip(File) ->
    {ok, Bin} = file:read_file(File),
    {ok, M} = wasm_decode:module(Bin),
    {ok, Encoded} = wasm_encode:module(M),
    ?assertEqual({File, {ok, M}}, {File, wasm_decode:module(Encoded)}),
    ?assertEqual({File, {ok, Encoded}},
                 {File, wasm_encode:module(element(2, wasm_decode:module(Encoded)))}).

%% The validator annotates every body with stack heights. Encoding strips
%% them, so a validated module gives the bytes its decoded form gives.
a_validated_module_encodes_as_decoded(_) ->
    [{_, _, Bin} | _] = golden(),
    {ok, M} = wasm_decode:module(Bin),
    {ok, V} = wasm_validate:module(M),
    ?assertMatch([#func{body = {validated, _}} | _], V#module.funcs),
    ?assertEqual({ok, Bin}, wasm_encode:module(V)).

%%% ------------------------------------------------------- canonical forms ---

sections_keep_their_order_and_empty_ones_are_left_out(_) ->
    %% Nothing at all: the header alone.
    ?assertEqual({ok, header()}, wasm_encode:module(#module{})),
    %% A memory, a tag and a global. The tag section has id 13 but sits
    %% between memory and global.
    M = #module{types = [#subtype{body = #functype{}}], rec_groups = [{0, 1}],
                mems = [#memtype{limits = #limits{min = 1}}],
                tags = [#tagtype{type = 0}],
                globals = [#global{type = #globaltype{valtype = i32, mut = const},
                                   init = [{i32_const, 7}]}]},
    ?assertEqual(
       {ok, <<(header())/binary,
              1, 4, 1, 16#60, 0, 0,     % type: one func type, no params
              5, 3, 1, 0, 1,            % memory: min 1, no max
              13, 3, 1, 0, 0,           % tag: attribute 0, type 0
              6, 6, 1, 16#7F, 0, 16#41, 7, 16#0B>>},  % global: i32 const 7
       wasm_encode:module(M)).

custom_sections_come_last_in_their_order(_) ->
    M = #module{mems = [#memtype{limits = #limits{min = 1}}],
                customs = [{~"b", ~"2"}, {~"a", ~"1"}]},
    ?assertEqual({ok, <<(header())/binary, 5, 3, 1, 0, 1,
                        0, 3, 1, $b, $2, 0, 3, 1, $a, $1>>},
                 wasm_encode:module(M)).

data_count_is_written_exactly_when_set(_) ->
    Data = #data{init = ~"x", mode = passive},
    {ok, Without} = wasm_encode:module(#module{datas = [Data]}),
    {ok, With} = wasm_encode:module(#module{datas = [Data], data_count = 1}),
    ?assertEqual(<<(header())/binary, 11, 4, 1, 1, 1, $x>>, Without),
    ?assertEqual(<<(header())/binary, 12, 1, 1, 11, 4, 1, 1, 1, $x>>, With),
    %% Set to zero is still set.
    ?assertEqual({ok, <<(header())/binary, 12, 1, 0>>},
                 wasm_encode:module(#module{data_count = 0})).

%% A group of one is the type alone; an empty group and a group of two are
%% `rec'. A final type with supertypes is `sub final', a non-final one `sub'.
rec_groups_and_subtypes_take_their_short_forms(_) ->
    F = #subtype{body = #functype{}},
    Open = #subtype{final = false, body = #structtype{}},
    Closed = #subtype{final = true, supers = [1], body = #structtype{}},
    M = #module{types = [F, Open, Closed], rec_groups = [{0, 1}, {1, 0}, {1, 2}]},
    {ok, Bin} = wasm_encode:module(M),
    <<_:8/binary, 1, _Size, 3, Groups/binary>> = Bin,
    ?assertEqual(<<16#60, 0, 0,                        % the func type, bare
                   16#4E, 0,                           % (rec)
                   16#4E, 2, 16#50, 0, 16#5F, 0,       % (rec (sub (struct))
                   16#4F, 1, 1, 16#5F, 0>>,            %      (sub final 1 (struct)))
                 Groups),
    ?assertEqual({ok, M}, wasm_decode:module(Bin)),
    %% Left empty, every type is a group of its own.
    {ok, Single} = wasm_encode:module(M#module{types = [F, F], rec_groups = []}),
    ?assertEqual({ok, [{0, 1}, {1, 1}]},
                 rec_groups_of(wasm_decode:module(Single))).

reference_types_take_their_short_forms(_) ->
    ?assertEqual(16#70, wasm_encode:valtype(?FUNCREF)),
    ?assertEqual(16#6F, wasm_encode:valtype(?EXTERNREF)),
    ?assertEqual(16#71, wasm_encode:valtype({ref, null, none})),
    ?assertEqual(<<16#63, 3>>, iolist_to_binary([wasm_encode:valtype({ref, null, {type, 3}})])),
    ?assertEqual(<<16#64, 16#70>>, iolist_to_binary([wasm_encode:valtype({ref, nonull, func})])),
    ?assertEqual(<<16#64, 16#C0, 0>>,
                 iolist_to_binary([wasm_encode:valtype({ref, nonull, {type, 64}})])).

locals_are_written_in_runs(_) ->
    M = func_module([], [i32, i32, i64, i32, i32, i32]),
    {ok, Bin} = wasm_encode:module(M),
    %% Three runs: two i32, one i64, three i32; then `end'.
    ?assertMatch({_, _}, binary:match(Bin, <<3, 2, 16#7F, 1, 16#7E, 3, 16#7F, 16#0B>>)),
    ?assertEqual({ok, M}, wasm_decode:module(Bin)).

a_memory_argument_names_only_another_memory(_) ->
    ?assertEqual(<<16#28, 2, 16#AC, 2>>, instr({i32_load, {2, 300, 0}})),
    ?assertEqual(<<16#28, 66, 1, 8>>, instr({i32_load, {2, 8, 1}})).

an_if_writes_else_only_when_it_has_one(_) ->
    ?assertEqual(<<16#04, 16#40, 16#01, 16#0B>>, instr({if_, empty, [nop], []})),
    ?assertEqual(<<16#04, 16#40, 16#01, 16#05, 16#01, 16#0B>>,
                 instr({if_, empty, [nop], [nop]})).

integers_take_their_shortest_form(_) ->
    ?assertEqual(<<16#20, 5>>, instr({local_get, 5})),
    ?assertEqual(<<16#20, 16#AC, 2>>, instr({local_get, 300})),
    ?assertEqual(<<16#41, 16#7F>>, instr({i32_const, -1})),
    ?assertEqual(<<16#41, 16#C0, 0>>, instr({i32_const, 64})),
    ?assertEqual(<<16#41, 16#80, 16#80, 16#80, 16#80, 16#78>>,
                 instr({i32_const, -16#80000000})),
    ?assertEqual(<<16#42, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF,
                   16#FF, 16#FF, 0>>,
                 instr({i64_const, 16#7FFFFFFFFFFFFFFF})).

%%% --------------------------------------------------------------- errors ---

%% A record with no binary form, or one whose bytes the decoder would refuse,
%% is an error value and never an exception.
what_cannot_be_encoded_is_an_error_value(_) ->
    Bad = [{export_index, #module{exports = [#export{name = ~"f",
                                                       desc = {func, 1 bsl 32}}]}},
           {negative_index, func_module([{local_get, -1}], [])},
           {not_utf8, #module{exports = [#export{name = <<16#FF>>, desc = {func, 0}}]}},
           {rec_groups_gap, #module{types = [#subtype{body = #functype{}}],
                                    rec_groups = [{1, 1}]}},
           {rec_groups_short, #module{types = [#subtype{body = #functype{}},
                                               #subtype{body = #functype{}}],
                                      rec_groups = [{0, 1}]}},
           {data_count_mismatch, #module{data_count = 2,
                                         datas = [#data{init = ~"", mode = passive}]}},
           {data_count_required, func_module([{data_drop, 0}], [])},
           {unknown_instruction, func_module([no_such_instruction], [])},
           {f32_not_exact, func_module([{f32_const, 0.1}], [])},
           {nan_without_payload, func_module([{f64_const, {nan, 0, 0}}], [])},
           {i32_const_too_large, func_module([{i32_const, 1 bsl 31}], [])},
           {alignment_too_large, func_module([{i32_load, {64, 0, 0}}], [])},
           {ref_null_non_null, func_module([{ref_null, {ref, nonull, func}}], [])},
           {not_a_module, not_a_module}],
    [?assertMatch({W, {error, #{class := invalid, kind := unencodable}}},
                  {W, wasm_encode:module(M)})
     || {W, M} <- Bad].

%%% -------------------------------------------------------------- helpers ---

header() -> <<"\0asm", 1:32/little>>.

%% One function of type `[] -> []' with these locals and this body.
func_module(Body, Locals) ->
    #module{types = [#subtype{body = #functype{}}], rec_groups = [{0, 1}],
            funcs = [#func{type = 0, locals = Locals, body = Body}]}.

instr(I) -> iolist_to_binary([wasm_encode_code:instr(I)]).

rec_groups_of({ok, #module{rec_groups = G}}) -> {ok, G}.

golden() ->
    Dir = filename:join(fixtures(), "encode"),
    [{filename:basename(W, ".wat"), Wat, Bin}
     || W <- lists:sort(filelib:wildcard(filename:join(Dir, "*.wat"))),
        {ok, Wat} <- [file:read_file(W)],
        {ok, Bin} <- [file:read_file(filename:rootname(W) ++ ".wasm")]].

fixtures() -> wasm_spec_runner:fixtures_dir().
