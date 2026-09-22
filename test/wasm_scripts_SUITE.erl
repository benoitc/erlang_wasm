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

all() -> [the_link_line_is_found_when_python_wasm_is_up_to_date,
          a_makefile_without_the_target_fails_clearly].

init_per_suite(Config) ->
    case os:find_executable("make") of
        false -> {skip, "no make on PATH"};
        _ -> Config
    end.

end_per_suite(_) -> ok.

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

%%% --------------------------------------------------------------- helpers ---

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
