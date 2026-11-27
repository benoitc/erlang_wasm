%% @doc The official WebAssembly specification test suite, as a regression gate.
%%
%% Suites are read from a checkout of the upstream sources, which
%% `wasm_spec_runner' finds beside the project or wherever `WASM_TESTSUITE'
%% says.
%% Nothing is generated and no tool is needed:
%%
%% ```
%% scripts/fetch-suites.sh
%% '''
%%
%% Each phase runs the core suites (see `wasm_spec_manifest') and compares the
%% per-suite failure count against a recorded baseline. Failures may go down
%% freely; going up fails the build, and so does going *down* without updating
%% the baseline, because a silently improving ceiling stops catching anything.
%%
%% The baseline is per suite rather than one total, so a fix in one area cannot
%% mask a regression in another.
-module(wasm_spec_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [decode_phase, validate_phase, execute_phase, compiled_phase,
     unfused_phase, unfused_compiled_phase, encode_phase,
     encode_execute_phase, wasm_tools_validates_what_is_encoded,
     byte_match_with_wasm_tools_is_reported, core_suites_present].

%% What the execute phase must reach, measured on this tree.
%%
%% A floor and not an equality, because fixing something is allowed to raise it
%% and the number then gets updated here. It exists because the failure count
%% alone cannot see coverage disappearing: a `wasm_wast' regression that stopped
%% recognising a directive form moves assertions from passing to *skipped*, and
%% a suite that only watches failures stays green while it happens.
-define(EXECUTE_PASS_FLOOR, 65481).

%% The compiled phase must actually reach generated code.
%%
%% Every failure in the tier's design falls back to interpreting, so a green
%% compiled phase is entirely consistent with having compiled nothing at all.
%% These are floors on `wasm_jit:counts/0', measured on this tree at 4894
%% functions compiled and 47453 entries into generated code, set low enough
%% that ordinary drift does not trip them and high enough that a phase which
%% silently degraded to the interpreter fails.
-define(COMPILED_FUNS_FLOOR, 4000).

%% How many modules the encode phase must round-trip, so a phase that stopped
%% building them, and so checked nothing, fails. Measured on this tree at
%% 5104, from bytes and from text, the invalid ones included.
-define(ENCODED_FLOOR, 5000).
%% The valid ones among them, which `wasm-tools validate' reads: 2311 here.
-define(VALID_MODULES_FLOOR, 2300).
-define(COMPILED_ENTRIES_FLOOR, 40000).

%% Compile eagerly, synchronously, and loudly.
%%
%% Each of the three is the opposite of what an embedder wants and exactly what
%% a test that means to check generated code needs. See `wasm_jit'.
opts() ->
    #{compile => true,        % the tier at all
      compile_sync => true,   % on this process, so the next call is compiled
      compile_after => 1,     % hot immediately; spec modules are called once
      compile_whole => true,  % every function, not only the one that ran
      compile_force => true}. % a compile error raises instead of interpreting

%% Known-failing counts. Every entry must name a specific unimplemented
%% proposal, and must have been checked to fail *because of* it. An entry that
%% cannot be attributed is a defect to fix, not a number to record.
%%
%% Reading this list back to its causes is what found the five linking defects
%% fixed in `wasm_linking_SUITE'. A baseline entry naming a proposal while a
%% real defect sits behind it is the failure mode a baseline has, and nothing
%% here detects it automatically.
%%
baseline() -> #{}.

%% Decoding and validation must be clean: at these phases the only permitted
%% failures are modules using unsupported proposals.
decode_baseline() -> #{}.

validate_baseline() -> #{}.

init_per_suite(Config) ->
    case filelib:is_regular(filename:join(wasm_spec_runner:suite_dir(), "i32.wast")) of
        false ->
            {skip, "no suite checkout: run scripts/fetch-suites.sh"};
        true ->
            %% The three interpreter phases run without the application, which
            %% is why this was missing for as long as it was. `compiled_phase'
            %% does not: the tier needs `wasm_code_slots' and `wasm_jit_sup',
            %% and without them every module command dies on a `noproc' and the
            %% phase reports one failure per suite. Running the whole test run
            %% hid it, because some other suite had already started the
            %% application in the same node.
            {ok, _} = application:ensure_all_started(wasm),
            Config
    end.

end_per_suite(_Config) -> ok.

decode_phase(_Config) ->
    check_phase([decode], decode_baseline(), strict).

validate_phase(_Config) ->
    check_phase([decode, validate], validate_baseline(), strict).

execute_phase(_Config) ->
    Results = check_phase([decode, validate, execute], baseline(), strict),
    no_skips(Results),
    pass_floor(Results, ?EXECUTE_PASS_FLOOR).

%% @doc The same specification, run through generated code.
%%
%% The tier is a second execution engine. It lowers loads, stores, widening and
%% arithmetic itself rather than calling the interpreter's, and until this case
%% existed all 65,481 assertions ran in the interpreter and none of them in
%% generated code: the tier's whole correctness argument rested on about fifteen
%% hand-written cases. Wasmtime runs its suite once per execution strategy for
%% this reason.
%%
%% It works the first time it is asked. `i32.shr_u(-1, 32)` answered 4294967295
%% where the specification says -1, because the generated form shifted the
%% unsigned reinterpretation and never wrapped it back; every nonzero shift
%% count happened to be right, so nothing else had caught it.
%%
%% A function the generator refuses is interpreted, so this cannot report fewer
%% passes than `execute_phase'. What it can report is fewer *entries* into
%% generated code, which is why the counts are asserted.
compiled_phase(_Config) ->
    ok = wasm_jit:reset_counts(),
    Results = check_phase([decode, validate, execute], baseline(), strict,
                          opts()),
    no_skips(Results),
    pass_floor(Results, ?EXECUTE_PASS_FLOOR),
    #{compiled := Funs, entered := Entries} = Counts = wasm_jit:counts(),
    ct:log("through the compiled tier: ~p", [Counts]),
    ?assert(Funs >= ?COMPILED_FUNS_FLOOR),
    ?assert(Entries >= ?COMPILED_ENTRIES_FLOOR).

