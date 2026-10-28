<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Source-built MoltenVK 1.4.2 component

The separate candidate `ready-source-moltenvk-53f6ea0ad1fb46c5ca0b` is retained under the authorized external workspace's `retained` directory. No active configuration, current provider, installer transaction, DLL or Vendor source was changed. The old official MoltenVK payload remains selected until a separate integration review.

`Scripts/runtime_build_moltenvk.py` and its lock compile unchanged MoltenVK commit `db66022459ffb663aa2b50f6b018bc2e124f5edf`. Eight exact upstream revisions and build-only CPM 0.40.8 are retained, with source-archive SHA256 and Git blob/tree metadata. The complete renderer source packet remains unchanged. All edits and Git metadata occur only inside copied source under external `build/moltenvk-82a6ab8f94ef6bad0984`.

The normal CMake path succeeds with Command Line Tools alone: no `metal`, `metallib`, `xcodebuild` or new Xcode installation is required. Runtime shader compilation uses system Metal APIs. CPM source overrides point to the exact private source copies, and its bootstrap file/source archive are pinned; no dependency floats to a branch or downloads itself during configure. Each dependency gets its own exact Git HEAD metadata, avoiding an accidentally inherited parent revision. Those recreated metadata objects are not a claim about how historical upstream CI binaries were built.

Features retain SPIRV-Tools disassembly and cereal pipeline caching. Metal private APIs remain off; the standalone shader-converter CLI is not packaged. Source builds run sequentially for x86_64 and arm64, at two jobs per architecture, with external TMP/cache paths and a 2 GiB reserve. Separate link maps contain 97 x86_64 and 98 ARM64 object entries, with no Homebrew static object/archive. Every compilation unit has a source/generated-path hash and command receipt. The final universal dylib has only macOS system/framework load dependencies, `@rpath/libMoltenVK.dylib` as its install ID, no rpaths, and actual minimum macOS 27.0.0 for both slices. The relative ICD follows the unchanged upstream template's API metadata; this is not a fabricated device capability.

The immutable component's 92 file/link records retain the universal code, complete upstream/CPM source archives, source lock, notices, actual orchestration snapshots/full GPL license, command/log hashes, compilation databases, CMake caches, separate link maps, source-unit map and lipo/install-ID/signing receipt. Its manifest intentionally retains `binaryRedistributionReady:false`: source/build correspondence for one component does not approve an entire runtime or replace license selection.

`Scripts/runtime_moltenvk_source_probe.py` executes seven real checks:

- Native ARM64 GPU buffer transfer/readback of 4 KiB.
- Native graphics pipeline producing the expected offscreen pixel `[64,128,191,255]`, plus 60 independent render-pass-clear presentations through a Metal surface.
- Native properties base/core/full queries preserving guards/headers and matching legacy properties.
- Actual current E6 Wine Vulkan GPU buffer/readback.
- Actual Windows Vulkan window presenting 600 frames through Wine and the new MoltenVK component.

All seven pass. The observed Vulkan device API is `1.3.357`, independently of the library release number 1.4.2. No API/capability override is applied. Native dyld observers see the new candidate and permitted tested loader/host/dependency images with no unexpected image in any case. The owned synthetic Wine prefix is stopped with its exact wineserver, waited for, and removed; user folder links are isolated into its private scratch. The candidate's complete file map and both default configuration hashes remain unchanged after the matrix. No physical-controller, direct-display, DXVK or game-compatibility claim follows.

`Scripts/runtime_verify_moltenvk.py` independently rechecks the immutable fingerprint, actual universal Mach-O closure/deployment metadata, retained archive/bootstrap pins, link maps and bound runtime logs/image audits. The actual component plus four owned APFS COW corruption controls pass six checks: changed payload, declared fingerprint, escaping alias and changed runtime-log hash are rejected; original bytes remain unchanged. This verifier neither loads a library nor needs original compiler caches.

```sh
python3 Scripts/runtime_build_moltenvk.py plan
python3 Scripts/runtime_build_moltenvk.py prepare
python3 Scripts/runtime_build_moltenvk.py configure
python3 Scripts/runtime_build_moltenvk.py build
python3 Scripts/runtime_build_moltenvk.py freeze
python3 Scripts/runtime_moltenvk_source_probe.py
python3 Scripts/runtime_verify_moltenvk.py /Volumes/…/retained/ready-source-moltenvk-53f6ea0ad1fb46c5ca0b --validation Evidence/runtime-moltenvk-source-validation.json
```

Raw local evidence is under `Evidence/runtime-moltenvk-source-*`; detailed logs live in an owned external `retained/moltenvk-proof-*` directory. A later consumer projection must transport its exact source/notices and validation receipt, then retest the selected host/loader before any verified-engine promotion or default change. Existing generation68, E6, native4 and installer fingerprints are not retroactively rewritten.
