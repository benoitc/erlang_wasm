%% @doc The text format's lexer and its numeric literals.
%%
%% Both are where a text front end quietly gets things wrong: a comment that
%% does not nest swallows the wrong amount of input, and a float literal that
%% goes through `list_to_float` loses exactly the values the format exists to
%% express.
-module(wasm_wat_lex_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [tokens_of_a_small_module,
     block_comments_nest,
     a_keyword_may_contain_equals,
     strings_are_bytes_not_text,
     integers_take_separators_between_digits,
     hexadecimal_floats_are_exact,
     nan_keeps_its_payload,
     literals_that_are_not_literals,
     forms_nest_and_report_where_they_opened].

tokens_of_a_small_module(_Config) ->
    {ok, Ts} = wasm_wat_lex:tokens(<<"(module $m (func $f))">>),
    ?assertMatch([{lparen, _}, {keyword, _, <<"module">>}, {id, _, <<"m">>},
                  {lparen, _}, {keyword, _, <<"func">>}, {id, _, <<"f">>},
                  {rparen, _}, {rparen, _}], Ts).

%% `(; a (; b ;) c ;)` is one comment. Stopping at the first `;)` would leave
%% `c ;)` behind as tokens, and the syntax error would appear a long way from
%% the comment that caused it.
block_comments_nest(_Config) ->
    {ok, Ts} = wasm_wat_lex:tokens(<<"(; a (; b ;) c ;)(module)">>),
    ?assertMatch([{lparen, _}, {keyword, _, <<"module">>}, {rparen, _}], Ts),
    ?assertMatch({error, #{kind := unterminated_comment}},
                 wasm_wat_lex:tokens(<<"(; a (; b ;)">>)).

%% `offset=4` is one token. Treating `=` as punctuation would make it three.
a_keyword_may_contain_equals(_Config) ->
    {ok, Ts} = wasm_wat_lex:tokens(<<"offset=4 align=8">>),
    ?assertMatch([{keyword, _, <<"offset=4">>}, {keyword, _, <<"align=8">>}], Ts).

strings_are_bytes_not_text(_Config) ->
    {ok, [{string, _, S}]} = wasm_wat_lex:tokens(<<"\"a\\6Ab\"">>),
    ?assertEqual(<<"ajb">>, S),
    {ok, [{string, _, U}]} = wasm_wat_lex:tokens(<<"\"\\u{41}\"">>),
    ?assertEqual(<<"A">>, U),
    %% A lone surrogate is not a code point.
    ?assertMatch({error, #{kind := invalid_unicode_escape}},
                 wasm_wat_lex:tokens(<<"\"\\u{D800}\"">>)),
    ?assertMatch({error, #{kind := unterminated_string}},
                 wasm_wat_lex:tokens(<<"\"abc">>)).

%% A separator has to sit between two digits, so all three of these are
%% malformed rather than a thousand.
integers_take_separators_between_digits(_Config) ->
    ?assertEqual({ok, 1000}, wasm_wat_num:integer(<<"1_000">>, u32)),
    ?assertEqual({ok, 255}, wasm_wat_num:integer(<<"0xff">>, u32)),
    ?assertEqual({ok, -1}, wasm_wat_num:integer(<<"-1">>, s32)),
    %% The same bits either way round.
    ?assertEqual({ok, -1}, wasm_wat_num:integer(<<"4294967295">>, i32)),
    [?assertEqual(error, wasm_wat_num:integer(B, u32))
     || B <- [<<"_1">>, <<"1_">>, <<"1__0">>, <<"0x_ff">>, <<>>]],
    %% Out of range for the width it is used at.
    ?assertEqual(error, wasm_wat_num:integer(<<"4294967296">>, u32)),
    ?assertEqual(error, wasm_wat_num:integer(<<"2147483648">>, s32)).

%% Read as an exact mantissa and a power of two, so nothing rounds on the way.
hexadecimal_floats_are_exact(_Config) ->
    ?assertEqual({ok, bits32(3.0)}, wasm_wat_num:float_bits(<<"0x1.8p1">>, 32)),
    ?assertEqual({ok, bits64(1.0)}, wasm_wat_num:float_bits(<<"0x1p0">>, 64)),
    ?assertEqual({ok, bits64(-0.5)}, wasm_wat_num:float_bits(<<"-0x1p-1">>, 64)),
    ?assertEqual({ok, bits64(255.0)}, wasm_wat_num:float_bits(<<"0xffp0">>, 64)),
    ?assertEqual({ok, bits64(1.5)}, wasm_wat_num:float_bits(<<"1.5">>, 64)).

%% Erlang has no NaN, so a literal becomes bits directly. Going through a float
%% would lose the payload and raise on infinity.
nan_keeps_its_payload(_Config) ->
    {ok, Canonical} = wasm_wat_num:float_bits(<<"nan">>, 32),
    ?assertEqual(16#7FC00000, Canonical),
    {ok, WithPayload} = wasm_wat_num:float_bits(<<"nan:0x200000">>, 32),
    ?assertEqual(16#7FA00000, WithPayload),
    {ok, NegNan} = wasm_wat_num:float_bits(<<"-nan">>, 64),
    ?assertEqual(16#FFF8000000000000, NegNan),
    {ok, Inf} = wasm_wat_num:float_bits(<<"inf">>, 32),
    ?assertEqual(16#7F800000, Inf),
    {ok, NegInf} = wasm_wat_num:float_bits(<<"-inf">>, 64),
    ?assertEqual(16#FFF0000000000000, NegInf).

%% A payload of zero is infinity and one that does not fit is another number.
%% Neither is what the literal says, so both are refused.
literals_that_are_not_literals(_Config) ->
    ?assertEqual(error, wasm_wat_num:float_bits(<<"nan:0x0">>, 32)),
    ?assertEqual(error, wasm_wat_num:float_bits(<<"nan:0x800000">>, 32)),
    ?assertEqual(error, wasm_wat_num:float_bits(<<"0x">>, 32)),
    ?assertEqual(error, wasm_wat_num:float_bits(<<"1.0e">>, 32)).

%% An unclosed parenthesis reports the one that was never closed, not the end
%% of the file. In a fifty-thousand-line script that is the whole difference
%% between a usable error and "unexpected end of input".
forms_nest_and_report_where_they_opened(_Config) ->
    {ok, [Form]} = wasm_wat_sexp:read_all(<<"(module (func (nop)))">>),
    ?assertMatch({list, 0, [{keyword, _, <<"module">>},
                            {list, _, [{keyword, _, <<"func">>},
                                       {list, _, [{keyword, _, <<"nop">>}]}]}]},
                 Form),
    {ok, Two} = wasm_wat_sexp:read_all(<<"(module) (module)">>),
    ?assertEqual(2, length(Two)),
    {error, #{kind := unclosed_paren, ctx := #{offset := Off}}} =
        wasm_wat_sexp:read_all(<<"(module (func (nop))">>),
    ?assertEqual(0, Off),
    ?assertMatch({error, #{kind := unexpected_close_paren}},
                 wasm_wat_sexp:read_all(<<")">>)).

bits32(F) -> wasm_num:f32_to_bits(wasm_num_float:round_to(32, F)).
bits64(F) -> wasm_num:f64_to_bits(F).
