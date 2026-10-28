# Renderer and Wine asset provenance — runtime 68 audit

This is a draft release inventory, followed by a separate verified source acquisition, for `ready-source-runtime-68c00b7d3878699829eb`, inspected on 28 October 2026. **Its renderer/asset payload is not yet approved for binary redistribution.** The source-built **25 shared dependency** gate remains valid only for its documented subset; it does not cover these components. Apple payloads are entirely outside this audit. The complete Wine executable engine, DXMT provider, store helpers and whole application need their own release inventory. The original Vendor and runtime observations below remain unchanged; the source-only packet described later closes the missing source trees in a separate location.

The raw local report is `Evidence/runtime-renderer-distribution-audit.json`. It records the actual SHA256 of four native code files, sixteen PE files and 171 files under `wine/share`, their source/artifact leads, frozen/staging comparisons, Mach-O/PE metadata and blockers. All audited code and assets match the frozen manifest; all twenty code files also match their retained staging inputs. Those are identity checks, not complete source/build/license receipts. Every audited byte was rehashed unchanged at the end. No build, fetch, activation or runtime/default/vendor modification was performed.

## Code in the frozen set

| Component and actual payload | Retained evidence | Remaining release work |
| --- | --- | --- |
| Vulkan Loader 1.4.366, universal arm64/x86_64 dylib | Source archive URL/hash in `Runtime/vulkan-loader-1.4.366.artifact.json`; source and primary license text retained locally; `Scripts/runtime_build.py build-loader`, configure/build/install logs and CMake cache | Package source/notices with a receipt binding the actual binary to exact source/config/toolchain and any post-build processing. The source license describes most files as Apache-2.0 with per-file exceptions. |
| Mesa KosmicKrisp 26.3.0-rc2, separate x86_64 and arm64 ICDs | `Vendor/mesa.source.json` and `sources.lock.json`; upstream Mesa source, licenses and per-file identifiers; `build-mesa` recipe and configure/build/install logs | Package selected compiled-source notices and source/build receipts. Mesa's license page explicitly defers to individual files; Kosmic's inspected build/device files identify MIT. The arm64 external closure below must also be fixed. |
| MoltenVK 1.4.2, official universal dylib | Separate pinned source archive and official binary-artifact hashes; frozen bytes match the official extracted input; root Apache-2.0 text exists outside the set | `Vendor/moltenvk/ExternalRevisions` pins external projects, but the `External` source tree and its individual notices are absent. Retain that exact source/notice closure and official build provenance, or build an unchanged-source candidate separately. The root license does not identify every statically incorporated dependency. |
| DXVK 3.1.1, five PE64 and five PE32 DLLs | Official binary archive URL/hash, separately pinned project source, explicit upstream zlib/libpng license, release/cross-build scripts | The source archive has empty required git-submodule directories. Resolve and retain exact gitlinks recursively, their notices, and artifact build provenance or a new source-build receipt. Frozen component directories currently contain only DLLs. |
| VKD3D-Proton 3.0.1, two PE64 and two PE32 DLLs | Official binary archive URL/hash, separately pinned project source, `COPYING` explicitly states LGPL-2.1-or-later, upstream release scripts | Required DXIL-SPIRV and Khronos submodule source directories are empty. Complete corresponding source, notices and build material remain pending. Each VKD3D engine directory additionally contains a DXVK `dxgi.dll`: its source/notice mapping belongs to DXVK. |

`Vendor/dxvk/.gitmodules` declares DirectX headers, Vulkan/SPIR-V headers, libdisplay-info and DXBC-SPIRV. `Vendor/vkd3d-proton/.gitmodules` declares DXIL-SPIRV and Vulkan/SPIR-V headers. The audited directories contain zero retained files. A hash of a parent codeload archive and a tag name do not themselves provide those missing source trees or their exact gitlink revisions. This report does not conclude that the original upstream distributions lack sources/notices; it describes what this project's extracted and frozen trees retain.

The current frozen `vulkan`, `kosmic-*`, `molten`, `dxvk*`, `vkd3d*` and `wine` folders have **no files named LICENSE, COPYING, NOTICE or acknowledgements**. Source-tree licenses and the repository's family-level `THIRD_PARTY_NOTICES.md` remain separate. The next release payload needs exact notices beside a manifest mapping to the distributed bytes. For permissive components, byte-reproducible rebuilding is not asserted to be a license requirement; complete source provenance is also this project's release policy. Copyleft components retain their corresponding-source/build-material requirements.

