-module(wasi_preview1).
-moduledoc """
WASI Preview 1, as an Erlang host interface.

Build an import map here when you want to choose exactly what a WASI program may
reach. This is not an embedded WASI runtime: each syscall is an ordinary Erlang
host function, so you can inspect it, trace it, replace it or refuse it, and the
capability decisions are made in Erlang rather than inside somebody else's C
library.

## Grant capabilities explicitly, because nothing is ambient

```
Wasi = #{ stdout => group_leader(),
          dirs   => [{<<"/data">>, "/srv/app/data", read}],
          env    => #{<<"MODE">> => <<"production">>},
          args   => [<<"prog">>, <<"--flag">>],
          clocks => [monotonic],
          random => strong,
          net    => #{connect => [{tcp, <<"10.0.0.0/8">>, 443}]} },
{ok, Imports} = wasi_preview1:imports(Wasi).
```

Leave a key out and the module does not have that capability: the syscall
returns `ENOTCAPABLE`. No `dirs` means no filesystem at all, not one rooted at
the current directory. No `net` means no network at all, not a network
restricted to somewhere sensible. No `env` means `environ_get` reports zero
variables rather than leaking the host's. That is the opposite of the usual
default, and it is the point: a module gets what you gave it and nothing else.

`wasi_net` parses the network grant, and `wasi_sock` runs the sockets behind it.
`docs/security.md` says what a grant does not cover.

`ENOTCAPABLE` stays distinct from `EACCES` throughout, so the module (and
whoever is debugging it) can tell "you were not granted this" from "the host
operating system refused".

Path resolution, which is where sandboxes actually fail, is in `wasi_path`.
""".

-include("wasm.hrl").
-include("wasm_exec.hrl").
-include_lib("kernel/include/file.hrl").
-include("wasi.hrl").

-export([imports/1, imports/2, default_config/0]).
-export([exit_code/1]).
-export([close_all/1]).

