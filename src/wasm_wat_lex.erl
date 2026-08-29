-module(wasm_wat_lex).
-moduledoc """
Tokens of the WebAssembly text format. Start here when the text parser rejects
something it should accept.

The grammar has six kinds of token and two kinds of comment, and almost all of
the difficulty is in the last two:

| token | example |
| --- | --- |
| parenthesis | `(` `)` |
| keyword | `module`, `i32.add`, `offset=4` |
| identifier | `$fac` |
| string | `"a\\6Ab"` |
| number | `-1_000`, `0x1.8p3`, `nan:0x4000`, `inf` |
| reserved | anything else, which is a syntax error where it appears |

**A keyword may contain `=`.** `offset=4` is one token, not three, so the
lexer cannot treat `=` as punctuation and the parser splits it later.

**Numbers carry underscores.** `1_000_000` is a million and `0x_ff` is
malformed, because a separator has to sit between two digits.

**Block comments nest.** `(; a (; b ;) c ;)` is one comment. A scanner that
stopped at the first `;)` would leave `c ;)` as tokens, which is how a comment
becomes a syntax error a long way from its cause.

**Tokens have to be separated.** `(data"a")` is not `data` followed by a
string: with nothing between them the two are one token, and a malformed one.
Only parentheses, whitespace and comments separate.

Quoted identifiers (`$"..."`) and annotations (`(@name ...)`) are not lexed.
Both belong to proposals this runtime does not implement, and both are refused
by name here rather than half-accepted: they are exactly the `id` and
`annotations` suites the specification manifest already lists as out of scope.

Positions are byte offsets from the start of the input, carried on every token
so a parse error can say where rather than what.
""".

-export([tokens/1, scan_all/1]).

-export_type([token/0]).

-doc "A token and the byte offset it starts at.".
-nominal token() :: {lparen, pos()}
                  | {rparen, pos()}
                  | {keyword, pos(), binary()}
                  | {id, pos(), binary()}
                  | {string, pos(), binary()}
                  | {reserved, pos(), binary()}.

-type pos() :: non_neg_integer().

-doc """
Tokenise, or fail with a structured error.

Answers `{ok, Tokens}` or `{error, Error}` in the shape everything else here
uses, so a malformed text module is a value like a malformed binary one.
""".
-spec tokens(binary()) -> {ok, [token()]} | {error, wasm_error:error()}.
tokens(Bin) when is_binary(Bin) ->
    wasm_error:capture(fun() -> {ok, scan_all(Bin)} end).

-doc """
As `tokens/1`, but raising rather than answering.

For a caller that is already inside `wasm_error:capture/1` and would otherwise
have to match `{ok, _}` and re-raise. Matching is what a first version of the
reader did, and a malformed file then arrived as an `internal` error with a
badmatch in it instead of the lexer's own diagnosis.
""".
-spec scan_all(binary()) -> [token()].
scan_all(Bin) when is_binary(Bin) -> scan(Bin, 0, true, []).

%%% --------------------------------------------------------------- scanner ---

%% `Sep' says whether anything separates this position from the token before
%% it. Two tokens written with nothing between them are *one* token as far as
%% the format is concerned, and a malformed one: `(data"a")' is not `data'
%% followed by a string. Parentheses separate, so `(func' and `"a")' are fine.
scan(<<>>, _Pos, _Sep, Acc) ->
    lists:reverse(Acc);
scan(<<C, R/binary>>, Pos, _Sep, Acc)
  when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
    scan(R, Pos + 1, true, Acc);
