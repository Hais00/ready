// SPDX-License-Identifier: GPL-3.0-only
/* Own-worker POSIX IPC namespacing prototype; no Valve/account/DRM logic.
 * Inject into our explicit worker only, never globally or into Steam.app.
 * READY_STEAM_IPC_NAMESPACE is a non-secret random 32-hex identifier, frozen at
 * construction. Every name received by these four APIs is remapped, including
 * names with interior '/' used by the inspected client.
 *
 * Physical names are 30 bytes, excluding NUL:
 * /RS<namespace first 16 hex>_<10 SHA256 hex> (shm), /RE... (sem).
 * The digest includes version, API domain, ALL 32 namespace hex and original
 * name. The short prefix permits an independent sandbox allowlist. This is
 * lookup namespacing, NOT authentication or collision-proof/full IPC isolation.
 * Direct syscalls, Mach IPC, sockets and inherited handles need independent
 * policy. A prefix-only sandbox shares permissions if namespaces share their
 * first 64 bits; the coordinator must assign/check unique active prefixes.
 */
#define _DARWIN_C_SOURCE 1
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define INTERPOSE(replacement, original) \
  __attribute__((used)) static const struct { const void *new_fn; const void *old_fn; } \
  interpose_##original __attribute__((section("__DATA,__interpose"))) = \
  { (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&original }

static char namespace_id[33];
static pthread_once_t namespace_once = PTHREAD_ONCE_INIT;
static void configure_namespace(void) {
    const char *input = getenv("READY_STEAM_IPC_NAMESPACE");
    if (input && strnlen(input, 33) == 32) {
        for (size_t i = 0; i < 32; i++) {
            char ch = input[i];
            if (ch >= 'A' && ch <= 'F') ch = (char)(ch - 'A' + 'a');
            if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'))) goto invalid;
            namespace_id[i] = ch;
        }
        return;
    }
invalid:;
    static const char text[] = "Ready IPC namespace: invalid namespace configuration\n";
    (void)write(STDERR_FILENO, text, sizeof text - 1); _exit(78);
}
__attribute__((constructor)) static void ready_ipc_start(void) { pthread_once(&namespace_once, configure_namespace); }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static int mapped_name(const char *name, int semaphore, char output[31]) {
    pthread_once(&namespace_once, configure_namespace);
    if (!name || !*name) { errno = EINVAL; return -1; }
    size_t length = strnlen(name, 4097);
    if (length > 4096) { errno = ENAMETOOLONG; return -1; }
    static const char version[] = "ready-steam-ipc-v1";
    const char *domain = semaphore ? "sem" : "shm";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    CC_SHA256_Update(&context, version, sizeof version); // includes separator NUL
    CC_SHA256_Update(&context, domain, (CC_LONG)strlen(domain) + 1);
    CC_SHA256_Update(&context, namespace_id, sizeof namespace_id);
    CC_SHA256_Update(&context, name, (CC_LONG)length);
    CC_SHA256_Final(digest, &context);
    int n = snprintf(output, 31, "/R%c%.16s_%02x%02x%02x%02x%02x", semaphore ? 'E' : 'S', namespace_id,
                     digest[0], digest[1], digest[2], digest[3], digest[4]);
    if (n != 30) { errno = EINVAL; return -1; }
    return 0;
}
#pragma clang diagnostic pop

/* Darwin declares shm_open variadic too (unlike the usual POSIX synopsis).
 * On ARM64, an O_CREAT mode is consequently read from the variadic stack. */
static int ready_shm_open(const char *name, int flags, ...) {
    char physical[31]; if (mapped_name(name, 0, physical)) return -1;
    if (flags & O_CREAT) {
        va_list arguments; va_start(arguments, flags);
        mode_t mode = (mode_t)va_arg(arguments, int); va_end(arguments);
        return shm_open(physical, flags, mode);
    }
    return shm_open(physical, flags);
}
INTERPOSE(ready_shm_open, shm_open);
static int ready_shm_unlink(const char *name) {
    char physical[31]; if (mapped_name(name, 0, physical)) return -1;
    return shm_unlink(physical);
}
INTERPOSE(ready_shm_unlink, shm_unlink);
static sem_t *ready_sem_open(const char *name, int flags, ...) {
    char physical[31]; if (mapped_name(name, 1, physical)) return SEM_FAILED;
    if (flags & O_CREAT) {
        va_list arguments; va_start(arguments, flags);
        mode_t mode = (mode_t)va_arg(arguments, int);
        unsigned int value = va_arg(arguments, unsigned int);
        va_end(arguments);
        return sem_open(physical, flags, mode, value);
    }
    return sem_open(physical, flags);
}
INTERPOSE(ready_sem_open, sem_open);
static int ready_sem_unlink(const char *name) {
    char physical[31]; if (mapped_name(name, 1, physical)) return -1;
    return sem_unlink(physical);
}
INTERPOSE(ready_sem_unlink, sem_unlink);
