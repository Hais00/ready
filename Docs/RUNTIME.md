# Runtime builds and evidence

Runtime binaries are local development inputs in ignored `Runtime/`. They are not
part of the source release. Central runtimes are versioned; every game/profile
supplies its own `WINEPREFIX`. Native macOS games have no Wine prefix.

## Versions selected on 2026-10-28

| Component | Version | Source / provenance |
| --- | --- | --- |
| Wine | 11.20 development | `Vendor/wine`; public WineHQ source recorded in `sources.lock.json` |
| Optional WineCX provider | 11.19 development, `9f3f6447844add700bc0dde650e4f398fd5f69ab` | public LGPL compatibility source; `Scripts/runtime_winecx.lock.json` |
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
| VKD3D-Proton / KosmicKrisp | Device gate fails | DXVK DXGI filter fails; direct builtin-DXGI diagnostic additionally faults in Wine Vulkan property query |
| Apple D3DMetal 4.0b3 / upstream Wine 11.20 | Framework and Unix bridge load | Native GS/TLS incompatibility; disabled |
| Apple D3DMetal 4.0b3 / WineCX 11.19 | D3D11 FL11_0 buffer readback; D3D12 GPU copies, clear, SM5 shader draw/readback and 600 shader swapchain frames | Local development/evaluation only, PE64; product selection disabled |

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

The current base is `ready-runtime-b4a90f0d97ce75cdd949`. The selected DXMT
provider and combined identity are recorded in `Runtime/runtime.json` and
`Evidence/runtime-dxmt-frozen.json`. IDs include build/patch manifests, not just
the upstream Wine version string. The freeze gate compares every unchanged Wine
core file with the tested base; unrelated core binaries cannot inherit stale
successful DXMT probes.

## 32-bit Windows applications

Actual i686 PE executables also pass Win32 calls, DXMT D3D11 feature level 11_0
with GPU buffer readback, and a 600-frame D3D11 swapchain on this M1. These tests
use the x86_64 Wine host and its WoW64 modules under Rosetta. No 32-bit macOS
executable or 32-bit Unix driver is required. SM5 shader rasterization was tested
separately in PE64; a PE32 shader-raster claim is not made.

An empty `syswow64` directory initially caused `kernel32.dll` c0000135 even though
the central Wine already contained its i386 builtin DLLs. Running `wineboot -u`
alone, including with `WINEARCH=wow64`, did not repair it. A COW projection of the
**pure base Wine** i386 builtin files into a new prefix's `windows/syswow64`
before Wineboot resolves the bootstrap. The selected engine's managed PE32 DLLs
are then projected separately, with pure Wine originals retained for restoration
when switching engines. Nothing is hard-linked or symlinked back to a mutable
central DLL. Normal PE32 launch also passes without forcing WINEARCH.

Configuration uses `builtin32Directory` for the pure Wine bootstrap and
`engineDLLs32` for each selected renderer's versioned payload. The transitional
`engineBuiltin32Dirs` is an alias for the latter, not the bootstrap source.
Pinned DXVK and VKD3D PE32 payloads are present in the immutable provider, but
their presence does not change their failed GPU capability gates.

`python3 Scripts/runtime_wow64_smoke.py` rebuilds freestanding PE32 probes,
creates a fresh synthetic prefix, bootstraps pure Wine, applies the selected DXMT
payload, verifies all three real API tests, and removes the fixture. `--keep`
retains only that synthetic run for diagnosis. The report is
`Evidence/runtime-wow64-proof.json`; module traces and exact payload/executable
hashes accompany it. No individual 32-bit game's compatibility is guaranteed.

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
and times out with upstream Wine 11.20. The public Apple Wine tap and LGPL
WineCX sources establish the required compatibility ABI.
`Evidence/runtime-apple-projection-complete.json` and `runtime-apple-seh.log`
retain the real failed result. The launcher keeps this optional engine disabled.

An isolated diagnostic Wine module now establishes the native failure more
precisely. Before Wine's signal handler restores native TLS, GS slot 0 is zero
and GS slot 0x30 equals the Windows TEB. The native pthread TLS base remains
valid in Wine's thread data. `dladdr` inside the same faulting process identifies
`pthread_setname_np+51` (read from address 0) and `pthread_setspecific+74` (write
to 0x8e8). Resolving symbols inside the same process avoids cross-process ASLR
assumptions. The stack unwinder stops at the signal trampoline, so a full caller
chain is not claimed. This is a native thread-context ABI failure, not a missing
Vulkan feature or proof that M1 cannot execute D3D12.

`Scripts/runtime_trace_native_fault.py` compiles only a copied LGPL Wine signal
source with observation/logging hooks. `runtime_apple_trace.py --observer-ntdll
Runtime/wine-native-fault-observer/ntdll.so --api dx12` runs it in a complete,
separate synthetic Apple projection. No Apple instructions are decoded or
modified, no security setting changes, and no active runtime is replaced.
`Evidence/runtime-apple-gs-diagnosis.json` records the actual GS values, public
symbol resolutions, observer hash, and limits of this diagnostic.

