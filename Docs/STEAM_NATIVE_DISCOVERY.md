<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Native game SDK discovery: exact metadata adapter

The signed Cyberpunk SDK `libsteam_api.dylib` SHA256 `2cbe2533e09d1561051f417d7b8c784481a2efdc4fc9d1274704ee8a7ef50cb1` uses a separate Mach metadata path before it loads the genuine core client. Its ARM64 SteamAPI_IsSteamRunning at0x47fc calls the fixed service `com.valvesoftware.steam.ipctool` through bootstrap_look_up, not the core client's Steam3Master TCP endpoint. The SDK's getenv calls cover AppID/GameID/OverlayGameID, not a discovery-service override.

Protocol104 uses32byte requests. Application operation100001 queries the supported version; operation14 requests a552byte response with PID at offset28 and a NUL-terminated path at offset32. The path field is512bytes. The SDK requires a nonzero live PID (`kill(pid,0)==0`), then derives the core-library path by replacing the returned basename with `steamclient.dylib`. Return the actual genuine client-library path, so its directory is correct; the custom host executable's directory need not contain that library.

Static hashes, addresses, literal references and imported calls are recorded by `steam_native_game_api_discovery.py` and `Evidence/steam-native-game-api-discovery.json`. No SDK execution or implementation body was copied by this analysis.

## Production API

`steam_native_discovery.h/.c` implement GPL metadata only. Load the **production** dylib in the owned authenticated host and call after genuine BLoggedOn, identity match and exact-game authorization:

```c
ReadySteamAuthenticatedHostRecord record = {
    .abi_version = 1,
    .owned_host_pid = getpid(),
    .generation = 1
};
atomic_init(&record.authenticated, 1);
ReadySteamDiscovery *service = NULL;
int status = ready_steam_discovery_start(
    private_name, genuine_client_dylib_path, exact_game_sdk_path,
    &record, &service);
/* status == READY_DISCOVERY_OK required before starting the SDK child. */
```

Use `app.ready.steam.ipctool.` followed by exactly32 lowercase hex characters; the existing private profile namespace UUID is suitable. The service rejects another owner PID, an unauthenticated record, invalid names and existing private-name registrations. Production startup hashes both code images against the pinned genuine client b9d62… and SDK2cbe…; no image is executed by the service.

Keep the record allocated and its immutable PID/generation fields unchanged until service stop. Root alone updates the atomic authenticated flag, based on its genuine checks. The server reads it without calling Steam APIs on its Mach thread. Revocation stops publication of PID/path. Protocol version104 remains the truthful software version even on revocation, avoiding the SDK's legacy old-version restart path. Incoming requests cannot set the record or request authentication, tickets, ownership or game actions.

Only exact32byte, noncomplex protocol104 requests from the same audit UID are accepted. Recognized replies are bounded; unsupported operations return KERN_NOT_SUPPORTED and no PID. Rights are consumed/destroyed appropriately, sends and receives have bounded waits. Stop/join the SDK child **before** calling `ready_steam_discovery_stop(service)`; stopping the service while an SDK query is in flight could trigger the SDK's own legacy restart logic. The stop API affects only this private service. Host process death destroys its owned Mach rights. No plist, PID file, normal Steam config or account file is created.

## Worker-local routing

On this host, bootstrap_subset returns125; a private UUID bootstrap_register/lookup succeeds. The measured fallback is `steam_native_discovery_redirect.c`, injected only into the owned SDK child. Set `READY_STEAM_DISCOVERY_SERVICE` to the private name and append its dylib to the existing FS/IPC adapters. It redirects only the fixed SDK lookup to that private service; missing or invalid private configuration fails closed. Other service lookups keep their original behavior. No global Steam service is queried, registered, overwritten or launched by this adapter.

The host policy needs exact mach-register and mach-lookup permission for the private name, plus read access to the production adapter and both code images for hash validation. The SDK child needs lookup only for the private name and read access to the lookup adapter. Keep the fixed global Steam lookup denied. Keep the genuine core's existing private TCP endpoints, FS/IPC namespaces and legitimate game context unchanged for the subsequent real client connection.

Fifteen own mock checks pass, including version and PID/path layout, wrong PID/name/auth rejection, collision rejection, malformed/unknown operation handling, no global lookup, redirect failure, unrelated lookup forwarding, lease revocation/restoration and owned stop. Production and TESTING images are separate. The TESTING build skips image hashes solely for dummy files in these tests; **never use it for the real host**. `Evidence/steam-native-discovery-mock.json` pins the current artifacts and tests.

This adapter does not assert authentication or ownership to the SDK and supplies no tickets. All such decisions remain with the genuine client. Original game/SDK files are unchanged. Actual SDK success, game launch and injection into the hardened game remain unverified by this agent.

## Safe discovery instrumentation

The instrumented production artifacts add two exported, bounded JSON getters:

```c
size_t ready_steam_discovery_stats_json(
    ReadySteamDiscovery *service, char *out, size_t capacity);
size_t ready_steam_discovery_redirect_stats_json(
    char *out, size_t capacity);
```

Use4096bytes and call the service getter before stopping/freeing its handle. A zero return means no complete JSON was copied. The SDK child's own probe can resolve the redirect getter with dlsym(RTLD_DEFAULT,...) and record whether it was found. Its constructor-set `redirectLoaded` confirms loading; the counters distinguish fixed-name lookup, configured private redirect, other-name forwarding and the final lookup result. They never include service names, paths, PIDs, SteamIDs, account data, credentials or message payloads.

The host getter reports receive/valid/rejected counts, separate size/protocol/right/audit failures, version/metadata/unsupported-operation counts, denied leases, reply counts and bounded numeric last-message protocol/status fields. Only the version operation's public104 argument is retained; metadata/unknown arguments are not copied into diagnostics.

Interpret the actual next SDK trial, without treating mock success as SDK compatibility:

- Getter missing or loaded=false: inspect the child's actual injected images/launch path.
- Loaded=true, fixedLookups=0: the SDK did not use the routed symbol/path, or its binding bypassed interposition.
- Fixed lookups with missing/invalid configuration: correct the owned child environment.
- Private lookup failure: inspect sandbox/private-bootstrap namespace and registration status.
- Lookup success with no receives: inspect transport send/receive/lifetime permissions.
- Size/protocol/right/audit rejects: inspect the exact actual header values before changing the parser.
- Metadata lease denial: inspect the owned record's allocation lifetime, PID/generation and genuine authorization state; do not bypass it.
- Successful replies with SDK failure: inspect its PID/path/protocol consumption and subsequent genuine client loading.

Eighteen own mock checks, including the safe counters themselves, pass for this instrumented build. No actual game SDK, account or Valve code was executed by this agent. Earlier production/redirect binaries remain immutable in their prior run directories. The actual SDK failure under the earlier production build remains unresolved until the new counters are observed in the genuine Root-owned trial.
