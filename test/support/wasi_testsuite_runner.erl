%% @doc Replays the official WASI test suite.
%%
%% A second, external reading of WASI Preview 1. The hand-written suites next to
%% this one are this project's own reading of the specification and they look
%% thorough; that is exactly the position from which a runtime ends up confident
%% and wrong. This runs somebody else's tests.
%%
%% The corpus is a separate upstream repository from the core specification
%% suite, and the built `.wasm' files live on a branch rather than on `main':
%%
%% ```
%% git clone --depth 1 --branch prod/testsuite-base \
%%     https://github.com/WebAssembly/wasi-testsuite.git
%% '''
%%
%% `WASI_TESTSUITE' names the checkout if it is somewhere else.
%%
%% == The format ==
%%
%% Every `*.wasm' under `tests/*/testsuite/*' is a test case. A case may have a
%% `.json' beside it with the same base name; when it has none, the defaults
%% apply. The fields, all optional, are the upstream legacy specification:
%%
%% <ul>
%%   <li>`args' &mdash; command line, after the program name. Default `[]'.</li>
%%   <li>`env' &mdash; environment variables. Default `{}'.</li>
%%   <li>`root' &mdash; a directory beside the test, preopened as the guest's
%%       `/'. Default none, which means no filesystem at all.</li>
%%   <li>`exit_code' &mdash; expected status. Default 0.</li>
%%   <li>`stdout', `stderr' &mdash; expected output. Default empty, and only
%%       compared when the specification names them, because a case that does
%%       not mention a stream is not making a claim about it.</li>
%% </ul>
%%
%% `manifest.json' names the directory and is not a case specification.
%%
%% Upstream also has a newer operation-based format, with a `proposals' list and
%% a sequence of `run', `wait', `read' and `connect' steps, for tests that need a
%% client and a server. Nothing in the Preview 1 directories uses it, and a case
%% that does is skipped by name rather than guessed at.
-module(wasi_testsuite_runner).

-export([run_all/0, run_all/1, run_dir/1, dirs/0, in_scope/1,
         suite_dir/0, format_report/1]).

-type result() :: #{dir := binary(),
                    pass := non_neg_integer(),
                    fail := non_neg_integer(),
                    skip := non_neg_integer(),
                    failures := [map()]}.

%%% ------------------------------------------------------------------ api ---

-doc "Where the checkout is, whether or not it exists.".
-spec suite_dir() -> file:filename_all().
suite_dir() ->
    case os:getenv("WASI_TESTSUITE") of
        false -> find_up(filename:absname("."), ["wasi-testsuite"], 8);
        Dir -> Dir
    end.

%% Beside the project rather than inside it, and located by walking up, because
%% Common Test runs with its own log directory as the working directory. The
%% same argument and the same shape as `wasm_spec_runner:suite_dir/0'.
find_up(_Dir, Parts, 0) -> filename:join(Parts);
find_up(Dir, Parts, N) ->
    Candidate = filename:join([Dir | Parts]),
    case filelib:is_dir(Candidate) of
        true -> Candidate;
        false ->
            case filename:dirname(Dir) of
                Dir -> filename:join(Parts);
                Parent -> find_up(Parent, Parts, N - 1)
            end
    end.

-doc """
Every directory of cases in the checkout.

A directory rather than a file is the unit here, because that is how upstream
groups them and how the expectations are kept.
""".
-spec dirs() -> [file:filename_all()].
dirs() ->
    lists:sort(
      [D || F <- filelib:wildcard(
                   filename:join([suite_dir(), "tests", "*", "testsuite", "*",
                                  "manifest.json"])),
            D <- [filename:dirname(F)],
            in_scope(D)]).

-doc """
Whether this runtime is held to this directory.

Preview 3 is a different interface, not a stricter version of this one, and
`wasi_preview1` does not implement it. Naming it here keeps the reason visible
instead of letting it become a number in a baseline.
""".
-spec in_scope(file:filename_all()) -> boolean().
in_scope(Dir) -> filename:basename(Dir) =/= "wasm32-wasip3".

%% `assemblyscript/wasm32-wasip1' rather than `wasm32-wasip1'. Three of the four
%% directories share a basename, so a report keyed on that would collapse them
%% and a baseline keyed on it would apply one directory's allowance to another.
label(Dir) ->
    list_to_binary(filename:join(filename:basename(filename:dirname(
                                   filename:dirname(Dir))),
                                 filename:basename(Dir))).

-spec run_all() -> [result()].
run_all() -> run_all(dirs()).

-spec run_all([file:filename_all()]) -> [result()].
run_all(Dirs) -> [run_dir(D) || D <- Dirs].

-doc "Replay one directory of cases.".
-spec run_dir(file:filename_all()) -> result().
run_dir(Dir) ->
    _ = cleanup(Dir),
    Cases = lists:sort(filelib:wildcard(filename:join(Dir, "*.wasm"))),
    lists:foldl(fun(C, Acc) -> case_result(C, Acc) end,
                #{dir => label(Dir),
                  pass => 0, fail => 0, skip => 0, failures => []},
                Cases).

%%% -------------------------------------------------------------- one case ---

case_result(Wasm, Acc) ->
    case spec_for(Wasm) of
        {skip, Why} -> bump(skip, Acc, Wasm, Why);
        {ok, Spec} ->
            case run_case(Wasm, Spec) of
                pass -> bump(pass, Acc, Wasm, ok);
                {fail, Why} -> bump(fail, Acc, Wasm, Why)
            end
    end.

%% The specification beside the case, or the defaults.
%%
%% A malformed one is a skip and not a failure: it says nothing about this
%% runtime, and a checkout that has grown a format nobody here understands
%% should be visible rather than counted as a defect.
spec_for(Wasm) ->
    Json = filename:rootname(Wasm) ++ ".json",
    case file:read_file(Json) of
        {error, enoent} -> {ok, #{}};
        {error, R} -> {skip, {unreadable_spec, R}};
        {ok, Bin} ->
            try json:decode(Bin) of
                #{<<"operations">> := _} -> {skip, operation_based_spec};
                #{} = Spec -> {ok, Spec};
                _ -> {skip, spec_not_an_object}
            catch
                _:_ -> {skip, spec_not_json}
            end
    end.

%% Compiled, not loaded.
%%
%% `wasm:load_file/1' goes through the node-wide module cache, which is rate
%% limited to fifty loads a second because a `persistent_term' write scans the
%% node and an attacker driving load and unload cycles could otherwise spend all
%% of its time scanning. A directory here is forty-six modules read back to back
%% and every one of them is used exactly once, so the cache buys nothing and the
%% limiter turned twenty-two real results into `load_rate_exceeded'.
run_case(Wasm, Spec) ->
    case compile_file(Wasm) of
        {error, E} -> {fail, {load_failed, E}};
        {ok, M} ->
            case run_collecting(M, config(Wasm, Spec)) of
                {error, E, Err} -> {fail, {trapped, E, first_line(Err)}};
                {ok, Code, Out, Err} -> check(Spec, Code, Out, Err)
            end
    end.

%% `wasi:run/2' does this and is the right thing for an embedder, but it answers
%% a bare `{error, _}' when the guest traps and drops the output with it. A
%% guest that traps is exactly the one worth reading: these tests are compiled
%% Rust and C, and a failed assertion arrives as a panic message on stderr
%% followed by `unreachable'. Without it every failure here reads
%% "trapped: unreachable" and no baseline entry could name its cause.
run_collecting(M, Config0) ->
    Self = self(),
    OutTag = make_ref(),
    ErrTag = make_ref(),
    Config = Config0#{stdout => fun(D) -> Self ! {OutTag, D}, ok end,
                      stderr => fun(D) -> Self ! {ErrTag, D}, ok end},
    case wasm:instantiate(M, wasi_preview1:imports(Config)) of
        %% An import this runtime does not provide fails here, before anything
        %% runs. That is a real result and the most attributable kind: it names
        %% the syscall.
        {error, E} -> {error, E, ~""};
        {ok, Inst} -> started(Inst, OutTag, ErrTag)
    end.

started(Inst, OutTag, ErrTag) ->
    Result = wasm:call(Inst, ~"_start", []),
    Out = drain(OutTag),
    Err = drain(ErrTag),
    ok = wasm:destroy(Inst),
    case Result of
        {ok, _} -> {ok, 0, Out, Err};
        {error, E} ->
            case wasi_preview1:exit_code(E) of
                {ok, Code} -> {ok, Code, Out, Err};
                error -> {error, E, Err}
            end
    end.

drain(Tag) -> iolist_to_binary(drain(Tag, [])).

drain(Tag, Acc) ->
    receive {Tag, Data} -> drain(Tag, [Data | Acc])
    after 0 -> lists:reverse(Acc)
    end.

%% A Rust panic is four lines and the second one carries the reason. The whole
%% thing in a failure list makes the list unreadable, so this keeps the line
%% that says what went wrong.
first_line(Err) ->
    case [L || L <- binary:split(Err, ~"\n", [global]), L =/= ~""] of
        [] -> ~"";
        Lines -> lists:last(lists:sublist(Lines, 2))
    end.

%% Only what the specification names is compared. A case with no `stdout' key is
%% not claiming its output is empty, and holding it to that would fail cases
%% that pass everywhere else.
check(Spec, Code, Out, Err) ->
    Want = maps:get(<<"exit_code">>, Spec, 0),
    Checks =
        [{exit_code, Code, Want} || Code =/= Want] ++
        [{stdout, Out, S} || S <- [maps:get(<<"stdout">>, Spec, undefined)],
                             S =/= undefined, Out =/= S] ++
        [{stderr, Err, S} || S <- [maps:get(<<"stderr">>, Spec, undefined)],
                             S =/= undefined, Err =/= S],
    case Checks of
        [] -> pass;
        _ -> {fail, Checks}
    end.

%% The capability map for one case.
%%
%% `args' is the command line *after* the program name, so the name goes in
%% front: a guest reading `argv[0]' gets what it would get from a shell.
%%
%% `root' is preopened as `/'. With no `root' the guest gets no filesystem at
%% all, which is this runtime's default and also what the upstream default of
%% `null' means.
config(Wasm, Spec) ->
    Name = list_to_binary(filename:basename(Wasm, ".wasm")),
    Args = [Name | [to_bin(A) || A <- maps:get(<<"args">>, Spec, [])]],
    Env = maps:from_list([{to_bin(K), to_bin(V)}
                          || {K, V} <- maps:to_list(
                                         maps:get(<<"env">>, Spec, #{}))]),
    Base = #{args => Args, env => Env,
             clocks => [monotonic, realtime], random => strong},
    case maps:get(<<"root">>, Spec, null) of
        null -> Base;
        Root ->
            Path = filename:join(filename:dirname(Wasm), binary_to_list(Root)),
            %% Read and write: the filesystem cases create, truncate and unlink,
            %% and `cleanup/1' is what puts the directory back afterwards.
            Base#{dirs => [{~"/", Path, write}]}
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(N) when is_integer(N) -> integer_to_binary(N).

%% Upstream marks the artifacts a run may leave behind with a `.cleanup' file,
%% and expects a runner to remove them before starting. Without this a second
%% run sees the first run's leftovers and fails cases that passed.
%%
%% The artifact is the `.cleanup' entry itself, not something it points at: a
%% test creates `directory_seek_dir.cleanup' under its own name and the suffix is
%% how a runner knows to remove it afterwards. Most of them are *directories*,
%% which `file:delete/1' will not touch, so half the Rust cases failed with
%% "File exists" from their own previous run. That looked exactly like a defect
%% in path handling and was not one.
cleanup(Dir) ->
    [remove(F) || F <- filelib:wildcard(filename:join(Dir, "**/*.cleanup"))].

