#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Create a LOCAL diagnostic projection. Not an export, installer, or release gate.

Original frozen payload, wrappers, ICDs and provenance remain byte-identical.
Derived wrappers/ICDs/config live outside component trees. No activation occurs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
from runtime_dependency_inventory import binary_headers

ROOT = Path(__file__).resolve().parents[1]
PARENT = ROOT / 'Runtime/TestProjections'
MARKER = '.ready-runtime-portable-projection'
SCALARS = ('wine', 'wineServer', 'wineBoot', 'kosmicICD', 'moltenICD', 'vulkanLibrary',
           'builtin32Directory', 'wineBinary', 'kosmicNativeICD', 'immutableRuntimeSet', 'sourceDependencyPrefix')
MAPS = ('engineDLLs', 'engineDLLs32', 'engineSearchPaths', 'engineWineBinaries',
        'engineWineServers', 'engineBootstrap32Dirs', 'engineBuiltin32Dirs')


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write_private(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    with os.fdopen(descriptor, 'wb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    path.chmod(mode)


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()


def inventory(root):
    entries = {}
    for path in sorted(root.rglob('*')):
        relative = str(path.relative_to(root))
        if path.is_symlink():
            text = os.readlink(path)
            if os.path.isabs(text) or not path.resolve(strict=True).is_relative_to(root.resolve()):
                raise RuntimeError('Component symlink is not confined and relative: ' + relative)
            entries[relative] = {'symlink': text}
        elif path.is_file():
            entries[relative] = {'sha256': sha(path), 'mode': stat.S_IMODE(path.stat().st_mode), 'bytes': path.stat().st_size}
    return entries


def verify_source(tree, provider=False):
    manifest = tree / 'source-generation.json'
    value = json.loads(manifest.read_text())
    payload = tree / 'wine' if provider else tree
    expected = value['wineFiles' if provider else 'files']
    actual = inventory(payload)
    wanted = set(expected)
    extra = set(actual) - wanted - (set() if provider else {'source-generation.json'})
    if extra or wanted - set(actual):
        raise RuntimeError('Frozen component membership differs: ' + tree.name)
    for name, record in expected.items():
        for kind in ('sha256', 'symlink'):
            if kind in record and actual[name].get(kind) != record[kind]:
                raise RuntimeError('Frozen component changed: ' + name)
    return sha(manifest), actual


def source_state(configuration):
    configuration = configuration.resolve(strict=True)
    config = json.loads(configuration.read_text())
    base = Path(config['immutableRuntimeSet']).resolve(strict=True)
    dxmt = Path(config['engineWineBinaries']['dxmtMetal']).resolve(strict=True).parents[2]
    expected = '68c00b7d3878699829eb'
    if base.name != 'ready-source-runtime-' + expected or dxmt.name != 'ready-source-dxmt-' + expected:
        raise RuntimeError('This diagnostic recipe is pinned to audited generation68')
    if base.parent != ROOT / 'Runtime/Sets' or dxmt.parent != ROOT / 'Runtime/Providers':
        raise RuntimeError('Only the audited local open component roots are accepted')
    base_hash, _ = verify_source(base)
    dxmt_hash, _ = verify_source(dxmt, provider=True)
    inputs = json.loads((base / 'source-generation.json').read_text())['inputs']
    identity = hashlib.sha256(json.dumps(inputs, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    if identity != config['runtimeManifestSHA256']:
        raise RuntimeError('Source generation inputs do not match configuration identity')
    return config, {'configuration': str(configuration), 'configurationSHA256': sha(configuration),
                    'runtimeID': config['runtimeID'], 'generationInputsSHA256': identity,
                    'components': {'base': {'root': str(base), 'manifestSHA256': base_hash},
                                   'dxmt': {'root': str(dxmt), 'manifestSHA256': dxmt_hash}}}


def wrapper(component):
    return ('''#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Derived local diagnostic launcher; original component wrapper is NOT invoked.
set -eu
READY_PROJECTION_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
READY_WINE_ROOT=$(CDPATH= cd -- "$READY_PROJECTION_ROOT/components/COMPONENT/wine" && pwd -P)
READY_BASE_ROOT="$READY_PROJECTION_ROOT/components/base"
READY_DEPS="$READY_BASE_ROOT/dependency-root"
READY_WINE_BINARY="$READY_WINE_ROOT/bin/wine"
[ -f "$READY_WINE_BINARY" ] && [ -x "$READY_WINE_BINARY" ] || exit 126
export DYLD_LIBRARY_PATH="$READY_BASE_ROOT/vulkan:$READY_DEPS/lib"
export DYLD_FALLBACK_LIBRARY_PATH="$DYLD_LIBRARY_PATH"
export P11_MODULE_PATH="$READY_DEPS/lib/pkcs11"
export P11_PACKAGE_CONFIG_MODULES="$READY_DEPS/share/p11-kit/modules"
export P11_SYSTEM_CONFIG_MODULES="$READY_DEPS/etc/pkcs11/modules"
export WINESERVER="$READY_WINE_ROOT/bin/wineserver"
unset DYLD_INSERT_LIBRARIES DYLD_FRAMEWORK_PATH DYLD_FALLBACK_FRAMEWORK_PATH
if [ -n "${READY_NATIVE_AUDIT_LIBRARY:-}" ] && [ -f "$READY_NATIVE_AUDIT_LIBRARY" ]; then
  export DYLD_INSERT_LIBRARIES="$READY_NATIVE_AUDIT_LIBRARY"
fi
if [ -n "${READY_OVERLAY_LIBRARY:-}" ] && [ -f "$READY_OVERLAY_LIBRARY" ]; then
  export DYLD_INSERT_LIBRARIES="$READY_OVERLAY_LIBRARY"
fi
case "${1:-}" in --version|--help) exec "$READY_WINE_BINARY" "$@" ;; esac
if [ -z "${WINEPREFIX:-}" ]; then echo 'An explicit owned test WINEPREFIX is required' >&2; exit 64; fi
trap '"$READY_WINE_ROOT/bin/wineserver" -k >/dev/null 2>&1 || true' TERM INT HUP
"$READY_WINE_BINARY" "$@" &
READY_CHILD=$!
READY_STATUS=0
wait "$READY_CHILD" || READY_STATUS=$?
"$READY_WINE_ROOT/bin/wineserver" -w
exit "$READY_STATUS"
''').replace('COMPONENT', component).encode()


def binary_constraints(components):
    minimum = (0, 0, 0)
    by_arch = {}
    loads, rpaths = [], []
    for name, tree in components.items():
        for path in tree.rglob('*'):
            if path.is_symlink() or not path.is_file():
                continue
            header = binary_headers(path)
            for part in header.get('slices', []):
                value = part.get('buildVersion', {}).get('minimumOS')
                if value:
                    version = tuple(int(x) for x in value.split('.'))
                    minimum = max(minimum, version)
                    arch = part['architecture']
                    by_arch[arch] = max(by_arch.get(arch, (0, 0, 0)), version)
                for load in part.get('dependencies', []):
                    target = load['name']
                    if target.startswith('/') and not target.startswith(('/usr/lib/', '/System/')):
                        loads.append({'component': name, 'path': str(path.relative_to(tree)), 'load': target, 'architecture': part['architecture']})
                for value in part.get('rpaths', []):
                    if value.startswith('/') and not value.startswith(('/usr/lib/', '/System/')):
                        rpaths.append({'component': name, 'path': str(path.relative_to(tree)), 'rpath': value})
    version = lambda x: '.'.join(map(str, x))
    return {'minimumMacOS': version(minimum), 'minimumMacOSByArchitecture': {k: version(v) for k, v in by_arch.items()},
            'nonSystemAbsoluteLoads': loads, 'staleAbsoluteRpaths': rpaths,
            'blockers': ['ARM64 Kosmic depends on external Homebrew zstd/SPIRV-Tools; no full portability claim',
                         'Original Wine contains developer rpaths/fallbacks; isolated runtime proof required',
                         'No whole-runtime distribution approval; dependency gate covers only25 shared libraries/modules']}


def create_projection(name, configuration=ROOT / 'Runtime/runtime.json'):
    if not name or Path(name).name != name or name in ('.', '..'):
        raise ValueError('A new projection directory name is required')
    if PARENT.is_symlink():
        raise RuntimeError('Projection parent cannot be a symlink')
    PARENT.mkdir(parents=True, exist_ok=True, mode=0o700)
    if PARENT.stat().st_uid != os.getuid():
        raise RuntimeError('Projection parent must be owned')
    target = PARENT / name
    if target.exists() or target.is_symlink():
        raise RuntimeError('Projection destination must be new; nothing is overwritten')
    config, origin = source_state(Path(configuration))
    target.mkdir(mode=0o700)
    write_private(target / MARKER, b'Owned LOCAL diagnostic projection; not a redistributable bundle\n')
    trees = {}
    for component, record in origin['components'].items():
        source = Path(record['root'])
        destination = target / 'components' / component
        destination.parent.mkdir(exist_ok=True, mode=0o700)
        subprocess.run(['/bin/cp', '-cR', str(source), str(destination)], check=True)
        copied_hash, _ = verify_source(destination, provider=component == 'dxmt')
        if copied_hash != record['manifestSHA256']:
            raise RuntimeError('Original source-generation manifest bytes changed')
        trees[component] = destination
        write_private(target / 'launchers' / component / 'ready-wine', wrapper(component), mode=0o755)
    write_private(target / 'origin/runtime.json', Path(configuration).read_bytes())
    write_private(target / 'origin/source-state.json', json_bytes(origin))
    derived = dict(config)
    sources = [(Path(value['root']), name) for name, value in origin['components'].items()]
    def relative(value):
        path = Path(value)
        if not path.is_absolute():
            raise RuntimeError('Audited source path unexpectedly relative')
        for source, component in sources:
            if path.is_relative_to(source):
                suffix = path.relative_to(source)
                return str(Path('components') / component / suffix)
        raise RuntimeError('Operational path leaves selected open components: ' + value)
    for key in SCALARS:
        if derived.get(key) is not None:
            derived[key] = relative(derived[key])
    for key in MAPS:
        if derived.get(key) is not None:
            derived[key] = {engine: relative(value) for engine, value in derived[key].items()}
    derived['wine'] = 'launchers/base/ready-wine'
    derived['engineWineBinaries']['dxmtMetal'] = 'launchers/dxmt/ready-wine'
    for key, filename in [('kosmicICD', 'kosmic-x64'), ('kosmicNativeICD', 'kosmic-arm64'), ('moltenICD', 'molten')]:
        original = json.loads((Path(origin['components']['base']['root']) / 'icd' / (filename + '.json')).read_text())
        original['ICD']['library_path'] = '../' + relative(original['ICD']['library_path'])
        derived[key] = 'icd/' + filename + '.json'
        write_private(target / derived[key], json_bytes(original))
    derived.update(pathFormat='runtime-relative-v1', diagnosticOnly=True, binaryDistributionApproved=False,
                   evaluationModeEnabled=False)
    derived['appleOptional'] = {'installedLocally': False, 'sourceOpen': False, 'enabled': False,
                                'enabledForConsumerPlay': False, 'publicRedistributionEnabled': False}
    write_private(target / 'runtime.json', json_bytes(derived))
    constraints = binary_constraints(trees)
    manifest = {'schema': 1, 'kind': 'local-byte-preserving-runtime-projection', 'diagnosticOnly': True,
                'binaryDistributionApproved': False, 'activationPerformed': False,
                'source': origin, 'components': {k: 'components/' + k for k in trees},
                'generatedEntrypoints': ['launchers/base/ready-wine', 'launchers/dxmt/ready-wine'],
                'ICDRelativePathContract': 'VulkanLoader1.4.366: relative library_path is relative to the ICD JSON, not CWD',
                'recipeSHA256': sha(Path(__file__)), **constraints, 'files': inventory(target)}
    write_private(target / 'projection-manifest.json', json_bytes(manifest))
    verify_projection(target)
    if sha(configuration) != origin['configurationSHA256']:
        raise RuntimeError('Original configuration changed during diagnostic projection')
    return target


def verify_projection(root, verify_originals=False):
    root = Path(root).resolve(strict=True)
    if not (root / MARKER).is_file():
        raise RuntimeError('Owned diagnostic marker missing')
    doc = json.loads((root / 'projection-manifest.json').read_text())
    if doc.get('diagnosticOnly') is not True or doc.get('binaryDistributionApproved') is not False or doc.get('activationPerformed') is not False:
        raise RuntimeError('Diagnostic policy marker changed')
    actual = inventory(root)
    actual.pop('projection-manifest.json', None)
    if actual != doc['files']:
        raise RuntimeError('Projected payload/generated files changed')
    for component, relative in doc['components'].items():
        manifest_hash, _ = verify_source(root / relative, provider=component == 'dxmt')
        if manifest_hash != doc['source']['components'][component]['manifestSHA256']:
            raise RuntimeError('Component source history changed')
        if verify_originals:
            verify_source(Path(doc['source']['components'][component]['root']), provider=component == 'dxmt')
    configuration = json.loads((root / 'runtime.json').read_text())
    if configuration.get('pathFormat') != 'runtime-relative-v1':
        raise RuntimeError('Relative configuration contract missing')
    for key in SCALARS:
        if configuration.get(key) is not None:
            validate_relative(configuration[key], root)
    for key in MAPS:
        for value in configuration.get(key, {}).values():
            validate_relative(value, root)
    for path in (root / 'icd').glob('*.json'):
        library = json.loads(path.read_text())['ICD']['library_path']
        if os.path.isabs(library) or '/' not in library or not (path.parent / library).resolve(strict=True).is_relative_to(root):
            raise RuntimeError('ICD does not resolve relative to its JSON inside the projection')
    if verify_originals and sha(doc['source']['configuration']) != doc['source']['configurationSHA256']:
        raise RuntimeError('Original live runtime configuration changed')
    return doc


def validate_relative(value, root):
    if not value or value.startswith('/') or '\\' in value or '\0' in value or any(x in ('', '.', '..') for x in value.split('/')):
        raise RuntimeError('Invalid operational relative path')
    path = (root / value).resolve(strict=True)
    if not path.is_relative_to(root):
        raise RuntimeError('Operational path leaves projection root')
    return path


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--name', default='Diagnostic projection with spaces ' + uuid.uuid4().hex)
    parser.add_argument('--verify', type=Path)
    args = parser.parse_args()
    if args.verify:
        manifest = verify_projection(args.verify, verify_originals=True)
        print(json.dumps({'verified': True, 'diagnosticOnly': True, 'minimumMacOS': manifest['minimumMacOS'], 'binaryDistributionApproved': False}))
    else:
        destination = create_projection(args.name)
        print(json.dumps({'projection': str(destination), 'diagnosticOnly': True, 'binaryDistributionApproved': False}))
