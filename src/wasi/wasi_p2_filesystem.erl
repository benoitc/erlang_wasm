-module(wasi_p2_filesystem).
-moduledoc """
The `wasi:filesystem` slice of the WASI 0.2 host: `filesystem/1` builds the
`wasi:filesystem/types` and `wasi:filesystem/preopens` imports over preopened
directories, read-only or writable per mount.

Read it when you change what a descriptor can do. Paths go through `wasi_fs`,
the same calls Preview 1 makes, so the sandbox is not reimplemented here. The
streams a descriptor opens are the `output-stream` and `input-stream` resources
`wasi_preview2` serves; this module only mints them, and never calls back into
`wasi_preview2`.
""".

-include("wasi.hrl").

-export([filesystem/1]).

%% wasi:filesystem enums, in WIT order (the enum discriminant is the index).
-define(ERROR_CODE,
        {enum, [<<"access">>, <<"would-block">>, <<"already">>,
                <<"bad-descriptor">>, <<"busy">>, <<"deadlock">>, <<"quota">>,
                <<"exist">>, <<"file-too-large">>, <<"illegal-byte-sequence">>,
                <<"in-progress">>, <<"interrupted">>, <<"invalid">>, <<"io">>,
                <<"is-directory">>, <<"loop">>, <<"too-many-links">>,
                <<"message-size">>, <<"name-too-long">>, <<"no-device">>,
                <<"no-entry">>, <<"no-lock">>, <<"insufficient-memory">>,
                <<"insufficient-space">>, <<"not-directory">>, <<"not-empty">>,
                <<"not-recoverable">>, <<"unsupported">>, <<"no-tty">>,
                <<"no-such-device">>, <<"overflow">>, <<"not-permitted">>,
                <<"pipe">>, <<"read-only">>, <<"invalid-seek">>,
                <<"text-file-busy">>, <<"cross-device">>]}).
-define(DESC_TYPE,
        {enum, [<<"unknown">>, <<"block-device">>, <<"character-device">>,
                <<"directory">>, <<"fifo">>, <<"symbolic-link">>,
                <<"regular-file">>, <<"socket">>]}).
-define(PATH_FLAGS, {flags, [<<"symlink-follow">>]}).
-define(OPEN_FLAGS,
        {flags, [<<"create">>, <<"directory">>, <<"exclusive">>,
                 <<"truncate">>]}).
-define(DESC_FLAGS,
        {flags, [<<"read">>, <<"write">>, <<"file-integrity-sync">>,
                 <<"data-integrity-sync">>, <<"requested-write-sync">>,
                 <<"mutate-directory">>]}).
-define(OPEN_RESULT, {result, handle, ?ERROR_CODE}).
-define(READ_AT_RESULT, {result, {tuple, [{list, u8}, bool]}, ?ERROR_CODE}).
-define(TYPE_RESULT, {result, ?DESC_TYPE, ?ERROR_CODE}).
-define(DATETIME2, {record, [{<<"seconds">>, u64}, {<<"nanoseconds">>, u32}]}).
-define(DESCRIPTOR_STAT,
        {record, [{<<"type">>, ?DESC_TYPE},
                  {<<"link-count">>, u64},
                  {<<"size">>, u64},
                  {<<"data-access-timestamp">>, {option, ?DATETIME2}},
                  {<<"data-modification-timestamp">>, {option, ?DATETIME2}},
                  {<<"status-change-timestamp">>, {option, ?DATETIME2}}]}).
-define(STAT_RESULT, {result, ?DESCRIPTOR_STAT, ?ERROR_CODE}).
-define(DIR_ENTRY, {record, [{<<"type">>, ?DESC_TYPE}, {<<"name">>, string}]}).
-define(DIR_ENTRY_RESULT, {result, {option, ?DIR_ENTRY}, ?ERROR_CODE}).
-define(FLAGS_RESULT, {result, ?DESC_FLAGS, ?ERROR_CODE}).
-define(METADATA_HASH, {record, [{<<"lower">>, u64}, {<<"upper">>, u64}]}).
-define(METADATA_HASH_RESULT, {result, ?METADATA_HASH, ?ERROR_CODE}).
-define(NEW_TIMESTAMP,
        {variant, [{<<"no-change">>, none}, {<<"now">>, none},
                   {<<"timestamp">>, ?DATETIME2}]}).
-define(ADVICE,
        {enum, [<<"normal">>, <<"sequential">>, <<"random">>, <<"will-need">>,
                <<"dont-need">>, <<"no-reuse">>]}).

-doc """
`wasi:filesystem` over preopened directories. `get-directories` hands the guest
a descriptor for `preopen` (named `name`, default `/`), or one per entry of
`mounts` as `{Name, Dir, Writable}`. A mount is read-only unless its flag (or
`writable`, for the single `preopen`) says otherwise, and write intent on a
read-only one is refused with `read-only`. Path resolution and the sandbox are not reimplemented here:
`open-at` passes the guest path straight to `wasi_fs:open/3`, the same call
Preview 1 makes, so the same escapes are refused.
""".
-spec filesystem(#{preopen => file:filename_all(), name => binary(),
                   writable => boolean(),
                   mounts => [{binary(), file:filename_all(), boolean()}]}) ->
          #{{binary(), binary()} => fun()}.
