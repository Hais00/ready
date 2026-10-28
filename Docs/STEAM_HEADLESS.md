# Steam headless: host-session architecture and provenance boundary

This is an implementation proposal, not a claim that Ready currently provides a
working Steamworks client. The target is the user's genuinely licensed Windows
and macOS games using genuine, external Valve client assets, without launching
the full Steam application. Account authorization, game ownership and the game's
own checks remain authoritative. No universal game-compatibility claim follows
from connecting to Steam or setting `SteamAppId`.

The architectural source audit below is distinct from the later, independently
authored local probes. Those probes load genuine Valve code into owned workers
under a restrictive sandbox; they do not launch, stop or attach to Steam.app,
authenticate an account or launch a game. The user's existing native Steam
process remains outside their ownership. Raw disassembly and external binaries
stay on the selected private work volume.

## Implementation checkpoint

Native ARM64 macOS now has a real two-process transport proof: the host creates a
global user and listens on a private loopback endpoint; a second owned worker
connects to it, obtains the genuine public User023/Apps008 adapters, drains
callbacks and releases its handles. Actual socket observations bind the peer to
that host. This is an unauthenticated IPC result. The returned base SteamID is
not a real logged-in identity, and a false offline subscription result is not an
authoritative negative entitlement check.

Wine PE32/PE64 independently use Windows shared memory/events, rather than the
native Mac TCP path. Same-namespace clients connect; different namespaces and
different prefixes do not. PE32's abnormal exit after handle-release events
remains separate from the positive IPC result. A later controlled Windows
shutdown path exits normally in both architectures; it does not rewrite the
older abnormal result. Native filesystem/SHM adapter composition now passes
cross-process fixtures and a genuine host/peer run with no controller mapping
warnings. Full game/profile isolation still requires real game evidence.

The source-built SteamKit helper now implements `authorize_game`: after genuine
logon it requires Valve's successful app-ownership-ticket response for the exact
AppID, a nonempty ticket and a real returned SteamID. It never returns ticket
bytes. Its offline decision/protocol tests do not prove real account ownership.