%% Both again with `fuse => false'. Fusion is a choice made per instance and
%% lowered bodies are cached per process and per module, so every cache that
%% holds a body has to keep the two apart, and the answers must not depend on
%% which one ran.
unfused_phase(_Config) ->
    Results = check_phase([decode, validate, execute], baseline(), strict,
                          #{fuse => false}),
    no_skips(Results),
    pass_floor(Results, ?EXECUTE_PASS_FLOOR).

unfused_compiled_phase(_Config) ->
    Results = check_phase([decode, validate, execute], baseline(), strict,
                          (opts())#{fuse => false}),
    no_skips(Results),
    pass_floor(Results, ?EXECUTE_PASS_FLOOR).

%% Every module the core suites build, from bytes or from text, through the
%% encoder: `decode(encode(M))' is `M' apart from its identity, and encoding
%% that again gives the same bytes. Validation is on so that the modules the
%% suites expect to be invalid are built, and round-tripped, too. Nothing may
%% fail: the baseline is the decoder's, which is empty.
encode_phase(_Config) ->
    Results = check_phase([decode, encode, validate], validate_baseline(), strict),
    Encoded = lists:sum([E || #{encoded := E} <- Results]),
    ct:log("~p modules round-tripped through the encoder", [Encoded]),
    ?assert(Encoded >= ?ENCODED_FLOOR).

%% The specification run again on the round-tripped modules. The bytes the
%% encoder wrote are what the interpreter runs, so a wrong encoding that still
%% decoded to some module is caught by what that module does.
encode_execute_phase(_Config) ->
    Results = check_phase([decode, encode, validate, execute], baseline(), strict),
    no_skips(Results),
    pass_floor(Results, ?EXECUTE_PASS_FLOOR).

%% Another implementation reads the bytes too. Every module the core suites
%% mean to be valid, encoded, is valid to `wasm-tools validate', so an
%% encoding this decoder reads but the format does not allow is caught.
wasm_tools_validates_what_is_encoded(Config) ->
    case os:find_executable("wasm-tools") of
        false ->
            {skip, "wasm-tools is not on the path, so no other tool read the encoded modules"};
        Tool ->
            Dir = filename:join(?config(priv_dir, Config), "validate"),
            ok = filelib:ensure_dir(filename:join(Dir, "x")),
            Checked = [validate_with(Tool, Dir, S, L, Src)
                       || S <- wasm_spec_manifest:core(),
                          {_, L, Src} <- wasm_spec_runner:module_commands(S)],
            Refused = [R || {refused, _, _, _} = R <- Checked],
            ct:log("~p modules encoded and validated by wasm-tools, ~p refused",
                   [length([ok || ok <- Checked]), length(Refused)]),
            ?assertEqual([], Refused),
            ?assert(length(Checked) >= ?VALID_MODULES_FLOOR)
    end.

validate_with(Tool, Dir, Suite, Line, Src) ->
    {ok, M} = wasm_spec_runner:module_of(Src),
    {ok, Bin} = wasm_encode:module(M),
    File = filename:join(Dir, binary_to_list(Suite) ++ "." ++ integer_to_list(Line) ++ ".wasm"),
    ok = file:write_file(File, Bin),
    case os:cmd(Tool ++ " validate --features all " ++ File ++ " 2>&1") of
        [] -> ok;
        Out -> {refused, Suite, Line, Out}
    end.

%% How many of the modules the suites write as text encode byte for byte as
%% `wasm-tools parse' does, once `wasm-tools strip --all' has taken its name
%% section away. Reported, never gated: where the two differ is where this
%% encoder's choice of encoding differs from the reference tool's, and the
%% kinds are counted by the first section in which the bytes differ, and by
%% whether the two decode to the same module.
%%
%% Measured with wasm-tools 1.256: 1987 of 2174 the same. The rest decode to
%% the same module and differ in two choices. 178 name table 0 in an element
%% segment, which wasm-tools writes with the table index (form 2) when the text
%% names the table and this writes without it (form 0). 8 declare a recursive
%% group of one type, which wasm-tools writes as `rec' and this writes as the
%% type alone. `type-subtyping' is not compared: that wasm-tools cannot read it.
byte_match_with_wasm_tools_is_reported(Config) ->
    case os:find_executable("wasm-tools") of
        false ->
            {skip, "wasm-tools is not on the path, so there was nothing to compare with"};
        Tool ->
            Dir = filename:join(?config(priv_dir, Config), "bytes"),
            ok = filelib:ensure_dir(filename:join(Dir, "x")),
            Rows = lists:append([match_suite(Tool, Dir, S)
                                 || S <- wasm_spec_manifest:core()]),
            Same = length([x || {_, _, same} <- Rows]),
            Kinds = lists:foldl(fun({_, _, K}, Acc) -> maps:update_with(K, fun(N) -> N + 1 end, 1, Acc) end,
                                #{}, [R || {_, _, K} = R <- Rows, K =/= same]),
            Examples = maps:from_list([{K, {binary_to_list(S), L}}
                                       || {S, L, K} <- lists:reverse(Rows), K =/= same]),
            ct:log("text modules compared: ~p, byte for byte the same: ~p~n"
                   "differences, by the first section that differs: ~p~n"
                   "one example of each: ~p",
                   [length(Rows), Same, Kinds, Examples]),
            {comment, io_lib:format("~p of ~p text modules byte for byte as wasm-tools",
                                    [Same, length(Rows)])}
    end.

%% A suite's text modules against the binaries `json-from-wast' wrote for them.
%% The two command lists are lined up by position; a suite where they do not
%% have the same number of modules is reported as misaligned rather than
%% guessed at.
match_suite(Tool, Dir, Suite) ->
    Out = filename:join(Dir, binary_to_list(Suite)),
    ok = filelib:ensure_dir(filename:join(Out, "x")),
    Json = filename:join(Out, "commands.json"),
    _ = os:cmd(Tool ++ " json-from-wast " ++ wasm_spec_runner:suite_path(Suite)
               ++ " -o " ++ Json ++ " --wasm-dir " ++ Out ++ " 2>&1"),
    Ours = wasm_spec_runner:module_commands(Suite),
    case file:read_file(Json) of
        {error, _} -> [{Suite, 0, json_from_wast_failed}];
        {ok, J} ->
            #{<<"commands">> := Cmds} = json:decode(J),
            Theirs = [C || #{<<"type">> := T} = C <- Cmds,
                           T =:= <<"module">> orelse T =:= <<"module_definition">>],
            case length(Theirs) =:= length(Ours) of
                false -> [{Suite, 0, misaligned}];
                true ->
                    [{Suite, L, compare(Tool, Out, Src, C)}
                     || {{_, L, {form, _} = Src}, C} <- lists:zip(Ours, Theirs)]
            end
    end.

compare(Tool, Out, Src, #{<<"filename">> := Name}) ->
    Theirs = filename:join(Out, binary_to_list(Name)),
    Stripped = Theirs ++ ".stripped",
    _ = os:cmd(Tool ++ " strip --all " ++ Theirs ++ " -o " ++ Stripped ++ " 2>&1"),
    case {wasm_spec_runner:module_of(Src), file:read_file(Stripped)} of
        {{ok, M}, {ok, Ref}} ->
            {ok, Ours} = wasm_encode:module(M),
            case Ours =:= Ref of
                true -> same;
                false ->
                    {first_difference(sections(Ours), sections(Ref)),
                     case wasm_decode:module(Ours) =:= wasm_decode:module(Ref) of
                         true -> same_module;
                         false -> different_module
                     end}
            end;
        {{error, _}, _} -> ours_did_not_parse;
        {_, {error, _}} -> theirs_not_written
    end;
compare(_Tool, _Out, _Src, _Cmd) ->
    no_binary.

sections(<<"\0asm", 1:32/little, Rest/binary>>) -> sections_(Rest).

sections_(<<>>) -> [];
sections_(<<Id, Rest0/binary>>) ->
    {Size, Rest1} = wasm_leb128:u32(Rest0),
    <<Body:Size/binary, Rest/binary>> = Rest1,
    [{Id, Body} | sections_(Rest)].

first_difference([S | A], [S | B]) -> first_difference(A, B);
first_difference([{Id, _} | _], [{Id, _} | _]) -> {section, section_name(Id)};
first_difference([{A, _} | _], [{B, _} | _]) -> {sections, section_name(A), section_name(B)};
first_difference([], [{Id, _} | _]) -> {only_theirs, section_name(Id)};
first_difference([{Id, _} | _], []) -> {only_ours, section_name(Id)}.

section_name(Id) ->
    element(Id + 1, {custom, type, import, function, table, memory, global,
                     export, start, element, code, data, data_count, tag}).

end_per_testcase(Phase, _Config) when Phase =:= compiled_phase;
                                      Phase =:= unfused_compiled_phase ->
    %% The phase leaves sixteen slots full of generated code and their call
    %% counters raised. Anything after it in the same node would inherit that.
    wasm_test_slots:reset();
end_per_testcase(_Case, _Config) ->
    ok.

%% Every core suite must actually have fixtures. A missing one means fixture
%% generation silently dropped a file, which would quietly shrink coverage
%% while every other test still passed.
%%
%% Suites present but unclassified are only logged. The upstream test suite
%% tracks the living specification and grows files for new proposals
%% constantly, so failing the build on them would mean the build breaks
%% whenever somebody else lands a proposal.
core_suites_present(_Config) ->
    Available = wasm_spec_runner:suites(),
    Missing = wasm_spec_manifest:core() -- Available,
    Unclassified = [S || S <- Available,
                         wasm_spec_manifest:classify(S) =:= unclassified],
    ct:log("unclassified suites (informational, ~p): ~p",
           [length(Unclassified), Unclassified]),
    ?assertEqual([], Missing).

%%% ---------------------------------------------------------------- helpers ---

check_phase(Phases, Baseline, Strictness) ->
    check_phase(Phases, Baseline, Strictness, #{}).

%% Answers the results, so a caller can assert on more than the failure count.
check_phase(Phases, Baseline, Strictness, Opts) ->
    Results = wasm_spec_runner:run_all(wasm_spec_manifest:core(), Phases, Opts),
    ct:log("~s", [wasm_spec_runner:format_report(Results)]),
    Regressions = [{S, F, maps:get(S, Baseline, 0)}
                   || #{suite := S, fail := F} <- Results,
                      F > maps:get(S, Baseline, 0)],
    log_failures(Results, Regressions),
    ?assertEqual([], Regressions),
    case Strictness of
        strict -> check_stale_baseline(Results, Baseline);
        lenient -> ok
    end,
    Results.

%% No command may be skipped once execution is enabled.
%%
%% Only at that point: `decode_phase' and `validate_phase' skip every execution
%% command by design, so this is not a rule the earlier phases can obey. The
%% runner's `command(_Other, St) -> bump_skip(St)' catch-all is what makes it
%% worth asserting, since an unrecognised directive is counted rather than
%% failed and would otherwise shrink coverage in silence.
no_skips(Results) ->
    Skipped = [{S, N} || #{suite := S, skip := N} <- Results, N > 0],
    ?assertEqual([], Skipped).

%% Coverage may grow. It may not shrink without somebody saying so here.
pass_floor(Results, Floor) ->
    Total = lists:sum([P || #{pass := P} <- Results]),
    ct:log("~p assertions passed (floor ~p)", [Total, Floor]),
    ?assert(Total >= Floor).

%% A baseline entry that is now too generous is reported so it gets tightened.
%% Left alone, an obsolete ceiling would let a genuine regression back in.
check_stale_baseline(Results, Baseline) ->
    Actual = maps:from_list([{S, F} || #{suite := S, fail := F} <- Results]),
    Stale = [{S, Allowed, maps:get(S, Actual, 0)}
             || {S, Allowed} <- maps:to_list(Baseline),
                maps:get(S, Actual, 0) < Allowed],
    case Stale of
        [] -> ok;
        _ -> ct:fail({baseline_too_generous, Stale})
    end.

log_failures(_Results, []) -> ok;
log_failures(Results, Regressions) ->
    Named = maps:from_list([{maps:get(suite, R), R} || R <- Results]),
    lists:foreach(
      fun({S, Got, Allowed}) ->
          #{failures := Fs} = maps:get(S, Named),
          ct:log("~s regressed (~p failures, baseline ~p):~n~p", [S, Got, Allowed, Fs])
      end, Regressions).
