# Store bridge

The store bridge is GPL-3.0-only source in `StoreBridge/`. It reconstructs the public GameNative account/library architecture without using any closed GameNative module. See `StoreBridge/NOTICE` and `StoreBridge/dependencies.lock.json`.

## Build and protocol

```sh
python3 Scripts/store_bootstrap.py
python3 StoreBridge/bridge.py
```

`bridge.py` reads **one UTF-8 JSON object plus newline from stdin** and writes **JSONL events to stdout**. The caller must treat stdout as a private credential channel, never a general log. Secrets never appear in bridge process arguments. `profileID` is a UUID; account state belongs to that profile only. Per-game/per-profile Wine prefixes are selected by the native session manager, not by this download service. Install files can be shared centrally.

Request shape:

```json
{"operation":"auth_begin","store":"gog","profileID":"00000000-0000-4000-8000-000000000001","credentials":{},"options":{}}
```

Operations:

| Operation | Input | Events/result |
| --- | --- | --- |
| `capabilities` | no store/profile needed | `result`, protocol version and supported operations |
| `auth_begin` (`auth_start` alias) | store/profile | Epic/GOG/Amazon: `auth_url` with `url`, `authState`; Steam: `qr` events, then `result.credentials` after approval |
| `auth_complete` | `options.authState` (or `state`), `options.code` or `redirectURL` | `result.credentials` |
| `refresh` | credentials | updated `result.credentials` |
| `library` | credentials | progress events then `result.games`; optional updated credentials |
| `download` (`install` alias) | `options.gameID`, `platform` (`windows`/`macOS`), absolute `installDir`, and game `metadata` | sanitized numeric progress then `installedVariant`, `workingDirectory`, `launchCandidates`, `launchIssues`; ambiguous launches remain an explicit choice |
| `launch_info` | credentials + gameID/metadata | arguments/environment, and explicit remaining client/SDK requirements |
| `native_inspect` | `options.path` executable or `.app` | inspected Mach-O architecture; does not prove the application runs |

Complete auth state must be kept in memory by the native app and passed back unmodified. Amazon uses PKCE; GOG redirect URLs verify OAuth state. Manually pasted one-time codes are an explicit alternate flow. State expires after fifteen minutes and is profile-bound.

## Implemented paths

- **Steam:** real SteamKit2 3.5.1-Alpha.1 connection, QR authentication, refresh-token logon, licensed package → app lookup, PICS metadata and launch entries. Public game list privacy does not control this authenticated library path. Downloads use the separate, open DepotDownloader 3.4.0 process. A reproducible patch lets it consume a username/refresh token from private stdin, suppresses its credential persistence, and leaves the token out of argv. The patched GPL-2 helper is **not linked** into the GPL-3 launcher.
- **Epic:** browser authorization-code flow, token refresh, authenticated paginated library and both Windows/Mac asset lists, product metadata. Downloads invoke Legendary 0.20.43 built from source. Game authentication uses a single-use exchange code; returned launch arguments are sensitive and must never be logged. Long-lived store tokens never go in process arguments.
- **GOG:** browser OAuth, refresh, owned game lookup, per-game available installer platforms. Downloads invoke heroic-gogdl 1.3.1 built from source (including its exact Apache-licensed xdelta submodule). Its macOS backend extracts installer game payloads; the resulting executable must still be inspected.
- **Amazon:** device-auth PKCE, registration, refresh, paginated/deduplicated entitlements. Downloads invoke Nile 1.2.0 built from source with an ephemeral credential config. The API advertises Windows game builds; the bridge does not invent macOS variants. Downloading does **not** silently fetch Amazon's proprietary SDK. SDK-dependent game launch integration remains a separate requirement.

No account sign-in has been performed by the agent and no owned commercial game has been downloaded to validate end-to-end entitlement/download/launch. The code is implemented and compile/transport-tested; this is not a claim of complete store compatibility. Steamworks/DRM games may still require a genuine Steam client. No Steamworks emulator, closed launcher helper, DRM bypass, or anti-cheat workaround is supplied.

## Native builds

`macOS` in store metadata is **not** `arm64`. All remote macOS variants begin with `architecture: "unknown"`. `native_inspect` reads the actual installed Mach-O header (including fat binaries), resolves `.app/Contents/Info.plist`, and rejects iOS-only bundles. The automatic launch resolver additionally validates executable Mach-O file type, slice bounds, load-command bounds and platform (macOS or Mac Catalyst, not iOS/simulator), and checks Windows PE machine types. This avoids labelling an Intel-only Mac port as Apple Silicon native.

