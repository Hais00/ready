#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
import json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='native-cache-revision-',dir=WORK/'tests'));run.chmod(0o700)
 state=run/'state';state.mkdir(mode=0o700);binary=run/'probe'
 env={k:v for k,v in os.environ.items()if not k.startswith(('READY_','DYLD_','Steam','STEAM'))};env['TMPDIR']=str(WORK/'tmp')+'/'
 result=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(ROOT/'Sources/M1Launcher/SteamNativeCacheRevision.swift'),str(ROOT/'Synthetic/ReadyNativeCacheRevisionProbe.swift'),'-o',str(binary)],env=env,capture_output=True,text=True,timeout=90)
 if result.returncode:raise RuntimeError(result.stderr[-6000:])
 result=subprocess.run(['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(binary),str(state)],env=env,capture_output=True,text=True,timeout=20)
 if result.returncode:raise RuntimeError(result.stderr[-5000:])
 data=json.loads(result.stdout);assert data['passed'];(run/'report.json').write_text(json.dumps(data,indent=2)+'\n');print(json.dumps({'passed':True,'count':data['count'],'report':str(run/'report.json')}))
if __name__=='__main__':main()
