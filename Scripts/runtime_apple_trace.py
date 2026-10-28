#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Trace a complete, optional local Apple projection in a fresh synthetic prefix.

No Apple download, license acceptance, live configuration change, or binary
modification. The complete local redist and its licenses must already exist.
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

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apple-root', type=Path, default=ROOT / 'Runtime/apple-evaluation-4.0b3')
    parser.add_argument('--timeout', type=float, default=40)
    parser.add_argument('--teb-adapter', action='store_true', help='Test the explicitly experimental public WineCX TLS hook')
    parser.add_argument('--observer-ntdll', type=Path, help='Diagnostic-only Wine ntdll; never modifies Apple files')
    parser.add_argument('--api', choices=['dx11', 'dx12'], help='Trace only this API instead of both')
    parser.add_argument('--keep', action='store_true')
    args = parser.parse_args()
    if args.teb_adapter and args.observer_ntdll:
        raise ValueError('Choose one isolated Wine diagnostic module')
    apple = args.apple_root.resolve()
    if not (apple / 'lib/external/D3DMetal.framework').is_dir() or not list(apple.glob('*License*')) + list(apple.glob('*LICENSE*')):
        raise RuntimeError('Complete optional Apple redist and its license files required')
    config = json.loads((ROOT / 'Runtime/runtime.json').read_text())
    central = Path(config['immutableRuntimeSet'])
    scratch = ROOT / 'Runtime/AppleExperiment' / ('trace-' + uuid.uuid4().hex)
    scratch.mkdir(parents=True)
    marker = scratch / '.ready-synthetic-apple-trace'; marker.write_text('Only synthetic test data\n')
    engine, prefix = scratch / 'wine', scratch / 'prefix'
    result = {'runtimeID': config['runtimeID'], 'appleOptional': True, 'tebAdapterExperimental': args.teb_adapter,
              'strictBuiltinDLLs': True, 'proprietaryDistributionEnabled': False, 'engines': {}}
    try:
        subprocess.run(['/bin/cp', '-cR', str(central / 'wine'), str(engine)], check=True)
        subprocess.run(['/bin/cp', '-cR', str(ROOT / 'Runtime/TestPrefixes/wine-11.20'), str(prefix)], check=True)
        for directory in ('x86_64-windows', 'x86_64-unix'):
            for source in (apple / 'lib/wine' / directory).iterdir():
                dest = engine / 'lib/wine' / directory / source.name
                dest.unlink(missing_ok=True)
                if source.is_symlink():
                    dest.symlink_to(os.readlink(source))
                elif source.is_file():
                    shutil.copy2(source, dest)
        subprocess.run(['/usr/bin/ditto', str(apple / 'lib/external'), str(engine / 'lib/external')], check=True)
        if args.teb_adapter:
            adapted = ROOT / 'Runtime/wine-ready-apple-adapter/ntdll.so'
            record = json.loads((ROOT / 'Evidence/runtime-apple-teb-adapter.json').read_text())
            if hashlib.sha256(adapted.read_bytes()).hexdigest() != record['moduleSHA256']:
                raise RuntimeError('Experimental adapter hash mismatch')
            shutil.copy2(adapted, engine / 'lib/wine/x86_64-unix/ntdll.so')
            result['adapter'] = record
        if args.observer_ntdll:
            observer = args.observer_ntdll.resolve()
            shutil.copy2(observer, engine / 'lib/wine/x86_64-unix/ntdll.so')
            result['diagnosticObserverSHA256'] = hashlib.sha256(observer.read_bytes()).hexdigest()
        env = dict(os.environ, WINEPREFIX=str(prefix), WINEDEBUG='+loaddll,+module,+seh',
                   WINEDLLOVERRIDES='d3d11,d3d12,d3d12core,dxgi=b;mscoree,mshtml=d',
                   DYLD_LIBRARY_PATH=str(engine / 'lib/external') + ':' + str(central / 'vulkan') + ':' + str(central / 'dependencies'),
                   DYLD_FRAMEWORK_PATH=str(engine / 'lib/external'), DYLD_PRINT_LIBRARIES='1')
        for api in ([args.api] if args.api else ['dx11', 'dx12']):
            log_path = ROOT / 'Evidence' / ('runtime-apple-trace-' + api + '.log')
            start = time.monotonic(); code = 124; output = b''
            try:
                with log_path.open('wb') as log:
                    completed = subprocess.run([str(engine / 'bin/wine'), str(ROOT / 'Runtime/Probes/runtime_windows_probe.exe'), api], env=env, stdout=subprocess.PIPE, stderr=log, timeout=args.timeout)
                    code, output = completed.returncode, completed.stdout
            except subprocess.TimeoutExpired as error:
                output = error.stdout or b''
            finally:
                subprocess.run([str(engine / 'bin/wineserver'), '-k'], env=env, capture_output=True, timeout=10)
            trace = log_path.read_text(errors='replace')
            result['engines'][api] = {'exitCode': code, 'timeout': code == 124, 'stdout': output.decode(errors='replace'),
                'seconds': round(time.monotonic() - start, 3), 'frameworkLoaded': 'D3DMetal.framework/Versions/A/D3DMetal' in trace,
                'bridgeLoaded': 'libd3dshared.dylib' in trace, 'nativeAccessViolation': 'EXCEPTION_ACCESS_VIOLATION' in trace,
                'verified': False, 'log': str(log_path)}
            print(api, json.dumps(result['engines'][api]), flush=True)
    finally:
        if not args.keep and scratch.parent == ROOT / 'Runtime/AppleExperiment' and marker.is_file():
            shutil.rmtree(scratch)
        result['scratchRetained'] = args.keep
        (ROOT / 'Evidence/runtime-apple-wine11-loader-trace.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
