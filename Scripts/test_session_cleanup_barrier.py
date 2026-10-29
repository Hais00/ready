#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Pure session cleanup/barrier fixture with production SessionManager methods.

Uses an isolated direct swiftc Core build; never runs SwiftPM or a game/keeper.
"""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='session-cleanup-barrier-',dir=WORK/'tests'));run.chmod(0o700)
 production=ROOT/'Sources/M1Launcher/SessionManager.swift';fixture=ROOT/'Synthetic/ReadySessionCleanupBarrierProbe.swift';before=sha(production)
 generated=run/'ProductionSessionManagerProbe.swift';generated.write_text(production.read_text()+'\n'+fixture.read_text())
 core=run/'core';core.mkdir(mode=0o700)
 env={k:v for k,v in os.environ.items()if not k.startswith(('READY_','DYLD_','Steam','STEAM'))};env['TMPDIR']=str(WORK/'tmp')+'/'
 common=['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(WORK/'cache/swift-session-cleanup')]
 commands=[[*common,'-emit-library','-static','-emit-module','-module-name','LauncherCore','-emit-module-path',str(core/'LauncherCore.swiftmodule'),*map(str,sorted((ROOT/'Sources/LauncherCore').glob('*.swift'))),'-o',str(core/'libLauncherCore.a')],
  [*common,'-I',str(core),str(generated),str(core/'libLauncherCore.a'),'-framework','AppKit','-o',str(run/'probe')]]
 for index,command in enumerate(commands):
  result=subprocess.run(command,env=env,capture_output=True,text=True,timeout=120);(run/f'build-{index}.log').write_text(result.stdout+result.stderr)
  if result.returncode:raise RuntimeError('Cleanup barrier fixture compilation failed: '+result.stderr[-6500:])
 result=subprocess.run(['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(run/'probe'),str(run)],env=env,capture_output=True,text=True,timeout=30)
 (run/'stdout.log').write_text(result.stdout);(run/'stderr.log').write_text(result.stderr)
 if result.returncode:raise RuntimeError('Cleanup barrier fixture failed: '+result.stderr[-5000:]+' Retained '+str(run))
 data=json.loads((run/'report.json').read_text());assert data['passed']and before==sha(production)
 data.update(sourceSHA256=before,fixtureSHA256=sha(fixture),retainedRoot=str(run));(run/'report.json').write_text(json.dumps(data,indent=2)+'\n')
 print(json.dumps({'passed':True,'count':data['count'],'report':str(run/'report.json'),'sourceSHA256':before},indent=2))
if __name__=='__main__':main()
