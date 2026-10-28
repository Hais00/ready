# Binary distribution gate

**Community bootstrap: `binaryRedistributionReady: false`. Source-built dependency subset: gate passes for 25 shared libraries/modules.** The new source set below has exact source/build/notice mapping and hash-bound runtime evidence. This is a dependency-payload gate, not approval of the whole application or every file in a runtime. The old community dylibs remain unapproved and are retained as local baseline inputs.

This audit covers `Runtime/wine-deps/lib`, inspected on 2026-10-28. It does not approve the entire launcher, Apple optional runtime, Wine, DXMT, store helpers, or every file in a frozen provider. A future binary release needs a complete inventory of its actual final payload as well.

## Actual inventory

`Scripts/runtime_dependency_inventory.py` statically reads Mach-O/ELF headers and Mach-O load commands without executing or loading a library. It records SHA256, size, CPU slices, install IDs, ABI versions, minimum OS/SDK fields, referenced dylibs, symlink targets, source evidence gaps, and project-family license leads.

Current result, recorded in `Evidence/distribution-dependency-inventory.json`:

| Measurement | Result |
|---|---:|
| Physical dynamic libraries | 39 |
| Mach-O dylibs | 39, all x86_64 |
| ELF files | 0 |
| Symlink aliases | 57, all present and inside the dependency directory |
| Physical payload | 51,346,204 bytes, about 49 MiB |
| Project-family leads | 26 |
| License/notice files retained in this dependency tree | 0 |
| Libraries with verified exact corresponding-source mapping | 0 |
| Unresolved non-system Mach-O references in this inventory | 0 |

Every current directory name appears in the recorded extraction list; no listed name is missing. That is a name-level check, not proof that current bytes still match their original archive members. The original downloaded archive was removed by the fetch recipe, and no original per-file hash manifest was retained. The inventory hashes the actual current bytes now.

All external-library reference resolutions are explicitly marked *candidate* resolutions. macOS system framework/libSystem references are not copied into this directory and are outside the shipped-community-file list. An install ID or LC_BUILD_VERSION reports binary metadata, not a source revision, full toolchain receipt, or license.

## What provenance exists

`Runtime/wine-deps.artifact.json` records:

- Container: [Gcenx Wine development 11.18](https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.18), asset `wine-devel-11.18-osx64.tar.xz`.
- URL: `https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.18/wine-devel-11.18-osx64.tar.xz`.
- SHA256: `aa0ea4c82e636ae7bca2076387cb0a5affa26509ad13f119ecd0d62bd7ba6f82`.
- Names extracted and the fact that Wine binaries, old MoltenVK, and non-dylib top-level files were excluded.
- `distribution_reviewed: false`.

