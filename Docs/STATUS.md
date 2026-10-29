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

- Settings now has persistent main-content tabs; account/friends, downloads, profiles and ordinary forms use nonmodal pages with the sidebar available. Actual Cua and the scoped automatic checks are recorded in [navigation pages](../Validation/navigation-pages-checkpoint.json). The older floating-dialog UI evidence below is historical. Game-time quit confirmation remains transient. No new server login/download/game certification is implied by this UI checkpoint.

- Latest beta releases requested explicitly; fetched Wine 11.20, Mesa/KosmicKrisp 26.3.0-rc2, SteamKit 3.5.1-Alpha.1, plus latest available DXVK/VKD3D/MoltenVK source artifacts.
- Single-prefix design superseded by **game/profile prefixes**. See REQUIREMENTS and PREFIXES.
- Native Swift/Metal frontend compiles and visually checked text orientation/icons. It renders only on change and tears down its canvas at actual game launch, after asynchronous Wine initialization.
- Thirty domain checks pass, including independent DLL copy-on-write projections, interrupted DLL projection recovery, regular-executable runtime validation, portable configuration resolution, registry paths, persistent folders, runtime selection and migration preflight. XCTest is absent on this CLT-only host; ReadyCoreProbe runs the same shared checks.
- Real Windows API probes under Wine verify game/profile registry and account marker separation, Documents redirection, and saved-data survival after prefix recreation. Original prefixes and rollback copies are preserved. Historical synthetic GUI checks pass 13 migration and 15 interrupted-copy/rollback-recovery cases with the earlier native dialogs. The current in-window dialog UI has separate actual Cua coverage below; real user-game migration is not certified. An actual copy process was killed mid-copy, archived by recovery and successfully retried with unchanged original hashes.
- Native session keeper checks verify exact-prefix coordination, independent process groups, parent-crash lock handoff, literal arguments and overlay handoff. SessionManager has asynchronous initialization/cancellation/timeout and main-thread lifecycle probes.
- Overlay passes six native GPU paths and Windows Vulkan → Wine → KosmicKrisp → Metal injection. Texture allocation is 835,584 bytes shown and zero hidden. The actual fullscreen HUD reports Composited with and without overlay; direct display remains unverified.
- Frontend allocation probe measures about 47 MB → 0.74 MB after graphics release, canvas texture 15,078,400 → 0 bytes. This is a local probe, not a commercial-game VRAM guarantee.
- Wine 11.20 is built from source. Vulkan native/Wine presentation works. The centrally frozen DXMT provider passes DX11 feature-level 11_0, SM5 shaders/readback and swapchain presentation. Latest DXVK/VKD3D do not pass device initialization on tested drivers; no capabilities are spoofed.
- Apple GPTK4 beta3 is a proprietary optional local input. The isolated WineCX 11.19 evaluation provider now passes DX12 buffer/clear/SM5 shader readback and 600 presentations plus Metal4 overlay GPU completion. It stays disabled by default; consumers do not inherit evaluation or redistribution rights. The same-prefix provider round-trip preserves state and another game's DLL/registry bytes. PE32/WoW64 passes Win32, DXMT DX11 device/buffer readback and 600-frame presentation. A separate real i386 shader proof now adds SM5/FL11_0 triangle rasterization and exact 4096-pixel readback; the historical three-step report remains unchanged. See WOW64.md.
- Store bridge has real protocols, manifest executable resolution and source-built helpers; 64 Python and 16 real-process Swift client checks pass. Downloads and launched games coordinate via installation lease v2. Cancellation supervises only that job and retains its lease until descendants and temporary credential cleanup finish; complete account/download/entitlement validation is pending; the later isolated Steam QR/login result and remaining ownership failure are scoped below.
- See Validation/checkpoint.json for a sanitized summary. Raw evidence stays ignored. The goal is active; no completion or automatic legacy-data deletion is claimed.

