#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real stopped-host resource owner + owned child exits; no game/window/GPU work."""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-retirement-',dir=WORK/'tests'));run.chmod(0o700)
 files=[ROOT/'Sources/ReadyHostedView/ReadyHostedView.m',*sorted((ROOT/'Sources/ReadyHostedView/include').glob('*.h')),ROOT/'Sources/ReadyHostedView/RHGPointerState.h',ROOT/'Synthetic/ReadyHostedRetirementProbe.m',pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in files}
 env={**os.environ,'TMPDIR':str(WORK/'tmp')+'/','CLANG_MODULE_CACHE_PATH':str(WORK/'cache/hosted-retirement')}
 cmd=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-Wno-deprecated-declarations','-I',str(ROOT/'Sources/ReadyHostedView/include'),str(files[-2]),'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-lbsm','-o',str(run/'probe')]
 r=subprocess.run(cmd,cwd=ROOT,env=env,capture_output=True,text=True,timeout=120);(run/'compile.log').write_text(r.stdout+r.stderr)
 if r.returncode:raise RuntimeError('Retirement compile failed: '+str(run/'compile.log'))
 r=subprocess.run([str(run/'probe')],env=env,capture_output=True,text=True,timeout=20);(run/'stdout.json').write_text(r.stdout);(run/'stderr.log').write_text(r.stderr)
 if r.returncode:raise RuntimeError('Retirement fixture failed: '+str(run))
 report=json.loads(r.stdout);assert report['passed'];assert before=={str(p.relative_to(ROOT)):sha(p)for p in files};report['sourceHashes']=before
 raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600)
 pointer={'passed':True,'count':report['count'],'retainedReport':str(raw),'retainedReportSHA256':sha(raw),'sourceHashes':before,'gameAccountWindowOrGPUWorkUsed':False}
 (ROOT/'Evidence/hosted-retirement-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