filesystem(Opts) ->
    Mounts = mounts_of(Opts),
    Types = <<"wasi:filesystem/types">>,
    Preopens = <<"wasi:filesystem/preopens">>,
    #{{Preopens, <<"get-directories">>} =>
          wasm_component:import_fun(
            {[], {list, {tuple, [handle, string]}}},
            fun([]) -> get_directories(Mounts) end),
      %% Map a stream error back to a filesystem error-code. Our stream errors do
      %% not carry one (a filesystem operation reports its code directly), so this
      %% is `none`: the io error was not a filesystem error.
      {Types, <<"filesystem-error-code">>} =>
          wasm_component:import_fun(
            {[handle], {option, ?ERROR_CODE}},
            fun([Err]) ->
                %% A file stream mints its error resource carrying the raw errno,
                %% which maps to a filesystem error-code; anything else is none.
                case wasm_component:host_get(Err) of
                    {ok, {error, Errno}} when is_integer(Errno) ->
                        {some, errno_name(Errno)};
                    _ ->
                        none
                end
            end),
      {Types, <<"[method]descriptor.open-at">>} =>
          wasm_component:import_fun(
            {[handle, ?PATH_FLAGS, string, ?OPEN_FLAGS, ?DESC_FLAGS], ?OPEN_RESULT},
            fun([Dir, PF, Path, OpenFlags, DescFlags]) ->
                open_at(Dir, PF, Path, OpenFlags, DescFlags)
            end),
      {Types, <<"[method]descriptor.write">>} =>
          wasm_component:import_fun(
            {[handle, {list, u8}, u64], {result, u64, ?ERROR_CODE}},
            fun([File, Data, Off]) -> write_at(File, Data, Off) end),
      {Types, <<"[method]descriptor.create-directory-at">>} =>
          wasm_component:import_fun(
            {[handle, string], {result, none, ?ERROR_CODE}},
            fun([Dir, Path]) -> create_directory_at(Dir, Path) end),
      {Types, <<"[method]descriptor.unlink-file-at">>} =>
          wasm_component:import_fun(
            {[handle, string], {result, none, ?ERROR_CODE}},
            fun([Dir, Path]) -> unlink_file_at(Dir, Path) end),
      {Types, <<"[method]descriptor.remove-directory-at">>} =>
          wasm_component:import_fun(
            {[handle, string], {result, none, ?ERROR_CODE}},
            fun([Dir, Path]) -> remove_directory_at(Dir, Path) end),
      {Types, <<"[method]descriptor.rename-at">>} =>
          wasm_component:import_fun(
            {[handle, string, handle, string], {result, none, ?ERROR_CODE}},
            fun([Dir, Path, NewDir, NewPath]) ->
                rename_at(Dir, Path, NewDir, NewPath)
            end),
      {Types, <<"[method]descriptor.symlink-at">>} =>
          wasm_component:import_fun(
            {[handle, string, string], {result, none, ?ERROR_CODE}},
            fun([Dir, OldPath, NewPath]) ->
                symlink_at(Dir, OldPath, NewPath)
            end),
      {Types, <<"[method]descriptor.link-at">>} =>
          wasm_component:import_fun(
            {[handle, ?PATH_FLAGS, string, handle, string],
             {result, none, ?ERROR_CODE}},
            fun([Dir, PathFlags, Path, NewDir, NewPath]) ->
                link_at(Dir, PathFlags, Path, NewDir, NewPath)
            end),
      {Types, <<"[method]descriptor.readlink-at">>} =>
          wasm_component:import_fun(
            {[handle, string], {result, string, ?ERROR_CODE}},
            fun([Dir, Path]) -> readlink_at(Dir, Path) end),
      {Types, <<"[method]descriptor.set-size">>} =>
          wasm_component:import_fun(
            {[handle, u64], {result, none, ?ERROR_CODE}},
            fun([File, Size]) -> set_size(File, Size) end),
      {Types, <<"[method]descriptor.set-times">>} =>
          wasm_component:import_fun(
            {[handle, ?NEW_TIMESTAMP, ?NEW_TIMESTAMP], {result, none, ?ERROR_CODE}},
            fun([H, Atime, Mtime]) -> set_times(H, Atime, Mtime) end),
      {Types, <<"[method]descriptor.set-times-at">>} =>
          wasm_component:import_fun(
            {[handle, ?PATH_FLAGS, string, ?NEW_TIMESTAMP, ?NEW_TIMESTAMP],
             {result, none, ?ERROR_CODE}},
            fun([Dir, PathFlags, Path, Atime, Mtime]) ->
                set_times_at(Dir, PathFlags, Path, Atime, Mtime)
            end),
      {Types, <<"[method]descriptor.advise">>} =>
          wasm_component:import_fun(
            {[handle, u64, u64, ?ADVICE], {result, none, ?ERROR_CODE}},
            fun([_H, _Off, _Len, _Advice]) -> {ok, undefined} end),
      {Types, <<"[method]descriptor.sync">>} =>
          wasm_component:import_fun(
            {[handle], {result, none, ?ERROR_CODE}}, fun([H]) -> sync_fd(H) end),
      {Types, <<"[method]descriptor.sync-data">>} =>
          wasm_component:import_fun(
            {[handle], {result, none, ?ERROR_CODE}}, fun([H]) -> sync_fd(H) end),
      {Types, <<"[method]descriptor.is-same-object">>} =>
          wasm_component:import_fun(
            {[handle, handle], bool}, fun([A, B]) -> is_same_object(A, B) end),
      {Types, <<"[method]descriptor.metadata-hash-at">>} =>
          wasm_component:import_fun(
            {[handle, ?PATH_FLAGS, string], ?METADATA_HASH_RESULT},
            fun([Dir, PathFlags, Path]) -> metadata_hash_at(Dir, PathFlags, Path) end),
      {Types, <<"[method]descriptor.read">>} =>
          wasm_component:import_fun(
            {[handle, u64, u64], ?READ_AT_RESULT},
            fun([File, Len, Off]) -> read_at(File, Len, Off) end),
      {Types, <<"[method]descriptor.get-type">>} =>
          wasm_component:import_fun(
            {[handle], ?TYPE_RESULT}, fun([H]) -> type_of(H) end),
      {Types, <<"[method]descriptor.stat">>} =>
          wasm_component:import_fun(
            {[handle], ?STAT_RESULT}, fun([H]) -> stat(H) end),
      {Types, <<"[method]descriptor.stat-at">>} =>
          wasm_component:import_fun(
            {[handle, ?PATH_FLAGS, string], ?STAT_RESULT},
            fun([Dir, PathFlags, Path]) -> stat_at(Dir, PathFlags, Path) end),
      {Types, <<"[method]descriptor.read-via-stream">>} =>
          wasm_component:import_fun(
            {[handle, u64], ?OPEN_RESULT},
            fun([File, Off]) -> read_via_stream(File, Off) end),
      {Types, <<"[method]descriptor.read-directory">>} =>
          wasm_component:import_fun(
            {[handle], ?OPEN_RESULT}, fun([Dir]) -> read_directory(Dir) end),
      {Types, <<"[method]descriptor.get-flags">>} =>
          wasm_component:import_fun(
            {[handle], ?FLAGS_RESULT}, fun([H]) -> get_flags(H) end),
      {Types, <<"[method]descriptor.metadata-hash">>} =>
          wasm_component:import_fun(
            {[handle], ?METADATA_HASH_RESULT}, fun([H]) -> metadata_hash(H) end),
      {Types, <<"[method]descriptor.write-via-stream">>} =>
          wasm_component:import_fun(
            {[handle, u64], ?OPEN_RESULT},
            fun([H, Off]) -> write_via_stream(H, Off) end),
      {Types, <<"[method]descriptor.append-via-stream">>} =>
          wasm_component:import_fun(
            {[handle], ?OPEN_RESULT}, fun([H]) -> append_via_stream(H) end),
      {Types, <<"[method]directory-entry-stream.read-directory-entry">>} =>
          wasm_component:import_fun(
            {[handle], ?DIR_ENTRY_RESULT},
            fun([Stream]) -> read_directory_entry(Stream) end),
      {Types, <<"[resource-drop]directory-entry-stream">>} =>
          fun(_Ctx, [H]) -> _ = wasm_component:host_drop(H), {ok, []} end,
      {Types, <<"[resource-drop]descriptor">>} =>
          fun(_Ctx, [H]) -> _ = fs_drop(H), {ok, []} end}.