- Standalone Swift probes explicitly build the static LauncherCore product before linking. This prevents a newer Swift module from being linked with an older archive after model-layout changes.
- Keeper and overlay builds publish signed binaries by atomic rename; a real running-child rebuild test verifies old executable mappings and leases remain intact.
- Native controller navigation has 30 logic checks. Actual current keyboard/focus/cancel flows are checked through Cua as listed below; physical-controller hardware remains unverified.
- See Docs/DISTRIBUTION.md: a selected source-built dependency payload now passes provenance and runtime checks; remaining components and whole-application distribution are separate gates.

- Settings now offers explicit local evaluation activation and byte-exact runtime restoration with private history. It accepts no vendor terms, grants no rights and includes no Apple binaries. Configuration policy/restore checks pass. The new internal confirmation preserves explicit choice and rechecks idle/authentication/state before mutation; actual Apple account, license acceptance or consumer-play authorization is not claimed.

- Historical source generation `68c00b7d3878699829eb` was activated after 26 real-wrapper checks and an 8-check Core provider round-trip. Before-images and old immutable providers are retained; user overrides/prefixes were not changed.
- The 17-component source dependency build and selected 25-library/module payload pass the source/runtime gate. Whole-app distribution is a separate gate, and Apple remains external/evaluation-only.
- Game-specific extra save directories are now applied and persisted across recreation. Five real Windows API checks prove normal C:\ProgramData access, game/profile separation and recreation survival.
- The frontend is relocatable with its own source, notices, overlay and session keeper. Fifteen relocation/configuration checks pass. Central engines and store tools remain external; Libreria → Motori… stores a private location pointer with history and restore, without editing engine files. Native folder selection, reopening and previous-location restore are now verified through the GUI with isolated data.
- The historical E5 input provider remains immutable. The current integrated project configuration selects E6 protocol2 input bindings; its 40 API/opt-out cases, 24 negative checks, four session pairs and five production-policy E2E cases are separately scoped. Physical controllers, WineCX capture and other input APIs remain open gates.
- The native keeper also covers wrappers that exit before their same-group children. Twenty-eight real process checks, including Metal overlay handoff, pass on macOS 27.0.1. Process-group escape and LaunchServices-owned lifetimes need explicit integration; earlier macOS runtime behavior is unverified.
- Save rules are authoritative outside disposable prefixes; recreation imports known physical saves before archiving. Eleven checks include a real SIGKILL after archive/before new metadata and a fresh empty-rule prepare. Copy-archive recovery has its own durable intent and fixed archive, with ten checks and six real SIGKILL boundaries. Both retain data and fail conservatively on corrupt state; real user-game and power-loss validation remain open.
- Runtime portability work retains component bytes/receipts and generates separate relative entrypoints/ICDs. Real Windows relocation under denial of original roots passes; the integrated project now selects the source-built ARM64 closure with 19 native GPU/property probes plus five sandbox controls and no Homebrew runtime dependency. Current Wine/Vulkan headers require macOS 27, separately from the frontend target 14. This does not approve a complete runtime distribution; installer staging/publication and final-location tests are separate below.
- The gate for the selected 25 dependency libraries/modules now verifies a private transported packet with 32 unchanged evidence files while original logs are denied to the verifier; 11 tests include 8 negative cases. Source packets retain 22 exact renderer revisions and 21 newly acquired core inputs plus 2 prior DXMT archives, with fingerprints, recipe/license material and integrity checks. Historical binary/static-input correspondence and release notice selection remain separate unfinished work.

## Current controller and snapshot checkpoint

