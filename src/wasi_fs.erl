-module(wasi_fs).
-moduledoc """
File access for WASI, over whichever backend is available.

Call `backend/0` if you need to know which one you got, because the weaker one
carries a documented race. There are two implementations of the same six
operations:

- **native**, via `wasi_file_nif`, which walks each path component with
  `openat(..., O_NOFOLLOW)` so a name is never resolved twice and no symlink is
  ever followed. This closes the time-of-check-to-time-of-use window.
- **fallback**, via `file` plus `wasi_path`, which refuses every escape it can
  detect lexically and through `filelib:safe_relative_path/2`, but resolves the
  path and opens it as two separate steps.

The backend is chosen once, at open time, and recorded in the handle, so a
descriptor is always used with the backend that produced it.

A native handle is safe to share between processes. Each one carries its own
lock, so a close cannot land between another operation testing the descriptor
and using it; without that, closing while a read was in flight returned the
descriptor number to the kernel, the next open anywhere in the VM was handed it
back, and the read in flight read whatever that now was.

You do not choose between them. `wasi_preview1` asks for a path beneath a
preopen and gets a handle back; which mechanism enforced the boundary is this
module's business.
""".

-export([open/3, pread/3, pwrite/3, size/1, stat_fd/1, close/1,
         list_dir/2, backend/0]).
-export([truncate/2, sync/1, preopen/1, forget/1, list/1]).
-export([mkdir/2, unlink/2, rmdir/2, symlink/3, readlink/2, stat/2,
         set_times/4, set_times/5, set_times_fd/3,
         stat/3, rename/4, link/4]).

-include("wasi.hrl").
-include_lib("kernel/include/file.hrl").

-doc "An open file, tagged with the backend that opened it.".
%% The fallback carries the path it was opened from as well as the device.
%% Erlang has no `fstat', so answering `fd_filestat_get' on that backend means
%% stating the name again; the native handle needs no path because it has the
%% descriptor.
-nominal handle() :: {native, term()} | {fallback, file:io_device(), string()}.

-doc """
A directory that guest paths are resolved beneath.

On the native backend it is the directory itself, opened once, and every guest
path is resolved relative to that descriptor. Naming the root by path on each
open would leave it to be resolved again every time, so replacing or renaming
it between two opens would silently move the sandbox; anchoring means
operations continue against the directory that was opened, and a swapped
*child* is what gets refused.
""".
-nominal root() :: {native, term()} | {fallback, string()}.
-export_type([handle/0, root/0]).

-doc "Open a preopen root, once, for every path that will be resolved under it.".
-spec preopen(file:filename_all()) -> {ok, root()} | {error, non_neg_integer()}.
preopen(Host) ->
    Str = unicode:characters_to_list(Host),
    case backend() of
        fallback ->
            {ok, {fallback, Str}};
        native ->
            case wasi_file_nif:open_dir(Str) of
                {ok, H} -> {ok, {native, H}};
                {error, E} -> {error, map_posix(E)}
            end
    end.

-doc "Release a root. A preopen holds one for the life of the instance.".
-spec forget(root()) -> ok.
forget({native, H}) -> wasi_file_nif:close(H), ok;
forget({fallback, _}) -> ok.

-doc "Which backend is in use. `fallback` still refuses every detectable escape.".
-spec backend() -> native | fallback.
backend() ->
    case wasi_file_nif:available() of
        true -> native;
        false -> fallback
    end.

-doc """
Open `Guest` beneath the preopened host directory `Root`.

Returns a WASI errno on failure, already mapped, so callers do not have to know
which backend produced it.
""".
-spec open(root(), binary(), [read | write | create | truncate | exclusive]) ->
          {ok, handle()} | {error, non_neg_integer()}.
open({native, Dir}, Guest, Modes) -> open_native(Dir, Guest, Modes);
open({fallback, Root}, Guest, Modes) -> open_fallback(Root, Guest, Modes).

%% The native path does not consult `wasi_path` at all: the kernel enforces the
%% boundary component by component, which is stronger than resolving first and
%% trusting the result to still be true at open time.
open_native(Dir, Guest, Modes) ->
    Flags = native_flags(Modes),
    Follow = case lists:member(follow, Modes) of true -> 1; false -> 0 end,
    case wasi_file_nif:open_at(Dir, Guest, Flags, Follow) of
        {ok, H} -> {ok, {native, H}};
        {error, Errno} -> {error, map_posix(Errno)}
    end.

