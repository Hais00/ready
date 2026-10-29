#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Production host+guest two-slot transport, actual own Metal clear/fences/readback. No game/account/user UI."""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-pipeline-',dir=WORK/'tests'));run.chmod(0o700);include=ROOT/'Sources/ReadyHostedView/include';shim=ROOT/'NativeEmbedding/ReadyHostedGameShim.m';host=ROOT/'Sources/ReadyHostedView/ReadyHostedView.m';source=shim.read_text();paths=[shim,host,include/'ReadyHostedGameProtocol.h',ROOT/'Synthetic/ReadyHostedPipelineGuest.m',ROOT/'Synthetic/ReadyHostedPipelineHost.m',pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in paths};marker='__attribute__((constructor))static void rhgInstall(void)';assert source.count(marker)==1
 guestSource=run/'guest.m';guestSource.write_text(source.replace(marker,'static void rhgInstall(void)')+'\n'+(ROOT/'Synthetic/ReadyHostedPipelineGuest.m').read_text());guest=run/'guest';harness=run/'host'
 flags=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-Wno-deprecated-declarations','-I',str(include),'-I',str(ROOT/'Sources/ReadyHostedView'),'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-framework','CoreGraphics','-lbsm']
 for name,src,out in [('guest',guestSource,guest),('host',ROOT/'Synthetic/ReadyHostedPipelineHost.m',harness)]:
  r=subprocess.run([*flags,str(src),'-o',str(out)],capture_output=True,text=True,timeout=90);(run/(name+'.build.log')).write_text(r.stdout+r.stderr)
  if r.returncode:raise RuntimeError('Pipeline compile failed '+str(run)+' '+r.stderr[-2200:])
 env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','READY_','Steam','STEAM','RHG_','MTL_'))};env['TMPDIR']=str(WORK/'tmp')+'/'
 cases={}
 for depth,mode in [(2,'positive'),(1,'positive'),(2,'stop'),(2,'callback-stop')]:
  case=run/(str(depth)+'-'+mode);case.mkdir(mode=0o700);r=subprocess.run([str(harness),str(guest),str(case),str(depth),mode],env=env,capture_output=True,text=True,timeout=35);(case/'host.stdout').write_text(r.stdout);(case/'host.stderr').write_text(r.stderr)
  if r.returncode or not(case/'report.json').exists():raise RuntimeError('Pipeline harness failed '+str(case)+' '+r.stderr[-1000:])
  result=json.loads((case/'report.json').read_text());assert not result['focusViolation'] and result['maximumSlots']<=depth and result['remainingSlots']==0,result
  if mode=='positive':
   if result['guestExit']!=0:raise RuntimeError('Pipeline guest failed '+str(case)+' '+(case/'guest.stderr').read_text()[-2000:])
   child=json.loads((case/'guest.json').read_text());assert child['passed'];expected=4 if depth==2 else 2;assert len(result['presentations'])==expected
   frames=result['presentations'];assert [f['frame']for f in frames]==list(range(expected));pixels=[[0,0,255,255],[0,255,0,255],[255,0,0,255],[0,255,255,255]];assert [f['pixel']for f in frames]==pixels[:expected],frames
   if depth==2:assert frames[0]['surface']!=frames[1]['surface']and frames[3]['generation']==frames[2]['generation']+1
   cases[str(depth)+'-'+mode]={'passed':True,'guestChecks':child['checks'],'frames':expected,'maximumSlots':result['maximumSlots'],'actualGPUClearAndCPUReadback':True}
  elif mode=='callback-stop':
   assert result['stoppedFromFirstFrameCallback']and result['guestExit']==77 and len(result['presentations'])==1;cases['callback-stop']={'passed':True,'controlledGuestExit':77,'stoppedStatusAfterFirstPresent':True,'exactOneActualPresentBeforeStop':True}
  else:
   assert result['stopDuringPendingGPU']and result['guestExit']==77 and not result['presentations'];cases['stop']={'passed':True,'controlledGuestExit':77,'pendingGPUHeldAtStop':True}
 assert before=={str(p.relative_to(ROOT)):sha(p)for p in paths}
 report={'passed':True,'sourceHashes':before,'cases':cases,'shimSHA256':sha(shim),'hostSHA256':sha(host),'protocolSHA256':sha(include/'ReadyHostedGameProtocol.h'),'ownGPUUsed':True,'readbacksInTestOnly':True,'gameAccountOrPhysicalInputUsed':False,'onScreenOrFPSClaimed':False,'privateBuildOnly':True,'report':str(run/'report.json')};(run/'report.json').write_text(json.dumps(report,indent=2)+'\n');pointer={**report,'retainedReport':str(run/'report.json'),'retainedReportSHA256':sha(run/'report.json')};(ROOT/'Evidence/hosted-pipeline-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
