// SPDX-License-Identifier: GPL-3.0-only
// Interoperates with StoreBridge/install_lock.py. Only libSystem is linked.
#include "InstallationLease.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

typedef struct {
  int *fds;
  size_t count, capacity;
} Lease;
static void close_lease(Lease *lease) {
  for (size_t i = 0; i < lease->count; i++)
    close(lease->fds[i]);
  free(lease->fds);
  memset(lease, 0, sizeof(*lease));
}
static int append_fd(Lease *lease, int fd) {
  if (lease->count == lease->capacity) {
    size_t size = lease->capacity ? lease->capacity * 2 : 16;
    int *copy = realloc(lease->fds, size * sizeof(int));
    if (!copy) {
      close(fd);
      return 71;
    }
    lease->fds = copy;
    lease->capacity = size;
  }
  lease->fds[lease->count++] = fd;
  return 0;
}
static int private_root(const char *requested, char *root) {
  char path[PATH_MAX];
  if (requested) {
    if (requested[0] != '/' || !strcmp(requested, "/") ||
        strlen(requested) >= sizeof(path))
      return 71;
    strcpy(path, requested);
  } else {
    const char *home = getenv("HOME");
    if (!home || home[0] != '/') {
      struct passwd *user = getpwuid(geteuid());
      home = user ? user->pw_dir : NULL;
    }
    if (!home ||
        snprintf(path, sizeof(path),
                 "%s/Library/Application Support/M1Launcher/InstallLocks",
                 home) >= (int)sizeof(path))
      return 71;
  }
  size_t path_length = strlen(path);
  while (path_length > 1 && path[path_length - 1] == '/')
    path[--path_length] = 0;
  if (!strcmp(path, "/"))
    return 71;
  // Create missing parents without changing permissions on existing
  // directories.
  for (char *p = path + 1;; p++)
    if (*p == '/' || *p == 0) {
      char value = *p;
      *p = 0;
      if (mkdir(path, 0700) != 0 && errno != EEXIST)
        return 71;
      *p = value;
      if (!value)
        break;
    }
  struct stat info;
  if (lstat(path, &info) != 0 || !S_ISDIR(info.st_mode) ||
      info.st_uid != geteuid() || chmod(path, 0700) != 0 ||
      !realpath(path, root))
    return 71;
  return 0;
}
static int lock_file(const char *root, const char *key, int mode, int *result) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1], file[PATH_MAX];
  CC_SHA256(key, (CC_LONG)strlen(key), digest);
  for (size_t i = 0; i < sizeof(digest); i++)
    snprintf(hex + i * 2, 3, "%02x", digest[i]);
  if (snprintf(file, sizeof(file), "%s/%s.lock", root, hex) >=
      (int)sizeof(file))
    return 71;
  int fd = open(file, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0)
    return 71;
  struct stat info;
  if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) ||
      info.st_uid != geteuid() || fchmod(fd, 0600) != 0) {
    close(fd);
    return 71;
  }
  if (flock(fd, mode | LOCK_NB) != 0) {
    int error = errno;
    close(fd);
    return error == EWOULDBLOCK ? 73 : 71;
  }
  *result = fd;
  return 0;
}
static int keys_for(const char *path, const char *channel,
                    char keys[2][PATH_MAX + 96]) {
  struct stat info;
  if (stat(path, &info) != 0 || !S_ISDIR(info.st_mode))
    return 64;
  if (snprintf(keys[0], PATH_MAX + 96, "%spath:%s", channel, path) >=
      PATH_MAX + 96)
    return 64;
  snprintf(keys[1], PATH_MAX + 96, "%sinode:%llu:%llu", channel,
           (unsigned long long)(unsigned int)info.st_dev,
           (unsigned long long)info.st_ino);
  return 0;
}
static int lock_keys(Lease *lease, const char *root, const char *path,
                     const char *channel, int probe) {
  char keys[2][PATH_MAX + 96];
  int code = keys_for(path, channel, keys);
  if (code)
    return code;
  for (size_t i = 0; i < 2; i++) {
    int fd = -1;
    code = lock_file(root, keys[i], probe ? LOCK_EX : LOCK_SH, &fd);
    if (code)
      return code;
    if (probe)
      close(fd);
    else if ((code = append_fd(lease, fd)))
      return code;
  }
  return 0;
}
int ready_installation_read_lease(const char *installation,
                                  const char *requested_root, int **fds,
                                  size_t *count) {
  *fds = NULL;
  *count = 0;
  char path[PATH_MAX], root[PATH_MAX];
  struct stat before, after;
  if (!installation || installation[0] != '/' ||
      !realpath(installation, path) || !strcmp(path, "/") ||
      stat(path, &before) != 0 || !S_ISDIR(before.st_mode))
    return 64;
  int code = private_root(requested_root, root);
  if (code)
    return code;
  char gate_path[PATH_MAX];
  if (snprintf(gate_path, sizeof(gate_path), "%s/admission.lock", root) >=
      (int)sizeof(gate_path))
    return 71;
  int gate = open(gate_path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (gate < 0)
    return 71;
  struct stat info;
  if (fstat(gate, &info) != 0 || !S_ISREG(info.st_mode) ||
      info.st_uid != geteuid() || fchmod(gate, 0600) != 0) {
    close(gate);
    return 71;
  }
  while (flock(gate, LOCK_EX) != 0) {
    if (errno == EINTR)
      continue;
    close(gate);
    return 71;
  }
  Lease lease = {0};
  char parent[PATH_MAX];
  strcpy(parent, path);
  // L shared on target and ancestors excludes writers of this root/any
  // ancestor.
  for (;;) {
    code = lock_keys(&lease, root, parent, "", 0);
    if (code)
      goto finish;
    if (!strcmp(parent, "/"))
      break;
    char *slash = strrchr(parent, '/');
    if (slash == parent)
      parent[1] = 0;
    else
      *slash = 0;
  }
  // I exclusive probe excludes writers anywhere below this installation. The
  // admission gate prevents any new writer appearing between probe and R lock.
  code = lock_keys(&lease, root, path, "intent:", 1);
  if (code)
    goto finish;
  // R shared membership tells future nested writers that this root is in use.
  code = lock_keys(&lease, root, path, "reader:", 0);
  if (code)
    goto finish;
  char verify[PATH_MAX];
  if (!realpath(installation, verify) || strcmp(path, verify) ||
      stat(path, &after) != 0 || before.st_dev != after.st_dev ||
      before.st_ino != after.st_ino || !S_ISDIR(after.st_mode)) {
    code = 64;
    goto finish;
  }
finish:
  close(gate); // Never inherited by the game or retained for session lifetime.
  if (code) {
    close_lease(&lease);
    return code;
  }
  *fds = lease.fds;
  *count = lease.count;
  return 0;
}