open_fallback(Root, Guest, Modes) ->
    MustExist = not lists:member(create, Modes),
    %% Before resolving, not after.
    %%
    %% Without `LOOKUPFLAGS_SYMLINK_FOLLOW' the final component may not be a
    %% symlink, and `ELOOP' is the answer Preview 1 wants. That has to be asked
    %% of the name the guest gave: `filelib:safe_relative_path/2' resolves links
    %% on the way to deciding a path is safe, so by the time it has answered
    %% there is no link left to notice. `read_link_info/1' does not follow the
    %% last component and does follow the ones before it, which is the rule.
    case lists:member(follow, Modes) orelse
         not is_symlink(filename:join(Root, Guest)) of
        false -> {error, ?ELOOP};
        true -> open_fallback_0(Root, Guest, MustExist, Modes)
    end.

open_fallback_0(Root, Guest, MustExist, Modes) ->
    case wasi_path:resolve(Root, Guest, MustExist) of
        {error, E} -> {error, E};
        {ok, Full} -> open_fallback_1(Root, Full, Modes)
    end.

%% `truncate' is not one of `file:open/2''s modes. It was passed as one for a
%% while and silently ignored, so `OFLAGS_TRUNC' did nothing on this backend and
%% a file opened to be overwritten kept whatever was in it past the new end.
%%
%% `file:truncate/1' cuts at the current position, so the position is set first.
truncate_if_asked(IoDev, Modes) ->
    case lists:member(truncate, Modes) of
        false -> ok;
        true ->
            {ok, _} = file:position(IoDev, bof),
            file:truncate(IoDev)
    end.

is_symlink(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = symlink}} -> true;
        _ -> false
    end.

open_fallback_1(Root, Full, Modes) ->
    case file:open(Full, fallback_modes(Modes)) of
        {ok, IoDev} ->
            ok = truncate_if_asked(IoDev, Modes),
            %% Re-verify after opening. This narrows the window; only the
            %% native backend closes it.
            case wasi_path:verify_within(Root, Full) of
                ok -> {ok, {fallback, IoDev, Full}};
                {error, E} -> _ = file:close(IoDev), {error, E}
            end;
        {error, Reason} -> {error, map_posix(Reason)}
    end.

-doc "Cut the file to `Len` bytes, or extend it with zeroes.".
-spec truncate(handle(), non_neg_integer()) -> ok | {error, non_neg_integer()}.
truncate({native, H}, Len) ->
    case wasi_file_nif:ftruncate(H, Len) of
        ok -> ok;
        {error, E} -> {error, map_posix(E)}
    end;
truncate({fallback, IoDev, _}, Len) ->
    %% `file:truncate/1' cuts at the current position, so the position is what
    %% has to be set. Nothing else uses this descriptor's own offset, which is
    %% kept in the WASI descriptor rather than here.
    case file:position(IoDev, {bof, Len}) of
        {ok, _} -> to_error(file:truncate(IoDev));
        {error, R} -> {error, map_posix(R)}
    end.

-doc "Flush to disk, answering `ok` for anything with nothing to flush.".
-spec sync(handle()) -> ok | {error, non_neg_integer()}.
sync({native, H}) ->
    case wasi_file_nif:fsync(H) of
        ok -> ok;
        {error, E} -> {error, map_posix(E)}
    end;
sync({fallback, IoDev, _}) -> to_error(file:sync(IoDev)).

to_error(ok) -> ok;
to_error({error, R}) -> {error, map_posix(R)}.

%%% ------------------------------------------------------- path operations ---
%%
%% Each of these acts on a name inside a directory. On the native backend the
%% walk stops one component short and the operation is a single `*at' call, so
%% the name is resolved once and by the kernel. On the fallback it is
%% `wasi_path' and `file', two steps with a window between them, which is the
%% same trade the fallback makes everywhere else.