The recorded SHA256 matches the digest returned by the [publisher's release API](https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases/tags/11.18) when checked for this audit. The [publisher README](https://github.com/Gcenx/macOS_Wine_builds) identifies MacPorts and its MacPorts overlay as the dependency source. This gives a credible container/package origin. It does not identify each dependency's exact source archive, MacPorts port revision/variants, applied patches, or complete build settings.

`Scripts/runtime_fetch.py --wine-deps-only` extracts top-level `.dylib` files and simple aliases. It intentionally does not retain the archive's other top-level content, so no license receipts can be assumed to accompany these extracted files. This audit does not claim the publisher's complete archive lacks notices or corresponding source; it establishes what **our extracted tree** currently retains.

`Scripts/runtime_build.py` builds Wine against these already-compiled dylibs. It is a Wine build recipe, not a recipe for compiling GnuTLS, FreeType, or their dependencies. Freezing/copying these bytes into a content-addressed provider does not close that source-provenance gap.

## Version evidence is incomplete

ABI numbers are not package versions. For example, the actual `libgnutls.30.dylib` has install ID `libgnutls.dylib` with current version `71.1.0`; `libfreetype.6.dylib` reports `27.2.0`. Neither number proves the corresponding GnuTLS/FreeType release or MacPorts patch set.

Filenames include useful leads such as Brotli `1.1.0`, ICU `76.1`, bzip2 `1.0.8`, zlib `1.3.1`, zstd `1.5.6`, LZ4 `1.10.0`, and Vulkan Loader `1.4.350`. The inventory preserves them as **unverified filename hints**. It deliberately leaves `exactSourceVersion`, `exactSourceRevision`, and source archive SHA256 null for every existing dependency binary.

Separate build headers came from uninstalled Homebrew bottles: GnuTLS `3.8.13_2` and FreeType `2.15.0`. Their header files remain in `Runtime/dependency-headers`, but the expected `dependency-headers.artifact.json` record is currently absent. These headers are neither the compiled community libraries nor their complete corresponding source. Supplying a newer upstream tarball because it has a compatible SONAME would not identify the source actually used to build an older binary.

## License review leads, not binary approvals

The following are upstream project-family leads. The exact compiled source and its individual file notices still control each binary. No row assigns a verified SPDX expression to an existing community dylib; the machine inventory records `binaryLicenseExpression: null`.

| Library family / current physical files | Upstream license lead |
|---|---|
| GnuTLS C/C++ (2) | [Core library LGPL-2.1-or-later](https://gnutls.org/); other project parts have different terms |
| GMP C/C++ (2) | [GNU GMP licensing](https://gmplib.org/manual/Copying): LGPL/GPL alternatives, subject to exact release and files |
| Nettle / Hogweed (2) | [Nettle manual](https://www.lysator.liu.se/~nisse/nettle/nettle.html): LGPLv3/GPLv2 alternatives; retain selected source notices |
| GNU libunistring (1) | [Upstream license summary](https://www.gnu.org/software/libunistring/manual/html_node/Licenses.html): LGPL-3.0-or-later or GPL-2.0-or-later, with per-file terms |
| GNU libidn2 (1) | [Upstream manual](https://www.gnu.org/s/libidn/libidn2/manual/libidn2.html): LGPL/GPL alternatives; review bundled Unicode data too |
| libtasn1 (1) | [GNU project](https://www.gnu.org/software/libtasn1/): library LGPL terms; exact release needed |
| libiconv / libcharset (2) | [GNU project](https://www.gnu.org/software/libiconv/): library LGPL terms; tools differ |
| gettext libintl (1) | [GNU license summary](https://www.gnu.org/software/gettext/manual/html_node/Licenses.html): runtime library and tools have different terms |
| FreeType (1) | [FTL or GPL alternatives](https://freetype.org/license), plus individual contributed-file notices |
| MacPorts Legacy Support/System (2) | [Mixed MIT, APSL-2.0, and per-file terms](https://github.com/macports/macports-legacy-support/blob/master/LICENSE); exact compiled subset not established |
| ICU (6) | [Unicode and third-party terms](https://github.com/unicode-org/icu/blob/main/LICENSE) |
| SDL2 (1) | [zlib-style license](https://github.com/libsdl-org/SDL/blob/SDL2/LICENSE.txt) |
| Brotli (3) | [MIT](https://github.com/google/brotli/blob/master/LICENSE) |
| bzip2 (1) | [Upstream release license](https://sourceware.org/bzip2/), BSD-style; retain its selected version's text |
| libffi (1) | [MIT and per-file notices](https://github.com/libffi/libffi/blob/master/LICENSE) |
| libinotify-kqueue (1) | [MIT](https://github.com/libinotify-kqueue/libinotify-kqueue/blob/master/LICENSE), subject to exact source mapping |
| LZ4 (1) | [Library BSD terms](https://github.com/lz4/lz4/blob/dev/lib/LICENSE); tools differ |
| liblzma (1) | [XZ release-specific licensing](https://github.com/tukaani-project/xz/blob/master/COPYING); current liblzma is 0BSD, older public-domain/file terms must be checked |
| p11-kit (1) | [BSD-style and per-file notices](https://github.com/p11-glue/p11-kit/blob/master/COPYING) |
| libpcap (1) | [BSD-style](https://github.com/the-tcpdump-group/libpcap/blob/master/LICENSE) |
| libpng (1) | [PNG Reference Library License](https://github.com/pnggroup/libpng/blob/libpng16/LICENSE), release-specific text |
| Vulkan Loader (1) | [Apache-2.0 project source](https://github.com/KhronosGroup/Vulkan-Loader); bundled `1.4.350` filename does not identify its exact build |
| libxml2 (1) | [MIT-style and per-file notices](https://github.com/GNOME/libxml2/blob/master/Copyright) |
| libxslt / libexslt (2) | [Separate notices](https://github.com/GNOME/libxslt/blob/master/Copyright) |
| zlib (1) | [zlib license](https://zlib.net/zlib_license.html) |
| Zstandard (1) | [BSD option and separate alternative terms](https://github.com/facebook/zstd/blob/dev/LICENSE) |

MacPorts Legacy Support deserves a specific review. Its upstream license file explicitly describes Apple-source APSL-2.0 files as well as MIT community additions; it cannot be labeled entirely MIT. The FSF classifies [APSL-2.0 as free software but GPL-incompatible](https://www.gnu.org/licenses/license-list.html#apsl2). This audit has not established which files entered these two dylibs or decided the applicable combined-work boundary. Retain that as a blocking file-level/source-build review, rather than declaring either universal incompatibility or approval from the project name alone.

For copyleft libraries, free-of-charge distribution does not remove source-delivery and notice requirements. LGPL-2.1 covers corresponding library source, changes and build/install material, and applicable replacement/relinking rights for combined works. See the [license text, particularly sections 4 and 6](https://opensource.org/license/lgpl-2-1). Permissive library options also require checking and retaining their actual notices; our launcher's GPL does not replace them.

## Pinned source rebuild required

The recommended release route is a **new dependency provider built from pinned public source**, rather than asserting that this bootstrap's exact source can be reconstructed from its filenames. It must not overwrite an active immutable runtime.

1. Determine the actual needed library closure using Wine configure results, native load commands, explicit dlopen names, and real launch traces. The known GnuTLS/FreeType inputs alone currently reach **20 physical libraries** through their static load-command closure. That is a lower-bound/configuration-specific lead, not evidence that all other libraries are unused. ICU test utilities or a second Vulkan Loader should not be shipped by default without demonstrating a need.
2. For every chosen dependency, pin an upstream source release/commit and archive hash; retain the complete source, package/port revision if used, patch files, configure/CMake/Meson arguments, feature choices, compiler/SDK/target information, and dependency input hashes. Inspect static linking too: a dylib can incorporate code whose license is not visible in `otool -L`.
3. Select and record actual permitted licensing alternatives from those source notices. Audit MacPorts legacy-support's compiled file set, or omit/rebuild the compatibility shim where the selected modern macOS target makes it unnecessary. Do not guess that upstream's root license covers every file.
4. Build into a fresh source-derived prefix. Preserve a machine-readable mapping from every resulting binary SHA256 to those source/patch/build inputs, plus all license/copyright/third-party notice files. Record changes to install IDs, signing, stripping, or universal slices as reproducible build steps.
5. Use the project's intended public copyleft source-delivery method and prepare the corresponding source/build material alongside the binary release. Include applicable replacement/relink instructions and material; exact obligations follow the selected licenses. GitHub links to unrelated latest source trees are insufficient evidence of correspondence.
6. Run the existing Wine/HTTPS/fonts/renderer/probe matrix against that new provider. New source rebuilds may change ABI/runtime behavior even if SONAMEs match. Freeze it under a new identity only after actual tests, then inventory the final release payload again.

The current inventory has no mechanism that turns a publisher `distribution_reviewed` flag or a filename match into approval. It deliberately reports false until the source/build/notice gaps are addressed and the gate is extended to verify the resulting evidence. This dependency gate is necessary for a binary release; passing it still does not authorize redistribution of Apple's optional proprietary files or approve every other runtime component.

## Run the inventory and gate

```sh
# Inspect local bytes; no download, execution, or runtime modification.
python3 Scripts/runtime_dependency_inventory.py --output Evidence/distribution-dependency-inventory.json

# Release/bundle preflight: currently exits 3 and writes binaryRedistributionReady=false.
python3 Scripts/runtime_dependency_inventory.py --gate --output Evidence/distribution-dependency-inventory.json
```

Normal inventory mode exits 0 so it can produce an audit artifact while blocked. `--gate` must be checked before preparing a redistributable runtime bundle; a false gate is not an instruction to stop source development or discard the existing local test runtimes. The script and this documentation are original GPL-3.0-only project files; dependencies retain their own licenses.

## Source rebuild completed: candidate and consumer subset

The rebuild is complete in `Runtime/SourceDependencies/source-deps-839dc852b05e28e8b67d`. It does not reuse community binary inputs or include MacPorts Legacy Support. `Scripts/runtime_dependencies.lock.json` pins all 17 source archives and hashes; `Scripts/runtime_build_dependencies.py` records the actual build, normalizes dependency references, retains the full corresponding source, and verifies installed bytes. The source prefix contains 54 compiled code inputs; the runtime dependency gate approves only **23 dylibs and 2 PKCS#11 modules**, about 14.3 MB. The other 27 executables and 2 static archives are outside this gate and are omitted from the consumer subset.

| Source component | Version |
|---|---|
| zlib | 1.3.2 |
| bzip2 | 1.0.8 |
| Brotli | 1.2.1 |
| Zstandard | 1.5.7 |
| libpng | 1.6.59 |
| libffi | 3.8.0 |
| GNU libiconv | 1.19 |
| GNU libunistring | 1.5 |
| GNU gettext runtime | 1.0 |
| GNU GMP | 6.3.0 |
| GNU Nettle | 4.0 |
| libtasn1 | 4.21.0 |
| GNU libidn2 | 2.3.8 |
| p11-kit | 0.26.5 |
| FreeType | 2.15.0 |
| GnuTLS | 3.8.13 |
| libpcap | 1.11.0 |

GnuTLS keeps Nettle/GMP, PKCS#11/libffi, IDN, C++ API, native macOS trust, and zlib/zstd/Brotli compression. FreeType keeps zlib/bzip2/PNG/Brotli. The actual Wine/WineCX native closure does not use native ICU/HarfBuzz: their shaping implementations remain static PE code in the independently pinned Wine source trees. Disabling FreeType's native HarfBuzz integration matches that baseline and does not remove Wine's PE shaping code. libpcap is included because the installed Wine `wpcap.so` directly references it.

The source target is x86_64/macOS 14.0; all installed Mach-O headers were checked. Tests ran on this M1/macOS 27 under Rosetta, not on an actual macOS 14 machine. Current SDK FreeType HVF support is a **weak** OS-library load with upstream availability checks; it remains enabled, and `/usr/lib/libhvf.dylib` is not copied or classified as open-source project code. libpng's optional framework packaging was disabled and FreeType explicitly links the source-built PNG dylib. Other macOS frameworks/libSystem are also external operating-system dependencies, not redistributed files.

Source bytes were fetched from upstream locations and matched the retained SHA256 pins. Expected pins from Homebrew's public source records are identified explicitly; official GitHub release digests were cross-checked where provided. OpenPGP signatures were not verified and no signing/certification claim is made. These new binaries have exact correspondence because we compiled the retained input archives with retained recipes; no version/source correspondence is inferred for the old community binaries.

### Retained provenance and runtime evidence

The source prefix retains approximately 69 MB of complete source archives under `share/ready/sources`, exact notices under `share/ready/notices`, and component receipts under `share/ready/receipts`. Each receipt maps installed paths/hashes to source version/URL/archive SHA, patches (none required here), exact commands, build environment, compiler/SDK/tool versions, and the copied recipe script hash. Recipe snapshots and the project recipe license are in `share/ready/recipes`. Post-build install-ID/load-path normalization and ad-hoc signing are recorded separately. Sources and active runtime providers were not overwritten.

Original source manifest SHA256:
`8cb19790aa15fd30b9b48fbb5b443126b030036b3d057be6dfe5071f1e75f6c2`.
Its full 54-code-input fingerprint is
`2764b2735f6008b627b6947d12ff3807e618605b49b2eb8c71f898ce20a24071`.

`runtime-validation.json` is a separate sidecar copied from `Evidence/runtime-source-dependency-validation.json`. It binds that unchanged manifest hash and all 54 input hashes to six required matrix groups and 32 real JSON/log evidence files with SHA256. The gate rechecks those files and raw reports, including their candidate input hashes and failure/bypass flags. The original manifest's initial pending flag is left unchanged to avoid a circular manifest/receipt hash; effective readiness is computed from the verified sidecar.

The required groups passed:

- Wine 11.20 and WineCX 11.19, both PE32 and PE64: real HTTPS 200/content, rejection of an untrusted local certificate without a bypass, GDI glyph alpha, and DirectWrite glyph-run alpha.
- Existing open GPU paths on Wine 11.20 PE64: D3D9 readback, Vulkan through Kosmic/Molten readback, DXMT buffer/shader readback and presentation.
- PE32: DXMT buffer readback and presentation. No PE32 shader-raster claim is added.

The Wine 11.20 DirectWrite module needed its already-identified malformed FreeType SONAME repaired in an isolated source-derived projection. That recipe/hash is in the evidence. No active Wine or old frozen runtime was changed. Optional local Apple evaluation results remain separate, proprietary, and consumer-disabled; they do not contribute to this open dependency gate. No game/account compatibility guarantee follows from the synthetic matrix.

### Consumer selection protocol

The private candidate `Runtime/Sets/ready-source-runtime-c120c38867741c7d8a1b/dependency-root` passed the dependency-only gate with exactly the 25 libraries/modules. Candidate wrapper/end-to-end testing and activation are separate runtime-manager steps; a passing dependency gate does not change the default configuration.

A consumer keeps the original 54-input manifest and runtime receipt byte-identical under `share/ready/origin`, with the 297 source/provenance files in their original relative paths. `selected-runtime-files.json` binds `originManifestPath`, `originManifestSHA256`, `originReceiptPath`, `originReceiptSHA256`, the dependency set ID, the selected 25 path/hash pairs, and the excluded 29 path/hash pairs. No original receipt is rewritten to pretend it tested a smaller input set.

The inspector independently derives the shared-library/module selection from the original manifest and actual Mach-O files. It requires every selected file to match, every excluded code input to be absent, no untracked native code, complete retained source/notices, valid internal aliases and actual relocatable shared-library closure. The payload fingerprint is distinct from the original 54-input fingerprint. Original source/provider snapshots remain immutable.

Tests on owned COW fixtures verify that missing runtime evidence, stale manifest binding, incomplete matrix, wrong input hashes, changed binaries, or reinserting an excluded CLI close the gate. The actual source/consumer prefixes are not altered by those negative tests. The default legacy-bootstrap gate still fails. Reports are `Evidence/distribution-source-dependency-inventory.json`, `distribution-source-consumer-gate.json`, and `distribution-source-gate-tests.json`.

### Reproduce or check

```sh
# Fresh input set: source fetch, build, normalization/provenance finalization.
python3 Scripts/runtime_build_dependencies.py fetch
python3 Scripts/runtime_build_dependencies.py build --jobs 3
python3 Scripts/runtime_build_dependencies.py finalize
python3 Scripts/runtime_build_dependencies.py verify

# Runtime evidence is generated only after executing the real smoke matrix.
python3 Scripts/runtime_dependency_receipt.py --prefix Runtime/SourceDependencies/source-deps-839dc852b05e28e8b67d

# Auto-detect complete source prefix or derived consumer subset; both require evidence.
python3 Scripts/runtime_dependency_inventory.py --root Runtime/SourceDependencies/source-deps-839dc852b05e28e8b67d --gate
python3 Scripts/runtime_dependency_inventory.py --root Runtime/Sets/ready-source-runtime-c120c38867741c7d8a1b/dependency-root --gate
```

Finalized prefixes refuse in-place rebuild/finalize; use a new locked recipe revision/input set for a subsequent provider. Build/work caches are ours only and remain separate from the retained source/receipt packet; cleanup must follow validation and must not discard corresponding-source material. The current sources, receipts, selected libraries, and 32-log runtime proof close the **dependency subset** gate. Fonts/assets, copied games, store tools/.NET, the whole app, and optional proprietary files still need their own applicable distribution review.
