-module(wasm_wasi2_fs_SUITE).
-moduledoc """
A component that reads files runs against the read-only `wasi:filesystem` host
(`wasi_preview2:filesystem/1`).

The guest imports `wasi:filesystem/preopens` and `.../types` and exports `cat`
(open a file and read it to end), `present` (does open-at succeed), and
`root-is-dir`. See `scripts/build-component-fixture.sh`. The point of this suite
is `the_sandbox_holds`: the four escape routes Preview 1 refuses are refused here
too, because open-at goes straight through `wasi_fs:open/3` and does not resolve
paths itself.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [a_file_reads_back_whole,
     the_root_is_a_directory,
     the_sandbox_holds,
     descriptors_do_not_leak].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(fixture_path()),
    Priv = ?config(priv_dir, Config),
    Root = filename:join(Priv, "fsroot"),
    Outside = filename:join(Priv, "outside"),
    ok = filelib:ensure_path(filename:join(Root, "sub")),
    ok = filelib:ensure_path(Outside),
    ok = file:write_file(filename:join(Root, "hello.txt"), <<"hello world">>),
    Big = crypto:strong_rand_bytes(10000),
    ok = file:write_file(filename:join(Root, "big.bin"), Big),
    ok = file:write_file(filename:join(Root, "empty.txt"), <<>>),
    ok = file:write_file(filename:join(Outside, "secret.txt"), <<"secret">>),
    %% A symlink whose target is outside the sandbox, for the escape test.
    _ = file:make_symlink(Outside, filename:join(Root, "escape")),
    [{component, Bin}, {root, Root}, {big, Big} | Config].

end_per_suite(_Config) -> ok.

%% A file reads back byte for byte, across sizes including empty and one larger
%% than the guest's 4096 read (so the read/offset/eof loop runs).
a_file_reads_back_whole(Config) ->
    Big = ?config(big, Config),
    [begin
         {ok, I} = instance(Config),
         ?assertEqual(Expected, cat(I, Name))
     end || {Name, Expected} <- [{<<"hello.txt">>, <<"hello world">>},
                                 {<<"empty.txt">>, <<>>},
                                 {<<"big.bin">>, Big}]].

the_root_is_a_directory(Config) ->
    {ok, I} = instance(Config),
    ?assertEqual(true, root_is_dir(I)),
    ?assertEqual(true, present(I, <<"hello.txt">>)),
    ?assertEqual(false, present(I, <<"nope.txt">>)).

%% The sandbox: each escape route Preview 1 closes is refused here too. If open-at
%% ever resolved a path itself instead of through wasi_fs:open, one of these would
%% open and this fails.
the_sandbox_holds(Config) ->
    {ok, I} = instance(Config),
    [?assertEqual(false, present(I, P))
     || P <- [<<"../../etc/passwd">>,   % parent traversal
              <<"sub/../../outside">>,  % escape partway through
              <<"/etc/passwd">>,        % absolute
              <<"escape/secret.txt">>]].% through a symlink pointing out

%% The dir and file descriptors the guest opened are freed once cat returns: the
%% guest dropped them and the host closed the fd and forgot the root.
descriptors_do_not_leak(Config) ->
    ?assertEqual([], wasm_component:host_live()),
    {ok, I} = instance(Config),
    _ = cat(I, <<"hello.txt">>),
    ?assertEqual([], wasm_component:host_live()).

%%% -------------------------------------------------------------- helpers ---

cat(I, Name) ->
    {ok, V} = wasm_component:call(I, <<"cat">>, {[string], {list, u8}}, [Name]),
    V.

present(I, Name) ->
    {ok, V} = wasm_component:call(I, <<"present">>, {[string], bool}, [Name]),
    V.

root_is_dir(I) ->
    {ok, V} = wasm_component:call(I, <<"root-is-dir">>, {[], bool}, []),
    V.

instance(Config) ->
    wasm_component:instantiate(
      ?config(component, Config),
      wasi_preview2:filesystem(#{preopen => ?config(root, Config)})).

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "wasifs.component.wasm"]).