-define(OP_MKDIR, 1).
-define(OP_UNLINK, 2).
-define(OP_RMDIR, 3).
-define(OP_SYMLINK, 4).
-define(OP_READLINK, 5).
-define(OP_STAT, 6).
-define(OP_SETTIMES, 8).
-define(OP_STAT_FOLLOW, 9).
-define(OP_SETTIMES_FOLLOW, 10).
-define(OP_RENAME, 7).
-define(OP_LINK, 8).

-spec mkdir(root(), binary()) -> ok | {error, non_neg_integer()}.
mkdir({native, D}, Guest) -> op(D, Guest, ?OP_MKDIR, <<>>);
mkdir({fallback, R}, Guest) -> fb(R, Guest, false, fun file:make_dir/1).

-spec unlink(root(), binary()) -> ok | {error, non_neg_integer()}.
unlink({native, D}, Guest) -> op(D, Guest, ?OP_UNLINK, <<>>);
unlink({fallback, R}, Guest) -> fb(R, Guest, true, fun file:delete/1).

-spec rmdir(root(), binary()) -> ok | {error, non_neg_integer()}.
rmdir({native, D}, Guest) -> op(D, Guest, ?OP_RMDIR, <<>>);
rmdir({fallback, R}, Guest) ->
    %% `file:del_dir/1' answers `eexist' for a directory that is not empty on
    %% some platforms, which is the one context where that atom means
    %% ENOTEMPTY rather than "it is already there".
    case fb(R, Guest, true, fun file:del_dir/1) of
        {error, ?EEXIST} -> {error, ?ENOTEMPTY};
        Other -> Other
    end.

-doc "Create a link holding `Target` verbatim. The target is never resolved.".
-spec symlink(root(), binary(), binary()) -> ok | {error, non_neg_integer()}.
symlink({native, D}, Guest, Target) -> op(D, Guest, ?OP_SYMLINK, Target);
symlink({fallback, R}, Guest, Target) ->
    fb(R, Guest, false,
       fun(Full) ->
           file:make_symlink(unicode:characters_to_list(Target), Full)
       end).

-spec readlink(root(), binary()) -> {ok, binary()} | {error, non_neg_integer()}.
readlink({native, D}, Guest) -> op(D, Guest, ?OP_READLINK, <<>>);
readlink({fallback, R}, Guest) ->
    fb(R, Guest, true,
       fun(Full) ->
           case file:read_link(Full) of
               {ok, T} -> {ok, unicode:characters_to_binary(T)};
               Err -> Err
           end
       end).

-doc "Stat a name without following it, which is what a link's own stat is.".
-spec stat(root(), binary()) -> {ok, map()} | {error, non_neg_integer()}.
stat(Root, Guest) -> stat(Root, Guest, nofollow).

-doc """
As `stat/2`, following the final component when asked.

`path_filestat_get` takes a lookup flag saying whether it is asking about a
symlink or about what it points at, and the two answers differ in every field.
Ignoring it reported the link for both, which upstream catches three ways:
`path_exists`, `symlink_filestat` and `fd_filestat_set`.

Only the *final* component is a choice. Everything before it is followed either
way, because that is what a path means.
""".
-spec stat(root(), binary(), follow | nofollow) ->
          {ok, map()} | {error, non_neg_integer()}.
stat({native, D}, Guest, follow) -> op(D, Guest, ?OP_STAT_FOLLOW, <<>>);
stat({native, D}, Guest, nofollow) -> op(D, Guest, ?OP_STAT, <<>>);
stat({fallback, R}, Guest, Mode) ->
    Read = case Mode of
               follow -> fun(F) -> file:read_file_info(F, [{time, posix}]) end;
               nofollow -> fun(F) -> file:read_link_info(F, [{time, posix}]) end
           end,
    fb(R, Guest, true,
       fun(Full) ->
           %% `posix' time, because `info_map/1' wants seconds since the epoch
           %% and the default is a local datetime tuple.
           case Read(Full) of
               {ok, Info} -> {ok, info_map(Info)};
               Err -> Err
           end
       end, Mode).

-doc """
Set a name's access and modification times, in nanoseconds.

`omit` for either leaves that stamp alone, which is what the WASI `fstflags`
bits ask for when they name only one of the two. The final component is not
followed, so this sets the times on a symlink itself rather than on its target,
which is what `path_filestat_set_times` without a follow flag means.
""".
-spec set_times(root(), binary(), non_neg_integer() | omit,
                non_neg_integer() | omit) -> ok | {error, non_neg_integer()}.
