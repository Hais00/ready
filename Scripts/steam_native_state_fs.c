// SPDX-License-Identifier: GPL-3.0-only
/* Worker-local filesystem adaptation prototype. No Steam/DRM/account logic.
 *
 * Configure once, before loading any Valve image:
 * READY_STEAM_ORIGINAL_STATE_ROOT, READY_STEAM_PRIVATE_STATE_ROOT.
 * The exact original/Steam.AppBundle subtree remains original and READ ONLY.
 * Everything else below original maps to private; no original state is seeded.
 * HOME is never changed. Inject only into our own explicitly launched worker.
 *
 * This is NOT a sandbox or a complete filesystem virtualization layer. An
 * accompanying sandbox must deny original user state and unapproved profile
 * roots, permit only original code reads, and limit writable locations. Direct
 * syscalls, unhooked APIs, inherited descriptors and filesystem races require
 * that independent boundary. Component symlinks and '..' are rejected. Paths
 * outside the managed namespace pass through for the sandbox to decide.
 */
#define _DARWIN_C_SOURCE 1
#include <copyfile.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <libproc.h>
#include <pthread.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/xattr.h>
#include <unistd.h>
#include <utime.h>
#include <dirent.h>

#define INTERPOSE(replacement, original) \
  __attribute__((used)) static const struct { const void *new_fn; const void *old_fn; } \
  interpose_##original __attribute__((section("__DATA,__interpose"))) = \
  { (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&original }

static char original_root[PATH_MAX], private_root[PATH_MAX], code_root[PATH_MAX], private_code_root[PATH_MAX];
static char own_shm_prefix[20]; /* RS + 16 namespace hex + '_' + NUL */
static pthread_once_t configuration_once = PTHREAD_ONCE_INIT;

static bool below(const char *path, const char *root) {
    size_t size = strlen(root);
    return !strncmp(path, root, size) && (path[size] == 0 || path[size] == '/');
}

/* Lexical normalization does not dereference anything. Parent traversal is
 * refused even when it would stay inside a root, rather than being guessed. */
static int normalize(const char *path, char out[PATH_MAX]) {
    if (!path || path[0] != '/') { errno = EINVAL; return -1; }
    size_t used = 1; out[0] = '/'; out[1] = 0;
    const char *part = path;
    while (*part) {
        while (*part == '/') part++;
        const char *end = part; while (*end && *end != '/') end++;
        size_t n = (size_t)(end - part);
        if (!n) break;
        if (n == 2 && part[0] == '.' && part[1] == '.') { errno = EPERM; return -1; }
        if (!(n == 1 && *part == '.')) {
            if (used + n + 1 >= PATH_MAX) { errno = ENAMETOOLONG; return -1; }
            if (used > 1) out[used++] = '/';
            memcpy(out + used, part, n); used += n; out[used] = 0;
        }
        part = end;
    }
    return 0;
}

static int no_aliases(const char *path) {
    char part[PATH_MAX]; size_t n = strlen(path);
    if (n >= sizeof part) { errno = ENAMETOOLONG; return -1; }
    memcpy(part, path, n + 1);
    for (size_t i = 1; i <= n; i++) {
        if (part[i] != '/' && part[i] != 0) continue;
        char saved = part[i]; part[i] = 0;
        struct stat st;
        if (lstat(part, &st) == 0) {
            if (S_ISLNK(st.st_mode)) { errno = ELOOP; return -1; }
        } else if (errno == ENOENT) { return 0; }
        else { return -1; }
        part[i] = saved;
    }
    return 0;
}

static void configuration_error(void) {
    static const char text[] = "Ready state filesystem: invalid owned root configuration\n";
    (void)write(STDERR_FILENO, text, sizeof text - 1); _exit(78);
}

static void configure(void) {
    const char *a = getenv("READY_STEAM_ORIGINAL_STATE_ROOT");
    const char *b = getenv("READY_STEAM_PRIVATE_STATE_ROOT");
    if (!a || !b || normalize(a, original_root) || normalize(b, private_root) ||
        strcmp(a, original_root) || strcmp(b, private_root) || !strcmp(a, "/") ||
        !strcmp(b, "/") || below(a, b) || below(b, a) || no_aliases(a) || no_aliases(b)) configuration_error();
    struct stat old, own;
    if (lstat(a, &old) || lstat(b, &own) || !S_ISDIR(old.st_mode) || !S_ISDIR(own.st_mode) ||
        old.st_uid != getuid() || own.st_uid != getuid() || (own.st_mode & 077)) configuration_error();
    int count = snprintf(code_root, sizeof code_root, "%s/Steam.AppBundle", original_root);
    if (count < 0 || count >= (int)sizeof code_root || no_aliases(code_root)) configuration_error();
    count = snprintf(private_code_root, sizeof private_code_root, "%s/Steam.AppBundle", private_root);
    if (count < 0 || count >= (int)sizeof private_code_root) configuration_error();
    const char *ipc_namespace = getenv("READY_STEAM_IPC_NAMESPACE");
    if (ipc_namespace) {
        if (strnlen(ipc_namespace, 33) != 32) configuration_error();
        memcpy(own_shm_prefix, "RS", 2);
        for (size_t i = 0; i < 32; i++) {
            char ch = ipc_namespace[i];
            if (ch >= 'A' && ch <= 'F') ch = (char)(ch - 'A' + 'a');
            if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'))) configuration_error();
            if (i < 16) own_shm_prefix[i + 2] = ch;
        }
        own_shm_prefix[18] = '_';
    }
}
__attribute__((constructor)) static void ready_state_fs_start(void) {
    pthread_once(&configuration_once, configure);
}

/* Returns a physical path and whether it is in the managed namespace. The real
 * functions referenced from this interposer image are not interposed by dyld. */
static int mapped(int dirfd, const char *path, bool writing, char out[PATH_MAX], bool *managed) {
    pthread_once(&configuration_once, configure);
    if (!path) { errno = EFAULT; return -1; }
    char absolute[PATH_MAX], normalized[PATH_MAX];
    if (path[0] == '/') {
        if (strlen(path) >= sizeof absolute) { errno = ENAMETOOLONG; return -1; }
        strcpy(absolute, path);
    } else {
        char base[PATH_MAX];
        if (dirfd == AT_FDCWD) { if (!getcwd(base, sizeof base)) return -1; }
        else if (fcntl(dirfd, F_GETPATH, base) < 0) return -1;
        int n = snprintf(absolute, sizeof absolute, "%s/%s", base, path);
        if (n < 0 || n >= (int)sizeof absolute) { errno = ENAMETOOLONG; return -1; }
    }
    if (normalize(absolute, normalized)) return -1;
    bool private_code = below(normalized, private_code_root);
    bool code = below(normalized, code_root) || private_code;
    *managed = code || below(normalized, original_root) || below(normalized, private_root);
    if (code && writing) { errno = EROFS; return -1; }
    if (private_code) {
        int n = snprintf(out, PATH_MAX, "%s%s", code_root, normalized + strlen(private_code_root));
        if (n < 0 || n >= PATH_MAX) { errno = ENAMETOOLONG; return -1; }
    } else if (below(normalized, original_root) && !code) {
        int n = snprintf(out, PATH_MAX, "%s%s", private_root, normalized + strlen(original_root));
        if (n < 0 || n >= PATH_MAX) { errno = ENAMETOOLONG; return -1; }
    } else strcpy(out, normalized);
    if (*managed && no_aliases(out)) return -1;
    return 0;
}
static int path_for(const char *path, bool writing, char out[PATH_MAX]) {
    bool managed; return mapped(AT_FDCWD, path, writing, out, &managed);
}
static bool own_namespaced_shm(int fd) {
    if (!*own_shm_prefix) return false;
    struct pshm_fdinfo info; memset(&info, 0, sizeof info);
    /* This flavor succeeds only for a kernel POSIX SHM descriptor. A failed
     * pathname query alone is never evidence that a descriptor is safe. No FD
     * registry is used: duplicates and reused numbers are inspected anew. */
    if (proc_pidfdinfo(getpid(), fd, PROC_PIDFDPSHMINFO, &info, sizeof info) != sizeof info ||
        info.pshminfo.pshm_stat.vst_uid != getuid()) return false;
    const char *name = info.pshminfo.pshm_name;
    size_t size = strnlen(name, sizeof info.pshminfo.pshm_name);
    if (size == sizeof info.pshminfo.pshm_name) return false;
    if (size && *name == '/') { name++; size--; }
    if (size != 29 || strncmp(name, own_shm_prefix, 19)) return false;
    for (size_t i = 19; i < 29; i++)
        if (!((name[i] >= '0' && name[i] <= '9') || (name[i] >= 'a' && name[i] <= 'f'))) return false;
    return true;
}
static int fd_for(int fd, bool writing) {
    char path[PATH_MAX], resolved[PATH_MAX]; bool managed;
    pthread_once(&configuration_once, configure);
    if (fcntl(fd, F_GETPATH, path) < 0) {
        if (own_namespaced_shm(fd)) return 0;
        errno = EPERM; return -1;
    }
    if (mapped(AT_FDCWD, path, writing, resolved, &managed)) return -1;
    /* A preopened original-state descriptor must never operate on the original
     * merely because its name could be remapped. The caller must reopen it. */
    if (strcmp(path, resolved)) { errno = EPERM; return -1; }
    return 0;
}
static bool writes(int flags) {
    return (flags & O_ACCMODE) != O_RDONLY || (flags & (O_CREAT | O_TRUNC | O_APPEND));
}
static int ready_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    char out[PATH_MAX]; bool managed;
    if (mapped(AT_FDCWD, path, writes(flags), out, &managed)) return -1;
    return open(out, flags | (managed ? O_NOFOLLOW : 0), mode);
}
INTERPOSE(ready_open, open);
static int ready_openat(int fd, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    char out[PATH_MAX]; bool managed;
    if (mapped(fd, path, writes(flags), out, &managed)) return -1;
    return open(out, flags | (managed ? O_NOFOLLOW : 0), mode);
}
INTERPOSE(ready_openat, openat);
static int ready_creat(const char *path, mode_t mode) { return ready_open(path, O_WRONLY | O_CREAT | O_TRUNC, mode); }
INTERPOSE(ready_creat, creat);
static FILE *ready_fopen(const char *path, const char *mode) {
    if (!mode) { errno = EINVAL; return NULL; }
    char out[PATH_MAX];
    if (path_for(path, strpbrk(mode, "wa+") != NULL, out)) return NULL;
    return fopen(out, mode);
}
INTERPOSE(ready_fopen, fopen);
static FILE *ready_freopen(const char *path, const char *mode, FILE *stream) {
    if (!path || !mode) { errno = EINVAL; return NULL; }
    char out[PATH_MAX];
    if (path_for(path, strpbrk(mode, "wa+") != NULL, out)) return NULL;
    return freopen(out, mode, stream);
}
INTERPOSE(ready_freopen, freopen);
#define PATH_INT(name, writing, decl, call) \
static int ready_##name decl { char out[PATH_MAX]; if (path_for(path, writing, out)) return -1; return name call; } \
INTERPOSE(ready_##name, name)
PATH_INT(stat, false, (const char *path, struct stat *value), (out, value));
PATH_INT(lstat, false, (const char *path, struct stat *value), (out, value));
PATH_INT(statfs, false, (const char *path, struct statfs *value), (out, value));
PATH_INT(access, (mode & W_OK) != 0, (const char *path, int mode), (out, mode));
PATH_INT(mkdir, true, (const char *path, mode_t mode), (out, mode));
PATH_INT(unlink, true, (const char *path), (out));
PATH_INT(remove, true, (const char *path), (out));
PATH_INT(rmdir, true, (const char *path), (out));
PATH_INT(chmod, true, (const char *path, mode_t mode), (out, mode));
PATH_INT(chdir, false, (const char *path), (out));
PATH_INT(truncate, true, (const char *path, off_t length), (out, length));
PATH_INT(utime, true, (const char *path, const struct utimbuf *times), (out, times));
PATH_INT(utimes, true, (const char *path, const struct timeval *times), (out, times));
static DIR *ready_opendir(const char *path) { char out[PATH_MAX]; if (path_for(path, false, out)) return NULL; return opendir(out); }
INTERPOSE(ready_opendir, opendir);
static char *ready_realpath(const char *path, char *buffer) { char out[PATH_MAX]; if (path_for(path, false, out)) return NULL; return realpath(out, buffer); }
INTERPOSE(ready_realpath, realpath);
static int ready_rename(const char *from, const char *to) {
    char a[PATH_MAX], b[PATH_MAX]; if (path_for(from, true, a) || path_for(to, true, b)) return -1; return rename(a, b);
}
INTERPOSE(ready_rename, rename);
static int ready_renameat(int afd, const char *from, int bfd, const char *to) {
    char a[PATH_MAX], b[PATH_MAX]; bool managed;
    if (mapped(afd, from, true, a, &managed) || mapped(bfd, to, true, b, &managed)) return -1; return rename(a, b);
}
INTERPOSE(ready_renameat, renameat);
static int ready_mkdirat(int fd, const char *path, mode_t mode) { char out[PATH_MAX]; bool m; if (mapped(fd, path, true, out, &m)) return -1; return mkdir(out, mode); }
INTERPOSE(ready_mkdirat, mkdirat);
static int ready_unlinkat(int fd, const char *path, int flags) { char out[PATH_MAX]; bool m; if (mapped(fd, path, true, out, &m)) return -1; return unlinkat(AT_FDCWD, out, flags); }
INTERPOSE(ready_unlinkat, unlinkat);
static int ready_fstatat(int fd, const char *path, struct stat *value, int flags) { char out[PATH_MAX]; bool m; if (mapped(fd, path, false, out, &m)) return -1; return fstatat(AT_FDCWD, out, value, flags); }
INTERPOSE(ready_fstatat, fstatat);
static int ready_faccessat(int fd, const char *path, int mode, int flags) { char out[PATH_MAX]; bool m; if (mapped(fd, path, (mode & W_OK) != 0, out, &m)) return -1; return faccessat(AT_FDCWD, out, mode, flags); }
INTERPOSE(ready_faccessat, faccessat);
static ssize_t ready_readlink(const char *path, char *buffer, size_t size) { char out[PATH_MAX]; if (path_for(path, false, out)) return -1; return readlink(out, buffer, size); }
INTERPOSE(ready_readlink, readlink);
static ssize_t ready_readlinkat(int fd, const char *path, char *buffer, size_t size) { char out[PATH_MAX]; bool m; if (mapped(fd, path, false, out, &m)) return -1; return readlink(out, buffer, size); }
INTERPOSE(ready_readlinkat, readlinkat);
static int ready_symlink(const char *target, const char *path) {
    char a[PATH_MAX], b[PATH_MAX]; bool am, bm;
    if (mapped(AT_FDCWD, target, false, a, &am) || mapped(AT_FDCWD, path, true, b, &bm)) return -1;
    if (am || bm) { errno = EPERM; return -1; } return symlink(target, path);
}
INTERPOSE(ready_symlink, symlink);
static int ready_link(const char *from, const char *to) {
    char a[PATH_MAX], b[PATH_MAX]; bool am, bm;
    if (mapped(AT_FDCWD, from, false, a, &am) || mapped(AT_FDCWD, to, true, b, &bm)) return -1;
    if (am || bm) { errno = EPERM; return -1; } return link(from, to);
}
INTERPOSE(ready_link, link);
static int ready_copyfile(const char *from, const char *to, copyfile_state_t state, copyfile_flags_t flags) {
    char a[PATH_MAX], b[PATH_MAX];
    if (path_for(from, false, a) || path_for(to, true, b)) return -1;
    if (flags & COPYFILE_MOVE) { if (path_for(from, true, a)) return -1; }
    return copyfile(a, b, state, flags);
}
INTERPOSE(ready_copyfile, copyfile);
#define FD_INT(name, decl, call) \
static int ready_##name decl { if (fd_for(fd, true)) return -1; return name call; } \
INTERPOSE(ready_##name, name)
FD_INT(ftruncate, (int fd, off_t length), (fd, length));
FD_INT(fchmod, (int fd, mode_t mode), (fd, mode));
FD_INT(futimes, (int fd, const struct timeval *times), (fd, times));
static int ready_fchdir(int fd) { char path[PATH_MAX], out[PATH_MAX]; if (fcntl(fd, F_GETPATH, path) < 0 || path_for(path, false, out)) return -1; return chdir(out); }
INTERPOSE(ready_fchdir, fchdir);
static ssize_t ready_getxattr(const char *path, const char *name, void *value, size_t size, u_int32_t position, int options) { char out[PATH_MAX]; if (path_for(path, false, out)) return -1; return getxattr(out, name, value, size, position, options); }
INTERPOSE(ready_getxattr, getxattr);
PATH_INT(setxattr, true, (const char *path, const char *name, const void *value, size_t size, u_int32_t position, int options), (out, name, value, size, position, options));
PATH_INT(removexattr, true, (const char *path, const char *name, int options), (out, name, options));
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
/* Intercept the exact legacy spelling actually imported by the inspected
 * client, even when a newer SDK recommends the POSIX spelling instead. */
static int ready_spawn_chdir(posix_spawn_file_actions_t *actions, const char *path) {
    char out[PATH_MAX]; if (path_for(path, false, out)) return errno; return posix_spawn_file_actions_addchdir_np(actions, out);
}
INTERPOSE(ready_spawn_chdir, posix_spawn_file_actions_addchdir_np);
#pragma clang diagnostic pop
