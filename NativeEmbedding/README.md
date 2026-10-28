# Dedicated native Metal embedding laboratory

Read `../Docs/NATIVE_EMBEDDING.md` for measured results, limits and evidence paths.

This directory does not integrate with Ready or patch games. `run_lab.py` compiles and signs our own synthetic host/guest bundles and dylib on the private Dati workspace, and tests the actual hardened-runtime entitlement matrix by direct launch and NSWorkspace. `experiment.py` exercises separate-process IOSurface/Mach forwarding, actual drawable interception, same-process reparenting and cross-process window lookup.

Build only when the owned test applications are stopped. Fullscreen self-tests are opt-in and act on our host only. The code intentionally uses conservative CPU/GPU synchronization and a deprecated bootstrap registration helper; it is an experiment, not production transport or a catalog compatibility claim. No new third-party dependency is needed.