%% The mounts a filesystem slice offers: an explicit list of {name, dir, writable}
%% for several preopens, or the single legacy preopen/name/writable.
mounts_of(Opts) ->
    case maps:find(mounts, Opts) of
        {ok, Mounts} ->
            Mounts;
        error ->
            case maps:find(preopen, Opts) of
                {ok, Dir} -> [{maps:get(name, Opts, <<"/">>), Dir,
                               maps:get(writable, Opts, false)}];
                error     -> []
            end
    end.

%% Each mount becomes one preopened directory descriptor carrying its own
%% writability, so a command can hold a read-only mount and a writable one at once
%% and the mutation gates read the descriptor, not one mount-wide flag.
get_directories(Mounts) ->
    lists:flatmap(
      fun({Name, HostDir, Writable}) ->
          case wasi_fs:preopen(HostDir) of
              {ok, Root} -> [{wasm_component:host_new(fs_dir, {Root, Writable}), Name}];
              {error, _} -> []
          end
      end, Mounts).

%% Open a path under a directory descriptor. Write intent is refused on a
%% read-only filesystem and otherwise turned into open modes. The path is not
%% resolved here: wasi_fs:open/3 applies the same sandbox Preview 1 does.
open_at(Dir, PathFlags, Path, OpenFlags, DescFlags) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, {Root, Writable}}} ->
            case write_intent(OpenFlags, DescFlags) of
                true when not Writable ->
                    %% A descriptor without write rights (a read-only mount) refuses
                    %% a write-intent open as not-permitted, the descriptor-rights
                    %% error, not the read-only-filesystem one.
                    {error, <<"not-permitted">>};
                WantsWrite ->
                    open_target(Root, Writable, PathFlags, Path,
                                OpenFlags, DescFlags, WantsWrite)
            end;
        _ ->
            {error, <<"bad-descriptor">>}
    end.

