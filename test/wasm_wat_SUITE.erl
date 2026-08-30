%% @doc The text format parser, checked against the binary decoder.
%%
%% The parser's whole job is to produce the *same* `#module{}` the binary
%% decoder produces from the same source. Testing it against hand-written
%% expectations would check it against my reading of the format; testing it
%% against the decoder checks it against the format, because the decoder is
%% already held to 63,616 specification assertions.
%%
%% The comparison needs `wasm-tools` to compile the text to binary, so these
%% cases skip without it. Nothing else does: the runtime and the rest of the
%% suite read the text format themselves.
-module(wasm_wat_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("wasm/include/wasm.hrl").

all() ->
    [parses_what_the_decoder_parses,
     parses_the_specification_corpus,
     float_literals_round_once,
     refuses_what_the_format_forbids,
     an_unknown_instruction_does_not_become_an_atom,
     errors_carry_an_offset,
     the_facade_compiles_text_too,
     the_facade_answers_a_value_for_bad_text].

%% Only the differential cases need `wasm-tools`, so only they skip without one.
init_per_testcase(Case, Config)
  when Case =:= parses_what_the_decoder_parses;
       Case =:= parses_the_specification_corpus ->
    case os:find_executable("wasm-tools") of
        false -> {skip, "wasm-tools not installed"};
        Path -> [{wasm_tools, Path} | Config]
    end;
init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(_Case, _Config) -> ok.

%% Every source here is parsed both ways and the two modules compared whole. A
%% difference anywhere, in a type's recursive group or a constant expression's
%% terminator, fails the case.
parses_what_the_decoder_parses(Config) ->
    Dir = ?config(priv_dir, Config),
    Failures =
        [{Src, Why} || Src <- sources(),
                       {differs, Why} <- [compare(Src, Dir)]],
    ?assertEqual([], Failures).

sources() ->
    [~"(module)",
     ~"(module (memory 1 2))",
     ~"(module (memory (export \"mem\") 1))",
     ~"(module (memory 1 2 shared))",
     ~"(module (global i32 (i32.const 42)))",
     ~"(module (global (mut f64) (f64.const 0x1.8p1)))",
     ~"(module (global f32 (f32.const nan:0x200000)))",
     ~"(module (global f64 (f64.const -inf)))",
     ~"(module (type (func (param i32) (result i32))))",
     ~"(module (type (func)) (type (func (param i32 i64))))",
     ~"(module (type (struct (field i32) (field (mut i64)))))",
     ~"(module (type (array (mut i8))))",
     ~"(module (rec (type (struct)) (type (struct))))",
     ~"(module (rec (type (sub (struct))) (type (sub final (array i8)))))",
     ~"(module (memory 1) (global (mut i32) (i32.const 0)) (export \"g\" (global 0)))",
     ~"(module (global $g i32 (i32.const 7)) (export \"e\" (global $g)))",

     %% Functions: the type use in all its spellings, locals, and both ways of
     %% writing the same instructions.
     ~"(module (func))",
     ~"(module (func (result i32) (i32.const 1)))",
     ~"(module (func (result i32) i32.const 1))",
     <<"(module (func (param i32) (param i32) (result i32)"
       " local.get 0 local.get 1 i32.add))">>,
     <<"(module (func (param $a i32) (param $b i32) (result i32)"
       " (i32.add (local.get $a) (local.get $b))))">>,
     <<"(module (type (func (param i32) (result i32)))"
       " (func (type 0) local.get 0))">>,
     <<"(module (type $t (func (param i32) (result i32)))"
       " (func (type $t) (param $x i32) (result i32) local.get $x))">>,
     <<"(module (func (local i32) (local $l i64) (local f32 f64)"
       " local.get 1 drop))">>,
     ~"(module (func (export \"f\") (result i32) (i32.const 2)))",
     ~"(module (func $f) (func (call $f)))",
     ~"(module (func $f) (start $f))",

     %% Control flow, flat and folded, named and numbered.
     ~"(module (func block nop end))",
     ~"(module (func (block (result i32) (i32.const 1)) drop))",
     <<"(module (func $f (result i32) (local i32) block $b (result i32)"
       " local.get 0 br_if $b br $b end))">>,
     ~"(module (func (loop $l (br $l))))",
     ~"(module (func (param i32) (if (local.get 0) (then nop) (else nop))))",
     <<"(module (func (param i32) (result i32) (if (result i32)"
       " (local.get 0) (then (i32.const 1)) (else (i32.const 2)))))">>,
     ~"(module (func (param i32) if nop else nop end))",
     <<"(module (func (param i32) (result i32)"
       " block $a block $b local.get 0 br_table $a $b 0 end end i32.const 0))">>,
     <<"(module (func (param i32) (result i32) (block (param i32)"
       " (result i32) (i32.const 1) (i32.add))))">>,
     <<"(module (func (result i32) (i32.const 1) (i32.const 2)"
       " (i32.const 0) (select)))">>,
     <<"(module (func (result funcref) (select (result funcref)"
       " (ref.null func) (ref.null func) (i32.const 0))))">>,

     %% Memory arguments: the default alignment, an explicit one, and an
     %% explicit offset.
     ~"(module (memory 1) (func (result i32) (i32.const 0) i32.load))",
     ~"(module (memory 1) (func (result i32) (i32.const 0) (i32.load offset=4)))",
     <<"(module (memory 1) (func (result i32) (i32.const 0)"
       " (i32.load offset=4 align=1)))">>,
     ~"(module (memory 1) (func (result i64) (i32.const 0) (i64.load16_u)))",
     ~"(module (memory 1) (func (i32.const 0) (i32.const 0) (i32.store align=2)))",
     ~"(module (memory 1) (func (result i32) memory.size))",
     <<"(module (memory 1) (func (i32.const 0) (i32.const 0) (i32.const 0)"
       " memory.copy))">>,

     %% Vectors: both sixteen-byte immediates and a lane index.
     ~"(module (func (result v128) (v128.const i32x4 1 2 3 4)))",
     <<"(module (func (result v128) (v128.const i8x16 0 1 2 3 4 5 6 7"
       " 8 9 10 11 12 13 14 15)))">>,
     ~"(module (func (result v128) (v128.const f32x4 1.5 -0x1p3 inf nan)))",
     ~"(module (func (result v128) (v128.const f64x2 nan:0x4 0)))",
     <<"(module (func (result i32) (i32x4.extract_lane 2"
       " (v128.const i32x4 1 2 3 4))))">>,
     <<"(module (func (result v128) (i8x16.shuffle 0 1 2 3 4 5 6 7"
       " 8 9 10 11 12 13 14 15 (v128.const i32x4 0 0 0 0)"
       " (v128.const i32x4 0 0 0 0))))">>,
     <<"(module (memory 1) (func (result v128) (i32.const 0)"
       " (v128.load32_lane 3 (v128.const i32x4 0 0 0 0))))">>,

     %% Atomics, whose alignment must be exactly natural and so is never
     %% defaulted to something narrower.
     <<"(module (memory 1 1 shared) (func (result i32) (i32.const 0)"
       " i32.atomic.load))">>,
     <<"(module (memory 1 1 shared) (func (result i32) (i32.const 0)"
       " (i32.const 1) (i32.atomic.rmw.add)))">>,
     ~"(module (memory 1 1 shared) (func atomic.fence))",

     %% A memory addressed by i64 says so before its limits.
     ~"(module (memory i64 1 2))",

     %% Imports, written both ways, and the index space they share with the
     %% definitions that follow them.
     ~"(module (import \"m\" \"f\" (func)))",
     ~"(module (import \"m\" \"f\" (func $f (param i32) (result i32))))",
     ~"(module (import \"m\" \"t\" (table 1 2 funcref)))",
     ~"(module (import \"m\" \"mem\" (memory 1)))",
     ~"(module (import \"m\" \"g\" (global (mut i64))))",
     ~"(module (func $f (import \"m\" \"f\") (param i32)))",
     ~"(module (memory (import \"m\" \"mem\") 1 2 shared))",
     ~"(module (global $g (import \"m\" \"g\") f32))",
     <<"(module (import \"m\" \"f\" (func $i)) (func $d)"
       " (export \"a\" (func $i)) (export \"b\" (func $d))"
       " (elem (i32.const 0) $d))">>,
     <<"(module (func (export \"e\") (import \"m\" \"f\")))">>,

     %% Tables, including the abbreviation that declares a segment with them
     %% and the initialiser a non-nullable element type needs.
     ~"(module (table 1 funcref))",
     ~"(module (table $t 1 2 externref))",
     ~"(module (func $f) (table funcref (elem $f $f)))",
     <<"(module (type $t (func)) (func $f (type $t))"
       " (table (ref null $t) (elem $f)))">>,
     <<"(module (type $t (func)) (func $f (type $t))"
       " (table 1 (ref $t) (ref.func $f)))">>,

     %% Element segments in all four modes and both element forms.
     ~"(module (func $f) (table 1 funcref) (elem (i32.const 0) $f))",
     ~"(module (func $f) (table 1 funcref) (elem (offset (i32.const 0)) func $f))",
     <<"(module (func $f) (table 1 funcref) (table $t 1 funcref)"
       " (elem (table $t) (i32.const 0) funcref (item (ref.func $f))))">>,
     ~"(module (func $f) (elem func $f))",
     ~"(module (func $f) (elem declare func $f))",
     ~"(module (elem funcref (ref.null func)))",

     %% Data segments, passive and active, and the memory abbreviation.
     ~"(module (memory 1) (data (i32.const 0) \"ab\" \"cd\"))",
     ~"(module (memory 1) (data (memory 0) (offset (i32.const 4)) \"x\"))",
     ~"(module (data \"passive\"))",
     ~"(module (memory (data \"inline\")))",
     %% The data count section is present only where a data index is used.
     <<"(module (memory 1) (data \"d\") (func (i32.const 0) (i32.const 0)"
       " (i32.const 1) (memory.init 0)))">>,

     %% Tags, defined and imported.
     ~"(module (tag))",
     ~"(module (tag $e (param i32 i64)))",
     ~"(module (import \"m\" \"e\" (tag (param i32))))",
     <<"(module (tag $e) (func (try_table (catch_all 0) (throw $e))))">>,

     %% An implicit type use matches on the signature alone, so a type
     %% declared `(sub ...)' is a candidate like any other.
     <<"(module (type $t1 (sub (func))) (type $t2 (sub final (func)))"
       " (func $f1 (type $t1)) (func $f2 (type $t2)) (func))">>,

     %% Recursive groups: an empty one occupies a group, and a type declared
     %% inside one is not a candidate for somebody else's implicit type.
     ~"(module (rec) (type (func)))",
     <<"(module (rec (type $ft (func))) (func $f)"
       " (global (ref $ft) (ref.func $f)))">>,

     %% Float literals whose correct answer differs from what two roundings
     %% give: the first is the largest finite f32 and the second the smallest
     %% subnormal f64.
     ~"(module (func (f32.const 0x1.fffffefffffff8000000p127) drop))",
     <<"(module (func (result f64)"
       " (f64.const +0x0.000000000000080000000001p-1022)))">>,

     %% Garbage collection: type indices, field indices and reference types.
     <<"(module (type $s (struct (field i32)))"
       " (func (result i32) (struct.get $s 0 (struct.new $s (i32.const 1)))))">>,
     <<"(module (type $s (struct (field $x i32) (field $y i64)))"
       " (func (result i64) (struct.get $s $y"
       " (struct.new $s (i32.const 1) (i64.const 2)))))">>,
     <<"(module (type $a (array i8))"
       " (func (result i32)"
       " (array.len (array.new_default $a (i32.const 3)))))">>,
     <<"(module (type $s (struct))"
       " (func (param anyref) (result i32) (ref.test (ref $s) (local.get 0))))">>,
     ~"(module (func (result i31ref) (ref.i31 (i32.const 1))))"].

compare(Src, Dir) ->
    Base = filename:join(Dir, integer_to_list(erlang:phash2(Src))),
    ok = file:write_file(Base ++ ".wat", Src),
    case os:cmd("wasm-tools parse " ++ Base ++ ".wat -o " ++ Base ++ ".wasm 2>&1") of
        "" ->
            {ok, Bin} = file:read_file(Base ++ ".wasm"),
            {ok, Decoded} = wasm_decode:module(Bin),
            Expected = without_customs(Decoded),
            case wasm_wat:module(Src) of
                {ok, Mine} ->
                    case without_customs(Mine) of
                        Expected -> same;
                        Other -> {differs, {got, Other, wanted, Expected}}
                    end;
                {error, E} -> {differs, {error, maps:get(kind, E)}}
            end;
        Out ->
            %% wasm-tools would not compile it, so there is nothing to compare
            %% against and the case says so rather than passing quietly.
            {differs, {wasm_tools_rejected, Out}}
    end.

%% Custom sections are excluded from the comparison. They carry no semantics,
%% and `wasm-tools` emits a name section recording the identifiers a source
%% used, which is a choice that tool made rather than anything the format
%% requires. Comparing them would test the tool, not the parser.
without_customs(M) -> setelement(tuple_size(M), M, []).

%% Every module in the specification's own `.wast` sources, compared the same
%% way. Thousands of modules written by the people who wrote the format is a
%% far stronger statement than any set of cases chosen here, and it is only
%% available while both paths still exist.
%%
%% Needs a checkout of WebAssembly/testsuite beside the project, or wherever
%% `WASM_TESTSUITE` says.
parses_the_specification_corpus(Config) ->
    case suite_checkout() of
        false -> {skip, "no suite checkout: git clone --depth 1 "
                        "https://github.com/WebAssembly/testsuite.git"};
        Dir -> corpus(Dir, ?config(priv_dir, Config))
    end.

%% Three files are left out, each for a stated reason rather than because they
%% fail. Naming them is what keeps the exclusion from growing quietly.
%% The checkout `wasm_spec_runner' found, if it is really there.
suite_checkout() ->
    Dir = wasm_spec_runner:suite_dir(),
    case filelib:is_regular(filename:join(Dir, "i32.wast")) of
        true -> Dir;
        false -> false
    end.

excluded() ->
    [{"id.wast", "quoted identifiers, a proposal this runtime does not implement"},
     {"annotations.wast", "annotations, likewise"},
     {"names.wast", "wasm-tools refuses confusable Unicode in a .wat source, "
                    "which is a lint of that tool rather than a rule of the format"}].

corpus(Dir, Priv) ->
    Skip = [F || {F, _Why} <- excluded()],
    Files = [F || F <- filelib:wildcard(filename:join(Dir, "*.wast")),
                  not lists:member(filename:basename(F), Skip)],
    Modules = lists:append([modules_in(F) || F <- Files]),
    ?assertNotEqual([], Modules),
    Failures = [{Src, Why} || Src <- Modules, {differs, Why} <- [compare(Src, Priv)]],
    ct:pal("~p files, ~p modules compared, ~p differ~nexcluded:~n~s",
           [length(Files), length(Modules), length(Failures),
            [io_lib:format("  ~s: ~s~n", [F, Why]) || {F, Why} <- excluded()]]),
    ?assertEqual([], Failures).

%% Every top-level `(module ...)` in the file, sliced out of the source by
%% counting parentheses. `(module binary ...)`, `(module quote ...)`,
%% `(module definition ...)` and `(module instance ...)` are script commands
%% rather than modules, and belong to the `.wast` layer.
modules_in(Path) ->
    {ok, Bin} = file:read_file(Path),
    Spans = spans(wasm_wat_lex:scan_all(Bin), 0, undefined, []),
    [Text || {Start, End} <- Spans,
             Text <- [binary:part(Bin, Start, End - Start)],
             is_module_text(Text)].

is_module_text(<<"(module", C, Rest/binary>>) when C =:= $\s; C =:= $\n;
                                                   C =:= $\t; C =:= $\r; C =:= $) ->
    nomatch =:= binary:match(head(Rest),
                             [~"binary", ~"quote", ~"definition", ~"instance"]);
is_module_text(_Text) ->
    false.

head(Bin) -> binary:part(Bin, 0, min(24, byte_size(Bin))).

spans([], _Depth, _Start, Acc) ->
    lists:reverse(Acc);
spans([{lparen, Pos} | Rest], 0, _Start, Acc) ->
    spans(Rest, 1, Pos, Acc);
spans([{lparen, _} | Rest], Depth, Start, Acc) ->
    spans(Rest, Depth + 1, Start, Acc);
spans([{rparen, Pos} | Rest], 1, Start, Acc) ->
    spans(Rest, 0, undefined, [{Start, Pos + 1} | Acc]);
spans([{rparen, _} | Rest], Depth, Start, Acc) ->
    spans(Rest, Depth - 1, Start, Acc);
spans([_ | Rest], Depth, Start, Acc) ->
    spans(Rest, Depth, Start, Acc).

%% A literal is rounded to its width once. Rounding to an Erlang double first
%% and to the width second gives a different answer for every case here, which
%% is why the specification's float suites contain them.
float_literals_round_once(_Config) ->
    Cases =
        [%% The largest finite f32. As a double it rounds up to 2^128, and the
         %% second rounding then reads that as infinity.
         {~"0x1.fffffefffffff8000000p127", 32, 16#7F7FFFFF},
         {~"-0x1.fffffefffffff8000000p127", 32, 16#FF7FFFFF},
         %% Just above a halfway point, where rounding twice rounds down.
         {~"+0x1.00000100000000001p-50", 32, 16#26800001},
         {~"+0x1.000002fffffffffffp-50", 32, 16#26800001},
         %% Subnormal f64: two roundings lose the value entirely.
         {~"+0x0.000000000000080000000001p-1022", 64, 1},
         {~"+0x0.000000000000180000000000p-1022", 64, 2},
         {~"+0x1.000000000000280000000001p-1022", 64, 16#0010000000000003},
         %% Normal f64, one ulp apart.
         {~"+0x1.000000000000080000000001p+600", 64, 16#6570000000000001},
         %% Decimal is the same rational and gets the same treatment.
         {~"1.5", 32, 16#3FC00000},
         %% Too large to name: infinity is spelled `inf', so a literal that
         %% overflows is out of range rather than a way of writing it. Rounding
         %% down to zero is not the same case and is admitted.
         {~"1e40", 32, error},
         {~"0x1p128", 32, error},
         {~"1e-50", 32, 0}],
    Got = [{Lit, wasm_wat_num:float_bits(Lit, W)} || {Lit, W, _} <- Cases],
    Want = [{Lit, expected(Bits)} || {Lit, _, Bits} <- Cases],
    ?assertEqual(Want, Got).

expected(error) -> error;
expected(Bits) -> {ok, Bits}.

%% Reading a module correctly is not the same as refusing one that is wrong,
%% and the differential check can only see the first: it compares modules that
%% parse. These are the classes of text the specification calls malformed.
refuses_what_the_format_forbids(_Config) ->
    Cases =
        [{"a name must be valid UTF-8", ~"(module (func (export \"\\ff\")))"},
         {"tokens must be separated", ~"(module (data\"a\"))"},
         {"a literal may not end in a separator",
          ~"(module (global f32 (f32.const 1.0_)))"},
         {"a literal must name a value", ~"(module (global f32 (f32.const 1e39)))"},
         {"a lane must fit its width",
          ~"(module (func (v128.const i8x16 256 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0) drop))"},
         {"a lane index must fit a byte",
          ~"(module (func (result i32) (i8x16.extract_lane_s 256 (v128.const i32x4 0 0 0 0))))"},
         {"a lane index carries no sign",
          ~"(module (func (result i32) (i8x16.extract_lane_s +1 (v128.const i32x4 0 0 0 0))))"},
         {"a block parameter has no name",
          ~"(module (func (i32.const 0) (block (param $x i32) (drop))))"},
         {"locals come before the body", ~"(module (func (nop) (local i32)))"},
         {"results come before params", ~"(module (type (func (result i32) (param i32))))"},
         {"an inline type must match the one it names",
          ~"(module (type $s (func)) (func (block (type $s) (result i32) (i32.const 0)) (unreachable)))"},
         {"an inline type must name a type",
          ~"(module (func (type 2) (param i32)))"},
         {"imports come before definitions",
          ~"(module (func) (import \"m\" \"n\" (func)))"},
         {"a label must match the block it closes",
          ~"(module (func i32.const 0 if else $l end))"},
         {"a module has one start function",
          ~"(module (func $a) (func $b) (start $a) (start $b))"},
         {"a field is named once",
          ~"(module (type (struct (field $x i32) (field $x i64))))"},
         {"a handler belongs to a try_table", ~"(module (func (catch_all)))"},
         {"a folded condition is folded",
          ~"(module (func (if i32.const 0 (then) (else))))"}],
    Accepted = [Why || {Why, Source} <- Cases,
                       {ok, _} <- [wasm_wat:module(Source)]],
    ?assertEqual([], Accepted).

%% The atom table is node-wide and never reclaimed, so a text module must not
%% be able to add to it. An instruction name that denotes nothing is reported
%% rather than interned.
an_unknown_instruction_does_not_become_an_atom(_Config) ->
    Before = erlang:system_info(atom_count),
    ?assertMatch({error, #{kind := unknown_instruction}},
                 wasm_wat:module(~"(module (global i32 (i32.no_such_thing 1)))")),
    ?assertEqual(Before, erlang:system_info(atom_count)).

errors_carry_an_offset(_Config) ->
    {error, #{ctx := #{offset := Off}}} =
        wasm_wat:module(~"(module (memory 1)"),
    ?assertEqual(0, Off).

%% `wasm:compile/1` takes the text format, so an embedder writing a module
%% inline does not have to know that parsing and validating are two calls.
%% It has to be the *same* module the two calls produce, or the convenience
%% would be a second way to build one.
the_facade_compiles_text_too(_Config) ->
    Src = ~"""
    (module
      (memory (export "mem") 1)
      (global $g (mut i32) (i32.const 3))
      (func (export "f") (param i32) (result i32)
        local.get 0 global.get $g i32.add))
    """,
    {ok, Parsed} = wasm_wat:module(Src),
    {ok, Want} = wasm_validate:module(Parsed),
    {ok, M} = wasm:compile({wat, Src}),
    %% Everything but the identity, which is a fresh reference per build and is
    %% meant to be: text has nothing stable to key a cache on.
    ?assertEqual(Want#module{identity = undefined}, M#module{identity = undefined}),
    %% And it instantiates, which is the point of having it.
    {ok, I} = wasm:instantiate(M, #{}),
    ?assertEqual({ok, [7]}, wasm:call(I, ~"f", [4])),
    ok = wasm:destroy(I).

%% Nothing raises. The text front end already answers a value through
%% `wasm_error:capture/1'; this is that the facade does not lose it.
the_facade_answers_a_value_for_bad_text(_Config) ->
    ?assertMatch({error, #{class := _, kind := _, ctx := #{offset := _}}},
                 wasm:compile({wat, ~"(module (memory 1)"})),
    ?assertMatch({error, #{class := _, kind := _}},
                 wasm:compile({wat, ~"(module (global i32 (i32.no_such_thing 1)))"})).
