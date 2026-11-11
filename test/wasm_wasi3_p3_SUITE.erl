-module(wasm_wasi3_p3_SUITE).
-moduledoc """
wasmtime's WASI 0.3 test programs (`p3_*`) run through
`wasi_preview3:run_command/3`.

Each program is a self-asserting command: it exits 0 when every check passed,
and traps or exits non-zero otherwise. Each imports `wasi:*@0.3.0` and, through
the wasip1 adapter it was built with, `wasi:*@0.2.12` too, so it needs both
hosts at once. The first cases name a program and what it must do, from
wasmtime's own tests of it. `p3_cases` runs every program and keeps, per
interface group, how many still fail, as `wasm_wasi2_p2_SUITE` does for 0.2: a
fix lowers a count, a regression that raises one fails, and a count lower than
the baseline fails until the baseline is lowered with it.

Skipped without the built fixtures: run `scripts/build-wasmtime-p2.sh`, which
also puts the 0.3 programs in `test/fixtures/wasmtime-p3` (not vendored).
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([hello_stdout/1, read_stdin/1, cli/1, clocks_sleep/1, random_imports/1,
         big_random_buf/1, random_limits/1, much_stdout/1,
         many_tasks_reach_the_resource_limit/1, file_write_chunked/1,
         file_truncation_readonly/1, serve_hello_world/1, serve_echo/1,
         serve_post_return/1, serve_drops_forbidden_headers/1, serve_proxy/1,
         p3_cases/1]).

all() ->
    [hello_stdout, read_stdin, cli, clocks_sleep, random_imports, big_random_buf,
     random_limits, much_stdout, many_tasks_reach_the_resource_limit,
     file_write_chunked, file_truncation_readonly, serve_hello_world, serve_echo,
     serve_post_return, serve_drops_forbidden_headers, serve_proxy, p3_cases].

%% Programs still failing, by group, and why. Each step of the WASI 0.3 work
%% lowers its group to 0.
baseline() ->
    #{~"cli"        => 0,
      ~"clocks"     => 0,
      ~"random"     => 0,
      ~"filesystem" => 0,
      ~"sockets"    => 0,
      ~"http"       => 0}.

init_per_suite(Config) ->
    case programs() of
        [] -> {skip, "no wasmtime p3 fixtures: run scripts/build-wasmtime-p2.sh"};
        _ ->
            {ok, _} = application:ensure_all_started(wasm),
            %% The server the outbound HTTP programs reach, as wasmtime's own
            %% tests give them through HTTP_SERVER.
            {ok, Server} = wasi_http_server:start(),
            persistent_term:put({?MODULE, http}, wasi_http_server:address(Server)),
            [{http_server, Server} | Config]
    end.

end_per_suite(Config) ->
    wasi_http_server:stop(?config(http_server, Config)),
    persistent_term:erase({?MODULE, http}),
    ok.

%%% --------------------------------------------------------------- cases ---

hello_stdout(_) ->
    ?assertMatch({ok, #{exit_code := 0, stdout := <<"hello, world\n">>}},
                 run("p3_cli_hello_stdout", <<>>, #{})).

read_stdin(_) ->
    ?assertMatch({ok, #{exit_code := 0}}, run("p3_cli_read_stdin", <<"hello!">>, #{})).

cli(_) ->
    ?assertMatch({ok, #{exit_code := 0}}, run("p3_cli", <<>>, opts("p3_cli"))).

%% Waiting until now is ready at once; waiting for a while suspends the task.
clocks_sleep(_) ->
    ?assertMatch({ok, #{exit_code := 0}}, run("p3_clocks_sleep", <<>>, #{})).

random_imports(_) ->
    ?assertMatch({ok, #{exit_code := 0}}, run("p3_random_imports", <<>>, #{})).

big_random_buf(_) ->
    ?assertMatch({ok, #{exit_code := 0}}, run("p3_big_random_buf", <<>>, #{})).

random_limits(_) ->
    [?assertMatch({ok, #{exit_code := 0}},
                  run("p3_cli_random_limits", <<>>,
                      #{args => [~"p3_cli_random_limits", Which, ~"256"]}))
     || Which <- [~"random", ~"insecure"]].

%% 1 KiB written 256 times reaches stdout whole.
much_stdout(_) ->
    {ok, #{exit_code := 0, stdout := Out}} =
        run("p3_cli_much_stdout", <<>>, opts("p3_cli_much_stdout")),
    ?assertEqual(binary:copy(<<"a">>, 1 bsl 18), Out).

%% A thousand waits of 2^60 ns at once: wasmtime runs the program with a limit
%% of 100 resources and expects it to trap.
many_tasks_reach_the_resource_limit(_) ->
    {error, E} = run("p3_cli_many_tasks", <<>>,
                     (opts("p3_cli_many_tasks"))#{resource_limit => 100}),
    ?assertMatch(#{ctx := #{reason := resource_limit_reached}}, E).

%% Writes that double until the host takes less than it was offered; a file
%% taking each write whole let them grow without end.
file_write_chunked(_) ->
    ?assertMatch({ok, #{exit_code := 0}},
                 run("p3_file_write_chunked", <<>>, opts("p3_file_write_chunked"))).

file_truncation_readonly(_) ->
    ?assertMatch({ok, #{exit_code := 0}},
                 run("p3_file_truncation_readonly", <<>>,
                     opts("p3_file_truncation_readonly"))).

%% The 0.3 handlers, served through wasi_preview3:run_serve/3.
serve_hello_world(_) ->
    ?assertEqual({ok, 200, [], <<"Hello, WASI!">>}, serve("p3_cli_serve_hello_world")).

%% The handler answers with the request's own headers and body.
serve_echo(_) ->
    ?assertMatch({ok, 200, [{<<"content-type">>, <<"text/plain">>}], <<"hello body">>},
                 serve("p3_http_echo")).


%% What the handler does after returning its response still runs.
serve_post_return(_) ->
    ?assertMatch({ok, 200, _, _}, serve("p3_cli_serve_post_return")).

%% The headers a guest may not set do not reach it from outside either, as
%% wasmtime's forbidden-headers test asserts of what the guest forwards. The
%% echo handler answers with the request's own headers.
serve_drops_forbidden_headers(_) ->
    {ok, 200, Headers, _} =
        serve("p3_http_echo",
              [{<<"host">>, <<"victim.internal">>}, {<<"connection">>, <<"close">>},
               {<<"custom-forbidden-header">>, <<"yes">>}, {<<"foo">>, <<"bar">>}],
              #{}),
    ?assertEqual([{<<"foo">>, <<"bar">>}], Headers).

%% The proxy forwards to the URL its `url' header names, here the suite's
%% server, and answers with that server's response.
serve_proxy(_) ->
    Url = <<"http://", (persistent_term:get({?MODULE, http}))/binary, "/">>,
    ?assertMatch({ok, 200, _, _},
                 serve("p3_http_proxy", [{<<"url">>, Url}], #{network => loopback()})).

serve(Name) ->
    serve(Name, [{<<"content-type">>, <<"text/plain">>}], #{}).

serve(Name, Headers, Extra) ->
    {ok, Bin} = file:read_file(filename:join(dir() ++ "-serve", Name ++ ".component.wasm")),
    Req = #{method => <<"POST">>, path => <<"/">>, scheme => <<"http">>,
            authority => <<"localhost">>, headers => Headers, body => <<"hello body">>},
    bounded(fun() -> wasi_preview3:run_serve(Bin, Req, Extra#{compile => true}) end).

p3_cases(_) ->
    Results = [{group(P), filename:basename(P, ".component.wasm"), outcome(P)}
               || P <- programs()],
    Failures = [{G, N, O} || {G, N, O} <- Results, O =/= pass],
    ct:log("~p", [Failures]),
    Counts = lists:foldl(fun({G, _, _}, M) -> maps:update_with(G, fun(C) -> C + 1 end, 1, M) end,
                         #{}, Failures),
    Regressions = [{G, maps:get(G, Counts, 0), Allowed}
                   || {G, Allowed} <- maps:to_list(baseline()),
                      maps:get(G, Counts, 0) > Allowed],
    ?assertEqual([], Regressions),
    Stale = [{G, maps:get(G, Counts, 0), Allowed}
             || {G, Allowed} <- maps:to_list(baseline()),
                maps:get(G, Counts, 0) < Allowed],
    ?assertEqual([], Stale),
    ?assert(length(Results) > length(Failures)).

%%% ------------------------------------------------------------- helpers ---

run(Name, Stdin, Opts) ->
    {ok, Bin} = file:read_file(filename:join(dir(), Name ++ ".component.wasm")),
    bounded(fun() -> wasi_preview3:run_command(Bin, Stdin, Opts#{compile => true}) end).

%% Each program in its own process, under a deadline.
bounded(Fun) ->
    {Pid, Mon} = spawn_monitor(fun() -> exit({done, Fun()}) end),
    receive
        {'DOWN', Mon, process, Pid, {done, R}} -> R;
        {'DOWN', Mon, process, Pid, Other} -> {error, {crashed, Other}}
    after 60000 ->
        exit(Pid, kill),
        {error, timeout}
    end.

outcome(Path) ->
    Name = filename:basename(Path, ".component.wasm"),
    case {Name, run(Name, stdin(Name), opts(Name))} of
        {_, {ok, #{exit_code := 0}}} -> pass;
        %% Passes by trapping at the limit, as wasmtime's own test has it.
        {"p3_cli_many_tasks", {error, #{ctx := #{reason := resource_limit_reached}}}} ->
            pass;
        {_, Other} -> Other
    end.

stdin("p3_cli_read_stdin") -> <<"hello!">>;
stdin(_) -> <<>>.

%% As wasmtime's own harness runs them: the program's name and "." as its
%% arguments, its errno environment, and a fresh writable scratch directory
%% mounted as ".".
opts("p3_cli_random_limits") -> #{args => [~"p3_cli_random_limits", ~"random", ~"256"]};
opts("p3_cli_much_stdout") ->
    #{args => [~"p3_cli_much_stdout", binary:copy(<<"a">>, 1024), ~"256"]};
opts("p3_cli_many_tasks") -> #{resource_limit => 100};
%% TCP with no right to listen: the bind it tries is refused.
opts("p3_cli_deny_listen" = Name) ->
    (base(Name))#{network => (unrestricted())#{listen => []}};
opts("p3_sockets" ++ _ = Name) ->
    (base(Name))#{network => unrestricted()};
%% The outbound programs reach the loopback server; the timeout one connects to
%% an unroutable TEST-NET-3 address and expects the connect to time out.
opts("p3_http_outbound_request" ++ _ = Name) ->
    Grant = loopback(),
    Connect = [{tcp, ~"203.0.113.12", {0, 65535}} | maps:get(connect, Grant)],
    (base(Name))#{network => Grant#{connect => Connect},
                  env => [errno_mode(),
                          {~"HTTP_SERVER", persistent_term:get({?MODULE, http})}]};
opts(Name) -> base(Name).

base(Name) ->
    #{args => [list_to_binary(Name ++ ".component"), ~"."],
      env => [errno_mode()],
      preopens => [{~".", scratch(), true} | readonly(Name)]}.

%% The cross-permission programs also get a read-only mount holding a file
%% they must not be able to change.
readonly(Name) when Name =:= "p3_file_truncation_readonly";
                    Name =:= "p3_file_hardlink_across_perms";
                    Name =:= "p3_file_rename_across_perms" ->
    Dir = scratch(),
    ok = file:write_file(filename:join(Dir, "test.txt"), <<"read only test file\n">>),
    [{~"readonly", Dir, false}];
readonly(_) ->
    [].

%% Any address and port for TCP and UDP, and name resolution.
unrestricted() ->
    Any = [{P, R, {0, 65535}} || P <- [tcp, udp], R <- [~"0.0.0.0/0", ~"::/0"]],
    #{connect => Any, listen => Any, resolve => allow}.

loopback() ->
    Local = [{P, A, {0, 65535}} || P <- [tcp, udp], A <- [~"127.0.0.1", ~"::1"]],
    #{connect => Local, listen => Local, resolve => allow}.

%% wasmtime's `wasi_tests_environment()': which errno conventions to expect.
errno_mode() ->
    case os:type() of
        {unix, darwin} -> {~"ERRNO_MODE_MACOS", ~"1"};
        _ -> {~"ERRNO_MODE_UNIX", ~"1"}
    end.

%% Fresh for every program and every run: a unique integer alone repeats
%% across VMs, and an earlier run's files then showed up in a listing.
scratch() ->
    Dir = filename:join(os:getenv("TMPDIR", "/tmp"),
                        lists:concat(["wasi3-", os:system_time(nanosecond), "-",
                                      erlang:unique_integer([positive])])),
    ok = filelib:ensure_path(Dir),
    Dir.

group(Path) ->
    case filename:basename(Path) of
        %% Denies a listen: it needs wasi:sockets.
        "p3_cli_deny_listen" ++ _ -> ~"sockets";
        "p3_cli" ++ _ -> ~"cli";
        "p3_clocks" ++ _ -> ~"clocks";
        "p3_random" ++ _ -> ~"random";
        "p3_big_random" ++ _ -> ~"random";
        "p3_file" ++ _ -> ~"filesystem";
        "p3_readdir" ++ _ -> ~"filesystem";
        "p3_sockets" ++ _ -> ~"sockets";
        "p3_http" ++ _ -> ~"http";
        _ -> ~"other"
    end.

programs() ->
    lists:sort([P || P <- filelib:wildcard(filename:join(dir(), "p3_*.component.wasm")),
                     not lists:member(filename:basename(P, ".component.wasm"), slow())]).

%% Programs that pass but run past the sweep's 60 s bound, run by hand.
%% p3_sockets_tcp_streams reads 2 MB a byte at a time through a debug build,
%% twice: about seven minutes interpreted (test/audit/PERF.md).
slow() -> ["p3_sockets_tcp_streams"].

dir() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..", "test", "fixtures",
                   "wasmtime-p3"]).
