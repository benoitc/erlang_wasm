-module(wasi_path).
-moduledoc """
Capability-scoped path resolution.

This is the part of WASI that decides whether a sandbox is real, so read it
before you trust one. A module names a path relative to a preopened directory,
and this module decides which host path, if any, that is allowed to mean.

Four escape routes have to be closed, and all four are tested in `wasi_SUITE`:
- absolute paths (`/etc/passwd`)
- parent traversal (`../../etc/passwd`)
- traversal that only escapes partway through (`sub/../../outside`)
- symlinks pointing out of the sandbox, including absolute ones and symlinked directories used as a prefix

`filelib:safe_relative_path/2` already handles all four, including the
symlink cases, so it is used rather than reimplemented: a hand-rolled path
sanitiser is exactly the kind of code that looks right and is not.

**Residual risk you carry.** There is a time-of-check to time-of-use window
between resolving a path and opening it: someone with write access to the
sandbox directory can replace a component with a symlink in between.
Re-verifying the opened path afterwards narrows the window without closing it,
because Erlang's file module exposes neither `openat` nor `O_NOFOLLOW`. Do not
point a preopen at a directory an untrusted party can write to concurrently.
""".

-include("wasi.hrl").

-export([resolve/2, resolve/3, resolve/4, verify_within/2]).

-doc "Resolve a guest-supplied path against a preopened host directory.".
-spec resolve(file:filename_all(), binary()) ->
          {ok, file:filename_all()} | {error, non_neg_integer()}.
resolve(HostRoot, GuestPath) -> resolve(HostRoot, GuestPath, false).

-doc """
As `resolve/2`. `MustExist` additionally requires the target to be
present, which distinguishes "you may not name that" from "it is not there".
""".
-spec resolve(file:filename_all(), binary(), boolean()) ->
          {ok, file:filename_all()} | {error, non_neg_integer()}.
resolve(_HostRoot, <<>>, _MustExist) ->
    {error, ?EINVAL};
resolve(HostRoot, GuestPath, MustExist) when is_binary(GuestPath) ->
    case unicode:characters_to_list(GuestPath, utf8) of
        {error, _, _} -> {error, ?EINVAL};
        {incomplete, _, _} -> {error, ?EINVAL};
        Path when length(Path) > 4096 -> {error, ?ENAMETOOLONG};
        Path -> resolve_checked(HostRoot, Path, MustExist)
    end.

-doc """
As `resolve/3`, saying whether the last component may be resolved.

`nofollow` is what lets this backend *name* a symlink. `filelib:safe_relative_path/2`
resolves links in the course of deciding a path is safe, which is what makes it
safe without `openat`, and it means the resolved path is the link's target: a
`readlink` through it answers `EINVAL` about a regular file, and an `unlink`
removes the wrong thing.

So for `nofollow` only the *parent* is resolved, and the last component is
appended by name. Containment still holds and holds for the same reason: the
parent is inside the root because `safe_relative_path/2` said so, and a bare
name with no separator in it cannot leave the directory it is in.

`.` and `..` are resolved whole. They name directories, so there is no final
component to decline to follow, and appending them by name is exactly the
traversal this must not do by hand.
""".
-spec resolve(file:filename_all(), binary(), boolean(), follow | nofollow) ->
          {ok, file:filename_all()} | {error, non_neg_integer()}.
resolve(HostRoot, GuestPath, MustExist, follow) ->
    resolve(HostRoot, GuestPath, MustExist);
resolve(_HostRoot, <<>>, _MustExist, nofollow) ->
    {error, ?EINVAL};
resolve(HostRoot, GuestPath, MustExist, nofollow) ->
    case unicode:characters_to_list(GuestPath, utf8) of
        {error, _, _} -> {error, ?EINVAL};
        {incomplete, _, _} -> {error, ?EINVAL};
        Path when length(Path) > 4096 -> {error, ?ENAMETOOLONG};
        Path -> resolve_last(HostRoot, Path, MustExist)
    end.

