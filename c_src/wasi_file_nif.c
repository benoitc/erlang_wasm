/* A capability-safe file API for WASI path resolution.
 *
 * This is the project's only NIF, and it exists for one reason: Erlang exposes
 * neither openat() nor O_NOFOLLOW, so a path resolved in Erlang and then opened
 * in Erlang has a window between the two in which a component can be replaced
 * with a symlink. filelib:safe_relative_path/2 closes every lexical and static
 * symlink escape, but it cannot close that race.
 *
 * The fix is to never resolve a name twice: walk the path one component at a
 * time with openat(..., O_NOFOLLOW) relative to the previously opened
 * directory, so each name is resolved exactly once, by the kernel, and no
 * symlink is ever followed.
 *
 * That requires owning the descriptor, which is why this is six functions and
 * not one: a NIF returning a raw fd would be useless, because Erlang's file
 * module cannot adopt one.
 *
 * Scope discipline: no WebAssembly semantics cross this boundary. Capability
 * decisions and rights masking stay in Erlang, and so does the choice of which
 * WASI errno a guest sees; what crosses is a POSIX error *name*, because only
 * <errno.h> knows which number means which name on this platform. Every call
 * is O(1) or bounded by an explicit length, and everything runs on a dirty I/O
 * scheduler because file I/O blocks.
 */

#include <erl_nif.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <dirent.h>
#include <stdlib.h>
#include <limits.h>

#ifndef O_DIRECTORY
#define O_DIRECTORY 0
#endif

/* Reads and writes are chunked so a single call cannot occupy a scheduler for
 * an unbounded time even on a dirty thread. */
#define MAX_IO_CHUNK (1024 * 1024)
#define MAX_PATH_LEN 4096

/* Not an errno. The path walk uses it for its own refusals so that "the
 * sandbox said no" and a real EACCES from the host stay distinguishable. */
#define E_REFUSED (-1)

static ErlNifResourceType *FILE_RES = NULL;

/* One lock per handle.
 *
 * Every operation used to test h->fd >= 0 and then use it, with nothing
 * between the test and the use. Two Erlang processes sharing a descriptor is
 * ordinary -- a guest hands one to an agent, a worker times out and something
 * closes -- and the interleaving is a use-after-close, not a crash: close(7)
 * returns the number to the kernel, the next open in any thread of the VM gets
 * 7 back, and the read in flight reads whatever that is. A WASI guest asks for
 * one file and is handed the contents of another.
 *
 * The lock is held across the syscall, so two reads of one handle serialise.
 * That is the right trade here: descriptors are per-instance and rarely shared,
 * and the alternative is duplicating the descriptor per call, which costs more
 * than the contention it avoids. The two places where the syscall really can
 * be long -- walking a path and reading a directory -- duplicate instead, so
 * they hold the lock only for the dup. */
typedef struct {
    ErlNifMutex *lock;
    int fd;
    int is_dir;
} file_handle;

static void file_dtor(ErlNifEnv *env, void *obj) {
    file_handle *h = (file_handle *)obj;
    (void)env;
    /* No lock. The destructor runs when the last reference is gone, so nothing
     * can be inside a NIF holding this handle: a NIF's pointer comes from a
     * term in its own environment, which keeps the resource alive for the
     * whole call. Destroying a mutex somebody holds is undefined, and taking
     * one nobody can contend for would only hide that.
     *
     * The garbage collector is the last line of defence: an Erlang process
     * that drops a handle without closing it must not leak a descriptor. */
    if (h->fd >= 0) { close(h->fd); h->fd = -1; }
    if (h->lock) { enif_mutex_destroy(h->lock); h->lock = NULL; }
}

/* Every field is set before the resource can be released, because releasing it
 * runs the destructor and the destructor reads all of them. */
static file_handle *new_handle(int fd, int is_dir) {
    file_handle *h = enif_alloc_resource(FILE_RES, sizeof(file_handle));
    if (!h) return NULL;
    h->lock = NULL;
    h->fd = fd;
    h->is_dir = is_dir;
    h->lock = enif_mutex_create("wasi_file");
    if (!h->lock) {
        /* The descriptor goes with it; the caller has no handle to close. */
        enif_release_resource(h);
        return NULL;
    }
    return h;
}

/* Take the lock and check the descriptor in one step. Answers 0 when the
 * handle is open and the caller holds the lock, EBADF otherwise with the lock
 * released. */
static int handle_lock(file_handle *h) {
    enif_mutex_lock(h->lock);
    if (h->fd < 0) { enif_mutex_unlock(h->lock); return EBADF; }
    return 0;
}

