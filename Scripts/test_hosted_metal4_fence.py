#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real own Metal4 queues/events; no game, account, WindowServer surface or global build."""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def region(source):return source[source.index('// One context per actual guest queue.'):source.index('static void rhgInstallQueue',source.index('// One context per actual guest queue.'))]
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='hosted-metal4-fence-',dir=WORK/'tests'));run.chmod(0o700)
 shim=ROOT/'NativeEmbedding/ReadyHostedGameShim.m';fixture=ROOT/'Synthetic/ReadyHostedMetal4FenceProbe.m';include=ROOT/'Sources/ReadyHostedView/include';source=shim.read_text();gpu=region(source)
 old=subprocess.check_output(['git','show','e8e5aba:NativeEmbedding/ReadyHostedGameShim.m'],cwd=ROOT,text=True);start=old.index('static void rhgSignalDrawable(id<MTL4CommandQueue>queue,SEL selector,id value) API_AVAILABLE');reference=old[start:old.index('static void rhgInstallQueue',start)].replace('rhgSignalDrawable','rhgSignalDrawableReference')
 marker='__attribute__((constructor))static void rhgInstall(void)';assert source.count(marker)==1
 generated=run/'own-metal4.m';generated.write_text(source.replace(marker,'static void rhgInstall(void)')+'\n'+reference+'\n'+fixture.read_text());binary=run/'probe'
 command=['xcrun','clang','-fobjc-arc','-fblocks','-std=gnu11','-O1','-Wno-deprecated-declarations','-I',str(include),str(generated),'-framework','Cocoa','-framework','Metal','-framework','QuartzCore','-framework','IOSurface','-framework','CoreGraphics','-o',str(binary)]
 r=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,timeout=90);(run/'compile.log').write_text(r.stdout+r.stderr)
 if r.returncode:raise RuntimeError('Own Metal4 compile failed: '+str(run/'compile.log')+' '+r.stderr[-2000:])
 env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','READY_','Steam','STEAM','RHG_','MTL_'))};env.update(TMPDIR=str(WORK/'tmp')+'/',RHG_PERF_PROFILE='0',MTL_HUD_ENABLED='0')
 cases={};guard=['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)']
 for mode,expected in [('positive',0),('overflow',77),('overlap',77)]:
  r=subprocess.run([*guard,str(binary),mode],env=env,capture_output=True,text=True,timeout=30);(run/(mode+'.stdout')).write_text(r.stdout);(run/(mode+'.stderr')).write_text(r.stderr)
  if r.returncode!=expected:raise RuntimeError('Own Metal4 '+mode+' failed; retained '+str(run)+' '+r.stderr[-1500:])
  if expected==0:cases[mode]=json.loads(r.stdout);assert cases[mode]['passed']
  else:
   refusal=next(json.loads(line)for line in r.stderr.splitlines()if line.startswith('{'));assert refusal['reason']==('metal4-fence-sequence-exhausted'if mode=='overflow'else'metal4-fence-overlap');cases[mode]={'passed':True,'expectedExit':77,'reason':refusal['reason']}
 assert gpu==region(shim.read_text())
 report={'passed':True,'cases':cases,'gpuSourceSHA256':hashlib.sha256(gpu.encode()).hexdigest(),'compiledWholeShimSHA256':hashlib.sha256(source.encode()).hexdigest(),'currentWholeShimSHA256':sha(shim),'baselineReferenceCommit':'e8e5aba','baselineFunctionSHA256':hashlib.sha256(reference.encode()).hexdigest(),'fixtureSHA256':sha(fixture),'scriptSHA256':sha(pathlib.Path(__file__)),'protocolSHA256':sha(include/'ReadyHostedGameProtocol.h'),'binarySHA256':sha(binary),'networkDenied':True,'fenceObservationPollingIntervalMilliseconds':1,'fenceRoundtripIncludesObserverPolling':True,'gameFPSOrRenderPerformanceClaimed':False,'privateBuildOnly':True,'report':str(run/'report.json')};(run/'report.json').write_text(json.dumps(report,indent=2)+'\n');pointer={'passed':True,'realMetal4QueueAndEvents':True,'checks':cases['positive']['checks'],'negativeCases':2,'retainedReport':str(run/'report.json'),'retainedReportSHA256':sha(run/'report.json'),'gpuSourceSHA256':report['gpuSourceSHA256'],'wholeShimSHA256':sha(shim),'GPUOrUIOrGameOrAccountUsed':'Own Metal4 queue/event operations only; no UI, game or account','gameFPSClaimed':False};(ROOT/'Evidence/hosted-metal4-fence-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
