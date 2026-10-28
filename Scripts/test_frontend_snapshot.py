#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Tiny synthetic tamper fixtures; no compiler, real snapshot minting or app publish."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
import frontend_snapshot as snapshot
ROOT = snapshot.ROOT


def main():
    checks = {}
    with tempfile.TemporaryDirectory(prefix='ready-snapshot-v2-fixture-') as raw:
        parent = Path(raw)
        baseline = parent / 'baseline'; baseline.mkdir()
        files = {'Package.swift': '// synthetic package fixture\n',
                 'Sources/LauncherCore/A.swift': '// synthetic Core fixture\n',
                 'Sources/M1Launcher/main.swift': '// synthetic App fixture\n',
                 'Overlay/Overlay.m': '// synthetic overlay fixture\n',
                 'SessionHost/Host.c': '// synthetic helper fixture\n',
                 'Scripts/build_app.sh': '# synthetic top-level build flags/recipe\n',
                 'Scripts/frontend_snapshot.py': '# synthetic snapshot validator source\n',
                 'Scripts/build_overlay.sh': '# synthetic build recipe\n',
                 'Scripts/build_session_host.sh': '# synthetic build recipe\n',
                 'Build/libReadyOverlay.dylib': 'synthetic owned fixture bytes, not native code\n',
                 'Build/ReadySessionHost': 'synthetic owned fixture bytes, not native code\n',
                 'products/M1Launcher': 'synthetic owned executable bytes, never executed\n',
                 'products/LauncherCore.swiftmodule/arm64.swiftmodule': 'synthetic compiler-module fixture\n',
                 'products/M1Launcher.swiftmodule/arm64.swiftmodule': 'synthetic compiler-module fixture\n'}
        for relative, value in files.items():
            path = baseline / relative; path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value)
        (baseline / 'products/M1Launcher').chmod(0o700)
        inputs = baseline / 'inputs.json'
        snapshot.write_new(inputs, snapshot.encoded(snapshot.capture(baseline)))
        modules = {name: baseline / 'products' / name for name in ('LauncherCore.swiftmodule', 'M1Launcher.swiftmodule')}
        produced = baseline / 'snapshot'
        snapshot.record_snapshot(baseline, inputs, baseline / 'products/M1Launcher', modules, produced, fixture=True)
        assert snapshot.verify_snapshot(baseline, produced, allow_fixture=True).name == 'M1Launcher'
        checks['completeSyntheticFingerprintAndArtifactHashesVerify'] = True
        try:
            snapshot.verify_snapshot(baseline, produced)
        except ValueError:
            checks['syntheticFixtureCannotBecomeProductionSnapshot'] = True
        else:
            raise AssertionError('Production accepted a test-only manifest')
        def negative(name, mutate):
            root = parent / name
            subprocess.run(['/bin/cp', '-cR', str(baseline), str(root)], check=True)
            mutate(root)
            try:
                snapshot.verify_snapshot(root, root / 'snapshot', allow_fixture=True)
            except (ValueError, OSError):
                checks[name] = True
                return
            raise AssertionError('Tampered snapshot accepted: ' + name)
        negative('changedAppSourceRejected', lambda root: (root / 'Sources/M1Launcher/main.swift').write_text('changed source'))
        negative('addedCoreSourceRejected', lambda root: (root / 'Sources/LauncherCore/New.swift').write_text('new source'))
        negative('changedPackageRejected', lambda root: (root / 'Package.swift').write_text('changed package/flags'))
        negative('changedTopLevelBuildRecipeRejected', lambda root: (root / 'Scripts/build_app.sh').write_text('changed compiler invocation/flags'))
        negative('changedSnapshotValidatorRejected', lambda root: (root / 'Scripts/frontend_snapshot.py').write_text('changed snapshot validator'))
        negative('changedUIBinaryRejected', lambda root: (root / 'snapshot/M1Launcher').write_text('changed synthetic binary'))
        negative('changedCompilerModuleRejected', lambda root: (root / 'snapshot/Modules/LauncherCore.swiftmodule/arm64.swiftmodule').write_text('changed module'))
        negative('unlistedArtifactRejected', lambda root: (root / 'snapshot/Modules/frontend-snapshot.json').write_text('unlisted artifact with metadata-like name'))
        negative('changedNativeSupportRejected', lambda root: (root / 'Build/ReadySessionHost').write_text('changed synthetic native support'))
        negative('changedOverlaySourceRejected', lambda root: (root / 'Overlay/Overlay.m').write_text('changed overlay source'))
        legacy = parent / 'legacy-v1'; legacy.mkdir()
        (legacy / '.ready-controller-policy-core-snapshot.json').write_text('{"sourceSHA256":{},"archiveSHA256":"v1"}')
        try:
            snapshot.verify_snapshot(baseline, legacy)
        except ValueError:
            checks['legacyV1RefusedWithoutRetroactiveAttestation'] = True
        else:
            raise AssertionError('Legacy v1 accepted')
        # Prove rejection occurs before any compiler or app publication in the
        # actual shell entrypoint. The current app and support are only read.
        fakebin = parent / 'fakebin'; fakebin.mkdir()
        invoked = parent / 'compiler-was-invoked'
        for name in ('swift', 'xcrun', 'clang'):
            path = fakebin / name
            path.write_text('#!/bin/sh\n/usr/bin/touch "' + str(invoked) + '"\nexit 99\n')
            path.chmod(0o700)
        app_binary = ROOT / 'Build/ready.app/Contents/MacOS/ready'
        before = snapshot.digest(app_binary) if app_binary.exists() else None
        env = dict(os.environ, PATH=str(fakebin) + ':' + os.environ.get('PATH', ''))
        result = subprocess.run(['/bin/sh', str(ROOT / 'Scripts/build_app.sh'), '--from-snapshot', str(legacy)],
                                cwd=ROOT, env=env, capture_output=True, text=True, timeout=20)
        assert result.returncode == 65 and not invoked.exists()
        assert (snapshot.digest(app_binary) if app_binary.exists() else None) == before
        checks['fromV1InvokesNoCompilerAndLeavesPublishedAppUnchanged'] = True
    report = {'passed': all(checks.values()), 'checks': checks,
              'scope': 'synthetic source/binary/module tamper only; no fresh v2 build or assembly executed',
              'realV2AssemblyExecuted': False, 'legacyV1Refused': True}
    # Retain the earlier twelve-check receipt unchanged.
    output = ROOT / 'Evidence/frontend-snapshot-v2-final-tests.json'
    temporary = output.with_name(output.name + '.pending')
    snapshot.write_new(temporary, snapshot.encoded(report)); os.replace(temporary, output)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
