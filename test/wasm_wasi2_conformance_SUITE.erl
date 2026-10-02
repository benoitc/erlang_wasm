-module(wasm_wasi2_conformance_SUITE).
-moduledoc """
WASI 0.2 conformance by differential against wasmtime.

Each case is a real, unmodified `wasm32-wasip2` Rust program that exercises one
WASI 0.2 area (args, env, stdin/stdout, a file over a mount, exit status). It is
run on erlang_wasm (`wasi_preview2:run_command/3`) and, when wasmtime is on the
path, on wasmtime with the same inputs, and the outputs must agree. Because the
Preview 2 command model carries only success or failure (`wasi:cli/run.run` and
`wasi:cli/exit.exit` are `result<_, _>`), exit codes are compared normalised to
zero vs non-zero; a specific status such as 33 is 1 on both runtimes.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [args_reach_the_guest,
     an_env_var_reaches_the_guest,
     stdin_copies_to_stdout,
     a_file_is_written_then_read,
     a_non_zero_exit_is_reported].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

%% argv[1..] is delivered in order.
args_reach_the_guest(Config) ->
    diff(Config, "argv", <<>>, #{args => [<<"one">>, <<"two">>, <<"three">>]}).

%% an environment variable is delivered.
an_env_var_reaches_the_guest(Config) ->
    diff(Config, "envvar", <<>>,
         #{args => [<<"GREETING">>], env => [{<<"GREETING">>, <<"hello p2">>}]}).

%% stdin is copied to stdout.
stdin_copies_to_stdout(Config) ->
    diff(Config, "catcat", <<"piped through\nsecond line\n">>, #{}).

%% a file written under the mount reads back, on both runtimes.
a_file_is_written_then_read(Config) ->
    diff(Config, "filewrite", <<>>, #{mount => true, writable => true}).

%% a non-zero exit is reported as non-zero on both (the specific code is lost).
a_non_zero_exit_is_reported(Config) ->
    diff(Config, "exitcode", <<>>, #{args => [<<"7">>]}).

%%% -------------------------------------------------------------- helpers ---

%% Run a program on erlang_wasm and (when present) wasmtime with the same inputs;
%% assert identical stdout and identical zero/non-zero exit.
diff(Config, Name, Stdin, Spec) ->
    Bin = component(Name),
    Args = maps:get(args, Spec, []),
    Env = maps:get(env, Spec, []),
    {Dir, DirOpt} = mount(Config, Name, maps:get(mount, Spec, false),
                          maps:get(writable, Spec, false)),
    Ours = wasi_preview2:run_command(
             Bin, Stdin,
             maps:merge(DirOpt, #{args => [list_to_binary(Name) | Args], env => Env})),
    {ok, #{stdout := OutOurs, exit_code := CodeOurs}} = Ours,
    case os:find_executable("wasmtime") of
        false ->
            {skip, "wasmtime not on the path"};
        Wasmtime ->
            Ref = run_wasmtime(Wasmtime, path(Name), Args, Env, Stdin, Dir),
            #{stdout := OutRef, exit_code := CodeRef} = Ref,
            ?assertEqual(OutRef, OutOurs),
            ?assertEqual(CodeRef =:= 0, CodeOurs =:= 0)
    end.

mount(_Config, _Name, false, _Writable) ->
    {undefined, #{}};
mount(Config, Name, true, Writable) ->
    Dir = filename:join([?config(priv_dir, Config), Name ++ "_mnt"]),
    ok = filelib:ensure_path(Dir),
    {Dir, #{preopen => Dir, writable => Writable}}.

%% wasmtime over a shell: stdin/stdout/stderr as files (kept separate) so the
%% port carries only the exit status.
run_wasmtime(Wasmtime, Path, Args, Env, Stdin, Dir) ->
    Tmp = string:trim(os:cmd("mktemp -d")),
    In = filename:join(Tmp, "in"),
    Out = filename:join(Tmp, "out"),
    Err = filename:join(Tmp, "err"),
    ok = file:write_file(In, Stdin),
    EnvArgs = [io_lib:format(" --env '~ts=~ts'", [K, V]) || {K, V} <- Env],
    DirArg = case Dir of undefined -> ""; _ -> io_lib:format(" --dir '~ts::/'", [Dir]) end,
    ArgStr = [io_lib:format(" '~ts'", [A]) || A <- Args],
    Cmd = io_lib:format("~ts run~ts~ts ~ts~ts < ~ts > ~ts 2> ~ts",
                        [Wasmtime, EnvArgs, DirArg, Path, ArgStr, In, Out, Err]),
    Port = open_port({spawn, lists:flatten(Cmd)}, [exit_status, binary]),
    Code = wait_exit(Port),
    {ok, OutBin} = file:read_file(Out),
    _ = file:del_dir_r(Tmp),
    #{stdout => OutBin, exit_code => Code}.

wait_exit(Port) ->
    receive
        {Port, {exit_status, Code}} -> Code;
        {Port, {data, _}}           -> wait_exit(Port)
    end.

component(Name) ->
    {ok, Bin} = file:read_file(path(Name)),
    Bin.

path(Name) ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", Name ++ ".component.wasm"]).