- Protocol2/E6 is frozen separately from E5 and inherited generation68, and is selected by the integrated project configuration. Its synthetic API matrix passes 40 cases (10 opted in and 30 opted out), 24 invalid-state/command checks, four independent session pairs, and five native-only opt-in cases. It requires exactly `M1L_XINPUT_CAPTURE=1`; absent/0/true/01 do not authorize capture. Physical controllers and non-XInput APIs remain unverified.
- Per-game/profile controller settings are implemented: automatic respects app-local input DLLs/explicit overrides; game-input opts out; advanced force-builtin appends Wine input selection without changing game files. Core 30 includes the new policy, capability/hash checks and profile isolation. All five actual production SessionManager cases now pass on Dati APFS: automatic builtin, explicit game input, private-DLL automatic bypass, forced builtin with unchanged private bytes, and real DXMT rendering/input override composition. Fresh Core/module/archive and production payload hashes are bound; keeper leases release after every case. Minimum observed free bytes: primary 4,153,282,560, work 55,035,367,424. The original zero-case disk-guard failure remains separately retained with unknown phase.
- Integrated normal/evaluation proposals preserve E6 open-engine bindings and the separate WineCX/Apple evaluation entries, with evaluation/consumer/proprietary distribution flags false. Eighteen private project-config fixtures pass, including interrupted activation/two-pointer rollback, exact before-image modes, stale proof and unknown-data rejection. Activation requires the exact hash of a reviewed readiness receipt and revalidates all gates under the transaction lease. All seven actual readiness gates now pass. Promotion is limited to the two project configuration files; user runtime overrides and prefixes are excluded. Evaluation/consumer/redistribution flags remain false, and WineCX does not receive E6 input capture.
- Snapshot v2 now captures Core/App/overlay/keeper source membership, Package.swift, native-support recipes, the top-level app-build recipe and validator itself. Fourteen lightweight source/recipe/artifact tamper fixtures pass. Legacy v1/debug metadata is rejected without invoking a compiler or changing the published app. A fresh current-source normal build, strict v2 assembly, signature verification and 15 relocated-package checks now pass. Source work remains WIP; the app/runtime is not declared finished.
- The user selected Dati APFS for further work. The owned external workspace contains SwiftPM/module caches, temporary build/test data and the hash-verified core source packet. The checkout retains stable links to the relocated cache/source packet; runtime and user configuration locations were not changed. Production E2E uses a real cross-volume prefix copy, separate free-space guards and retained external telemetry. No runtime activation or completion is implied by this storage change.

- Actual AppKit GUI checks now cover controller save/reopen, profile B retaining automatic after profile A selects game input, native runtime folder selection/reopening/previous-location restore, and the idle maintenance dialog. Evidence uses isolated Dati APFS data. The historical 13/15 migration/recovery dialog checks used the earlier native-alert implementation. Current internal-dialog interaction is separately recorded below; real migrations, physical controllers, store accounts and games remain distinct gates.

- Integrated project activation is now committed after the seven actual gates and 18 transaction fixtures: E6 production input bindings and the independently source-built ARM64 Vulkan renderer are selected. Both prior project configurations and modes are retained for rollback. User overrides and prefixes were not modified; evaluation/consumer/proprietary redistribution flags remain false. This does not complete the runtime installer or whole-application distribution gates.

## Current local installer and internal UI checkpoint

- Installer fixtures pass 40 checks with eight actual SIGKILL/resume boundaries; source/layout fixtures pass nine static checks. They use tiny synthetic inputs, never execute Wine or a GPU, and cannot authorize a real runtime publication. CI runs only these fixture suites on macOS 15 and makes no GPU claim.
- Actual staged runtime proof passes 18 checks: source-root/Homebrew/raw-object access is denied, loaded native images are audited, real Windows 32/64 save separation and Vulkan/DXMT/native graphics work, and all five production controller-policy cases pass. The stage's fingerprints remain unchanged. Local transaction `f791932f-1c82-4f03-bbf4-05a197d77b91` is published diagnostically with fingerprint `ab6715945f4fb823c65961ea6e7a647f8a49bc65536d098e72fb5f8e79cad5c5`. The normal user's runtime-location pointer was not changed: only an isolated GUI location was tested and restored. **The real rerun after the final publication move remains pending.** Staged proof is not reported as final-location verification, a clean-machine result or distribution approval.
- Separate source-built MoltenVK 1.4.2 is unactivated: seven actual native/Wine Vulkan checks and six integrity/corruption controls pass. Its source receipts do not approve the inherited Wine/DXMT/static/data payload or change the currently installed transaction's pinned component bytes.
- Current UI uses internal, same-window dialogs rather than NSAlert/NSPanel/open-panel flows across six dialog groups. Actual Cua checks cover search Return/Escape, profile creation/error, game options, runtime folder choice (invalid/valid/restore), stable-ID native import/reimport, canvas hover, and visibly corrected icon proportions/colors. These checks use isolated data and no store account. That earlier UI checkpoint did not verify store login. The later live-status UI and isolated Steam QR/login attempt are scoped separately below; complete game authorization is still unverified. A final full primary/hover pass is still being checked separately.
- The latest real frontend lifecycle probe passes 13 checks, including active and queued internal dialogs being detached when a game starts, graphics released, background errors deferred without focus theft, and the launcher restored on return. Canvas probes perform a real Metal BGRA round-trip, preserve five icon aspect ratios and cover 12 distinct own-window hit targets; their programmatic event proof remains separate from manual Cua hover and does not establish physical-controller behavior or direct display.
- Generated app backups now use a non-launchable `.ready-backup` extension and private inventory; scoped LaunchServices registration targets only the current app. Twelve existing generated backups were renamed byte-identically without deletion. This prevents an old launchable backup from being reopened under the same bundle identifier; it does not remove user applications or data.
- The user is unlocked and current GUI scopes above are verified. Remaining gates include final-move installer retesting, real store account/entitlement/download/game validation, physical input APIs, direct display, native per-profile save/account behavior, real legacy-user migration, and complete binary/source/license distribution closure. The goal remains incomplete.