## Actual native closure and OS requirement

Mach-O load-command inspection finds two strong external dependencies in the **ARM64** Kosmic ICD:

- `/opt/homebrew/opt/zstd/lib/libzstd.1.dylib`
- `/opt/homebrew/opt/spirv-tools/lib/libSPIRV-Tools.dylib`

Their actual local files are hashed in the raw report. They are outside both the immutable runtime and the source-approved dependency25 payload. A Homebrew filename/version or SONAME does not establish their exact source/build mapping. The x86_64 Kosmic dylib has only OS load dependencies; it still needs the compiled/static-source notice inventory above. The absolute staging paths reported as the two Kosmic **install IDs** are distinguished from actual dependency load commands.

Both Loader slices and both Kosmic ICDs declare `LC_BUILD_VERSION` minimum macOS **27.0.0**, SDK 27.0.0. The official MoltenVK slices declare minimum **12.0.0**, SDK 26.5.0. Therefore dependency25's macOS14+ build target cannot be advertised as the requirement of this complete runtime. A different deployment target requires a separate source build and actual validation; no flags or headers in this audit alter those existing binaries.

System Metal/Foundation/QuartzCore and other OS libraries are platform requirements, not redistributed free implementation code. This open launcher/source distribution runs on macOS; the audit does not label macOS itself open source.

## Wine fonts and other share assets

`wine/share` contains 171 regular files: 56 fonts, 77 NLS/ICU data files, ten WinMD files, `wine.inf` and 27 manual pages.

- All **six TTFs** are byte-identical to their `Vendor/wine/fonts` inputs. Their editable SFD counterparts are retained. The files are Wine's Marlett, Symbol, Tahoma regular/bold, Webdings and Wingdings implementations; their familiar display names do not establish proprietary Microsoft provenance. Actual PostScript names include `WineSymbol`, `WineTahoma`, `WineTahomaBold`, `WineWebdings` and `WineWingdings`.
- All **fifty FONs** map to explicit `sfnt2fon` rules in the retained Wine build Makefile, with source TTF and editable SFD hashes in the report. The generated FON outputs have not been rebuilt during this read-only audit; rule identification is distinct from a source-bound output receipt.
- All **77 NLS/ICU files**, including `icudtl.dat`, are byte-identical to corresponding files in the pinned Wine source tree. Wine's source archive includes these binary data inputs; that match alone is not an inventory of their preferred editable data/generator inputs.
- The ten WinMD outputs map to Wine IDL inputs and the `widl` rules in the retained Makefile. `wine.inf` maps to `loader/wine.inf.in` and configured inputs. The 27 manual pages are recorded but lack complete per-output generation receipts in this audit.

Wine's `LICENSE`, `COPYING.LIB` and `NOTICES.md` are available in the source tree but absent from the frozen Wine folder. The source project notice is LGPL-2.1-or-later; third-party exceptions/notices still apply. In particular, `NOTICES.md` contains the Bitstream Vera notice for the Tahoma derivation and the ICU/Unicode notice. The observed Tahoma PostScript names are renamed Wine names, but packaging must still retain the actual applicable notices. There is no blanket “all fonts are LGPL” approval here.

## Complete source packet acquired after the baseline audit

`Scripts/runtime_fetch_renderer_sources.py` now acquires a source-only packet from primary public GitHub endpoints. The committed `Scripts/runtime_fetch_renderer_sources.lock.json` retains the exact commit/tree objects, recursive gitlinks, artifact-release association, codeload archive hashes and notice indexes. Source archives avoid downloading Git history. Every tracked file is checked against its Git blob SHA; an archive omitted/substituted by Git export attributes would be repaired from the exact pinned raw blob and recorded. This acquisition needed no such corrections. Upstream code, dependency scripts and build programs were **not executed**.

| Root release | Verified commit | Source association with the retained binary archive |
| --- | --- | --- |
| DXVK `v3.1.1` | `b1a1c99ab52b687cf950d62c88bc2fa316b41663` | Annotated tag `1e0f92318d6ec7b7286e050d9e24fd01a2d09c92` resolves to this commit; official release asset digest matches retained archive SHA256 `40565b4a724aadc4433fa4e010b4b23916d9b1f1baeee64e17186db94f54e608` |
| VKD3D-Proton `v3.0.1` | `3b10bd7a7ec6a7347e616cf8bea59333afec2255` | Official release asset digest matches retained archive SHA256 `3cf2315522af5e43605ef6d3c41dad91387040bf97199934f3f7ab76caaa2f0c` |
| MoltenVK `v1.4.2` | `db66022459ffb663aa2b50f6b018bc2e124f5edf` | Official release asset digest matches retained archive SHA256 `f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e` |

