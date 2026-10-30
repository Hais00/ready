#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Own Mach/observer fixture; synthetic drawable, no rendered frames or UI."""
import hashlib,json,os,pathlib,subprocess,tempfile,uuid
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-remote-shim-',dir=WORK/'tests'));run.chmod(0o700);shim=ROOT/'NativeEmbedding/ReadyHostedGameShim.m';fixture=ROOT/'Synthetic/ReadyHostedRemoteShimProbe.m';include=ROOT/'Sources/ReadyHostedView/include';files=[shim,fixture,*sorted(include.glob('*.h')),pathlib.Path(__file__).resolve()];before={str(p.relative_to(ROOT)):sha(p)for p in files};source=shim.read_text();marker='__attribute__((constructor))static void rhgInstall(void)';assert source.count(marker)==1
 tested=run/'under-test.m';tested.write_text(source.replace(marker,'static void rhgInstall(void)')+'\n'+fixture.read_text());binary=run/'probe';env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','RHG_','READY_','Steam','STEAM','MTL_'))};env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/hosted-remote-shim'),MTL_HUD_ENABLED='0')
 flags=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-Wno-deprecated-declarations','-I',str(include),'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-framework','CoreGraphics'];p=subprocess.run([*flags,str(tested),'-o',str(binary)],env=env,capture_output=True,text=True,timeout=90);(run/'build.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError('Remote shim fixture compile failed '+str(run)+'\n'+p.stderr[-2000:])
 cases={}
 for mode in ['default','next','getter','reuse-id','trace','trace-file','trace-freopen','trace-zero-limit','foreign','bad-reply','bad-depth','zero-limit','timeout']:
  child=dict(env,READY_HOSTED_GAME_SERVICE='local.ready.hostedgame.fixture.'+uuid.uuid4().hex,READY_HOSTED_GAME_NONCE='a1'*32)
  if mode!='default':child['READY_HOSTED_GAME_TRANSPORT']='remote-layer'
  if mode.startswith('trace'):child['RHG_REMOTE_TRACE']='1'
  expected=77 if mode in ('bad-reply','bad-depth','zero-limit','timeout','trace-zero-limit')else 0
  if mode=='trace-file':
   sink=run/'inherited-stderr.log'
   with sink.open('w')as output:p=subprocess.run([str(binary),mode],env=child,stdout=subprocess.PIPE,stderr=output,text=True,timeout=20)
   sink.chmod(0o600);p.stderr=sink.read_text()
  else:p=subprocess.run([str(binary),mode],env=child,capture_output=True,text=True,timeout=20)
  (run/(mode+'.stdout.json')).write_text(p.stdout);(run/(mode+'.stderr.log')).write_text(p.stderr)
  if p.returncode!=expected:raise RuntimeError('Remote shim '+mode+' failed '+str(run)+'\n'+p.stderr[-2000:])
  rows=[json.loads(line)for line in p.stderr.splitlines()if line.startswith('{')]
  if expected==0:cases[mode]=json.loads(p.stdout);assert cases[mode]['passed']
  else:
   failure=next(row for row in rows if row.get('type')=='hosted-shim-refused');assert failure['reason']=={'bad-reply':'host-rejected-request','bad-depth':'invalid-remote-frame-depth-ack','zero-limit':'remote-layer-no-presented-startup-frame','trace-zero-limit':'remote-layer-no-presented-startup-frame','timeout':'remote-layer-presented-startup-timeout'}[mode];cases[mode]={'passed':True,'expectedExit':77,'reason':failure['reason']}
  if mode.startswith('trace'):
   status=[row for row in rows if row['type']=='hosted-remote-trace-status'];geometry=[row for row in rows if row['type']=='hosted-remote-startup'];count=8 if mode=='trace-zero-limit'else 2
   assert len(status)==1 and status[0]['enabled']and status[0]['sinkAvailable']and status[0]['sinkCloseOnExec'];assert status[0]['sinkRegularFile']==(mode=='trace-file')
   assert len(geometry)==count and all(len(row['layerChain'])<=8 for row in geometry);assert [row['observation']for row in geometry]==list(range(1,count+1))
   forbidden={'nonce','account','username','token','ticket','characters','coordinates','pointerX','pointerY','path','contextId','surfaceID','drawableID'}
   def safe(value):
    if isinstance(value,dict):assert not(forbidden&set(value));[safe(v)for v in value.values()]
    elif isinstance(value,list):[safe(v)for v in value]
   safe(rows);assert len(p.stderr.encode())<32768;cases[mode]['boundedSafeGeometryRows']=count;cases[mode]['synchronousGeometrySurvivedExit']=mode=='trace-zero-limit';cases[mode]['geometrySurvivedStderrReplacement']=mode=='trace-freopen'
 assert before=={str(p.relative_to(ROOT)):sha(p)for p in files};report={'passed':True,'cases':cases,'sourceHashes':before,'syntheticDrawable':True,'actualRenderedFrames':0,'UIOrGameOrAccountUsed':False,'defaultTransport':'surface'};raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600);pointer={**report,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)};(ROOT/'Evidence/hosted-remote-shim-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
