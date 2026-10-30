#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Own console-provider/diagnostic sink fixtures against actual host source.

No real NSWindow, GPU, account, game, screen capture or physical input.
"""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-hotpath-',dir=WORK/'tests'));run.chmod(0o700)
 source=ROOT/'Synthetic/ReadyHostedHotPathProbe.m';host=ROOT/'Sources/ReadyHostedView/ReadyHostedView.m';include=ROOT/'Sources/ReadyHostedView/include'
 paths=[source,host,*sorted(include.glob('*.h')),*sorted(host.parent.glob('*.h')),pathlib.Path(__file__).resolve()]
 before={str(p.relative_to(ROOT)):sha(p)for p in paths}
 env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','RHG_','READY_','STEAM','Steam','MTL_'))}
 env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/hosted-hotpath'))
 command=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-Wno-deprecated-declarations','-I',str(include),'-I',str(ROOT/'Sources/ReadyHostedView'),str(source),'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-framework','CoreGraphics','-lbsm','-o',str(run/'probe')]
 p=subprocess.run(command,env=env,capture_output=True,text=True,timeout=90);(run/'build.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError('Own hot-path fixture compile failed '+str(run)+'\n'+p.stderr[-2000:])
 p=subprocess.run([str(run/'probe'),str(run)],env=env,capture_output=True,text=True,timeout=10);(run/'stdout.json').write_text(p.stdout);(run/'stderr.log').write_text(p.stderr)
 if p.returncode:raise RuntimeError('Own hot-path fixture failed '+str(run)+'\n'+p.stderr[-1000:])
 d=json.loads(p.stdout);assert d['passed'];assert before=={str(p.relative_to(ROOT)):sha(p)for p in paths};d['sourceHashes']=before
 raw=run/'report.json';raw.write_text(json.dumps(d,indent=2)+'\n');raw.chmod(0o600)
 out={**d,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)}
 (ROOT/'Evidence/hosted-hotpath-tests.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
if __name__=='__main__':main()
