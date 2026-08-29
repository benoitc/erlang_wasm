-module(wasm_wat_sexp).
-moduledoc """
Tokens to a tree, and the thing that tells you where your parenthesis is
missing.

The text format is s-expressions, so this is small: a list becomes a list and
everything else stays as the lexer produced it. What it adds is *balance*.

An unclosed parenthesis in a fifty-thousand-line `.wast` file reports the
position of the parenthesis that was never closed, not the end of the file.
That is the difference between a usable error and "unexpected end of input".
""".

-export([read/1, read_all/1, forms_of/1]).

-export_type([sexp/0]).

-doc "A tree: a list of forms, or a token from the lexer.".
-nominal sexp() :: {list, non_neg_integer(), [sexp()]} | wasm_wat_lex:token().

-doc "Read every top-level form in a source file.".
-spec read_all(binary()) -> {ok, [sexp()]} | {error, wasm_error:error()}.
read_all(Source) ->
    wasm_error:capture(fun() -> {ok, forms_of(Source)} end).

-doc """
As `read_all/1`, but raising rather than answering.

For a caller already inside `wasm_error:capture/1`. Matching `{ok, _}` on the
answering form is how a malformed file becomes an `internal` error with a
badmatch in it, which happened twice here before this existed.
""".
-spec forms_of(binary()) -> [sexp()].
forms_of(Source) -> forms(wasm_wat_lex:scan_all(Source), []).

-doc "Read one form, answering it and whatever tokens follow.".
-spec read([wasm_wat_lex:token()]) -> {sexp(), [wasm_wat_lex:token()]}.
read(Tokens) -> form(Tokens).

forms([], Acc) -> lists:reverse(Acc);
forms(Tokens, Acc) ->
    {Form, Rest} = form(Tokens),
    forms(Rest, [Form | Acc]).

form([{lparen, Pos} | Rest]) ->
    {Items, Rest1} = items(Rest, Pos, []),
    {{list, Pos, Items}, Rest1};
form([{rparen, Pos} | _]) ->
    fail(unexpected_close_paren, Pos);
form([Token | Rest]) ->
    {Token, Rest};
form([]) ->
    fail(unexpected_end, 0).

%% `Open' is carried so an unclosed list reports where it began.
items([{rparen, _} | Rest], _Open, Acc) ->
    {lists:reverse(Acc), Rest};
items([], Open, _Acc) ->
    fail(unclosed_paren, Open);
items(Tokens, Open, Acc) ->
    {Item, Rest} = form(Tokens),
    items(Rest, Open, [Item | Acc]).

fail(Kind, Pos) ->
    wasm_error:malformed(Kind, atom_to_binary(Kind), #{offset => Pos}).
