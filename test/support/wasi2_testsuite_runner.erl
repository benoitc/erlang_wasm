-module(wasi2_testsuite_runner).
-moduledoc """
Replays the official WASI test suite through the preview1->preview2 adapter.

The suite ships `wasm32-wasip1` programs. `wasi_testsuite_runner` runs them on
`wasi_preview1`; this runs the same programs on `wasi_preview2` by first adapting
each into a preview2 component with `wasm-tools component new --adapt` (the
committed `wasi_snapshot_preview1.command.wasm`), then running it with
`wasi_preview2:run_command`. The manifest format, the per-case configuration and
the cleanup are shared with the preview1 runner.

Two things differ from preview1. The command model carries only success or
failure, so an exit code is compared normalised to zero vs non-zero (a specific
status is lost). And the adapter lowers the whole preview2 surface, so a program
that reaches a function this host does not implement traps; those cases are the
known-failing baseline, and shrink as the host grows.

Needs `wasm-tools` on the path and the committed adapter; `have_tools/0` says so.
""".

-export([run_all/0, run_dir/1, have_tools/0, adapter/0,
         format_report/1]).

%%% ------------------------------------------------------------------ api ---

-doc "Whether the adapter path can run: wasm-tools present and adapter committed.".
-spec have_tools() -> boolean().
have_tools() ->
    os:find_executable("wasm-tools") =/= false andalso filelib:is_regular(adapter()).

-doc "Run every in-scope directory of the checkout through the adapter.".
run_all() ->
    [run_dir(D) || D <- wasi_testsuite_runner:dirs()].

-doc "Run one directory: adapt and run each case, tallied like the preview1 runner.".
run_dir(Dir) ->
    _ = wasi_testsuite_runner:cleanup(Dir),
    Cases = lists:sort(filelib:wildcard(filename:join(Dir, "*.wasm"))),
    lists:foldl(fun case_result/2,
                #{dir => label(Dir), pass => 0, fail => 0, skip => 0,
                  failures => []},
                Cases).

%%% -------------------------------------------------------------- one case ---

case_result(Wasm, Acc) ->
    case wasi_testsuite_runner:spec_for(Wasm) of
        {skip, Why} -> bump(skip, Acc, Wasm, Why);
        {ok, Spec} ->
            case run_case(Wasm, Spec) of
                pass        -> bump(pass, Acc, Wasm, ok);
                {skip, Why} -> bump(skip, Acc, Wasm, Why);
                {fail, Why} -> bump(fail, Acc, Wasm, Why)
            end
    end.

run_case(Wasm, Spec) ->
    case adapt(Wasm) of
        {error, R} ->
            {skip, {adapt_failed, R}};
        {ok, Component} ->
            case run_collecting(Component, Wasm, Spec) of
                {ok, Code, Out, Err} -> check(Spec, Code, Out, Err);
                {fail, _} = F        -> F
            end
    end.

%% Run the adapted component through the command entry, with the case's arguments,
%% environment and (when it names a root) a writable preopen. Unimplemented
%% preview2 imports are stubbed, so a program that only reaches implemented ones
%% runs; `compile` avoids the load cache's rate limit over a whole directory.
run_collecting(Component, Wasm, Spec) ->
    Config = wasi_testsuite_runner:config(Wasm, Spec),
    Opts = maps:merge(dir_opt(Config),
                      #{args => maps:get(args, Config, []),
                        env => maps:to_list(maps:get(env, Config, #{})),
                        compile => true}),
    try wasi_preview2:run_command(Component, <<>>, Opts) of
        {ok, #{exit_code := Code, stdout := Out, stderr := Err}} ->
            {ok, Code, Out, Err};
        {error, E} ->
            {fail, {trapped, first_line(reason(E))}}
    catch
        Class:Reason -> {fail, {crash, Class, Reason}}
    end.

dir_opt(Config) ->
    case maps:get(dirs, Config, []) of
        [{_Guest, Path, _Access} | _] -> #{preopen => Path, writable => true};
        _                             -> #{}
    end.

%% Only what the specification names is compared; the exit code is normalised
%% because the command model does not carry a specific status.
check(Spec, Code, Out, Err) ->
    Want = maps:get(<<"exit_code">>, Spec, 0),
    Checks =
        [{exit_code, Code, Want} || (Want =:= 0) =/= (Code =:= 0)] ++
        [{stdout, Out, S} || S <- [maps:get(<<"stdout">>, Spec, undefined)],
                             S =/= undefined, Out =/= S] ++
        [{stderr, Err, S} || S <- [maps:get(<<"stderr">>, Spec, undefined)],
                             S =/= undefined, Err =/= S],
    case Checks of
        [] -> pass;
        _  -> {fail, Checks}
    end.

%%% ---------------------------------------------------------------- adapt ---

%% Turn one wasip1 program into a preview2 component. A case wasm-tools cannot
%% adapt is a skip: it is a gap in the toolchain, not a result about this runtime.
adapt(Wasm) ->
    Out = filename:join(tmp_dir(), lists:concat(
            [filename:basename(Wasm, ".wasm"), "-",
             erlang:unique_integer([positive]), ".component.wasm"])),
    Cmd = io_lib:format(
            "~ts component new ~ts --adapt wasi_snapshot_preview1=~ts -o ~ts 2>&1",
            [os:find_executable("wasm-tools"), Wasm, adapter(), Out]),
    case os:cmd(lists:flatten(Cmd)) of
        "" ->
            Read = file:read_file(Out),
            _ = file:delete(Out),
            case Read of
                {ok, Bin}  -> {ok, Bin};
                {error, R} -> {error, R}
            end;
        Err ->
            {error, string:slice(unicode:characters_to_binary(Err), 0, 80)}
    end.

tmp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir   -> Dir
    end.

-doc "The committed preview1->preview2 adapter.".
adapter() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..", "test",
                   "fixtures", "component", "wasi_snapshot_preview1.command.wasm"]).

%%% ---------------------------------------------------------------- report ---

-doc "The same per-directory report the preview1 runner prints.".
format_report(Results) ->
    [io_lib:format("~-28ts pass ~3b  fail ~3b  skip ~3b~n",
                   [D, P, F, S])
     || #{dir := D, pass := P, fail := F, skip := S} <- Results].

bump(Kind, Acc, Wasm, Why) ->
    A = maps:update_with(Kind, fun(N) -> N + 1 end, Acc),
    case Kind of
        fail -> A#{failures => [#{case_ => label_case(Wasm), why => Why}
                                | maps:get(failures, A)]};
        _    -> A
    end.

%% `rust/wasm32-wasip1`: the toolchain and the target, the same key the preview1
%% runner and its baseline use.
label(Dir) ->
    list_to_binary(filename:join(
                     filename:basename(filename:dirname(filename:dirname(Dir))),
                     filename:basename(Dir))).

label_case(Wasm) -> list_to_binary(filename:basename(Wasm)).

reason(#{msg := M}) -> M;
reason(Other)       -> unicode:characters_to_binary(io_lib:format("~p", [Other])).

first_line(Bin) ->
    case binary:split(Bin, ~"\n") of
        [First | _] -> First;
        []          -> Bin
    end.
