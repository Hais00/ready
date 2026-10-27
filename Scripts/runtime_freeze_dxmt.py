#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Freeze the verified open DXMT/Wine provider without replacing an active Wine.

The engine's builtin PE/Unix libraries must live in its actual Wine tree. Merely
appending WINEDLLPATH cannot override Wine's preferred builtin directory.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'Runtime'
SOURCE = RUNTIME / 'DXMTExperiment/wine-latest'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    config = json.loads((RUNTIME / 'runtime.json').read_text())
    base = Path(config['immutableRuntimeSet'])
    lock = json.loads((ROOT / 'DXMTIntegration/dxmt.lock.json').read_text())
    adapter = json.loads((ROOT / 'Evidence/runtime-dxmt-window-adapter.json').read_text())
    if digest(SOURCE / 'lib/wine/x86_64-unix/winemac.so') != adapter['moduleSHA256']:
        raise RuntimeError('The tested Wine window adapter differs from the provider')
    for name, sha in lock['selectedPayloadFiles'].items():
        candidate = SOURCE / 'lib/wine' / name
        if not candidate.is_file() or digest(candidate) != sha:
            raise RuntimeError('Provider DXMT payload differs from pinned artifact: ' + name)
    device = json.loads((ROOT / 'Evidence/dxmt-device-result.json').read_text())
    shader = json.loads((ROOT / 'Evidence/dxmt-shader-result.json').read_text())
    present = json.loads((ROOT / 'Evidence/runtime-dxmt-present.json').read_text())
    observation = json.loads(present['stdout'].strip())
    if not device['passed'] or not shader['passed'] or present['exitCode'] != 0 or observation['presentedFrames'] < 60 or int(observation['featureLevel'], 0) < 0xb000 or present.get('windowAdapterSHA256') != adapter['moduleSHA256']:
        raise RuntimeError('Real device, shader rasterization, and presentation gates required')
    native32 = {}
    for path in sorted((RUNTIME / 'dxvk-3.1.1/x32').glob('*.dll')):
        native32['dxvk/' + path.name] = path
    for path in sorted((RUNTIME / 'vkd3d-proton-3.0.1/x86').glob('*.dll')):
        native32['vkd3d/' + path.name] = path
    if 'dxvk/dxgi.dll' in native32:
        native32['vkd3d/dxgi.dll'] = native32['dxvk/dxgi.dll']
    wow64_path = ROOT / 'Evidence/runtime-wow64-proof.json'
    wow64 = json.loads(wow64_path.read_text()) if wow64_path.exists() else {}
    verified32 = wow64.get('verified') is True and all(wow64.get('selectedPayloadSHA256', {}).get(name.replace('i386-windows/', 'i386/')) == sha for name, sha in lock['selectedPayloadFiles'].items() if name.startswith('i386-windows/'))
    manifest = {'format': 1, 'wineVersion': 'wine-11.20', 'dxmtSourceCommit': lock['sourceCommit'],
                'windowAdapter': adapter, 'baseRuntimeSet': str(base),
                'recipeSHA256': digest(Path(__file__).resolve()), 'files': {},
                'verifiedAPIs': ['d3d11'], 'shaderRasterizationVerified': True,
                'presentationVerified': True, 'directToDisplayVerified': False,
                'gameCompatibilityVerified': False, 'proprietaryFilesIncluded': False,
                'native32Files': {name: digest(path) for name, path in native32.items()},
                'verifiedArchitectures': ['x86_64', 'i386'] if verified32 else ['x86_64']}
    for path in sorted(SOURCE.rglob('*')):
        relative = str(path.relative_to(SOURCE))
        if path.is_symlink():
            manifest['files'][relative] = {'symlink': os.readlink(path)}
        elif path.is_file():
            manifest['files'][relative] = {'sha256': digest(path)}
    # Reusing stale successful probes with unrelated Wine core binaries is not
    # sufficient. The provider is exactly the tested base plus the pinned DXMT
    # payload, explicit window adapter, and its preparation record.
    allowed_changes = {'dxmt-prepared.json', 'lib/wine/x86_64-unix/winemac.so'}
    allowed_changes.update('lib/wine/' + name for name in lock['selectedPayloadFiles'])
    for path in sorted((base / 'wine').rglob('*')):
        relative = str(path.relative_to(base / 'wine'))
        if relative in allowed_changes or relative == 'bin/ready-wine' or path.is_dir():
            continue
        candidate = SOURCE / relative
        if path.is_symlink():
            if not candidate.is_symlink() or os.readlink(candidate) != os.readlink(path):
                raise RuntimeError('Wine base symlink differs from the tested immutable base: ' + relative)
        elif not candidate.is_file() or digest(path) != manifest['files'].get(relative, {}).get('sha256'):
            raise RuntimeError('Wine core differs from the tested immutable base: ' + relative)
    identity = hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    provider_id = 'ready-dxmt-' + identity[:20]
    providers = RUNTIME / 'Providers'; providers.mkdir(exist_ok=True)
    target = providers / provider_id
    wrapper_text = '''#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -u
READY_WINE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
READY_BASE=''' + "'" + str(base).replace("'", "'\"'\"'") + "'" + '''
export DYLD_LIBRARY_PATH="$READY_BASE/vulkan:$READY_BASE/dependencies${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export DYLD_FALLBACK_LIBRARY_PATH="$DYLD_LIBRARY_PATH"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-d3d11,dxgi,d3d10core,winemetal=b}"
if [ -n "${READY_OVERLAY_LIBRARY:-}" ] && [ -f "$READY_OVERLAY_LIBRARY" ]; then
  export DYLD_INSERT_LIBRARIES="$READY_OVERLAY_LIBRARY"
fi
case "${1:-}" in --version|--help) exec "$READY_WINE_ROOT/bin/wine" "$@" ;; esac
if [ -z "${WINEPREFIX:-}" ]; then echo 'An explicit per-game/per-profile WINEPREFIX is required' >&2; exit 64; fi
trap '"$READY_WINE_ROOT/bin/wineserver" -k >/dev/null 2>&1 || true' TERM INT HUP
"$READY_WINE_ROOT/bin/wine" "$@" &
READY_CHILD=$!
wait "$READY_CHILD"
READY_STATUS=$?
"$READY_WINE_ROOT/bin/wineserver" -w
exit "$READY_STATUS"
'''
    if not target.exists():
        temporary = providers / (provider_id + '.staging')
        temporary.mkdir()
        subprocess.run(['/bin/cp', '-cR', str(SOURCE), str(temporary / 'wine')], check=True)
        for name, source in native32.items():
            destination = temporary / 'native32' / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['/bin/cp', '-c', str(source), str(destination)], check=True)
        wrapper = temporary / 'wine/bin/ready-wine'
        wrapper.write_text(wrapper_text); wrapper.chmod(0o755)
        (temporary / 'provider-manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
        temporary.rename(target)
    elif json.loads((target / 'provider-manifest.json').read_text()) != manifest or (target / 'wine/bin/ready-wine').read_text() != wrapper_text:
        raise RuntimeError('Refusing to mutate an existing immutable provider')
    config.setdefault('engineWineBinaries', {})['dxmtMetal'] = str(target / 'wine/bin/ready-wine')
    config.setdefault('engineWineServers', {})['dxmtMetal'] = str(target / 'wine/bin/wineserver')
    config.setdefault('engineOverrides', {})['dxmtMetal'] = 'd3d11,dxgi,d3d10core,winemetal=b'
    config.setdefault('engineSearchPaths', {})['dxmtMetal'] = str(target / 'wine/lib/wine')
    config.setdefault('engineDLLs', {})['dxmtMetal'] = str(target / 'wine/lib/wine/x86_64-windows')
    config['builtin32Directory'] = str(base / 'wine/lib/wine/i386-windows')
    config.setdefault('engineDLLs32', {})['dxmtMetal'] = str(target / 'wine/lib/wine/i386-windows')
    if 'dxvk/d3d11.dll' in native32 and 'dxvk/dxgi.dll' in native32:
        for engine in ['dxvkKosmic', 'dxvkMolten']:
            config['engineDLLs32'][engine] = str(target / 'native32/dxvk')
    if all(name in native32 for name in ['vkd3d/d3d12.dll', 'vkd3d/d3d12core.dll', 'vkd3d/dxgi.dll']):
        config['engineDLLs32']['vkd3dKosmic'] = str(target / 'native32/vkd3d')
    config['engineBuiltin32Dirs'] = dict(config['engineDLLs32'])
    config.setdefault('engineArchitectures', {})['dxmtMetal'] = manifest['verifiedArchitectures']
    config.setdefault('engineAPIs', {})['dxmtMetal'] = ['d3d11']
    config.setdefault('engineProviderIDs', {})['dxmtMetal'] = provider_id
    if 'dxmtMetal' not in config.setdefault('verifiedEngines', []):
        config['verifiedEngines'].append('dxmtMetal')
    config.setdefault('componentVersions', {})['dxmt'] = lock['sourceCommit']
    config['runtimeID'] = base.name + '+' + provider_id
    pending = RUNTIME / 'runtime.json.pending'
    pending.write_text(json.dumps(config, indent=2) + '\n'); os.replace(pending, RUNTIME / 'runtime.json')
    result = {'providerID': provider_id, 'path': str(target), 'runtimeID': config['runtimeID'],
              'verifiedAPIs': ['d3d11'], 'presentationVerified': True, 'directToDisplayVerified': False,
              'gameCompatibilityVerified': False, 'proprietaryAppleFilesExcluded': True,
              'verifiedArchitectures': manifest['verifiedArchitectures'],
              'native32PayloadPresenceMeansCompatibility': False}
    (ROOT / 'Evidence/runtime-dxmt-frozen.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
