#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Bounded clock/statistics and actual shim completion+Mach fixtures. No UI,
GPU commands, real account, normal Steam, game or global artifact publication."""
import hashlib,json,os,pathlib,subprocess,tempfile,uuid
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-performance-',dir=WORK/'tests'));run.chmod(0o700)
 include=ROOT/'Sources/ReadyHostedView/include'
 files=[ROOT/'NativeEmbedding/ReadyHostedGameShim.m',ROOT/'Sources/ReadyHostedView/ReadyHostedView.m',*sorted(include.glob('*.h')),ROOT/'Synthetic/ReadyHostedPerformanceStatsProbe.c',ROOT/'Synthetic/ReadyHostedCompletionProbe.m',pathlib.Path(__file__).resolve()]
 before={str(p.relative_to(ROOT)):sha(p)for p in files}
 env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','READY_','Steam','STEAM','MTL_HUD_','RHG_'))}
 env.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/hosted-performance'),RHG_PERF_PROFILE='1')
 logs=[]
 def call(command,timeout=30,expected=0,environment=None):
  p=subprocess.run(list(map(str,command)),cwd=ROOT,env=environment or env,capture_output=True,text=True,timeout=timeout)
  logs.append(p.stdout+p.stderr);(run/'build.log').write_text('\n'.join(logs))
  if p.returncode!=expected:raise RuntimeError('Own performance fixture failed: '+str(run/'build.log'))
  return p
 flags=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-Wno-deprecated-declarations','-I',include,'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-framework','CoreGraphics']
 call(['xcrun','clang','-std=c11','-O1','-Wall','-Wextra','-Werror','-I',include,ROOT/'Synthetic/ReadyHostedPerformanceStatsProbe.c','-o',run/'stats'])
 stats=json.loads(call([run/'stats']).stdout)
 source=(ROOT/'NativeEmbedding/ReadyHostedGameShim.m').read_text()
 marker='__attribute__((constructor))static void rhgInstall(void)'
 assert source.count(marker)==1
 # Only this private test copy disables installation/interposition setup. Every
 # measured completion/RPC/stats function remains exactly production source.
 tested=run/'completion-under-test.m';tested.write_text(source.replace(marker,'static void rhgInstall(void)')+'\n'+(ROOT/'Synthetic/ReadyHostedCompletionProbe.m').read_text())
 call(flags+[tested,'-o',run/'completion'])
 results={}
 for name,expected in [('positive',0),('bad-identity',77),('bad-gpu',77)]:
  child={**env,'READY_HOSTED_GAME_SERVICE':'local.ready.hostedgame.fixture.'+uuid.uuid4().hex,'READY_HOSTED_GAME_NONCE':'a1'*32}
  p=call([run/'completion',name],expected=expected,environment=child)
  (run/(name+'.stdout')).write_text(p.stdout);(run/(name+'.stderr')).write_text(p.stderr)
  if expected==0:
   result=json.loads(p.stdout);assert result['passed'];results[name]=result
   rows=[json.loads(line)for line in p.stderr.splitlines()if line.startswith('{')]
   profile=next(r for r in rows if r.get('type')=='hosted-guest-performance')
   assert profile['unit']=='nanoseconds'and profile['rpc']['present']['total']['count']==2 and profile['gpuCallbackToWorker']['count']==2
   forbidden={'nonce','account','username','token','ticket','characters','coordinates','pointerX','pointerY','path'}
   def safe(v):
    if isinstance(v,dict):assert not(forbidden&set(v));[safe(x)for x in v.values()]
    elif isinstance(v,list):[safe(x)for x in v]
   safe(profile);assert len(p.stderr.encode())<=65536
   results['boundedSafeJSON']=True
  else:
   refusal=next(json.loads(line)for line in p.stderr.splitlines()if line.startswith('{'))
   reason='present-surface-identity-changed'if name=='bad-identity'else'guest-metal-command-failed'
   assert refusal['reason']==reason;results[name]={'expectedExit':77,'safeReason':reason,'passed':True}
 assert before=={str(p.relative_to(ROOT)):sha(p)for p in files}
 report={'passed':True,'stats':stats,'completionCases':results,'sourceHashes':before,'fixtureOnly':True,'actualMachIPC':True,'GPUOrUIOrGameOrAccountUsed':False,'maximumOutstandingFrames':1}
 retained=run/'report.json';retained.write_text(json.dumps(report,indent=2)+'\n');retained.chmod(0o600)
 pointer={'passed':True,'statsChecks':stats['count'],'completionChecks':results['positive']['count'],'negativeCases':2,'safeJSON':True,'retainedReport':str(retained),'retainedReportSHA256':sha(retained),'sourceHashes':before,'fixtureOnly':True,'GPUOrUIOrGameOrAccountUsed':False}
 (ROOT/'Evidence/hosted-performance-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
