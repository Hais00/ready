<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Central local runtime installation

The installer constructs a versioned central installation from the existing
verified open components. It excludes Apple evaluation files, user profiles,
Wine prefixes, games and store credentials. It does not change the frontend's
saved location or any user/project runtime configuration.

Immutable raw objects are stored once per complete content inventory. Operational
views are versioned separately and use APFS clones where available; a cross-volume
copy must budget real bytes. No full Wine engine is installed per game/profile.
Two new wrappers live in the copied Wine bin directories. Their original bytes,
source manifests and validation receipts remain retained, with an explicit delta
manifest instead of an assertion that a modified view is the frozen original.

Runtime paths and the new controller capability use the explicit relative format.
The capability codec resolves only provider Wine roots, after its raw-byte hash
check; provider equality and all payload/wrapper/alias checks remain required.
Moving an installation therefore does not rewrite its historical receipts or
silently accept an unbound provider. The source Wine binaries retain declared
old RPATHs. Actual execution with original engines and Homebrew denied is required
before publication; relative JSON alone is insufficient.

The private store holds objects, staging, transactions, installations and retained
rollback data. Each regular file is copied to a private temporary file, verified
and atomically renamed. A durable journal supports resume after interruption.
Completed versions are never overwritten. Publication renames the verified
candidate on the same volume and publishes runtime.json last. Rollback preserves
the installed data in quarantine and leaves previous versions and user pointers
alone.

```sh
python3 Scripts/runtime_install.py --store '/absolute/private/runtime-store' plan --config Runtime/runtime.json
python3 Scripts/runtime_install.py --store '/absolute/private/runtime-store' stage --transaction UUID
python3 Scripts/runtime_install.py --store '/absolute/private/runtime-store' status --transaction UUID
python3 Scripts/runtime_install.py --store '/absolute/private/runtime-store' verify --transaction UUID --runtime-proof /absolute/actual-proof.json
python3 Scripts/runtime_install.py --store '/absolute/private/runtime-store' publish --transaction UUID --verified-sha256 EXACT_RECEIPT_SHA256
python3 Scripts/runtime_install.py --store '/absolute/private/runtime-store' resume --transaction UUID
python3 Scripts/runtime_install.py --store '/absolute/private/runtime-store' rollback --transaction UUID
```

Use the transaction, plan hash and paths returned by the commands. An actual
runtime proof binds the complete candidate fingerprint, plan, native images,
observations and retained evidence hashes. Fixture/static receipts cannot
publish a production installation. Evidence is checked again at publication.
The returned location can be selected explicitly through **Libreria → Motori…**.

The local implementation currently requires the authorized private work volume.
Forty transaction checks pass, including eight actual SIGKILL boundaries, corrupt
input/evidence rejection, source-offline object reuse, configuration-last
publication and rollback. Nine layout checks cover byte-preserving derivation,
move invariance and rejected wrapper/payload/capability changes. These are small
fixtures; actual Windows/GPU integration has its own evidence and cannot be
inferred from their result.

`Scripts/test_runtime_installation.py` exercises real SessionManager policy,
profile-separated Windows file I/O on PE64/PE32, DXMT shaders/presentation,
Vulkan drivers and native ARM64 shader/readback/presentation. It uses marked
external scratch and retains separate reports. It denies the old engine roots,
Homebrew and explicitly supplied raw-object/previous-location roots, checks that
the denial is effective, and observes actual native images. The test never
publishes a runtime or selects a user's location.

This is a local installation path. Whole-runtime source/object correspondence,
exact release notice selection, clean-machine packaging and distribution approval
remain separate work. No consumer archive or proprietary Apple component is
approved or bundled by this installer. Current runtime binaries require macOS 27.
