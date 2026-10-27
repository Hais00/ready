# ready

Free, open-source native macOS game launcher for Apple Silicon. **Work in progress**, not yet a finished replacement for Steam or a production-ready game compatibility package.

Repository: https://github.com/Hais00/ready (currently private). Our code is **GPL-3.0-or-later**; see [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).

## Design

- Native AppKit window with one opaque Metal canvas, rendered only when the UI changes. Reference-inspired sidebar, game cards, controller/keyboard navigation, fullscreen.
- Explicit teardown of launcher textures/drawables during play. In-process overlay draws in the game's existing drawable rather than creating another window. **Fullscreen/direct-display eligibility is not proof of actual direct-to-display.**
- Steam, Epic, GOG and Amazon integration through open protocols and open-source helpers. Login/library/download code exists; real account/entitlement end-to-end validation remains pending.
- macOS and Windows builds are distinguished. A macOS store flag is not labelled Apple Silicon native until its installed Mach-O executable is inspected.
- **One Windows prefix per game/profile**, with shared centrally versioned engines and game files. Native macOS apps do not use Wine.
- Persistent profile Documents/Saved Games; isolated game/profile AppData and registry. Prefix recreation preserves personal data and retains a rollback copy. Legacy single-prefix migration never deletes its source automatically.
- Automatic renderer selection uses runtime availability and verification evidence, exact game/runtime rules when available, and advanced overrides. No arbitrary simultaneous loading of DXVK and D3DMetal.
- Store tokens are stored in the macOS Keychain, scoped to the launcher profile. No telemetry.

See [requirements and evidence gates](Docs/REQUIREMENTS.md), [prefix architecture](Docs/PREFIXES.md), [store integration](Docs/STORES.md), [overlay](Docs/OVERLAY.md), and [current work state](Docs/STATUS.md).

## Build and test

macOS 14+ and Swift 5.10+; Metal4/GPTK4 testing requires compatible newer SDK/OS and Apple Silicon.

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

The standalone app is generated at `Build/ready.app`. Development currently expects `READY_PROJECT_ROOT` to point to this source directory when launched elsewhere; self-contained packaging is still an open gate.

## Sources and runtimes

```sh
python3 Scripts/fetch_sources.py
```

Public upstream sources go into ignored `Vendor/`, pinned in `sources.lock.json`. Store helper source acquisition/build scripts and locks live in `StoreBridge/` and `Scripts/`. Build/download intermediates can be cleaned only inside this project after preserving installed runtimes and provenance.

Apple D3DMetal/GPTK evaluation libraries are **proprietary optional local inputs**, excluded from the open-source distribution. Their beta license permits certain non-commercial distribution; that does not make them open source or license them under our GPL. The open rendering path is Wine + DXVK/VKD3D + Vulkan + KosmicKrisp/MoltenVK, subject to actual per-engine compatibility tests.

## Verified so far / still open

Actual Metal overlay rendering has passed ARM64 and x64/Rosetta synthetic paths. Prefix/data-isolation and protocol tests also pass. These do not prove a commercial game works, its anti-cheat accepts Wine, an account login is successful, or macOS selects direct display. Runtime interoperability, real store entitlement/download flows, injected input suppression, physical-controller behavior, native app save isolation, and real game validation remain explicitly open. Nothing is published as a completed product yet.
