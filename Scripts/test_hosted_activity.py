#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Own process activity API roundtrip and actual trusted-POLL fake-focus tests. No game/UI/GPU/account."""
import hashlib,json,os,pathlib,subprocess,tempfile,uuid
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-activity-',dir=WORK/'tests'));run.chmod(0o700);shim=ROOT/'NativeEmbedding/ReadyHostedGameShim.m';fixture=ROOT/'Synthetic/ReadyHostedActivityProbe.m';source=shim.read_text();marker='__attribute__((constructor))static void rhgInstall(void)';assert source.count(marker)==1
 generated=run/'activity.m';generated.write_text(source.replace(marker,'static void rhgInstall(void)')+'\n'+fixture.read_text());binary=run/'probe';include=ROOT/'Sources/ReadyHostedView/include'
 flags=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-Wno-deprecated-declarations','-I',str(include),'-I',str(ROOT/'NativeEmbedding'),str(generated),'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-framework','CoreGraphics','-o',str(binary)]
 r=subprocess.run(flags,capture_output=True,text=True,timeout=90);(run/'build.log').write_text(r.stdout+r.stderr)
 if r.returncode:raise RuntimeError('Activity compile failed '+str(run)+' '+r.stderr[-2000:])
 env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','READY_','Steam','STEAM','RHG_','MTL_'))};env['TMPDIR']=str(WORK/'tmp')+'/'
 cases={}
 for mode,expected in [('actual',0),('focus',0),('close',0),('poll',0),('stop-return',0),('stop',77),('bad-reply',77)]:
  child={**env,'READY_HOSTED_GAME_SERVICE':'local.ready.hostedgame.fixture.'+uuid.uuid4().hex,'READY_HOSTED_GAME_NONCE':'a1'*32}
  r=subprocess.run(['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(binary),mode],env=child,capture_output=True,text=True,timeout=15);(run/(mode+'.stdout')).write_text(r.stdout);(run/(mode+'.stderr')).write_text(r.stderr)
  if r.returncode!=expected:raise RuntimeError('Activity '+mode+' failed '+str(run)+' '+r.stderr[-1800:])
  if not expected:cases[mode]=json.loads(r.stdout);assert cases[mode]['passed']
  else:
   rows=[json.loads(x)for x in r.stderr.splitlines()if x.startswith('{')];begins=sum(x.get('type')=='fixture-activity-began'for x in rows);ends=sum(x.get('type')=='fixture-activity-ended'for x in rows)
   assert (begins,ends)==((1,1)if mode=='stop'else(0,0)),rows
   cases[mode]={'passed':True,'expectedExit':77,'beginCount':begins,'endCount':ends}
 current=shim.read_text();activity=lambda s:s[s.index('// The real guest owns no visible WindowServer window.'):s.index('static NSApplicationPresentationOptions',s.index('// The real guest owns no visible WindowServer window.'))];assert activity(source)==activity(current)
 report={'passed':True,'cases':cases,'activityHelperSHA256':hashlib.sha256(activity(source).encode()).hexdigest(),'compiledShimSHA256':hashlib.sha256(source.encode()).hexdigest(),'currentShimSHA256':sha(shim),'fixtureSHA256':sha(fixture),'scriptSHA256':sha(pathlib.Path(__file__)),'actualOwnProcessActivityAPIRoundtrip':True,'actualGameAppNapOrHangCauseVerified':False,'globalPreferencesChanged':False,'networkGameGPUOrUserUIUsed':False,'report':str(run/'report.json')};(run/'report.json').write_text(json.dumps(report,indent=2)+'\n');pointer={**report,'retainedReportSHA256':sha(run/'report.json')};(ROOT/'Evidence/hosted-activity-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
