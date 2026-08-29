%% @doc The `.wast' script reader.
%%
%% This reader replaced `wasm-tools json-from-wast'. Before the switch the two
%% were compared command by command over the whole suite, 65,107 commands
%% across 255 files, and agreed on every one. What remains here is the part
%% that keeps meaning something now the generator is gone: the hand-written
%% cases, and that every file the specification ships can be read.
-module(wasm_wast_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [reads_the_commands_a_script_holds,
     values_are_written_as_the_runner_reads_them,
     a_malformed_module_does_not_stop_the_script,
     replays_every_suite_the_specification_ships].

%% The two files the lexer refuses by name, for reasons the manifest already
%% records: both belong to proposals this runtime does not implement.
%% The checkout `wasm_spec_runner' found, if it is really there.
suite_checkout() ->
    Dir = wasm_spec_runner:suite_dir(),
    case filelib:is_regular(filename:join(Dir, "i32.wast")) of
        true -> Dir;
        false -> false
    end.

excluded() ->
    [{"id.wast", "quoted identifiers"},
     {"annotations.wast", "annotations"}].

reads_the_commands_a_script_holds(_Config) ->
    Script = ~"""
    (module $M (func (export "f") (result i32) (i32.const 7)))
    (register "m" $M)
    (assert_return (invoke "f") (i32.const 7))
    (assert_return (invoke $M "f") (i32.const 7))
    (assert_trap (invoke "f") "unreachable")
    (invoke "f")
    """,
    {ok, Commands} = wasm_wast:script(Script),
    ?assertEqual([<<"module">>, <<"register">>, <<"assert_return">>,
                  <<"assert_return">>, <<"assert_trap">>, <<"action">>],
                 [maps:get(<<"type">>, C) || C <- Commands]),
    ?assertMatch(#{<<"name">> := <<"M">>, <<"line">> := 1}, hd(Commands)),
    ?assertMatch(#{<<"as">> := <<"m">>, <<"name">> := <<"M">>},
                 lists:nth(2, Commands)),
    ?assertMatch(#{<<"action">> := #{<<"module">> := <<"M">>}},
                 lists:nth(4, Commands)),
    ?assertMatch(#{<<"text">> := <<"unreachable">>}, lists:nth(5, Commands)).

%% Values come out in the notation the runner already reads: integers signed,
%% floats as bit patterns, because that is the only way to name a NaN payload
%% or tell the two zeroes apart.
values_are_written_as_the_runner_reads_them(_Config) ->
    Script = ~"""
    (assert_return (invoke "f")
      (i32.const -1)
      (i64.const 0xffffffffffffffff)
      (f32.const -0.0)
      (f64.const nan:canonical)
      (v128.const i8x16 -1 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
      (v128.const f32x4 1.0 nan:arithmetic 0 0)
      (ref.null func)
      (ref.null none)
      (ref.extern 3)
      (ref.array))
    """,
    {ok, [#{<<"expected">> := Expected}]} = wasm_wast:script(Script),
    ?assertEqual(
       [#{<<"type">> => <<"i32">>, <<"value">> => <<"-1">>},
        #{<<"type">> => <<"i64">>, <<"value">> => <<"-1">>},
        #{<<"type">> => <<"f32">>, <<"value">> => <<"2147483648">>},
        #{<<"type">> => <<"f64">>, <<"value">> => <<"nan:canonical">>},
        #{<<"type">> => <<"v128">>, <<"lane_type">> => <<"i8">>,
          <<"value">> => [~"-1", ~"1", ~"0", ~"0", ~"0", ~"0", ~"0", ~"0",
                          ~"0", ~"0", ~"0", ~"0", ~"0", ~"0", ~"0", ~"0"]},
        #{<<"type">> => <<"v128">>, <<"lane_type">> => <<"f32">>,
          <<"value">> => [~"1065353216", ~"nan:arithmetic", ~"0", ~"0"]},
        #{<<"type">> => <<"funcref">>, <<"value">> => <<"null">>},
        #{<<"type">> => <<"nullref">>},
        #{<<"type">> => <<"externref">>, <<"value">> => <<"3">>},
        #{<<"type">> => <<"arrayref">>}],
       Expected).

%% A third of what the suite asserts is that some module is malformed, so a
%% script holding one has to read like any other. Modules travel with their
%% command and are parsed by whoever runs it.
a_malformed_module_does_not_stop_the_script(_Config) ->
    Script = ~"""
    (assert_malformed (module quote "(memory 1) (memory 2)") "multiple memories")
    (assert_malformed (module binary "\00asm") "unexpected end")
    (assert_invalid (module (func (result i32))) "type mismatch")
    """,
    {ok, [Quoted, Binary, Invalid]} = wasm_wast:script(Script),
    ?assertMatch(#{<<"module_type">> := <<"text">>,
                   <<"module">> := {quote, <<"(memory 1) (memory 2)">>}}, Quoted),
    ?assertMatch(#{<<"module_type">> := <<"binary">>,
                   <<"module">> := {binary, <<0, "asm">>}}, Binary),
    ?assertMatch(#{<<"module_type">> := <<"binary">>,
                   <<"module">> := {form, _}}, Invalid),
    %% The module the third one carries is a real module, and an invalid one.
    {form, Form} = maps:get(<<"module">>, Invalid),
    {ok, Module} = wasm_wat:module_form(Form),
    ?assertMatch({error, #{class := invalid}}, wasm_validate:module(Module)).

%% Every suite the specification ships, read as a script. `wasm_spec_SUITE`
%% replays the ones this runtime is held to; this only asks that every file can
%% be *read*, out-of-scope proposals included, because a script that cannot be
%% read is a gap in the reader rather than in the runtime.
replays_every_suite_the_specification_ships(_Config) ->
    case suite_checkout() of
        false -> {skip, "no suite checkout: git clone --depth 1 "
                        "https://github.com/WebAssembly/testsuite.git"};
        Dir -> read_every_suite(Dir)
    end.

read_every_suite(Dir) ->
    Skip = [F || {F, _Why} <- excluded()],
    Files = [F || F <- filelib:wildcard(filename:join(Dir, "*.wast")),
                  not lists:member(filename:basename(F), Skip)],
    ?assertNotEqual([], Files),
    Unreadable = [{filename:basename(File), Error}
                  || File <- Files,
                     {ok, Source} <- [file:read_file(File)],
                     {error, Error} <- [wasm_wast:script(Source)]],
    Commands = lists:sum([length(Cs)
                          || File <- Files,
                             {ok, Source} <- [file:read_file(File)],
                             {ok, Cs} <- [wasm_wast:script(Source)]]),
    ct:pal("~p files, ~p commands read, ~p unreadable~nexcluded:~n~s",
           [length(Files), Commands, length(Unreadable),
            [io_lib:format("  ~s: ~s~n", [F, Why]) || {F, Why} <- excluded()]]),
    ?assertEqual([], Unreadable).
