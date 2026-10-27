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
- Native Swift/Metal frontend compiles. Initial visual QA found upside-down text; corrected the graphics context and rechecking.
- Nine domain probes pass (including paths/registry isolation, persistent personal folders, engine selection, and legacy source preservation). XCTest is unavailable in this Command Line Tools-only host; `ReadyCoreProbe` runs the SAME shared checks without XCTest. Full Xcode CI can run the XCTest wrapper.
- Overlay universal dylib passes six actual GPU paths (Metal3, scheduled Metal3, Metal4; ARM64 and x64/Rosetta), keyboard/mouse, protected control file, and independent two-process sessions. Actual direct display and physical controller behavior remain open.
- Store bridge has real protocol implementations and source-built helpers; no actual account login/download validation yet.
- Runtime agent is building Wine11.20 and has installed/probed ARM64 and x64 KosmicKrisp and universal MoltenVK. Apple runtime interoperability remains under investigation.
- No repository goal completion is claimed. Do not delete old prefixes or mark migration complete based on synthetic tests.
