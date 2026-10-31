<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Native Windows port

`Windows/` contains an incomplete C# / Vulkan port alongside the existing macOS
implementation. The requested end state remains the complete Ready interface,
native Windows x64/x86 and ARM64 operation, genuine Steam launch and in-game UI.

## Current implementation

`Ready.Windows.Core` provides profiles, atomic library state, PE architecture
detection, a bounded text Valve KeyValues parser, installed Steam library
discovery, canvas layout and interaction. WinForms supplies the HWND and input;
GDI+ rasterizes text/paths into premultiplied BGRA8, then the Vulkan graphics
pipeline presents it. This follows the macOS CoreGraphics-to-Metal architecture.
Normal navigation/forms are drawn inside the canvas. Vulkan is selected
explicitly through Veldrid, without a renderer fallback.

The GLSL shaders port `CanvasShader`'s fullscreen triangle and dock/header motion.
Embedded SPIR-V works independently of CPU architecture; its source/binary hashes
are in `Windows/Ready.Windows/Shaders/shaders.lock.json`. Users need a Vulkan
driver, not a shader compiler or SPIRV-Cross native helper. Upstream Veldrid
`GraphicsDevice.CreateVulkan`, `SwapchainSource.CreateWin32`,
`VkCommandList.SetViewport` and `RenderTests` staging readback were consulted
directly after the local reference index ran out of disk space. Veldrid's MIT
notice is retained in `LICENSES/veldrid-MIT.txt`.

The original dock (72 points), content origin (112), header (84), grid gap (18),
cover ratio (1.5), title band (42) and card inset (7) are preserved. Cards scroll
behind the header; only the visible interaction region accepts clicks. Navigation
and scrolling cancel an existing press. The current Segoe UI text and independent
line icons differ from macOS system typography/SF Symbols; full visual parity
is not established. Windows settings omit Apple Toolkit and translation engines.

Local games start directly through `CreateProcessW`, with an atomic
`PROC_THREAD_ATTRIBUTE_JOB_LIST` admission before their first instruction.
Each session's job owns descendants and uses `KILL_ON_JOB_CLOSE`. The launcher
currently hides, releases artwork/canvas textures, and rebuilds the library after
its job becomes empty. Same-window hosting and the in-game interface remain
required; this hide/restore path does not satisfy those requirements.

Steam discovery reads installed ACF manifests and current/legacy
`libraryfolders.vdf`. It does not read saved Steam credentials, infer ownership
from installation, or guess authenticated launch executables.

## Windows Steam account integration

The account canvas now runs the actual source-built Steam service through
`SteamServiceProcess`, with anonymous stdin/stdout, immutable profile/generation
binding, monotonically increasing event sequences, bounded JSONL, correlated
requests, cancellation and owned-process shutdown. Stderr is discarded and
unknown backend error text never enters UI diagnostics. Private credential
events have a separate receiver; cancelled or old-profile requests cannot save
a late credential. QR URLs remain in memory and are rendered directly into the
Vulkan canvas using QRCoder. Password and Guard inputs are masked and cleared on
submission/navigation; no password is persisted.

`SteamCredentialStore` encrypts refresh credentials with Windows current-user
DPAPI, separate purpose entropy for each profile, protected directory ACLs for
the owner/SYSTEM and atomic replacement. It never selects machine-wide DPAPI.
Offline mode and transient failures retain the login; explicit logout removes
only that profile's credential. Managed string/buffer lifetimes are not a claim
of forensic zeroization. See Microsoft's
[DPAPI contract](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata).

The account page exposes QR/password login, Guard, reconnect/offline/logout,
public name, presence, friends and their explicit relationship actions.
Remove/block require a second matching action within eight seconds. Profile
changes close the old helper and isolate its catalog. The owned library is
received in bounded pages and committed only after terminal counts match;
non-game and Mac-only records are filtered, while uninstalled games remain
uninstalled. An account connection never marks the genuine game host ready.
The download queue is connected separately as described below. Authenticated
game-worker launch remains unfinished.

