<!-- SPDX-License-Identifier: GPL-3.0-only -->
# PE32 shader rasterization through DXMT

The missing PE32 shader/readback check now passes on the existing open DXMT68
provider and Wine 11.20. This extends the earlier PE32 device/buffer/presentation
proof with actual shader compilation, triangle rasterization and texture readback.
It does not change runtime configuration, capability declarations, source-provider
contents, or any game's compatibility status.

`Scripts/runtime_dxmt_shader32_probe.c` includes the exact original Ready shader
probe body from `DXMTIntegration/dxmt_shader_probe.c`. Its entry point adds a
runtime pointer-width observation and a compile-time assertion that pointers are
32-bit. Wine's public `pD3DCompile`, WINAPI and COM interface declarations retain
the i386 stdcall ABI. The test uses `D3D_DRIVER_TYPE_HARDWARE` and requests only
feature level 11_0; it neither lowers that level nor modifies reported features.

| Check | Actual PE32 result |
| --- | --- |
| Executable | i386 machine `0x14c`, PE32 optional-header magic `0x10b` |
| Process ABI observation | `pointerBits: 32` |
| HLSL compilation | `vs_5_0` and `ps_5_0` |
| Device | HRESULT 0, feature level `0xb000` (11_0) |
| Raster target | 64×64, RGBA8 UNORM |
| Triangle color | 1,152 pixels with bytes `(51,102,153,255)` |
| Clear background | 2,944 pixels with bytes `(0,0,0,255)` |
| Spatial checks | Center colored, corner black; all 4,096 pixels accounted for |
| Provenance | Wine PE32 builtin modules and the selected provider's native `winemetal.so` observed |

The color/background counts match the original successful PE64 shader test.
The 18.697-second observation includes process startup and Wine-wrapper lifetime;
it is not a shader performance benchmark. The existing `runtime-wow64-proof.json`
is a historical three-step report and retains its original shader flag. The new
proof is `Evidence/runtime-wow64-shader-proof.json`, where
`shaderRasterization32Verified` is true.

## Reproduction

```sh
python3 Scripts/runtime_wow64_shader_smoke.py --compile-only
python3 Scripts/runtime_wow64_shader_smoke.py
```

The script compiles only the freestanding original test. The build receipt lists
exact compiler/import-library/linker commands, source hashes, PE-header checks
and executable hash. No Wine, DXMT, vendor source or native renderer is rebuilt.
The test is a dedicated companion to `runtime_wow64_smoke.py`; it does not repeat
that suite's device and presentation cases.

A unique synthetic COW prefix is made from the earlier owned Wine test baseline
when available. Pure Wine i386 builtins are projected before `wineboot -u`;
selected DXMT PE32 and PE64 DLLs are then independently projected using COW copies.
The script checks that files are not hard-linked back to central engines and
verifies every selected payload against the existing DXMT lock. Only that exact
prefix's wineserver is stopped. The fixture is removed after confirmed shutdown;
`--keep` retains it for diagnosis. The script preserves a 512 MiB free-space
reserve at allocation/bootstrap checkpoints.

Wine's module trace reports logical `C:\windows\system32` paths inside this
WoW64 process. This does not indicate a PE64 shader process: the executable and
runtime pointer-width checks are PE32, and the selected physical payload was
copied into the prefix's `syswow64` with the i386 hashes. The trace identifies
`d3dcompiler_47.dll`, `d3d11.dll`, `DXGI.DLL` and `winemetal.dll` as builtins, while
DYLD records the selected provider's x86_64 Unix DXMT bridge. No proprietary
D3DMetal framework is observed.

The final report binds logs, original probe source, build recipe, executable,
selected renderer payload, native adapter and provider-generation identities.
Tracked central engine files and both default/evaluation configuration hashes
match before/after. The prefix is stopped and removed. No Metal presentation,
overlay, direct-display, arbitrary game, other rendering engine or older macOS
support is inferred from this offscreen shader test. It also does not approve
the runtime's source-to-binary correspondence or distribution licenses.
