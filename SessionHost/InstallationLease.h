// SPDX-License-Identifier: GPL-3.0-only
#ifndef READY_INSTALLATION_LEASE_H
#define READY_INSTALLATION_LEASE_H
#include <stddef.h>
/* On success the caller owns all returned descriptors for its entire session.
 * Returns 73 for a busy installation, 64 for an invalid installation, or 71 for
 * an unsafe/unavailable lock store. No installation file is changed. */
int ready_installation_read_lease(const char *installation,
                                  const char *lock_root, int **fds,
                                  size_t *count);
#endif
