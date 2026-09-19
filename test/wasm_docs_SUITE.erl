%% @doc Every code block in the documentation, checked.
%%
%% A snippet nobody runs stops working without anybody noticing. When this
%% suite was written, `getting-started.md' could not be pasted into a shell: it
%% loaded an `add.wasm' and a `hello.wasm' the reader did not have, and bound
%% `Inst' twice. This suite reads every fenced block in the README, the
%% `## Unreleased' section of the changelog, `docs/' and the module docs, and
%% checks each one by its language. A block with no checker fails, so nothing
%% is silently unchecked.
%%
%% Erlang blocks are parsed, and every module they name is resolved against
%% the loaded code: remote calls, `fun M:F/A', `-behaviour', remote types and
%% the adapter argument of the worker start function. That is what catches a
%% rename in a block that is never run. Blocks marked `run', and every Erlang
%% block of the pages in `?RUN_PAGES', are executed in a peer node, in order,
%% sharing bindings the way a shell does.
%%
%% Annotations are an HTML comment on the line before a fence, which renders
%% as nothing on GitHub and in ex_doc:
%%
%%   <!-- check: run -->              execute this block
%%   <!-- check: parse "reason" -->   on a run page, check but do not execute
%%   <!-- check: fresh -->            forget the bindings before this block
%%   <!-- check: needs qjs -->        needs a fixture, by id (`fixture/1')
%%   <!-- check: modules my_a my_b --> modules the reader writes
%%   <!-- check: expect-exit killed --> this block may kill what it linked
%%   <!-- check: skip "reason" -->    not checked at all; listed in the log
%%
%% A run block passes when it evaluates without an exception and without an
%% abnormal exit of a process it linked. If its last line is `%% => Pattern',
%% the value must also match `Pattern'.
%%
%% Two modes. By default a block whose checker tool or fixture is missing is
%% skipped with the reason, so `rebar3 ct' passes on a machine without `luac'.
%% With `WASM_DOCS_STRICT=1' a missing tool fails, and a block whose fixture
%% is in `WASM_DOCS_FIXTURES' must run; blocks needing a fixture outside that
%% list are "not run in CI", and that set must equal `?NOT_IN_CI', so an
%% exemption cannot grow without somebody editing this file.
-module(wasm_docs_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% Pages whose Erlang blocks all run unless marked `parse'.
-define(RUN_PAGES, ["docs/getting-started.md"]).
%% Pages where no block may be skipped.
-define(START_PAGES, ["docs/getting-started.md", "docs/guests.md"]).
%% The worker start functions whose adapter argument must name an adapter, as
%% {Module, Function, Arity, ArgumentPosition}.
-define(ADAPTER_ARGS, [{wasm_script_worker, start_link, 2, 1},
                       {wasm_script_worker, start_link, 3, 2}]).
-define(ADAPTER_BEHAVIOUR, wasm_worker_adapter).
%% Blocks the strict run may not execute, as {Page, Fixture}: reviewed here.
-define(NOT_IN_CI, []).

suite() -> [{timetrap, {minutes, 15}}].

all() ->
    [every_fence_is_labelled,
     every_skip_has_a_reason,
     start_pages_skip_nothing,
     erlang_blocks_parse,
     erlang_blocks_name_what_exists,
     other_languages_parse,
     run_pages_run,
     strict_fixtures_are_accounted_for].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Root = root(),
    [{root, Root}, {blocks, blocks(Root)} | Config].

end_per_suite(_Config) ->
    ok.

%%% --------------------------------------------------------------- cases ---

every_fence_is_labelled(Config) ->
    Bad = [where(B) || #{lang := ""} = B <- all_blocks(Config)],
    ?assertEqual([], Bad, "label these fences (text, erlang, sh, ...)").

every_skip_has_a_reason(Config) ->
    Bad = [where(B) || #{ann := A} = B <- all_blocks(Config),
                       maps:get(skip, A, false) =:= ""],
    Skipped = [{where(B), R} || #{ann := #{skip := R}} = B
                                    <- all_blocks(Config)],
    ct:log("skipped blocks:~n~p", [Skipped]),
    ?assertEqual([], Bad, "a skip needs a reason").

start_pages_skip_nothing(Config) ->
    Bad = [where(B) || #{src := {file, F}, ann := #{skip := _}} = B
                           <- all_blocks(Config),
                       lists:member(F, ?START_PAGES)],
    ?assertEqual([], Bad, "no skip on a Start here page").

erlang_blocks_parse(Config) ->
    Bad = [{where(B), E} || #{lang := "erlang"} = B <- checked(Config),
                            {error, E} <- [parse_erlang(maps:get(text, B))]],
    ?assertEqual([], Bad).

erlang_blocks_name_what_exists(Config) ->
    Bad = lists:append(
            [[{where(B), R} || R <- unresolved(B)]
             || #{lang := "erlang"} = B <- checked(Config)]),
    ?assertEqual([], Bad).

other_languages_parse(Config) ->
    Root = ?config(root, Config),
    Results = [{where(B), check_other(B, Root)}
               || #{lang := L} = B <- checked(Config), L =/= "erlang"],
    Skips = [{W, R} || {W, {skip, R}} <- Results],
    ct:log("not checked here:~n~p", [Skips]),
    Bad = [{W, E} || {W, {error, E}} <- Results],
    ?assertEqual([], Bad).

run_pages_run(Config) ->
    Root = ?config(root, Config),
    Pages = lists:usort([F || #{src := {file, F}} = B <- checked(Config),
                              runs(B)]),
    Failures = lists:append([run_page(Root, P, page_blocks(Config, P))
                             || P <- Pages]),
    ?assertEqual([], Failures).

strict_fixtures_are_accounted_for(Config) ->
    case strict() of
        false ->
            {skip, "WASM_DOCS_STRICT is not set"};
        true ->
            Declared = declared_fixtures(),
            NotInCi = lists:usort(
                        [{F, N} || #{src := {file, F}, ann := #{needs := N}}
                                       <- checked(Config),
                                   not lists:member(N, Declared)]),
            ?assertEqual(lists:sort(?NOT_IN_CI), NotInCi,
                         "blocks the strict run cannot execute changed"),
            Missing = [N || N <- Declared, not fixture_present(N, root())],
            ?assertEqual([], Missing, "declared fixtures are missing")
    end.

%%% ------------------------------------------------------------ the pages ---

%% The repository root, found from the loaded application: Common Test runs
%% in its log directory, so nothing relative is assumed.
root() ->
    Root = filename:absname(filename:join([code:lib_dir(wasm),
                                           "..", "..", "..", ".."])),
    true = filelib:is_regular(filename:join(Root, "rebar.config")),
    true = filelib:is_dir(filename:join(Root, "docs")),
    Root.

blocks(Root) ->
    Files = ["README.md" | [F || F <- filelib:wildcard("docs/**/*.md", Root)]],
    FileBlocks =
        lists:append([fences({file, F}, read(Root, F)) || F <- Files]),
    Changelog = fences({file, "CHANGELOG.md"},
                       unreleased(read(Root, "CHANGELOG.md"))),
    FileBlocks ++ Changelog ++ module_doc_blocks().

read(Root, F) ->
    {ok, B} = file:read_file(filename:join(Root, F)),
    unicode:characters_to_list(B).

%% Only `## Unreleased': a released section is history and keeps the names it
%% was released with.
unreleased(Text) ->
    Lines = string:split(Text, "\n", all),
    case lists:dropwhile(fun(L) -> L =/= "## Unreleased" end, Lines) of
        [] -> "";
        [_ | Rest] ->
            Section = lists:takewhile(
                        fun(L) -> not lists:prefix("## ", L) end, Rest),
            lists:flatten(lists:join("\n", Section))
    end.

module_doc_blocks() ->
    {ok, Mods} = application:get_key(wasm, modules),
    lists:append([doc_blocks(M) || M <- Mods]).

doc_blocks(M) ->
    case code:get_doc(M) of
        {ok, {docs_v1, _, _, _, MDoc, _, Docs}} ->
            Texts = [{moduledoc, MDoc}
                     | [{{K, F, A}, D} || {{K, F, A}, _, _, D, _} <- Docs]],
            lists:append([fences({doc, M, What}, unicode:characters_to_list(T))
                          || {What, #{<<"en">> := T}} <- Texts]);
        _ ->
            []
    end.

%% A fence opens with ```lang, possibly indented, and closes with ```.
%% The annotations are the HTML comments on the lines just above it.
fences(Src, Text) ->
    Lines = lists:enumerate(string:split(Text, "\n", all)),
    fences(Src, Lines, [], []).

fences(_Src, [], _Above, Acc) ->
    lists:reverse(Acc);
fences(Src, [{N, Line} | Rest], Above, Acc) ->
    case fence_open(Line) of
        {ok, Indent, Lang} ->
            {Body, Rest1} = fence_body(Rest, Indent, []),
            B = #{src => Src, line => N, lang => Lang, text => Body,
                  ann => annotations(Above)},
            fences(Src, Rest1, [], [B | Acc]);
        nomatch ->
            Trim = string:trim(Line),
            Above1 = case Trim of
                         "<!--" ++ _ -> [Trim | Above];
                         ""          -> Above;
                         _           -> []
                     end,
            fences(Src, Rest, Above1, Acc)
    end.

fence_open(Line) ->
    case re:run(Line, "^( *)```([A-Za-z0-9_+-]*)\\s*$",
                [unicode, {capture, all_but_first, list}]) of
        {match, [Indent, Lang]} -> {ok, length(Indent), Lang};
        nomatch                 -> nomatch
    end.

fence_body([], _Indent, Acc) ->
    {lists:flatten(lists:join("\n", lists:reverse(Acc))), []};
fence_body([{_, Line} | Rest], Indent, Acc) ->
    case string:trim(Line) of
        "```" -> {lists:flatten(lists:join("\n", lists:reverse(Acc))), Rest};
        _     -> fence_body(Rest, Indent, [dedent(Line, Indent) | Acc])
    end.

dedent(Line, 0) -> Line;
dedent(" " ++ Line, N) -> dedent(Line, N - 1);
dedent(Line, _) -> Line.

annotations(Comments) ->
    lists:foldl(fun annotation/2, #{}, Comments).

annotation(C, Acc) ->
    case re:run(C, "^<!--\\s*check:\\s*([a-z-]+)\\s*(.*?)\\s*-->$",
                [unicode, {capture, all_but_first, list}]) of
        {match, ["run", _]}         -> Acc#{run => true};
        {match, ["fresh", _]}       -> Acc#{fresh => true};
        {match, ["parse", R]}       -> Acc#{parse => unquote(R)};
        {match, ["skip", R]}        -> Acc#{skip => unquote(R)};
        {match, ["needs", F]}       -> Acc#{needs => list_to_atom(F)};
        {match, ["modules", Ms]}    ->
            Acc#{modules => [list_to_atom(M) || M <- string:lexemes(Ms, " ")]};
        {match, ["expect-exit", R]} ->
            Acc#{expect_exit => [list_to_atom(X)
                                 || X <- string:lexemes(R, " ")]};
        _ ->
            Acc
    end.

unquote("\"" ++ R) -> string:trim(R, trailing, "\"");
unquote(R)         -> R.

%%% ------------------------------------------------------------ filtering ---

all_blocks(Config) -> ?config(blocks, Config).

%% Everything not skipped, and not waiting for a missing fixture in default
%% mode. In strict mode a missing declared fixture is an error, reported by
%% the case that needs it.
checked(Config) ->
    [B || #{ann := A} = B <- all_blocks(Config), not maps:is_key(skip, A)].

page_blocks(Config, Page) ->
    [B || #{src := {file, F}} = B <- checked(Config), F =:= Page].

runs(#{lang := "erlang", src := {file, F}, ann := A}) ->
    not maps:is_key(parse, A) andalso
        (maps:get(run, A, false) orelse lists:member(F, ?RUN_PAGES));
runs(_) ->
    false.

where(#{src := {file, F}, line := N}) -> {F, N};
where(#{src := {doc, M, What}, line := N}) -> {M, What, N}.

%%% --------------------------------------------------------------- erlang ---

%% A block is a sequence of forms, expressions or terms, each ending in a dot.
%% A missing final dot is supplied, since a block often shows one expression.
%%
%% Two kinds of excerpt are accepted and still checked: the entries of an
%% options map shown without the `#{...}' around them (`dirs => [...]'), and an
%% expression list cut off at a comma, where the page goes on to explain the
%% next line. A macro is read as the atom it names, which is all a reference
%% check needs.
parse_erlang(Text) ->
    case erl_scan:string(Text) of
        {ok, Toks, _} ->
            Results = [parse_chunk(C) || C <- chunks(unmacro(Toks))],
            case [E || {error, E} <- Results] of
                []      -> {ok, lists:append([F || {ok, F} <- Results])};
                [E | _] -> {error, E}
            end;
        {error, E, _} ->
            {error, {scan, E}}
    end.

unmacro([{'?', L}, {T, _, N} | Rest]) when T =:= atom; T =:= var ->
    [{atom, L, N} | unmacro(Rest)];
unmacro([Tok | Rest]) -> [Tok | unmacro(Rest)];
unmacro([]) -> [].

%% An attribute is tried as a form first: `-behaviour(m).' also parses as an
%% expression, unary minus applied to a call, and would hide the reference.
parse_chunk([{'-', _}, {atom, _, _}, {'(', _} | _] = C) ->
    first_ok([fun() -> as_list(erl_parse:parse_form(C)) end,
              fun() -> erl_parse:parse_exprs(C) end]);
parse_chunk(C) ->
    first_ok([fun() -> erl_parse:parse_exprs(C) end,
              fun() -> as_list(erl_parse:parse_form(C)) end,
              fun() -> erl_parse:parse_exprs(as_map(C)) end,
              fun() -> erl_parse:parse_exprs(without_trailing_comma(C)) end]).

first_ok([F]) -> F();
first_ok([F | Rest]) ->
    case F() of
        {ok, _} = Ok -> Ok;
        {error, _}   -> first_ok(Rest)
    end.

as_list({ok, F})  -> {ok, [F]};
as_list(E)        -> E.

as_map(C) ->
    {Body, [{dot, L}]} = lists:split(length(C) - 1, C),
    [{'#', L}, {'{', L}] ++ Body ++ [{'}', L}, {dot, L}].

without_trailing_comma(C) ->
    case lists:reverse(C) of
        [{dot, L}, {',', _} | Rest] -> lists:reverse([{dot, L} | Rest]);
        _                           -> C
    end.

chunks(Toks) -> wasm_docs_eval:chunks(Toks).

%% Every module the block names must exist and export what it names.
unresolved(#{text := Text, ann := A}) ->
    case parse_erlang(Text) of
        {ok, Forms} ->
            Own = maps:get(modules, A, []),
            Refs = lists:usort(refs(Forms)),
            [R || R <- Refs, not resolves(R, Own)];
        {error, _} ->
            []
    end.

refs(T) -> refs(T, []).

refs({call, _, {remote, _, {atom, _, M}, {atom, _, F}}, Args} = C, Acc) ->
    Adapter = adapter_ref(M, F, Args),
    refs(Args, refs(element(3, C), Adapter ++ [{call, M, F, length(Args)}
                                               | Acc]));
refs({'fun', _, {function, {atom, _, M}, {atom, _, F}, {integer, _, A}}},
     Acc) ->
    [{call, M, F, A} | Acc];
refs({attribute, _, B, M}, Acc) when B =:= behaviour; B =:= behavior,
                                     is_atom(M) ->
    [{behaviour, M} | Acc];
refs({remote_type, _, [{atom, _, M}, {atom, _, T}, Args]}, Acc) ->
    refs(Args, [{type, M, T, length(Args)} | Acc]);
refs(T, Acc) when is_tuple(T) -> refs(tuple_to_list(T), Acc);
refs(L, Acc) when is_list(L) -> lists:foldl(fun refs/2, Acc, L);
refs(_, Acc) -> Acc.

adapter_ref(M, F, Args) ->
    [{adapter, A} || {M1, F1, Ar, Pos} <- ?ADAPTER_ARGS,
                     M1 =:= M, F1 =:= F, Ar =:= length(Args),
                     {atom, _, A} <- [lists:nth(Pos, Args)]].

resolves(R, Own) ->
    Mod = case R of
              {call, M, _, _} -> M;
              {type, M, _, _} -> M;
              {behaviour, M}  -> M;
              {adapter, M}    -> M
          end,
    lists:member(Mod, Own) orelse known(R).

known({call, M, F, A}) ->
    loaded(M) andalso
        (erlang:function_exported(M, F, A) orelse erlang:is_builtin(M, F, A));
known({behaviour, M}) ->
    loaded(M) andalso erlang:function_exported(M, behaviour_info, 1);
known({type, M, T, A}) ->
    loaded(M) andalso type_exported(M, T, A);
known({adapter, M}) ->
    loaded(M) andalso
        lists:member(?ADAPTER_BEHAVIOUR,
                     lists:append([B || {behaviour, B}
                                            <- M:module_info(attributes)])).

loaded(M) -> code:ensure_loaded(M) =:= {module, M}.

%% From the abstract code where the beam carries it, and from the docs chunk
%% otherwise. A module with neither, such as some of OTP, is taken on trust.
type_exported(M, T, A) ->
    case code:where_is_file(atom_to_list(M) ++ ".beam") of
        non_existing -> true;
        Path ->
            case beam_lib:chunks(Path, [abstract_code]) of
                {ok, {_, [{abstract_code, {_, Forms}}]}} ->
                    lists:member({T, A},
                                 lists:append([Ts || {attribute, _,
                                                      export_type, Ts}
                                                         <- Forms]));
                _ ->
                    case code:get_doc(M) of
                        {ok, {docs_v1, _, _, _, _, _, Docs}} ->
                            lists:keymember({type, T, A}, 1, Docs);
                        _ ->
                            true
                    end
            end
    end.

%%% -------------------------------------------------------- other languages ---

check_other(#{lang := L}, _Root)
  when L =:= "text"; L =:= "mermaid"; L =:= "console" ->
    ok;
check_other(#{lang := "sh", text := T}, Root) ->
    case missing_scripts(T, Root) of
        [] -> tool("bash", fun(Bash) -> run_tool(Bash, ["-n"], ".sh", T) end);
        Ms -> {error, {missing_scripts, Ms}}
    end;
check_other(#{lang := "wat", text := T}, _Root) ->
    case wasm:compile({wat, unicode:characters_to_binary(T)}) of
        {ok, _}    -> ok;
        {error, E} -> {error, E}
    end;
check_other(#{lang := "json", text := T}, _Root) ->
    json_ok([T]);
check_other(#{lang := "jsonl", text := T}, _Root) ->
    json_ok([L || L <- string:split(T, "\n", all), string:trim(L) =/= ""]);
check_other(#{lang := "javascript", text := T}, _Root) ->
    tool("node", fun(N) -> run_tool(N, ["--check"], ".mjs", T) end);
check_other(#{lang := "python", text := T}, _Root) ->
    tool("python3",
         fun(P) ->
                 run_tool(P, ["-c", "import ast,sys; "
                                    "ast.parse(open(sys.argv[1]).read())"],
                          ".py", T)
         end);
check_other(#{lang := "lua", text := T}, _Root) ->
    tool(["luac", "luac5.4"], fun(L) -> run_tool(L, ["-p"], ".lua", T) end);
check_other(#{lang := "rust", text := T}, _Root) ->
    tool("rustc",
         fun(R) ->
                 Out = scratch("rust-out"),
                 run_tool(R, ["--crate-type", "lib", "--emit", "metadata",
                              "-o", Out], ".rs", T)
         end);
check_other(#{lang := "c", text := T}, _Root) ->
    tool("cc", fun(C) -> run_tool(C, ["-fsyntax-only"], ".c", T) end);
check_other(#{lang := L}, _Root) ->
    {error, {no_checker_for, L}}.

json_ok(Docs) ->
    try
        _ = [json:decode(unicode:characters_to_binary(D)) || D <- Docs],
        ok
    catch
        _:E -> {error, {json, E}}
    end.

missing_scripts(T, Root) ->
    case re:run(T, "(?:^|[\\s./])(scripts/[A-Za-z0-9_.-]+)",
                [unicode, global, {capture, all_but_first, list}]) of
        {match, Ms} ->
            [S || [S] <- lists:usort(Ms),
                  not filelib:is_regular(filename:join(Root, S))];
        nomatch ->
            []
    end.

%% A missing tool skips the block by default and fails it in strict mode.
tool(Names, Fun) when is_list(hd(Names)) ->
    case [P || N <- Names, P <- [os:find_executable(N)], P =/= false] of
        [Path | _] -> Fun(Path);
        []         -> missing_tool(Names)
    end;
tool(Name, Fun) ->
    tool([Name], Fun).

missing_tool(Names) ->
    case strict() of
        true  -> {error, {tool_missing, Names}};
        false -> {skip, {tool_missing, Names}}
    end.

run_tool(Exe, Args, Ext, Text) ->
    File = scratch("block" ++ Ext),
    ok = file:write_file(File, unicode:characters_to_binary(Text)),
    Port = open_port({spawn_executable, Exe},
                     [{args, Args ++ [File]}, exit_status, stderr_to_stdout,
                      binary]),
    collect(Port, <<>>).

collect(Port, Acc) ->
    receive
        {Port, {data, D}}         -> collect(Port, <<Acc/binary, D/binary>>);
        {Port, {exit_status, 0}}  -> ok;
        {Port, {exit_status, S}}  -> {error, {exit, S, Acc}}
    after 60000 ->
        {error, {timeout, Acc}}
    end.

scratch(Name) ->
    Dir = filename:join(filename:basedir(user_cache, "erlang_wasm"),
                        "docs-check"),
    ok = filelib:ensure_path(Dir),
    filename:join(Dir, Name).

%%% ------------------------------------------------------------- running ---

%% One peer node per page, working directory at the repository root, the
%% application started, and one evaluator for the whole page.
run_page(Root, Page, Blocks) ->
    case [B || B <- Blocks, runs(B)] of
        []   -> [];
        Runs ->
            case [N || #{ann := #{needs := N}} <- Runs,
                       not fixture_present(N, Root)] of
                [] ->
                    run_blocks(Root, Page, Runs);
                Missing ->
                    case strict() andalso
                         lists:any(fun(N) ->
                                       lists:member(N, declared_fixtures())
                                   end, Missing) of
                        true  -> [{Page, {fixture_missing, Missing}}];
                        false -> ct:log("~ts not run: missing ~p",
                                        [Page, Missing]),
                                 []
                    end
            end
    end.

run_blocks(Root, Page, Runs) ->
    Paths = lists:append([["-pa", D] || D <- code:get_path()]),
    {ok, Peer, _} = peer:start_link(#{connection => standard_io,
                                      args => Paths}),
    try
        ok = peer:call(Peer, file, set_cwd, [Root]),
        {ok, _} = peer:call(Peer, application, ensure_all_started, [wasm]),
        Eval = peer:call(Peer, wasm_docs_eval, start, []),
        Fails = run_each(Peer, Eval, Page, Runs, []),
        Final = peer:call(Peer, wasm_docs_eval, finish, [Eval], 10000),
        Fails ++ [{Page, end_of_page, E} || {error, E} <- [Final]]
    after
        peer:stop(Peer)
    end.

run_each(_Peer, _Eval, _Page, [], Acc) ->
    lists:reverse(Acc);
run_each(Peer, Eval0, Page, [B | Rest], Acc) ->
    #{text := T, ann := A} = B,
    Eval = case maps:get(fresh, A, false) of
               true  -> peer:call(Peer, wasm_docs_eval, start, []);
               false -> Eval0
           end,
    Result = peer:call(Peer, wasm_docs_eval, run,
                       [Eval, where(B), T, expectation(T),
                        maps:get(expect_exit, A, [])], 600000),
    Acc1 = case Result of
               ok         -> Acc;
               {error, E} -> [{where(B), E} | Acc]
           end,
    run_each(Peer, Eval, Page, Rest, Acc1).

%% `%% => Pattern' on the last non-empty line.
expectation(Text) ->
    Lines = [string:trim(L) || L <- string:split(Text, "\n", all),
                               string:trim(L) =/= ""],
    case lists:reverse(Lines) of
        ["%% =>" ++ P | _] -> string:trim(P);
        _                  -> none
    end.

%%% ------------------------------------------------------------ fixtures ---

fixture(qjs)            -> ["test/fixtures/lang/qjs.wasm"];
fixture(python)         -> ["test/fixtures/lang/python.wasm"];
fixture(qjs_reactor)    -> ["test/fixtures/lang/qjs_reactor.wasm"];
fixture(lua_reactor)    -> ["test/fixtures/lang/lua_reactor.wasm"];
fixture(python_reactor) -> ["test/fixtures/lang/py_reactor.wasm",
                            "test/fixtures/lang/py_reactor_lib"].

fixture_present(Id, Root) ->
    lists:all(fun(P) -> filelib:is_file(filename:join(Root, P)) end,
              fixture(Id)).

strict() -> os:getenv("WASM_DOCS_STRICT") =:= "1".

declared_fixtures() ->
    case os:getenv("WASM_DOCS_FIXTURES") of
        false -> [];
        S     -> [list_to_atom(F) || F <- string:lexemes(S, ",")]
    end.
