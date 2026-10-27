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

The frontend derives download targets from `Games/<store>/<safe-game-id>/<platform>`, independent of the active profile. Credentials remain profile-specific in Keychain; Wine session/prefix locks belong to the separate session manager. StoreBridge does not acquire a running-game/prefix lock.

StoreBridge canonicalizes `installDir` with filesystem realpath, then holds an exclusive installation lease for the complete downloader/verification/launch-resolution operation. Its keys contain neither profile nor account IDs: two profiles, stores, or symlink aliases targeting the same directory cannot write it simultaneously. Pathname and filesystem-inode locks also cover insensitive-filesystem aliases and directory replacement. Ancestors have shared leases, so nested targets conflict while distinct sibling games can download concurrently. A competing request fails promptly with `installation_busy`; the caller can retry after the active download ends. No entitlement, account identity, or token is written into shared lock files.

Zero-byte lock files live in the owned private `~/Library/Application Support/M1Launcher/InstallLocks` directory. Kernel `flock` ownership determines whether they are busy; files are never unlinked as a stale-lock workaround. Descriptors pass into the downloader so it retains the lease if the bridge crashes, and are released when all holders exit. Normal cancellation terminates the downloader process group before releasing the bridge's lease. Installation identity is rechecked before starting the engine and before reporting completion.

Writable helper caches are isolated under `Profiles/<canonical-UUID>/Stores/<store>/Games/<SHA256(gameID)>/<platform>`, with a separate per-game/profile/platform cache lock. Thus unrelated Legendary `installed.json` files and GOG metadata cannot overwrite each other during parallel downloads. Old profile-wide caches are not merged into this new layout; helpers rebuild their metadata and can verify/resume existing shared game content. Credential files remain in private temporary directories and are removed after each operation. Profile/cache directory symlinks are rejected, and install targets cannot overlap the profile-state or lock trees.

Synthetic validation includes real subprocess contention across profiles and symlink aliases, nested-vs-sibling paths, independent same-profile game caches, profile symlink rejection, directory replacement, cancellation/failure cleanup, and an orphan downloader retaining its inherited lease after its bridge process exits. These checks use fixtures only and do not claim real store account/download compatibility.
