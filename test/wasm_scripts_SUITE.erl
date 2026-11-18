%% @doc The part of the fixture build scripts that can be run without the
%% toolchain.
%%
%% `scripts/build-python-reactor.sh' asks CPython's Makefile for the
%% `python.wasm' link line rather than copying it. Once `python.wasm' existed
%% and was up to date, `make -n' answered "is up to date" instead, and that
%% sentence went to a shell. `scripts/python-link-line.sh' is that step on
%% its own, so this suite can run it against a Makefile of its own making.
-module(wasm_scripts_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("kernel/include/file.hrl").

all() -> [{group, link_line}, {group, pins}].

groups() ->
    [{link_line, [], [the_link_line_is_found_when_python_wasm_is_up_to_date,
                      a_makefile_without_the_target_fails_clearly]},
     {pins, [], [a_missing_checkout_is_fetched_at_its_commit,
                 a_missing_checkout_is_fetched_at_its_tag,
                 a_checkout_at_its_pin_is_left_alone,
                 a_clean_checkout_elsewhere_is_moved_to_its_pin,
                 a_changed_checkout_elsewhere_stops_the_script,
                 a_directory_that_is_not_a_checkout_stops_the_script]}].

init_per_suite(Config) -> Config.

end_per_suite(_) -> ok.

init_per_group(link_line, Config) -> needs("make", Config);
init_per_group(pins, Config) -> needs("git", Config).

end_per_group(_, _) -> ok.

%% Each case its own directory: the source and the checkout are made fresh.
init_per_testcase(Case, Config) ->
    Dir = filename:join(?config(priv_dir, Config), atom_to_list(Case)),
    ok = filelib:ensure_path(Dir),
    [{case_dir, Dir} | Config].

end_per_testcase(_, _) -> ok.

needs(Tool, Config) ->
    case os:find_executable(Tool) of
        false -> {skip, "no " ++ Tool ++ " on PATH"};
        _ -> Config
    end.

-define(LINK, "clang -o python.wasm Programs/python.o -lm").

the_link_line_is_found_when_python_wasm_is_up_to_date(Config) ->
    Dir = build_dir(Config, "python.wasm: Programs/python.o\n\t" ?LINK "\n"),
    Object = filename:join([Dir, "Programs", "python.o"]),
    ok = file:write_file(Object, <<>>),
    ok = file:write_file(filename:join(Dir, "python.wasm"), <<>>),
    %% The object ten seconds older than the target: make has nothing to do,
    %% which is the state a second build run finds.
    ok = age(Object, 10),
    ?assertEqual({0, ?LINK "\n"}, run(Dir)).

a_makefile_without_the_target_fails_clearly(Config) ->
    Dir = build_dir(Config, "all:\n\t@echo nothing here\n"),
    {Status, Out} = run(Dir),
    ?assertNotEqual(0, Status),
    ?assertNotEqual(nomatch, string:find(Out, "python.wasm")).

%%% ---------------------------------------------------------------- pins ---
%%
%% `scripts/checkout-pin.sh' makes a directory a checkout of a pinned commit or
%% tag. The fetch scripts used to skip the fetch whenever the directory
%% existed, so a checkout left at another commit was used silently and moving
%% a pin changed nothing: a local `wasi-testsuite' sat at another commit than
%% the one `fetch-suites.sh' declares. Fail-first: against that logic the last
%% three cases failed; the first three passed, and guard what must not change.
%% The source is a local repository of the case's own, two commits and a tag.

a_missing_checkout_is_fetched_at_its_commit(Config) ->
    {Url, C1, _C2} = source(Config),
    Dest = dest(Config),
    ?assertMatch({0, _}, pin(Dest, Url, C1)),
    ?assertEqual(C1, head(Dest)).

a_missing_checkout_is_fetched_at_its_tag(Config) ->
    {Url, _C1, C2} = source(Config),
    Dest = dest(Config),
    ?assertMatch({0, _}, pin(Dest, Url, "v2")),
    ?assertEqual(C2, head(Dest)).

%% Nothing is fetched: the URL the second run is given does not exist, so a
%% fetch would fail the run.
a_checkout_at_its_pin_is_left_alone(Config) ->
    {Url, C1, _C2} = source(Config),
    Dest = dest(Config),
    {0, _} = pin(Dest, Url, C1),
    Nowhere = "file://" ++ filename:join(?config(case_dir, Config), "nowhere"),
    ?assertMatch({0, _}, pin(Dest, Nowhere, C1)),
    ?assertEqual(C1, head(Dest)).

a_clean_checkout_elsewhere_is_moved_to_its_pin(Config) ->
    {Url, C1, C2} = source(Config),
    Dest = dest(Config),
    {0, _} = pin(Dest, Url, C1),
    {Status, Out} = pin(Dest, Url, C2),
    ?assertEqual(0, Status),
    ?assertEqual(C2, head(Dest)),
    ?assertNotEqual(nomatch, string:find(Out, C1)),
    ?assertNotEqual(nomatch, string:find(Out, C2)).

a_changed_checkout_elsewhere_stops_the_script(Config) ->
    {Url, C1, C2} = source(Config),
    Dest = dest(Config),
    {0, _} = pin(Dest, Url, C1),
    File = filename:join(Dest, "file"),
    ok = file:write_file(File, <<"local change">>),
    {Status, Out} = pin(Dest, Url, C2),
    ?assertNotEqual(0, Status),
    ?assertNotEqual(nomatch, string:find(Out, C1)),
    ?assertNotEqual(nomatch, string:find(Out, C2)),
    ?assertEqual(C1, head(Dest)),
    ?assertEqual({ok, <<"local change">>}, file:read_file(File)).

a_directory_that_is_not_a_checkout_stops_the_script(Config) ->
    {Url, C1, _C2} = source(Config),
    Dest = dest(Config),
    ok = filelib:ensure_path(Dest),
    {Status, Out} = pin(Dest, Url, C1),
    ?assertNotEqual(0, Status),
    ?assertNotEqual(nomatch, string:find(Out, "not a git checkout")).

%%% --------------------------------------------------------------- helpers ---

%% A repository with two commits, the second tagged `v2', that lets a commit be
%% fetched by its hash the way GitHub does.
source(Config) ->
    Src = filename:join(?config(case_dir, Config), "source"),
    ok = filelib:ensure_path(Src),
    G = fun(Args) -> git(Src, Args) end,
    _ = G(["init", "-q"]),
    _ = G(["config", "uploadpack.allowAnySHA1InWant", "true"]),
    ok = file:write_file(filename:join(Src, "file"), <<"one">>),
    C1 = commit(Src, "one"),
    ok = file:write_file(filename:join(Src, "file"), <<"two">>),
    C2 = commit(Src, "two"),
    _ = G(["tag", "v2"]),
    {"file://" ++ Src, C1, C2}.

commit(Dir, Msg) ->
    _ = git(Dir, ["add", "file"]),
    _ = git(Dir, ["-c", "user.name=t", "-c", "user.email=t@example.invalid",
                  "commit", "-q", "-m", Msg]),
    head(Dir).

dest(Config) -> filename:join(?config(case_dir, Config), "checkout").

head(Dir) -> string:trim(git(Dir, ["rev-parse", "HEAD"])).

git(Dir, Args) ->
    Port = erlang:open_port({spawn_executable, os:find_executable("git")},
                            [{args, ["-C", Dir | Args]}, exit_status,
                             stderr_to_stdout, binary]),
    {0, Out} = collect(Port, <<>>),
    Out.

pin(Dest, Url, Ref) ->
    Script = filename:join([root(), "scripts", "checkout-pin.sh"]),
    Port = erlang:open_port({spawn_executable, Script},
                            [{args, [Dest, Url, Ref]}, exit_status,
                             stderr_to_stdout, binary]),
    collect(Port, <<>>).

build_dir(Config, Makefile) ->
    Dir = filename:join(?config(priv_dir, Config), "build"),
    ok = filelib:ensure_path(filename:join(Dir, "Programs")),
    ok = file:write_file(filename:join(Dir, "Makefile"), Makefile),
    Dir.

age(Path, Seconds) ->
    {ok, Info} = file:read_file_info(Path, [{time, posix}]),
    file:write_file_info(Path, Info#file_info{mtime = Info#file_info.mtime
                                                       - Seconds},
                         [{time, posix}]).

%% Exit status and combined output of the script on `Dir'.
run(Dir) ->
    Script = filename:join([root(), "scripts", "python-link-line.sh"]),
    Port = erlang:open_port({spawn_executable, Script},
                            [{args, [Dir]}, exit_status, stderr_to_stdout,
                             binary]),
    collect(Port, <<>>).

collect(Port, Acc) ->
    receive
        {Port, {data, D}} -> collect(Port, <<Acc/binary, D/binary>>);
        {Port, {exit_status, S}} -> {S, binary_to_list(Acc)}
    after 10_000 -> error({no_exit_status, Acc})
    end.

root() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", ".."]).