resolve_last(HostRoot, Path0, MustExist) ->
    %% Strip the trailing slash first. `filename:dirname("file/")' answers
    %% `"file"' rather than `"."', so splitting a path that ends in one puts the
    %% last component in both halves and looks for `dir/dir'. Whether a trailing
    %% slash was there is the caller's business anyway: `wasi_preview1' checks
    %% separately that such a path names a directory.
    Path = string:trim(Path0, trailing, "/"),
    resolve_last_1(HostRoot, Path, Path0, MustExist).

resolve_last_1(HostRoot, "", Path0, MustExist) ->
    resolve_checked(HostRoot, Path0, MustExist);
resolve_last_1(HostRoot, Path, _Path0, MustExist) ->
    case lists:last(filename:split(Path)) of
        Base when Base =:= "."; Base =:= ".."; Base =:= "/" ->
            resolve_checked(HostRoot, Path, MustExist);
        Base ->
            Dir = filename:dirname(Path),
            %% The parent must exist whatever `MustExist' says about the target:
            %% there is nowhere to put a name otherwise.
            case resolve_checked(HostRoot, Dir, true) of
                {error, E} -> {error, E};
                {ok, Parent} ->
                    Full = filename:join(Parent, Base),
                    %% `read_link_info/1', which does not follow: a dangling
                    %% link exists as a link, and `path_link' to one is a case
                    %% the specification suite checks.
                    case MustExist andalso not names_something(Full) of
                        true -> {error, ?ENOENT};
                        false -> {ok, Full}
                    end
            end
    end.

names_something(Path) ->
    case file:read_link_info(Path) of
        {ok, _} -> true;
        _ -> false
    end.

resolve_checked(HostRoot, Path, MustExist) ->
    case filelib:safe_relative_path(Path, HostRoot) of
        unsafe ->
            %% Deliberately `ENOTCAPABLE', not `ENOENT' or `EACCES'. The module
            %% asked for something outside its capability; saying so is both
            %% more accurate and avoids turning the error code into an oracle
            %% for probing the host filesystem's layout.
            {error, ?ENOTCAPABLE};
        SafeRel ->
            Full = filename:join(HostRoot, SafeRel),
            case MustExist andalso not exists(Full) of
                true -> {error, ?ENOENT};
                false -> {ok, Full}
            end
    end.

exists(Path) ->
    case file:read_link_info(Path) of
        {ok, _} -> true;
        _ -> false
    end.

-doc """
Re-check that a path is still inside the root.

Called after opening, to narrow the time-of-check to time-of-use window
described above. It cannot eliminate it.
""".
-spec verify_within(file:filename_all(), file:filename_all()) -> ok | {error, non_neg_integer()}.
verify_within(HostRoot, Path) ->
    case {real(HostRoot), real(Path)} of
        {{ok, Root}, {ok, Real}} ->
            case lists:prefix(Root, Real) of
                true -> ok;
                false -> {error, ?ENOTCAPABLE}
            end
    end.

%% Canonicalise, resolving every symlink. Compared with a trailing separator so
%% that "/srv/appdata" is not treated as being inside "/srv/app".
real(Path) ->
    case file:read_link_all(Path) of
        {ok, _} -> canonical(Path);
        {error, einval} -> canonical(Path);      % not a symlink
        {error, _} -> canonical(Path)
    end.

canonical(Path) ->
    Abs = filename:absname(Path),
    case file:read_file_info(Abs) of
        {ok, _} -> {ok, ensure_trailing(filename:join(split_resolved(Abs)))};
        {error, _} -> {ok, ensure_trailing(Abs)}
    end.

split_resolved(Path) -> filename:split(Path).

ensure_trailing(P) when is_list(P) -> P ++ "/";
ensure_trailing(P) -> binary_to_list(P) ++ "/".