/* An errno by name, not by number.
 *
 * The number is meaningless outside this translation unit: ENOTEMPTY is 66 on
 * darwin and 39 on Linux, ELOOP is 62 and 40, and 63 is ENAMETOOLONG on one and
 * ENOSR on the other. Erlang had a single table of raw numbers and so was wrong
 * on whichever platform it was not written against, and everything it did not
 * recognise became EIO: ENOTEMPTY, EPERM and EBADF all reached the guest as
 * "I/O error".
 *
 * Only <errno.h> can do this correctly, so it does it here. The names are the
 * same atoms `file:' answers, which is what `wasi_fs:map_posix/1' already maps,
 * so both backends now go through one table instead of two.
 *
 * This does not put WASI semantics in C. The atom is a POSIX error name; which
 * WASI errno a guest sees is still decided in Erlang. */
static const char *errno_name(int e) {
    switch (e) {
    case EACCES:       return "eacces";
    case EAGAIN:       return "eagain";
    case EBADF:        return "ebadf";
    case EBUSY:        return "ebusy";
    case EEXIST:       return "eexist";
    case EFAULT:       return "efault";
    case EFBIG:        return "efbig";
    case EINVAL:       return "einval";
    case EIO:          return "eio";
    case EISDIR:       return "eisdir";
    case ELOOP:        return "eloop";
    case EMFILE:       return "emfile";
    case ENAMETOOLONG: return "enametoolong";
    case ENFILE:       return "enfile";
    case ENOENT:       return "enoent";
    case ENOMEM:       return "enomem";
    case ENOSPC:       return "enospc";
    case ENOSYS:       return "enosys";
    case ENOTDIR:      return "enotdir";
    case ENOTEMPTY:    return "enotempty";
    case ENOTSUP:      return "enotsup";
    case ENXIO:        return "enxio";
    case EPERM:        return "eperm";
    case EPIPE:        return "epipe";
    case EROFS:        return "erofs";
    case ESPIPE:       return "espipe";
    case EXDEV:        return "exdev";
    /* Everything else keeps its shape rather than being flattened, so an
     * unmapped error is visible as itself in a report. */
    default:           return NULL;
    }
}

static ERL_NIF_TERM mk_errno(ErlNifEnv *env, int e) {
    /* Not an errno: the walk refused this path. Distinct from any host error,
     * because "you may not name that" and "the OS said no" are different
     * answers and a guest can act on the difference. */
    if (e == E_REFUSED)
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "enotcapable"));
    const char *name = errno_name(e);
    ERL_NIF_TERM reason = name ? enif_make_atom(env, name)
                               : enif_make_tuple2(env,
                                     enif_make_atom(env, "unknown_errno"),
                                     enif_make_int(env, e));
    return enif_make_tuple2(env, enif_make_atom(env, "error"), reason);
}

static ERL_NIF_TERM mk_ok(ErlNifEnv *env, ERL_NIF_TERM v) {
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), v);
}

/* Walk a relative path one component at a time.
 *
 * Each component is opened with O_NOFOLLOW relative to the previous directory
 * descriptor, so each name is resolved exactly once, by the kernel, and nothing
 * between the check and the use can substitute a component. That is the whole
 * reason this NIF exists.
 *
 * O_NOFOLLOW makes a symlink *fail* rather than be followed, so following one
 * is done here, deliberately, rather than by the kernel: read the link, walk
 * its text under the same rules, and continue from the result. A link is
 * therefore worth exactly what a literal path would be worth, and no more.
 *
 * Containment is a depth counter rather than a ban.
 *
 * ".." used to be refused outright. Preview 1 allows it as long as it stays
 * inside the preopen, and ordinary programs produce it, so it is permitted
 * while `depth' is above zero and refused at zero. A path can go up and back
 * down and can never reach the root, which is true by construction: depth
 * counts components consumed below the preopen, and a symlink's text is walked
 * from the directory it sits in with that same counter.
 *
 * Refusals by this walk are E_REFUSED, not an errno. Borrowing EACCES for them
 * meant a real EACCES from the host and "the sandbox said no" arrived at the
 * guest as the same code.
 */
/* Eight, which is what Linux allows per path. It has to be a constant a cycle
 * cannot outrun; a self-referential link is otherwise not an error but a hang. */
#define MAX_SYMLINKS 8

static int walk_from(int dirfd, const char *path, int flags, mode_t mode,
                     int depth, int budget, int follow_final, int *out_fd);

/* Open one component, following it if it turns out to be a symlink.
 *
 * `depth' is how far below the preopen `cur' sits, and is what "." and ".."
 * are counted against. On success the caller owns *out_fd and *out_depth holds
 * the new depth.
 */
/* `may_follow' is what `LOOKUPFLAGS_SYMLINK_FOLLOW' decides for the final
 * component. Intermediate components are always followed, which is what a path
 * means; only the thing at the end is a choice, and Preview 1 gives it to the
 * caller. Refusing to follow answers ELOOP, which is what the guest is looking
 * for: `nofollow_errors' and `dangling_symlink' both assert it. */