-doc """
Close every descriptor this instance still holds.

Registered as an instance cleanup, so `wasm:destroy/1` runs it. A guest that
exits without closing its files and sockets is ordinary, and dropping the
handles only makes them unreachable: the operating system resources stay until
the owning process exits. Preopens are closed here too. Refusing to close one
is a rule about the guest asking, not about teardown.
""".
-spec close_all(term()) -> ok.
close_all(Inst) ->
    case wasm_instance:get_extra(Inst, wasi) of
        error -> ok;
        {ok, #{fds := Fds} = St} ->
            _ = [close_entry(E) || E <- maps:values(Fds)],
            wasm_instance:set_extra(Inst, wasi, St#{fds := #{}})
    end.

close_entry(#wasi_fd{type = file, handle = H}) when H =/= undefined ->
    wasi_fs:close(H);
close_entry(#wasi_fd{type = socket, handle = H}) when H =/= undefined ->
    wasi_sock:close(H);
close_entry(#wasi_fd{type = dir, root = R}) when R =/= undefined ->
    wasi_fs:forget(R);
close_entry(_) ->
    ok.

-define(MODULE_NAME, <<"wasi_snapshot_preview1">>).

%% Preopened directories start here; 0/1/2 are stdio.
-define(FIRST_PREOPEN_FD, 3).

%%% ----------------------------------------------------------------- api ---

-spec default_config() -> map().
default_config() ->
    #{args => [], env => #{}, dirs => [], clocks => [monotonic, realtime],
      random => strong, net => none}.

-spec imports(map()) -> map().
imports(Config) -> imports(Config, ?MODULE_NAME).

-doc """
Build the import map, under a module name you choose. Pass `wasi_unstable` to
bind the same implementation for an older toolchain.
""".
-spec imports(map(), binary()) -> map().
imports(Config0, ModuleName) ->
    Merged = maps:merge(default_config(), Config0),
    %% The network grant is parsed here, in the embedder's own process, so a
    %% malformed rule is reported as the configuration error it is rather than
    %% surfacing later as a refused connection.
    Config = Merged#{net := wasi_net:grant(maps:get(net, Merged, none))},
    Fns = [args_get, args_sizes_get, environ_get, environ_sizes_get,
           clock_res_get, clock_time_get, random_get,
           fd_write, fd_read, fd_close, fd_seek, fd_tell, fd_fdstat_get,
           fd_fdstat_set_flags, fd_fdstat_set_rights,
           fd_prestat_get, fd_prestat_dir_name,
           fd_filestat_get, fd_filestat_set_size, fd_filestat_set_times,
           fd_sync, fd_datasync, fd_pread, fd_pwrite, fd_readdir,
           fd_advise, fd_allocate, fd_renumber,
           path_open, path_filestat_get, path_filestat_set_times,
           path_create_directory, path_unlink_file, path_remove_directory,
           path_rename, path_symlink, path_readlink, path_link,
           proc_exit, sched_yield, poll_oneoff,
           %% Preview 1's own four, then the extension a client needs.
           sock_accept, sock_recv, sock_send, sock_shutdown,
           sock_open, sock_bind, sock_listen, sock_connect,
           sock_send_to, sock_recv_from, sock_getlocaladdr, sock_getpeeraddr,
           sock_getsockopt, sock_setsockopt, sock_getaddrinfo],
    maps:from_list(
      [{{ModuleName, atom_to_binary(F)},
        fun(Ctx, Args) -> dispatch(F, Ctx, Args, Config) end} || F <- Fns]).

-doc "Pull the exit status out of the error `proc_exit` produces.".
-spec exit_code(term()) -> {ok, integer()} | error.
exit_code(#{class := trap, ctx := #{wasi_exit := Code}}) -> {ok, Code};
exit_code(_) -> error.

%%% -------------------------------------------------------------- dispatch ---

%% Every syscall returns an errno. An Erlang exception inside one would be
%% converted to a trap by the interpreter, which is a much blunter failure than
%% the errno the module is expecting and able to handle, so unexpected errors
%% become `EIO' instead.
dispatch(Name, Ctx, Args, Config) ->
    try
        St = state(Ctx, Config),
        case handle(Name, Ctx, Args, Config, St) of
            {errno, E} -> {ok, [E]};
            {errno, E, St1} -> save(Ctx, St1), {ok, [E]};
            {trap, Reason, TrapCtx} -> wasm_error:trap(Reason, TrapCtx)
        end
    catch
        throw:{wasm_error, _} = Err -> erlang:throw(Err);
        _Class:_Reason -> {ok, [?EIO]}
    end.

%%% ------------------------------------------------------ args and environ ---

handle(args_sizes_get, Ctx, [CountPtr, BufPtr], Config, _St) ->
    sizes(Ctx, CountPtr, BufPtr, maps:get(args, Config));
handle(args_get, Ctx, [PtrsPtr, BufPtr], Config, _St) ->
    write_strings(Ctx, PtrsPtr, BufPtr, maps:get(args, Config));

handle(environ_sizes_get, Ctx, [CountPtr, BufPtr], Config, _St) ->
    sizes(Ctx, CountPtr, BufPtr, env_list(Config));
handle(environ_get, Ctx, [PtrsPtr, BufPtr], Config, _St) ->
    write_strings(Ctx, PtrsPtr, BufPtr, env_list(Config));

%%% --------------------------------------------------------------- clocks ---

handle(clock_res_get, Ctx, [ClockId, OutPtr], Config, _St) ->
    case clock_allowed(ClockId, Config) of
        false -> {errno, ?ENOTCAPABLE};
        true -> write_u64(Ctx, OutPtr, 1000)          % 1 us, honestly reported
    end;
handle(clock_time_get, Ctx, [ClockId, _Precision, OutPtr], Config, _St) ->
    case clock_allowed(ClockId, Config) of
        false -> {errno, ?ENOTCAPABLE};
        true ->
            case clock_now(ClockId) of
                {ok, Nanos} -> write_u64(Ctx, OutPtr, Nanos);
                error -> {errno, ?EINVAL}
            end
    end;

%%% --------------------------------------------------------------- random ---

handle(random_get, Ctx, [Buf, Len0], Config, St) ->
    case maps:get(random, Config, none) of
        none -> {errno, ?ENOTCAPABLE};
        Source ->
            Ptr = wasm_num:to_u32(Buf),
            Len = wasm_num:to_u32(Len0),
            %% Checked before a byte is generated, so a request that could
            %% never land costs nothing to refuse.
            case fits(Ctx, Ptr, Len) of
                false -> {errno, ?EFAULT};
                true ->
                    {E, St1} = fill_random(Ctx, Ptr, Len, Source, St),
                    {errno, E, St1}
            end
    end;

%%% ------------------------------------------------------------- file I/O ---

handle(fd_write, Ctx, [Fd, IovsPtr, IovsLen, NWrittenPtr], _Config, St) ->
    with_fd(St, Fd, ?RIGHT_FD_WRITE,
            fun(Entry) ->
                case read_iovecs(Ctx, IovsPtr, IovsLen) of
                    {error, E} -> {errno, E};
                    {ok, Data} -> do_write(Ctx, Entry, Data, NWrittenPtr, St, Fd)
                end
            end);

handle(fd_read, Ctx, [Fd, IovsPtr, IovsLen, NReadPtr], Config, St) ->
    with_fd(St, Fd, ?RIGHT_FD_READ,
            fun(#wasi_fd{type = socket} = Entry) ->
                    %% Reading a socket through `fd_read' is a `sock_recv' with
                    %% no flags. Rust's `TcpStream` implements `Read`, so this
                    %% is the path a program actually takes.
                    sock_read(Ctx, Entry, Fd, IovsPtr, IovsLen, 0, NReadPtr,
                              none, Config, St);
               (Entry) ->
                    case iovec_specs(Ctx, IovsPtr, IovsLen) of
                        {error, E} -> {errno, E};
                        {ok, Specs} -> do_read(Ctx, Entry, Specs, NReadPtr, St, Fd)
                    end
            end);

handle(fd_close, _Ctx, [Fd], _Config, St) ->
    case fd_lookup(St, Fd) of
        error -> {errno, ?EBADF};
        %% A preopen closes like anything else. Refusing was defensible -- it
        %% drops a capability irrecoverably and is usually a bug -- but Preview 1
        %% permits it, `close_preopen' asserts it, and it is the guest's own
        %% capability to drop. `fd_prestat_get' answers `EBADF' afterwards,
        %% which is what a libc scanning for preopens expects.
        {ok, #wasi_fd{type = file, handle = H}} ->
            _ = wasi_fs:close(H),
            {errno, ?ESUCCESS, fd_remove(St, Fd)};
        {ok, #wasi_fd{type = socket, handle = H}} ->
            _ = wasi_sock:close(H),
            {errno, ?ESUCCESS, fd_remove(St, Fd)};
        {ok, _} ->
            {errno, ?ESUCCESS, fd_remove(St, Fd)}
    end;

handle(fd_seek, Ctx, [Fd, Offset, Whence, OutPtr], _Config, St) ->
    with_fd(St, Fd, ?RIGHT_FD_SEEK,
            fun(#wasi_fd{type = file, handle = H, offset = Off}) ->
                    %% Arithmetic on the descriptor's own offset. The handle
                    %% has no position of its own any more: every read and
                    %% write is positional, so two descriptors on one file
                    %% cannot move each other's cursor.
                    Base = case Whence of
                               ?WHENCE_SET -> 0;
                               ?WHENCE_CUR -> Off;
                               ?WHENCE_END -> file_size(H);
                               _ -> invalid
                           end,
                    case Base of
                        invalid ->
                            {errno, ?EINVAL};
                        _ when Base + Offset < 0 ->
                            %% Seeking before the start is an error; seeking
                            %% past the end is not, and reads there give
                            %% nothing until something is written.
                            {errno, ?EINVAL};
                        _ ->
                            New = Base + Offset,
                            case write_u64(Ctx, OutPtr, New) of
                                {errno, ?ESUCCESS} ->
                                    {errno, ?ESUCCESS,
                                     fd_set_offset(St, Fd, New)};
                                Other -> Other
                            end
                    end;
               (_) -> {errno, ?ESPIPE}
            end);

%% Positional I/O does not disturb the descriptor's own offset, which is what
%% `Seek`-free readers such as Rust's `read_at` rely on.
handle(fd_pread, Ctx, [Fd, IovsPtr, IovsLen, Offset, NReadPtr], _Config, St) ->
    with_fd(St, Fd, ?RIGHT_FD_READ,
            fun(#wasi_fd{type = file, handle = H}) ->
                    case iovec_specs(Ctx, IovsPtr, IovsLen) of
                        {error, E} -> {errno, E};
                        {ok, Specs} ->
                            Total = lists:sum([L || {_, L} <- Specs]),
                            case wasi_fs:pread(H, Offset, Total) of
                                eof -> write_u32(Ctx, NReadPtr, 0);
                                {ok, Data} ->
                                    ok = scatter(Ctx, Specs, Data),
                                    write_u32(Ctx, NReadPtr, byte_size(Data));
                                {error, E} -> {errno, E}
                            end
                    end;
               (_) -> {errno, ?ESPIPE}
            end);

handle(fd_pwrite, Ctx, [Fd, IovsPtr, IovsLen, Offset, NWrittenPtr], _Config, St) ->
    with_fd(St, Fd, ?RIGHT_FD_WRITE,
            fun(#wasi_fd{type = file, handle = H}) ->
                    case read_iovecs(Ctx, IovsPtr, IovsLen) of
                        {error, E} -> {errno, E};
                        {ok, Data} ->
                            case wasi_fs:pwrite(H, Offset, Data) of
                                {ok, N} -> write_u32(Ctx, NWrittenPtr, N);
                                {error, E} -> {errno, E}
                            end
                    end;
               (_) -> {errno, ?ESPIPE}
            end);

handle(fd_tell, Ctx, [Fd, OutPtr], _Config, St) ->
    with_fd(St, Fd, ?RIGHT_FD_TELL,
            fun(#wasi_fd{type = file, offset = Off}) ->
                    write_u64(Ctx, OutPtr, Off);
               (_) -> {errno, ?ESPIPE}
            end);

%% `FD_FILESTAT_SET_SIZE', not `FD_WRITE'. They are separate rights precisely so
%% a descriptor can be handed on with permission to write but not to truncate,
%% and checking the wrong one let a guest shorten a file it had only been given
%% write access to.
handle(fd_filestat_set_size, _Ctx, [Fd, Size], _Config, St) ->
    with_fd(St, Fd, ?RIGHT_FD_FILESTAT_SET_SIZE,
            fun(#wasi_fd{type = file, handle = H}) ->
                    case wasi_fs:truncate(H, Size) of
                        ok -> {errno, ?ESUCCESS};
                        {error, E} -> {errno, E}
                    end;
               (_) -> {errno, ?EBADF}
            end);

%% Timestamps are accepted and ignored: the runtime does not track them, and
%% failing would break build tools that set them defensively.
%% Both forms of set_times, which used to answer `ESUCCESS' and do nothing.
%%
%% A guest that sets a timestamp and reads it back was told the call worked and
%% then found the old value, which upstream catches twice over: `fd_filestat_set'
%% and `symlink_filestat' both set a stamp and compare.
handle(fd_filestat_set_times, _Ctx, [Fd, Atim, Mtim, Flags], _Config, St) ->
    with_fd(St, Fd, ?RIGHT_FD_FILESTAT_SET_TIMES,
            fun(#wasi_fd{type = file, handle = H}) ->
                    set_times_on(fun(A, M) -> wasi_fs:set_times_fd(H, A, M) end,
                                 Atim, Mtim, Flags);
               (#wasi_fd{type = dir, root = Root}) ->
                    set_times_on(fun(A, M) ->
                                     wasi_fs:set_times(Root, ~".", A, M)
                                 end, Atim, Mtim, Flags);
               (_) -> {errno, ?EBADF}
            end);

handle(path_filestat_set_times, Ctx,
       [DirFd, Flags, PathPtr, PathLen, Atim, Mtim, FstFlags], _Config, St) ->
    with_dir(St, DirFd,
             fun(#wasi_fd{root = Root, rights_inheriting = Inh}) ->
                 case (Inh band ?RIGHT_PATH_FILESTAT_SET_TIMES) =:= 0 of
                     true -> {errno, ?ENOTCAPABLE};
                     false ->
                         case read_path(Ctx, PathPtr, PathLen) of
                             {error, E} -> {errno, E};
                             {ok, Guest} ->
                                 set_times(Root, Guest, Atim, Mtim, FstFlags,
                                           lookup(Flags))
                         end
                 end
             end);

%% Advisory only, and `fd_allocate` is refused rather than silently ignored:
%% a module that asks for space and gets a lie will fail later and further away.
handle(fd_advise, _Ctx, _Args, _Config, _St) ->
    {errno, ?ESUCCESS};

%% Reserve space by growing the file to `Offset + Len' when that is past the
%% end, and do nothing when it is not.
%%
%% This used to answer `ENOSYS' on the grounds that pretending to reserve space
%% is worse than refusing. That reasoning applies to a *lie*; extending the file
%% is not one. What the guest is promised by `fd_allocate' is that a later write
%% inside that range will not fail for want of space, and a file that is already
%% that long delivers it.
handle(fd_allocate, _Ctx, [Fd, Offset, Len], _Config, St) ->
    with_fd(St, Fd, ?RIGHT_FD_ALLOCATE,
            fun(#wasi_fd{type = file, handle = H}) ->
                    Want = Offset + Len,
                    case wasi_fs:size(H) of
                        {error, E} -> {errno, E};
                        {ok, Size} when Size >= Want -> {errno, ?ESUCCESS};
                        {ok, _} ->
                            case wasi_fs:truncate(H, Want) of
                                ok -> {errno, ?ESUCCESS};
                                {error, E} -> {errno, E}
                            end
                    end;
               (_) -> {errno, ?EBADF}
            end);

%% `fd_renumber(from, to)' moves a descriptor, closing whatever `to' named
%% first. Two things were wrong with reading it the other way round.
%%
%% `to' must name an open descriptor. It is being *replaced*, which is what the
%% specification's wording means and what wasmtime enforces; upstream's
%% `renumber' case asserts `EBADF' for a destination that is not open.
%%
%% This ran the other way round for a while, on the reasoning that the point of
%% the call is moving a descriptor to a number the guest picked and that number
%% is usually free, and that a libc doing the standard `dup2' dance would get
%% `EBADF' for a correct call. That has to be wrong somewhere, because wasi-libc
%% runs against wasmtime constantly: either the dance passes a live descriptor,
%% or it was never the dance that failed.
%%
%% And when `to' was open, its entry was overwritten rather than closed, so
%% the file or socket behind it stayed open with no descriptor naming it: the
%% guest could not close it and `close_all/1' at destroy could not find it.
handle(fd_renumber, _Ctx, [From, To], _Config, St) ->
    case fd_lookup(St, From) of
        error ->
            {errno, ?EBADF};
        {ok, #wasi_fd{preopen = true}} ->
            %% Same reasoning as `fd_close': moving a preopen away from the
            %% number a module discovered it at is almost always a bug.
            {errno, ?ENOTSUP};
        {ok, Entry} ->
            case fd_lookup(St, To) of
                error -> {errno, ?EBADF};
                {ok, Old} ->
                    _ = close_entry(Old),
                    Fds = maps:get(fds, St),
                    St1 = St#{fds := maps:put(To, Entry, Fds)},
                    {errno, ?ESUCCESS, fd_remove(St1, From)}
            end
    end;

%% Directory listing. Entries are emitted as `dirent` records followed by the
%% name, truncated to the caller's buffer; the cookie is the index of the next
%% entry, so a caller with a small buffer can page through.
handle(fd_readdir, Ctx, [Fd, Buf, BufLen, Cookie, NUsedPtr], _Config, St) ->
    with_fd(St, Fd, ?RIGHT_FD_READDIR,
            fun(#wasi_fd{type = dir, host_path = Dir, root = Root}) ->
                    %% Through the descriptor's own directory, which on the
                    %% native backend is the directory rather than its name, so
                    %% listing it cannot be redirected by a rename between the
                    %% open and the read.
                    case wasi_fs:list(Root) of
                        {error, E} -> {errno, E};
                        {ok, Bins} ->
                            Names = [binary_to_list(B) || B <- Bins],
                            %% "." and ".." are expected by readers that count
                            %% entries, and sorting makes the cookie stable
                            %% across calls, which paging depends on.
                            All = [".", ".."] ++ lists:sort(Names),
                            Bin = dirents(Dir, All, Cookie, BufLen),
                            case wasm:write_memory(Ctx, wasm_num:to_u32(Buf), Bin) of
                                ok -> write_u32(Ctx, NUsedPtr, byte_size(Bin));
                                _ -> {errno, ?EFAULT}
                            end
                    end;
               (_) -> {errno, ?ENOTDIR}
            end);

handle(fd_fdstat_get, Ctx, [Fd, OutPtr], _Config, St) ->
    case fd_lookup(St, Fd) of
        error -> {errno, ?EBADF};
        {ok, E} ->
            Flags = fdflags(E),
            Bin = <<(E#wasi_fd.filetype):8, 0:8, Flags:16/little, 0:32,
                    (E#wasi_fd.rights):64/little,
                    (E#wasi_fd.rights_inheriting):64/little>>,
            write_mem(Ctx, OutPtr, Bin)
    end;

%% Narrowing only. A descriptor may give rights up and may never gain one it
%% does not hold, which is the whole point of the field: a guest hands a
%% narrowed descriptor to a component it trusts less. Asking for a bit that is
%% not there is `ENOTCAPABLE' rather than a silent clamp, so a caller finds out.
handle(fd_fdstat_set_rights, _Ctx, [Fd, Base, Inheriting], _Config, St) ->
    case fd_lookup(St, Fd) of
        error -> {errno, ?EBADF};
        {ok, #wasi_fd{rights = R, rights_inheriting = I} = E} ->
            case (Base band bnot R) =/= 0 orelse (Inheriting band bnot I) =/= 0 of
                true -> {errno, ?ENOTCAPABLE};
                false ->
                    {errno, ?ESUCCESS,
                     fd_put(St, Fd, E#wasi_fd{rights = Base,
                                              rights_inheriting = Inheriting})}
            end
    end;

%% Only `NONBLOCK', and only on sockets. A file ignores it because a local read
%% does not block long enough for the distinction to mean anything, and the
%% sync flags are accepted and ignored as they always were.
handle(fd_fdstat_set_flags, _Ctx, [Fd, Flags], _Config, St) ->
    case fd_lookup(St, Fd) of
        error -> {errno, ?EBADF};
        {ok, #wasi_fd{type = socket} = E} ->
            NonBlock = (Flags band ?FDFLAGS_NONBLOCK) =/= 0,
            {errno, ?ESUCCESS, fd_put(St, Fd, E#wasi_fd{nonblock = NonBlock})};
        {ok, #wasi_fd{} = E} ->
            %% Append and the sync flags are what a file can carry. They are
            %% recorded rather than acted on, and reading them back is what a
            %% guest checks.
            Append = (Flags band ?FDFLAGS_APPEND) =/= 0,
            {errno, ?ESUCCESS,
             fd_put(St, Fd, E#wasi_fd{append = Append,
                                      syncflags = Flags band ?SYNCFLAGS})}
    end;

handle(fd_filestat_get, Ctx, [Fd, OutPtr], _Config, St) ->
    with_fd(St, Fd, ?RIGHT_FD_FILESTAT_GET,
            fun(#wasi_fd{type = file, handle = H} = E) ->
                    %% Stat the descriptor rather than reporting its size and
                    %% nothing else, or every file shares an inode.
                    case wasi_fs:stat_fd(H) of
                        {ok, Info} ->
                            write_mem(Ctx, OutPtr,
                                      filestat(E#wasi_fd.filetype, Info));
                        {error, Err} -> {errno, Err}
                    end;
               %% A directory has no handle, but it does have the root it was
               %% opened as, so `.' against that is its own stat. Reporting a
               %% bare zero here made `fd_readdir' disagree with itself: the
               %% entry for "." carried the real inode and the directory's own
               %% filestat carried none.
               (#wasi_fd{type = dir, root = Root} = E) when Root =/= undefined ->
                    case wasi_fs:stat(Root, ~".") of
                        {ok, Info} ->
                            write_mem(Ctx, OutPtr,
                                      filestat(E#wasi_fd.filetype, Info));
                        {error, Err} -> {errno, Err}
                    end;
               %% A socket or a stream. Nothing to stat, so the filetype is all
               %% this can honestly report.
               (E) ->
                    write_mem(Ctx, OutPtr, filestat_bare(E#wasi_fd.filetype))
            end);

handle(Sync, _Ctx, [_Fd], _Config, _St)
  when Sync =:= fd_sync; Sync =:= fd_datasync ->
    {errno, ?ESUCCESS};

%%% ------------------------------------------------------------- preopens ---

%% `fd_prestat_get' and `fd_prestat_dir_name' are how a module discovers which
%% directories it was granted. It learns the *guest* path only; the host path
%% behind it is never exposed.
%% A preopened socket answers `ENOTDIR', not `EBADF'. wasi-libc discovers
%% preopens by walking descriptors upward until one answers `EBADF', treating
%% `ENOTDIR' as "not a directory, keep going". Answering `EBADF' here would end
%% the walk at the first listener and hide every directory behind it.
handle(fd_prestat_get, Ctx, [Fd, OutPtr], _Config, St) ->
    case fd_lookup(St, Fd) of
        {ok, #wasi_fd{preopen = true, type = socket}} ->
            {errno, ?ENOTDIR};
        {ok, #wasi_fd{preopen = true, guest_path = G}} ->
            write_mem(Ctx, OutPtr,
                      <<?PREOPENTYPE_DIR:8, 0:24, (byte_size(G)):32/little>>);
        _ -> {errno, ?EBADF}
    end;
handle(fd_prestat_dir_name, Ctx, [Fd, PathPtr, PathLen], _Config, St) ->
    case fd_lookup(St, Fd) of
        {ok, #wasi_fd{preopen = true, type = socket}} ->
            {errno, ?ENOTDIR};
        {ok, #wasi_fd{preopen = true, guest_path = G}}
          when byte_size(G) =< PathLen ->
            write_mem(Ctx, PathPtr, G);
        {ok, #wasi_fd{preopen = true}} -> {errno, ?ENAMETOOLONG};
        _ -> {errno, ?EBADF}
    end;

%%% ----------------------------------------------------------- path syscalls ---

handle(path_open, Ctx,
       [DirFd, DirFlags, PathPtr, PathLen, OFlags, RightsBase, _RightsInh,
        FdFlags, OutFdPtr],
       _Config, St) ->
    with_dir(St, DirFd,
             fun(#wasi_fd{host_path = Path, root = Root,
                          rights = Own, rights_inheriting = Inh}) ->
                 case read_path(Ctx, PathPtr, PathLen) of
                     {error, E} -> {errno, E};
                     {ok, Guest} ->
                         %% Requested rights are masked against what the
                         %% preopen passes down, so a read-only grant stays
                         %% read-only no matter what the module asks for.
                         Rights = RightsBase band Inh,
                         %% Preview 1 gives the caller the choice about the
                         %% final component, and only that one. Opening a
                         %% symlink without asking to follow it is `ELOOP',
                         %% which is what `nofollow_errors' and
                         %% `dangling_symlink' both assert.
                         Follow = (DirFlags band ?LOOKUPFLAGS_SYMLINK_FOLLOW)
                                      =/= 0,
                         case trailing_slash_ok(Root, Guest) of
                             {error, E} -> {errno, E};
                             ok ->
                                 open_at(Ctx, Path, Root, Guest, OFlags,
                                         FdFlags, Rights, Inh, Own, Follow,
                                         OutFdPtr, St)
                         end
                 end
             end);

handle(path_filestat_get, Ctx, [DirFd, Flags, PathPtr, PathLen, OutPtr],
       _Config, St) ->
    with_dir(St, DirFd,
             fun(#wasi_fd{root = Root}) ->
                 case read_path(Ctx, PathPtr, PathLen) of
                     {error, E} -> {errno, E};
                     {ok, Guest} ->
                         case wasi_fs:stat(Root, Guest, lookup(Flags)) of
                             {error, E} -> {errno, E};
                             {ok, Info} ->
                                 write_mem(Ctx, OutPtr, stat_to_filestat(Info))
                         end
                 end
             end);

%% Rename takes two capability-scoped paths, and both are resolved against
%% their own preopen. Resolving only one would let a module move a file out of
%% the sandbox by naming the destination carelessly.
handle(path_rename, Ctx, [OldFd, OldPtr, OldLen, NewFd, NewPtr, NewLen],
       _Config, St) ->
    two_paths(Ctx, St, {OldFd, OldPtr, OldLen}, {NewFd, NewPtr, NewLen},
              ?RIGHT_PATH_UNLINK_FILE,
              fun(RA, GA, RB, GB) -> wasi_fs:rename(RA, GA, RB, GB) end);

%% The *target* of a symlink is not resolved here: it is data, stored verbatim,
%% and checked when something later tries to follow it. `wasi_path' refuses to
%% traverse a symlink that leaves the preopen, so a module can create a
%% dangling or escaping link but can never read through one.
handle(path_symlink, Ctx, [TargetPtr, TargetLen, DirFd, PathPtr, PathLen],
       _Config, St) ->
    with_dir(St, DirFd,
             fun(#wasi_fd{root = Root, rights_inheriting = Inh}) ->
                 case (Inh band ?RIGHT_PATH_CREATE_FILE) =:= 0 of
                     true -> {errno, ?ENOTCAPABLE};
                     false ->
                         maybe
                             {ok, Target} ?= read_path(Ctx, TargetPtr, TargetLen),
                             {ok, Guest} ?= read_path(Ctx, PathPtr, PathLen),
                             ok ?= trailing_slash_ok(Root, Guest),
                             %% An absolute target names something outside the
                             %% preopen by construction, and creating a link
                             %% nothing may ever follow is not a service to
                             %% anybody. Refused at creation, where the guest
                             %% can still do something about it.
                             ok ?= case Target of
                                       <<$/, _/binary>> -> {error, ?ENOTCAPABLE};
                                       _ -> ok
                                   end,
                             fs_errno(wasi_fs:symlink(Root, Guest, Target))
                         else
                             {error, E} -> {errno, E}
                         end
                 end
             end);

handle(path_readlink, Ctx, [DirFd, PathPtr, PathLen, Buf, BufLen, NUsedPtr],
       _Config, St) ->
    with_dir(St, DirFd,
             fun(#wasi_fd{root = Root}) ->
                 maybe
                     {ok, Guest} ?= read_path(Ctx, PathPtr, PathLen),
                     {ok, Target} ?= wasi_fs:readlink(Root, Guest),
                     Out = binary:part(Target, 0,
                                       erlang:min(byte_size(Target), BufLen)),
                     case wasm:write_memory(Ctx, wasm_num:to_u32(Buf), Out) of
                         ok -> write_u32(Ctx, NUsedPtr, byte_size(Out));
                         _ -> {errno, ?EFAULT}
                     end
                 else
                     {error, E} -> {errno, E}
                 end
             end);

%% `LOOKUPFLAGS_SYMLINK_FOLLOW' is refused rather than ignored. `path_link' on a
%% symlink links the link itself here, and a guest that asked for the target and
%% silently got the link would find out much later.
handle(path_link, _Ctx, [_OldFd, Flags, _OldPtr, _OldLen, _NewFd, _NewPtr,
                         _NewLen], _Config, _St)
  when (Flags band ?LOOKUPFLAGS_SYMLINK_FOLLOW) =/= 0 ->
    {errno, ?EINVAL};
handle(path_link, Ctx, [OldFd, _Flags, OldPtr, OldLen, NewFd, NewPtr, NewLen],
       _Config, St) ->
    two_paths(Ctx, St, {OldFd, OldPtr, OldLen}, {NewFd, NewPtr, NewLen},
              ?RIGHT_PATH_CREATE_FILE,
              fun(RA, GA, RB, GB) -> wasi_fs:link(RA, GA, RB, GB) end);

handle(path_create_directory, Ctx, [DirFd, PathPtr, PathLen], _Config, St) ->
    mutate_path(Ctx, St, DirFd, PathPtr, PathLen, ?RIGHT_PATH_CREATE_DIRECTORY,
                fun(Root, Guest) -> wasi_fs:mkdir(Root, Guest) end, any_slash);
handle(path_unlink_file, Ctx, [DirFd, PathPtr, PathLen], _Config, St) ->
    mutate_path(Ctx, St, DirFd, PathPtr, PathLen, ?RIGHT_PATH_UNLINK_FILE,
                fun(Root, Guest) -> wasi_fs:unlink(Root, Guest) end);
handle(path_remove_directory, Ctx, [DirFd, PathPtr, PathLen], _Config, St) ->
    mutate_path(Ctx, St, DirFd, PathPtr, PathLen, ?RIGHT_PATH_REMOVE_DIRECTORY,
                fun(Root, Guest) -> wasi_fs:rmdir(Root, Guest) end);

%%% ---------------------------------------------------------------- process ---

%% `proc_exit' does not return. It becomes a trap carrying the status, which is
%% the only way to unwind a WebAssembly stack, and `exit_code/1' recovers the
%% status from the error the embedder receives.
handle(proc_exit, _Ctx, [Code], _Config, _St) ->
    {trap, {host_error, {wasi_exit, Code}}, #{wasi_exit => Code}};

handle(sched_yield, _Ctx, [], _Config, _St) ->
    {errno, ?ESUCCESS};

%% Clock subscriptions are what `thread::sleep` and timeouts use. Socket
%% readiness is real; file readiness still returns `ENOSYS`, because telling a
%% module a file is ready when that cannot be known produces misbehaviour which
%% is very hard to trace back here, and a truthful refusal is more useful.
handle(poll_oneoff, Ctx, [InPtr, OutPtr, NSubs, NEventsPtr], Config, St) ->
    case read_subscriptions(Ctx, InPtr, NSubs) of
        {error, E} ->
            {errno, E};
        {ok, Subs} ->
            Clocks = [S || {clock, _, _} = S <- Subs], Fds = [S || {fd, _, _, _} = S <- Subs], case length(Clocks) + length(Fds) =:= length(Subs) of
                false -> {errno, ?EINVAL};
                true -> poll(Ctx, OutPtr, NEventsPtr, Clocks, Fds, Config, St)
            end
    end;

%%% ---------------------------------------------------------------- sockets ---
%%
%% Preview 1 standardised four socket calls, and all four assume the socket
%% already exists: the host opens it and hands it in. A module using only these
%% never names an address, which is why they need no capability check of their
%% own beyond the descriptor they were given. Opening sockets from inside the
%% module is the extension, and lives further down.

handle(sock_accept, Ctx, [Fd, _FdFlags, OutFdPtr], Config, St) ->
    with_socket(St, Fd, ?RIGHT_SOCK_ACCEPT,
                fun(Entry) ->
                    case at_socket_limit(St, Config) of
                        true -> {errno, ?EMFILE};
                        false -> accept_into(Ctx, Entry, OutFdPtr, Config, St)
                    end
                end);

%% The accepted peer is not checked against the `connect' rules. Inbound is not
%% outbound: the listener was granted, and whoever reaches it was always able
%% to. Filtering here would be security theatre over a socket the host opened.
handle(sock_recv, Ctx, [Fd, IovsPtr, IovsLen, RiFlags, RoLenPtr, RoFlagsPtr],
       Config, St) ->
    with_socket(St, Fd, ?RIGHT_FD_READ,
                fun(Entry) ->
                    case (RiFlags band ?RIFLAGS_RECV_PEEK) =/= 0 of
                        %% Peeking would need a socket that can un-read, which
                        %% `gen_tcp' has no way to express. Refusing is better
                        %% than consuming what the module asked to leave.
                        true -> {errno, ?ENOTSUP};
                        false ->
                            sock_read(Ctx, Entry, Fd, IovsPtr, IovsLen, RiFlags,
                                      RoLenPtr, RoFlagsPtr, Config, St)
                    end
                end);

handle(sock_send, Ctx, [Fd, IovsPtr, IovsLen, _SiFlags, OutPtr], _Config, St) ->
    with_socket(St, Fd, ?RIGHT_FD_WRITE,
                fun(#wasi_fd{handle = H}) ->
                    case read_iovecs(Ctx, IovsPtr, IovsLen) of
                        {error, E} -> {errno, E};
                        {ok, Data} ->
                            case wasi_sock:send(H, Data) of
                                ok -> write_u32(Ctx, OutPtr, byte_size(Data));
                                {error, E} -> {errno, E}
                            end
                    end
                end);

handle(sock_shutdown, _Ctx, [Fd, How], _Config, St) ->
    with_socket(St, Fd, ?RIGHT_SOCK_SHUTDOWN,
                fun(#wasi_fd{handle = H}) ->
                    case wasi_sock:shutdown(H, How) of
                        ok -> {errno, ?ESUCCESS};
                        {error, E} -> {errno, E}
                    end
                end);

%%% ------------------------------------------------- sockets: the extension ---
%%
%% Preview 1 has no way for a module to open a socket, so there is no
%% standardised client. What follows is the extension WasmEdge defined and
%% `wasmedge_wasi_socket' compiles against, bound under the same module name.
%% It is not part of the specification, and `docs/wasi.md' says so.
%%
%% Every call that names an address checks it against the grant before it
%% reaches a socket, and the address it checks is the one it then uses.

%% A descriptor with a family and a type, and nothing open behind it. An
%% instance with no network at all does not get one: a descriptor it can do
%% nothing with is a slower way of saying `ENOTCAPABLE'.
handle(sock_open, Ctx, [Family, Type, OutFdPtr], Config, St) ->
    case wasi_net:max_sockets(net(Config)) of
        0 ->
            {errno, ?ENOTCAPABLE};
        _ ->
            case {address_family(Family), socket_type(Type)} of
                {error, _} -> {errno, ?EAFNOSUPPORT};
                {_, error} -> {errno, ?EPROTONOSUPPORT};
                {Fam, Kind} ->
                    case at_socket_limit(St, Config) of
                        true -> {errno, ?EMFILE};
                        false ->
                            {ok, H} = wasi_sock:open(Fam, Kind),
                            %% A socket the module opened may become a
                            %% listener. What stops it is the grant, not the
                            %% right.
                            add_socket(Ctx, H, ?RIGHTS_LISTENER, OutFdPtr, St)
                    end
            end
    end;

%% Binding claims a local address, which is what `listen' grants. A client that
%% wants a particular source port therefore needs a `listen' rule for it: that
%% is stricter than POSIX, and it is the only reading under which "which
%% addresses may this instance occupy" has one answer.
handle(sock_bind, Ctx, [Fd, AddrPtr, Port], Config, St) ->
    with_endpoint(Ctx, St, Fd, AddrPtr, Port, listen, Config,
                  fun(H, Endpoint) -> wasi_sock:bind(H, Endpoint) end);

handle(sock_listen, _Ctx, [Fd, Backlog], _Config, St) ->
    with_socket(St, Fd, ?RIGHT_SOCK_ACCEPT,
                fun(#wasi_fd{handle = H}) ->
                    case wasi_sock:listen(H, wasm_num:to_u32(Backlog)) of
                        {error, E} -> {errno, E};
                        {ok, H1} -> {errno, ?ESUCCESS, fd_set_handle(St, Fd, H1)}
                    end
                end);

handle(sock_connect, Ctx, [Fd, AddrPtr, Port], Config, St) ->
    with_endpoint(Ctx, St, Fd, AddrPtr, Port, connect, Config,
                  fun(H, Endpoint) ->
                      wasi_sock:connect(H, Endpoint, net_timeout(Config))
                  end);

%% The extension's `sock_accept' takes two arguments where Preview 1's takes
%% three. A host function adopts whatever signature the importing module
%% declared, so both forms work and a module compiled against either links.
handle(sock_accept, Ctx, [Fd, OutFdPtr], Config, St) ->
    handle(sock_accept, Ctx, [Fd, 0, OutFdPtr], Config, St);

handle(sock_send_to, Ctx, [Fd, IovsPtr, IovsLen, AddrPtr, Port, _Flags, OutPtr],
       Config, St) ->
    with_socket(St, Fd, ?RIGHT_FD_WRITE,
                fun(#wasi_fd{handle = H}) ->
                    maybe
                        {ok, Addr} ?= raw_address(Ctx, AddrPtr, H),
                        Endpoint = {udp, Addr, wasm_num:to_u32(Port)},
                        true ?= wasi_net:allows(connect, Endpoint, net(Config)),
                        {ok, Data} ?= read_iovecs(Ctx, IovsPtr, IovsLen),
                        {ok, H1} ?= wasi_sock:send_to(H, Data, Endpoint),
                        St1 = fd_set_handle(St, Fd, H1),
                        case write_u32(Ctx, OutPtr, byte_size(Data)) of
                            {errno, ?ESUCCESS} -> {errno, ?ESUCCESS, St1};
                            Other -> Other
                        end
                    else
                        false -> {errno, ?ENOTCAPABLE};
                        {error, E} -> {errno, E}
                    end
                end);

%% Where a datagram came from is reported, not filtered. The socket was bound
%% under a `listen' grant and anything that can reach it already has.
handle(sock_recv_from, Ctx,
       [Fd, IovsPtr, IovsLen, AddrPtr, _Flags, PortPtr, RoLenPtr, RoFlagsPtr],
       Config, St) ->
    with_socket(St, Fd, ?RIGHT_FD_READ,
                fun(#wasi_fd{handle = H} = Entry) ->
                    maybe
                        {ok, Specs} ?= iovec_specs(Ctx, IovsPtr, IovsLen),
                        Total = lists:sum([L || {_, L} <- Specs]), {ok, Data, {From, Port}} ?=
                            wasi_sock:recv_from(H, Total,
                                                read_timeout(Entry, Config)),
                        Take = erlang:min(Total, byte_size(Data)),
                        <<Chunk:Take/binary, _/binary>> = Data,
                        ok = scatter(Ctx, Specs, Chunk),
                        %% A datagram that does not fit is truncated and the
                        %% rest of it is gone. Saying so is the difference
                        %% between a short read and a corrupt message.
                        Flags = case byte_size(Data) > Total of
                                    true -> ?ROFLAGS_RECV_DATA_TRUNCATED;
                                    false -> 0
                                end,
                        ok ?= write_raw_address(Ctx, AddrPtr, From, H),
                        {errno, ?ESUCCESS} ?= write_u32(Ctx, PortPtr, Port),
                        {errno, ?ESUCCESS} ?= write_u32(Ctx, RoLenPtr, Take),
                        write_u32(Ctx, RoFlagsPtr, Flags)
                    else
                        {error, E} -> {errno, E};
                        {errno, _} = Errno -> Errno
                    end
                end);

handle(sock_getlocaladdr, Ctx, [Fd, AddrPtr, TypePtr, PortPtr], _Config, St) ->
    with_socket(St, Fd, ?RIGHT_FD_FILESTAT_GET,
                fun(#wasi_fd{handle = H}) ->
                    emit_address(Ctx, wasi_sock:local(H), AddrPtr, TypePtr, PortPtr)
                end);

handle(sock_getpeeraddr, Ctx, [Fd, AddrPtr, TypePtr, PortPtr], _Config, St) ->
    with_socket(St, Fd, ?RIGHT_FD_FILESTAT_GET,
                fun(#wasi_fd{handle = H}) ->
                    emit_address(Ctx, wasi_sock:peer(H), AddrPtr, TypePtr, PortPtr)
                end);

%% Only `SOL_SOCKET` exists here. An option that cannot be honoured is refused
%% rather than accepted and dropped: a module that believes it set a timeout
%% and did not will find out at the worst possible moment.
handle(sock_getsockopt, Ctx, [Fd, Level, Name, FlagPtr, SizePtr], _Config, St) ->
    with_socket(St, Fd, ?RIGHT_FD_FILESTAT_GET,
                fun(#wasi_fd{handle = H}) ->
                    case Level =:= ?SOL_SOCKET of
                        false -> {errno, ?ENOPROTOOPT};
                        true ->
                            case wasi_sock:getopt(H, Name) of
                                {error, E} -> {errno, E};
                                {ok, Value} ->
                                    case write_u32(Ctx, FlagPtr, Value) of
                                        {errno, ?ESUCCESS} ->
                                            write_u32(Ctx, SizePtr, 4);
                                        Other -> Other
                                    end
                            end
                    end
                end);

handle(sock_setsockopt, Ctx, [Fd, Level, Name, FlagPtr, Size], _Config, St) ->
    with_socket(St, Fd, ?RIGHT_FD_FDSTAT_SET_FLAGS,
                fun(#wasi_fd{handle = H}) ->
                    case Level =:= ?SOL_SOCKET andalso Size >= 4 of
                        false -> {errno, ?ENOPROTOOPT};
                        true ->
                            case wasm:read_memory(Ctx, wasm_num:to_u32(FlagPtr), 4) of
                                {ok, <<Value:32/little-signed>>} ->
                                    case wasi_sock:setopt(H, Name, Value) of
                                        ok -> {errno, ?ESUCCESS};
                                        {error, E} -> {errno, E}
                                    end;
                                _ -> {errno, ?EFAULT}
                            end
                    end
                end);

%% Resolution is its own capability and is off unless granted. Its answers get
%% no authority from having been resolved: a module may learn an address it
%% cannot reach, and `sock_connect' refuses it then, on the address itself.
handle(sock_getaddrinfo, Ctx,
       [NodePtr, NodeLen, ServicePtr, ServiceLen, HintPtr, ResPtr, MaxLen,
        ResLenPtr], Config, _St) ->
    case wasi_net:resolves(net(Config)) of
        false -> {errno, ?ENOTCAPABLE};
        true ->
            resolve_into(Ctx, {NodePtr, NodeLen}, {ServicePtr, ServiceLen},
                         HintPtr, ResPtr, wasm_num:to_u32(MaxLen), ResLenPtr)
    end;

handle(_Name, _Ctx, _Args, _Config, _St) ->
    {errno, ?ENOSYS}.

%%% ----------------------------------------------------------- socket helper ---

accept_into(Ctx, #wasi_fd{handle = H} = Entry, OutFdPtr, Config, St) ->
    case wasi_sock:accept(H, read_timeout(Entry, Config)) of
        {error, E} -> {errno, E};
        {ok, Conn} ->
            %% An accepted socket cannot itself accept, so it does not carry
            %% the right. A module that tries gets `ENOTCAPABLE'.
            Accepted = #wasi_fd{type = socket,
                                filetype = ?FILETYPE_SOCKET_STREAM,
                                rights = ?RIGHTS_SOCKET,
                                rights_inheriting = ?RIGHTS_SOCKET,
                                handle = Conn},
            {NewFd, St1} = fd_add(St, Accepted),
            emit_fd(Ctx, OutFdPtr, NewFd, St1)
    end.

%% A stream read returns whatever has arrived, which can be more than the
%% module's buffers hold, so the excess is kept against the next read. `buffer'
%% is drained first for the same reason.
sock_read(Ctx, #wasi_fd{handle = H, buffer = Buf} = Entry, Fd, IovsPtr, IovsLen,
          RiFlags, RoLenPtr, RoFlagsPtr, Config, St) ->
    case iovec_specs(Ctx, IovsPtr, IovsLen) of
        {error, E} -> {errno, E};
        {ok, Specs} ->
            Total = lists:sum([L || {_, L} <- Specs]), case fill(H, Buf, Total, RiFlags, read_timeout(Entry, Config)) of
                {error, E} -> {errno, E};
                {ok, Data} ->
                    Take = erlang:min(Total, byte_size(Data)),
                    <<Chunk:Take/binary, Rest/binary>> = Data,
                    ok = scatter(Ctx, Specs, Chunk),
                    St1 = fd_set_buffer(St, Fd, Rest),
                    case write_u32(Ctx, RoLenPtr, Take) of
                        {errno, ?ESUCCESS} ->
                            case roflags(Ctx, RoFlagsPtr) of
                                {errno, ?ESUCCESS} -> {errno, ?ESUCCESS, St1};
                                Other -> Other
                            end;
                        Other -> Other
                    end
            end
    end.

%% `RECV_WAITALL` asks for the whole request or nothing, which is exactly what
%% `gen_tcp:recv/3` does when given a length.
fill(_H, Buf, Total, _RiFlags, _Timeout) when byte_size(Buf) >= Total, Total > 0 ->
    {ok, Buf};
fill(_H, Buf, 0, _RiFlags, _Timeout) ->
    {ok, Buf};
fill(H, Buf, Total, RiFlags, Timeout) ->
    Want = case (RiFlags band ?RIFLAGS_RECV_WAITALL) =/= 0 of
               true -> Total - byte_size(Buf); false -> 0
           end,
    case wasi_sock:recv(H, Want, Timeout) of
        %% End of stream is zero bytes read, not an error: it is how a module
        %% learns the peer is done.
        eof -> {ok, Buf};
        {ok, Data} -> {ok, <<Buf/binary, Data/binary>>};
        {error, E} when Buf =/= <<>>, E =:= ?EAGAIN -> {ok, Buf};
        {error, E} -> {error, E}
    end.

%% `fd_read' has no roflags word to write; `sock_recv' does. Nothing here ever
%% sets one, because the only flag defined says a datagram was truncated and
%% these are streams.
roflags(_Ctx, none) -> {errno, ?ESUCCESS};
roflags(Ctx, Ptr) -> write_u32(Ctx, Ptr, 0).

fdflags(#wasi_fd{append = Append, nonblock = NonBlock, syncflags = Sync}) ->
    (case Append of true -> ?FDFLAGS_APPEND; false -> 0 end) bor
    (case NonBlock of true -> ?FDFLAGS_NONBLOCK; false -> 0 end) bor
    Sync.

%% A non-blocking socket does not wait: a read with nothing there is `EAGAIN',
%% which is what a program built around `poll_oneoff' expects to see.
read_timeout(#wasi_fd{nonblock = true}, _Config) -> 0;
read_timeout(_Entry, Config) -> net_timeout(Config).

fd_put(#{fds := Fds} = St, Fd, Entry) -> St#{fds := maps:put(Fd, Entry, Fds)}.

with_socket(St, Fd, Right, Fun) ->
    case fd_lookup(St, Fd) of
        error -> {errno, ?EBADF};
        {ok, #wasi_fd{type = socket} = E} ->
            case (E#wasi_fd.rights band Right) =/= 0 of
                true -> Fun(E);
                false -> {errno, ?ENOTCAPABLE}
            end;
        {ok, _} -> {errno, ?ENOTSOCK}
    end.

%% Descriptors are capped for the reason the node page budget exists: without a
%% cap, a module opens sockets until the node runs out of them. Listeners the
%% host opened count, because they are sockets this instance is holding.
at_socket_limit(#{fds := Fds}, Config) ->
    Open = length([E || E <- maps:values(Fds), E#wasi_fd.type =:= socket]),
    Open >= wasi_net:max_sockets(maps:get(net, Config, none)).

net_timeout(Config) -> wasi_net:timeout(net(Config)).

net(Config) -> maps:get(net, Config, none).

fd_set_buffer(#{fds := Fds} = St, Fd, Buf) ->
    case maps:find(Fd, Fds) of
        {ok, E} -> St#{fds := maps:put(Fd, E#wasi_fd{buffer = Buf}, Fds)};
        error -> St
    end.

%% Binding, connecting and listening replace the handle behind a descriptor:
%% the descriptor number a module holds does not change, but what is behind it
%% does, from nothing to an open socket.
fd_set_handle(#{fds := Fds} = St, Fd, H) ->
    case maps:find(Fd, Fds) of
        {ok, E} ->
            St#{fds := maps:put(Fd, E#wasi_fd{handle = H,
                                              filetype = wasi_sock:filetype(H)},
                                Fds)};
        error -> St
    end.

add_socket(Ctx, Handle, Rights, OutFdPtr, St) ->
    Entry = #wasi_fd{type = socket, filetype = wasi_sock:filetype(Handle),
                     rights = Rights, rights_inheriting = ?RIGHTS_SOCKET,
                     handle = Handle},
    {Fd, St1} = fd_add(St, Entry),
    emit_fd(Ctx, OutFdPtr, Fd, St1).

address_family(?ADDRESS_FAMILY_INET4) -> inet;
address_family(?ADDRESS_FAMILY_INET6) -> inet6;
address_family(_Other) -> error.

socket_type(?SOCK_TYPE_STREAM) -> stream;
socket_type(?SOCK_TYPE_DGRAM) -> dgram;
%% `SOCK_ANY' asks the host to choose, and there is no basis on which to.
socket_type(_Other) -> error.

%% Read an address, check it against the grant, and only then act on it. The
%% address that was checked is the one handed on, which is the whole point:
%% nothing between the two can substitute a different destination.
with_endpoint(Ctx, St, Fd, AddrPtr, Port, Kind, Config, Fun) ->
    case fd_lookup(St, Fd) of
        error ->
            {errno, ?EBADF};
        {ok, #wasi_fd{type = socket, handle = H}} ->
            maybe
                {ok, Addr} ?= read_wasi_address(Ctx, AddrPtr),
                Endpoint = {protocol_of(H), Addr, wasm_num:to_u32(Port)},
                true ?= wasi_net:allows(Kind, Endpoint, net(Config)),
                {ok, H1} ?= Fun(H, Endpoint),
                {errno, ?ESUCCESS, fd_set_handle(St, Fd, H1)}
            else
                false -> {errno, ?ENOTCAPABLE};
                {error, E} -> {errno, E}
            end;
        {ok, _} ->
            {errno, ?ENOTSOCK}
    end.

protocol_of(Handle) ->
    case wasi_sock:type(Handle) of
        stream -> tcp;
        dgram -> udp
    end.

%%% ------------------------------------------------------ socket addresses ---
%%
%% `__wasi_address_t' is a pointer and a length, and the length is how the
%% family is told: 4 octets is IPv4 and 16 is IPv6. `sock_send_to' and
%% `sock_recv_from' pass the octets directly with no length at all, so there
%% the socket's own family decides how many bytes are there.

read_wasi_address(Ctx, Ptr) ->
    case wasm:read_memory(Ctx, wasm_num:to_u32(Ptr), ?ADDRESS_SIZE) of
        {ok, <<Buf:32/little, Len:32/little>>} -> read_octets(Ctx, Buf, Len);
        _ -> {error, ?EFAULT}
    end.

read_octets(Ctx, Buf, 4) ->
    case wasm:read_memory(Ctx, Buf, 4) of
        {ok, <<A, B, C, D>>} -> {ok, {A, B, C, D}};
        _ -> {error, ?EFAULT}
    end;
read_octets(Ctx, Buf, 16) ->
    case wasm:read_memory(Ctx, Buf, 16) of
        {ok, <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>>} ->
            %% Folded here, so an IPv4-mapped address is checked, and then
            %% reached, as the IPv4 address it is.
            {ok, wasi_net:normalise({A, B, C, D, E, F, G, H})};
        _ -> {error, ?EFAULT}
    end;
read_octets(_Ctx, _Buf, _Len) ->
    {error, ?EAFNOSUPPORT}.

write_wasi_address(Ctx, Ptr, Addr) ->
    Bytes = octets(Addr),
    case wasm:read_memory(Ctx, wasm_num:to_u32(Ptr), ?ADDRESS_SIZE) of
        {ok, <<Buf:32/little, Len:32/little>>} when Len >= byte_size(Bytes) ->
            case wasm:write_memory(Ctx, Buf, Bytes) of
                ok -> write_u32(Ctx, wasm_num:to_u32(Ptr) + 4, byte_size(Bytes));
                _ -> {errno, ?EFAULT}
            end;
        {ok, _Short} ->
            %% The module's buffer cannot hold an address of this family.
            {errno, ?EINVAL};
        _ ->
            {errno, ?EFAULT}
    end.

raw_address(Ctx, Ptr, Handle) ->
    Len = case wasi_sock:family(Handle) of inet -> 4; inet6 -> 16 end,
    read_octets(Ctx, wasm_num:to_u32(Ptr), Len).

%% Written back at the width the socket's family implies, so a v4 peer seen
%% through a v6 socket is written in the mapped form the module is expecting.
write_raw_address(Ctx, Ptr, Addr, Handle) ->
    Bytes = case {wasi_sock:family(Handle), tuple_size(Addr)} of
                {inet6, 4} -> mapped_octets(Addr);
                {_, _} -> octets(Addr)
            end,
    case wasm:write_memory(Ctx, wasm_num:to_u32(Ptr), Bytes) of
        ok -> ok;
        _ -> {error, ?EFAULT}
    end.

emit_address(_Ctx, {error, E}, _AddrPtr, _TypePtr, _PortPtr) ->
    {errno, E};
emit_address(Ctx, {ok, {Addr, Port}}, AddrPtr, TypePtr, PortPtr) ->
    maybe
        {errno, ?ESUCCESS} ?= write_wasi_address(Ctx, AddrPtr, Addr),
        {errno, ?ESUCCESS} ?= write_u32(Ctx, TypePtr, family_constant(Addr)),
        write_u32(Ctx, PortPtr, Port)
    end.

octets({A, B, C, D}) -> <<A, B, C, D>>;
octets({A, B, C, D, E, F, G, H}) ->
    <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>>.

mapped_octets({A, B, C, D}) -> <<0:80, 16#ffff:16, A, B, C, D>>.

family_constant(Addr) when tuple_size(Addr) =:= 4 -> ?ADDRESS_FAMILY_INET4;
family_constant(_Addr) -> ?ADDRESS_FAMILY_INET6.

%%% ------------------------------------------------------------ resolution ---
%%
%% The guest allocates everything: an array of pointers to `__wasi_addrinfo_t',
%% each with a `__wasi_sockaddr_t' and a buffer behind it. The host fills them
%% in and says how many it used. Offsets are the ones WasmEdge's static asserts
%% fix, and are written out rather than named because getting one wrong reads
%% as plausible garbage rather than as an error.

resolve_into(Ctx, Node, Service, HintPtr, ResPtr, MaxLen, ResLenPtr) ->
    maybe
        {ok, Name} ?= read_name(Ctx, Node),
        {ok, ServiceName} ?= read_name(Ctx, Service),
        true ?= Name =/= <<>>,
        {ok, Families} ?= hint_families(Ctx, HintPtr),
        {ok, Port} ?= service_port(ServiceName),
        Addrs = lists:sublist(resolve(Name, Families), MaxLen),
        {ok, Slots} ?= result_slots(Ctx, ResPtr, length(Addrs)),
        ok ?= fill_addrinfo(Ctx, lists:zip(Slots, Addrs), Port),
        write_u32(Ctx, ResLenPtr, length(Addrs))
    else
        %% An empty node has nothing to resolve. The passive form, where a
        %% null node means "bind to everything", has no meaning here: a
        %% listener's address comes from the grant, never from a lookup.
        false -> {errno, ?EINVAL};
        {error, E} -> {errno, E}
    end.

read_name(_Ctx, {_Ptr, 0}) ->
    {ok, <<>>};
read_name(Ctx, {Ptr, Len0}) ->
    Len = wasm_num:to_u32(Len0),
    case Len > 255 of
        true -> {error, ?ENAMETOOLONG};
        false ->
            case wasm:read_memory(Ctx, wasm_num:to_u32(Ptr), Len) of
                %% A trailing NUL is tolerated: the length a caller passes is
                %% sometimes the buffer's rather than the string's.
                {ok, Bin} -> {ok, hd(binary:split(Bin, <<0>>))};
                _ -> {error, ?EFAULT}
            end
    end.

hint_families(_Ctx, 0) ->
    {ok, [inet, inet6]};
hint_families(Ctx, Ptr) ->
    case wasm:read_memory(Ctx, wasm_num:to_u32(Ptr), ?ADDRINFO_SIZE) of
        {ok, <<_Flags:16/little, Family:8, _/binary>>} ->
            case Family of
                ?ADDRESS_FAMILY_INET4 -> {ok, [inet]};
                ?ADDRESS_FAMILY_INET6 -> {ok, [inet6]};
                ?ADDRESS_FAMILY_UNSPEC -> {ok, [inet, inet6]};
                _ -> {error, ?EAFNOSUPPORT}
            end;
        _ ->
            {error, ?EFAULT}
    end.

%% A fixed table, and deliberately not `/etc/services'.
%%
%% Looking a name up needed `binary_to_atom/2' on a service string the *guest*
%% chose. The atom table is node-wide and never reclaimed, so a module calling
%% `sock_getaddrinfo' in a loop with names it made up minted a permanent atom
%% each time and killed the node at the default limit of about a million. That
%% is a guest reaching past its sandbox into the runtime, which is the one
%% thing none of the rest of this is allowed to permit.
%%
%% There is no non-atom form of `inet:getservbyname/2', so the lookup goes.
%% What replaces it covers the names a WASI guest plausibly asks for; anything
%% else is `EINVAL', and a numeric port always works. Say so in the
%% documentation rather than let somebody discover that an obscure entry in
%% their `/etc/services' is not honoured.
service_port(<<>>) ->
    {ok, 0};
service_port(Service) ->
    try {ok, binary_to_integer(Service)}
    catch _:_ -> known_service(Service)
    end.

known_service(<<"ftp">>) -> {ok, 21};
known_service(<<"ssh">>) -> {ok, 22};
known_service(<<"telnet">>) -> {ok, 23};
known_service(<<"smtp">>) -> {ok, 25};
known_service(<<"domain">>) -> {ok, 53};
known_service(<<"dns">>) -> {ok, 53};
known_service(<<"http">>) -> {ok, 80};
known_service(<<"pop3">>) -> {ok, 110};
known_service(<<"ntp">>) -> {ok, 123};
known_service(<<"imap">>) -> {ok, 143};
known_service(<<"snmp">>) -> {ok, 161};
known_service(<<"ldap">>) -> {ok, 389};
known_service(<<"https">>) -> {ok, 443};
known_service(<<"smtps">>) -> {ok, 465};
known_service(<<"submission">>) -> {ok, 587};
known_service(<<"ldaps">>) -> {ok, 636};
known_service(<<"imaps">>) -> {ok, 993};
known_service(<<"pop3s">>) -> {ok, 995};
known_service(<<"socks">>) -> {ok, 1080};
known_service(<<"mysql">>) -> {ok, 3306};
known_service(<<"rdp">>) -> {ok, 3389};
known_service(<<"postgresql">>) -> {ok, 5432};
known_service(<<"postgres">>) -> {ok, 5432};
known_service(<<"amqp">>) -> {ok, 5672};
known_service(<<"redis">>) -> {ok, 6379};
known_service(<<"http-alt">>) -> {ok, 8080};
known_service(<<"https-alt">>) -> {ok, 8443};
known_service(_Other) -> {error, ?EINVAL}.

%% Both families are asked separately rather than through one call, so an
%% instance hinting IPv4 gets IPv4 answers and nothing else.
resolve(Name, Families) ->
    Host = binary_to_list(Name),
    lists:usort(
      lists:flatmap(
        fun(Family) ->
            case inet:getaddrs(Host, Family) of
                {ok, Addrs} -> [wasi_net:normalise(A) || A <- Addrs]; {error, _} -> []
            end
        end, Families)).

result_slots(Ctx, ResPtr, Count) ->
    case wasm:read_memory(Ctx, wasm_num:to_u32(ResPtr), Count * 4) of
        {ok, Bin} -> {ok, [P || <<P:32/little>> <= Bin]};
        _ -> {error, ?EFAULT}
    end.

fill_addrinfo(_Ctx, [], _Port) ->
    ok;
fill_addrinfo(Ctx, [{Slot, Addr} | Rest], Port) ->
    Bytes = octets(Addr),
    Next = case Rest of
               [] -> 0;
               [{N, _} | _] -> N
           end,
    %% flags 0, family 2, socktype 3, protocol 4, addrlen 8, addr 12,
    %% canonname 16, canonname_len 20, next 24.
    Head = <<0:16/little, (family_constant(Addr)):8, ?SOCK_TYPE_STREAM:8,
             ?AI_PROTOCOL_TCP:8, 0:24, (byte_size(Bytes)):32/little>>,
    maybe
        ok ?= write_bytes(Ctx, Slot, Head),
        {ok, SockAddr} ?= read_u32(Ctx, Slot + 12),
        ok ?= fill_sockaddr(Ctx, SockAddr, Addr, Bytes, Port),
        ok ?= write_bytes(Ctx, Slot + 24, <<Next:32/little>>),
        fill_addrinfo(Ctx, Rest, Port)
    end.

%% The guest allocated the `sa_data' buffer and said how long it is, so the
%% address is written into what is there rather than over whatever follows.
fill_sockaddr(_Ctx, 0, _Addr, _Bytes, _Port) ->
    ok;
fill_sockaddr(Ctx, SockAddr, Addr, Bytes, Port) ->
    maybe
        {ok, DataLen} ?= read_u32(Ctx, SockAddr + 4),
        {ok, Data} ?= read_u32(Ctx, SockAddr + 8),
        ok ?= write_bytes(Ctx, SockAddr,
                          <<(family_constant(Addr)):8, 0:24,
                            (byte_size(Bytes)):32/little>>),
        case DataLen >= byte_size(Bytes) + 2 of
            %% Port first, as `sockaddr_in' has it, then the octets.
            true -> write_bytes(Ctx, Data, <<Port:16/big, Bytes/binary>>);
            false -> {error, ?EINVAL}
        end
    end.

read_u32(Ctx, Ptr) ->
    case wasm:read_memory(Ctx, Ptr, 4) of
        {ok, <<V:32/little>>} -> {ok, V};
        _ -> {error, ?EFAULT}
    end.

write_bytes(Ctx, Ptr, Bin) ->
    case wasm:write_memory(Ctx, Ptr, Bin) of
        ok -> ok;
        _ -> {error, ?EFAULT}
    end.

%%% ------------------------------------------------------------ open helper ---

open_at(Ctx, Path, Root, Guest, OFlags, FdFlags, Rights, Inh, Own, Follow,
        OutFdPtr, St) ->
    Backend = wasi_fs:backend(),
    MustExist = (OFlags band ?OFLAGS_CREAT) =:= 0,
    %% Resolved lexically only to decide whether the target is a directory,
    %% which still holds a host path. The open itself does not use the answer.
    %%
    %% Which is why its *failure* is not the answer either, on the backend that
    %% resolves properly. `filelib:safe_relative_path/2' reports `unsafe' for
    %% anything it will not vouch for, including a symlink cycle inside the
    %% preopen, and that arrived at the guest as `ENOTCAPABLE' even though the
    %% native walk would have said `ELOOP'. Advisory means advisory: hand the
    %% path to `wasi_fs' and let the walk produce the errno.
    %% A symlink is refused here, before anything is classified.
    %%
    %% The directory arm below opens by *host path*, which does not go through
    %% the walk and so cannot honour the follow flag itself: `path_open' on a
    %% symlink to a directory happily returned the directory. Asking `wasi_fs'
    %% for the link's own type is the one question that settles it, and both
    %% backends answer it the same way.
    case not Follow andalso wasi_fs:stat(Root, Guest, nofollow) of
        {ok, #{type := symlink}} -> {errno, ?ELOOP};
        _ -> open_at_1(Ctx, Path, Root, Guest, OFlags, FdFlags, Rights, Inh,
                       Own, Follow, OutFdPtr, St, Backend, MustExist)
    end.

open_at_1(Ctx, Path, Root, Guest, OFlags, FdFlags, Rights, Inh, Own, Follow,
          OutFdPtr, St, Backend, MustExist) ->
    case wasi_path:resolve(Path, Guest, MustExist) of
        {error, E} when Backend =:= fallback -> {errno, E};
        {error, _} ->
            open_file(Ctx, Root, Guest, OFlags, FdFlags, Rights, Inh, Own,
                      Follow, OutFdPtr, St);
        {ok, Full} ->
            case classify(Full) of
                %% A directory opened for writing is `EISDIR', whatever else
                %% the flags say. Asking for `FD_WRITE' on one is a category
                %% error rather than a capability the guest lacks, so it is not
                %% `ENOTCAPABLE'.
                directory when (Rights band ?RIGHT_FD_WRITE) =/= 0 ->
                    {errno, ?EISDIR};
                directory when (OFlags band ?OFLAGS_DIRECTORY) =/= 0;
                               (OFlags band ?OFLAGS_CREAT) =:= 0 ->
                    add_dir_fd(Ctx, Full, Rights, Inh, OutFdPtr, St);
                directory -> {errno, ?EISDIR};
                %% `O_DIRECTORY' on something that is not one. The kernel would
                %% say this for the file arm, but the classification happens
                %% here and a symlink to a file resolved to the file and opened
                %% it.
                _ when (OFlags band ?OFLAGS_DIRECTORY) =/= 0 ->
                    {errno, ?ENOTDIR};
                _ ->
                    %% The guest path, not the resolved one: `wasi_fs'
                    %% resolves it itself, one component at a time, and that
                    %% is the whole point of handing it over.
                    open_file(Ctx, Root, Guest, OFlags, FdFlags, Rights, Inh,
                              Own, Follow, OutFdPtr, St)
            end
    end.

open_file(Ctx, Root, Guest, OFlags, FdFlags, Rights, Inh, Own, Follow,
          OutFdPtr, St) ->
    Wants = fun(F) -> (OFlags band F) =/= 0 end,
    Append = (FdFlags band ?FDFLAGS_APPEND) =/= 0,
    NeedWrite = Wants(?OFLAGS_CREAT) orelse Wants(?OFLAGS_TRUNC) orelse Append
        orelse (Rights band ?RIGHT_FD_WRITE) =/= 0,
    %% Truncating on open is a size change, and `PATH_FILESTAT_SET_SIZE' is the
    %% right that governs it. It is separate from write precisely so a
    %% descriptor can be passed on with permission to append but not to discard
    %% what is already there.
    %% Against the directory's *own* rights, not what it passes down: this is
    %% something the guest is asking that descriptor to do, the way `path_open'
    %% itself needs `PATH_OPEN' on it.
    Truncating = Wants(?OFLAGS_TRUNC),
    case (NeedWrite andalso (Inh band ?RIGHT_PATH_CREATE_FILE) =:= 0)
         orelse (Truncating
                 andalso (Own band ?RIGHT_PATH_FILESTAT_SET_SIZE) =:= 0) of
        true ->
            %% The preopen was granted read-only, so no combination of flags
            %% may produce a writable descriptor.
            {errno, ?ENOTCAPABLE};
        false ->
            Modes = fs_modes(Wants, Append, NeedWrite)
                        ++ [follow || Follow],
            %% Through `wasi_fs', which is what makes the native backend real.
            %% This resolved the path and then opened it as two steps, so the
            %% `openat(O_NOFOLLOW)' walk that exists to close the
            %% time-of-check-to-time-of-use window guarded nothing a guest
            %% actually did.
            case wasi_fs:open(Root, Guest, Modes) of
                {error, E} -> {errno, E};
                {ok, H} ->
                    Entry = #wasi_fd{type = file,
                                     filetype = ?FILETYPE_REGULAR_FILE,
                                     rights = Rights band Inh,
                                     rights_inheriting = Inh,
                                     handle = H, append = Append,
                                     syncflags = FdFlags band ?SYNCFLAGS},
                    {Fd, St1} = fd_add(St, Entry),
                    emit_fd(Ctx, OutFdPtr, Fd, St1)
            end
    end.

%% Append is not a mode here. Every write is positional now, so appending is
%% writing at the size the file is, which is decided per write rather than once
%% at open. That also means two descriptors appending to one file cannot end up
%% disagreeing about where the end was.
fs_modes(Wants, _Append, NeedWrite) ->
    [read]
        ++ [write || NeedWrite]
        ++ [create || Wants(?OFLAGS_CREAT)]
        ++ [truncate || Wants(?OFLAGS_TRUNC)]
        ++ [exclusive || Wants(?OFLAGS_EXCL)].

add_dir_fd(Ctx, Full, Rights, Inh, OutFdPtr, St) ->
    case wasi_fs:preopen(Full) of
        {error, E} ->
            {errno, E};
        {ok, Root} ->
            %% Masked to the directory set, for the reason a preopen is: a
            %% directory that held `FD_SEEK' let a seek through to the type
            %% clause, which answered `ESPIPE' where the specification wants
            %% the descriptor never to have had the right.
            Entry = #wasi_fd{type = dir, filetype = ?FILETYPE_DIRECTORY,
                             rights = Rights band Inh band ?RIGHTS_DIR_WRITE,
                             rights_inheriting = Inh,
                             host_path = Full, root = Root},
            {Fd, St1} = fd_add(St, Entry),
            emit_fd(Ctx, OutFdPtr, Fd, St1)
    end.

%% Hand the guest the descriptor it asked for, and give up what it names if it
%% cannot be handed over.
%%
%% A guest that passes an out-pointer outside its memory gets `EFAULT', which
%% is right. What was wrong is what happened to the socket behind the
%% descriptor: the errno came back without the new state, so the entry was
%% dropped, and with it the only reference to an accepted connection. The guest
%% never learned the number so it could never close it, and `close_all/1' at
%% destroy could not find it either, because it was never in `fds'. One
%% connected socket per bad pointer, held for the life of the node.
emit_fd(Ctx, OutFdPtr, Fd, St) ->
    case write_mem(Ctx, OutFdPtr, <<Fd:32/little>>) of
        {errno, ?ESUCCESS} ->
            {errno, ?ESUCCESS, St};
        {errno, E} ->
            _ = close_entry(fd_entry(St, Fd)),
            {errno, E, fd_remove(St, Fd)}
    end.

fd_entry(#{fds := Fds}, Fd) -> maps:get(Fd, Fds, undefined).

%% `Fun' takes the descriptor's directory and the guest path, and does the
%% operation through `wasi_fs'. It used to take a resolved host path, which
%% meant resolving the name here and acting on it there: two steps with a
%% window between them, and the whole reason the native backend exists.
mutate_path(Ctx, St, DirFd, PathPtr, PathLen, Right, Fun) ->
    mutate_path(Ctx, St, DirFd, PathPtr, PathLen, Right, Fun, check_slash).

%% `Slash' is `check_slash' or `any_slash'. Creating a directory is the one
%% caller that may name a path ending in `/' for something that is not there
%% yet; see `trailing_slash_ok/2'.
mutate_path(Ctx, St, DirFd, PathPtr, PathLen, Right, Fun, Slash) ->
    with_dir(St, DirFd,
             fun(#wasi_fd{root = Root, rights_inheriting = Inh}) ->
                 case (Inh band Right) =:= 0 of
                     true -> {errno, ?ENOTCAPABLE};
                     false ->
                         maybe
                             {ok, Guest} ?= read_path(Ctx, PathPtr, PathLen),
                             ok ?= case Slash of
                                       check_slash -> trailing_slash_ok(Root, Guest);
                                       any_slash -> ok
                                   end,
                             fs_errno(Fun(Root, Guest))
                         else
                             {error, E} -> {errno, E}
                         end
                 end
             end).

fs_errno(ok) -> {errno, ?ESUCCESS};
fs_errno({error, E}) -> {errno, E}.

%% Two capability-scoped paths, each against its own preopen. Resolving only
%% the source would let a module place the destination outside the sandbox, and
%% on the native backend neither is resolved here at all: both ends go to
%% `wasi_fs' as a directory and a name, and the kernel does the rest in one
%% call.
two_paths(Ctx, St, {FdA, PtrA, LenA}, {FdB, PtrB, LenB}, Right, Fun) ->
    with_dir(St, FdA,
      fun(#wasi_fd{root = RootA, rights_inheriting = Inh}) ->
          case (Inh band Right) =:= 0 of
              true -> {errno, ?ENOTCAPABLE};
              false ->
                  with_dir(St, FdB,
                    fun(#wasi_fd{root = RootB, rights_inheriting = InhB}) ->
                        case (InhB band ?RIGHT_PATH_CREATE_FILE) =:= 0 of
                            true -> {errno, ?ENOTCAPABLE};
                            false ->
                                maybe
                                    {ok, GA} ?= read_path(Ctx, PtrA, LenA),
                                    {ok, GB} ?= read_path(Ctx, PtrB, LenB),
                                    ok ?= trailing_slash_ok(RootA, GA),
                                    %% The destination need not exist yet, so
                                    %% a trailing slash on it constrains the
                                    %% *source* instead: `rename("d", "e/")'
                                    %% is legal when `d' is a directory and
                                    %% `link("f", "l/")' is not.
                                    ok ?= dest_slash_ok(RootA, GA, GB),
                                    fs_errno(Fun(RootA, GA, RootB, GB))
                                else
                                    {error, E} -> {errno, E}
                                end
                        end
                    end)
          end
      end).

%% A `dirent' is a fixed 24-byte header followed by the name. Entries are
%% emitted from `Cookie' onward and the result is truncated to the caller's
%% buffer, which is how a caller with a small buffer pages through a large
%% directory.
dirents(Dir, Names, Cookie, BufLen) ->
    Indexed = lists:zip(lists:seq(1, length(Names)), Names),
    Wanted = [{I, N} || {I, N} <- Indexed, I > Cookie],
    dirents_fill(Dir, Wanted, BufLen, <<>>).

dirents_fill(_Dir, [], _BufLen, Acc) -> Acc;
dirents_fill(Dir, [{Index, Name} | Rest], BufLen, Acc) ->
    NameBin = unicode:characters_to_binary(Name),
    {Type, Ino} = dirent_info(Dir, Name),
    Entry = <<Index:64/little, Ino:64/little, (byte_size(NameBin)):32/little,
              Type:8, 0:24, NameBin/binary>>,
    Next = <<Acc/binary, Entry/binary>>,
    case byte_size(Next) >= BufLen of
        %% Truncating mid-entry is expected: the caller retries with the cookie
        %% of the last complete entry and a bigger buffer.
        true -> binary:part(Next, 0, BufLen);
        false -> dirents_fill(Dir, Rest, BufLen, Next)
    end.

%% The type and the inode, from one stat rather than the type alone.
%%
%% The inode was a literal zero here while `filestat/2' also wrote zero, so the
%% two agreed by both being wrong. Now that a stat reports the real one,
%% `fd_readdir' has to as well: the upstream case asserts that the entry for "."
%% carries the same inode the directory's own `path_filestat_get' reports.
%%
%% "." and ".." are the directory and its parent, which is why they are stated
%% rather than assumed: only their *type* is known without looking.
dirent_info(Dir, ".") -> {?FILETYPE_DIRECTORY, inode_of(Dir)};
dirent_info(Dir, "..") -> {?FILETYPE_DIRECTORY, inode_of(filename:join(Dir, ".."))};
dirent_info(Dir, Name) ->
    case file:read_link_info(filename:join(Dir, Name)) of
        {ok, #file_info{type = T, inode = I}} -> {filetype_of(T), I};
        _ -> {?FILETYPE_UNKNOWN, 0}
    end.

inode_of(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{inode = I}} -> I;
        _ -> 0
    end.

%% A `subscription' is 48 bytes: an 8-byte userdata, a tag, and a union. Only
%% the clock arm is decoded; anything else is reported so the caller can refuse.
read_subscriptions(Ctx, Ptr, N0) ->
    N = wasm_num:to_u32(N0),
    case N > 256 of
        true -> {error, ?EINVAL};
        false ->
            case wasm:read_memory(Ctx, wasm_num:to_u32(Ptr), N * 48) of
                {error, _} -> {error, ?EFAULT};
                {ok, Bin} -> {ok, [subscription(S) || <<S:48/binary>> <= Bin]}
            end
    end.

%% The layout is fixed by the witx definition and is padding-sensitive:
%%
%%   0  userdata   u64
%%   8  tag        u8      (+7 padding, the union is 8-byte aligned)
%%   16 clock id   u32     (+4 padding, timeout is 8-byte aligned)
%%   24 timeout    u64
%%   32 precision  u64
%%   40 flags      u16     (+6 padding)
%%
%% Omitting the 4 bytes after the clock id made `timeout' straddle the padding
%% and read garbage, so every `thread::sleep' hit the 60 second cap instead of
%% sleeping its 30 ms. Worth noting how that hid: the program only checked
%% `elapsed >= 25ms', which a 60 second sleep satisfies just as well.
subscription(<<UserData:64/little, ?EVENTTYPE_CLOCK:8, _:7/binary,
               _ClockId:32/little, _:32, Timeout:64/little,
               _Precision:64/little, Flags:16/little, _/binary>>) ->
    %% Bit 0 of the flags selects an absolute deadline over a relative one.
    {clock, UserData, {Timeout, Flags band 1}};
%% The read and write arms share a union holding one descriptor, at the same
%% 8-byte-aligned offset the clock arm's id sits at.
subscription(<<UserData:64/little, Tag:8, _:7/binary, Fd:32/little, _/binary>>)
  when Tag =:= ?EVENTTYPE_FD_READ; Tag =:= ?EVENTTYPE_FD_WRITE ->
    {fd, UserData, Tag, Fd};
subscription(<<UserData:64/little, Tag:8, _/binary>>) ->
    {unknown, UserData, Tag}.

%% Sleeping the whole subscription set means waiting for the earliest deadline,
%% since that is the first that could fire.
shortest_delay(Subs) ->
    Ns = [T || {clock, _, {T, 0}} <- Subs],
    case Ns of
        [] -> 0;
        _ -> lists:min(Ns) div 1000000
    end.

%% Blocking the instance process is acceptable here and nowhere else: the
%% module asked to wait. It stays interruptible, so a timeout still kills it.
sleep_ms(0) -> ok;
sleep_ms(Ms) when Ms > 0 -> timer:sleep(erlang:min(Ms, 60000)), ok;
sleep_ms(_) -> ok.

%% An `event' is 32 bytes: userdata, errno, type, and a union left zeroed for
%% the clock case.
clock_event(UserData) ->
    <<UserData:64/little, ?ESUCCESS:16/little, ?EVENTTYPE_CLOCK:8, 0:40,
      0:64/little, 0:64/little>>.

%% The read and write arms fill that union: how many bytes are waiting, and
%% whether the peer has hung up.
fd_event(UserData, Type, Errno, NBytes, Flags) ->
    <<UserData:64/little, Errno:16/little, Type:8, 0:40, NBytes:64/little,
      Flags:16/little, 0:48>>.

%%% --------------------------------------------------------------- polling ---

%% How long a wait is broken into when more than one socket is being watched.
-define(POLL_SLICE_MS, 10).

poll(Ctx, OutPtr, NEventsPtr, Clocks, [], _Config, St) ->
    ok = sleep_ms(shortest_delay(Clocks)),
    emit_events(Ctx, OutPtr, NEventsPtr,
                [clock_event(Id) || {clock, Id, _} <- Clocks], St);
poll(Ctx, OutPtr, NEventsPtr, Clocks, Fds, Config, St) ->
    %% Every subscription resolves: an unknown descriptor becomes a `bad' entry
    %% that reports EBADF as its own event, rather than failing the whole poll.
    case resolve_subs(Fds, St, []) of
        {ok, Resolved} ->
            {Events, St1} = wait_ready(Resolved, poll_deadline(Clocks, Config), St),
            %% Nothing became ready, so the wait ended at its deadline, and the
            %% clocks that set it are what fired.
            Out = case Events of
                      [] -> [clock_event(Id) || {clock, Id, _} <- Clocks]; _ -> Events
                  end,
            emit_events(Ctx, OutPtr, NEventsPtr, Out, St1)
    end.

%% A subscription on a descriptor that is not a socket is refused for the whole
%% call, which is what this did for every descriptor until sockets existed. A
%% descriptor that does not exist is reported as an event instead: that is one
%% subscription being wrong, not the call.
resolve_subs([], _St, Acc) ->
    {ok, lists:reverse(Acc)};
resolve_subs([{fd, UserData, Tag, Fd} | Rest], St, Acc) ->
    case fd_lookup(St, Fd) of
        {ok, #wasi_fd{type = socket, handle = H}} ->
            Kind = case Tag of
                       ?EVENTTYPE_FD_READ -> read;
                       ?EVENTTYPE_FD_WRITE -> write
                   end,
            resolve_subs(Rest, St, [{Kind, UserData, Fd, H} | Acc]);
        error ->
            resolve_subs(Rest, St, [{bad, UserData, Tag} | Acc]);
        %% A regular file and a stdio stream are always ready.
        %%
        %% This answered `ENOSYS' on the grounds that claiming a file is ready
        %% when that cannot be known produces misbehaviour far from here. For a
        %% *file* it can be known: POSIX says a regular file is always ready for
        %% reading and writing, `select' has said so for forty years, and a
        %% guest that polls stdin before reading it -- which is what Rust's
        %% standard library does -- got `ENOSYS' and gave up.
        {ok, _Ready} ->
            Kind = case Tag of
                       ?EVENTTYPE_FD_READ -> ready_read;
                       ?EVENTTYPE_FD_WRITE -> ready_write
                   end,
            resolve_subs(Rest, St, [{Kind, UserData, Fd} | Acc])
    end.

poll_deadline([], Config) -> net_timeout(Config);
poll_deadline(Clocks, _Config) -> shortest_delay(Clocks).

%% One socket and nothing else to watch: wait on it directly. This is the
%% common case and it is exact, with no polling interval in it.
wait_ready([{read, _UserData, _Fd, _H}] = One, Deadline, St) when Deadline > 0 ->
    ready_now(One, St, capped(Deadline), []);
wait_ready(Resolved, Deadline, St) ->
    poll_loop(Resolved, capped(Deadline), St).

capped(infinity) -> 60000;
capped(Ms) when is_integer(Ms), Ms > 0 -> erlang:min(Ms, 60000);
capped(_) -> 0.

%% More than one socket, so they are checked in turn and the wait is broken
%% into slices. Watching them all at once would mean putting them in active
%% mode, and an inline call runs in the embedder's own process, where a
%% `{tcp, _, _}' message may belong to the embedder rather than to us. Taking
%% one would be silent data loss in somebody else's code, so the cost is paid
%% here instead, as latency, where it is visible and bounded.
poll_loop(Resolved, Remaining, St) ->
    case ready_now(Resolved, St, 0, []) of
        {[], St1} when Remaining =< 0 ->
            {[], St1};
        {[], St1} ->
            Slice = erlang:min(Remaining, ?POLL_SLICE_MS),
            ok = timer:sleep(Slice),
            poll_loop(Resolved, Remaining - Slice, St1); Ready ->
            Ready
    end.

ready_now([], St, _Timeout, Acc) ->
    {lists:reverse(Acc), St};
%% A connected socket is writable: `sock_send' sends all of it or fails, so
%% there is no partial-write state to be not-ready in.
ready_now([{write, UserData, _Fd, _H} | Rest], St, Timeout, Acc) ->
    Event = fd_event(UserData, ?EVENTTYPE_FD_WRITE, ?ESUCCESS, 0, 0),
    ready_now(Rest, St, Timeout, [Event | Acc]);
%% A file or a stdio stream, which is ready by definition. Zero bytes rather
%% than a size: `nbytes' is a hint and a guest that trusted it would read past
%% the end just as readily with a real number in it.
ready_now([{ready_read, UserData, _Fd} | Rest], St, Timeout, Acc) ->
    Event = fd_event(UserData, ?EVENTTYPE_FD_READ, ?ESUCCESS, 0, 0),
    ready_now(Rest, St, Timeout, [Event | Acc]);
ready_now([{ready_write, UserData, _Fd} | Rest], St, Timeout, Acc) ->
    Event = fd_event(UserData, ?EVENTTYPE_FD_WRITE, ?ESUCCESS, 0, 0),
    ready_now(Rest, St, Timeout, [Event | Acc]);
ready_now([{bad, UserData, Tag} | Rest], St, Timeout, Acc) ->
    ready_now(Rest, St, Timeout, [fd_event(UserData, Tag, ?EBADF, 0, 0) | Acc]);
ready_now([{read, UserData, Fd, H} | Rest], St, Timeout, Acc) ->
    case peek(H, Fd, St, Timeout) of
        {not_ready, St1} ->
            ready_now(Rest, St1, Timeout, Acc);
        {ready, N, Flags, St1} ->
            Event = fd_event(UserData, ?EVENTTYPE_FD_READ, ?ESUCCESS, N, Flags),
            ready_now(Rest, St1, Timeout, [Event | Acc]);
        {failed, E, St1} ->
            Event = fd_event(UserData, ?EVENTTYPE_FD_READ, E, 0, 0),
            ready_now(Rest, St1, Timeout, [Event | Acc])
    end.

%% Readiness without consuming. Bytes that arrive go into the descriptor's
%% buffer, which is where the next read looks first, so nothing is read twice
%% and nothing is lost between finding out and asking for it.
peek(H, Fd, St, Timeout) ->
    case fd_lookup(St, Fd) of
        {ok, #wasi_fd{buffer = B}} when B =/= <<>> ->
            {ready, byte_size(B), 0, St};
        _ ->
            case wasi_sock:recv(H, 0, Timeout) of
                {ok, Data} ->
                    {ready, byte_size(Data), 0, fd_set_buffer(St, Fd, Data)};
                eof ->
                    {ready, 0, ?EVENTRWFLAGS_FD_READWRITE_HANGUP, St};
                {error, ?EAGAIN} ->
                    {not_ready, St};
                {error, E} ->
                    {failed, E, St}
            end
    end.

classify(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = directory}} -> directory;
        {ok, _} -> regular;
        {error, _} -> absent
    end.

%%% ---------------------------------------------------------- read / write ---

do_write(Ctx, #wasi_fd{type = stdio, device = Dev}, Data, NWrittenPtr, _St, _Fd) ->
    ok = write_stdio(Dev, Data),
    write_u32(Ctx, NWrittenPtr, byte_size(Data));
do_write(Ctx, #wasi_fd{type = file, handle = H, offset = Off, append = App},
         Data, NWrittenPtr, St, Fd) ->
    At = case App of true -> file_size(H); false -> Off end,
    case wasi_fs:pwrite(H, At, Data) of
        {ok, N} ->
            %% An append leaves the descriptor's offset where the write ended,
            %% which is what a subsequent `fd_tell' has to report.
            St1 = fd_set_offset(St, Fd, At + N),
            case write_u32(Ctx, NWrittenPtr, N) of
                {errno, ?ESUCCESS} -> {errno, ?ESUCCESS, St1};
                Other -> Other
            end;
        {error, E} -> {errno, E}
    end;
do_write(Ctx, #wasi_fd{type = socket, handle = H}, Data, NWrittenPtr, _St, _Fd) ->
    case wasi_sock:send(H, Data) of
        ok -> write_u32(Ctx, NWrittenPtr, byte_size(Data));
        {error, E} -> {errno, E}
    end;
do_write(_Ctx, _Entry, _Data, _Ptr, _St, _Fd) ->
    {errno, ?EBADF}.

%% Writing to a pid delivers a message rather than blocking on io. That keeps
%% the instance's output under the embedder's control, and means a slow or
%% absent consumer cannot stall WebAssembly execution.
write_stdio(Pid, Data) when is_pid(Pid) -> Pid ! {wasi_output, self(), Data}, ok;
write_stdio(Dev, Data) when is_atom(Dev) -> io:put_chars(Dev, Data);
write_stdio({Mod, Fun}, Data) -> Mod:Fun(Data), ok;
write_stdio(F, Data) when is_function(F, 1) -> F(Data), ok;
write_stdio(_, _) -> ok.

%% The offset is tracked in the descriptor, so a binary stdin behaves like a
%% file being consumed rather than repeating itself on every read.
stdin_read(Bin, Off, _Want) when is_binary(Bin), Off >= byte_size(Bin) -> eof;
stdin_read(Bin, Off, Want) when is_binary(Bin) ->
    Take = erlang:min(Want, byte_size(Bin) - Off),
    {ok, binary:part(Bin, Off, Take)};
stdin_read(F, _Off, Want) when is_function(F, 1) ->
    case F(Want) of
        eof -> eof;
        {ok, Data} when is_binary(Data) -> {ok, Data};
        Data when is_binary(Data) -> {ok, Data};
        _ -> eof
    end;
stdin_read(_, _, _) -> eof.

do_read(Ctx, #wasi_fd{type = file, handle = H, offset = Off}, Specs, NReadPtr,
        St, Fd) ->
    Total = lists:sum([L || {_, L} <- Specs]),
    case wasi_fs:pread(H, Off, Total) of
        eof -> write_u32(Ctx, NReadPtr, 0);
        {ok, Data} ->
            ok = scatter(Ctx, Specs, Data),
            St1 = fd_bump_offset(St, Fd, byte_size(Data)),
            case write_u32(Ctx, NReadPtr, byte_size(Data)) of
                {errno, ?ESUCCESS} -> {errno, ?ESUCCESS, St1};
                Other -> Other
            end;
        {error, E} -> {errno, E}
    end;
%% stdin is a capability like any other. Absent, it reports end of file, which
%% is honest and is what a module can cope with. Present, it may be a binary
%% (consumed progressively across reads), or a fun returning `{ok, Data}` or
%% `eof` so the embedder can stream.
do_read(Ctx, #wasi_fd{type = stdio, device = none}, _Specs, NReadPtr, _St, _Fd) ->
    write_u32(Ctx, NReadPtr, 0);
do_read(Ctx, #wasi_fd{type = stdio, device = Dev, offset = Off}, Specs,
        NReadPtr, St, Fd) ->
    Want = lists:sum([L || {_, L} <- Specs]),
    case stdin_read(Dev, Off, Want) of
        eof -> write_u32(Ctx, NReadPtr, 0);
        {ok, Data} ->
            ok = scatter(Ctx, Specs, Data),
            St1 = fd_bump_offset(St, Fd, byte_size(Data)),
            case write_u32(Ctx, NReadPtr, byte_size(Data)) of
                {errno, ?ESUCCESS} -> {errno, ?ESUCCESS, St1};
                Other -> Other
            end
    end;
do_read(_Ctx, _E, _S, _P, _St, _Fd) ->
    {errno, ?EBADF}.

scatter(_Ctx, [], _Data) -> ok;
scatter(_Ctx, _Specs, <<>>) -> ok;
scatter(Ctx, [{Ptr, Len} | Rest], Data) ->
    Take = min(Len, byte_size(Data)),
    <<Chunk:Take/binary, Tail/binary>> = Data,
    _ = wasm:write_memory(Ctx, Ptr, Chunk),
    scatter(Ctx, Rest, Tail).

%% An iovec array is pairs of {pointer, length}. Reading them all before
%% touching the target file means a malformed vector cannot leave a partial
%% write behind.
read_iovecs(Ctx, Ptr, Len) ->
    case iovec_specs(Ctx, Ptr, Len) of
        {error, E} -> {error, E};
        {ok, Specs} ->
            Chunks = [case wasm:read_memory(Ctx, P, L) of
                          {ok, B} -> B;
                          _ -> <<>>
                      end || {P, L} <- Specs], {ok, iolist_to_binary(Chunks)}
    end.

iovec_specs(Ctx, Ptr, Count0) ->
    Count = wasm_num:to_u32(Count0),
    case Count > 1024 of
        true -> {error, ?EINVAL};
        false ->
            case wasm:read_memory(Ctx, wasm_num:to_u32(Ptr), Count * 8) of
                {error, _} -> {error, ?EFAULT};
                {ok, Bin} -> {ok, [{P, L} || <<P:32/little, L:32/little>> <= Bin]}
            end
    end.

emit_events(Ctx, OutPtr, NEventsPtr, Events, St) ->
    case wasm:write_memory(Ctx, wasm_num:to_u32(OutPtr),
                           iolist_to_binary(Events)) of
        ok ->
            case write_u32(Ctx, NEventsPtr, length(Events)) of
                {errno, ?ESUCCESS} -> {errno, ?ESUCCESS, St};
                Other -> Other
            end;
        _ ->
            {errno, ?EFAULT}
    end.

%% dev, ino, filetype, nlink, size, atim, mtim, ctim.
%%
%% Every field but the filetype used to be a literal: dev and ino zero, nlink
%% one, all three times zero. Two files in one directory therefore reported the
%% same inode, and a guest that set a timestamp and subtracted the value it read
%% back underflowed. Both are upstream test cases.
%% Naming both a value and "now" for one stamp says two things at once, so the
%% specification requires `EINVAL' rather than a choice between them. Upstream's
%% `fstflags_validate' is the case; this answered success for every combination.
set_times(Root, Guest, Atim, Mtim, Flags, Mode) ->
    set_times_on(fun(A, M) -> wasi_fs:set_times(Root, Guest, A, M, Mode) end,
                 Atim, Mtim, Flags).

set_times_on(Apply, Atim, Mtim, Flags) ->
    Both = fun(A, B) -> (Flags band A) =/= 0 andalso (Flags band B) =/= 0 end,
    case Both(?FSTFLAGS_ATIM, ?FSTFLAGS_ATIM_NOW)
         orelse Both(?FSTFLAGS_MTIM, ?FSTFLAGS_MTIM_NOW) of
        true -> {errno, ?EINVAL};
        false ->
            Now = erlang:system_time(nanosecond),
            A = stamp(Flags, ?FSTFLAGS_ATIM, ?FSTFLAGS_ATIM_NOW, Atim, Now),
            M = stamp(Flags, ?FSTFLAGS_MTIM, ?FSTFLAGS_MTIM_NOW, Mtim, Now),
            fs_errno(Apply(A, M))
    end.

%% A stamp nobody named is left alone rather than set to zero.
stamp(Flags, Bit, NowBit, Value, Now) ->
    if (Flags band NowBit) =/= 0 -> Now;
       (Flags band Bit) =/= 0 -> Value;
       true -> omit
    end.

%% Whether a lookup follows the final component.
lookup(Flags) when (Flags band ?LOOKUPFLAGS_SYMLINK_FOLLOW) =/= 0 -> follow;
lookup(_) -> nofollow.

%% A path ending in `/' must name a directory.
%%
%% POSIX, and four upstream cases: `unlink_file_trailing_slashes' expects
%% `ENOTDIR' for `path_unlink_file(dir, "file/")', `path_link' expects `ENOENT'
%% for a link target that ends in one, and `interesting_paths' expects opening
%% `"file/"' to fail. One rule produces all three answers, because stating the
%% name says which: nothing there is `ENOENT', something there that is not a
%% directory is `ENOTDIR'.
%%
%% Not applied to `path_create_directory': `mkdir("x/")' is ordinary and the
%% directory is not supposed to exist yet.
dest_slash_ok(_Root, _Src, Dest) when byte_size(Dest) =:= 0 -> ok;
dest_slash_ok(Root, Src, Dest) ->
    case binary:last(Dest) of
        $/ ->
            case wasi_fs:stat(Root, Src) of
                {ok, #{type := directory}} -> ok;
                {ok, _} -> {error, ?ENOENT};
                {error, E} -> {error, E}
            end;
        _ -> ok
    end.

trailing_slash_ok(_Root, Guest) when byte_size(Guest) =:= 0 -> ok;
trailing_slash_ok(Root, Guest) ->
    case binary:last(Guest) of
        $/ ->
            case wasi_fs:stat(Root, Guest) of
                {ok, #{type := directory}} -> ok;
                {ok, _} -> {error, ?ENOTDIR};
                {error, E} -> {error, E}
            end;
        _ -> ok
    end.

filestat(Filetype, Info) ->
    #{inode := Ino, dev := Dev, nlink := Nlink,
      size := Size, atim := A, mtim := M, ctim := C} = Info,
    <<Dev:64/little, Ino:64/little, Filetype:8, 0:56, Nlink:64/little,
      Size:64/little, A:64/little, M:64/little, C:64/little>>.

%% For a descriptor with no file behind it, such as a socket or a stream. There
%% is nothing to stat, so the filetype is all this can honestly report.
filestat_bare(Filetype) ->
    filestat(Filetype, #{inode => 0, dev => 0, nlink => 1, size => 0,
                         atim => 0, mtim => 0, ctim => 0}).

%% `wasi_fs' answers a map rather than a `#file_info{}', because that is what
%% the two backends can both produce: the native one has an `fstatat' and the
%% fallback has `file:read_link_info/2'.
stat_to_filestat(#{type := Type} = Info) ->
    filestat(case Type of
                 directory -> ?FILETYPE_DIRECTORY;
                 regular -> ?FILETYPE_REGULAR_FILE;
                 symlink -> ?FILETYPE_SYMBOLIC_LINK;
                 _ -> ?FILETYPE_UNKNOWN
             end, Info).

%%% --------------------------------------------------------------- helpers ---

sizes(Ctx, CountPtr, BufPtr, Items) ->
    Count = length(Items),
    BufSize = lists:sum([byte_size(I) + 1 || I <- Items]),
    case write_u32(Ctx, CountPtr, Count) of
        {errno, ?ESUCCESS} -> write_u32(Ctx, BufPtr, BufSize);
        Other -> Other
    end.

%% Strings are laid out as a pointer array plus a NUL-separated buffer, which
%% is the C convention WASI inherited.
write_strings(Ctx, PtrsPtr, BufPtr, Items) ->
    {Ptrs, Buf, _} =
        lists:foldl(
          fun(Item, {Ps, Bs, Off}) ->
              {[<<(BufPtr + Off):32/little>> | Ps],
               [<<Item/binary, 0>> | Bs],
               Off + byte_size(Item) + 1}
          end, {[], [], 0}, Items),
    case wasm:write_memory(Ctx, wasm_num:to_u32(PtrsPtr),
                           iolist_to_binary(lists:reverse(Ptrs))) of
        ok ->
            case wasm:write_memory(Ctx, wasm_num:to_u32(BufPtr),
                                   iolist_to_binary(lists:reverse(Buf))) of
                ok -> {errno, ?ESUCCESS};
                _ -> {errno, ?EFAULT}
            end;
        _ -> {errno, ?EFAULT}
    end.

env_list(Config) ->
    [<<K/binary, "=", V/binary>>
     || {K, V} <- lists:sort(maps:to_list(maps:get(env, Config, #{})))].

clock_allowed(?CLOCK_REALTIME, C) -> lists:member(realtime, maps:get(clocks, C, []));
clock_allowed(?CLOCK_MONOTONIC, C) -> lists:member(monotonic, maps:get(clocks, C, []));
clock_allowed(_, _) -> false.

clock_now(?CLOCK_REALTIME) -> {ok, erlang:system_time(nanosecond)};
clock_now(?CLOCK_MONOTONIC) -> {ok, erlang:monotonic_time(nanosecond)};
clock_now(_) -> error.

%% The whole buffer is filled, however large, in pieces.
%%
%% A request over 1 MiB used to be answered with `crypto:strong_rand_bytes(0)',
%% which is the empty binary. Writing nothing succeeds, so the guest was told
%% `ESUCCESS' and handed back its buffer untouched: a program seeding a
%% generator from `random_get' would have seeded it from whatever was already
%% there, which on a fresh page is zeroes, and believed it had entropy. Silence
%% is the worst possible failure for this call.
%%
%% Pieces rather than one binary for two reasons. The peak allocation is one
%% chunk instead of the whole request, and `crypto:strong_rand_bytes/1' is a
%% NIF, so a chunk bounds how long any one of them holds a scheduler.
-define(RANDOM_CHUNK, 65536).

fill_random(_Ctx, _Ptr, 0, _Source, St) ->
    {?ESUCCESS, St};
fill_random(Ctx, Ptr, Len, Source, St) ->
    N = erlang:min(Len, ?RANDOM_CHUNK),
    {Bytes, St1} = random_bytes(Source, N, St),
    case wasm:write_memory(Ctx, Ptr, Bytes) of
        ok -> fill_random(Ctx, Ptr + N, Len - N, Source, St1);
        _ -> {?EFAULT, St1}
    end.

fits(Ctx, Ptr, Len) ->
    case wasm:memory_size(Ctx) of
        {ok, Pages} -> Ptr + Len =< Pages * ?PAGE_SIZE;
        _ -> false
    end.

random_bytes(strong, N, St) -> {crypto:strong_rand_bytes(N), St};
random_bytes({seed, Seed}, N, St) ->
    %% A deterministic source, for reproducible runs and tests. Never the
    %% default: a module that believes it has entropy and does not is worse off
    %% than one that is told it has none.
    %%
    %% Seeded once per instance and then carried. Re-seeding on every call made
    %% two `random_get' calls in one run hand back byte-identical streams, and
    %% would have made each 64 KiB piece of a large request a copy of the
    %% first. Deterministic means reproducible across runs, not constant within
    %% one.
    S0 = case maps:get(rand, St, undefined) of
             undefined -> rand:seed_s(exsss, {Seed, Seed, Seed});
             S -> S
         end,
    {Bytes, S1} = rand:bytes_s(N, S0),
    {Bytes, St#{rand => S1}};
random_bytes(_, N, St) -> {crypto:strong_rand_bytes(N), St}.

read_path(Ctx, Ptr, Len0) ->
    Len = wasm_num:to_u32(Len0),
    case Len > 4096 of
        true -> {error, ?ENAMETOOLONG};
        false ->
            case wasm:read_memory(Ctx, wasm_num:to_u32(Ptr), Len) of
                %% A path is bytes with a length, not a C string, so a NUL can
                %% appear in the middle of one. Every backend below eventually
                %% hands it to a C API that stops there, which would open
                %% "secret" for a guest that asked for "secret\0.txt". Refused
                %% here, once, rather than trusted at each call site.
                {ok, Bin} ->
                    case binary:match(Bin, ~"\0") of
                        nomatch -> {ok, Bin};
                        _ -> {error, ?EINVAL}
                    end;
                _ -> {error, ?EFAULT}
            end
    end.

write_mem(Ctx, Ptr, Bin) ->
    case wasm:write_memory(Ctx, wasm_num:to_u32(Ptr), Bin) of
        ok -> {errno, ?ESUCCESS};
        _ -> {errno, ?EFAULT}
    end.

write_u32(Ctx, Ptr, V) -> write_mem(Ctx, Ptr, <<V:32/little>>).
write_u64(Ctx, Ptr, V) -> write_mem(Ctx, Ptr, <<V:64/little>>).

filetype_of(directory) -> ?FILETYPE_DIRECTORY;
filetype_of(regular) -> ?FILETYPE_REGULAR_FILE;
filetype_of(symlink) -> ?FILETYPE_SYMBOLIC_LINK;
filetype_of(device) -> ?FILETYPE_CHARACTER_DEVICE;
filetype_of(_) -> ?FILETYPE_UNKNOWN.

%%% ------------------------------------------------------------- fd table ---

with_fd(St, Fd, Right, Fun) ->
    case fd_lookup(St, Fd) of
        error -> {errno, ?EBADF};
        {ok, E} ->
            %% Every caller names a specific right; there is no "no right
            %% required" case, so the mask alone decides.
            case (E#wasi_fd.rights band Right) =/= 0 of
                true -> Fun(E);
                false -> {errno, ?ENOTCAPABLE}
            end
    end.

with_dir(St, Fd, Fun) ->
    case fd_lookup(St, Fd) of
        {ok, #wasi_fd{type = dir} = E} -> Fun(E);
        {ok, _} -> {errno, ?ENOTDIR};
        error -> {errno, ?EBADF}
    end.

fd_lookup(#{fds := Fds}, Fd) -> maps:find(Fd, Fds).

fd_add(#{fds := Fds, next := Next} = St, Entry) ->
    {Next, St#{fds := maps:put(Next, Entry, Fds), next := Next + 1}}.

fd_remove(#{fds := Fds} = St, Fd) -> St#{fds := maps:remove(Fd, Fds)}.

fd_set_offset(#{fds := Fds} = St, Fd, Off) ->
    case maps:find(Fd, Fds) of
        {ok, E} -> St#{fds := Fds#{Fd => E#wasi_fd{offset = Off}}};
        error -> St
    end.

%% The size a positional write appends at, and what `fd_filestat_get' reports.
%% A handle that has gone answers zero rather than raising: the syscall above
%% turns the failure into an errno of its own.
file_size(H) ->
    case wasi_fs:size(H) of
        {ok, N} -> N;
        _ -> 0
    end.

fd_bump_offset(#{fds := Fds} = St, Fd, N) ->
    case maps:find(Fd, Fds) of
        {ok, E} -> St#{fds := maps:put(Fd, E#wasi_fd{offset = E#wasi_fd.offset + N},
                                       Fds)};
        error -> St
    end.

%%% ---------------------------------------------------------------- state ---
%%
%% The fd table lives in the instance's own store, so it shares the instance's
%% lifetime and is cleaned up with it. Building it lazily on first use means
%% the capability configuration is interpreted inside the instance process
%% rather than in whoever happened to construct the import map.

state(Ctx, Config) ->
    Inst = maps:get(instance, Ctx),
    case wasm_instance:get_extra(Inst, wasi) of
        {ok, St} -> St;
        error ->
            St = initial_state(Config),
            wasm_instance:set_extra(Inst, wasi, St),
            %% Registered once, with the state, so destroying the instance
            %% closes whatever the guest still holds.
            ok = wasm_instance:on_destroy(Inst, fun close_all/1),
            St
    end.

save(Ctx, St) ->
    wasm_instance:set_extra(maps:get(instance, Ctx), wasi, St).

initial_state(Config) ->
    Stdio = [{0, stdio_entry(maps:get(stdin, Config, none), ?RIGHT_FD_READ)},
             {1, stdio_entry(maps:get(stdout, Config, none), ?RIGHT_FD_WRITE)},
             {2, stdio_entry(maps:get(stderr, Config, none), ?RIGHT_FD_WRITE)}],
    {Preopens, AfterDirs} = preopen_entries(maps:get(dirs, Config, [])),
    %% Directories first, then listeners. Both orders work now that a socket
    %% preopen answers `ENOTDIR', but keeping the directories contiguous means
    %% a libc that stops early still finds all of them.
    {Listeners, Next} = listener_entries(maps:get(net, Config, none), AfterDirs),
    #{fds => maps:from_list(Stdio ++ Preopens ++ Listeners), next => Next}.

%% Listening sockets named by the grant are opened by the host and handed in as
%% preopened descriptors, so a module using only the standardised socket calls
%% never names an address at all.
%%
%% They are opened here, lazily, inside the instance process, so the socket is
%% owned by the process that will use it and closes when that process exits. A
%% bind that fails takes its descriptor with it and leaves the rest in place;
%% the numbering does not shift, so which descriptor is which does not depend
%% on whether some other port happened to be free.
listener_entries(Grant, First) ->
    lists:foldl(
      fun(Endpoint, {Acc, Fd}) ->
          case wasi_sock:open_listener(Endpoint) of
              {error, _Errno} -> {Acc, Fd + 1};
              {ok, Handle} ->
                  Entry = #wasi_fd{type = socket,
                                   filetype = wasi_sock:filetype(Handle),
                                   rights = ?RIGHTS_LISTENER,
                                   rights_inheriting = ?RIGHTS_SOCKET,
                                   handle = Handle, preopen = true},
                  {[{Fd, Entry} | Acc], Fd + 1}
          end
      end, {[], First}, wasi_net:bindable(Grant)).

stdio_entry(Device, Right) ->
    #wasi_fd{type = stdio, filetype = ?FILETYPE_CHARACTER_DEVICE,
             %% An absent capability carries no rights at all, so a read or
             %% write against it fails with ENOTCAPABLE rather than silently
             %% succeeding against nothing.
             rights = case Device of none -> 0; _ -> Right end,
             device = Device}.

%% Each entry is `{GuestPath, HostPath}' or `{GuestPath, HostPath, Access}'
%% where `Access' is `read' (the default) or `write'.
preopen_entries(Dirs) ->
    lists:foldl(
      fun(Spec, {Acc, Fd}) ->
          {Guest, Host, Access} = normalise_dir(Spec),
          %% A directory's *own* rights are the directory set; the file rights
          %% belong only to what is opened beneath it.
          %%
          %% Both used to be the union, so a directory held `FD_SEEK' and
          %% `FD_READ', `with_fd/4' let a seek through, and the type clause
          %% answered `ESPIPE'. The specification's answer is that a directory
          %% never had the right, which is what the split produces with no
          %% extra code.
          {Own, Inh} =
              case Access of
                  write -> {?RIGHTS_DIR_WRITE,
                            ?RIGHTS_DIR_WRITE bor ?RIGHTS_FILE_WRITE};
                  _ -> {?RIGHTS_DIR_READ,
                        ?RIGHTS_DIR_READ bor ?RIGHTS_FILE_READ}
              end,
          %% Opened once, here, and held for the life of the instance. A
          %% preopen whose directory cannot be opened at all is left out
          %% rather than handed over as a capability that will fail later.
          case wasi_fs:preopen(Host) of
              {error, _} ->
                  {Acc, Fd + 1};
              {ok, Root} ->
                  Entry = #wasi_fd{type = dir, filetype = ?FILETYPE_DIRECTORY,
                                   rights = Own, rights_inheriting = Inh,
                                   host_path = Host, root = Root,
                                   guest_path = Guest, preopen = true},
                  {[{Fd, Entry} | Acc], Fd + 1}
          end
      end, {[], ?FIRST_PREOPEN_FD}, Dirs).

normalise_dir({Guest, Host}) -> {Guest, Host, read};
normalise_dir({Guest, Host, Access}) -> {Guest, Host, Access}.