## Steam headless research checkpoint

The sanitized [Steam checkpoint](../Validation/steam-headless-checkpoint.json)
binds private reports and measured source/artifact hashes without account
identifiers, credentials, raw tickets, client binaries or disassembly.

- Windows PE32 and PE64 demonstrate offline client IPC. The current candidate's
  synthetic authentication cases terminate with the expected negative result;
  no real Windows account authentication or game launch is verified. Historical
  aggregate/teardown failures remain false in their original reports.
- The native ARM64 offline host/peer run exits normally, processes 12/3 callbacks,
  releases both users/pipes and passes seven sandbox controls. Separate composed
  filesystem/IPC fixtures pass eight groups on ARM64/x86_64 and both load orders,
  including kernel-validated namespace SHM and descriptor reuse rejection. This
  is not native account authentication or complete game/profile isolation.
- The latest real native ARM64 run now passes genuine account authentication
  and the owned-title subscription check after a successful SteamKit preflight.
  It releases the genuine client user/pipe and exits zero; full Steam client
  process counts are zero before and after. The same user-approved authorization
  context was reused without another QR scan. This verifies the isolated native
  authentication/subscription path, not actual game IPC/launch or a persistent
  production backend. Real Windows authentication remains unverified.
- The successful helper closure retains the separately licensed LGPL SteamKit
  source patch for asynchronous WebSocket cleanup. Its 21 protocol/build and
  47 offline decision checks are bound independently from the real native run.
  The previously successful preflight/native-failure attempt remains recorded:
  native login dispatched, 38 online callbacks, a captured type-102/eight-byte
  callback, account/subscription false and exit 5. No report was rewritten.
- The earlier real attempt that passed QR/login but failed after the ownership
  callback (`steam_error`, ownership stage, result OK) remains preserved history;
  it handed no authorized context to a worker. The new positive preflight does
  not rewrite that failure or promote its report into game compatibility.
- The current signed live-status frontend snapshot passes 28 synthetic status,
  rotation, viewport and cancellation checks. Its fixtures never showed a test
  window. The earlier actual live run used the preserved preceding snapshot;
  the latest binary is not retroactively assigned that run. SessionManager's
  21 checks include the authenticated-host requirement before Steam session
  mutation. Final app assembly from the current snapshot awaits documentation
  freeze; no unchanged UI suite was rerun for this checkpoint.

The native offline report's measured probe/driver sources precede later auth
research edits. Their original hashes and the differences from current sources
are retained explicitly. The latest successful authentication run is likewise limited to its recorded
source/driver hashes; later cached-mode, network or other research behavior is
not promoted by it. No historical failure is rewritten as a success; authentication is claimed only
for the new measured native run. Actual game validation remains pending. Genuine Valve assets remain external proprietary
inputs, and GameNative's withheld host/bootstrap is not included in Ready's
free implementation. Distribution and actual owned-game validation remain open.
