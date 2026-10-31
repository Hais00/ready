# Third-party notices

ready's original code is GPL-3.0-only. Copyright 2026 ready contributors.

The Windows C# frontend uses Veldrid 4.9.0 (MIT), with its dependency resolution
in `Windows/Ready.Windows/packages.lock.json` and its copyright/permission notice
in `LICENSES/veldrid-MIT.txt`. Our GLSL/SPIR-V canvas shaders are GPL-3.0-only.
glslang is a developer tool, not a runtime dependency. Windows Steam builds use
the existing pinned SteamKit source and LGPL shutdown patch. Valve client files
and GameNative's closed hosts are not included; complete Windows binary
distribution closure remains unapproved.

The Windows login canvas generates QR codes in memory with QRCoder 1.8.1 (MIT),
copyright Raffael Herrmann and Shane Krueger. The complete notice is retained in
`LICENSES/qrcoder-MIT.txt`; its dependency hash is pinned in the Windows lock file.

The full LGPL 2.1 text for Wine-derived patches and their LGPL-2.1-or-later notices is retained in `LICENSES/LGPL-2.1.txt`. It is copied unchanged from the pinned Wine source. Each patch/source header controls its license; ready's GPL does not replace that permission.

GameNative, copyright its contributors, GPL-3.0: https://github.com/utkarshdalal/GameNative, revision `eaa715cf38fddfea6f8d1278c7dd89c0bb50e063`, is the architectural reference for store authentication, depots and launch coordination. The public source clone remains at `../GameNative`. Closed GameNative helpers are not included or reconstructed from binaries.

Apple Game Porting Toolkit resources, Apache-2.0: https://github.com/apple/game-porting-toolkit. Its macOS window/presentation guidance informed the Metal layer configuration. Apple's proprietary D3DMetal runtime has a different license and is excluded from our open-source distribution.

The other upstream components and exact archive hashes are listed in `sources.lock.json`. `Docs/LICENSES.md` documents distribution boundaries. Downloading a dependency for development does not automatically authorize bundling it in a release.

WineCX 11.19, dappermint/winecx, revision `9f3f6447844add700bc0dde650e4f398fd5f69ab`, provides an LGPL-2.1-or-later compatibility engine for optional local Apple evaluation. Per-file Wine/CodeWeavers notices and the pinned source archive are recorded in `Scripts/runtime_winecx_NOTICE.txt` and `Scripts/runtime_winecx.lock.json`. No Apple framework or SDK implementation is included in these sources.

Wine 11.20, copyright its Wine/CodeWeavers contributors, is LGPL-2.1-or-later. The diagnostic XInput adaptation in `Scripts/runtime_wine_xinput_capture.patch` retains upstream headers. Its native reader and ABI/protocol headers also use LGPL-2.1-or-later; ready's original tests and build orchestration use GPL-3.0-only. The frozen local diagnostic provider contains pristine and adapted corresponding source, recipes and notices. See `Docs/XINPUT_CAPTURE.md`; it is not the active runtime or a claim of whole-application distribution readiness.

The source-built dependency generation now has an approved distribution subset of 25 shared libraries/modules from 17 pinned source components, with corresponding source, recipes and notices. The original unverified bootstrap binaries remain excluded from redistribution. This subset does not approve every component or a complete application release; see `Docs/DISTRIBUTION.md` for the remaining gates. Runtime binaries remain outside this repository.

Source-only acquisition is additionally pinned by `Scripts/runtime_fetch_renderer_sources.lock.json` and `Scripts/runtime_core_sources.lock.json`. Retained source packets include upstream license texts and per-file notices, including LLVM's Apache-2.0/LLVM-exception material, Wine's LGPL and third-party notices, and separate dataset/CRT/font terms for review. These upstream files are not relicensed under ready's GPL. The corresponding provenance documents distinguish exact retained source bytes, publisher release/tag association and still-unverified historical static/binary-build inputs; source acquisition alone grants no new distribution approval.


Steam catalog artwork, icons, logos, screenshots/backgrounds and descriptive
store content are Valve or the respective publishers’ content. Ready obtains
public metadata and offered CDN URLs at runtime; it does not bundle these assets
or game binaries in this source repository. Any local runtime artwork cache is
excluded from the source distribution. This content is not relicensed under
Ready’s GPL and is not represented as open source. See [Steam’s library asset
documentation](https://partner.steamgames.com/doc/store/assets/libraryassets)
and [Steam’s Subscriber Agreement](https://store.steampowered.com/subscriber_agreement/).
The catalog UI’s use of Steam metadata does not establish a right to redistribute
third-party assets or imply Valve/publisher endorsement.
