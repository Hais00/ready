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
- Eighteen domain checks pass, including independent DLL copy-on-write projections, registry paths, persistent folders, runtime selection and migration preflight. XCTest is absent on this CLT-only host; ReadyCoreProbe runs the same shared checks.
- Real Windows API probes under Wine verify game/profile registry and account marker separation, Documents redirection, and saved-data survival after prefix recreation. Original prefixes and rollback copies are preserved.
- Native session keeper checks verify exact-prefix coordination, independent process groups, parent-crash lock handoff, literal arguments and overlay handoff. SessionManager has asynchronous initialization/cancellation/timeout and main-thread lifecycle probes.
- Overlay passes six native GPU paths and Windows Vulkan → Wine → KosmicKrisp → Metal injection. Texture allocation is 835,584 bytes shown and zero hidden. The actual fullscreen HUD reports Composited with and without overlay; direct display remains unverified.
- Frontend allocation probe measures about 47 MB → 0.74 MB after graphics release, canvas texture 15,078,400 → 0 bytes. This is a local probe, not a commercial-game VRAM guarantee.
- Wine 11.20 is built from source. Vulkan native/Wine presentation works. The centrally frozen DXMT provider passes DX11 feature-level 11_0, SM5 shaders/readback and swapchain presentation. Latest DXVK/VKD3D do not pass device initialization on tested drivers; no capabilities are spoofed.
- Apple GPTK4 beta3 is a proprietary optional local input; working DX12 integration remains open. PE32/WoW64 is still being checked separately from successful PE64 execution.
- Store bridge has real protocols, manifest executable resolution and source-built helpers; real account login/download/entitlement validation is pending.
- See Validation/checkpoint.json for a sanitized summary. Raw evidence stays ignored. The goal is active; no completion or automatic legacy-data deletion is claimed.