scan(<<$(, $;, R/binary>>, Pos, _Sep, Acc) ->
    {Rest, Pos1} = block_comment(R, Pos + 2, 1),
    scan(Rest, Pos1, true, Acc);
scan(<<$;, $;, R/binary>>, Pos, _Sep, Acc) ->
    {Rest, Pos1} = line_comment(R, Pos + 2),
    scan(Rest, Pos1, true, Acc);
scan(<<$(, R/binary>>, Pos, _Sep, Acc) ->
    scan(R, Pos + 1, true, [{lparen, Pos} | Acc]);
scan(<<$), R/binary>>, Pos, _Sep, Acc) ->
    scan(R, Pos + 1, true, [{rparen, Pos} | Acc]);
scan(_Bin, Pos, false, _Acc) ->
    fail(unseparated_tokens, Pos);
scan(<<$", R/binary>>, Pos, true, Acc) ->
    {Str, Rest, Pos1} = string(R, Pos + 1, []),
    scan(Rest, Pos1, false, [{string, Pos, Str} | Acc]);
scan(<<$$, R/binary>>, Pos, true, Acc) ->
    {Word, Rest, Pos1} = idchars(R, Pos + 1, []),
    case Word of
        <<>> -> fail(empty_identifier, Pos);
        _ -> scan(Rest, Pos1, false, [{id, Pos, Word} | Acc])
    end;
scan(Bin, Pos, true, Acc) ->
    {Word, Rest, Pos1} = idchars(Bin, Pos, []),
    case Word of
        <<>> ->
            <<C, _/binary>> = Bin,
            fail(unexpected_character, Pos, #{character => C});
        _ ->
            scan(Rest, Pos1, false, [classify(Word, Pos) | Acc])
    end.

%% A keyword begins with a lowercase letter. Everything else that is not a
%% number is reserved: the specification wants those rejected where they are
%% used rather than silently treated as something else.
classify(<<C, _/binary>> = Word, Pos) when C >= $a, C =< $z ->
    {keyword, Pos, Word};
classify(Word, Pos) ->
    case is_number_like(Word) of
        true -> {keyword, Pos, Word};
        false -> {reserved, Pos, Word}
    end.

%% Numbers are handed on as keywords and parsed by the caller, which knows
%% whether it wants an integer, a float, or a lane of a particular width.
is_number_like(<<C, _/binary>>) when C >= $0, C =< $9 -> true;
is_number_like(<<C, _/binary>>) when C =:= $+; C =:= $- -> true;
is_number_like(_) -> false.

%%% -------------------------------------------------------------- comments ---

%% A line ends at a line feed, a carriage return, or the two together. Stopping
%% only at the line feed swallows whatever followed a lone carriage return,
%% which is a comment eating the code after it.
line_comment(<<>>, Pos) -> {<<>>, Pos};
line_comment(<<$\r, $\n, R/binary>>, Pos) -> {R, Pos + 2};
line_comment(<<C, R/binary>>, Pos) when C =:= $\n; C =:= $\r -> {R, Pos + 1};
line_comment(<<_, R/binary>>, Pos) -> line_comment(R, Pos + 1).

%% Nesting is counted rather than matched, so the depth is the whole state.
block_comment(<<>>, Pos, _Depth) ->
    fail(unterminated_comment, Pos);
block_comment(<<$(, $;, R/binary>>, Pos, Depth) ->
    block_comment(R, Pos + 2, Depth + 1);
block_comment(<<$;, $), R/binary>>, Pos, 1) ->
    {R, Pos + 2};
block_comment(<<$;, $), R/binary>>, Pos, Depth) ->
    block_comment(R, Pos + 2, Depth - 1);
block_comment(<<_, R/binary>>, Pos, Depth) ->
    block_comment(R, Pos + 1, Depth).

%%% --------------------------------------------------------------- strings ---

%% A string is a byte sequence, not text: `\6A` is one byte and `\u{41}` is the
%% UTF-8 encoding of a code point. Names are checked for valid UTF-8 later, by
%% whoever wants a name rather than by the lexer.
string(<<>>, Pos, _Acc) ->
    fail(unterminated_string, Pos);
string(<<$", R/binary>>, Pos, Acc) ->
    {iolist_to_binary(lists:reverse(Acc)), R, Pos + 1};
string(<<$\\, C, R/binary>>, Pos, Acc) ->
    case escape(C) of
        {ok, Byte} -> string(R, Pos + 2, [Byte | Acc]);
        hex -> hex_escape(<<C, R/binary>>, Pos, Acc);
        unicode -> unicode_escape(R, Pos + 2, Acc);
        false -> fail(invalid_escape, Pos, #{character => C})
    end;
string(<<C, R/binary>>, Pos, Acc) when C >= 16#20, C =/= 16#7F ->
    string(R, Pos + 1, [C | Acc]);
string(<<C, _/binary>>, Pos, _Acc) ->
    fail(invalid_character_in_string, Pos, #{character => C}).

escape($n) -> {ok, $\n};
escape($t) -> {ok, $\t};
escape($r) -> {ok, $\r};
escape($") -> {ok, $"};
escape($') -> {ok, $'};
escape($\\) -> {ok, $\\};
escape($u) -> unicode;
escape(C) when C >= $0, C =< $9 -> hex;
escape(C) when C >= $a, C =< $f -> hex;
escape(C) when C >= $A, C =< $F -> hex;
escape(_) -> false.

hex_escape(<<H1, H2, R/binary>>, Pos, Acc) ->
    case {hexval(H1), hexval(H2)} of
        {V1, V2} when is_integer(V1), is_integer(V2) ->
            string(R, Pos + 3, [V1 * 16 + V2 | Acc]);
        _ ->
            fail(invalid_escape, Pos)
    end;
hex_escape(_, Pos, _Acc) ->
    fail(invalid_escape, Pos).

unicode_escape(<<${, R0/binary>>, Pos, Acc) ->
    {Digits, R1, Pos1} = take_while(R0, Pos + 1, fun(C) -> hexval(C) =/= false end),
    case R1 of
        <<$}, R2/binary>> when Digits =/= <<>> ->
            Code = binary_to_integer(Digits, 16),
            case Code =< 16#10FFFF andalso not (Code >= 16#D800 andalso
                                                Code =< 16#DFFF) of
                true -> string(R2, Pos1 + 1, [unicode(Code) | Acc]);
                false -> fail(invalid_unicode_escape, Pos, #{code => Code})
            end;
        _ -> fail(invalid_unicode_escape, Pos)
    end;
unicode_escape(_, Pos, _Acc) ->
    fail(invalid_unicode_escape, Pos).

unicode(Code) -> unicode:characters_to_binary([Code], unicode, utf8).

%%% ----------------------------------------------------------------- atoms ---

%% The specification's `idchar` set: everything a keyword, identifier or number
%% may be made of. Deliberately generous, so a mistyped token is one reserved
%% token rather than a run of small ones.
idchars(<<C, R/binary>>, Pos, Acc) ->
    case is_idchar(C) of
        true -> idchars(R, Pos + 1, [C | Acc]);
        false -> {list_to_binary(lists:reverse(Acc)), <<C, R/binary>>, Pos}
    end;
idchars(<<>>, Pos, Acc) ->
    {list_to_binary(lists:reverse(Acc)), <<>>, Pos}.

is_idchar(C) when C >= $0, C =< $9 -> true;
is_idchar(C) when C >= $a, C =< $z -> true;
is_idchar(C) when C >= $A, C =< $Z -> true;
is_idchar(C) ->
    lists:member(C, "!#$%&'*+-./:<=>?@\\^_`|~").

take_while(Bin, Pos, Pred) -> take_while(Bin, Pos, Pred, []).

take_while(<<C, R/binary>> = Bin, Pos, Pred, Acc) ->
    case Pred(C) of
        true -> take_while(R, Pos + 1, Pred, [C | Acc]);
        false -> {list_to_binary(lists:reverse(Acc)), Bin, Pos}
    end;
take_while(<<>>, Pos, _Pred, Acc) ->
    {list_to_binary(lists:reverse(Acc)), <<>>, Pos}.

hexval(C) when C >= $0, C =< $9 -> C - $0;
hexval(C) when C >= $a, C =< $f -> C - $a + 10;
hexval(C) when C >= $A, C =< $F -> C - $A + 10;
hexval(_) -> false.

fail(Kind, Pos) -> fail(Kind, Pos, #{}).

fail(Kind, Pos, Ctx) ->
    wasm_error:malformed(Kind, atom_to_binary(Kind), Ctx#{offset => Pos}).
