# DXMT development integration

The current official DXMT development build provides a working **Direct3D 11 shader/raster path on our Wine 11.20**. This is an additional open-source engine alongside the ongoing DXVK/Kosmickrisp work; it does not replace the other engines or enable Direct3D 12.

## Version and provenance

Checked 2026-10-27/28 against the [official repository](https://github.com/3Shain/dxmt), GitHub release API, and its successful [CI run 40488590746](https://github.com/3Shain/dxmt/actions/runs/40488590746). Latest published release is v0.80, dated 2026-04-23; the newer official development build was selected because Ready requests the latest available development/beta components.

| Item | Pin |
|---|---|
| DXMT source commit | `3b252590cb0290e36fca6f088b5255b871d2d95a` |
| Successful official CI | `40488590746`, 2026-10-27 |
| Combined official artifact | `12726786394`, `dxmt-3b252590cb0290e36fca6f088b5255b871d2d95a` |
| CI ZIP SHA256 | `44a13648294d432898db1198788f0da2567cf25b194666ff6b7bd919926c2f73` |
| Source archive SHA256 | `c098a89937f6faec94ff6c1f54b1b3b7f330ca9b37c78d1c50d749f4a10971e1` |
| Inner payload archive SHA256 | `c9e111225685da2dd7e7ffb55ea4a0dba66a6267835693cdf24d7406223b2fbd` |
| Runtime tested locally | source-built Wine 11.20, x86_64 host under Rosetta, Apple M1 |

`DXMTIntegration/dxmt.lock.json` records these pins, every selected DLL/unix-module checksum, submodule revisions, and toolchain provenance. The ZIP hash matches the digest returned by GitHub's artifact API. A digest proves exact artifact identity; it does not turn an upstream CI binary into a local source build.

`DXMTIntegration/Source` contains the unchanged pinned DXMT source and its unchanged DirectX-header submodule. We used upstream's official compiled artifact for this experiment; we did not build LLVM/DXMT locally. No DXMT source was modified. Its current `AGENTS.md` says: “AI must not be used to generate code for contributions to this project.” Ready's separate staging scripts, probes, and Wine adapter are our project code; no upstream DXMT contribution is being made.

## Actual checks passed

1. Existing Ready `runtime_windows_probe.exe dx11`: real hardware D3D11 device, feature level **11_0**, HRESULT 0, a 4,096-byte device-buffer to staging-buffer transfer, and all 1,024 words verified after Map. Exit 0. Evidence: `Evidence/dxmt-device-result.json`, `.log`, `.stdout.txt`.
2. Original `DXMTIntegration/dxmt_shader_probe.c`: HLSL vertex and pixel shader model 5.0 compiled through Wine's open `d3dcompiler_47`, DXMT shader creation/translation, draw into a 64x64 RGBA render target, texture copy to staging, and mapped CPU pixel checks. **1,152 pixels** have the expected `(51,102,153,255)` color, **2,944** are black background, the center and corner match, HRESULT 0, feature level 11_0, exit 0. Evidence: `Evidence/dxmt-shader-result.json`, `.log`, `.stdout.txt`.
3. The shader run enabled Wine DLL-load tracing and dyld tracing. It loaded the selected `d3d11.dll`, `DXGI.DLL`, and `winemetal.dll` as Wine builtins and `winemetal.so` from the isolated experiment's Wine directory. Core payload files were checked against the locked official artifact before running.

The buffer copy path reaches DXMT's `CopyBuffer` readback blit and the native `[MTLBlitCommandEncoder copyFromBuffer:...]` implementation. The second test additionally proves shader conversion and rasterization, beyond successful device creation or memory allocation.

These results do not establish full game compatibility, every D3D11 feature, controller behavior, presentation/direct display, or overlay integration. The first new-prefix attempt timed out during Wine initialization at 100 seconds; once that isolated prefix initialized, the Win32 check and both D3D11 checks passed. The measured shader run took about 3.9 seconds including process startup.

## Isolation and installation contract

All experimental mutations stay under `Runtime/DXMTExperiment/`. `Runtime/Sets/`, the active runtime manifest, `Runtime/wine-11.20`, and users' game/profile prefixes are not changed.

`Scripts/dxmt_experiment.py prepare` APFS-clones an existing Wine installation to a **new** experiment directory and installs only these official DXMT core payloads:

- `x86_64-unix/winemetal.so`
- `x86_64-windows/{winemetal,d3d11,dxgi,d3d10core}.dll`
- Equivalent i386 PE DLLs when the Wine build includes i386 support. Their presence is not a 32-bit compatibility test.

The official combined package also contains ARM64EC payloads and optional NVIDIA DLLs. We do not install those in this x86_64 experiment and do not claim they were tested. NVIDIA SDK source is not fetched.

This artifact uses **Wine builtin DLLs**. Set `WINEDLLOVERRIDES=d3d11,dxgi,d3d10core,winemetal=b` and supply the unix module in the selected Wine runtime. Treating these DLLs as `native` can reject their Wine builtin markers. Wine initializes/copies the matching builtin PE payload into the scratch prefix; the helper verifies installed core payload hashes before tests. The [upstream installation guide](https://github.com/3Shain/dxmt/wiki/DXMT-Installation-Guide-for-Geeks) describes this distinction.

For the launcher, DXMT needs a distinct central runtime snapshot, including its unix module and builtin PE DLLs, plus explicit builtin overrides. It cannot be integrated by the generic “copy native DXVK DLLs into any prefix” path. A user launch must still choose a per-game/per-profile prefix; shared game files remain outside it. Before changing a prefix's engine, stop its Wine session and replace any old engine-specific D3D DLLs with the matching selected runtime payload. Register the engine only for API capabilities actually tested; these probes verify D3D11, not D3D10 or D3D12.

## Wine window ABI adapter

The device and offscreen raster tests do not create a swapchain/window. Presentation needs a separate compatibility adapter in Wine 11.20.

The unchanged DXMT unix module resolves either an exported `macdrv_functions` table or these private Wine driver symbols:

- `get_win_data`, `release_win_data`
- `macdrv_view_create_metal_view`, `macdrv_view_get_metal_layer`, `macdrv_view_release_metal_view`

In `Source/src/winemetal/unix/winemetal_unix.c`, DXMT's historical `macdrv_win_data` has four pointers: hwnd, cocoa window, cocoa view, client cocoa view. It reads the last field at byte offset 24. Wine 11.20's real structure has hwnd, cocoa window, client view, then window rectangles; its client view is at offset 16. Exporting the original `get_win_data()` blindly would give DXMT an incorrect object pointer.

The appropriate integration is a separately licensed Wine adapter that exports the expected table with a compatibility wrapper, preserves Wine's locking/lifetime, and returns the correct current client view in the legacy layout. Its source/patch and build recipe must remain public under Wine's applicable LGPL terms. Do not rewrite DXMT's source or present a simple export change as sufficient. The runtime agent owns that isolated adapter and its presentation proof; this document's raster evidence predates its installation.

## Reproduce with existing local components

```sh
# Recover exact official CI artifact; token stays in memory, only sent to api.github.com.
# Authentication is removed on every redirect to GitHub's signed artifact storage.
python3 Scripts/dxmt_experiment.py fetch

# A fresh output path is mandatory. APFS clone fails rather than silently copying gigabytes.
python3 Scripts/dxmt_experiment.py prepare --wine-root Runtime/wine-11.20 --output Runtime/DXMTExperiment/wine-new

# Always an isolated experiment prefix, never a user prefix or active Runtime/Sets installation.
python3 Scripts/dxmt_experiment.py probe --wine-root Runtime/DXMTExperiment/wine-new --prefix Runtime/DXMTExperiment/prefix-new
python3 Scripts/dxmt_experiment.py shader-probe --wine-root Runtime/DXMTExperiment/wine-new --prefix Runtime/DXMTExperiment/prefix-new --trace-modules
```

The shader probe compiles with the existing open LLVM Windows-target compiler, Wine public headers, and lld; it links only the small existing Ready kernel32 import library. It does not require Microsoft/Apple game-porting SDK headers. Runtime dependencies include the normal macOS Metal frameworks and Wine's open dependencies. Compiler/probe intermediates stay in the experiment directory.

The `fetch` command pins the exact artifact. Official CI retention may eventually remove it; in that case build the pinned source rather than silently selecting a different binary. No account login, Steam token, or store credential is used by these probes.

## Source build and licenses

The selected development snapshot is **LGPL-2.1-or-later**, with its complete original `LICENSE`, `COPYING.LIB`, older MIT notice, and file-specific notices retained. v0.80's release license was MIT; that does not describe the newer main snapshot. DXVK-derived utility notices and MinGW/Wine header licenses remain intact. Our separate integration and shader probe are GPL-3.0-only. See `DXMTIntegration/NOTICE`.

Source build requirements and the authoritative build recipe are in unchanged `Source/docs/DEVELOPMENT.md` and `.github/workflows/ci.yml`. The CI x86_64 package uses Wine tooling v8.16-3shain and LLVM **15.0.7**. Our runtime execution tests use Wine 11.20; do not describe the official CI artifact as having been compiled against Wine 11.20.

To build unmodified DXMT locally, supply an x86_64 LLVM 15.0.7 development installation and a suitable Wine build/toolchain, then invoke Meson with the upstream `build-win64.txt` cross file, `-Dnative_llvm_path=...`, `-Dwine_build_path=...`, `-Dwine_builtin_dll=true`, and `-Denable_nvapi=false -Denable_nvngx=false -Denable_d3d12=false`. Put the build directory under the experiment tree. The checked source lock includes the exact DirectX-header gitlink. The optional NVAPI gitlink is recorded, but unused in this configuration.

This repository publishes the source/integration pins and preserves upstream licenses. Installed CI binaries stay in ignored local `Runtime/`, not in this source commit. A future binary distribution must carry the relevant notices, corresponding library source and build configuration (including linked LLVM and Wine dependencies), and the ability to replace/relink LGPL components under their licenses. No proprietary GPTK/D3DMetal component is needed for the DXMT path tested here.
