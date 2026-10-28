# ready

Free, open-source native macOS game launcher for Apple Silicon. **Work in progress**, not yet a finished replacement for Steam or a production-ready game compatibility package.

Repository: https://github.com/Hais00/ready (currently private). Our code is **GPL-3.0-only**; see [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).

## Design

- Native AppKit window with one opaque Metal canvas, rendered only when the UI changes. Reference-inspired sidebar, game cards, controller/keyboard navigation, fullscreen.
- Explicit teardown of launcher textures/drawables during play. In-process overlay draws in the game's existing drawable rather than creating another window. **Fullscreen/direct-display eligibility is not proof of actual direct-to-display.**
- Steam, Epic, GOG and Amazon integration through open protocols and open-source helpers. Login/library/download code exists; real account/entitlement end-to-end validation remains pending.
- macOS and Windows builds are distinguished. A macOS store flag is not labelled Apple Silicon native until its installed Mach-O executable is inspected.
- **One Windows prefix per game/profile**, with shared centrally versioned engines and game files. Native macOS apps do not use Wine.
- Persistent profile Documents/Saved Games; isolated game/profile AppData and registry. Prefix recreation preserves personal data and retains a rollback copy. Legacy single-prefix migration never deletes its source automatically.
- Automatic renderer selection uses runtime availability and verification evidence, exact game/runtime rules when available, and advanced overrides. No arbitrary simultaneous loading of DXVK and D3DMetal.
- Store tokens are stored in the macOS Keychain, scoped to the launcher profile. No telemetry.

See [portable frontend packaging](Docs/FRONTEND_PACKAGING.md), [requirements and evidence gates](Docs/REQUIREMENTS.md), [prefix architecture](Docs/PREFIXES.md), [store integration](Docs/STORES.md), [overlay](Docs/OVERLAY.md), and [current work state](Docs/STATUS.md).

## Build and test

The build targets macOS 14+ and Swift 5.10+; current runtime validation is on macOS 27.0.1. Metal4/GPTK4 testing requires a compatible newer SDK/OS and Apple Silicon. The native group-lifetime checks have not been run on macOS 14/15.

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

## Sources and runtimes

```sh
python3 Scripts/fetch_sources.py
```

Public upstream sources go into ignored `Vendor/`, pinned in `sources.lock.json`. Store helper source acquisition/build scripts and locks live in `StoreBridge/` and `Scripts/`. Build/download intermediates can be cleaned only inside this project after preserving installed runtimes and provenance.

Apple D3DMetal/GPTK evaluation libraries are **proprietary optional local inputs**, excluded from the open-source distribution. Their beta license permits certain non-commercial distribution; that does not make them open source or license them under our GPL. The working open DX11 path tested here is Wine + [DXMT](Docs/DXMT.md). Wine + Vulkan + KosmicKrisp/MoltenVK also passes Vulkan presentation probes. Current DXVK/VKD3D device-creation failures are documented in [runtime validation](Docs/RUNTIME.md); those paths are not enabled automatically as verified DX11/DX12 engines.

## Verified so far / still open

The [sanitized checkpoint](Validation/checkpoint.json) records 28 domain checks, 64 store protocol/concurrency tests, real process/session coordination, and real Wine registry/folder API checks across game/profile prefixes. Two actual Windows sessions also verify that terminating A leaves B running with its lease intact. Game readers and store writers now protect shared installation files with an interoperable lease. Twenty-eight keeper checks include native wrappers that exit before their child, isolated termination, crash survival and actual Metal overlay handoff. Sixteen real-process StoreClient checks cover cancellation and private credential transport without accessing real Keychain accounts. Actual Metal overlay rendering passes six ARM64/x64 paths and a Windows Vulkan → Wine → KosmicKrisp path. The launcher releases its canvas texture during play; a local Metal allocation measurement falls from about 47 MB to 0.74 MB.

The Library menu and settings expose **Dati e ripristino** for guided legacy migration, interrupted-copy recovery and archival rollback. The copy crash probe passes; visual verification of the new dialogs is pending because the Mac was locked during the attempt.

Save-folder recipes persist outside disposable prefixes. Eleven recreation-crash checks include a real SIGKILL before replacement metadata exists; ten archive-recovery checks include six real SIGKILL boundaries and preserve one stable recovery archive. These use synthetic data and do not certify migrations of real user games. Interrupted renderer DLL projections also recover under the prefix lease, retaining before/after custom versions.

The relocatable frontend passes 14 packaging/configuration checks, including a saved central-runtime location, restoration and invalid-path rejection. **Libreria → Motori…** selects that location without copying engines or changing their configuration. The graphical selection flow still needs visual verification. A separate [diagnostic XInput provider](Docs/XINPUT_CAPTURE.md) passes ten DLL/architecture combinations and actual injected-overlay integration with simulated controller input; it is not the active runtime and does not establish physical-controller or other input-API support.

For an isolated application-data root use `--data-root /absolute/path` (profiles, store state, installation locks and Keychain service namespace are separated).

WineCX 11.19 plus the optional local GPTK4 beta3 now passes actual DX12 GPU buffer, clear, shader/readback and 600-frame presentation probes. Its injected overlay uses the observed Metal4 path with completed GPU work and zero errors. Settings exposes an explicit local evaluation mode and restoration of the previous runtime configuration, with an on-screen evaluation label. `evaluationModeEnabled` is false by default and enforced by renderer selection, including manual overrides; this is not a consumer-play or redistribution permission. A same-prefix Wine 11.20 → WineCX → Wine 11.20 round-trip preserves personal state and leaves another game's registry/DLLs unchanged.

After provisioning the local runtime, additional integration probes are reproducible with `Scripts/runtime_prefix_proof.py`, `Scripts/test_wine_sessions.py` and `Scripts/runtime_wow64_smoke.py`. They use synthetic data and Windows programs; they do not use store accounts or real user saves.

These probes do not prove a commercial game works, its anti-cheat accepts Wine, or a real account login/download succeeds. The tested fullscreen baseline and injected overlay both show **Composited** in the Metal HUD; direct display remains unverified. Physical-controller behavior, input suppression, native app save isolation, complete release packaging and real game/migration validation remain open. The active runtime now uses the source-built dependency payload: 17 pinned source components and a verified 25-library/module distribution subset, with source, recipe, notice and runtime-test receipts. This does not approve whole-application redistribution; [distribution readiness](Docs/DISTRIBUTION.md) still tracks the other components and packaging. Nothing is published as a completed product yet.