%% Open a path that may be a directory or a file. A directory becomes a directory
%% descriptor (its own root, for path operations beneath it); a file is opened
%% through wasi_fs and remembers the flags it was opened with, which `get-flags`
%% reports. This mirrors Preview 1's path_open: a directory has a root and no file
%% handle. A directory asked for with write intent is is-directory, and the
%% `directory` open flag on a non-directory is not-directory.
open_target(_Root, _W, _PathFlags, Path, _OpenFlags, _DescFlags, _WantsWrite)
  when Path =:= <<>> ->
    {error, <<"invalid">>};
open_target(Root, W, PathFlags, Path, OpenFlags, DescFlags, WantsWrite) ->
    case binary:match(Path, <<0>>) of
        nomatch -> open_named(Root, W, PathFlags, Path, OpenFlags, DescFlags, WantsWrite);
        %% A NUL truncates the name in C, so it must be refused, not silently
        %% opening whatever comes before it.
        _       -> {error, <<"invalid">>}
    end.

open_named(Root, W, PathFlags, Path0, OpenFlags, DescFlags, WantsWrite) ->
    %% A trailing slash names a directory: it forces the directory expectation and
    %% is stripped before the name reaches the backend, so a file named with one is
    %% not-directory rather than the backend's mishandling of the slash.
    Slash = trailing_slash(Path0),
    Path = strip_trailing_slashes(Path0),
    WantDir = Slash orelse lists:member(<<"directory">>, OpenFlags),
    Follow = follow_of(PathFlags),
    case wasi_fs:stat(Root, Path, Follow) of
        {ok, #{type := directory}} when WantsWrite ->
            {error, <<"is-directory">>};
        {ok, #{type := directory}} ->
            open_dir(Root, W, Path);
        {ok, _} when WantDir ->
            {error, <<"not-directory">>};
        {ok, _} ->
            open_file(Root, W, Path, OpenFlags, DescFlags, WantsWrite, Follow);
        {error, Errno} when WantDir ->
            {error, errno_name(Errno)};
        {error, _} ->
            %% Absent (a create) or a symlink stat could not follow: let the open
            %% produce the errno, as Preview 1 hands the name to wasi_fs.
            open_file(Root, W, Path, OpenFlags, DescFlags, WantsWrite, Follow)
    end.

strip_trailing_slashes(Path) ->
    case trailing_slash(Path) of
        true  -> strip_trailing_slashes(binary:part(Path, 0, byte_size(Path) - 1));
        false -> Path
    end.

open_dir(Root, W, Path) ->
    case wasi_fs:open_dir_at(Root, Path) of
        {ok, SubRoot} -> {ok, wasm_component:host_new(fs_dir, {SubRoot, W})};
        {error, Errno} -> {error, errno_name(Errno)}
    end.

open_file(Root, W, Path, OpenFlags, DescFlags, WantsWrite, Follow) ->
    Modes = open_modes(OpenFlags, DescFlags, WantsWrite)
        ++ [follow || Follow =:= follow],
    case wasi_fs:open(Root, Path, Modes) of
        {ok, Handle} ->
            Flags = eff_flags(DescFlags, WantsWrite),
            %% The descriptor carries its mount's writability, so a write stream on a
            %% file in a read-only mount is not-permitted (the mount boundary) while a
            %% read-only descriptor in a writable mount is bad-descriptor (Preview 1).
            {ok, wasm_component:host_new(fs_file, {Handle, Flags, W})};
        {error, Errno} ->
            {error, errno_name(Errno)}
    end.

%% The descriptor-flags a file ends up with: readable and writable as it was
%% opened, plus whichever sync flags the guest asked for. A write-only open reports
%% no read, so a guest can tell it apart.
eff_flags(DescFlags, WantsWrite) ->
    Sync = [F || F <- [<<"file-integrity-sync">>, <<"data-integrity-sync">>,
                       <<"requested-write-sync">>],
                 lists:member(F, DescFlags)],
    [<<"read">> || wants_read(DescFlags, WantsWrite)]
        ++ [<<"write">> || WantsWrite] ++ Sync.

%% Read is implied unless the open is write-only (write wanted, read not named).
wants_read(DescFlags, WantsWrite) ->
    (not WantsWrite) orelse lists:member(<<"read">>, DescFlags).

write_intent(OpenFlags, DescFlags) ->
    Wants = fun(Name, Set) -> lists:member(Name, Set) end,
    Wants(<<"create">>, OpenFlags) orelse Wants(<<"truncate">>, OpenFlags)
        orelse Wants(<<"exclusive">>, OpenFlags)
        orelse Wants(<<"write">>, DescFlags)
        orelse Wants(<<"mutate-directory">>, DescFlags).

open_modes(OpenFlags, DescFlags, WantsWrite) ->
    Base = [read || wants_read(DescFlags, WantsWrite)] ++ [write || WantsWrite],
    Add = fun(Flag, Mode, Acc) ->
              case lists:member(Flag, OpenFlags) of true -> [Mode | Acc]; false -> Acc end
          end,
    Add(<<"create">>, create,
        Add(<<"truncate">>, truncate,
            Add(<<"exclusive">>, exclusive, Base))).

%% Write bytes at an offset, reporting how many. A write to a read-opened file is
%% refused by the OS, so a read-only filesystem needs no extra guard here.
%% A file-backed output stream, from the given offset (write) or the file end
%% (append). Refused on a read-only filesystem. `write_stream` does the pwrite.
%% Writability is the file's own: a file opened without the write flag (which a
%% read-only mount never grants) cannot make a write stream.
write_via_stream(File, Off) ->
    case writable_file(File) of
        {ok, Handle}   -> {ok, new_output_stream(output_file(Handle, {write, Off}))};
        {error, _} = E -> E
    end.

append_via_stream(File) ->
    case writable_file(File) of
        {ok, Handle}   -> {ok, new_output_stream(output_file(Handle, append))};
        {error, _} = E -> E
    end.

%% Mint a host output-stream over Backing: the `{ostream, Permit, Closed,
%% Backing}` envelope wasi_preview2's stream methods read, with no permit and
%% open. Inlined (not a call) to keep the module graph acyclic, since
%% wasi_preview2 already depends on this module.
new_output_stream(Backing) ->
    wasm_component:host_new(output_stream, {ostream, 0, false, Backing}).

%% A file-backed output stream owns a duplicated descriptor on the native backend,
%% so it outlives the descriptor it was taken from; the fallback cannot duplicate a
%% handle, so it borrows the descriptor's and is closed with it. An append stream
%% carries no offset: each write goes to the current end, so concurrent appends do
%% not overwrite each other.
output_file(Handle, Mode) ->
    {Own, Fh} = case wasi_fs:dup(Handle) of
                    {ok, Dup}  -> {own, Dup};
                    {error, _} -> {borrow, Handle}
                end,
    case Mode of
        {write, Off} -> {file, Own, Fh, Off};
        append       -> {file_append, Own, Fh}
    end.

%% A file that was opened for writing; a read-only descriptor cannot produce a
%% write stream, which is how a write to a read-opened file is refused.
writable_file(File) ->
    case wasm_component:host_get(File) of
        {ok, {fs_file, {Handle, Flags, MountW}}} ->
            case {lists:member(<<"write">>, Flags), MountW} of
                {true, _} ->
                    {ok, Handle};
                %% A read-only mount denies the write itself: not-permitted, the mount
                %% boundary (p2_file_stream_not_permitted).
                {false, false} ->
                    {error, <<"not-permitted">>};
                %% A read-only descriptor in a writable mount is the preview1 fd_write
                %% contract: bad-descriptor (the p1->p2 adapter's path_open_read_write
                %% asserts EBADF/ENOTCAPABLE/EACCES).
                {false, true} ->
                    {error, <<"bad-descriptor">>}
            end;
        _ ->
            {error, <<"bad-descriptor">>}
    end.

write_at(File, Data, Off) ->
    case wasm_component:host_get(File) of
        {ok, {fs_file, {Handle, _, _}}} ->
            case wasi_fs:pwrite(Handle, Off, Data) of
                {ok, Count}    -> {ok, Count};
                {error, Errno} -> {error, errno_name(Errno)}
            end;
        _ ->
            {error, <<"bad-descriptor">>}
    end.

%% The directory mutations below are gated on the mount being writable, not on a
%% per-descriptor `mutate-directory` right. Enforcing the per-descriptor right is
%% not possible on the preview1-to-preview2 adapter path, which does not request the
%% `mutate-directory` descriptor flag: a native p2 host could enforce it, but doing
%% so here would refuse every adapted preview1 program that mutates a directory. The
%% mount's writable flag is therefore the boundary.
create_directory_at(Dir, Path) ->
    case writable_dir(Dir) of
        {ok, Root}     -> fs_unit(wasi_fs:mkdir(Root, Path));
        {error, _} = E -> E
    end.

unlink_file_at(Dir, Path) ->
    case writable_dir(Dir) of
        {ok, Root} ->
            %% A trailing slash on a name that is not a directory is not-directory;
            %% on a directory, unlink itself reports is-directory / not-permitted.
            case trailing_slash(Path) andalso not is_dir(Root, Path) of
                true  -> {error, <<"not-directory">>};
                false -> fs_unit(wasi_fs:unlink(Root, Path))
            end;
        {error, _} = E ->
            E
    end.

%% A directory descriptor open for mutation: its own mount's writable flag governs
%% here, so a read-only mount refuses while a writable one proceeds, and each
%% descriptor carries the flag it was preopened or opened-at with.
writable_dir(Dir) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, {Root, true}}}   -> {ok, Root};
        {ok, {fs_dir, {_Root, false}}} -> {error, <<"not-permitted">>};
        _                              -> {error, <<"bad-descriptor">>}
    end.

