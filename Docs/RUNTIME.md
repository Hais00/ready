# Runtime builds and evidence

Runtime binaries are local development inputs in ignored `Runtime/`. They are not
part of the source release. Central runtimes are versioned; every game/profile
supplies its own `WINEPREFIX`. Native macOS games have no Wine prefix.

## Versions selected on 2026-10-28

| Component | Version | Source / provenance |
| --- | --- | --- |
| Wine | 11.20 development | `Vendor/wine`; public WineHQ source recorded in `sources.lock.json` |
| KosmicKrisp | Mesa 26.3.0-rc2 | `Vendor/mesa`; built for arm64 and x86_64 |
| Vulkan Loader / headers | 1.4.366 | Khronos tagged source; `Scripts/runtime_fetch.py` |
| MoltenVK | 1.4.2 | source in `Vendor/moltenvk`; official universal binary for local tests |
| DXVK | 3.1.1 | source in `Vendor/dxvk`; official release DLLs for local tests |
| VKD3D-Proton | 3.0.1 | source in `Vendor/vkd3d-proton`; official release DLLs for local tests |
| DXMT | development `3b252590cb0290e36fca6f088b5255b871d2d95a` | official source and CI artifact pinned by `DXMTIntegration/dxmt.lock.json` |
| Apple evaluation runtime | 4.0 beta 3 | authenticated Apple download, local only |

The community artifact named `Game-Porting-Toolkit-3.0-3` contains a custom Wine
that reports **Wine 7.7 (Game Porting Toolkit 1.1)**. Its packaging version must
not be confused with a current Wine release. It was used only as a separate
Apple compatibility experiment and was never exposed as Wine 11.20. Its failed
baseline and scratch prefix were removed after retaining test evidence; the
current Apple 4.0b3 redist, licenses, and original DMGs remain available.

## Real GPU tests completed

`Scripts/runtime_vulkan_probe.c` loads the selected ICD through the Vulkan Loader,
creates a physical-device-backed queue, allocates/binds a real buffer, submits
`vkCmdFillBuffer`, waits for completion, maps memory, and checks every word of
the 4096-byte readback. It is not merely a library-load or version-string test.

The following all returned successful readback on this Apple M1:

- native arm64 KosmicKrisp 26.3.0-rc2, device Vulkan API 1.4.363;
- x86_64 KosmicKrisp 26.3.0-rc2 under Rosetta, API 1.4.363;
- x86_64 MoltenVK 1.4.2 under Rosetta, API 1.3.357 requested/reported by this probe.

Evidence: `Evidence/runtime-kosmic-arm64-probe.json`,
`Evidence/runtime-kosmic-x64-probe.json`, and
`Evidence/runtime-molten-x64-probe.json`, with corresponding logs.

The x86_64 KosmicKrisp binary links only system libraries/frameworks; it does not
attempt to load the installed arm64 Homebrew LLVM or SPIRV libraries. Build-time
shader compilation uses native arm64 Mesa helpers and embeds their results.

Subsequent **Windows PE programs running inside the source-built Wine 11.20**
passed Vulkan queue submission and buffer readback through both x86_64 ICDs.
`Scripts/runtime_vulkan_present.c` also presented 600 real window frames through
KosmicKrisp. The session helper and overlay passed the same Wine/Vulkan/Metal
path: hidden texture 0 bytes, visible texture 835584 bytes, then hidden 0 bytes.
These are synthetic tests, not game compatibility or direct display guarantees.

| Engine | Verified scope on this M1 | Remaining limitation |
| --- | --- | --- |
| WineD3D | D3D9 HAL clear and GPU readback | D3D11 device reaches only feature level 9_3; not a modern DX11 fallback |
| Vulkan / KosmicKrisp | Windows GPU buffer readback and 600 presented frames | No direct display guarantee |
| Vulkan / MoltenVK | Windows GPU buffer readback with actual driver 1.4.2 | Presentation and individual games require separate tests |
| DXMT / Metal | D3D11 feature level 11_0, SM5 vertex/pixel shader rasterization with target readback, 600 presented frames | Individual games and direct display remain unverified |
| DXVK / KosmicKrisp | Device gate fails | Upstream KosmicKrisp lacks required `fillModeNonSolid` |
| DXVK / MoltenVK | Instance gate repaired; device gate fails | Required `geometryShader` unsupported |
| VKD3D-Proton / KosmicKrisp | Device gate fails | DXVK DXGI adapter filtering fails; builtin DXGI experiment returns E_INVALIDARG |
| Apple D3DMetal 4.0b3 | Framework and Unix bridge load in isolated Wine projection | Initialization faults; D3D11/D3D12 remain disabled |

DXVK and VKD3D probes use native-only DLL overrides. Allowing builtin fallback
would otherwise misreport a WineD3D feature-level-9_3 device as a successful DXVK
test. No hardware feature flag is fabricated to bypass the device gates.

Evidence includes `runtime-engine-probes.json`, `runtime-windows-vulkan-present.json`,
`dxmt-shader-result.json`, `runtime-dxmt-present.json`, and
`runtime-dxmt-frozen-present.json` in local `Evidence/`.

## Wine build

The public-source build enables x86_64 and i386 Windows PE modules with an
x86_64 macOS host. Rosetta executes that host on M1. GnuTLS, FreeType, and Vulkan
are configured. Linux-only subsystems and optional GStreamer are disabled.

The Vulkan backend loads the **compile-time SONAME** of the native Vulkan
library. Upstream Wine does not read a `WINE_VULKAN_DRIVER` variable. The local
universal Vulkan Loader, plus standard `VK_DRIVER_FILES` / `VK_ICD_FILENAMES`,
selects the appropriate ICD. Never give x86_64 Wine an arm64-only ICD.

