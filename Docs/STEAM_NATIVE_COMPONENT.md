# Local native Steam component

`Scripts/steam_native_component.py` prepares a versioned **local-only** component
from Ready's current GPL sources. It compiles the ARM64 host, filesystem and IPC
adapters, private discovery service, lookup adapter and independent SDK probe.
It does not load any of them during preparation. Its static inspection accepts
only system-linked dependencies; no Homebrew library, Apple SDK/header payload,
Valve client, game, credentials or account state is copied into the component.

The external installed `steamclient.dylib` and game `libsteam_api.dylib` remain
proprietary references. The current measured image hashes are required. These
hashes establish image identity; they do not establish entitlement, general SKU
support, successful game initialization or permission to redistribute Valve code.
An AppID binding does not authenticate an account. Every binding starts with
`genuineSDKInteropVerified:false`, `genuineEntitlementVerified:false` and
`commercialGameExecutionVerified:false`.

## Preparation

Use an existing canonical private owned work root with the explicit workspace
marker, and an immediate child store whose parent already exists:

```sh
python3 Scripts/steam_native_component.py prepare \
  --workspace '/Volumes/Dati APFS/Codex-ready-01a17e79' \
  --components-store '/Volumes/Dati APFS/Codex-ready-01a17e79/retained/native-components'
```

Preparation snapshots our sources, GPL license and recipes, compiles with system
Clang, signs our binaries ad hoc, checks their ARM64/system dependency closure,
and records every file's digest, size and mode. No testing macro is passed.
The component and source/recipe fingerprints determine a version ID. An existing
version is verified and reused; versions are never overwritten. Publication uses
Darwin's exclusive rename on the same filesystem. A failed preparation leaves its
own marked staging directory for inspection and publishes no version or selector.

The host uses its existing source-build helper inside the captured source tree.
The snapshots are corresponding source for our binaries, not source for the
external Steam client or SDK. Build commands in provenance can mention the old
staging directory; these are historical records, not operational fallback paths.
All operational component asset paths are relative to the component root.
Python and Apple Clang are external build-time tools, not bundled payload or a
claim of Python/.NET source closure. The compile target is macOS 14, while runtime verification on other macOS releases
requires separate evidence. Consumer distribution remains unapproved.

## Explicit binding and selection

The Python API is:

```python
prepare(workspace, components_store)
bind_game(componentRoot, clientPath, sdkPath, gameID, stateRoot)
verify_component(componentRoot)
rollback(stateRoot, gameID, bindingID)
```

`stateRoot` must already exist, be canonical, private (0700) and owned by the
current user. It must be separate from component code. The tool validates all
inputs before creating its own state marker and selection directories. It never
changes `HOME`, engine runtime configuration, the frontend runtime pointer, an
immutable store-tools version or an account vault.

```sh
python3 Scripts/steam_native_component.py bind \
  --component-root '/absolute/component/versions/native-ID' \
  --client '/absolute/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib' \
  --sdk '/absolute/owned/game/Contents/Frameworks/libsteam_api.dylib' \
  --game-id 1091500 --state-root '/absolute/private/app-data'
```

Binding copies only small JSON metadata. The seven `assets` match the existing
`ready-steam-native-host-binding-v1` decoder: five Ready artifacts plus external
client and SDK references. The Ready SDK probe is an additional verified
`extraFiles` entry and `sdkProbe` role. Its presence never executes it or implies
SDK readiness. The parent must still authenticate, authorize the exact game,
apply independent filesystem/IPC sandboxing and retain the session leases.

The owned marker is `.ready-steam-native-component-state`. Selection lives at:

```
stateRoot/Components/SteamNativeHost/AppID/
  selected.json
  versions/binding-ID/binding.json
  history/UUID.json
```

`selected.json` is private JSON with schema 1, kind
`ready-native-steam-host-selection-v1`, a relative `manifestPath` under `versions/`
and its `manifestSHA256`. Replacement is atomic; the preceding selector is saved
byte-for-byte in `history` first. Invalid existing metadata is rejected, never
silently replaced. Aliases, unknown asset roles, changed bytes and non-production
components are rejected. The user-state reader gives this explicit owned
selection precedence over the legacy tool-directory convention.

Rollback is explicit and revalidates the old component and both current external
images before restoring the old binding:

```sh
python3 Scripts/steam_native_component.py rollback \
  --state-root '/absolute/private/app-data' --game-id 1091500 \
  --binding-id binding-0123456789abcdef01234567
```

No previous version, personal data or installation is deleted. Selection is an
explicit local operation; preparation alone does not select anything. Tests bind
only marked scratch roots on the work volume. Positive reference tests may read
and hash the known installed images, but do not execute their initializers, SDK
APIs, authentication, full Steam or games.
