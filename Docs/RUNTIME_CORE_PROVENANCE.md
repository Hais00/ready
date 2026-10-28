<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Wine / DXMT runtime provenance audit — draft

The current Wine 11.20 and DXMT runtime trees have intact frozen file identities,
but their complete source-and-notice distribution package is unfinished. The
approved subset of 25 external dependency libraries/modules does not approve Wine,
DXMT, statically linked code, fonts, or embedded resources.

This is a read-only technical inventory, with no new license approval. Missing
items below are provenance and reproducibility gaps; they are not findings that a
component is non-free, nor a determination that every listed artifact is legally
required. No runtime, vendor source, configuration, or binary was modified or
rebuilt. Raw records, hashes, recipe candidates, and limitations are in
`Evidence/runtime-core-distribution-audit.json`.

## Actual files and retained identities

| Scope | Regular files observed | Important contents |
| --- | ---: | --- |
| `ready-source-runtime-68c00b7d3878699829eb/wine` | 3,885 | 751 PE x64, 839 PE x86, 38 Mach-O, 520 static/import archives, 50 NE bitmap font resources, 1,687 other files |
| `ready-source-dxmt-68c00b7d3878699829eb/wine` | 3,888 | 752 PE x64, 840 PE x86, 39 Mach-O, otherwise the same category counts |

Each tree also has 16 symlinks. All observed regular-file hashes and symlink
targets match their respective `source-generation.json`. PE counts include
resource containers and WinRT metadata; they are not counts of executable game
code. SDK headers, development tools, and static/import archives have not been
selected for a consumer runtime subset.

The current retained Wine Makefile supplies source/recipe candidates for all
installed PE and Mach-O files, including generated `.winmd` metadata. This is a
recipe graph, not proof that each historical binary used every recorded input.
The current `compile_commands.json` contains 9,168 entries; configure files and
local build logs are retained. A release still needs a source/binary manifest
binding the selected files to the relevant historical configuration, toolchain,
source, static inputs, and post-link transformations.

## Wine source, changes, and static inputs

`Vendor/wine` contains Wine 11.20 source, original per-file notices, `LICENSE`,
`COPYING.LIB`, and `AUTHORS`. `Vendor/wine.source.json` records the original source
URL and archive SHA256 `eac8ca448f9c0087f963026b4dc276d1e2b7fbb64056edc093e59bbb7e56fe28`.
The original fetch recipe deletes the archive after extraction. This audit hashes
the extracted tree but does not reverify every file against the original archive.
The diagnostic XInput source snapshot is separate from the active generation and
does not certify the active runtime's release package.

Three narrow modifications have original/adapted source or configuration receipts:

| Change | Source and recipe retained | Final-byte chain |
| --- | --- | --- |
| Vulkan portability enumeration | Wine `dlls/win32u/vulkan.c`, `runtime_wine_portability.patch`, `runtime_patch_wine.py` | Pre-normalization module hash matches the normalization input; final hashes match base and DXMT modules |
| DXMT window ABI bridge | Wine `dlls/winemac.drv/window.c`, `runtime_wine_dxmt_window.patch`, `runtime_patch_dxmt_wine.py` | Same chain matches the DXMT `winemac.so` |
| DirectWrite FreeType SONAME | Wine `dlls/dwrite/freetype.c`, header/configuration receipt, `runtime_build.py build-dwrite` | Same chain matches base and DXMT `dwrite.so` |

The normalization receipts record `install_name_tool` commands and before/after
hashes. The declared historical `runtime_freeze.py` recipe differs from today's
file, but its exact version remains in Git commit
`c224aff19345813601049af1e34be51c38056bf8`. The DXMT freeze and source-generation
freeze recipes still match their declared hashes.

The matched Wine recipe graph references 31 in-tree static components:

`c++`, `capstone`, `compiler-rt`, `dmoguids`, `dxguid`, `faudio`, `ffmpeg`,
`fluidsynth`, `gsm`, `icucommon`, `icui18n`, `jpeg`, `jxr`, `lcms2`, `ldap`,
`mfuuid`, `mpg123`, `musl`, `png`, `sqlite3`, `strmbase`, `strmiids`, `symcrypt`,
`tiff`, `uuid`, `vkd3d`, `winecrt0`, `wmcodecdspuuid`, `xml2`, `xslt`, and `zlib`.

Their source trees, Makefiles and available standalone notice files are indexed
and hashed in the raw report. Root Wine LGPL notices alone do not enumerate all
those per-file terms. The remaining work is to select the actual shipped files,
map their historical static/object inputs, and retain the corresponding component
and per-file notices in the release source/notice package.

## Fonts, tables, and resources

All 56 installed font files have retained recipes. Six TTF files byte-match the
upstream Wine TTFs; 50 `.fon` files are generated NE font resources. SFD glyph
sources and Wine's `sfnt2fon` generator are present. Font source metadata preserves
individual authors and terms, including Larry Snyder / Bitstream Vera attribution
for Tahoma. There is no completed release asset/notice selection or independent
regeneration receipt for the generated FON files.

All 77 installed NLS files byte-match their Wine source-tree counterparts. The
current recipe graph identifies 572 retained resource/IDL/translation inputs.
Wine's `tools/make_unicode` pins 15 external data inputs by URL and SHA256:
Unicode UCD/Unihan/IDNA, CLDR 48 and 33, Microsoft sorting/codepage tables, SIL
ISO639, legacy Korean/Japanese mappings, IANA timezones, Adobe glyph/font data,
and Microsoft ICU. None of those original dataset files is present in the
known local Wine data cache. The generated Wine files and generator are present;
preferred-input retention, dataset notice mapping, and a release resource manifest
remain separate work.

