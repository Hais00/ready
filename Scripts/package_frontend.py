#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Stage only ready-owned frontend code; never discover/copy external runtimes."""
import argparse
import hashlib
import json
import pathlib
import shutil

ROOT = pathlib.Path(__file__).resolve().parents[1]


def stage(destination):
    if destination.exists():
        raise RuntimeError('Frontend support destination must be new')
    destination.mkdir(parents=True)
    # Explicit source roots exclude Vendor, Runtime, Evidence, dependency checkouts,
    # caches, dotnet outputs, user data and every proprietary Apple input.
    sources = []
    source_extensions = {
        'Sources': {'.swift'}, 'Overlay': {'.m', '.h'},
        'SessionHost': {'.c', '.h'}, 'Synthetic': {'.swift', '.m', '.c'},
        'Tests': {'.swift', '.py'}, 'Docs': {'.md'},
    }
    for directory, extensions in source_extensions.items():
        sources.extend(path for path in (ROOT / directory).rglob('*')
                       if path.is_file() and path.suffix in extensions and '__pycache__' not in path.parts)
    sources.extend((ROOT / 'StoreBridge').glob('*.py'))
    sources.extend((ROOT / 'StoreBridge/SteamBridge').glob('*.cs'))
    sources.extend((ROOT / 'StoreBridge/SteamBridge').glob('*.csproj'))
    sources.extend(ROOT / name for name in (
        'LICENSE', 'LICENSES/LGPL-2.1.txt', 'THIRD_PARTY_NOTICES.md', 'README.md', 'Package.swift', 'sources.lock.json',
        'StoreBridge/NOTICE', 'StoreBridge/dependencies.lock.json',
        'Scripts/build_app.sh', 'Scripts/build_overlay.sh', 'Scripts/build_session_host.sh',
        'Scripts/package_frontend.py', 'Scripts/test_frontend_package.py',
        'Scripts/frontend_snapshot.py', 'Scripts/test_frontend_snapshot.py',
    ))
    sources.extend(ROOT / name for name in ('Build/libReadyOverlay.dylib', 'Build/ReadySessionHost'))
    inventory = []
    for path in sorted(set(sources)):
        if path.is_symlink() or not path.is_file():
            raise RuntimeError('Required owned payload is missing or a symlink: ' + str(path.relative_to(ROOT)))
        relative = path.relative_to(ROOT)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        inventory.append({'path': str(relative), 'sha256': hashlib.sha256(target.read_bytes()).hexdigest(), 'size': target.stat().st_size})
    manifest = {
        'schemaVersion': 1,
        'scope': 'ready-owned frontend support and corresponding original source',
        'license': 'GPL-3.0-only',
        'licenseScope': 'Original ready code; upstream notices and license texts retain their own terms',
        'externalRuntimeIncluded': False,
        'proprietaryAppleFilesIncluded': False,
        'wholeApplicationRedistributionApproved': False,
        'dependencyGateScope': '25 source-built shared libraries/modules only; no runtime payload is included here',
        'pythonRequirement': 'External Python 3 interpreter; no interpreter or third-party store tools bundled',
        'files': inventory,
    }
    (destination / 'frontend-package.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=pathlib.Path)
    stage(parser.parse_args().destination)
