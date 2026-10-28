# Third-party notices

ready's original code is GPL-3.0-only. Copyright 2026 ready contributors.

GameNative, copyright its contributors, GPL-3.0: https://github.com/utkarshdalal/GameNative, revision `eaa715cf38fddfea6f8d1278c7dd89c0bb50e063`, is the architectural reference for store authentication, depots and launch coordination. The public source clone remains at `../GameNative`. Closed GameNative helpers are not included or reconstructed from binaries.

Apple Game Porting Toolkit resources, Apache-2.0: https://github.com/apple/game-porting-toolkit. Its macOS window/presentation guidance informed the Metal layer configuration. Apple's proprietary D3DMetal runtime has a different license and is excluded from our open-source distribution.

The other upstream components and exact archive hashes are listed in `sources.lock.json`. `Docs/LICENSES.md` documents distribution boundaries. Downloading a dependency for development does not automatically authorize bundling it in a release.

WineCX 11.19, dappermint/winecx, revision `9f3f6447844add700bc0dde650e4f398fd5f69ab`, provides an LGPL-2.1-or-later compatibility engine for optional local Apple evaluation. Per-file Wine/CodeWeavers notices and the pinned source archive are recorded in `Scripts/runtime_winecx_NOTICE.txt` and `Scripts/runtime_winecx.lock.json`. No Apple framework or SDK implementation is included in these sources.

The current bootstrapped dependency binaries do not yet have a complete corresponding-source and notices mapping. They remain excluded from this repository and from redistribution; see `Docs/DISTRIBUTION.md`. Upstream source rebuilds are a separate verification gate.
