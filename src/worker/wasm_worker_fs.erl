-module(wasm_worker_fs).
-moduledoc """
Internal: the file operations a request makes, done in the calling process.

Every function here is a raw operation. The ordinary `file` and `filelib`
functions send each operation to `file_server_2`, one process for the node, so
every request on the node queued behind every other one to create a
directory, stage a file or remove a tree. Measured at 14 workers, a request
made about 34 such calls and the server's queue held 4 on average. These do
the same work in the caller, which is where the work was always charged.

Only absolute paths are passed here, so the one thing the file server adds on
top of the operation, resolving a relative name against its own working
directory, is never needed.
""".

-export([ensure_path/1, ensure_dir/1, write_file/2, rename/2, delete/1,
         del_dir_r/1, empty_dir/1, exists/1]).

-include_lib("kernel/include/file.hrl").

-doc "Make `Dir` and every missing parent, like `filelib:ensure_path/1`.".
-spec ensure_path(file:filename_all()) -> ok | {error, term()}.
ensure_path(Dir) ->
    case is_dir(Dir) of
        true -> ok;
        false ->
            Parent = filename:dirname(Dir),
            case Parent =:= Dir of
                true -> {error, enoent};
                false ->
                    case ensure_path(Parent) of
                        ok -> make_dir(Dir);
                        {error, _} = E -> E
                    end
            end
    end.

-doc "Make the parent of `File`, like `filelib:ensure_dir/1`.".
-spec ensure_dir(file:filename_all()) -> ok | {error, term()}.
ensure_dir(File) -> ensure_path(filename:dirname(File)).

-spec write_file(file:filename_all(), iodata()) -> ok | {error, term()}.
write_file(Path, Data) -> file:write_file(Path, Data, [raw]).

-spec rename(file:filename_all(), file:filename_all()) -> ok | {error, term()}.
rename(From, To) -> prim_file:rename(From, To).

-spec delete(file:filename_all()) -> ok | {error, term()}.
delete(Path) -> file:delete(Path, [raw]).

-spec exists(file:filename_all()) -> boolean().
exists(Path) ->
    case file:read_link_info(Path, [raw]) of
        {ok, _} -> true;
        {error, _} -> false
    end.

-doc """
Remove `Path` and everything under it, like `file:del_dir_r/1`.

A symbolic link is removed and never followed, which is the property that
makes this safe on a directory a guest could write into.
""".
-spec del_dir_r(file:filename_all()) -> ok | {error, term()}.
del_dir_r(Path) ->
    case file:read_link_info(Path, [raw]) of
        {ok, #file_info{type = directory}} ->
            case empty_dir(Path) of
                ok -> prim_file:del_dir(Path);
                {error, _} = E -> E
            end;
        {ok, _} ->
            delete(Path);
        {error, _} = E ->
            E
    end.

-doc "Remove everything under `Dir` and keep `Dir` itself.".
-spec empty_dir(file:filename_all()) -> ok | {error, term()}.
empty_dir(Dir) ->
    case prim_file:list_dir_all(Dir) of
        {ok, Names} ->
            lists:foldl(fun(N, ok) -> del_dir_r(filename:join(Dir, N));
                           (_N, E) -> E
                        end, ok, Names);
        {error, _} = E ->
            E
    end.

is_dir(Dir) ->
    case file:read_file_info(Dir, [raw]) of
        {ok, #file_info{type = directory}} -> true;
        _ -> false
    end.

%% Another process making the same directory between the check and the call
%% is not an error.
make_dir(Dir) ->
    case prim_file:make_dir(Dir) of
        ok -> ok;
        {error, eexist} ->
            case is_dir(Dir) of
                true -> ok;
                false -> {error, eexist}
            end;
        {error, _} = E -> E
    end.