The native checks cover actual DPAPI/DACLs and real child pipes with an owned
synthetic protocol helper, plus the actual SteamKit adapter's offline snapshot
and shutdown. The form test renders QR/password states through Vulkan, checks
masked GPU pixels against an unmasked negative control, cancels navigation,
completes a synthetic Guard flow and switches profiles. No real Steam login,
social operation, ownership authorization or game launch was performed. The
Steam form fixture requires a new, empty data root so a substitute test helper
cannot receive an existing saved login. The current evidence is in
`Validation/windows-steam-client-checkpoint.json`.

## Native Steam downloads

Windows now builds the same separate GPL-2 DepotDownloader 3.4.0 source archive,
private-stdin adaptation and numeric progress patch used by Ready's macOS recipe.
`Prepare-Downloader.ps1` verifies archive, preimage, patch and output hashes;
`Build-Downloader.ps1` targets .NET 10 and runs the five retained source fixtures
in a separate build copy. The GPL-2 engine remains a child executable and is not
linked into Ready's GPL-3 frontend.

The game detail requests a verified PICS depot plan before offering installation.
The selected IDs/manifests, platform, public branch, English language, architecture,
payload totals and fingerprint are retained. Windows 32-bit planning is now
supported separately from 64-bit planning; macOS planning retains its 64-bit rule.
No anonymous download or broad all-platform fallback is introduced.

`SteamDownloadQueue` stores per-profile jobs, desired state and numeric progress
atomically without credentials or PIDs. Login IDs use the separate `0xD...` range.
The worker reads only that profile's DPAPI credential and sends it through its
anonymous stdin. The UI offers folder/size preview, pause/resume/cancel and
completed-content registration. Partial files/cache are retained. Existing
nonempty folders are not silently adopted; the local content-owner marker binds
an AppID, not an account entitlement.

`OwnedChild` uses an atomic Windows job assignment and an explicit inherited
handle list for pipes and leases. The Steam account supervisor uses that same
launcher. Shared installation coordination checks ancestor/child path overlap,
read/write handle conflicts, canonical kernel paths and reparse/hardlink policy.
The downloader inherits its writer/run handles; local game sessions inherit
reader handles. Kernel handle availability, not metadata age or saved PIDs,
decides whether a worker is still active. Completed records require an engine
exit of zero, an exact selected manifest set, cache config agreement and SHA1
validation of the retained manifest files. Download completion does not certify
game execution or authenticated Steamworks startup.

The size preview distinguishes compressed payload, installed payload and actual
reported network bytes. The initial free-space check is not an exact staging/peak
or cross-process volume-reservation proof. Whole-volume reservations, launch
candidate selection and real-account/CDN acceptance remain to be finished and
verified. Native tests cover owned synthetic files/processes and the actual
downloader's source fixtures/version startup; they do not download a real game.
See `Validation/windows-downloads-checkpoint.json` for the exact measured scope.

## Build

Use Windows 10/11, .NET 10 SDK and a matching Vulkan driver:

```powershell
./Windows/Scripts/Build-Windows.ps1 -Runtime win-x64
./Build/Windows/publish/win-x64/Ready.exe
./Windows/Scripts/Build-Windows.ps1 -Runtime win-x86
./Windows/Scripts/Build-Windows.ps1 -Runtime win-arm64
```

The recipe verifies shader hashes, restores locked frontend dependencies, runs
core checks and publishes a self-contained build. It also prepares the pinned
SteamKit source with the retained bounded WebSocket-close patch, runs the shared
service checks and builds the native Steam service. No Swift, Wine, bash or
Python is required. `-SkipSteam` builds the frontend alone. These are development
artifacts; whole-binary source/notice/distribution closure remains unapproved.

```powershell
# On a Windows machine with a Vulkan GPU:
./Windows/Scripts/Build-Windows.ps1 -Runtime win-x64 -GraphicsChecks -SessionChecks

# After editing GLSL, use an explicit developer compiler:
./Windows/Scripts/Compile-Shaders.ps1 -Compiler C:/VulkanSDK/<version>/Bin/glslangValidator.exe
```

