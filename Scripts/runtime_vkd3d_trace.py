#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Trace strict native VKD3D against a real ICD in a disposable synthetic prefix.

Default DXGI is Wine's builtin, so DXVK's independent D3D11 adapter filter does
not hide VKD3D's own requirements. No feature-level/capability override is used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import uuid

import runtime_smoke
ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--icd', choices=['kosmic', 'molten'], default='kosmic')
    parser.add_argument('--native-dxgi', action='store_true')
    parser.add_argument('--observer-ntdll', type=Path)
    parser.add_argument('--keep', action='store_true')
    parser.add_argument('--timeout', type=float, default=90)
    args = parser.parse_args()
    runtime_smoke.compile_d3d12_probe()
    config = json.loads((ROOT / 'Runtime/runtime.json').read_text())
    base = Path(config['immutableRuntimeSet'])
    parent = ROOT / 'Runtime/Vkd3DRequirementExperiment'; parent.mkdir(exist_ok=True)
    scratch = parent / ('run-' + uuid.uuid4().hex); scratch.mkdir()
    marker = scratch / '.ready-synthetic-vkd3d'; marker.write_text('Only synthetic GPU probes\n')
    prefix = scratch / 'prefix'; wine = base / 'wine'
    report = {'runtimeID': config['runtimeID'], 'icd': args.icd, 'nativeDLLOnly': True,
              'dxgiBuiltin': not args.native_dxgi, 'hardwareFeatureOverrides': False, 'dx12Verified': False}
    env = dict(os.environ)
    env.pop('VKD3D_FEATURE_LEVEL', None)
    env.pop('VKD3D_CONFIG', None)
    env.update(WINEPREFIX=str(prefix), WINEDEBUG='+loaddll,+seh', VKD3D_DEBUG='trace',
               WINEDLLOVERRIDES='d3d12,d3d12core=n;dxgi=' + ('n' if args.native_dxgi else 'b') + ';mscoree,mshtml=d',
               DYLD_LIBRARY_PATH=str(base / 'vulkan') + ':' + str(base / 'dependencies'),
               VK_DRIVER_FILES=config['kosmicICD'] if args.icd == 'kosmic' else config['moltenICD'],
               VKD3D_SHADER_CACHE_PATH=str(prefix / 'vkd3d-cache'))
    env['VK_ICD_FILENAMES'] = env['VK_DRIVER_FILES']
    try:
        subprocess.run(['/bin/cp', '-cR', str(ROOT / 'Runtime/TestPrefixes/wine-11.20'), str(prefix)], check=True)
        if args.observer_ntdll:
            subprocess.run(['/bin/cp', '-cR', str(wine), str(scratch / 'wine')], check=True)
            wine = scratch / 'wine'; observer = args.observer_ntdll.resolve()
            shutil.copy2(observer, wine / 'lib/wine/x86_64-unix/ntdll.so')
            report['diagnosticObserverSHA256'] = hashlib.sha256(observer.read_bytes()).hexdigest()
        payloads = {'d3d12.dll': base / 'vkd3d/d3d12.dll', 'd3d12core.dll': base / 'vkd3d/d3d12core.dll'}
        if args.native_dxgi: payloads['dxgi.dll'] = base / 'dxvk/dxgi.dll'
        report['payloadSHA256'] = {}
        for name, source in payloads.items():
            target = prefix / 'drive_c/windows/system32' / name
            target.unlink(missing_ok=True)
            subprocess.run(['/bin/cp', '-c', str(source), str(target)], check=True)
            report['payloadSHA256'][name] = hashlib.sha256(source.read_bytes()).hexdigest()
        log = ROOT / 'Evidence/runtime-vkd3d-requirements.log'
        started = time.monotonic()
        try:
            with log.open('wb') as stream:
                result = subprocess.run([str(wine / 'bin/wine'), str(ROOT / 'Runtime/Probes/runtime_d3d12_probe.exe')], env=env, stdout=subprocess.PIPE, stderr=stream, timeout=args.timeout)
            report.update(exitCode=result.returncode, stdout=result.stdout.decode(errors='replace'))
        except subprocess.TimeoutExpired as error:
            report.update(exitCode=124, timeout=True, stdout=(error.stdout or b'').decode(errors='replace'))
        report['seconds'] = round(time.monotonic() - started, 3)
        report['log'] = str(log)
        observations = []
        for line in report.get('stdout', '').splitlines():
            try: observations.append(json.loads(line))
            except ValueError: pass
        report['dx12Verified'] = report.get('exitCode') == 0 and any(x.get('shaderRasterizationVerified') is True and x.get('gpuBufferReadbackVerified') is True for x in observations)
        print(json.dumps(report, indent=2))
    finally:
        subprocess.run([str(wine / 'bin/wineserver'), '-k'], env=env, capture_output=True, timeout=10)
        if not args.keep and scratch.parent == parent and marker.is_file(): shutil.rmtree(scratch)
        report['scratchRetained'] = args.keep
        (ROOT / 'Evidence/runtime-vkd3d-requirements.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
