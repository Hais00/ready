#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Own real NSEvent capture/CG scroll reconstruction and production host gating."""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-scroll-',dir=WORK/'tests'));run.chmod(0o700)
 paths=[ROOT/'Sources/ReadyHostedView/ReadyHostedView.m',ROOT/'Sources/ReadyHostedView/RHGPointerState.h',ROOT/'Sources/ReadyHostedView/RHGInputMotion.h',ROOT/'Sources/ReadyHostedView/include/RHGScrollEvent.h',ROOT/'Sources/ReadyHostedView/include/ReadyHostedGameProtocol.h',ROOT/'Synthetic/ReadyHostedScrollProbe.m'];hashes={str(p.relative_to(ROOT)):sha(p)for p in paths}
 env={**os.environ,'TMPDIR':str(WORK/'tmp')+'/','CLANG_MODULE_CACHE_PATH':str(WORK/'cache/hosted-scroll-clang')}
 cmd=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-Wno-deprecated-declarations','-I',str(ROOT/'Sources/ReadyHostedView/include'),'-I',str(ROOT/'Sources/ReadyHostedView'),str(paths[-1]),'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-framework','Security','-lbsm','-o',str(run/'probe')];p=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=90);(run/'build.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError(p.stderr[-2600:])
 p=subprocess.run([str(run/'probe')],env=env,capture_output=True,text=True,timeout=12);(run/'stdout.json').write_text(p.stdout);(run/'stderr.log').write_text(p.stderr)
 if p.returncode:raise RuntimeError('Own scroll fixture failed '+str(run))
 d=json.loads(p.stdout);d['protocolVersion']=6;assert '#define RHG_VERSION 6' in (ROOT/'Sources/ReadyHostedView/include/ReadyHostedGameProtocol.h').read_text();assert d['passed'];assert hashes=={str(p.relative_to(ROOT)):sha(p)for p in paths};d['sourceHashes']=hashes;raw=run/'report.json';raw.write_text(json.dumps(d,indent=2)+'\n');out={**d,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)};(ROOT/'Evidence/hosted-scroll-tests.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
if __name__=='__main__':main()
