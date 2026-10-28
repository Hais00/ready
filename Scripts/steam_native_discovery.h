/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef READY_STEAM_NATIVE_DISCOVERY_H
#define READY_STEAM_NATIVE_DISCOVERY_H
#include <stdatomic.h>
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
/* Root sets authenticated only AFTER genuine BLoggedOn, matching identity and
 * genuine exact-game authorization. No incoming metadata request can set it. */
typedef struct {
    uint32_t abi_version;
    pid_t owned_host_pid;
    uint64_t generation;
    _Atomic uint32_t authenticated;
} ReadySteamAuthenticatedHostRecord;
typedef struct ReadySteamDiscovery ReadySteamDiscovery;
enum {READY_DISCOVERY_OK=0,READY_DISCOVERY_AUTH_REQUIRED=1,READY_DISCOVERY_BAD_OWNER=2,READY_DISCOVERY_BAD_NAME=3,READY_DISCOVERY_BAD_IMAGES=4,READY_DISCOVERY_REGISTER_FAILED=5,READY_DISCOVERY_THREAD_FAILED=6};
int ready_steam_discovery_start(const char *private_name,const char *genuine_client_path,const char *exact_sdk_path,const ReadySteamAuthenticatedHostRecord *owned_record,ReadySteamDiscovery **out);
/* Safe protocol counters only: no service names, file paths, PIDs or user data. */
size_t ready_steam_discovery_stats_json(ReadySteamDiscovery *service,char *out,size_t capacity);
size_t ready_steam_discovery_redirect_stats_json(char *out,size_t capacity);
void ready_steam_discovery_stop(ReadySteamDiscovery *service);
#endif
