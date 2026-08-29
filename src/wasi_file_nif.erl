-module(wasi_file_nif).
-moduledoc """
Optional native file access that closes the WASI path race.

Changing the C means running it under a sanitizer; the sanitizer section of
`docs/wasi.md` says how, and why AddressSanitizer alone is not enough for it.

You never call this; `wasi_fs` picks it when it built. Call `wasi_fs:backend/0`
to find out whether you have it. `wasi_path` resolves a path and then opens it,
and a component can be swapped for a symlink in between. `filelib:safe_relative_path/2` closes every lexical
and static symlink escape, but Erlang exposes neither `openat` nor
`O_NOFOLLOW`, so the race itself cannot be closed from Erlang.

This module walks a path one component at a time with `openat(..., O_NOFOLLOW)`
relative to the previously opened directory, so each name is resolved exactly
once, by the kernel, and no symlink is followed at any depth.

## Optional by construction

If the shared object is missing or fails to load, `available/0` returns `false`
and `wasi_path` falls back to the pure-Erlang resolver with the race documented.
Building this project never requires a C compiler.

## Scope

Six functions, all file I/O. No WebAssembly semantics cross the boundary:
capability decisions, rights masking and errno mapping stay in Erlang. Every
call is O(1) or bounded by an explicit length, and all of them run on dirty I/O
schedulers because they block.
""".

-export([available/0, open_at/4, open_dir/1, pread/3, pwrite/3, fstat/1,
         futimes/2,
         readdir/1, path_op/4, path_op2/5,
         ftruncate/2, fsync/1, close/1]).
-on_load(init/0).

-define(NOT_LOADED, erlang:nif_error({nif_not_loaded, ?MODULE})).

-doc "Whether the native backend loaded. `false` means the fallback is in use.".
-spec available() -> boolean().
available() ->
    %% The flag is set by init/0 rather than probed, so a partially loaded NIF
    %% cannot look available.
    persistent_term:get({?MODULE, available}, false).

-doc """
Open `RelPath` beneath `Dir`, one component at a time.

`Dir` is either a handle from a previous call or, for a preopen, the host root
as a string. `Flags` are raw `open(2)` flags.

`Follow` is 1 when the *final* component may be a symlink that gets followed
and 0 when it may not, which is what `LOOKUPFLAGS_SYMLINK_FOLLOW` decides.
Components before the last are always followed: that is what a path means.
""".
-spec open_at(term(), binary(), integer(), 0 | 1) ->
          {ok, term()} | {error, atom()}.
open_at(_Dir, _RelPath, _Flags, _Follow) -> ?NOT_LOADED.

-doc """
Open a preopen root by name, once.

The only place a path is resolved by name rather than component by component,
and it happens once per preopen rather than once per open, which is what
anchoring means.
""".
-spec open_dir(string()) -> {ok, term()} | {error, integer()}.
open_dir(_Path) -> ?NOT_LOADED.

-spec pread(term(), integer(), non_neg_integer()) ->
          {ok, binary()} | eof | {error, integer()}.
pread(_H, _Offset, _Len) -> ?NOT_LOADED.

-spec pwrite(term(), integer(), binary()) -> {ok, non_neg_integer()} | {error, integer()}.
pwrite(_H, _Offset, _Data) -> ?NOT_LOADED.

-spec fstat(term()) -> {ok, map()} | {error, integer()}.
fstat(_H) -> ?NOT_LOADED.

-doc """
Set an open descriptor's times, as two 64-bit second/nanosecond pairs.

`futimens`, because an open file has no name to walk: `fd_filestat_set_times`
cannot go through the path operations the way its `path_*` counterpart does.
""".
-spec futimes(term(), binary()) -> ok | {error, atom()}.
futimes(_H, _Spec) -> ?NOT_LOADED.

-spec readdir(term()) -> {ok, [binary()]} | {error, integer()}.
readdir(_H) -> ?NOT_LOADED.

-doc """
Act on a name inside a directory, without resolving that name twice.

The walk stops one component short and the operation is a single `*at` call
against a descriptor nobody can substitute, which is what closes the window
between checking a path and acting on it. `Op` is a small integer because
choosing it is `wasi_fs`'s business and no WebAssembly meaning crosses this
boundary.
""".
-spec path_op(term(), binary(), integer(), binary()) ->
          ok | {ok, term()} | {error, integer()}.
path_op(_Dir, _Rel, _Op, _Arg) -> ?NOT_LOADED.

-doc """
The two-place operations, rename and link.

Each end is resolved against its own directory. Resolving only one would let a
module move a file out of the sandbox by naming the destination carelessly.
""".
-spec path_op2(term(), binary(), term(), binary(), integer()) ->
          ok | {error, integer()}.
path_op2(_Dir1, _Rel1, _Dir2, _Rel2, _Op) -> ?NOT_LOADED.

-spec ftruncate(term(), non_neg_integer()) -> ok | {error, integer()}.
ftruncate(_H, _Len) -> ?NOT_LOADED.

-doc """
Flush this file to disk.

Answers `ok` for a descriptor that cannot be synced, such as a pipe. A guest
that calls `fd_sync` defensively should not be failed for holding something
that has nothing to flush.
""".
-spec fsync(term()) -> ok | {error, integer()}.
fsync(_H) -> ?NOT_LOADED.

-spec close(term()) -> ok.
close(_H) -> ?NOT_LOADED.

%%% ----------------------------------------------------------------- load ---

init() ->
    Path = filename:join(priv_dir(), "wasi_file_nif"),
    case erlang:load_nif(Path, 0) of
        ok ->
            persistent_term:put({?MODULE, available}, true),
            ok;
        {error, _Reason} ->
            %% Deliberately not an error. The native backend is an optimisation
            %% of a security property, not a requirement: without it the pure
            %% Erlang resolver still refuses every escape it can detect, and
            %% only the time-of-check window remains.
            persistent_term:put({?MODULE, available}, false),
            ok
    end.

priv_dir() ->
    case code:priv_dir(wasm) of
        {error, bad_name} -> "priv";
        Dir -> Dir
    end.
