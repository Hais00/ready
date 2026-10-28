# Continuation state

Started 2026-10-27. Repository: `https://github.com/Hais00/ready` (private). Local source folder: `src/M1Launcher`.

- Native ARM64 macOS 27.0.1, Swift 6.4, Command Line Tools; full Xcode is absent.
- About 10 GiB available initially. Do not clean unrelated `.local`, `analysis`, or `mbp2020-reverse-lab` files.
- User explicitly requested latest beta components and supplied authenticated Apple Developer access.
- Downloaded `~/Downloads/Game_Porting_Toolkit_4.0_beta_3.dmg` and `~/Downloads/Evaluation_environment_for_Windows_games_4.0_beta_3.dmg` through the authenticated IAB.
- Current GameNative source: `../GameNative`, commit `eaa715cf38fddfea6f8d1278c7dd89c0bb50e063`, submodules complete.
- GameNative is GPL-3.0; any translated implementation must retain attribution and compatible licensing. Closed GameNative helpers are not available as source and must not be described as reconstructed.
- Important: upstream Wine plus arbitrary D3DMetal versions is not automatically ABI compatible. Verify rather than assume.
- Do not call the active goal complete until every original requirement has direct evidence.

## Latest steering and progress

- Latest beta releases requested explicitly; fetched Wine 11.20, Mesa/KosmicKrisp 26.3.0-rc2, SteamKit 3.5.1-Alpha.1, plus latest available DXVK/VKD3D/MoltenVK source artifacts.
- Single-prefix design superseded by **game/profile prefixes**. See REQUIREMENTS and PREFIXES.
- Native Swift/Metal frontend compiles and visually checked text orientation/icons. It renders only on change and tears down its canvas at actual game launch, after asynchronous Wine initialization.
- Twenty-six domain checks pass, including independent DLL copy-on-write projections, registry paths, persistent folders, runtime selection and migration preflight. XCTest is absent on this CLT-only host; ReadyCoreProbe runs the same shared checks.
- Real Windows API probes under Wine verify game/profile registry and account marker separation, Documents redirection, and saved-data survival after prefix recreation. Original prefixes and rollback copies are preserved. Guided migration/recovery UI is implemented and compiled; visual verification awaits Mac unlock. An actual copy process was killed mid-copy, archived by recovery and successfully retried with unchanged original hashes.
- Native session keeper checks verify exact-prefix coordination, independent process groups, parent-crash lock handoff, literal arguments and overlay handoff. SessionManager has asynchronous initialization/cancellation/timeout and main-thread lifecycle probes.
- Overlay passes six native GPU paths and Windows Vulkan → Wine → KosmicKrisp → Metal injection. Texture allocation is 835,584 bytes shown and zero hidden. The actual fullscreen HUD reports Composited with and without overlay; direct display remains unverified.
- Frontend allocation probe measures about 47 MB → 0.74 MB after graphics release, canvas texture 15,078,400 → 0 bytes. This is a local probe, not a commercial-game VRAM guarantee.
- Wine 11.20 is built from source. Vulkan native/Wine presentation works. The centrally frozen DXMT provider passes DX11 feature-level 11_0, SM5 shaders/readback and swapchain presentation. Latest DXVK/VKD3D do not pass device initialization on tested drivers; no capabilities are spoofed.
- Apple GPTK4 beta3 is a proprietary optional local input. The isolated WineCX 11.19 evaluation provider now passes DX12 buffer/clear/SM5 shader readback and 600 presentations plus Metal4 overlay GPU completion. It stays disabled by default; consumers do not inherit evaluation or redistribution rights. The same-prefix provider round-trip preserves state and another game's DLL/registry bytes. PE32/WoW64 now passes Win32, DXMT DX11 device/buffer readback and 600-frame presentation; PE32 shader rasterization remains unverified.
- Store bridge has real protocols, manifest executable resolution and source-built helpers; 64 Python and 16 real-process Swift client checks pass. Downloads and launched games coordinate via installation lease v2. Cancellation supervises only that job and retains its lease until descendants and temporary credential cleanup finish; real account login/download/entitlement validation is pending.
- See Validation/checkpoint.json for a sanitized summary. Raw evidence stays ignored. The goal is active; no completion or automatic legacy-data deletion is claimed.

- Standalone Swift probes explicitly build the static LauncherCore product before linking. This prevents a newer Swift module from being linked with an older archive after model-layout changes.
- Keeper and overlay builds publish signed binaries by atomic rename; a real running-child rebuild test verifies old executable mappings and leases remain intact.
- Native controller policy has 30 logic checks; real AppKit modal interaction and hardware remain unverified while the Mac is locked.
- See Docs/DISTRIBUTION.md: a selected source-built dependency payload now passes provenance and runtime checks; remaining components and whole-application distribution are separate gates.

- Settings now offers explicit local evaluation activation and byte-exact runtime restoration with private history. It accepts no vendor terms, grants no rights and includes no Apple binaries. GUI visual verification remains pending; configuration policy/restore checks pass.

- Source generation `68c00b7d3878699829eb` is active after 26 real-wrapper checks and an 8-check Core provider round-trip. Before-images and old immutable providers are retained; user overrides/prefixes were not changed.
- The 17-component source dependency build and selected 25-library/module payload pass the source/runtime gate. Whole-app distribution is a separate gate, and Apple remains external/evaluation-only.
- Game-specific extra save directories are now applied and persisted across recreation. Five real Windows API checks prove normal C:\ProgramData access, game/profile separation and recreation survival; the Core domain suite has 26 checks.
- The frontend is relocatable with its own source, notices, overlay and session keeper. Fourteen relocation/configuration checks pass. Central engines and store tools remain external; Libreria → Motori… stores a private location pointer with history and restore, without editing engine files. Actual selection through the graphical dialogs remains unverified while the Mac is locked.
- A frozen diagnostic Wine 11.20 XInput provider passes ten DLL/architecture combinations, negative protocol checks, two-session isolation and actual injected-overlay integration with simulated controller input. It remains separate from the active runtime; physical controllers, WineCX and other input APIs are open gates.
