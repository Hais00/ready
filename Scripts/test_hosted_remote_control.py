#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Production remote transport/control attestation with real Mach audit and fake geometry.
No windows, GPU commands, input, screen capture, account or game.
"""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-remote-control-',dir=WORK/'tests'));run.chmod(0o700)
 source=ROOT/'Synthetic/ReadyHostedRemoteControlProbe.m';host=ROOT/'Sources/ReadyHostedView/ReadyHostedView.m';include=host.parent/'include';paths=[source,host,*sorted(include.glob('*.h')),*sorted(host.parent.glob('*.h')),pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in paths}
 env={k:v for k,v in os.environ.items()if not k.startswith(('RHG_','DYLD_','READY_','MTL_','STEAM','Steam'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/hosted-remote-control'))
 cmd=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-Wno-deprecated-declarations','-I',str(host.parent),'-I',str(include),str(source),'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-framework','CoreGraphics','-lbsm','-o',str(run/'probe')]
 p=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=60);(run/'build.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError(str(run)+' compile '+p.stderr[-2500:])
 cases={}
 for mode in ['normal','surface','stop','trace']:
  p=subprocess.run([str(run/'probe'),mode],env={**env,**({'RHG_REMOTE_TRACE':'1'}if mode=='trace'else{})},capture_output=True,text=True,timeout=18);(run/(mode+'.stdout.json')).write_text(p.stdout);(run/(mode+'.stderr.log')).write_text(p.stderr)
  if p.returncode:raise RuntimeError(str(run)+' '+mode+' probe '+p.stdout[-2000:]+p.stderr[-1000:])
  result=json.loads(p.stdout);assert result['passed'];cases[mode]=result
 assert before=={str(p.relative_to(ROOT)):sha(p)for p in paths}
 report={'passed':True,'cases':cases,'sourceHashes':before,'wireVersion':6,'wireLayoutChanged':False,'remoteOwnsNoMetalDeviceOrPool':True};raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600)
 out={**report,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)};(ROOT/'Evidence/hosted-remote-control-tests.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
if __name__=='__main__':main()