static int step(int cur, const char *comp, int oflags, mode_t mode,
                int depth, int budget, int may_follow,
                int *out_fd, int *out_depth) {
    if (strcmp(comp, ".") == 0) {
        int fd = openat(cur, ".", O_RDONLY | O_DIRECTORY);
        if (fd < 0) return errno;
        *out_fd = fd; *out_depth = depth;
        return 0;
    }
    if (strcmp(comp, "..") == 0) {
        /* At the root there is no parent inside the capability. */
        if (depth == 0) return E_REFUSED;
        int fd = openat(cur, "..", O_RDONLY | O_DIRECTORY);
        if (fd < 0) return errno;
        *out_fd = fd; *out_depth = depth - 1;
        return 0;
    }

    int fd = openat(cur, comp, oflags, mode);
    if (fd >= 0) { *out_fd = fd; *out_depth = depth + 1; return 0; }

    /* ELOOP is O_NOFOLLOW's way of saying "that is a symlink". ENOTDIR is the
     * same answer when the caller also asked for O_DIRECTORY, and ENXIO on
     * some systems; anything else is a real failure. */
    int e = errno;
    if (e != ELOOP && e != ENOTDIR && e != ENXIO) return e;
    if (!may_follow) return ELOOP;
    if (budget <= 0) return ELOOP;

    char target[MAX_PATH_LEN];
    ssize_t len = readlinkat(cur, comp, target, sizeof(target) - 1);
    if (len < 0) {
        /* Not a symlink after all, so the original error stands. */
        return e;
    }
    target[len] = '\0';
    /* An absolute link target is refused for the same reason an absolute guest
     * path is: resolving it against the preopen would silently mean something
     * other than what it says. */
    if (target[0] == '/') return E_REFUSED;

    /* The link's text, from the directory the link sits in, at the same depth.
     * The last component of the target is what the caller asked for, so it
     * carries the caller's flags. */
    int rc = walk_from(cur, target, oflags, mode, depth, budget - 1, 1, out_fd);
    if (rc != 0) return rc;
    /* Depth is not knowable exactly through a link that went up and down, and
     * does not need to be: the recursion enforced containment itself, and
     * anything after this continues from a directory already inside. Counting
     * it as one step down is the conservative answer, since it can only make a
     * later ".." refuse sooner. */
    *out_depth = depth + 1;
    return 0;
}