## Automatic launch selection

`StoreBridge/launch_resolver.py` resolves declared launch metadata, not arbitrary EXE scans:

- Steam: the selected platform's PICS `config/launch` entry, prioritising a unique `type: default`; preserve `executable`, `arguments`, `workingdir`, OS constraints and label.
- Epic: Legendary's `installed.json[appName]` record (`executable`, `launch_parameters`, `install_path`). Mac and Windows installation state are cached separately.
- GOG: the unique primary `FileTask` in `goggame-<id>.info`; a downloaded Mac app's file lives under `Contents/Resources` and task paths are relative to that app root.
- Amazon: `fuel.json` / `Main.Command`, `Main.Args`, `Main.WorkingSubdirOverride`. JSON5 is parsed through Nile's open JSON5 dependency when necessary.

An unambiguous valid entry yields `result.installedVariant`, compatible with `GameVariant` and containing additional `workingDirectory`, `source`, `primary` and `label` fields. The same directory is also returned as `result.workingDirectory`. If valid alternatives remain ambiguous, `installedVariant` is null, `launchCandidates` contains only validated choices, and `launchSelectionRequired` is true. Missing or unsafe primary entries are never replaced automatically with a settings tool. Missing metadata does not trigger a guessed EXE fallback.

All executable and working-directory paths are resolved and confined to the canonical installation root before binary inspection. Absolute/drive/UNC paths, traversal and symlink escapes are rejected. Application plist/executable symlinks are checked before reading the binary. Windows string arguments follow Microsoft CRT quoting/backslash rules **for the argument tail**, documented [by Microsoft](https://learn.microsoft.com/en-us/cpp/c-language/parsing-c-command-line-arguments). macOS strings use POSIX quote parsing without shell evaluation. JSON argument arrays remain literal. No environment expansion, globbing, `cmd.exe` interpretation or command substitution is performed. Steam `%command%` templates are not silently interpreted and require explicit advanced configuration. Current defaults when working-directory metadata is absent: executable parent for Steam/Epic, installation/app root for GOG, installation root for Amazon.

## Credentials and cancellation

- Native frontend stores returned credentials in macOS Keychain, keyed by profile and store.
- Epic's temporary `user.json` is mode 0600 inside a temporary config, including engine failures/cancellation. Only an explicit whitelist of non-secret installation metadata/manifests is copied back to the profile cache. GOG credential JSON and Nile's encrypted credential state also live in a mode-0700 temporary directory, removed after the operation.
- The bridge forwards only numeric progress from engines. It discards raw engine logs because they may contain signed CDN URLs or account data.
- SIGTERM becomes cancellation, allowing process-group cleanup and credential-file removal. After a hard crash or SIGKILL, normal `finally` cleanup cannot run; a production release still needs startup cleanup of stale private auth artifacts.
- Current lock/pagination checks reject conflicting profile-store operations and repeated remote page tokens. Errors do not return partial libraries as successful complete libraries.

## Verified evidence

`Evidence/stores-tests.txt`: synthetic protocol and HTTP fixture tests for auth, profile isolation, PKCE/CSRF, refresh, pagination failures, cross-platform metadata, native architecture inspection, downloader token hygiene and failure handling.

`Evidence/stores-helper-smoke.json`: actual local execution of SteamKit helper self-test and Legendary/GOGdl/Nile/DepotDownloader version commands. `.NET` and Python helper dependencies are installed locally, not in public source distribution. Dependency archives are pinned and the exact source retrieval is scripted. `Evidence/stores-python-packages.txt` records Python dependency versions; a distributable binary still needs a full third-party notice/source-offer audit.

Remaining direct evidence: real authorized account logins; real small entitled downloads for each platform/store; launch selection against downloaded production manifests (four-store fixtures pass); working Steam client coupling where required; Epic DRM/EOS corner cases; Amazon SDK-dependent launches; account switching while a game is running; crash recovery of temporary auth artifacts.

## Steamworks runtime: open host versus proprietary client

SteamKit account/CDN connectivity is distinct from Steamworks inside a running game. Valve explicitly says [SteamAPI_Init requires a running Steam client and an owned app licence](https://partner.steamgames.com/doc/sdk/api). Setting `SteamAppId` alone cannot satisfy that requirement. The public [ISteamClient API](https://partner.steamgames.com/doc/api/ISteamClient) can create a pipe and connect to an **existing** global user; `CreateLocalUser` is for game servers, not an alternative desktop-client login API.

Proton's source provides the relevant architecture:

- [`steam_helper/steam.c`](https://github.com/ValveSoftware/Proton/blob/bc896217ffcd67f892f952b010f898fe7bd0f0a1/steam_helper/steam.c) is a BSD-3-Clause `steam.exe` stub supplying client process/registry/launch context.
- [`lsteamclient/unixlib.cpp`](https://github.com/ValveSoftware/Proton/blob/bc896217ffcd67f892f952b010f898fe7bd0f0a1/lsteamclient/unixlib.cpp#L750) has a macOS branch that loads the user's real `steamclient.dylib` through `STEAM_COMPAT_CLIENT_INSTALL_PATH`, bridges callbacks/interfaces, and connects to a global user.
- **Important licensing boundary:** [`lsteamclient/LICENSE`](https://github.com/ValveSoftware/Proton/blob/bc896217ffcd67f892f952b010f898fe7bd0f0a1/lsteamclient/LICENSE) is the Steamworks SDK licence, not a free/open-source licence. Visible source is not permission to relabel this component GPL. It must not be copied into the wholly free release under an assumed Proton-wide BSD licence.

[NotProton](https://github.com/NotProtonNot/NotProton) and [steamplay-mac](https://github.com/Drustburn/steamplay-mac) demonstrate macOS ports using genuine Valve libraries and Wine client bridging. NotProton's [NOTICE](https://github.com/NotProtonNot/NotProton/blob/5065066a54622cfad1f34eab4bd2ad7c4a762cfe/NOTICE) explicitly distinguishes its GPL app, BSD steam shim and SDK-licensed lsteamclient. The self-built runner fork patches Wine source instead of binary detours, but still has that SDK boundary and currently references Wine 11.0/CrossOver sources rather than our Wine 11.20.

[OpenSteamClient](https://github.com/OpenSteamClient/OpenSteamClient) demonstrates a source-visible headless-core pattern: `dlopen` the genuine client, create `CLIENTENGINE_INTERFACE_VERSION005`, create a global user, then token login through `IClientUser`. Its main branch is deprecated, targets Linux, depends on private version-sensitive interfaces, and its imported OpenSteamworks headers claim Valve copyright without a clearly independent free licence. The MIT label on its UI is insufficient to approve copying that complete ABI layer.

[Aurelia](https://github.com/Drackrath/Aurelia) is a GPL-3 launcher/reference for runtime lifecycle. Its documented Steamworks path uses either the real host Steam or a real Windows Steam installation inside Wine; it does not prove a fully free replacement for Valve's Steamworks runtime. Its in-Wine runtime path is currently Linux-focused.

Plausible implementation for Ready: keep our host/IPC/session code free, require a genuine optional user-installed Valve client, preserve its entitlement checks, and use compatible ABI bridging only after a per-file licence audit and a pinned-Wine integration test. Alternatively, run a genuine Windows Steam client in the game's/profile's Wine environment and launch through it, with central immutable client payloads and isolated writable account state. The latter avoids copying SDK-licensed bridge source, but hiding Steam's UI does not guarantee the CEF/GPU allocation disappears. A genuinely lightweight direct `steamclient.dylib` host would require independently authored free declarations plus careful private-ABI integration; it is not implemented or validated here. No universal DRM-free assumption, fake ownership ticket or licence bypass is used.
## Shared installations and concurrent downloads

The frontend derives download targets from `Games/<store>/<safe-game-id>/<platform>`, independent of the active profile. Credentials remain profile-specific in Keychain; Wine session/prefix locks belong to the separate session manager. StoreBridge does not acquire a Wine prefix/session lock. The native `ReadySessionHost` keeper holds a separate installation read lease while the game/session is active.

StoreBridge canonicalizes `installDir` with filesystem realpath, then holds an exclusive installation lease for the complete downloader/verification/launch-resolution operation. Its keys contain neither profile nor account IDs: two profiles, stores, or symlink aliases targeting the same directory cannot write it simultaneously. Pathname and filesystem-inode locks also cover insensitive-filesystem aliases and directory replacement. The v2 admission protocol below makes overlapping read/write leases conflict in either hierarchy direction, while read/read and distinct sibling games remain parallel. A competing request fails promptly with `installation_busy`; the caller can retry after the active download ends. No entitlement, account identity, or token is written into shared lock files.

Zero-byte lock files live in the owned private `~/Library/Application Support/M1Launcher/InstallLocks` directory. Kernel `flock` ownership determines whether they are busy; files are never unlinked as a stale-lock workaround. Descriptors pass into the downloader so it retains the lease if the bridge crashes, and are released when all holders exit. Normal cancellation terminates the downloader process group before releasing the bridge's lease. Installation identity is rechecked before starting the engine and before reporting completion.

Writable helper caches are isolated under `Profiles/<canonical-UUID>/Stores/<store>/Games/<SHA256(gameID)>/<platform>`, with a separate per-game/profile/platform cache lock. Thus unrelated Legendary `installed.json` files and GOG metadata cannot overwrite each other during parallel downloads. Old profile-wide caches are not merged into this new layout; helpers rebuild their metadata and can verify/resume existing shared game content. Credential files remain in private temporary directories and are removed after each operation. Profile/cache directory symlinks are rejected, and install targets cannot overlap the profile-state or lock trees.

The 64-test fixture suite includes real subprocess contention across profiles and symlink aliases, nested-vs-sibling paths, independent same-profile game caches, profile symlink rejection, directory replacement, cancellation/failure cleanup, and an orphan downloader retaining its inherited lease after its bridge process exits. Cross-language tests launch the real native `Build/ReadySessionHost` keeper and Python writers: equal, ancestor, and nested targets conflict in both directions, multiple readers coexist, siblings remain independent, and stopping the keeper releases its read lease. These checks use fixtures only and do not claim real store account/download compatibility.

### Installation lease protocol v2 (Python and native keeper)

For each canonical target and ancestor directory, use two keys: `path:<realpath>` and `inode:<st_dev>:<st_ino>` (decimal). Each channel uses a zero-byte file named `SHA256(key).lock` under the same private `InstallLocks` root:

- L: key unchanged, legacy hierarchical locks.
- I: prefix the key with `intent:` to represent live writers.
- R: prefix the key with `reader:` to represent live reader roots.

Every admission holds `InstallLocks/admission.lock` exclusively for the brief probe/registration sequence. This gate can wait; all target/channel locks are nonblocking. It is closed before starting a game/downloader or yielding the lease, and is never passed to children.

| Holder | Temporary probes under gate | Locks retained for its lifetime |
|---|---|---|
| Writer | EX on R(target and all ancestors), then close probes | L: EX target, SH ancestors; I: SH target and all ancestors |
| Reader | After acquiring L, EX on I(target), then close probes | L: SH target and all ancestors; R: SH target |

Path and inode keys both participate in every step. An unsuccessful acquisition closes every partially acquired descriptor. Temporary probes never outlive admission. The gate prevents a new conflicting holder from appearing between a successful probe and its retained registration. Reader roots conflict with nested writers through R; writer descendants conflict with parent readers through I; L handles the opposite hierarchy direction. Readers share their retained locks, so equal/nested readers can coexist. Siblings share ancestor intent locks and do not block each other.

Python exposes `installation_lease(path, mode='write'|'read')`; downloads default to write. The keeper implements the read side with the same keys and reports exit 73 on conflict. It retains read descriptors until the supervised game plus the exact-prefix Wine session have ended. Prefix locks remain independent. Persistent lock files are not PID files, and neither implementation resolves contention by deleting them.

Protocol v1 writers did not retain I locks. Mixed v1 writers/v2 readers cannot safely protect the parent-reader/nested-writer case. During an upgrade, stop existing v1 download operations before enabling v2 session keepers. Reusing the L channel preserves writer/writer exclusion, but does not make mixed-version read protection complete.

### StoreClient cancellation and private IPC

`StoreClient` registers a request before dispatching its worker. Cancellation is checked atomically with launching `Process`, suppresses all queued/future callbacks, and prevents subsequent credential saves. Terminal credential persistence and event delivery share the same cancellation barrier. `cancelAll()` applies the same rules to each owned request; it does not signal another launcher session. `hasActiveRequests` stays true through subprocess cleanup and the ordered final callback, including cancelled requests whose callbacks are discarded.

`result`, `auth_url`, and `error` are terminal records. Progress/QR records are intermediate and never persist credentials. A crash after progress, missing terminal, duplicate terminal, broken pipe, launch failure, or nonzero exit following a result yields a fixed sanitized error. A successful `auth_url` is valid without a `result`. Tokens are removed from UI events and saved only from a successful final result after the process lifetime barrier. Invalid requests are rejected before process launch. The request pipe disables descriptor-specific SIGPIPE; no global signal policy is changed.

The app launches the original `StoreBridge/supervisor.py`. This guardian forks a bridge child in a dedicated process group and observes it with `waitid(WNOWAIT)`. Its child PID is not reaped until cleanup finishes, reserving the PGID against reuse. Cancel signals only the still-running guardian; it sends TERM, then KILL when needed, to that reserved job group. macOS `libproc` group membership and short BSD process status distinguish live processes from zombies. The guardian does not exit or close its stdout lifetime barrier while live descendants remain. Backend helper processes join this job group in supervised mode; standalone CLI operation retains its previous process-group behavior. Python errors still clean up the reserved group before exit.

Authentication temp directories are created beneath a guardian-owned private 0700 job directory. After its descendants are gone, the guardian removes that directory, including credential files left when forced termination skips a child's `finally`. Normal backend cleanup still removes its own temporary files. The guardian performs no global process matching or termination.

`StoreClient(project:stateRoot:)` optionally passes `READY_DATA_ROOT`. It changes account/cache/install-lock state paths, not the project/source/runtime root. The shared Python resolver requires an absolute owned private directory with no symlink components; the default remains `~/Library/Application Support/M1Launcher`. Custom roots also get a distinct Keychain service namespace, while an explicit default root preserves the existing production service. Profiles remain separate within each namespace.

Validation: `Scripts/test_store_client.py` compiles the actual production Swift client and exercises Foundation `Process` with a local Python fixture and an injected memory vault. Its 16 checks cover cancellation before launch and after terminal queuing, ordered active-state callbacks, crashes/terminal failures, fragmented JSON, auth URL completion, pipe and vault failures, cancellation of stubborn children/grandchildren, isolation of a concurrent job, and pure Keychain query namespace comparisons. No Keychain read/write or real store account is used. `Evidence/store-client-tests.json` records the result. Python tests additionally exercise the real backend installation-lease descriptors during forced cancellation, verify the lease remains busy until all download workers stop, and verify guardian-owned credential temp files disappear before completion.

## Corrected central Steam helper

The normal SteamBridge recipe now applies the pinned LGPL SteamKit WebSocket
cleanup fix to an owned source copy before compiling. The normal upstream
checkout stays unchanged. The resulting version retains Ready and patched
SteamKit sources, the original modified file, patch/lock, licenses, exact NuGet
archive hashes, build command and file/mode inventory. The executable runtime
contains only the pinned .NET host/shared runtime, not SDK build tools.

For an offline Steam-only build using the already verified SDK and package cache:

```sh
python3 Scripts/store_bootstrap.py --steam-only \
  --work-root /absolute/owned/work/build \
  --sdk-root /absolute/verified/dotnet-sdk-copy \
  --tools-store /absolute/owned/work/retained/store-tools
```

This mode performs no source/SDK/Python download. It publishes a new immutable
version rather than overwriting a helper DLL. Add
`--no-project-helper-selection` to build a reviewable candidate only. The normal
project's existing `Runtime/Tools/StoreBridge/SteamBridge` convention selects the
version through an atomic directory link; a private selection history retains
the prior target and the old development build remains intact. The locator
resolves that link before starting .NET so sibling assemblies cannot switch
versions during startup. The version and manifest can be checked with
`python3 Scripts/store_steam_tools.py verify /absolute/version`.

`READY_STORE_TOOLS_ROOT=/absolute/version` explicitly selects a complete central
tools view independently of `READY_RUNTIME_ROOT`. Its default remains
`<runtimeRoot>/Tools/StoreBridge`. An explicit missing tools root does not fall
back to an older development helper. Ready uses the same native helper and
profile-scoped credential boundary for Windows and macOS requests; these tools
are not copied into Wine prefixes. Changing this tools selection does not edit
an engine configuration, a saved runtime location or any account.

To reverse an owned project selection, use
`python3 Scripts/store_steam_tools.py rollback-project /absolute/selection-history.json`.
It verifies that the current selector still matches that record, restores the
previous version or the original development fallback, and retains code and the
old selector. An explicit environment override continues to select its exact
version until the caller changes that override.

The current local view may reference the existing Python/download-engine code
through explicit read-only-use aliases; their original locations and bytes are
not moved or deleted. That view is local-only. Python/Homebrew portability,
complete .NET/NuGet corresponding-source/notices and whole-tools binary
distribution approval remain separate work. The manifest does not label those
closures approved or include any proprietary Valve/Apple assets.