is_dir(Root, Path) ->
    case wasi_fs:stat(Root, Path, nofollow) of
        {ok, #{type := directory}} -> true;
        _                          -> false
    end.

trailing_slash(<<>>)   -> false;
trailing_slash(Path)   -> binary:last(Path) =:= $/.

fs_unit(ok)             -> {ok, undefined};
fs_unit({error, Errno}) -> {error, errno_name(Errno)}.

%% Remove an empty directory. A mutation, so refused on a read-only mount.
remove_directory_at(Dir, Path) ->
    case writable_dir(Dir) of
        {ok, Root}     -> fs_unit(wasi_fs:rmdir(Root, Path));
        {error, _} = E -> E
    end.

%% Rename within the sandbox. Both descriptors are directories; a mutation, so both
%% must be writable.
rename_at(Dir, Path, NewDir, NewPath) ->
    with_two_writable_dirs(Dir, NewDir,
                           fun(From, To) ->
                               fs_unit(wasi_fs:rename(From, Path, To, NewPath))
                           end).

%% Create a symlink at NewPath pointing at OldPath. An absolute target is refused
%% at creation, as Preview 1 does, so a symlink can never name outside the sandbox.
symlink_at(_Dir, <<$/, _/binary>>, _NewPath) ->
    {error, <<"access">>};
symlink_at(Dir, OldPath, NewPath) ->
    case trailing_slash(NewPath) of
        %% The link location ending in `/` names a directory that is not there.
        true ->
            {error, <<"no-entry">>};
        false ->
            case writable_dir(Dir) of
                {ok, Root}     -> fs_unit(wasi_fs:symlink(Root, NewPath, OldPath));
                {error, _} = E -> E
            end
    end.

%% Hard-link Path under Dir to NewPath under NewDir. Following the source symlink
%% is rejected as invalid, as Preview 1's path_link does.
link_at(Dir, PathFlags, Path, NewDir, NewPath) ->
    case lists:member(<<"symlink-follow">>, PathFlags) of
        true ->
            {error, <<"invalid">>};
        false ->
            case trailing_slash(NewPath) of
                %% The link location ending in `/` names a directory not there.
                true ->
                    {error, <<"no-entry">>};
                false ->
                    with_two_writable_dirs(
                      Dir, NewDir,
                      fun(From, To) ->
                          fs_unit(wasi_fs:link(From, Path, To, NewPath))
                      end)
            end
    end.

%% Both descriptors must be writable directories for a cross-directory mutation.
with_two_writable_dirs(A, B, Fun) ->
    case {writable_dir(A), writable_dir(B)} of
        {{ok, RA}, {ok, RB}}        -> Fun(RA, RB);
        {{error, _} = E, _}         -> E;
        {_, {error, _} = E}         -> E
    end.

readlink_at(Dir, Path) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, {Root, _}}} ->
            case wasi_fs:readlink(Root, Path) of
                {ok, Target}   -> {ok, Target};
                {error, Errno} -> {error, errno_name(Errno)}
            end;
        _ ->
            {error, <<"bad-descriptor">>}
    end.

