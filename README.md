# ready

Free, open-source native macOS game launcher for Apple Silicon. **Work in progress**, not yet a finished replacement for Steam or a production-ready game compatibility package.

Repository: https://github.com/Hais00/ready (currently private). Our code is **GPL-3.0-only**; see [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).

## Design

- Native AppKit window with one opaque Metal canvas, rendered only when the UI changes. Visible hover/pressed/focus feedback, proportionate icons, controller/keyboard navigation and fullscreen. Search, profiles, options, errors, authentication and maintenance use asynchronous panels inside the launcher; file/folder browsing is also internal.
- Explicit teardown of launcher textures/drawables during play. Hosted native games reopen the actual Ready interface in the same window, with a one-shot CPU-blurred, dimmed background instead of continuous live blur. Closing releases that UI again. Other supported paths use the in-process drawable overlay. **Fullscreen/direct-display eligibility is not proof of actual direct-to-display.**
- Steam, Epic, GOG and Amazon integration through open protocols and open-source helpers. Real Steam login now persists across reconnect and app restart. Ready has launched native Cyberpunk 2077 to its settings interface without the full Steam client, displayed its injected overlay and closed the owned session back to the library. General gameplay, real CDN downloads, other-store account flows and Windows authentication/launch remain unverified.
- Steam game launch uses a separate authenticated backend. Genuine SDK initialization, account/subscription and restart checks pass through the actual Swift supervisor. Central tools/native component installation and reversible user selections work without development overrides. The native path uses one-use grants, typed host leases and a health channel; one real native title has completed GUI launch/overlay/shutdown validation. This does not establish catalog compatibility or complete gameplay support. See [headless design](Docs/STEAM_HEADLESS.md), [host supervision](Docs/STEAM_NATIVE_HOST_PROCESS.md), [component installation](Docs/STEAM_NATIVE_COMPONENT.md), [Wine research](Docs/STEAM_WINDOWS_HEADLESS_RESEARCH.md) and [ownership preflight](Docs/STEAM_OWNERSHIP_PREFLIGHT.md).
- Steam library scrolling uses a native sparse layer grid, cached sorting and bounded card tiles. Artwork has a persistent indexed APFS cache: prefetch owned entries before clicks, then revalidate icon/banner only on detail opening. Public descriptions warm across the library; authenticated CM names/PICS content types distinguish games from other license content, with honest placeholders for unavailable metadata. Detail → Play and existing download controls remain. See [library/UI behavior and verification limits](Docs/STEAM_LIBRARY_UI.md). Native performance checks can also run entirely through CLI, with no screen capture; see [the measured scope](Docs/HOSTED_PERFORMANCE_AUDIT.md).
- Settings → Archiviazione manages persistent game libraries and a default installation folder. Installation details select among them, show per-version payload sizes and reserve free space across the whole volume; installed folders are measured separately. See [game storage and size semantics](Docs/GAME_STORAGE.md).
- Steam size planning handles zero-ID license placeholders and missing package access tokens. Two actual authenticated plans now pass the pinned downloader validator; license-metadata failures preserve estimates and show a specific explanation. See [the size/license verification](Validation/steam-size-license-checkpoint.json).
- The game detail renders stored sizes immediately and refreshes only the selected game/version in the background through a lighter display request. No extra all-catalog size pass is needed; display data and install authorization stay separate. See [size cache verification](Validation/game-size-cache-checkpoint.json).
- Partial Steam mode entries keep available launch, feature and achievement facts without erasing known metadata. Legacy platform fields and an explicit same-AppID Store fallback are supported; missing publisher descriptions remain explicit. See [partial metadata](Docs/STEAM_PARTIAL_METADATA.md).
- Saved Steam startup failures recover through bounded retries, preserving the credential and newer offline/logout choices. Reconnect reloads the profile file if the service never selected its account. A live restoration returned OK with the same saved credential and no QR; see [startup recovery](Docs/STEAM_STARTUP_RECOVERY.md).
- Native Cyberpunk hosting now carries precise trackpad scroll phases, restores cursor ownership after gestures, and provides the hosted Ctrl+Shift+Space overlay. Protocol V6 uses two validated frame slots and reuses Metal 4 fence objects; public catalog/artwork maintenance pauses during gameplay; isolated correctness checks do not certify native FPS parity. Real direct-mode benchmarks and trackpad/game acceptance remain with the user. See [native fixes and limits](Docs/NATIVE_CYBERPUNK_FIXES.md).
- macOS and Windows builds are distinguished. A macOS store flag is not labelled Apple Silicon native until its installed Mach-O executable is inspected.
- **One Windows prefix per game/profile**, with shared centrally versioned engines and game files. Native macOS apps do not use Wine.
- Persistent profile Documents/Saved Games; isolated game/profile AppData and registry. Prefix recreation preserves personal data and retains a rollback copy. Legacy single-prefix migration never deletes its source automatically.
- Automatic renderer selection uses runtime availability and verification evidence, exact game/runtime rules when available, and advanced overrides. No arbitrary simultaneous loading of DXVK and D3DMetal.
- Settings, accounts/friends, downloads and profiles open as main navigation pages, with the sidebar always available. Settings has its own section tabs; form errors remain inline. See [interface behavior](Docs/INTERFACE.md).
- Scrolling reads 512-pixel card thumbnails on separate interactive workers, with directional prefetch and RAM isolated from detail banners. Visible downloads have reserved capacity; background index/blob writes cannot block cached reads. Durable URL receipts and a recovery snapshot preserve cached files across failed index commits.
- During gameplay, decoded artwork caches and library graphics are released, with no thumbnail snapshot retained in RAM. Titles/catalog models stay available; on return, visible cards are reloaded first from the indexed disk cache.
- Native hosting moves console-session audits and diagnostic writes off the input/render hot path, delivers logical key-window focus for wheel consumers and balances one AppKit cursor hide per capture. Library return reconstructs cards before background shader compilation/maintenance. See [native verification](Validation/hosted-native-interaction-checkpoint.json); real Cyberpunk frametime and physical-trackpad acceptance remain with the user.
- Artwork checks retain the selected image while its URL remains in metadata; reordered background candidates and temporary HTTP failures do not replace it. New Steam banner selections prefer the library hero. Cached banner decoding keeps the same image role instead of flashing an icon.
- Account storage defaults to the macOS Keychain. Following explicit user consent, this installation selects a profile-scoped private refresh-credential file for Steam only; other stores keep Keychain, old entries stay untouched, and passwords are never saved in the file. The genuine native Steam component also maintains its own private profile/game login cache, excluded from the repository. No telemetry.
- Steam login persists independently of per-game native workers. Workers may stop with the game; a new credential initializes native login once, and later launches reuse the genuine saved login while still requiring a current ownership grant. See [persistent login](Docs/STEAM_SERVICE.md#persistent-login-and-per-game-native-workers).
- A single Steam account sign-in serves native macOS and Windows/Wine targets in the same profile. The account coordinator reuses that profile's selected credential storage, joins concurrent login requests and shares exact-game preflight requests; ordinary network/backend failures do not demand a new QR. Thirteen coordinator process checks, sixteen StoreClient checks and sixty-seven bridge checks cover this account flow. Authenticated game-worker handoff and gameplay remain separate integration gates.
- A persistent Steam network service now provides QR/password/Steam Guard login, account/public-name separation, friends and their relationships/activity, presence controls, network reconnect and remote-session/revocation handling. The in-window account UI consumes its private profile-bound stream; credentials never enter UI events. The source-built adapter compiles against the pinned SteamKit and passes 71 offline lifecycle/protocol/social checks; live server behavior is not certified by those checks. See [service scope](Docs/STEAM_SERVICE.md).
- Steam downloads have a durable per-profile queue with pause/resume/cancel, retained depot cache, numeric progress and verified installation completion under shared-file leases. Twenty-one cold-process backend groups, five patched-engine fixtures and four frontend queue checks pass; real account/CDN downloads remain to be validated. See [download behavior](Docs/DOWNLOADS.md).

The opt-in [same-window presentation](Docs/READY_HOSTED_PRESENTATION.md) now defaults to native remote-layer hosting. Ready retains its fullscreen Space; the game keeps its original Metal layer, drawable and command queues. After a bounded startup observation, rendering needs no application-level per-frame surface import or PRESENT RPC. The surface transport remains available through `--host-game-transport surface`. CLI-only Cyberpunk tests on this M1, with Metal HUD and no screen capture, measured **37.11 FPS hosted vs 36.75–36.92 native with VSync**, and **37.52 vs 37.12 with VSync off**. The latter 99th-percentile engine frame times were 35.46 vs 39.43 ms. These samples show no added rendering penalty; they do not certify literal zero overhead, input latency, direct scanout or other titles/macOS versions. The remote path uses private system APIs; our bindings remain GPL and no Apple implementation is bundled. See [results and limits](Docs/HOSTED_PERFORMANCE_AUDIT.md). The real AppKit wheel-event bug is fixed and the user confirmed scrolling.

See [interface behavior and verification](Docs/INTERFACE.md), [local runtime installation](Docs/LOCAL_RUNTIME_INSTALLER.md), [build/test storage](Docs/BUILD_STORAGE.md), [portable frontend packaging](Docs/FRONTEND_PACKAGING.md), [requirements and evidence gates](Docs/REQUIREMENTS.md), [prefix architecture](Docs/PREFIXES.md), [store integration](Docs/STORES.md), [overlay](Docs/OVERLAY.md), and [current work state](Docs/STATUS.md).

The [unified in-game interface checkpoint](Validation/unified-game-interface-checkpoint.json) records actual-canvas routing, snapshot cancellation/resource cleanup, software filtering and an owned remote-Metal window capture fixture. The background is frozen while the interface is open. These checks do not establish commercial-game GPU cost or direct display with the UI visible.

An optional `--host-game-gpu-blur` experiment now applies a low-resolution MPS blur to the native Metal drawable only while the in-game interface is open. It has rendered one presented blurred frame in Cyberpunk; no FPS or frame-time result is claimed. See [the scoped live-blur checkpoint](Validation/live-gpu-blur-checkpoint.json) and [overlay details](Docs/OVERLAY.md#optional-live-gpu-blur-experiment).

The [reopen regression checkpoint](Validation/gpu-blur-reopen-checkpoint.json) fixes hook reinstallation after closing the overlay and scopes presented-frame acknowledgements to each opening. Twenty-cycle CPU fixtures detect the original defect, and three consecutive openings in Cyberpunk received separate presented-frame acknowledgements. No new FPS result is claimed.

The [overlay response checkpoint](Validation/overlay-response-checkpoint.json) adds a shared 240 ms timeline for the dock, header and game blur, immutable shader caching, and visible-card restoration during play. User checks confirmed prompt opening and removal of the post-overlay cursor jump after unnecessary physical recentering was removed. These are scoped functional checks, without a new FPS benchmark or a general-game compatibility claim.

The [monochrome catalog checkpoint](Validation/monochrome-catalog-checkpoint.json) records the neutral UI palette, top-aligned dock, upright cached game icon and full-height catalog scrolling behind header/error text. Artwork keeps its source colors. Build, owned rendering/navigation fixtures and a normal-library visual check passed; this checkpoint does not add a gameplay benchmark.

## Build and test

The frontend build targets macOS 14+ and Swift 5.10+; current runtime validation is on macOS 27.0.1. The currently built Wine/Vulkan payload declares macOS 27 as its minimum OS. Metal4/GPTK4 testing requires a compatible newer SDK/OS and Apple Silicon. The native group-lifetime checks have not been run on macOS 14/15.

```sh
swift build --product M1Launcher --jobs 2
swift run --jobs 2 ReadyCoreProbe
python3 -m unittest discover -s Tests/StoreBridgeTests -v
sh Scripts/build_overlay.sh
python3 Scripts/test_overlay.py
sh Scripts/build_app.sh
```

`ReadyCoreProbe` and the XCTest wrapper execute the same domain checks. The probe also works with Command Line Tools alone. For visual QA:

```sh
swift run M1Launcher --preview Evidence/ready-preview.png
swift run M1Launcher --graphics-self-test
```

The app is generated at `Build/ready.app`. The frontend carries its own support code, native overlay, session keeper, sources and notices. Engines and store tools remain external and central; `READY_RUNTIME_ROOT` selects their location. A packaged frontend defaults to the selected application-data directory’s Runtimes folder and reports an absent runtime honestly. Source execution retains its development fallback. See the packaging guide for the exact scope and remaining distribution requirements.

Versioned [relative runtime paths](Docs/PORTABLE_RUNTIME_PATHS.md) resolve against the configuration location. Diagnostic projections retain component bytes and historical receipts while generating separate entrypoints and ICDs for relocation testing. Whole-runtime assembly and distribution remain work in progress. The active generation68 retains its old native path; a separate source-built ARM64 candidate removes Homebrew runtime dependencies and passes 19 GPU/property probes plus five sandbox controls, without activation.

## Sources and runtimes

Ready's new Steam host, adapters and account orchestration are independently
authored GPL code. Genuine Valve client assets are external proprietary inputs;
GameNative's withheld bootstrap/host implementation is not included. Static
analysis and local probes do not establish permission to redistribute either
party's binaries or make them open source.

```sh
python3 Scripts/fetch_sources.py
```

Public upstream sources go into ignored `Vendor/`, pinned in `sources.lock.json`. Store helper source acquisition/build scripts and locks live in `StoreBridge/` and `Scripts/`. Build/download intermediates can be cleaned only inside this project after preserving installed runtimes and provenance.

Additional source-only packets retain the complete recursive [renderer sources](Docs/RENDERER_PROVENANCE.md) and [Wine/DXMT/data/toolchain inputs](Docs/RUNTIME_CORE_PROVENANCE.md), with exact archive/commit pins, acquisition recipes, notices and integrity checks. Acquiring these sources does not attest every historical binary build or approve an entire runtime release.

Apple D3DMetal/GPTK evaluation libraries are **proprietary optional local inputs**, excluded from the open-source distribution. Their beta license permits certain non-commercial distribution; that does not make them open source or license them under our GPL. The working open DX11 path tested here is Wine + [DXMT](Docs/DXMT.md). Wine + Vulkan + KosmicKrisp/MoltenVK also passes Vulkan presentation probes. Current DXVK/VKD3D device-creation failures are documented in [runtime validation](Docs/RUNTIME.md); those paths are not enabled automatically as verified DX11/DX12 engines.

## Verified so far / still open

The [Steam headless checkpoint](Validation/steam-headless-checkpoint.json) separates
these scopes: Windows PE32/PE64 offline IPC and controlled negative authentication;
native offline host/peer IPC with seven sandbox controls and composed-shim
fixtures; and the latest real SteamKit attempt that passed QR/login and genuine ownership
preflight. A later native ARM64 run also reached logged-on/subscribed state
without Steam.app and tore down normally; no game was started. Earlier helper
and native-login failures remain separate history, and Windows authentication
is not inferred from the native result. The current live-status UI passes 28 synthetic checks;
21 SessionManager checks include blocking Steam launch without a verified host.
Private report/source/artifact hashes are bound without publishing account data.


The [sanitized checkpoint](Validation/checkpoint.json) records 30 domain checks, 64 store protocol/concurrency tests, real process/session coordination, and real Wine registry/folder API checks across game/profile prefixes. Two actual Windows sessions also verify that terminating A leaves B running with its lease intact. Game readers and store writers now protect shared installation files with an interoperable lease. Twenty-eight keeper checks include native wrappers that exit before their child, isolated termination, crash survival and actual Metal overlay handoff. Sixteen real-process StoreClient checks cover cancellation and private credential transport without accessing real Keychain accounts. Actual Metal overlay rendering passes six ARM64/x64 paths and a Windows Vulkan → Wine → KosmicKrisp path. The launcher releases its canvas texture during play; a local Metal allocation measurement falls from about 47 MB to 0.74 MB.

The Library menu and settings expose **Dati e ripristino** for guided legacy migration, interrupted-copy recovery and archival rollback. The copy crash probe passes; owner selection, copy, archival rollback and recovery after real copy/rollback interruptions have also been exercised through AppKit with synthetic files. Originals remain hash-identical; real legacy games and saves still require validation.

Save-folder recipes persist outside disposable prefixes. Eleven recreation-crash checks include a real SIGKILL before replacement metadata exists; ten archive-recovery checks include six real SIGKILL boundaries and preserve one stable recovery archive. These use synthetic data and do not certify migrations of real user games. Interrupted renderer DLL projections also recover under the prefix lease, retaining before/after custom versions.

The relocatable frontend passes 15 packaging/configuration checks, including a saved central-runtime location, restoration and invalid-path rejection. **Libreria → Motori…** selects that location without copying engines or changing their configuration. The graphical folder selection and previous-location restore were also exercised with isolated application data. A separate [protocol2 XInput provider](Docs/XINPUT_CAPTURE.md) passes 40 API/opt-out cases, 24 negative protocol checks, four session-pair cases and five native opt-in unit cases, plus injected-overlay integration with simulated input. The new per-game/profile controller preference is covered by Core policy checks. All five production SessionManager [controller-policy E2E](Docs/CONTROLLER_POLICY_E2E.md) cases now pass under real Wine on Dati APFS, including private-DLL preservation and actual DXMT rendering. GUI save/reopen and profile separation also pass. No physical-controller or other input-API support is established.

Frontend snapshot v2 captures exact Core/App/overlay/keeper source membership, Package.swift and build recipes (including the top-level build script and snapshot validator), then binds the resulting binary, compiler modules and signed support. Fourteen lightweight tamper fixtures pass. Legacy v1/debug snapshots are rejected before any compiler or app publication; they are never retroactively labelled v2. A fresh normal build, real v2 assembly and strict code-signature verification now pass. Build caches and large test data use the user-selected Dati APFS volume. Project-only integrated runtime proposals retain durable before-images; activation code has 18 transaction fixtures and still requires a reviewed readiness receipt. The seven integration gates pass against the retained production evidence and strict v2 app. The integrated XInput/source ARM64 configuration is now active in the project. Promotion is confined to the two project configuration files; it preserves durable before-images and never edits user overrides, prefixes or proprietary policy flags.

For an isolated application-data root use `--data-root /absolute/path` (profiles, store state, installation locks and Keychain service namespace are separated).

WineCX 11.19 plus the optional local GPTK4 beta3 now passes actual DX12 GPU buffer, clear, shader/readback and 600-frame presentation probes. Its injected overlay uses the observed Metal4 path with completed GPU work and zero errors. Settings exposes an explicit local evaluation mode and restoration of the previous runtime configuration, with an on-screen evaluation label. `evaluationModeEnabled` is false by default and enforced by renderer selection, including manual overrides; this is not a consumer-play or redistribution permission. A same-prefix Wine 11.20 → WineCX → Wine 11.20 round-trip preserves personal state and leaves another game's registry/DLLs unchanged.

After provisioning the local runtime, additional integration probes are reproducible with `Scripts/runtime_prefix_proof.py`, `Scripts/test_wine_sessions.py` and `Scripts/runtime_wow64_smoke.py`. They use synthetic data and Windows programs; they do not use store accounts or real user saves.

The separate [PE32 shader proof](Docs/WOW64.md) also passes on the open DXMT provider: a real i386 process compiles SM5 shaders at feature level 11_0, draws a triangle and reads back all 4,096 pixels correctly. Engines, source providers and default configuration remain unchanged; this adds no commercial-game, performance or distribution approval.

These probes do not prove a commercial game works, its anti-cheat accepts Wine, or a real account login/download succeeds. The tested fullscreen baseline and injected overlay both show **Composited** in the Metal HUD; direct display remains unverified. Physical-controller behavior, input suppression, native app save isolation, complete release packaging and real game/migration validation remain open. The active runtime now uses the source-built dependency payload: 17 pinned source components and a verified 25-library/module distribution subset, with source, recipe, notice and runtime-test receipts. This does not approve whole-application redistribution; [distribution readiness](Docs/DISTRIBUTION.md) still tracks the other components and packaging. Nothing is published as a completed product yet.
