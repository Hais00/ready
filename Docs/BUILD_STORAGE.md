<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Build and test storage

The current development workspace uses the user-selected **Dati APFS** volume.
Large generated files live under an owned, private workspace on that volume;
project sources remain in the Git checkout. This is a local development layout,
not an application runtime location or a path required by published sources.

The checkout’s ignored `.build` entry links to the external SwiftPM build tree.
`TMPDIR`, the Clang/Swift module caches and test build outputs are also directed
to that workspace. Mount the volume before reusing this local build cache.
On another machine, ordinary `swift build` creates its own local cache.

The immutable core corresponding-source packet was copied and verified by full
membership, size, mode and SHA256 before its original duplicate was removed.
The checkout retains a stable link to it. Its source fingerprint and manifests
are unchanged. Runtime providers, game installations, profiles and user runtime
configurations were not relocated by this operation.

Production controller-policy tests require an explicit private, owned workspace
on a separate volume, with the `.ready-external-workspace` marker and private
`tmp`, `build`, `tests`, `cache` and `retained` subdirectories. For example:

```sh
python3 Scripts/test_controller_policy_e2e.py \
  --work-root '/Volumes/Dati APFS/your-owned-ready-workspace' \
  --modules '/absolute/current/Products/Release' \
  --archive '/absolute/current/Products/Release/libLauncherCore.a'
```

Use the module and real static archive from the same current Core build.
`--compile-only` records the exact sources and artifacts; `--run-only` verifies
that receipt and runs without invoking a compiler. Cross-volume prefix setup
copies real files while preserving links; it does not pretend that APFS clones
can span volumes or skip Wine initialization. Cleanup is confined to the owned
scratch prefix. Raw logs and telemetry remain on the work volume; the checkout
receives compact evidence summaries that bind the retained reports by SHA256.

The test monitors both filesystems: a 512 MiB work-volume reserve and a 256 MiB
primary-volume reserve. Preflight additionally budgets the expected copy/build
space. A reserve stop is recorded separately from a software failure, with
monotonic time, free/minimum bytes and observed initialization/process state.
