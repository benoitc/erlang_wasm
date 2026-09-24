-module(wasi_p2_runner).
-moduledoc """
Runs wasmtime's native `p2_*` test programs against `wasi_preview2` as
self-asserting oracles (interop track 3).

Unlike the adapter track (`wasi2_testsuite_runner`), these programs are authored
against WASI 0.2 directly: no preview1 adapter, no adapter ceiling. Each program
asserts its own expectations and traps (or exits non-zero) on any failure, so exit
code 0 is a pass. The programs are the wasmtime `test-programs` command components,
built on demand by `scripts/build-wasmtime-p2.sh` into `test/fixtures/wasmtime-p2`;
they are not vendored, so the suite skips when they are absent.

Results are tallied per interface group (random, clocks, io, filesystem, sockets,
cli), the same shape `wasm_wasi2_p2_SUITE` compares against a known-failing
baseline: a fix lowers a count, a regression raises one and fails the build.
""".

-export([dir/0, have_fixtures/0, programs/0, run_all/0, format_report/1, group/1]).

%% A program that neither exits nor traps within this bound is killed and
%% counted as a failure: the WASI operations these programs use are meant to be
%% prompt, so a hang is a real result (the blocking-socket items in Phase 2).
-define(CASE_TIMEOUT, 8000).

%%% ------------------------------------------------------------------ api ---

-doc "Where the built p2 fixtures live (gitignored, built on demand).".
-spec dir() -> file:filename().
dir() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..", "test",
                   "fixtures", "wasmtime-p2"]).

-doc "Whether the fixtures have been built.".
-spec have_fixtures() -> boolean().
have_fixtures() ->
    filelib:is_dir(dir()) andalso programs() =/= [].

-doc "Every built command program, sorted.".
-spec programs() -> [file:filename()].
programs() ->
    lists:sort(filelib:wildcard(filename:join(dir(), "p2_*.component.wasm"))).

-doc "Run every program, tallied per interface group.".
-spec run_all() -> [map()].
run_all() ->
    Preopen = fresh_preopen(),
    {ok, Server} = wasi_http_server:start(),
    Ctx = #{preopen => Preopen, http => wasi_http_server:address(Server)},
    try
        Tally = lists:foldl(
                  fun(Wasm, Acc) ->
                      Group = group(Wasm),
                      G0 = maps:get(Group, Acc,
                                   #{dir => Group, pass => 0, fail => 0,
                                     skip => 0, failures => []}),
                      Acc#{Group => case_result(Wasm, Ctx, G0)}
                  end, #{}, programs()),
        [G || {_, G} <- lists:sort(maps:to_list(Tally))]
    after
        wasi_http_server:stop(Server)
    end.

%%% -------------------------------------------------------------- one case ---