The packet is `Runtime/CorrespondingSources/renderer-sources-4d0f21c8f6e04e228035`, fingerprint `dae5322f288de526db85704aa2cd76b0b1f104630acbe6dcba7d126d74fe7745`. It contains 22 exact repository revisions, 19,359 verified Git blob files and 57 indexed license/copyright/notice/author documents. Complete source files also retain their individual headers. `repositories/` holds exact root trees; `trees/` assembles the three roots with all recursively pinned gitlinks and MoltenVK's seven `ExternalRevisions` dependencies at their expected paths. All codeload archives, primary metadata, notices, source lock, original fetch recipe and its full GPL-3.0-only license are retained inside this marked packet. Its manifest checks all 39,047 file/link records, including assembled copies and metadata. APFS copy-on-write copies avoid duplicating source data pages; the initial conservative estimate was 285 MB of unique source content, with a 512 MiB free-space reserve. No active runtime or Vendor tree was changed.

The nested closure includes DXIL-SPIRV's own DXBC-SPIRV/SPIRV-Cross/SPIRV-Tools/headers and DXBC-SPIRV's headers, as selected by the actual gitlinks. MoltenVK's external revisions come from its pinned `ExternalRevisions/*_repo_revision` files and the inspected `fetchDependencies` recipe. They were acquired without running that recipe. Optional non-Git-managed test/build dependencies, generated/configured files, cross-compilers and exact publisher toolchain inputs must still be inventoried when preparing a build; this source acquisition is not a tested offline-build claim.

Commands:

```sh
# Resolve/review the fixed root tags, acquire recursive exact sources and write the lock.
python3 Scripts/runtime_fetch_renderer_sources.py prepare
# Use the committed lock, or independently verify the already acquired packet.
python3 Scripts/runtime_fetch_renderer_sources.py fetch
python3 Scripts/runtime_fetch_renderer_sources.py verify --packet Runtime/CorrespondingSources/renderer-sources-4d0f21c8f6e04e228035
```

A newly fetched packet stays separate and an existing packet is verified rather than overwritten. Packet identity includes the exact acquisition recipe hash; verification recomputes the declared fingerprint and checks the source lock, recipe hash and every Git blob. `prepare --archive-cache <verified-packet>` can reuse already verified archives and retained primary metadata without another API resolve; it must match these three fixed release commits. The superseded scratch source packet from the first acquisition was retired only after this packet and its license/recipe were verified. Six verification checks pass: the actual complete packet and a valid synthetic fixture are accepted; a corrupt declared fingerprint, changed source blob, changed recipe, and changed lock are rejected even when the fixture file map is refreshed. The owned synthetic verification directory was removed. All three published artifact digests match, which proves **release/tag association**. A publisher build attestation or equivalent complete binary-build record has not been verified by this acquisition. Therefore `artifactBinaryBuildAttested` and `binaryRedistributionReady` remain **false**. Source completeness does not create approval for those binaries, the frozen notice payload, or renderer capabilities. The copied orchestration's full GPL-3.0-only license is retained as `recipe-LICENSE`, alongside upstream notice indexes. Apple is entirely excluded.

## Next immutable candidate

Use the newly retained complete renderer source trees and pinned external dependencies, deliver exact notices with the runtime, and create component receipts tying actual output hashes to source/archive inputs, patches, commands, tools and post-processing. Resolve the native ARM64 closure and deployment target explicitly. Separately close the font/asset receipts and source-delivery package. The dependency25 gate and receipts should be referenced without expanding their scope.

Distribution provenance and rendering capability are independent gates. Runtime68 currently verifies WineD3D/D3D9, Vulkan on Kosmic/Molten and DXMT/D3D11. It does **not** verify DXVK or VKD3D as available renderers. The diagnostic Wine layered-properties W2H correction is not in the active runtime68. None of these provenance findings remove actual device-feature, shader/readback or presentation requirements, and no Vulkan features were overridden.
