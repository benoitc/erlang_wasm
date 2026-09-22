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
     descriptors_do_not_leak,
     stat_reports_the_size,
     the_directory_is_listed,
     read_via_stream_reads_the_file].

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

%% stat via the NIF-backed wasi_fs reports the real file size.
stat_reports_the_size(Config) ->
    {ok, I} = instance(Config),
    ?assertEqual(11, size(I, <<"hello.txt">>)),
    ?assertEqual(0, size(I, <<"empty.txt">>)),
    ?assertEqual(10000, size(I, <<"big.bin">>)).

%% read-directory lists the entries; the known names are all there.
the_directory_is_listed(Config) ->
    {ok, I} = instance(Config),
    Names = entries(I),
    [?assert(lists:member(N, Names))
     || N <- [<<"hello.txt">>, <<"big.bin">>, <<"empty.txt">>, <<"sub">>]].

%% read-via-stream returns a wasi:io input-stream over the file; reading it back
%% yields the file (exercises the filesystem-to-io bridge).
read_via_stream_reads_the_file(Config) ->
    Big = ?config(big, Config),
    {ok, I} = instance(Config),
    ?assertEqual(<<"hello world">>, slurp(I, <<"hello.txt">>)),
    ?assertEqual(Big, slurp(I, <<"big.bin">>)).

%%% -------------------------------------------------------------- helpers ---

size(I, Name) ->
    {ok, V} = wasm_component:call(I, <<"size">>, {[string], u64}, [Name]),
    V.

entries(I) ->
    {ok, V} = wasm_component:call(I, <<"entries">>, {[], {list, string}}, []),
    V.

slurp(I, Name) ->
    {ok, V} = wasm_component:call(I, <<"slurp">>, {[string], {list, u8}}, [Name]),
    V.

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
    %% The guest also imports wasi:io/streams (read-via-stream returns an
    %% input-stream), so filesystem and io are both supplied.
    Imports = maps:merge(
                wasi_preview2:filesystem(#{preopen => ?config(root, Config)}),
                wasi_preview2:io()),
    wasm_component:instantiate(?config(component, Config), Imports).

fixture_path() ->
    filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                   "test", "fixtures", "component", "wasifs.component.wasm"]).