## DXMT and its incorporated dependencies

The DXMT source archive for commit
`3b252590cb0290e36fca6f088b5255b871d2d95a` and its DirectX-header archive are
retained and match their pinned SHA256 values. This audit rechecked 391 DXMT files
and 66 header-submodule files against those archives with no mismatch. All nine
selected DXMT DLL/Unix-module files in the active provider remain byte-identical
to the locked upstream CI payload. The original CI ZIP and payload archive,
run/artifact identifiers, workflow, source notices, and submodule pin are retained.

This identity proof does not close incorporated-code provenance:

- Actual `winemetal.so` contains LLVM 15.0.7 version strings. Its recipe links
  static LLVM libraries and `airconv`; its Mach-O imports contain no separate LLVM
  dylib. The exact LLVM 15 source tree/archive, complete notices and third-party
  terms are absent from the retained DXMT inputs. A local link map/receipt for the
  actual LLVM archives and objects is also absent.
- The source workflow names LLVM-MinGW `20260908` and Wine `v8.16-3shain` as CI
  inputs. The PE recipe uses static runtime linking and Wine startup/import
  libraries. Their exact incorporated runtime/startup source-and-notice closure
  is not established by the local artifact receipt. Import tables are recorded;
  they cannot identify every statically linked input.
- DXBCParser sources retain Microsoft's MIT declarations; DXVK-derived utilities
  retain their zlib notice, and SHA1 source retains its public-domain statement.
  These are retained facts, not a completed notice selection for the binaries.
- Metal shader sources and generation recipes are present. The local receipt lacks
  the original CI link maps/attestation and exact Metal compiler/SDK input receipt
  for generated AIR/metallib data. Metal, MetalFX and other macOS framework imports
  remain external operating-system dependencies; the nine selected payload files
  do not contain a copied Apple framework.

## Portability and remaining release gate

Every one of the 38 Wine Mach-O images advertises a minimum macOS version of
27.0, including the Wine loader. DXMT's additional `winemetal.so` advertises 15.0.
The frontend package's macOS 14 target therefore does not establish runtime
support on macOS 14. Earlier runtime support needs a suitable runtime build and
actual validation on that OS range.

Before a complete open runtime release can be assessed, retain the missing exact
source/data/toolchain inputs or replace them with a reproducibly mapped build;
select the consumer runtime files; produce the derived binary/source/static-input
and resource manifest; and assemble the exact notices. Keep this core gate
separate from the approved 25-library dependency subset, rendering API tests, the
frontend package, store helpers, and optional proprietary Apple evaluation files.


## Source acquisition update

The missing source-material acquisition step is now complete in the immutable
`Runtime/CorrespondingSources/core-sources-fab45a108a11b5d83fa9` packet. It contains
21 newly acquired inputs plus the two previously retained DXMT/source-header
archives. Large LLVM trees remain compressed; only notices, metadata, and local
recipes are materialized. None of the vendor or runtime trees was changed.

- The original Wine 11.20 archive matches its pre-existing SHA256. All 12,463
  regular source files were compared against `Vendor/wine`, with zero missing or
  different files. This resolves the earlier archive/tree acquisition gap.
- All 15 `make_unicode` inputs match their pre-existing SHA pins and are retained
  in the packet, without changing the generator's normal cache. Candidate
  standalone notices, original data, and available inline notice headers are
  preserved. Presence is not a license-scope approval.
- LLVM 15.0.7 source resolves to commit
  `8dfdcc7b7bf66834a761bd8de445840ef68e4d1a`, matching the observed binary version
  string. Wine CI `v8.16-3shain` resolves to
  `4dd8a2d6dca39a116d0911f247bbaf1ad5e29471`.
- LLVM-MinGW `20260908` resolves to
  `030097eeee87fcfd0f3bfe536b21cbd6e5d3b324`. Its pinned source scripts default
  to LLVM `llvmorg-23.1.1` at
  `6dfe1677ab8dffbc6ec13d53a1e0215d75147689` and MinGW-w64 CRT commit
  `9f55f4a2d3b9783dab76d9808be3d6279b99ec2a`; their complete archives are
  acquired. These runtime-source candidates are distinct from the toolchain
  build recipes and LLVM 15 airconv code. The upstream nightly/manual workflow
  can override defaults, so the release defaults alone do not prove which
  objects were incorporated in a cached DXMT artifact.

The source lock is `Scripts/runtime_core_sources.lock.json`; acquisition,
Wine-tree comparison and negative-check reports live under `Evidence/runtime-core-source-*`.
The packet includes the exact acquisition recipe, its GPL-3.0-only license,
historical/current local build recipes, source lock, catalogue and file manifest.
Its fingerprint is
`cb9dd8dc237773bc3727ef0d9f28706e8a2d1eea929cd2a6ee5ddb4404f3a445`.

```sh
python3 Scripts/runtime_fetch_core_sources.py --verify
python3 Scripts/runtime_fetch_core_sources.py --negative-checks
```

Verification checks the locked archive bytes, complete packet file inventory,
lock, recipe, recipe license and declared fingerprint. Completed packets reject
fetch/finalize overwrites; retries require an owned partial marker. The original
completed files are retained when network/hash checks fail or the 512 MiB
free-space reserve is reached. No build or activation is performed.

The earlier source-availability gaps are resolved by this packet. The remaining
artifact/static-object correspondence, historical toolchain/cache identity,
per-file notice/terms review, selected runtime release inventory and macOS
portability gates remain open. `artifactCorrespondenceVerified`,
`licenseApproval` and complete-runtime distribution approval remain false.
