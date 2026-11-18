-module(wasi_nul_path_SUITE).
-moduledoc """
A NUL byte inside a guest path is refused, by every WASI version.

A path a guest passes is bytes with a length, and the native backend hands it
to C, where the first NUL ends the string. So `made\0suffix` acted on `made`:
WASI 0.2 and 0.3 refused one only in `open-at`, and every other path operation
created, removed, renamed, linked or re-timed the name before the NUL, inside a
writable granted directory. Preview 1 refuses one when it reads the path.

The cases run at three levels: `wasi_fs` on each backend, the WASI 0.2
operations, and the WASI 0.3 import table. Each checks the answer and that
nothing on disk changed. Fail-first: on the parent 42 of the 44 cases failed.
The native backend made `made`, removed the victim and answered about the
prefix; the fallback changed nothing but answered `EIO` or `ENOENT` rather
than `EINVAL`. Only `open-at`, already guarded, passed in 0.2 and 0.3.
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("kernel/include/file.hrl").
-include("wasi.hrl").

%% A modification time no case sets, so a changed one shows.
-define(OLD, 1000000000).

all() ->
    [{group, fs_native}, {group, fs_fallback}, {group, preview2},
     {group, preview3}].

groups() ->
    [{fs_native, [], fs_cases()},
     {fs_fallback, [], fs_cases()},
     {preview2, [], p2_cases()},
     {preview3, [], p3_cases()}].

fs_cases() ->
    [fs_mkdir, fs_unlink, fs_rmdir, fs_symlink, fs_readlink, fs_stat,
     fs_set_times, fs_rename, fs_link, fs_open, fs_open_dir_at].

p2_cases() ->
    [p2_create_directory_at, p2_unlink_file_at, p2_remove_directory_at,
     p2_rename_at, p2_link_at, p2_symlink_at, p2_set_times_at, p2_stat_at,
     p2_readlink_at, p2_metadata_hash_at, p2_open_at].

p3_cases() ->
    [p3_create_directory_at, p3_unlink_file_at, p3_remove_directory_at,
     p3_rename_at, p3_link_at, p3_symlink_at, p3_set_times_at, p3_stat_at,
     p3_readlink_at, p3_metadata_hash_at, p3_open_at].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wasm),
    Config.

end_per_suite(_Config) -> ok.

init_per_group(fs_native, Config) ->
    case wasi_fs:backend() of
        native -> [{group, fs_native}, {backend, native} | Config];
        fallback -> {skip, "the native file backend is not built"}
    end;
init_per_group(fs_fallback, Config) ->
    [{group, fs_fallback}, {backend, fallback} | Config];
init_per_group(Group, Config) -> [{group, Group} | Config].

end_per_group(_, _Config) -> ok.

%% A fresh directory per case: a file `victim', a directory `vdir', a symlink
%% `alink' to `victim', all with a known modification time.
init_per_testcase(Case, Config) ->
    Dir = filename:join([?config(priv_dir, Config),
                         atom_to_list(?config(group, Config)),
                         atom_to_list(Case)]),
    ok = filelib:ensure_path(filename:join(Dir, "vdir")),
    ok = file:write_file(filename:join(Dir, "victim"), <<"keep me">>),
    ok = file:make_symlink("victim", filename:join(Dir, "alink")),
    ok = file:write_file_info(filename:join(Dir, "victim"),
                              #file_info{mtime = ?OLD}, [{time, posix}]),
    [{dir, Dir} | Config].

end_per_testcase(_Case, _Config) -> ok.

nul(Name) -> <<Name/binary, 0, "suffix">>.

%%% ------------------------------------------------------------- wasi_fs ---

root(Config) ->
    Dir = ?config(dir, Config),
    case ?config(backend, Config) of
        fallback -> {fallback, Dir};
        native -> {ok, R} = wasi_fs:preopen(Dir), R
    end.

fs_mkdir(Config) ->
    R = root(Config),
    ?assertEqual({error, ?EINVAL}, wasi_fs:mkdir(R, nul(~"made"))),
    refute_exists(Config, "made").

fs_unlink(Config) ->
    R = root(Config),
    ?assertEqual({error, ?EINVAL}, wasi_fs:unlink(R, nul(~"victim"))),
    assert_victim(Config).

fs_rmdir(Config) ->
    R = root(Config),
    ?assertEqual({error, ?EINVAL}, wasi_fs:rmdir(R, nul(~"vdir"))),
    ?assert(filelib:is_dir(path(Config, "vdir"))).

fs_symlink(Config) ->
    R = root(Config),
    ?assertEqual({error, ?EINVAL}, wasi_fs:symlink(R, nul(~"made"), ~"victim")),
    refute_exists(Config, "made"),
    ?assertEqual({error, ?EINVAL}, wasi_fs:symlink(R, ~"made", nul(~"victim"))),
    refute_exists(Config, "made").

fs_readlink(Config) ->
    R = root(Config),
    ?assertEqual({error, ?EINVAL}, wasi_fs:readlink(R, nul(~"alink"))).

fs_stat(Config) ->
    R = root(Config),
    ?assertEqual({error, ?EINVAL}, wasi_fs:stat(R, nul(~"victim"))),
    ?assertEqual({error, ?EINVAL}, wasi_fs:stat(R, nul(~"victim"), follow)),
    ?assertEqual({error, ?EINVAL}, wasi_fs:stat(R, nul(~"victim"), nofollow)).

fs_set_times(Config) ->
    R = root(Config),
    Now = os:system_time(nanosecond),
    ?assertEqual({error, ?EINVAL},
                 wasi_fs:set_times(R, nul(~"victim"), Now, Now)),
    ?assertEqual({error, ?EINVAL},
                 wasi_fs:set_times(R, nul(~"victim"), Now, Now, follow)),
    assert_victim(Config).

fs_rename(Config) ->
    R = root(Config),
    ?assertEqual({error, ?EINVAL},
                 wasi_fs:rename(R, nul(~"victim"), R, ~"moved")),
    ?assertEqual({error, ?EINVAL},
                 wasi_fs:rename(R, ~"victim", R, nul(~"moved"))),
    assert_victim(Config),
    refute_exists(Config, "moved").

fs_link(Config) ->
    R = root(Config),
    ?assertEqual({error, ?EINVAL}, wasi_fs:link(R, nul(~"victim"), R, ~"hard")),
    ?assertEqual({error, ?EINVAL}, wasi_fs:link(R, ~"victim", R, nul(~"hard"))),
    refute_exists(Config, "hard").

fs_open(Config) ->
    R = root(Config),
    ?assertEqual({error, ?EINVAL}, wasi_fs:open(R, nul(~"victim"), [read])),
    ?assertEqual({error, ?EINVAL},
                 wasi_fs:open(R, nul(~"made"), [write, create])),
    refute_exists(Config, "made").

fs_open_dir_at(Config) ->
    R = root(Config),
    ?assertEqual({error, ?EINVAL}, wasi_fs:open_dir_at(R, nul(~"vdir"))).

%%% ------------------------------------------------------------ WASI 0.2 ---
%%
%% The operations `wasi_p2_filesystem' exports, which both the 0.2 import table
%% and the 0.3 one call, on a writable preopen made in this process.

preopen(Config) ->
    Mounts = wasi_p2_filesystem:mounts_of(#{preopen => ?config(dir, Config),
                                            writable => true}),
    [{D, _Name}] = wasi_p2_filesystem:get_directories(Mounts),
    D.

-define(INVALID, {error, ~"invalid"}).

p2_create_directory_at(Config) ->
    D = preopen(Config),
    ?assertEqual(?INVALID,
                 wasi_p2_filesystem:create_directory_at(D, nul(~"made"))),
    refute_exists(Config, "made").

p2_unlink_file_at(Config) ->
    D = preopen(Config),
    ?assertEqual(?INVALID, wasi_p2_filesystem:unlink_file_at(D, nul(~"victim"))),
    assert_victim(Config).

p2_remove_directory_at(Config) ->
    D = preopen(Config),
    ?assertEqual(?INVALID,
                 wasi_p2_filesystem:remove_directory_at(D, nul(~"vdir"))),
    ?assert(filelib:is_dir(path(Config, "vdir"))).

p2_rename_at(Config) ->
    D = preopen(Config),
    ?assertEqual(?INVALID,
                 wasi_p2_filesystem:rename_at(D, nul(~"victim"), D, ~"moved")),
    ?assertEqual(?INVALID,
                 wasi_p2_filesystem:rename_at(D, ~"victim", D, nul(~"moved"))),
    assert_victim(Config),
    refute_exists(Config, "moved").

p2_link_at(Config) ->
    D = preopen(Config),
    ?assertEqual(?INVALID,
                 wasi_p2_filesystem:link_at(D, [], nul(~"victim"), D, ~"hard")),
    ?assertEqual(?INVALID,
                 wasi_p2_filesystem:link_at(D, [], ~"victim", D, nul(~"hard"))),
    refute_exists(Config, "hard").

p2_symlink_at(Config) ->
    D = preopen(Config),
    ?assertEqual(?INVALID,
                 wasi_p2_filesystem:symlink_at(D, ~"victim", nul(~"made"))),
    refute_exists(Config, "made"),
    ?assertEqual(?INVALID,
                 wasi_p2_filesystem:symlink_at(D, nul(~"victim"), ~"made")),
    refute_exists(Config, "made").

p2_set_times_at(Config) ->
    D = preopen(Config),
    Now = {~"now", undefined},
    ?assertEqual(?INVALID,
                 wasi_p2_filesystem:set_times_at(D, [], nul(~"victim"), Now,
                                                 Now)),
    assert_victim(Config).

p2_stat_at(Config) ->
    D = preopen(Config),
    ?assertEqual(?INVALID, wasi_p2_filesystem:stat_at(D, [], nul(~"victim"))),
    ?assertEqual(?INVALID,
                 wasi_p2_filesystem:stat_at(D, [~"symlink-follow"],
                                            nul(~"victim"))).

p2_readlink_at(Config) ->
    D = preopen(Config),
    ?assertEqual(?INVALID, wasi_p2_filesystem:readlink_at(D, nul(~"alink"))).

p2_metadata_hash_at(Config) ->
    D = preopen(Config),
    ?assertEqual(?INVALID,
                 wasi_p2_filesystem:metadata_hash_at(D, [], nul(~"victim"))).

p2_open_at(Config) ->
    D = preopen(Config),
    ?assertEqual(?INVALID,
                 wasi_p2_filesystem:open_at(D, [], nul(~"made"), [~"create"],
                                            [~"write"])),
    refute_exists(Config, "made").

%%% ------------------------------------------------------------ WASI 0.3 ---
%%
%% The 0.3 import table's own entries, called directly: each is
%% `{async_import, Sig, Fun}' and `Fun' takes the lifted arguments. A 0.3
%% error-code is a variant case, so `invalid' carries no payload.

-define(P3_INVALID, {error, {~"invalid", undefined}}).

p3(Name, Args) ->
    Table = wasi_p3_filesystem:filesystem(#{}),
    Key = {~"wasi:filesystem/types@0.3", <<"[method]descriptor.", Name/binary>>},
    {async_import, _Sig, Fun} = maps:get(Key, Table),
    Fun(Args).

p3_create_directory_at(Config) ->
    D = preopen(Config),
    ?assertEqual(?P3_INVALID, p3(~"create-directory-at", [D, nul(~"made")])),
    refute_exists(Config, "made").

p3_unlink_file_at(Config) ->
    D = preopen(Config),
    ?assertEqual(?P3_INVALID, p3(~"unlink-file-at", [D, nul(~"victim")])),
    assert_victim(Config).

p3_remove_directory_at(Config) ->
    D = preopen(Config),
    ?assertEqual(?P3_INVALID, p3(~"remove-directory-at", [D, nul(~"vdir")])),
    ?assert(filelib:is_dir(path(Config, "vdir"))).

p3_rename_at(Config) ->
    D = preopen(Config),
    ?assertEqual(?P3_INVALID, p3(~"rename-at", [D, nul(~"victim"), D, ~"moved"])),
    ?assertEqual(?P3_INVALID, p3(~"rename-at", [D, ~"victim", D, nul(~"moved")])),
    assert_victim(Config),
    refute_exists(Config, "moved").

p3_link_at(Config) ->
    D = preopen(Config),
    ?assertEqual(?P3_INVALID,
                 p3(~"link-at", [D, [], nul(~"victim"), D, ~"hard"])),
    ?assertEqual(?P3_INVALID,
                 p3(~"link-at", [D, [], ~"victim", D, nul(~"hard")])),
    refute_exists(Config, "hard").

p3_symlink_at(Config) ->
    D = preopen(Config),
    ?assertEqual(?P3_INVALID, p3(~"symlink-at", [D, ~"victim", nul(~"made")])),
    ?assertEqual(?P3_INVALID, p3(~"symlink-at", [D, nul(~"victim"), ~"made"])),
    refute_exists(Config, "made").

p3_set_times_at(Config) ->
    D = preopen(Config),
    Now = {~"now", undefined},
    ?assertEqual(?P3_INVALID,
                 p3(~"set-times-at", [D, [], nul(~"victim"), Now, Now])),
    assert_victim(Config).

p3_stat_at(Config) ->
    D = preopen(Config),
    ?assertEqual(?P3_INVALID, p3(~"stat-at", [D, [], nul(~"victim")])).

p3_readlink_at(Config) ->
    D = preopen(Config),
    ?assertEqual(?P3_INVALID, p3(~"readlink-at", [D, nul(~"alink")])).

p3_metadata_hash_at(Config) ->
    D = preopen(Config),
    ?assertEqual(?P3_INVALID, p3(~"metadata-hash-at", [D, [], nul(~"victim")])).

p3_open_at(Config) ->
    D = preopen(Config),
    ?assertEqual(?P3_INVALID,
                 p3(~"open-at", [D, [], nul(~"made"), [~"create"], [~"write"]])),
    refute_exists(Config, "made").

%%% ------------------------------------------------------------- helpers ---

path(Config, Name) -> filename:join(?config(dir, Config), Name).

refute_exists(Config, Name) ->
    ?assertEqual({error, enoent}, file:read_link_info(path(Config, Name))).

%% The victim is still there, with its content and its old modification time.
assert_victim(Config) ->
    P = path(Config, "victim"),
    ?assertEqual({ok, <<"keep me">>}, file:read_file(P)),
    {ok, #file_info{mtime = M}} = file:read_file_info(P, [{time, posix}]),
    ?assertEqual(?OLD, M).
