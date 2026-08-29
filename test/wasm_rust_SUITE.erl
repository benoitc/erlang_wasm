%% @doc End-to-end acceptance: a real Rust `std` binary.
%%
%% This is the test that decides whether the runtime is usable for anything, as
%% opposed to correct on paper. It runs an unmodified `rustc --target
%% wasm32-wasip1 -O` build, entered through `_start` under the WASI command
%% model, which drags in the whole of Rust's startup path: argument and
%% environment marshalling, the preopen discovery dance
%% (`fd_prestat_get`/`fd_prestat_dir_name`), buffered stdout, `std::fs`, and
%% `proc_exit`.
%%
%% It also checks the sandbox against a real standard library rather than a
%% hand-written probe: `std::fs::read_to_string("/data/../secret/key.txt")`
%% must fail, with the module never learning the host path behind `/data`.
%%
%% Rebuild with `scripts/build-rust-fixture.sh`; the stripped artefact is
%% committed so this runs without a Rust toolchain.
-module(wasm_rust_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [runs_to_completion, sandbox_holds_against_std_fs,
     capabilities_are_what_was_granted, compiles_in_reasonable_time,
     directory_listing_and_positional_io, rename_round_trips, sleep_actually_waits].

init_per_suite(Config) ->
    Path = filename:join([wasm_spec_runner:fixtures_dir(), "rust",
                          "wasi_demo.wasm"]),
    case file:read_file(Path) of
        {error, _} -> {skip, "rust fixture missing"};
        {ok, Bin} ->
            {ok, Mod} = wasm:compile(Bin),
            [{mod, Mod}, {size, byte_size(Bin)} | Config]
    end.

end_per_suite(_) -> ok.

init_per_testcase(_Case, Config) ->
    Priv = ?config(priv_dir, Config),
    Data = filename:join(Priv, "data"),
    Secret = filename:join(Priv, "secret"),
    %% Every case runs the whole program, which writes and renames a file, so
    %% the directory has to start empty or `fd_readdir' sees leftovers from the
    %% case before it.
    _ = file:del_dir_r(Data),
    ok = filelib:ensure_path(Data),
    ok = filelib:ensure_path(Secret),
    ok = file:write_file(filename:join(Data, "note.txt"), <<"contents of note\n">>),
    ok = file:write_file(filename:join(Secret, "key.txt"), <<"TOPSECRET\n">>),
    [{data, Data} | Config].

end_per_testcase(_, _) -> ok.

%%% ---------------------------------------------------------------- running ---

run(Config, Extra) ->
    Base = #{stdout => self(), stderr => self(),
             args => [<<"prog">>, <<"--verbose">>],
             env => #{<<"MODE">> => <<"production">>},
             dirs => [{<<"/data">>, ?config(data, Config), write}],
             clocks => [monotonic, realtime], random => strong},
    Cfg = maps:merge(Base, Extra),
    {ok, I} = wasm:instantiate(?config(mod, Config), wasi_preview1:imports(Cfg)),
    Result = wasm:call(I, <<"_start">>, []),
    {Result, drain()}.

drain() -> iolist_to_binary(drain(500)).
drain(T) ->
    receive {wasi_output, _, Out} -> [Out | drain(50)]
    after T -> []
    end.

%%% ------------------------------------------------------------------ cases ---

runs_to_completion(Config) ->
    {Result, Out} = run(Config, #{}),
    ct:log("program output:~n~ts", [Out]),
    %% `std::process::exit(7)' arrives as a trap carrying the status, because a
    %% trap is the only way to unwind a WebAssembly stack.
    ?assertMatch({error, _}, Result),
    {error, Err} = Result,
    ?assertEqual({ok, 7}, wasi_preview1:exit_code(Err)),
    ?assertNotEqual(nomatch, binary:match(Out, <<"hello from rust on wasm">>)),
    %% Real recursion through the interpreter, from optimised Rust.
    ?assertNotEqual(nomatch, binary:match(Out, <<"fib(20)=6765">>)),
    %% stdout and stderr both reach the configured sink.
    ?assertNotEqual(nomatch, binary:match(Out, <<"this goes to stderr">>)).

%% The escape is attempted by Rust's own standard library, through the preopen
%% table it built from `fd_prestat_*'. It must fail, and the successful read of
%% a legitimate file in the same directory shows the failure is the capability
%% check rather than the filesystem being broken.
sandbox_holds_against_std_fs(Config) ->
    {_Result, Out} = run(Config, #{}),
    ?assertNotEqual(nomatch, binary:match(Out, <<"file: contents of note">>)),
    ?assertNotEqual(nomatch, binary:match(Out, <<"escape refused">>)),
    ?assertEqual(nomatch, binary:match(Out, <<"ESCAPED">>)),
    ?assertEqual(nomatch, binary:match(Out, <<"TOPSECRET">>)).

capabilities_are_what_was_granted(Config) ->
    %% Environment is what the embedder passed, not the host's.
    {_, WithEnv} = run(Config, #{}),
    ?assertNotEqual(nomatch, binary:match(WithEnv, <<"MODE=production">>)),
    {_, NoEnv} = run(Config, #{env => #{}}),
    ?assertNotEqual(nomatch, binary:match(NoEnv, <<"MODE unset">>)),
    %% With no directory granted there is no preopen to resolve against, so the
    %% legitimate read fails too. Absent means absent, not "defaults to cwd".
    {_, NoDirs} = run(Config, #{dirs => []}),
    ?assertNotEqual(nomatch, binary:match(NoDirs, <<"file error">>)).

%% `fd_readdir` and positional I/O, driven by `std::fs::read_dir` and
%% `Seek`, not by a hand-written probe.
directory_listing_and_positional_io(Config) ->
    {_, Out} = run(Config, #{}),
    ?assertNotEqual(nomatch, binary:match(Out, <<"readdir: [\"note.txt\"]">>)),
    %% Seek to 8 in "contents of note" then read: the tail, and a position of 16.
    ?assertNotEqual(nomatch, binary:match(Out, <<"seek+read: \" of note\"">>)),
    ?assertNotEqual(nomatch, binary:match(Out, <<"stream_position: 16">>)).

%% `fs::write` then `fs::rename` then read back, all through the capability.
rename_round_trips(Config) ->
    {_, Out} = run(Config, #{}),
    ?assertNotEqual(nomatch, binary:match(Out, <<"rename ok: written by wasm">>)),
    %% The rename landed inside the preopen, not somewhere else.
    ?assert(filelib:is_regular(filename:join(?config(data, Config), "renamed.txt"))).

%% `thread::sleep` needs `poll_oneoff` clock subscriptions.
%%
%% The duration is asserted from *outside*, because the program's own check is
%% `elapsed >= 25ms` and that is satisfied just as well by sleeping far too
%% long. A padding error in the subscription struct made every sleep hit the
%% 60 second cap, and the in-program check passed happily throughout.
sleep_actually_waits(Config) ->
    T0 = erlang:monotonic_time(millisecond),
    {_, Out} = run(Config, #{}),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    ?assertNotEqual(nomatch, binary:match(Out, <<"slept: true">>)),
    %% It really slept (the program asks for 30 ms), and it did not oversleep.
    ?assert(Elapsed >= 25, {slept_too_little, Elapsed}),
    ?assert(Elapsed < 5000, {slept_far_too_long, Elapsed}).

%% A 98 KB module with Rust's runtime in it. This is a smoke test against
%% pathological behaviour in the pipeline (quadratic decoding, runaway IR
%% construction), not a benchmark: the bound is deliberately loose because the
%% machine it runs on is not controlled.
compiles_in_reasonable_time(_Config) ->
    Path = filename:join([wasm_spec_runner:fixtures_dir(), "rust",
                          "wasi_demo.wasm"]),
    {ok, Bin} = file:read_file(Path),
    T0 = erlang:monotonic_time(millisecond),
    {ok, _} = wasm:compile(Bin),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    ct:log("compiled ~p bytes in ~p ms", [byte_size(Bin), Elapsed]),
    ?assert(Elapsed < 5000).
