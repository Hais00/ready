# Distribution policy

Our original launcher, overlay, and synthetic test code are GPL-3.0-only. `LICENSE` contains the full license. GameNative architecture is a reference; any translated or copied implementation must preserve its GPL notices and attribution. Its closed helpers are not incorporated.

| Component | License / distribution treatment |
| --- | --- |
| Wine | LGPL-2.1-or-later; source archive pinned in sources.lock.json |
| DXVK | zlib; retain upstream license |
| DXMT current development source | LGPL-2.1-or-later; unchanged source and official development artifact pinned separately in DXMTIntegration/dxmt.lock.json; old release license must not be assumed for current main |
| VKD3D-Proton | LGPL-2.1; retain license and corresponding source |
| Mesa / KosmicKrisp | inspect per-file MIT/BSD notices; retain upstream licensing files |
| MoltenVK | Apache-2.0 and third-party notices |
| SteamKit | LGPL-2.1-only; retain its exact corresponding source and notices |
| GameNative | GPL-3.0; reference source lives outside this repository |
| Apple GPTK sample resources | Apache-2.0; independent of proprietary runtime |
| Apple D3DMetal and evaluation redist | proprietary, NOT open source; local optional input, excluded from public source/binary release |
| Valve Steam client / Steamworks SDK / Proton lsteamclient | not covered by our GPL; do not copy or relabel as free source; any legitimate external client integration stays an explicit optional runtime boundary |

The downloaded evaluation 4.0 beta 3 license explicitly permits certain **non-commercial** redistribution in sections 2A/2C, but that is not an open-source license. The launcher must not impose Apple's non-commercial restriction on its GPL code. Keep Apple's files separate and do not claim the complete optional Apple rendering stack is open source. The public distribution must be usable without it.

Before release: generate source/binary inventory; verify each actual shipped file's license; provide exact corresponding source and modifications for copyleft dependencies; omit credentials, downloaded games, store assets, proprietary runtimes, private logs, build caches, and vendor binaries lacking a redistribution grant. No release has been published yet.

The experimental native remote-layer transport contains our GPL SPI bindings only. `CAContext` and `CALayerHost` are proprietary system framework implementations supplied by macOS; neither their implementation nor Apple private headers are bundled. The API pattern was researched in [WebKit](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/Platform/cocoa/LayerHostingContext.mm); no WebKit implementation is vendored. Private interfaces have no cross-version stability guarantee; this is an experimental runtime dependency, not an open-source Apple component.
