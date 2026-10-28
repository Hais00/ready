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

POSIX spawn creates a new process group and starts in its allowed private
temporary directory. Child descriptors are stdin 0, events 1,
`/dev/null` stderr 2, read-only parent lifeline 3 and write-only game health pipe
4; original pipe ends and unrelated
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

`takeGameHealthReadFD()` transfers an owned CLOEXEC reader exactly once. The
supervisor never reads it. The host revokes its discovery record, then closes
the only health writer, before potentially slow vendor cleanup. An unclaimed
reader is closed on reap/deinitialization. Closing a reader does not itself
terminate another host or grant game authorization.

## Native game integration

`SteamGameAuthorization` obtains a genuine `authorize_game` result from the
already-online persistent service. Its short-lived, one-use grant binds profile,
server identity, AppID, service generation and credential digest. Cancellation,
logout, account changes and credential replacement reject late results. A new
online event cannot resume a launch until its persona matches the saved account.
No platform-specific QR is created.

`SteamNativeGameSession` consumes that grant only after checking the native ARM64
executable, SDK installation/bundle relationship, exact asset hashes and signing
compatibility. Its trusted environment contains private IPC/metadata endpoints
and account identity, never a refresh token. Credentials travel only through the
host's anonymous stdin. The profile/game backend cache is separate from other
games and accounts; shared engines are not copied. This does not establish native
game save-folder isolation.

`SessionManager` accepts a ready typed lease for the matching native Steam game
and profile. Store JSON/environment cannot manufacture that capability. Windows
remains unavailable until its own authenticated game host is integrated. The
keeper receives a session-lock descriptor and health-reader descriptor via an
anonymous socket and SCM_RIGHTS. A fixed frame, EOF and three-second deadline
precede admission ACK. The parent switches the shared lock to close-only
**before** sending descriptors, including failure paths. ACK acknowledges
admission, not successful game execution.

After taking the installation read lease, the keeper rechecks executable and SDK
digests immediately before ACK/spawn. A concurrent download cannot silently
replace the bytes validated by the parent. Only the selected three Steam
adapters and optional Ready overlay are composed. Game children inherit neither
health/lifeline descriptors nor account tokens.

Host revocation, exit or frontend death closes health. The keeper signals only
its still-anchored game group, escalating TERM to KILL after two seconds, and
retains installation/session locks until the group is dead. This Steam-specific
crash behavior differs from the detached non-Steam path. Processes that deliberately
escape the original group are not claimed to be contained.

## Central selection and remaining deployment

The local versioned selection is
`<application-data>/Components/SteamNativeHost/<AppID>/selected.json`:

```json
{
  "schema": 1,
  "kind": "ready-native-steam-host-selection-v1",
  "manifestPath": "versions/example/binding.json",
  "manifestSHA256": "<independently selected complete SHA-256>"
}
```

The selector is an owned private regular file; manifest paths stay relative below
that game's central selection. This component is independent of the selected
engine and StoreBridge versions. The old `Tools/StoreBridge/NativeSteamHost` lookup
remains a fallback only when no user selection exists. Explicit developer
overrides `READY_STEAM_NATIVE_BINDING` and its companion
`READY_STEAM_NATIVE_BINDING_SHA256` use the same checked interface. Missing
selection/assets fail before starting a game. The [local component installer](STEAM_NATIVE_COMPONENT.md)
now prepares versioned Ready code and publishes a reversible game binding. This
machine's native component and central StoreBridge selections have been installed
and checked through the packaged frontend without development environment
overrides. Commercial-game validation, general first-run distribution and Windows
integration remain open. Valve assets are external inputs, not GPL payloads.

## Genuine Swift-supervised SDK evidence

The first real attempt exposed filesystem-adapter recursion when the inherited
working directory was denied by the sandbox. That failure remains retained.
The supervisor now selects its private cwd. The adapter resolves cwd through a
kernel directory descriptor first and guards libc fallback with thread-local
recursion tracking; unresolvable paths fail closed. Removed, denied and reentrant
cwd controls run without Valve code.

The subsequent test through the actual Swift supervisor and health-capable host
passes genuine external SDK initialization, identity and subscription immediately
and after over 40 seconds. Parent EOF yields orderly host exit 42; the source
private cache is unchanged and no full Steam process appears. Report SHA-256:
`8b75fdea8b3e3493d7f6648ef06ed713963f4d1d01f7bdf87b50dec4c33b77d9`.
It reuses the approved private cached logon, with no new QR or fresh SteamKit
preflight. No commercial game was executed. This does not verify the entire
GUI → persistent-service grant → game path against a real account.

The later component test also calls the genuine
[`SteamAPI_RestartAppIfNecessary`](https://partner.steamgames.com/doc/api/steam_api#SteamAPI_RestartAppIfNecessary)
before initialization. Valve documents this as a potential relaunch operation,
so the explicit probe runs under independently checked execution/Mach denials.
Both immediate and 41-second checks return false, then successfully initialize
and verify the genuine account/subscription. There is no `steam_appid.txt` override
and no full Steam process appears. The component's six prepared artifacts match
the tested bytes exactly. See [the sanitized checkpoint](../Validation/steam-native-component-checkpoint.json).
This is still an SDK test, not a commercial-game execution.

## Later live GUI and native game checkpoint

The subsequent human-approved login was performed in the real packaged Ready
interface using its normal user data and selected central tools. Account name,
public persona and friends were received. Manual offline/reconnect and closing
and reopening Ready both recovered the account without another QR or credential
storage warning. No friend/account identifiers are published in the checkpoint.

The first game preparation exposed an APFS path-spelling issue: an existing
profile UUID directory had different case from the generated URL. The canonical
path guard correctly rejected it. `SteamNativeStateDirectory` now opens/creates
the private hierarchy with descriptor-relative NOFOLLOW operations and obtains
its real spelling using F_GETPATH. Thirty filesystem checks cover case aliases,
ownership, permissions, symlink escapes and descriptor cleanup; the existing
backend guards were not weakened.

After that fix, Ready's actual persistent-service grant → native host → keeper
→ Cyberpunk 2077 executable path succeeded. The real game reached its settings
interface with the full Steam client absent. The injected Ready overlay was
observed in the game's window and responded to keyboard input. Selecting its
close action returned to the Ready library; game, native host and keeper exited,
and both session and installation writer leases could be acquired again. The
persistent Steam service stayed connected without another QR.

The retained overlay counters report 21,312 completed overlay submissions, zero
failed submissions and zero separate overlay windows/layers. These are application
counters, not a driver capture. Gameplay, performance, native profile save
isolation, physical controllers and direct scanout remain unverified. The separate
logical-window proxy experiment was **not** used in this commercial-game run.
See [live account evidence](../Validation/steam-live-account-checkpoint.json) and
[native game evidence](../Validation/steam-live-native-game-checkpoint.json).
