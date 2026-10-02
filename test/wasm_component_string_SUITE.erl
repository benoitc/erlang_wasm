-module(wasm_component_string_SUITE).
-moduledoc """
The Canonical ABI string encodings: utf8 (the default), utf16, and latin1+utf16.

A component's `canon lift` chooses how it stores strings. Each fixture has a `units`
export that returns the length operand the runtime passes after lowering a string (the
count in the encoding's units, which differs from the UTF-8 byte count) and a `make`
export that returns a constant string whose bytes are in that encoding (so the lift must
decode them). Both are non-trivial: a byte-for-byte echo would pass under any encoding.
The UTF-8 default is covered by `wasm_component_vectors_SUITE`.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() -> [utf16_lowers_and_lifts, latin1_utf16_lowers_and_lifts].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

%% Lowering counts UTF-16 code units, not UTF-8 bytes: "café" is 4 units (5 UTF-8 bytes),
%% "日本語" is 3 (9 bytes), and the astral "😀" is a surrogate pair, 2 units (4 bytes).
%% Lifting reads the units back as UTF-16: `make` returns UTF-16LE "café". Fail-first: the
%% string path assumed UTF-8, so `units` returned byte counts and `make` mis-decoded.
utf16_lowers_and_lifts(_Config) ->
    Inst = load("strutf16"),
    ?assertEqual({ok, 4}, units(Inst, <<"café"/utf8>>)),
    ?assertEqual({ok, 3}, units(Inst, <<"日本語"/utf8>>)),
    ?assertEqual({ok, 2}, units(Inst, <<"😀"/utf8>>)),
    ?assertEqual({ok, 5}, units(Inst, <<"hello">>)),
    ?assertEqual({ok, <<"café"/utf8>>},
                 wasm_component:call(Inst, <<"make">>, {[], string}, [])).

%% latin1+utf16 stores Latin-1 when every code point fits in a byte (length is the byte
%% count, high bit clear) and UTF-16 otherwise (code units, high bit set). "café" is
%% Latin-1 (4 units, high bit clear); "日本語" needs UTF-16 (3 units, high bit set =
%% 16#80000003). `make` returns a Latin-1 "café" that the lift widens to UTF-8.
latin1_utf16_lowers_and_lifts(_Config) ->
    Inst = load("strlatin1"),
    ?assertEqual({ok, 4}, units(Inst, <<"café"/utf8>>)),
    ?assertEqual({ok, 16#80000003}, units(Inst, <<"日本語"/utf8>>)),
    ?assertEqual({ok, <<"café"/utf8>>},
                 wasm_component:call(Inst, <<"make">>, {[], string}, [])).

load(Fixture) ->
    {ok, Bin} = file:read_file(fixture_path(Fixture)),
    {ok, Inst} = wasm_component:instantiate(Bin),
    Inst.

units(Inst, S) ->
    wasm_component:call(Inst, <<"units">>, {[string], u32}, [S]).

fixture_path(Name) ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..", "test",
                   "fixtures", "component", Name ++ ".component.wasm"]).