set_size(File, Size) ->
    case writable_file(File) of
        {ok, Handle}   -> fs_unit(wasi_fs:truncate(Handle, Size));
        {error, _} = E -> E
    end.

set_times(H, Atime, Mtime) ->
    case wasm_component:host_get(H) of
        {ok, {fs_file, _}} ->
            case writable_file(H) of
                {ok, Handle}   ->
                    fs_unit(wasi_fs:set_times_fd(Handle, new_ts(Atime), new_ts(Mtime)));
                {error, _} = E -> E
            end;
        {ok, {fs_dir, {_, _}}} ->
            case writable_dir(H) of
                {ok, Root}     ->
                    fs_unit(wasi_fs:set_times(Root, <<".">>,
                                              new_ts(Atime), new_ts(Mtime)));
                {error, _} = E -> E
            end;
        _ ->
            {error, <<"bad-descriptor">>}
    end.

set_times_at(Dir, PathFlags, Path, Atime, Mtime) ->
    case writable_dir(Dir) of
        {ok, Root} ->
            fs_unit(wasi_fs:set_times(Root, Path, new_ts(Atime), new_ts(Mtime),
                                      follow_of(PathFlags)));
        {error, _} = E ->
            E
    end.

%% The new-timestamp variant: leave unchanged, set to now, or a given datetime.
%% `wasi_fs` takes nanoseconds since the epoch, or `omit` to leave a stamp alone.
new_ts({<<"no-change">>, _}) ->
    omit;
new_ts({<<"now">>, _}) ->
    os:system_time(nanosecond);
new_ts({<<"timestamp">>, #{<<"seconds">> := S, <<"nanoseconds">> := N}}) ->
    S * 1000000000 + N.

follow_of(PathFlags) ->
    case lists:member(<<"symlink-follow">>, PathFlags) of
        true  -> follow;
        false -> nofollow
    end.

sync_fd(H) ->
    case wasm_component:host_get(H) of
        {ok, {fs_file, {Handle, _, _}}} -> fs_unit(wasi_fs:sync(Handle));
        {ok, {fs_dir, {_Root, _}}}   -> {ok, undefined};
        error                   -> {error, <<"bad-descriptor">>}
    end.

%% Two descriptors name the same object when their device and inode agree.
is_same_object(A, B) ->
    case {ino(A), ino(B)} of
        {{ok, Key}, {ok, Key}} -> true;
        _                      -> false
    end.

ino(H) ->
    case wasm_component:host_get(H) of
        {ok, {fs_file, {Handle, _, _}}} -> ino_of(wasi_fs:stat_fd(Handle));
        {ok, {fs_dir, {Root, _}}}    -> ino_of(wasi_fs:stat(Root, <<".">>));
        error                   -> error
    end.

ino_of({ok, Map})  -> {ok, {maps:get(dev, Map, 0), maps:get(inode, Map, 0)}};
ino_of({error, _}) -> error.

metadata_hash_at(Dir, PathFlags, Path) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, {Root, _}}} ->
            from_hash(wasi_fs:stat(Root, Path, follow_of(PathFlags)));
        _ ->
            {error, <<"bad-descriptor">>}
    end.