remove(Path) ->
    case filelib:is_dir(Path) of
        true -> file:del_dir_r(Path);
        false -> file:delete(Path)
    end.

compile_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> wasm:compile(Bin);
        {error, R} -> {error, {unreadable, R}}
    end.

%%% ---------------------------------------------------------------- report ---

bump(Kind, Acc, Wasm, Why) ->
    A = maps:update_with(Kind, fun(N) -> N + 1 end, Acc),
    case Kind of
        pass -> A;
        _ ->
            F = #{case_ => list_to_binary(filename:basename(Wasm)),
                  kind => Kind, why => Why},
            maps:update_with(failures, fun(L) -> [F | L] end, A)
    end.

-doc "The results as a table, for `ct:log'.".
-spec format_report([result()]) -> iolist().
format_report(Results) ->
    [io_lib:format("~-40s ~6s ~6s ~6s~n", ["directory", "pass", "fail", "skip"]),
     [io_lib:format("~-40s ~6b ~6b ~6b~n", [D, P, F, S])
      || #{dir := D, pass := P, fail := F, skip := S} <- Results],
     io_lib:format("~-40s ~6b ~6b ~6b~n",
                   ["total",
                    lists:sum([P || #{pass := P} <- Results]),
                    lists:sum([F || #{fail := F} <- Results]),
                    lists:sum([S || #{skip := S} <- Results])])].