case_result(Wasm, Ctx, Acc) ->
    Name = filename:basename(Wasm, ".component.wasm"),
    case skip_reason(Name) of
        {skip, Why} ->
            bump(skip, Acc, Wasm, Why);
        run ->
            {Stdin, Opts} = config(Name, Ctx),
            case file:read_file(Wasm) of
                {ok, Bin} ->
                    R = run_bounded(Bin, Stdin, Opts#{compile => true}),
                    classify(R, Name, Acc, Wasm);
                {error, R} ->
                    bump(skip, Acc, Wasm, {noread, R})
            end
    end.

%% Never terminates by design (wasmtime uses it for epoch-interruption tests),
%% so it is not a pass/fail oracle here.
skip_reason("p2_cli_sleep_forever") -> {skip, runs_forever};
skip_reason(_)                      -> run.

%% Run one program in its own process under a timeout, so a hang becomes a
%% failure rather than wedging the whole run.
run_bounded(Bin, Stdin, Opts) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, Mon} =
        spawn_monitor(
          fun() ->
              R = try wasi_preview2:run_command(Bin, Stdin, Opts)
                  catch Class:Reason -> {caught, Class, Reason} end,
              Parent ! {Ref, R}
          end),
    receive
        {Ref, R} ->
            erlang:demonitor(Mon, [flush]),
            R;
        {'DOWN', Mon, process, Pid, Reason} ->
            {caught, exit, Reason}
    after ?CASE_TIMEOUT ->
        exit(Pid, kill),
        receive {'DOWN', Mon, process, Pid, _} -> ok after 1000 -> ok end,
        {error, #{msg => ~"timeout", kind => timeout}}
    end.

%% Exit 0 is a pass, except the handful of programs that are meant to exit
%% non-zero (they pass by doing so). A trap or a crash is a fail.
classify({ok, #{exit_code := Code}}, Name, Acc, Wasm) ->
    case {expect(Name), Code} of
        {zero, 0}                  -> bump(pass, Acc, Wasm, ok);
        {nonzero, C} when C =/= 0  -> bump(pass, Acc, Wasm, ok);
        {_, C}                     -> bump(fail, Acc, Wasm, {exit, C})
    end;
classify({error, E}, _Name, Acc, Wasm) ->
    bump(fail, Acc, Wasm, {trapped, first_line(reason(E))});
classify({caught, Class, Reason}, _Name, Acc, Wasm) ->
    bump(fail, Acc, Wasm, {crash, Class, Reason}).

%%% --------------------------------------------------------- configuration ---

%% The capability each program needs to link and run. Sockets need a loopback
%% network grant; filesystem programs need a writable preopen. Arguments,
%% environment and stdin that a specific program expects are added per phase as
%% the group is burned down; until then such a program lands in the baseline.
config(Name, Ctx) ->
    case program_config(Name) of
        {_, _} = C -> C;
        default ->
            case group_name(Name) of
                ~"sockets"    -> {<<>>, #{network => socket_grant(Name)}};
                ~"filesystem" -> fs_config(Name, maps:get(preopen, Ctx));
                ~"http"       -> {<<>>, #{network => loopback(),
                                          env => [{<<"HTTP_SERVER">>,
                                                   maps:get(http, Ctx)}]}};
                _             -> {<<>>, #{}}
            end
    end.

%% Filesystem programs get a writable scratch mount; the cross-permission ones
%% also get a read-only mount named "readonly" holding the fixture file they read,
%% and their scratch mount's name as the single argument they expect.
fs_config(Name, Scratch) when Name =:= "p2_cli_file_read";
                              Name =:= "p2_cli_file_append";
                              Name =:= "p2_cli_file_dir_sync" ->
    %% Each opens "bar.txt"; file_read asserts its exact 27-byte contents.
    ok = file:write_file(filename:join(Scratch, "bar.txt"),
                         <<"And stood awhile in thought">>),
    {<<>>, #{preopen => Scratch, writable => true}};
fs_config("p2_cli_directory_list", Scratch) ->
    [ok = file:write_file(filename:join(Scratch, F), <<>>)
     || F <- ["foo.txt", "bar.txt", "baz.txt"]],
    Sub = filename:join(Scratch, "sub"),
    ok = filelib:ensure_path(Sub),
    [ok = file:write_file(filename:join(Sub, F), <<>>)
     || F <- ["wow.txt", "yay.txt"]],
    {<<>>, #{preopen => Scratch, writable => true}};
fs_config("p2_cli_multiple_preopens", Scratch) ->
    B = fresh_dir(),
    C = fresh_dir(),
    {<<>>, #{preopens => [{<<"/a">>, Scratch, true},
                          {<<"/b">>, B, true},
                          {<<"/c">>, C, true}]}};
fs_config("p2_cli_initial_cwd", Scratch) ->
    {<<>>, #{preopen => Scratch, writable => true,
             initial_cwd => <<"/sandbox">>}};
fs_config(Name, Scratch) ->
    case needs_readonly(Name) of
        true ->
            {<<>>, #{args => [list_to_binary(Name), <<"rw">>],
                     preopens => [{<<"rw">>, Scratch, true},
                                  {<<"readonly">>, readonly_mount(), false}]}};
        false ->
            {<<>>, #{preopen => Scratch, writable => true}}
    end.

fresh_dir() ->
    Dir = filename:join(tmp_dir(),
                        "p2d_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_path(Dir),
    Dir.

needs_readonly("p2_file_rename_across_perms")   -> true;
needs_readonly("p2_file_hardlink_across_perms") -> true;
needs_readonly("p2_file_truncation_readonly")   -> true;
needs_readonly("p2_file_stream_not_permitted")  -> true;
needs_readonly(_)                               -> false.

readonly_mount() ->
    Dir = filename:join(tmp_dir(),
                        "p2ro_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_path(Dir),
    ok = file:write_file(filename:join(Dir, "test.txt"),
                         <<"read only test file\n">>),
    ok = file:write_file(filename:join(Dir, "stream-perms.txt"),
                         <<"stream permission test\n">>),
    Dir.

%% The arguments, environment and stdin each program asserts. argv[0] is the
%% program name (the guests skip it), so it leads the args list.
program_config("p2_cli_args") ->
    {<<>>, #{args => [<<"p2_cli_args">>, <<"hello">>, <<"this">>, <<>>,
                      <<"is an argument">>, <<"with ", 240,159,154,169, " emoji">>]}};
program_config("p2_cli_env") ->
    {<<>>, #{env => [{<<"frabjous">>, <<"day">>}, {<<"callooh">>, <<"callay">>}]}};
program_config("p2_cli_stdin") ->
    {<<"So rested he by the Tumtum tree">>, #{}};
program_config(_) ->
    default.

%% p2_cli_no_ip_name_lookup is offered the sockets interface but no resolve
%% capability, so it asserts the lookup is a permanent resolver failure; everything
%% else gets a loopback grant.
socket_grant("p2_cli_no_ip_name_lookup") -> none;
socket_grant(_)                          -> loopback().

loopback() ->
    #{connect => [{tcp, <<"127.0.0.1">>, {0, 65535}},
                  {udp, <<"127.0.0.1">>, {0, 65535}},
                  {tcp, <<"::1">>, {0, 65535}},
                  {udp, <<"::1">>, {0, 65535}}],
      listen  => [{tcp, <<"127.0.0.1">>, {0, 65535}},
                  {udp, <<"127.0.0.1">>, {0, 65535}},
                  {tcp, <<"::1">>, {0, 65535}},
                  {udp, <<"::1">>, {0, 65535}}],
      resolve => allow}.

%% Programs that pass by exiting non-zero rather than 0.
expect("p2_cli_exit_failure")   -> nonzero;
expect("p2_cli_exit_panic")     -> nonzero;
expect("p2_cli_exit_with_code") -> nonzero;
expect(_)                       -> zero.

%%% --------------------------------------------------------------- grouping ---

-doc "The interface group a program belongs to, by name.".
-spec group(file:filename()) -> binary().
group(Wasm) ->
    group_name(filename:basename(Wasm, ".component.wasm")).

group_name(Name) ->
    classify_group(Name,
                   [{["http"], ~"http"},
                    {["random"], ~"random"},
                    {["tcp", "udp", "ip_name_lookup", "no_tcp", "no_udp",
                      "no_ip"], ~"sockets"},
                    {["file", "directory", "preopen", "initial_cwd",
                      "badfd"], ~"filesystem"},
                    {["clock", "sleep"], ~"clocks"},
                    {["pollable"], ~"io"}]).

classify_group(_Name, []) -> ~"cli";
classify_group(Name, [{Subs, G} | Rest]) ->
    case lists:any(fun(S) -> string:find(Name, S) =/= nomatch end, Subs) of
        true  -> G;
        false -> classify_group(Name, Rest)
    end.

%%% ---------------------------------------------------------------- report ---

-doc "One line per group: pass/fail/skip counts.".
-spec format_report([map()]) -> iolist().
format_report(Results) ->
    [io_lib:format("~-14ts pass ~3b  fail ~3b  skip ~3b~n", [D, P, F, S])
     || #{dir := D, pass := P, fail := F, skip := S} <- Results].

%%% ----------------------------------------------------------------- helpers ---

fresh_preopen() ->
    Dir = filename:join(tmp_dir(),
                        "p2_fs_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_path(Dir),
    Dir.

tmp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir   -> Dir
    end.

bump(Kind, Acc, Wasm, Why) ->
    A = maps:update_with(Kind, fun(N) -> N + 1 end, Acc),
    case Kind of
        pass -> A;
        _    -> A#{failures => [#{case_ => label_case(Wasm), why => Why}
                                | maps:get(failures, A)]}
    end.

label_case(Wasm) -> list_to_binary(filename:basename(Wasm, ".component.wasm")).

reason(#{msg := M}) -> M;
reason(Other)       -> unicode:characters_to_binary(io_lib:format("~p", [Other])).

first_line(Bin) when is_binary(Bin) ->
    case binary:split(Bin, ~"\n") of
        [First | _] -> First;
        []          -> Bin
    end;
first_line(Other) ->
    unicode:characters_to_binary(io_lib:format("~p", [Other])).
