<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Production controller-policy E2E — pending space

The production SessionManager harness and freestanding Windows probes compile.
The five-case production-policy run has not completed. Its first live attempt
was stopped by the 512 MiB disk reserve before any case completed; no Core policy
failure is established. The approximately21.8-second runner wall duration includes
cleanup. The old runner did not record monotonic elapsed/free bytes at the guard,
and its sole retained session log is empty, so the exact initialization phase and
whether Wine had started remain unknown. The owned prefix was stopped and removed.
No default, candidate configuration or frozen provider was changed.

The prepared cases use one initialized COW prefix and one profile/game:

1. Automatic, no app-local input DLL: actual flag1 and builtin input override.
2. Input del gioco: actual flag0, no input override, native gamepad menu disabled.
3. Automatic, app-local DLL: bypass with original bytes retained.
4. Force builtin with that same app-local DLL: flag1, builtin selection, bytes retained.
5. Automatic DXMT in a separate synthetic app folder on the same prefix: real D3D11
   presenter, DXMT controller/rendering module mappings and graphics override
   preserved alongside the appended input override.

The Windows executable reads only the relevant environment variables, observes
which XInput module was loaded, checks that production has no test-backend export,
and presents actual Vulkan or D3D11/Metal frames. The private DLL is a disconnected
app-local fixture with a marker, not a synthetic physical controller backend.
The Swift harness uses the real Core policy and SessionManager, checks actual
native overlay state, production module mappings, unchanged app DLL bytes and
keeper lease release. Hardware input remains unverified.

`Evidence/controller-policy-e2e-build.json` binds the already compiled Core snapshot,
Swift/C sources and all binaries. Its original compile-driver source is preserved
under `Build/ControllerPolicyE2EInputs`; the later run-only orchestration has a
separate hash and does not claim to have compiled those executables.

After sufficient space is available, the prepared invocation is:

```sh
python3 Scripts/test_controller_policy_e2e.py \
  --modules Build/ControllerPolicyE6CoreSnapshot \
  --archive Build/ControllerPolicyE6CoreSnapshot/libLauncherCore.a \
  --run-only
```

Run-only verifies the existing binaries, Core module/archive and unchanged compiled
source inputs. It invokes no compiler. Future guard telemetry records monotonic
elapsed time, free/minimum-free bytes, exact owned process/ReadySessionHost argv,
markers and completed-case progress every second. Wineboot and regedit are labeled
only from actual owned child/host arguments. An in-process bootstrap label requires
an actual available sampled harness stack; otherwise the phase stays unresolved.
The newly prepared telemetry and stack sampling have not been executed yet.

The retry is on hold pending additional space. No source/runtime rebuild,
activation, physical-controller claim or production-policy success follows from
the successful compile or the separate synthetic XInput API tests.
