<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Production controller-policy E2E

All five production SessionManager cases pass on the recorded macOS 27.0.1 M1
host, using the frozen protocol 2/E6 Wine 11.20 provider and the fresh Core build.
The complete run took 97.67 seconds. It used a real cross-volume prefix copy on
the user-selected Dati APFS volume, preserved symbolic links, and copied ten
production builtins when clonefile could not span volumes. Wine initialization
was not skipped and no initialized marker was fabricated.

The cases use the same prefix and profile/game:

1. Automatic, no app-local input DLL: actual flag 1 and builtin input selection.
2. Input del gioco: actual flag 0, no input override, native gamepad menu disabled.
3. Automatic, app-local DLL: actual flag 0 and the private DLL loaded, with its
   original bytes retained and the capture reader absent from mapped images.
4. Force builtin with that same app-local DLL: flag 1, builtin selection, private
   DLL bytes retained.
5. Automatic DXMT in a separate synthetic app folder: actual D3D11 presentation,
   DXMT controller/rendering module mappings and graphics override preserved
   alongside the input override. The native winemetal.so image is observed.

The Windows executable reads the relevant environment, observes which XInput
module loaded, checks that production has no test-backend export, and presents
actual Vulkan or D3D11/Metal frames. The private DLL is a disconnected app-local
loader fixture, not a physical controller backend. The Swift harness uses real
Core policy and SessionManager, checks native overlay state and production module
mappings, and verifies keeper lease release. Every case observes 835,584 bytes of
shown overlay textures and zero hidden texture allocation. These checks establish
neither direct display nor physical controller compatibility.

All bound provider/configuration inputs are unchanged after the run. The owned
prefix was stopped and removed; raw logs, process-stage telemetry and SHA-bound
reports remain on the work volume. Compact summaries live at
`Evidence/controller-policy-e2e.json` and
`Evidence/controller-policy-e2e-build.json`. The build receipt binds exact
Swift/C sources, real static Core archive, importable module and all executables.
The compile-driver snapshot is retained separately from later run-only orchestration.

See [build/test storage](BUILD_STORAGE.md) for invocation and storage contracts.
The work-volume reserve is 512 MiB; the primary reserve is 256 MiB. Minimum free
space in this passing run was 55,035,367,424 bytes on the work volume and 4,153,282,560 bytes
on the primary volume. Telemetry records monotonic time and observed process state;
Wineboot/regedit labels require actual owned argv, while an in-process bootstrap
label requires a sampled stack. Unknown phases remain unknown.

The original disk-guard failure is preserved separately. It completed zero cases,
its session log was empty, and its initialization phase remains unknown. Its
approximately 21.8-second total runner duration includes cleanup and is not a
measurement of elapsed time at the guard. The later successful run does not
rewrite that history.

This is an actual production-provider integration test with synthetic Windows
programs. Real store games, physical devices, other input APIs and WineCX input
capture remain separate unverified requirements.
