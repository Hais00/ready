# M1 Launcher — original scope and verification gates

The goal remains the complete native macOS launcher requested by the user. No gate is satisfied merely by a mocked screen or a green unit test.

| Requirement | Required evidence | Current state |
| --- | --- | --- |
| Latest Wine development/beta sources and usable runtime | pinned source hash; wine --version; Windows synthetic executables | Wine 11.20 built from source; real PE64 and PE32 Win32/DXMT probes pass; commercial games remain unverified |
| Latest Apple GPTK beta | authenticated download, version, working DX11/DX12 probes | 4.0 beta 3 downloaded; DLL/framework loading investigated; genuine DX12 device/rendering not verified |
| Latest Vulkan-to-Metal renderer | Mesa/KosmicKrisp source; Vulkan runtime/device probe; presentation test | Mesa/KosmicKrisp 26.3.0-rc2 and MoltenVK 1.4.2 installed/versioned; ARM64/x64 buffer and Wine presentation probes pass |
| Reference UX | native app screenshot compared with attachment; controller focus navigation | native Metal UI rendered and visually checked; physical-controller validation open |
| Minimal graphics memory during play | frontend texture/drawable teardown; measured before/during/after | canvas texture 15,078,400 → 0 bytes; process Metal allocation about 47 MB → 0.74 MB in local probe |
| Fullscreen presentation | opaque CAMetalLayer; Metal HUD direct mode evidence for each engine | fullscreen, focus and opacity verified; HUD reports Composited in both baseline and overlay; direct mode unverified |
| Steam/Epic/GOG/Amazon login, library, download, launch | real adapters and authorized account flows; synthetic transport tests; real authorized smoke tests | real adapters/source-built helpers and protocol tests; authorized account/entitlement/game smoke tests pending |
| Native Apple Silicon vs Windows install choice | per-build availability and Mach-O architecture verification; unknown differs from unsupported | implemented manifest-based resolution and Mach-O/PE inspection; real store downloads pending |
| Multiple launcher users | isolated account tokens, registry/AppData/saves and per-prefix session coordination | profile-scoped Keychain and game/profile data paths implemented; actual account flows pending |
| Prefix per Windows game/profile (supersedes original single-prefix requirement) | independent registry/AppData/DLL state; per-prefix leases; central versioned engines; persistent Documents/Saved Games; non-destructive legacy migration | domain checks and real Wine Windows registry/folder/recreation probes pass; real game and legacy-data validation pending |
| In-process overlay without a second compositor surface | injected Metal render pass; real attach; resume/quit; memory and direct mode measurements | six native GPU paths plus real Wine Vulkan path pass; hidden overlay texture 0 bytes; direct display unverified |
| Controller + keyboard/mouse | synthetic input plus real device evidence when available | keyboard/mouse synthetic probes pass; physical controller and game input suppression open |

Prefix/profile isolation concerns launcher profiles inside one macOS login. Native macOS apps do not require Wine. Different macOS OS accounts and adversarial sandboxing require a separate permissions design. No unrequested changes to system security, other projects, or user files.

## Architecture correction, 2026-10-27

The user's later instruction supersedes only the original single-prefix requirement. All other original requirements remain. Central Wine/renderers are shared and versioned; Windows prefixes are keyed by game AND profile; native macOS games do not create a Wine prefix. Documents and Saved Games point to persistent profile directories; AppData points to persistent game/profile directories. Automatic rendering uses available verified paths and exact game/runtime compatibility rules, advanced overrides, and fallback between launches. Never hot-swap a running prefix's DLLs. Preserve legacy data and a rollback source until actual game validation. Prefix separation is NOT claimed to save VRAM.

Required new tests: dependencies A vs B; profile account/registry/save isolation; Documents links; available/verified renderer selection; save survival on recreation; independent session termination. Synthetic success alone does not close these integration gates.
