#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Strict build-time frontend snapshots; v1/debug attestations are never upgraded.

Capture inputs BEFORE the normal build, record its coherent outputs afterwards,
then verify exact source membership/content and artifact hashes before reuse.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
NAME = 'frontend-snapshot.json'
KIND = 'ready-frontend-build-snapshot-v2'
FIXTURE = KIND + '-test-fixture-only'
SUPPORT = {'overlay': 'Build/libReadyOverlay.dylib', 'sessionHost': 'Build/ReadySessionHost',
           'hostedGameShim': 'Build/libReadyHostedGame.dylib'}


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def encoded(value):
    return (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()


def write_new(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(data); stream.flush(); os.fsync(stream.fileno())


def regular(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise ValueError('Snapshot input/artifact must be a regular file: ' + str(path))
    return info


def read_document(path):
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 4 * 1024 * 1024:
            raise ValueError('Invalid snapshot metadata')
        value = json.loads(stream.read(4 * 1024 * 1024 + 1))
    if not isinstance(value, dict):
        raise ValueError('Invalid snapshot metadata')
    return value


def source_inputs(root):
    root = Path(root).resolve(strict=True)
    paths = [root / name for name in ('Package.swift', 'Scripts/build_app.sh',
                                    'Scripts/frontend_snapshot.py', 'Scripts/build_overlay.sh',
                                    'Scripts/build_session_host.sh', 'Scripts/build_hosted_game_shim.sh',
                                    'NativeEmbedding/ReadyHostedGameShim.m')]
    for directory in ('Sources', 'Overlay', 'SessionHost'):
        base = root / directory
        if not base.is_dir() or base.is_symlink():
            raise ValueError('Required source directory missing or linked: ' + directory)
        for path in base.rglob('*'):
            if path.is_symlink():
                raise ValueError('Source symlinks are not accepted in a strict build snapshot')
            if path.is_file() and path.name != '.DS_Store':
                paths.append(path)
    for required in ('Sources/LauncherCore', 'Sources/M1Launcher', 'Sources/ReadyHostedView'):
        if not any(path.is_relative_to(root / required) for path in paths):
            raise ValueError('Core/App/hosted-view source inventory is empty')
    result = {}
    for path in sorted(set(paths)):
        regular(path)
        if path.resolve(strict=True) != path:
            raise ValueError('Source parent aliases are not accepted in a strict build snapshot')
        result[str(path.relative_to(root))] = digest(path)
    return result


def capture(root):
    files = source_inputs(root)
    return {'schemaVersion': 2, 'kind': 'ready-frontend-build-inputs-v2', 'files': files,
            'fingerprintSHA256': hashlib.sha256(encoded(files)).hexdigest()}


def validate_inputs(document, root):
    if document.get('schemaVersion') != 2 or document.get('kind') != 'ready-frontend-build-inputs-v2':
        raise ValueError('Complete build-time v2 input capture required; v1 is unsupported')
    actual = capture(root)
    if document != actual:
        raise ValueError('Exact source membership/content or Package/build recipe changed')


def tree(root):
    result = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise ValueError('Snapshot artifact symlinks are not accepted')
        if path.is_file() and path != root / NAME:
            info = regular(path)
            result[str(path.relative_to(root))] = {'sha256': digest(path), 'bytes': info.st_size,
                                                  'mode': stat.S_IMODE(info.st_mode)}
    return result


def native_signature(path, executable=False):
    info = regular(path)
    with path.open('rb') as stream:
        magic = stream.read(4)
    if magic not in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf'):
        raise ValueError('Native Mach-O artifact required')
    if executable and not info.st_mode & 0o111:
        raise ValueError('Frontend executable is not executable')
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(path)], check=True, capture_output=True)


def support_state(root, fixture=False):
    result = {}
    for name, relative in SUPPORT.items():
        path = root / relative
        regular(path)
        if not fixture:
            native_signature(path, executable=name == 'sessionHost')
        result[name] = {'path': relative, 'sha256': digest(path)}
    return result


def copy_artifact(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # External build caches may be on another volume. Select copying before
    # attempting clonefile so a partial clone cannot be mistaken for a snapshot.
    if source.stat().st_dev != destination.parent.stat().st_dev:
        if source.is_dir():
            shutil.copytree(source, destination, symlinks=True, copy_function=shutil.copy2)
        else:
            shutil.copy2(source, destination, follow_symlinks=False)
    else:
        subprocess.run(['/bin/cp', '-cR', str(source), str(destination)], check=True)


def compiler_module(products, name):
    for path in (products / name, products / 'Modules' / name):
        if path.exists() and not path.is_symlink():
            return path
    # Swift6.4/Xcode keeps the executable's module in this target's exact
    # configuration/architecture output, not in installed Products. Require a
    # unique real module; never search other configurations or stale caches.
    if name == 'M1Launcher.swiftmodule' and products.parent.name == 'Products':
        target = products.parent.parent / 'Intermediates.noindex/M1Launcher.build' / products.name / 'M1Launcher-p.build/Objects-normal'
        candidates = [p for p in target.glob('*/M1Launcher.swiftmodule') if p.is_file() and not p.is_symlink()]
        if len(candidates) == 1:
            return candidates[0]
    raise ValueError('Compiler module missing, linked, or ambiguous: ' + name)


def record_snapshot(root, inputs_file, binary, modules, destination, fixture=False):
    root = Path(root).resolve(strict=True)
    document = read_document(inputs_file)
    validate_inputs(document, root)
    if destination.exists() or destination.is_symlink():
        raise ValueError('Snapshot destination must be new')
    regular(binary)
    if not fixture:
        native_signature(binary, executable=True)
    expected_names = {'LauncherCore.swiftmodule', 'M1Launcher.swiftmodule'}
    if set(modules) != expected_names:
        raise ValueError('Both matching Core and App compiler modules are required')
    for module in modules.values():
        if module.is_symlink() or not module.exists():
            raise ValueError('Compiler module missing or linked')
    support = support_state(root, fixture=fixture)
    destination.mkdir(parents=True, mode=0o700)
    copy_artifact(binary, destination / 'M1Launcher')
    for name, module in modules.items():
        copy_artifact(module, destination / 'Modules' / name)
    copied = tree(destination)
    if copied['M1Launcher']['sha256'] != digest(binary):
        raise ValueError('Frontend binary changed while copying')
    validate_inputs(document, root)
    if support_state(root, fixture=fixture) != support:
        raise ValueError('Signed native support changed during snapshot capture')
    metadata = {'schemaVersion': 2, 'kind': FIXTURE if fixture else KIND,
                'producer': 'Scripts/build_app.sh: capture-before / successful-normal-build / record-after',
                'inputs': document, 'artifacts': copied, 'nativeSupport': support,
                'binaryDistributionApproved': False}
    write_new(destination / NAME, encoded(metadata))
    verify_snapshot(root, destination, allow_fixture=fixture)
    return destination / 'M1Launcher'


def verify_snapshot(root, snapshot, allow_fixture=False):
    root = Path(root).resolve(strict=True)
    snapshot = Path(snapshot).resolve(strict=True)
    metadata_file = snapshot / NAME
    if not metadata_file.is_file():
        raise ValueError('Build-time v2 snapshot metadata missing; legacy v1 cannot be reused')
    doc = read_document(metadata_file)
    allowed = (KIND, FIXTURE) if allow_fixture else (KIND,)
    if doc.get('schemaVersion') != 2 or doc.get('kind') not in allowed:
        raise ValueError('Only real build-time v2 snapshots are accepted for assembly')
    validate_inputs(doc.get('inputs', {}), root)
    artifacts = tree(snapshot)
    if not artifacts or artifacts != doc.get('artifacts') or 'M1Launcher' not in artifacts:
        raise ValueError('Snapshot binary/module bytes, mode, or membership changed')
    for name in ('LauncherCore.swiftmodule', 'M1Launcher.swiftmodule'):
        if not any(value == 'Modules/' + name or value.startswith('Modules/' + name + '/') for value in artifacts):
            raise ValueError('Required matching compiler module is absent')
    fixture = doc['kind'] == FIXTURE
    if not fixture:
        native_signature(snapshot / 'M1Launcher', executable=True)
    if support_state(root, fixture=fixture) != doc.get('nativeSupport'):
        raise ValueError('Current signed native support differs from captured snapshot')
    return snapshot / 'M1Launcher'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    before = commands.add_parser('capture-inputs')
    before.add_argument('--output', type=Path, required=True)
    after = commands.add_parser('record')
    after.add_argument('--inputs', type=Path, required=True)
    after.add_argument('--products', type=Path, required=True)
    after.add_argument('--destination', type=Path, required=True)
    verify = commands.add_parser('verify')
    verify.add_argument('snapshot', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'capture-inputs':
            write_new(args.output, encoded(capture(ROOT)))
        elif args.command == 'record':
            products = args.products.resolve(strict=True)
            modules = {}
            for name in ('LauncherCore.swiftmodule', 'M1Launcher.swiftmodule'):
                modules[name] = compiler_module(products, name)
            print(record_snapshot(ROOT, args.inputs, products / 'M1Launcher', modules, args.destination))
        else:
            print(verify_snapshot(ROOT, args.snapshot))
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print('Frontend snapshot refused: ' + str(error), file=sys.stderr)
        raise SystemExit(65)
