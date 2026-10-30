#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Own-directory storage registry, capacity and adoption checks; no games."""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    run=pathlib.Path(tempfile.mkdtemp(prefix='storage-libraries-',dir=WORK/'tests'));run.chmod(0o700)
    core=run/'core';core.mkdir(mode=0o700)
    sources=sorted((ROOT/'Sources/LauncherCore').glob('*.swift'));probe=ROOT/'Synthetic/ReadyStorageLibraryProbe.swift';hashes={str(p.relative_to(ROOT)):sha(p)for p in [*sources,probe,pathlib.Path(__file__)]}
    env={**os.environ,'TMPDIR':str(WORK/'tmp')+'/'};base=['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(WORK/'cache/storage-libraries')]
    commands=[[*base,'-emit-library','-static','-emit-module','-module-name','LauncherCore','-emit-module-path',str(core/'LauncherCore.swiftmodule'),*map(str,sources),'-o',str(core/'libLauncherCore.a')],
      [*base,'-I',str(core),str(probe),str(core/'libLauncherCore.a'),'-o',str(run/'probe')]]
    for i,command in enumerate(commands):
      p=subprocess.run(command,env=env,capture_output=True,text=True,timeout=120);(run/f'build-{i}.log').write_text(p.stdout+p.stderr)
      if p.returncode:raise RuntimeError('Storage fixture compile failed: '+str(run/f'build-{i}.log'))
    fixture=run/'fixtures';fixture.mkdir(mode=0o700)
    p=subprocess.run([str(run/'probe'),str(fixture)],env=env,capture_output=True,text=True,timeout=25);(run/'stdout.json').write_text(p.stdout);(run/'stderr.log').write_text(p.stderr)
    if p.returncode:raise RuntimeError('Storage fixture failed: '+str(run/'stderr.log'))
    report=json.loads(p.stdout);assert report['passed'];assert all(sha(ROOT/p)==h for p,h in hashes.items())
    report.update(sourceHashes=hashes,coreRoot=str(core));raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600)
    pointer={'passed':True,'count':report['count'],'retainedReport':str(raw),'retainedReportSHA256':sha(raw),'fixtureOnly':True,'sourceHashes':{p:h for p,h in hashes.items()if 'Storage' in p},'coreRoot':str(core)}
    (ROOT/'Evidence/storage-library-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