The wrapper generated by `Scripts/runtime_configure.py`:

- requires an explicit caller-owned per-game/per-profile `WINEPREFIX`;
- rebuilds its own dylib search path;
- restores the overlay dylib from `READY_OVERLAY_LIBRARY` after the protected
  shell has stripped incoming `DYLD_*` variables;
- waits for that prefix's wineserver after the initial Wine process exits;
- terminates only that prefix's server on session termination.

The build is release-oriented (`-O2 -g0`). Explicit SONAME configure cache values
avoid parsing Homebrew's bare dylib install IDs together with otool's version
annotation. GNU make is used because the protected system make strips incoming
DYLD variables needed by locally built Wine tools.

`Scripts/runtime_patch_wine.py` applies the public LGPL portability-enumeration
adapter to a copied Wine source file, leaving `Vendor/wine` unchanged. It enables
the advertised Vulkan portability extension and its instance flag on Apple; it
does not change advertised GPU capabilities.

`Scripts/runtime_patch_dxmt_wine.py` exports an explicit legacy window ABI table
for the pinned DXMT build. Wine 11.20's internal `macdrv_win_data` layout differs
from DXMT's expected four-pointer structure. The adapter returns a translated
structure, creates the Wine content view lazily, and manages its geometry and
lifetime. The LGPL patch and copied-source build recipe are public; only an
isolated provider's `winemac.so` is replaced. Native Metal view operations remain
Wine's own implementation.

`Scripts/runtime_freeze.py` and `runtime_freeze_dxmt.py` create content-addressed
APFS copy-on-write central runtimes. Existing installations are never overwritten.
The DXMT provider owns a separate Wine tree because its builtin PE/Unix libraries
must be in Wine's preferred builtin directory. Appending `WINEDLLPATH` alone does
not override that directory. Configuration selects both the engine's Wine wrapper
and its wineserver, records a combined runtime identity, and exposes only verified
API capabilities. Updating an engine takes effect on a subsequent launch.

The current base is `ready-runtime-b4a90f0d97ce75cdd949`; the verified DXMT provider
is `ready-dxmt-8b9fd99324a40e1c2f37`. IDs include build/patch manifests, not just
the upstream Wine version string.

## Apple integration boundary

Apple D3DMetal 4.0b3 is installed only into `Runtime/apple-evaluation-4.0b3`.
`Evidence/runtime-apple-local-install.json` records original file hashes and the
framework's 4.0b3 version. The proprietary files are excluded from Git and the
open distribution. The API wrapper code remains ours and open source.

Apple's PE DLLs have the Wine builtin marker and cannot be tested with a
native-only override. A separate Wine projection installs the PE shims, Unix
symlinks, complete external directory, and framework together. The final loader
trace confirms the actual local 4.0b3 D3DMetal, libd3dshared, metalirconverter and
dxccontainer loaded. Initialization then faults in the native thread boundary
and times out; no successful device or rendering is claimed. The public Apple
Wine tap and LGPL WineCX sources are used to investigate the compatibility ABI.
`Evidence/runtime-apple-projection-complete.json` and `runtime-apple-seh.log`
retain the real failed result. The launcher keeps this optional engine disabled.

## Actual prefix isolation and persistence

`Scripts/runtime_prefix_proof.py` builds a freestanding Windows API probe and
creates a fresh, marked synthetic fixture with three independent APFS-cloned
prefixes. It validates every folder target before permitting writes. Seven actual
Windows steps verify HKCU/AppData isolation, Documents/Saved Games sharing only
within a profile, and preservation after recreating one prefix. Folder APIs return
canonical Windows paths, e.g. `C:\users\jasonpolizzi\Documents`, while host
symlinks resolve to persistent per-profile or per-game data. The fixture is removed
after success unless `--keep` is requested. Existing/user prefixes are refused.
`Evidence/runtime-prefix-reproduction.json` records a complete successful rerun.

## Reproduction

Prerequisites on this build host: macOS 27 Command Line Tools, Rosetta, Homebrew
LLVM/lld 23.1.3, CMake, Ninja, Meson, Python with Mako/YAML/packaging, and libclc.
No SIP or system-security change is needed or performed.

```sh
python3 Scripts/fetch_sources.py
python3 Scripts/runtime_fetch.py
python3 Scripts/runtime_fetch.py --wine-deps-only
python3 Scripts/runtime_fetch.py --dependency-headers
python3 Scripts/runtime_build.py build-loader
python3 Scripts/runtime_build.py build-mesa
python3 Scripts/runtime_build.py configure-wine
python3 Scripts/runtime_build.py build-wine --jobs 4
python3 Scripts/runtime_patch_wine.py
python3 Scripts/runtime_smoke.py
python3 Scripts/runtime_configure.py --staging
python3 Scripts/runtime_freeze.py
```

See `Docs/DXMT.md` for the pinned DXMT preparation/device/shader steps. After
installing the window adapter in the isolated DXMT Wine projection and passing
the standalone presentation probe, run `python3 Scripts/runtime_freeze_dxmt.py`.
`python3 Scripts/runtime_smoke.py --compile-only` builds both presentation probes.
The generated probes and runtime files remain local ignored build outputs.

Dependency headers currently come from locally fetched, uninstalled Homebrew
bottles (GnuTLS 3.8.13_2 and FreeType 2.15.0). Runtime dependency dylibs are
bootstrapped from an open-source Wine community bundle; before shipping any
binary bundle, corresponding-source/license inventory must be completed. The
default public fetch path does not download Apple's proprietary compatibility
bundle; that experiment requires an explicit `--include-apple-compat` argument.

Build caches may be removed after installed binaries and probes are verified.
Do not remove source trees, active per-user prefixes, or unrelated workspace data.