The public [WineCX compatibility source](https://github.com/dappermint/winecx/tree/9f3f6447844add700bc0dde650e4f398fd5f69ab)
retains the compatible native-GS model and includes the LGPL D3DMetal driver
hooks, the 24-slot `macdrv_functions` window adapter, and non-native code-region
handling. This unmodified source was successfully built and reports `wine-11.19`.
The source archive and eight bridge/ABI file license grants are hash-pinned in
`Scripts/runtime_winecx.lock.json`; copyrights and scope are recorded in
`Scripts/runtime_winecx_NOTICE.txt`. The audited source archive contains no
D3DMetal framework, libd3dshared, native dylib/metallib payload, or copied
Metal.h/AppKit.h system SDK header. The pure source build contains no Apple
evaluation payload. Wine 11.20 remains the default runtime.

For a prepared optional provider, the **pure** WineCX tree must be frozen before
projecting Apple's PE/Unix libraries and framework into a separate local engine.
Its `engineBootstrap32Dirs` entry must reference pure WineCX i386 builtins. Using
the default Wine 11.20 bootstrap for a different Wine host would mix core ABIs.
The selected host/pure bootstrap participates in prefix initialization identity.

The freestanding `Scripts/runtime_d3d12_probe.c` exercises queue copies through
a default GPU buffer, fence completion, render-target clear/readback, HLSL SM5
vertex/pixel compilation, root signature and graphics pipeline creation, and a
draw whose 256 output pixels must all match. All gates passed with source-built
WineCX 11.19 and local Apple 4.0b3: actual GPU buffer readback, clear/readback,
and 256 green pixels from the compiled shader draw. The trace loads the precise
projected Apple DLLs, libd3dshared, D3DMetal 4.0b3, and shader converter. Wine's
`d3dcompiler_47` also imports WineD3D for compilation helpers; this auxiliary
module load is separate from the Apple D3D12 renderer. Prefix/engine Apple DLL
hashes match. Evidence: `Evidence/runtime-winecx-probes.json` and module logs.

`Scripts/runtime_d3d12_present.c` additionally creates a real HWND/DXGI swapchain,
compiles the SM5 shaders and PSO, draws a full-screen triangle, waits on a GPU
fence, and presents each frame. The frozen evaluation Wine wrapper passed 600
submitted shader frames and 600 S_OK presents, with zero occluded presents,
requesting `D3DM_MTL4=1`. Its deliberate 16 ms sleep is test pacing, not a frame
rate measurement. `Evidence/runtime-winecx-dx12-present.json` records the result.
This does not establish direct display or any individual game's compatibility.

The injected overlay also passed inside this Apple D3D12 process: the observer
recorded 118 Metal 4 overlay entries, zero Metal 3 entries, 118 completed GPU
submissions and zero failures. Showing the overlay used 835584 texture bytes;
hiding it returned to zero bytes with the counter stable at the later hidden
frame. `Evidence/overlay-apple-d3d12.json` records this actual process/Metal 4
path. Native tests separately verify pixels for all six overlay paths. No
end-to-end pixel-difference result inside Apple's drawable or direct display
result is claimed.

The local evaluation provider is immutable and separate from the pure WineCX
provider. `Scripts/runtime_freeze_apple.py` writes only
`Runtime/evaluation-runtime.json`, verifies the default configuration remains
unchanged, and preserves the original Apple notices. The fragment records
technical D3D11/D3D12 proof while setting `evaluationOnlyEngines=["d3dMetal"]`,
`evaluationModeEnabled=false`, `enabledForConsumerPlay=false`, and the exact
Apple license hash. Core blocks its selection until evaluation mode is explicitly
enabled in a **synthetic development test root**. The normal GUI/default runtime
does not enable or bundle the Apple provider. A GPU pass does not make Apple's
software open source or extend its license scope.

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
`python3 Scripts/runtime_smoke.py --compile-only` builds the presentation probes.
The generated probes and runtime files remain local ignored build outputs.

For the separate local Apple development/evaluation experiment, with the complete
redist and its original license already obtained separately:

```sh
python3 Scripts/runtime_build_winecx.py fetch
python3 Scripts/runtime_build_winecx.py configure
python3 Scripts/runtime_build_winecx.py build --jobs 2
python3 Scripts/runtime_winecx_probe.py prepare --apple-root /path/to/local/redist-with-license
python3 Scripts/runtime_winecx_probe.py probe
python3 Scripts/runtime_freeze_apple.py
```

Preparation refuses to overwrite an existing experiment. A new proof uses its
own synthetic prefix; after exact-prefix server shutdown, that fixture can be
removed while keeping source, installed runtimes, immutable providers and reports.
No Apple download, license-dialog acceptance, public distribution, or consumer
selection is performed by this recipe.

Dependency headers currently come from locally fetched, uninstalled Homebrew
bottles (GnuTLS 3.8.13_2 and FreeType 2.15.0). Runtime dependency dylibs are
bootstrapped from an open-source Wine community bundle; before shipping any
binary bundle, corresponding-source/license inventory must be completed. The
default public fetch path does not download Apple's proprietary compatibility
bundle; that experiment requires an explicit `--include-apple-compat` argument.

Build caches may be removed after installed binaries and probes are verified.
Do not remove source trees, active per-user prefixes, or unrelated workspace data.