Session checks include a real form/event-loop fixture: profile typing, internal
file browser, PE import, detail/navigation/search, production native launch and
library return, settings, GPU readback and idle rendering. These programmatic
handler checks do not establish physical input/controller acceptance.
`--data-root <absolute-path>` selects isolated state; the default is
`%LOCALAPPDATA%\Ready`. `library-windows.json` remains separate from the Swift
schema until a deliberate migration exists.

## Steam and injection review

The persistent network service was already C#. Windows projects link its actual
production sources. The build verifies the SteamKit archive, shutdown patch and
patched source hashes in a separate owned copy, preserving the original UTF-8
BOM. Authentication identifies Windows correctly. The preflight rejects reserved
AppID `0xffffffff`, as required by the Windows-client research. Heartbeats now
retain safe Steam result/context fields after logoff and cleanup failure.

The broker-to-genuine-game-host boundary is still open. Existing results in
`STEAM_WINDOWS_HEADLESS_RESEARCH.md` were measured under Wine and must not be
relabeled as native Windows results.

| Existing evidence | Windows consequence | Remaining verification |
| --- | --- | --- |
| PE32/PE64 factory, disconnected user and shared-memory isolation | Match genuine Valve DLL architecture and use session-specific Windows object names; the Mac TCP endpoint is not this transport | Native Windows workers, verified external files and isolated state |
| Windows login ABI and callback record sizes 16/24 | Use Windows x86 cdecl/thiscall and x64 conventions; never reuse Mac vtable offsets | Bind exact DLL hashes and prove callback/free lifetime |
| Private `RDYAUTH1` stdin plus ownership broker | Keep credentials out of arguments, environment and logs; login/identity alone is not ownership | Private Windows credentials, worker supervision and a real owned-game launch |
| Metal injection and hosted remote layers | DYLD, AppKit, Mach, IOSurface and Metal hooks are platform-specific | Windows presentation/input interception, fullscreen and teardown |
| Actual Windows Vulkan canvas | C# UI shaders run on the Windows GPU | Reuse the actual UI in the game's presentation path and verify hidden/visible lifetimes |
| Games use D3D9/11/12 or Vulkan | Vulkan UI does not make every game a Vulkan application | Verified interception/interop and synchronization for each supported API/bitness |
| ARM64 frontend build | Does not prove an ARM64 Valve engine is available | Identify external worker architectures and test on ARM hardware |

A Vulkan layer must be enabled only for the owned child and handle loader
negotiation, swapchain replacement, queue synchronization and teardown. DirectX
needs its own presentation/interop path. A C# DLL cannot be passed to remote
`LoadLibrary` as if it were a native overlay: any bootstrap needs matching bitness
and an explicit managed-runtime/export boundary. No arbitrary attachment,
game-DLL replacement, license emulation or GameNative closed helper is added.
Valve's [API overview](https://partner.steamgames.com/doc/sdk/api) describes the
genuine client startup boundary. Windows job admission follows Microsoft's
[job documentation](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)
and [process attributes](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute).

## Completion gates still open

- Complete visual parity, form/accessibility behavior, asynchronous sparse artwork
  and controller navigation across all pages.
- Validate the connected Steam UI and download queue against a real account/CDN,
  including saved-login restore, friends and full owned catalog; complete artwork,
  volume reservation/launch selection and genuine game-worker handoff.
- Repeat headless-host measurements natively and complete real owned-game
  authentication, launch and exit.
- Implement Windows embedding/injection and the actual in-game UI, input gating,
  fullscreen, swapchain recreation and graphics teardown across supported APIs.
- Run on physical ARM64 Windows, including its Vulkan driver and Steam/game
  architecture boundary; cross-publishing alone does not pass this gate.
- Finish other-store Windows adapters, game/save policy, packaging, notices,
  installer/update behavior and required macOS regression checks.

`Validation/windows-native-checkpoint.json` records only its measured scope.
No finished Windows product, broad game compatibility or zero-overhead result
is asserted.