read_at(File, Len, Off) ->
    case wasm_component:host_get(File) of
        {ok, {fs_file, {Handle, _, _}}} ->
            case wasi_fs:pread(Handle, Off, Len) of
                {ok, Bin} -> {ok, {Bin, at_eof(Handle, Off, byte_size(Bin), Len)}};
                eof -> {ok, {<<>>, true}};
                {error, Errno} -> {error, errno_name(Errno)}
            end;
        _ ->
            {error, <<"bad-descriptor">>}
    end.

at_eof(Handle, Off, Got, Len) ->
    case wasi_fs:size(Handle) of
        {ok, Size} -> (Off + Got) >= Size;
        {error, _} -> Got < Len
    end.

type_of(H) ->
    case wasm_component:host_get(H) of
        {ok, {fs_dir, {_Root, _}}} ->
            {ok, <<"directory">>};
        {ok, {fs_file, {Handle, _, _}}} ->
            case wasi_fs:stat_fd(Handle) of
                {ok, #{type := Type}} -> {ok, fs_type_name(Type)};
                {error, Errno} -> {error, errno_name(Errno)}
            end;
        error ->
            {error, <<"bad-descriptor">>}
    end.

fs_type_name(directory) -> <<"directory">>;
fs_type_name(regular)   -> <<"regular-file">>;
fs_type_name(symlink)   -> <<"symbolic-link">>;
fs_type_name(_Other)    -> <<"unknown">>.

descriptor_flags(true)  -> [<<"read">>, <<"write">>];
descriptor_flags(false) -> [<<"read">>].

%% A file reports the flags it was opened with; a directory reports the mount's.
get_flags(H) ->
    case wasm_component:host_get(H) of
        {ok, {fs_file, {_Handle, Flags, _}}} -> {ok, Flags};
        {ok, {fs_dir, {_Root, W}}}        -> {ok, descriptor_flags(W)};
        _                                 -> {error, <<"bad-descriptor">>}
    end.

%% A stable identity for a descriptor, from its inode; enough for a guest to tell
%% two descriptors apart, which is what metadata-hash is for.
metadata_hash(H) ->
    case wasm_component:host_get(H) of
        {ok, {fs_file, {Handle, _, _}}} -> from_hash(wasi_fs:stat_fd(Handle));
        {ok, {fs_dir, {Root, _}}}    -> from_hash(wasi_fs:stat(Root, <<".">>));
        error                   -> {error, <<"bad-descriptor">>}
    end.

from_hash({ok, Map}) ->
    {ok, #{<<"lower">> => maps:get(inode, Map, 0), <<"upper">> => 0}};
from_hash({error, Errno}) ->
    {error, errno_name(Errno)}.

stat(H) ->
    case wasm_component:host_get(H) of
        {ok, {fs_file, {Handle, _, _}}} -> from_stat(wasi_fs:stat_fd(Handle));
        {ok, {fs_dir, {Root, _}}}    -> from_stat(wasi_fs:stat(Root, <<".">>));
        error                   -> {error, <<"bad-descriptor">>}
    end.

stat_at(Dir, PathFlags, Path) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, {Root, _}}} ->
            Follow = case lists:member(<<"symlink-follow">>, PathFlags) of
                         true -> follow;
                         false -> nofollow
                     end,
            from_stat(wasi_fs:stat(Root, Path, Follow));
        _ ->
            {error, <<"bad-descriptor">>}
    end.

from_stat({ok, Map}) -> {ok, stat_record(Map)};
from_stat({error, Errno}) -> {error, errno_name(Errno)}.

stat_record(#{size := Size, type := Type} = M) ->
    #{<<"type">> => fs_type_name(Type),
      <<"link-count">> => maps:get(nlink, M, 1),
      <<"size">> => Size,
      <<"data-access-timestamp">> => opt_datetime(maps:get(atim, M, undefined)),
      <<"data-modification-timestamp">> => opt_datetime(maps:get(mtim, M, undefined)),
      <<"status-change-timestamp">> => opt_datetime(maps:get(ctim, M, undefined))}.

opt_datetime(Nsec) when is_integer(Nsec) ->
    {some, #{<<"seconds">> => Nsec div 1000000000,
             <<"nanoseconds">> => Nsec rem 1000000000}};
opt_datetime(_) ->
    none.

%% read-via-stream snapshots the file from the offset into an input-stream (the
%% wasi:io kind), so a caller must also supply io/1 to read it. pread does the
%% reading, so the sandbox is unchanged.
%% The stream reads the file lazily, one chunk per read, so a guest reading a
%% small prefix of a large file never makes the host materialise the rest. It
%% duplicates the descriptor's handle (`wasi_fs:dup/1`) and owns the copy, so
%% dropping the descriptor does not close the stream and the stream never touches
%% the descriptor's own fd. The stream closes its handle on drop and teardown.
read_via_stream(File, Off) ->
    %% A directory is not a byte stream: streaming it is is-directory, not a bad
    %% descriptor. Check read permission up front otherwise, before deferring any
    %% I/O: a descriptor with no read right must fail here as a bad descriptor, not
    %% later as a stream error, which is the error code the caller expects and how
    %% the eager read reported it.
    case wasm_component:host_get(File) of
        {ok, {fs_dir, {_, _}}} -> {error, <<"is-directory">>};
        _                 -> read_via_stream_file(File, Off)
    end.

