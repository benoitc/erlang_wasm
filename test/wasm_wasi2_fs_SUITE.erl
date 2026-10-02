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
     read_via_stream_reads_the_file,
     a_file_is_written_and_read_back,
     a_directory_is_created,
     a_file_is_removed,
     mutations_are_refused_read_only,
     the_sandbox_holds_on_writes].

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
    %% A separate writable root for the write-side cases.
    WRoot = filename:join(Priv, "wroot"),
    ok = filelib:ensure_path(WRoot),
    [{component, Bin}, {root, Root}, {wroot, WRoot}, {big, Big} | Config].

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

%% On a writable filesystem a file written comes back byte for byte.
a_file_is_written_and_read_back(Config) ->
    {ok, I} = writable(Config),
    ?assertEqual(7, write_file(I, <<"new.txt">>, <<"content">>)),
    ?assertEqual(<<"content">>, cat(I, <<"new.txt">>)).

%% create-directory-at makes a directory under the sandbox.
a_directory_is_created(Config) ->
    {ok, I} = writable(Config),
    ?assertEqual(true, make_dir(I, <<"sub2">>)),
    ?assert(filelib:is_dir(filename:join(?config(wroot, Config), "sub2"))).

%% unlink-file-at removes a file.
a_file_is_removed(Config) ->
    {ok, I} = writable(Config),
    _ = write_file(I, <<"temp.txt">>, <<"x">>),
    ?assertEqual(true, remove(I, <<"temp.txt">>)),
    ?assertEqual(false, present(I, <<"temp.txt">>)).

%% A read-only filesystem refuses to mutate: create and unlink return an error,
%% so the guest's is-ok checks are false and nothing changes on disk.
mutations_are_refused_read_only(Config) ->
    {ok, I} = instance(Config),
    ?assertEqual(false, make_dir(I, <<"nope">>)),
    ?assertEqual(false, remove(I, <<"hello.txt">>)),
    ?assert(filelib:is_file(filename:join(?config(root, Config), "hello.txt"))).

%% Even writable, a mutation cannot escape the sandbox: wasi_fs refuses the path.
the_sandbox_holds_on_writes(Config) ->
    {ok, I} = writable(Config),
    ?assertEqual(false, make_dir(I, <<"../escape_dir">>)),
    ?assertEqual(false, remove(I, <<"../../etc/hosts">>)).

%%% -------------------------------------------------------------- helpers ---

write_file(I, Name, Data) ->
    {ok, V} = wasm_component:call(
                I, <<"write-file">>, {[string, {list, u8}], u64}, [Name, Data]),
    V.

make_dir(I, Name) ->
    {ok, V} = wasm_component:call(I, <<"make-dir">>, {[string], bool}, [Name]),
    V.

remove(I, Name) ->
    {ok, V} = wasm_component:call(I, <<"remove">>, {[string], bool}, [Name]),
    V.

writable(Config) ->
    Imports = maps:merge(
                wasi_preview2:filesystem(#{preopen => ?config(wroot, Config),
                                           writable => true}),
                wasi_preview2:io()),
    wasm_component:instantiate(?config(component, Config), Imports).

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
