#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Verify actual PE32 Win32/D3D11 execution with isolated COW builtin bootstrap."""
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
    parser.add_argument('--keep', action='store_true')
    args = parser.parse_args()
    runtime_smoke.compile_probes()
    config = json.loads((ROOT / 'Runtime/runtime.json').read_text())
    base = Path(config['immutableRuntimeSet'])
    wine = Path(config['engineWineBinaries']['dxmtMetal'])
    provider = wine.parent.parent
    server = Path(config['engineWineServers']['dxmtMetal'])
    scratch = ROOT / 'Runtime/TestPrefixes' / ('wow64-proof-' + uuid.uuid4().hex)
    scratch.mkdir()
    marker = scratch / '.ready-synthetic-wow64-proof'; marker.write_text('Only synthetic test data\n')
    prefix = scratch / 'prefix'
    report = {'runtimeID': config['runtimeID'], 'pointerBits': 32, 'bootstrap': 'Pure Wine i386 builtins copied with APFS COW before wineboot',
              'wineWrapper': str(wine), 'windowAdapterSHA256': hashlib.sha256((provider / 'lib/wine/x86_64-unix/winemac.so').read_bytes()).hexdigest(),
              'renderer': 'DXMT i386 PE payload after wineboot, selected central Wine provider', 'steps': {}, 'verified': False,
              'shaderRasterization32Verified': False, 'gameCompatibilityVerified': False, 'directToDisplayVerified': False}
    env = dict(os.environ, WINEPREFIX=str(prefix), WINEARCH='wow64', WINEDEBUG='-all',
               WINEDLLOVERRIDES='mscoree,mshtml=d', DYLD_LIBRARY_PATH=str(base / 'vulkan') + ':' + str(base / 'dependencies'))
    try:
        subprocess.run(['/bin/cp', '-cR', str(ROOT / 'Runtime/TestPrefixes/wine-11.20'), str(prefix)], check=True)
        pure = base / 'wine/lib/wine/i386-windows'
        destination = prefix / 'drive_c/windows/syswow64'; destination.mkdir(exist_ok=True)
        if destination.is_symlink():
            raise RuntimeError('Synthetic syswow64 must be an actual directory')
        subprocess.run(['/bin/cp', '-cR', str(pure) + '/.', str(destination)], check=True)
        if (pure / 'kernel32.dll').stat().st_ino == (destination / 'kernel32.dll').stat().st_ino:
            raise RuntimeError('The bootstrap must not hard-link central files')
        boot = subprocess.run([str(base / 'wine/bin/wine'), 'wineboot', '-u'], env=env, capture_output=True, text=True, timeout=120)
        subprocess.run([str(base / 'wine/bin/wineserver'), '-k'], env=env, capture_output=True)
        report['bootExitCode'] = boot.returncode
        if boot.returncode:
            raise RuntimeError('Wineboot failed: ' + boot.stderr[-1000:])
        payloads = {}
        for architecture, directory in [('i386', 'syswow64'), ('x86_64', 'system32')]:
            for name in ('d3d10core.dll', 'd3d11.dll', 'dxgi.dll', 'winemetal.dll'):
                source = provider / 'lib/wine' / (architecture + '-windows') / name
                target = prefix / 'drive_c/windows' / directory / name
                pending = target.with_suffix('.dll.ready-pending')
                subprocess.run(['/bin/cp', '-c', str(source), str(pending)], check=True)
                os.replace(pending, target)
                payloads[architecture + '/' + name] = hashlib.sha256(source.read_bytes()).hexdigest()
        report['selectedPayloadSHA256'] = payloads
        env['WINEDLLOVERRIDES'] = 'd3d11,dxgi,d3d10core,winemetal=b;mscoree,mshtml=d'
        for name, executable, arguments in [('win32', 'runtime_windows_probe32.exe', []), ('dx11', 'runtime_windows_probe32.exe', ['dx11']), ('present', 'runtime_d3d11_present32.exe', [])]:
            env['WINEDEBUG'] = '+loaddll'; env['DYLD_PRINT_LIBRARIES'] = '1'
            start = time.monotonic()
            log_path = ROOT / 'Evidence' / ('runtime-wow64-' + name + '.log')
            try:
                with log_path.open('wb') as log:
                    result = subprocess.run([str(wine), str(ROOT / 'Runtime/Probes' / executable), *arguments], env=env, stdout=subprocess.PIPE, stderr=log, timeout=120)
                output = result.stdout.decode(errors='replace')
                observation = next(json.loads(line) for line in reversed(output.splitlines()) if line.startswith('{'))
                passed = result.returncode == 0
                if name == 'win32': passed &= observation.get('pointerBits') == 32
                elif name == 'dx11': passed &= observation.get('gpuBufferReadbackVerified') is True and int(observation.get('featureLevel', '0'), 0) >= 0xb000
                else: passed &= observation.get('presentedFrames', 0) >= 60 and int(observation.get('featureLevel', '0'), 0) >= 0xb000
                report['steps'][name] = {'exitCode': result.returncode, 'seconds': round(time.monotonic() - start, 3), 'observation': observation, 'passed': passed,
                                         'executableSHA256': hashlib.sha256((ROOT / 'Runtime/Probes' / executable).read_bytes()).hexdigest(), 'log': str(log_path)}
                print(name, json.dumps(report['steps'][name]), flush=True)
                if not passed:
                    raise RuntimeError('PE32 ' + name + ' gate failed')
            finally:
                subprocess.run([str(server), '-k'], env=env, capture_output=True, timeout=10)
        report['verified'] = True
        report['verifiedPE32APIs'] = ['win32', 'd3d11']
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        subprocess.run([str(server), '-k'], env=env, capture_output=True, timeout=10)
        if not args.keep and scratch.parent == ROOT / 'Runtime/TestPrefixes' and marker.is_file():
            shutil.rmtree(scratch)
        report['scratchRetained'] = args.keep
        (ROOT / 'Evidence/runtime-wow64-proof.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