set_times(Root, Guest, Atime, Mtime) ->
    set_times(Root, Guest, Atime, Mtime, nofollow).

-doc """
As `set_times/4`, following the final component when asked.

`path_filestat_set_times` takes the same lookup flag `path_filestat_get` does,
and means the same thing by it: without it the symlink's own times are set, with
it the target's.

The fallback follows either way. `file:write_file_info/3` has no `lstat`
counterpart, so on that backend a symlink's own times cannot be set at all,
which is the same class of limitation as its path resolution.
""".
-spec set_times(root(), binary(), non_neg_integer() | omit,
                non_neg_integer() | omit, follow | nofollow) ->
          ok | {error, non_neg_integer()}.
set_times({native, D}, Guest, Atime, Mtime, follow) ->
    op(D, Guest, ?OP_SETTIMES_FOLLOW, times_spec(Atime, Mtime));
set_times({native, D}, Guest, Atime, Mtime, nofollow) ->
    op(D, Guest, ?OP_SETTIMES, times_spec(Atime, Mtime));
set_times({fallback, R}, Guest, Atime, Mtime, Mode) ->
    fb(R, Guest, true,
       fun(Full) ->
           %% No `utimensat', so anything left out has to be read back first.
           case file:read_link_info(Full, [{time, posix}]) of
               {error, _} = E -> E;
               {ok, Info} ->
                   A = keep(Atime, Info#file_info.atime),
                   M = keep(Mtime, Info#file_info.mtime),
                   %% `file:write_file_info/3' follows whatever `Full' names, so
                   %% `nofollow' gets as far as naming the link and no further:
                   %% Erlang has no `lutimes'. That is the one upstream case
                   %% this backend cannot reach, and the NIF is what reaches it.
                   file:write_file_info(Full, Info#file_info{atime = A,
                                                            mtime = M},
                                        [{time, posix}])
           end
       end, Mode).

%% A mask byte then the two stamps, seconds and nanoseconds each.
%%
%% The mask says which to set and the NIF fills the rest with `UTIME_OMIT'. That
%% constant used to be written here, and it is a platform value: on this one it
%% landed in the wrong field and set the access time to 2004 instead of leaving
%% it. Only `<sys/stat.h>' knows, so only C says it.
times_spec(Atime, Mtime) ->
    Mask = (case Atime of omit -> 0; _ -> 1 end)
        bor (case Mtime of omit -> 0; _ -> 2 end),
    <<Mask:8, (ts(Atime))/binary, (ts(Mtime))/binary>>.

ts(omit) -> <<0:64/little, 0:64/little>>;
ts(Nsec) -> <<(Nsec div 1000000000):64/little,
              (Nsec rem 1000000000):64/little>>.

keep(omit, Was) -> Was;
keep(Nsec, _) -> Nsec div 1000000000.

-doc "As `set_times/4`, for an open descriptor rather than a name.".
-spec set_times_fd(handle(), non_neg_integer() | omit,
                   non_neg_integer() | omit) -> ok | {error, non_neg_integer()}.
set_times_fd({native, H}, Atime, Mtime) ->
    case wasi_file_nif:futimes(H, times_spec(Atime, Mtime)) of
        ok -> ok;
        {error, E} -> {error, map_posix(E)}
    end;
