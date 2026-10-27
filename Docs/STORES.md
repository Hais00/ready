# Store bridge

The store bridge is GPL-3.0-or-later source in `StoreBridge/`. It reconstructs the public GameNative account/library architecture without using any closed GameNative module. See `StoreBridge/NOTICE` and `StoreBridge/dependencies.lock.json`.

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
| `download` (`install` alias) | `options.gameID`, `platform` (`windows`/`macOS`), absolute `installDir`, and game `metadata` | sanitized numeric progress then result with installed variants; failure never becomes an empty success |
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

`macOS` in store metadata is **not** `arm64`. All remote macOS variants begin with `architecture: "unknown"`. `native_inspect` reads the actual installed Mach-O header (including fat binaries), resolves `.app/Contents/Info.plist`, and rejects iOS-only bundles. Windows EXE candidates require launch-entry selection and execution validation. This avoids labelling an Intel-only Mac port as Apple Silicon native.

## Credentials and cancellation

- Native frontend stores returned credentials in macOS Keychain, keyed by profile and store.
- Epic's temporary `user.json` is mode 0600 inside a temporary config, including engine failures/cancellation. Only an explicit whitelist of non-secret installation metadata/manifests is copied back to the profile cache. GOG credential JSON and Nile's encrypted credential state also live in a mode-0700 temporary directory, removed after the operation.
- The bridge forwards only numeric progress from engines. It discards raw engine logs because they may contain signed CDN URLs or account data.
- SIGTERM becomes cancellation, allowing process-group cleanup and credential-file removal. After a hard crash or SIGKILL, normal `finally` cleanup cannot run; a production release still needs startup cleanup of stale private auth artifacts.
- Current lock/pagination checks reject conflicting profile-store operations and repeated remote page tokens. Errors do not return partial libraries as successful complete libraries.

## Verified evidence

`Evidence/stores-tests.txt`: synthetic protocol and HTTP fixture tests for auth, profile isolation, PKCE/CSRF, refresh, pagination failures, cross-platform metadata, native architecture inspection, downloader token hygiene and failure handling.

`Evidence/stores-helper-smoke.json`: actual local execution of SteamKit helper self-test and Legendary/GOGdl/Nile/DepotDownloader version commands. `.NET` and Python helper dependencies are installed locally, not in public source distribution. Dependency archives are pinned and the exact source retrieval is scripted. `Evidence/stores-python-packages.txt` records Python dependency versions; a distributable binary still needs a full third-party notice/source-offer audit.

Remaining direct evidence: real authorized account logins; real small entitled downloads for each platform/store; launch executable selection against actual manifests; working Steam client coupling where required; Epic DRM/EOS corner cases; Amazon SDK-dependent launches; account switching while a game is running; crash recovery of temporary auth artifacts.
