#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Development-only round trip through real open Wine and optional local Apple SDK.

Requires already-provisioned evaluation-runtime.json and our Windows probes.
Evaluation is enabled ONLY in a private synthetic application-data root. Neither
project runtime configuration nor consumer defaults are changed. No Apple library
is downloaded or redistributed by this test.
"""
import fcntl, json, os, pathlib, shutil, subprocess, time, uuid
from swift_probe_support import prepare_core

ROOT = pathlib.Path(__file__).resolve().parents[1]

def cleanup(scratch, remove=True):
    manifest = scratch/'cleanup.json'
    if manifest.exists():
        data = json.loads(manifest.read_text())
        for value in data['prefixes']:
            prefix = pathlib.Path(value)
            assert prefix.is_relative_to(scratch/'data/Prefixes')
            for value in data['servers']:
                server = pathlib.Path(value)
                assert server.is_absolute() and server.is_relative_to(ROOT/'Runtime') and server.is_file()
                env = {k:v for k,v in os.environ.items() if not k.startswith(('WINE','DYLD_','READY_','M1L_'))}
                env.update(WINEPREFIX=str(prefix),WINEDEBUG='-all')
                subprocess.run([str(server),'-k'],env=env,capture_output=True,timeout=10)
                subprocess.run([str(server),'-w'],env=env,capture_output=True,timeout=15)
    deadline=time.monotonic()+10
    while True:
        busy=False
        for path in (scratch/'data/Locks').glob('*.lock'):
            with path.open('a+b') as handle:
                try: fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
                except BlockingIOError: busy=True
        if not busy: break
        if time.monotonic()>deadline: raise RuntimeError('Retaining scratch while its native keeper owns a lease')
        time.sleep(.1)
    assert scratch.parent==ROOT/'Runtime/TestPrefixes' and (scratch/'.ready-provider-switch').is_file()
    if remove: shutil.rmtree(scratch)

def main():
    assert (ROOT/'Runtime/evaluation-runtime.json').is_file(), 'Provision optional local SDK before this development-only test'
    assert shutil.disk_usage(ROOT).free>1_500_000_000, 'Not enough space for two fresh synthetic prefixes'
    subprocess.run(['swift','build','--product','M1Launcher','--jobs','2'],cwd=ROOT,check=True,capture_output=True)
    subprocess.run(['sh',str(ROOT/'Scripts/build_session_host.sh')],cwd=ROOT,check=True,capture_output=True)
    directory,modules,archive=prepare_core()
    command=['xcrun','swiftc','-swift-version','5','-parse-as-library','-I',str(modules),str(ROOT/'Sources/M1Launcher/SessionManager.swift'),str(ROOT/'Synthetic/ReadyProviderSwitchProbe.swift')]
    command+=[str(archive)]
    executable=ROOT/'Build/ReadyProviderSwitchProbe'
    command+=['-framework','AppKit','-o',str(executable)]
    subprocess.run(command,cwd=ROOT,check=True,capture_output=True)
    scratch=ROOT/'Runtime/TestPrefixes'/('provider-switch-'+uuid.uuid4().hex)
    scratch.mkdir(parents=True,mode=0o700)
    (scratch/'.ready-provider-switch').write_text('Disposable synthetic provider-switch fixture\n')
    passed=False
    try:
        env={k:v for k,v in os.environ.items() if not k.startswith(('WINE','DYLD_','READY_','M1L_'))}
        result=subprocess.run([str(executable),str(ROOT),str(scratch)],cwd=ROOT,env=env,capture_output=True,text=True,timeout=300)
        (ROOT/'Evidence/provider-switch.log').write_text(result.stdout+'\n'+result.stderr)
        (ROOT/'Evidence/provider-switch-process.json').write_text(json.dumps({'returncode':result.returncode,'scratch':str(scratch)},indent=2)+'\n')
        assert result.returncode==0, 'Provider switch failed; inspect the ignored private log'
        report=json.loads(result.stdout)
        assert report['passed'] and report['evaluationOnly'] and not report['consumerPlayEnabled']
        (ROOT/'Evidence/provider-switch.json').write_text(json.dumps(report,indent=2)+'\n')
        passed=True
        print(json.dumps(report,indent=2))
    finally:
        cleanup(scratch, remove=passed)

if __name__=='__main__': main()