read_via_stream_file(File, Off) ->
    case readable_file(File) of
        {ok, Handle} ->
            case wasi_fs:dup(Handle) of
                {ok, Own} ->
                    %% Native: an owned fd, read lazily one chunk at a time.
                    {ok, wasm_component:host_new(input_stream, {file, Own, Off})};
                {error, _} ->
                    %% Fallback: no safe dup, so read eagerly into a self-contained
                    %% binary rather than hold a re-resolvable pathname.
                    case read_all(Handle, Off, <<>>) of
                        {ok, Bytes}  -> {ok, wasm_component:host_new(input_stream, Bytes)};
                        {error, Errno} -> {error, errno_name(Errno)}
                    end
            end;
        {error, _} = E ->
            E
    end.

%% Read a whole file (from Off) into one binary, for the fallback backend where a
%% lazy stream cannot own an independent descriptor.
read_all(Handle, Off, Acc) ->
    case wasi_fs:pread(Handle, Off, 65536) of
        {ok, <<>>}     -> {ok, Acc};
        eof            -> {ok, Acc};
        {ok, Bin}      -> read_all(Handle, Off + byte_size(Bin), <<Acc/binary, Bin/binary>>);
        {error, Errno} -> {error, Errno}
    end.

readable_file(File) ->
    case wasm_component:host_get(File) of
        {ok, {fs_file, {Handle, Flags, _MountW}}} ->
            case lists:member(<<"read">>, Flags) of
                true  -> {ok, Handle};
                false -> {error, <<"bad-descriptor">>}
            end;
        _ ->
            {error, <<"bad-descriptor">>}
    end.

read_directory(Dir) ->
    case wasm_component:host_get(Dir) of
        {ok, {fs_dir, {Root, _}}} ->
            case wasi_fs:list(Root) of
                {ok, Names} ->
                    Entries = [dir_entry(Root, N) || N <- Names],
                    {ok, wasm_component:host_new(dir_entries, Entries)};
                {error, Errno} ->
                    {error, errno_name(Errno)}
            end;
        _ ->
            {error, <<"bad-descriptor">>}
    end.

dir_entry(Root, Name) ->
    Type = case wasi_fs:stat(Root, Name, nofollow) of
               {ok, #{type := T}} -> fs_type_name(T);
               _ -> <<"unknown">>
           end,
    #{<<"type">> => Type, <<"name">> => Name}.

read_directory_entry(Stream) ->
    case wasm_component:host_get(Stream) of
        {ok, {dir_entries, []}} ->
            {ok, none};
        {ok, {dir_entries, [Entry | Rest]}} ->
            _ = wasm_component:host_update(Stream, Rest),
            {ok, {some, Entry}};
        _ ->
            {error, <<"bad-descriptor">>}
    end.

%% Drop a descriptor: close the open file or forget the preopened root, then
%% free the host handle. A double drop or unknown handle is a no-op.
fs_drop(H) ->
    case wasm_component:host_get(H) of
        {ok, {fs_file, {Handle, _, _}}} -> _ = wasi_fs:close(Handle);
        {ok, {fs_dir, {Root, _}}}    -> _ = wasi_fs:forget(Root);
        error                   -> ok
    end,
    wasm_component:host_drop(H).

%% A Preview 1 errno to a wasi:filesystem error-code name; anything not mapped is
%% the generic `io`.
errno_name(?EACCES)       -> <<"access">>;
errno_name(?ENOENT)       -> <<"no-entry">>;
errno_name(?ELOOP)        -> <<"loop">>;
errno_name(?ENOTDIR)      -> <<"not-directory">>;
errno_name(?EISDIR)       -> <<"is-directory">>;
errno_name(?ENAMETOOLONG) -> <<"name-too-long">>;
errno_name(?EEXIST)       -> <<"exist">>;
errno_name(?EBADF)        -> <<"bad-descriptor">>;
errno_name(?EINVAL)       -> <<"invalid">>;
errno_name(?ENOSPC)       -> <<"insufficient-space">>;
errno_name(?ENOMEM)       -> <<"insufficient-memory">>;
errno_name(?ENOTEMPTY)    -> <<"not-empty">>;
errno_name(?ENOTCAPABLE)  -> <<"not-permitted">>;
errno_name(?EPERM)        -> <<"not-permitted">>;
errno_name(?EROFS)        -> <<"read-only">>;
errno_name(?EBUSY)        -> <<"busy">>;
errno_name(?EAGAIN)       -> <<"would-block">>;
errno_name(?EXDEV)        -> <<"cross-device">>;
errno_name(?EFBIG)        -> <<"file-too-large">>;
errno_name(?ESPIPE)       -> <<"invalid-seek">>;
errno_name(?ENXIO)        -> <<"no-such-device">>;
errno_name(?ENOSYS)       -> <<"unsupported">>;
errno_name(?ENOTSUP)      -> <<"unsupported">>;
errno_name(?EPIPE)        -> <<"pipe">>;
errno_name(_Other)        -> <<"io">>.
