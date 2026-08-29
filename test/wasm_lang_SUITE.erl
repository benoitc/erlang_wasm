%% @doc A real language runtime, running real scripts.
%%
%% Every other module here was written for this runtime, or is a conformance
%% oracle. This one is a 1.8 MB QuickJS build produced by somebody else's
%% toolchain, which has never heard of this project, and it is the only test
%% that answers "is this usable" rather than "is this correct".
%%
%% It earned its place immediately: the first attempt to run it aborted the
%% emulator, because a function reference carried its whole instance and the
%% table held a thousand of them. `wasm_scale_SUITE' pins that property
%% directly; this pins the thing that made it visible.
%%
%% It also happens to be an independent check of the socket extension from
%% `wasi_sock_ext_SUITE': this module imports twelve of those calls, with the
%% signatures that suite asserts, including the two-argument `sock_accept'.
%%
%% Fetch with `scripts/fetch-qjs-fixture.sh'; the artefact is not committed.
-module(wasm_lang_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("wasm.hrl").

all() ->
    [imports_only_wasi,
     evaluates_a_script,
     computes_something,
     a_script_cannot_leave_its_directory,
     two_instances_do_not_share].

init_per_suite(Config) ->
    case file:read_file(module_path()) of
        {error, _} ->
            {skip, "no QuickJS build: run scripts/fetch-qjs-fixture.sh"};
        {ok, Bin} ->
            {ok, Mod} = wasm:compile(Bin),
            [{mod, Mod}, {size, byte_size(Bin)} | Config]
    end.

end_per_suite(_) -> ok.

module_path() ->
    filename:join([wasm_spec_runner:fixtures_dir(), "lang", "qjs.wasm"]).

%%% ---------------------------------------------------------------- running ---

%% Runs `Script' as the module's argument, with `Dir' as its only preopen. That
%% is the whole WASI command model: argument marshalling, preopen discovery,
%% `path_open', buffered stdout and `proc_exit'.
run(Config, Dir, Script) ->
    Self = self(),
    Sink = fun(D) -> Self ! {out, D}, ok end,
    Cfg = #{args => [~"qjs", list_to_binary(Script)],
            env => #{},
            dirs => [{~"/", Dir, read}],
            clocks => [monotonic, realtime],
            random => strong,
            stdout => Sink, stderr => Sink},
    {ok, Inst} = wasm:instantiate(?config(mod, Config), wasi_preview1:imports(Cfg)),
    Result = wasm:call(Inst, ~"_start", []),
    ok = wasm:destroy(Inst),
    {Result, drain(<<>>)}.

drain(Acc) ->
    receive {out, D} -> drain(<<Acc/binary, D/binary>>)
    after 0 -> Acc
    end.

write_script(Config, Name, Source) ->
    Dir = ?config(priv_dir, Config),
    ok = file:write_file(filename:join(Dir, Name), Source),
    Dir.

%%% ------------------------------------------------------------------ cases ---

%% Nothing but WASI, so the module needs no host functions this runtime does
%% not already implement. Worth asserting, because if it ever imports something
%% else the other failures here would be confusing rather than informative.
imports_only_wasi(Config) ->
    {ok, Bin} = file:read_file(module_path()),
    {ok, M} = wasm_decode:module(Bin),
    Modules = lists:usort([Mod || #import{module = Mod} <- M#module.imports]),
    ct:pal("~p bytes, imports from ~p", [?config(size, Config), Modules]),
    ?assertEqual([~"wasi_snapshot_preview1"], Modules).

evaluates_a_script(Config) ->
    Dir = write_script(Config, "hello.js", ~"print('hello from javascript');"),
    {Result, Out} = run(Config, Dir, "hello.js"),
    ct:pal("result ~p, output ~p", [Result, Out]),
    ?assertEqual(~"hello from javascript\n", Out).

%% A loop, so the answer depends on the interpreter actually interpreting
%% rather than on a string coming back out of a buffer.
computes_something(Config) ->
    Dir = write_script(Config, "sum.js",
                       ~"let s = 0; for (let i = 1; i <= 1000; i++) s += i; print(s);"),
    {_Result, Out} = run(Config, Dir, "sum.js"),
    ?assertEqual(~"500500\n", Out).

%% The sandbox, against a real standard library rather than a hand-written
%% probe. The script names a path outside its only preopen and must not get it.
a_script_cannot_leave_its_directory(Config) ->
    Secret = filename:join(?config(priv_dir, Config), "secret.txt"),
    ok = file:write_file(Secret, ~"TOPSECRET"),
    Dir = filename:join(?config(priv_dir, Config), "sandbox"),
    ok = filelib:ensure_path(Dir),
    Escape = ~"try { print(std.loadFile('../secret.txt')); } catch (e) { print('refused'); }",
    ok = file:write_file(filename:join(Dir, "escape.js"), Escape),
    {_Result, Out} = run(Config, Dir, "escape.js"),
    ct:pal("escape attempt said ~p", [Out]),
    ?assertNotEqual(match, re:run(Out, "TOPSECRET", [{capture, none}])).

%% Each instance gets its own linear memory and its own descriptor table, so
%% one script cannot see what another left behind. This is the property a
%% worker with `isolation => fresh' rests on.
two_instances_do_not_share(Config) ->
    Dir = write_script(Config, "count.js",
                       ~"globalThis.n = (globalThis.n || 0) + 1; print(globalThis.n);"),
    {_, First} = run(Config, Dir, "count.js"),
    {_, Second} = run(Config, Dir, "count.js"),
    ?assertEqual(First, Second),
    ?assertEqual(~"1\n", First).