set_times_fd({fallback, _D, Path}, Atime, Mtime) ->
    case file:read_link_info(Path, [{time, posix}]) of
        {error, R} -> {error, map_posix(R)};
        {ok, Info} ->
            A = keep(Atime, Info#file_info.atime),
            M = keep(Mtime, Info#file_info.mtime),
            to_error(file:write_file_info(Path, Info#file_info{atime = A,
                                                              mtime = M},
                                          [{time, posix}]))
    end.

-spec rename(root(), binary(), root(), binary()) ->
          ok | {error, non_neg_integer()}.
rename(From, A, To, B) ->
    %% As `rmdir/2': renaming onto a non-empty directory is `eexist' here and
    %% ENOTEMPTY everywhere the specification is written down.
    case op2(From, A, To, B, ?OP_RENAME, fun file:rename/2) of
        {error, ?EEXIST} -> {error, ?ENOTEMPTY};
        Other -> Other
    end.

-spec link(root(), binary(), root(), binary()) ->
          ok | {error, non_neg_integer()}.
link(From, A, To, B) -> op2(From, A, To, B, ?OP_LINK, fun file:make_link/2).

op(D, Guest, Op, Arg) ->
    case wasi_file_nif:path_op(D, Guest, Op, Arg) of
        {error, E} -> {error, map_posix(E)};
        Other -> Other
    end.

op2({native, D1}, A, {native, D2}, B, Op, _Fb) ->
    case wasi_file_nif:path_op2(D1, A, D2, B, Op) of
        {error, E} -> {error, map_posix(E)};
        Other -> Other
    end;
op2({fallback, R1}, A, {fallback, R2}, B, _Op, Fb) ->
    %% The source must exist and the destination need not, and both are checked
    %% against their own root.
    %%
    %% Neither is followed. `link' and `rename' act on the name given: a hard
    %% link to a dangling symlink is a link to the *link*, and it is a case the
    %% specification suite checks. Following the source resolved it to nothing
    %% and answered `ENOENT'.
    case {wasi_path:resolve(R1, A, true, nofollow),
          wasi_path:resolve(R2, B, false, nofollow)} of
        {{ok, From}, {ok, To}} -> to_error(Fb(From, To));
        {{error, E}, _} -> {error, E};
        {_, {error, E}} -> {error, E}
    end.

fb(Root, Guest, MustExist, Fun) -> fb(Root, Guest, MustExist, Fun, nofollow).

%% `nofollow' for everything that acts on a *name*.
%%
%% Unlink, rmdir, symlink, readlink and a link's own stat all mean the last
%% component itself, not what it points at, and the resolver used to hand back
%% the target. So `readlink' answered `EINVAL' about a regular file and `unlink'
%% removed the wrong one. See `wasi_path:resolve/4'.
fb(Root, Guest, MustExist, Fun, Final) ->
    case wasi_path:resolve(Root, Guest, MustExist, Final) of
        {error, E} -> {error, E};
        {ok, Full} ->
            case Fun(Full) of
                ok -> ok;
                {ok, _} = Ok -> Ok;
                {error, R} -> {error, map_posix(R)}
            end
    end.

%% By field name, not by position: `#file_info.type' is the fourth field of the
%% record and the fifth element of the tuple, and reading it positionally
%% picked up `access' instead, which never matches any of these.
%%
%% The same shape the native backend answers, so `wasi_preview1:filestat/1' does
%% not care which one produced it. `inode' used to be a hardcoded zero here and
%% the times were absent, which meant two files in a directory reported the same
%% inode and a guest that subtracted a timestamp it had just set underflowed.
%%
%% Read this with `read_file_info/2' or `read_link_info/2' in `posix' time
%% units, which is seconds; the WASI struct wants nanoseconds.
info_map(#file_info{size = Size, type = Type, inode = Inode, links = Links,
                    atime = A, mtime = M, ctime = C}) ->
    #{size => Size,
      type => case Type of
                  directory -> directory;
                  regular -> regular;
                  symlink -> symlink;
                  _ -> other
              end,
      inode => Inode,
      %% The fallback has no device number to offer. Nothing in Preview 1
      %% requires one to be meaningful, only that a file keeps the same one.
      dev => 0,
      nlink => Links,
      atim => secs_to_nsec(A), mtim => secs_to_nsec(M), ctim => secs_to_nsec(C)}.

secs_to_nsec(S) when is_integer(S) -> S * 1000000000;
%% `file:read_file_info/1' answers a datetime tuple unless asked for `posix'
%% time. Every caller here asks, so this is the belt on that braces.
secs_to_nsec(_) -> 0.

%%% ------------------------------------------------------------------ io ---

-spec pread(handle(), non_neg_integer(), non_neg_integer()) ->
          {ok, binary()} | eof | {error, non_neg_integer()}.
pread({native, H}, Offset, Len) ->
    case wasi_file_nif:pread(H, Offset, Len) of
        {error, E} -> {error, map_posix(E)};
        Other -> Other
    end;
pread({fallback, D, _}, Offset, Len) ->
    case file:pread(D, Offset, Len) of
        {error, R} -> {error, map_posix(R)};
        Other -> Other
    end.

-spec pwrite(handle(), non_neg_integer(), binary()) ->
          {ok, non_neg_integer()} | {error, non_neg_integer()}.
pwrite({native, H}, Offset, Data) ->
    case wasi_file_nif:pwrite(H, Offset, Data) of
        {error, E} -> {error, map_posix(E)};
        Other -> Other
    end;
pwrite({fallback, D, _}, Offset, Data) ->
    case file:pwrite(D, Offset, Data) of
        ok -> {ok, byte_size(Data)};
        {error, R} -> {error, map_posix(R)}
    end.

-doc """
Everything the WASI filestat holds, for an open descriptor.

The same map `stat/2` answers for a name. `fd_filestat_get` used to report only
the size and the descriptor's own filetype and zero for the rest, which is what
made two files in a directory share an inode.

The fallback has no `fstat`, so it stats the path the descriptor was opened
from. That is a second resolution and therefore a window, which is the whole
reason the native backend exists; it is the fallback's existing bargain and not
a new one.
""".
-spec stat_fd(handle()) -> {ok, map()} | {error, non_neg_integer()}.
stat_fd({native, H}) ->
    case wasi_file_nif:fstat(H) of
        {ok, Info} -> {ok, Info};
        {error, E} -> {error, map_posix(E)}
    end;
stat_fd({fallback, _D, Path}) ->
    case file:read_link_info(Path, [{time, posix}]) of
        {ok, Info} -> {ok, info_map(Info)};
        {error, R} -> {error, map_posix(R)}
    end.

-spec size(handle()) -> {ok, non_neg_integer()} | {error, non_neg_integer()}.
size({native, H}) ->
    case wasi_file_nif:fstat(H) of
        {ok, #{size := S}} -> {ok, S};
        {error, E} -> {error, map_posix(E)}
    end;
size({fallback, D, _}) ->
    case file:position(D, eof) of
        {ok, S} -> {ok, S};
        {error, R} -> {error, map_posix(R)}
    end.

-spec close(handle()) -> ok.
close({native, H}) -> wasi_file_nif:close(H);
close({fallback, D, _}) -> _ = file:close(D), ok.

-spec list_dir(file:filename_all(), binary()) ->
          {ok, [binary()]} | {error, non_neg_integer()}.
-doc """
List the directory a root names, rather than one beneath it.

What `fd_readdir` needs: the descriptor already names the directory, and on the
native backend it *is* the directory, so there is no name to resolve. `.` and
`..` are filtered out here so both backends answer the same thing; the caller
puts them back, because a reader that counts entries expects them first.
""".
-spec list(root()) -> {ok, [binary()]} | {error, non_neg_integer()}.
list({native, H}) ->
    case wasi_file_nif:readdir(H) of
        {ok, Names} ->
            {ok, [N || N <- Names, N =/= ~".", N =/= ~".."]};
        {error, E} ->
            {error, map_posix(E)}
    end;
list({fallback, Path}) ->
    case file:list_dir(Path) of
        {ok, Names} -> {ok, [unicode:characters_to_binary(N) || N <- Names]};
        {error, R} -> {error, map_posix(R)}
    end.

list_dir(Root, Guest) ->
    case backend() of
        native ->
            case wasi_file_nif:open_at(unicode:characters_to_list(Root), Guest, 0, 1) of
                {error, E} -> {error, map_posix(E)};
                {ok, H} ->
                    Result = case wasi_file_nif:readdir(H) of
                                 {ok, Names} -> {ok, Names};
                                 {error, E2} -> {error, map_posix(E2)}
                             end,
                    ok = wasi_file_nif:close(H),
                    Result
            end;
        fallback ->
            case wasi_path:resolve(Root, Guest, true) of
                {error, E} -> {error, E};
                {ok, Full} ->
                    case file:list_dir(Full) of
                        {ok, Names} ->
                            {ok, [unicode:characters_to_binary(N) || N <- Names]}; {error, R} -> {error, map_posix(R)}
                    end
            end
    end.

%%% --------------------------------------------------------------- mapping ---

native_flags(Modes) ->
    %% Raw open(2) flags. Values differ per platform in principle; these are the
    %% ones every supported Unix agrees on.
    Base = case {lists:member(read, Modes), lists:member(write, Modes)} of
               {true, true} -> 2;      % O_RDWR
               {_, true} -> 1;         % O_WRONLY
               _ -> 0                  % O_RDONLY
           end,
    Base
        bor creat_flag(lists:member(create, Modes))
        bor trunc_flag(lists:member(truncate, Modes))
        bor excl_flag(lists:member(exclusive, Modes)).

%% O_CREAT, O_TRUNC and O_EXCL are not stable across platforms, so they are
%% taken from the host rather than hardcoded.
creat_flag(false) -> 0;
creat_flag(true) -> o_creat().
trunc_flag(false) -> 0;
trunc_flag(true) -> o_trunc().
excl_flag(false) -> 0;
excl_flag(true) -> o_excl().

o_creat() -> case os:type() of {unix, darwin} -> 16#0200; _ -> 16#40 end.
o_trunc() -> case os:type() of {unix, darwin} -> 16#0400; _ -> 16#200 end.
o_excl()  -> case os:type() of {unix, darwin} -> 16#0800; _ -> 16#80 end.

fallback_modes(Modes) ->
    [binary, raw, read]
        ++ [write || lists:member(write, Modes)]
        ++ [exclusive || lists:member(exclusive, Modes)].

%% One table for both backends.
%%
%% There used to be two: this one for the atoms `file:' answers and a second for
%% raw errno *numbers* from the NIF. The numbers are platform-specific and the
%% table was a mix of both, so one platform was always wrong: 63 is
%% ENAMETOOLONG on darwin and ENOSR on Linux, and 36 is the other way round.
%% The NIF names its errors now, so there is nothing left to guess.
%%
%% The catch-all was doing real damage too. Everything unlisted became EIO, so a
%% guest removing a non-empty directory was told "I/O error" rather than
%% ENOTEMPTY and could not tell the two apart.
%%
%% ENOTDIR and ELOOP report themselves. They were folded into ENOTCAPABLE on the
%% theory that any error code is an oracle for the host's layout, but they are
%% facts about a path the guest is allowed to name and can already stat.
%% ENOTCAPABLE stays for what it is for: a path the sandbox refuses, which is
%% `wasi_path:resolve/3' answering `unsafe' and the walk refusing an absolute
%% path or an escape.
%% The walk's own refusal, not a host error: an absolute path, `..' at the root,
%% or a symlink pointing out of the preopen. It is the one answer that says the
%% capability model refused rather than the filesystem.
map_posix(enotcapable) -> ?ENOTCAPABLE;
map_posix(enoent) -> ?ENOENT;
map_posix(eexist) -> ?EEXIST;
map_posix(eacces) -> ?EACCES;
map_posix(eisdir) -> ?EISDIR;
map_posix(enotdir) -> ?ENOTDIR;
map_posix(enotempty) -> ?ENOTEMPTY;
map_posix(eloop) -> ?ELOOP;
map_posix(eperm) -> ?EPERM;
map_posix(ebadf) -> ?EBADF;
map_posix(espipe) -> ?ESPIPE;
map_posix(einval) -> ?EINVAL;
map_posix(eagain) -> ?EAGAIN;
map_posix(efault) -> ?EFAULT;
map_posix(emfile) -> ?EMFILE;
map_posix(enfile) -> ?ENFILE;
map_posix(ebusy) -> ?EBUSY;
map_posix(efbig) -> ?EFBIG;
map_posix(enxio) -> ?ENXIO;
map_posix(enomem) -> ?ENOMEM;
map_posix(enospc) -> ?ENOSPC;
map_posix(enosys) -> ?ENOSYS;
map_posix(enotsup) -> ?ENOTSUP;
map_posix(epipe) -> ?EPIPE;
map_posix(erofs) -> ?EROFS;
map_posix(exdev) -> ?EXDEV;
map_posix(enametoolong) -> ?ENAMETOOLONG;
map_posix(_) -> ?EIO.