Production SessionManager rejects Steam game launch before creating session or
prefix state until an authenticated, owned headless host can replace that gate.
This avoids a direct executable silently restarting the full client through
[SteamAPI_RestartAppIfNecessary](https://partner.steamgames.com/doc/api/steam_api#SteamAPI_RestartAppIfNecessary).
The new gate is covered for both native and Windows variants by the 21-check
real SessionManager/keeper suite. Account/library/download operations remain
separate from this launch gate.

See [native evidence](STEAM_NATIVE_HEADLESS_RESEARCH.md),
[Windows evidence](STEAM_WINDOWS_HEADLESS_RESEARCH.md) and
[ownership preflight](STEAM_OWNERSHIP_PREFLIGHT.md). No successful account logon,
commercial-game launch, full native profile isolation, complete GUI exclusion
during a real game, or general DRM/anti-cheat compatibility is claimed.

## What the inspected source actually does

The inspected local GameNative revision is
`eaa715cf38fddfea6f8d1278c7dd89c0bb50e063`. Relevant files are:

- `THIRD_PARTY_NOTICES`, sections **Steam Client Bootstrap Shim** and
  **Launcher Compatibility Helpers**.
- `app/src/main/java/app/gamenative/SteamBootstrap.kt`.
- `app/src/main/java/com/winlator/xenvironment/components/BionicProgramLauncherComponent.java`,
  `bootstrapNativeSteamClient`.
- `app/src/main/java/app/gamenative/ui/screen/xserver/XServerScreen.kt`,
  the headless/bionic launch branches, Steam extraction and exit handling.
- `app/src/main/java/app/gamenative/utils/launchdependencies/BionicSteamAssetsDependency.kt`.

The notices explicitly classify `libsteambootstrap.so` and the downloaded
`steamhost` helpers (`steam.exe` and `steamhost64.exe`) as proprietary, with source
withheld. They also distinguish genuine Valve files carried alongside the
headless helper. These binaries are not GPL merely because the surrounding
Kotlin/Java orchestration is GPL. Ready must not copy or repackage these closed
helpers as its own open implementation.

The current Kotlin implementation is more specific than the notice's older JNI
description: `start` stores configuration; `prepareApp` stops the previous host
and starts `libsteambootstrap.so` as a subprocess with app ID, client-library path
and readiness-file path. It passes account/token material through environment
variables and polls INIT/READY/FAILED/CLOSED for up to sixty seconds. Its singleton
configuration, shared ready/log paths and one-current-app behavior are not a
profile-isolation design suitable for direct reuse in Ready.

There are two different guest paths. Bionic mode starts a genuine Android client
library through the withheld host and uses Wine-version-specific `lsteamclient`
modules. Windows headless mode starts a withheld `steam.exe` with genuine Windows
client files, app/launch metadata and token handoff; it disables the separate
`lsteamclient` route. The bionic assets target Android/Proton variants, not a
validated macOS Wine 11.20 ABI. Source comments about ownership-ticket prewarming
or process monitoring describe intent; the missing host implementation prevents
this audit from independently establishing its detailed behavior.

Ready's existing `StoreBridge/SteamBridge/Program.cs` uses SteamKit2 for one stdin
JSON request per process. It creates a callback pump, uses a four-minute overall
deadline, and logs off/disconnects after library or launch-info operations. Its
launch-info response sets Steam app IDs and explicitly reports a genuine client
requirement. This account/library service does not provide the persistent client
runtime, game IPC, callback processing or lifecycle required by Steamworks.

## Code and asset boundaries

| Component | Proposed treatment |
|---|---|
| Ready broker, IPC framing, profile leases, cancellation and lifecycle | Independently authored GPL source with tests and source/build receipts |
| Ready platform adapter declarations | Independently authored, pinned to independently verified interfaces; no copied withheld helper or uncleared SDK header layer |
| SteamKit account/library code | Preserve its separate LGPL notices/source and Ready's current private credential channel |
| Valve client libraries and accompanying assets | Explicit external proprietary component, identified by platform, architecture, exact file hashes and provenance; never labelled open source or included in an open-only runtime packet |
| GameNative closed bootstrap/headless helpers | Architectural reference only; do not copy into Ready's open payload |
| Proton `lsteamclient` / Steamworks SDK-derived interface code | Separate per-file licence boundary; no blanket Proton/BSD approval |
| A game's own Steam API/DRM files | Remain unmodified in the user's installation; no substituted ownership implementation |

A locally loadable Valve library does not prove source-closure or binary
redistribution approval. External asset acquisition, licence acceptance and any
public distribution decision are separate from implementing the free broker.
Version/ABI mismatch must return an explicit unavailable state rather than
falling back to a different Steam process or an unverified helper.

## Proposed lifecycle

One free coordinator is logically scoped to a canonical profile UUID and an
unpredictable host generation. It can remain alive across account/library
requests, but it is not a shared global account singleton. Credentials enter
through the native app's existing profile-specific Keychain boundary and private
IPC; they do not enter process arguments, launch environment, status files or
ordinary logs. The existing per-request bridge can remain compatible while this
new persistent runtime service is developed separately.

The coordinator owns platform workers rather than pretending one executable
serves both guest types:

- **Windows/Wine worker:** exact Wine binary/provider identity, executable PE
  architecture, that game's/profile's canonical Wine prefix, and a genuine
  Windows client-asset identity. Its guest runtime state remains isolated from
  other profiles. Engine files remain central. The host and any game it starts
  must remain under the game's supervised lifetime/installation lease.
- **Native macOS worker:** exact native client image and architecture, with an
  explicitly tested native game IPC path. A Mach-O `dlopen` or SteamKit login is
  not that proof. Never attach to or stop the user's already running Steam
  process implicitly.

Valve's actual native IPC/configuration namespace may be global for the current
macOS user. Separate broker sockets and directories alone do not isolate it.
Until real conflicting-profile tests prove otherwise, the native backend must
hold an exclusive client-namespace lease and report `client_namespace_busy` when
another owner is present. A Windows backend must similarly prove its actual
Wine-prefix/process namespace; a profile identifier in JSON is insufficient.

State transitions are:

`stopped → starting → awaitingAuthorization → authenticating → online → preparingGame → gameReady → running → draining → stopped`.

`failed` and `authorizationRequired` are explicit outcomes. `gameReady` requires
more than a live PID: exact worker/client bindings, successful real logon,
matching account identity and the platform-specific game context must all have
been established. Genuine entitlement/API failures remain failures. Offline
behavior is limited to what the genuine client itself authorizes; a cached
library list is not a new entitlement grant.

Each game has a separate session UUID and reference on its owning worker.
Stopping one game releases only that reference. Account switching/logoff waits
for, or explicitly terminates, the affected sessions; it cannot silently change
the identity beneath a running game. No provider/client binary swap happens
while a worker references that generation.

SessionManager/ReadySessionHost must remain the authority for game process groups,
prefix leases and installation read leases. A future host-mediated launch must
be inside that same supervised session, including a host which starts the game
and exits early. The lease cannot be released when just the bootstrap PID exits.
An external native runtime worker needs an explicit lifetime reference/guardian
contract as well; it cannot be made safe by merely saving its PID. Processes
which deliberately escape the supervised group or use independent launch
services require separate evidence and cannot be claimed contained.

Loss of the UI/coordinator connection must not release a live game's leases or
silently reassign its profile. The worker/keeper must either continue the already
owned session with its lifetime reference, or stop that owned session according
to an explicit tested policy. Restarting a coordinator does not authenticate a
new owner to an existing session. Drain/teardown closes genuine client handles,
logs off when appropriate, releases workers and finally releases namespace
leases; timeouts signal only the processes that coordinator actually owns.

## Minimal free-code API proposal

The following is a proposed v1 contract awaiting agreement with the platform
adapters. No consumer protocol or runtime implementation is declared complete by
this document.

A private persistent JSONL or equivalent framed channel carries envelopes with
`protocolVersion`, `requestID`, `hostGeneration`, `profileID`, optional `sessionID`,
`operation` and operation-specific data. All IDs are validated, frames bounded,
and request cancellation is ordered against callback/credential delivery. Every
response carries the same identity tuple and a monotonically increasing event
sequence. A stale generation/request cannot update Keychain or another session.

| Operation | Required behavior |
|---|---|
| `capabilities` | Report exact supported platform/client/ABI and currently verified features, without login |
| `open` | Acquire profile/client namespace leases and start only an explicitly selected owned worker; bind hashes and architecture |
| `authorize` | Accept a credential over private IPC and verify real identity; require user reauthorization on rejection |
| `prepareGame` | Validate app ID, game installation/executable, platform, prefix and session ownership; obtain the genuine client game context; fail on unowned/unavailable/mismatched state |
| `attachGame` | Bind the actual keeper-owned game identity/lifetime to the prepared session; no arbitrary PID adoption |
| `status` | Return safe state, identities and capability/error codes; never credential or ticket contents |
| `cancel` / `releaseGame` | Affect only the exact request/session generation; leave unrelated sessions alive |
| `close` | Drain active references or return busy; never kill another Steam instance |

`prepareGame` returns a bounded context descriptor rather than an executable
shell command or a ticket-forging API. It identifies whether the proven backend
requires direct or host-mediated launch, and includes only the scoped IPC/handle
references and allowlisted non-secret environment needed by that backend.
Executable arguments remain arrays validated by the launch planner. Game tickets
and other authentication material stay inside the genuine client/game IPC path;
they are not dumped as reusable diagnostic results.

An inherited anonymous channel is preferable for initial secret/capability
handoff. If a local socket is needed, its private owned parent, peer identity and
unguessable connection capability must be verified; UID equality alone does not
identify the intended profile. Writable caches and recovery records live under
the application's profile data root, outside immutable tool/client objects and
shared game installations. No untrusted launch option can choose an arbitrary
client library, IPC endpoint, credential path or signal target.

## Necessary proof before integration

1. Pure fixture protocol/lifecycle tests: stale generation, duplicate/replayed
   request, wrong profile, cancellation-before-credential-save, bounded malformed
   frames, busy namespace, host crash/reconnect, two games sharing one profile,
   and one profile stopping without affecting another.
2. Owned process/lease tests: bootstrap exits before its game, UI/coordinator
   SIGKILL, host failure while a game lives, termination and bounded drain;
   exact-prefix and installation leases remain held until the owned session ends.
3. Separate real platform tests with pinned genuine external assets: native
   Mach-O and Wine PE32/PE64 game IPC, real callback processing and a genuine
   owned-game launch. Include an authoritative negative entitlement result and
   account/namespace conflict. Do not substitute a fixture backend for this gate.
4. No full-client UI claim requires actual process/image/resource evidence:
   exclude the GUI client/CEF helpers, show the real host/client images used and
   keep existing unrelated Steam processes untouched. A hidden window, no visible
   menu bar or a small wrapper PID is insufficient evidence.
5. Preserve source/build/asset receipts and a truthful per-platform capability
   matrix. No common "Steam works" flag may promote one successful title or one
   architecture into universal DRM/Steamworks compatibility.

This proposal changes no profile data, frontend location pointer, runtime default
or licensing/distribution gate. The existing account/library bridge remains the
implemented path until a real host backend and these proofs are available.
