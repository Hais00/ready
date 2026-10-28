#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Freeze a tested LOCAL evaluation provider and a disabled evaluation config.

Never writes the default runtime.json. Apple binaries retain their own license;
technical success never enables consumer play or public/bundle redistribution.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'Runtime'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    default_path = RUNTIME / 'runtime.json'
    default_sha = digest(default_path)
    config = json.loads(default_path.read_text())
    source = RUNTIME / 'AppleCXExperiment/wine'
    prepared = json.loads((RUNTIME / 'AppleCXExperiment/prepared.json').read_text())
    probes = json.loads((ROOT / 'Evidence/runtime-winecx-probes.json').read_text())
    pure = Path(prepared['pureWineRoot'])
    if not probes.get('dx12Verified') or not probes.get('evaluationOnly') or probes.get('enabledForConsumerPlay') is not False:
        raise RuntimeError('Genuine GPU proof in explicit local evaluation scope is required')
    dx12 = probes['tests']['dx12']
    if dx12['exitCode'] != 0 or not any(x.get('gpuBufferReadbackVerified') and x.get('renderTargetClearReadbackVerified') and x.get('shaderRasterizationVerified') for x in dx12['observations']):
        raise RuntimeError('Actual queue, render, and shader readback proof required')
    trace = Path(dx12['log']).read_text(errors='replace')
    for relative in ['lib/external/libd3dshared.dylib', 'lib/external/D3DMetal.framework/Versions/A/D3DMetal']:
        if str(source / relative) not in trace:
            raise RuntimeError('Apple bridge/framework provenance missing from the actual probe trace')
    for name, expected in prepared['graphicsDLLSHA256'].items():
        if digest(source / 'lib/wine/x86_64-windows' / name) != expected:
            raise RuntimeError('Apple DLL differs from the prepared/tested projection: ' + name)
        if digest(Path(probes['prefix']) / 'drive_c/windows/system32' / name) != expected:
            raise RuntimeError('Test prefix differs from the projected builtin: ' + name)
    info = source / 'lib/external/D3DMetal.framework/Versions/A/Resources/Info.plist'
    with info.open('rb') as stream:
        apple_version = plistlib.load(stream)['CFBundleShortVersionString']
    license_sha = digest(source / 'License.rtf')
    policy = {'evaluationOnly': True, 'enabledForConsumerPlay': False,
              'publicRedistributionEnabled': False, 'applicationBundleInclusionEnabled': False,
              'exactAppleLicenseSHA256': license_sha, 'appleVersion': apple_version,
              'purpose': 'Synthetic development, testing, and evaluation on this Apple-branded system',
              'productDefaultEnabled': False}
    manifest = {'schema': 1, 'sourceWineCX': prepared['sourceWineCX'], 'pureWineIdentity': prepared['pureWineIdentity'],
                'policy': policy, 'verifiedAPIs': probes['verifiedAPIs'], 'files': {},
                'proofSHA256': digest(ROOT / 'Evidence/runtime-winecx-probes.json'),
                'probeExecutableSHA256': digest(RUNTIME / 'Probes/runtime_d3d12_probe.exe'),
                'probeSourceSHA256': digest(ROOT / 'Scripts/runtime_d3d12_probe.c'),
                'recipeSHA256': digest(Path(__file__).resolve())}
    for path in sorted(source.rglob('*')):
        relative = str(path.relative_to(source))
        if path.is_symlink(): manifest['files'][relative] = {'symlink': os.readlink(path)}
        elif path.is_file(): manifest['files'][relative] = {'sha256': digest(path)}
    identity = hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    provider_id = 'ready-apple-evaluation-' + identity[:20]
    target = RUNTIME / 'Providers' / provider_id
    base = Path(config['immutableRuntimeSet'])
    wrapper_text = '''#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Local development/evaluation provider. Apple's own license applies separately.
set -u
READY_WINE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
READY_BASE=''' + "'" + str(base).replace("'", "'\"'\"'") + "'" + '''
export CX_APPLEGPTK_LIBD3DSHARED_PATH="$READY_WINE_ROOT/lib/external/libd3dshared.dylib"
export DYLD_FRAMEWORK_PATH="$READY_WINE_ROOT/lib/external"
export DYLD_LIBRARY_PATH="$READY_WINE_ROOT/lib/external:$READY_BASE/vulkan:$READY_BASE/dependencies${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export DYLD_FALLBACK_LIBRARY_PATH="$DYLD_LIBRARY_PATH"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-d3d10,d3d11,d3d12,d3d12core,dxgi=b;nvapi64,nvapi,nvngx=d;mscoree,mshtml=d}"
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
        stage = target.with_name(target.name + '.staging'); stage.mkdir()
        subprocess.run(['/bin/cp', '-cR', str(source), str(stage / 'wine')], check=True)
        for name in ['LICENSE', 'COPYING.LIB']: shutil.copy2(pure.parent / name, stage / name)
        shutil.copy2(ROOT / 'Scripts/runtime_winecx_NOTICE.txt', stage / 'WineCX-NOTICE.txt')
        wrapper = stage / 'wine/bin/ready-wine'; wrapper.write_text(wrapper_text); wrapper.chmod(0o755)
        (stage / 'evaluation-manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
        stage.rename(target)
    elif json.loads((target / 'evaluation-manifest.json').read_text()) != manifest:
        raise RuntimeError('Refusing to mutate an existing immutable evaluation provider')
    wine = target / 'wine'
    config.setdefault('engineWineBinaries', {})['d3dMetal'] = str(wine / 'bin/ready-wine')
    config.setdefault('engineWineServers', {})['d3dMetal'] = str(wine / 'bin/wineserver')
    config.setdefault('engineBootstrap32Dirs', {})['d3dMetal'] = str(pure / 'lib/wine/i386-windows')
    config.setdefault('engineDLLs', {})['d3dMetal'] = str(wine / 'lib/wine/x86_64-windows')
    config.setdefault('engineOverrides', {})['d3dMetal'] = 'd3d10,d3d11,d3d12,d3d12core,dxgi=b;nvapi64,nvapi,nvngx=d;mscoree,mshtml=d'
    config.setdefault('engineSearchPaths', {})['d3dMetal'] = str(wine / 'lib/wine')
    config.setdefault('engineWineVersions', {})['d3dMetal'] = probes['reportedVersion'] + ' (WineCX)'
    config.setdefault('engineAPIs', {})['d3dMetal'] = list(probes['verifiedAPIs'])
    config.setdefault('engineArchitectures', {})['d3dMetal'] = ['x86_64']
    config.setdefault('engineProviderIDs', {})['d3dMetal'] = provider_id
    if 'd3dMetal' not in config.setdefault('verifiedEngines', []): config['verifiedEngines'].append('d3dMetal')
    config['evaluationOnlyEngines'] = ['d3dMetal']
    config['evaluationModeEnabled'] = False
    config['appleOptional'] = dict(policy, installedLocally=True, sourceOpen=False, wineABIValidated=True, enabled=False)
    config['runtimeID'] = config['runtimeID'] + '+' + provider_id
    config['evaluationCapabilityEvidence'] = {'d3dMetal': {'gpuBufferReadbackVerified': True, 'renderTargetClearReadbackVerified': True,
        'shaderRasterizationVerified': True, 'presentationVerified': False, 'directToDisplayVerified': False,
        'gameCompatibilityVerified': False, 'manifestSHA256': identity}}
    output = RUNTIME / 'evaluation-runtime.json'
    output.write_text(json.dumps(config, indent=2) + '\n')
    if digest(default_path) != default_sha:
        raise RuntimeError('The default runtime configuration changed unexpectedly')
    result = {'providerID': provider_id, 'path': str(target), 'pureWineRoot': str(pure), 'evaluationConfiguration': str(output),
              'runtimeID': config['runtimeID'], 'policy': policy, 'defaultConfigurationChanged': False,
              'verifiedAPIs': probes['verifiedAPIs'], 'consumerSelectionEnabled': False}
    (ROOT / 'Evidence/runtime-apple-frozen-evaluation.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
