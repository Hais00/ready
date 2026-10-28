# Native Steam host supervisor

`SteamNativeHostProcess` supervises one exact native host process. The caller must
first verify the active profile's genuine Steam ownership response, matching
account identity, and credential revision. This supervisor performs no login,
entitlement decision, game launch, or SDK emulation itself.

Load `Binding` using a selected manifest URL and an independently trusted SHA-256.
The manifest is an owned private regular file with this schema:

```json
{
  "schema": 1,
  "kind": "ready-steam-native-host-binding-v1",
  "fixtureOnly": false,
  "assets": {
    "host": {"path": "/absolute/host", "sha256": "..."},
    "library": {"path": "/absolute/Steam.AppBundle/Contents/MacOS/steamclient.dylib", "sha256": "..."},
    "discoveryLibrary": {"path": "/absolute/discovery.dylib", "sha256": "..."},
    "sdk": {"path": "/absolute/libsteam_api.dylib", "sha256": "..."},
    "fsAdapter": {"path": "/absolute/filesystem.dylib", "sha256": "..."},
    "ipcAdapter": {"path": "/absolute/ipc.dylib", "sha256": "..."},
    "lookupAdapter": {"path": "/absolute/lookup.dylib", "sha256": "..."}
  },
  "extraFiles": []
}
```

Digests must be complete lowercase SHA-256 values. All assets must be canonical,
owned regular files without symbolic links or group/world write permissions;
the host must be executable. Extra selected dependencies use the same path/hash
descriptor. The factory hashes all assets and rechecks them at spawn. This binds
the selected files; it is not a global approval of their licensing, all dynamic
dependencies, or mutable upstream files after verification.

`spawn(binding:credentialPacket:profile:sessionID:gameID:profileStateRoot:mode:onEvent:onExit:)`
consumes an `inout Data` RDYAUTH1 packet and clears that caller buffer even on
failure. The private writer clears its own mutable copy after writing anonymous
stdin and closing it to deliver EOF. Other copies created by the caller remain
the caller's responsibility. No credentials enter arguments, environment,
receipts, diagnostics or frontend events. The profile root must already be an
owned canonical 0700 directory. A profile marker prevents another profile from
reusing it. Client/cache folders persist; per-session temporary, policy and
receipt files remain available for review.

The fixed OS `sandbox-exec` applies a generated 0600 policy before executing the
selected host. It permits the selected Steam code bundle, exact asset files and
private profile data, while denying other user/volume files and writes, other
executables, nonnamespaced POSIX shared memory/semaphores, other loopback IPC and
other Mach services. Required OS dyld/DNS/configuration/trust services and public
outbound Steam traffic have explicit allowances following the existing tested
native-host policy. There is no HOME redirection; HOME identifies the actual OS
user. A receipt binds the policy hash, selected manifest hash, profile/session,
namespace and endpoints. Two ports are allocated simultaneously and released
before the genuine client binds: this is **not race-free**. No verified Valve
listener-FD handoff exists; collision must fail startup rather than choose the
normal Steam client as a fallback.

POSIX spawn creates a new process group. Child descriptors are stdin 0, events 1,
`/dev/null` stderr 2 and read-only lifeline 3; original pipe ends and unrelated
descriptors are closed using `POSIX_SPAWN_CLOEXEC_DEFAULT`. Only the parent owns
the lifeline writer. `stop()` closes it, permits three seconds of orderly cleanup,
then sends TERM and, after another three seconds, KILL only to that owned group.
One serial guardian performs both `waitpid` and signalling, so a reaped/reused PID
is never signalled. Startup has a 50-second supervisor budget. Event reads are
bounded/nonblocking, drain before the final exit callback, and stop a host whose
event channel is lost or malformed. Cancellation suppresses queued ready events.

Only fixed safe event fields are forwarded on the main queue. Ready requires the
expected AppID, private service/namespace/endpoints, strict boolean authentication,
identity and subscription flags, and matching fixture status. The caller must
reject fixture bindings for production. These flags describe the selected host's
report; actual game SDK interoperability still needs its separate genuine proof.

`Scripts/test_steam_native_host_process.py` compiles the real Swift supervisor and
an independent C protocol fixture on the marked external work volume. It checks
descriptor/sandbox controls, two concurrent hosts, startup cancellation, EOF,
hash/path/profile rejection, event failures, bounded signalling and actual parent
SIGKILL. It never executes Valve code or a game SDK, authenticates an account,
reads normal Steam account data, or alters an existing Steam process.
