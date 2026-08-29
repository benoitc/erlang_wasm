%% -*- erlang -*-
%% WASI Preview 1 ABI constants.
%%
%% Values are fixed by the `wasi_snapshot_preview1' witx definitions. They are
%% not internal choices and must not be renumbered.

-ifndef(WASI_HRL).
-define(WASI_HRL, true).

%%% ----------------------------------------------------------------- errno ---

-define(ESUCCESS,      0).
-define(EACCES,        2).
-define(EADDRINUSE,    3).
-define(EADDRNOTAVAIL, 4).
-define(EAFNOSUPPORT,  5).
-define(EAGAIN,        6).
-define(EBADF,         8).
-define(EBUSY,        10).
-define(ECONNABORTED, 13).
-define(ECONNREFUSED, 14).
-define(ECONNRESET,   15).
-define(EDESTADDRREQ, 17).
-define(EEXIST,       20).
-define(EFAULT,       21).
-define(EFBIG,        22).
-define(EHOSTUNREACH, 23).
-define(EINPROGRESS,  26).
-define(EINVAL,       28).
-define(EIO,          29).
-define(EISCONN,      30).
-define(EISDIR,       31).
-define(ELOOP,        32).
-define(EMFILE,       33).
-define(EMSGSIZE,     35).
-define(ENAMETOOLONG, 37).
-define(ENETDOWN,     38).
-define(ENETUNREACH,  40).
-define(ENFILE,       41).
-define(ENOBUFS,      42).
-define(ENOMEM,       48).
-define(ENOENT,       44).
-define(ENOPROTOOPT,  50).
-define(ENOSPC,       51).
-define(ENOSYS,       52).
-define(ENOTCONN,     53).
-define(ENOTDIR,      54).
-define(ENOTEMPTY,    55).
-define(ENOTSOCK,     57).
-define(ENOTSUP,      58).
-define(ENXIO,        60).
-define(EPERM,        63).
-define(EPIPE,        64).
-define(EPROTONOSUPPORT, 66).
-define(EROFS,        69).
-define(ESPIPE,       70).
-define(ETIMEDOUT,    73).
-define(EXDEV,        75).
%% Returned when a capability was simply not granted, as distinct from a
%% permission denied by the host operating system. Keeping them separate is
%% what lets a module tell "you did not give me this" from "the OS said no".
-define(ENOTCAPABLE,  76).

%%% -------------------------------------------------------------- filetype ---

-define(FILETYPE_UNKNOWN,          0).
-define(FILETYPE_BLOCK_DEVICE,     1).
-define(FILETYPE_CHARACTER_DEVICE, 2).
-define(FILETYPE_DIRECTORY,        3).
-define(FILETYPE_REGULAR_FILE,     4).
-define(FILETYPE_SOCKET_DGRAM,     5).
-define(FILETYPE_SOCKET_STREAM,    6).
-define(FILETYPE_SYMBOLIC_LINK,    7).

%%% ------------------------------------------------------------ open flags ---

-define(OFLAGS_CREAT,     16#1).
-define(OFLAGS_DIRECTORY, 16#2).
-define(OFLAGS_EXCL,      16#4).
-define(OFLAGS_TRUNC,     16#8).

-define(FDFLAGS_APPEND,   16#1).
-define(FDFLAGS_DSYNC,    16#2).
-define(FDFLAGS_NONBLOCK, 16#4).
-define(FDFLAGS_RSYNC,    16#8).
-define(FDFLAGS_SYNC,     16#10).
%% The three that say "make it durable". Grouped because nothing here treats
%% them differently: every write is followed through to the file already.
-define(SYNCFLAGS, (?FDFLAGS_DSYNC bor ?FDFLAGS_RSYNC bor ?FDFLAGS_SYNC)).

%% `fd_filestat_set_times' and `path_filestat_set_times'. The two pairs are
%% mutually exclusive: naming both a value and "now" for the same stamp says two
%% different things, and the specification requires `EINVAL' rather than a
%% choice between them.
-define(FSTFLAGS_ATIM,     16#1).
-define(FSTFLAGS_ATIM_NOW, 16#2).
-define(FSTFLAGS_MTIM,     16#4).
-define(FSTFLAGS_MTIM_NOW, 16#8).

-define(LOOKUPFLAGS_SYMLINK_FOLLOW, 16#1).

-define(WHENCE_SET, 0).
-define(WHENCE_CUR, 1).
-define(WHENCE_END, 2).

-define(PREOPENTYPE_DIR, 0).

%%% ------------------------------------------------------------ poll_oneoff ---

-define(EVENTTYPE_CLOCK,    0).
-define(EVENTTYPE_FD_READ,  1).
-define(EVENTTYPE_FD_WRITE, 2).

%% Set on a read event when the peer has hung up, which is how a module tells
%% "nothing yet" from "nothing ever again".
-define(EVENTRWFLAGS_FD_READWRITE_HANGUP, 16#1).

%%% --------------------------------------------------------------- sockets ---

%% `sock_recv' input flags, and the output flag saying data was cut short.
-define(RIFLAGS_RECV_PEEK,    16#1).
-define(RIFLAGS_RECV_WAITALL, 16#2).
-define(ROFLAGS_RECV_DATA_TRUNCATED, 16#1).

%% `sock_shutdown' directions.
-define(SDFLAGS_RD, 16#1).
-define(SDFLAGS_WR, 16#2).

%% The rest of this section belongs to the socket extension rather than to
%% Preview 1, and its values come from WasmEdge's `api.hpp' and the
%% `wasmedge_wasi_socket' crate, which is what a guest is compiled against.
%% They are not internal choices any more than the errnos above are.

-define(ADDRESS_FAMILY_UNSPEC, 0).
-define(ADDRESS_FAMILY_INET4,  1).
-define(ADDRESS_FAMILY_INET6,  2).

-define(SOCK_TYPE_ANY,    0).
-define(SOCK_TYPE_DGRAM,  1).
-define(SOCK_TYPE_STREAM, 2).

-define(AI_PROTOCOL_IP,  0).
-define(AI_PROTOCOL_TCP, 1).
-define(AI_PROTOCOL_UDP, 2).

-define(SOL_SOCKET, 0).

-define(SO_REUSEADDR,   0).
-define(SO_TYPE,        1).
-define(SO_ERROR,       2).
-define(SO_DONTROUTE,   3).
-define(SO_BROADCAST,   4).
-define(SO_SNDBUF,      5).
-define(SO_RCVBUF,      6).
-define(SO_KEEPALIVE,   7).
-define(SO_OOBINLINE,   8).
-define(SO_LINGER,      9).
-define(SO_RCVLOWAT,   10).
-define(SO_RCVTIMEO,   11).
-define(SO_SNDTIMEO,   12).
-define(SO_ACCEPTCONN, 13).

%% `__wasi_address_t' is a pointer and a length. The length is how the family
%% is told: 4 octets is IPv4, 16 is IPv6.
-define(ADDRESS_SIZE, 8).

%% `__wasi_sockaddr_t': family at 0, data length at 4, data pointer at 8.
-define(SOCKADDR_SIZE, 12).

%% `__wasi_addrinfo_t', 28 bytes, at the offsets WasmEdge's static_asserts fix:
%% flags 0, family 2, socktype 3, protocol 4, addrlen 8, addr 12, canonname 16,
%% canonname_len 20, next 24.
-define(ADDRINFO_SIZE, 28).

%%% ---------------------------------------------------------------- rights ---

-define(RIGHT_FD_DATASYNC,             16#1).
-define(RIGHT_FD_READ,                 16#2).
-define(RIGHT_FD_SEEK,                 16#4).
-define(RIGHT_FD_FDSTAT_SET_FLAGS,     16#8).
-define(RIGHT_FD_SYNC,                16#10).
-define(RIGHT_FD_TELL,                16#20).
-define(RIGHT_FD_WRITE,               16#40).
-define(RIGHT_FD_ADVISE,              16#80).
-define(RIGHT_FD_ALLOCATE,           16#100).
-define(RIGHT_PATH_CREATE_DIRECTORY, 16#200).       % bit 9
-define(RIGHT_PATH_CREATE_FILE,      16#400).       % bit 10
-define(RIGHT_PATH_LINK_SOURCE,      16#800).       % bit 11
-define(RIGHT_PATH_LINK_TARGET,     16#1000).       % bit 12
-define(RIGHT_PATH_OPEN,            16#2000).       % bit 13
-define(RIGHT_FD_READDIR,           16#4000).       % bit 14
-define(RIGHT_PATH_READLINK,        16#8000).       % bit 15
-define(RIGHT_PATH_RENAME_SOURCE,  16#10000).       % bit 16
-define(RIGHT_PATH_RENAME_TARGET,  16#20000).       % bit 17
-define(RIGHT_PATH_FILESTAT_GET,   16#40000).       % bit 18
-define(RIGHT_PATH_FILESTAT_SET_SIZE,  16#80000).   % bit 19
-define(RIGHT_PATH_FILESTAT_SET_TIMES, 16#100000).  % bit 20
-define(RIGHT_FD_FILESTAT_GET,        16#200000).   % bit 21
-define(RIGHT_FD_FILESTAT_SET_SIZE,   16#400000).   % bit 22
-define(RIGHT_FD_FILESTAT_SET_TIMES,  16#800000).   % bit 23
-define(RIGHT_PATH_SYMLINK,          16#1000000).   % bit 24
-define(RIGHT_PATH_REMOVE_DIRECTORY, 16#2000000).   % bit 25
-define(RIGHT_PATH_UNLINK_FILE, 16#4000000).        % bit 26
-define(RIGHT_POLL_FD_READWRITE, 16#8000000).       % bit 27
-define(RIGHT_SOCK_SHUTDOWN,   16#10000000).        % bit 28
-define(RIGHT_SOCK_ACCEPT,     16#20000000).        % bit 29

%% What a read-only preopened directory grants, and what a read-write one adds.
%%
%% A right that is not advertised is a call wasi-libc will not make, whatever
%% the runtime would have done with it. Ten of the thirty bits were missing from
%% this file, and `path_link', `path_rename', `path_symlink' and `path_readlink'
%% were all implemented and none of them reachable from a real guest.
-define(RIGHTS_DIR_READ,
        (?RIGHT_PATH_OPEN bor ?RIGHT_FD_READDIR bor ?RIGHT_PATH_FILESTAT_GET
         bor ?RIGHT_FD_FILESTAT_GET bor ?RIGHT_PATH_READLINK
         bor ?RIGHT_PATH_LINK_SOURCE)).
-define(RIGHTS_DIR_WRITE,
        (?RIGHTS_DIR_READ bor ?RIGHT_PATH_CREATE_FILE
         bor ?RIGHT_PATH_CREATE_DIRECTORY bor ?RIGHT_PATH_UNLINK_FILE
         bor ?RIGHT_PATH_REMOVE_DIRECTORY bor ?RIGHT_PATH_LINK_TARGET
         bor ?RIGHT_PATH_RENAME_SOURCE bor ?RIGHT_PATH_RENAME_TARGET
         bor ?RIGHT_PATH_SYMLINK bor ?RIGHT_PATH_FILESTAT_SET_SIZE
         bor ?RIGHT_PATH_FILESTAT_SET_TIMES
         %% A directory descriptor's own times can be set through it, so this
         %% is a base right on a directory and not only an inherited one.
         bor ?RIGHT_FD_FILESTAT_SET_TIMES)).
-define(RIGHTS_FILE_READ,
        (?RIGHT_FD_READ bor ?RIGHT_FD_SEEK bor ?RIGHT_FD_TELL
         bor ?RIGHT_FD_FILESTAT_GET bor ?RIGHT_FD_ADVISE
         bor ?RIGHT_POLL_FD_READWRITE bor ?RIGHT_FD_FDSTAT_SET_FLAGS)).
-define(RIGHTS_FILE_WRITE,
        (?RIGHTS_FILE_READ bor ?RIGHT_FD_WRITE bor ?RIGHT_FD_ALLOCATE
         bor ?RIGHT_FD_DATASYNC bor ?RIGHT_FD_SYNC
         bor ?RIGHT_FD_FILESTAT_SET_SIZE bor ?RIGHT_FD_FILESTAT_SET_TIMES)).

%% What a socket descriptor carries. A listener additionally accepts; a
%% connected socket does not, which is what stops `sock_accept' on a stream
%% from being a surprise instead of an errno.
-define(RIGHTS_SOCKET,
        (?RIGHT_FD_READ bor ?RIGHT_FD_WRITE bor ?RIGHT_FD_FILESTAT_GET
         bor ?RIGHT_FD_FDSTAT_SET_FLAGS bor ?RIGHT_POLL_FD_READWRITE
         bor ?RIGHT_SOCK_SHUTDOWN)).
-define(RIGHTS_LISTENER, (?RIGHTS_SOCKET bor ?RIGHT_SOCK_ACCEPT)).

%%% ---------------------------------------------------------------- clocks ---

-define(CLOCK_REALTIME,           0).
-define(CLOCK_MONOTONIC,          1).
-define(CLOCK_PROCESS_CPUTIME_ID, 2).
-define(CLOCK_THREAD_CPUTIME_ID,  3).

%%% -------------------------------------------------------------- fd table ---

%% One open file descriptor. `rights' is what this descriptor may do, and
%% `rights_inheriting' is what descriptors derived from it may do, which is how
%% a read-only preopen stays read-only however deep a module opens into it.
-record(wasi_fd, {
    type             :: stdio | dir | file | socket,
    filetype         :: non_neg_integer(),
    rights = 0       :: non_neg_integer(),
    rights_inheriting = 0 :: non_neg_integer(),
    %% stdio: the pid or io device to write to / read from
    device           :: term(),
    %% dir: the host path this preopen maps to, and the guest path it is
    %% presented as. Both are needed: the guest never learns the host path.
    host_path        :: undefined | file:filename_all(),
    %% dir: the same directory, opened once, that guest paths are resolved
    %% beneath. Naming the root by path on each open would leave it to be
    %% resolved again every time.
    root             :: undefined | wasi_fs:root(),
    guest_path       :: undefined | binary(),
    %% file: the open handle and current offset. The offset is the descriptor's
    %% own: every read and write through it is positional, so two descriptors
    %% on one file cannot move each other's cursor and an append decides where
    %% the end is per write rather than once at open. socket: the `wasi_sock'
    %% handle, and `buffer' holds bytes the socket gave up that did not fit in
    %% the module's read buffers. Keeping them is not an optimisation: a
    %% stream read returns whatever has arrived, so discarding the excess would
    %% lose bytes out of the middle of a stream, silently, under load only.
    handle           :: undefined | wasi_fs:handle() | wasi_sock:handle(),
    buffer = <<>>    :: binary(),
    offset = 0       :: non_neg_integer(),
    append = false   :: boolean(),
    %% Honoured on sockets only, where a read with nothing available is
    %% `EAGAIN' rather than a wait. Files ignore it: a local read does not
    %% block long enough for the distinction to mean anything.
    nonblock = false :: boolean(),
    %% `SYNC', `DSYNC' and `RSYNC' exactly as the guest asked for them at open.
    %% Every write here is followed by the write reaching the file, so there is
    %% nothing behaviourally to do with them; what a guest can tell is whether
    %% `fd_fdstat_get' gives back the flags it opened with, and it used to give
    %% back zero. Kept rather than acted on, and honestly so.
    syncflags = 0    :: non_neg_integer(),
    preopen = false  :: boolean()
}).

-endif.