/* `path' relative to `dirfd', which sits `depth' components below the preopen. */
static int walk_from(int dirfd, const char *path, int flags, mode_t mode,
                     int depth, int budget, int follow_final, int *out_fd) {
    char buf[MAX_PATH_LEN];
    size_t n = strlen(path);
    if (n == 0) return EINVAL;
    if (n >= sizeof(buf)) return ENAMETOOLONG;
    /* An absolute path is refused rather than reinterpreted. strtok_r would
     * otherwise strip the leading slash and resolve "/etc/passwd" against the
     * preopen, which is safe but silently means something else than the caller
     * asked for. Refusing keeps the capability model legible. */
    if (path[0] == '/') return E_REFUSED;
    memcpy(buf, path, n + 1);

    int cur = dirfd;
    int cur_owned = 0;
    int d = depth;
    char *save = NULL;
    char *comp = strtok_r(buf, "/", &save);

    while (comp) {
        char *next = strtok_r(NULL, "/", &save);
        int last = (next == NULL);
        int oflags = last ? (flags | O_NOFOLLOW)
                          : (O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        int fd, nd;
        int rc = step(cur, comp, oflags, mode, d, budget,
                      last ? follow_final : 1, &fd, &nd);
        if (cur_owned) close(cur);
        if (rc != 0) return rc;
        cur = fd;
        cur_owned = 1;
        d = nd;
        comp = next;
    }
    if (!cur_owned) return EINVAL;               /* path was "." or empty */
    *out_fd = cur;
    return 0;
}

static int walk_open(int dirfd, const char *path, int flags, mode_t mode,
                     int follow_final, int *out_fd) {
    return walk_from(dirfd, path, flags, mode, 0, MAX_SYMLINKS, follow_final,
                     out_fd);
}

/* Walk to the *parent* of the last component, leaving that component unopened.
 *
 * Same discipline as walk_open. What differs is the end. An operation like
 * unlink or mkdir acts on a name inside a directory rather than on an open
 * file, so the walk stops one short and hands back the directory and the name
 * to act on. The `*at' call that follows is one syscall against a descriptor
 * nobody can substitute, which is what closes the window between checking a
 * path and acting on it.
 *
 * The last component is never followed here even if it is a symlink, and that
 * is right: unlink, rmdir and rename act on the link itself, not on what it
 * points at.
 */
static int walk_parent(int dirfd, const char *path, char *buf, size_t buflen,
                       int *out_fd, int *out_owned, char **out_name) {
    size_t n = strlen(path);
    if (n == 0) return EINVAL;
    if (n >= buflen) return ENAMETOOLONG;
    if (path[0] == '/') return E_REFUSED;
    memcpy(buf, path, n + 1);

    int cur = dirfd, owned = 0, d = 0;
    char *save = NULL, *last = NULL;
    char *comp = strtok_r(buf, "/", &save);

    while (comp) {
        char *next = strtok_r(NULL, "/", &save);
        if (next == NULL) { last = comp; break; }
        int fd, nd;
        int rc = step(cur, comp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW, 0,
                      d, MAX_SYMLINKS, 1, &fd, &nd);
        if (owned) close(cur);
        if (rc != 0) return rc;
        cur = fd;
        owned = 1;
        d = nd;
        comp = next;
    }
    /* A path naming no component, "." or "/./", is the directory itself, and
     * asking about it is ordinary: `std::fs::read_dir` stats "." before it
     * lists anything. Refusing it made the whole listing come back empty. The
     * name is handed on as "." so `fstatat' answers about the directory, and
     * the operations that must not touch it -- mkdir, unlink, rmdir -- are
     * refused by the kernel rather than by a rule of ours. */
    static char dot[] = ".";
    if (last == NULL) last = dot;
    /* ".." as the final component would act on the parent by name, which the
     * depth counter cannot see. It is only ever the directory itself that is
     * meant, and `step' has already enforced containment for everything before
     * it, so this is refused rather than reinterpreted. */
    if (strcmp(last, "..") == 0) {
        if (owned) close(cur);
        return E_REFUSED;
    }
    *out_fd = cur;
    *out_owned = owned;
    *out_name = last;
    return 0;
}

/* A directory handle's descriptor, duplicated under its lock. The copy is
 * ours, so it cannot be closed underneath a walk that takes many syscalls. */
static int dir_dup(file_handle *dir, int *out) {
    int e = handle_lock(dir);
    if (e != 0) return e;
    int fd = dup(dir->fd);
    e = (fd < 0) ? errno : 0;
    enif_mutex_unlock(dir->lock);
    if (e != 0) return e;
    *out = fd;
    return 0;
}

/* Operations that act on a name inside a directory. The code is chosen in
 * Erlang, where the WASI call it serves is; nothing about WebAssembly crosses
 * this boundary. */
#define OP_MKDIR    1
#define OP_UNLINK   2
#define OP_RMDIR    3
#define OP_SYMLINK  4
#define OP_READLINK 5
#define OP_STAT     6
#define OP_SETTIMES 8
#define OP_STAT_FOLLOW 9
#define OP_SETTIMES_FOLLOW 10

/* Timestamps in nanoseconds, which is what the WASI filestat holds.
 *
 * st_atim is POSIX.1-2008; darwin spells the same field st_atimespec and
 * defines _DARWIN_FEATURE_64_BIT_INODE rather than the POSIX name. Both give
 * whole seconds through st_atime, so the fallback below is exact to the second
 * rather than absent. */
#if defined(__APPLE__)
#define STAT_NSEC(st, which) \
    ((ErlNifUInt64)(st)->st_##which##timespec.tv_sec * 1000000000ULL + \
     (ErlNifUInt64)(st)->st_##which##timespec.tv_nsec)
#else
#define STAT_NSEC(st, which) \
    ((ErlNifUInt64)(st)->st_##which##tim.tv_sec * 1000000000ULL + \
     (ErlNifUInt64)(st)->st_##which##tim.tv_nsec)
#endif

/* A mask byte then two 64-bit little-endian second/nanosecond pairs.
 *
 * The mask says which of the two to set; anything unset becomes UTIME_OMIT
 * here rather than in Erlang. UTIME_OMIT is a platform constant, and writing
 * its value on the Erlang side put it in the wrong field on this platform and
 * set the access time to the year 2004. The same argument as the errno names:
 * only <sys/stat.h> knows. */
static int decode_times(ErlNifBinary *arg, struct timespec ts[2]) {
    if (arg->size != 33) return 0;
    const unsigned char *a = arg->data;
    unsigned mask = a[0];
    for (int i = 0; i < 2; i++) {
        if (!(mask & (1u << i))) {
            ts[i].tv_sec = 0;
            ts[i].tv_nsec = UTIME_OMIT;
            continue;
        }
        ErlNifUInt64 sec = 0, nsec = 0;
        for (int b = 7; b >= 0; b--) sec = (sec << 8) | a[1 + i * 16 + b];
        for (int b = 7; b >= 0; b--) nsec = (nsec << 8) | a[1 + i * 16 + 8 + b];
        ts[i].tv_sec = (time_t)sec;
        ts[i].tv_nsec = (long)nsec;
    }
    return 1;
}

static ERL_NIF_TERM stat_map(ErlNifEnv *env, struct stat *st) {
    const char *type = S_ISDIR(st->st_mode) ? "directory"
                     : S_ISREG(st->st_mode) ? "regular"
                     : S_ISLNK(st->st_mode) ? "symlink" : "other";
    ERL_NIF_TERM map = enif_make_new_map(env);
    enif_make_map_put(env, map, enif_make_atom(env, "size"),
                      enif_make_int64(env, (ErlNifSInt64)st->st_size), &map);
    enif_make_map_put(env, map, enif_make_atom(env, "type"),
                      enif_make_atom(env, type), &map);
    /* Every field the WASI filestat carries. They used to stop at size and
     * type, and `wasi_preview1:filestat/2' wrote zero for the rest: two files
     * in one directory reported the same inode, and a guest that set a
     * timestamp and subtracted the value it read back underflowed. */
    enif_make_map_put(env, map, enif_make_atom(env, "inode"),
                      enif_make_uint64(env, (ErlNifUInt64)st->st_ino), &map);
    enif_make_map_put(env, map, enif_make_atom(env, "dev"),
                      enif_make_uint64(env, (ErlNifUInt64)st->st_dev), &map);
    enif_make_map_put(env, map, enif_make_atom(env, "nlink"),
                      enif_make_uint64(env, (ErlNifUInt64)st->st_nlink), &map);
    enif_make_map_put(env, map, enif_make_atom(env, "atim"),
                      enif_make_uint64(env, STAT_NSEC(st, a)), &map);
    enif_make_map_put(env, map, enif_make_atom(env, "mtim"),
                      enif_make_uint64(env, STAT_NSEC(st, m)), &map);
    enif_make_map_put(env, map, enif_make_atom(env, "ctim"),
                      enif_make_uint64(env, STAT_NSEC(st, c)), &map);
    return map;
}

/* path_op(Dir, RelPath, Op, Arg) */
static ERL_NIF_TERM path_op_nif(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[]) {
    file_handle *dir;
    ErlNifBinary rel, arg;
    int op;
    (void)argc;
    if (!enif_get_resource(env, argv[0], FILE_RES, (void **)&dir) ||
        !enif_inspect_binary(env, argv[1], &rel) ||
        !enif_get_int(env, argv[2], &op) ||
        !enif_inspect_binary(env, argv[3], &arg))
        return enif_make_badarg(env);
    if (rel.size >= MAX_PATH_LEN || arg.size >= MAX_PATH_LEN)
        return mk_errno(env, ENAMETOOLONG);

    int base;
    int e = dir_dup(dir, &base);
    if (e != 0) return mk_errno(env, e);

    char path[MAX_PATH_LEN], buf[MAX_PATH_LEN];
    memcpy(path, rel.data, rel.size);
    path[rel.size] = '\0';

    int pfd, owned;
    char *name;
    e = walk_parent(base, path, buf, sizeof(buf), &pfd, &owned, &name);
    if (e != 0) { close(base); return mk_errno(env, e); }

    ERL_NIF_TERM result;
    int rc = 0;
    switch (op) {
    case OP_MKDIR:
        rc = mkdirat(pfd, name, 0755);
        result = enif_make_atom(env, "ok");
        break;
    case OP_UNLINK:
        rc = unlinkat(pfd, name, 0);
        result = enif_make_atom(env, "ok");
        break;
    case OP_RMDIR:
        rc = unlinkat(pfd, name, AT_REMOVEDIR);
        result = enif_make_atom(env, "ok");
        break;
    case OP_SYMLINK: {
        char target[MAX_PATH_LEN];
        memcpy(target, arg.data, arg.size);
        target[arg.size] = '\0';
        /* The target is data, stored verbatim and never resolved here. What
         * stops it being followed out of the sandbox is that every later walk
         * refuses to follow a symlink at all. */
        rc = symlinkat(target, pfd, name);
        result = enif_make_atom(env, "ok");
        break;
    }
    case OP_READLINK: {
        char link[MAX_PATH_LEN];
        ssize_t n = readlinkat(pfd, name, link, sizeof(link) - 1);
        if (n < 0) { rc = -1; result = enif_make_atom(env, "ok"); break; }
        ERL_NIF_TERM b;
        unsigned char *p = enif_make_new_binary(env, (size_t)n, &b);
        memcpy(p, link, (size_t)n);
        result = mk_ok(env, b);
        break;
    }
    case OP_STAT_FOLLOW:
    case OP_STAT: {
        struct stat st;
        /* Not following the final component either: `path_filestat_get' with
         * no follow flag is asking about the link, and following it would be
         * resolving a name this walk deliberately did not. */
        rc = fstatat(pfd, name, &st,
                     (op == OP_STAT_FOLLOW) ? 0 : AT_SYMLINK_NOFOLLOW);
        result = (rc == 0) ? mk_ok(env, stat_map(env, &st))
                           : enif_make_atom(env, "ok");
        break;
    }
    case OP_SETTIMES_FOLLOW:
    case OP_SETTIMES: {
        /* Arg is four 64-bit little-endian words: atime seconds and
         * nanoseconds, then mtime. UTIME_OMIT in the nanoseconds field leaves
         * that stamp alone, which is how the WASI `fstflags' bits are carried
         * across; Erlang builds the pair and this only applies it.
         *
         * AT_SYMLINK_NOFOLLOW for the same reason OP_STAT uses it: the walk
         * did not follow the final component, so neither does this. */
        struct timespec ts[2];
        if (!decode_times(&arg, ts)) {
            if (owned) close(pfd);
            close(base);
            return enif_make_badarg(env);
        }
        rc = utimensat(pfd, name, ts,
                       (op == OP_SETTIMES_FOLLOW) ? 0 : AT_SYMLINK_NOFOLLOW);
        result = enif_make_atom(env, "ok");
        break;
    }
    default:
        if (owned) close(pfd);
        close(base);
        return enif_make_badarg(env);
    }
    int saved = errno;
    if (owned) close(pfd);
    close(base);
    if (rc < 0) return mk_errno(env, saved);
    return result;
}

#define OP_RENAME 7
#define OP_LINK   8

/* path_op2(Dir1, Rel1, Dir2, Rel2, Op)
 *
 * Rename and link name two places, and each is resolved against its own
 * preopen. Resolving only one would let a module move a file out of the
 * sandbox by naming the destination carelessly. */
static ERL_NIF_TERM path_op2_nif(ErlNifEnv *env, int argc,
                                 const ERL_NIF_TERM argv[]) {
    file_handle *d1, *d2;
    ErlNifBinary r1, r2;
    int op;
    (void)argc;
    if (!enif_get_resource(env, argv[0], FILE_RES, (void **)&d1) ||
        !enif_inspect_binary(env, argv[1], &r1) ||
        !enif_get_resource(env, argv[2], FILE_RES, (void **)&d2) ||
        !enif_inspect_binary(env, argv[3], &r2) ||
        !enif_get_int(env, argv[4], &op))
        return enif_make_badarg(env);
    if (r1.size >= MAX_PATH_LEN || r2.size >= MAX_PATH_LEN)
        return mk_errno(env, ENAMETOOLONG);

    int b1, b2;
    int e = dir_dup(d1, &b1);
    if (e != 0) return mk_errno(env, e);
    e = dir_dup(d2, &b2);
    if (e != 0) { close(b1); return mk_errno(env, e); }

    char p1[MAX_PATH_LEN], p2[MAX_PATH_LEN], f1[MAX_PATH_LEN], f2[MAX_PATH_LEN];
    memcpy(p1, r1.data, r1.size); p1[r1.size] = '\0';
    memcpy(p2, r2.data, r2.size); p2[r2.size] = '\0';

    int pfd1, own1, pfd2, own2;
    char *n1, *n2;
    e = walk_parent(b1, p1, f1, sizeof(f1), &pfd1, &own1, &n1);
    if (e != 0) { close(b1); close(b2); return mk_errno(env, e); }
    e = walk_parent(b2, p2, f2, sizeof(f2), &pfd2, &own2, &n2);
    if (e != 0) {
        if (own1) close(pfd1);
        close(b1); close(b2);
        return mk_errno(env, e);
    }

    int rc = (op == OP_RENAME) ? renameat(pfd1, n1, pfd2, n2)
           : (op == OP_LINK)   ? linkat(pfd1, n1, pfd2, n2, 0)
           : -2;
    int saved = errno;
    if (own1) close(pfd1);
    if (own2) close(pfd2);
    close(b1); close(b2);
    if (rc == -2) return enif_make_badarg(env);
    if (rc < 0) return mk_errno(env, saved);
    return enif_make_atom(env, "ok");
}

/* open_at(DirHandle | RootPath, RelPath, Flags) */
static ERL_NIF_TERM open_at_nif(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[]) {
    ErlNifBinary rel;
    file_handle *dir = NULL;
    int dirfd, flags, follow;
    char root[MAX_PATH_LEN];
    (void)argc;

    int dirfd_owned = 0;
    if (enif_get_resource(env, argv[0], FILE_RES, (void **)&dir)) {
        /* Duplicated under the lock rather than walked under it. Walking a
         * path is many syscalls and would serialise every open beneath one
         * preopen; a dup is one, and the copy cannot be closed underneath us
         * because it is ours. */
        int e = handle_lock(dir);
        if (e != 0) return mk_errno(env, e);
        dirfd = dup(dir->fd);
        e = (dirfd < 0) ? errno : 0;
        enif_mutex_unlock(dir->lock);
        if (e != 0) return mk_errno(env, e);
        dirfd_owned = 1;
    } else {
        /* A preopen is named by path exactly once, when it is granted. */
        if (enif_get_string(env, argv[0], root, sizeof(root), ERL_NIF_LATIN1) <= 0)
            return enif_make_badarg(env);
        dirfd = open(root, O_RDONLY | O_DIRECTORY);
        if (dirfd < 0) return mk_errno(env, errno);
        dirfd_owned = 1;
    }
    if (!enif_inspect_binary(env, argv[1], &rel) ||
        !enif_get_int(env, argv[2], &flags) ||
        !enif_get_int(env, argv[3], &follow)) {
        if (dirfd_owned) close(dirfd);
        return enif_make_badarg(env);
    }
    if (rel.size >= MAX_PATH_LEN) {
        if (dirfd_owned) close(dirfd);
        return mk_errno(env, ENAMETOOLONG);
    }
    char path[MAX_PATH_LEN];
    memcpy(path, rel.data, rel.size);
    path[rel.size] = '\0';

    int fd = -1;
    int err = walk_open(dirfd, path, flags, 0644, follow, &fd);
    if (dirfd_owned) close(dirfd);
    if (err != 0) return mk_errno(env, err);

    struct stat st;
    int is_dir = (fstat(fd, &st) == 0) && S_ISDIR(st.st_mode);

    file_handle *h = new_handle(fd, is_dir);
    if (!h) { close(fd); return mk_errno(env, ENOMEM); }
    ERL_NIF_TERM term = enif_make_resource(env, h);
    enif_release_resource(h);
    return mk_ok(env, term);
}

/* open_dir(Path) -- a preopen root, opened once.
 *
 * Separate from open_at because the walk deliberately has no answer for a path
 * that names no component: "." is skipped and an empty walk is an error, which
 * is right for a guest path and wrong for the root the walk starts from. This
 * is the only place a path is resolved by name rather than component by
 * component, and it happens once per preopen rather than once per open. */
static ERL_NIF_TERM open_dir_nif(ErlNifEnv *env, int argc,
                                 const ERL_NIF_TERM argv[]) {
    char root[MAX_PATH_LEN];
    (void)argc;
    if (enif_get_string(env, argv[0], root, sizeof(root), ERL_NIF_LATIN1) <= 0)
        return enif_make_badarg(env);
    int fd = open(root, O_RDONLY | O_DIRECTORY);
    if (fd < 0) return mk_errno(env, errno);
    file_handle *h = new_handle(fd, 1);
    if (!h) { close(fd); return mk_errno(env, ENOMEM); }
    ERL_NIF_TERM term = enif_make_resource(env, h);
    enif_release_resource(h);
    return mk_ok(env, term);
}

static ERL_NIF_TERM pread_nif(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
    file_handle *h;
    ErlNifSInt64 off;
    unsigned long len;
    (void)argc;
    if (!enif_get_resource(env, argv[0], FILE_RES, (void **)&h) ||
        !enif_get_int64(env, argv[1], &off) ||
        !enif_get_ulong(env, argv[2], &len))
        return enif_make_badarg(env);
    if (len > MAX_IO_CHUNK) len = MAX_IO_CHUNK;

    ErlNifBinary bin;
    if (!enif_alloc_binary(len, &bin)) return mk_errno(env, ENOMEM);
    int lerr = handle_lock(h);
    if (lerr != 0) { enif_release_binary(&bin); return mk_errno(env, lerr); }
    ssize_t n = pread(h->fd, bin.data, len, (off_t)off);
    int perr = (n < 0) ? errno : 0;
    enif_mutex_unlock(h->lock);
    if (n < 0) { enif_release_binary(&bin); return mk_errno(env, perr); }
    if (n == 0) { enif_release_binary(&bin); return enif_make_atom(env, "eof"); }
    if ((unsigned long)n < len) enif_realloc_binary(&bin, n);
    return mk_ok(env, enif_make_binary(env, &bin));
}

static ERL_NIF_TERM pwrite_nif(ErlNifEnv *env, int argc,
                               const ERL_NIF_TERM argv[]) {
    file_handle *h;
    ErlNifSInt64 off;
    ErlNifBinary data;
    (void)argc;
    if (!enif_get_resource(env, argv[0], FILE_RES, (void **)&h) ||
        !enif_get_int64(env, argv[1], &off) ||
        !enif_inspect_binary(env, argv[2], &data))
        return enif_make_badarg(env);
    size_t len = data.size > MAX_IO_CHUNK ? MAX_IO_CHUNK : data.size;
    int lerr = handle_lock(h);
    if (lerr != 0) return mk_errno(env, lerr);
    ssize_t n = pwrite(h->fd, data.data, len, (off_t)off);
    int perr = (n < 0) ? errno : 0;
    enif_mutex_unlock(h->lock);
    if (n < 0) return mk_errno(env, perr);
    return mk_ok(env, enif_make_ulong(env, (unsigned long)n));
}

/* futimens(Handle, AtimeSpec, MtimeSpec): four 64-bit little-endian words, the
 * same shape OP_SETTIMES takes. An open descriptor has no name to walk, so
 * `fd_filestat_set_times' cannot go through the path ops. */
static ERL_NIF_TERM futimes_nif(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[]) {
    file_handle *h;
    ErlNifBinary arg;
    struct timespec ts[2];
    (void)argc;
    if (!enif_get_resource(env, argv[0], FILE_RES, (void **)&h) ||
        !enif_inspect_binary(env, argv[1], &arg))
        return enif_make_badarg(env);
    if (!decode_times(&arg, ts)) return enif_make_badarg(env);
    int lerr = handle_lock(h);
    if (lerr != 0) return mk_errno(env, lerr);
    int rc = futimens(h->fd, ts);
    int serr = (rc < 0) ? errno : 0;
    enif_mutex_unlock(h->lock);
    if (rc < 0) return mk_errno(env, serr);
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM fstat_nif(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
    file_handle *h;
    struct stat st;
    (void)argc;
    if (!enif_get_resource(env, argv[0], FILE_RES, (void **)&h))
        return enif_make_badarg(env);
    int lerr = handle_lock(h);
    if (lerr != 0) return mk_errno(env, lerr);
    int rc = fstat(h->fd, &st);
    int serr = (rc < 0) ? errno : 0;
    enif_mutex_unlock(h->lock);
    if (rc < 0) return mk_errno(env, serr);
    /* The same map `stat_map' builds for a name. It was a second copy of that
     * code and the two drifted the moment fields were added to one of them. */
    return mk_ok(env, stat_map(env, &st));
}

static ERL_NIF_TERM readdir_nif(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[]) {
    file_handle *h;
    (void)argc;
    if (!enif_get_resource(env, argv[0], FILE_RES, (void **)&h))
        return enif_make_badarg(env);
    /* fdopendir takes ownership of the descriptor, so it gets a duplicate:
     * the resource must stay usable after this call. Duplicating under the
     * lock and reading the directory outside it means a long listing does not
     * hold up a close. */
    int lerr = handle_lock(h);
    if (lerr != 0) return mk_errno(env, lerr);
    if (!h->is_dir) { enif_mutex_unlock(h->lock); return mk_errno(env, ENOTDIR); }
    int dup_fd = dup(h->fd);
    int derr = (dup_fd < 0) ? errno : 0;
    enif_mutex_unlock(h->lock);
    if (dup_fd < 0) return mk_errno(env, derr);
    DIR *d = fdopendir(dup_fd);
    if (!d) { int e = errno; close(dup_fd); return mk_errno(env, e); }
    rewinddir(d);

    ERL_NIF_TERM list = enif_make_list(env, 0);
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        size_t nlen = strlen(de->d_name);
        ERL_NIF_TERM nb;
        unsigned char *p = enif_make_new_binary(env, nlen, &nb);
        memcpy(p, de->d_name, nlen);
        list = enif_make_list_cell(env, nb, list);
    }
    closedir(d);
    return mk_ok(env, list);
}

static ERL_NIF_TERM ftruncate_nif(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]) {
    file_handle *h;
    ErlNifSInt64 len;
    (void)argc;
    if (!enif_get_resource(env, argv[0], FILE_RES, (void **)&h) ||
        !enif_get_int64(env, argv[1], &len) || len < 0)
        return enif_make_badarg(env);
    int lerr = handle_lock(h);
    if (lerr != 0) return mk_errno(env, lerr);
    int rc = ftruncate(h->fd, (off_t)len);
    int terr = (rc < 0) ? errno : 0;
    enif_mutex_unlock(h->lock);
    if (rc < 0) return mk_errno(env, terr);
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM fsync_nif(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
    file_handle *h;
    (void)argc;
    if (!enif_get_resource(env, argv[0], FILE_RES, (void **)&h))
        return enif_make_badarg(env);
    int lerr = handle_lock(h);
    if (lerr != 0) return mk_errno(env, lerr);
    int rc = fsync(h->fd);
    int serr = (rc < 0) ? errno : 0;
    enif_mutex_unlock(h->lock);
    /* A pipe or a socket cannot be synced and does not need to be. Reporting
     * that as a failure would make a guest's defensive fsync fatal. */
    if (rc < 0 && serr != EINVAL && serr != ENOTSUP) return mk_errno(env, serr);
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM close_nif(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
    file_handle *h;
    (void)argc;
    if (!enif_get_resource(env, argv[0], FILE_RES, (void **)&h))
        return enif_make_badarg(env);
    enif_mutex_lock(h->lock);
    if (h->fd >= 0) { close(h->fd); h->fd = -1; }
    enif_mutex_unlock(h->lock);
    return enif_make_atom(env, "ok");
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    (void)priv; (void)info;
    FILE_RES = enif_open_resource_type(env, NULL, "wasi_file",
                                       file_dtor, ERL_NIF_RT_CREATE, NULL);
    return FILE_RES == NULL ? -1 : 0;
}

/* All of these block, which is exactly what dirty I/O schedulers are for. */
static ErlNifFunc funcs[] = {
    {"open_at",  4, open_at_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"open_dir", 1, open_dir_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"pread",    3, pread_nif,   ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"pwrite",   3, pwrite_nif,  ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"fstat",    1, fstat_nif,   ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"futimes",  2, futimes_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"readdir",  1, readdir_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"close",    1, close_nif,   ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"ftruncate", 2, ftruncate_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"fsync",    1, fsync_nif,   ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"path_op",  4, path_op_nif,  ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"path_op2", 5, path_op2_nif, ERL_NIF_DIRTY_JOB_IO_BOUND}
};

ERL_NIF_INIT(wasi_file_nif, funcs, load, NULL, NULL, NULL)
